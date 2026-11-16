// Internal declarations shared by the Win32 stand-ins (user32, kernel32, ...).
//
// Files in this folder define functions under their Windows names. To keep
// those names from colliding with Apple's headers, nothing here includes a
// framework header: anything that needs AppKit goes through native/platform.
#pragma once
#include "wmc.h"
#include "threadq.h"

typedef struct { int32_t left, top, right, bottom; } RECT;
typedef struct { int32_t cx, cy; } SIZE;

#define WM_NULL 0x0000
#define WM_CREATE 0x0001
#define WM_DESTROY 0x0002
#define WM_CLOSE 0x0010
#define WM_QUIT 0x0012
#define WM_NCCREATE 0x0081
#define WM_NCDESTROY 0x0082
#define WM_TIMER 0x0113

typedef LRESULT (*WNDPROC)(HWND, UINT, WPARAM, LPARAM);

// ---- windows (user32_window.c) ---------------------------------------------
// The thread whose queue receives a window's posted messages; NULL if the
// handle is not a window.
WmcThreadQueue *wmc_window_queue(HWND hwnd);
LRESULT wmc_window_call_proc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
