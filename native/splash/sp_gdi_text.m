// GDI text: fonts, memory device contexts, and drawing strings into bitmaps.
//
// The older parts of Media Center's UI do not use the rich-text functions.
// They create a GDI font, select it and a bitmap into a memory device
// context, measure with GetTextExtentPoint32 or a "calculate" DrawText, draw
// white on black (or black on white), and then ask the engine to turn that
// picture into coloured text with alpha (SpTrueTypeProcess*).
//
// With Direct3D the framework asks for 4x oversampled text (the font it
// creates is four times too tall and the engine shrinks the result). Here
// Core Text antialiases directly, so the "AA" functions draw at the font's
// height divided by the scale they are given.
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#include "wmc.h"
#include "win32/gdi.h"

CTFontRef sp_create_font(NSString *face, CGFloat px, BOOL bold, BOOL italic);

typedef struct { int32_t left, top, right, bottom; } WRECT;   // (Windows' RECT)
typedef struct { int32_t cx, cy; } WSIZE;
typedef struct { int32_t a; uint32_t b; int32_t c; } WABC;
typedef struct { int32_t w, h; } SpSizeI;

typedef struct {
    int32_t lfHeight, lfWidth, lfEscapement, lfOrientation, lfWeight;
    uint8_t lfItalic, lfUnderline, lfStrikeOut, lfCharSet, lfOutPrecision, lfClipPrecision, lfQuality, lfPitchAndFamily;
    WCHAR lfFaceName[32];
} WLOGFONTW;
_Static_assert(sizeof(WLOGFONTW) == 92, "LOGFONTW layout");

typedef struct {
    HGDIOBJ bitmap, font;
    uint32_t textColor, bkColor;   // COLORREF: 0x00BBGGRR
    int bkMode;                    // 1 transparent, 2 opaque
    uint32_t align;                // TA_RIGHT 2, TA_CENTER 6
    int charExtra;
} WmcDC;

enum { DT_CENTER = 1, DT_RIGHT = 2, DT_WORDBREAK = 0x10, DT_SINGLELINE = 0x20, DT_CALCRECT = 0x400 };
enum { ETO_OPAQUE = 2, ETO_CLIPPED = 4 };
enum { TA_RIGHT = 2, TA_CENTER = 6 };

static WmcDC *dc_of(HDC hdc) { return wmc_gdi_object_payload(hdc, WmcGdiDC); }

// ---- objects --------------------------------------------------------------------

WMC_API HFONT CreateFontIndirectW(const WLOGFONTW *lf) {
    if (!lf) return NULL;
    WmcFont *f = calloc(1, sizeof(*f));
    char *face = wmc_utf8n(lf->lfFaceName, wmc_wcslen(lf->lfFaceName) < 32 ? wmc_wcslen(lf->lfFaceName) : 31);
    strlcpy(f->face, face, sizeof(f->face));
    free(face);
    f->px = (float)(lf->lfHeight < 0 ? -lf->lfHeight : lf->lfHeight);
    if (f->px < 1) f->px = 12;
    f->bold = lf->lfWeight >= 600;
    f->italic = lf->lfItalic != 0;
    return (HFONT)wmc_gdi_object_create(WmcGdiFont, f, NULL);
}

WMC_API HDC CreateCompatibleDC(HDC other) {
    WmcDC *dc = calloc(1, sizeof(*dc));
    dc->textColor = 0;
    dc->bkColor = 0x00FFFFFF;
    dc->bkMode = 2;
    return (HDC)wmc_gdi_object_create(WmcGdiDC, dc, NULL);
}

WMC_API WINBOOL DeleteDC(HDC hdc) { return dc_of(hdc) ? DeleteObject(hdc) : FALSE; }

// The stock objects are placeholders: Media Center selects them only to
// restore a DC's previous state.
WMC_API HGDIOBJ GetStockObject(int index) {
    static HGDIOBJ stock[32];
    if (index < 0 || index >= 32) return NULL;
    if (!stock[index]) stock[index] = wmc_gdi_object_create(WmcGdiStock, calloc(1, 8), NULL);
    return stock[index];
}

WMC_API HGDIOBJ SelectObject(HDC hdc, HGDIOBJ object) {
    WmcDC *dc = dc_of(hdc);
    if (!dc) return NULL;
    HGDIOBJ old = NULL;
    switch (wmc_gdi_object_kind(object)) {
        case WmcGdiBitmap: old = dc->bitmap; dc->bitmap = object; break;
        case WmcGdiFont: old = dc->font; dc->font = object; break;
        default:
            // Restoring "the object that was there before" when there was none.
            if (!object) return NULL;
            return object;
    }
    // Windows returns the previously selected object; a DC starts with stock ones.
    return old ? old : GetStockObject(object == dc->bitmap ? 21 : 13);
}

WMC_API int SetTextCharacterExtra(HDC hdc, int extra) {
    WmcDC *dc = dc_of(hdc);
    if (!dc) return (int)0x80000000;
    int old = dc->charExtra;
    dc->charExtra = extra;
    return old;
}

WMC_API int SetBkMode(HDC hdc, int mode) {
    WmcDC *dc = dc_of(hdc);
    if (!dc) return 0;
    int old = dc->bkMode;
    dc->bkMode = mode;
    return old;
}

WMC_API uint32_t SetBkColor(HDC hdc, uint32_t color) {
    WmcDC *dc = dc_of(hdc);
    if (!dc) return 0xFFFFFFFF;
    uint32_t old = dc->bkColor;
    dc->bkColor = color & 0x00FFFFFF;
    return old;
}

WMC_API uint32_t SetTextColor(HDC hdc, uint32_t color) {
    WmcDC *dc = dc_of(hdc);
    if (!dc) return 0xFFFFFFFF;
    uint32_t old = dc->textColor;
    dc->textColor = color & 0x00FFFFFF;
    return old;
}

WMC_API uint32_t SetTextAlign(HDC hdc, uint32_t mode) {
    WmcDC *dc = dc_of(hdc);
    if (!dc) return 0xFFFFFFFF;
    uint32_t old = dc->align;
    dc->align = mode;
    return old;
}

WMC_API uint32_t GetTextAlign(HDC hdc) {
    WmcDC *dc = dc_of(hdc);
    return dc ? dc->align : 0xFFFFFFFF;
}

// ---- measuring --------------------------------------------------------------------

// The DC's font at 1/scale of its height (scale 1 for the plain GDI calls).
static CTFontRef dc_font(WmcDC *dc, float scale) {
    WmcFont *f = wmc_gdi_object_payload(dc->font, WmcGdiFont);
    if (!f) return sp_create_font(@"Segoe UI", 12, NO, NO);
    return sp_create_font(@(f->face), f->px / (scale > 0 ? scale : 1), f->bold, f->italic);
}

static NSAttributedString *attributed(NSString *text, CTFontRef font, int charExtra) {
    NSMutableDictionary *attrs = [@{ (id)kCTFontAttributeName : (__bridge id)font,
                                     (id)kCTForegroundColorFromContextAttributeName : @YES } mutableCopy];
    if (charExtra) attrs[(id)kCTKernAttributeName] = @(charExtra);
    return [[NSAttributedString alloc] initWithString:text attributes:attrs];
}

static NSString *string_of(const WCHAR *text, int count) {
    if (!text) return @"";
    if (count < 0) count = (int)wmc_wcslen(text);
    return [NSString stringWithCharacters:text length:(NSUInteger)count] ?: @"";
}

WMC_API WINBOOL GetTextExtentPoint32W(HDC hdc, const WCHAR *text, int count, WSIZE *size) {
    @autoreleasepool {
        WmcDC *dc = dc_of(hdc);
        if (!dc || !size) return FALSE;
        CTFontRef font = dc_font(dc, 1);
        CTLineRef line = CTLineCreateWithAttributedString(
            (__bridge CFAttributedStringRef)attributed(string_of(text, count), font, dc->charExtra));
        double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        size->cx = (int32_t)ceil(width);
        size->cy = (int32_t)ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font));
        CFRelease(line);
        CFRelease(font);
        return TRUE;
    }
}

// Reported as a plain advance with no overhang.
WMC_API WINBOOL GetCharABCWidthsW(HDC hdc, uint32_t first, uint32_t last, WABC *abc) {
    @autoreleasepool {
        WmcDC *dc = dc_of(hdc);
        if (!dc || !abc || last < first) return FALSE;
        CTFontRef font = dc_font(dc, 1);
        for (uint32_t c = first; c <= last && c - first < 1024; c++) {
            unichar ch = (unichar)c;
            CGGlyph glyph = 0;
            CGSize advance = CGSizeZero;
            if (CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)) {
                CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &advance, 1);
            }
            abc[c - first] = (WABC){ 0, (uint32_t)ceil(advance.width), 0 };
        }
        CFRelease(font);
        return TRUE;
    }
}

// ---- layout and drawing ---------------------------------------------------------

typedef struct {
    CFArrayRef lines;      // CTLine
    double *widths;
    double lineHeight, ascent, width, height;
    CFIndex count;
} TextLayout;

static TextLayout layout_text(NSString *text, CTFontRef font, int charExtra, double wrapWidth, BOOL singleLine) {
    TextLayout l = { 0 };
    l.ascent = ceil(CTFontGetAscent(font));
    l.lineHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font));
    NSAttributedString *attr = attributed(text, font, charExtra);
    CFMutableArrayRef lines = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (attr.length) {
        CTTypesetterRef ts = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        CFIndex start = 0, length = (CFIndex)attr.length;
        while (start < length) {
            CFIndex n = singleLine ? length - start : CTTypesetterSuggestLineBreak(ts, start, wrapWidth > 0 ? wrapWidth : 1e7);
            if (n <= 0) n = 1;
            CTLineRef line = CTTypesetterCreateLine(ts, CFRangeMake(start, n));
            CFArrayAppendValue(lines, line);
            CFRelease(line);
            start += n;
        }
        CFRelease(ts);
    }
    l.lines = lines;
    l.count = CFArrayGetCount(lines);
    l.widths = calloc((size_t)l.count + 1, sizeof(double));
    for (CFIndex i = 0; i < l.count; i++) {
        CTLineRef line = CFArrayGetValueAtIndex(lines, i);
        l.widths[i] = CTLineGetTypographicBounds(line, NULL, NULL, NULL) - CTLineGetTrailingWhitespaceWidth(line);
        if (l.widths[i] > l.width) l.width = l.widths[i];
    }
    l.height = l.lineHeight * (l.count > 0 ? l.count : 1);
    return l;
}

static void layout_free(TextLayout *l) {
    if (l->lines) CFRelease(l->lines);
    free(l->widths);
}

// Draws laid-out text into the DC's bitmap. The bitmap is 32-bit, top row
// first. Text is blended in the DC's text colour over what is there (or over
// the background colour if `opaque`), leaving the alpha byte alone: the
// SpTrueTypeProcess functions derive alpha from the picture afterwards.
static void draw_layout(WmcDC *dc, TextLayout *l, int x, int y, int boxWidth, int alignment, BOOL opaque,
                        const WRECT *fill) {
    int bw = 0, bh = 0;
    void *bits = NULL;
    if (!wmc_gdi_bitmap_get(dc->bitmap, &bw, &bh, &bits)) return;
    uint32_t *px = bits;
    uint32_t tr = dc->textColor & 0xFF, tg = (dc->textColor >> 8) & 0xFF, tb = (dc->textColor >> 16) & 0xFF;
    if (opaque && fill) {
        uint32_t bk = 0xFF000000u | (dc->bkColor & 0xFF) << 16 | (dc->bkColor & 0xFF00) | ((dc->bkColor >> 16) & 0xFF);
        for (int yy = MAX(0, fill->top); yy < MIN(bh, fill->bottom); yy++) {
            for (int xx = MAX(0, fill->left); xx < MIN(bw, fill->right); xx++) px[yy * bw + xx] = bk;
        }
    }
    // Coverage of the glyphs, one byte per pixel.
    uint8_t *mask = calloc((size_t)bw * (size_t)bh, 1);
    CGContextRef ctx = CGBitmapContextCreate(mask, (size_t)bw, (size_t)bh, 8, (size_t)bw, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    CGContextSetShouldSmoothFonts(ctx, false);
    for (CFIndex i = 0; i < l->count; i++) {
        double lx = x;
        if (alignment == 1) lx = x + (boxWidth - l->widths[i]) / 2;
        else if (alignment == 2) lx = x + boxWidth - l->widths[i];
        double baseline = y + l->lineHeight * i + l->ascent;
        CGContextSetTextPosition(ctx, lx, bh - baseline);
        CTLineDraw(CFArrayGetValueAtIndex(l->lines, i), ctx);
    }
    CGContextRelease(ctx);
    for (int i = 0; i < bw * bh; i++) {
        uint32_t c = mask[i];
        if (!c) continue;
        uint32_t p = px[i], b = p & 0xFF, g = (p >> 8) & 0xFF, r = (p >> 16) & 0xFF;
        r += ((int)tr - (int)r) * (int)c / 255;
        g += ((int)tg - (int)g) * (int)c / 255;
        b += ((int)tb - (int)b) * (int)c / 255;
        px[i] = (p & 0xFF000000u) | r << 16 | g << 8 | b;
    }
    free(mask);
}

// DrawText with the framework's flags. With DT_CALCRECT nothing is drawn and
// the rectangle is set to the text's size. `scale` is the oversampling the
// caller's font was created for (4 under Direct3D, 1 for plain GDI).
static WINBOOL draw_text(HDC hdc, const WCHAR *text, int count, WRECT *rc, uint32_t format, uint32_t scale) {
    @autoreleasepool {
        WmcDC *dc = dc_of(hdc);
        if (!dc || !rc) return FALSE;
        CTFontRef font = dc_font(dc, scale);
        BOOL single = (format & DT_SINGLELINE) != 0 || !(format & DT_WORDBREAK);
        int boxWidth = rc->right - rc->left;
        TextLayout l = layout_text(string_of(text, count), font, dc->charExtra / (int)(scale ? scale : 1), boxWidth, single);
        if (format & DT_CALCRECT) {
            rc->right = rc->left + (int32_t)ceil(l.width);
            rc->bottom = rc->top + (int32_t)ceil(l.height);
        } else {
            int alignment = (format & DT_CENTER) ? 1 : (format & DT_RIGHT) ? 2 : 0;
            draw_layout(dc, &l, rc->left, rc->top, boxWidth, alignment, NO, rc);
        }
        layout_free(&l);
        CFRelease(font);
        return TRUE;
    }
}

static WINBOOL ext_text_out(HDC hdc, int x, int y, uint32_t options, const WRECT *rc, const WCHAR *text, int count,
                            uint32_t scale) {
    @autoreleasepool {
        WmcDC *dc = dc_of(hdc);
        if (!dc) return FALSE;
        CTFontRef font = dc_font(dc, scale);
        TextLayout l = layout_text(string_of(text, count), font, dc->charExtra / (int)(scale ? scale : 1), 0, YES);
        int left = x;
        if ((dc->align & TA_CENTER) == TA_CENTER) left = x - (int)(l.width / 2);
        else if (dc->align & TA_RIGHT) left = x - (int)ceil(l.width);
        draw_layout(dc, &l, left, y, (int)ceil(l.width), 0, (options & ETO_OPAQUE) != 0, rc);
        layout_free(&l);
        CFRelease(font);
        return TRUE;
    }
}

WMC_API HRESULT SpDrawTextAA(HDC hdc, const WCHAR *text, int count, WRECT *rc, uint32_t format, uint32_t scale,
                             uint32_t fade) {
    return draw_text(hdc, text, count, rc, format, scale) ? S_OK : E_FAIL;
}

WMC_API HRESULT SpExtTextOutAA(HDC hdc, int x, int y, uint32_t options, WRECT *rc, const WCHAR *text, int count,
                               void *dx, uint32_t scale, uint32_t fade) {
    return ext_text_out(hdc, x, y, options, rc, text, count, scale) ? S_OK : E_FAIL;
}

WMC_API WINBOOL DrawTextW(HDC hdc, const WCHAR *text, int count, WRECT *rc, uint32_t format) {
    return draw_text(hdc, text, count, rc, format, 1);
}

WMC_API WINBOOL ExtTextOutW(HDC hdc, int x, int y, uint32_t options, WRECT *rc, const WCHAR *text, int count, void *dx) {
    return ext_text_out(hdc, x, y, options, rc, text, count, 1);
}

WMC_API WINBOOL TextOutW(HDC hdc, int x, int y, const WCHAR *text, int count) {
    return ext_text_out(hdc, x, y, 0, NULL, text, count, 1);
}

// ---- from a drawn picture to text with alpha ---------------------------------------
// The framework has drawn white text on black ("light"), black on white
// ("dark"), or coloured text on a coloured background ("opaque"). The result
// is the text in the given colour with straight alpha.

WMC_API HRESULT SpTrueTypeProcessTransparentLight(SpSizeI size, uint32_t *pixels, uint32_t color) {
    uint32_t rgb = color & 0x00FFFFFF, alpha = color >> 24;
    for (int i = 0; i < size.w * size.h; i++) {
        uint32_t coverage = (pixels[i] >> 16) & 0xFF;
        pixels[i] = rgb | ((coverage * alpha + 127) / 255) << 24;
    }
    return S_OK;
}

WMC_API HRESULT SpTrueTypeProcessTransparentDark(SpSizeI size, uint32_t *pixels, uint32_t color) {
    uint32_t rgb = color & 0x00FFFFFF, alpha = color >> 24;
    for (int i = 0; i < size.w * size.h; i++) {
        uint32_t coverage = 255 - ((pixels[i] >> 16) & 0xFF);
        pixels[i] = rgb | ((coverage * alpha + 127) / 255) << 24;
    }
    return S_OK;
}

WMC_API HRESULT SpTrueTypeProcessOpaque(SpSizeI size, uint32_t *pixels, uint32_t color) {
    for (int i = 0; i < size.w * size.h; i++) pixels[i] |= 0xFF000000u;
    return S_OK;
}
