// Shared declarations for the stand-in library (libwmcshim.dylib).
//
// The library answers for the Windows DLLs that Media Center's .NET code
// calls: the Win32 system libraries and Media Center's own native halves
// (EhUI.dll, ehuihlp.dll, ...). Every function here is written from the
// calling side's declaration of it; none of it is translated Windows code.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define WMC_API __attribute__((visibility("default")))

// ---- Windows scalar types, by their Win64 sizes ---------------------------
typedef int32_t WINBOOL;        // Windows BOOL: 32 bits
#ifndef __OBJC__
typedef int32_t BOOL;           // Objective-C has its own one-byte BOOL: use WINBOOL there
#endif
typedef uint8_t BYTE;
typedef uint16_t WORD;
typedef uint32_t DWORD;
typedef int32_t LONG;
typedef uint32_t UINT;
typedef int32_t HRESULT;
typedef uint16_t WCHAR;          // UTF-16 code unit (not wchar_t, which is 32-bit here)
typedef intptr_t LONG_PTR, LPARAM, LRESULT;
typedef uintptr_t ULONG_PTR, WPARAM, UINT_PTR, DWORD_PTR;
typedef void *HANDLE, *HWND, *HINSTANCE, *HMODULE, *HDC, *HBITMAP, *HFONT, *HGDIOBJ, *HICON, *HCURSOR, *HKEY;

#define S_OK ((HRESULT)0)
#define S_FALSE ((HRESULT)1)
#define E_NOTIMPL ((HRESULT)0x80004001)
#define E_FAIL ((HRESULT)0x80004005)
#define E_INVALIDARG ((HRESULT)0x80070057)
#define E_OUTOFMEMORY ((HRESULT)0x8007000E)
#define TRUE 1
#define FALSE 0

// ---- logging ---------------------------------------------------------------
// Channels are enabled with WMC_LOG=all or a comma list (stub,sp,msg,win,...).
bool wmc_log_enabled(const char *channel);
void wmc_log(const char *channel, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
#define WLOG(channel, ...) \
    do { if (wmc_log_enabled(channel)) wmc_log(channel, __VA_ARGS__); } while (0)

// ---- UTF-16 helpers ----------------------------------------------------------
size_t wmc_wcslen(const WCHAR *s);
// Returns a malloc'd UTF-8 copy (never NULL for non-NULL input).
char *wmc_utf8(const WCHAR *s);
char *wmc_utf8n(const WCHAR *s, size_t n);
// Returns a malloc'd, NUL-terminated UTF-16 copy.
WCHAR *wmc_utf16(const char *s);
// Copies into a fixed buffer, always terminating; returns units written.
size_t wmc_utf16_copy(WCHAR *dst, size_t cap, const char *src);

// ---- last error ------------------------------------------------------------
void wmc_set_last_error(DWORD e);
DWORD wmc_get_last_error(void);
