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
#ifdef WMC_XP
// XP Media Center Edition 2005 asks for a mixer object and its controls'
// ids (the system mixer tells its window when one changes), and counts
// volume from 0 to 65535. Every call returns an HRESULT.
static uint32_t s_volume = 0xFFFF;
static BOOL s_mute;
static int s_mixer;   // (its address is the mixer handle)
WMC_API HRESULT CreateSystemMixer(void **mixer) { *mixer = &s_mixer; return S_OK; }
WMC_API HRESULT OpenSystemMixer(void *mixer, HWND notify, BOOL *opened) { if (opened) *opened = TRUE; return S_OK; }
WMC_API HRESULT CloseSystemMixer(void *mixer) { return S_OK; }
WMC_API HRESULT GetMixerID(void *mixer, intptr_t *id) { *id = 1; return S_OK; }
WMC_API HRESULT GetMuteControlID(void *mixer, intptr_t *id) { *id = 1; return S_OK; }
WMC_API HRESULT GetVolumeControlID(void *mixer, intptr_t *id) { *id = 2; return S_OK; }
WMC_API HRESULT GetVolume(void *mixer, uint32_t *volume) { *volume = s_volume; return S_OK; }
WMC_API HRESULT SetVolume(void *mixer, uint32_t volume) { s_volume = volume & 0xFFFF; return S_OK; }
WMC_API HRESULT GetMute(void *mixer, BOOL *mute) { *mute = s_mute; return S_OK; }
WMC_API HRESULT SetMute(void *mixer, BOOL mute) { s_mute = mute; return S_OK; }
// The volume as one of `chunks` steps (the volume bar's 25).
WMC_API int GetPositionForVolume(uint32_t volume, int chunks) {
    return (int)(((uint64_t)(volume & 0xFFFF) * (uint64_t)chunks + 0x7FFF) / 0xFFFF);
}
#else
static float s_volume = 1.0f;
static BOOL s_mute;
WMC_API void CreateSystemVolume(void) {}
WMC_API void DestroySystemVolume(void) {}
WMC_API void GetVolume(float *volume) { *volume = s_volume; }
WMC_API void SetVolume(float volume) { s_volume = volume; }
WMC_API void GetMute(BOOL *mute) { *mute = s_mute; }
WMC_API void SetMute(BOOL mute) { s_mute = mute; }
#endif
WMC_API void SetVolumeChangeCallback(void *callback) {}

// "Is the MPEG-2/DVD decoder package installed?" On Windows 8 and later the
// Movies, TV and Sports strips are hidden without it. Decoding here is the
// Mac's own (AVFoundation / VideoToolbox), which is always present.
WMC_API BOOL IsCodecPackInstalled(void) { return TRUE; }

// Whether some other full-screen shell is set to start with Windows.
WMC_API BOOL IsAnotherTenFootShellSetToRunAtBoot(void) { return FALSE; }
