// Images: the SpBitmapLoad* functions.
//
// The framework asks the engine to decode a picture (from a file, a memory
// buffer, a resource in a DLL, or raw pixels) and gets back its size and a
// pointer to 32-bit B G R A pixels with straight alpha, top row first. It
// then uploads those pixels to a surface itself. Decoding is ImageIO's job.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include "wmc.h"
#include "paths.h"
#include "splash_protocol.h"
#include "win32/module.h"

typedef struct { int32_t w, h; } SpSizeI;
typedef struct Sp_RenderApi_ImageInformation SpImageInfo;
// XP Media Center Edition's image information is flat; Windows 7's and
// Vista's keep the size and format in a Header and the pixels in Data.
#ifdef WMC_XP
#define IMG_HEADER(i) (*(i))
#define IMG_DATA(i) (*(i))
#else
#define IMG_HEADER(i) ((i)->Header)
#define IMG_DATA(i) ((i)->Data)
#endif
typedef struct Sp_ImageRequirements SpImageReq;

enum { SpBitmapDecode = 1, SpBitmapFlip = 2 };
enum { SpReqMaximumSize = 1, SpReqBorder = 2, SpReqFlippable = 4, SpReqFilterSet = 8 };
#define SP_FORMAT_ARGB32 2132104u

typedef struct {
    uint32_t magic;
    void *pixels;
} SpBitmap;
#define SP_BITMAP_MAGIC 0x504D4253u

static HRESULT finish(CGImageSourceRef source, const SpImageReq *req, int options, void **handle,
                      SpImageInfo *info) {
    memset(info, 0, sizeof(*info));
    *handle = NULL;
    if (!source) return (HRESULT)0x800401A4;   // "file could not be found"
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return E_FAIL;
    int ow = (int)CGImageGetWidth(image), oh = (int)CGImageGetHeight(image);
    int w = ow, h = oh;
    // The framework may cap the size (textures have a maximum).
    if (req && (req->nMask & SpReqMaximumSize) && req->sizeMaximumPxl.m_width > 0 && req->sizeMaximumPxl.m_height > 0) {
        double s = fmin(1.0, fmin((double)req->sizeMaximumPxl.m_width / w, (double)req->sizeMaximumPxl.m_height / h));
        if (s < 1.0) {
            w = MAX(1, (int)floor(w * s));
            h = MAX(1, (int)floor(h * s));
        }
    }
    IMG_HEADER(info).sizeActualPxl.m_width = w;
    IMG_HEADER(info).sizeActualPxl.m_height = h;
    IMG_HEADER(info).sizeOriginalPxl.m_width = ow;
    IMG_HEADER(info).sizeOriginalPxl.m_height = oh;
    IMG_HEADER(info).nStride = w * 4;
    IMG_HEADER(info).nFormat = SP_FORMAT_ARGB32;

    SpBitmap *bmp = calloc(1, sizeof(*bmp));
    bmp->magic = SP_BITMAP_MAGIC;
    if (options & SpBitmapDecode) {
        uint32_t *pixels = calloc((size_t)w * (size_t)h, 4);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(pixels, (size_t)w, (size_t)h, 8, (size_t)w * 4, space,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        if (options & SpBitmapFlip) {
            CGContextTranslateCTM(ctx, 0, h);
            CGContextScaleCTM(ctx, 1, -1);
        }
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
        CGContextRelease(ctx);
        CGColorSpaceRelease(space);
        // Core Graphics draws premultiplied; the engine blends straight alpha.
        for (size_t i = 0; i < (size_t)w * (size_t)h; i++) {
            uint32_t p = pixels[i], a = p >> 24;
            if (a != 0 && a != 255) {
                uint32_t r = MIN(255u, ((p >> 16) & 0xFF) * 255 / a), g = MIN(255u, ((p >> 8) & 0xFF) * 255 / a),
                         b = MIN(255u, (p & 0xFF) * 255 / a);
                pixels[i] = a << 24 | r << 16 | g << 8 | b;
            }
        }
        bmp->pixels = pixels;
        IMG_DATA(info).rgData = (int64_t)(intptr_t)pixels;
    }
    CGImageRelease(image);
    *handle = bmp;
    return S_OK;
}

WMC_API HRESULT SpBitmapLoadBuffer(const void *src, uint32_t size, const SpImageReq *req, int options, void **handle,
                                   SpImageInfo *info) {
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:src length:size];
        return finish(CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL), req, options, handle, info);
    }
}

WMC_API HRESULT SpBitmapLoadFileW(const WCHAR *file, const SpImageReq *req, int options, void **handle,
                                  SpImageInfo *info) {
    @autoreleasepool {
        char *host = wmc_host_path(file);
        NSURL *url = [NSURL fileURLWithPath:@(host)];
        WLOG("img", "load file %s", host);
        free(host);
        return finish(CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL), req, options, handle, info);
    }
}

// `type` is a resource type: a small integer (10 = RCDATA) or a string.
WMC_API HRESULT SpBitmapLoadResourceW(HMODULE module, const WCHAR *name, const WCHAR *type, const SpImageReq *req,
                                      int options, void **handle, SpImageInfo *info) {
    @autoreleasepool {
        memset(info, 0, sizeof(*info));
        *handle = NULL;
        WmcModule *m = wmc_module_from_handle(module);
        const void *entry = m ? wmc_module_find_resource(m, type, name, 0) : NULL;
        uint32_t size = 0;
        const void *bytes = entry ? wmc_resource_data(entry, &size) : NULL;
        if (!bytes) {
            char *n = (uintptr_t)name < 0x10000 ? NULL : wmc_utf8(name);
            WLOG("img", "resource image %s not found in %s", n ? n : "(by id)", m ? wmc_module_name(m) : "(no module)");
            free(n);
            return (HRESULT)0x800401A4;
        }
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
        return finish(CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL), req, options, handle, info);
    }
}

// Raw pixels the framework already has: hand back a copy as 32-bit B G R A
// rows from the top, the shape every decoded picture has (the framework's
// colour filters, applied after this, read four bytes a pixel).
WMC_API HRESULT SpBitmapLoadRaw(SpSizeI size, int stride, uint32_t format, const void *data, const SpImageReq *req,
                                int options, void **handle, SpImageInfo *info) {
    memset(info, 0, sizeof(*info));
    int w = size.w, h = size.h;
    IMG_HEADER(info).sizeActualPxl.m_width = IMG_HEADER(info).sizeOriginalPxl.m_width = w;
    IMG_HEADER(info).sizeActualPxl.m_height = IMG_HEADER(info).sizeOriginalPxl.m_height = h;
    IMG_HEADER(info).nStride = w * 4;
    IMG_HEADER(info).nFormat = SP_FORMAT_ARGB32;
    SpBitmap *bmp = calloc(1, sizeof(*bmp));
    bmp->magic = SP_BITMAP_MAGIC;
    if ((options & SpBitmapDecode) && data && w > 0 && h > 0) {
        bool is24 = (format & 0x00FF0000) == 0x00180000;
        bool opaque = (format & 0xFFFF) == 0x1808 || format == 2099336u;   // RGB32: the alpha byte is unused
        int rowBytes = stride < 0 ? -stride : stride;
        uint32_t *out = malloc((size_t)w * (size_t)h * 4);
        for (int r = 0; r < h; r++) {
            const uint8_t *src = (const uint8_t *)data + (size_t)(stride < 0 ? h - 1 - r : r) * (size_t)rowBytes;
            uint32_t *dst = out + (size_t)r * (size_t)w;
            if (is24) {
                for (int c = 0; c < w; c++)
                    dst[c] = 0xFF000000u | (uint32_t)src[c * 3 + 2] << 16 | (uint32_t)src[c * 3 + 1] << 8 | src[c * 3];
            } else {
                memcpy(dst, src, (size_t)w * 4);
                if (opaque)
                    for (int c = 0; c < w; c++) dst[c] |= 0xFF000000u;
            }
        }
        bmp->pixels = out;
        IMG_DATA(info).rgData = (int64_t)(intptr_t)out;
    }
    *handle = bmp;
    return S_OK;
}

WMC_API HRESULT SpBitmapDelete(void *handle) {
    SpBitmap *bmp = handle;
    if (!bmp || bmp->magic != SP_BITMAP_MAGIC) return S_OK;
    bmp->magic = 0;
    free(bmp->pixels);
    free(bmp);
    return S_OK;
}
