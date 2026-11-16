// ehtrace: Media Center's own diagnostic tracing (ETW on Windows).
//
// The messages are Media Center's account of what it is doing, which is
// worth having when a stand-in misbehaves: `--log trace` prints them.
#include "wmc.h"

#include <stdlib.h>
#include <string.h>

typedef struct { char name[64]; } WmcTraceProvider;

WMC_API void *CETWProvider_Initialize(const WCHAR *name, const void *guid, void *module, void *instance, void *group) {
    WmcTraceProvider *p = calloc(1, sizeof *p);
    char *utf8 = wmc_utf8(name);
    if (utf8) strlcpy(p->name, utf8, sizeof p->name);
    free(utf8);
    return p;
}

WMC_API void CETWProvider_Uninitialize(void *handle) {
    free(handle);
}

static const char *provider(void *handle) {
    return handle ? ((WmcTraceProvider *)handle)->name : "";
}

WMC_API void CETWProvider_TraceInfo(void *handle, const char *caller, int line) {
    WLOG("trace", "%s: %s", provider(handle), caller ? caller : "");
}

WMC_API void CETWProvider_TraceTextLevel(void *handle, const char *caller, int line, int level, const char *text) {
    WLOG("trace", "%s: %s: %s", provider(handle), caller ? caller : "", text ? text : "");
}

WMC_API void CETWProvider_TraceErrorLevel(void *handle, const char *caller, int line, int level, void *hr, const char *text) {
    WLOG("trace", "%s: %s: error %#lx %s", provider(handle), caller ? caller : "", (unsigned long)(uintptr_t)hr, text ? text : "");
}

WMC_API void CETWProvider_TraceErrorEvent(void *handle, const char *caller, int line, uint32_t event) {
    WLOG("trace", "%s: %s: error event %u", provider(handle), caller ? caller : "", event);
}

WMC_API void CETWProvider_TraceCriticalCall(void *handle, const char *caller, int line) {
    WLOG("trace", "%s: critical: %s", provider(handle), caller ? caller : "");
}

WMC_API void CETWProvider_TraceEventID(void *handle, uint32_t event, const char *text) {
    WLOG("trace", "%s: event %u %s", provider(handle), event, text ? text : "");
}

WMC_API void CETWProvider_TraceEHomeEvent(void *handle, uint32_t code, int level, const WCHAR *description, uint64_t d1, uint64_t d2,
                                          uint64_t d3, uint64_t d4, uint64_t d5) {
    if (!wmc_log_enabled("trace")) return;
    char *utf8 = wmc_utf8(description);
    wmc_log("trace", "%s: event %u %s (%llu, %llu)", provider(handle), code, utf8 ? utf8 : "", (unsigned long long)d1, (unsigned long long)d2);
    free(utf8);
}

WMC_API void CETWProvider_TracePerfMarkerStart(void *handle, const char *caller, int line) {}
WMC_API void CETWProvider_TracePerfMarkerEnd(void *handle, const char *caller, int line) {}
WMC_API void CETWProvider_TraceVideoSize(void *handle, uint32_t type, uint32_t width, uint32_t height) {
    WLOG("trace", "%s: video size %ux%u", provider(handle), width, height);
}

// The older interface: a registration handle and messages by index.
WMC_API uint32_t ehRegisterTraceGUIDs(const WCHAR *name, const void *guid, uint32_t module, uint32_t instance, uint32_t group,
                                      const void *guids, uint32_t count, uint32_t flags, uint32_t *handle) {
    if (handle) *handle = 1;
    return 0;
}
WMC_API uint32_t ehUnregisterTraceGUIDs(uint32_t handle) { return 0; }
WMC_API WINBOOL ehIsTraceEnabled(uint32_t handle, uint32_t flag, uint8_t level) { return wmc_log_enabled("trace"); }

WMC_API void ehTraceEventText(uint32_t handle, uint32_t index, const WCHAR *message) {
    if (!wmc_log_enabled("trace")) return;
    char *utf8 = wmc_utf8(message);
    wmc_log("trace", "%s", utf8 ? utf8 : "");
    free(utf8);
}

WMC_API void ehTraceEventError(uint32_t handle, uint32_t index, const WCHAR *message, uint32_t error) {
    if (!wmc_log_enabled("trace")) return;
    char *utf8 = wmc_utf8(message);
    wmc_log("trace", "error %#x: %s", error, utf8 ? utf8 : "");
    free(utf8);
}
