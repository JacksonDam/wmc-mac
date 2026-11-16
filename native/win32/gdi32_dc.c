// gdi32/user32: device contexts. Media Center only asks a screen DC about the
// display (colour depth, size, dots per inch); nothing is drawn through one.
#include "win32.h"
#include "../platform/platform.h"

#define WMC_SCREEN_DC ((HDC)(uintptr_t)0x0000DC01)

// (Memory DCs, fonts and text live in native/splash/sp_gdi_text.m.)
WMC_API HDC GetDC(HWND hwnd) { return WMC_SCREEN_DC; }
WMC_API HDC GetDCEx(HWND hwnd, HGDIOBJ clip, DWORD flags) { return WMC_SCREEN_DC; }
WMC_API BOOL ReleaseDC(HWND hwnd, HDC dc) { return TRUE; }

WMC_API int GetDeviceCaps(HDC dc, int index) {
    int w = 0, h = 0;
    wmc_main_screen_size(&w, &h);
    switch (index) {
        case 8: return w;      // HORZRES
        case 10: return h;     // VERTRES
        case 12: return 32;    // BITSPIXEL
        case 14: return 1;     // PLANES
        case 88: return 96;    // LOGPIXELSX
        case 90: return 96;    // LOGPIXELSY
        case 116: return 60;   // VREFRESH
        case 117: return h;    // DESKTOPVERTRES
        case 118: return w;    // DESKTOPHORZRES
    }
    WLOG("todo", "GetDeviceCaps(%d) is not handled", index);
    return 0;
}
