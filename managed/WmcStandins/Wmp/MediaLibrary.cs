// The media library: every song, picture and video in the folders Media
// Center watches (the Mac user's Music, Pictures and Movies, and the Public
// folders under the stand-in for C:\).
//
// Songs have their tags read once and remembered in a cache file keyed by
// path, size and modification time, so only new or changed files cost
// anything on later starts.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace WmcStandins.Wmp
{
    public static class MediaLibrary
    {
        static readonly object s_lock = new object();
        static List<MediaItem> s_items;

        static readonly Dictionary<string, string> s_kinds = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { ".mp3", "audio" }, { ".m4a", "audio" }, { ".aac", "audio" }, { ".wav", "audio" }, { ".aif", "audio" },
            { ".aiff", "audio" }, { ".flac", "audio" }, { ".caf", "audio" }, { ".m4b", "audio" }, { ".wma", "audio" },
            { ".jpg", "photo" }, { ".jpeg", "photo" }, { ".png", "photo" }, { ".gif", "photo" }, { ".bmp", "photo" },
            { ".tif", "photo" }, { ".tiff", "photo" }, { ".heic", "photo" },
            { ".mp4", "video" }, { ".m4v", "video" }, { ".mov", "video" }, { ".wmv", "video" }, { ".asf", "video" },
            { ".avi", "video" }, { ".divx", "video" },
        };

        public static string KindOf(string path)
        {
            string kind;
            return s_kinds.TryGetValue(Path.GetExtension(path), out kind) ? kind : null;
        }

        // The folders that are scanned: those of the Music, Pictures and
        // Videos libraries, each for its own kind of file.
        static readonly KeyValuePair<Guid, string>[] s_libraries =
        {
            new KeyValuePair<Guid, string>(Libraries.Music, "audio"),
            new KeyValuePair<Guid, string>(Libraries.Pictures, "photo"),
            new KeyValuePair<Guid, string>(Libraries.Videos, "video"),
        };

        public static List<string> Folders
        {
            get
            {
                var all = new List<string>();
                foreach (var library in s_libraries)
                    foreach (string folder in Libraries.Folders(library.Key))
                        if (!all.Contains(folder)) all.Add(folder);
                return all;
            }
        }

        static MediaLibrary()
        {
            // A folder was added or removed: look again on the next question.
            Libraries.Changed += delegate { lock (s_lock) { s_items = null; } };
        }

        // How many times files have come or gone in the library folders
        // (native/platform/watch.m); Player looks at it every few seconds.
        public static int Changes { get { return Native.wmc_watch_changes(); } }

        // Look again on the next question.
        public static void Invalidate()
        {
            lock (s_lock) { s_items = null; }
        }

        public static List<MediaItem> Items
        {
            get
            {
                lock (s_lock)
                {
                    if (s_items == null) s_items = Scan();
                    return s_items;
                }
            }
        }

        public static MediaItem Find(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            if (path.StartsWith("file://", StringComparison.OrdinalIgnoreCase)) path = new Uri(path).LocalPath;
            foreach (var item in Items)
                if (string.Equals(item.Path, path, StringComparison.OrdinalIgnoreCase)) return item;
            return null;
        }

        // An item for a file outside the library (played by path).
        public static MediaItem Create(string path)
        {
            if (path != null && path.StartsWith("file://", StringComparison.OrdinalIgnoreCase)) path = new Uri(path).LocalPath;
            var item = new MediaItem(path ?? "", KindOf(path ?? "") ?? "other");
            if (File.Exists(path)) Describe(item, new FileInfo(path), null, null);
            return item;
        }

        static string CachePath
        {
            get
            {
                string dir = Path.Combine(Compat.Environment_GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WmcMac");
                Directory.CreateDirectory(dir);
                return Path.Combine(dir, "library-tags.tsv");
            }
        }

        static List<MediaItem> Scan()
        {
            var watch = System.Diagnostics.Stopwatch.StartNew();
            var cache = new Dictionary<string, string[]>();
            try
            {
                if (File.Exists(CachePath))
                    foreach (string line in File.ReadAllLines(CachePath))
                    {
                        string[] f = line.Split('\t');
                        if (f.Length == 4) cache[f[0]] = f;
                    }
            }
            catch (IOException) { }
            var items = new List<MediaItem>();
            var fresh = new StringBuilder();
            int read = 0;
            foreach (var library in s_libraries)
                foreach (string root in Libraries.Folders(library.Key))
                    if (Directory.Exists(root)) Walk(root, 0, library.Value, items, cache, fresh, ref read);
            try { File.WriteAllText(CachePath, fresh.ToString()); } catch (IOException) { }
            // From now on, files that come and go in these folders are noticed.
            Native.wmc_watch_folders(string.Join("\n", Folders.ToArray()));
            ComTodo.Log("wmp", string.Format("library: {0} items ({1} tag reads) in {2} ms", items.Count, read, watch.ElapsedMilliseconds));
            return items;
        }

        static bool Skip(string name)
        {
            if (name.StartsWith(".")) return true;
            string ext = Path.GetExtension(name).ToLowerInvariant();
            // Packages: folders that are another program's own storage.
            return ext.EndsWith("library") || ext == ".app" || ext == ".bundle" || ext == ".fcpbundle" || ext == ".band" || ext == ".logicx" || ext == ".localized" && false;
        }

        static void Walk(string dir, int depth, string wanted, List<MediaItem> items, Dictionary<string, string[]> cache, StringBuilder fresh, ref int read)
        {
            if (depth > 12) return;
            string[] files, dirs;
            try
            {
                files = Directory.GetFiles(dir);
                dirs = Directory.GetDirectories(dir);
            }
            catch (Exception) { return; }   // not readable: leave it out
            Array.Sort(files, StringComparer.OrdinalIgnoreCase);
            Array.Sort(dirs, StringComparer.OrdinalIgnoreCase);
            foreach (string file in files)
            {
                string name = Path.GetFileName(file);
                if (name.StartsWith(".")) continue;
                string kind = KindOf(file);
                if (kind != wanted) continue;
                FileInfo info;
                try { info = new FileInfo(file); } catch (Exception) { continue; }
                var item = new MediaItem(file, kind);
                if (Describe(item, info, cache, fresh)) read++;
                items.Add(item);
            }
            foreach (string sub in dirs)
            {
                if (Skip(Path.GetFileName(sub))) continue;
                try
                {
                    if (depth > 0 && (File.GetAttributes(sub) & FileAttributes.ReparsePoint) != 0) continue;   // a link: could loop
                }
                catch (Exception) { continue; }
                Walk(sub, depth + 1, wanted, items, cache, fresh, ref read);
            }
        }

        // Fills in an item. Returns true if the file's tags had to be read.
        static bool Describe(MediaItem item, FileInfo info, Dictionary<string, string[]> cache, StringBuilder fresh)
        {
            item.Set("size", info.Length.ToString(CultureInfo.InvariantCulture));
            item.Set("mtime", info.LastWriteTime.Ticks.ToString(CultureInfo.InvariantCulture));
            if (item.Kind != "audio") return false;
            string stamp = info.Length.ToString(CultureInfo.InvariantCulture) + ":" + info.LastWriteTimeUtc.Ticks.ToString(CultureInfo.InvariantCulture);
            string tags = null;
            bool read = false;
            string[] cached;
            if (cache != null && cache.TryGetValue(item.Path, out cached) && cached[1] == stamp) tags = cached[3];
            if (tags == null)
            {
                var buffer = new byte[8192];
                int n = Native.wmc_media_tags(item.Path, buffer, buffer.Length);
                tags = n > 0 ? Encoding.UTF8.GetString(buffer, 0, n).Replace('\t', ' ').Replace("\n", "\u0001") : "";
                read = true;
            }
            foreach (string pair in tags.Split('\u0001'))
            {
                int eq = pair.IndexOf('=');
                if (eq <= 0) continue;
                string key = pair.Substring(0, eq), value = pair.Substring(eq + 1).Trim();
                if (key == "artwork") item.HasArtwork = value == "1";
                else if (key == "track")
                {
                    // "3/12" means track 3 of 12.
                    int slash = value.IndexOf('/');
                    item.Set("track", slash > 0 ? value.Substring(0, slash) : value);
                }
                else if (key == "year") item.Set("year", value.Length >= 4 ? value.Substring(0, 4) : value);
                else item.Set(key, value);
            }
            if (fresh != null) fresh.Append(item.Path).Append('\t').Append(stamp).Append('\t').Append(item.Kind).Append('\t').Append(tags).Append('\n');
            return read;
        }
    }
}
