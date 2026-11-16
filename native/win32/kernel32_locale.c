// kernel32: geographic location ("GeoID"), which Media Center uses to pick a
// TV standard and regional defaults.
#include "win32.h"
#include "../platform/platform.h"

#include <string.h>

static const struct { const char *iso2; const char *iso3; int id; const char *name; } s_geo[] = {
    { "US", "USA", 244, "United States" }, { "GB", "GBR", 242, "United Kingdom" }, { "CA", "CAN", 39, "Canada" },
    { "AU", "AUS", 12, "Australia" }, { "DE", "DEU", 94, "Germany" }, { "FR", "FRA", 84, "France" },
    { "IT", "ITA", 118, "Italy" }, { "ES", "ESP", 217, "Spain" }, { "NL", "NLD", 176, "Netherlands" },
    { "SE", "SWE", 221, "Sweden" }, { "NO", "NOR", 177, "Norway" }, { "DK", "DNK", 61, "Denmark" },
    { "FI", "FIN", 77, "Finland" }, { "IE", "IRL", 68, "Ireland" }, { "NZ", "NZL", 183, "New Zealand" },
    { "JP", "JPN", 122, "Japan" }, { "KR", "KOR", 134, "Korea" }, { "CN", "CHN", 45, "China" },
    { "TW", "TWN", 237, "Taiwan" }, { "HK", "HKG", 104, "Hong Kong SAR" }, { "IN", "IND", 113, "India" },
    { "BR", "BRA", 32, "Brazil" }, { "MX", "MEX", 166, "Mexico" }, { "AT", "AUT", 14, "Austria" },
    { "CH", "CHE", 223, "Switzerland" }, { "BE", "BEL", 21, "Belgium" }, { "PT", "PRT", 193, "Portugal" },
    { "PL", "POL", 191, "Poland" }, { "CZ", "CZE", 75, "Czech Republic" }, { "HU", "HUN", 109, "Hungary" },
    { "RU", "RUS", 203, "Russia" }, { "TR", "TUR", 235, "Turkey" }, { "GR", "GRC", 98, "Greece" },
    { "ZA", "ZAF", 209, "South Africa" }, { "SG", "SGP", 215, "Singapore" }, { "IL", "ISR", 117, "Israel" },
};
#define GEO_COUNT ((int)(sizeof(s_geo) / sizeof(s_geo[0])))

static int geo_index_for_id(int id) {
    for (int i = 0; i < GEO_COUNT; i++) if (s_geo[i].id == id) return i;
    return -1;
}

static int user_geo_index(void) {
    char iso[3];
    wmc_region_iso2(iso);
    for (int i = 0; i < GEO_COUNT; i++) if (strcmp(s_geo[i].iso2, iso) == 0) return i;
    return 0;   // not in the table: United States
}

WMC_API int GetUserGeoID(int geoClass) { return s_geo[user_geo_index()].id; }

// GEO_NATION 1, GEO_ISO2 4, GEO_ISO3 5, GEO_FRIENDLYNAME 8, GEO_OFFICIALNAME 9.
// Returns the length written including the terminator, or 0.
WMC_API int GetGeoInfoW(int geoId, int type, WCHAR *buffer, int cch, uint16_t lang) {
    int i = geo_index_for_id(geoId);
    if (i < 0) {
        wmc_set_last_error(87);
        return 0;
    }
    char number[16];
    const char *text = NULL;
    switch (type) {
        case 1: { int n = s_geo[i].id, k = 0; char tmp[16]; do { tmp[k++] = (char)('0' + n % 10); n /= 10; } while (n);
                  int j = 0; while (k) number[j++] = tmp[--k]; number[j] = 0; text = number; break; }
        case 4: text = s_geo[i].iso2; break;
        case 5: text = s_geo[i].iso3; break;
        case 8: case 9: text = s_geo[i].name; break;
        default: wmc_set_last_error(87); return 0;
    }
    int need = (int)strlen(text) + 1;
    if (!buffer || cch == 0) return need;
    if (cch < need) {
        wmc_set_last_error(122);   // ERROR_INSUFFICIENT_BUFFER
        return 0;
    }
    wmc_utf16_copy(buffer, (size_t)cch, text);
    return need;
}

typedef BOOL (*GEO_ENUMPROC)(int geoId);

WMC_API BOOL EnumSystemGeoID(int geoClass, int parent, GEO_ENUMPROC proc) {
    for (int i = 0; i < GEO_COUNT; i++) if (!proc(s_geo[i].id)) break;
    return TRUE;
}

// ehuihlp.dll: the user's region as a two-letter code.
WMC_API void GetGeoISO2(WCHAR *buffer, int cch) {
    if (buffer && cch > 0) wmc_utf16_copy(buffer, (size_t)cch, s_geo[user_geo_index()].iso2);
}
