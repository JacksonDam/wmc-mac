// WmcProbe: the smallest possible host for Media Center's UI framework.
//
// It creates a UI session and one window and loads a single markup (MCML)
// page into it, without any of the Media Center shell. This is the test bed
// for the renderer stand-in: if a page draws correctly here, the framework,
// the message protocol and the renderer agree.
//
//   tools/run.py WmcProbe <page.mcml or resource uri>
using System;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.MediaCenter.UI;

static class Probe
{
    [DllImport("wmcshim")]
    static extern int wmc_run_main_loop();

    [DllImport("wmcshim")]
    static extern void wmc_stop_main_loop(int exitCode);

    // The Mac's main thread belongs to AppKit, so the framework's
    // "application" thread is a second thread, as large as a main thread.
    static int Main(string[] args)
    {
        var app = new Thread(() =>
        {
            int code = 1;
            try { code = Run(args); }
            finally { wmc_stop_main_loop(code); }
        }, 16 * 1024 * 1024);
        app.Name = "Application";
        app.SetApartmentState(ApartmentState.STA);
        app.Start();
        return wmc_run_main_loop();
    }

    static int Run(string[] args)
    {
        string source = args.Length > 0 ? args[0] : null;
        // The framework finds a page by a URI with a scheme; a plain file
        // name has none.
        if (source != null && source.IndexOf("://") < 0 && System.IO.File.Exists(source))
            source = "file://" + System.IO.Path.GetFullPath(source);
        try
        {
            Console.Error.WriteLine("probe: creating UI session");
            var info = new RenderingInfo(Platform.Nt, DeviceType.NtDirectX9, SoundDeviceType.WinApi);
            var session = new UiSession(info);
            Console.Error.WriteLine("probe: session connected; creating window");
            var form = new NewUiForm(session);
            if (source != null) form.Source = source;
            form.Visible = true;
            Console.Error.WriteLine("probe: entering message loop");
            Application.Run();
            Console.Error.WriteLine("probe: message loop ended");
            return 0;
        }
        catch (Exception e)
        {
            for (Exception x = e; x != null; x = x.InnerException)
            {
                Console.Error.WriteLine("probe: " + x.GetType().FullName + ": " + x.Message);
                Console.Error.WriteLine(x.StackTrace);
            }
            return 1;
        }
    }
}
