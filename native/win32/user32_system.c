// user32: system-wide settings and metrics.
#include "win32.h"

#include <string.h>

static int32_t s_default_layout;   // 1 = right-to-left

WMC_API BOOL GetProcessDefaultLayout(int32_t *layout) {
    *layout = s_default_layout;
    return TRUE;
}

WMC_API BOOL SetProcessDefaultLayout(int32_t layout) {
    s_default_layout = layout;
    return TRUE;
}

#define SPI_GETSCREENSAVEACTIVE 0x0010
#define SPI_GETWORKAREA 0x0030
#define SPI_GETHIGHCONTRAST 0x0042
#define SPI_GETSCREENSAVERRUNNING 0x0072
#define SPI_GETFONTSMOOTHING 0x004A
#define SPI_GETFONTSMOOTHINGTYPE 0x200A
#define SPI_GETCLEARTYPE 0x1048
#define SPI_GETUIEFFECTS 0x103E
#define SPI_GETMOUSEVANISH 0x1020

// ---- keyboard layout ----------------------------------------------------------
//
// A layout handle carries a language id in each half. Typing arrives from
// the Mac as finished characters, so the layout only tells Media Center
// which of its own on-screen input methods to use: the plain one.
static void *wmc_keyboard_layout(void) {
    return (void *)(uintptr_t)0x04090409u;   // US English
}

WMC_API void *GetKeyboardLayout(uint32_t thread) {
    return wmc_keyboard_layout();
}

WMC_API UINT GetKeyboardLayoutList(int count, void **list) {
    if (count > 0 && list) list[0] = wmc_keyboard_layout();
    return 1;
}

static BOOL system_parameters(UINT action, UINT param, void *value) {
    switch (action) {
        case SPI_GETHIGHCONTRAST: {
            // HIGHCONTRAST { cbSize, dwFlags, lpszDefaultScheme }: not in high contrast.
            if (value) {
                uint32_t *hc = value;
                hc[1] = 0;
            }
            return TRUE;
        }
        case SPI_GETSCREENSAVEACTIVE:
        case SPI_GETSCREENSAVERRUNNING:
        case SPI_GETMOUSEVANISH:
            if (value) *(BOOL *)value = FALSE;
            return TRUE;
        case SPI_GETFONTSMOOTHING:
        case SPI_GETCLEARTYPE:
        case SPI_GETUIEFFECTS:
            if (value) *(BOOL *)value = TRUE;
            return TRUE;
        case SPI_GETFONTSMOOTHINGTYPE:
            if (value) *(UINT *)value = 1;   // FE_FONTSMOOTHINGSTANDARD
            return TRUE;
    }
    if (action >= 0x1000 && (action & 1) == 0 && value) {
        // Even-numbered actions from 0x1000 are "get a BOOL"; say no.
        *(BOOL *)value = FALSE;
        return TRUE;
    }
    if (action == 89) {   // SPI_GETDEFAULTINPUTLANG: a keyboard layout handle
        if (value) *(void **)value = wmc_keyboard_layout();
        return TRUE;
    }
    WLOG("todo", "SystemParametersInfo action %#x is not handled", action);
    return (action & 1) ? TRUE : FALSE;   // odd actions are setters: accept
}

WMC_API BOOL SystemParametersInfoW(UINT action, UINT param, void *value, UINT winIni) {
    return system_parameters(action, param, value);
}

WMC_API BOOL SystemParametersInfoA(UINT action, UINT param, void *value, UINT winIni) {
    return system_parameters(action, param, value);
}

WMC_API BOOL SystemParametersInfo(UINT action, UINT param, void *value, UINT winIni) {
    return system_parameters(action, param, value);
}

// ---- metrics -----------------------------------------------------------------

#include "../platform/platform.h"

WMC_API int GetSystemMetrics(int index) {
    int w = 0, h = 0;
    wmc_main_screen_size(&w, &h);
    switch (index) {
        case 0: return w;            // SM_CXSCREEN
        case 1: return h;            // SM_CYSCREEN
        case 2: return 17;           // SM_CXVSCROLL
        case 3: return 17;           // SM_CYHSCROLL
        case 4: return 23;           // SM_CYCAPTION
        case 5: case 6: return 1;    // SM_CXBORDER, SM_CYBORDER
        case 7: case 8: return 3;    // SM_CXDLGFRAME, SM_CYDLGFRAME
        case 11: case 12: return 32; // SM_CXICON, SM_CYICON
        case 13: case 14: return 32; // SM_CXCURSOR, SM_CYCURSOR
        case 15: return 20;          // SM_CYMENU
        case 16: return w;           // SM_CXFULLSCREEN
        case 17: return h;           // SM_CYFULLSCREEN
        case 19: return 1;           // SM_MOUSEPRESENT
        case 28: return 136;         // SM_CXMIN
        case 29: return 39;          // SM_CYMIN
        case 32: case 33: return 8;  // SM_CXFRAME, SM_CYFRAME (sizing border)
        case 36: case 37: return 4;  // SM_CXDOUBLECLK, SM_CYDOUBLECLK
        case 43: return 3;           // SM_CMOUSEBUTTONS
        case 49: case 50: return 16; // SM_CXSMICON, SM_CYSMICON
        case 67: return 0;           // SM_CLEANBOOT
        case 68: case 69: return 4;  // SM_CXDRAG, SM_CYDRAG
        case 75: return 1;           // SM_MOUSEWHEELPRESENT
        case 76: case 77: return 0;  // SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN
        case 78: return w;           // SM_CXVIRTUALSCREEN
        case 79: return h;           // SM_CYVIRTUALSCREEN
        case 80: return wmc_screen_count();   // SM_CMONITORS
        case 81: return 1;           // SM_SAMEDISPLAYFORMAT
        case 86: return 0;           // SM_TABLETPC
        case 87: return 1;           // SM_MEDIACENTER
        case 0x1000: return 0;       // SM_REMOTESESSION
        case 0x2000: return 0;       // SM_SHUTTINGDOWN
        case 0x2001: return 0;       // SM_REMOTECONTROL
    }
    WLOG("todo", "GetSystemMetrics(%d) is not handled", index);
    return 0;
}

// ---- strings and message boxes -------------------------------------------------

#include "module.h"
#include <stdlib.h>

// String tables hold sixteen strings per block; each is a length word
// followed by that many UTF-16 units.
WMC_API int LoadStringW(HINSTANCE instance, UINT id, WCHAR *buffer, int max) {
    WmcModule *m = wmc_module_from_handle(instance);
    const void *entry = m ? wmc_module_find_resource(m, (const WCHAR *)(uintptr_t)6, (const WCHAR *)(uintptr_t)((id >> 4) + 1), 0) : NULL;
    uint32_t size = 0;
    const uint8_t *p = entry ? wmc_resource_data(entry, &size) : NULL;
    if (!p) return 0;
    const uint8_t *end = p + size;
    for (UINT i = 0; i < (id & 15) && p + 2 <= end; i++) p += 2 + 2 * (size_t)(p[0] | p[1] << 8);
    if (p + 2 > end) return 0;
    int len = p[0] | p[1] << 8;
    p += 2;
    if (max == 0) {
        // A zero-length buffer asks for a pointer to the string itself.
        *(const WCHAR **)buffer = (const WCHAR *)p;
        return len;
    }
    if (!buffer || max < 0) return 0;
    int n = len < max - 1 ? len : max - 1;
    memcpy(buffer, p, (size_t)n * sizeof(WCHAR));
    buffer[n] = 0;
    return n;
}

// A Win32 message box: there is no Mac dialog for it yet, so it goes to the
// log and answers OK.
WMC_API int MessageBoxW(HWND owner, const WCHAR *text, const WCHAR *title, UINT type) {
    char *t = wmc_utf8(text), *c = wmc_utf8(title);
    wmc_log("msgbox", "%s: %s", c ? c : "", t ? t : "");
    free(t);
    free(c);
    return 1;   // IDOK
}
