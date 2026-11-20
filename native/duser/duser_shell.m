// XP Media Center Edition 2002's own helpers in ehuihlp.dll that the other
// Media Centers do not have: the photo thumbnail cache, screen sizes.
#import <AppKit/AppKit.h>
#include "wmc.h"
#include "win32/gdi.h"

#ifdef WMC_XP2002

// ---- photo thumbnails ------------------------------------------------------------
//
// My Pictures keeps the thumbnails it has made in a cache (on Windows a file
// in the user's profile), keyed by a picture's path and a number (its size
// and date). Here it is kept in memory for as long as Media Center runs: a
// copy of each bitmap stored, and a copy of it handed out (which the caller
// gives back with PhotoDisposeHbitmap).

enum { PHOTO_CACHE_MAX = 1024 };

@interface DuPhotoCache : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *bitmaps;   // key -> w, h, data, pixels
@property (nonatomic, strong) NSMutableArray<NSString *> *order;
@end
@implementation DuPhotoCache
@end

static NSString *photo_key(const WCHAR *name, uint32_t u) {
    char *s = name ? wmc_utf8(name) : NULL;
    NSString *key = [NSString stringWithFormat:@"%s|%u", s ?: "", u];
    free(s);
    return key;
}

WMC_API void *PhotoCreateCache(const WCHAR *file, uint16_t size) {
    DuPhotoCache *c = [DuPhotoCache new];
    c.bitmaps = [NSMutableDictionary dictionary];
    c.order = [NSMutableArray array];
    return (void *)CFBridgingRetain(c);
}

WMC_API void PhotoDispose(void *handle) {
    if (handle) CFRelease(handle);
}

typedef struct { int32_t w, h; int16_t data; } DuPhotoHeader;

WMC_API HBITMAP PhotoHbitmapFromNameUInt(void *handle, const WCHAR *name, uint32_t u, int16_t *data) {
    if (!handle) return NULL;
    DuPhotoCache *c = (__bridge DuPhotoCache *)handle;
    NSData *entry;
    @synchronized (c) { entry = c.bitmaps[photo_key(name, u)]; }
    if (!entry) return NULL;
    const DuPhotoHeader *h = entry.bytes;
    void *bits = NULL;
    HBITMAP bmp = wmc_gdi_bitmap_create(h->w, h->h, &bits);
    if (!bmp) return NULL;
    memcpy(bits, (const uint8_t *)entry.bytes + sizeof(*h), (size_t)h->w * (size_t)h->h * 4);
    if (data) *data = h->data;
    return bmp;
}

WMC_API void PhotoStoreHbitmap(void *handle, const WCHAR *name, uint32_t u, HBITMAP bitmap, int16_t data) {
    int w = 0, h = 0;
    void *bits = NULL;
    if (!handle || !wmc_gdi_bitmap_get(bitmap, &w, &h, &bits) || !bits) return;
    DuPhotoCache *c = (__bridge DuPhotoCache *)handle;
    DuPhotoHeader header = { w, h, data };
    NSMutableData *entry = [NSMutableData dataWithBytes:&header length:sizeof(header)];
    [entry appendBytes:bits length:(size_t)w * (size_t)h * 4];
    NSString *key = photo_key(name, u);
    @synchronized (c) {
        if (!c.bitmaps[key]) [c.order addObject:key];
        c.bitmaps[key] = entry;
        while (c.order.count > PHOTO_CACHE_MAX) {
            [c.bitmaps removeObjectForKey:c.order.firstObject];
            [c.order removeObjectAtIndex:0];
        }
    }
}

WMC_API void PhotoDisposeHbitmap(void *handle, HBITMAP bitmap) {
    if (bitmap) DeleteObject(bitmap);
}

WMC_API WINBOOL PhotoFDoHousekeeping(void *handle) { return FALSE; }   // (nothing left to tidy)

// ---- screens ---------------------------------------------------------------------------
//
// The size of the screen a window is on, and of its working area (without
// the menu bar and the Dock), in pixels. Media Center sizes its full-screen
// pictures and its window by them.

static NSScreen *screen_of(HWND window) {
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

static void screen_size(BOOL working, int *dx, int *dy) {
    if (getenv("WMC_HEADLESS")) {
        // (offscreen: the screen is the size maximised windows are, duser_agent.m)
        int w = 1024, h = 768;
        const char *size = getenv("WMC_HEADLESS_SIZE");
        if (size) sscanf(size, "%dx%d", &w, &h);
        if (dx) *dx = w;
        if (dy) *dy = h;
        return;
    }
    __block NSRect frame = NSZeroRect;
    __block CGFloat scale = 1;
    void (^read)(void) = ^{
        NSScreen *s = screen_of(NULL);
        frame = working ? s.visibleFrame : s.frame;
        scale = s.backingScaleFactor ?: 1;
    };
    if ([NSThread isMainThread]) read();
    else dispatch_sync(dispatch_get_main_queue(), read);
    if (frame.size.width <= 0) frame.size = NSMakeSize(1024, 768);   // (offscreen with no screen)
    if (dx) *dx = (int)lround(frame.size.width * scale);
    if (dy) *dy = (int)lround(frame.size.height * scale);
}

WMC_API void GetScreenDimensions(HWND window, int *dx, int *dy) { screen_size(NO, dx, dy); }
WMC_API void GetWorkingAreaDimensions(HWND window, int *dx, int *dy) { screen_size(YES, dx, dy); }
WMC_API void *MonitorFromDeviceNameW(const WCHAR *name) { return (void *)(uintptr_t)1; }

#endif
