// msi: Windows Installer's list of installed products. Nothing here was
// installed by Windows Installer, so every product and component is unknown.
//
// The answers matter: the Windows Media Center Setup page asks which products
// use the PlayReady component with a loop that runs for as long as the call
// succeeds, and a call that returns 0 ("success") every time never lets the
// page open.
#include "wmc.h"

enum {
    ERROR_NO_MORE_ITEMS = 259,
    ERROR_UNKNOWN_PRODUCT = 1605,
    INSTALLSTATE_UNKNOWN = -1,
};

// The products that use a component, one per index: there are none.
WMC_API UINT MsiEnumClientsW(const WCHAR *component, DWORD index, WCHAR *product, int *size) {
    if (product) product[0] = 0;
    return ERROR_NO_MORE_ITEMS;
}

WMC_API UINT MsiGetProductInfoW(const WCHAR *product, const WCHAR *property, WCHAR *value, int *size) {
    if (value) value[0] = 0;
    return ERROR_UNKNOWN_PRODUCT;
}

WMC_API int MsiQueryProductStateW(const WCHAR *product) {
    return INSTALLSTATE_UNKNOWN;
}
