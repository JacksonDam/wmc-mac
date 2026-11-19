// The tables under the in-memory object store (MemoryStore.cs).
//
// Media Center's object store keeps its objects in database tables, one per
// stored type, and reaches them through OLE DB-style row cursors: rows go in
// and out as byte buffers laid out by "accessors" (a list of column name,
// type, offset in the buffer, size). Here a table keeps, for each row, the
// value of each column as the bytes that column holds in a buffer, so the
// layout of any accessor can be served from it.
//
// Value bytes by column type (OLE DB type numbers):
//   2 short, 3 int, 5 double, 11 bool (a 16-bit 0 / -1), 17 byte, 20 long
//   (also dates and object ids), 72 GUID, 13 a blob handle (StoreCompat.cs):
//   their fixed size.
//   130 a string (UTF-16, no terminator; compared ignoring case, as the
//   original database did), 128 bytes (also case-sensitive strings and
//   arrays; compared byte by byte): as long as the value.
using System;
using System.Collections.Generic;
using System.Text;
using MediaCenter.Store.OleDB;

namespace WmcStandins.Store
{
    // OLE DB error codes the store reacts to.
    static class MemErrors
    {
        public const int NoTable = -2147217865;    // DB_E_NOTABLE: the store creates the table and tries again
    }

    sealed class MemColumn
    {
        public readonly string Name;
        public readonly short Type;

        public MemColumn(string name, short type)
        {
            Name = name;
            Type = type;
        }
    }

    sealed class MemRow
    {
        public byte[][] Values;
        public long Serial;      // insertion order, the order of rows that sort equal
        public bool Deleted;
    }

    sealed class MemTable
    {
        public readonly string Name;
        public readonly List<MemColumn> Columns = new List<MemColumn>();
        public readonly List<MemRow> Rows = new List<MemRow>();
        // Index name -> its columns, most significant first.
        public readonly Dictionary<string, string[]> Indexes = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        // Changes whenever a row is added, changed or removed: sorted views are kept until then.
        public int Version;

        readonly Dictionary<string, int> columnIndex = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, KeyValuePair<int, MemRow[]>> sorted = new Dictionary<string, KeyValuePair<int, MemRow[]>>(StringComparer.OrdinalIgnoreCase);
        long nextSerial;

        public MemTable(string name)
        {
            Name = name;
        }

        public int Column(string name)
        {
            int i;
            return name != null && columnIndex.TryGetValue(name, out i) ? i : -1;
        }

        public int AddColumn(string name, short type)
        {
            int i = Column(name);
            if (i >= 0) return i;
            Columns.Add(new MemColumn(name, type));
            columnIndex[name] = Columns.Count - 1;
            return Columns.Count - 1;
        }

        public MemRow NewRow()
        {
            var row = new MemRow { Values = new byte[Columns.Count][], Serial = nextSerial++ };
            Rows.Add(row);
            bySerial[row.Serial] = row;
            Version++;
            return row;
        }

        public void Delete(MemRow row)
        {
            if (row == null || row.Deleted) return;
            row.Deleted = true;
            Rows.Remove(row);
            bySerial.Remove(row.Serial);
            Version++;
        }

        readonly Dictionary<long, MemRow> bySerial = new Dictionary<long, MemRow>();

        public MemRow BySerial(long serial)
        {
            MemRow row;
            return bySerial.TryGetValue(serial, out row) ? row : null;
        }

        public byte[] Get(MemRow row, int column)
        {
            return column >= 0 && column < row.Values.Length ? row.Values[column] : null;
        }

        public void Set(MemRow row, int column, byte[] value)
        {
            if (column < 0) return;
            if (column >= row.Values.Length) Array.Resize(ref row.Values, Columns.Count);
            row.Values[column] = value;
        }

        public void Changed()
        {
            Version++;
        }

        // The rows in an index's order (rows that sort equal, and every row
        // when there is no such index, in the order they were added).
        public MemRow[] Ordered(string index)
        {
            string[] names;
            if (index == null || !Indexes.TryGetValue(index, out names)) return Rows.ToArray();
            KeyValuePair<int, MemRow[]> cached;
            if (sorted.TryGetValue(index, out cached) && cached.Key == Version) return cached.Value;
            var columns = new int[names.Length];
            for (int i = 0; i < names.Length; i++) columns[i] = Column(names[i]);
            var rows = Rows.ToArray();
            Array.Sort(rows, (a, b) =>
            {
                for (int i = 0; i < columns.Length; i++)
                {
                    if (columns[i] < 0) continue;
                    int c = MemValue.Compare(Columns[columns[i]].Type, Get(a, columns[i]), Get(b, columns[i]));
                    if (c != 0) return c;
                }
                return a.Serial.CompareTo(b.Serial);
            });
            sorted[index] = new KeyValuePair<int, MemRow[]>(Version, rows);
            return rows;
        }
    }

    // An accessor: where each column's value sits in a row buffer.
    sealed class MemAccessor
    {
        public readonly DbBinding[] Bindings;   // in key order for a key accessor
        public readonly int[] Columns;          // the table column of each binding, or Bookmark
        // With `bookmarks` (Vista's store), the binding of column 0 named
        // "Bookmark" is the row's bookmark, which the store reads to find the
        // row again: served as Serial + 1, never stored.
        public const int Bookmark = -2;

        public MemAccessor(DbBinding[] bindings, MemTable table, bool bookmarks = false)
        {
            var list = new List<DbBinding>();
            foreach (DbBinding b in bindings)
                if (b != null) list.Add(b);
            Bindings = list.ToArray();
            Columns = new int[Bindings.Length];
            for (int i = 0; i < Bindings.Length; i++)
            {
                DbBinding b = Bindings[i];
                Columns[i] = bookmarks && b.iOrdinal == 0 && b.Name == "Bookmark" ? Bookmark : table.AddColumn(b.Name, b.wType);
            }
        }

        static bool HasLength(DbBinding b)
        {
            return (b.dwPart & 2) != 0;
        }


        // The value of binding b in a buffer, as the bytes the table keeps.
        public static byte[] Take(DbBinding b, byte[] buffer)
        {
            int at = (int)b.obValue, max = (int)b.cbMaxLen;
            if (at >= buffer.Length) return null;
            if (at + max > buffer.Length) max = buffer.Length - at;
            int length;
            if (HasLength(b) && b.obLength + 4 <= buffer.Length)
            {
                // The length (DBLENGTH) is 4 bytes in Media Center's store.
                length = (int)BitConverter.ToUInt32(buffer, (int)b.obLength);
                if (length > max) length = max;
            }
            else if (MemValue.IsText(b.wType))
            {
                // a key holds a string up to its terminating zero character
                length = 0;
                while (length + 1 < max && (buffer[at + length] | buffer[at + length + 1]) != 0) length += 2;
            }
            else
            {
                length = max;
            }
            var value = new byte[length];
            Buffer.BlockCopy(buffer, at, value, 0, length);
            return value;
        }

        // Puts a value into a buffer where binding b says.
        public static void Put(DbBinding b, byte[] buffer, byte[] value)
        {
            int at = (int)b.obValue, max = (int)b.cbMaxLen;
            if (at >= buffer.Length) return;
            if (at + max > buffer.Length) max = buffer.Length - at;
            Array.Clear(buffer, at, max);
            int n = value == null ? 0 : Math.Min(value.Length, max);
            if (n > 0) Buffer.BlockCopy(value, 0, buffer, at, n);
            if (HasLength(b) && b.obLength + 4 <= buffer.Length)
                Buffer.BlockCopy(BitConverter.GetBytes((uint)n), 0, buffer, (int)b.obLength, 4);
        }
    }

    // A row cursor over one table, which both stores' rowsets walk with: in
    // an index's order or filtered by a query's condition, limited to a key
    // range, put in place by Seek and stepped by Next. Callers hold the
    // database's lock.
    sealed class MemCursor
    {
        readonly MemDatabase db;
        public readonly string TableName, IndexName;
        public readonly MemCondition Condition;
        MemAccessor key;

        // The range the cursor is limited to (SetRange), as key values.
        byte[][] rangeMin, rangeMax;
        uint rangeType;

        MemRow[] view;      // the rows the cursor walks, worked out at the start of each walk
        int position = -1;

        public MemCursor(MemDatabase db, string tableName, string indexName, MemCondition condition)
        {
            this.db = db;
            TableName = tableName;
            IndexName = indexName;
            Condition = condition;
        }

        public MemTable Table { get { return db.Table(TableName); } }
        public MemAccessor Key { get { return key; } }

        public MemRow Current
        {
            get { return view != null && position >= 0 && position < view.Length && !view[position].Deleted ? view[position] : null; }
        }

        // The accessor keys are given in. An index the table does not have
        // yet is the key's columns in order.
        public void SetKey(MemAccessor accessor)
        {
            key = accessor;
            MemTable t = Table;
            if (t != null && IndexName != null && !t.Indexes.ContainsKey(IndexName))
            {
                var names = new string[key.Bindings.Length];
                for (int i = 0; i < names.Length; i++) names[i] = key.Bindings[i].Name;
                t.Indexes[IndexName] = names;
            }
        }

        byte[][] KeyValues(byte[] buffer, uint count)
        {
            if (key == null) return new byte[0][];
            int n = (int)Math.Min(count, (uint)key.Bindings.Length);
            var values = new byte[n][];
            for (int i = 0; i < n; i++) values[i] = MemAccessor.Take(key.Bindings[i], buffer);
            return values;
        }

        // How a row compares with a key on the key's columns. With `prefix`,
        // a text column only has to begin with the key's text.
        int CompareKey(MemTable t, MemRow row, byte[][] values, bool prefix)
        {
            for (int i = 0; i < values.Length; i++)
            {
                int column = key.Columns[i];
                if (column < 0) continue;
                short type = t.Columns[column].Type;
                byte[] v = t.Get(row, column);
                if (prefix && i == values.Length - 1 && MemValue.IsText(type) && v != null && values[i] != null && v.Length > values[i].Length)
                {
                    var head = new byte[values[i].Length];
                    Buffer.BlockCopy(v, 0, head, 0, head.Length);
                    v = head;
                }
                int c = MemValue.Compare(type, v, values[i]);
                if (c != 0) return c;
            }
            return 0;
        }

        bool InRange(MemTable t, MemRow row)
        {
            if (rangeMin == null || key == null) return true;
            bool prefix = (rangeType & 8) != 0;
            int c = CompareKey(t, row, rangeMin, prefix);
            if ((rangeType & 16) != 0) return c == 0;                  // Match: equal to the first key
            if (c < 0 || (c == 0 && (rangeType & 1) != 0)) return false;  // before the start
            if (rangeMax != null)
            {
                int d = CompareKey(t, row, rangeMax, prefix);
                if (d > 0 || (d == 0 && (rangeType & 2) != 0)) return false;
            }
            return true;
        }

        public void SetRange(uint columnCountMin, byte[] keyMin, uint columnCountMax, byte[] keyMax, uint range)
        {
            rangeMin = KeyValues(keyMin, columnCountMin);
            rangeMax = keyMax != null ? KeyValues(keyMax, columnCountMax) : null;
            rangeType = range;
            Restart();
        }

        public void ClearRange()
        {
            rangeMin = rangeMax = null;
            Restart();
        }

        MemRow[] BuildView()
        {
            MemTable t = Table;
            if (t == null) return new MemRow[0];
            var rows = new List<MemRow>();
            foreach (MemRow row in t.Ordered(IndexName))
            {
                if (!InRange(t, row)) continue;
                if (Condition != null && !Condition.Test(t, row)) continue;
                rows.Add(row);
            }
            return rows.ToArray();
        }

        public void Restart()
        {
            view = null;
            position = -1;
        }

        public bool Next()
        {
            if (view == null)
            {
                view = BuildView();
                position = -1;
            }
            do position++;
            while (position < view.Length && view[position].Deleted);
            return position < view.Length;
        }

        public bool Seek(uint columnCount, byte[] keyBuffer, uint seekType)
        {
            MemTable t = Table;
            view = BuildView();
            position = view.Length;
            if (t == null || key == null) return false;
            byte[][] values = KeyValues(keyBuffer, columnCount);
            int found = -1;
            switch (seekType)
            {
                case 1:   // the first row equal to the key
                    for (int i = 0; i < view.Length && found < 0; i++) if (CompareKey(t, view[i], values, false) == 0) found = i;
                    break;
                case 2:   // the last row equal to the key
                    for (int i = view.Length - 1; i >= 0 && found < 0; i--) if (CompareKey(t, view[i], values, false) == 0) found = i;
                    break;
                case 4:   // the first row at or after the key
                    for (int i = 0; i < view.Length && found < 0; i++) if (CompareKey(t, view[i], values, false) >= 0) found = i;
                    break;
                case 8:   // the first row after the key
                    for (int i = 0; i < view.Length && found < 0; i++) if (CompareKey(t, view[i], values, false) > 0) found = i;
                    break;
                case 16:  // the last row at or before the key
                    for (int i = view.Length - 1; i >= 0 && found < 0; i--) if (CompareKey(t, view[i], values, false) <= 0) found = i;
                    break;
                case 32:  // the last row before the key
                    for (int i = view.Length - 1; i >= 0 && found < 0; i--) if (CompareKey(t, view[i], values, false) < 0) found = i;
                    break;
            }
            if (found < 0) return false;
            position = found - 1;     // the next Next lands on it
            return true;
        }

        // Just before a given row (Vista's PositionOnBookmark), in the walk if
        // it is in it, else on its own.
        public void PositionOn(MemRow row)
        {
            view = BuildView();
            int at = row == null ? -1 : Array.IndexOf(view, row);
            if (at < 0)
            {
                view = row == null ? new MemRow[0] : new[] { row };
                at = 0;
            }
            position = at - 1;
        }
    }

    sealed class MemDatabase
    {
        public readonly object Sync = new object();
        readonly Dictionary<string, MemTable> tables = new Dictionary<string, MemTable>(StringComparer.OrdinalIgnoreCase);

        public MemTable Table(string name)
        {
            MemTable t;
            return name != null && tables.TryGetValue(name, out t) ? t : null;
        }

        public MemTable Create(string name)
        {
            MemTable t = Table(name);
            if (t == null) tables[name] = t = new MemTable(name);
            return t;
        }

        public void Drop(string name)
        {
            if (name != null) tables.Remove(name);
        }
    }

    static class MemValue
    {
        public static bool IsText(short type)
        {
            return type == 130 || type == 128;
        }

        public static int Compare(short type, byte[] a, byte[] b)
        {
            if (a == null || a.Length == 0) return b == null || b.Length == 0 ? 0 : -1;
            if (b == null || b.Length == 0) return 1;
            switch (type)
            {
                case 2:
                case 11:
                    if (a.Length >= 2 && b.Length >= 2) return BitConverter.ToInt16(a, 0).CompareTo(BitConverter.ToInt16(b, 0));
                    break;
                case 3:
                    if (a.Length >= 4 && b.Length >= 4) return BitConverter.ToInt32(a, 0).CompareTo(BitConverter.ToInt32(b, 0));
                    break;
                case 20:
                    if (a.Length >= 8 && b.Length >= 8) return BitConverter.ToInt64(a, 0).CompareTo(BitConverter.ToInt64(b, 0));
                    break;
                case 5:
                    if (a.Length >= 8 && b.Length >= 8) return BitConverter.ToDouble(a, 0).CompareTo(BitConverter.ToDouble(b, 0));
                    break;
                case 130:
                    return string.Compare(Text(a), Text(b), StringComparison.OrdinalIgnoreCase);
            }
            int n = Math.Min(a.Length, b.Length);
            for (int i = 0; i < n; i++)
                if (a[i] != b[i]) return a[i].CompareTo(b[i]);
            return a.Length.CompareTo(b.Length);
        }

        public static string Text(byte[] v)
        {
            return v == null ? null : Encoding.Unicode.GetString(v, 0, v.Length & ~1);
        }

        // A value as a .NET object, for comparing with a literal in a query.
        public static object ToObject(short type, byte[] v)
        {
            if (v == null) return null;
            switch (type)
            {
                case 2: return v.Length >= 2 ? (long)BitConverter.ToInt16(v, 0) : 0L;
                case 3: return v.Length >= 4 ? (long)BitConverter.ToInt32(v, 0) : 0L;
                case 20: return v.Length >= 8 ? BitConverter.ToInt64(v, 0) : 0L;
                case 17: return v.Length >= 1 ? (long)v[0] : 0L;
                case 11: return v.Length >= 2 && BitConverter.ToInt16(v, 0) != 0;
                case 5: return v.Length >= 8 ? BitConverter.ToDouble(v, 0) : 0.0;
                case 72: return v.Length >= 16 ? new Guid(v) : Guid.Empty;
                case 130:
                case 128: return Text(v);
            }
            return v;
        }
    }
}
