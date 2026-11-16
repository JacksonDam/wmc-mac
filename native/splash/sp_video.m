// Video: the engine's "video pools", and the players that fill them.
//
// The framework draws video like any other picture: a pool (a texture), a
// surface on it, draw calls in display lists. What is special is where the
// pixels come from. For each "dynamic image" the framework creates a video
// pool and registers it under a small number (DynamicSurfaceFactory); the
// player is told that number as its "surface id" and presents its frames
// there. Here a player is an AVPlayer (opened by the managed stand-in in
// WmcStandins/Playback), or for Windows Media and AVI files (which
// AVFoundation cannot open) FFmpeg's (native/platform/ffmedia.m); on every tick each
// playing one hands its newest frame to its pool.
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import "sp_scene.h"
#include "platform/ffmedia.h"
#include "splash_protocol.h"

static NSMutableDictionary<NSNumber *, SpVideoPool *> *s_pools;      // by unique id
static NSMutableArray *s_videos;                                       // WmcVideo, open ones

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

// ---------------------------------------------------------------- the players

@interface WmcVideo : NSObject
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *item;
@property (nonatomic, strong) AVPlayerItemVideoOutput *output;
@property (nonatomic, strong) id endObserver;
@property (nonatomic) void *ff;                     // FFmpeg's player, for Windows Media files
@property (nonatomic) int surfaceId;
@property (nonatomic) BOOL ended, announced;
@property (nonatomic) float volume, rate;
@property (nonatomic) BOOL muted;
@end

@implementation WmcVideo
@end

static void on_main(void (^block)(void)) {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}

static void apply_volume(WmcVideo *v) {
    v.player.volume = getenv("WMC_MUTE") ? 0 : v.volume;
    v.player.muted = v.muted;
}

// Opens a file for playing. Returns a handle; whether it can be played is
// known a moment later (wmc_video_state).
WMC_API void *wmc_video_open(const char *path) {
    if (!path) return NULL;
    __block WmcVideo *v = nil;
    NSString *file = @(path);
    if (wmc_ff_handles(path)) {
        on_main(^{
            v = [WmcVideo new];
            v.volume = 1;
            v.rate = 1;
            v.ff = wmc_ff_open(path, true);
            if (!s_videos) s_videos = [NSMutableArray array];
            [s_videos addObject:v];
        });
        return (__bridge_retained void *)v;
    }
    on_main(^{
        v = [WmcVideo new];
        v.volume = 1;
        v.rate = 1;
        v.item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:file]];
        v.output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferMetalCompatibilityKey : @YES,
        }];
        [v.item addOutput:v.output];
        v.player = [AVPlayer playerWithPlayerItem:v.item];
        v.player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        apply_volume(v);
        __weak WmcVideo *weak = v;
        v.endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                         object:v.item
                                                                          queue:NSOperationQueue.mainQueue
                                                                     usingBlock:^(NSNotification *n) { weak.ended = YES; }];
        if (!s_videos) s_videos = [NSMutableArray array];
        [s_videos addObject:v];
        WLOG("video", "opened %s", file.UTF8String);
    });
    return (__bridge_retained void *)v;
}

WMC_API void wmc_video_close(void *handle) {
    if (!handle) return;
    WmcVideo *v = (__bridge_transfer WmcVideo *)handle;
    on_main(^{
        if (v.ff) {
            wmc_ff_close(v.ff);
            v.ff = NULL;
        }
        [v.player pause];
        [NSNotificationCenter.defaultCenter removeObserver:v.endObserver];
        [v.item removeOutput:v.output];
        [s_videos removeObject:v];
    });
}

// 0 still opening, 1 ready and not playing, 2 playing, 3 played to the end,
// 4 cannot be played.
WMC_API int wmc_video_state(void *handle) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (!v) return 4;
    if (!v.item) return v.ff ? wmc_ff_state(v.ff) : 4;
    if (v.item.status == AVPlayerItemStatusFailed) return 4;
    if (v.item.status != AVPlayerItemStatusReadyToPlay) return 0;
    if (v.ended) return 3;
    return v.player.rate != 0 ? 2 : 1;
}

WMC_API void wmc_video_size(void *handle, int *width, int *height) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (v.ff) return wmc_ff_size(v.ff, width, height);
    CGSize size = v ? v.item.presentationSize : CGSizeZero;
    if (width) *width = (int)size.width;
    if (height) *height = (int)size.height;
}

WMC_API int wmc_video_has_sound(void *handle) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (v.ff) return wmc_ff_has_audio(v.ff);
    for (AVPlayerItemTrack *track in v.item.tracks)
        if ([track.assetTrack.mediaType isEqualToString:AVMediaTypeAudio]) return 1;
    return 0;
}

WMC_API double wmc_video_duration(void *handle) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (v.ff) return wmc_ff_duration(v.ff);
    CMTime d = v ? v.item.duration : kCMTimeInvalid;
    return CMTIME_IS_NUMERIC(d) ? CMTimeGetSeconds(d) : 0;
}

WMC_API double wmc_video_position(void *handle) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (v.ff) return wmc_ff_position(v.ff);
    CMTime t = v ? v.player.currentTime : kCMTimeInvalid;
    return CMTIME_IS_NUMERIC(t) ? CMTimeGetSeconds(t) : 0;
}

WMC_API void wmc_video_seek(void *handle, double seconds) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (!v) return;
    if (v.ff) return wmc_ff_seek(v.ff, seconds);
    on_main(^{
        v.ended = NO;
        [v.player seekToTime:CMTimeMakeWithSeconds(seconds < 0 ? 0 : seconds, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    });
}

WMC_API void wmc_video_play(void *handle) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (!v) return;
    if (v.ff) return wmc_ff_play(v.ff);
    on_main(^{
        if (v.ended) {
            [v.player seekToTime:kCMTimeZero];
            v.ended = NO;
        }
        v.player.rate = v.rate;
    });
}

WMC_API void wmc_video_pause(void *handle) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (v.ff) return wmc_ff_pause(v.ff);
    if (v) on_main(^{ [v.player pause]; });
}

// The speed to play at (1 is normal). Takes effect at once if playing.
WMC_API void wmc_video_set_rate(void *handle, float rate) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (!v || rate <= 0) return;
    if (v.ff) return wmc_ff_set_rate(v.ff, rate);
    on_main(^{
        v.rate = rate;
        if (v.player.rate != 0) v.player.rate = rate;
    });
}

WMC_API void wmc_video_set_volume(void *handle, float volume, int muted) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (!v) return;
    if (v.ff) return wmc_ff_set_volume(v.ff, volume, muted);
    on_main(^{
        v.volume = volume;
        v.muted = muted != 0;
        apply_volume(v);
    });
}

// Which dynamic image the frames go to (0: nowhere).
WMC_API void wmc_video_set_surface(void *handle, int surfaceId) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (!v) return;
    on_main(^{
        v.surfaceId = surfaceId;
        v.announced = NO;
        WLOG("video", "player presents to dynamic image %d", surfaceId);
    });
}

// FFmpeg's player: its picture due now, if it is a new one.
static void present_ff(WmcVideo *v) {
    if (!v.surfaceId) return;
    SpVideoPool *pool = s_pools[@(v.surfaceId)];
    if (!pool) return;
    const uint8_t *bgra;
    int stride, width, height, shownW, shownH;
    if (!wmc_ff_take_frame(v.ff, &bgra, &stride, &width, &height)) return;
    wmc_ff_display_size(v.ff, &shownW, &shownH);
    if (!pool.texture || pool.width != width || pool.height != height) [pool allocateWidth:width height:height format:2099336u];
    [pool.texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
                    mipmapLevel:0
                      withBytes:bgra
                    bytesPerRow:(NSUInteger)stride];
    if (!v.announced) {
        v.announced = YES;
        [pool announceWidth:width height:height aspectWidth:shownW aspectHeight:shownH];
        WLOG("video", "first frame %dx%d (FFmpeg, shown as %dx%d) into pool %#x", width, height, shownW, shownH, pool.handle);
    }
    sp_scene_invalidate();
}

// Moves every video's newest frame into its pool. On the main thread,
// before frames are drawn.
void sp_video_tick(void) {
    if (!s_videos.count) return;
    CFTimeInterval host = CACurrentMediaTime();
    for (WmcVideo *v in s_videos) {
        if (v.ff) {
            present_ff(v);
            continue;
        }
        if (!v.surfaceId || v.item.status != AVPlayerItemStatusReadyToPlay) continue;
        SpVideoPool *pool = s_pools[@(v.surfaceId)];
        if (!pool) continue;
        CMTime at = [v.output itemTimeForHostTime:host];
        if (![v.output hasNewPixelBufferForItemTime:at] && pool.texture && v.announced) continue;
        CVPixelBufferRef frame = [v.output copyPixelBufferForItemTime:at itemTimeForDisplay:NULL];
        if (!frame) continue;
        int width = (int)CVPixelBufferGetWidth(frame), height = (int)CVPixelBufferGetHeight(frame);
        if (!pool.texture || pool.width != width || pool.height != height) [pool allocateWidth:width height:height format:2099336u];
        CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        [pool.texture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)width, (NSUInteger)height)
                        mipmapLevel:0
                          withBytes:CVPixelBufferGetBaseAddress(frame)
                        bytesPerRow:CVPixelBufferGetBytesPerRow(frame)];
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(frame);
        if (!v.announced) {
            v.announced = YES;
            [pool announceWidth:width height:height];
            WLOG("video", "first frame %dx%d into pool %#x", width, height, pool.handle);
        }
        sp_scene_invalidate();
    }
}
