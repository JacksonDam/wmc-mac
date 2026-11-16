// The Mac's region, for the Win32 "geo" functions.
#import <Foundation/Foundation.h>
#include "platform.h"

void wmc_region_iso2(char out[3]) {
    NSString *code = NSLocale.currentLocale.countryCode ?: @"US";
    const char *c = code.uppercaseString.UTF8String;
    out[0] = c[0] ? c[0] : 'U';
    out[1] = c[0] && c[1] ? c[1] : 'S';
    out[2] = 0;
}
