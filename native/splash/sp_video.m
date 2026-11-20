// Video: the engine's "video pools", and the players that fill them.
//
// The framework draws video like any other picture: a pool (a texture), a
// surface on it, draw calls in display lists. What is special is where the
// pixels come from. For each "dynamic image" the framework creates a video
// pool and registers it under a small number (DynamicSurfaceFactory); the
// player (native/platform/video.m) is told that number as its "surface id",
// and on every tick each playing one hands its newest frame to its pool.
//
// XP Media Center Edition 2005 has no video pools: its dynamic image is a
// pair of ordinary surfaces, each the whole of a pool of its own, which it
// draws itself (one before the scene, for full-screen video, one in it).
// SpDynamicSurfaceCreate pairs them for a player and names the pair.
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import "sp_scene.h"
#import "platform/video.h"
#include "splash_protocol.h"

#ifndef WMC_XP

static NSMutableDictionary<NSNumber *, SpVideoPool *> *s_pools;      // by unique id

// ------------------------------------------------------------------ the pool

@implementation SpVideoPool

- (void)spMessage:(const SpMessage *)msg {
    switch (msg->nMsg) {
        case SpMsg_VideoPool_NotifyVideoInputChanged:
        case SpMsg_VideoPool_SetContentOverscan:
        case SpMsg_VideoPool_NotifyVideoSizeChanged:
        case SpMsg_VideoPool_OnClockStop:
        case SpMsg_VideoPool_OnClockStart:
        case SpMsg_VideoPool_OnDisconnect:
        case SpMsg_VideoPool_OnConnect:
            break;   // (what the Windows presenter is told; the frames here need none of it)
        default:
            [super spMessage:msg];   // the messages a video pool shares with every pool
    }
}

- (void)spDestroy {
    if (_uniqueId) [s_pools removeObjectForKey:@(_uniqueId)];
    [super spDestroy];
}

// Tells the framework what is arriving: its size in pixels and its shape.
- (void)announceWidth:(int)width height:(int)height {
    [self announceWidth:width height:height aspectWidth:width aspectHeight:height];
}

// The same for pixels that are not square (DV, many DivX files): the shape
// the picture is shown at.
- (void)announceWidth:(int)width height:(int)height aspectWidth:(int)aspectWidth aspectHeight:(int)aspectHeight {
    if (!_ownerObject) return;
    struct Sp_LocalVideoPoolCallback_OnInputChanged cb = {0};
    cb.size = sizeof(cb);
    cb.msgid = SpMsg_VideoPoolCallback_OnInputChanged;
    cb.idObjectSubject.value = _ownerObject;
    cb.target.value = self.handle;
    cb.sizeTargetPxl.m_width = width;
    cb.sizeTargetPxl.m_height = height;
    cb.sizeAspectRatioPxl.m_width = aspectWidth;
    cb.sizeAspectRatioPxl.m_height = aspectHeight;
    cb.nFrameRateNumerator = 30;
    cb.nFrameRateDenominator = 1;
    cb.nFormat = 2099336u;   // RGB32
    [self.context sendCallback:&cb toContext:_ownerContext];
}

@end

@interface SpDynamicSurfaceFactory : SpObject
@end

@implementation SpDynamicSurfaceFactory

+ (void)spStaticMessage:(const SpMessage *)msg context:(SpRenderContext *)context {
    if (!s_pools) s_pools = [NSMutableDictionary dictionary];
    switch (msg->nMsg) {
        case SpMsg_DynamicSurfaceFactory_CreateVideoInstance:
        case SpMsg_DynamicSurfaceFactory_CreateSurfaceInstance: {
            const struct Sp_RemoteDynamicSurfaceFactory_CreateVideoInstance *m = (const void *)msg;
            SpVideoPool *pool = [context objectForHandle:m->poolScene.value];
            if ([pool isKindOfClass:SpVideoPool.class]) {
                pool.uniqueId = m->nUniqueID;
                s_pools[@(m->nUniqueID)] = pool;
                WLOG("video", "dynamic image %d is pool %#x", m->nUniqueID, pool.handle);
            }
            break;
        }
        case SpMsg_DynamicSurfaceFactory_CloseInstance: {
            const struct Sp_RemoteDynamicSurfaceFactory_CloseInstance *m = (const void *)msg;
            [s_pools removeObjectForKey:@(m->nUniqueID)];
            break;
        }
        default:
            [super spStaticMessage:msg context:context];
    }
}

@end

__attribute__((constructor)) static void register_video_classes(void) {
    sp_register_class(@"Splash::Rendering::VideoPool", [SpVideoPool class]);
    sp_register_class(@"Splash::Rendering::DynamicSurfaceFactory", [SpDynamicSurfaceFactory class]);
}

// Where a player's frames go, and telling the framework their size.
static NSArray<SpSurfacePool *> *target_pools(int surfaceId) {
    SpVideoPool *pool = s_pools[@(surfaceId)];
    return pool ? @[ pool ] : @[];
}

static void announce(int surfaceId, int width, int height, int aspectWidth, int aspectHeight) {
    [s_pools[@(surfaceId)] announceWidth:width height:height aspectWidth:aspectWidth aspectHeight:aspectHeight];
}

#else

// ------------------------------------------------------- XP's dynamic surfaces

SpRenderContext *sp_render_context(uint32_t idContext);   // sp_core.m

@interface SpXpDynamicSurface : NSObject
@property (nonatomic) uint32_t context, preScenePool, inScenePool;
@property (nonatomic) int width, height;        // what is arriving (0: nothing yet)
@end
@implementation SpXpDynamicSurface
@end

static NSMutableDictionary<NSNumber *, SpXpDynamicSurface *> *s_dynamic;   // by number (main thread)
static int s_next_dynamic = 1;

// The number is handed to the player as a 32-bit "surface" (VideoViewport
// casts the pointer), so it is small, not a pointer.
WMC_API HRESULT SpDynamicSurfaceCreate(uint32_t idContextRender, int deviceType, uint32_t idClassContext, uint32_t idDevice,
                                       uint32_t preScene, uint32_t preScenePool, uint32_t inScene, uint32_t inScenePool,
                                       void **dynamicSurface) {
    __block int number;
    sp_main_sync(^{
        if (!s_dynamic) s_dynamic = [NSMutableDictionary dictionary];
        number = s_next_dynamic++;
        SpXpDynamicSurface *d = [SpXpDynamicSurface new];
        d.context = idContextRender;
        d.preScenePool = preScenePool;
        d.inScenePool = inScenePool;
        s_dynamic[@(number)] = d;
    });
    *dynamicSurface = (void *)(intptr_t)number;
    WLOG("video", "dynamic image %d: pools %#x (before the scene) and %#x (in it)", number, preScenePool, inScenePool);
    return S_OK;
}

// The rectangle of the surfaces that holds the picture.
WMC_API HRESULT SpDynamicSurfaceGetContentArea(void *dynamicSurface, int category, int32_t rect[4]) {
    __block int w = 0, h = 0;
    sp_main_sync(^{
        SpXpDynamicSurface *d = s_dynamic[@((int)(intptr_t)dynamicSurface)];
        w = d.width;
        h = d.height;
    });
    rect[0] = rect[1] = 0;
    rect[2] = w;
    rect[3] = h;
    return S_OK;
}

WMC_API HRESULT SpDynamicSurfaceSetRetainSurfaces(void *dynamicSurface, WINBOOL retained) { return S_OK; }

void sp_video_release(void *dynamicSurface) {
    intptr_t number = (intptr_t)dynamicSurface;
    if (number <= 0 || number >= 0x10000) return;   // (not one of these)
    dispatch_async(dispatch_get_main_queue(), ^{ [s_dynamic removeObjectForKey:@((int)number)]; });
}

static NSArray<SpSurfacePool *> *target_pools(int surfaceId) {
    SpXpDynamicSurface *d = s_dynamic[@(surfaceId)];
    SpRenderContext *rc = d ? sp_render_context(d.context) : nil;
    if (!rc) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSNumber *h in @[ @(d.inScenePool), @(d.preScenePool) ]) {
        SpSurfacePool *p = [rc objectForHandle:h.unsignedIntValue];
        if ([p isKindOfClass:SpSurfacePool.class]) [out addObject:p];
    }
    return out;
}

static void announce(int surfaceId, int width, int height, int aspectWidth, int aspectHeight) {
    SpXpDynamicSurface *d = s_dynamic[@(surfaceId)];
    d.width = width;
    d.height = height;
}

#endif

// Copies a frame into the pools it is shown from.
static void put_frame(NSArray<SpSurfacePool *> *pools, const void *bgra, size_t stride, int width, int height) {
    for (SpSurfacePool *pool in pools) {
        if (!pool.texture || pool.width != width || pool.height != height) [pool allocateWidth:width height:height format:2099336u];
        [pool.texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
                        mipmapLevel:0
                          withBytes:bgra
                        bytesPerRow:(NSUInteger)stride];
    }
}

// Where a frame goes: the surface's pools.
static int splash_target(int surfaceId) {
    NSArray<SpSurfacePool *> *pools = target_pools(surfaceId);
    if (!pools.count) return 0;
    return pools[0].texture ? 1 : 2;
}

static void splash_put(int surfaceId, const void *bgra, size_t stride, int width, int height, int shownWidth, int shownHeight,
                       bool first) {
    NSArray<SpSurfacePool *> *pools = target_pools(surfaceId);
    if (!pools.count) return;
    put_frame(pools, bgra, stride, width, height);
    if (first) {
        announce(surfaceId, width, height, shownWidth, shownHeight);
        WLOG("video", "first frame into pool %#x", pools[0].handle);
    }
    sp_scene_invalidate();
}

// Moves every video's newest frame into its pool. On the main thread,
// before frames are drawn.
void sp_video_tick(void) {
    static const WmcVideoSink sink = { splash_target, splash_put };
    wmc_video_tick(&sink);
}
