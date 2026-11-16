// Media files, for the managed stand-ins (WmcStandins/Wmp): reading tags and
// cover pictures, and playing sound.
//
// Tags come from AudioToolbox's own tag reader (ID3, iTunes atoms, Vorbis
// comments, ...), with AVFoundation asked for the one thing it lacks, the
// album artist. Sound is played with AVAudioPlayer. Windows Media Audio
// (.wma), which neither can open, is read and played with FFmpeg
// (ffmedia.m).
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include "ffmedia.h"
#include "wmc.h"

static NSString *text_of(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static void put(NSMutableString *out, NSString *key, id value) {
    NSString *text = text_of(value);
    if (text.length == 0) return;
    text = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    [out appendFormat:@"%@=%@\n", key, text];
}

// What AudioToolbox's tag dictionary does not carry, from AVFoundation: the
// album artist ("TPE2" in ID3, "aART" in iTunes files) and the cover picture
// of MP3 files.
static void more_metadata(NSURL *url, NSString **albumArtist, NSData **artwork) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @NO}];
    NSArray<AVMetadataIdentifier> *wanted = @[ AVMetadataIdentifieriTunesMetadataAlbumArtist, AVMetadataIdentifierID3MetadataBand ];
    __block NSString *artist = nil;
    __block NSData *picture = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:@[ @"metadata" ] completionHandler:^{
        NSError *error = nil;
        if ([asset statusOfValueForKey:@"metadata" error:&error] == AVKeyValueStatusLoaded) {
            for (AVMetadataIdentifier identifier in wanted) {
                NSArray<AVMetadataItem *> *items = [AVMetadataItem metadataItemsFromArray:asset.metadata filteredByIdentifier:identifier];
                NSString *value = text_of(items.firstObject.value);
                if (value.length) { artist = value; break; }
            }
            NSArray<AVMetadataItem *> *pictures = [AVMetadataItem metadataItemsFromArray:asset.metadata
                                                                 filteredByIdentifier:AVMetadataCommonIdentifierArtwork];
            picture = pictures.firstObject.dataValue;
        }
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
    if (albumArtist) *albumArtist = artist;
    if (artwork) *artwork = picture;
}

// Writes "key=value" lines (UTF-8) for a sound file: title, artist, album,
// albumartist, genre, track, year, composer, duration (seconds), artwork
// (1 when the file carries a picture). Returns the number of bytes, or -1 if
// the file is not sound that can be read.
WMC_API int wmc_media_tags(const char *path, char *out, int size) {
    @autoreleasepool {
        if (!path || !out || size <= 0) return -1;
        if (wmc_ff_handles(path)) return wmc_ff_tags(path, out, size);
        NSURL *url = [NSURL fileURLWithPath:@(path)];
        AudioFileID file = NULL;
        if (AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, 0, &file) != noErr) return -1;
        NSMutableString *text = [NSMutableString string];
        CFDictionaryRef info = NULL;
        UInt32 infoSize = sizeof(info);
        if (AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &infoSize, &info) == noErr && info) {
            NSDictionary *d = CFBridgingRelease(info);
            put(text, @"title", d[@kAFInfoDictionary_Title]);
            put(text, @"artist", d[@kAFInfoDictionary_Artist]);
            put(text, @"album", d[@kAFInfoDictionary_Album]);
            put(text, @"genre", d[@kAFInfoDictionary_Genre]);
            put(text, @"track", d[@kAFInfoDictionary_TrackNumber]);
            put(text, @"year", d[@kAFInfoDictionary_Year]);
            put(text, @"composer", d[@kAFInfoDictionary_Composer]);
            put(text, @"duration", d[@kAFInfoDictionary_ApproximateDurationInSeconds]);
        }
        if ([text rangeOfString:@"duration="].location == NSNotFound) {
            Float64 seconds = 0;
            UInt32 secondsSize = sizeof(seconds);
            if (AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &secondsSize, &seconds) == noErr)
                [text appendFormat:@"duration=%.3f\n", seconds];
        }
        AudioFileClose(file);
        NSString *albumArtist = nil;
        NSData *picture = nil;
        more_metadata(url, &albumArtist, &picture);
        if (picture.length) [text appendString:@"artwork=1\n"];
        put(text, @"albumartist", albumArtist);
        const char *utf8 = text.UTF8String;
        size_t n = strlen(utf8);
        if (n >= (size_t)size) n = (size_t)size - 1;
        memcpy(out, utf8, n);
        out[n] = 0;
        return (int)n;
    }
}

// Writes the picture a sound file carries (as stored: JPEG or PNG) to `dest`.
WMC_API int wmc_media_artwork(const char *path, const char *dest) {
    @autoreleasepool {
        if (!path || !dest) return 0;
        if (wmc_ff_handles(path)) return wmc_ff_artwork(path, dest);
        NSData *picture = nil;
        more_metadata([NSURL fileURLWithPath:@(path)], NULL, &picture);
        return picture.length > 0 && [picture writeToFile:@(dest) atomically:YES] ? 1 : 0;
    }
}

// ---- playing sound --------------------------------------------------------------

@interface WmcAudio : NSObject <AVAudioPlayerDelegate>
@property(nonatomic, strong) AVAudioPlayer *player;
@property(nonatomic) void *ff;                   // FFmpeg's player, for Windows Media Audio
@property(nonatomic) BOOL ended;
@property(nonatomic) float volume;
@end

@implementation WmcAudio
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    self.ended = YES;
}
@end

static bool muted(void) {
    return getenv("WMC_MUTE") != NULL;
}

// Opens a sound file. Returns a handle, or NULL if it cannot be played.
WMC_API void *wmc_audio_open(const char *path) {
    @autoreleasepool {
        if (!path) return NULL;
        if (wmc_ff_handles(path)) {
            void *ff = wmc_ff_open(path, false);
            if (!ff) return NULL;
            WmcAudio *audio = [WmcAudio new];
            audio.ff = ff;
            audio.volume = 1;
            WLOG("snd", "opened %s with FFmpeg (%.1f s)", path, wmc_ff_duration(ff));
            return (__bridge_retained void *)audio;
        }
        NSError *error = nil;
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@(path)] error:&error];
        if (!player) {
            WLOG("snd", "cannot play %s: %s", path, error.localizedDescription.UTF8String);
            return NULL;
        }
        WmcAudio *audio = [WmcAudio new];
        audio.player = player;
        audio.volume = 1;
        player.delegate = audio;
        player.enableRate = YES;
        player.volume = muted() ? 0 : 1;
        [player prepareToPlay];
        WLOG("snd", "opened %s (%.1f s)", path, player.duration);
        return (__bridge_retained void *)audio;
    }
}

WMC_API void wmc_audio_close(void *handle) {
    if (!handle) return;
    WmcAudio *audio = (__bridge_transfer WmcAudio *)handle;
    if (audio.ff) wmc_ff_close(audio.ff);
    audio.ff = NULL;
    audio.player.delegate = nil;
    [audio.player stop];
}

WMC_API void wmc_audio_play(void *handle) {
    WmcAudio *audio = (__bridge WmcAudio *)handle;
    if (!audio) return;
    if (audio.ff) return wmc_ff_play(audio.ff);
    audio.ended = NO;
    [audio.player play];
}

WMC_API void wmc_audio_pause(void *handle) {
    WmcAudio *audio = (__bridge WmcAudio *)handle;
    if (audio.ff) return wmc_ff_pause(audio.ff);
    [audio.player pause];
}

WMC_API double wmc_audio_duration(void *handle) {
    WmcAudio *audio = (__bridge WmcAudio *)handle;
    if (audio.ff) return wmc_ff_duration(audio.ff);
    return audio ? audio.player.duration : 0;
}

WMC_API double wmc_audio_position(void *handle) {
    WmcAudio *audio = (__bridge WmcAudio *)handle;
    if (!audio) return 0;
    if (audio.ff) return wmc_ff_position(audio.ff);
    return audio.ended ? audio.player.duration : audio.player.currentTime;
}

WMC_API void wmc_audio_set_position(void *handle, double seconds) {
    WmcAudio *audio = (__bridge WmcAudio *)handle;
    if (!audio) return;
    if (audio.ff) return wmc_ff_seek(audio.ff, seconds);
    if (seconds < 0) seconds = 0;
    if (seconds > audio.player.duration) seconds = audio.player.duration;
    audio.player.currentTime = seconds;
}

// 0 not playing, 1 playing, 2 played to the end.
WMC_API int wmc_audio_state(void *handle) {
    WmcAudio *audio = (__bridge WmcAudio *)handle;
    if (!audio) return 0;
    if (audio.ff) {
        int state = wmc_ff_state(audio.ff);
        return state == 3 ? 2 : state == 2 ? 1 : 0;
    }
    if (audio.ended) return 2;
    return audio.player.isPlaying ? 1 : 0;
}

// 0 to 1.
WMC_API void wmc_audio_set_volume(void *handle, float volume) {
    WmcAudio *audio = (__bridge WmcAudio *)handle;
    if (!audio) return;
    if (audio.ff) return wmc_ff_set_volume(audio.ff, volume, 0);
    audio.volume = volume;
    audio.player.volume = muted() ? 0 : volume;
}

WMC_API void wmc_audio_set_rate(void *handle, float rate) {
    WmcAudio *audio = (__bridge WmcAudio *)handle;
    if (audio.ff && rate > 0) return wmc_ff_set_rate(audio.ff, rate);
    if (audio && rate > 0) audio.player.rate = rate;
}

// A line in the shim's log, from managed code.
WMC_API void wmc_log_line(const char *channel, const char *text) {
    if (channel && text && wmc_log_enabled(channel)) wmc_log(channel, "%s", text);
}
