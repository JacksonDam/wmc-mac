// Contexts, buffers and the application thread's message loop: the part of
// EhUI.dll's interface that carries messages (the Sp* functions).
#import <QuartzCore/QuartzCore.h>
#import "sp.h"

// ---------------------------------------------------------------- contexts
//
// A context is one end of the conversation. The framework's thread calls
// SpInit and becomes an application context; SpRenderThreadInit creates the
// engine's context.

typedef struct SpAppContext {
    uint32_t idContext;
    WmcThreadQueue *queue;
    SpProcessBufferProc proc;
    void *procData;
    struct SpAppContext *next;
} SpAppContext;

static pthread_mutex_t s_ctx_lock = PTHREAD_MUTEX_INITIALIZER;
static SpAppContext *s_app_contexts;
static NSMutableDictionary<NSNumber *, SpRenderContext *> *s_render_contexts;

static SpAppContext *app_context(uint32_t idContext) {
    SpAppContext *found = NULL;
    pthread_mutex_lock(&s_ctx_lock);
    for (SpAppContext *c = s_app_contexts; c; c = c->next) {
        if (c->idContext == idContext) { found = c; break; }
    }
    pthread_mutex_unlock(&s_ctx_lock);
    return found;
}

static SpRenderContext *render_context(uint32_t idContext) {
    pthread_mutex_lock(&s_ctx_lock);
    SpRenderContext *rc = s_render_contexts[@(idContext)];
    pthread_mutex_unlock(&s_ctx_lock);
    return rc;
}

WmcThreadQueue *sp_app_queue(uint32_t idContext) {
    SpAppContext *c = app_context(idContext);
    return c ? c->queue : NULL;
}

void sp_main_sync(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

// ------------------------------------------------------------------ buffers

typedef struct {
    SpAppContext *app;
    SpBufferInfo info;
    void *data;
} SpDelivery;

// Runs on the application thread, from inside its Sp*Message call.
static void deliver_to_app(void *p) {
    SpDelivery *d = p;
    if (d->app->proc) d->app->proc(d->app->procData, d->app->idContext, &d->info, d->data);
    free(d->data);
    free(d);
}

HRESULT sp_post_buffer(SpBufferInfo info, const void *data) {
    SpRenderContext *rc = render_context(info.idContextDest);
    if (rc) {
        NSData *copy = [NSData dataWithBytes:data length:info.cbSizeBuffer];
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool { [rc processBuffer:info data:copy]; }
        });
        return S_OK;
    }
    SpAppContext *app = app_context(info.idContextDest);
    if (app) {
        SpDelivery *d = calloc(1, sizeof(*d));
        d->app = app;
        d->info = info;
        d->data = malloc(info.cbSizeBuffer ? info.cbSizeBuffer : 1);
        memcpy(d->data, data, info.cbSizeBuffer);
        wmc_threadq_post_work(app->queue, deliver_to_app, d);
        return S_OK;
    }
    WLOG("err", "buffer for unknown context %u (from %u, %u bytes)", info.idContextDest,
         info.idContextSrc, info.cbSizeBuffer);
    return E_FAIL;
}

// ------------------------------------------------------- exported functions

WMC_API HRESULT SpInit(SpInitArgs *args) {
    WmcThreadQueue *q = wmc_threadq_current();
    SpAppContext *c = calloc(1, sizeof(*c));
    c->idContext = args->idContext;
    c->queue = q;
    c->proc = (SpProcessBufferProc)args->pfnProcessBuffer;
    c->procData = args->pvProcessData;
    q->sp_context = c->idContext;
    pthread_mutex_lock(&s_ctx_lock);
    c->next = s_app_contexts;
    s_app_contexts = c;
    pthread_mutex_unlock(&s_ctx_lock);
    WLOG("sp", "SpInit: application context %u on thread %#x (args %u bytes, %d+%d handle bits)",
         c->idContext, q->thread_id, args->cbSize, args->cGroupBits, args->cItemsPerGroupBits);
    return S_OK;
}

WMC_API HRESULT SpUninit(void) {
    WmcThreadQueue *q = wmc_threadq_current();
    pthread_mutex_lock(&s_ctx_lock);
    for (SpAppContext **pp = &s_app_contexts; *pp; pp = &(*pp)->next) {
        if ((*pp)->queue == q) { *pp = (*pp)->next; break; }   // small leak: late deliveries may still hold it
    }
    pthread_mutex_unlock(&s_ctx_lock);
    q->sp_context = 0;
    WLOG("sp", "SpUninit");
    return S_OK;
}

// The framework passes a delegate; Mono has already turned it into a native
// function pointer, which is all the "wrapping" needed.
WMC_API HRESULT SpWrapBufferProc(void *pfnProcessBufferProc, void **ppNativeProc) {
    *ppNativeProc = pfnProcessBufferProc;
    return S_OK;
}

WMC_API HRESULT SpRenderThreadInit(SpInitArgs *args, void **pThread) {
    SpInitArgs copy = *args;
    __block SpRenderContext *rc;
    sp_main_sync(^{ rc = [[SpRenderContext alloc] initWithArgs:&copy]; });
    pthread_mutex_lock(&s_ctx_lock);
    if (!s_render_contexts) s_render_contexts = [NSMutableDictionary dictionary];
    s_render_contexts[@(copy.idContext)] = rc;
    pthread_mutex_unlock(&s_ctx_lock);
    *pThread = (__bridge void *)rc;
    WLOG("sp", "SpRenderThreadInit: render context %u, broker class %#x", copy.idContext,
         copy.idObjectBrokerClass);
    return S_OK;
}

WMC_API HRESULT SpRenderThreadUninit(void *pThread) {
    SpRenderContext *rc = (__bridge SpRenderContext *)pThread;
    WLOG("sp", "SpRenderThreadUninit: render context %u", rc.contextId);
    uint32_t idContext = rc.contextId;
    // Let everything already queued for the engine finish first.
    sp_main_sync(^{});
    pthread_mutex_lock(&s_ctx_lock);
    [s_render_contexts removeObjectForKey:@(idContext)];
    pthread_mutex_unlock(&s_ctx_lock);
    return S_OK;
}

WMC_API HRESULT SpBufferOpen(SpBufferInfo *info, void *data) {
    return sp_post_buffer(*info, data);
}

// The framework calls this when it has finished with a buffer we delivered;
// deliver_to_app frees it after the callback returns.
WMC_API HRESULT SpBufferClose(SpBufferInfo *info, void *data) {
    return S_OK;
}

WMC_API HRESULT SpGetThreadContextOrNull(uint32_t *idContext) {
    *idContext = wmc_threadq_current()->sp_context;
    return S_OK;
}

WMC_API HRESULT SpGetThreadContext(uint32_t *idContext) {
    *idContext = wmc_threadq_current()->sp_context;
    return *idContext ? S_OK : (HRESULT)0x800401E4;   // "context has not been initialized"
}

typedef struct {
    void (*fn)(void *);
    void *args;
} SpInvocation;

static void run_invocation(void *p) {
    SpInvocation *i = p;
    i->fn(i->args);
    free(i);
}

// With no function this is a plain wake-up of the context's thread, which is
// how other threads tell the dispatcher that they queued something for it.
WMC_API HRESULT SpInvoke(uint32_t idContext, void *pfnInvoke, void *pvArgs, WINBOOL synchronous) {
    SpAppContext *app = app_context(idContext);
    if (app) {
        if (!pfnInvoke) {
            wmc_threadq_wake(app->queue);
        } else {
            SpInvocation *i = calloc(1, sizeof(*i));
            i->fn = pfnInvoke;
            i->args = pvArgs;
            wmc_threadq_post_work(app->queue, run_invocation, i);
        }
        return S_OK;
    }
    if (render_context(idContext)) {
        if (pfnInvoke) {
            void (*fn)(void *) = pfnInvoke;
            if (synchronous) sp_main_sync(^{ fn(pvArgs); });
            else dispatch_async(dispatch_get_main_queue(), ^{ fn(pvArgs); });
        }
        return S_OK;
    }
    return E_INVALIDARG;
}

// ---- the application thread's message loop --------------------------------
//
// The dispatcher polls with SpPeekMessage and sleeps in SpWaitMessage. The
// result flags say what happened: 1 = engine buffers were processed (their
// callbacks have already run), 2 = *msg holds a window message to dispatch.

enum { SpWorkProcessedMessage = 1, SpWorkNewUserMessage = 2 };

WINBOOL PeekMessageW(MSG *msg, HWND hwnd, UINT min, UINT max, UINT remove);
WINBOOL GetMessageW(MSG *msg, HWND hwnd, UINT min, UINT max);

WMC_API HRESULT SpPeekMessageW(MSG *msg, HWND hwnd, UINT min, UINT max, UINT remove, uint32_t *result) {
    WmcThreadQueue *q = wmc_threadq_current();
    uint32_t r = 0;
    if (wmc_threadq_run_work(q) > 0) r |= SpWorkProcessedMessage;
    memset(msg, 0, sizeof(*msg));
    if (PeekMessageW(msg, hwnd, min, max, remove)) r |= SpWorkNewUserMessage;
    *result = r;
    return S_OK;
}

WMC_API HRESULT SpGetMessageW(MSG *msg, HWND hwnd, UINT min, UINT max, uint32_t *result) {
    WmcThreadQueue *q = wmc_threadq_current();
    for (;;) {
        uint32_t r = 0;
        SpPeekMessageW(msg, hwnd, min, max, 1, &r);
        if (r) { *result = r; return S_OK; }
        wmc_threadq_wait(q, 0xFFFFFFFFu);
    }
}

WMC_API HRESULT SpWaitMessage(uint32_t timeoutMs, void *unused) {
    wmc_threadq_wait(wmc_threadq_current(), timeoutMs);
    return S_OK;
}

// ---- small engine services --------------------------------------------------

WMC_API HRESULT SpGdiplusInit(void) { return S_OK; }
WMC_API HRESULT SpGdiplusUninit(void) { return S_OK; }
WMC_API HRESULT SpRegisterTraceCallback(void *cb) { return S_OK; }
WMC_API HRESULT SpUnregisterTraceCallback(void *cb) { return S_OK; }
WMC_API void SpTraceEvent_US(uint32_t code, uint32_t level, const WCHAR *desc) {}
WMC_API void SpTraceEvent_5QS(uint32_t code, uint32_t level, const WCHAR *desc, uint64_t a, uint64_t b,
                              uint64_t c, uint64_t d, uint64_t e) {}
WMC_API void SpObjectRelease(void *unknown) {}

WMC_API HRESULT SpDestroyObject(uint32_t handle) {
    WLOG("sp", "SpDestroyObject %#x", handle);
    return S_OK;
}

NSString *sp_blob_string(const void *msg, uint32_t ref) {
    uint32_t len = 0;
    const uint8_t *p = sp_blob(msg, ref, &len);
    if (len < 2) return @"";
    return [[NSString alloc] initWithBytes:p length:len - 2 encoding:NSUTF16LittleEndianStringEncoding] ?: @"";
}
