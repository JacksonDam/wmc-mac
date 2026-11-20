// XP Media Center Edition 2002's video: what its player draws on. A player
// (WmcStandins/Xp2002Video.cs) owns a "surface", a small number it hands
// the framework both as the "surface owner" an inset video's picture is
// made from and as the "front buffer" the full-screen picture is drawn from
// (it comes back as a 32-bit number, so it cannot be a pointer). Render
// operations on it are layers; each frame the player's video
// (native/platform/video.m) has becomes their contents.
#import <AppKit/AppKit.h>
#import "duser.h"
#import "platform/video.h"

#ifdef WMC_XP2002

@interface DuSurface : NSObject
@property (nonatomic) int width, height;              // of the frames (0: none yet)
@property (nonatomic) CGImageRef frame;               // the newest (retained)
@property (nonatomic, strong) NSHashTable<CALayer *> *layers;   // what shows it (weak)
@end
@implementation DuSurface
- (void)dealloc {
    if (_frame) CGImageRelease(_frame);
}
@end

static NSMutableDictionary<NSNumber *, DuSurface *> *s_surfaces;   // (main thread)
static int s_next_surface = 1;

static void main_sync(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

WMC_API int du_video_surface_new(void) {
    __block int number = 0;
    main_sync(^{
        if (!s_surfaces) s_surfaces = [NSMutableDictionary dictionary];
        number = s_next_surface++;
        DuSurface *s = [DuSurface new];
        s.layers = [NSHashTable weakObjectsHashTable];
        s_surfaces[@(number)] = s;
    });
    WLOG("video", "surface %d", number);
    return number;
}

WMC_API void du_video_surface_free(int number) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DuSurface *s = s_surfaces[@(number)];
        for (CALayer *l in s.layers) l.contents = nil;
        [s_surfaces removeObjectForKey:@(number)];
    });
}

bool du_is_surface(const void *p) { return (uintptr_t)p > 0 && (uintptr_t)p < 0x10000; }

WMC_API HRESULT EhGenericSurfaceGetSize(void *owner, int32_t size[2]) {
    __block int w = 0, h = 0;
    main_sync(^{
        DuSurface *s = s_surfaces[@((int)(intptr_t)owner)];
        w = s.width;
        h = s.height;
    });
    size[0] = w;
    size[1] = h;
    return w > 0 ? S_OK : E_FAIL;
}

// The picture's part a layer shows (its operation's source rectangle, in
// the frame's pixels; empty: all of it).
static void show(CALayer *layer, DuSurface *s) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.contents = (__bridge id)s.frame;
    NSValue *src = [layer valueForKey:@"duSource"];
    CGRect r = src ? src.rectValue : CGRectZero;
    if (s.width > 0 && s.height > 0 && r.size.width > 0 && r.size.height > 0)
        layer.contentsRect = CGRectMake(r.origin.x / s.width, r.origin.y / s.height, r.size.width / s.width, r.size.height / s.height);
    else
        layer.contentsRect = CGRectMake(0, 0, 1, 1);
    [CATransaction commit];
}

// A layer for a render operation on a surface (duser_agent.m's drawing).
void du_video_attach(CALayer *layer, int number, CGRect source, bool hasSource) {
    DuSurface *s = s_surfaces[@(number)];
    if (!s) return;
    if (hasSource) [layer setValue:[NSValue valueWithRect:source] forKey:@"duSource"];
    [s.layers addObject:layer];
    if (s.frame) show(layer, s);
}

static int sink_target(int number) {
    DuSurface *s = s_surfaces[@(number)];
    if (!s) return 0;
    return s.frame ? 1 : 2;
}

static void sink_put(int number, const void *bgra, size_t stride, int width, int height, int shownW, int shownH, bool first) {
    DuSurface *s = s_surfaces[@(number)];
    if (!s) return;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CFDataRef data = CFDataCreate(NULL, bgra, (CFIndex)(stride * (size_t)height));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, stride, space,
                                     (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, provider, NULL,
                                     false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CFRelease(data);
    CGColorSpaceRelease(space);
    if (!image) return;
    if (s.frame) CGImageRelease(s.frame);
    s.frame = image;
    s.width = width;
    s.height = height;
    for (CALayer *l in s.layers) show(l, s);
}

void du_video_tick(void) {
    static const WmcVideoSink sink = { sink_target, sink_put };
    wmc_video_tick(&sink);
}

#endif
