// Video players, for both engines: an AVPlayer (opened by the managed
// stand-ins in WmcStandins/Playback), or for Windows Media and AVI files
// (which AVFoundation cannot open) FFmpeg's (native/platform/ffmedia.m).
//
// A player shows its frames on a "surface": a small number the engine gave
// the stand-in. On every tick (wmc_video_tick) each playing video hands its
// newest frame to the engine, which says where a surface's frames go
// (native/splash/sp_video.m: the framework's video pools; native/duser:
// layers).
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import "platform/video.h"
#include "platform/ffmedia.h"

static NSMutableArray *s_videos;                                       // WmcVideo, open ones

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

// Which surface the frames go to (0: nowhere).
WMC_API void wmc_video_set_surface(void *handle, int surfaceId) {
    WmcVideo *v = (__bridge WmcVideo *)handle;
    if (!v) return;
    on_main(^{
        v.surfaceId = surfaceId;
        v.announced = NO;
        WLOG("video", "player presents to surface %d", surfaceId);
    });
}

// FFmpeg's player: its picture due now, if it is a new one.
static void present_ff(WmcVideo *v, const WmcVideoSink *sink) {
    if (!v.surfaceId || !sink->target(v.surfaceId)) return;
    const uint8_t *bgra;
    int stride, width, height, shownW, shownH;
    if (!wmc_ff_take_frame(v.ff, &bgra, &stride, &width, &height)) return;
    wmc_ff_display_size(v.ff, &shownW, &shownH);
    BOOL first = !v.announced;
    v.announced = YES;
    sink->put(v.surfaceId, bgra, (size_t)stride, width, height, shownW, shownH, first);
    if (first) WLOG("video", "first frame %dx%d (FFmpeg, shown as %dx%d) on surface %d", width, height, shownW, shownH, v.surfaceId);
}

// Hands every video's newest frame to the engine. On the main thread,
// before frames are drawn.
void wmc_video_tick(const WmcVideoSink *sink) {
    if (!s_videos.count) return;
    CFTimeInterval host = CACurrentMediaTime();
    for (WmcVideo *v in s_videos) {
        if (v.ff) {
            present_ff(v, sink);
            continue;
        }
        if (!v.surfaceId || v.item.status != AVPlayerItemStatusReadyToPlay) continue;
        int target = sink->target(v.surfaceId);
        if (!target) continue;
        CMTime at = [v.output itemTimeForHostTime:host];
        if (![v.output hasNewPixelBufferForItemTime:at] && target != 2 && v.announced) continue;
        CVPixelBufferRef frame = [v.output copyPixelBufferForItemTime:at itemTimeForDisplay:NULL];
        if (!frame) continue;
        int width = (int)CVPixelBufferGetWidth(frame), height = (int)CVPixelBufferGetHeight(frame);
        BOOL first = !v.announced;
        v.announced = YES;
        CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        sink->put(v.surfaceId, CVPixelBufferGetBaseAddress(frame), CVPixelBufferGetBytesPerRow(frame), width, height, width, height, first);
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(frame);
        if (first) WLOG("video", "first frame %dx%d on surface %d", width, height, v.surfaceId);
    }
}
