// kernel32: system information, time, memory and the small process-level
// calls that need no state.
#include "win32.h"

#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

typedef struct {
    uint16_t wProcessorArchitecture;
    uint16_t wReserved;
    uint32_t dwPageSize;
    void *lpMinimumApplicationAddress;
    void *lpMaximumApplicationAddress;
    uintptr_t dwActiveProcessorMask;
    uint32_t dwNumberOfProcessors;
    uint32_t dwProcessorType;
    uint32_t dwAllocationGranularity;
    uint16_t wProcessorLevel;
    uint16_t wProcessorRevision;
} SYSTEM_INFO;
_Static_assert(sizeof(SYSTEM_INFO) == 48, "SYSTEM_INFO layout");

WMC_API void GetSystemInfo(SYSTEM_INFO *info) {
    memset(info, 0, sizeof(*info));
    int cpus = (int)sysconf(_SC_NPROCESSORS_ONLN);
    info->wProcessorArchitecture = 9;            // PROCESSOR_ARCHITECTURE_AMD64, what the code was built for
    info->dwPageSize = 4096;                     // the Windows page size its heaps are sized by
    info->lpMinimumApplicationAddress = (void *)0x10000;
    info->lpMaximumApplicationAddress = (void *)0x00007FFFFFFEFFFF;
    info->dwNumberOfProcessors = (uint32_t)(cpus > 0 ? cpus : 1);
    info->dwActiveProcessorMask = cpus >= 64 ? ~(uintptr_t)0 : (((uintptr_t)1 << cpus) - 1);
    info->dwProcessorType = 8664;
    info->dwAllocationGranularity = 65536;
    info->wProcessorLevel = 6;
}

WMC_API DWORD GetTickCount(void) { return wmc_tick_count(); }

WMC_API BOOL QueryPerformanceFrequency(int64_t *frequency) {
    *frequency = 10000000;   // 100 ns units, as on current Windows
    return TRUE;
}

WMC_API BOOL QueryPerformanceCounter(int64_t *counter) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    *counter = (int64_t)(mach_absolute_time() * tb.numer / tb.denom / 100);
    return TRUE;
}

WMC_API DWORD GetCurrentThreadId(void) { return wmc_current_thread_id(); }

// The pseudo-handle Windows uses for "this process".
WMC_API HANDLE wmcapi_GetCurrentProcess(void) { return (HANDLE)(intptr_t)-1; }
WMC_API HANDLE GetCurrentProcess(void) { return (HANDLE)(intptr_t)-1; }

WMC_API UINT SetErrorMode(UINT mode) { return 0; }
WMC_API BOOL SetProcessShutdownParameters(DWORD level, DWORD flags) { return TRUE; }
WMC_API BOOL SetProcessWorkingSetSize(HANDLE process, size_t min, size_t max) { return TRUE; }
WMC_API UINT SetThreadExecutionState(UINT flags) { return 0x80000000u; }

WMC_API void wmcapi_Sleep(DWORD ms) { usleep((useconds_t)ms * 1000); }

WMC_API void CopyMemory(void *dst, const void *src, size_t n) { memmove(dst, src, n); }
WMC_API void MoveMemory(void *dst, const void *src, size_t n) { memmove(dst, src, n); }
WMC_API void RtlMoveMemory(void *dst, const void *src, size_t n) { memmove(dst, src, n); }
WMC_API void FillMemory(void *dst, size_t n, uint8_t fill) { memset(dst, fill, n); }
WMC_API void ZeroMemory(void *dst, size_t n) { memset(dst, 0, n); }

WMC_API void OutputDebugStringW(const WCHAR *text) {
    if (!wmc_log_enabled("debug")) return;
    char *utf8 = wmc_utf8(text);
    size_t n = strlen(utf8);
    while (n && (utf8[n - 1] == '\n' || utf8[n - 1] == '\r')) utf8[--n] = 0;
    wmc_log("debug", "%s", utf8);
    free(utf8);
}

typedef struct {
    uint32_t dwLength;
    uint32_t dwMemoryLoad;
    uint64_t ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile;
    uint64_t ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
} MEMORYSTATUSEX;

WMC_API BOOL GlobalMemoryStatusEx(MEMORYSTATUSEX *status) {
    uint64_t mem = 0;
    size_t len = sizeof(mem);
    sysctlbyname("hw.memsize", &mem, &len, NULL, 0);
    status->dwMemoryLoad = 50;
    status->ullTotalPhys = mem;
    status->ullAvailPhys = mem / 2;
    status->ullTotalPageFile = mem * 2;
    status->ullAvailPageFile = mem;
    status->ullTotalVirtual = 0x00007FFFFFFE0000ull;
    status->ullAvailVirtual = 0x00007FFF00000000ull;
    status->ullAvailExtendedVirtual = 0;
    return TRUE;
}
