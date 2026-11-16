// shlwapi: small path and string helpers. Paths may use either slash.
// shell32: known folders (at the end).
#include "wmc.h"
#include "paths.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wctype.h>

static bool is_slash(WCHAR c) { return c == '/' || c == '\\'; }

static size_t wlen(const WCHAR *s) {
    size_t n = 0;
    while (s && s[n]) n++;
    return n;
}

// Takes a trailing slash off a path (but leaves a root alone). Returns where
// the path now ends.
WMC_API WCHAR *PathRemoveBackslashW(WCHAR *path) {
    if (!path) return NULL;
    size_t n = wlen(path);
    if (n > 1 && is_slash(path[n - 1]) && path[n - 2] != ':') path[--n] = 0;
    return path + (n ? n - 1 : 0);
}
WMC_API WCHAR *PathRemoveBackslash(WCHAR *path) { return PathRemoveBackslashW(path); }

// The folders two paths share from the start. Returns the length and, if a
// buffer is given (260 characters), the shared path.
WMC_API int PathCommonPrefixW(const WCHAR *a, const WCHAR *b, WCHAR *out) {
    if (out) out[0] = 0;
    if (!a || !b) return 0;
    size_t i = 0, shared = 0;
    for (;; i++) {
        bool endA = a[i] == 0 || is_slash(a[i]), endB = b[i] == 0 || is_slash(b[i]);
        if (endA && endB) {
            shared = i;
            if (a[i] == 0 || b[i] == 0) break;
            continue;
        }
        if (endA || endB) break;
        if (towlower(a[i]) != towlower(b[i])) break;
    }
    if (shared == 0 && is_slash(a[0]) && is_slash(b[0])) shared = 1;   // only the root
    if (shared >= 260) shared = 259;
    if (out) {
        memcpy(out, a, shared * sizeof(WCHAR));
        out[shared] = 0;
    }
    return (int)shared;
}
WMC_API int PathCommonPrefix(const WCHAR *a, const WCHAR *b, WCHAR *out) { return PathCommonPrefixW(a, b, out); }

// Compares names the way Explorer sorts them: runs of digits by their value
// ("2" before "10"), the rest without regard to case.
WMC_API int StrCmpLogicalW(const WCHAR *a, const WCHAR *b) {
    if (!a || !b) return a ? 1 : (b ? -1 : 0);
    while (*a && *b) {
        if (iswdigit(*a) && iswdigit(*b)) {
            while (*a == '0') a++;
            while (*b == '0') b++;
            const WCHAR *startA = a, *startB = b;
            while (iswdigit(*a)) a++;
            while (iswdigit(*b)) b++;
            size_t lenA = (size_t)(a - startA), lenB = (size_t)(b - startB);
            if (lenA != lenB) return lenA < lenB ? -1 : 1;
            for (size_t i = 0; i < lenA; i++)
                if (startA[i] != startB[i]) return startA[i] < startB[i] ? -1 : 1;
            continue;
        }
        wint_t x = towlower(*a), y = towlower(*b);
        if (x != y) return x < y ? -1 : 1;
        a++;
        b++;
    }
    return *a ? 1 : (*b ? -1 : 0);
}

// ---- shell32: known folders ----------------------------------------------------------
// SHGetFolderPathEx names a folder by its KNOWNFOLDERID (a GUID) instead of a
// CSIDL number. The folders Media Center asks for, by the CSIDL with the
// same meaning (paths.c), as Mac paths.

typedef struct { uint32_t d1; uint16_t d2, d3; uint8_t d4[8]; } WmcGuid;

static const struct { const char *id; int csidl; } kKnownFolders[] = {
    { "DFDF76A2-C82A-4D63-906A-5644AC457385", 0xfe },   // Public
    { "5E6C858F-0E22-4760-9AFE-EA3317B67173", 0x28 },   // Profile
    { "FDD39AD0-238F-46AF-ADB4-6C85480369C7", 0x05 },   // Documents
    { "4BD8D571-6D19-48D3-BE97-422220080E43", 0x0d },   // Music
    { "33E28130-4E1E-4676-835A-98395C3BC3BB", 0x27 },   // Pictures
    { "18989B1D-99B5-455B-841C-AB7C74E4DDFC", 0x0e },   // Videos
    { "ED4824AF-DCE4-45A8-81E2-FC7965083634", 0x2e },   // PublicDocuments
    { "3214FAB5-9757-4298-BB61-92A9DEAA44FF", 0x35 },   // PublicMusic
    { "B6EBFB86-6907-413C-9AF7-4FC2ABF07CC5", 0x36 },   // PublicPictures
    { "2400183A-6185-49FB-A2D8-4A392A602BA3", 0x37 },   // PublicVideos
    { "62AB5D82-FDC1-4DC3-A9DD-070D1D495D97", 0x23 },   // ProgramData
    { "F1B32785-6FBA-4FCF-9D55-7B8E7F157091", 0x1c },   // LocalAppData
    { "3EB685DB-65F9-4CF6-A03A-E3EF65729F3D", 0x1a },   // RoamingAppData
};

static bool guid_is(const WmcGuid *g, const char *text) {
    unsigned d1, d2, d3, b[8];
    if (sscanf(text, "%8x-%4x-%4x-%2x%2x-%2x%2x%2x%2x%2x%2x", &d1, &d2, &d3, &b[0], &b[1], &b[2], &b[3], &b[4], &b[5],
               &b[6], &b[7]) != 11)
        return false;
    if (g->d1 != d1 || g->d2 != d2 || g->d3 != d3) return false;
    for (int i = 0; i < 8; i++)
        if (g->d4[i] != b[i]) return false;
    return true;
}

WMC_API int32_t SHGetFolderPathEx(const WmcGuid *id, uint32_t flags, void *token, WCHAR *path, uint32_t capacity) {
    if (path && capacity) path[0] = 0;
    if (!id) return (int32_t)0x80070057;                        // E_INVALIDARG
    for (size_t i = 0; i < sizeof kKnownFolders / sizeof kKnownFolders[0]; i++) {
        if (!guid_is(id, kKnownFolders[i].id)) continue;
        char buffer[1024];
        if (!wmc_special_folder(kKnownFolders[i].csidl, (flags & 0x8000) != 0, buffer, sizeof buffer)) break;
        if (path && capacity) wmc_utf16_copy(path, capacity, buffer);
        return 0;
    }
    return (int32_t)0x80070002;                                  // HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)
}
WMC_API int32_t SHGetFolderPathExW(const WmcGuid *id, uint32_t flags, void *token, WCHAR *path, uint32_t capacity) {
    return SHGetFolderPathEx(id, flags, token, path, capacity);
}
