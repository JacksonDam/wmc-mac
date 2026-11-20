// Windows XP Media Center Edition 2005's own crash reporters (Watson, in
// ehshell.exe and ehepg.dll) write a report, then start rundll32.exe and
// dwwin.exe to send it to Microsoft. Neither is here, and Mono would hand them
// to the Mac's "open". These replace their bodies (redirects.txt, [xp]): the
// failure goes to the log, and Media Center ends as it would after a report.
#if XP
using System;

namespace WmcStandins
{
    public static partial class Compat
    {
        // CrashReporting.Watson.HandleFailure(exception, hangType, title, header, error)
        public static void Xp_CrashReport(Exception exception, string hangType, string title, string header, string error)
        {
            string what = exception != null ? exception.ToString() : "hang: " + hangType;
            ComTodo.Log("err", "Media Center failed: " + what);
        }

        // Microsoft.Ehome.Epg.CrashReporting.Watson.DumpAndTerminate: the
        // guide's copy of the same reporter.
        public static void Xp_GuideCrashReport(Exception exception, string title, string header, string error, bool terminateProcess)
        {
            ComTodo.Log("err", "the guide failed: " + (exception != null ? exception.ToString() : error));
            if (terminateProcess) Environment.Exit(1);
        }

        // eHome.Debug.eDebug.DumpExceptionToLog: the exceptions Media Center
        // catches and carries on from. Its retail build never opens the log
        // they are meant for; here they go to ours ("err" when not handled,
        // "exc" when recovered from or ignored).
        public static void Xp_DebugException(string message, Exception e)
        {
            Xp_DebugException(message, eHome.Debug.eDebug.ExceptionType.NotHandled, e, false);
        }

        public static void Xp_DebugException(string message, eHome.Debug.eDebug.ExceptionType type, Exception e)
        {
            Xp_DebugException(message, type, e, false);
        }

        public static void Xp_DebugException(string message, eHome.Debug.eDebug.ExceptionType type, Exception e, bool stop)
        {
            string channel = type == eHome.Debug.eDebug.ExceptionType.NotHandled ? "err" : "exc";
            ComTodo.Log(channel, (message ?? "exception") + " (" + type + "): " + e);
        }
    }
}
#endif
