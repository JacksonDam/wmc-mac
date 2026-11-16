// Windows modules as data: mapped PE files and their resource trees.
#pragma once
#include "win32.h"

typedef struct WmcModule WmcModule;

// Opens (or returns the already open) module for a Windows path or a bare
// file name looked up in the ehome folder. NULL if there is no such PE file.
WmcModule *wmc_module_open(const WCHAR *name);
WmcModule *wmc_module_main(void);                 // the program itself (ehshell.exe)
WmcModule *wmc_module_from_handle(HMODULE handle);  // NULL handle = main module
const char *wmc_module_name(WmcModule *m);        // file name, as on disk

// A resource "name" or "type" is a small integer or a UTF-16 string, encoded
// the Windows way: values below 0x10000 are integers.
// Returns the resource's data-entry record (an HRSRC), or NULL. Looks in the
// module, then in its language file (<lang>/<name>.mui).
const void *wmc_module_find_resource(WmcModule *m, const WCHAR *type, const WCHAR *name, uint16_t lang);
// Resolves a data-entry record to its bytes.
const void *wmc_resource_data(const void *entry, uint32_t *size);
