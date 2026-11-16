// Entry points from Media Center's object store into the in-memory database
// (see managed/redirects.txt, "The object store").
using System;
using System.Collections.Generic;

namespace WmcStandins
{
    public static partial class Compat
    {
        // MediaCenter.Store.SqlLite.ObjectStoreOpener.Open: the store opens
        // its database through here.
        public static MediaCenter.Store.OleDB.ObjectStore Store_Open(string fileName, bool isCollecting)
        {
            var store = new Store.MemObjectStore();
            store.IsCollecting = isCollecting;
            store.OpenInMemory(fileName);
            return store;
        }

        // The store guards its files against other processes with named
        // mutexes ("Global\\MCStore..."). There are no other processes here:
        // a mutex of its own each time does the job, without asking Mono for
        // system-wide names.
        public static System.Threading.Mutex Store_NewMutex(string baseName, string fileName)
        {
            return new System.Threading.Mutex(false);
        }

        public static System.Threading.Mutex Store_NewMutex(Microsoft.MediaCenter.Store.ObjectStore store, string baseName)
        {
            return new System.Threading.Mutex(false);
        }

        // While the store must not pump window messages it waits through
        // its own synchronization context, which asks Windows to wait on the
        // handles directly (WaitForMultipleObjects). The handles are Mono's,
        // so the wait goes back to the runtime's own waiting.
        public static unsafe int Store_WaitForMultipleObjects(int count, IntPtr* handles, bool waitAll, int milliseconds)
        {
            var list = new IntPtr[count];
            for (int i = 0; i < count; i++) list[i] = handles[i];
            return RuntimeWait.Wait(list, waitAll, milliseconds);
        }

        sealed class RuntimeWait : System.Threading.SynchronizationContext
        {
            public static new int Wait(IntPtr[] handles, bool waitAll, int milliseconds)
            {
                return WaitHelper(handles, waitAll, milliseconds);
            }
        }

        // The store makes a constructor for each stored type as a small
        // compiled method. Mono compiles it at once and refuses one for an
        // abstract type (Windows only fails if it is ever called, and it never
        // is): an abstract type gets none.
        public static Microsoft.MediaCenter.Store.ObjectType.Constructor Store_CompileConstructor(Microsoft.MediaCenter.Store.ObjectType objectType)
        {
            Type type = objectType.Type;
            if (type == null || type.IsAbstract) return null;
            var ctor = type.GetConstructor(System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic, null, Type.EmptyTypes, null);
            if (ctor == null) return null;
            var method = new System.Reflection.Emit.DynamicMethod("Constructor", typeof(object), Type.EmptyTypes, type);
            var il = method.GetILGenerator();
            il.Emit(System.Reflection.Emit.OpCodes.Newobj, ctor);
            il.Emit(System.Reflection.Emit.OpCodes.Ret);
            return (Microsoft.MediaCenter.Store.ObjectType.Constructor)method.CreateDelegate(typeof(Microsoft.MediaCenter.Store.ObjectType.Constructor));
        }

        // A session with the recording service (ehrecvr on Windows) tries
        // each call five times, half a second apart, while the page that asked
        // waits. There is no recording service here, so one try is enough.
        public static void PvrSession_Init(Microsoft.MediaCenter.Pvr.PvrServiceSession session)
        {
            OneTry(session);
        }

        public static void PvrSession_Init(Microsoft.MediaCenter.Pvr.PvrServiceSession session, int retryAttempts, TimeSpan retryDelay)
        {
            OneTry(session);
        }

        static void OneTry(object session)
        {
            const System.Reflection.BindingFlags fields = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public;
            Type t = session.GetType();
            t.GetField("_retryAttempts", fields).SetValue(session, 1);
            t.GetField("_retryDelay", fields).SetValue(session, TimeSpan.Zero);
        }

        // Not in Mono: the last Win32 error as an HRESULT.
        public static int Marshal_GetHRForLastWin32Error()
        {
            int e = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
            return e == 0 ? 0 : unchecked((int)(0x80070000u | (uint)(e & 0xFFFF)));
        }

        // Large values ("blobs") travel in a row buffer as a pointer to a
        // stream the database hands out. Here the buffer holds a number that
        // names the bytes in this table instead. Entries are never removed:
        // a row keeps the number, and the store is gone when Media Center
        // quits.
        static readonly Dictionary<long, byte[]> s_blobs = new Dictionary<long, byte[]>();
        static long s_nextBlob = 1;

        public static unsafe byte[] Blob_Load(byte* pb)
        {
            long id = *(long*)pb;
            lock (s_blobs)
            {
                byte[] bytes;
                return id != 0 && s_blobs.TryGetValue(id, out bytes) ? bytes : null;
            }
        }

        public static unsafe void Blob_Store(byte* pb, byte[] bytes)
        {
            long id = 0;
            if (bytes != null && bytes.Length > 0)
            {
                lock (s_blobs)
                {
                    id = s_nextBlob++;
                    s_blobs[id] = (byte[])bytes.Clone();
                }
            }
            *(long*)pb = id;
        }

        public static unsafe void Blob_Release(byte* pb)
        {
        }
    }
}
