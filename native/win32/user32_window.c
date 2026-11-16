// user32: window classes and window objects.
//
// Most windows Media Center's managed code creates are invisible: message
// targets for notifications and timers. They need no Mac window at all, only
// a handle, a window procedure and a thread whose queue receives their
// messages. The one visible window (the form) is created by the render
// engine, which attaches its NSWindow to an entry in this same table.
#include "win32.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    UINT cbSize;
    UINT style;
    WNDPROC lpfnWndProc;
    int32_t cbClsExtra;
    int32_t cbWndExtra;
    HINSTANCE hInstance;
    HICON hIcon;
    HCURSOR hCursor;
    void *hbrBackground;
    const WCHAR *lpszMenuName;
    const WCHAR *lpszClassName;
    HICON hIconSm;
} WNDCLASSEXW;
_Static_assert(sizeof(WNDCLASSEXW) == 80, "WNDCLASSEXW layout");

typedef struct {
    void *lpCreateParams;
    HINSTANCE hInstance;
    void *hMenu;
    HWND hwndParent;
    int32_t cy, cx, y, x;
    LONG style;
    const WCHAR *lpszName;
    const WCHAR *lpszClass;
    DWORD dwExStyle;
} CREATESTRUCTW;

typedef struct WmcClass {
    struct WmcClass *next;
    char *name;            // UTF-8, compared without case
    uint16_t atom;
    WNDPROC proc;
    int wndExtra;
    UINT style;
} WmcClass;

#define WMC_WND_EXTRA 64

typedef struct WmcWindow {
    struct WmcWindow *next;
    HWND handle;
    WmcClass *cls;
    WmcThreadQueue *queue;
    WNDPROC proc;
    HWND parent;
    DWORD style, exStyle;
    LONG_PTR userData, id;
    HINSTANCE instance;
    RECT rect;
    WCHAR *text;
    bool destroyed;
    uint8_t extra[WMC_WND_EXTRA];
} WmcWindow;

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static WmcClass *s_classes;
static WmcWindow *s_windows;
static uintptr_t s_next_handle = 0x00010100;
static uint16_t s_next_atom = 0xC100;

static WmcWindow *find_window(HWND hwnd) {
    for (WmcWindow *w = s_windows; w; w = w->next) {
        if (w->handle == hwnd) return w->destroyed ? NULL : w;
    }
    return NULL;
}

static WmcWindow *lookup(HWND hwnd) {
    pthread_mutex_lock(&s_lock);
    WmcWindow *w = find_window(hwnd);
    pthread_mutex_unlock(&s_lock);
    return w;
}

static WmcClass *find_class_utf8(const char *name) {
    for (WmcClass *c = s_classes; c; c = c->next) {
        if (strcasecmp(c->name, name) == 0) return c;
    }
    return NULL;
}

// A class is named either by string or by its atom in the low word.
static WmcClass *find_class(const WCHAR *name) {
    if ((uintptr_t)name < 0x10000) {
        for (WmcClass *c = s_classes; c; c = c->next) {
            if (c->atom == (uint16_t)(uintptr_t)name) return c;
        }
        return NULL;
    }
    char *utf8 = wmc_utf8(name);
    WmcClass *c = find_class_utf8(utf8);
    free(utf8);
    return c;
}

WmcThreadQueue *wmc_window_queue(HWND hwnd) {
    WmcWindow *w = lookup(hwnd);
    return w ? w->queue : NULL;
}

LRESULT wmc_window_call_proc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    WmcWindow *w = lookup(hwnd);
    if (!w || !w->proc) return 0;
    return w->proc(hwnd, message, wParam, lParam);
}

WMC_API LRESULT DefWindowProcW(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);

// Registers a window whose behaviour lives elsewhere (the form window).
HWND wmc_window_adopt(const char *className, WNDPROC proc, WmcThreadQueue *queue) {
    WmcWindow *w = calloc(1, sizeof(*w));
    pthread_mutex_lock(&s_lock);
    w->handle = (HWND)s_next_handle;
    s_next_handle += 4;
    w->cls = find_class_utf8(className);
    w->queue = queue;
    w->proc = proc ? proc : DefWindowProcW;
    w->next = s_windows;
    s_windows = w;
    pthread_mutex_unlock(&s_lock);
    return w->handle;
}

WMC_API uint16_t RegisterClassExW(const WNDCLASSEXW *wc) {
    char *name = (uintptr_t)wc->lpszClassName < 0x10000 ? strdup("#atom") : wmc_utf8(wc->lpszClassName);
    pthread_mutex_lock(&s_lock);
    WmcClass *c = find_class_utf8(name);
    if (c) {
        pthread_mutex_unlock(&s_lock);
        free(name);
        wmc_set_last_error(1410);   // ERROR_CLASS_ALREADY_EXISTS
        return 0;
    }
    c = calloc(1, sizeof(*c));
    c->name = name;
    c->atom = s_next_atom++;
    c->proc = wc->lpfnWndProc;
    c->wndExtra = wc->cbWndExtra;
    c->style = wc->style;
    c->next = s_classes;
    s_classes = c;
    pthread_mutex_unlock(&s_lock);
    WLOG("win", "RegisterClassEx \"%s\" -> atom %#x", name, c->atom);
    return c->atom;
}

WMC_API BOOL UnregisterClassW(const WCHAR *name, HINSTANCE instance) {
    pthread_mutex_lock(&s_lock);
    WmcClass *c = find_class(name);
    if (c) {
        for (WmcClass **pp = &s_classes; *pp; pp = &(*pp)->next) {
            if (*pp == c) { *pp = c->next; break; }
        }
    }
    pthread_mutex_unlock(&s_lock);
    return c != NULL;   // the class record is left allocated: windows may still point at it
}

WMC_API HWND CreateWindowExW(DWORD exStyle, const WCHAR *className, const WCHAR *windowName, DWORD style,
                             int32_t x, int32_t y, int32_t width, int32_t height, HWND parent, void *menu,
                             HINSTANCE instance, void *param) {
    pthread_mutex_lock(&s_lock);
    WmcClass *c = find_class(className);
    if (!c) {
        pthread_mutex_unlock(&s_lock);
        char *n = (uintptr_t)className < 0x10000 ? NULL : wmc_utf8(className);
        WLOG("win", "CreateWindowEx: class \"%s\" is not registered", n ? n : "(atom)");
        free(n);
        wmc_set_last_error(1407);   // ERROR_CANNOT_FIND_WND_CLASS
        return NULL;
    }
    WmcWindow *w = calloc(1, sizeof(*w));
    w->handle = (HWND)s_next_handle;
    s_next_handle += 4;
    w->cls = c;
    w->queue = wmc_threadq_current();
    w->proc = c->proc;
    w->parent = parent;
    w->style = style;
    w->exStyle = exStyle;
    w->instance = instance;
    w->rect = (RECT){ x, y, x + width, y + height };
    if (windowName && (uintptr_t)windowName >= 0x10000) {
        size_t n = wmc_wcslen(windowName);
        w->text = calloc(n + 1, sizeof(WCHAR));
        memcpy(w->text, windowName, n * sizeof(WCHAR));
    }
    w->next = s_windows;
    s_windows = w;
    pthread_mutex_unlock(&s_lock);

    CREATESTRUCTW cs = {
        .lpCreateParams = param, .hInstance = instance, .hMenu = menu, .hwndParent = parent,
        .cy = height, .cx = width, .y = y, .x = x, .style = (LONG)style,
        .lpszName = windowName, .lpszClass = className, .dwExStyle = exStyle,
    };
    WLOG("win", "CreateWindowEx class \"%s\" -> %p (style %#x)", c->name, w->handle, style);
    if (w->proc) {
        if (!w->proc(w->handle, WM_NCCREATE, 0, (LPARAM)&cs) || w->proc(w->handle, WM_CREATE, 0, (LPARAM)&cs) == -1) {
            w->destroyed = true;
            return NULL;
        }
    }
    return w->handle;
}

WMC_API BOOL DestroyWindow(HWND hwnd) {
    WmcWindow *w = lookup(hwnd);
    if (!w) return FALSE;
    if (w->proc) {
        w->proc(hwnd, WM_DESTROY, 0, 0);
        w->proc(hwnd, WM_NCDESTROY, 0, 0);
    }
    pthread_mutex_lock(&s_lock);
    w->destroyed = true;
    pthread_mutex_unlock(&s_lock);
    return TRUE;
}

WMC_API LRESULT DefWindowProcW(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
        case WM_NCCREATE: return 1;
        case WM_CLOSE: DestroyWindow(hwnd); return 0;
    }
    return 0;
}

WMC_API LRESULT CallWindowProcW(WNDPROC proc, HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    return proc ? proc(hwnd, message, wParam, lParam) : 0;
}

WMC_API BOOL IsWindow(HWND hwnd) { return lookup(hwnd) != NULL; }

WMC_API DWORD GetWindowThreadProcessId(HWND hwnd, DWORD *processId) {
    WmcWindow *w = lookup(hwnd);
    if (!w) return 0;
    if (processId) *processId = (DWORD)getpid();
    return w->queue ? w->queue->thread_id : 0;
}

#define GWLP_WNDPROC (-4)
#define GWLP_HINSTANCE (-6)
#define GWLP_HWNDPARENT (-8)
#define GWL_STYLE (-16)
#define GWL_EXSTYLE (-20)
#define GWLP_USERDATA (-21)
#define GWLP_ID (-12)

static LONG_PTR window_long(HWND hwnd, int index, bool set, LONG_PTR value) {
    WmcWindow *w = lookup(hwnd);
    if (!w) {
        wmc_set_last_error(1400);
        return 0;
    }
    LONG_PTR old = 0;
    switch (index) {
        case GWLP_WNDPROC: old = (LONG_PTR)w->proc; if (set) w->proc = (WNDPROC)value; break;
        case GWLP_HINSTANCE: old = (LONG_PTR)w->instance; if (set) w->instance = (HINSTANCE)value; break;
        case GWLP_HWNDPARENT: old = (LONG_PTR)w->parent; if (set) w->parent = (HWND)value; break;
        case GWL_STYLE: old = (LONG_PTR)w->style; if (set) w->style = (DWORD)value; break;
        case GWL_EXSTYLE: old = (LONG_PTR)w->exStyle; if (set) w->exStyle = (DWORD)value; break;
        case GWLP_USERDATA: old = w->userData; if (set) w->userData = value; break;
        case GWLP_ID: old = w->id; if (set) w->id = value; break;
        default:
            if (index >= 0 && index + (int)sizeof(LONG_PTR) <= WMC_WND_EXTRA) {
                memcpy(&old, w->extra + index, sizeof(old));
                if (set) memcpy(w->extra + index, &value, sizeof(value));
            }
    }
    return old;
}

WMC_API LONG_PTR GetWindowLongPtrW(HWND hwnd, int index) { return window_long(hwnd, index, false, 0); }
WMC_API LONG_PTR SetWindowLongPtrW(HWND hwnd, int index, LONG_PTR value) { return window_long(hwnd, index, true, value); }
WMC_API LONG GetWindowLongW(HWND hwnd, int index) { return (LONG)window_long(hwnd, index, false, 0); }
WMC_API LONG SetWindowLongW(HWND hwnd, int index, LONG value) { return (LONG)window_long(hwnd, index, true, value); }

WMC_API HWND GetParent(HWND hwnd) {
    WmcWindow *w = lookup(hwnd);
    return w ? w->parent : NULL;
}

WMC_API HWND FindWindowW(const WCHAR *className, const WCHAR *windowName) {
    HWND found = NULL;
    pthread_mutex_lock(&s_lock);
    WmcClass *c = className ? find_class(className) : NULL;
    if (!className || c) {
        for (WmcWindow *w = s_windows; w; w = w->next) {
            if (w->destroyed || (c && w->cls != c)) continue;
            found = w->handle;
            break;
        }
    }
    pthread_mutex_unlock(&s_lock);
    return found;
}

WMC_API int GetClassNameW(HWND hwnd, WCHAR *buffer, int max) {
    WmcWindow *w = lookup(hwnd);
    if (!w || !w->cls) return 0;
    return (int)wmc_utf16_copy(buffer, (size_t)max, w->cls->name);
}

// ---- sending -----------------------------------------------------------------

typedef struct {
    HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam;
    LRESULT result;
    pthread_mutex_t lock; pthread_cond_t cond; bool done;
} SendCall;

static void run_send(void *p) {
    SendCall *c = p;
    c->result = wmc_window_call_proc(c->hwnd, c->message, c->wParam, c->lParam);
    pthread_mutex_lock(&c->lock);
    c->done = true;
    pthread_cond_signal(&c->cond);
    pthread_mutex_unlock(&c->lock);
}

WMC_API LRESULT SendMessageW(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    WmcWindow *w = lookup(hwnd);
    if (!w) return 0;
    if (!w->queue || w->queue == wmc_threadq_current()) {
        return wmc_window_call_proc(hwnd, message, wParam, lParam);
    }
    SendCall c = { .hwnd = hwnd, .message = message, .wParam = wParam, .lParam = lParam };
    pthread_mutex_init(&c.lock, NULL);
    pthread_cond_init(&c.cond, NULL);
    wmc_threadq_post_work(w->queue, run_send, &c);
    pthread_mutex_lock(&c.lock);
    while (!c.done) pthread_cond_wait(&c.cond, &c.lock);
    pthread_mutex_unlock(&c.lock);
    return c.result;
}

WMC_API LRESULT SendMessageTimeoutW(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam, UINT flags,
                                    UINT timeout, DWORD_PTR *result) {
    if (!lookup(hwnd)) {
        wmc_set_last_error(1400);
        return 0;
    }
    LRESULT r = SendMessageW(hwnd, message, wParam, lParam);
    if (result) *result = (DWORD_PTR)r;
    return 1;
}
