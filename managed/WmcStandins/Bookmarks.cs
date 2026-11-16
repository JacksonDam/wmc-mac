// Where each video was stopped, so that it can be resumed from there.
// Media Center keeps this in its object store; with no store it lives in a
// tab-separated file: name, seconds, expiry (ticks).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using Microsoft.MediaCenter.Guide;

namespace WmcStandins
{
    public static partial class Compat
    {
        static Dictionary<string, KeyValuePair<double, long>> s_bookmarks;
        static readonly object s_bookmarkLock = new object();

        static string BookmarkFile
        {
            get
            {
                string dir = Path.Combine(Environment_GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WmcMac");
                Directory.CreateDirectory(dir);
                return Path.Combine(dir, "bookmarks.tsv");
            }
        }

        static Dictionary<string, KeyValuePair<double, long>> LoadBookmarks()
        {
            if (s_bookmarks != null) return s_bookmarks;
            s_bookmarks = new Dictionary<string, KeyValuePair<double, long>>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (File.Exists(BookmarkFile))
                    foreach (string line in File.ReadAllLines(BookmarkFile))
                    {
                        string[] f = line.Split('\t');
                        double seconds;
                        long expires;
                        if (f.Length == 3 && double.TryParse(f[1], NumberStyles.Float, CultureInfo.InvariantCulture, out seconds) && long.TryParse(f[2], out expires))
                            s_bookmarks[f[0]] = new KeyValuePair<double, long>(seconds, expires);
                    }
            }
            catch (IOException) { }
            return s_bookmarks;
        }

        static void SaveBookmarks()
        {
            var lines = new List<string>();
            foreach (var kv in s_bookmarks)
                lines.Add(kv.Key + "\t" + kv.Value.Key.ToString(CultureInfo.InvariantCulture) + "\t" + kv.Value.Value.ToString(CultureInfo.InvariantCulture));
            try { File.WriteAllLines(BookmarkFile, lines); } catch (IOException) { }
        }

        public static void Bookmarks_Create(VideoFileBookmarkManager manager)
        {
        }

        public static TimeSpan Bookmarks_Get(VideoFileBookmarkManager manager, string name)
        {
            if (string.IsNullOrEmpty(name)) return TimeSpan.Zero;
            lock (s_bookmarkLock)
            {
                KeyValuePair<double, long> entry;
                if (LoadBookmarks().TryGetValue(name, out entry) && entry.Value > DateTime.UtcNow.Ticks) return TimeSpan.FromSeconds(entry.Key);
            }
            return TimeSpan.Zero;
        }

        public static TimeSpan Bookmarks_Get(VideoFileBookmarkManager manager, FileSystemInfo file)
        {
            return file == null ? TimeSpan.Zero : Bookmarks_Get(manager, file.FullName);
        }

        public static TimeSpan Bookmarks_Get(VideoFileBookmarkManager manager, Uri uri)
        {
            return uri == null ? TimeSpan.Zero : Bookmarks_Get(manager, uri.AbsoluteUri);
        }

        public static void Bookmarks_Update(VideoFileBookmarkManager manager, string name, TimeSpan bookmark, int days)
        {
            if (string.IsNullOrEmpty(name)) return;
            lock (s_bookmarkLock)
            {
                var all = LoadBookmarks();
                if (bookmark == TimeSpan.Zero) all.Remove(name);
                else all[name] = new KeyValuePair<double, long>(bookmark.TotalSeconds, DateTime.UtcNow.AddDays(days).Ticks);
                SaveBookmarks();
            }
        }

        public static void Bookmarks_Update(VideoFileBookmarkManager manager, FileSystemInfo file, TimeSpan bookmark)
        {
            if (file != null) Bookmarks_Update(manager, file.FullName, bookmark, 365);
        }

        public static void Bookmarks_Update(VideoFileBookmarkManager manager, Uri uri, TimeSpan bookmark)
        {
            if (uri != null) Bookmarks_Update(manager, uri.AbsoluteUri, bookmark, 30);
        }

        public static void Bookmarks_Clear(VideoFileBookmarkManager manager)
        {
            lock (s_bookmarkLock)
            {
                LoadBookmarks().Clear();
                SaveBookmarks();
            }
        }
    }
}
