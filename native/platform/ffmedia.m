// Windows Media files (WMV and WMA, in the ASF container) and AVI files with
// FFmpeg: the Mac's own media frameworks cannot open them, so here they are
// read, decoded and played with FFmpeg's libraries (LGPL;
// tools/setup_toolchain.py builds them with only these formats and the
// codecs they usually carry).
//
// A player has one thread that reads the file and decodes. What it reads
// goes to a queue of compressed packets per stream (small, and files differ
// in how far ahead of the sound they keep the pictures); sound is decoded
// whenever less than half a second is scheduled on the AVAudioEngine player
// node, pictures whenever the queue of decoded ones (about a second) has
// room. Reading never waits for the pictures, so the sound never starves. The sound card's clock is the player's clock: the position
// is where the node has got to in what was scheduled. Without sound (no sound
// track, or played faster or slower than normal) a wall clock stands in.
// The video stand-in (native/splash/sp_video.m) asks on every frame drawn for
// the picture due then, which is converted to BGRA only when it is shown.
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include "ffmedia.h"
#include "wmc.h"

enum { QUEUE_MAX = 30, QUEUE_ROOM = 40 }; // decoded pictures held ahead (room for one packet's worth over)
static const int64_t PACKETS_MAX = 64 << 20; // compressed bytes read ahead, at most
static const double AUDIO_AHEAD = 0.5;   // seconds of sound scheduled ahead

bool wmc_ff_handles(const char *path) {
    const char *dot = path ? strrchr(path, '.') : NULL;
    if (!dot) return false;
    return !strcasecmp(dot, ".wmv") || !strcasecmp(dot, ".wma") || !strcasecmp(dot, ".asf") || !strcasecmp(dot, ".wm") ||
           !strcasecmp(dot, ".avi") || !strcasecmp(dot, ".divx");
}

static AVFormatContext *open_file(const char *path) {
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return NULL;
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        avformat_close_input(&fmt);
        return NULL;
    }
    return fmt;
}

// The first stream of a kind that can be decoded (cover pictures are not video).
static int pick_stream(AVFormatContext *fmt, enum AVMediaType type) {
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        if (st->codecpar->codec_type != type) continue;
        if (st->disposition & AV_DISPOSITION_ATTACHED_PIC) continue;
        if (avcodec_find_decoder(st->codecpar->codec_id)) return (int)i;
    }
    return -1;
}

static AVCodecContext *open_decoder(AVStream *st) {
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return NULL;
    if (avcodec_parameters_to_context(ctx, st->codecpar) < 0) goto fail;
    ctx->thread_count = 0;                                  // as many as there are cores
    ctx->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    ctx->pkt_timebase = st->time_base;
    if (avcodec_open2(ctx, codec, NULL) < 0) goto fail;
    return ctx;
fail:
    avcodec_free_context(&ctx);
    return NULL;
}

static double duration_of(AVFormatContext *fmt) {
    if (fmt->duration != AV_NOPTS_VALUE && fmt->duration > 0) return fmt->duration / (double)AV_TIME_BASE;
    double best = 0;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        if (st->duration != AV_NOPTS_VALUE) best = fmax(best, st->duration * av_q2d(st->time_base));
    }
    return best;
}

// Converts a decoded picture to BGRA in `out` (width * 4 bytes a row).
static struct SwsContext *to_bgra(struct SwsContext *sws, const AVFrame *f, uint8_t *out) {
    sws = sws_getCachedContext(sws, f->width, f->height, f->format, f->width, f->height, AV_PIX_FMT_BGRA,
                               SWS_BILINEAR, NULL, NULL, NULL);
    if (!sws) return NULL;
    // HD pictures use BT.709 colours, smaller ones BT.601, unless the file says.
    int space = f->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709
              : f->colorspace == AVCOL_SPC_UNSPECIFIED ? (f->height >= 720 ? SWS_CS_ITU709 : SWS_CS_ITU601)
              : SWS_CS_ITU601;
    sws_setColorspaceDetails(sws, sws_getCoefficients(space), f->color_range == AVCOL_RANGE_JPEG,
                             sws_getCoefficients(SWS_CS_ITU709), 1, 0, 1 << 16, 1 << 16);
    uint8_t *dst[4] = {out, NULL, NULL, NULL};
    int stride[4] = {f->width * 4, 0, 0, 0};
    sws_scale(sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, dst, stride);
    return sws;
}

// ---- the player -----------------------------------------------------------------

typedef struct {
    double pts;
    AVFrame *frame;
} QueuedPicture;

@interface WmcFFPlayer : NSObject
@end

@implementation WmcFFPlayer {
@public
    AVFormatContext *_fmt;
    AVCodecContext *_vctx, *_actx;
    int _vstream, _astream;
    double _duration;
    _Atomic int _sarNum, _sarDen;         // the pixels' shape the decoded pictures give (DV keeps it there)
    pthread_mutex_t _lock;
    pthread_cond_t _wake;
    pthread_t _thread;
    bool _threadStarted, _quit, _eof;
    double _seekTo;                       // NAN, or where the reader is to go next
    double _dropBefore;                   // what the reader leaves out after a seek
    QueuedPicture _queue[QUEUE_ROOM];
    AVPacket **_vpkts, **_apkts;          // compressed packets read and not yet decoded
    int _vcount, _acount, _vcap, _acap;
    int64_t _packetBytes;
    bool _readEnd;                        // the file has been read to its end
    int _queued;
    double _lastPts;                      // of the picture before, for pictures without a time
    // the picture handed out
    struct SwsContext *_sws;
    uint8_t *_bgra;
    int _shownW, _shownH;
    double _shownPts;
    // sound
    AVAudioEngine *_engine;
    AVAudioPlayerNode *_node;
    AVAudioFormat *_format;
    SwrContext *_swr;
    bool _audioOn;                        // sound is being scheduled (rate 1, an engine that started)
    double _audioBase;                    // media time of the first sample scheduled since the node started
    int64_t _scheduled;                   // samples scheduled since then
    int _buffers;                         // buffers scheduled since then
    // Buffers played out, counted by the node's callbacks without the lock:
    // stopping the node (under the lock) calls them for what was pending.
    atomic_int _buffersPlayed;
    atomic_int _generation;               // counts restarts (a stopped node reports its buffers as done)
    // the clock
    bool _playing;
    float _rate, _volume;
    bool _muted;
    double _wallBase;                     // media time when the wall clock last started or stopped
    CFTimeInterval _wallStart;
    double _held;                         // the position while paused
}

static void *reader_main(void *arg);

- (void)dealloc {
    [self shutdown];
}

- (void)shutdown {
    if (_threadStarted) {
        pthread_mutex_lock(&_lock);
        _quit = true;
        pthread_cond_broadcast(&_wake);
        pthread_mutex_unlock(&_lock);
        pthread_join(_thread, NULL);
        _threadStarted = false;
    }
    [_node stop];
    [_engine stop];
    _engine = nil;
    for (int i = 0; i < _queued; i++) av_frame_free(&_queue[i].frame);
    _queued = 0;
    [self dropPacketsLocked];
    free(_vpkts), _vpkts = NULL;
    free(_apkts), _apkts = NULL;
    if (_sws) sws_freeContext(_sws), _sws = NULL;
    if (_swr) swr_free(&_swr);
    if (_vctx) avcodec_free_context(&_vctx);
    if (_actx) avcodec_free_context(&_actx);
    if (_fmt) avformat_close_input(&_fmt);
    free(_bgra), _bgra = NULL;
}

- (instancetype)initWithPath:(const char *)path video:(bool)withVideo {
    if (!(self = [super init])) return nil;
    pthread_mutex_init(&_lock, NULL);
    pthread_cond_init(&_wake, NULL);
    _seekTo = NAN;
    _dropBefore = -INFINITY;
    _audioBase = NAN;
    _shownPts = NAN;
    _lastPts = 0;
    _rate = 1;
    _volume = 1;
    _fmt = open_file(path);
    if (!_fmt) return nil;
    _duration = duration_of(_fmt);
    _vstream = withVideo ? pick_stream(_fmt, AVMEDIA_TYPE_VIDEO) : -1;
    _astream = pick_stream(_fmt, AVMEDIA_TYPE_AUDIO);
    if (_vstream >= 0 && !(_vctx = open_decoder(_fmt->streams[_vstream]))) _vstream = -1;
    if (_astream >= 0 && !(_actx = open_decoder(_fmt->streams[_astream]))) _astream = -1;
    if (_vstream < 0 && _astream < 0) return nil;
    if (_astream >= 0) [self startSound];
    if (pthread_create(&_thread, NULL, reader_main, (__bridge void *)self) != 0) return nil;
    _threadStarted = true;
    WLOG("video", "FFmpeg opened %s: %s%s%s, %.1f s", path, _vctx ? _vctx->codec->name : "",
         _vctx && _actx ? " + " : "", _actx ? _actx->codec->name : "", _duration);
    return self;
}

// An engine and a player node for the sound, at the file's own rate, in
// stereo (or mono). If the Mac cannot play sound, the wall clock serves.
- (void)startSound {
    int channels = _actx->ch_layout.nb_channels >= 2 ? 2 : 1;
    AVChannelLayout out;
    av_channel_layout_default(&out, channels);
    if (swr_alloc_set_opts2(&_swr, &out, AV_SAMPLE_FMT_FLTP, _actx->sample_rate, &_actx->ch_layout,
                            _actx->sample_fmt, _actx->sample_rate, 0, NULL) < 0 || swr_init(_swr) < 0) {
        if (_swr) swr_free(&_swr);
        return;
    }
    _format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:_actx->sample_rate channels:(AVAudioChannelCount)channels];
    _engine = [AVAudioEngine new];
    _node = [AVAudioPlayerNode new];
    [_engine attachNode:_node];
    [_engine connect:_node to:_engine.mainMixerNode format:_format];
    [self applyVolume];
    NSError *error = nil;
    if (![_engine startAndReturnError:&error]) {
        WLOG("snd", "no sound for FFmpeg's player: %s", error.localizedDescription.UTF8String);
        _engine = nil;
        _node = nil;
        return;
    }
    _audioOn = true;
}

- (void)applyVolume {
    _node.volume = (_muted || getenv("WMC_MUTE")) ? 0 : _volume;
}

// ---- the clock (under _lock) ----

- (bool)audioClock {
    return _audioOn && !isnan(_audioBase);
}

- (double)positionLocked {
    double p;
    if (!_playing) {
        p = _held;
    } else if ([self audioClock]) {
        AVAudioTime *t = _node.lastRenderTime ? [_node playerTimeForNodeTime:_node.lastRenderTime] : nil;
        double played = t && t.isSampleTimeValid ? (double)t.sampleTime : 0;
        if (played > (double)_scheduled) played = (double)_scheduled;
        p = _audioBase + played / _format.sampleRate;
    } else {
        p = _wallBase + (CACurrentMediaTime() - _wallStart) * _rate;
    }
    if (_duration > 0 && p > _duration) p = _duration;
    return p < 0 ? 0 : p;
}

- (bool)endedLocked {
    if (!_eof || _queued > 0) return false;
    if ([self audioClock]) return atomic_load(&_buffersPlayed) >= _buffers;
    return [self positionLocked] >= _lastPts - 0.001 || _duration <= 0 || [self positionLocked] >= _duration;
}

// Starts again from `t`: everything queued or scheduled goes.
- (void)dropPacketsLocked {
    for (int i = 0; i < _vcount; i++) av_packet_free(&_vpkts[i]);
    for (int i = 0; i < _acount; i++) av_packet_free(&_apkts[i]);
    _vcount = _acount = 0;
    _packetBytes = 0;
}

- (void)restartLocked:(double)t {
    for (int i = 0; i < _queued; i++) av_frame_free(&_queue[i].frame);
    _queued = 0;
    [self dropPacketsLocked];
    _readEnd = false;
    atomic_fetch_add(&_generation, 1);
    [_node stop];
    _audioBase = NAN;
    _scheduled = 0;
    _buffers = 0;
    atomic_store(&_buffersPlayed, 0);
    _seekTo = t;
    _dropBefore = t;
    _eof = false;
    _held = t;
    _wallBase = t;
    _wallStart = CACurrentMediaTime();
    _shownPts = NAN;
    pthread_cond_broadcast(&_wake);
}

// ---- the reader ----

static void handle_picture(WmcFFPlayer *p, AVFrame *f) {
    AVStream *st = p->_fmt->streams[p->_vstream];
    if (f->sample_aspect_ratio.num > 0 && f->sample_aspect_ratio.den > 0) {
        p->_sarNum = f->sample_aspect_ratio.num;
        p->_sarDen = f->sample_aspect_ratio.den;
    }
    double pts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp * av_q2d(st->time_base)
                                                             : p->_lastPts + 1.0 / 30;
    pthread_mutex_lock(&p->_lock);
    p->_lastPts = pts;
    if (pts < p->_dropBefore - 0.001 || !isnan(p->_seekTo)) {
        pthread_mutex_unlock(&p->_lock);
        return;
    }
    if (!p->_quit && p->_queued < QUEUE_ROOM) {
        p->_queue[p->_queued].pts = pts;
        p->_queue[p->_queued].frame = av_frame_clone(f);
        p->_queued++;
    }
    pthread_mutex_unlock(&p->_lock);
}

static void handle_sound(WmcFFPlayer *p, AVFrame *f) {
    if (!p->_audioOn || !p->_swr) return;
    AVStream *st = p->_fmt->streams[p->_astream];
    double rate = p->_format.sampleRate;
    double pts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp * av_q2d(st->time_base) : NAN;
    int capacity = swr_get_out_samples(p->_swr, f->nb_samples);
    if (capacity <= 0) return;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:p->_format frameCapacity:(AVAudioFrameCount)capacity];
    uint8_t *out[2] = {(uint8_t *)buffer.floatChannelData[0],
                       (uint8_t *)buffer.floatChannelData[p->_format.channelCount > 1 ? 1 : 0]};
    int n = swr_convert(p->_swr, out, capacity, (const uint8_t **)f->extended_data, f->nb_samples);
    if (n <= 0) return;
    pthread_mutex_lock(&p->_lock);
    if (!isnan(p->_seekTo) || p->_quit) {
        pthread_mutex_unlock(&p->_lock);
        return;
    }
    if (isnan(pts)) pts = isnan(p->_audioBase) ? p->_dropBefore : p->_audioBase + p->_scheduled / rate;
    // After a seek, the sound before the target is left out.
    int skip = pts < p->_dropBefore ? (int)lround((p->_dropBefore - pts) * rate) : 0;
    if (skip >= n) {
        pthread_mutex_unlock(&p->_lock);
        return;
    }
    if (skip > 0) {
        for (AVAudioChannelCount c = 0; c < p->_format.channelCount; c++)
            memmove(buffer.floatChannelData[c], buffer.floatChannelData[c] + skip, (size_t)(n - skip) * sizeof(float));
        n -= skip;
        pts += skip / rate;
    }
    buffer.frameLength = (AVAudioFrameCount)n;
    if (isnan(p->_audioBase)) p->_audioBase = pts;
    int generation = atomic_load(&p->_generation);
    __weak WmcFFPlayer *weak = p;
    [p->_node scheduleBuffer:buffer
          completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
               completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
                   WmcFFPlayer *me = weak;
                   if (me && atomic_load(&me->_generation) == generation) atomic_fetch_add(&me->_buffersPlayed, 1);
               }];
    p->_scheduled += n;
    p->_buffers++;
    if (p->_playing && !p->_node.isPlaying) [p->_node play];
    pthread_mutex_unlock(&p->_lock);
}

static void drain(WmcFFPlayer *p, AVCodecContext *ctx, AVFrame *f, bool picture) {
    while (avcodec_receive_frame(ctx, f) == 0) {
        if (picture) handle_picture(p, f);
        else handle_sound(p, f);
        av_frame_unref(f);
    }
}

static void push_packet(AVPacket ***list, int *count, int *cap, AVPacket *pkt) {
    if (*count == *cap) {
        *cap = *cap ? *cap * 2 : 64;
        *list = realloc(*list, sizeof(AVPacket *) * (size_t)*cap);
    }
    (*list)[(*count)++] = pkt;
}

static AVPacket *pop_packet(AVPacket **list, int *count) {
    AVPacket *pkt = list[0];
    memmove(list, list + 1, sizeof(AVPacket *) * (size_t)(*count - 1));
    (*count)--;
    return pkt;
}

static void *reader_main(void *arg) {
    WmcFFPlayer *p = (__bridge WmcFFPlayer *)arg;
    pthread_setname_np("FFmpeg reader");
    AVPacket *pkt = av_packet_alloc();
    AVFrame *f = av_frame_alloc();
    bool flushed = false;                 // the decoders have given up what they held at the end
    for (;;) {
        pthread_mutex_lock(&p->_lock);
        if (p->_quit) {
            pthread_mutex_unlock(&p->_lock);
            break;
        }
        if (!isnan(p->_seekTo)) {
            double t = p->_seekTo;
            p->_seekTo = NAN;
            pthread_mutex_unlock(&p->_lock);
            av_seek_frame(p->_fmt, -1, (int64_t)(t * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD);
            if (p->_vctx) avcodec_flush_buffers(p->_vctx);
            if (p->_actx) avcodec_flush_buffers(p->_actx);
            flushed = false;
            continue;
        }
        // What is wanted: sound when less than AUDIO_AHEAD is scheduled (none
        // scheduled yet: none ahead), pictures when their queue has room.
        // Without sound being played, sound drives nothing, unless there are
        // no pictures either: then it is still read and decoded to the end,
        // so that the end is seen.
        double ahead = 0;
        if (p->_audioOn && !isnan(p->_audioBase))
            ahead = p->_audioBase + p->_scheduled / p->_format.sampleRate - [p positionLocked];
        bool wantSound = p->_astream >= 0 && (p->_audioOn ? ahead < AUDIO_AHEAD : p->_vstream < 0);
        bool wantPictures = p->_vstream >= 0 && p->_queued < QUEUE_MAX;
        AVPacket *next = NULL;
        bool sound = false;
        if (wantSound && p->_acount > 0) {
            next = pop_packet(p->_apkts, &p->_acount);
            sound = true;
        } else if (wantPictures && p->_vcount > 0) {
            next = pop_packet(p->_vpkts, &p->_vcount);
        }
        if (next) p->_packetBytes -= next->size;
        bool needRead = !next && !p->_readEnd && p->_packetBytes < PACKETS_MAX &&
                        ((wantSound && p->_acount == 0) || (wantPictures && p->_vcount == 0));
        bool finished = !next && p->_readEnd && p->_acount == 0 && p->_vcount == 0;
        if (!next && !needRead && !(finished && !flushed)) {
            if (finished && flushed) p->_eof = true;
            struct timespec until;
            clock_gettime(CLOCK_REALTIME, &until);
            until.tv_nsec += 10 * 1000000;
            if (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
            pthread_cond_timedwait(&p->_wake, &p->_lock, &until);
            pthread_mutex_unlock(&p->_lock);
            continue;
        }
        pthread_mutex_unlock(&p->_lock);

        if (next) {
            AVCodecContext *ctx = sound ? p->_actx : p->_vctx;
            if (avcodec_send_packet(ctx, next) >= 0) drain(p, ctx, f, !sound);
            av_packet_free(&next);
        } else if (needRead) {
            int r = av_read_frame(p->_fmt, pkt);
            pthread_mutex_lock(&p->_lock);
            if (r < 0) {
                p->_readEnd = true;
            } else if (isnan(p->_seekTo) && (pkt->stream_index == p->_vstream ||
                                             (pkt->stream_index == p->_astream && (p->_audioOn || p->_vstream < 0)))) {
                AVPacket *kept = av_packet_clone(pkt);
                p->_packetBytes += kept->size;
                if (pkt->stream_index == p->_vstream) push_packet(&p->_vpkts, &p->_vcount, &p->_vcap, kept);
                else push_packet(&p->_apkts, &p->_acount, &p->_acap, kept);
            }
            pthread_mutex_unlock(&p->_lock);
            av_packet_unref(pkt);
        } else {
            // The end: what the decoders still hold comes out.
            if (p->_vctx && avcodec_send_packet(p->_vctx, NULL) >= 0) drain(p, p->_vctx, f, true);
            if (p->_actx && avcodec_send_packet(p->_actx, NULL) >= 0) drain(p, p->_actx, f, false);
            flushed = true;
        }
    }
    av_frame_free(&f);
    av_packet_free(&pkt);
    return NULL;
}

@end

// ---- the C interface ----------------------------------------------------------------

void *wmc_ff_open(const char *path, bool with_video) {
    WmcFFPlayer *p = [[WmcFFPlayer alloc] initWithPath:path video:with_video];
    if (!p) WLOG("video", "FFmpeg cannot play %s", path);
    return p ? (__bridge_retained void *)p : NULL;
}

void wmc_ff_close(void *player) {
    if (!player) return;
    WmcFFPlayer *p = (__bridge_transfer WmcFFPlayer *)player;
    [p shutdown];
}

#define PLAYER(h) WmcFFPlayer *p = (__bridge WmcFFPlayer *)(h)

int wmc_ff_state(void *player) {
    PLAYER(player);
    if (!p) return 3;
    pthread_mutex_lock(&p->_lock);
    int state = [p endedLocked] ? 3 : p->_playing ? 2 : 1;
    pthread_mutex_unlock(&p->_lock);
    return state;
}

int wmc_ff_has_audio(void *player) { PLAYER(player); return p && p->_astream >= 0; }
int wmc_ff_has_video(void *player) { PLAYER(player); return p && p->_vstream >= 0; }

void wmc_ff_size(void *player, int *width, int *height) {
    PLAYER(player);
    if (width) *width = p && p->_vctx ? p->_vctx->width : 0;
    if (height) *height = p && p->_vctx ? p->_vctx->height : 0;
}

void wmc_ff_display_size(void *player, int *width, int *height) {
    PLAYER(player);
    int w = p && p->_vctx ? p->_vctx->width : 0, h = p && p->_vctx ? p->_vctx->height : 0;
    AVRational sar = p && p->_vstream >= 0 ? av_guess_sample_aspect_ratio(p->_fmt, p->_fmt->streams[p->_vstream], NULL)
                                           : (AVRational){0, 1};
    if (p && p->_sarNum > 0 && p->_sarDen > 0 && (sar.num <= 0 || sar.num == sar.den)) sar = (AVRational){p->_sarNum, p->_sarDen};
    if (sar.num > 0 && sar.den > 0 && sar.num != sar.den) w = (int)lround(w * (double)sar.num / sar.den);
    if (width) *width = w;
    if (height) *height = h;
}

double wmc_ff_duration(void *player) { PLAYER(player); return p ? p->_duration : 0; }

double wmc_ff_position(void *player) {
    PLAYER(player);
    if (!p) return 0;
    pthread_mutex_lock(&p->_lock);
    double pos = [p endedLocked] ? p->_duration : [p positionLocked];
    pthread_mutex_unlock(&p->_lock);
    return pos;
}

void wmc_ff_seek(void *player, double seconds) {
    PLAYER(player);
    if (!p) return;
    pthread_mutex_lock(&p->_lock);
    [p restartLocked:fmax(0, p->_duration > 0 ? fmin(seconds, p->_duration) : seconds)];
    pthread_mutex_unlock(&p->_lock);
}

void wmc_ff_play(void *player) {
    PLAYER(player);
    if (!p) return;
    pthread_mutex_lock(&p->_lock);
    if ([p endedLocked]) [p restartLocked:0];
    if (!p->_playing) {
        p->_playing = true;
        p->_wallBase = p->_held;
        p->_wallStart = CACurrentMediaTime();
        if ([p audioClock] && p->_rate == 1) [p->_node play];
    }
    pthread_mutex_unlock(&p->_lock);
}

void wmc_ff_pause(void *player) {
    PLAYER(player);
    if (!p) return;
    pthread_mutex_lock(&p->_lock);
    if (p->_playing) {
        p->_held = [p positionLocked];
        p->_playing = false;
        [p->_node pause];
    }
    pthread_mutex_unlock(&p->_lock);
}

// Faster or slower than normal: the pictures follow a wall clock and there is
// no sound (as Media Center does when it skims); back at normal speed the
// sound starts again where the pictures are.
void wmc_ff_set_rate(void *player, float rate) {
    PLAYER(player);
    if (!p || rate <= 0 || rate == p->_rate) return;
    pthread_mutex_lock(&p->_lock);
    double at = [p positionLocked];
    bool hadSound = p->_engine != nil;
    p->_rate = rate;
    p->_audioOn = hadSound && rate == 1;
    p->_held = at;
    p->_wallBase = at;
    p->_wallStart = CACurrentMediaTime();
    if (rate == 1 && hadSound) {
        [p restartLocked:at];
    } else {
        atomic_fetch_add(&p->_generation, 1);
        [p->_node stop];
        p->_audioBase = NAN;
        p->_scheduled = 0;
        p->_buffers = 0;
        atomic_store(&p->_buffersPlayed, 0);
    }
    pthread_mutex_unlock(&p->_lock);
}

void wmc_ff_set_volume(void *player, float volume, int muted) {
    PLAYER(player);
    if (!p) return;
    p->_volume = volume;
    p->_muted = muted != 0;
    [p applyVolume];
}

int wmc_ff_take_frame(void *player, const uint8_t **bgra, int *stride, int *width, int *height) {
    PLAYER(player);
    if (!p || p->_vstream < 0) return 0;
    pthread_mutex_lock(&p->_lock);
    double now = [p positionLocked];
    // The newest picture due by now; older ones go.
    int due = -1;
    for (int i = 0; i < p->_queued && p->_queue[i].pts <= now + 0.005; i++) due = i;
    if (due < 0 && isnan(p->_shownPts) && p->_queued > 0) due = 0;   // the first picture, before it is due
    AVFrame *frame = NULL;
    double pts = NAN;
    if (due >= 0) {
        frame = p->_queue[due].frame;
        pts = p->_queue[due].pts;
        for (int i = 0; i < due; i++) av_frame_free(&p->_queue[i].frame);
        // (the shown one stays first until a later one is due)
        memmove(p->_queue, p->_queue + due, sizeof(QueuedPicture) * (size_t)(p->_queued - due));
        p->_queued -= due;
        pthread_cond_broadcast(&p->_wake);
    }
    bool fresh = frame && pts != p->_shownPts;
    if (fresh) {
        if (!p->_bgra || p->_shownW != frame->width || p->_shownH != frame->height) {
            free(p->_bgra);
            p->_bgra = malloc((size_t)frame->width * (size_t)frame->height * 4);
            p->_shownW = frame->width;
            p->_shownH = frame->height;
        }
        p->_sws = to_bgra(p->_sws, frame, p->_bgra);
        p->_shownPts = pts;
    }
    pthread_mutex_unlock(&p->_lock);
    if (!fresh || !p->_sws) return 0;
    *bgra = p->_bgra;
    *stride = p->_shownW * 4;
    *width = p->_shownW;
    *height = p->_shownH;
    return 1;
}

// ---- tags, cover pictures, thumbnails ---------------------------------------------

int wmc_ff_tags(const char *path, char *out, int size) {
    if (!path || !out || size <= 0) return -1;
    AVFormatContext *fmt = open_file(path);
    if (!fmt) return -1;
    NSMutableString *text = [NSMutableString string];
    // (FFmpeg names the ASF attributes: Author is "artist", WM/AlbumTitle
    // "album", WM/Year "date", and so on.)
    const char *keys[][2] = {{"title", "title"}, {"artist", "artist"}, {"album", "album"},
                             {"albumartist", "album_artist"}, {"genre", "genre"}, {"track", "track"},
                             {"year", "date"}, {"composer", "composer"}};
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        AVDictionaryEntry *e = av_dict_get(fmt->metadata, keys[i][1], NULL, 0);
        if (!e || !e->value[0]) continue;
        NSString *value = [@(e->value) stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (!strcmp(keys[i][0], "year") && value.length > 4) value = [value substringToIndex:4];
        [text appendFormat:@"%s=%@\n", keys[i][0], value];
    }
    [text appendFormat:@"duration=%.3f\n", duration_of(fmt)];
    for (unsigned i = 0; i < fmt->nb_streams; i++)
        if (fmt->streams[i]->disposition & AV_DISPOSITION_ATTACHED_PIC) [text appendString:@"artwork=1\n"];
    avformat_close_input(&fmt);
    const char *utf8 = text.UTF8String;
    size_t n = strlen(utf8);
    if (n >= (size_t)size) n = (size_t)size - 1;
    memcpy(out, utf8, n);
    out[n] = 0;
    return (int)n;
}

int wmc_ff_artwork(const char *path, const char *dest) {
    AVFormatContext *fmt = open_file(path);
    if (!fmt) return 0;
    int done = 0;
    for (unsigned i = 0; i < fmt->nb_streams && !done; i++) {
        AVStream *st = fmt->streams[i];
        if (!(st->disposition & AV_DISPOSITION_ATTACHED_PIC) || st->attached_pic.size <= 0) continue;
        NSData *data = [NSData dataWithBytes:st->attached_pic.data length:(NSUInteger)st->attached_pic.size];
        done = [data writeToFile:@(dest) atomically:YES] ? 1 : 0;
    }
    avformat_close_input(&fmt);
    return done;
}

CGImageRef wmc_ff_thumbnail(const char *path, int box) {
    AVFormatContext *fmt = open_file(path);
    if (!fmt) return NULL;
    int vs = pick_stream(fmt, AVMEDIA_TYPE_VIDEO);
    AVCodecContext *ctx = vs >= 0 ? open_decoder(fmt->streams[vs]) : NULL;
    CGImageRef image = NULL;
    if (ctx) {
        double at = duration_of(fmt) * 0.1;
        if (at > 0) av_seek_frame(fmt, -1, (int64_t)(at * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD);
        AVPacket *pkt = av_packet_alloc();
        AVFrame *f = av_frame_alloc();
        AVStream *st = fmt->streams[vs];
        bool got = false;
        for (int packets = 0; !got && packets < 2000 && av_read_frame(fmt, pkt) >= 0; packets++) {
            if (pkt->stream_index == vs && avcodec_send_packet(ctx, pkt) >= 0) {
                while (!got && avcodec_receive_frame(ctx, f) == 0) {
                    double pts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp * av_q2d(st->time_base) : at;
                    if (pts + 0.001 >= at || packets > 600) got = true;
                    else av_frame_unref(f);
                }
            }
            av_packet_unref(pkt);
        }
        if (got) {
            uint8_t *bgra = malloc((size_t)f->width * (size_t)f->height * 4);
            struct SwsContext *sws = to_bgra(NULL, f, bgra);
            if (sws) {
                CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
                CGContextRef full = CGBitmapContextCreate(bgra, (size_t)f->width, (size_t)f->height, 8, (size_t)f->width * 4, space,
                                                          kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
                CGImageRef whole = full ? CGBitmapContextCreateImage(full) : NULL;
                double scale = box > 0 ? fmin(1.0, box / (double)(f->width > f->height ? f->width : f->height)) : 1.0;
                size_t w = (size_t)lround(f->width * scale), h = (size_t)lround(f->height * scale);
                CGContextRef small = whole ? CGBitmapContextCreate(NULL, w, h, 8, 0, space,
                                                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little) : NULL;
                if (small) {
                    CGContextSetInterpolationQuality(small, kCGInterpolationHigh);
                    CGContextDrawImage(small, CGRectMake(0, 0, w, h), whole);
                    image = CGBitmapContextCreateImage(small);
                    CGContextRelease(small);
                }
                if (whole) CGImageRelease(whole);
                if (full) CGContextRelease(full);
                CGColorSpaceRelease(space);
                sws_freeContext(sws);
            }
            free(bgra);
        }
        av_frame_free(&f);
        av_packet_free(&pkt);
        avcodec_free_context(&ctx);
    }
    avformat_close_input(&fmt);
    return image;
}
