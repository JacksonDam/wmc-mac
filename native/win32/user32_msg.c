// user32: the thread message queue (post, peek, get, dispatch) and
// registered message names.
#include "win32.h"

#include <stdlib.h>
#include <string.h>

WMC_API BOOL PeekMessageW(MSG *msg, HWND hwnd, UINT min, UINT max, UINT remove) {
    return wmc_threadq_take_msg(wmc_threadq_current(), msg, hwnd, min, max, (remove & 1) != 0);
}

WMC_API BOOL GetMessageW(MSG *msg, HWND hwnd, UINT min, UINT max) {
    WmcThreadQueue *q = wmc_threadq_current();
    for (;;) {
        if (wmc_threadq_take_msg(q, msg, hwnd, min, max, true)) return msg->message != WM_QUIT;
        wmc_threadq_run_work(q);
        wmc_threadq_wait(q, 0xFFFFFFFFu);
    }
}

WMC_API BOOL TranslateMessage(const MSG *msg) {
    return FALSE;   // key messages arrive already translated from the Mac side
}

typedef void (*TIMERPROC)(HWND hwnd, UINT msg, uintptr_t id, DWORD time);

WMC_API LRESULT DispatchMessageW(const MSG *msg) {
    // A timer with a callback is called here, window or not (Vista's UI
    // framework runs its time-outs on one).
    if (msg->message == 0x0113 /* WM_TIMER */ && msg->lParam) {
        ((TIMERPROC)msg->lParam)(msg->hwnd, msg->message, msg->wParam, wmc_tick_count());
        return 0;
    }
    if (!msg->hwnd) return 0;
    return wmc_window_call_proc(msg->hwnd, msg->message, msg->wParam, msg->lParam);
}

// Timers belong to the calling thread, as on Windows: its message loop
// delivers them.
WMC_API uintptr_t SetTimer(HWND hwnd, uintptr_t id, UINT ms, void *proc) {
    return wmc_threadq_set_timer(wmc_threadq_current(), hwnd, id, ms, proc);
}

WMC_API BOOL KillTimer(HWND hwnd, uintptr_t id) {
    return wmc_threadq_kill_timer(wmc_threadq_current(), hwnd, id);
}

WMC_API BOOL PostMessageW(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    WmcThreadQueue *q = wmc_window_queue(hwnd);
    if (!q) {
        WLOG("win", "PostMessage to unknown window %p (msg %#x)", hwnd, message);
        wmc_set_last_error(1400);   // ERROR_INVALID_WINDOW_HANDLE
        return FALSE;
    }
    MSG m = { .hwnd = hwnd, .message = message, .wParam = wParam, .lParam = lParam };
    wmc_threadq_post_msg(q, &m);
    return TRUE;
}

WMC_API BOOL PostThreadMessageW(DWORD threadId, UINT message, WPARAM wParam, LPARAM lParam) {
    WmcThreadQueue *q = wmc_threadq_find(threadId);
    if (!q) {
        wmc_set_last_error(1444);   // ERROR_INVALID_THREAD_ID
        return FALSE;
    }
    MSG m = { .hwnd = NULL, .message = message, .wParam = wParam, .lParam = lParam };
    wmc_threadq_post_msg(q, &m);
    return TRUE;
}

WMC_API void PostQuitMessage(int exitCode) {
    MSG m = { .message = WM_QUIT, .wParam = (WPARAM)exitCode };
    wmc_threadq_post_msg(wmc_threadq_current(), &m);
}

// Registered messages: a process-wide table of names to ids from 0xC000.
static pthread_mutex_t s_reg_lock = PTHREAD_MUTEX_INITIALIZER;
static char *s_reg_names[1024];
static int s_reg_count;

WMC_API UINT RegisterWindowMessageW(const WCHAR *name) {
    char *utf8 = wmc_utf8(name);
    UINT id = 0;
    pthread_mutex_lock(&s_reg_lock);
    for (int i = 0; i < s_reg_count; i++) {
        if (strcasecmp(s_reg_names[i], utf8) == 0) { id = 0xC000 + (UINT)i; break; }
    }
    if (!id && s_reg_count < 1024) {
        s_reg_names[s_reg_count] = utf8;
        utf8 = NULL;
        id = 0xC000 + (UINT)s_reg_count++;
    }
    pthread_mutex_unlock(&s_reg_lock);
    free(utf8);
    return id;
}
