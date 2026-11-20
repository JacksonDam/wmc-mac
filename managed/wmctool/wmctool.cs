// wmctool: build-time helper that reads the .NET assemblies of an unpacked
// Media Center installer. It only ever reads metadata (names, signatures,
// layouts); nothing from those assemblies is copied into this repository.
//
//   wmctool pinvokes  <ehome dir> <out.tsv>      every native call the code makes
//   wmctool protocol  <Microsoft.MediaCenter.UI.dll | EhCM.dll> <out.h>   render protocol layouts
//   wmctool publicize <in.dll> <out.dll>         reference copy with everything public
//   wmctool patch     <ehome dir> <out dir>      runtime copies with Windows semantics
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Mono.Cecil;
using Mono.Cecil.Cil;

static class WmcTool
{
    static int Main(string[] args)
    {
        if (args.Length < 3)
        {
            Console.Error.WriteLine("usage: wmctool pinvokes|protocol|publicize|patch <in> <out> | uses <folder> <assembly> [type prefix]"
                                    + " | layouts <assembly> <out.h> <C prefix> <type|Outer/Nested|Outer/*> ...");
            return 2;
        }
        switch (args[0])
        {
            case "pinvokes": return PInvokes(args[1], args[2]);
            case "protocol": return Protocol(args[1], args[2]);
            case "layouts": return Layouts(args[1], args[2], args.Skip(3).ToArray());
            case "publicize": return Publicize(args[1], args[2]);
            case "bases": return Bases.Run(args[1], args[2], args.Skip(3).ToArray());
            case "uses": return Uses(args[1], args[2], args.Length > 3 ? args[3] : null);
            case "patch": return Patcher.Run(args[1], args[2], args.Skip(3).ToArray());
        }
        Console.Error.WriteLine("unknown command " + args[0]);
        return 2;
    }

    // ---------------------------------------------------------------- helpers

    internal static IEnumerable<string> AssemblyFiles(string dir)
    {
        foreach (string path in Directory.GetFiles(dir).OrderBy(p => p, StringComparer.OrdinalIgnoreCase))
        {
            string lower = path.ToLowerInvariant();
            if (!lower.EndsWith(".dll") && !lower.EndsWith(".exe")) continue;
            if (IsManaged(path)) yield return path;
        }
    }

    internal static bool IsManaged(string path)
    {
        try
        {
            using (var f = File.OpenRead(path))
            {
                var b = new byte[4096];
                int n = f.Read(b, 0, b.Length);
                if (n < 0x100 || b[0] != 'M' || b[1] != 'Z') return false;
                int pe = BitConverter.ToInt32(b, 0x3C);
                if (pe + 0x108 > n) return false;
                int magic = BitConverter.ToUInt16(b, pe + 24);
                int ddir = pe + 24 + (magic == 0x10B ? 96 : 112);
                return BitConverter.ToInt32(b, ddir + 14 * 8) != 0;
            }
        }
        catch (IOException) { return false; }
    }

    internal static IEnumerable<TypeDefinition> AllTypes(ModuleDefinition module)
    {
        var stack = new Stack<TypeDefinition>(module.Types);
        while (stack.Count > 0)
        {
            var t = stack.Pop();
            yield return t;
            foreach (var n in t.NestedTypes) stack.Push(n);
        }
    }

    internal static ReaderParameters Reader(string dir)
    {
        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(dir);
        return new ReaderParameters { AssemblyResolver = resolver, ReadingMode = ReadingMode.Deferred };
    }

    // --------------------------------------------------------------- pinvokes

    static int PInvokes(string dir, string outPath)
    {
        var lines = new List<string>();
        foreach (string path in AssemblyFiles(dir))
        {
            AssemblyDefinition asm;
            try { asm = AssemblyDefinition.ReadAssembly(path, Reader(dir)); }
            catch (Exception e) { Console.Error.WriteLine("skip " + Path.GetFileName(path) + ": " + e.Message); continue; }
            foreach (var type in AllTypes(asm.MainModule))
            {
                foreach (var m in type.Methods)
                {
                    if (!m.IsPInvokeImpl || m.PInvokeInfo == null) continue;
                    var pi = m.PInvokeInfo;
                    string charset = pi.IsCharSetUnicode ? "Unicode" : pi.IsCharSetAuto ? "Auto" : pi.IsCharSetAnsi ? "Ansi" : "None";
                    var sig = new StringBuilder();
                    sig.Append(TypeName(m.ReturnType)).Append(" (");
                    for (int i = 0; i < m.Parameters.Count; i++)
                    {
                        var p = m.Parameters[i];
                        if (i > 0) sig.Append(", ");
                        if (p.IsOut && !p.IsIn) sig.Append("out ");
                        sig.Append(TypeName(p.ParameterType));
                        if (p.HasMarshalInfo) sig.Append(" [").Append(p.MarshalInfo.NativeType).Append("]");
                        sig.Append(' ').Append(p.Name);
                    }
                    sig.Append(')');
                    string module = pi.Module.Name.ToLowerInvariant();
                    if (module.Length == 0) module = "(self)";   // C++/CLI: native code in the same file
                    else if (!module.Contains(".")) module += ".dll";
                    lines.Add(string.Join("\t", new[] {
                        module, pi.EntryPoint ?? m.Name, charset,
                        pi.IsNoMangle ? "exact" : "probe",
                        pi.SupportsLastError ? "lasterror" : "-",
                        sig.ToString(), type.FullName, Path.GetFileName(path) }));
                }
            }
        }
        lines.Sort(StringComparer.Ordinal);
        File.WriteAllLines(outPath, lines.Distinct());
        Console.WriteLine("{0} native call declarations", lines.Count);
        return 0;
    }

    static string TypeName(TypeReference t)
    {
        string n = t.FullName;
        n = n.Replace("System.Void", "void").Replace("System.Int32", "int").Replace("System.UInt32", "uint")
             .Replace("System.Int16", "short").Replace("System.UInt16", "ushort").Replace("System.Int64", "long")
             .Replace("System.UInt64", "ulong").Replace("System.Boolean", "bool").Replace("System.String", "string")
             .Replace("System.IntPtr", "IntPtr").Replace("System.UIntPtr", "UIntPtr").Replace("System.Byte", "byte")
             .Replace("System.Single", "float").Replace("System.Double", "double").Replace("System.Char", "char")
             .Replace("System.Text.StringBuilder", "StringBuilder").Replace("System.Object", "object");
        return n;
    }

    // --------------------------------------------------------------- protocol
    //
    // The UI framework talks to its renderer in fixed-layout messages. Each
    // remote class is a type under Microsoft.MediaCenter.Protocols with nested
    // structs named Msg<id>_<Name>. This writes those layouts as a C header so
    // the stand-in renderer reads exactly what the framework writes.

    class Layout
    {
        public int Size, Align;
        public string CName;           // C type to declare a field with
        public List<Field> Fields;     // null for primitives
    }

    class Field { public string Name; public Layout Type; public int Offset; public string Comment; }

    static bool s_allowClasses;
    static bool s_refsAsPointers;   // (layouts: a field of a reference type is marshalled as a pointer)
    static string s_prefix = "Sp_";   // (C names: Sp_ for the Splash protocol, another for `layouts`)
    static readonly Dictionary<string, Layout> s_layouts = new Dictionary<string, Layout>();
    static readonly List<string> s_structDecls = new List<string>();
    // Message type -> its name without the number; overloads get _2, _3 in order.
    static readonly Dictionary<string, string> s_msgNames = new Dictionary<string, string>();

    static Layout Prim(string c, int size) { return new Layout { CName = c, Size = size, Align = size }; }

    static Layout LayoutOf(TypeReference tr)
    {
        // Pointers, and arrays (references, which nothing native reads).
        if (tr.IsPointer || tr.IsFunctionPointer || tr.IsByReference || tr.IsArray) return Prim("uint64_t", 8);
        switch (tr.FullName)
        {
            case "System.Boolean": return Prim("uint8_t", 1);
            case "System.Byte": return Prim("uint8_t", 1);
            case "System.SByte": return Prim("int8_t", 1);
            case "System.Char": return Prim("uint16_t", 2);
            case "System.Int16": return Prim("int16_t", 2);
            case "System.UInt16": return Prim("uint16_t", 2);
            case "System.Int32": return Prim("int32_t", 4);
            case "System.UInt32": return Prim("uint32_t", 4);
            case "System.Int64": return Prim("int64_t", 8);
            case "System.UInt64": return Prim("uint64_t", 8);
            case "System.Single": return Prim("float", 4);
            case "System.Double": return Prim("double", 8);
            case "System.IntPtr": return Prim("int64_t", 8);
            case "System.UIntPtr": return Prim("uint64_t", 8);
        }
        Layout known;
        if (s_layouts.TryGetValue(tr.FullName, out known)) return known;

        TypeDefinition td = tr.Resolve();
        if (td == null) throw new InvalidOperationException("cannot resolve " + tr.FullName);
        if (td.IsEnum)
        {
            var under = td.Fields.First(f => !f.IsStatic).FieldType;
            var l = LayoutOf(under);
            s_layouts[tr.FullName] = l;
            return l;
        }
        if (!td.IsValueType && s_refsAsPointers) return Prim("uint64_t", 8);   // (a marshalled string, delegate, ...)
        if (!td.IsValueType && !s_allowClasses) throw new InvalidOperationException("reference type in a message: " + tr.FullName);

        var layout = new Layout { Fields = new List<Field>() };
        layout.CName = "struct " + CIdent(td);
        s_layouts[tr.FullName] = layout;
        int pack = td.PackingSize > 0 ? td.PackingSize : 8;
        int offset = 0, align = 1;
        foreach (var f in td.Fields.Where(f => !f.IsStatic))
        {
            var ft = LayoutOf(f.FieldType);
            int a = Math.Min(ft.Align, pack);
            if (td.IsExplicitLayout) offset = f.Offset;
            else offset = (offset + a - 1) / a * a;
            layout.Fields.Add(new Field { Name = CField(SameName(td, f.Name)), Type = ft, Offset = offset, Comment = f.FieldType.Name });
            offset += ft.Size;
            align = Math.Max(align, a);
        }
        if (td.IsExplicitLayout) offset = layout.Fields.Count == 0 ? 0 : layout.Fields.Max(x => x.Offset + x.Type.Size);
        int size = (offset + align - 1) / align * align;
        if (td.ClassSize > size) size = td.ClassSize;
        if (size == 0) size = 1;
        layout.Size = size;
        layout.Align = align;
        s_structDecls.Add(Declare(layout, td.FullName));
        return layout;
    }

    static string CIdent(TypeDefinition td)
    {
        // Messages are named without their number ("Msg6_OnStateChange" ->
        // "OnStateChange"): the engine handles them by name, and the numbers
        // move whenever a message is added or taken away.
        string name;
        if (!s_msgNames.TryGetValue(td.FullName, out name)) name = td.Name;
        for (var d = td.DeclaringType; d != null; d = d.DeclaringType)
        {
            // (XP's eHome.Native.Win32 is Windows 7's Win32Api: one name for the engine)
            string outer = d.Name == "Win32" && d.Namespace == "eHome.Native" ? "Win32Api" : d.Name;
            name = outer + "_" + name;
        }
        return s_prefix + Regex.Replace(name, "[^A-Za-z0-9_]", "_");
    }

    // XP Media Center Edition 2005 (eHome.* in EhCM.dll) names the fields the
    // engine reads differently: messages start "__size, __msgid,
    // __idObjectSubject" and geometry has no "m_". They get Windows 7's names,
    // so one engine reads both.
    static readonly HashSet<string> s_geometry = new HashSet<string>
        { "Size", "Point", "Rectangle", "Vector3", "Rotation" };   // (the float ones match already)

    static string SameName(TypeDefinition td, string name)
    {
        string ns = td.DeclaringType != null ? td.DeclaringType.Namespace : td.Namespace;
        if (ns == null || !ns.StartsWith("eHome.")) return name;
        if (name.StartsWith("__")) return name.Substring(2);
        if (s_geometry.Contains(td.Name) && !name.StartsWith("m_")) return "m_" + name.TrimStart('_');
        return name;
    }

    static string CField(string name)
    {
        name = Regex.Replace(name, "[^A-Za-z0-9_]", "_");
        if (name.StartsWith("_priv_")) name = name.Substring(6);
        return name;
    }

    // Emits the struct packed, with the padding the CLR inserts written out,
    // so the C layout is the computed one whatever the C compiler would do.
    static string Declare(Layout l, string comment)
    {
        var sb = new StringBuilder();
        // SP_HAS_<struct>_<field>: the engine's code for a field that only
        // some Media Center versions send is compiled only where it exists.
        var has = new StringBuilder();
        string bare = l.CName.StartsWith("struct ") ? l.CName.Substring(7) : l.CName;
        sb.AppendFormat("/* {0} */\n", comment);
        sb.AppendFormat("{0} {{\n", l.CName);
        int pos = 0, pad = 0;
        foreach (var f in l.Fields.OrderBy(x => x.Offset))
        {
            if (f.Offset > pos) sb.AppendFormat("    uint8_t _pad{0}[{1}];\n", pad++, f.Offset - pos);
            if (f.Offset < pos) { sb.AppendFormat("    /* overlapping field {0} at {1} omitted */\n", f.Name, f.Offset); continue; }
            sb.AppendFormat("    {0} {1}; /* +{2} {3} */\n", f.Type.CName, f.Name, f.Offset, f.Comment);
            has.AppendFormat("#define SP_HAS_{0}_{1} 1\n", bare, f.Name);
            pos = f.Offset + f.Type.Size;
        }
        if (l.Size > pos) sb.AppendFormat("    uint8_t _pad{0}[{1}];\n", pad++, l.Size - pos);
        sb.Append("} __attribute__((packed));\n");
        sb.AppendFormat("_Static_assert(sizeof({0}) == {1}, \"layout\");\n", l.CName, l.Size);
        sb.Append(has).Append("\n");
        return sb.ToString();
    }

    // ---------------------------------------------------------------- layouts
    //
    // The C layouts of chosen structs, for an engine whose messages are not
    // the Splash protocol's (XP Media Center Edition 2002's, in EhCM.dll's
    // Fast.Remote.RenderApi and its callbacks). A type is named in full,
    // "Outer/Nested" for a nested one, or "Outer/*" for every struct nested
    // in Outer. Each gets the C prefix given.

    static int Layouts(string dll, string outPath, string[] specs)
    {
        if (specs.Length < 2) { Console.Error.WriteLine("layouts: a C prefix and at least one type"); return 2; }
        s_prefix = specs[0];
        s_refsAsPointers = true;
        var asm = AssemblyDefinition.ReadAssembly(dll, Reader(Path.GetDirectoryName(Path.GetFullPath(dll))));
        var all = AllTypes(asm.MainModule).ToList();
        int count = 0;
        foreach (string spec in specs.Skip(1))
        {
            string[] parts = spec.Split('/');
            var outer = all.FirstOrDefault(x => x.FullName == parts[0] && x.DeclaringType == null);
            if (outer == null) { Console.Error.WriteLine("layouts: no type " + parts[0]); return 1; }
            IEnumerable<TypeDefinition> chosen = new[] { outer };
            for (int i = 1; i < parts.Length; i++)
            {
                string want = parts[i];
                chosen = chosen.SelectMany(x => x.NestedTypes)
                               .Where(x => x.IsValueType && !x.IsEnum && (want == "*" || x.Name == want)).ToList();
            }
            foreach (var td in chosen.OrderBy(x => x.Name, StringComparer.Ordinal)) { LayoutOf(td); count++; }
        }
        var sb = new StringBuilder();
        sb.Append("/* Generated by wmctool layouts from " + Path.GetFileName(dll) + ". Do not edit. */\n");
        sb.Append("#pragma once\n#include <stdint.h>\n\n");
        foreach (var d in s_structDecls) sb.Append(d);
        File.WriteAllText(outPath, sb.ToString());
        Console.WriteLine(count + " structures (" + s_structDecls.Count + " with what they contain)");
        return 0;
    }

    static int Protocol(string uiDll, string outPath)
    {
        var asm = AssemblyDefinition.ReadAssembly(uiDll, Reader(Path.GetDirectoryName(Path.GetFullPath(uiDll))));
        var enums = new StringBuilder();
        var names = new StringBuilder();
        var tables = new StringBuilder();
        var sizes = new List<string>();
        var classNames = new List<string>();
        var hasMessages = new StringBuilder();   // SP_HAS_MSG_<class>_<message>: what this version sends
        int messages = 0;

        foreach (var type in AllTypes(asm.MainModule).OrderBy(t => t.FullName, StringComparer.Ordinal))
        {
            // (XP Media Center Edition 2005: eHome.UI.Remote.Protocols in EhCM.dll)
            string space = type.Namespace == null ? null
                         : type.Namespace.StartsWith("Microsoft.MediaCenter.Protocols") ? "Microsoft.MediaCenter.Protocols."
                         : type.Namespace.StartsWith("eHome.UI.Remote.Protocols") ? "eHome.UI.Remote.Protocols." : null;
            if (space == null) continue;

            // Remote class names appear as string constants in the protocol
            // binders: port.InitRemoteClass("Splash::Rendering::Visual").
            foreach (var m in type.Methods.Where(m => m.HasBody))
                foreach (var ins in m.Body.Instructions)
                    if (ins.OpCode == OpCodes.Ldstr && ((string)ins.Operand).Contains("::"))
                        classNames.Add((string)ins.Operand);

            var msgs = type.NestedTypes
                .Select(n => new { Type = n, Match = Regex.Match(n.Name, @"^Msg(\d+)_(\w+)$") })
                .Where(x => x.Match.Success)
                .OrderBy(x => int.Parse(x.Match.Groups[1].Value)).ToList();
            if (msgs.Count == 0) continue;

            string cls = type.Name;
            bool callback = cls.StartsWith("Local");
            cls = cls.StartsWith("Remote") ? cls.Substring(6) : cls.StartsWith("Local") ? cls.Substring(5) : cls;
            enums.AppendFormat("/* {0}{1} */\nenum {{\n", type.FullName, callback ? " (renderer to application)" : "");
            var counts = new Dictionary<string, int>();
            string protoName = type.Namespace.Substring(space.Length).Replace(".", "::") + "::" + cls;
            string table = "n_" + Regex.Replace(protoName, "[^A-Za-z0-9]", "_");
            int maxId = msgs.Max(x => int.Parse(x.Match.Groups[1].Value));
            names.AppendFormat("static const char *const {0}[{1}] = {{\n", table, maxId + 1);
            tables.AppendFormat("    {{ \"{0}\", {1}, {2} }},\n", protoName, table, maxId + 1);
            foreach (var x in msgs)
            {
                names.AppendFormat("    [{0}] = \"{1}\",\n", x.Match.Groups[1].Value, x.Match.Groups[2].Value);
                string mname = x.Match.Groups[2].Value;
                int n;
                counts.TryGetValue(mname, out n);
                counts[mname] = ++n;
                if (n > 1) mname += "_" + n;   // overloads, in order
                s_msgNames[x.Type.FullName] = mname;
                var l = LayoutOf(x.Type);
                enums.AppendFormat("    SpMsg_{0}_{1} = {2},\n", cls, mname, x.Match.Groups[1].Value);
                hasMessages.AppendFormat("#define SP_HAS_MSG_{0}_{1} 1\n", cls, mname);
                sizes.Add(x.Type.FullName + "\t" + l.Size);
                messages++;
            }
            enums.Append("};\n\n");
            names.Append("};\n");
        }

        // Structures passed across the native function boundary (not in
        // messages): the text run packet, image and device descriptions.
        foreach (var type in AllTypes(asm.MainModule).OrderBy(t => t.FullName, StringComparer.Ordinal))
        {
            bool interop = type.DeclaringType != null && (type.DeclaringType.FullName == "Microsoft.MediaCenter.Interop.RenderApi"
                                                          || type.DeclaringType.FullName == "eHome.Native.RenderApi")
                           && type.IsValueType && !type.IsEnum;
            bool named = type.FullName == "Microsoft.MediaCenter.Interop.Win32Api/LOGFONTW_STRUCT"
                         || type.FullName == "Microsoft.MediaCenter.Interop.Win32Api/RECT"
                         || type.FullName == "eHome.Native.Win32/LOGFONTW_STRUCT" || type.FullName == "eHome.Native.Win32/RECT";
            if (!interop && !named) continue;
            try { LayoutOf(type); }
            catch (InvalidOperationException e) { Console.Error.WriteLine("skip " + type.FullName + ": " + e.Message); }
        }
        s_allowClasses = true;
        var req = asm.MainModule.GetType("Microsoft.MediaCenter.UI.ImageRequirements") ?? asm.MainModule.GetType("eHome.Native.ImageRequirements");
        if (req != null)
        {
            try { LayoutOf(req); }
            catch (InvalidOperationException e) { Console.Error.WriteLine("skip ImageRequirements: " + e.Message); }
        }
        s_allowClasses = false;

        var sb = new StringBuilder();
        sb.Append("/* Generated by wmctool from the installed UI framework's metadata. Do not edit. */\n");
        sb.Append("#pragma once\n#include <stdint.h>\n\n");
        sb.Append("/* Remote class names the framework registers */\n");
        foreach (var n in classNames.Distinct().OrderBy(n => n, StringComparer.Ordinal))
            sb.AppendFormat("/*   {0} */\n", n);
        sb.Append("\n");
        foreach (var d in s_structDecls) sb.Append(d);
        sb.Append(enums);
        sb.Append(hasMessages);
        File.WriteAllText(outPath, sb.ToString());
        File.WriteAllLines(outPath + ".sizes.tsv", sizes);
        // Message names by class, for the engine's log.
        var nc = new StringBuilder();
        nc.Append("/* Generated by wmctool. Do not edit. */\n#include <stddef.h>\n");
        nc.Append("typedef struct { const char *class_name; const char *const *msg_names; int count; } SpProtoClass;\n\n");
        nc.Append(names);
        nc.Append("\n__attribute__((visibility(\"hidden\"))) const SpProtoClass sp_proto_classes[] = {\n");
        nc.Append(tables);
        nc.Append("    { NULL, NULL, 0 },\n};\n");
        File.WriteAllText(Path.Combine(Path.GetDirectoryName(outPath), Path.GetFileNameWithoutExtension(outPath) + "_names.c"), nc.ToString());
        Console.WriteLine("{0} messages, {1} structures, {2} class names", messages, s_structDecls.Count, classNames.Distinct().Count());
        return 0;
    }

    // -------------------------------------------------------------- publicize
    //
    // A copy with every type and member public, used only as a compile-time
    // reference for our own host code. The runtime always loads the real
    // (patched) assemblies, where access is granted by IgnoresAccessChecksTo.

    // Which members of one assembly (by name) the other assemblies in a
    // folder use, with the number of places: what a stand-in for it has to
    // provide. An optional prefix limits the output to matching types.
    static int Uses(string dir, string assemblyName, string prefix)
    {
        var counts = new SortedDictionary<string, int>();
        var users = new Dictionary<string, HashSet<string>>();
        foreach (string path in Directory.GetFiles(dir))
        {
            string lower = path.ToLowerInvariant();
            if (!(lower.EndsWith(".dll") || lower.EndsWith(".exe")) || !IsManaged(path)) continue;
            AssemblyDefinition asm;
            try { asm = AssemblyDefinition.ReadAssembly(path, Reader(dir)); } catch { continue; }
            if (asm.Name.Name == assemblyName) continue;
            foreach (var type in AllTypes(asm.MainModule))
            {
                foreach (var m in type.Methods)
                {
                    if (!m.HasBody) continue;
                    foreach (var ins in m.Body.Instructions)
                    {
                        var member = ins.Operand as MemberReference;
                        if (member == null || member is TypeReference) continue;
                        var declaring = member.DeclaringType;
                        if (declaring == null) continue;
                        var scope = declaring.GetElementType().Scope as AssemblyNameReference;
                        if (scope == null || scope.Name != assemblyName) continue;
                        string key = declaring.FullName + "::" + member.Name;
                        if (prefix != null && !declaring.FullName.StartsWith(prefix)) continue;
                        int n;
                        counts.TryGetValue(key, out n);
                        counts[key] = n + 1;
                        HashSet<string> set;
                        if (!users.TryGetValue(key, out set)) users[key] = set = new HashSet<string>();
                        set.Add(asm.Name.Name);
                    }
                }
            }
        }
        foreach (var kv in counts)
            Console.WriteLine("{0,5}  {1}  [{2}]", kv.Value, kv.Key, string.Join(",", users[kv.Key]));
        return 0;
    }

    static int Publicize(string inPath, string outPath)
    {
        var asm = AssemblyDefinition.ReadAssembly(inPath, Reader(Path.GetDirectoryName(Path.GetFullPath(inPath))));
        foreach (var type in AllTypes(asm.MainModule))
        {
            if (type.IsNested) type.IsNestedPublic = true; else type.IsPublic = true;
            var eventNames = new HashSet<string>(type.Events.Select(e => e.Name));
            foreach (var f in type.Fields)
                if (!eventNames.Contains(f.Name)) f.IsPublic = true;
            foreach (var m in type.Methods)
                if (!m.Name.Contains(".") || m.IsConstructor) m.IsPublic = true;
        }
        asm.Write(outPath);
        return 0;
    }
}
