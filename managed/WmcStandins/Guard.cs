// What happens when a part of Media Center fails.
//
// On Windows an unhandled exception ends Media Center. Here large parts lean
// on Windows services that have no stand-in yet, so a failure in one page
// should not take the rest down: the call that runs each queued piece of
// work is guarded (redirects.txt), the exception is reported on the console,
// and if it happened while opening a page Media Center goes back to the page
// before and says so in one of its own dialogs.
//
// WMC_STRICT=1 turns this off: the exception travels on as it would have.
using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Threading;
using Microsoft.MediaCenter.UI;
using ServiceBus.UIFramework;

namespace WmcStandins
{
    public static class Guard
    {
        static readonly bool s_strict = System.Environment.GetEnvironmentVariable("WMC_STRICT") == "1";
        static readonly Dictionary<string, int> s_seen = new Dictionary<string, int>();
        static bool s_recovering;
        static bool s_leavePending;

        public static void Report(Exception e, string where)
        {
            if (e is ThreadAbortException) return;   // the runtime raises it again by itself
            if (s_strict) ExceptionDispatchInfo.Capture(e).Throw();
            Exception inner = e;
            while (inner.InnerException != null) inner = inner.InnerException;
            string first = FirstFrame(inner);
            string key = inner.GetType().FullName + "|" + first;
            int count;
            lock (s_seen)
            {
                s_seen.TryGetValue(key, out count);
                s_seen[key] = count + 1;
            }
            if (count == 0)
            {
                for (Exception x = e; x != null; x = x.InnerException)
                {
                    Console.Error.WriteLine("host: guarded: " + x.GetType().FullName + ": " + x.Message);
                    Console.Error.WriteLine(x.StackTrace);
                }
            }
            else if (count < 4)
            {
                Console.Error.WriteLine("host: guarded again: " + inner.GetType().FullName + ": " + inner.Message + " " + first);
            }
            // A page that fails while Media Center is opening it is left
            // half made. The notifications to it are guarded one by one, so
            // the navigation itself completes; afterwards step back off it.
            if (!s_recovering && !s_leavePending && where.StartsWith("ServiceBus.UIFramework.") &&
                new System.Diagnostics.StackTrace().ToString().Contains("PageBasedUCPService.LoadNewPageInternal"))
            {
                s_leavePending = true;
                Application.DeferredInvoke(delegate { LeaveBrokenPage(); });
            }
        }

        static string FirstFrame(Exception e)
        {
            string trace = e.StackTrace ?? "";
            int end = trace.IndexOf('\n');
            return (end < 0 ? trace : trace.Substring(0, end)).Trim();
        }

        static void LeaveBrokenPage()
        {
            s_leavePending = false;
            PageBasedUCPService ucp = PageBasedUCPService.DefaultUCP;
            if (ucp == null) return;
            s_recovering = true;
            try
            {
                try
                {
                    Page broken = ucp.CurrentPage;
                    try { ucp.BackPage(); }
                    catch (Exception x)
                    {
                        Console.Error.WriteLine("host: the failed page could not handle Back (" + x.GetType().Name + "); moving back without it");
                    }
                    if (ucp.CurrentPage == broken) ucp.MoveToPage();
                }
                catch (Exception x) { Console.Error.WriteLine("host: could not go back from the failed page: " + x.GetType().Name + ": " + x.Message); }
                try
                {
                    Dialog.ShowMessage("NOT ON THE MAC YET",
                        "This part of Windows Media Center depends on something that has no Mac stand-in yet, so it cannot open.");
                }
                catch (Exception x) { Console.Error.WriteLine("host: could not show the dialog: " + x.GetType().Name + ": " + x.Message); }
            }
            finally { s_recovering = false; }
        }
    }
}
