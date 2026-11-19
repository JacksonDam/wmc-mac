// Vista's object store over the in-memory database (MemoryDatabase.cs), as
// MemoryStore.cs does for Windows 7's.
//
// Vista's store (mcstore.dll) has the same design with an older interface:
// no sessions or transactions, the store itself opens tables and runs
// statements, and a row cursor works with handles: CreateAccessor gives the
// handle of a layout, GetNextRow and InsertRow give a row handle (0: none),
// ReadRow returns a new buffer, and a row is found again by its bookmark
// (the 4-byte "Bookmark" binding of column 0, served as the row's serial
// number + 1).
#if VISTA
using System;
using System.Collections;
using System.Collections.Generic;
using MediaCenter.Store.OleDB;
using Microsoft.MediaCenter.Store;

namespace WmcStandins.Store
{
    sealed class VistaObjectStore : MediaCenter.Store.OleDB.ObjectStore
    {
        readonly MemDatabase db = new MemDatabase();
        string name = string.Empty;

        public override string StoreName { get { return name; } }

        // What the database driver's Open does around opening the file: the
        // store's own set-up before and after (after: "the database was just
        // created", which makes it create its tables and import its initial
        // data).
        public void OpenInMemory(string fileName)
        {
            name = fileName ?? string.Empty;
            ComTodo.Log("store", "opening an empty in-memory store for " + name);
            BeforeOpen(name);
            AfterOpen(true);
            ComTodo.Log("store", "store open");
        }

        public override Rowset OpenRowset(string tableName, string indexName, OleDBError error)
        {
            lock (db.Sync)
            {
                if (db.Table(tableName) == null)
                {
                    error.Error = MemErrors.NoTable;
                    return null;
                }
            }
            return new VistaRowset(db, new MemCursor(db, tableName, indexName, null));
        }

        public override Rowset OpenRowsetSql(string sql, string tableName, OleDBError error)
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
                if (db.Table(table) == null)
                {
                    error.Error = MemErrors.NoTable;
                    return null;
                }
            }
            ComTodo.Log("store", "query: " + sql);
            return new VistaRowset(db, new MemCursor(db, table, null, condition));
        }

        public override bool CreateTable(string tableName, DataFieldBindings bindings)
        {
            lock (db.Sync)
            {
                AddColumns(db.Create(tableName), bindings);
            }
            ComTodo.Log("store", "table " + tableName);
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

        // A table that lacks columns its type now has: they are added here and
        // then, and the open cursor stays good (false: nothing to reopen).
        public override bool AddMissingColumns(Rowset rowset, DataFieldBindings bindings)
        {
            lock (db.Sync)
            {
                MemTable table = db.Table(rowset.Name);
                if (table != null) AddColumns(table, bindings);
            }
            return false;
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

        // After a guide download the store removes what the download did not
        // bring again. Nothing is ever downloaded here.
        public override void SweepTable(string tableName, int generation) { }
        public override void SweepLinkTable(string sourceTableName, string linkTableName, int generation) { }
    }

    sealed class VistaRowset : Rowset
    {
        readonly MemDatabase db;
        readonly MemCursor cursor;
        readonly List<MemAccessor> accessors = new List<MemAccessor> { null };    // by handle; 0 is none
        readonly Dictionary<uint, MemRow> rows = new Dictionary<uint, MemRow>();  // row handles held
        uint lastRow;

        public VistaRowset(MemDatabase db, MemCursor cursor)
        {
            this.db = db;
            this.cursor = cursor;
        }

        public override string Name { get { return cursor.TableName; } }

        public override void Close()
        {
            cursor.Restart();
            rows.Clear();
        }

        public override void Update() { }

        // ---- accessors ------------------------------------------------------------------

        public override uint CreateAccessor(DbBinding[] bindings)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                if (t == null) return 0;
                accessors.Add(new MemAccessor(bindings, t, bookmarks: true));
                return (uint)(accessors.Count - 1);
            }
        }

        public override void ReleaseAccessor(uint accessorHandle) { }

        MemAccessor Accessor(uint handle)
        {
            return handle > 0 && handle < accessors.Count ? accessors[(int)handle] : null;
        }

        // A range or seek names the accessor its key is laid out by.
        void UseKey(uint handle)
        {
            MemAccessor key = Accessor(handle);
            if (key != null && cursor.Key != key) cursor.SetKey(key);
        }

        public override uint GetOrdinal(string columnName)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                int c = t == null ? -1 : t.Column(columnName);
                return c < 0 ? 0u : (uint)(c + 1);
            }
        }

        public override Hashtable GetOrdinals()
        {
            var result = new Hashtable(StringComparer.OrdinalIgnoreCase);
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                if (t != null)
                    for (int i = 0; i < t.Columns.Count; i++) result[t.Columns[i].Name] = (uint)(i + 1);
            }
            return result;
        }

        // ---- rows -----------------------------------------------------------------------

        uint Hold(MemRow row)
        {
            if (row == null) return 0;
            uint handle = ++lastRow;
            if (handle == 0) handle = ++lastRow;
            rows[handle] = row;
            return handle;
        }

        MemRow Row(uint handle)
        {
            MemRow row;
            return rows.TryGetValue(handle, out row) && !row.Deleted ? row : null;
        }

        public override void ReleaseRow(uint rowHandle)
        {
            rows.Remove(rowHandle);
        }

        public override bool SetRange(uint accessorKeyHandle, uint columnCountMin, byte[] keyMin, uint columnCountMax, byte[] keyMax, uint range)
        {
            lock (db.Sync)
            {
                UseKey(accessorKeyHandle);
                cursor.SetRange(columnCountMin, keyMin, columnCountMax, keyMax, range);
                return true;
            }
        }

        public override bool Seek(uint accessorKeyHandle, uint columnCount, byte[] key, uint seekType)
        {
            lock (db.Sync)
            {
                UseKey(accessorKeyHandle);
                return cursor.Seek(columnCount, key, seekType);
            }
        }

        public override void RestartPosition(uint r)
        {
            cursor.Restart();
        }

        public override uint GetNextRow()
        {
            lock (db.Sync)
            {
                return cursor.Next() ? Hold(cursor.Current) : 0;
            }
        }

        public override void PositionOnBookmark(uint bookmark)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                cursor.PositionOn(t == null || bookmark == 0 ? null : t.BySerial((long)bookmark - 1));
            }
        }

        public override byte[] ReadRow(uint rowHandle, uint accessorHandle, uint bufferSize)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                MemRow row = Row(rowHandle);
                MemAccessor data = Accessor(accessorHandle);
                if (t == null || row == null || data == null) return null;
                var buffer = new byte[bufferSize];
                for (int i = 0; i < data.Bindings.Length; i++)
                {
                    byte[] value = data.Columns[i] == MemAccessor.Bookmark
                        ? BitConverter.GetBytes((uint)(row.Serial + 1))
                        : t.Get(row, data.Columns[i]);
                    MemAccessor.Put(data.Bindings[i], buffer, value);
                }
                return buffer;
            }
        }

        public override uint InsertRow(uint accessorHandle, byte[] data)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                MemAccessor layout = Accessor(accessorHandle);
                if (t == null || layout == null) return 0;
                MemRow row = t.NewRow();
                Store(t, row, layout, data);
                return Hold(row);
            }
        }

        public override void SetData(uint rowHandle, uint accessorHandle, byte[] data)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                MemRow row = Row(rowHandle);
                MemAccessor layout = Accessor(accessorHandle);
                if (t == null || row == null || layout == null) return;
                Store(t, row, layout, data);
                t.Changed();
            }
        }

        static void Store(MemTable t, MemRow row, MemAccessor layout, byte[] data)
        {
            for (int i = 0; i < layout.Bindings.Length; i++)
                if (layout.Columns[i] != MemAccessor.Bookmark)
                    t.Set(row, layout.Columns[i], MemAccessor.Take(layout.Bindings[i], data));
        }

        public override void DeleteRow(uint rowHandle)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                MemRow row = Row(rowHandle);
                if (t != null && row != null) t.Delete(row);
            }
        }
    }
}
#endif
