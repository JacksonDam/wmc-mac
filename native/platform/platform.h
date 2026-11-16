// What the Win32 stand-ins ask of the Mac. Implemented in Objective-C files
// in this folder so that the Win32 files never include a framework header.
#pragma once
#include "wmc.h"

void wmc_main_screen_size(int *width, int *height);   // in points
int wmc_screen_count(void);
void wmc_region_iso2(char out[3]);                    // "GB", "US", ...
