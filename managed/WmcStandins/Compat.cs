// Stand-ins that patched calls land in.
//
// The patcher (managed/wmctool) rewrites the calls listed in
// managed/redirects.txt so that they come here instead. Each method takes
// the original call's arguments, with the instance first for instance
// methods, and must match the original signature exactly.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace WmcStandins
{
    public static partial class Compat
    {
        // Windows lets a process raise its own priority class. macOS does not
        // without privileges, and Media Center does not depend on it.
        public static void Process_set_PriorityClass(Process process, ProcessPriorityClass value)
        {
        }

        // COM classes that have a stand-in here are created as ordinary
        // managed objects.
        public static Type Type_GetTypeFromCLSID(Guid clsid)
        {
            return ComClasses.Find(clsid) ?? Type.GetTypeFromCLSID(clsid);
        }

        // Controls that Windows would host as ActiveX objects.
        public static object AxHost_CreateControl(ServiceBus.UIFramework.AxHost host, string controlId)
        {
            Guid id;
            if (Guid.TryParse(controlId, out id) && id == Wmp.Player.ClassId)
            {
                object site;
                lock (s_axSites) s_axSites.TryGetValue(host, out site);
                Wmp.Player.Instance.Site = site;
                return Wmp.Player.Instance;
            }
            ComTodo.Hit("ActiveX control " + controlId);
            return null;
        }

        // The Windows version and edition, which Media Center reads through
        // native code: what Windows 8 and later report to a program without a
        // compatibility manifest (as ehshell.exe is), and Professional, the
        // edition Media Center was sold for there.
        public static System.Version Product_SystemVersion()
        {
            return new System.Version(6, 2, 9200, 0);
        }

        public static uint Product_EditionRaw()
        {
            return 48;   // ProductEdition.Professional
        }

        // Marshal.PtrToStringAuto as on Windows NT: UTF-16.
        public static string Marshal_PtrToStringAuto(IntPtr ptr)
        {
            return Marshal.PtrToStringUni(ptr);
        }

        public static string Marshal_PtrToStringAuto(IntPtr ptr, int length)
        {
            return Marshal.PtrToStringUni(ptr, length);
        }

        // The site an ActiveX host gives its control (on Windows it goes into
        // native code). Kept for the control the host creates next.
        static readonly System.Collections.Generic.Dictionary<ServiceBus.UIFramework.AxHost, object> s_axSites =
            new System.Collections.Generic.Dictionary<ServiceBus.UIFramework.AxHost, object>();

        public static void AxHost_SetSite(ServiceBus.UIFramework.AxHost host, object site)
        {
            lock (s_axSites) s_axSites[host] = site;
        }

        // Not in Mono: the last Win32 error as an HRESULT.
        public static int Marshal_GetHRForLastWin32Error()
        {
            int e = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
            return e == 0 ? 0 : unchecked((int)(0x80070000u | (uint)(e & 0xFFFF)));
        }

        // Releasing a stand-in (which is not a COM object) is not an error.
        public static int Marshal_ReleaseComObject(object o)
        {
            return o != null && Marshal.IsComObject(o) ? Marshal.ReleaseComObject(o) : 0;
        }

        public static int Marshal_FinalReleaseComObject(object o)
        {
            return o != null && Marshal.IsComObject(o) ? Marshal.FinalReleaseComObject(o) : 0;
        }

        // A path as Media Center wrote it (C:\Windows\ehome\x, or a Mac path
        // with backslashes added to it) as the path the Mac knows it by.
        [DllImport("wmcshim")]
        static extern int wmc_fix_path(string path, System.Text.StringBuilder result, int size);

        public static string FixPath(string path)
        {
            if (string.IsNullOrEmpty(path)) return path;
            if (path.IndexOf('\\') < 0 && !(path.Length > 1 && path[1] == ':')) return path;
            var result = new System.Text.StringBuilder(path.Length + 512);
            return wmc_fix_path(path, result, result.Capacity) != 0 ? result.ToString() : path;
        }

        // Windows' special folders, laid out as native/core/paths.c says: the
        // user's own media folders are the Mac's, the rest is under the
        // folder that stands for C:\.
        [DllImport("wmcshim")]
        static extern int wmc_special_folder_path(int csidl, System.Text.StringBuilder path, int size);

        public static string Environment_GetFolderPath(Environment.SpecialFolder folder)
        {
            var path = new System.Text.StringBuilder(1024);
            if (wmc_special_folder_path((int)folder, path, path.Capacity) != 0) return path.ToString();
            return Environment.GetFolderPath(folder);
        }

        // One of the small pictures on a folder's tile: `image` cropped to
        // 4:3 and scaled into the rectangle `rc` of the tile's own picture.
        // (Media Center draws this with GDI+, which Mono's stand-in for it
        // cannot do from raw pixel buffers; the copying is done natively.)
        [DllImport("wmcshim")]
        static extern void wmc_image_scale_blit(IntPtr src, int srcStride, int srcWidth, int srcHeight, int sx, int sy, int sw, int sh,
                                                IntPtr dst, int dstStride, int dstWidth, int dstHeight, int dx, int dy, int dw, int dh);

        static System.Reflection.FieldInfo s_thumbData, s_thumbStride, s_thumbWidth, s_thumbHeight;

        public static void Thumbnails_DrawMini(ServiceBus.UIFramework.ImageLoadingTask task, System.Drawing.Rectangle rc,
                                               System.Drawing.Graphics g, System.Drawing.Image image)
        {
            var bitmap = image as System.Drawing.Bitmap;
            if (bitmap == null || bitmap.Width <= 0 || bitmap.Height <= 0) return;
            if (s_thumbData == null)
            {
                const System.Reflection.BindingFlags any = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public;
                var t = typeof(ServiceBus.UIFramework.ImageLoadingTask);
                s_thumbStride = t.GetField("_stride", any);
                s_thumbWidth = t.GetField("_cxThumb", any);
                s_thumbHeight = t.GetField("_cyThumb", any);
                s_thumbData = t.GetField("_imageData", any);
            }
            IntPtr dst = (IntPtr)s_thumbData.GetValue(task);
            int dstStride = (int)s_thumbStride.GetValue(task), dstWidth = (int)s_thumbWidth.GetValue(task), dstHeight = (int)s_thumbHeight.GetValue(task);
            if (dst == IntPtr.Zero) return;
            // The middle of the picture, as wide as 4:3 allows.
            int left = 0, top = 0, width = bitmap.Width, height = bitmap.Height;
            int wide = (int)(bitmap.Height * 1.3333334f);
            if (wide < bitmap.Width) { width = wide; left = (bitmap.Width - width) / 2; }
            else height = bitmap.Width == 1 ? 1 : Math.Min(bitmap.Height, (int)(width * 0.75f));
            var data = bitmap.LockBits(new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height),
                                       System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            try
            {
                wmc_image_scale_blit(data.Scan0, data.Stride, bitmap.Width, bitmap.Height, left, top, width, height,
                                     dst, Math.Abs(dstStride), dstWidth, dstHeight, rc.X, rc.Y, rc.Width, rc.Height);
            }
            finally { bitmap.UnlockBits(data); }
        }

        // The playback code's own log (a file on Windows, when switched on in
        // the registry): on the "trace" log channel here.
        public static void PlaybackLog(string message)
        {
            ComTodo.Log("trace", "playback: " + message);
        }

        public static void PlaybackLog(string format, object[] args)
        {
            string text;
            try { text = string.Format(System.Globalization.CultureInfo.InvariantCulture, format, args); }
            catch (FormatException) { text = format; }
            ComTodo.Log("trace", "playback: " + text);
        }

        // Which player class plays a given address. Files the Mac can play
        // go to the Mac's player; everything else (discs, TV recordings,
        // network streams) to Media Center's own choice, which then reports
        // that it cannot start.
#if !VISTA && !XP
        public static string Playback_FindPlayerType(Uri uri, bool remote, out string assemblyName)
        {
            if (uri != null && uri.IsFile)
            {
                string ext = System.IO.Path.GetExtension(uri.LocalPath).ToLowerInvariant();
                if (ext == ".mp4" || ext == ".m4v" || ext == ".mov" || ext == ".wmv" || ext == ".asf" || ext == ".avi" ||
                    ext == ".divx")
                {
                    assemblyName = "WmcStandins";
                    return typeof(Playback.MacPlayer).FullName;
                }
            }
            return Microsoft.MediaCenter.Playback.PlayerTable.FindPlayerType(uri, remote, out assemblyName);
        }
#endif

#if !XP
        // Is a file protected (Windows Media DRM), and what does its licence
        // allow? Nothing that can be opened here is protected.
        public static void Drm_Info(string file, Microsoft.MediaCenter.Interop.UIHelper.DRMInfoStruct info)
        {
            if (info == null) return;
            info.status = Microsoft.MediaCenter.Interop.UIHelper.DRMStatus.NotDRMProtected;
            info.dwCategory = Microsoft.MediaCenter.Interop.UIHelper.DRM_LICENSE_STATE_CATEGORY.WM_DRM_LICENSE_STATE_UNLIM;
        }
#endif

        // An exception left a guarded call (see "@guard" in redirects.txt).
        public static void Swallowed(Exception e, string where)
        {
            Guard.Report(e, where);
        }
    }
}
