// Animations.
//
// The framework does not animate anything itself. It builds an animation in
// the engine (a target property of a visual or gradient, keyframes with times,
// values and an interpolation each), says Play, and is told when it is over.
// The engine evaluates every playing animation against the clock each frame.
//
// The interpolation curves here are written from their names and parameters
// (linear, s-curve, exponential, ...); the original engine's exact formulas
// are not known, so timing inside a segment may differ slightly from Windows.
#import <QuartzCore/QuartzCore.h>
#import "sp_scene.h"

typedef NS_ENUM(int, SpAnimProperty) {
    SpAnimAlpha, SpAnimColor, SpAnimPosition, SpAnimScale, SpAnimSize, SpAnimRotation,
    SpAnimGradientOffset, SpAnimGradientColorMask,
};

typedef NS_ENUM(int, SpInterp) {
    SpInterpLinear, SpInterpSCurve, SpInterpExp, SpInterpLog, SpInterpSine, SpInterpCosine, SpInterpBezier,
    SpInterpEaseIn, SpInterpEaseOut,
};

typedef struct {
    float time;
    SpInterp interp;
    float weight, h1, h2;
    float v[4];          // float: v[0]; vector: xyz; colour: a r g b (0..1); rotation: axis xyz + angle
    BOOL dynamic, multiply;
} SpKeyframe;

@interface SpAnimation : SpObject
@property (nonatomic) SpAnimProperty property;
@property (nonatomic, weak) SpObject *target;
@property (nonatomic, readonly) int repeatCount;   // below 0: for ever
- (float)duration;
- (BOOL)decoration;
- (void)tick:(CFTimeInterval)now;
@end

static NSHashTable<SpAnimation *> *s_playing;
static float s_speed = 1;

// The curve every eased type is built from: (b^t - 1) / (b - 1) with
// b = 1 + 9 * weight, which starts slowly and ends fast. At weight 1 it is
// (10^t - 1) / 9, the inverse of log10(1 + 9t); at weight 0 it is a straight
// line.
static float grow(float weight, float t) {
    if (weight < 1e-4f) return t;
    float rate = logf(1 + 9 * weight);
    return (expf(rate * t) - 1) / (9 * weight);
}

// How far a keyframe has got towards the next (0..1) at fraction t of the
// time between them.
//
// The original engine's formulas are not published. These were measured
// from a 30 fps recording of Media Center (ref/video, tools/measure), with
// the recording's clock fixed by the launch logo's two straight segments:
//
//   "EaseIn, 2.0, 0.80"  the launch logo's scale, 3 to 1 in a second: a
//                        steady 1.163 a second until 0.8, then a settle
//                        that decays by the same ratio every frame
//   "EaseIn, 1.0, 0.4"   a start-menu strip arriving: steady 1.57, then the
//                        same kind of settle, slower
//   "EaseIn, 1.0, 0.8"   the selector growing: steady 1.15
//   "SCurve, 2.0"        a strip move: symmetric, each half an exponential
//
// One curve fits all four to within the measuring error: `grow` above. An
// S-curve is `grow` to the half-way point and its mirror image after it.
// EaseIn is a steady speed until the "ease percent" of the time, then
// `grow` backwards, sized so that the speed does not jump where they meet.
// EaseOut is taken to be EaseIn backwards (it sets off slowly); Exp is
// `grow` itself and Log its inverse. Those three were not on the recording.
static float ease(const SpKeyframe *k, float t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    float w = k->weight >= 0 ? k->weight : 1;
    switch (k->interp) {
        case SpInterpLinear: return t;
        case SpInterpSCurve: return t < 0.5f ? 0.5f * grow(w, 2 * t) : 1 - 0.5f * grow(w, 2 * (1 - t));
        case SpInterpExp: return grow(w, t);
        case SpInterpLog: return w < 1e-4f ? t : logf(1 + 9 * w * t) / logf(1 + 9 * w);
        case SpInterpSine: return sinf(t * (float)M_PI_2);
        case SpInterpCosine: return 1 - cosf(t * (float)M_PI_2);
        case SpInterpBezier: {
            float u = 1 - t;
            return 3 * u * u * t * k->h1 + 3 * u * t * t * k->h2 + t * t * t;
        }
        case SpInterpEaseIn:
        case SpInterpEaseOut: {
            float p = k->h1 < 0 ? 0 : (k->h1 > 1 ? 1 : k->h1);      // the "ease percent"
            BOOL mirror = k->interp == SpInterpEaseOut;
            float x = mirror ? 1 - t : t;
            // The settle's mean speed as a share of the steady speed: one
            // over the slope `grow` ends with.
            float mean = w < 1e-4f ? 1 : 9 * w / ((1 + 9 * w) * logf(1 + 9 * w));
            float speed = 1 / (p + (1 - p) * mean);
            float y = (x <= p || p >= 1) ? speed * x : 1 - (1 - speed * p) * grow(w, (1 - x) / (1 - p));
            return mirror ? 1 - y : y;
        }
    }
    return t;
}

static void argb_to_floats(uint32_t c, float v[4]) {
    v[0] = (c >> 24) / 255.0f;
    v[1] = ((c >> 16) & 0xFF) / 255.0f;
    v[2] = ((c >> 8) & 0xFF) / 255.0f;
    v[3] = (c & 0xFF) / 255.0f;
}

static uint32_t floats_to_argb(const float v[4]) {
    uint32_t out = 0;
    for (int i = 0; i < 4; i++) {
        float f = v[i] < 0 ? 0 : v[i] > 1 ? 1 : v[i];
        out = out << 8 | (uint32_t)lroundf(f * 255);
    }
    return out;
}

@implementation SpAnimation {
    NSMutableData *_frames;
    int _count;
    int _repeatCount, _stopCommand;
    BOOL _playing;
    CFTimeInterval _start;
    NSMutableArray<NSArray<NSNumber *> *> *_callbacks;
    NSMutableArray<NSNumber *> *_links;
}

- (instancetype)init {
    if ((self = [super init])) {
        _frames = [NSMutableData data];
        _callbacks = [NSMutableArray array];
        _links = [NSMutableArray array];
        _stopCommand = 2;   // MoveToEnd
    }
    return self;
}

- (SpKeyframe *)frame:(int)index {
    if (index < 0 || index > 4096) return NULL;
    if (index >= _count) {
        _frames.length = (NSUInteger)(index + 1) * sizeof(SpKeyframe);
        _count = index + 1;
    }
    return (SpKeyframe *)_frames.mutableBytes + index;
}

// ---- reading and writing the target property ------------------------------------

- (void)read:(float *)v {
    v[0] = v[1] = v[2] = v[3] = 0;
    SpVisual *vis = [_target isKindOfClass:[SpVisual class]] ? (SpVisual *)_target : nil;
    SpGradient *grad = [_target isKindOfClass:[SpGradient class]] ? (SpGradient *)_target : nil;
    switch (_property) {
        case SpAnimAlpha: v[0] = vis.alpha; break;
        case SpAnimColor: argb_to_floats(vis.color, v); break;
        case SpAnimPosition: v[0] = vis.position.x; v[1] = vis.position.y; v[2] = vis.position.z; break;
        case SpAnimScale: v[0] = vis.scale.x; v[1] = vis.scale.y; v[2] = vis.scale.z; break;
        case SpAnimSize: v[0] = vis.size.x; v[1] = vis.size.y; v[2] = vis.size.z; break;
        case SpAnimRotation: v[0] = vis.axis.x; v[1] = vis.axis.y; v[2] = vis.axis.z; v[3] = vis.angle; break;
        case SpAnimGradientOffset: v[0] = grad.offset; break;
        case SpAnimGradientColorMask: argb_to_floats(grad.colorMask, v); break;
    }
}

- (void)write:(const float *)v {
    SpVisual *vis = [_target isKindOfClass:[SpVisual class]] ? (SpVisual *)_target : nil;
    SpGradient *grad = [_target isKindOfClass:[SpGradient class]] ? (SpGradient *)_target : nil;
    switch (_property) {
        case SpAnimAlpha: vis.alpha = v[0] < 0 ? 0 : v[0] > 1 ? 1 : v[0]; break;
        case SpAnimColor: vis.color = floats_to_argb(v); break;
        case SpAnimPosition: vis.position = (SpVec3){ v[0], v[1], v[2] }; break;
        case SpAnimScale: vis.scale = (SpVec3){ v[0], v[1], v[2] }; break;
        case SpAnimSize: vis.size = (SpVec3){ v[0], v[1], v[2] }; break;
        case SpAnimRotation: vis.axis = (SpVec3){ v[0], v[1], v[2] }; vis.angle = v[3]; break;
        case SpAnimGradientOffset: grad.offset = v[0]; break;
        case SpAnimGradientColorMask: grad.colorMask = floats_to_argb(v); break;
    }
    if (self.decoration) sp_scene_invalidate_looping();
    else sp_scene_invalidate();
}

// ---- playing -------------------------------------------------------------------

// Repeating for ever, or slow (a background drifting for seconds): not a
// page arriving, so scripted runs do not wait for it (see sp_animation_settling).
- (BOOL)decoration {
    return _repeatCount < 0 || [self duration] > 2.0;
}

- (float)duration {
    return _count ? ((SpKeyframe *)_frames.mutableBytes)[_count - 1].time : 0;
}

- (void)applyAt:(float)t {
    if (_count == 0 || !_target) return;
    SpKeyframe *f = _frames.mutableBytes;
    int i = 0;
    while (i < _count - 2 && t >= f[i + 1].time) i++;
    if (_count == 1 || t <= f[0].time) {
        [self write:f[0].v];
        return;
    }
    SpKeyframe *a = &f[i], *b = &f[i + 1];
    float span = b->time - a->time;
    float u = span > 0 ? ease(a, (t - a->time) / span) : 1;
    float v[4];
    for (int k = 0; k < 4; k++) v[k] = a->v[k] + (b->v[k] - a->v[k]) * u;
    if (_property == SpAnimRotation && t >= b->time) memcpy(v, b->v, sizeof(v));
    [self write:v];
}

- (void)play {
    if (_playing || _count == 0) return;
    float current[4];
    [self read:current];
    SpKeyframe *f = _frames.mutableBytes;
    // Keyframes are numbered in the order the framework added them, which is
    // not time order (it tends to add the one at time zero last).
    for (int i = 1; i < _count; i++) {
        SpKeyframe k = f[i];
        int j = i - 1;
        while (j >= 0 && f[j].time > k.time) { f[j + 1] = f[j]; j--; }
        f[j + 1] = k;
    }
    // A "dynamic" keyframe is relative to the property as it is now: scaled
    // by it (alpha, scale) or offset from it (position and the rest).
    for (int i = 0; i < _count; i++) {
        if (!f[i].dynamic) continue;
        for (int k = 0; k < 4; k++) f[i].v[k] = f[i].multiply ? f[i].v[k] * current[k] : f[i].v[k] + current[k];
        f[i].dynamic = NO;
    }
    if (wmc_log_enabled("anim")) {
        static const char *const names[] = { "alpha", "color", "position", "scale", "size", "rotation", "grad-offset", "grad-mask" };
        NSMutableString *desc = [NSMutableString string];
        for (int i = 0; i < _count; i++) [desc appendFormat:@" %.2fs=%.3g,%.3g,%.3g", f[i].time, f[i].v[0], f[i].v[1], f[i].v[2]];
        wmc_log("anim", "play %#x %s on %#x (now %.3g,%.3g,%.3g) repeat %d stop %d:%s", self.handle, names[_property],
                _target.handle, current[0], current[1], current[2], _repeatCount, _stopCommand, desc.UTF8String);
    }
    _playing = YES;
    _start = CACurrentMediaTime();
    if (!s_playing) s_playing = [NSHashTable weakObjectsHashTable];
    [s_playing addObject:self];
    [self applyAt:0];
}

- (void)finish:(float)progress command:(int)command {
    if (!_playing) return;
    _playing = NO;
    [s_playing removeObject:self];
    WLOG("anim", "end  %#x on %#x progress %.2f command %d", self.handle, _target.handle, progress, command);
    if (command == 1) [self applyAt:0];                    // MoveToBegin
    else if (command == 2) [self applyAt:[self duration]];  // MoveToEnd
    for (NSArray<NSNumber *> *cb in [_callbacks copy]) {
        struct Sp_LocalAnimationCallback_OnComplete msg = {0};
        msg.size = sizeof(msg);
        msg.msgid = SpMsg_AnimationCallback_OnComplete;
        msg.idObjectSubject.value = cb[0].unsignedIntValue;
        msg.target.value = self.handle;
        msg.flAnimationProgress = progress;
        [self.context sendCallback:&msg toContext:cb[1].unsignedIntValue];
    }
    for (NSNumber *next in [_links copy]) {
        SpAnimation *a = [self.context objectForHandle:next.unsignedIntValue];
        if ([a isKindOfClass:[SpAnimation class]]) [a play];
    }
}

- (void)tick:(CFTimeInterval)now {
    if (!_playing) return;
    if (!_target) {
        [self finish:0 command:0];
        return;
    }
    float duration = [self duration];
    float elapsed = (float)(now - _start) * s_speed;
    if (duration <= 0) {
        [self finish:1 command:2];
        return;
    }
    if (elapsed >= duration) {
        int loop = (int)floorf(elapsed / duration);
        if (_repeatCount >= 0 && loop > _repeatCount) {
            [self finish:1 command:2];
            return;
        }
        elapsed = fmodf(elapsed, duration);
    }
    [self applyAt:elapsed];
}

- (void)spDestroy {
    _playing = NO;
    [s_playing removeObject:self];
}

- (void)spMessage:(const SpMessage *)msg {
    // Every keyframe message starts with the keyframe index.
    const struct Sp_RemoteAnimation_SetLinear *head = (const void *)msg;
    switch (msg->nMsg) {
        case SpMsg_Animation_AddCompletionLink:
            [_links addObject:@(((const struct Sp_RemoteAnimation_AddCompletionLink *)msg)->aniToPlayNext.value)];
            break;
        case SpMsg_Animation_SetEaseOut: {
            const struct Sp_RemoteAnimation_SetEaseOut *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) { k->interp = SpInterpEaseOut; k->weight = m->flWeight; k->h1 = m->flHandle; }
            break;
        }
        case SpMsg_Animation_SetEaseIn: {
            const struct Sp_RemoteAnimation_SetEaseIn *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) { k->interp = SpInterpEaseIn; k->weight = m->flWeight; k->h1 = m->flHandle; }
            break;
        }
        case SpMsg_Animation_SetBezier: {
            const struct Sp_RemoteAnimation_SetBezier *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) { k->interp = SpInterpBezier; k->h1 = m->flHandle1; k->h2 = m->flHandle2; }
            break;
        }
        case SpMsg_Animation_SetCosine: { SpKeyframe *k = [self frame:head->idxKeyframe]; if (k) k->interp = SpInterpCosine; break; }
        case SpMsg_Animation_SetSine: { SpKeyframe *k = [self frame:head->idxKeyframe]; if (k) k->interp = SpInterpSine; break; }
        case SpMsg_Animation_SetLinear: { SpKeyframe *k = [self frame:head->idxKeyframe]; if (k) k->interp = SpInterpLinear; break; }
        case SpMsg_Animation_SetSCurve: {
            const struct Sp_RemoteAnimation_SetSCurve *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) { k->interp = SpInterpSCurve; k->weight = m->flWeight; }
            break;
        }
        case SpMsg_Animation_SetLogarithmic: {
            const struct Sp_RemoteAnimation_SetLogarithmic *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) { k->interp = SpInterpLog; k->weight = m->flWeight; }
            break;
        }
        case SpMsg_Animation_SetExponential: {
            const struct Sp_RemoteAnimation_SetExponential *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) { k->interp = SpInterpExp; k->weight = m->flWeight; }
            break;
        }
        case SpMsg_Animation_SetDynamicRotation:
        case SpMsg_Animation_SetDynamicARGBColor: {
            SpKeyframe *k = [self frame:head->idxKeyframe];
            if (k) { k->dynamic = YES; k->multiply = NO; }
            break;
        }
        case SpMsg_Animation_SetDynamicRGBColor:
        case SpMsg_Animation_SetDynamicVector3:
        case SpMsg_Animation_SetDynamicFloat: {
            const struct Sp_RemoteAnimation_SetDynamicFloat *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) { k->dynamic = YES; k->multiply = m->fMultiply != 0; }
            break;
        }
        case SpMsg_Animation_SetRotation: {
            const struct Sp_RemoteAnimation_SetRotation *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) { k->v[0] = m->rot.m_axis.m_x; k->v[1] = m->rot.m_axis.m_y; k->v[2] = m->rot.m_axis.m_z; k->v[3] = m->rot.m_angleRad; }
            break;
        }
        case SpMsg_Animation_SetColorF: {
            const struct Sp_RemoteAnimation_SetColorF *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) memcpy(k->v, &m->clrfValue, sizeof(float) * 4);
            break;
        }
        case SpMsg_Animation_SetARGBColor:
        case SpMsg_Animation_SetRGBColor: {
            const struct Sp_RemoteAnimation_SetARGBColor *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) {
                argb_to_floats(m->clrValue.value, k->v);
                if (msg->nMsg == SpMsg_Animation_SetRGBColor) k->v[0] = 1;
            }
            break;
        }
        case SpMsg_Animation_SetVector3: {
            const struct Sp_RemoteAnimation_SetVector3 *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) { k->v[0] = m->vValue.m_x; k->v[1] = m->vValue.m_y; k->v[2] = m->vValue.m_z; }
            break;
        }
        case SpMsg_Animation_SetFloat: {
            const struct Sp_RemoteAnimation_SetFloat *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) k->v[0] = m->flValue;
            break;
        }
        case SpMsg_Animation_RemoveCallback: {
            const struct Sp_RemoteAnimation_RemoveCallback *m = (const void *)msg;
            [_callbacks removeObject:@[ @(m->objcb.value), @(m->ctxcb.value) ]];
            break;
        }
        case SpMsg_Animation_AddCallback: {
            const struct Sp_RemoteAnimation_AddCallback *m = (const void *)msg;
            [_callbacks addObject:@[ @(m->objcb.value), @(m->ctxcb.value) ]];
            break;
        }
        case SpMsg_Animation_AddKeyframe:
        case SpMsg_Animation_SetKeyframeTime: {
            const struct Sp_RemoteAnimation_AddKeyframe *m = (const void *)msg;
            SpKeyframe *k = [self frame:m->idxKeyframe];
            if (k) k->time = m->flTimeSec;
            break;
        }
        case SpMsg_Animation_Stop: {
            const struct Sp_RemoteAnimation_Stop *m = (const void *)msg;
            float d = [self duration];
            float p = d > 0 ? fminf(1, (float)(CACurrentMediaTime() - _start) * s_speed / d) : 1;
            [self finish:p command:(int)m->cmd];
            break;
        }
        case SpMsg_Animation_Stop_2: {
            float d = [self duration];
            float p = d > 0 ? fminf(1, (float)(CACurrentMediaTime() - _start) * s_speed / d) : 1;
            [self finish:p command:_stopCommand];
            break;
        }
        case SpMsg_Animation_Play:
            [self play];
            break;
        case SpMsg_Animation_SetStopCommand:
            _stopCommand = (int)((const struct Sp_RemoteAnimation_SetStopCommand *)msg)->cmd;
            break;
        case SpMsg_Animation_SetAutoStop:
            break;
        case SpMsg_Animation_SetRepeatCount:
            _repeatCount = ((const struct Sp_RemoteAnimation_SetRepeatCount *)msg)->cRepeats;
            break;
        case SpMsg_Animation_SetKeyframeCount: {
            int n = ((const struct Sp_RemoteAnimation_SetKeyframeCount *)msg)->cKeyframes;
            if (n > 0) [self frame:n - 1];
            break;
        }
        default:
            [self spUnhandled:msg];
    }
}

@end

// Brings every playing animation up to the present. Called before each
// frame is drawn, by the idle timer, and before snapshots.
void sp_video_tick(void);
void sp_animation_tick(void) {
    sp_video_tick();   // (playing videos move on the same beat)
    if (!s_playing.count) return;
    CFTimeInterval now = CACurrentMediaTime();
    for (SpAnimation *a in s_playing.allObjects) [a tick:now];
}

BOOL sp_animation_active(void) { return s_playing.count > 0; }

// Whether an animation that is not decoration is playing.
BOOL sp_animation_settling(void) {
    for (SpAnimation *a in s_playing.allObjects)
        if (!a.decoration) return YES;
    return NO;
}

// --------------------------------------------------------------- AnimationManager

@interface SpAnimationManager : SpObject
@end

@implementation SpAnimationManager {
    NSTimer *_timer;
}

- (void)spConstruct:(const SpMessage *)msg {
    // Keeps animations moving (and their completion callbacks arriving)
    // when no window is drawing frames, as in offscreen runs.
    _timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) { sp_animation_tick(); }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)spDestroy {
    [_timer invalidate];
    _timer = nil;
}

- (void)build:(SpAnimProperty)property subject:(uint32_t)subject handle:(uint32_t)handle {
    SpAnimation *a = [SpAnimation new];
    a.handle = handle;
    a.context = self.context;
    a.spClassName = @"Splash::Rendering::Animation";
    a.property = property;
    a.target = [self.context objectForHandle:subject];
    [self.context registerObject:a];
}

- (void)spMessage:(const SpMessage *)msg {
    // Every Build message has the same shape: subject, then the new handle.
    const struct Sp_RemoteAnimationManager_BuildAlphaAnimation *m = (const void *)msg;
    switch (msg->nMsg) {
        case SpMsg_AnimationManager_SetAnimationRate:
        case SpMsg_AnimationManager_PulseTimeAdvance:
            break;
        case SpMsg_AnimationManager_SetGlobalSpeedAdjustment: {
            float f = ((const struct Sp_RemoteAnimationManager_SetGlobalSpeedAdjustment *)msg)->flFactor;
            s_speed = f > 0 ? f : 1;
            break;
        }
        case SpMsg_AnimationManager_BuildGradientColorMaskAnimation:
            [self build:SpAnimGradientColorMask subject:m->viSubject.value handle:m->idAnimation.value];
            break;
        case SpMsg_AnimationManager_BuildGradientOffsetAnimation:
            [self build:SpAnimGradientOffset subject:m->viSubject.value handle:m->idAnimation.value];
            break;
        case SpMsg_AnimationManager_BuildRotationAnimation:
            [self build:SpAnimRotation subject:m->viSubject.value handle:m->idAnimation.value];
            break;
        case SpMsg_AnimationManager_BuildSizeAnimation:
            [self build:SpAnimSize subject:m->viSubject.value handle:m->idAnimation.value];
            break;
        case SpMsg_AnimationManager_BuildScaleAnimation:
            [self build:SpAnimScale subject:m->viSubject.value handle:m->idAnimation.value];
            break;
        case SpMsg_AnimationManager_BuildPositionAnimation:
            [self build:SpAnimPosition subject:m->viSubject.value handle:m->idAnimation.value];
            break;
        case SpMsg_AnimationManager_BuildColorAnimation:
            [self build:SpAnimColor subject:m->viSubject.value handle:m->idAnimation.value];
            break;
        case SpMsg_AnimationManager_BuildAlphaAnimation:
            [self build:SpAnimAlpha subject:m->viSubject.value handle:m->idAnimation.value];
            break;
        default:
            [self spUnhandled:msg];
    }
}

@end

__attribute__((constructor)) static void register_animation_classes(void) {
    sp_register_class(@"Splash::Rendering::AnimationManager", [SpAnimationManager class]);
    sp_register_class(@"Splash::Rendering::Animation", [SpAnimation class]);
}
