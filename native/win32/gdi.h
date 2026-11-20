// GDI objects shared between the gdi32 stand-in and the render engine.
#pragma once
#include "wmc.h"
#include <pthread.h>

// A zeroed 32-bit top-down bitmap (B G R A). Freed by DeleteObject.
HBITMAP wmc_gdi_bitmap_create(int width, int height, void **bits);
bool wmc_gdi_bitmap_get(HBITMAP handle, int *width, int *height, void **bits);

// Object kinds. A handle's kind is checked on every use.
enum { WmcGdiBitmap = 1, WmcGdiFont = 2, WmcGdiDC = 3, WmcGdiStock = 4 };
HGDIOBJ wmc_gdi_object_create(int kind, void *payload, void (*destroy)(void *));
void *wmc_gdi_object_payload(HGDIOBJ handle, int kind);
int wmc_gdi_object_kind(HGDIOBJ handle);
WINBOOL DeleteObject(HGDIOBJ handle);

// A font's payload (WmcGdiFont): what CreateFontIndirectW was asked for.
typedef struct {
    char face[128];
    float px;          // em height in the DC's units
    bool bold, italic;
} WmcFont;
