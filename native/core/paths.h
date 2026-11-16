#pragma once
#include "wmc.h"

// Translate a Windows path (C:\Windows\ehome\x.dll, with either slash) to a
// Mac path. The result is malloc'd. Mac paths pass through unchanged.
char *wmc_host_path(const WCHAR *win);
char *wmc_host_path_utf8(const char *win);

// The Windows-side names of the two folders Media Center asks about.
const char *wmc_windows_dir(void);   // C:\Windows
const char *wmc_ehome_dir(void);     // C:\Windows\ehome

// The Mac folder that stands for a Windows "special folder" (a CSIDL number,
// the same numbers as .NET's Environment.SpecialFolder). The user's Music,
// Pictures, Videos, Documents and Desktop are the Mac's own; everything else
// (application data, ProgramData, the Public folders) lives under the folder
// that stands for C:\. Returns false, with an empty string, for folders
// that have no counterpart. `create` makes the folder if it is one of ours.
bool wmc_special_folder(int csidl, bool create, char *out, size_t size);

// The user's real home folder (HOME is pointed elsewhere for Mono's sake),
// or WMC_MEDIA_HOME when a test wants its own Music/Pictures/Movies.
const char *wmc_media_home(void);
const char *wmc_drive_c_dir(void);
