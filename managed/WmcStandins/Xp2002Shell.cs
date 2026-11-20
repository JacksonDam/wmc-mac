// XP Media Center Edition 2002's shell keeps its settings in XML files
// (ehshell.config, one for the machine and one for the user), not in the
// registry. Its first-run mark is there too: until the set-up wizard has
// finished, the machine file names the wizard's first page. The other Media
// Centers are started with that mark set (tools/setup_registry.py writes it
// into the registry, unless the first run is asked for); for 2002 the same
// registry value decides what a new machine file says.
#if XP2002
using System;
using System.IO;
using Microsoft.Win32;

namespace WmcStandins
{
    public static partial class Compat
    {
        // ehuihlp.dll's CreateOcxAndClientSite: Windows Media Player as an
        // ActiveX control, sited in the shell's window. Here the stand-in
        // (Wmp/Player.cs), the same object each time, as the control was.
        public static void Xp2002_CreatePlayer(Fast.Windows.NativeMethods.Win32.HWND window, ref object control)
        {
            control = Wmp.Player.Instance;
        }

        public static Microsoft.Ehome.Epg.Channel[] Xp2002_NoChannels()
        {
            return new Microsoft.Ehome.Epg.Channel[0];
        }

        public static void Thread_set_Priority(System.Threading.Thread thread, System.Threading.ThreadPriority priority)
        {
        }

        // Guide.Initialize without the download service it listens to: the
        // guide file is loaded (none is here, which makes an empty guide).
        public static void Xp2002_GuideInitialize(string file, Microsoft.Ehome.Epg.Guide.InitLoadOption option)
        {
            if (Microsoft.Ehome.Epg.Guide.s_initCalled) return;
            Microsoft.Ehome.Epg.Guide.s_initCalled = true;
            if (option == Microsoft.Ehome.Epg.Guide.InitLoadOption.DontLoad) return;
            new Microsoft.Ehome.Epg.GuideLoader(Microsoft.Ehome.Epg.Helper.EpgFileHelper.CurrentEpgFile, null,
                                                option == Microsoft.Ehome.Epg.Guide.InitLoadOption.LoadInBackground);
        }
    }

    public static class Xp2002Shell
    {
        const string GlobalSettings = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Media Center\Settings\MCE.GlobalSettings";

        public static void PrepareSettings()
        {
            string dir = Path.Combine(Compat.Environment_GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Microsoft", "eHome");
            string file = Path.Combine(dir, "ehshell.config");
            if (File.Exists(file)) return;
            string page;
            using (RegistryKey key = Registry.LocalMachine.OpenSubKey(GlobalSettings))
                page = key != null ? key.GetValue("strPageFirstRun") as string : null;
            if (page == null) return;   // the first run is pending: the shell's own default (its wizard)
            Directory.CreateDirectory(dir);
            // (the shell's own format: a SOAP-serialised ServiceBus.UIFramework.PageBasedUCPConfig)
            File.WriteAllText(file,
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                "<eHomeConfig>\n" +
                "  <PBUCPSvc.TV>\n" +
                "    <SOAP-ENV:Envelope xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" " +
                "xmlns:SOAP-ENC=\"http://schemas.xmlsoap.org/soap/encoding/\" xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
                "xmlns:clr=\"http://schemas.microsoft.com/clr/\" SOAP-ENV:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\n" +
                "  <SOAP-ENV:Body>\n" +
                "    <a1:PageBasedUCPConfig id=\"ref-1\" xmlns:a1=\"http://schemas.microsoft.com/clr/nsassem/ServiceBus.UIFramework/ehshell%2C%20Version%3D0.0.0.0%2C%20Culture%3Dneutral%2C%20PublicKeyToken%3D31bf3856ad364e35\">\n" +
                "      <strPageFirstRun id=\"ref-2\">" + System.Security.SecurityElement.Escape(page) + "</strPageFirstRun>\n" +
                "      <enableTwoFootUI>1</enableTwoFootUI>\n" +
                "      <twoFootTimeoutInterval>5000</twoFootTimeoutInterval>\n" +
                "    </a1:PageBasedUCPConfig>\n" +
                "  </SOAP-ENV:Body>\n" +
                "</SOAP-ENV:Envelope>\n" +
                "  </PBUCPSvc.TV>\n" +
                "</eHomeConfig>\n");
        }
    }
}
#endif
