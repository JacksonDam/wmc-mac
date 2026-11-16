// gdi32: object handles. Only memory bitmaps exist so far: 32-bit, top-down,
// B G R A byte order (what Windows calls a 32-bpp DIB section).
#include "gdi.h"

#include <stdlib.h>
#include <string.h>

#define WMC_GDI_MAGIC 0x47444957u   // 'WIDG'

typedef struct WmcGdiObject {
    uint32_t magic;
    int kind;                // 1 = bitmap
    int width, height;
    void *bits;               // pixels for a bitmap, the payload for other kinds
    void (*destroy)(void *);  // frees the payload; NULL means free()
    struct WmcGdiObject *next, *prev;
} WmcGdiObject;

static pthread_mutex_t s_lock = PTHREAD_MUTEX_INITIALIZER;
static WmcGdiObject *s_objects;

static WmcGdiObject *valid(void *handle) {
    WmcGdiObject *found = NULL;
    pthread_mutex_lock(&s_lock);
    for (WmcGdiObject *o = s_objects; o; o = o->next) {
        if (o == handle) { found = o; break; }
    }
    pthread_mutex_unlock(&s_lock);
    return found;
}

HBITMAP wmc_gdi_bitmap_create(int width, int height, void **bits) {
    if (width <= 0 || height <= 0 || width > 32768 || height > 32768) return NULL;
    WmcGdiObject *o = calloc(1, sizeof(*o));
    o->magic = WMC_GDI_MAGIC;
    o->kind = 1;
    o->width = width;
    o->height = height;
    o->bits = calloc((size_t)width * (size_t)height, 4);
    pthread_mutex_lock(&s_lock);
    o->next = s_objects;
    if (s_objects) s_objects->prev = o;
    s_objects = o;
    pthread_mutex_unlock(&s_lock);
    if (bits) *bits = o->bits;
    return (HBITMAP)o;
}

bool wmc_gdi_bitmap_get(HBITMAP handle, int *width, int *height, void **bits) {
    WmcGdiObject *o = valid(handle);
    if (!o || o->kind != 1) return false;
    if (width) *width = o->width;
    if (height) *height = o->height;
    if (bits) *bits = o->bits;
    return true;
}

// Other kinds of object (fonts, device contexts) keep their state in a
// payload owned by whoever created them.
HGDIOBJ wmc_gdi_object_create(int kind, void *payload, void (*destroy)(void *)) {
    WmcGdiObject *o = calloc(1, sizeof(*o));
    o->magic = WMC_GDI_MAGIC;
    o->kind = kind;
    o->bits = payload;
    o->destroy = destroy;
    pthread_mutex_lock(&s_lock);
    o->next = s_objects;
    if (s_objects) s_objects->prev = o;
    s_objects = o;
    pthread_mutex_unlock(&s_lock);
    return (HGDIOBJ)o;
}

void *wmc_gdi_object_payload(HGDIOBJ handle, int kind) {
    WmcGdiObject *o = valid(handle);
    return o && o->kind == kind ? o->bits : NULL;
}

int wmc_gdi_object_kind(HGDIOBJ handle) {
    WmcGdiObject *o = valid(handle);
    return o ? o->kind : 0;
}

WMC_API BOOL DeleteObject(HGDIOBJ handle) {
    WmcGdiObject *o = valid(handle);
    if (!o) return FALSE;
    pthread_mutex_lock(&s_lock);
    if (o->prev) o->prev->next = o->next; else s_objects = o->next;
    if (o->next) o->next->prev = o->prev;
    pthread_mutex_unlock(&s_lock);
    o->magic = 0;
    if (o->destroy) o->destroy(o->bits); else free(o->bits);
    free(o);
    return TRUE;
}
