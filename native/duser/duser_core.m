// XP Media Center Edition 2002's DirectUser: gadgets (only the framework's
// listener, which callbacks are delivered to), the thread's message loop,
// and the Smooth renderer's entry points: start, the class table, posting.
#import "duser.h"

#ifdef WMC_XP2002

WINBOOL PeekMessageW(MSG *msg, HWND hwnd, UINT min, UINT max, UINT remove);

// ---- gadgets ------------------------------------------------------------------------
//
// A handle is a small number. The framework makes one gadget (its listener,
// LocalMessagePort); its procedure runs on the thread that made it, from
// that thread's message loop.

typedef struct {
    DuGadgetProc proc;
    int32_t data;
    WmcThreadQueue *queue;
    uint32_t style;
    bool used;
} DuGadget;

enum { GADGETS = 64, GADGET_BASE = 0x6A0000 };
static DuGadget s_gadgets[GADGETS];
static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;

static DuGadget *gadget(void *h) {
    uintptr_t v = (uintptr_t)h;
    if (v < GADGET_BASE || v >= GADGET_BASE + GADGETS * 4 || (v & 3)) return NULL;
    DuGadget *g = &s_gadgets[(v - GADGET_BASE) / 4];
    return g->used ? g : NULL;
}

WMC_API void *CreateGadget(void *parent, uint32_t flags, DuGadgetProc proc, int32_t data) {
    pthread_mutex_lock(&s_lock);
    for (int i = 0; i < GADGETS; i++) {
        if (s_gadgets[i].used) continue;
        s_gadgets[i] = (DuGadget){ proc, data, wmc_threadq_current(), 0, true };
        pthread_mutex_unlock(&s_lock);
        return (void *)(uintptr_t)(GADGET_BASE + i * 4);
    }
    pthread_mutex_unlock(&s_lock);
    return NULL;
}

WMC_API void DeleteHandle(void *h) {
    pthread_mutex_lock(&s_lock);
    DuGadget *g = gadget(h);
    if (g) g->used = false;
    pthread_mutex_unlock(&s_lock);
}

typedef struct {
    void *hgad;
    uint32_t size;
    uint8_t bytes[];
} DuDelivery;

static void deliver(void *p) {
    DuDelivery *d = p;
    DuGadgetProc proc = NULL;
    int32_t data = 0;
    pthread_mutex_lock(&s_lock);
    DuGadget *g = gadget(d->hgad);
    if (g) {
        proc = g->proc;
        data = g->data;
    }
    pthread_mutex_unlock(&s_lock);
    if (proc) proc(d->hgad, data, d->bytes);
    free(d);
}

void du_gadget_post(void *hgad, const void *msg, uint32_t size) {
    pthread_mutex_lock(&s_lock);
    DuGadget *g = gadget(hgad);
    WmcThreadQueue *q = g ? g->queue : NULL;
    pthread_mutex_unlock(&s_lock);
    if (!q) return;
    DuDelivery *d = malloc(sizeof(*d) + size);
    d->hgad = hgad;
    d->size = size;
    memcpy(d->bytes, msg, size);
    ((struct Du_DUser_EventMsg *)d->bytes)->hgadMsg.h = (int64_t)(intptr_t)hgad;
    wmc_threadq_post_work(q, deliver, d);
}

// Style, rectangle, focus and the rest matter only to gadgets that draw: the
// listener does not.
WMC_API WINBOOL SetGadgetStyle(void *h, uint32_t style, uint32_t mask) {
    DuGadget *g = gadget(h);
    if (g) g->style = (g->style & ~mask) | (style & mask);
    return g != NULL;
}
WMC_API uint32_t GetGadgetStyle(void *h) { DuGadget *g = gadget(h); return g ? g->style : 0; }
WMC_API WINBOOL SetGadgetRect(void *h, int x, int y, int w, int cy, uint32_t flags) { return gadget(h) != NULL; }
WMC_API WINBOOL GetGadgetRect(void *h, int32_t rect[4], uint32_t flags) {
    memset(rect, 0, 16);
    return gadget(h) != NULL;
}
WMC_API WINBOOL SetGadgetParent(void *h, void *parent, void *other, uint32_t cmd) { return gadget(h) != NULL; }
WMC_API WINBOOL SetGadgetMessageFilter(void *h, int32_t cookie, uint32_t filter, uint32_t mask) { return gadget(h) != NULL; }
WMC_API WINBOOL SetGadgetFocus(void *h) { return gadget(h) != NULL; }
WMC_API void *GetGadgetFocus(void) { return NULL; }
WMC_API uint32_t InvalidateGadget(void *h, uint32_t flags) { return 0; }
WMC_API uint32_t DrawGadgetTree(void *h, void *hdc, void *rect, uint32_t flags) { return 0; }
WMC_API WINBOOL IsGadgetParentChainStyle(void *h, uint32_t style, WINBOOL *flag, uint32_t ignore) {
    if (flag) *flag = FALSE;
    return gadget(h) != NULL;
}
WMC_API uint32_t DUserSendEvent(void *msg, uint32_t flags) { return 0; }
WMC_API void HACK_ForceSoftwareRendering(void) {}

// ---- the thread's message loop -----------------------------------------------------
//
// Like GetMessage and the rest, but deliveries to the thread's gadgets (the
// engine's callbacks) run first.

WMC_API int32_t GetMessageEx(MSG *msg, HWND hwnd, UINT min, UINT max) {
    WmcThreadQueue *q = wmc_threadq_current();
    for (;;) {
        wmc_threadq_run_work(q);
        if (PeekMessageW(msg, hwnd, min, max, 1)) return msg->message != 0x0012;   // WM_QUIT: 0
        wmc_threadq_wait(q, 0xFFFFFFFFu);
    }
}

WMC_API WINBOOL PeekMessageEx(MSG *msg, HWND hwnd, UINT min, UINT max, UINT remove) {
    wmc_threadq_run_work(wmc_threadq_current());
    return PeekMessageW(msg, hwnd, min, max, remove);
}

WMC_API WINBOOL WaitMessageEx(void) {
    wmc_threadq_wait(wmc_threadq_current(), 0xFFFFFFFFu);
    return TRUE;
}

// ---- the Smooth renderer -----------------------------------------------------------

static void *s_listener;            // the framework's gadget, which callbacks go to
static void *const PROXY = (void *)(uintptr_t)0x6B0001;   // what messages are posted to
static void *const RENDER_THREAD = (void *)(uintptr_t)0x6B0002;

static void main_sync(void (^block)(void)) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

WMC_API HRESULT DUserSmoothInit(WINBOOL multiThread, int groupBits, int objectBits, uint32_t rootCookie, void *listener,
                                void **renderThread, void **proxy) {
    s_listener = listener;
    main_sync(^{ du_agent_start(rootCookie); });
    *renderThread = RENDER_THREAD;
    *proxy = PROXY;
    WLOG("sp", "DUserSmoothInit: render agent %#x, %d+%d handle bits, listener %p", rootCookie, groupBits, objectBits,
         listener);
    return S_OK;
}

WMC_API HRESULT DUserSmoothUninit(void *renderThread) {
    main_sync(^{ du_agent_stop(); });
    s_listener = NULL;
    return S_OK;
}

// Every method of the three classes has a number of its own (duser.h); an
// unknown one is given one that nothing handles, and logged when used.
static const char *const s_render_agent[] = {
    "MessageForwarderProxy", "MessageBatchForwarderProxy", "CreateGroup", "DeleteGroup", "DeleteObject", "Shutdown",
    "ShellExec", "CreateFormWindow", "CreateVisual", "CreateAnimation", "SetVisualStyle", "SetVisualParent",
    "SetVisualRect", "SetVisualDescription", "SetVisualAlpha", "SetVisualScale", "SetVisualCenter", "SetVisualLight",
    "RemoveVisualLight", "SetRenderHolderParams", NULL };
static const char *const s_form_window[] = {
    "CreateRoot", "SetOptions", "SetMouseIdleOptions", "SetStyles", "SetCursors", "SetIcon", "SetSize",
    "SetPosition", "SetVisible", "SetMode", "Restore", "ForceMouseIdle", "TakeFocus", "SetForeground", "Update",
    "Close", "SetText", "ShowHelp", "SetExtendedSysCommand", "SetVisualCapture", "SetBackgroundARGB",
    "SetPreBeginSceneROs", NULL };
static const char *const s_animation_helper[] = {
    "AddLightKeyframe", "AddRectKeyframe", "AddAlphaKeyframe", "AddScaleKeyframe", "Play", "Stop", NULL };

WMC_API HRESULT DUserSmoothFindClass(uint32_t version, const WCHAR *className, struct Du_DUser_MessageInfoStub *info,
                                     int count, void **classId) {
    char *name = wmc_utf8(className);
    const char *const *table = NULL;
    int base = 0, id = 0;
    if (!strcmp(name, "DUser::Smooth::RenderAgent")) { table = s_render_agent; base = DU_RA_FORWARD; id = 1; }
    else if (!strcmp(name, "DUser::Smooth::FormWindow")) { table = s_form_window; base = DU_FW_CREATE_ROOT; id = 2; }
    else if (!strcmp(name, "DUser::Smooth::AnimationHelper")) { table = s_animation_helper; base = DU_AH_ADD_LIGHT; id = 3; }
    for (int i = 0; i < count; i++) {
        char *method = wmc_utf8((const WCHAR *)(intptr_t)info[i].stMsgName);
        info[i].nMsg = 9000 + id * 100 + i;
        for (int k = 0; table && table[k]; k++) {
            if (!strcmp(table[k], method)) { info[i].nMsg = base + k; break; }
        }
        if (info[i].nMsg >= 9000) WLOG("todo", "%s::%s is not known", name, method);
        free(method);
    }
    WLOG("sp", "class %s: %d methods", name, count);
    free(name);
    *classId = (void *)(uintptr_t)(0x6C0000 + id);
    return id ? S_OK : E_FAIL;
}

// A message is copied (the framework reuses its memory), except a batch's
// list, which stays the framework's until the batch is reported done.
static void post(const struct Du_DUser_Msg *msg, bool wait) {
    if (!msg || msg->cbSize < sizeof(*msg)) return;
    NSData *copy = [NSData dataWithBytes:msg length:msg->cbSize];
    void (^run)(void) = ^{
        @autoreleasepool { du_agent_dispatch(copy.bytes); }
    };
    if (wait) main_sync(run);
    else dispatch_async(dispatch_get_main_queue(), run);
}

WMC_API HRESULT DUserPostMethod(void *proxy, const struct Du_DUser_Msg *msg) {
    post(msg, false);
    return S_OK;
}

WMC_API HRESULT DUserSendMethod(void *proxy, const struct Du_DUser_Msg *msg) {
    post(msg, true);
    return S_OK;
}

void du_callback_post(void *record, uint32_t size) {
    if (!s_listener) return;
    struct Du_RemoteCallbackMsg *m = record;
    m->cbSize = size;
    m->nMsg = DU_CALLBACK;
    du_gadget_post(s_listener, record, size);
}

void du_callback(uint32_t cookie, uint32_t ownerMessage) {
    struct Du_RemoteCallbackMsg m = {0};
    m.ownerCookie = cookie;
    m.ownerMessage = ownerMessage;
    du_callback_post(&m, sizeof(m));
}

NSString *du_blob_string(const void *msg, uint32_t ref) {
    uint32_t len = 0;
    const uint8_t *p = du_blob(msg, ref, &len);
    if (len < 2) return @"";
    return [[NSString alloc] initWithBytes:p length:len - 2 encoding:NSUTF16LittleEndianStringEncoding] ?: @"";
}

#endif
