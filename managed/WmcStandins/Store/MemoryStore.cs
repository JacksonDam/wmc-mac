// Media Center's object store over an in-memory database.
//
// The object store (mcstore.dll) keeps the guide, recordings, tuner set-up
// and much else as objects in a database. It is plain .NET down to four
// abstract classes - a store that hands out sessions, a session that opens
// tables, a row cursor ("rowset") and a transaction - which a C++/CLI
// assembly (mcstoredb.dll) implements over SQL Server Compact through OLE
// DB. That half cannot run here. These classes implement the same four over
// MemoryDatabase.cs, so the store itself (types, ids, caching, keys, events)
// runs unchanged on top. The database starts empty with every run and is
// never written to disk: pages that need the store open and show what an
// empty store holds (no recordings, no guide).
//
// What the store asks of a row cursor (the OLE DB IRowsetIndex model):
//   - it is opened on a table, either in the order of one of the table's
//     indexes or (for a text query) filtered by a condition;
//   - a range may limit it to rows whose index columns lie between two keys;
//   - Seek puts it just before the first (or last) row matching a key, and
//     GetNextRow steps to the next row, which ReadRow copies out;
//   - rows go in and out as byte buffers laid out by the accessors the store
//     gives it (MemAccessor).
using System;
using System.Collections.Generic;
using System.Text;
using MediaCenter.Store.OleDB;
using Microsoft.MediaCenter.Store;
using StoredObjectsEnumerator = MediaCenter.Store.OleDB.StoredObjectsEnumerator;

namespace WmcStandins.Store
{
    // OLE DB error codes the store reacts to.
    static class MemErrors
    {
        public const int NoTable = -2147217865;    // DB_E_NOTABLE: the store creates the table and tries again
    }

    sealed class MemObjectStore : MediaCenter.Store.OleDB.ObjectStore
    {
        readonly MemDatabase db = new MemDatabase();
        string name = string.Empty;

        public override string StoreName { get { return name; } }

        public override Session CreateSession()
        {
            return new MemSession(db);
        }

        // What the database driver's Open does around opening the file: the
        // store's own set-up before and after (after: "the database was just
        // created", which makes it create its own tables and import its
        // initial data).
        public void OpenInMemory(string fileName)
        {
            name = fileName ?? string.Empty;
            ComTodo.Log("store", "opening an empty in-memory store for " + name);
            BeforeOpen(name);
            AfterOpen(true);
            ComTodo.Log("store", "store open");
        }
    }

    sealed class MemTransaction : Transaction
    {
        // Changes take effect at once; there is nothing to commit or undo.
        public override void Commit() { }
        public override void Abort() { }
        public override void Dispose() { }
    }

    sealed class MemSession : Session
    {
        readonly MemDatabase db;

        public MemSession(MemDatabase db)
        {
            this.db = db;
        }

        public override void Close() { }

        public override Rowset OpenRowset(StoredObjectsEnumerator enumerator, string tableName, string indexName, OleDBError error)
        {
            lock (db.Sync)
            {
                if (db.Table(tableName) == null)
                {
                    error.Error = MemErrors.NoTable;
                    error.Message = "no table " + tableName;
                    return null;
                }
            }
            var rowset = new MemRowset(this, db, tableName, indexName, null);
            rowset.Claim(enumerator);
            return rowset;
        }

        public override Rowset OpenRowsetSql(StoredObjectsEnumerator enumerator, string sql, string tableName)
        {
            string table;
            MemCondition condition;
            if (!MemSql.ParseSelect(sql, out table, out condition))
            {
                // (an empty result, not a missing table: the store would create the table and ask again, forever)
                condition = new MemCondition { Test = (t, r) => false };
                table = tableName;
            }
            lock (db.Sync)
            {
                if (db.Table(table) == null) return null;
            }
            ComTodo.Log("store", "query: " + sql);
            var rowset = new MemRowset(this, db, table, null, condition);
            rowset.Claim(enumerator);
            return rowset;
        }

        public override bool CreateTable(string name, DataFieldBindings bindings)
        {
            lock (db.Sync)
            {
                MemTable table = db.Create(name);
                AddColumns(table, bindings);
            }
            ComTodo.Log("store", "table " + name);
            return true;
        }

        static void AddColumns(MemTable table, FieldBindings bindings)
        {
            foreach (FieldBinding fb in bindings)
            {
                var binding = fb as OleDbFieldBinding;
                if (binding == null || binding.DBType == 1 || string.IsNullOrEmpty(binding.StoredName)) continue;
                table.AddColumn(binding.StoredName, binding.DBType);
            }
        }

        public override bool CreateIndex(string tableName, string indexName, FieldBindings bindings)
        {
            var ordered = new SortedDictionary<int, string>();
            foreach (FieldBinding fb in bindings)
                ordered[fb.Order] = fb.StoredName;
            lock (db.Sync)
            {
                MemTable table = db.Create(tableName);
                if (!table.Indexes.ContainsKey(indexName)) table.Indexes[indexName] = new List<string>(ordered.Values).ToArray();
            }
            return true;
        }

        // Called when a table lacks columns its type now has. The columns are
        // added here and then, so there is no statement to run.
        public override string CreateAlterTableSql(Rowset rowset, DataFieldBindings bindings)
        {
            lock (db.Sync)
            {
                MemTable table = db.Table(rowset.Name);
                if (table != null) AddColumns(table, bindings);
            }
            return string.Empty;
        }

        public override void ExecuteSql(string sql)
        {
            lock (db.Sync)
            {
                MemSql.Execute(db, sql);
            }
        }

        public override Transaction BeginTransaction()
        {
            return new MemTransaction();
        }

        public override void DropTable(string tableName)
        {
            lock (db.Sync)
            {
                db.Drop(tableName);
            }
        }

        public override void DeleteObjectsFromTable(string tableName, string columnName, string objectIds)
        {
            ExecuteSql("delete from " + tableName + " where " + columnName + " in (" + objectIds + ")");
        }

        public override void DeleteFromCollectionInfoTable(int statusCode, long minGroupId, long maxGroupId)
        {
            ExecuteSql("delete from collectionInfo where status = " + statusCode + " and groupId between " + minGroupId + " and " + maxGroupId);
        }

        public override void DeleteCollectionInfoTable()
        {
            DropTable("collectionInfo");
        }
    }

    // An accessor: where each column's value sits in a row buffer.
    sealed class MemAccessor
    {
        public readonly DbBinding[] Bindings;   // in key order for a key accessor
        public readonly int[] Columns;          // the table column of each binding

        public MemAccessor(DbBinding[] bindings, MemTable table)
        {
            var list = new List<DbBinding>();
            foreach (DbBinding b in bindings)
                if (b != null) list.Add(b);
            Bindings = list.ToArray();
            Columns = new int[Bindings.Length];
            for (int i = 0; i < Bindings.Length; i++)
                Columns[i] = table.AddColumn(Bindings[i].Name, Bindings[i].wType);
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

    sealed class MemRowset : Rowset
    {
        readonly MemSession session;
        readonly MemDatabase db;
        readonly string tableName;
        readonly string indexName;
        readonly MemCondition condition;
        MemAccessor data, key;
        bool disposed;

        // The range the cursor is limited to (SetRange), as key values.
        byte[][] rangeMin, rangeMax;
        uint rangeType;

        MemRow[] view;      // the rows the cursor walks, worked out at the start of each walk
        int position = -1;

        public MemRowset(MemSession session, MemDatabase db, string tableName, string indexName, MemCondition condition)
        {
            this.session = session;
            this.db = db;
            this.tableName = tableName;
            this.indexName = indexName;
            this.condition = condition;
        }

        public override Session Session { get { return session; } }
        public override bool IsDisposed { get { return disposed; } }
        public override string Name { get { return tableName; } }

        public override void Dispose()
        {
            disposed = true;
            view = null;
        }

        MemTable Table { get { return db.Table(tableName); } }

        MemRow Current
        {
            get { return view != null && position >= 0 && position < view.Length && !view[position].Deleted ? view[position] : null; }
        }

        // ---- accessors ------------------------------------------------------------------

        public override void CreateDataAccessor(DbBinding[] bindings)
        {
            lock (db.Sync)
            {
                MemTable t = Table;
                if (t != null) data = new MemAccessor(bindings, t);
            }
        }

        public override void CreateKeyAccessor(DbBinding[] bindings)
        {
            lock (db.Sync)
            {
                MemTable t = Table;
                if (t == null) return;
                key = new MemAccessor(bindings, t);
                // An index the table does not have yet is the key's columns in order.
                if (indexName != null && !t.Indexes.ContainsKey(indexName))
                {
                    var names = new string[key.Bindings.Length];
                    for (int i = 0; i < names.Length; i++) names[i] = key.Bindings[i].Name;
                    t.Indexes[indexName] = names;
                }
            }
        }

        public override uint GetOrdinal(string name)
        {
            lock (db.Sync)
            {
                MemTable t = Table;
                int c = t == null ? -1 : t.Column(name);
                return c < 0 ? 0u : (uint)(c + 1);
            }
        }

        public override Dictionary<string, uint> GetOrdinals()
        {
            var result = new Dictionary<string, uint>();
            lock (db.Sync)
            {
                MemTable t = Table;
                if (t != null)
                    for (int i = 0; i < t.Columns.Count; i++) result[t.Columns[i].Name.ToLowerInvariant()] = (uint)(i + 1);
            }
            return result;
        }

        // ---- keys and ranges ------------------------------------------------------------

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

        public override void SetRange(uint columnCountMin, byte[] keyMin, uint columnCountMax, byte[] keyMax, uint range)
        {
            lock (db.Sync)
            {
                rangeMin = KeyValues(keyMin, columnCountMin);
                rangeMax = keyMax != null ? KeyValues(keyMax, columnCountMax) : null;
                rangeType = range;
                view = null;
                position = -1;
            }
        }

        public override void ClearRange()
        {
            rangeMin = rangeMax = null;
            view = null;
            position = -1;
        }

        MemRow[] BuildView()
        {
            MemTable t = Table;
            if (t == null) return new MemRow[0];
            var rows = new List<MemRow>();
            foreach (MemRow row in t.Ordered(indexName))
            {
                if (!InRange(t, row)) continue;
                if (condition != null && !condition.Test(t, row)) continue;
                rows.Add(row);
            }
            return rows.ToArray();
        }

        // ---- walking --------------------------------------------------------------------

        public override void RestartPosition(uint r)
        {
            NoteUse();
            view = null;
            position = -1;
        }

        public override bool GetNextRow()
        {
            lock (db.Sync)
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
        }

        public override bool Seek(uint columnCount, byte[] keyBuffer, uint seekType)
        {
            NoteUse();
            lock (db.Sync)
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
                position = found - 1;     // the next GetNextRow lands on it
                return true;
            }
        }

        public override void ReleaseRow() { }

        public override bool ReadRow(byte[] buffer)
        {
            lock (db.Sync)
            {
                MemTable t = Table;
                MemRow row = Current;
                if (t == null || row == null || data == null) return false;
                for (int i = 0; i < data.Bindings.Length; i++)
                    MemAccessor.Put(data.Bindings[i], buffer, t.Get(row, data.Columns[i]));
                return true;
            }
        }

        public override bool InsertRow(byte[] buffer)
        {
            NoteUse();
            lock (db.Sync)
            {
                MemTable t = Table;
                if (t == null || data == null) return false;
                MemRow row = t.NewRow();
                for (int i = 0; i < data.Bindings.Length; i++)
                    t.Set(row, data.Columns[i], MemAccessor.Take(data.Bindings[i], buffer));
                return true;
            }
        }

        public override void SetData(byte[] buffer)
        {
            lock (db.Sync)
            {
                MemTable t = Table;
                MemRow row = Current;
                if (t == null || row == null || data == null) return;
                for (int i = 0; i < data.Bindings.Length; i++)
                    t.Set(row, data.Columns[i], MemAccessor.Take(data.Bindings[i], buffer));
                t.Changed();
            }
        }

        public override void DeleteRow()
        {
            lock (db.Sync)
            {
                MemTable t = Table;
                MemRow row = Current;
                if (t != null && row != null) t.Delete(row);
            }
        }

        public override void Dump(string prefix, StringBuilder result)
        {
            result.AppendFormat("{0}MemRowset {1} index={2}{3}\n", prefix, tableName, indexName ?? "(none)", condition != null ? " (query)" : "");
        }
    }
}
