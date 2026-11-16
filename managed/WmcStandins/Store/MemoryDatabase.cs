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

namespace WmcStandins.Store
{
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
            Version++;
            return row;
        }

        public void Delete(MemRow row)
        {
            if (row == null || row.Deleted) return;
            row.Deleted = true;
            Rows.Remove(row);
            Version++;
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
