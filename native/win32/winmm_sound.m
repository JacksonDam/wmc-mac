// winmm: PlaySound, for the interface sounds of XP Media Center Edition
// 2005. Its theme keeps them as WAVE resources; it plays them with
// PlaySound (SND_RESOURCE), directly or through the engine
// (DesktopManager.PlaySound, sp_window.m). Windows 7 and Vista play theirs
// through the engine's sound classes (sp_sound.m) instead.
//
// As on Windows, one sound plays at a time: a new one stops the old, unless
// SND_NOSTOP is given (then the new one is not played while another is).
#import <AVFoundation/AVFoundation.h>
#include "win32.h"
#include "paths.h"

#ifdef WMC_XP

enum {
    SND_ASYNC = 0x1, SND_MEMORY = 0x4, SND_LOOP = 0x8, SND_NOSTOP = 0x10, SND_PURGE = 0x40,
    SND_FILENAME = 0x20000, SND_RESOURCE = 0x40004,
};

const void *FindResourceW(HMODULE module, const WCHAR *name, const WCHAR *type);
const void *wmcapi_LoadResource(HMODULE module, const void *resInfo);
DWORD SizeofResource(HMODULE module, const void *resInfo);

static AVAudioPlayer *s_playing;   // (main thread only)

static NSData *resource_bytes(HMODULE module, const WCHAR *name) {
    static const WCHAR wave[] = { 'W', 'A', 'V', 'E', 0 };
    const void *info = FindResourceW(module, name, wave);
    const void *bytes = info ? wmcapi_LoadResource(module, info) : NULL;
    DWORD size = info ? SizeofResource(module, info) : 0;
    return bytes && size ? [NSData dataWithBytes:bytes length:size] : nil;
}

// name: UTF-16, or a resource number below 0x10000.
WINBOOL wmc_play_sound(const WCHAR *name, HMODULE module, DWORD flags) {
    BOOL stop = !name || (flags & SND_PURGE);
    NSData *data = nil;
    if (!stop) {
        if ((flags & SND_RESOURCE) == SND_RESOURCE) {
            data = resource_bytes(module, name);
        } else if (flags & SND_MEMORY) {
            data = nil;   // (not used by Media Center)
        } else {
            char *mac = (uintptr_t)name < 0x10000 ? NULL : wmc_host_path(name);
            if (mac) data = [NSData dataWithContentsOfFile:@(mac)];
            free(mac);
        }
        if (!data) {
            char *n = (uintptr_t)name < 0x10000 ? NULL : wmc_utf8(name);
            WLOG("snd", "PlaySound: no sound %s (flags %#x)", n ? n : "(number)", flags);
            free(n);
            return FALSE;
        }
    }
    BOOL loop = (flags & SND_LOOP) != 0, nostop = (flags & SND_NOSTOP) != 0;
    __block BOOL played = YES;
    void (^work)(void) = ^{
        if (stop) {
            [s_playing stop];
            s_playing = nil;
            return;
        }
        if (nostop && s_playing.playing) {
            played = NO;
            return;
        }
        NSError *error = nil;
        AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:data error:&error];
        if (!p) {
            WLOG("snd", "PlaySound: %s", error.localizedDescription.UTF8String);
            played = NO;
            return;
        }
        if (getenv("WMC_MUTE")) p.volume = 0;
        WLOG("snd", "PlaySound: %.2f s%s", p.duration, loop ? ", looping" : "");
        p.numberOfLoops = loop ? -1 : 0;
        [s_playing stop];
        s_playing = p;
        [p play];
    };
    if ([NSThread isMainThread]) work();
    else if (flags & SND_ASYNC) dispatch_async(dispatch_get_main_queue(), work);
    else dispatch_sync(dispatch_get_main_queue(), work);
    return played;
}

// Declared with no character set: the name arrives as UTF-8 (Mono's ANSI).
WMC_API WINBOOL PlaySound(const char *name, HMODULE module, DWORD flags) {
    if ((uintptr_t)name < 0x10000) return wmc_play_sound((const WCHAR *)name, module, flags);
    WCHAR *w = wmc_utf16(name);
    WINBOOL r = wmc_play_sound(w, module, flags);
    free(w);
    return r;
}

WMC_API WINBOOL PlaySoundW(const WCHAR *name, HMODULE module, DWORD flags) {
    return wmc_play_sound(name, module, flags);
}

#endif
