// ehuihlp: the parts of the Windows shell Media Center leans on while
// browsing folders.
#import <Foundation/Foundation.h>
#include "wmc.h"
#include "paths.h"

#include <sys/stat.h>

// The picture a folder is shown with, if it has one of its own: a file
// called folder.jpg inside it (what Windows Media Player leaves in album
// folders). 0 with the path when there is one.
WMC_API int EHGetBitmapForFolder(const WCHAR *folder, WCHAR *out, int size) {
    @autoreleasepool {
        if (out && size > 0) out[0] = 0;
        char *path = wmc_host_path(folder);
        if (!path) return 1;
        NSString *dir = @(path);
        free(path);
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL]) {
            if ([name caseInsensitiveCompare:@"folder.jpg"] == NSOrderedSame) {
                if (out && size > 0) wmc_utf16_copy(out, (size_t)size, [dir stringByAppendingPathComponent:name].UTF8String);
                return 0;
            }
        }
        return 1;
    }
}

// The name a file or folder is shown by (the Finder's name for it).
WMC_API void EhGetDisplayNameOf(const WCHAR *file, WCHAR *out, int size) {
    @autoreleasepool {
        if (!out || size <= 0) return;
        out[0] = 0;
        char *path = wmc_host_path(file);
        if (!path) return;
        NSString *name = [NSFileManager.defaultManager displayNameAtPath:@(path)];
        free(path);
        wmc_utf16_copy(out, (size_t)size, name.UTF8String);
    }
}

// Being told when files change: native/platform/watch.m.
WMC_API void SHChangeNotify(uint32_t event, uint32_t flags, const WCHAR *path, const WCHAR *other) {}

// Video thumbnails are made by EhGetThumbnailFromShellCache; the slower
// route through a playback graph is never needed. Its "abort" handles are
// still handed out and taken back.
WMC_API void *BeginGetVideoThumbnail(void) { return calloc(1, 8); }
WMC_API void AbortGetVideoThumbnail(void *handle) {}
WMC_API void EndGetVideoThumbnail(void *handle) { free(handle); }
WMC_API void *GroupGetVideoThumbnailBegin(void) { return NULL; }
WMC_API void *GroupGetVideoThumbnailEnd(void) { return NULL; }

// Windows' jump lists and "recent documents".
WMC_API void EhLogOtherMediaPlayback(const WCHAR *path, const WCHAR *title, const WCHAR *album) {}
WMC_API void CreateIShellLink(const WCHAR *path, const WCHAR *arguments, const WCHAR *title, const WCHAR *description,
                              const WCHAR *icon, int iconIndex, void **link) {
    if (link) *link = NULL;
}
WMC_API void SHAddToRecentDocs(uint32_t flags, void *item) {}

// HomeGroup (sharing libraries between Windows PCs): there is none.
WMC_API void EhRegisterHomeGroupCallBacks(void *connected, void *disconnected, void *joined, void *departed, void *statusChanged) {}
WMC_API void EhUnregisterHomeGroupCallBacks(void) {}

// Media Center's online services are gone, so it is told that there is no
// connection rather than left to wait for servers that never answer.
WMC_API WINBOOL NLM_IsConnectedToInternet(void) { return FALSE; }

// A cache file of thumbnails per folder. None is kept: thumbnails are made
// again when asked for.
WMC_API void *OpenFolderBrowserCache(const WCHAR *file, uint32_t mode) { return NULL; }
WMC_API void CloseFolderBrowserCache(void *cache) {}

WMC_API WINBOOL CreateDirectoryW(const WCHAR *folder, void *security) {
    char *path = wmc_host_path(folder);
    if (!path) return FALSE;
    int r = mkdir(path, 0755);
    free(path);
    if (r != 0) { wmc_set_last_error(183); return FALSE; }   // ERROR_ALREADY_EXISTS (or cannot)
    return TRUE;
}
WMC_API WINBOOL CreateDirectory(const WCHAR *folder, void *security) { return CreateDirectoryW(folder, security); }
