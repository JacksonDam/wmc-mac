// Members of COM stand-ins that are not written yet report here (the
// generated base classes call Hit; see managed/wmctool/bases.cs), once each,
// on the "todo" log channel.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WmcStandins
{
    public static class ComTodo
    {
        static readonly HashSet<string> s_seen = new HashSet<string>();

        [DllImport("wmcshim")]
        static extern void wmc_log_line(string channel, string text);

        public static void Hit(string member)
        {
            lock (s_seen)
            {
                if (!s_seen.Add(member)) return;
            }
            wmc_log_line("todo", "COM stand-in: " + member + " is not written");
        }

        public static void Log(string channel, string text)
        {
            wmc_log_line(channel, text);
        }
    }
}
