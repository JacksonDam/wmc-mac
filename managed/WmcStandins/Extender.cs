// Media Center Extenders (Xbox 360 and set-top boxes that showed Media
// Center on another TV) are found and served by native code in
// Mcx2Dvcs.dll, which cannot run here, and could not reach one anyway. The
// device manager is made without its native work queue and never starts
// looking: the Extender pages open and list no Extenders (see
// managed/redirects.txt).
using System;
using System.Collections;
using System.Reflection;

namespace WmcStandins
{
    public static partial class Compat
    {
        // CDeviceManager's constructor: what it sets up in managed code only.
        public static void Extender_DeviceManagerInit(Microsoft.MediaCenter.NetworkConnectedDevices.CDeviceManager manager)
        {
            const BindingFlags fields = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
            Type t = typeof(Microsoft.MediaCenter.NetworkConnectedDevices.CDeviceManager);
            t.GetField("m_devices", fields).SetValue(manager, new Hashtable());
            t.GetField("c_maxUninstalledDvcs", fields).SetValue(manager, 30);
        }
    }
}
