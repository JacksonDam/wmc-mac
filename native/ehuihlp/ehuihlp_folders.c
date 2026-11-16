// ehuihlp: where Windows keeps things.
#include "wmc.h"
#include "paths.h"

#include <stdio.h>
#include <string.h>

// The path of a special folder (a CSIDL number; 0x8000 asks for it to be
// created). An unknown folder gives an empty string.
WMC_API void GetSpecialFolderPath(int folder, WCHAR *path, int size) {
    char buffer[1024];
    if (!path || size <= 0) return;
    if (!wmc_special_folder(folder, (folder & 0x8000) != 0, buffer, sizeof buffer)) {
        WLOG("todo", "GetSpecialFolderPath(%#x) has no counterpart", folder);
        buffer[0] = 0;
    }
    wmc_utf16_copy(path, (size_t)size, buffer);
}

// The name Windows shows for a special folder.
WMC_API void GetSpecialFolderName(int folder, WCHAR *name, int size) {
    if (!name || size <= 0) return;
    const char *text;
    switch (folder & 0xff) {
        case 0x35: text = "Public Music"; break;
        case 0x36: text = "Public Pictures"; break;
        case 0x37: text = "Public Videos"; break;
        case 0x2e: text = "Public Documents"; break;
        default: {
            char buffer[1024];
            if (!wmc_special_folder(folder, false, buffer, sizeof buffer)) buffer[0] = 0;
            const char *slash = strrchr(buffer, '/');
            wmc_utf16_copy(name, (size_t)size, slash ? slash + 1 : buffer);
            return;
        }
    }
    wmc_utf16_copy(name, (size_t)size, text);
}

// The folder Media Center's own programs are in.
WMC_API void GetBinaryFolderPath(WCHAR *path, int size) {
    char buffer[1024];
    if (!path || size <= 0) return;
    wmc_special_folder(0x24, false, buffer, sizeof buffer);
    strlcat(buffer, "/ehome", sizeof buffer);
    wmc_utf16_copy(path, (size_t)size, buffer);
}

// Authenticode: is this file signed by Microsoft? Signatures cannot be
// checked here. The only files asked about are downloaded add-on packages,
// which never arrive (the services are gone), so the answer is no.
WMC_API BOOL IsFileMicrosoftTrusted(const WCHAR *file, const WCHAR *compareWith) {
    return FALSE;
}
