// Logging, stub accounting and string helpers shared by every stand-in.
#include "wmc.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static pthread_mutex_t s_log_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *s_log_file;
static const char *s_channels;
static pthread_once_t s_log_once = PTHREAD_ONCE_INIT;

static void log_init(void) {
    s_channels = getenv("WMC_LOG");
    const char *path = getenv("WMC_LOG_FILE");
    s_log_file = path && *path ? fopen(path, "w") : NULL;
    if (!s_log_file) s_log_file = stderr;
}

bool wmc_log_enabled(const char *channel) {
    pthread_once(&s_log_once, log_init);
    if (strcmp(channel, "msgbox") == 0) return true;   // what would be a dialog is always shown
    if (!s_channels || !*s_channels) return strcmp(channel, "stub") == 0 || strcmp(channel, "err") == 0;
    if (strcmp(s_channels, "all") == 0) return true;
    if (strcmp(s_channels, "none") == 0) return false;
    size_t n = strlen(channel);
    for (const char *p = s_channels; p && *p;) {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len == n && strncmp(p, channel, n) == 0) return true;
        p = end ? end + 1 : NULL;
    }
    return strcmp(channel, "err") == 0;
}

void wmc_log(const char *channel, const char *fmt, ...) {
    pthread_once(&s_log_once, log_init);
    struct timeval tv;
    gettimeofday(&tv, NULL);
    va_list ap;
    va_start(ap, fmt);
    pthread_mutex_lock(&s_log_lock);
    fprintf(s_log_file, "[%02d.%03d %s] ", (int)(tv.tv_sec % 100), (int)(tv.tv_usec / 1000), channel);
    vfprintf(s_log_file, fmt, ap);
    fputc('\n', s_log_file);
    fflush(s_log_file);
    pthread_mutex_unlock(&s_log_lock);
    va_end(ap);
}

// ---- stubs -------------------------------------------------------------------
// Every Windows function nobody has written yet lands here (see
// build/gen/stubs.c). The first call of each is logged; WMC_STUB_ABORT=1 stops
// in the debugger instead, for finding the caller.

#define STUB_SEEN_MAX 2048
static const char *s_stub_seen[STUB_SEEN_MAX];
static int s_stub_count;

WMC_API intptr_t wmc_stub_hit(const char *module, const char *name) {
    bool first = true;
    pthread_mutex_lock(&s_log_lock);
    for (int i = 0; i < s_stub_count; i++) {
        if (s_stub_seen[i] == name) { first = false; break; }
    }
    if (first && s_stub_count < STUB_SEEN_MAX) s_stub_seen[s_stub_count++] = name;
    pthread_mutex_unlock(&s_log_lock);
    if (first) WLOG("stub", "UNIMPLEMENTED %s!%s (returns 0)", module, name);
    if (getenv("WMC_STUB_ABORT")) abort();
    wmc_set_last_error(120); // ERROR_CALL_NOT_IMPLEMENTED
    return 0;
}

// ---- UTF-16 ------------------------------------------------------------------

size_t wmc_wcslen(const WCHAR *s) {
    size_t n = 0;
    if (s) while (s[n]) n++;
    return n;
}

char *wmc_utf8n(const WCHAR *s, size_t n) {
    if (!s) return NULL;
    char *out = malloc(n * 3 + 1), *p = out;
    for (size_t i = 0; i < n; i++) {
        uint32_t c = s[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + (s[++i] - 0xDC00);
        }
        if (c < 0x80) *p++ = (char)c;
        else if (c < 0x800) { *p++ = (char)(0xC0 | (c >> 6)); *p++ = (char)(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) {
            *p++ = (char)(0xE0 | (c >> 12)); *p++ = (char)(0x80 | ((c >> 6) & 0x3F)); *p++ = (char)(0x80 | (c & 0x3F));
        } else {
            *p++ = (char)(0xF0 | (c >> 18)); *p++ = (char)(0x80 | ((c >> 12) & 0x3F));
            *p++ = (char)(0x80 | ((c >> 6) & 0x3F)); *p++ = (char)(0x80 | (c & 0x3F));
        }
    }
    *p = 0;
    return out;
}

char *wmc_utf8(const WCHAR *s) { return s ? wmc_utf8n(s, wmc_wcslen(s)) : NULL; }

WCHAR *wmc_utf16(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    WCHAR *out = malloc((n + 1) * sizeof(WCHAR)), *p = out;
    const unsigned char *u = (const unsigned char *)s;
    for (size_t i = 0; i < n;) {
        uint32_t c = u[i];
        int extra = c < 0x80 ? 0 : c < 0xE0 ? 1 : c < 0xF0 ? 2 : 3;
        if (extra == 1) c &= 0x1F; else if (extra == 2) c &= 0x0F; else if (extra == 3) c &= 0x07;
        i++;
        for (int k = 0; k < extra && i < n; k++, i++) c = (c << 6) | (u[i] & 0x3F);
        if (c >= 0x10000) {
            c -= 0x10000;
            *p++ = (WCHAR)(0xD800 + (c >> 10));
            *p++ = (WCHAR)(0xDC00 + (c & 0x3FF));
        } else {
            *p++ = (WCHAR)c;
        }
    }
    *p = 0;
    return out;
}

size_t wmc_utf16_copy(WCHAR *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) return 0;
    WCHAR *w = wmc_utf16(src ? src : "");
    size_t n = wmc_wcslen(w);
    if (n >= cap) n = cap - 1;
    memcpy(dst, w, n * sizeof(WCHAR));
    dst[n] = 0;
    free(w);
    return n;
}

// ---- last error ---------------------------------------------------------------
// Mono reads errno after a SetLastError=true call and reports it through
// Marshal.GetLastWin32Error, so the Windows error code travels in errno.

#include <errno.h>

void wmc_set_last_error(DWORD e) { errno = (int)e; }
DWORD wmc_get_last_error(void) { return (DWORD)errno; }
