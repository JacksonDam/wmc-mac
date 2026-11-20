// WmcHost: starts Media Center itself.
//
// On Windows a small native program (ehshell.exe) starts the .NET runtime and
// calls ServiceBus.UIFramework.UserControlPoint.Launch in ehshell.dll. This
// does the same from managed code, on the framework's "application" thread,
// with the Mac's main thread left to AppKit. (XP Media Center Edition's
// ehshell.exe is itself .NET: its Main is called the same way.)
//
//   tools/run.py WmcHost [Media Center command-line arguments]
using System;
using System.Runtime.InteropServices;
using System.Threading;

static class Host
{
    [DllImport("wmcshim")]
    static extern int wmc_run_main_loop();

    [DllImport("wmcshim")]
    static extern void wmc_stop_main_loop(int exitCode);

    static int Main(string[] args)
    {
        // Windows always defines these; Media Center builds paths with them
        // (%windir%\ehome\...). The shim maps C:\Windows to the app folder.
        if (Environment.GetEnvironmentVariable("windir") == null) Environment.SetEnvironmentVariable("windir", @"C:\Windows");
        if (Environment.GetEnvironmentVariable("SystemRoot") == null) Environment.SetEnvironmentVariable("SystemRoot", @"C:\Windows");
        // Reading the tags of the music library can take a while the first
        // time: start on it now, so that it is ready when a library is opened.
        ThreadPool.QueueUserWorkItem(delegate { WmcStandins.Wmp.MediaLibrary.Items.GetHashCode(); });
        var app = new Thread(() =>
        {
            int code = 1;
            try
            {
#if XP
                ServiceBus.UIFramework.UserControlPoint.Main(args);
                code = 0;
                Console.Error.WriteLine("host: Main returned");
#else
                code = ServiceBus.UIFramework.UserControlPoint.Launch(string.Join(" ", args));
                Console.Error.WriteLine("host: Launch returned " + code);
#endif
            }
            catch (Exception e)
            {
                for (Exception x = e; x != null; x = x.InnerException)
                {
                    Console.Error.WriteLine("host: " + x.GetType().FullName + ": " + x.Message);
                    Console.Error.WriteLine(x.StackTrace);
                }
            }
            finally { wmc_stop_main_loop(code); }
        }, 16 * 1024 * 1024);
        // Launch (Main on XP) names its own thread ("Application"), and a name can be set only once.
        app.SetApartmentState(ApartmentState.STA);
        app.Start();
        return wmc_run_main_loop();
    }
}
