// kernel32 / shlwapi: looking at files and folders.
//
// Paths arrive either as Windows paths (C:\...) or, for the user's own
// folders, as Mac paths; wmc_host_path takes both. Names that start with a
// dot and folders that are another program's package (a Photos library, an
// app) are left out of listings, as the Finder leaves them out.
#include "wmc.h"
#include "paths.h"

#include <dirent.h>
#include <fnmatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>

#define FILE_ATTRIBUTE_READONLY 0x1
#define FILE_ATTRIBUTE_DIRECTORY 0x10
#define FILE_ATTRIBUTE_ARCHIVE 0x20
#define INVALID_FILE_ATTRIBUTES 0xFFFFFFFFu
#define ERROR_FILE_NOT_FOUND 2
#define ERROR_PATH_NOT_FOUND 3
#define ERROR_NO_MORE_FILES 18
#define ERROR_ALREADY_EXISTS 183
#define ERROR_INVALID_HANDLE 6
#define ERROR_NOT_ENOUGH_MEMORY 8

typedef struct __attribute__((packed)) {
    uint32_t attributes;
    uint64_t created, accessed, written;      // FILETIMEs
    uint32_t sizeHigh, sizeLow;
    uint32_t reserved0, reserved1;
    WCHAR name[260];
    WCHAR shortName[14];
} WmcFindData;
_Static_assert(sizeof(WmcFindData) == 592, "WIN32_FIND_DATAW");

typedef struct __attribute__((packed)) {
    uint32_t attributes;
    uint64_t created, accessed, written;
    uint32_t sizeHigh, sizeLow;
} WmcFileAttributeData;
_Static_assert(sizeof(WmcFileAttributeData) == 36, "WIN32_FILE_ATTRIBUTE_DATA");

// 100 ns ticks since 1601.
static uint64_t filetime(struct timespec t) {
    return ((uint64_t)t.tv_sec + 11644473600ull) * 10000000ull + (uint64_t)t.tv_nsec / 100;
}

static bool is_package(const char *name) {
    const char *dot = strrchr(name, '.');
    if (!dot) return false;
    size_t n = strlen(dot);
    if (n >= 8 && strcasecmp(dot + n - 7, "library") == 0) return true;   // .photoslibrary, .musiclibrary, ...
    return strcasecmp(dot, ".app") == 0 || strcasecmp(dot, ".bundle") == 0 || strcasecmp(dot, ".fcpbundle") == 0 ||
           strcasecmp(dot, ".band") == 0 || strcasecmp(dot, ".logicx") == 0;
}

static uint32_t attributes_of(const struct stat *st) {
    if (S_ISDIR(st->st_mode)) return FILE_ATTRIBUTE_DIRECTORY;
    uint32_t a = FILE_ATTRIBUTE_ARCHIVE;
    if (!(st->st_mode & S_IWUSR)) a |= FILE_ATTRIBUTE_READONLY;
    return a;
}

// ---- FindFirstFile ---------------------------------------------------------------

typedef struct {
    uint32_t magic;
    DIR *dir;
    char *folder;
    char *pattern;
} WmcFind;
#define WMC_FIND_MAGIC 0x444e4946u   // 'FIND'

static bool next_entry(WmcFind *f, WmcFindData *out) {
    struct dirent *e;
    while ((e = readdir(f->dir)) != NULL) {
        if (e->d_name[0] == '.') continue;
        if (fnmatch(f->pattern, e->d_name, FNM_CASEFOLD) != 0) continue;
        char path[MAXPATHLEN];
        snprintf(path, sizeof path, "%s/%s", f->folder, e->d_name);
        struct stat st;
        if (stat(path, &st) != 0) continue;
        if (S_ISDIR(st.st_mode) && is_package(e->d_name)) continue;
        if (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)) continue;
        memset(out, 0, sizeof *out);
        out->attributes = attributes_of(&st);
        out->created = filetime(st.st_birthtimespec);
        out->accessed = filetime(st.st_atimespec);
        out->written = filetime(st.st_mtimespec);
        if (!S_ISDIR(st.st_mode)) {
            out->sizeHigh = (uint32_t)((uint64_t)st.st_size >> 32);
            out->sizeLow = (uint32_t)st.st_size;
        }
        wmc_utf16_copy(out->name, 260, e->d_name);
        return true;
    }
    return false;
}

WMC_API void *FindFirstFileW(const WCHAR *pattern, WmcFindData *data) {
    char *path = wmc_host_path(pattern);
    if (!path || !data) { free(path); wmc_set_last_error(ERROR_PATH_NOT_FOUND); return (void *)(intptr_t)-1; }
    // "folder/pattern": the last component may hold wildcards.
    char *slash = strrchr(path, '/');
    const char *last = slash ? slash + 1 : path;
    char *folder;
    if (slash == path) folder = strdup("/");
    else if (slash) { *slash = 0; folder = strdup(path); }
    else folder = strdup(".");
    char *wanted = strdup(strcmp(last, "*.*") == 0 || *last == 0 ? "*" : last);
    free(path);
    DIR *dir = opendir(folder);
    WLOG("file", "FindFirstFile %s / %s%s", folder, wanted, dir ? "" : " (no such folder)");
    if (!dir) {
        free(folder); free(wanted);
        wmc_set_last_error(ERROR_PATH_NOT_FOUND);
        return (void *)(intptr_t)-1;
    }
    WmcFind *f = calloc(1, sizeof *f);
    f->magic = WMC_FIND_MAGIC;
    f->dir = dir;
    f->folder = folder;
    f->pattern = wanted;
    if (!next_entry(f, data)) {
        closedir(dir); free(folder); free(wanted); free(f);
        wmc_set_last_error(ERROR_FILE_NOT_FOUND);
        return (void *)(intptr_t)-1;
    }
    return f;
}

WMC_API WINBOOL FindNextFileW(void *handle, WmcFindData *data) {
    WmcFind *f = handle;
    if (!f || handle == (void *)(intptr_t)-1 || f->magic != WMC_FIND_MAGIC || !data) return FALSE;
    if (next_entry(f, data)) return TRUE;
    wmc_set_last_error(ERROR_NO_MORE_FILES);
    return FALSE;
}

WMC_API WINBOOL FindClose(void *handle) {
    WmcFind *f = handle;
    if (!f || handle == (void *)(intptr_t)-1 || f->magic != WMC_FIND_MAGIC) return FALSE;
    f->magic = 0;
    closedir(f->dir);
    free(f->folder);
    free(f->pattern);
    free(f);
    return TRUE;
}

WMC_API void *FindFirstFile(const WCHAR *pattern, WmcFindData *data) { return FindFirstFileW(pattern, data); }
WMC_API WINBOOL FindNextFile(void *handle, WmcFindData *data) { return FindNextFileW(handle, data); }

// ---- attributes ------------------------------------------------------------------

static bool stat_win(const WCHAR *name, struct stat *st) {
    char *path = wmc_host_path(name);
    bool ok = path && stat(path, st) == 0;
    free(path);
    return ok;
}

WMC_API uint32_t GetFileAttributesW(const WCHAR *name) {
    struct stat st;
    if (!stat_win(name, &st)) { wmc_set_last_error(ERROR_FILE_NOT_FOUND); return INVALID_FILE_ATTRIBUTES; }
    return attributes_of(&st);
}

WMC_API WINBOOL GetFileAttributesExW(const WCHAR *name, int level, WmcFileAttributeData *data) {
    struct stat st;
    if (!data || !stat_win(name, &st)) { wmc_set_last_error(ERROR_FILE_NOT_FOUND); return FALSE; }
    memset(data, 0, sizeof *data);
    data->attributes = attributes_of(&st);
    data->created = filetime(st.st_birthtimespec);
    data->accessed = filetime(st.st_atimespec);
    data->written = filetime(st.st_mtimespec);
    if (!S_ISDIR(st.st_mode)) {
        data->sizeHigh = (uint32_t)((uint64_t)st.st_size >> 32);
        data->sizeLow = (uint32_t)st.st_size;
    }
    return TRUE;
}

// Windows-only attributes (hidden, system) have nowhere to go; accepted.
WMC_API uint32_t SetFileAttributesW(const WCHAR *name, uint32_t attributes) { return 1; }

WMC_API uint32_t GetFileAttributes(const WCHAR *name) { return GetFileAttributesW(name); }
WMC_API WINBOOL GetFileAttributesEx(const WCHAR *name, int level, WmcFileAttributeData *data) { return GetFileAttributesExW(name, level, data); }
WMC_API uint32_t SetFileAttributes(const WCHAR *name, uint32_t attributes) { return 1; }

// ---- drives ----------------------------------------------------------------------

// 3 is a fixed disk, 4 a network share, 1 "no such root".
WMC_API uint32_t GetDriveTypeW(const WCHAR *root) {
    char *path = wmc_host_path(root);
    struct statfs fs;
    uint32_t type = 1;
    if (path && statfs(path, &fs) == 0) type = (fs.f_flags & MNT_LOCAL) ? 3 : 4;
    free(path);
    return type;
}
WMC_API uint32_t GetDriveType(const WCHAR *root) { return GetDriveTypeW(root); }

WMC_API int GetDiskFreeSpaceExW(const WCHAR *folder, uint64_t *freeToCaller, uint64_t *total, uint64_t *freeTotal) {
    char *path = wmc_host_path(folder);
    struct statfs fs;
    bool ok = path && statfs(path, &fs) == 0;
    free(path);
    if (!ok) { wmc_set_last_error(ERROR_PATH_NOT_FOUND); return 0; }
    if (freeToCaller) *freeToCaller = (uint64_t)fs.f_bavail * fs.f_bsize;
    if (total) *total = (uint64_t)fs.f_blocks * fs.f_bsize;
    if (freeTotal) *freeTotal = (uint64_t)fs.f_bfree * fs.f_bsize;
    return 1;
}
WMC_API int GetDiskFreeSpaceEx(const WCHAR *folder, uint64_t *a, uint64_t *b, uint64_t *c) { return GetDiskFreeSpaceExW(folder, a, b, c); }

// The volume's name: the last part of where it is mounted.
WMC_API WINBOOL GetVolumeInformationW(const WCHAR *root, WCHAR *name, int nameSize, uint32_t *serial, uint32_t *maxComponent,
                                      uint32_t *flags, WCHAR *fsName, int fsNameSize) {
    char *path = wmc_host_path(root);
    struct statfs fs;
    bool ok = path && statfs(path, &fs) == 0;
    free(path);
    if (!ok) { wmc_set_last_error(ERROR_PATH_NOT_FOUND); return FALSE; }
    if (name && nameSize > 0) {
        const char *slash = strrchr(fs.f_mntonname, '/');
        const char *label = slash && slash[1] ? slash + 1 : "Macintosh HD";
        wmc_utf16_copy(name, (size_t)nameSize, label);
    }
    if (serial) *serial = (uint32_t)fs.f_fsid.val[0];
    if (maxComponent) *maxComponent = 255;
    if (flags) *flags = 0;
    if (fsName && fsNameSize > 0) wmc_utf16_copy(fsName, (size_t)fsNameSize, fs.f_fstypename);
    return TRUE;
}

// ---- shlwapi ----------------------------------------------------------------------

static bool mount_point(const WCHAR *name, char *out, size_t size) {
    char *path = wmc_host_path(name);
    struct statfs fs;
    bool ok = path && statfs(path, &fs) == 0;
    if (ok) snprintf(out, size, "%s", fs.f_mntonname);
    free(path);
    return ok;
}

WMC_API WINBOOL PathIsNetworkPathW(const WCHAR *name) {
    char *path = wmc_host_path(name);
    struct statfs fs;
    bool network = path && statfs(path, &fs) == 0 && !(fs.f_flags & MNT_LOCAL);
    free(path);
    return network;
}

WMC_API WINBOOL PathIsRootW(const WCHAR *name) {
    char *path = wmc_host_path(name);
    char mount[MAXPATHLEN];
    bool root = false;
    if (path && mount_point(name, mount, sizeof mount)) {
        size_t n = strlen(path);
        while (n > 1 && path[n - 1] == '/') path[--n] = 0;
        root = strcmp(path, mount) == 0;
    }
    free(path);
    return root;
}

WMC_API WINBOOL PathIsSameRootW(const WCHAR *a, const WCHAR *b) {
    char x[MAXPATHLEN], y[MAXPATHLEN];
    return mount_point(a, x, sizeof x) && mount_point(b, y, sizeof y) && strcmp(x, y) == 0;
}

WMC_API WINBOOL PathIsNetworkPath(const WCHAR *name) { return PathIsNetworkPathW(name); }
WMC_API WINBOOL PathIsRoot(const WCHAR *name) { return PathIsRootW(name); }
WMC_API WINBOOL PathIsSameRoot(const WCHAR *a, const WCHAR *b) { return PathIsSameRootW(a, b); }

// ---- CreateFile -------------------------------------------------------------------

#include <fcntl.h>
#include <unistd.h>

// Opens a file (or, to ask whether something exists, a file or folder with
// no access asked for). The handle is the file descriptor itself, which is
// also what Mono's own file handles are, so a SafeFileHandle made from it
// closes it properly.
// The file descriptors CreateFileW handed out, so that CloseHandle closes
// those and nothing else (other handles are not descriptors).
static uint8_t s_ourFds[4096];
static void file_opened(int fd) {
    if (fd >= 0 && fd < (int)sizeof(s_ourFds)) s_ourFds[fd] = 1;
}

WMC_API void *CreateFileW(const WCHAR *name, uint32_t access, uint32_t share, void *security, uint32_t disposition,
                          uint32_t flags, void *templateFile) {
    char *path = wmc_host_path(name);
    if (!path) { wmc_set_last_error(ERROR_PATH_NOT_FOUND); return (void *)(intptr_t)-1; }
    bool read = (access & 0x80000000u) != 0, write = (access & 0x40000000u) != 0;
    int mode = write ? (read ? O_RDWR : O_WRONLY) : O_RDONLY;
    switch (disposition) {
        case 1: mode |= O_CREAT | O_EXCL; break;    // CREATE_NEW
        case 2: mode |= O_CREAT | O_TRUNC; break;   // CREATE_ALWAYS
        case 4: mode |= O_CREAT; break;             // OPEN_ALWAYS
        case 5: mode |= O_TRUNC; break;             // TRUNCATE_EXISTING
        default: break;                             // OPEN_EXISTING
    }
    struct stat st;
    bool existed = stat(path, &st) == 0;
    int fd = open(path, mode | O_CLOEXEC, 0644);
    free(path);
    if (fd < 0) {
        wmc_set_last_error(ERROR_FILE_NOT_FOUND);
        return (void *)(intptr_t)-1;
    }
    file_opened(fd);
    // As on Windows: "always" dispositions say whether the file was there.
    wmc_set_last_error(existed && (disposition == 2 || disposition == 4) ? ERROR_ALREADY_EXISTS : 0);
    return (void *)(intptr_t)fd;
}
WMC_API void *CreateFile(const WCHAR *name, uint32_t access, uint32_t share, void *security, uint32_t disposition,
                         uint32_t flags, void *templateFile) {
    return CreateFileW(name, access, share, security, disposition, flags, templateFile);
}

WMC_API WINBOOL DeleteFileW(const WCHAR *name) {
    char *path = wmc_host_path(name);
    if (!path) { wmc_set_last_error(ERROR_PATH_NOT_FOUND); return 0; }
    int r = unlink(path);
    free(path);
    if (r != 0) { wmc_set_last_error(ERROR_FILE_NOT_FOUND); return 0; }
    wmc_set_last_error(0);
    return 1;
}

// ---- file mappings ----------------------------------------------------------------
// Media Center's object store keeps a table of ids in files it maps into
// memory (CreateFileMapping + MapViewOfFile), so that several processes can
// share it. Here there is one process: a mapping is the file (or, with no
// file, anonymous memory) mapped with mmap.

#define WMC_MAPPING_MAGIC 0x4d415050u   // "MAPP"

typedef struct {
    uint32_t magic;
    int fd;                 // -1: no file behind it
    uint64_t size;
} WmcMapping;

typedef struct { void *address; size_t length; } WmcView;
static WmcView s_views[256];
static pthread_mutex_t s_viewsLock = PTHREAD_MUTEX_INITIALIZER;

static WmcMapping *as_mapping(void *h) {
    WmcMapping *m = h;
    return (uintptr_t)h > 0x10000 && m->magic == WMC_MAPPING_MAGIC ? m : NULL;
}

WMC_API void *CreateFileMappingW(void *file, void *security, uint32_t protect, uint32_t sizeHigh, uint32_t sizeLow,
                                 const WCHAR *name) {
    int fd = (intptr_t)file == -1 ? -1 : (int)(intptr_t)file;
    uint64_t size = (uint64_t)sizeHigh << 32 | sizeLow;
    if (fd >= 0) {
        struct stat st;
        if (fstat(fd, &st) != 0) { wmc_set_last_error(ERROR_INVALID_HANDLE); return NULL; }
        if (size == 0) size = (uint64_t)st.st_size;
        else if ((uint64_t)st.st_size < size && ftruncate(fd, (off_t)size) != 0) {
            wmc_set_last_error(ERROR_NOT_ENOUGH_MEMORY);
            return NULL;
        }
    }
    if (size == 0) { wmc_set_last_error(ERROR_INVALID_HANDLE); return NULL; }
    WmcMapping *m = calloc(1, sizeof(*m));
    m->magic = WMC_MAPPING_MAGIC;
    m->fd = fd;
    m->size = size;
    wmc_set_last_error(0);
    return m;
}
WMC_API void *CreateFileMapping(void *file, void *security, uint32_t protect, uint32_t sizeHigh, uint32_t sizeLow,
                                const WCHAR *name) {
    return CreateFileMappingW(file, security, protect, sizeHigh, sizeLow, name);
}

WMC_API void *MapViewOfFile(void *mapping, uint32_t access, uint32_t offsetHigh, uint32_t offsetLow, size_t bytes) {
    WmcMapping *m = as_mapping(mapping);
    if (!m) { wmc_set_last_error(ERROR_INVALID_HANDLE); return NULL; }
    uint64_t offset = (uint64_t)offsetHigh << 32 | offsetLow;
    size_t length = bytes ? bytes : (size_t)(m->size - offset);
    void *address = m->fd >= 0 ? mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, m->fd, (off_t)offset)
                               : mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    if (address == MAP_FAILED) { wmc_set_last_error(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
    pthread_mutex_lock(&s_viewsLock);
    for (int i = 0; i < 256; i++) {
        if (!s_views[i].address) { s_views[i].address = address; s_views[i].length = length; break; }
    }
    pthread_mutex_unlock(&s_viewsLock);
    wmc_set_last_error(0);
    return address;
}

WMC_API WINBOOL UnmapViewOfFile(void *address) {
    pthread_mutex_lock(&s_viewsLock);
    for (int i = 0; i < 256; i++) {
        if (s_views[i].address == address) {
            munmap(address, s_views[i].length);
            s_views[i].address = NULL;
            break;
        }
    }
    pthread_mutex_unlock(&s_viewsLock);
    return 1;
}

// Closes what this file's functions handed out. Other handles (most are
// stand-ins that hold nothing) are accepted and left alone.
WMC_API WINBOOL CloseHandle(void *handle) {
    WmcMapping *m = as_mapping(handle);
    if (m) {
        m->magic = 0;
        free(m);
        return 1;
    }
    intptr_t fd = (intptr_t)handle;
    if (fd >= 0 && fd < (intptr_t)sizeof(s_ourFds) && s_ourFds[fd]) {
        s_ourFds[fd] = 0;
        close((int)fd);
    }
    return 1;
}
