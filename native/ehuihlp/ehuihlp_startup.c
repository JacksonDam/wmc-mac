// ehuihlp.dll: the helper calls Media Center makes while starting up.
#include "wmc.h"

#include <stdlib.h>
#include <string.h>

WMC_API void SetCheckPointMark(int mark) {}

WMC_API BOOL EHIsUserAGuest(void) { return FALSE; }

// On Windows this reads the system's licence policy: does this copy of
// Windows include Media Center? (Zero makes Media Center refuse to start.)
// Media Center here comes from a Windows 7 edition that includes it, obtained
// legally (see README), so the answer is yes.
WMC_API int GetMCSkuPolicyFromLicense(void) { return 1; }

// ---- small services -------------------------------------------------------------

#include <pwd.h>
#include <unistd.h>

WMC_API void GrantProcessSynchonizeAccessToNetworkService(void) {}
WMC_API void OnMCEBootComplete(void) {}
WMC_API void EhRegisterForWpcLogging(void) {}

// Fills the buffer with the user's name; *size is the capacity in characters.
WMC_API int EHGetUserName(WCHAR *buffer, int *size) {
    struct passwd *pw = getpwuid(getuid());
    const char *name = pw && pw->pw_name ? pw->pw_name : "user";
    if (!buffer || !size || *size <= 0) return 0;
    *size = (int)wmc_utf16_copy(buffer, (size_t)*size, name);
    return 1;
}

// System volume: reported as full and unmuted until sound output is wired to it.
static float s_volume = 1.0f;
static BOOL s_mute;
WMC_API void CreateSystemVolume(void) {}
WMC_API void DestroySystemVolume(void) {}
WMC_API void GetVolume(float *volume) { *volume = s_volume; }
WMC_API void SetVolume(float volume) { s_volume = volume; }
WMC_API void GetMute(BOOL *mute) { *mute = s_mute; }
WMC_API void SetMute(BOOL mute) { s_mute = mute; }
WMC_API void SetVolumeChangeCallback(void *callback) {}

// "Is the MPEG-2/DVD decoder package installed?" On Windows 8 and later the
// Movies, TV and Sports strips are hidden without it. Decoding here is the
// Mac's own (AVFoundation / VideoToolbox), which is always present.
WMC_API BOOL IsCodecPackInstalled(void) { return TRUE; }

// Whether some other full-screen shell is set to start with Windows.
WMC_API BOOL IsAnotherTenFootShellSetToRunAtBoot(void) { return FALSE; }
