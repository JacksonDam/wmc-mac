// Windows "libraries": the lists of folders that make up Music, Pictures,
// Videos and Recorded TV. Media Center reads and edits them (Settings >
// Media Libraries). Here each list starts with the Mac user's own folder of
// that kind plus the Public one, and is kept in a small file.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace WmcStandins
{
    public static class Libraries
    {
        public static readonly Guid Music = new Guid("2112AB0A-C86A-4FFE-A368-0DE96E47012E");
        public static readonly Guid Pictures = new Guid("A990AE9F-A03B-4E80-94BC-9912D7504104");
        public static readonly Guid Videos = new Guid("491E922F-5643-4AF4-A7EB-4E7A138D8174");
        public static readonly Guid RecordedTV = new Guid("1A6FDBA2-F42D-4358-A798-B74D745926C5");

        static readonly object s_lock = new object();
        static Dictionary<Guid, List<string>> s_folders;
        public static event Action Changed;

        static string StorePath
        {
            get
            {
                string dir = Path.Combine(Compat.Environment_GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WmcMac");
                Directory.CreateDirectory(dir);
                return Path.Combine(dir, "libraries.tsv");
            }
        }

        static List<string> Defaults(Guid library)
        {
            var list = new List<string>();
            Action<Environment.SpecialFolder> add = f =>
            {
                string p = Compat.Environment_GetFolderPath(f);
                if (!string.IsNullOrEmpty(p) && Directory.Exists(p)) list.Add(p);
            };
            if (library == Music) { add(Environment.SpecialFolder.MyMusic); add(Environment.SpecialFolder.CommonMusic); }
            else if (library == Pictures) { add(Environment.SpecialFolder.MyPictures); add(Environment.SpecialFolder.CommonPictures); }
            else if (library == Videos) { add(Environment.SpecialFolder.MyVideos); add(Environment.SpecialFolder.CommonVideos); }
            else if (library == RecordedTV)
            {
                string p = Path.Combine(Path.GetDirectoryName(Compat.Environment_GetFolderPath(Environment.SpecialFolder.CommonMusic)), "Recorded TV");
                Directory.CreateDirectory(p);
                list.Add(p);
            }
            return list;
        }

        static Dictionary<Guid, List<string>> Load()
        {
            if (s_folders != null) return s_folders;
            s_folders = new Dictionary<Guid, List<string>>();
            try
            {
                if (File.Exists(StorePath))
                    foreach (string line in File.ReadAllLines(StorePath))
                    {
                        string[] f = line.Split('\t');
                        Guid id;
                        if (f.Length < 1 || !Guid.TryParse(f[0], out id)) continue;
                        var list = new List<string>();
                        for (int i = 1; i < f.Length; i++) if (f[i].Length > 0) list.Add(f[i]);
                        s_folders[id] = list;
                    }
            }
            catch (IOException) { }
            return s_folders;
        }

        static void Save()
        {
            var text = new StringBuilder();
            foreach (var kv in s_folders) text.Append(kv.Key).Append('\t').Append(string.Join("\t", kv.Value)).Append('\n');
            try { File.WriteAllText(StorePath, text.ToString()); } catch (IOException) { }
        }

        public static List<string> Folders(Guid library)
        {
            lock (s_lock)
            {
                List<string> list;
                if (!Load().TryGetValue(library, out list)) return Defaults(library);
                return new List<string>(list);
            }
        }

        static string Clean(string path)
        {
            path = (path ?? "").Trim();
            while (path.Length > 1 && (path.EndsWith("/") || path.EndsWith("\\"))) path = path.Substring(0, path.Length - 1);
            return path;
        }

        public static bool Add(Guid library, string folder)
        {
            folder = Clean(folder);
            if (folder.Length == 0) return false;
            lock (s_lock)
            {
                var list = Folders(library);
                if (list.Exists(p => string.Equals(p, folder, StringComparison.OrdinalIgnoreCase))) return true;
                list.Add(folder);
                Load()[library] = list;
                Save();
            }
            Raise();
            return true;
        }

        public static bool Remove(Guid library, string folder)
        {
            folder = Clean(folder);
            lock (s_lock)
            {
                var list = Folders(library);
                if (list.RemoveAll(p => string.Equals(p, folder, StringComparison.OrdinalIgnoreCase)) == 0) return false;
                Load()[library] = list;
                Save();
            }
            Raise();
            return true;
        }

        static void Raise()
        {
            var handler = Changed;
            if (handler != null) handler();
        }
    }

    public static partial class Compat
    {
        const int E_FAIL = unchecked((int)0x80004005);

        public static int Libraries_GetLocations(ref Guid library, out string[] locations)
        {
            locations = Libraries.Folders(library).ToArray();
            return 0;
        }

        public static int Libraries_GetLocationsFromPath(string libraryPath, out string[] locations)
        {
            locations = new string[0];
            return E_FAIL;
        }

        public static int Libraries_Add(ref Guid library, string location)
        {
            return Libraries.Add(library, location) ? 0 : E_FAIL;
        }

        public static int Libraries_Remove(ref Guid library, string location)
        {
            return Libraries.Remove(library, location) ? 0 : E_FAIL;
        }

        public static int Libraries_RemoveAt(ref Guid library, uint index)
        {
            var list = Libraries.Folders(library);
            return index < list.Count && Libraries.Remove(library, list[(int)index]) ? 0 : E_FAIL;
        }

        // Where new files of a kind are saved: the first folder of its library.
        public static int Libraries_DefaultSaveLocation(ref Guid library, StringBuilder path, int size)
        {
            var list = Libraries.Folders(library);
            if (list.Count == 0 || path == null) return E_FAIL;
            path.Length = 0;
            path.Append(list[0]);
            return 0;
        }
    }
}
