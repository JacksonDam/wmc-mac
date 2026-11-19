// Base classes for stand-ins of COM objects.
//
// Media Center talks to Windows components (Windows Media Player, ...)
// through interop interfaces with dozens of members each, of which it uses a
// fraction. A stand-in written by hand would be mostly empty members. This
// generates, from the interop assembly itself, one class per request that
// implements every member of the named interfaces as a virtual method which
// reports that it was reached (WmcStandins.ComTodo.Hit) and returns the
// default value. The hand-written stand-in derives from it and overrides
// the members that matter.
//
//   wmctool bases <interop.dll> <out.dll> <Class=Interface[+Interface...]> ...
//
// Members are plain methods (get_X, set_X, add_X, remove_X): the class has
// no property or event metadata, so a C# subclass overrides them by those
// names. Event accessors are real: they keep the handlers in a public field
// named <Event>_handler, which the subclass invokes.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;

static class Bases
{
    public static int Run(string interopPath, string outPath, string[] specs)
    {
        string dir = Path.GetDirectoryName(Path.GetFullPath(interopPath));
        var interop = AssemblyDefinition.ReadAssembly(interopPath, WmcTool.Reader(dir));
        string name = Path.GetFileNameWithoutExtension(outPath);
        var asm = AssemblyDefinition.CreateAssembly(new AssemblyNameDefinition(name, new Version(0, 0, 0, 0)), name, ModuleKind.Dll);
        var module = asm.MainModule;
        var standins = new AssemblyNameReference("WmcStandins", new Version(0, 0, 0, 0));
        module.AssemblyReferences.Add(standins);
        var hit = new MethodReference("Hit", module.TypeSystem.Void, new TypeReference("WmcStandins", "ComTodo", module, standins));
        hit.Parameters.Add(new ParameterDefinition(module.TypeSystem.String));
        var objectCtor = module.ImportReference(typeof(object).GetConstructor(Type.EmptyTypes));
        var combine = module.ImportReference(typeof(Delegate).GetMethod("Combine", new[] { typeof(Delegate), typeof(Delegate) }));
        var remove = module.ImportReference(typeof(Delegate).GetMethod("Remove", new[] { typeof(Delegate), typeof(Delegate) }));

        foreach (string spec in specs)
        {
            string[] parts = spec.Split('=');
            var type = new TypeDefinition(name, parts[0], TypeAttributes.Public | TypeAttributes.Class | TypeAttributes.BeforeFieldInit, module.TypeSystem.Object);
            module.Types.Add(type);
            var ctor = new MethodDefinition(".ctor", MethodAttributes.Public | MethodAttributes.HideBySig | MethodAttributes.SpecialName | MethodAttributes.RTSpecialName, module.TypeSystem.Void);
            var cil = ctor.Body.GetILProcessor();
            cil.Append(cil.Create(OpCodes.Ldarg_0));
            cil.Append(cil.Create(OpCodes.Call, objectCtor));
            cil.Append(cil.Create(OpCodes.Ret));
            type.Methods.Add(ctor);

            // The named interfaces and everything they inherit.
            var all = new List<TypeDefinition>();
            Action<TypeDefinition> add = null;
            add = t =>
            {
                if (all.Contains(t)) return;
                all.Add(t);
                foreach (var i in t.Interfaces) add(i.InterfaceType.Resolve());
            };
            // A|B: the first of these that the interop assembly has (an older
            // Media Center may only have the interface a newer one extends).
            foreach (string choice in parts[1].Split('+'))
            {
                var t = choice.Split('|').Select(iname => interop.MainModule.Types.FirstOrDefault(x => x.Name == iname))
                              .FirstOrDefault(x => x != null);
                if (t == null) { Console.Error.WriteLine("bases: no interface " + choice); return 1; }
                add(t);
            }
            var done = new HashSet<string>();
            int count = 0;
            foreach (var iface in all)
            {
                type.Interfaces.Add(new InterfaceImplementation(module.ImportReference(iface)));
                foreach (var m in iface.Methods)
                {
                    string key = m.Name + "(" + string.Join(",", m.Parameters.Select(p => p.ParameterType.FullName)) + "):" + m.ReturnType.FullName;
                    if (!done.Add(key)) continue;
                    var impl = new MethodDefinition(m.Name, MethodAttributes.Public | MethodAttributes.Virtual | MethodAttributes.HideBySig | MethodAttributes.NewSlot,
                        module.ImportReference(m.ReturnType));
                    foreach (var p in m.Parameters)
                        impl.Parameters.Add(new ParameterDefinition(p.Name, p.Attributes & (ParameterAttributes.In | ParameterAttributes.Out), module.ImportReference(p.ParameterType)));
                    var il = impl.Body.GetILProcessor();
                    bool accessor = (m.Name.StartsWith("add_") || m.Name.StartsWith("remove_")) && m.Parameters.Count == 1 && IsDelegate(m.Parameters[0].ParameterType);
                    if (accessor)
                    {
                        string field = m.Name.Substring(m.Name.IndexOf('_') + 1) + "_handler";
                        var handlerType = module.ImportReference(m.Parameters[0].ParameterType);
                        var f = type.Fields.FirstOrDefault(x => x.Name == field);
                        if (f == null) type.Fields.Add(f = new FieldDefinition(field, FieldAttributes.Public, handlerType));
                        il.Append(il.Create(OpCodes.Ldarg_0));
                        il.Append(il.Create(OpCodes.Ldarg_0));
                        il.Append(il.Create(OpCodes.Ldfld, f));
                        il.Append(il.Create(OpCodes.Ldarg_1));
                        il.Append(il.Create(OpCodes.Call, m.Name.StartsWith("add_") ? combine : remove));
                        il.Append(il.Create(OpCodes.Castclass, handlerType));
                        il.Append(il.Create(OpCodes.Stfld, f));
                        il.Append(il.Create(OpCodes.Ret));
                    }
                    else
                    {
                        il.Append(il.Create(OpCodes.Ldstr, iface.Name + "." + m.Name));
                        il.Append(il.Create(OpCodes.Call, hit));
                        if (m.ReturnType.FullName != "System.Void")
                        {
                            var local = new VariableDefinition(impl.ReturnType);
                            impl.Body.Variables.Add(local);
                            impl.Body.InitLocals = true;
                            il.Append(il.Create(OpCodes.Ldloc, local));
                        }
                        il.Append(il.Create(OpCodes.Ret));
                    }
                    type.Methods.Add(impl);
                    count++;
                }
            }
            Console.WriteLine("{0}: {1} interfaces, {2} members", parts[0], all.Count, count);
        }
        asm.Write(outPath);
        return 0;
    }

    static bool IsDelegate(TypeReference t)
    {
        var d = t.Resolve();
        return d != null && d.BaseType != null && d.BaseType.FullName == "System.MulticastDelegate";
    }
}
