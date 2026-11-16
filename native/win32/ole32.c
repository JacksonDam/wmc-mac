// ole32: COM class creation.
//
// There is no COM registry and no COM servers here. Classes that Media
// Center needs are provided as managed stand-ins before the request gets
// this far (WmcStandins/ComClasses.cs); anything that does arrive is
// answered the way Windows answers for a class that is not installed, which
// callers already handle.
#include "wmc.h"

#include <stdio.h>

#define REGDB_E_CLASSNOTREG ((int32_t)0x80040154)

typedef struct { uint32_t a; uint16_t b, c; uint8_t d[8]; } WmcGuid;

static void log_class(const char *what, const WmcGuid *g) {
    if (!g) return;
    WLOG("todo", "%s {%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}: no such COM class here", what, g->a, g->b, g->c,
         g->d[0], g->d[1], g->d[2], g->d[3], g->d[4], g->d[5], g->d[6], g->d[7]);
}

WMC_API int32_t CoCreateInstance(const WmcGuid *clsid, void *outer, uint32_t context, const WmcGuid *iid, void **object) {
    if (object) *object = NULL;
    log_class("CoCreateInstance", clsid);
    return REGDB_E_CLASSNOTREG;
}

WMC_API int32_t CoGetClassObject(const WmcGuid *clsid, uint32_t context, void *server, const WmcGuid *iid, void **object) {
    if (object) *object = NULL;
    log_class("CoGetClassObject", clsid);
    return REGDB_E_CLASSNOTREG;
}
