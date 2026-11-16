// Text: the SpRichText* functions.
//
// The framework hands the engine a string (as RTF) with a font and a width,
// and expects back a list of "runs": one positioned piece of text per line.
// Later it asks for each run's bitmap, first as white coverage, then
// coloured. On Windows the engine drove a RichEdit control for this; here it
// is Core Text. The bitmap for a run is exactly the size reported for it, so
// the framework draws it 1:1.
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#include "wmc.h"
#include "win32/gdi.h"
#include "paths.h"
#include "splash_protocol.h"

typedef struct { float w, h; } SpSizeF;
typedef struct { int32_t w, h; } SpSizeI;
typedef struct Sp_RenderApi_RasterizeRunPacket SpRunPacket;
typedef HRESULT (*SpReportRun)(SpRunPacket *run, void *data);

// Windows lays text out at 96 dots per inch.
#define SP_PX_PER_PT (96.0 / 72.0)
// Room around a line's bitmap for antialiasing and italic overhang.
#define SP_RUN_PAD 2

@interface SpRichText : NSObject
@property (nonatomic) BOOL richMode, bold, italic, wordWrap, rtl;
@property (nonatomic, copy) NSString *face;
@property (nonatomic) int heightPts, alignment;
@property (nonatomic) uint32_t colorref;
@property (nonatomic) float scale;
@property (nonatomic, strong) NSArray<NSDictionary *> *spans;   // text + bold/italic
@end

@implementation SpRichText
- (instancetype)init {
    if ((self = [super init])) {
        _scale = 1;
        _face = @"Segoe UI";
        _heightPts = 12;
        _spans = @[];
    }
    return self;
}
@end

// ---- fonts ---------------------------------------------------------------------

// Media Center ships its own fonts beside the program; make them available
// to this process (never installed system-wide).
static void register_private_fonts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char *dir = wmc_host_path_utf8(wmc_ehome_dir());
        NSString *path = @(dir);
        free(dir);
        NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil];
        int count = 0;
        for (NSString *name in files) {
            NSString *ext = name.pathExtension.lowercaseString;
            if (![ext isEqualToString:@"ttf"] && ![ext isEqualToString:@"ttc"]) continue;
            NSURL *url = [NSURL fileURLWithPath:[path stringByAppendingPathComponent:name]];
            if (CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL)) count++;
        }
        WLOG("text", "registered %d private font files from %s", count, path.UTF8String);
    });
}

CTFontRef sp_create_font(NSString *face, CGFloat px, BOOL bold, BOOL italic);
static CTFontRef create_font(NSString *face, CGFloat px, BOOL bold, BOOL italic) {
    return sp_create_font(face, px, bold, italic);
}

// Finds a font by its Windows face name: the installer's own fonts first,
// then stand-ins for Windows fonts the Mac does not have.
CTFontRef sp_create_font(NSString *face, CGFloat px, BOOL bold, BOOL italic) {
    register_private_fonts();
    NSArray<NSString *> *candidates = @[ face ?: @"", @"Segoe Media Center", @"Helvetica Neue" ];
    CTFontRef font = NULL;
    for (NSString *name in candidates) {
        if (!name.length) continue;
        CTFontRef f = CTFontCreateWithName((__bridge CFStringRef)name, px, NULL);
        NSString *family = CFBridgingRelease(CTFontCopyFamilyName(f));
        NSString *full = CFBridgingRelease(CTFontCopyFullName(f));
        // CTFontCreateWithName substitutes silently: accept only a real match.
        if ([family caseInsensitiveCompare:name] == NSOrderedSame || [full caseInsensitiveCompare:name] == NSOrderedSame) {
            font = f;
            break;
        }
        CFRelease(f);
    }
    if (!font) font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, px, NULL);
    CTFontSymbolicTraits traits = (bold ? kCTFontBoldTrait : 0) | (italic ? kCTFontItalicTrait : 0);
    if (traits) {
        CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(font, px, NULL, traits, kCTFontBoldTrait | kCTFontItalicTrait);
        if (styled) {
            CFRelease(font);
            font = styled;
        }
    }
    return font;
}

// ---- RTF ------------------------------------------------------------------------
// The subset the framework produces: plain text with \par, \'hh, \uN, and
// the character formats \b and \i. Other control words are skipped.

static NSArray<NSDictionary *> *parse_rtf(const char *rtf) {
    NSMutableArray *spans = [NSMutableArray array];
    NSMutableString *text = [NSMutableString string];
    __block BOOL bold = NO, italic = NO;
    void (^flush)(void) = ^{
        if (text.length) {
            [spans addObject:@{ @"text" : [text copy], @"bold" : @(bold), @"italic" : @(italic) }];
            [text setString:@""];
        }
    };
    int depth = 0, skipDepth = 0, ucSkip = 1;
    const char *p = rtf;
    while (*p) {
        char c = *p;
        if (c == '{') { depth++; p++; continue; }
        if (c == '}') {
            if (skipDepth && depth == skipDepth) skipDepth = 0;
            depth--;
            p++;
            continue;
        }
        if (c == '\\') {
            p++;
            if (*p == '\'') {   // \'hh: one byte in the ANSI code page
                unsigned v = 0;
                if (p[1] && p[2]) sscanf(p + 1, "%2x", &v);
                p += (p[1] && p[2]) ? 3 : 1;
                if (!skipDepth) [text appendFormat:@"%C", (unichar)(v == 0x0A ? '\n' : v)];
                continue;
            }
            if (*p == '\\' || *p == '{' || *p == '}') {
                if (!skipDepth) [text appendFormat:@"%c", *p];
                p++;
                continue;
            }
            if (*p == '*') {    // \* marks an ignorable destination group
                if (!skipDepth) skipDepth = depth;
                p++;
                continue;
            }
            char word[32];
            int n = 0;
            while (((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')) && n < 31) word[n++] = *p++;
            word[n] = 0;
            BOOL hasParam = NO;
            int param = 0, sign = 1;
            if (*p == '-') { sign = -1; p++; }
            while (*p >= '0' && *p <= '9') { param = param * 10 + (*p - '0'); p++; hasParam = YES; }
            param *= sign;
            if (*p == ' ') p++;
            if (skipDepth) continue;
            if (!strcmp(word, "par") || !strcmp(word, "line")) [text appendString:@"\n"];
            else if (!strcmp(word, "tab")) [text appendString:@"\t"];
            else if (!strcmp(word, "uc")) ucSkip = param;
            else if (!strcmp(word, "u")) {
                [text appendFormat:@"%C", (unichar)(param < 0 ? param + 65536 : param)];
                for (int k = 0; k < ucSkip && *p; k++) {    // the fallback character(s)
                    if (*p == '\\' && p[1] == '\'') p += 4; else p++;
                }
            } else if (!strcmp(word, "b")) { flush(); bold = !hasParam || param != 0; }
            else if (!strcmp(word, "i")) { flush(); italic = !hasParam || param != 0; }
            else if (!strcmp(word, "fonttbl") || !strcmp(word, "colortbl") || !strcmp(word, "stylesheet") ||
                     !strcmp(word, "info")) skipDepth = depth;
            continue;
        }
        if (c == '\r' || c == '\n') { p++; continue; }
        if (!skipDepth) {
            // Bytes outside ASCII arrive as UTF-8 from the marshaller.
            const char *start = p;
            p++;
            while ((*p & 0xC0) == 0x80) p++;
            NSString *piece = [[NSString alloc] initWithBytes:start length:(NSUInteger)(p - start) encoding:NSUTF8StringEncoding];
            if (piece) [text appendString:piece];
        } else {
            p++;
        }
    }
    flush();
    return spans;
}

static uint32_t colorref_to_argb(uint32_t cr) {
    return 0xFF000000u | (cr & 0xFF) << 16 | (cr & 0xFF00) | ((cr >> 16) & 0xFF);
}

// ---- exported -------------------------------------------------------------------

WMC_API HRESULT SpRichTextBuildObject(WINBOOL richMode, SpSizeI maxSurface, void **handle) {
    SpRichText *rt = [SpRichText new];
    rt.richMode = richMode != 0;
    *handle = (__bridge_retained void *)rt;
    return S_OK;
}

WMC_API HRESULT SpRichTextDestroyObject(void *handle) {
    if (handle) CFRelease(handle);
    return S_OK;
}

WMC_API HRESULT SpRichTextSetFormat(void *handle, const WCHAR *face, int heightPts, uint32_t colorref, WINBOOL bold,
                                    WINBOOL italic, WINBOOL wordWrap, int16_t alignment, WINBOOL rtl) {
    SpRichText *rt = (__bridge SpRichText *)handle;
    rt.face = face ? [NSString stringWithCharacters:face length:wmc_wcslen(face)] : @"";
    rt.heightPts = heightPts;
    rt.colorref = colorref;
    rt.bold = bold != 0;
    rt.italic = italic != 0;
    rt.wordWrap = wordWrap != 0;
    rt.alignment = alignment;
    rt.rtl = rtl != 0;
    return S_OK;
}

WMC_API HRESULT SpRichTextSetContent(void *handle, const char *rtf) {
    SpRichText *rt = (__bridge SpRichText *)handle;
    rt.spans = rtf ? parse_rtf(rtf) : @[];
    return S_OK;
}

WMC_API HRESULT SpRichTextSetSimpleContent(void *handle, const WCHAR *text) {
    SpRichText *rt = (__bridge SpRichText *)handle;
    NSString *s = text ? [NSString stringWithCharacters:text length:wmc_wcslen(text)] : @"";
    rt.spans = s.length ? @[ @{ @"text" : s, @"bold" : @NO, @"italic" : @NO } ] : @[];
    return S_OK;
}

WMC_API HRESULT SpRichTextSetScale(void *handle, float scale) {
    ((__bridge SpRichText *)handle).scale = scale > 0 ? scale : 1;
    return S_OK;
}

WMC_API HRESULT SpRichTextIsRichRtlString(void *handle, const char *rtf, WINBOOL hostIsRtl, WINBOOL *isRtl) {
    *isRtl = FALSE;
    return S_OK;
}

// Lays the text out and reports one run per line and style span.
WMC_API HRESULT SpRichTextMeasure(void *handle, SpSizeF constraint, SpReportRun report, void *data) {
    @autoreleasepool {
        SpRichText *rt = (__bridge SpRichText *)handle;
        CGFloat px = rt.heightPts * SP_PX_PER_PT * rt.scale;
        if (px < 1) px = 1;
        NSMutableAttributedString *attr = [NSMutableAttributedString new];
        for (NSDictionary *span in rt.spans) {
            BOOL bold = rt.bold || [span[@"bold"] boolValue], italic = rt.italic || [span[@"italic"] boolValue];
            CTFontRef font = create_font(rt.face, px, bold, italic);
            NSDictionary *attrs = @{
                (id)kCTFontAttributeName : (__bridge id)font,
                @"SpBold" : @(bold),
                @"SpItalic" : @(italic),
            };
            [attr appendAttributedString:[[NSAttributedString alloc] initWithString:span[@"text"] attributes:attrs]];
            CFRelease(font);
        }
        if (attr.length == 0) return S_OK;

        // Two sets of units. The framework lays out in its own "logical"
        // units and scales the whole scene to the window; it asks for text
        // at that scale so glyphs are rasterised at real pixels. So fonts,
        // line breaking and bitmaps are in pixels (logical x scale), and the
        // rectangles reported for layout are divided back by the scale.
        double scale = rt.scale;
        CTTypesetterRef ts = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        double wrapWidth = rt.wordWrap && constraint.w > 0 ? constraint.w * scale : 1.0e7;
        NSMutableArray *lines = [NSMutableArray array];
        CFIndex start = 0, length = (CFIndex)attr.length;
        double maxWidth = 0;
        while (start < length) {
            CFIndex count = CTTypesetterSuggestLineBreak(ts, start, wrapWidth);
            if (count <= 0) count = 1;
            CTLineRef line = CTTypesetterCreateLine(ts, CFRangeMake(start, count));
            CGFloat ascent = 0, descent = 0, leading = 0;
            double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
            width -= CTLineGetTrailingWhitespaceWidth(line);
            if (width > maxWidth) maxWidth = width;
            [lines addObject:@{ @"line" : (__bridge_transfer id)line, @"start" : @(start), @"count" : @(count),
                                @"width" : @(width), @"ascent" : @(ascent), @"descent" : @(descent),
                                @"leading" : @(leading) }];
            start += count;
        }
        CFRelease(ts);

        double layoutWidth = rt.wordWrap && constraint.w > 0 && constraint.w < 4095 ? constraint.w * scale : maxWidth;
        double y = 0;
        int lineNumber = 0;
        HRESULT hr = S_OK;
        for (NSDictionary *info in lines) {
            lineNumber++;
            NSRange range = NSMakeRange([info[@"start"] unsignedIntegerValue], [info[@"count"] unsignedIntegerValue]);
            NSString *text = [attr.string substringWithRange:range];
            while (text.length && [NSCharacterSet.newlineCharacterSet characterIsMember:[text characterAtIndex:text.length - 1]]) {
                text = [text substringToIndex:text.length - 1];
            }
            double width = [info[@"width"] doubleValue];
            double height = ceil([info[@"ascent"] doubleValue] + [info[@"descent"] doubleValue] + [info[@"leading"] doubleValue]);
            double x = 0;
            if (rt.alignment == 3) x = (layoutWidth - width) / 2;
            else if (rt.alignment == 2) x = layoutWidth - width;
            if (text.length > 0) {
                NSDictionary *attrs = [attr attributesAtIndex:range.location effectiveRange:NULL];
                int w = (int)ceil(width) + 2 * SP_RUN_PAD, h = (int)height;
                NSUInteger n = text.length;
                unichar *chars = calloc(n + 1, sizeof(unichar));
                [text getCharacters:chars range:NSMakeRange(0, n)];
                int32_t *dx = calloc(n + 1, sizeof(int32_t));
                SpRunPacket run;
                memset(&run, 0, sizeof(run));
                run.sizefSrc.width = w;
                run.sizefSrc.height = h;
                run.rcfDestLogical.x = run.rcfDestContent.x = (float)((floor(x) - SP_RUN_PAD) / scale);
                run.rcfDestLogical.y = run.rcfDestContent.y = (float)(y / scale);
                run.rcfDestLogical.width = run.rcfDestContent.width = (float)(w / scale);
                run.rcfDestLogical.height = run.rcfDestContent.height = (float)(h / scale);
                run.lpString = (uint64_t)(uintptr_t)chars;
                run.cbCount = (uint32_t)n;
                run.lpDx = (uint64_t)(uintptr_t)dx;
                run.clrText.value = colorref_to_argb(rt.colorref);
                run.lf.lfHeight = -(int32_t)lround(px);
                run.lf.lfWeight = [attrs[@"SpBold"] boolValue] ? 700 : 400;
                run.lf.lfItalic = [attrs[@"SpItalic"] boolValue] ? 1 : 0;
                run.lf.lfCharSet = 1;
                NSUInteger faceLen = MIN(rt.face.length, (NSUInteger)31);
                [rt.face getCharacters:(unichar *)&run.lf.lfFaceName range:NSMakeRange(0, faceLen)];
                run.sizeRasterizeRun.m_width = w;
                run.sizeRasterizeRun.m_height = h;
                run.nLine = lineNumber;
                hr = report(&run, data);
                free(chars);
                free(dx);
                if (hr < 0) break;
            }
            y += height;
        }
        WLOG("text", "measure \"%s\" %s %dpt x%.2f wrap %d width %g -> %d lines, %gx%g",
             attr.string.length > 40 ? [attr.string substringToIndex:40].UTF8String : attr.string.UTF8String,
             rt.face.UTF8String, rt.heightPts, rt.scale, rt.wordWrap, constraint.w, lineNumber, maxWidth, y);
        return hr;
    }
}

// Draws one run as white-on-clear coverage, at the size reported for it.
WMC_API HRESULT SpRichTextRasterizeOversampled(void *handle, SpRunPacket *run, int outlineMode, HBITMAP *bitmap,
                                               void **bits, SpSizeI *size) {
    @autoreleasepool {
        int w = run->sizeRasterizeRun.m_width, h = run->sizeRasterizeRun.m_height;
        void *pixels = NULL;
        HBITMAP hbm = wmc_gdi_bitmap_create(w, h, &pixels);
        if (!hbm) return E_OUTOFMEMORY;
        const unichar *chars = (const unichar *)(uintptr_t)run->lpString;
        NSString *text = [NSString stringWithCharacters:chars length:run->cbCount];
        NSString *face = [NSString stringWithCharacters:(const unichar *)&run->lf.lfFaceName
                                                 length:wmc_wcslen((const WCHAR *)&run->lf.lfFaceName)];
        CGFloat px = run->lf.lfHeight < 0 ? -run->lf.lfHeight : run->lf.lfHeight;
        CTFontRef font = create_font(face, px, run->lf.lfWeight >= 600, run->lf.lfItalic != 0);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(pixels, (size_t)w, (size_t)h, 8, (size_t)w * 4, space,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
        NSMutableDictionary *attrs = [@{
            (id)kCTFontAttributeName : (__bridge id)font,
            (id)kCTForegroundColorAttributeName : (__bridge id)white,
        } mutableCopy];
        if (outlineMode) {
            attrs[(id)kCTStrokeWidthAttributeName] = @(3.0);
            attrs[(id)kCTStrokeColorAttributeName] = (__bridge id)white;
        }
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:text attributes:attrs];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        CGFloat ascent = 0, descent = 0, leading = 0;
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        // Core Graphics' origin is bottom left; the bitmap rows are top-down
        // in memory, which is the same thing.
        CGContextSetShouldSmoothFonts(ctx, false);
        CGContextSetTextPosition(ctx, SP_RUN_PAD, h - ceil(ascent));
        CTLineDraw(line, ctx);
        CFRelease(line);
        CGColorRelease(white);
        CGContextRelease(ctx);
        CGColorSpaceRelease(space);
        CFRelease(font);
        *bitmap = hbm;
        *bits = pixels;
        size->w = w;
        size->h = h;
        return S_OK;
    }
}

// Colours a coverage bitmap. The result has straight alpha: every pixel
// carries the text colour and the coverage is the alpha. Shadow mode softens
// the coverage first.
WMC_API HRESULT SpRichTextAntiAlias(void *handle, HBITMAP oversampled, uint32_t color, int shadowMode,
                                    HBITMAP *bitmap, void **bits, struct Sp_Win32Api_RECT *rect) {
    int w = 0, h = 0;
    void *src = NULL;
    if (!wmc_gdi_bitmap_get(oversampled, &w, &h, &src)) return E_INVALIDARG;
    void *dst = NULL;
    HBITMAP hbm = wmc_gdi_bitmap_create(w, h, &dst);
    if (!hbm) return E_OUTOFMEMORY;
    const uint32_t *in = src;
    uint32_t *out = dst;
    uint32_t rgb = color & 0x00FFFFFF, alpha = color >> 24;
    uint8_t *cov = malloc((size_t)w * (size_t)h);
    for (int i = 0; i < w * h; i++) cov[i] = (uint8_t)(in[i] >> 24);
    if (shadowMode) {
        // Two passes of a 3-wide box in each direction: a small soft blur.
        uint8_t *tmp = malloc((size_t)w * (size_t)h);
        for (int pass = 0; pass < 2; pass++) {
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int a = cov[y * w + (x > 0 ? x - 1 : x)], b = cov[y * w + x], c = cov[y * w + (x < w - 1 ? x + 1 : x)];
                    tmp[y * w + x] = (uint8_t)((a + b + c) / 3);
                }
            }
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) {
                    int a = tmp[(y > 0 ? y - 1 : y) * w + x], b = tmp[y * w + x], c = tmp[(y < h - 1 ? y + 1 : y) * w + x];
                    cov[y * w + x] = (uint8_t)((a + b + c) / 3);
                }
            }
        }
        free(tmp);
    }
    for (int i = 0; i < w * h; i++) out[i] = rgb | (((uint32_t)cov[i] * alpha + 127) / 255) << 24;
    free(cov);
    *bitmap = hbm;
    *bits = dst;
    rect->left = 0;
    rect->top = 0;
    rect->right = w;
    rect->bottom = h;
    return S_OK;
}

WMC_API HRESULT SpDibCreate(SpSizeI size, uint32_t clear, HBITMAP *bitmap, void **bits) {
    void *pixels = NULL;
    HBITMAP hbm = wmc_gdi_bitmap_create(size.w, size.h, &pixels);
    if (!hbm) return E_OUTOFMEMORY;
    uint32_t *p = pixels;
    for (int i = 0; i < size.w * size.h; i++) p[i] = clear;
    *bitmap = hbm;
    *bits = pixels;
    return S_OK;
}

WMC_API HRESULT SpDibClear(SpSizeI size, uint32_t clear, void *bits) {
    uint32_t *p = bits;
    for (int i = 0; i < size.w * size.h; i++) p[i] = clear;
    return S_OK;
}

WMC_API HRESULT SpCheckGlyphAvailability(const WCHAR *text, int count, void *hdc) { return S_OK; }

// ---- device capabilities ----------------------------------------------------------

void wmc_main_screen_size(int *width, int *height);

WMC_API HRESULT SpDx9DeviceCheckCaps(struct Sp_RenderApi_Dx9DriverInfo *info) {
    memset(info, 0, sizeof(*info));
    int w = 0, h = 0;
    wmc_main_screen_size(&w, &h);
    info->sizeScreenPxl.m_width = w;
    info->sizeScreenPxl.m_height = h;
    info->cBitDepth = 32;
    info->sizeMinTexturePxl.m_width = info->sizeMinTexturePxl.m_height = 1;
    info->sizeMaxTexturePxl.m_width = info->sizeMaxTexturePxl.m_height = 4096;
    info->cbTotalVideoMemory = 1024ll * 1024 * 1024;
    info->cbDedicatedVideoMemory = 1024ll * 1024 * 1024;
    info->nDxCaps = 1;   // "Required" capabilities present
    return S_OK;
}

WMC_API HRESULT SpDx9SoundDeviceCheckCaps(struct Sp_RenderApi_Dx9SoundDriverInfo *info) {
    info->nMinSecondarySampleRate = 100;
    info->nMaxSecondarySampleRate = 200000;
    info->nDxCaps = 1;
    return S_OK;
}
