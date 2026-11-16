#include "threadq.h"

#include <errno.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static pthread_key_t s_key;
static pthread_once_t s_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t s_all_lock = PTHREAD_MUTEX_INITIALIZER;
static WmcThreadQueue *s_all;
static uint32_t s_next_thread_id = 0x1000;

static void make_key(void) { pthread_key_create(&s_key, NULL); }

WmcThreadQueue *wmc_threadq_current(void) {
    pthread_once(&s_once, make_key);
    WmcThreadQueue *q = pthread_getspecific(s_key);
    if (q) return q;
    q = calloc(1, sizeof(*q));
    pthread_mutex_init(&q->lock, NULL);
    pthread_cond_init(&q->cond, NULL);
    q->thread = pthread_self();
    pthread_mutex_lock(&s_all_lock);
    q->thread_id = s_next_thread_id;
    s_next_thread_id += 4;
    q->next_all = s_all;
    s_all = q;
    pthread_mutex_unlock(&s_all_lock);
    pthread_setspecific(s_key, q);
    return q;
}

WmcThreadQueue *wmc_threadq_find(uint32_t thread_id) {
    WmcThreadQueue *found = NULL;
    pthread_mutex_lock(&s_all_lock);
    for (WmcThreadQueue *q = s_all; q; q = q->next_all) {
        if (q->thread_id == thread_id) { found = q; break; }
    }
    pthread_mutex_unlock(&s_all_lock);
    return found;
}

uint32_t wmc_current_thread_id(void) { return wmc_threadq_current()->thread_id; }

// The watchdog: a UI thread that leaves its queued work (input, replies from
// the renderer) untaken for a while is stuck, and the window looks frozen
// although it still draws. Logged on the "hang" channel when it starts and
// when it ends, so automated runs can tell a frozen page from a quiet one.
// Once Media Center has been asked to close, its UI thread spends a while
// shutting down (longer while something plays) and is not expected to take
// input: that is not a freeze.
enum { STALL_MS = 2000, CHECK_MS = 250 };
static volatile bool s_closing;

void wmc_threadq_closing(void) { s_closing = true; }

static void *watchdog_main(void *unused) {
    for (;;) {
        usleep(CHECK_MS * 1000);
        if (s_closing) continue;
        uint32_t now = wmc_tick_count();
        pthread_mutex_lock(&s_all_lock);
        for (WmcThreadQueue *q = s_all; q; q = q->next_all) {
            if (!q->sp_context) continue;
            pthread_mutex_lock(&q->lock);
            WmcWork *oldest = q->work_head;
            if (oldest && !q->stalled_since && now - oldest->posted > STALL_MS) {
                q->stalled_since = oldest->posted;
                WLOG("hang", "thread %#x has not taken its queued work for %.1f s", q->thread_id,
                     (now - oldest->posted) / 1000.0);
            }
            pthread_mutex_unlock(&q->lock);
        }
        pthread_mutex_unlock(&s_all_lock);
    }
    return NULL;
}

static void start_watchdog(void) {
    if (!wmc_log_enabled("hang")) return;
    pthread_t t;
    pthread_create(&t, NULL, watchdog_main, NULL);
    pthread_detach(t);
}

void wmc_threadq_post_work(WmcThreadQueue *q, void (*run)(void *), void *ctx) {
    static pthread_once_t watchdog_once = PTHREAD_ONCE_INIT;
    if (q->sp_context) pthread_once(&watchdog_once, start_watchdog);
    WmcWork *w = calloc(1, sizeof(*w));
    w->run = run;
    w->ctx = ctx;
    w->posted = wmc_tick_count();
    pthread_mutex_lock(&q->lock);
    if (q->work_tail) q->work_tail->next = w; else q->work_head = w;
    q->work_tail = w;
    pthread_cond_broadcast(&q->cond);
    pthread_mutex_unlock(&q->lock);
}

void wmc_threadq_post_msg(WmcThreadQueue *q, const MSG *msg) {
    WmcMsgNode *n = calloc(1, sizeof(*n));
    n->msg = *msg;
    if (!n->msg.time) n->msg.time = wmc_tick_count();
    pthread_mutex_lock(&q->lock);
    if (q->msg_tail) q->msg_tail->next = n; else q->msg_head = n;
    q->msg_tail = n;
    pthread_cond_broadcast(&q->cond);
    pthread_mutex_unlock(&q->lock);
}

void wmc_threadq_wake(WmcThreadQueue *q) {
    pthread_mutex_lock(&q->lock);
    q->wake = true;
    pthread_cond_broadcast(&q->cond);
    pthread_mutex_unlock(&q->lock);
}

int wmc_threadq_run_work(WmcThreadQueue *q) {
    int ran = 0;
    for (;;) {
        pthread_mutex_lock(&q->lock);
        WmcWork *w = q->work_head;
        if (w) {
            q->work_head = w->next;
            if (!q->work_head) q->work_tail = NULL;
        }
        uint32_t stalled = q->stalled_since;
        q->stalled_since = 0;
        pthread_mutex_unlock(&q->lock);
        if (stalled)
            WLOG("hang", "thread %#x took its queued work again after %.1f s", q->thread_id,
                 (wmc_tick_count() - stalled) / 1000.0);
        if (!w) break;
        __atomic_add_fetch(&q->running, 1, __ATOMIC_RELAXED);
        w->run(w->ctx);
        __atomic_sub_fetch(&q->running, 1, __ATOMIC_RELAXED);
        free(w);
        ran++;
    }
    return ran;
}

bool wmc_threadq_ui_busy(void) {
    bool busy = false;
    pthread_mutex_lock(&s_all_lock);
    for (WmcThreadQueue *q = s_all; q && !busy; q = q->next_all) {
        if (!q->sp_context) continue;
        pthread_mutex_lock(&q->lock);
        busy = q->work_head != NULL || __atomic_load_n(&q->running, __ATOMIC_RELAXED) > 0;
        pthread_mutex_unlock(&q->lock);
    }
    pthread_mutex_unlock(&s_all_lock);
    return busy;
}

bool wmc_threadq_take_msg(WmcThreadQueue *q, MSG *out, HWND hwnd, UINT min, UINT max, bool remove) {
    bool found = false;
    pthread_mutex_lock(&q->lock);
    WmcMsgNode *prev = NULL;
    for (WmcMsgNode *n = q->msg_head; n; prev = n, n = n->next) {
        if (hwnd && n->msg.hwnd != hwnd) continue;
        if ((min || max) && (n->msg.message < min || n->msg.message > max)) continue;
        *out = n->msg;
        found = true;
        if (remove) {
            if (prev) prev->next = n->next; else q->msg_head = n->next;
            if (q->msg_tail == n) q->msg_tail = prev;
            free(n);
        }
        break;
    }
    pthread_mutex_unlock(&q->lock);
    return found;
}

bool wmc_threadq_wait(WmcThreadQueue *q, uint32_t timeout_ms) {
    bool ready = true;
    struct timespec until;
    if (timeout_ms != 0xFFFFFFFFu) {
        struct timeval now;
        gettimeofday(&now, NULL);
        uint64_t ns = (uint64_t)now.tv_usec * 1000 + (uint64_t)(timeout_ms % 1000) * 1000000ull;
        until.tv_sec = now.tv_sec + timeout_ms / 1000 + (time_t)(ns / 1000000000ull);
        until.tv_nsec = (long)(ns % 1000000000ull);
    }
    pthread_mutex_lock(&q->lock);
    while (!q->wake && !q->work_head && !q->msg_head) {
        if (timeout_ms == 0xFFFFFFFFu) {
            pthread_cond_wait(&q->cond, &q->lock);
        } else if (pthread_cond_timedwait(&q->cond, &q->lock, &until) == ETIMEDOUT) {
            ready = false;
            break;
        }
    }
    q->wake = false;
    pthread_mutex_unlock(&q->lock);
    return ready;
}

uint32_t wmc_tick_count(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (uint32_t)(mach_absolute_time() * tb.numer / tb.denom / 1000000ull);
}
