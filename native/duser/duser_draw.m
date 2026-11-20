// XP Media Center Edition 2002's drawing objects (ehuihlp.dll): sessions,
// pictures, text, and the render operations visuals are drawn with. The
// framework holds them as pointers and counts its references to them
// (EhObjectAddRef/EhObjectRelease); a visual drawing an operation keeps its
// own.
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import "duser.h"
#include "paths.h"
#include "win32/gdi.h"

#ifdef WMC_XP2002

CTFontRef sp_create_font(NSString *face, CGFloat px, BOOL bold, BOOL italic);   // native/platform/fonts.m
const void *FindResourceW(HMODULE module, const WCHAR *name, const WCHAR *type);
const void *wmcapi_LoadResource(HMODULE module, const void *resInfo);
DWORD SizeofResource(HMODULE module, const void *resInfo);

typedef struct { float x, y, w, h; } DuRectF;
typedef struct { int32_t w, h; } DuSize;
typedef struct { float w, h; } DuSizeF;

// The framework's references, counted apart from ours (a visual drawing an
// operation holds its own), so that a release of something it does not hold
// is reported instead of freeing what is still in use.
static CFMutableDictionaryRef s_refs;          // pointer -> count
static pthread_mutex_t s_refs_lock = PTHREAD_MUTEX_INITIALIZER;

static intptr_t refs_add(void *p, intptr_t delta) {
    pthread_mutex_lock(&s_refs_lock);
    if (!s_refs) s_refs = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    intptr_t n = (intptr_t)CFDictionaryGetValue(s_refs, p);
    if (n > 0 || delta > 0) {
        n += delta;
        if (n > 0) CFDictionarySetValue(s_refs, p, (const void *)n);
        else CFDictionaryRemoveValue(s_refs, p);
    } else {
        n = -1;   // (not one of ours)
    }
    pthread_mutex_unlock(&s_refs_lock);
    return n;
}

void *du_object_out(id object) {
    if (!object) return NULL;
    void *p = (void *)CFBridgingRetain(object);
    refs_add(p, 1);
    return p;
}

id du_object_in(void *pointer) {
    if (!pointer) return nil;
    pthread_mutex_lock(&s_refs_lock);
    BOOL known = s_refs && CFDictionaryContainsKey(s_refs, pointer);
    pthread_mutex_unlock(&s_refs_lock);
    if (!known) {
        WLOG("err", "%p is not a drawing object", pointer);
        return nil;
    }
    return (__bridge id)pointer;
}

static CGRect rect(DuRectF r) { return CGRectMake(r.x, r.y, r.w, r.h); }

// ---- objects --------------------------------------------------------------------

@interface DuSession : NSObject
@end
@implementation DuSession
@end

@implementation DuImage
- (void)dealloc {
    if (_image) CGImageRelease(_image);
}
- (void)setImage:(CGImageRef)image {
    if (image) CGImageRetain(image);
    if (_image) CGImageRelease(_image);
    _image = image;
    _width = image ? (int)CGImageGetWidth(image) : 0;
    _height = image ? (int)CGImageGetHeight(image) : 0;
}
@end

@implementation DuOp
@end

// Text flags (ehuihlp's): 0x20 one line, cut short with an ellipsis (the
// framework's "alpha ellipses"); otherwise lines wrap at the width given.
enum { DT_CENTER = 1, DT_RIGHT = 2, TF_ELLIPSIS = 0x20 };

@implementation DuText

- (instancetype)init {
    if ((self = [super init])) {
        _text = @"";
        _face = @"Tahoma";
        _px = 16;
        _color = 0xFF000000;
        _scaleX = _scaleY = 1;
    }
    return self;
}

- (NSAttributedString *)attributed {
    CGFloat scale = _scaleY > 0 ? _scaleY : 1;
    CTFontRef font = sp_create_font(_face, _px * scale, _bold, _italic);
    uint32_t c = _color;
    CGColorRef color = CGColorCreateSRGB(((c >> 16) & 0xFF) / 255.0, ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0,
                                         (c >> 24) / 255.0);
    CTTextAlignment align = (_flags & DT_CENTER) ? kCTTextAlignmentCenter
                          : (_flags & DT_RIGHT) ? kCTTextAlignmentRight : kCTTextAlignmentLeft;
    CTLineBreakMode wrap = (_flags & TF_ELLIPSIS) ? kCTLineBreakByTruncatingTail : kCTLineBreakByWordWrapping;
    CTParagraphStyleSetting settings[] = {
        { kCTParagraphStyleSpecifierAlignment, sizeof(align), &align },
        { kCTParagraphStyleSpecifierLineBreakMode, sizeof(wrap), &wrap },
    };
    CTParagraphStyleRef para = CTParagraphStyleCreate(settings, 2);
    NSMutableDictionary *attrs = [@{
        (id)kCTFontAttributeName : (__bridge id)font,
        (id)kCTForegroundColorAttributeName : (__bridge id)color,
        (id)kCTParagraphStyleAttributeName : (__bridge id)para,
    } mutableCopy];
    if (_spacing != 0 && _spacing != 1) attrs[(id)kCTKernAttributeName] = @((_spacing - 1) * _px * scale * 0.5);
    NSAttributedString *s = [[NSAttributedString alloc] initWithString:_text ?: @"" attributes:attrs];
    CFRelease(font);
    CGColorRelease(color);
    CFRelease(para);
    return s;
}

// The text's size when laid out no wider than maxWidth (0: no limit), in
// whole pixels.
// Whether the text is drawn as one line in a given width: cut short, or
// short enough (and without line breaks).
- (BOOL)oneLine:(double)width within:(CGFloat)limit {
    if (_flags & TF_ELLIPSIS) return YES;
    if ([_text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return NO;
    return limit <= 0 || width <= limit + 0.5;
}

- (CGSize)measure:(int)maxWidth {
    NSAttributedString *s = [self attributed];
    // (one line as GDI measures it: trailing spaces count, which a frame's size leaves out)
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)s);
    CGFloat ascent = 0, descent = 0, leading = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CFRelease(line);
    if ([self oneLine:width within:maxWidth]) {
        if (maxWidth > 0 && width > maxWidth) width = maxWidth;
        return CGSizeMake(ceil(width), ceil(ascent + descent));
    }
    CTFramesetterRef fs = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)s);
    CGFloat limit = maxWidth > 0 ? maxWidth : CGFLOAT_MAX;
    CGSize size = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRangeMake(0, 0), NULL, CGSizeMake(limit, CGFLOAT_MAX), NULL);
    CFRelease(fs);
    return CGSizeMake(ceil(size.width), ceil(size.height));
}

// The text drawn into a picture of its own size (or *size, if given).
- (CGImageRef)render:(CGSize *)size {
    CGSize want = size && size->width > 0 && size->height > 0 ? *size : [self measure:0];
    int w = (int)ceil(want.width), h = (int)ceil(want.height);
    if (w <= 0 || h <= 0) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)w, (size_t)h, 8, 0, space,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!ctx) return NULL;
    uint32_t bk = _bkColor;
    if (bk >> 24) {
        CGContextSetRGBFillColor(ctx, ((bk >> 16) & 0xFF) / 255.0, ((bk >> 8) & 0xFF) / 255.0, (bk & 0xFF) / 255.0, (bk >> 24) / 255.0);
        CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    }
    NSAttributedString *s = [self attributed];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)s);
    CGFloat ascent = 0, descent = 0, leading = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    if ([self oneLine:width within:w]) {
        // One line from the top, as GDI draws it (a frame would leave out a
        // line that does not fit with its leading), cut short with an
        // ellipsis if it is wider than the space.
        if (width > w + 0.5) {
            NSDictionary *attrs = s.length ? [s attributesAtIndex:0 effectiveRange:NULL] : @{};
            NSAttributedString *dots = [[NSAttributedString alloc] initWithString:@"\u2026" attributes:attrs];
            CTLineRef ellipsis = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)dots);
            CTLineRef cut = CTLineCreateTruncatedLine(line, w, kCTLineTruncationEnd, ellipsis);
            CFRelease(ellipsis);
            if (cut) {
                CFRelease(line);
                line = cut;
                width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
            }
        }
        CGFloat x = (_flags & DT_CENTER) ? (w - width) / 2 : (_flags & DT_RIGHT) ? w - width : 0;
        CGContextSetTextPosition(ctx, x, h - ascent);
        CTLineDraw(line, ctx);
        CFRelease(line);
    } else {
        CFRelease(line);
        // Lines from the top: the frame as tall as they need.
        CTFramesetterRef fs = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)s);
        CGSize need = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRangeMake(0, 0), NULL, CGSizeMake(w, CGFLOAT_MAX), NULL);
        CGFloat tall = MAX(h, ceil(need.height) + 1);
        CGPathRef path = CGPathCreateWithRect(CGRectMake(0, h - tall, w, tall), NULL);
        CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, NULL);
        CTFrameDraw(frame, ctx);
        CFRelease(frame);
        CGPathRelease(path);
        CFRelease(fs);
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (size) *size = CGSizeMake(w, h);
    return image;
}

@end

// ---- start and end ----------------------------------------------------------------

WMC_API uint32_t EhInitialize(void **context) {
    if (context) *context = (void *)(uintptr_t)1;
    return 0;
}

WMC_API uint32_t EhUninitialize(void *context) { return 0; }

WMC_API int32_t EhObjectAddRef(void *object) {
    if (!object || du_is_surface(object)) return 0;
    intptr_t n = refs_add(object, 0);
    if (n <= 0) {
        WLOG("err", "EhObjectAddRef(%p): not a drawing object", object);
        return 0;
    }
    CFRetain(object);
    return (int32_t)refs_add(object, 1);
}

WMC_API int32_t EhObjectRelease(void *object) {
    // (EhInitialize's context is released too, and video surfaces)
    if ((uintptr_t)object <= 1 || du_is_surface(object)) return 0;
    intptr_t n = refs_add(object, -1);
    if (n < 0) {
        WLOG("err", "EhObjectRelease(%p): not a drawing object", object);
        return 0;
    }
    CFRelease(object);
    return (int32_t)n;
}

// The session the engine gives the framework when its window is ready (the
// form's load callback); the framework passes it back to make things with.
void *du_session_new(void) { return du_object_out([DuSession new]); }

// ---- pictures -------------------------------------------------------------------

static DuImage *image_from_data(NSData *data) {
    if (!data.length) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src) CFRelease(src);
    if (!image) return nil;
    DuImage *out = [DuImage new];
    out.image = image;
    CGImageRelease(image);
    return out;
}

WMC_API HRESULT EhSessionLoadImage(void *session, const WCHAR *file, void **image) {
    @autoreleasepool {
        *image = NULL;
        char *path = file ? wmc_host_path(file) : NULL;
        NSData *data = path ? [NSData dataWithContentsOfFile:@(path)] : nil;
        DuImage *img = image_from_data(data);
        if (!img) WLOG("img", "no picture in %s", path ?: "(null)");
        free(path);
        if (!img) return E_FAIL;
        *image = du_object_out(img);
        return S_OK;
    }
}

// A bitmap resource (RT_BITMAP) is a DIB without its file header: one is
// put in front so that ImageIO reads it.
static NSData *with_bitmap_header(const uint8_t *dib, uint32_t size) {
    if (size < 40) return nil;
    uint32_t headerSize = *(const uint32_t *)dib;
    uint16_t bits = *(const uint16_t *)(dib + 14);
    uint32_t colors = *(const uint32_t *)(dib + 32);
    if (bits <= 8 && colors == 0) colors = 1u << bits;
    uint32_t compression = *(const uint32_t *)(dib + 16);
    uint32_t masks = compression == 3 && headerSize == 40 ? 12 : 0;   // BI_BITFIELDS
    uint32_t offset = 14 + headerSize + masks + colors * 4;
    NSMutableData *out = [NSMutableData dataWithLength:14];
    uint8_t *h = out.mutableBytes;
    h[0] = 'B';
    h[1] = 'M';
    uint32_t total = 14 + size;
    memcpy(h + 2, &total, 4);
    memcpy(h + 10, &offset, 4);
    [out appendBytes:dib length:size];
    return out;
}

WMC_API HRESULT EhSessionLoadImageFromResource(void *session, HMODULE module, const WCHAR *name, int type, void **image) {
    @autoreleasepool {
        *image = NULL;
        const void *info = FindResourceW(module, name, (const WCHAR *)(intptr_t)type);
        const uint8_t *bytes = info ? wmcapi_LoadResource(module, info) : NULL;
        uint32_t size = info ? SizeofResource(module, info) : 0;
        if (!bytes || !size) {
            char *n = (uintptr_t)name < 0x10000 ? NULL : wmc_utf8(name);
            WLOG("img", "no resource %s (type %d)", n ?: "(number)", type);
            free(n);
            return E_FAIL;
        }
        NSData *data = type == 2 ? with_bitmap_header(bytes, size) : [NSData dataWithBytes:bytes length:size];
        DuImage *img = image_from_data(data);
        if (!img) return E_FAIL;
        *image = du_object_out(img);
        return S_OK;
    }
}

WMC_API HRESULT EhSessionLoadImageFromStream(void *session, void *stream, void **image) {
    *image = NULL;
    WLOG("todo", "EhSessionLoadImageFromStream is not written");
    return E_FAIL;
}

static CGImageRef image_from_bgra(const void *bits, int w, int h, BOOL premultiplied) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(
        (__bridge CFDataRef)[NSData dataWithBytes:bits length:(size_t)w * (size_t)h * 4]);
    CGBitmapInfo info = (premultiplied ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaFirst) | kCGBitmapByteOrder32Little;
    CGImageRef image = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, space, info, provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return image;
}

WMC_API HRESULT EhSessionCreateImageFromHBitmap(void *session, HBITMAP bitmap, WINBOOL premultiplied, void **image) {
    *image = NULL;
    int w = 0, h = 0;
    void *bits = NULL;
    if (!wmc_gdi_bitmap_get(bitmap, &w, &h, &bits) || !bits) {
        WLOG("img", "EhSessionCreateImageFromHBitmap(%p): not a bitmap", bitmap);
        return E_FAIL;
    }
    WLOG("img", "picture %dx%d from a bitmap", w, h);
    CGImageRef cg = image_from_bgra(bits, w, h, premultiplied);
    if (!cg) return E_FAIL;
    DuImage *img = [DuImage new];
    img.image = cg;
    CGImageRelease(cg);
    *image = du_object_out(img);
    return S_OK;
}

WMC_API HRESULT EhImageGetSize(void *image, DuSize *size) {
    DuImage *img = du_object_in(image);
    size->w = img.width;
    size->h = img.height;
    return img ? S_OK : E_FAIL;
}

WMC_API HRESULT EhImageCreateRenderOperation(void *image, DuRectF src, DuRectF dst, void **op) {
    DuImage *img = du_object_in(image);
    if (![img isKindOfClass:DuImage.class]) { *op = NULL; return E_FAIL; }
    DuOp *o = [DuOp new];
    o.kind = DuOpImage;
    o.image = img;
    o.src = rect(src);
    o.dst = rect(dst);
    o.hasSrc = src.w > 0 && src.h > 0;
    o.hasDst = dst.w > 0 && dst.h > 0;
    *op = du_object_out(o);
    return S_OK;
}

// ---- text -------------------------------------------------------------------------

WMC_API HRESULT EhSessionCreateText(void *session, const WCHAR *text, void **out) {
    DuText *t = [DuText new];
    if (text) {
        char *s = wmc_utf8(text);
        t.text = @(s);
        free(s);
    }
    *out = du_object_out(t);
    return S_OK;
}

static DuText *text_in(void *p) {
    DuText *t = du_object_in(p);
    return [t isKindOfClass:DuText.class] ? t : nil;
}

WMC_API HRESULT EhTextSetText(void *text, const WCHAR *s) {
    DuText *t = text_in(text);
    char *u = s ? wmc_utf8(s) : NULL;
    t.text = u ? @(u) : @"";
    free(u);
    return t ? S_OK : E_FAIL;
}

WMC_API HRESULT EhTextSetFont(void *text, HFONT font) {
    DuText *t = text_in(text);
    WmcFont *f = wmc_gdi_object_payload(font, WmcGdiFont);
    if (t && f) {
        t.face = @(f->face);
        t.px = f->px > 0 ? f->px : 16;
        t.bold = f->bold;
        t.italic = f->italic;
    }
    return t ? S_OK : E_FAIL;
}

WMC_API HRESULT EhTextSetColor(void *text, int32_t argb) { DuText *t = text_in(text); t.color = (uint32_t)argb; return t ? S_OK : E_FAIL; }
WMC_API HRESULT EhTextGetColor(void *text, int32_t *argb) { DuText *t = text_in(text); *argb = (int32_t)t.color; return t ? S_OK : E_FAIL; }
WMC_API HRESULT EhTextSetBkColor(void *text, int32_t argb) { DuText *t = text_in(text); t.bkColor = (uint32_t)argb; return t ? S_OK : E_FAIL; }
WMC_API HRESULT EhTextGetBkColor(void *text, int32_t *argb) { DuText *t = text_in(text); *argb = (int32_t)t.bkColor; return t ? S_OK : E_FAIL; }
WMC_API HRESULT EhTextSetFlags(void *text, int32_t flags) { DuText *t = text_in(text); t.flags = flags; return t ? S_OK : E_FAIL; }
WMC_API HRESULT EhTextSetCharacterSpacing(void *text, float factor) { DuText *t = text_in(text); t.spacing = factor; return t ? S_OK : E_FAIL; }
WMC_API HRESULT EhTextSetScale(void *text, DuSizeF scale) {
    DuText *t = text_in(text);
    t.scaleX = scale.w;
    t.scaleY = scale.h;
    return t ? S_OK : E_FAIL;
}

WMC_API HRESULT EhTextComputeSize(void *text, int maxWidth, DuSize *size) {
    DuText *t = text_in(text);
    CGSize s = t ? [t measure:maxWidth] : CGSizeZero;
    size->w = (int32_t)s.width;
    size->h = (int32_t)s.height;
    return t ? S_OK : E_FAIL;
}

static HRESULT text_op(void *text, const DuRectF *src, void **op) {
    DuText *t = text_in(text);
    if (!t) { *op = NULL; return E_FAIL; }
    DuOp *o = [DuOp new];
    o.kind = DuOpText;
    DuText *copy = [DuText new];   // (what it says now: the framework changes its text object later)
    copy.text = t.text; copy.face = t.face; copy.px = t.px; copy.bold = t.bold; copy.italic = t.italic;
    copy.color = t.color; copy.bkColor = t.bkColor; copy.flags = t.flags;
    copy.scaleX = t.scaleX; copy.scaleY = t.scaleY; copy.spacing = t.spacing;
    o.text = copy;
    WLOG("text", "\"%s\" %s %.0fpx%s color %08x flags %#x%s", copy.text.UTF8String, copy.face.UTF8String, copy.px,
         copy.bold ? " bold" : "", copy.color, copy.flags, src ? " (part)" : "");
    if (src) {
        o.src = rect(*src);
        o.hasSrc = src->w > 0 && src->h > 0;
    }
    *op = du_object_out(o);
    return S_OK;
}

WMC_API HRESULT EhTextCreateRenderOperation1(void *text, void **op) { return text_op(text, NULL, op); }
WMC_API HRESULT EhTextCreateRenderOperation2(void *text, DuRectF src, void **op) { return text_op(text, &src, op); }

// ---- fills and surfaces --------------------------------------------------------------

static HRESULT fill_op(int32_t argb, const DuRectF *dst, void **op) {
    DuOp *o = [DuOp new];
    o.kind = DuOpFill;
    o.color = (uint32_t)argb;
    if (dst) {
        o.dst = rect(*dst);
        o.hasDst = dst->w > 0 && dst->h > 0;
    }
    *op = du_object_out(o);
    return S_OK;
}

WMC_API HRESULT EhSessionCreateSolidFillRenderOperation1(void *session, int32_t argb, void **op) { return fill_op(argb, NULL, op); }
WMC_API HRESULT EhSessionCreateSolidFillRenderOperation2(void *session, int32_t argb, DuRectF dst, void **op) { return fill_op(argb, &dst, op); }
WMC_API HRESULT EhSessionCreateDDrawSolidFillRenderOperation(void *session, int32_t argb, DuRectF dst, void **op) { return fill_op(argb, &dst, op); }

// Video: a player's surface (the "front buffer" of full-screen video, or
// the "surface owner" of an inset one; duser_video.m).
static HRESULT surface_op(void *surface, const DuRectF *src, const DuRectF *dst, void **op) {
    *op = NULL;
    if (!du_is_surface(surface)) {
        WLOG("todo", "a video picture from %p, not a player's surface", surface);
        return E_FAIL;
    }
    DuOp *o = [DuOp new];
    o.kind = DuOpSurface;
    o.surface = (int)(intptr_t)surface;
    if (src) {
        o.src = rect(*src);
        o.hasSrc = src->w > 0 && src->h > 0;
    }
    if (dst) {
        o.dst = rect(*dst);
        o.hasDst = dst->w > 0 && dst->h > 0;
    }
    *op = du_object_out(o);
    return S_OK;
}
WMC_API HRESULT EhSessionCreateDDrawRO(void *session, void *surface, DuRectF src, DuRectF dst, void **op) { return surface_op(surface, &src, &dst, op); }
WMC_API HRESULT EhSurfaceOwnerCreateRenderOperation1(void *session, void *owner, void **op) { return surface_op(owner, NULL, NULL, op); }
WMC_API HRESULT EhSurfaceOwnerCreateRenderOperation2(void *session, void *owner, DuRectF src, DuRectF dst, void **op) { return surface_op(owner, &src, &dst, op); }

// ---- odds and ends -----------------------------------------------------------------------

// A page's title (the large faint word behind it): its text drawn into a
// 32-bit bitmap of its size. The colour is a COLORREF with an alpha in its
// top byte, and the framework reads the bitmap as not premultiplied.
WMC_API WINBOOL CreateTitleText(HFONT font, uint32_t colorref, const WCHAR *text, int *cx, int *cy, HBITMAP *bitmap) {
    @autoreleasepool {
        DuText *t = [DuText new];
        void *self = du_object_out(t);
        EhTextSetFont(self, font);
        char *s = text ? wmc_utf8(text) : NULL;
        t.text = s ? @(s) : @"";
        free(s);
        uint32_t alpha = colorref >> 24 ? colorref >> 24 : 0xFF;
        t.color = (alpha << 24) | ((colorref & 0xFF) << 16) | (colorref & 0xFF00) | ((colorref >> 16) & 0xFF);
        CGSize size = CGSizeZero;
        CGImageRef image = [t render:&size];
        CFRelease(self);
        *bitmap = NULL;
        *cx = (int)size.width;
        *cy = (int)size.height;
        if (!image) return FALSE;
        void *bits = NULL;
        HBITMAP bmp = wmc_gdi_bitmap_create(*cx, *cy, &bits);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(bits, (size_t)*cx, (size_t)*cy, 8, (size_t)*cx * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(space);
        CGContextDrawImage(ctx, CGRectMake(0, 0, *cx, *cy), image);
        CGContextRelease(ctx);
        CGImageRelease(image);
        uint8_t *px = bits;   // (B G R A, premultiplied: undo it)
        for (size_t i = 0, n = (size_t)*cx * (size_t)*cy; i < n; i++, px += 4) {
            unsigned a = px[3];
            if (a == 0 || a == 255) continue;
            for (int k = 0; k < 3; k++) px[k] = (uint8_t)MIN(255u, (px[k] * 255u + a / 2) / a);
        }
        *bitmap = bmp;
        return bmp != NULL;
    }
}

WMC_API void EhGenerateCaptionButton(void *theme, HBITMAP *bitmap, int button, int state, int l, int t, int r, int b) {
    *bitmap = NULL;
}

WMC_API int32_t EhEnableCloth(WINBOOL enable) { return 0; }

#endif
