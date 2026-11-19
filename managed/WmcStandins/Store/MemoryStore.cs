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
// Windows 7 only: Vista's object store has an older interface.
#if !VISTA

using System;
using System.Collections.Generic;
using System.Text;
using MediaCenter.Store.OleDB;
using Microsoft.MediaCenter.Store;
using StoredObjectsEnumerator = MediaCenter.Store.OleDB.StoredObjectsEnumerator;

namespace WmcStandins.Store
{
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

    sealed class MemRowset : Rowset
    {
        readonly MemSession session;
        readonly MemDatabase db;
        readonly MemCursor cursor;
        MemAccessor data;
        bool disposed;

        public MemRowset(MemSession session, MemDatabase db, string tableName, string indexName, MemCondition condition)
        {
            this.session = session;
            this.db = db;
            cursor = new MemCursor(db, tableName, indexName, condition);
        }

        public override Session Session { get { return session; } }
        public override bool IsDisposed { get { return disposed; } }
        public override string Name { get { return cursor.TableName; } }

        public override void Dispose()
        {
            disposed = true;
            cursor.Restart();
        }

        // ---- accessors ------------------------------------------------------------------

        public override void CreateDataAccessor(DbBinding[] bindings)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                if (t != null) data = new MemAccessor(bindings, t);
            }
        }

        public override void CreateKeyAccessor(DbBinding[] bindings)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                if (t != null) cursor.SetKey(new MemAccessor(bindings, t));
            }
        }

        public override uint GetOrdinal(string name)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                int c = t == null ? -1 : t.Column(name);
                return c < 0 ? 0u : (uint)(c + 1);
            }
        }

        public override Dictionary<string, uint> GetOrdinals()
        {
            var result = new Dictionary<string, uint>();
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                if (t != null)
                    for (int i = 0; i < t.Columns.Count; i++) result[t.Columns[i].Name.ToLowerInvariant()] = (uint)(i + 1);
            }
            return result;
        }

        // ---- keys, ranges and walking (MemCursor) ---------------------------------------

        public override void SetRange(uint columnCountMin, byte[] keyMin, uint columnCountMax, byte[] keyMax, uint range)
        {
            lock (db.Sync)
            {
                cursor.SetRange(columnCountMin, keyMin, columnCountMax, keyMax, range);
            }
        }

        public override void ClearRange()
        {
            cursor.ClearRange();
        }

        public override void RestartPosition(uint r)
        {
            NoteUse();
            cursor.Restart();
        }

        public override bool GetNextRow()
        {
            lock (db.Sync)
            {
                return cursor.Next();
            }
        }

        public override bool Seek(uint columnCount, byte[] keyBuffer, uint seekType)
        {
            NoteUse();
            lock (db.Sync)
            {
                return cursor.Seek(columnCount, keyBuffer, seekType);
            }
        }

        public override void ReleaseRow() { }

        public override bool ReadRow(byte[] buffer)
        {
            lock (db.Sync)
            {
                MemTable t = cursor.Table;
                MemRow row = cursor.Current;
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
                MemTable t = cursor.Table;
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
                MemTable t = cursor.Table;
                MemRow row = cursor.Current;
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
                MemTable t = cursor.Table;
                MemRow row = cursor.Current;
                if (t != null && row != null) t.Delete(row);
            }
        }

        public override void Dump(string prefix, StringBuilder result)
        {
            result.AppendFormat("{0}MemRowset {1} index={2}{3}\n", prefix, cursor.TableName, cursor.IndexName ?? "(none)",
                                cursor.Condition != null ? " (query)" : "");
        }
    }
}

#endif
