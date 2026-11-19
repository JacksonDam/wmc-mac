// Queries over the library and what they return: playlists (lists of items)
// and string collections (the distinct values of one attribute, each with
// the items that have it).
using System;
using System.Collections.Generic;
using System.Globalization;
using WmcComBases;
using ehiwmp;

namespace WmcStandins.Wmp
{
    // Conditions joined by "and", in groups joined by "or".
    public sealed class Query : QueryBase
    {
        struct Condition { public string Attribute, Operator, Value; }
        readonly List<List<Condition>> _groups = new List<List<Condition>> { new List<Condition>() };

        public override void addCondition(string attribute, string op, string value)
        {
            _groups[_groups.Count - 1].Add(new Condition { Attribute = attribute, Operator = op, Value = value ?? "" });
        }

        public override void beginNextGroup()
        {
            if (_groups[_groups.Count - 1].Count > 0) _groups.Add(new List<Condition>());
        }

        public override string ToString()
        {
            var parts = new List<string>();
            foreach (var group in _groups)
            {
                var conds = new List<string>();
                foreach (var c in group) conds.Add(c.Attribute + " " + c.Operator + " '" + c.Value + "'");
                if (conds.Count > 0) parts.Add(string.Join(" and ", conds));
            }
            return parts.Count == 0 ? "(all)" : string.Join(" or ", parts);
        }

        public bool Matches(MediaItem item)
        {
            bool any = false;
            foreach (var group in _groups)
            {
                if (group.Count == 0) continue;
                any = true;
                bool all = true;
                foreach (var c in group)
                    if (!Test(item.Get(c.Attribute), c.Operator, c.Value)) { all = false; break; }
                if (all) return true;
            }
            return !any;
        }

        static bool Test(string actual, string op, string wanted)
        {
            switch ((op ?? "").ToLowerInvariant())
            {
                case "equals": return string.Equals(actual, wanted, StringComparison.CurrentCultureIgnoreCase);
                case "notequals": return !string.Equals(actual, wanted, StringComparison.CurrentCultureIgnoreCase);
                case "contains": return actual.IndexOf(wanted, StringComparison.CurrentCultureIgnoreCase) >= 0;
                case "notcontains": return actual.IndexOf(wanted, StringComparison.CurrentCultureIgnoreCase) < 0;
                case "beginswith": return actual.StartsWith(wanted, StringComparison.CurrentCultureIgnoreCase);
                case "notbeginswith": return !actual.StartsWith(wanted, StringComparison.CurrentCultureIgnoreCase);
                case "greaterthan": return Sorting.Compare(actual, wanted) > 0;
                case "greaterthanorequals": return Sorting.Compare(actual, wanted) >= 0;
                case "lessthan": return Sorting.Compare(actual, wanted) < 0;
                case "lessthanorequals": return Sorting.Compare(actual, wanted) <= 0;
            }
            ComTodo.Hit("query operator " + op);
            return false;
        }
    }

    static class Sorting
    {
        // Numbers as numbers, dates as dates, the rest as text.
        public static int Compare(string a, string b)
        {
            double x, y;
            if (double.TryParse(a, NumberStyles.Float, CultureInfo.InvariantCulture, out x) && double.TryParse(b, NumberStyles.Float, CultureInfo.InvariantCulture, out y))
                return x.CompareTo(y);
            DateTime s, t;
            if (a.Length > 5 && b.Length > 5 && DateTime.TryParse(a, CultureInfo.CurrentCulture, DateTimeStyles.None, out s) && DateTime.TryParse(b, CultureInfo.CurrentCulture, DateTimeStyles.None, out t))
                return s.CompareTo(t);
            return string.Compare(a, b, StringComparison.CurrentCultureIgnoreCase);
        }

        // Items by one attribute, falling back to album order (album, track,
        // title) so that equal keys keep a sensible order.
        public static void Sort(List<MediaItem> items, string attribute, bool ascending)
        {
            var order = new Dictionary<MediaItem, int>();
            for (int i = 0; i < items.Count; i++) order[items[i]] = i;
            items.Sort((p, q) =>
            {
                int c = 0;
                if (!string.IsNullOrEmpty(attribute))
                {
                    c = Compare(p.Get(attribute), q.Get(attribute));
                    if (!ascending) c = -c;
                }
                if (c == 0 && p.Kind == "audio") c = Compare(p.Get("Album"), q.Get("Album"));
                if (c == 0 && p.Kind == "audio") c = Compare(p.Get("WM/TrackNumber"), q.Get("WM/TrackNumber"));
                if (c == 0) c = order[p].CompareTo(order[q]);
                return c;
            });
        }
    }

    public class Playlist : PlaylistBase
    {
        public readonly List<MediaItem> Items = new List<MediaItem>();
        readonly Dictionary<string, string> _info = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string _name;
        public Action<Playlist, WMPPlaylistChangeEventType> Changed;

        public Playlist(string name) { _name = name ?? ""; }
        public Playlist(string name, IEnumerable<MediaItem> items) : this(name) { Items.AddRange(items); }

        void Notify(WMPPlaylistChangeEventType change)
        {
            var handler = Changed;
            if (handler != null) handler(this, change);
        }

        public override int get_count() { return Items.Count; }
        public override IWMPMedia get_Item(int index) { return index >= 0 && index < Items.Count ? Items[index] : null; }
        public override string get_name() { return _name; }
        public override void set_name(string value) { _name = value ?? ""; Notify(WMPPlaylistChangeEventType.wmplcNameChange); }
        public override bool get_isIdentical(IWMPPlaylist other) { return ReferenceEquals(other, this); }
        public override int get_attributeCount() { return _info.Count; }
        public override string getItemInfo(string name)
        {
            string v;
            if (_info.TryGetValue(name ?? "", out v)) return v;
            if (string.Equals(name, "Name", StringComparison.OrdinalIgnoreCase) || string.Equals(name, "Title", StringComparison.OrdinalIgnoreCase)) return _name;
            if (string.Equals(name, "MediaType", StringComparison.OrdinalIgnoreCase)) return "playlist";
            return "";
        }
        public override void setItemInfo(string name, string value) { _info[name ?? ""] = value ?? ""; Notify(WMPPlaylistChangeEventType.wmplcInfoChange); }
        public override void appendItem(IWMPMedia media)
        {
            var m = media as MediaItem;
            if (m == null) return;
            Items.Add(m);
            Notify(WMPPlaylistChangeEventType.wmplcAppend);
        }
        public override void insertItem(int index, IWMPMedia media)
        {
            var m = media as MediaItem;
            if (m == null) return;
            Items.Insert(Math.Max(0, Math.Min(index, Items.Count)), m);
            Notify(WMPPlaylistChangeEventType.wmplcInsert);
        }
        public override void removeItem(IWMPMedia media)
        {
            var m = media as MediaItem;
            if (m != null && Items.Remove(m)) Notify(WMPPlaylistChangeEventType.wmplcDelete);
        }
        public override void moveItem(int from, int to)
        {
            if (from < 0 || from >= Items.Count || to < 0 || to >= Items.Count) return;
            var m = Items[from];
            Items.RemoveAt(from);
            Items.Insert(to, m);
            Notify(WMPPlaylistChangeEventType.wmplcMove);
        }
        public override void clear()
        {
            Items.Clear();
            Notify(WMPPlaylistChangeEventType.wmplcClear);
        }
    }

    // The distinct values of one attribute among some items.
    public sealed class StringCollection : StringCollectionBase
    {
        public sealed class Group
        {
            public string Value;
            public readonly List<MediaItem> Items = new List<MediaItem>();
        }
        public readonly List<Group> Groups = new List<Group>();
        public readonly string Attribute;

        public StringCollection(string attribute) { Attribute = attribute ?? ""; }

        public override int get_count() { return Groups.Count; }
        public override string Item(int index) { return index >= 0 && index < Groups.Count ? Groups[index].Value : ""; }
        public override bool isIdentical(IWMPStringCollection2 other) { return ReferenceEquals(other, this); }
        public override string getItemInfo(int index, string name)
        {
            if (index < 0 || index >= Groups.Count) return "";
            var g = Groups[index];
            MediaItem.Asked("strings of " + Attribute, name);
            if (string.Equals(name, Attribute, StringComparison.OrdinalIgnoreCase)) return g.Value;
            if (string.Equals(name, "Count", StringComparison.OrdinalIgnoreCase)) return g.Items.Count.ToString(CultureInfo.InvariantCulture);
            if (string.Equals(name, "Duration", StringComparison.OrdinalIgnoreCase))
            {
                double total = 0;
                foreach (var i in g.Items) total += i.Seconds;
                return total.ToString(CultureInfo.InvariantCulture);
            }
            return g.Items.Count > 0 ? g.Items[0].Get(name) : "";
        }
        public override int getAttributeCountByType(int index, string type, string language)
        {
            if (index < 0 || index >= Groups.Count || Groups[index].Items.Count == 0) return 0;
            return Groups[index].Items[0].getAttributeCountByType(type, language);
        }
        public override object getItemInfoByType(int index, string type, string language, int attributeIndex)
        {
            if (index < 0 || index >= Groups.Count || Groups[index].Items.Count == 0) return null;
            MediaItem.Asked("strings of " + Attribute + " (typed)", type);
            if (string.Equals(type, "ChildList", StringComparison.OrdinalIgnoreCase)) return null;
            if (string.Equals(type, Attribute, StringComparison.OrdinalIgnoreCase) && Groups[index].Items[0].Typed(type) is string) return Groups[index].Value;
            return Groups[index].Items[0].getItemInfoByType(type, language, attributeIndex);
        }
    }

    public sealed class MediaCollection : MediaCollectionBase
    {
        static List<MediaItem> Select(Query query, string mediaType)
        {
            var result = new List<MediaItem>();
            foreach (var item in MediaLibrary.Items)
            {
                if (!string.IsNullOrEmpty(mediaType) && !string.Equals(item.Kind, mediaType, StringComparison.OrdinalIgnoreCase)) continue;
                if (query != null && !query.Matches(item)) continue;
                result.Add(item);
            }
            return result;
        }

        static Query Where(string attribute, string value)
        {
            var q = new Query();
            q.addCondition(attribute, "Equals", value);
            return q;
        }

        public override IWMPQuery createQuery() { return new Query(); }

        public override IWMPPlaylist getPlaylistByQuery(IWMPQuery query, string mediaType, string sortAttribute, bool ascending)
        {
            var items = Select(query as Query, mediaType);
            Sorting.Sort(items, sortAttribute, ascending);
            ComTodo.Log("wmpq", string.Format("playlist where {0} type {1} sort {2}: {3} items", query, mediaType, sortAttribute, items.Count));
            return new Playlist("", items);
        }

        public override IWMPStringCollection getStringCollectionByQuery(string attribute, IWMPQuery query, string mediaType, string sortAttribute, bool ascending)
        {
            var items = Select(query as Query, mediaType);
            Sorting.Sort(items, null, true);
            var collection = new StringCollection(attribute);
            var index = new Dictionary<string, StringCollection.Group>(StringComparer.CurrentCultureIgnoreCase);
            foreach (var item in items)
            {
                string value = item.Get(attribute);
                StringCollection.Group g;
                if (!index.TryGetValue(value, out g))
                {
                    index[value] = g = new StringCollection.Group { Value = value };
                    collection.Groups.Add(g);
                }
                g.Items.Add(item);
            }
            string by = string.IsNullOrEmpty(sortAttribute) ? attribute : sortAttribute;
            collection.Groups.Sort((p, q) =>
            {
                int c = Sorting.Compare(p.Items[0].Get(by), q.Items[0].Get(by));
                if (c == 0) c = Sorting.Compare(p.Value, q.Value);
                return ascending ? c : -c;
            });
            ComTodo.Log("wmpq", string.Format("strings of {0} where {1} type {2} sort {3}: {4} values", attribute, query, mediaType, sortAttribute, collection.Groups.Count));
            return collection;
        }

        public override IWMPPlaylist getAll() { return new Playlist("", MediaLibrary.Items); }
        public override IWMPPlaylist getByName(string name) { return getByAttribute("Name", name); }
        public override IWMPPlaylist getByGenre(string genre) { return getByAttribute("Genre", genre); }
        public override IWMPPlaylist getByAuthor(string author) { return getByAttribute("Artist", author); }
        public override IWMPPlaylist getByAlbum(string album) { return getByAttribute("Album", album); }
        public override IWMPPlaylist getByAttribute(string attribute, string value)
        {
            return getPlaylistByQuery(Where(attribute, value), null, null, true);
        }
        public override IWMPPlaylist getByAttributeAndMediaType(string attribute, string value, string mediaType)
        {
            return getPlaylistByQuery(Where(attribute, value), mediaType, null, true);
        }
        public override IWMPStringCollection getAttributeStringCollection(string attribute, string mediaType)
        {
            return getStringCollectionByQuery(attribute, null, mediaType, attribute, true);
        }
        public override IWMPMedia add(string url)
        {
            return MediaLibrary.Find(url) ?? MediaLibrary.Create(url);
        }
        public override void remove(IWMPMedia item, bool deleteFile)
        {
            // Taking a file out of the library (or deleting it) is not offered here.
            ComTodo.Hit("IWMPMediaCollection.remove");
        }
        public override bool isDeleted(IWMPMedia item) { return false; }
        public override int getMediaAtom(string name) { return 0; }
    }

    public sealed class Library : LibraryBase
    {
        readonly MediaCollection _collection;
        public Library(MediaCollection collection) { _collection = collection; }
        public override string get_name() { return Environment.MachineName; }
        public override WMPLibraryType get_type() { return WMPLibraryType.wmpltLocal; }
        public override IWMPMediaCollection get_mediaCollection() { return _collection; }
        public override bool isIdentical(IWMPLibrary other) { return ReferenceEquals(other, this); }
#if !VISTA
        public override string getItemInfo(string name) { return ""; }     // IWMPLibrary2 (not in Vista)
#endif
    }
}
