// kernel32: events, mutexes, and waits on them.
//
// Windows 7's and Vista's Media Center synchronise through .NET's own
// objects; XP Media Center Edition 2005 also calls the Win32 functions
// directly (its single-instance mutex, events between its parts). Named
// objects are shared within the process: there are no other Media Center
// processes here to share them with.
//
// Its code was written for 32-bit Windows and often declares handles as
// 32-bit integers, so these handles are small numbers (0x40000000 and up,
// an index into a table), never pointers. Built for XP only (WMC_XP).
#include "win32.h"

#ifdef WMC_XP     // (Windows 7 and Vista: their stand-ins return at once, as before)

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#define SYNC_BASE 0x40000000u
#define SYNC_MAX 4096
#define WAIT_OBJECT_0 0u
#define WAIT_TIMEOUT 258u
#define WAIT_FAILED 0xFFFFFFFFu
#define INFINITE_WAIT 0xFFFFFFFFu

enum { SYNC_EVENT = 1, SYNC_MUTEX = 2, SYNC_WAIT = 3 };

typedef struct {
    int kind;                 // 0: free
    int refs;
    char *name;
    bool manual, signaled;    // events
    pthread_t owner;          // mutexes
    int recursion;
    bool cancelled;           // registered waits
} WmcSync;

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t s_changed = PTHREAD_COND_INITIALIZER;   // any object's state changed
static WmcSync s_objects[SYNC_MAX];

static void *handle_of(int i) { return (void *)(uintptr_t)(SYNC_BASE + (unsigned)i * 4); }

static WmcSync *object(void *h, int *index) {
    uintptr_t v = (uintptr_t)h;
    if (v < SYNC_BASE || v >= SYNC_BASE + SYNC_MAX * 4 || (v & 3)) return NULL;
    int i = (int)((v - SYNC_BASE) / 4);
    if (!s_objects[i].kind) return NULL;
    if (index) *index = i;
    return &s_objects[i];
}

bool wmc_sync_close(void *h) {
    pthread_mutex_lock(&s_lock);
    WmcSync *o = object(h, NULL);
    if (o && --o->refs <= 0) {
        if (o->kind == SYNC_WAIT) o->cancelled = true;
        free(o->name);
        memset(o, 0, sizeof(*o));
        pthread_cond_broadcast(&s_changed);
    }
    pthread_mutex_unlock(&s_lock);
    return o != NULL;
}

// Called with the lock held. A named object that exists is shared
// (ERROR_ALREADY_EXISTS); else a new one, or NULL with nothing free.
static void *make(int kind, const char *name, WmcSync **made) {
    *made = NULL;
    if (name && *name) {
        for (int i = 0; i < SYNC_MAX; i++) {
            if (s_objects[i].kind == kind && s_objects[i].name && strcmp(s_objects[i].name, name) == 0) {
                s_objects[i].refs++;
                wmc_set_last_error(183);   // ERROR_ALREADY_EXISTS
                return handle_of(i);
            }
        }
    }
    for (int i = 0; i < SYNC_MAX; i++) {
        if (!s_objects[i].kind) {
            memset(&s_objects[i], 0, sizeof(s_objects[i]));
            s_objects[i].kind = kind;
            s_objects[i].refs = 1;
            s_objects[i].name = name && *name ? strdup(name) : NULL;
            *made = &s_objects[i];
            wmc_set_last_error(0);
            return handle_of(i);
        }
    }
    wmc_set_last_error(8);   // ERROR_NOT_ENOUGH_MEMORY
    return NULL;
}

static void *create_event(bool manual, bool initial, const char *name) {
    pthread_mutex_lock(&s_lock);
    WmcSync *o;
    void *h = make(SYNC_EVENT, name, &o);
    if (o) {
        o->manual = manual;
        o->signaled = initial;
    }
    pthread_mutex_unlock(&s_lock);
    return h;
}

static void *create_mutex(bool owned, const char *name) {
    pthread_mutex_lock(&s_lock);
    WmcSync *o;
    void *h = make(SYNC_MUTEX, name, &o);
    if (o && owned) {
        o->owner = pthread_self();
        o->recursion = 1;
    }
    pthread_mutex_unlock(&s_lock);
    return h;
}

static void *open_named(int kind, const char *name) {
    pthread_mutex_lock(&s_lock);
    void *h = NULL;
    for (int i = 0; name && i < SYNC_MAX && !h; i++) {
        if (s_objects[i].kind == kind && s_objects[i].name && strcmp(s_objects[i].name, name) == 0) {
            s_objects[i].refs++;
            h = handle_of(i);
        }
    }
    pthread_mutex_unlock(&s_lock);
    wmc_set_last_error(h ? 0 : 2);   // ERROR_FILE_NOT_FOUND
    return h;
}

WMC_API void *CreateEventW(void *security, WINBOOL manual, WINBOOL initial, const WCHAR *name) {
    char *n = name ? wmc_utf8(name) : NULL;
    void *h = create_event(manual != 0, initial != 0, n);
    free(n);
    return h;
}

WMC_API void *CreateEventA(void *security, WINBOOL manual, WINBOOL initial, const char *name) {
    return create_event(manual != 0, initial != 0, name);
}

WMC_API void *CreateMutexW(void *security, WINBOOL owned, const WCHAR *name) {
    char *n = name ? wmc_utf8(name) : NULL;
    void *h = create_mutex(owned != 0, n);
    free(n);
    return h;
}

WMC_API void *CreateMutexA(void *security, WINBOOL owned, const char *name) {
    return create_mutex(owned != 0, name);
}

WMC_API void *OpenMutexW(DWORD access, WINBOOL inherit, const WCHAR *name) {
    char *n = name ? wmc_utf8(name) : NULL;
    void *h = open_named(SYNC_MUTEX, n);
    free(n);
    return h;
}

WMC_API void *OpenMutexA(DWORD access, WINBOOL inherit, const char *name) { return open_named(SYNC_MUTEX, name); }

WMC_API void *OpenEventW(DWORD access, WINBOOL inherit, const WCHAR *name) {
    char *n = name ? wmc_utf8(name) : NULL;
    void *h = open_named(SYNC_EVENT, n);
    free(n);
    return h;
}

WMC_API void *OpenEventA(DWORD access, WINBOOL inherit, const char *name) { return open_named(SYNC_EVENT, name); }

// The plain names, for declarations with no character set: on Windows these
// reach the "A" functions (kernel32 has no plain ones), but Mono tries the
// plain name first and would find its logging stub.
WMC_API void *CreateEvent(void *security, WINBOOL manual, WINBOOL initial, const char *name) {
    return CreateEventA(security, manual, initial, name);
}
WMC_API void *CreateMutex(void *security, WINBOOL owned, const char *name) { return CreateMutexA(security, owned, name); }
WMC_API void *OpenMutex(DWORD access, WINBOOL inherit, const char *name) { return OpenMutexA(access, inherit, name); }
WMC_API void *OpenEvent(DWORD access, WINBOOL inherit, const char *name) { return OpenEventA(access, inherit, name); }

static WINBOOL set_event(void *h, int how) {   // 1 set, 0 reset, 2 pulse
    pthread_mutex_lock(&s_lock);
    WmcSync *o = object(h, NULL);
    if (o && o->kind == SYNC_EVENT) {
        o->signaled = how != 0;
        pthread_cond_broadcast(&s_changed);
        if (how == 2) o->signaled = false;   // (only waiters already waking see it)
    }
    pthread_mutex_unlock(&s_lock);
    return o != NULL;
}

WMC_API WINBOOL SetEvent(void *h) { return set_event(h, 1); }
WMC_API WINBOOL ResetEvent(void *h) { return set_event(h, 0); }
WMC_API WINBOOL PulseEvent(void *h) { return set_event(h, 2); }

WMC_API WINBOOL ReleaseMutex(void *h) {
    pthread_mutex_lock(&s_lock);
    WmcSync *o = object(h, NULL);
    WINBOOL ok = o && o->kind == SYNC_MUTEX && o->recursion > 0 && pthread_equal(o->owner, pthread_self());
    if (ok && --o->recursion == 0) pthread_cond_broadcast(&s_changed);
    pthread_mutex_unlock(&s_lock);
    if (!ok) wmc_set_last_error(288);   // ERROR_NOT_OWNER
    return ok;
}

// Called with the lock held.
static bool ready(WmcSync *o) {
    if (!o) return true;   // handles that are not ours: stand-ins with nothing to wait for
    if (o->kind == SYNC_EVENT) return o->signaled;
    if (o->kind == SYNC_MUTEX) return o->recursion == 0 || pthread_equal(o->owner, pthread_self());
    return false;
}

static void take(WmcSync *o) {
    if (!o) return;
    if (o->kind == SYNC_EVENT && !o->manual) o->signaled = false;
    if (o->kind == SYNC_MUTEX) {
        o->owner = pthread_self();
        o->recursion++;
    }
}

static struct timespec deadline(DWORD ms) {
    struct timeval now;
    gettimeofday(&now, NULL);
    uint64_t ns = (uint64_t)now.tv_usec * 1000 + (uint64_t)(ms % 1000) * 1000000ull;
    return (struct timespec){ now.tv_sec + ms / 1000 + (time_t)(ns / 1000000000ull), (long)(ns % 1000000000ull) };
}

WMC_API DWORD WaitForMultipleObjects(DWORD count, void *const *handles, WINBOOL all, DWORD ms) {
    if (count == 0 || count > 64) {
        wmc_set_last_error(87);   // ERROR_INVALID_PARAMETER
        return WAIT_FAILED;
    }
    struct timespec until = deadline(ms == INFINITE_WAIT ? 0 : ms);
    pthread_mutex_lock(&s_lock);
    DWORD result = WAIT_TIMEOUT;
    for (;;) {
        WmcSync *objs[64];
        for (DWORD i = 0; i < count; i++) objs[i] = object(handles[i], NULL);
        if (all) {
            bool every = true;
            for (DWORD i = 0; i < count && every; i++) every = ready(objs[i]);
            if (every) {
                for (DWORD i = 0; i < count; i++) take(objs[i]);
                result = WAIT_OBJECT_0;
                break;
            }
        } else {
            DWORD first = count;
            for (DWORD i = 0; i < count && first == count; i++) if (ready(objs[i])) first = i;
            if (first < count) {
                take(objs[first]);
                result = WAIT_OBJECT_0 + first;
                break;
            }
        }
        if (ms == 0) break;
        if (ms == INFINITE_WAIT) {
            pthread_cond_wait(&s_changed, &s_lock);
        } else if (pthread_cond_timedwait(&s_changed, &s_lock, &until) == ETIMEDOUT) {
            break;
        }
    }
    pthread_mutex_unlock(&s_lock);
    return result;
}

WMC_API DWORD WaitForSingleObject(void *h, DWORD ms) {
    return WaitForMultipleObjects(1, &h, 0, ms);
}

WMC_API DWORD WaitForSingleObjectEx(void *h, DWORD ms, WINBOOL alertable) {
    return WaitForMultipleObjects(1, &h, 0, ms);
}

// RegisterWaitForSingleObject: a thread of its own waits and calls back
// (callback(context, timedOut)), once or each time, until unregistered.
typedef void (*WAITORTIMERCALLBACK)(void *context, uint8_t timedOut);

typedef struct {
    void *object, *wait;
    WAITORTIMERCALLBACK callback;
    void *context;
    DWORD ms, flags;
} WaitJob;

static void *wait_main(void *arg) {
    WaitJob *job = arg;
    for (;;) {
        DWORD r = WaitForSingleObject(job->object, job->ms);
        pthread_mutex_lock(&s_lock);
        WmcSync *w = object(job->wait, NULL);
        bool stop = !w || w->cancelled;
        pthread_mutex_unlock(&s_lock);
        if (stop) break;
        job->callback(job->context, r == WAIT_TIMEOUT);
        if (job->flags & 8) break;   // WT_EXECUTEONLYONCE
    }
    free(job);
    return NULL;
}

WMC_API WINBOOL RegisterWaitForSingleObject(void **wait, void *h, WAITORTIMERCALLBACK callback, void *context, DWORD ms,
                                            DWORD flags) {
    pthread_mutex_lock(&s_lock);
    WmcSync *o;
    void *w = make(SYNC_WAIT, NULL, &o);
    pthread_mutex_unlock(&s_lock);
    if (!w) return 0;
    WaitJob *job = calloc(1, sizeof(*job));
    *job = (WaitJob){ h, w, callback, context, ms, flags };
    pthread_t t;
    if (pthread_create(&t, NULL, wait_main, job) != 0) {
        free(job);
        wmc_sync_close(w);
        return 0;
    }
    pthread_detach(t);
    if (wait) *wait = w;
    return 1;
}

WMC_API WINBOOL UnregisterWait(void *wait) {
    pthread_mutex_lock(&s_lock);
    WmcSync *w = object(wait, NULL);
    if (w) w->cancelled = true;
    pthread_cond_broadcast(&s_changed);
    pthread_mutex_unlock(&s_lock);
    return w != NULL;
}

WMC_API WINBOOL UnregisterWaitEx(void *wait, void *completion) { return UnregisterWait(wait); }

#endif
