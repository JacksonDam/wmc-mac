// COM's component category manager (StdComponentCategoriesMgr), which XP
// Media Center Edition 2005 asks for the classes of a category: its
// text-entry input modules (then each one's language, from the registry).
// Answered from the registry's "Implemented Categories" keys, as Windows
// does; the classes there come from the servers' own registry scripts
// (tools/rgs.py). Without it the search fails, and every page with a text
// box waits for its result for ever.
#if XP
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using ServiceBus.UIFramework;

namespace WmcStandins
{
    public sealed class XpCategoryManager : ICatInformation
    {
        public static readonly Guid ClassId = new Guid("0002E005-0000-0000-C000-000000000046");

        const int E_NOTIMPL = unchecked((int)0x80004001);

        public object EnumClassesOfCategories(int cImplemented, ref Guid rgcatidImpl, int cRequired, Guid[] rgcatidReq)
        {
            var found = new List<Guid>();
            using (RegistryKey classes = Registry.ClassesRoot.OpenSubKey("CLSID"))
            {
                if (classes == null) return new ClassList(found);
                foreach (string name in classes.GetSubKeyNames())
                {
                    Guid clsid;
                    if (!Guid.TryParse(name, out clsid)) continue;
                    using (RegistryKey cats = classes.OpenSubKey(name + "\\Implemented Categories"))
                    {
                        if (cats == null) continue;
                        foreach (string cat in cats.GetSubKeyNames())
                        {
                            Guid id;
                            if (Guid.TryParse(cat, out id) && id == rgcatidImpl)
                            {
                                found.Add(clsid);
                                break;
                            }
                        }
                    }
                }
            }
            return new ClassList(found);
        }

        public object EnumCategories(int lcid) { throw new COMException("not here", E_NOTIMPL); }
        public char GetCategoryDesc(ref Guid rcatid, int lcid) { throw new COMException("not here", E_NOTIMPL); }
        public void IsClassOfCategories(ref Guid rclsid, int cImplemented, Guid[] rgcatidImpl, int cRequired, Guid[] rgcatidReq)
        {
            throw new COMException("not here", E_NOTIMPL);
        }
        public object EnumImplCategoriesOfClass(ref Guid rclsid) { throw new COMException("not here", E_NOTIMPL); }
        public object EnumReqCategoriesOfClass(ref Guid rclsid) { throw new COMException("not here", E_NOTIMPL); }

        sealed class ClassList : IEnumCLSID
        {
            readonly List<Guid> _ids;
            int _next;

            public ClassList(List<Guid> ids) { _ids = ids; }

            public int Next(int celt, out Guid rgelt, int[] pceltFetched)
            {
                bool any = _next < _ids.Count && celt > 0;
                rgelt = any ? _ids[_next++] : Guid.Empty;
                if (pceltFetched != null && pceltFetched.Length > 0) pceltFetched[0] = any ? 1 : 0;
                return any && celt == 1 ? 0 : 1;   // S_OK, or S_FALSE when fewer than asked for
            }

            public int Skip(int celt)
            {
                _next = Math.Min(_ids.Count, _next + Math.Max(0, celt));
                return _next < _ids.Count ? 0 : 1;
            }

            public void Reset() { _next = 0; }
            public void Clone(out Guid ppenum) { throw new COMException("not here", E_NOTIMPL); }
        }
    }
}
#endif
