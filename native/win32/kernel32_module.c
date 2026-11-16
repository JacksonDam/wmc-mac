// kernel32: LoadLibrary, module handles and Win32 resources.
//
// Media Center keeps its markup, images, sounds and strings as resources
// inside DLLs (ehres.dll above all). Nothing in those DLLs is executed here:
// a module is the file mapped read-only, and the resource functions walk its
// resource directory.
#include "module.h"
#include "paths.h"

#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    uint32_t rva, vsize, raw, rawsize;
} Section;

struct WmcModule {
    struct WmcModule *next;
    char *host_path;
    char *file_name;
    const uint8_t *base;
    size_t size;
    Section *sections;
    int nsections;
    const uint8_t *rsrc;      // start of the resource directory, or NULL
    uint32_t rsrc_size;
    struct WmcModule *mui;
    bool mui_tried;
};

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static WmcModule *s_modules;
static WmcModule *s_main;

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

static const uint8_t *rva_ptr(WmcModule *m, uint32_t rva) {
    for (int i = 0; i < m->nsections; i++) {
        Section *s = &m->sections[i];
        uint32_t span = s->vsize > s->rawsize ? s->vsize : s->rawsize;
        if (rva >= s->rva && rva < s->rva + span) {
            uint32_t off = rva - s->rva + s->raw;
            return off < m->size ? m->base + off : NULL;
        }
    }
    return NULL;
}

static WmcModule *map_file(const char *host_path) {
    int fd = open(host_path, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 0x100) {
        close(fd);
        return NULL;
    }
    const uint8_t *base = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (base == MAP_FAILED) return NULL;
    size_t size = (size_t)st.st_size;
    uint32_t pe = rd32(base + 0x3C);
    if (base[0] != 'M' || base[1] != 'Z' || pe + 0x120 > size || rd32(base + pe) != 0x00004550) {
        munmap((void *)base, size);
        return NULL;
    }
    WmcModule *m = calloc(1, sizeof(*m));
    m->host_path = strdup(host_path);
    const char *slash = strrchr(host_path, '/');
    m->file_name = strdup(slash ? slash + 1 : host_path);
    m->base = base;
    m->size = size;
    const uint8_t *coff = base + pe + 4;
    const uint8_t *opt = coff + 20;
    m->nsections = rd16(coff + 2);
    const uint8_t *sec = opt + rd16(coff + 16);
    m->sections = calloc((size_t)m->nsections + 1, sizeof(Section));
    for (int i = 0; i < m->nsections && sec + 40 <= base + size; i++, sec += 40) {
        m->sections[i] = (Section){ rd32(sec + 12), rd32(sec + 8), rd32(sec + 20), rd32(sec + 16) };
    }
    const uint8_t *dirs = opt + (rd16(opt) == 0x20B ? 112 : 96);
    uint32_t rsrc_rva = rd32(dirs + 2 * 8);
    m->rsrc_size = rd32(dirs + 2 * 8 + 4);
    if (rsrc_rva) m->rsrc = rva_ptr(m, rsrc_rva);
    return m;
}

static WmcModule *open_host(const char *host_path) {
    pthread_mutex_lock(&s_lock);
    WmcModule *m;
    for (m = s_modules; m; m = m->next) {
        if (strcasecmp(m->host_path, host_path) == 0) break;
    }
    if (!m) {
        m = map_file(host_path);
        if (m) {
            m->next = s_modules;
            s_modules = m;
        }
    }
    pthread_mutex_unlock(&s_lock);
    return m;
}

WmcModule *wmc_module_open(const WCHAR *name) {
    char *utf8 = wmc_utf8(name);
    WmcModule *m = NULL;
    bool bare = !strchr(utf8, '\\') && !strchr(utf8, '/') && !strchr(utf8, ':');
    if (bare) {
        // A bare name is searched for the way Windows would find it: beside
        // the program first.
        const char *ext = strrchr(utf8, '.');
        char win[1024];
        snprintf(win, sizeof(win), "%s\\%s%s", wmc_ehome_dir(), utf8, ext ? "" : ".dll");
        char *host = wmc_host_path_utf8(win);
        m = open_host(host);
        free(host);
    } else {
        char *host = wmc_host_path_utf8(utf8);
        m = open_host(host);
        free(host);
    }
    WLOG("mod", "open \"%s\" -> %s", utf8, m ? m->host_path : "(not found)");
    free(utf8);
    return m;
}

WmcModule *wmc_module_main(void) {
    if (!s_main) {
        WCHAR *w = wmc_utf16("ehshell.exe");
        s_main = wmc_module_open(w);
        free(w);
    }
    return s_main;
}

WmcModule *wmc_module_from_handle(HMODULE handle) {
    if (!handle) return wmc_module_main();
    // A data-file handle carries flag bits in its low two bits on Windows.
    WmcModule *want = (WmcModule *)((uintptr_t)handle & ~(uintptr_t)3);
    WmcModule *found = NULL;
    pthread_mutex_lock(&s_lock);
    for (WmcModule *m = s_modules; m; m = m->next) {
        if (m == want) { found = m; break; }
    }
    pthread_mutex_unlock(&s_lock);
    return found;
}

const char *wmc_module_name(WmcModule *m) { return m->file_name; }

// Language resources live beside the module: <dir>/<lang>/<name>.mui.
static WmcModule *module_mui(WmcModule *m) {
    if (m->mui_tried) return m->mui;
    m->mui_tried = true;
    const char *lang = getenv("WMC_LANG");
    if (!lang || !*lang) lang = "en-US";
    const char *slash = strrchr(m->host_path, '/');
    if (!slash) return NULL;
    char path[2048];
    snprintf(path, sizeof(path), "%.*s/%s/%s.mui", (int)(slash - m->host_path), m->host_path, lang, m->file_name);
    m->mui = open_host(path);
    if (!m->mui && strcmp(lang, "en-US") != 0) {
        snprintf(path, sizeof(path), "%.*s/en-US/%s.mui", (int)(slash - m->host_path), m->host_path, m->file_name);
        m->mui = open_host(path);
    }
    // A Media Center in one other language (from a German Windows, say) has
    // only that language's folder: use whichever folder has the file.
    if (!m->mui) {
        char dir[2048];
        snprintf(dir, sizeof(dir), "%.*s", (int)(slash - m->host_path), m->host_path);
        DIR *d = opendir(dir);
        struct dirent *e;
        while (d && !m->mui && (e = readdir(d))) {
            if (e->d_name[0] == '.' || !strchr(e->d_name, '-')) continue;
            snprintf(path, sizeof(path), "%s/%s/%s.mui", dir, e->d_name, m->file_name);
            if (access(path, R_OK) == 0) m->mui = open_host(path);
        }
        if (d) closedir(d);
    }
    return m->mui;
}

// ---- the resource directory --------------------------------------------------

static bool key_is_int(const WCHAR *key, uint32_t *value) {
    if ((uintptr_t)key < 0x10000) {
        *value = (uint32_t)(uintptr_t)key;
        return true;
    }
    if (key[0] == '#') {
        uint32_t v = 0;
        for (const WCHAR *p = key + 1; *p >= '0' && *p <= '9'; p++) v = v * 10 + (uint32_t)(*p - '0');
        *value = v;
        return true;
    }
    return false;
}

static WCHAR upper(WCHAR c) { return (c >= 'a' && c <= 'z') ? (WCHAR)(c - 32) : c; }

// Finds a child of a directory by integer id or by name. Returns the entry's
// OffsetToData field value, or 0.
static uint32_t dir_find(WmcModule *m, uint32_t dir_off, const WCHAR *key) {
    if (dir_off + 16 > m->rsrc_size) return 0;
    const uint8_t *dir = m->rsrc + dir_off;
    int named = rd16(dir + 12), ids = rd16(dir + 14);
    const uint8_t *e = dir + 16;
    uint32_t id;
    if (key_is_int(key, &id)) {
        for (int i = named; i < named + ids; i++) {
            if (rd32(e + i * 8) == id) return rd32(e + i * 8 + 4);
        }
        return 0;
    }
    size_t len = wmc_wcslen(key);
    for (int i = 0; i < named; i++) {
        uint32_t noff = rd32(e + i * 8) & 0x7FFFFFFF;
        if (noff + 2 > m->rsrc_size) continue;
        const uint8_t *s = m->rsrc + noff;
        if (rd16(s) != len) continue;
        bool same = true;
        for (size_t k = 0; k < len && same; k++) same = upper(rd16(s + 2 + k * 2)) == upper(key[k]);
        if (same) return rd32(e + i * 8 + 4);
    }
    return 0;
}

static const void *find_in(WmcModule *m, const WCHAR *type, const WCHAR *name, uint16_t lang) {
    if (!m || !m->rsrc) return NULL;
    uint32_t t = dir_find(m, 0, type);
    if (!(t & 0x80000000)) return NULL;
    uint32_t n = dir_find(m, t & 0x7FFFFFFF, name);
    if (!(n & 0x80000000)) return NULL;
    uint32_t langdir = n & 0x7FFFFFFF;
    uint32_t leaf = lang ? dir_find(m, langdir, (const WCHAR *)(uintptr_t)lang) : 0;
    if (!leaf) {
        // Any language will do: take the first entry.
        if (langdir + 16 > m->rsrc_size) return NULL;
        const uint8_t *dir = m->rsrc + langdir;
        if (rd16(dir + 12) + rd16(dir + 14) == 0) return NULL;
        leaf = rd32(dir + 16 + 4);
    }
    if (leaf & 0x80000000 || leaf + 16 > m->rsrc_size) return NULL;
    return m->rsrc + leaf;
}

const void *wmc_module_find_resource(WmcModule *m, const WCHAR *type, const WCHAR *name, uint16_t lang) {
    const void *r = find_in(m, type, name, lang);
    if (!r) r = find_in(module_mui(m), type, name, lang);
    return r;
}

static WmcModule *module_containing(const void *p) {
    WmcModule *found = NULL;
    pthread_mutex_lock(&s_lock);
    for (WmcModule *m = s_modules; m; m = m->next) {
        if ((const uint8_t *)p >= m->base && (const uint8_t *)p < m->base + m->size) { found = m; break; }
    }
    pthread_mutex_unlock(&s_lock);
    return found;
}

const void *wmc_resource_data(const void *entry, uint32_t *size) {
    WmcModule *m = module_containing(entry);
    if (!m) return NULL;
    const uint8_t *e = entry;
    if (size) *size = rd32(e + 4);
    return rva_ptr(m, rd32(e));
}

// ---- exported -----------------------------------------------------------------

WMC_API HMODULE LoadLibraryExW(const WCHAR *name, HANDLE file, DWORD flags) {
    WmcModule *m = name ? wmc_module_open(name) : NULL;
    if (!m) wmc_set_last_error(126);   // ERROR_MOD_NOT_FOUND
    return (HMODULE)m;
}

WMC_API HMODULE LoadLibraryW(const WCHAR *name) { return LoadLibraryExW(name, NULL, 0); }

WMC_API BOOL FreeLibrary(HMODULE module) { return TRUE; }

WMC_API HMODULE GetModuleHandleW(const WCHAR *name) {
    WmcModule *m = name ? wmc_module_open(name) : wmc_module_main();
    if (!m) wmc_set_last_error(126);
    return (HMODULE)m;
}

WMC_API DWORD GetModuleFileNameW(HMODULE module, WCHAR *buffer, DWORD size) {
    WmcModule *m = wmc_module_from_handle(module);
    char path[1024];
    snprintf(path, sizeof(path), "%s\\%s", wmc_ehome_dir(), m ? m->file_name : "ehshell.exe");
    return (DWORD)wmc_utf16_copy(buffer, size, path);
}

WMC_API UINT GetWindowsDirectoryW(WCHAR *buffer, UINT size) {
    return (UINT)wmc_utf16_copy(buffer, size, wmc_windows_dir());
}

WMC_API UINT GetSystemDirectoryW(WCHAR *buffer, UINT size) {
    return (UINT)wmc_utf16_copy(buffer, size, "C:\\Windows\\System32");
}

WMC_API const void *FindResourceW(HMODULE module, const WCHAR *name, const WCHAR *type) {
    WmcModule *m = wmc_module_from_handle(module);
    const void *r = m ? wmc_module_find_resource(m, type, name, 0) : NULL;
    if (!r) wmc_set_last_error(1814);   // ERROR_RESOURCE_NAME_NOT_FOUND
    return r;
}

WMC_API const void *FindResourceExW(HMODULE module, const WCHAR *type, const WCHAR *name, uint16_t lang) {
    WmcModule *m = wmc_module_from_handle(module);
    const void *r = m ? wmc_module_find_resource(m, type, name, lang) : NULL;
    if (!r) wmc_set_last_error(1814);
    return r;
}

WMC_API const void *wmcapi_LoadResource(HMODULE module, const void *resInfo) {
    return resInfo ? wmc_resource_data(resInfo, NULL) : NULL;
}

WMC_API const void *LockResource(const void *resData) { return resData; }

WMC_API DWORD SizeofResource(HMODULE module, const void *resInfo) {
    uint32_t size = 0;
    if (resInfo) wmc_resource_data(resInfo, &size);
    return size;
}

typedef BOOL (*ENUMRESNAMEPROCW)(HMODULE module, const WCHAR *type, WCHAR *name, LONG_PTR param);

static BOOL enum_names(WmcModule *m, HMODULE handle, const WCHAR *type, ENUMRESNAMEPROCW proc, LONG_PTR param,
                       bool *any) {
    if (!m || !m->rsrc) return TRUE;
    uint32_t t = dir_find(m, 0, type);
    if (!(t & 0x80000000)) return TRUE;
    const uint8_t *dir = m->rsrc + (t & 0x7FFFFFFF);
    int named = rd16(dir + 12), ids = rd16(dir + 14);
    for (int i = 0; i < named + ids; i++) {
        uint32_t key = rd32(dir + 16 + i * 8);
        *any = true;
        if (key & 0x80000000) {
            const uint8_t *s = m->rsrc + (key & 0x7FFFFFFF);
            uint16_t len = rd16(s);
            WCHAR *name = calloc((size_t)len + 1, sizeof(WCHAR));
            memcpy(name, s + 2, (size_t)len * 2);
            BOOL go = proc(handle, type, name, param);
            free(name);
            if (!go) return FALSE;
        } else if (!proc(handle, type, (WCHAR *)(uintptr_t)key, param)) {
            return FALSE;
        }
    }
    return TRUE;
}

WMC_API BOOL EnumResourceNamesW(HMODULE module, const WCHAR *type, ENUMRESNAMEPROCW proc, LONG_PTR param) {
    WmcModule *m = wmc_module_from_handle(module);
    if (!m) return FALSE;
    bool any = false;
    if (!enum_names(m, module, type, proc, param, &any)) return TRUE;
    if (!any) enum_names(module_mui(m), module, type, proc, param, &any);
    if (!any) wmc_set_last_error(1813);   // ERROR_RESOURCE_TYPE_NOT_FOUND
    return any;
}
