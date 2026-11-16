// Per-thread work queue: the one place a thread sleeps.
//
// On Windows a UI thread waits in its message queue. Here the same thread can
// be woken by three things, so they share one lock and condition:
//   - posted window messages (the user32 stand-in),
//   - render-protocol buffers addressed to the thread's context (the EhUI
//     stand-in), and
//   - an explicit wake or a function to run on the thread.
#pragma once
#include "wmc.h"
#include <pthread.h>

typedef struct {
    int32_t x, y;
} POINT;

typedef struct {
    HWND hwnd;
    UINT message;
    WPARAM wParam;
    LPARAM lParam;
    DWORD time;
    POINT pt;
} MSG;
_Static_assert(sizeof(MSG) == 48, "MSG layout");

typedef struct WmcWork {
    struct WmcWork *next;
    void (*run)(void *ctx);   // called on the owning thread, outside the lock
    void *ctx;
    uint32_t posted;          // tick count when it was queued
} WmcWork;

typedef struct WmcMsgNode {
    struct WmcMsgNode *next;
    MSG msg;
} WmcMsgNode;

typedef struct WmcThreadQueue {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    pthread_t thread;
    uint32_t thread_id;
    WmcMsgNode *msg_head, *msg_tail;
    WmcWork *work_head, *work_tail;
    bool wake;
    uint32_t sp_context;      // render-protocol context bound to this thread, or 0
    uint32_t stalled_since;   // when the watchdog found it stalled (the oldest item's time), or 0
    int running;              // work items being run now
    struct WmcThreadQueue *next_all;
} WmcThreadQueue;

WmcThreadQueue *wmc_threadq_current(void);
WmcThreadQueue *wmc_threadq_find(uint32_t thread_id);
uint32_t wmc_current_thread_id(void);

// Queue work for a thread and wake it. Safe from any thread.
void wmc_threadq_post_work(WmcThreadQueue *q, void (*run)(void *), void *ctx);
void wmc_threadq_post_msg(WmcThreadQueue *q, const MSG *msg);
void wmc_threadq_wake(WmcThreadQueue *q);

// Run every queued work item; returns how many ran.
int wmc_threadq_run_work(WmcThreadQueue *q);
// Take the first posted message that matches; returns false if none.
bool wmc_threadq_take_msg(WmcThreadQueue *q, MSG *out, HWND hwnd, UINT min, UINT max, bool remove);
// Sleep until there is work, a message or a wake, or the time-out passes.
// timeout_ms == 0xFFFFFFFF waits forever. Returns false on time-out.
bool wmc_threadq_wait(WmcThreadQueue *q, uint32_t timeout_ms);

uint32_t wmc_tick_count(void);

// Media Center has been asked to close: the stall watchdog stops reporting.
void wmc_threadq_closing(void);

// Whether a UI thread (one bound to a render context) has work queued or is
// running some: scripted runs wait for it to settle before the next key.
bool wmc_threadq_ui_busy(void);
