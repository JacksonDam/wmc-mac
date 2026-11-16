// Watching folders for files that come and go, so that Media Center shows
// them without being started again. Two users:
//
// The Windows shell's change notifications (EhRegisterForChangeNotify...),
// with which Media Center's picture and video pages watch the folders they
// show: each registration gets an FSEvents stream, and each change becomes
// the registered window message, which Media Center opens with
// EhBeginChangeNotifyEvent and reads with EhCrackChangeNotifyEvent.
//
// The media library (Windows Media Player's, which the music pages use): an
// FSEvents stream over the library folders counts the changes that matter; the
// Media Player stand-in (WmcStandins/Wmp/Player.cs) looks at the count every
// few seconds on Media Center's UI thread, and when it has moved, scans the
// library again and tells Media Center (MediaCollectionChange), which then
// refreshes what it shows. Hidden files (.DS_Store and the like) and the
// insides of other programs' packages (an iMovie library, say), which change
// all the time, do not count.
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>

#include "core/paths.h"
#include "wmc.h"
#include "win32/win32.h"

BOOL PostMessageW(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);   // (native/win32/user32_msg.c)

static FSEventStreamRef s_stream;
static atomic_int s_changes;
static dispatch_queue_t s_queue;

static bool counts(const char *path) {
    for (const char *part = path; part && *part;) {
        const char *end = strchr(part, '/');
        size_t n = end ? (size_t)(end - part) : strlen(part);
        if (n > 0 && part[0] == '.') return false;              // hidden
        static const char *const packages[] = {"library", ".app", ".bundle", ".fcpbundle", ".band", ".logicx",
                                               ".theater", ".photoslibrary"};
        for (size_t i = 0; i < sizeof(packages) / sizeof(packages[0]); i++) {
            size_t k = strlen(packages[i]);
            if (end && n >= k && !strncasecmp(part + n - k, packages[i], k)) return false;   // inside a package
        }
        part = end ? end + 1 : NULL;
    }
    return true;
}

static void changed(ConstFSEventStreamRef stream, void *info, size_t count, void *paths,
                    const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    char **list = paths;
    for (size_t i = 0; i < count; i++) {
        if (!counts(list[i])) continue;
        atomic_fetch_add(&s_changes, 1);
        WLOG("wmp", "library folder changed: %s", list[i]);
        return;
    }
}

// Watches these folders (one per line) from now on, in place of any before.
WMC_API void wmc_watch_folders(const char *folders) {
    if (!s_queue) s_queue = dispatch_queue_create("wmc.watch", DISPATCH_QUEUE_SERIAL);
    dispatch_sync(s_queue, ^{
        if (s_stream) {
            FSEventStreamStop(s_stream);
            FSEventStreamInvalidate(s_stream);
            FSEventStreamRelease(s_stream);
            s_stream = NULL;
        }
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSString *line in [@(folders ? folders : "") componentsSeparatedByString:@"\n"])
            if (line.length) [paths addObject:line];
        if (!paths.count) return;
        s_stream = FSEventStreamCreate(NULL, changed, NULL, (__bridge CFArrayRef)paths, kFSEventStreamEventIdSinceNow,
                                       1.0, kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
        if (!s_stream) return;
        FSEventStreamSetDispatchQueue(s_stream, s_queue);
        FSEventStreamStart(s_stream);
        WLOG("wmp", "watching %lu library folders", (unsigned long)paths.count);
    });
}

// How many changes there have been (the number only ever grows).
WMC_API int wmc_watch_changes(void) {
    return atomic_load(&s_changes);
}

// ---- the shell's change notifications ------------------------------------------------

enum {
    SHCNE_RENAMEITEM = 0x1, SHCNE_CREATE = 0x2, SHCNE_DELETE = 0x4, SHCNE_MKDIR = 0x8, SHCNE_RMDIR = 0x10,
    SHCNE_UPDATEDIR = 0x1000, SHCNE_UPDATEITEM = 0x2000,
};

typedef struct {
    uint32_t event;
    WCHAR path[260];
} ChangeRecord;

@interface WmcShellWatch : NSObject
@property (nonatomic) uint32_t ident;
@property (nonatomic) HWND window;
@property (nonatomic) uint32_t message, events;
@property (nonatomic) BOOL recursive;
@property (nonatomic, copy) NSString *root;        // the folder, as a Mac path
@property (nonatomic, copy) NSString *shown;       // the folder as Media Center named it
@property (nonatomic) FSEventStreamRef stream;
@end

@implementation WmcShellWatch
@end

static NSMutableDictionary<NSNumber *, WmcShellWatch *> *s_watches;
static uint32_t s_nextWatch;

// The change as Media Center names things: its path in the form it used.
static void report(WmcShellWatch *w, NSString *path, uint32_t event) {
    if (!(w.events & event)) return;
    NSString *rest = [path substringFromIndex:MIN(w.root.length, path.length)];
    if ([w.shown containsString:@"\\"]) rest = [rest stringByReplacingOccurrencesOfString:@"/" withString:@"\\"];
    NSString *shown = [w.shown stringByAppendingString:rest];
    ChangeRecord *record = calloc(1, sizeof(ChangeRecord));
    record->event = event;
    wmc_utf16_copy(record->path, 260, shown.UTF8String);
    WLOG("wmp", "shell change %#x: %s", event, shown.UTF8String);
    PostMessageW(w.window, w.message, (WPARAM)record, 0);
}

static void shell_changed(ConstFSEventStreamRef stream, void *info, size_t count, void *paths,
                          const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    WmcShellWatch *w = (__bridge WmcShellWatch *)info;
    char **list = paths;
    for (size_t i = 0; i < count; i++) {
        if (!counts(list[i])) continue;
        NSString *path = @(list[i]);
        if (!w.recursive && ![path.stringByDeletingLastPathComponent isEqualToString:w.root] &&
            ![path isEqualToString:w.root])
            continue;
        BOOL folder = (flags[i] & kFSEventStreamEventFlagItemIsDir) != 0;
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path];
        uint32_t event;
        if (!exists) event = folder ? SHCNE_RMDIR : SHCNE_DELETE;
        else if (flags[i] & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed))
            event = folder ? SHCNE_MKDIR : SHCNE_CREATE;
        else if (flags[i] & kFSEventStreamEventFlagItemModified) event = folder ? SHCNE_UPDATEDIR : SHCNE_UPDATEITEM;
        else continue;
        report(w, path, event);
    }
}

WMC_API uint32_t EhRegisterForChangeNotifyOnFilename(HWND window, uint32_t message, uint32_t events, const WCHAR *file,
                                                     WINBOOL recurse) {
    char *host = wmc_host_path(file);
    char *shown = wmc_utf8(file);
    if (!host || !shown) {
        free(host);
        free(shown);
        return 0;
    }
    WmcShellWatch *w = [WmcShellWatch new];
    w.window = window;
    w.message = message;
    w.events = events;
    w.recursive = recurse != 0;
    // (The real path: FSEvents reports /private/tmp, not /tmp, and the like.)
    char real[PATH_MAX];
    w.root = realpath(host, real) ? @(real) : @(host);
    w.shown = [@(shown) hasSuffix:@"\\"] || [@(shown) hasSuffix:@"/"] ? [@(shown) substringToIndex:strlen(shown) - 1] : @(shown);
    free(host);
    free(shown);
    if (!s_queue) s_queue = dispatch_queue_create("wmc.watch", DISPATCH_QUEUE_SERIAL);
    __block uint32_t ident = 0;
    dispatch_sync(s_queue, ^{
        FSEventStreamContext context = {0, (__bridge void *)w, NULL, NULL, NULL};
        w.stream = FSEventStreamCreate(NULL, shell_changed, &context, (__bridge CFArrayRef)@[ w.root ],
                                       kFSEventStreamEventIdSinceNow, 1.0,
                                       kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
        if (!w.stream) return;
        FSEventStreamSetDispatchQueue(w.stream, s_queue);
        FSEventStreamStart(w.stream);
        if (!s_watches) s_watches = [NSMutableDictionary dictionary];
        ident = w.ident = ++s_nextWatch;
        s_watches[@(ident)] = w;
    });
    if (ident) WLOG("wmp", "shell watch %u on %s", ident, w.root.UTF8String);
    return ident;
}

// Changes not tied to a folder (discs and drives coming and going): accepted;
// none are reported yet.
WMC_API uint32_t EhRegisterForChangeNotify(HWND window, uint32_t message, uint32_t events) {
    return ++s_nextWatch;
}

WMC_API void EhUnRegisterForChangeNotify(uint32_t registration) {
    if (!s_queue) return;
    dispatch_sync(s_queue, ^{
        WmcShellWatch *w = s_watches[@(registration)];
        if (!w) return;
        FSEventStreamStop(w.stream);
        FSEventStreamInvalidate(w.stream);
        FSEventStreamRelease(w.stream);
        w.stream = NULL;
        [s_watches removeObjectForKey:@(registration)];
    });
}

// What a posted change message carries (wParam: the record).
WMC_API void *EhBeginChangeNotifyEvent(WPARAM wParam, LPARAM lParam, void **item, uint32_t *event) {
    ChangeRecord *record = (ChangeRecord *)wParam;
    if (item) *item = record;
    if (event) *event = record ? record->event : 0;
    return record;
}

WMC_API void EhCrackChangeNotifyEvent(void *item, WCHAR *file) {
    ChangeRecord *record = item;
    if (!file) return;
    file[0] = 0;
    if (record) memcpy(file, record->path, sizeof(record->path));
}

// (Renames are reported as a delete and a create.)
WMC_API void EhCrackRenameChangeNotifyEvent(void *item, WCHAR *from, WCHAR *to) {
    EhCrackChangeNotifyEvent(item, from);
    if (to) to[0] = 0;
}

WMC_API void EhEndChangeNotifyEvent(void *handle) {
    free(handle);
}
