// Windows paths to Mac paths.
//
// Media Center believes it is installed in C:\Windows\ehome on a C: drive.
// Two folders back that belief:
//   WMC_WINDIR   stands for C:\Windows   (so <WMC_WINDIR>/ehome is the app)
//   WMC_DRIVE_C  stands for C:\          (user data, ProgramData, ...)
// A path that already starts with "/" is a Mac path and passes through, so
// either form works anywhere.
#include "paths.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *windir(void) {
    static char *dir;
    if (!dir) {
        const char *env = getenv("WMC_WINDIR");
        dir = strdup(env && *env ? env : ".");
    }
    return dir;
}

static const char *drive_c(void) {
    static char *dir;
    if (!dir) {
        const char *env = getenv("WMC_DRIVE_C");
        if (env && *env) {
            dir = strdup(env);
        } else {
            size_t n = strlen(windir()) + 16;
            dir = malloc(n);
            snprintf(dir, n, "%s/drive_c", windir());
        }
    }
    return dir;
}

static bool has_prefix_nocase(const char *s, const char *prefix) {
    size_t n = strlen(prefix);
    return strncasecmp(s, prefix, n) == 0 && (s[n] == 0 || s[n] == '/');
}

char *wmc_host_path_utf8(const char *win) {
    if (!win) return NULL;
    size_t len = strlen(win);
    char *p = malloc(len + 1);
    for (size_t i = 0; i <= len; i++) p[i] = win[i] == '\\' ? '/' : win[i];
    char *s = p;
    if (strncmp(s, "//?/", 4) == 0) s += 4;          // \\?\ long-path prefix
    if (strncasecmp(s, "file:///", 8) == 0) s += 8;
    char *out;
    if (isalpha((unsigned char)s[0]) && s[1] == ':') {
        const char *rest = s + 2;
        while (*rest == '/') rest++;
        const char *root = drive_c();
        if (tolower((unsigned char)s[0]) == 'c' && has_prefix_nocase(rest, "windows")) {
            root = windir();
            rest += 7;
            while (*rest == '/') rest++;
            // System32 and SysWOW64 hold nothing of ours; the app's own
            // libraries all live in ehome.
        }
        size_t n = strlen(root) + strlen(rest) + 2;
        out = malloc(n);
        snprintf(out, n, "%s/%s", root, rest);
    } else {
        out = strdup(s);
    }
    free(p);
    return out;
}

char *wmc_host_path(const WCHAR *win) {
    char *utf8 = wmc_utf8(win);
    char *out = wmc_host_path_utf8(utf8);
    free(utf8);
    return out;
}

const char *wmc_windows_dir(void) { return "C:\\Windows"; }
const char *wmc_ehome_dir(void) { return "C:\\Windows\\ehome"; }

// ---- special folders ------------------------------------------------------------

#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

const char *wmc_drive_c_dir(void) {
    return drive_c();
}

const char *wmc_media_home(void) {
    static char *home;
    if (!home) {
        const char *env = getenv("WMC_MEDIA_HOME");
        if (env && *env) {
            home = strdup(env);
        } else {
            struct passwd *pw = getpwuid(getuid());
            home = strdup(pw && pw->pw_dir ? pw->pw_dir : "/tmp");
        }
    }
    return home;
}

static void make_dirs(const char *path) {
    char *copy = strdup(path);
    for (char *p = copy + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(copy, 0755);
            *p = '/';
        }
    }
    mkdir(copy, 0755);
    free(copy);
}

bool wmc_special_folder(int csidl, bool create, char *out, size_t size) {
    const char *user = "User";
    const char *media = NULL;    // under the user's own home
    const char *ours = NULL;     // under C:
    char buffer[1024];
    switch (csidl & 0xff) {
        case 0x00: case 0x10: media = "Desktop"; break;          // Desktop, DesktopDirectory
        case 0x05: media = "Documents"; break;                   // Personal
        case 0x0d: media = "Music"; break;                       // MyMusic
        case 0x0e: media = "Movies"; break;                      // MyVideos
        case 0x27: media = "Pictures"; break;                    // MyPictures
        case 0x1a: snprintf(buffer, sizeof buffer, "Users/%s/AppData/Roaming", user); ours = buffer; break;
        case 0x1c: snprintf(buffer, sizeof buffer, "Users/%s/AppData/Local", user); ours = buffer; break;
        case 0x20: snprintf(buffer, sizeof buffer, "Users/%s/AppData/Local/Microsoft/Windows/INetCache", user); ours = buffer; break;
        case 0x28: snprintf(buffer, sizeof buffer, "Users/%s", user); ours = buffer; break;
        case 0x02: snprintf(buffer, sizeof buffer, "Users/%s/AppData/Roaming/Microsoft/Windows/Start Menu/Programs", user); ours = buffer; break;
        case 0x17: ours = "ProgramData/Microsoft/Windows/Start Menu/Programs"; break;
        case 0x23: ours = "ProgramData"; break;                  // CommonApplicationData
        case 0x26: ours = "Program Files"; break;
        case 0x2e: ours = "Users/Public/Documents"; break;
        case 0xfe: ours = "Users/Public"; break;                 // (no CSIDL: FOLDERID_Public, see shlwapi.c)
        case 0x35: ours = "Users/Public/Music"; break;
        case 0x36: ours = "Users/Public/Pictures"; break;
        case 0x37: ours = "Users/Public/Videos"; break;
        case 0x24: snprintf(out, size, "%s", windir()); return true;              // Windows
        case 0x25: snprintf(out, size, "%s/System32", windir()); return true;     // System
        default: if (size) out[0] = 0; return false;
    }
    if (media) {
        snprintf(out, size, "%s/%s", wmc_media_home(), media);
        return true;
    }
    snprintf(out, size, "%s/%s", drive_c(), ours);
    // (ours to make: Media Center expects these to exist)
    (void)create;
    make_dirs(out);
    return true;
}

// For the managed side (WmcStandins): the same answer as a UTF-8 string.
WMC_API int wmc_special_folder_path(int csidl, char *out, int size) {
    return wmc_special_folder(csidl, (csidl & 0x8000) != 0, out, (size_t)size) ? 1 : 0;
}

// For the managed side: a Windows path (or a Mac path with backslashes) as
// a Mac path, UTF-8.
WMC_API int wmc_fix_path(const char *path, char *out, int size) {
    if (!path || !out || size <= 0) return 0;
    char *host = wmc_host_path_utf8(path);
    if (!host) return 0;
    snprintf(out, (size_t)size, "%s", host);
    free(host);
    return 1;
}
