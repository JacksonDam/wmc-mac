// One file in the library: a song, a picture or a video.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using WmcComBases;
using ehiwmp;

namespace WmcStandins.Wmp
{
    public sealed class MediaItem : MediaBase
    {
        public readonly string Path;
        public readonly string Kind;      // "audio", "photo", "video"
        readonly Dictionary<string, string> _values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public bool HasArtwork;
        string _artworkPath;

        public MediaItem(string path, string kind)
        {
            Path = path;
            Kind = kind;
        }

        public void Set(string name, string value)
        {
            if (!string.IsNullOrEmpty(value)) _values[name] = value;
        }

        string Raw(string name)
        {
            string v;
            return _values.TryGetValue(name, out v) ? v : "";
        }

        // Windows Media Player's attribute names, and what each means here.
        public string Get(string name)
        {
            if (string.IsNullOrEmpty(name)) return "";
            switch (name.ToLowerInvariant())
            {
                case "name":
                case "title":
                {
                    string t = Raw("title");
                    return t.Length > 0 ? t : System.IO.Path.GetFileNameWithoutExtension(Path);
                }
                case "artist": case "author": case "displayartist": return Raw("artist");
                case "wm/albumartist":
                {
                    string a = Raw("albumartist");
                    return a.Length > 0 ? a : Raw("artist");
                }
                case "album": case "wm/albumtitle": case "albumid": return Raw("album");
                case "albumidalbumartist": return Raw("album") + "*;*" + Get("WM/AlbumArtist");
                case "genre": case "wm/genre": return Raw("genre");
                case "wm/tracknumber": case "originalindex": return Raw("track");
                case "wm/composer": case "composer": return Raw("composer");
                case "duration": return Raw("duration");
                case "releasedate": case "releasedateyear": case "wm/year": return Raw("year");
                case "mediatype": return Kind;
                case "mediacontenttypes": return Kind == "audio" ? "3" : Kind == "video" ? "4" : "5";
                case "sourceurl": case "dlnasourceuri": return Path;   // (both unique to the file)
                case "titlesortorder": return Get("Title");
                case "displayartistsortorder": case "artistsortorder": return Raw("artist");
                case "albumtitlesortorder": return Raw("album");
                case "filetype": return System.IO.Path.GetExtension(Path).TrimStart('.').ToLowerInvariant();
                case "filesize": return Raw("size");
                case "userrating": case "usereffectiverating": case "userplaycount": return Raw(name).Length > 0 ? Raw(name) : "0";
                case "trackingid": return Id("item:" + Path);
                case "wm/wmcollectionid": case "wm/wmcollectiongroupid":
                {
                    if (Raw("album").Length == 0) return "";
                    string id = Id("album:" + Get("AlbumIDAlbumArtist"));
                    ProvideCover(id);
                    return id;
                }
                case "acquisitiontime": case "datetaken": case "daterecorded":
                    return Modified.ToString(CultureInfo.CurrentCulture);
                case "acquisitiontimeyearmonth": case "datetakenyearmonth": case "daterecordedyearmonth":
                    return Modified.Year.ToString(CultureInfo.InvariantCulture) + "/" + Modified.Month.ToString(CultureInfo.InvariantCulture);
                case "datetakenyearmonthday": case "daterecordedyearmonthday":
                    return Modified.ToString("yyyy/M/d", CultureInfo.InvariantCulture);
            }
            if (name.StartsWith("Folder", StringComparison.OrdinalIgnoreCase) && name.Length == 8)
            {
                // Folder00, Folder01, ...: the folders on the way to the file.
                int depth;
                if (int.TryParse(name.Substring(6), out depth))
                {
                    string[] parts = System.IO.Path.GetDirectoryName(Path).Split(new[] { '/' }, StringSplitOptions.RemoveEmptyEntries);
                    return depth < parts.Length ? parts[depth] : "";
                }
            }
            return Raw(name);
        }

        public DateTime Modified
        {
            get
            {
                long ticks;
                return long.TryParse(Raw("mtime"), out ticks) ? new DateTime(ticks) : DateTime.MinValue;
            }
        }

        public double Seconds
        {
            get
            {
                double d;
                return double.TryParse(Raw("duration"), NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d : 0;
            }
        }

        static string Id(string text)
        {
            using (var md5 = MD5.Create())
                return "{" + new Guid(md5.ComputeHash(Encoding.UTF8.GetBytes(text))).ToString().ToUpperInvariant() + "}";
        }

        // Media Center looks for an album's cover as a file named after the
        // album's collection id, in its own art cache folder (among other
        // places). The picture inside the song is put there, once per album.
        static readonly HashSet<string> s_coversDone = new HashSet<string>();

        void ProvideCover(string collectionId)
        {
            lock (s_coversDone)
            {
                if (!s_coversDone.Add(collectionId)) return;
            }
            // Any song of the album that carries a picture will do.
            MediaItem source = HasArtwork ? this : null;
            if (source == null)
            {
                string album = Get("AlbumIDAlbumArtist");
                foreach (var other in MediaLibrary.Items)
                    if (other.HasArtwork && other.Kind == "audio" && other.Get("AlbumIDAlbumArtist") == album) { source = other; break; }
            }
            if (source == null) return;
            try
            {
                // (Media Center spells this folder with backslashes and tests
                // for the file through a Windows call, which takes either slash)
                string folder = Compat.Environment_GetFolderPath(Environment.SpecialFolder.LocalApplicationData) + "/Microsoft/eHome/Art Cache/";
                Directory.CreateDirectory(folder);
                string file = System.IO.Path.Combine(folder, string.Format(CultureInfo.CurrentCulture, "AlbumArt_{0}_Large.jpg", collectionId));
                if (!File.Exists(file)) Native.wmc_media_artwork(source.Path, file);
            }
            catch (IOException) { }
        }

        // The picture inside a sound file, written out once to a cache folder.
        public string ArtworkPath
        {
            get
            {
                if (!HasArtwork) return null;
                if (_artworkPath == null)
                {
                    string dir = System.IO.Path.Combine(Compat.Environment_GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WmcMac/artwork");
                    Directory.CreateDirectory(dir);
                    string file = System.IO.Path.Combine(dir, Id("art:" + Path).Trim('{', '}') + ".jpg");
                    if (!File.Exists(file) && Native.wmc_media_artwork(Path, file) == 0) HasArtwork = false;
                    _artworkPath = HasArtwork ? file : "";
                }
                return _artworkPath.Length > 0 ? _artworkPath : null;
            }
        }

        // ---- IWMPMedia3 ----
        public override string get_sourceURL() { return Path; }
        public override string get_name() { return Get("Title"); }
        public override void set_name(string value) { Set("title", value); }
        public override double get_duration() { return Seconds; }
        public override string get_durationString()
        {
            int s = (int)Seconds;
            return s >= 3600 ? string.Format("{0}:{1:00}:{2:00}", s / 3600, s / 60 % 60, s % 60) : string.Format("{0:00}:{1:00}", s / 60, s % 60);
        }
        public override string getItemInfo(string name) { Asked("item", name); return Get(name); }

        // Which attributes Media Center asks for, each named once on the
        // "wmpq" log channel.
        static readonly HashSet<string> s_asked = new HashSet<string>();
        internal static void Asked(string of, string name)
        {
            lock (s_asked)
            {
                if (!s_asked.Add(of + ":" + name)) return;
            }
            ComTodo.Log("wmpq", of + " attribute " + name);
        }
        public override void setItemInfo(string name, string value) { _values[name] = value ?? ""; }
        public override bool get_isIdentical(IWMPMedia other)
        {
            var m = other as MediaItem;
            return m != null && (ReferenceEquals(m, this) || m.Path == Path);
        }
        public override bool isMemberOf(IWMPPlaylist playlist)
        {
            var p = playlist as Playlist;
            return p != null && p.Items.Contains(this);
        }
        public override bool isReadOnlyItem(string name) { return false; }
        public override IWMPErrorItem get_Error() { return null; }
        public override int get_attributeCount() { return _values.Count; }
        public override int get_markerCount() { return 0; }
        public override int get_imageSourceWidth() { return 0; }
        public override int get_imageSourceHeight() { return 0; }
        public override int getAttributeCountByType(string type, string language)
        {
            if (string.Equals(type, "WM/Picture", StringComparison.OrdinalIgnoreCase)) return ArtworkPath != null ? 1 : 0;
            return Get(type).Length > 0 ? 1 : 0;
        }
        public override object getItemInfoByType(string type, string language, int index)
        {
            if (string.Equals(type, "WM/Picture", StringComparison.OrdinalIgnoreCase))
                return ArtworkPath != null ? new MetadataPicture(ArtworkPath) : null;
            return Typed(type);
        }

        // An attribute as the kind of value Windows Media Player gives for it:
        // dates as dates, lengths and ratings as numbers, the rest as text.
        public object Typed(string name)
        {
            switch ((name ?? "").ToLowerInvariant())
            {
                case "acquisitiontime": case "datetaken": case "daterecorded":
                case "acquisitiontimeyearmonth": case "datetakenyearmonth": case "daterecordedyearmonth":
                case "acquisitiontimeyearmonthday": case "datetakenyearmonthday": case "daterecordedyearmonthday":
                    return Modified;
                case "duration": return Seconds;
                case "userrating": case "usereffectiverating": case "userplaycount": case "wm/tracknumber":
                {
                    uint n;
                    uint.TryParse(Get(name), out n);
                    return n;
                }
                case "filesize":
                {
                    long n;
                    long.TryParse(Get(name), out n);
                    return n;
                }
            }
            string text = Get(name);
            return text.Length > 0 ? text : null;
        }
        public override string ToString() { return Kind + ":" + Path; }
    }

    // A picture attached to a media item. Type 3 is "front cover".
    public sealed class MetadataPicture : MetadataPictureBase
    {
        readonly string _path;
        public MetadataPicture(string path) { _path = path; }
        public override string get_URL() { return _path; }
        public override string get_mimeType() { return "image/jpeg"; }
        public override string get_pictureType() { return "3"; }
        public override string get_Description() { return ""; }
    }

    static class Native
    {
        const string Shim = "wmcshim";
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern int wmc_media_tags(string path, byte[] buffer, int size);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern void wmc_watch_folders(string folders);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern int wmc_watch_changes();
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern int wmc_media_artwork(string path, string dest);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern IntPtr wmc_audio_open(string path);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern void wmc_audio_close(IntPtr handle);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern void wmc_audio_play(IntPtr handle);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern void wmc_audio_pause(IntPtr handle);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern double wmc_audio_duration(IntPtr handle);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern double wmc_audio_position(IntPtr handle);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern void wmc_audio_set_position(IntPtr handle, double seconds);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern int wmc_audio_state(IntPtr handle);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern void wmc_audio_set_volume(IntPtr handle, float volume);
        [System.Runtime.InteropServices.DllImport(Shim)] public static extern void wmc_audio_set_rate(IntPtr handle, float rate);
    }
}
