// XP Media Center Edition 2002's render agent: visuals (Core Animation
// layers), the form window, animations, input, and the test hooks the other
// engine has (WMC_HEADLESS, WMC_SNAPSHOT, WMC_STEPS).
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import "duser.h"

#ifdef WMC_XP2002

HWND wmc_window_adopt(const char *className, void *proc, WmcThreadQueue *queue);
void *du_session_new(void);

enum { GS_VISIBLE = 1, GS_MOUSE_FOCUS = 8 };
enum { GORDER_ANY, GORDER_BEFORE, GORDER_BEHIND, GORDER_TOP, GORDER_BOTTOM };
enum { RA_OBJECT_DELETED = 1, RA_BATCH_COMPLETED = 2 };
enum { FORM_CREATED = 1, FORM_DESTROYED = 2, FORM_LOAD = 3, FORM_CLOSING = 4, FORM_STATE = 5 };

// ---- objects ------------------------------------------------------------------------

@interface DuObject : NSObject
@property (nonatomic) uint32_t handle;
@end
@implementation DuObject
@end

@interface DuVisual : DuObject
@property (nonatomic, strong) CALayer *layer, *content;
@property (nonatomic, weak) DuVisual *parent;
@property (nonatomic, strong) NSMutableArray<DuVisual *> *children;
@property (nonatomic) CGRect rect;
@property (nonatomic) uint32_t style;
@property (nonatomic) uint8_t alpha;
@property (nonatomic) CGSize scale;
@property (nonatomic) CGPoint center;
@property (nonatomic, strong) NSArray<DuOp *> *ops;
@end
@implementation DuVisual
@end

// The form's client area is in pixels (as on Windows), and so is the layer
// tree; on the Mac it is shown scaled to points.
@interface DuForm : DuObject
@property (nonatomic, strong) DuVisual *root;
@property (nonatomic) int width, height, x, y;   // client size; the window's place
@property (nonatomic) int restoredW, restoredH;  // the client size when not maximised
@property (nonatomic) BOOL visible, loaded;
@property (nonatomic) uint32_t mode;             // 0 normal, 1 minimised, 2 maximised
@property (nonatomic) uint32_t style;            // the window style when normal (Win32 WS_*)
@property (nonatomic, copy) NSString *title;
@property (nonatomic) HWND hwnd;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) CALayer *host;     // the root of the layer tree (top-left origin)
@property (nonatomic, strong) CALayer *pre;      // drawn before the scene (full-screen video), under the root
@end
@implementation DuForm
@end

typedef struct {
    float time;
    int interp;
    float weight;
    int relative;
    uint32_t flags;          // rect keyframes: 1 position, 2 size
    float v[4];
} DuKeyframe;

@interface DuAnimation : DuObject
@property (nonatomic) int type, loop;
@property (nonatomic, weak) DuVisual *visual;
@property (nonatomic, strong) NSMutableData *frames;
@property (nonatomic) int count;
@property (nonatomic) BOOL playing;
@property (nonatomic) CFTimeInterval start;
@end
@implementation DuAnimation
@end

// ---- the agent ----------------------------------------------------------------------

static uint32_t s_root_cookie;
static NSMutableDictionary<NSNumber *, DuObject *> *s_objects;
static DuForm *s_form;                          // (one form: Media Center's)
static NSMutableSet<DuAnimation *> *s_playing;
static NSTimer *s_timer;
static BOOL s_headless;

static id object_for(uint32_t handle) { return handle ? s_objects[@(handle)] : nil; }

static DuVisual *visual_for(uint32_t handle) {
    id o = object_for(handle);
    return [o isKindOfClass:DuVisual.class] ? o : nil;
}

static void tick(void);
static void run_steps(void);

void du_agent_start(uint32_t rootCookie) {
    s_root_cookie = rootCookie;
    s_objects = [NSMutableDictionary dictionary];
    s_playing = [NSMutableSet set];
    s_headless = getenv("WMC_HEADLESS") != NULL;
    s_timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) { tick(); }];
    [NSRunLoop.mainRunLoop addTimer:s_timer forMode:NSRunLoopCommonModes];
}

void du_agent_stop(void) {
    [s_timer invalidate];
    s_timer = nil;
    [s_form.window orderOut:nil];
    s_form = nil;
    [s_objects removeAllObjects];
}

// ---- visuals --------------------------------------------------------------------------

static CATransform3D scale_about(CGSize scale, CGPoint c) {
    CATransform3D t = CATransform3DMakeTranslation(c.x, c.y, 0);
    t = CATransform3DScale(t, scale.width, scale.height, 1);
    return CATransform3DTranslate(t, -c.x, -c.y, 0);
}

static void place(DuVisual *v) {
    v.layer.frame = v.rect;
    v.content.frame = CGRectMake(0, 0, v.rect.size.width, v.rect.size.height);
    v.layer.hidden = !(v.style & GS_VISIBLE);
    v.layer.opacity = v.alpha / 255.0f;
    BOOL scaled = v.scale.width != 1 || v.scale.height != 1;
    v.layer.transform = scaled ? scale_about(v.scale, v.center) : CATransform3DIdentity;
}

static CALayer *new_layer(void) {
    CALayer *l = [CALayer layer];
    l.anchorPoint = CGPointZero;
    l.masksToBounds = NO;
    return l;
}

// A list of render operations drawn into a layer of that size: one layer
// per operation.
static void draw_list(CALayer *into, NSArray<DuOp *> *ops, CGRect bounds) {
    into.sublayers = nil;
    for (DuOp *op in ops) {
        CALayer *l = new_layer();
        CGRect dst = op.hasDst ? op.dst : bounds;
        switch (op.kind) {
            case DuOpImage: {
                l.contents = (__bridge id)op.image.image;
                if (op.hasSrc && op.image.width > 0 && op.image.height > 0) {
                    CGFloat w = op.image.width, h = op.image.height;
                    l.contentsRect = CGRectMake(op.src.origin.x / w, op.src.origin.y / h, op.src.size.width / w, op.src.size.height / h);
                }
                break;
            }
            case DuOpText: {
                CGSize size = CGSizeMake(MAX(bounds.size.width, op.hasSrc ? CGRectGetMaxX(op.src) : 0),
                                         MAX(bounds.size.height, op.hasSrc ? CGRectGetMaxY(op.src) : 0));
                CGImageRef image = [op.text render:&size];
                l.contents = (__bridge id)image;
                if (op.hasSrc && size.width > 0 && size.height > 0)
                    l.contentsRect = CGRectMake(op.src.origin.x / size.width, op.src.origin.y / size.height,
                                                op.src.size.width / size.width, op.src.size.height / size.height);
                else
                    dst = CGRectMake(0, 0, size.width, size.height);
                if (image) CGImageRelease(image);
                break;
            }
            case DuOpFill: {
                uint32_t c = op.color;
                CGColorRef color = CGColorCreateSRGB(((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0, (c >> 24) / 255.0);
                l.backgroundColor = color;
                CGColorRelease(color);
                break;
            }
            case DuOpSurface:
                du_video_attach(l, op.surface, op.src, op.hasSrc);
                break;
        }
        l.frame = dst;
        [into addSublayer:l];
    }
}

// The visual's drawing, under its children.
static void draw_ops(DuVisual *v) {
    draw_list(v.content, v.ops, CGRectMake(0, 0, v.rect.size.width, v.rect.size.height));
}

static NSArray<DuOp *> *ops_in(const struct Du_DUser_Msg *msg, uint32_t blob) {
    uint32_t len = 0;
    const uint8_t *p = du_blob(msg, blob, &len);
    NSMutableArray<DuOp *> *ops = [NSMutableArray array];
    for (uint32_t i = 0; i + 8 <= len; i += 8) {
        int64_t ptr;
        memcpy(&ptr, p + i, 8);
        DuOp *op = du_object_in((void *)(intptr_t)ptr);
        if ([op isKindOfClass:DuOp.class]) [ops addObject:op];
    }
    return ops;
}

static DuVisual *new_visual(uint32_t handle) {
    DuVisual *v = [DuVisual new];
    v.handle = handle;
    v.layer = new_layer();
    v.content = new_layer();
    [v.layer addSublayer:v.content];
    v.children = [NSMutableArray array];
    v.alpha = 255;
    v.scale = CGSizeMake(1, 1);
    v.style = GS_VISIBLE;
    s_objects[@(handle)] = v;
    return v;
}

static void reparent(DuVisual *v, DuVisual *parent, DuVisual *other, uint32_t order) {
    [v.parent.children removeObject:v];
    [v.layer removeFromSuperlayer];
    v.parent = parent;
    if (!parent) return;
    NSMutableArray *kids = parent.children;
    NSUInteger at = kids.count;                                  // top (drawn last)
    if (order == GORDER_BOTTOM) at = 0;
    else if (order == GORDER_BEFORE && other && [kids containsObject:other]) at = [kids indexOfObject:other] + 1;
    else if (order == GORDER_BEHIND && other && [kids containsObject:other]) at = [kids indexOfObject:other];
    [kids insertObject:v atIndex:at];
    [parent.layer insertSublayer:v.layer atIndex:(unsigned)(at + 1)];   // (the content layer is sublayer 0)
}

// ---- callbacks ---------------------------------------------------------------------------

// The frame Windows would draw around the client area: XP's thick frame is
// four pixels a side, a thin border one (Media Center 2002 has no caption).
static int frame_inset(DuForm *f) {
    if (f.mode == 2) return 0;
    if (f.style & 0x40000) return 4;      // WS_THICKFRAME
    if (f.style & 0x800000) return 1;     // WS_BORDER
    return 0;
}

static void form_simple(uint32_t message, int64_t p1, int64_t p2) {
    struct Du_Form_FormSimpleCallbackMsg m = {0};
    m.ownerCookie = s_form.handle;
    m.ownerMessage = message;
    m.uParam1 = p1;
    m.uParam2 = p2;
    du_callback_post(&m, sizeof(m));
}

static void form_state(uint32_t changed) {
    DuForm *f = s_form;
    if (!f) return;
    struct Du_Form_FormStateCallbackMsg m = {0};
    m.ownerCookie = f.handle;
    m.ownerMessage = FORM_STATE;
    m.uRecentlyChanged = changed;
    m.uCurrentMode = f.mode;
    m.fVisible = f.visible;
    m.szClientDims_cx = f.width;
    m.szClientDims_cy = f.height;
    int inset = frame_inset(f);
    m.rcWindowGlobal_left = f.x;
    m.rcWindowGlobal_top = f.y;
    m.rcWindowGlobal_right = f.x + f.width + 2 * inset;
    m.rcWindowGlobal_bottom = f.y + f.height + 2 * inset;
    m.hMonitor = 1;
    du_callback_post(&m, sizeof(m));
}

// The client area: the layer tree's size, and the root visual's.
static void set_client(DuForm *f, int w, int h) {
    if (w <= 0 || h <= 0 || (w == f.width && h == f.height)) return;
    f.width = w;
    f.height = h;
    f.host.bounds = CGRectMake(0, 0, w, h);
    if (f.root) {
        f.root.rect = CGRectMake(0, 0, w, h);
        place(f.root);
        draw_ops(f.root);
    }
    WLOG("win", "client area %dx%d", w, h);
    form_state(8);
}

// ---- the window -------------------------------------------------------------------------

static CGFloat backing_scale(void) { return NSScreen.mainScreen.backingScaleFactor ?: 1; }

static void key_event(int vk, uint32_t message, uint32_t modifiers);
static void mouse_event(uint32_t message, CGPoint p, uint32_t button);

@interface DuView : NSView
@end
@implementation DuView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)isFlipped { return YES; }
static int vk_for(NSEvent *e) {
    switch (e.keyCode) {
        case 0x24: case 0x4C: return 0x0D;
        case 0x30: return 0x09;
        case 0x31: return 0x20;
        case 0x33: return 0x08;
        case 0x35: return 0x1B;
        case 0x7B: return 0x25;
        case 0x7E: return 0x26;
        case 0x7C: return 0x27;
        case 0x7D: return 0x28;
        case 0x74: return 0x21;
        case 0x79: return 0x22;
    }
    NSString *s = e.charactersIgnoringModifiers.uppercaseString;
    unichar c = s.length ? [s characterAtIndex:0] : 0;
    return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ? c : 0;
}
- (void)keyDown:(NSEvent *)e {
    int vk = vk_for(e);
    if (vk) key_event(vk, 0, 0);
    for (NSUInteger i = 0; i < e.characters.length; i++) {
        unichar c = [e.characters characterAtIndex:i];
        if (c == 0x7F) c = 0x08;
        if (c < 0xF700) key_event(c, 2, 0);
    }
}
- (void)keyUp:(NSEvent *)e { int vk = vk_for(e); if (vk) key_event(vk, 1, 0); }
- (CGPoint)at:(NSEvent *)e {
    CGPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat scale = backing_scale();
    return CGPointMake(p.x * scale, p.y * scale);
}
- (void)mouseDown:(NSEvent *)e { mouse_event(0x201, [self at:e], 1); }
- (void)mouseUp:(NSEvent *)e { mouse_event(0x202, [self at:e], 1); }
- (void)mouseMoved:(NSEvent *)e { mouse_event(0x200, [self at:e], 0); }
- (void)mouseDragged:(NSEvent *)e { mouse_event(0x200, [self at:e], 1); }
- (void)rightMouseDown:(NSEvent *)e { mouse_event(0x204, [self at:e], 2); }
- (void)rightMouseUp:(NSEvent *)e { mouse_event(0x205, [self at:e], 2); }
@end

@interface DuWindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation DuWindowDelegate
- (BOOL)windowShouldClose:(NSWindow *)w {
    form_simple(FORM_CLOSING, 0, 0);
    return NO;   // (Media Center closes it when it has finished)
}
- (void)windowDidResize:(NSNotification *)n {
    NSSize s = s_form.window.contentView.bounds.size;
    CGFloat scale = backing_scale();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    set_client(s_form, (int)lround(s.width * scale), (int)lround(s.height * scale));
    [CATransaction commit];
}
- (void)modeChanged:(uint32_t)mode {
    if (mode == s_form.mode) return;
    s_form.mode = mode;
    form_state(1);
}
- (void)windowDidEnterFullScreen:(NSNotification *)n { [self modeChanged:2]; }
- (void)windowDidExitFullScreen:(NSNotification *)n { [self modeChanged:0]; }
- (void)windowDidMiniaturize:(NSNotification *)n { [self modeChanged:1]; }
- (void)windowDidDeminiaturize:(NSNotification *)n {
    [self modeChanged:(s_form.window.styleMask & NSWindowStyleMaskFullScreen) ? 2 : 0];
}
@end

// Maximised is the Mac's full screen (Media Center's maximised window
// covered the whole screen); runs that must leave the screen alone only
// echo the mode asked for.
static void apply_mode(DuForm *f) {
    NSWindow *w = f.window;
    if (!w || !f.visible || getenv("WMC_NO_ACTIVATE")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL full = (w.styleMask & NSWindowStyleMaskFullScreen) != 0;
        switch (f.mode) {
            case 2: if (w.miniaturized) [w deminiaturize:nil]; if (!full) [w toggleFullScreen:nil]; break;
            case 1: if (full) [w toggleFullScreen:nil]; else [w miniaturize:nil]; break;
            default: if (w.miniaturized) [w deminiaturize:nil]; if (full) [w toggleFullScreen:nil];
        }
    });
}
static DuWindowDelegate *s_delegate;

static void ensure_window(DuForm *f) {
    if (s_headless || f.window) return;
    CGFloat scale = backing_scale();
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, (f.restoredW ?: 1024) / scale, (f.restoredH ?: 768) / scale)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO;
    w.title = f.title ?: @"Media Center";
    w.acceptsMouseMovedEvents = YES;
    DuView *view = [[DuView alloc] initWithFrame:w.contentView.bounds];
    CALayer *container = [CALayer layer];
    container.geometryFlipped = YES;
    container.backgroundColor = f.host.backgroundColor;
    view.layer = container;
    view.wantsLayer = YES;
    f.host.affineTransform = CGAffineTransformMakeScale(1 / scale, 1 / scale);
    f.host.position = CGPointZero;
    [container addSublayer:f.host];
    w.contentView = view;
    if (!s_delegate) s_delegate = [DuWindowDelegate new];
    w.delegate = s_delegate;
    [w center];
    [w makeFirstResponder:view];
    f.window = w;
}

// ---- input -----------------------------------------------------------------------------

static void key_event(int vk, uint32_t message, uint32_t modifiers) {
    DuForm *f = s_form;
    if (!f.root) return;
    struct Du_DUser_KeyboardCommandMsg m = {0};
    m.hOwner = f.root.handle;          // (ownerCookie: the root visual)
    m.uCode = 1;                       // (ownerMessage: a command)
    m.Type = 1;                        // keyboard
    m.vk = (int16_t)vk;
    m.uiMsg = message;                 // 0 down, 1 up, 2 a character
    m.cRep = 1;
    m.dwState = modifiers;
    du_callback_post(&m, sizeof(m));
    WLOG("input", "key vk %#x message %u", vk, message);
}

static DuVisual *hit(DuVisual *v, CGPoint p) {
    if (!v || !(v.style & GS_VISIBLE)) return nil;
    if (!CGRectContainsPoint(CGRectMake(0, 0, v.rect.size.width, v.rect.size.height), p)) return nil;
    for (DuVisual *c in v.children.reverseObjectEnumerator) {
        DuVisual *h = hit(c, CGPointMake(p.x - c.rect.origin.x, p.y - c.rect.origin.y));
        if (h) return h;
    }
    return (v.style & GS_MOUSE_FOCUS) ? v : nil;
}

static void mouse_event(uint32_t message, CGPoint p, uint32_t button) {
    DuForm *f = s_form;
    if (!f.root) return;
    struct Du_Gadget_WindowInputCallbackMsg m = {0};
    m.ownerCookie = f.root.handle;
    m.ownerMessage = 2;
    m.uMessage = message;
    m.lParam = (int64_t)(((uint32_t)(uint16_t)(int16_t)p.y << 16) | (uint16_t)(int16_t)p.x);
    DuVisual *target = hit(f.root, p);
    m.dwSubject = target.handle;
    m.ptPositionX = (int32_t)p.x;
    m.ptPositionY = (int32_t)p.y;
    m.bButton = button;
    m.nModifiers = button == 1 ? 0x10 : button == 2 ? 0x20 : 0;
    du_callback_post(&m, sizeof(m));
}

// ---- animations ---------------------------------------------------------------------------

static float ease(int interp, float weight, float t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    float w = weight > 0 ? weight : 1;
    switch (interp) {
        case 2: return t < 0.5f ? 0.5f * powf(2 * t, 1 + w) : 1 - 0.5f * powf(2 * (1 - t), 1 + w);   // S-curve
        case 3: return powf(t, 1 + w);                                                               // exponential
        case 4: return 1 - powf(1 - t, 1 + w);                                                       // logarithmic
    }
    return t;
}

static void read_property(DuAnimation *a, float v[4]) {
    DuVisual *vis = a.visual;
    v[0] = v[1] = v[2] = v[3] = 0;
    switch (a.type) {
        case 0: v[0] = vis.rect.origin.x; v[1] = vis.rect.origin.y; v[2] = vis.rect.size.width; v[3] = vis.rect.size.height; break;
        case 1: v[0] = vis.alpha; break;
        case 2: v[0] = vis.scale.width; v[1] = vis.scale.height; break;
    }
}

static void apply_at(DuAnimation *a, float t) {
    DuVisual *vis = a.visual;
    if (!vis || a.count == 0) return;
    DuKeyframe *f = a.frames.mutableBytes;
    int i = 0;
    while (i < a.count - 2 && t >= f[i + 1].time) i++;
    float v[4];
    if (a.count == 1 || t <= f[0].time) {
        memcpy(v, f[0].v, sizeof(v));
    } else {
        DuKeyframe *x = &f[i], *y = &f[i + 1];
        float span = y->time - x->time;
        float u = span > 0 ? ease(x->interp, x->weight, (t - x->time) / span) : 1;
        for (int k = 0; k < 4; k++) v[k] = x->v[k] + (y->v[k] - x->v[k]) * u;
    }
    switch (a.type) {
        case 0: {
            uint32_t flags = f[0].flags;
            CGRect r = vis.rect;
            if (flags & 1) r.origin = CGPointMake(v[0], v[1]);
            if (flags & 2) r.size = CGSizeMake(v[2], v[3]);
            vis.rect = r;
            break;
        }
        case 1: vis.alpha = (uint8_t)fmaxf(0, fminf(255, v[0])); break;
        case 2: vis.scale = CGSizeMake(v[0], v[1]); break;
    }
    BOOL resized = a.type == 0 && (f[0].flags & 2);
    place(vis);
    if (resized) draw_ops(vis);
}

static float duration(DuAnimation *a) {
    DuKeyframe *f = a.frames.mutableBytes;
    return a.count ? f[a.count - 1].time : 0;
}

static void finish(DuAnimation *a) {
    WLOG("anim", "%#x finished", a.handle);
    a.playing = NO;
    [s_playing removeObject:a];
    du_callback(a.handle, 1);
}

static void play(DuAnimation *a) {
    WLOG("anim", "%#x plays: type %d, loop %d, %d keyframes over %.2f s, visual %#x", a.handle, a.type, a.loop, a.count,
         a.count ? ((DuKeyframe *)a.frames.mutableBytes)[a.count - 1].time : 0, a.visual.handle);
    if (a.count == 0 || !a.visual) {
        du_callback(a.handle, 1);
        return;
    }
    DuKeyframe *f = a.frames.mutableBytes;
    // Keyframes in time order; relative ones from the property as it is now.
    for (int i = 1; i < a.count; i++) {
        DuKeyframe k = f[i];
        int j = i - 1;
        while (j >= 0 && f[j].time > k.time) { f[j + 1] = f[j]; j--; }
        f[j + 1] = k;
    }
    float now[4];
    read_property(a, now);
    for (int i = 0; i < a.count; i++) {
        if (a.type == 0) {
            // (a move keeps the size and a resize the place; relative: from where it is)
            if (f[i].relative) for (int k = 0; k < 4; k++) f[i].v[k] += now[k];
            if (!(f[i].flags & 1)) { f[i].v[0] = now[0]; f[i].v[1] = now[1]; }
            if (!(f[i].flags & 2)) { f[i].v[2] = now[2]; f[i].v[3] = now[3]; }
        } else if (f[i].relative) {
            for (int k = 0; k < 4; k++) f[i].v[k] += now[k];
        }
        f[i].relative = 0;
    }
    a.playing = YES;
    a.start = CACurrentMediaTime();
    [s_playing addObject:a];
    apply_at(a, 0);
}

// ---- steps and snapshots (tests) ---------------------------------------------------------

static void snapshot(NSString *path) {
    DuForm *f = s_form;
    int w = f.width > 0 ? f.width : 640, h = f.height > 0 ? f.height : 480;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)w, (size_t)h, 8, 0, space,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    // The tree is laid out from the top left: drawn inside a flipped layer
    // (pictures stay the right way up), at its own size in pixels.
    CALayer *host = f.host, *parent = host.superlayer;
    CGAffineTransform shown = host.affineTransform;
    CALayer *wrap = [CALayer layer];
    wrap.geometryFlipped = YES;
    wrap.anchorPoint = CGPointZero;
    wrap.bounds = CGRectMake(0, 0, w, h);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    host.affineTransform = CGAffineTransformIdentity;
    [wrap addSublayer:host];
    CGContextTranslateCTM(ctx, 0, h);   // (the bitmap's rows run bottom up)
    CGContextScaleCTM(ctx, 1, -1);
    [wrap renderInContext:ctx];
    [host removeFromSuperlayer];
    host.affineTransform = shown;
    if (parent) [parent addSublayer:host];
    [CATransaction commit];
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    if (dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    }
    CGImageRelease(image);
    WLOG("sp", "snapshot %dx%d -> %s", w, h, path.UTF8String);
}

static void quit_soon(void) {
    wmc_threadq_closing();
    form_simple(FORM_CLOSING, 0, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
}

static const struct { const char *name; int vk; } s_keys[] = {
    { "left", 0x25 }, { "up", 0x26 }, { "right", 0x27 }, { "down", 0x28 }, { "enter", 0x0D }, { "back", 0x08 },
    { "escape", 0x1B }, { "space", 0x20 }, { "tab", 0x09 }, { "pageup", 0x21 }, { "pagedown", 0x22 }, { NULL, 0 } };

// The visual tree, on the "tree" log channel (WMC_STEPS "dump"; with
// WMC_DUMP_DIR, each text's picture is saved there too).
static void dump_tree(DuVisual *v, int depth) {
    NSMutableString *ops = [NSMutableString string];
    for (DuOp *op in v.ops) {
        if (op.kind == DuOpText) [ops appendFormat:@" text\"%@\" src %@%@", op.text.text,
                                            op.hasSrc ? NSStringFromRect(op.src) : @"-", op.hasDst ? NSStringFromRect(op.dst) : @""];
        else if (op.kind == DuOpImage) [ops appendFormat:@" image%dx%d", op.image.width, op.image.height];
        else if (op.kind == DuOpFill) [ops appendFormat:@" fill%08x", op.color];
        else [ops appendFormat:@" video%d", op.surface];
    }
    for (CALayer *l in v.content.sublayers) {
        [ops appendFormat:@" [layer %@ %@%@]", NSStringFromRect(l.frame), NSStringFromRect(l.contentsRect), l.contents ? @"" : @" empty"];
        const char *dir = getenv("WMC_DUMP_DIR");
        if (dir && l.contents && v.ops.count == 1 && v.ops[0].kind == DuOpText) {
            NSString *path = [NSString stringWithFormat:@"%s/%x.png", dir, v.handle];
            CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
            if (d) { CGImageDestinationAddImage(d, (__bridge CGImageRef)l.contents, NULL); CGImageDestinationFinalize(d); CFRelease(d); }
        }
    }
    WLOG("tree", "%*s%#x (%.0f,%.0f %.0fx%.0f) style %#x alpha %d%s", depth * 2, "", v.handle, v.rect.origin.x,
         v.rect.origin.y, v.rect.size.width, v.rect.size.height, v.style, v.alpha, ops.UTF8String);
    for (DuVisual *c in v.children) dump_tree(c, depth + 1);
}

static NSMutableArray<NSString *> *s_steps;

static BOOL drawn(DuVisual *v) {
    if (!v || !(v.style & GS_VISIBLE)) return NO;
    if (v.ops.count) return YES;
    for (DuVisual *c in v.children)
        if (drawn(c)) return YES;
    return NO;
}

static void next_step(double after) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ run_steps(); });
}

// WMC_STEPS="ready [max] [quiet]; key down; wait 2; snap a.png; click x y; quit": run in order once
// Media Center's window is loaded. (WMC_INPUT's timed form "3 key down; ..." works too.)
static void run_steps(void) {
    if (!s_steps.count) return;
    NSString *step = s_steps.firstObject;
    [s_steps removeObjectAtIndex:0];
    NSArray<NSString *> *p = [step componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    p = [p filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (!p.count) { next_step(0); return; }
    NSString *kind = p[0];
    if (![kind isEqualToString:@"settling"]) WLOG("steps", "%s", step.UTF8String);
    if ([kind isEqualToString:@"ready"] || [kind isEqualToString:@"settle"] || [kind isEqualToString:@"settling"]) {
        // Something drawn and no animation running for `quiet` seconds, at
        // most `max` in all (as the Splash engine's: ready 60 s and 1 s by
        // default, settle 4 s and 0.3 s). "settling" is the same wait going on.
        static CFTimeInterval s_since, s_until;
        static double s_quiet;
        CFTimeInterval now = CACurrentMediaTime();
        if (![kind isEqualToString:@"settling"]) {
            BOOL ready = [kind isEqualToString:@"ready"];
            s_until = now + (p.count > 1 ? p[1].doubleValue : (ready ? 60 : 4));
            s_quiet = p.count > 2 ? p[2].doubleValue : (ready ? 1.0 : 0.3);
            s_since = 0;
        }
        BOOL settled = s_form.loaded && drawn(s_form.root) && !s_playing.count;
        if (!settled) s_since = 0;
        else if (!s_since) s_since = now;
        if ((settled && now - s_since >= s_quiet) || now >= s_until) {
            next_step(0);
            return;
        }
        [s_steps insertObject:@"settling" atIndex:0];
        next_step(0.05);
        return;
    }
    if ([kind isEqualToString:@"wait"] && p.count > 1) { next_step(p[1].doubleValue); return; }
    if ([kind isEqualToString:@"dump"]) dump_tree(s_form.root, 0);
    if ([kind isEqualToString:@"snap"] && p.count > 1) {
        // (the rest of the step is the path, spaces and all)
        NSString *rest = [step stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        snapshot([[rest substringFromIndex:4] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
    }
    else if ([kind isEqualToString:@"exit"]) exit(0);
    else if ([kind isEqualToString:@"quit"]) { quit_soon(); return; }
    else if ([kind isEqualToString:@"key"] && p.count > 1) {
        NSString *name = p[1].lowercaseString;
        for (int i = 0; s_keys[i].name; i++) {
            if ([name isEqualToString:@(s_keys[i].name)]) {
                key_event(s_keys[i].vk, 0, 0);
                key_event(s_keys[i].vk, 1, 0);
            }
        }
    } else if ([kind isEqualToString:@"char"] && p.count > 1) {
        unichar c = [p[1] characterAtIndex:0];
        key_event(toupper(c), 0, 0);
        key_event(c, 2, 0);
        key_event(toupper(c), 1, 0);
    } else if (([kind isEqualToString:@"click"] || [kind isEqualToString:@"move"]) && p.count > 2) {
        CGPoint at = CGPointMake(p[1].doubleValue, p[2].doubleValue);
        mouse_event(0x200, at, 0);
        if ([kind isEqualToString:@"click"]) {
            mouse_event(0x201, at, 1);
            mouse_event(0x202, at, 1);
        }
    }
    next_step(0.25);
}

static void start_tests(void) {
    static BOOL started;
    if (started) return;
    started = YES;
    const char *steps = getenv("WMC_STEPS");
    const char *input = getenv("WMC_INPUT");
    if (steps && *steps) {
        s_steps = [NSMutableArray array];
        for (NSString *s in [@(steps) componentsSeparatedByString:@";"]) [s_steps addObject:s];
        next_step(1.0);
    } else if (input && *input) {
        // "<seconds> <command>; ...": each at its time after the window loaded
        for (NSString *s in [@(input) componentsSeparatedByString:@";"]) {
            NSString *t = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSRange sp = [t rangeOfString:@" "];
            if (sp.location == NSNotFound) continue;
            double at = [t substringToIndex:sp.location].doubleValue;
            NSString *cmd = [t substringFromIndex:sp.location + 1];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                s_steps = [NSMutableArray arrayWithObject:cmd];
                run_steps();
            });
        }
    }
    const char *snap = getenv("WMC_SNAPSHOT");
    if (snap && *snap) {
        double after = getenv("WMC_SNAPSHOT_AFTER") ? atof(getenv("WMC_SNAPSHOT_AFTER")) : 3.0;
        NSString *path = @(snap);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            snapshot(path);
            if (getenv("WMC_SNAPSHOT_EXIT")) quit_soon();
        });
    }
    const char *series = getenv("WMC_SERIES");
    if (series && *series) {
        double every = getenv("WMC_SERIES_EVERY") ? atof(getenv("WMC_SERIES_EVERY")) : 1.0;
        int count = getenv("WMC_SERIES_COUNT") ? atoi(getenv("WMC_SERIES_COUNT")) : 10;
        NSString *folder = @(series);
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
        __block int index = 0;
        NSTimer *t = [NSTimer timerWithTimeInterval:every repeats:YES block:^(NSTimer *timer) {
            snapshot([folder stringByAppendingPathComponent:[NSString stringWithFormat:@"frame_%03d.png", index]]);
            if (++index >= count) {
                [timer invalidate];
                quit_soon();
            }
        }];
        [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    }
}

// ---- the clock --------------------------------------------------------------------------------

static void tick(void) {
    du_video_tick();
    if (!s_playing.count) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CFTimeInterval now = CACurrentMediaTime();
    for (DuAnimation *a in s_playing.allObjects) {
        if (!a.visual) { finish(a); continue; }
        float d = duration(a), t = (float)(now - a.start);
        if (t >= d) {
            int plays = a.loop < 0 ? INT_MAX : (a.loop > 0 ? a.loop : 1);
            int done = d > 0 ? (int)(t / d) : plays;
            if (done >= plays) {
                apply_at(a, d);
                finish(a);
                continue;
            }
            t = fmodf(t, d);
        }
        apply_at(a, t);
    }
    [CATransaction commit];
}

// ---- messages ------------------------------------------------------------------------------------

static void form_message(DuForm *f, int method, const struct Du_DUser_Msg *msg) {
    switch (method) {
        case DU_FW_CREATE_ROOT: {
            // (the form makes its root visual, by the handle it is given)
            const struct Du_RenderApi_FormWindow_CreateRoot_Msg *m = (const void *)msg;
            DuVisual *root = new_visual(m->hRoot.value);
            f.root = root;
            [f.host addSublayer:root.layer];
            root.rect = CGRectMake(0, 0, f.width, f.height);
            place(root);
            break;
        }
        case DU_FW_SET_SIZE: {
            // (the window's size, frame and all; when maximised, the size it
            // goes back to)
            const struct Du_RenderApi_FormWindow_SetSize_Msg *m = (const void *)msg;
            int inset = (f.style & 0x40000) ? 4 : (f.style & 0x800000) ? 1 : 0;
            f.restoredW = m->cx - 2 * inset;
            f.restoredH = m->cy - 2 * inset;
            if (f.mode == 2) break;
            if (f.window && !(f.window.styleMask & NSWindowStyleMaskFullScreen)) {
                CGFloat scale = backing_scale();
                [f.window setContentSize:NSMakeSize(f.restoredW / scale, f.restoredH / scale)];
            } else if (!f.window) {
                set_client(f, f.restoredW, f.restoredH);
            }
            break;
        }
        case DU_FW_SET_STYLES:
            f.style = ((const struct Du_RenderApi_FormWindow_SetStyles_Msg *)msg)->uRst;
            break;
        case DU_FW_SET_POSITION: {
            const struct Du_RenderApi_FormWindow_SetPosition_Msg *m = (const void *)msg;
            f.x = m->xLeft;
            f.y = m->yTop;
            form_state(4);
            break;
        }
        case DU_FW_SET_VISIBLE: {
            const struct Du_RenderApi_FormWindow_SetVisible_Msg *m = (const void *)msg;
            f.visible = m->fVisible != 0;
            if (f.visible) {
                BOOL made = !f.window;
                ensure_window(f);
                if (made && f.window) {
                    NSSize s = f.window.contentView.bounds.size;
                    set_client(f, (int)lround(s.width * backing_scale()), (int)lround(s.height * backing_scale()));
                }
                if (f.window) {
                    if (getenv("WMC_NO_ACTIVATE")) [f.window orderFrontRegardless];
                    else {
                        [f.window makeKeyAndOrderFront:nil];
                        [NSApp activateIgnoringOtherApps:YES];
                    }
                }
            } else {
                [f.window orderOut:nil];
            }
            form_state(2);
            apply_mode(f);
            if (f.visible && !f.loaded) {
                f.loaded = YES;
                form_simple(FORM_LOAD, (int64_t)(intptr_t)du_session_new(), 1);
                start_tests();
            }
            break;
        }
        case DU_FW_SET_MODE:
            f.mode = ((const struct Du_RenderApi_FormWindow_SetMode_Msg *)msg)->uMode;
            if (s_headless && f.mode == 2) {
                // (offscreen: a screen of Media Center's own design size, or WMC_HEADLESS_SIZE=WxH)
                int w = 1024, h = 768;
                const char *size = getenv("WMC_HEADLESS_SIZE");
                if (size) sscanf(size, "%dx%d", &w, &h);
                set_client(f, w, h);
            }
            form_state(1);
            apply_mode(f);
            break;
        case DU_FW_SET_TEXT:
            f.title = du_blob_string(msg, ((const struct Du_RenderApi_FormWindow_SetText_Msg *)msg)->text.value);
            f.window.title = f.title;
            break;
        case DU_FW_SET_BACKGROUND: {
            uint32_t c = ((const struct Du_RenderApi_FormWindow_SetBackgroundARGB_Msg *)msg)->dwARGB;
            CGColorRef color = CGColorCreateSRGB(((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0, 1);
            f.host.backgroundColor = color;
            CGColorRelease(color);
            break;
        }
        case DU_FW_CLOSE:
            [f.window orderOut:nil];
            form_simple(FORM_DESTROYED, 0, 0);
            break;
        case DU_FW_TAKE_FOCUS:
        case DU_FW_SET_FOREGROUND:
            if (f.window && !getenv("WMC_NO_ACTIVATE")) [f.window makeKeyAndOrderFront:nil];
            break;
        case DU_FW_SET_PRE_ROS: {
            NSArray<DuOp *> *ops = ops_in(msg, ((const struct Du_RenderApi_FormWindow_SetPreBeginSceneROs_Msg *)msg)->ops.value);
            if (!f.pre) {
                f.pre = new_layer();
                [f.host insertSublayer:f.pre atIndex:0];
            }
            f.pre.frame = CGRectMake(0, 0, f.width, f.height);
            draw_list(f.pre, ops, f.pre.bounds);
            break;
        }
        case DU_FW_SET_OPTIONS: case DU_FW_SET_MOUSE_IDLE: case DU_FW_SET_CURSORS:
        case DU_FW_SET_ICON: case DU_FW_RESTORE: case DU_FW_FORCE_MOUSE_IDLE: case DU_FW_UPDATE: case DU_FW_SHOW_HELP:
        case DU_FW_SET_SYS_COMMAND: case DU_FW_SET_CAPTURE:
            break;
        default:
            WLOG("todo", "FormWindow method %d is not handled", method);
    }
}

static void animation_message(DuAnimation *a, int method, const struct Du_DUser_Msg *msg) {
    if (method == DU_AH_PLAY) { play(a); return; }
    if (method == DU_AH_STOP) { if (a.playing) finish(a); return; }
    DuKeyframe k = {0};
    switch (method) {
        case DU_AH_ADD_RECT: {
            const struct Du_RenderApi_AnimationHelper_AddRectKeyframe_Msg *m = (const void *)msg;
            k = (DuKeyframe){ m->time, m->interpolationType, m->scale, m->relative, m->uFlags, { m->x, m->y, m->cx, m->cy } };
            break;
        }
        case DU_AH_ADD_ALPHA: {
            const struct Du_RenderApi_AnimationHelper_AddAlphaKeyframe_Msg *m = (const void *)msg;
            k = (DuKeyframe){ m->time, m->interpolationType, m->scale, 0, 0, { m->alpha } };
            break;
        }
        case DU_AH_ADD_SCALE: {
            const struct Du_RenderApi_AnimationHelper_AddScaleKeyframe_Msg *m = (const void *)msg;
            k = (DuKeyframe){ m->time, m->interpolationType, m->scale, 0, 0, { m->cx, m->cy } };
            break;
        }
        case DU_AH_ADD_LIGHT: {
            const struct Du_RenderApi_AnimationHelper_AddLightKeyframe_Msg *m = (const void *)msg;
            k = (DuKeyframe){ m->time, m->interpolationType, m->scale, 0, 0, { 0 } };   // (lights are not drawn)
            break;
        }
        default:
            WLOG("todo", "AnimationHelper method %d is not handled", method);
            return;
    }
    // (rect keyframes for a move and for a resize come as separate animations)
    [a.frames appendBytes:&k length:sizeof(k)];
    a.count++;
}

static void dispatch_one(const struct Du_DUser_Msg *msg);

static void delete_object(uint32_t handle) {
    DuObject *o = object_for(handle);
    if (!o) return;
    if ([o isKindOfClass:DuVisual.class]) {
        DuVisual *v = (DuVisual *)o;
        [v.parent.children removeObject:v];
        [v.layer removeFromSuperlayer];
    } else if ([o isKindOfClass:DuAnimation.class]) {
        [s_playing removeObject:(DuAnimation *)o];
    }
    [s_objects removeObjectForKey:@(handle)];
    struct Du_RenderApiBase_ObjectDeletedMsg m = {0};
    m.ownerCookie = s_root_cookie;
    m.ownerMessage = RA_OBJECT_DELETED;
    m.deletedHandle.value = handle;
    du_callback_post(&m, sizeof(m));
}

static void agent_message(int method, const struct Du_DUser_Msg *msg) {
    switch (method) {
        case DU_RA_FORWARD: {
            const struct Du_RenderApiBase_ProxyTrailer *trailer = (const void *)((const uint8_t *)msg + msg->cbSize - sizeof(*trailer));
            id target = object_for(trailer->_innerTarget);
            int inner = trailer->_innerMsg;
            if ([target isKindOfClass:DuForm.class]) form_message(target, inner, msg);
            else if ([target isKindOfClass:DuAnimation.class]) animation_message(target, inner, msg);
            else WLOG("err", "message %d for unknown object %#x", inner, trailer->_innerTarget);
            break;
        }
        case DU_RA_BATCH: {
            const struct Du_RenderApi_RenderAgent_MessageBatchForwarderProxy_Msg *m = (const void *)msg;
            const struct Du_RenderApiBase_BatchHeader *header = (const void *)(intptr_t)m->pBatchInfo;
            int guard = 0;
            for (const struct Du_RenderApiBase_BatchMessage *b = (const void *)(intptr_t)header->pFirstMessage;
                 b && guard++ < 1000000; b = (const void *)(intptr_t)b->pNextMessage)
                dispatch_one((const void *)(intptr_t)b->pMethodMessage);
            struct Du_RenderApiBase_BatchCompletedMsg done = {0};
            done.ownerCookie = s_root_cookie;
            done.ownerMessage = RA_BATCH_COMPLETED;
            done.pBatchInfo = m->pBatchInfo;
            done.fSuccess = 1;
            du_callback_post(&done, sizeof(done));
            break;
        }
        case DU_RA_CREATE_GROUP:
            break;
        case DU_RA_DELETE_GROUP:
            break;   // (each object in it is deleted by name as well)
        case DU_RA_DELETE_OBJECT:
            delete_object(((const struct Du_RenderApi_RenderAgent_DeleteObject_Msg *)msg)->hObject.value);
            break;
        case DU_RA_SHUTDOWN:
            break;
        case DU_RA_SHELL_EXEC:
            WLOG("todo", "ShellExec is not written");
            break;
        case DU_RA_CREATE_FORM: {
            const struct Du_RenderApi_RenderAgent_CreateFormWindow_Msg *m = (const void *)msg;
            DuForm *f = [DuForm new];
            f.handle = m->hForm.value;
            f.host = new_layer();
            CGColorRef black = CGColorCreateSRGB(0, 0, 0, 1);
            f.host.backgroundColor = black;
            CGColorRelease(black);
            f.hwnd = wmc_window_adopt("eHome Render Window", NULL, wmc_threadq_current());
            s_objects[@(f.handle)] = f;
            s_form = f;
            form_simple(FORM_CREATED, (int64_t)(intptr_t)f.hwnd, 0);
            break;
        }
        case DU_RA_CREATE_VISUAL: {
            const struct Du_RenderApi_RenderAgent_CreateVisual_Msg *m = (const void *)msg;
            DuVisual *v = new_visual(m->hVisual.value);
            reparent(v, visual_for(m->hParent.value), nil, GORDER_TOP);
            place(v);
            break;
        }
        case DU_RA_CREATE_ANIMATION: {
            const struct Du_RenderApi_RenderAgent_CreateAnimation_Msg *m = (const void *)msg;
            DuAnimation *a = [DuAnimation new];
            a.handle = m->hAnimation.value;
            a.type = m->type;
            a.loop = m->loop;
            a.visual = visual_for(m->hVisual.value);
            a.frames = [NSMutableData data];
            s_objects[@(a.handle)] = a;
            break;
        }
        case DU_RA_SET_STYLE: {
            const struct Du_RenderApi_RenderAgent_SetVisualStyle_Msg *m = (const void *)msg;
            DuVisual *v = visual_for(m->hVisual.value);
            v.style = (v.style & ~m->nMask) | (m->nNewStyle & m->nMask);
            place(v);
            break;
        }
        case DU_RA_SET_PARENT: {
            const struct Du_RenderApi_RenderAgent_SetVisualParent_Msg *m = (const void *)msg;
            DuVisual *v = visual_for(m->hVisual.value);
            if (v) reparent(v, visual_for(m->hNewParent.value), visual_for(m->hOther.value), m->nFlags);
            break;
        }
        case DU_RA_SET_RECT: {
            const struct Du_RenderApi_RenderAgent_SetVisualRect_Msg *m = (const void *)msg;
            DuVisual *v = visual_for(m->hVisual.value);
            if (!v) break;
            CGRect r = v.rect;
            // (SGR_MOVE 1, SGR_SIZE 2; neither: both)
            uint32_t what = m->nFlags & 3 ? m->nFlags & 3 : 3;
            if (what & 1) r.origin = CGPointMake(m->x, m->y);
            if (what & 2) r.size = CGSizeMake(m->w, m->h);
            BOOL resized = !CGSizeEqualToSize(r.size, v.rect.size);
            v.rect = r;
            place(v);
            if (resized) draw_ops(v);
            break;
        }
        case DU_RA_SET_DESCRIPTION:
            break;
        case DU_RA_SET_ALPHA: {
            const struct Du_RenderApi_RenderAgent_SetVisualAlpha_Msg *m = (const void *)msg;
            DuVisual *v = visual_for(m->hVisual.value);
            v.alpha = (uint8_t)MIN(m->alpha, 255u);
            place(v);
            break;
        }
        case DU_RA_SET_SCALE: {
            const struct Du_RenderApi_RenderAgent_SetVisualScale_Msg *m = (const void *)msg;
            DuVisual *v = visual_for(m->hVisual.value);
            v.scale = CGSizeMake(m->sizefScale.width, m->sizefScale.height);
            place(v);
            break;
        }
        case DU_RA_SET_CENTER: {
            const struct Du_RenderApi_RenderAgent_SetVisualCenter_Msg *m = (const void *)msg;
            DuVisual *v = visual_for(m->hVisual.value);
            v.center = CGPointMake(m->pointfCenter.x, m->pointfCenter.y);
            place(v);
            break;
        }
        case DU_RA_SET_LIGHT:
        case DU_RA_REMOVE_LIGHT:
            break;   // (Direct3D lights: not drawn)
        case DU_RA_SET_OPS: {
            const struct Du_RenderApi_RenderAgent_SetRenderHolderParams_Msg *m = (const void *)msg;
            DuVisual *v = visual_for(m->hVisual.value);
            if (!v) break;
            v.ops = ops_in(msg, m->ops.value);
            draw_ops(v);
            break;
        }
        default:
            WLOG("todo", "RenderAgent method %d is not handled", method);
    }
}

static void dispatch_one(const struct Du_DUser_Msg *msg) {
    if (!msg) return;
    int method = msg->nMsg;
    if (wmc_log_enabled("du")) {
        const uint32_t *w = (const uint32_t *)msg;
        uint32_t words = msg->cbSize / 4;
        char line[256];
        int n = snprintf(line, sizeof line, "message %d (%u bytes):", method, msg->cbSize);
        for (uint32_t i = 2; i < words && i < 14 && n < (int)sizeof line - 12; i++) n += snprintf(line + n, sizeof line - n, " %x", w[i]);
        if (method == DU_RA_FORWARD && msg->cbSize >= 16) {
            const struct Du_RenderApiBase_ProxyTrailer *tr = (const void *)((const uint8_t *)msg + msg->cbSize - 8);
            snprintf(line + n, sizeof line - n, " -> %#x method %d", tr->_innerTarget, tr->_innerMsg);
        }
        WLOG("du", "%s", line);
    }
    if (method >= DU_RA_FORWARD && method <= DU_RA_SET_OPS) agent_message(method, msg);
    else WLOG("todo", "message %d is not handled", method);
}

void du_agent_dispatch(const struct Du_DUser_Msg *msg) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    dispatch_one(msg);
    [CATransaction commit];
}

#endif
