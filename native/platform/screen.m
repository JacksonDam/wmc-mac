// Display facts for the Win32 stand-ins, from Core Graphics (safe on any thread).
#import <CoreGraphics/CoreGraphics.h>
#include "platform.h"

void wmc_main_screen_size(int *width, int *height) {
    CGRect r = CGDisplayBounds(CGMainDisplayID());
    *width = (int)r.size.width;
    *height = (int)r.size.height;
}

int wmc_screen_count(void) {
    uint32_t n = 0;
    CGGetActiveDisplayList(0, NULL, &n);
    return n ? (int)n : 1;
}
