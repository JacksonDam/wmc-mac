// ehuihlp: small pictures of files, for the picture and video libraries.
//
// Media Center asks for a thumbnail no larger than a box and takes it as
// 24-bit pixels (blue, green, red), top row first, rows padded to four
// bytes. Pictures are scaled by ImageIO (which also turns them upright);
// videos give a frame from near their start through AVFoundation.
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "platform/ffmedia.h"
#include "wmc.h"
#include "paths.h"


static NSURL *url_for(const WCHAR *file) {
    char *path = wmc_host_path(file);
    if (!path) return nil;
    NSURL *url = [NSURL fileURLWithPath:@(path)];
    free(path);
    return url;
}

static bool is_video(NSURL *url) {
    NSString *ext = url.pathExtension.lowercaseString;
    return [@[ @"mp4", @"m4v", @"mov", @"wmv", @"asf", @"avi", @"divx" ] containsObject:ext];
}

// A frame from a video, about a tenth of the way in (the first frames are
// often black).
static CGImageRef video_frame(NSURL *url, int box) {
    if (wmc_ff_handles(url.path.UTF8String)) return wmc_ff_thumbnail(url.path.UTF8String, box);
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(box, box);
    __block CGImageRef result = NULL;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:@[ @"duration" ] completionHandler:^{
        CMTime at = CMTimeMultiplyByFloat64(asset.duration, 0.1);
        if (!CMTIME_IS_NUMERIC(at)) at = kCMTimeZero;
        [generator generateCGImagesAsynchronouslyForTimes:@[ [NSValue valueWithCMTime:at] ]
                                         completionHandler:^(CMTime requested, CGImageRef image, CMTime actual,
                                                             AVAssetImageGeneratorResult status, NSError *error) {
            if (status == AVAssetImageGeneratorSucceeded && image) result = CGImageRetain(image);
            dispatch_semaphore_signal(done);
        }];
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
    return result;
}

// The picture in a file, no larger than `box` on its longer side (0: whole),
// upright. The caller releases it. Also gives the full size.
static CGImageRef load_image(NSURL *url, int box, int *fullWidth, int *fullHeight) {
    if (is_video(url)) {
        CGImageRef frame = video_frame(url, box > 0 ? box : 1024);
        if (frame) {
            if (fullWidth) *fullWidth = (int)CGImageGetWidth(frame);
            if (fullHeight) *fullHeight = (int)CGImageGetHeight(frame);
        }
        return frame;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return NULL;
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    int w = [props[(id)kCGImagePropertyPixelWidth] intValue], h = [props[(id)kCGImagePropertyPixelHeight] intValue];
    int orientation = [props[(id)kCGImagePropertyOrientation] intValue];
    if (orientation >= 5) { int t = w; w = h; h = t; }   // turned on its side
    if (fullWidth) *fullWidth = w;
    if (fullHeight) *fullHeight = h;
    int longest = w > h ? w : h;
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @(box > 0 && box < longest ? box : (longest > 0 ? longest : 4096)),
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

// Draws an image into 24-bit rows of the given size. malloc'd.
static uint8_t *to_bgr24(CGImageRef image, int width, int height, int *bytes) {
    int stride = (width * 3 + 3) & ~3;
    uint8_t *rgba = calloc((size_t)width * height, 4);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(rgba, width, height, 8, width * 4, space,
                                             (CGBitmapInfo)kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) { free(rgba); return NULL; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
    CGContextRelease(ctx);
    uint8_t *out = calloc((size_t)stride * height, 1);
    for (int y = 0; y < height; y++) {
        const uint8_t *s = rgba + (size_t)y * width * 4;
        uint8_t *d = out + (size_t)y * stride;
        for (int x = 0; x < width; x++, s += 4, d += 3) { d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; }
    }
    free(rgba);
    *bytes = stride * height;
    return out;
}

// The size that fits (w, h) inside the box, keeping its shape.
static void fit(int w, int h, int boxW, int boxH, int *outW, int *outH) {
    if (boxW <= 0) boxW = w;
    if (boxH <= 0) boxH = h;
    double scale = fmin((double)boxW / w, (double)boxH / h);
    if (scale > 1) scale = 1;
    *outW = (int)fmax(1, floor(w * scale + 0.5));
    *outH = (int)fmax(1, floor(h * scale + 0.5));
}

static int32_t thumbnail(const WCHAR *file, int *cx, int *cy, int *fullW, int *fullH, int *bytes, void **data) {
    @autoreleasepool {
        if (data) *data = NULL;
        if (bytes) *bytes = 0;
        if (!file || !cx || !cy || !data || !bytes) return E_FAIL;
        NSURL *url = url_for(file);
        if (!url) return E_FAIL;
        int box = *cx > *cy ? *cx : *cy;
        int w = 0, h = 0;
        CGImageRef image = load_image(url, box, &w, &h);
        if (!image) {
            WLOG("img", "no thumbnail for %s", url.path.UTF8String);
            return E_FAIL;
        }
        if (fullW) *fullW = w;
        if (fullH) *fullH = h;
        int outW, outH;
        fit((int)CGImageGetWidth(image), (int)CGImageGetHeight(image), *cx, *cy, &outW, &outH);
        *data = to_bgr24(image, outW, outH, bytes);
        CGImageRelease(image);
        if (!*data) return E_FAIL;
        *cx = outW;
        *cy = outH;
        WLOG("img", "thumbnail %dx%d of %s", outW, outH, url.lastPathComponent.UTF8String);
        return S_OK;
    }
}

// Windows keeps thumbnails in a cache of its own; here one is simply made.
WMC_API int32_t EhGetThumbnailFromShellCache(const WCHAR *file, WINBOOL extract, int *cx, int *cy, int *bytes, void **data) {
    return thumbnail(file, cx, cy, NULL, NULL, bytes, data);
}

WMC_API int32_t EhExtractBitmap(const WCHAR *file, WINBOOL forceAspect, int *cx, int *cy, int *fullW, int *fullH, int *bytes, void **data) {
    return thumbnail(file, cx, cy, fullW, fullH, bytes, data);
}

WMC_API void EhReleaseBitmapBuffer(void *data) {
    free(data);
}

// 0: not protected. Nothing here can be.
WMC_API int EhGetDRMStatusInfo(const WCHAR *file) {
    return 0;
}

// ---- image handles: a picture file opened for its size (and for printing) -------

typedef struct {
    uint32_t magic;
    int width, height;
    WCHAR *file;          // for EhCreateBitmapFromImageData
    void *pixels;         // its result, kept until the handle is cleaned up
} WmcImageData;
#define WMC_IMAGE_MAGIC 0x44474d49u   // 'IMGD'

WMC_API int32_t EhCreateImageDataHandle(const WCHAR *file, void **handle) {
    @autoreleasepool {
        if (handle) *handle = NULL;
        NSURL *url = file ? url_for(file) : nil;
        if (!url || !handle) return E_FAIL;
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!source) return E_FAIL;
        NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        CFRelease(source);
        int w = [props[(id)kCGImagePropertyPixelWidth] intValue], h = [props[(id)kCGImagePropertyPixelHeight] intValue];
        if (w <= 0 || h <= 0) return E_FAIL;
        if ([props[(id)kCGImagePropertyOrientation] intValue] >= 5) { int t = w; w = h; h = t; }
        WmcImageData *d = calloc(1, sizeof *d);
        d->magic = WMC_IMAGE_MAGIC;
        d->width = w;
        d->height = h;
        size_t n = 0;
        while (file[n]) n++;
        d->file = malloc((n + 1) * sizeof(WCHAR));
        memcpy(d->file, file, (n + 1) * sizeof(WCHAR));
        *handle = d;
        return S_OK;
    }
}

// Vista's pictures (slide shows, the library) are decoded through an image
// handle: 24-bit rows fitted into cx x cy, the bottom row first as in a
// Windows bitmap (the callers say so with a negative stride). The rows
// belong to the handle; no GDI bitmap is made (hbmp 0, which the caller
// allows).
WMC_API int32_t EhCreateBitmapFromImageData(void *handle, WINBOOL forceAspect, int *cx, int *cy, int *fullW, int *fullH,
                                            void **data, void **hbmp) {
    WmcImageData *d = handle;
    if (data) *data = NULL;
    if (hbmp) *hbmp = NULL;
    if (!d || d->magic != WMC_IMAGE_MAGIC || !data) return E_FAIL;
    free(d->pixels);
    d->pixels = NULL;
    int bytes = 0;
    int32_t hr = thumbnail(d->file, cx, cy, fullW, fullH, &bytes, &d->pixels);
    if (hr == S_OK && d->pixels) {
        int stride = (*cx * 3 + 3) & ~3;
        uint8_t *rows = d->pixels, *tmp = malloc((size_t)stride);
        for (int top = 0, bottom = *cy - 1; top < bottom; top++, bottom--) {
            memcpy(tmp, rows + (size_t)top * stride, (size_t)stride);
            memcpy(rows + (size_t)top * stride, rows + (size_t)bottom * stride, (size_t)stride);
            memcpy(rows + (size_t)bottom * stride, tmp, (size_t)stride);
        }
        free(tmp);
    }
    *data = d->pixels;
    return hr;
}

WMC_API int32_t EhGetImageDataSize(void *handle, int *cx, int *cy) {
    WmcImageData *d = handle;
    if (!d || d->magic != WMC_IMAGE_MAGIC) return E_FAIL;
    if (cx) *cx = d->width;
    if (cy) *cy = d->height;
    return S_OK;
}

WMC_API int32_t EhCleanupImageDataHandle(void *handle) {
    WmcImageData *d = handle;
    if (!d || d->magic != WMC_IMAGE_MAGIC) return E_FAIL;
    d->magic = 0;
    free(d->file);
    free(d->pixels);
    free(d);
    return S_OK;
}

// ---- for the managed stand-ins ----------------------------------------------------

#import <Accelerate/Accelerate.h>

// Copies a rectangle of one 32-bit picture into a rectangle of another,
// scaling it, and makes the result opaque. Both are rows from the top.
WMC_API void wmc_image_scale_blit(const uint8_t *src, int srcStride, int srcWidth, int srcHeight, int sx, int sy, int sw, int sh,
                                  uint8_t *dst, int dstStride, int dstWidth, int dstHeight, int dx, int dy, int dw, int dh) {
    if (!src || !dst) return;
    if (sx < 0) { sw += sx; sx = 0; }
    if (sy < 0) { sh += sy; sy = 0; }
    if (sx + sw > srcWidth) sw = srcWidth - sx;
    if (sy + sh > srcHeight) sh = srcHeight - sy;
    if (dx < 0 || dy < 0 || dx + dw > dstWidth || dy + dh > dstHeight || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return;
    vImage_Buffer from = { (void *)(src + (size_t)sy * (size_t)srcStride + (size_t)sx * 4), (vImagePixelCount)sh, (vImagePixelCount)sw, (size_t)srcStride };
    vImage_Buffer to = { dst + (size_t)dy * (size_t)dstStride + (size_t)dx * 4, (vImagePixelCount)dh, (vImagePixelCount)dw, (size_t)dstStride };
    if (vImageScale_ARGB8888(&from, &to, NULL, kvImageHighQualityResampling) != kvImageNoError) return;
    for (int y = 0; y < dh; y++) {
        uint8_t *row = dst + (size_t)(dy + y) * (size_t)dstStride + (size_t)dx * 4;
        for (int x = 0; x < dw; x++) row[x * 4 + 3] = 0xFF;
    }
}
