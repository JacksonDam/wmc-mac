// Fonts by their Windows face names, for every engine's text (Splash's
// rich and GDI text, XP Media Center Edition 2002's): the fonts Media Center
// ships beside its program first (made available to this process only),
// then stand-ins for Windows fonts the Mac does not have.
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#include "wmc.h"
#include "paths.h"

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
