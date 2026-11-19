// Runtime copies of the installer's assemblies, adjusted so that they behave
// under Mono on macOS the way they do under the .NET Framework on Windows.
// Every change here is a mechanical metadata edit made on the user's own
// files at conversion time; none of Microsoft's code is stored in this repo.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;

static class Patcher
{
    // Calls sent to a method of the same name in WmcStandins.Compat.
    static readonly Dictionary<string, string> s_redirects = new Dictionary<string, string>();
    // Calls replaced by "do nothing and return the type's default value".
    static readonly HashSet<string> s_defaults = new HashSet<string>();
    // Methods whose own body is replaced by "return the default value". Unlike
    // a call redirect this also covers virtual and reflection calls.
    static readonly HashSet<string> s_stubs = new HashSet<string>();
    // Calls wrapped so that an exception is reported to WmcStandins.Compat
    // instead of travelling on.
    static readonly HashSet<string> s_guards = new HashSet<string>();
    // Methods whose own body is replaced by a call to a method of that name
    // in WmcStandins.Compat (instance first, then the parameters).
    static readonly Dictionary<string, string> s_bodies = new Dictionary<string, string>();
    // Calls whose leading string argument(s) are file paths, to be passed
    // through WmcStandins.Compat.FixPath first. The number is how many.
    static readonly Dictionary<string, int> s_paths = new Dictionary<string, int>();
    // Every rule, and those that found something (the rest are reported: in
    // another Media Center version the type or method may be named otherwise).
    static readonly List<string> s_rules = new List<string>();
    static readonly HashSet<string> s_used = new HashSet<string>();

    // managed/redirects.txt names the calls to change.
    static void LoadRedirects(string outDir)
    {
        // build.py names the table; otherwise it is beside the build folder.
        string table = Environment.GetEnvironmentVariable("WMC_REDIRECTS");
        if (string.IsNullOrEmpty(table))
        {
            string root = Path.GetDirectoryName(Path.GetDirectoryName(Path.GetDirectoryName(Path.GetFullPath(outDir))));
            table = Path.Combine(root, "managed", "redirects.txt");
        }
        if (!File.Exists(table)) throw new FileNotFoundException("the table of calls to patch is missing", table);
        // "[vista] rule" or "[7] rule": only when patching that Media Center
        // (WMC_RELEASE, set by build.py).
        string release = Environment.GetEnvironmentVariable("WMC_RELEASE") ?? "7";
        foreach (string raw in File.ReadAllLines(table))
        {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;
            if (line.StartsWith("["))
            {
                int close = line.IndexOf(']');
                if (close < 0 || line.Substring(1, close - 1) != release) continue;
                line = line.Substring(close + 1).Trim();
            }
            string[] parts = line.Split(new[] { "=>" }, StringSplitOptions.None);
            if (parts.Length != 2) continue;
            string key = parts[0].Trim(), what = parts[1].Trim();
            s_rules.Add(key);
            if (what == "@default") s_defaults.Add(key);
            else if (what == "@stub") s_stubs.Add(key);
            else if (what == "@guard") s_guards.Add(key);
            else if (what.StartsWith("@body ")) s_bodies[key] = what.Substring(6).Trim();
            else if (what == "@path") s_paths[key] = 1;
            else if (what == "@path2") s_paths[key] = 2;
            else s_redirects[key] = what;
        }
    }

    static TypeReference CompatType(ModuleDefinition module)
    {
        var asm = module.AssemblyReferences.FirstOrDefault(a => a.Name == "WmcStandins");
        if (asm == null)
        {
            asm = new AssemblyNameReference("WmcStandins", new Version(0, 0, 0, 0));
            module.AssemblyReferences.Add(asm);
        }
        return new TypeReference("WmcStandins", "Compat", module, asm);
    }

    // WmcStandins.Compat.<name> with the callee's own signature: the instance
    // (if any) first, then its parameters. The stand-ins are compiled after
    // the patching, against the patched assemblies, so nothing is looked up
    // here; a stand-in whose signature differs fails when it is first called.
    static MethodReference CompatMethod(ModuleDefinition module, string name, MethodReference callee)
    {
        var m = new MethodReference(name, callee.ReturnType, CompatType(module));
        if (callee.HasThis) m.Parameters.Add(new ParameterDefinition(callee.DeclaringType));
        foreach (var p in callee.Parameters) m.Parameters.Add(new ParameterDefinition(p.ParameterType));
        return m;
    }

    static bool Plain(MethodReference callee)
    {
        // Generic callees and value-type instances need more care than any
        // entry has needed so far.
        if (callee is GenericInstanceMethod || callee.DeclaringType is GenericInstanceType) return false;
        if (callee.HasThis && callee.DeclaringType.IsValueType) return false;
        return true;
    }

    // A static method beside the calling method that makes the call inside
    // try/catch, hands any exception to WmcStandins.Compat.Swallowed and
    // returns the default value.
    static MethodDefinition GuardWrapper(TypeDefinition host, MethodReference callee, bool isVirtual, string key)
    {
        string name = "Wmc$Guard$" + key.Replace("::", "$").Replace(".", "_") + (isVirtual ? "$v" : "");
        var existing = host.Methods.FirstOrDefault(x => x.Name == name);
        if (existing != null) return existing;
        var module = host.Module;
        var w = new MethodDefinition(name, MethodAttributes.Private | MethodAttributes.Static | MethodAttributes.HideBySig, callee.ReturnType);
        if (callee.HasThis) w.Parameters.Add(new ParameterDefinition("self", ParameterAttributes.None, callee.DeclaringType));
        foreach (var p in callee.Parameters) w.Parameters.Add(new ParameterDefinition(p.Name, ParameterAttributes.None, p.ParameterType));
        var il = w.Body.GetILProcessor();
        bool returns = callee.ReturnType.FullName != "System.Void";
        VariableDefinition result = null;
        if (returns)
        {
            result = new VariableDefinition(callee.ReturnType);
            w.Body.Variables.Add(result);
            w.Body.InitLocals = true;
        }
        var end = returns ? il.Create(OpCodes.Ldloc, result) : il.Create(OpCodes.Ret);
        var tryStart = il.Create(OpCodes.Nop);
        il.Append(tryStart);
        for (int i = 0; i < w.Parameters.Count; i++) il.Append(il.Create(OpCodes.Ldarg, w.Parameters[i]));
        il.Append(il.Create(isVirtual ? OpCodes.Callvirt : OpCodes.Call, callee));
        if (returns) il.Append(il.Create(OpCodes.Stloc, result));
        il.Append(il.Create(OpCodes.Leave, end));
        var exceptionType = module.ImportReference(typeof(Exception));
        var swallowed = new MethodReference("Swallowed", module.TypeSystem.Void, CompatType(module));
        swallowed.Parameters.Add(new ParameterDefinition(exceptionType));
        swallowed.Parameters.Add(new ParameterDefinition(module.TypeSystem.String));
        var handlerStart = il.Create(OpCodes.Ldstr, key);
        il.Append(handlerStart);
        il.Append(il.Create(OpCodes.Call, swallowed));
        il.Append(il.Create(OpCodes.Leave, end));
        il.Append(end);
        if (returns) il.Append(il.Create(OpCodes.Ret));
        w.Body.ExceptionHandlers.Add(new ExceptionHandler(ExceptionHandlerType.Catch)
        {
            TryStart = tryStart, TryEnd = handlerStart, HandlerStart = handlerStart, HandlerEnd = end, CatchType = exceptionType,
        });
        host.Methods.Add(w);
        return w;
    }

    static int ApplyRedirects(ModuleDefinition module)
    {
        if (s_redirects.Count == 0 && s_defaults.Count == 0 && s_stubs.Count == 0 && s_guards.Count == 0 && s_bodies.Count == 0 && s_paths.Count == 0) return 0;
        int n = 0;
        foreach (var type in WmcTool.AllTypes(module).ToList())
        {
            foreach (var m in type.Methods.ToList())
            {
                if (!m.HasBody || m.Name.StartsWith("Wmc$Guard$")) continue;
                if (s_stubs.Contains(type.FullName + "::" + m.Name))
                {
                    s_used.Add(type.FullName + "::" + m.Name);
                    StubBody(m);
                    n++;
                    continue;
                }
                string replacement;
                if (s_bodies.TryGetValue(type.FullName + "::" + m.Name, out replacement))
                {
                    s_used.Add(type.FullName + "::" + m.Name);
                    ReplaceBody(m, replacement);
                    n++;
                    continue;
                }
                var il = m.Body.GetILProcessor();
                LengthenBranches(m);
                foreach (var ins in m.Body.Instructions.ToList())
                {
                    if (ins.OpCode != OpCodes.Call && ins.OpCode != OpCodes.Callvirt && ins.OpCode != OpCodes.Newobj) continue;
                    var callee = ins.Operand as MethodReference;
                    if (callee == null) continue;
                    string key = callee.DeclaringType.FullName + "::" + callee.Name;
                    if (s_rules.Contains(key)) s_used.Add(key);
                    int pathCount;
                    if (s_paths.TryGetValue(key, out pathCount))
                    {
                        if (FixPathArguments(m, il, ins, callee, pathCount)) n++;
                        continue;
                    }
                    string target;
                    if (ins.OpCode == OpCodes.Newobj)
                    {
                        // Type::.ctor => Name: `new Type(args)` becomes a call
                        // to the static Name(args), which returns the object
                        // to use instead (as object: a stand-in for a COM
                        // class cannot be that class).
                        if (callee.Name == ".ctor" && s_redirects.TryGetValue(key, out target))
                        {
                            var factory = new MethodReference(target, module.TypeSystem.Object, CompatType(module));
                            foreach (var p in callee.Parameters) factory.Parameters.Add(new ParameterDefinition(p.ParameterType));
                            ins.OpCode = OpCodes.Call;
                            ins.Operand = factory;
                            n++;
                        }
                        continue;
                    }
                    if (s_redirects.TryGetValue(key, out target))
                    {
                        if (!Plain(callee))
                        {
                            Console.Error.WriteLine("redirect not applied (generic or value-type callee): " + key);
                            continue;
                        }
                        ins.OpCode = OpCodes.Call;
                        ins.Operand = CompatMethod(module, target, callee);
                        n++;
                    }
                    else if (s_defaults.Contains(key))
                    {
                        ReplaceWithDefault(m, il, ins, callee);
                        n++;
                    }
                    else if (s_guards.Contains(key) && Plain(callee))
                    {
                        // (the constrained./tail. prefixes do not occur on the calls guarded so far)
                        var wrapper = GuardWrapper(type, callee, ins.OpCode == OpCodes.Callvirt, key);
                        ins.OpCode = OpCodes.Call;
                        ins.Operand = wrapper;
                        n++;
                    }
                }
            }
        }
        return n;
    }

    // Short branches reach only 127 bytes. Before instructions are inserted
    // into a method its short branches are made long ones, or a branch that
    // no longer reaches would be written out wrong.
    static readonly Dictionary<Code, OpCode> s_longForms = new Dictionary<Code, OpCode>
    {
        { Code.Br_S, OpCodes.Br }, { Code.Brfalse_S, OpCodes.Brfalse }, { Code.Brtrue_S, OpCodes.Brtrue },
        { Code.Beq_S, OpCodes.Beq }, { Code.Bge_S, OpCodes.Bge }, { Code.Bgt_S, OpCodes.Bgt }, { Code.Ble_S, OpCodes.Ble },
        { Code.Blt_S, OpCodes.Blt }, { Code.Bne_Un_S, OpCodes.Bne_Un }, { Code.Bge_Un_S, OpCodes.Bge_Un },
        { Code.Bgt_Un_S, OpCodes.Bgt_Un }, { Code.Ble_Un_S, OpCodes.Ble_Un }, { Code.Blt_Un_S, OpCodes.Blt_Un },
        { Code.Leave_S, OpCodes.Leave },
    };

    static void LengthenBranches(MethodDefinition m)
    {
        foreach (var ins in m.Body.Instructions)
        {
            OpCode longForm;
            if (s_longForms.TryGetValue(ins.OpCode.Code, out longForm)) ins.OpCode = longForm;
        }
    }

    // Before `call X(a1 .. an)`: the arguments are taken off the stack into
    // new locals and put back in order, with the first `count` string ones
    // passed through WmcStandins.Compat.FixPath on the way. (An instance, if
    // any, lies beneath the arguments and is not touched.)
    static bool FixPathArguments(MethodDefinition m, ILProcessor il, Instruction call, MethodReference callee, int count)
    {
        var ps = callee.Parameters;
        if (ps.Count == 0 || !ps.Any(p => p.ParameterType.FullName == "System.String")) return false;
        var module = m.Module;
        var fix = new MethodReference("FixPath", module.TypeSystem.String, CompatType(module));
        fix.Parameters.Add(new ParameterDefinition(module.TypeSystem.String));
        var locals = new VariableDefinition[ps.Count];
        var generic = callee.DeclaringType as GenericInstanceType;
        for (int i = 0; i < ps.Count; i++)
        {
            var t = ps[i].ParameterType;
            if (t.ContainsGenericParameter && generic == null) return false;
            locals[i] = new VariableDefinition(module.ImportReference(t));
            m.Body.Variables.Add(locals[i]);
        }
        // The original instruction object becomes the first store, so that
        // branches to the call still arrive before the whole sequence.
        var original = il.Create(call.OpCode, callee);
        call.OpCode = OpCodes.Stloc;
        call.Operand = locals[ps.Count - 1];
        var after = call;
        for (int i = ps.Count - 2; i >= 0; i--)
        {
            var store = il.Create(OpCodes.Stloc, locals[i]);
            il.InsertAfter(after, store);
            after = store;
        }
        int left = count;
        for (int i = 0; i < ps.Count; i++)
        {
            var load = il.Create(OpCodes.Ldloc, locals[i]);
            il.InsertAfter(after, load);
            after = load;
            if (left > 0 && ps[i].ParameterType.FullName == "System.String")
            {
                var c = il.Create(OpCodes.Call, fix);
                il.InsertAfter(after, c);
                after = c;
                left--;
            }
        }
        il.InsertAfter(after, original);
        return true;
    }

    // The body becomes: (for a constructor, the base class's constructor,
    // then) WmcStandins.Compat.<name>(this, arguments...) and return.
    static void ReplaceBody(MethodDefinition m, string name)
    {
        var module = m.Module;
        m.Body = new MethodBody(m);
        var il = m.Body.GetILProcessor();
        if (m.IsConstructor && !m.IsStatic)
        {
            var baseType = m.DeclaringType.BaseType;
            var baseDef = baseType.Resolve();
            var baseCtor = baseDef.Methods.First(c => c.IsConstructor && !c.IsStatic && c.Parameters.Count == 0);
            il.Append(il.Create(OpCodes.Ldarg_0));
            il.Append(il.Create(OpCodes.Call, module.ImportReference(baseCtor)));
        }
        var target = new MethodReference(name, m.ReturnType, CompatType(module));
        if (m.HasThis)
        {
            target.Parameters.Add(new ParameterDefinition(m.DeclaringType));
            il.Append(il.Create(OpCodes.Ldarg_0));
        }
        foreach (var p in m.Parameters)
        {
            target.Parameters.Add(new ParameterDefinition(p.ParameterType));
            il.Append(il.Create(OpCodes.Ldarg, p));
        }
        il.Append(il.Create(OpCodes.Call, target));
        il.Append(il.Create(OpCodes.Ret));
    }

    static void StubBody(MethodDefinition m)
    {
        m.Body = new MethodBody(m);
        var il = m.Body.GetILProcessor();
        var ret = m.ReturnType;
        switch (ret.FullName)
        {
            case "System.Void": break;
            case "System.Boolean": case "System.Byte": case "System.SByte": case "System.Char":
            case "System.Int16": case "System.UInt16": case "System.Int32": case "System.UInt32":
                il.Append(il.Create(OpCodes.Ldc_I4_0)); break;
            case "System.Int64": case "System.UInt64":
                il.Append(il.Create(OpCodes.Ldc_I8, 0L)); break;
            case "System.Single": il.Append(il.Create(OpCodes.Ldc_R4, 0f)); break;
            case "System.Double": il.Append(il.Create(OpCodes.Ldc_R8, 0d)); break;
            default:
                bool valueType = ret.IsValueType || (ret.Resolve() != null && ret.Resolve().IsValueType);
                if (ret.IsGenericParameter || valueType)
                {
                    var local = new VariableDefinition(ret);
                    m.Body.Variables.Add(local);
                    m.Body.InitLocals = true;
                    il.Append(il.Create(OpCodes.Ldloca, local));
                    il.Append(il.Create(OpCodes.Initobj, ret));
                    il.Append(il.Create(OpCodes.Ldloc, local));
                }
                else il.Append(il.Create(OpCodes.Ldnull));
                break;
        }
        il.Append(il.Create(OpCodes.Ret));
    }

    // Rewrites `call X` as: drop X's arguments, push default(return type).
    // The original instruction object is reused as the first of the new
    // sequence so that branches to it stay valid.
    static void ReplaceWithDefault(MethodDefinition m, ILProcessor il, Instruction ins, MethodReference callee)
    {
        var seq = new List<Instruction>();
        int args = callee.Parameters.Count + (callee.HasThis ? 1 : 0);
        for (int i = 0; i < args; i++) seq.Add(il.Create(OpCodes.Pop));
        var ret = callee.ReturnType;
        switch (ret.FullName)
        {
            case "System.Void": break;
            case "System.Boolean": case "System.Byte": case "System.SByte": case "System.Char":
            case "System.Int16": case "System.UInt16": case "System.Int32": case "System.UInt32":
                seq.Add(il.Create(OpCodes.Ldc_I4_0)); break;
            case "System.Int64": case "System.UInt64":
                seq.Add(il.Create(OpCodes.Ldc_I8, 0L)); break;
            case "System.Single": seq.Add(il.Create(OpCodes.Ldc_R4, 0f)); break;
            case "System.Double": seq.Add(il.Create(OpCodes.Ldc_R8, 0d)); break;
            case "System.IntPtr": case "System.UIntPtr":
                seq.Add(il.Create(OpCodes.Ldc_I4_0)); seq.Add(il.Create(OpCodes.Conv_I)); break;
            default:
                bool valueType = ret.IsValueType || (ret.Resolve() != null && ret.Resolve().IsValueType);
                if (ret.IsGenericParameter || valueType)
                {
                    var local = new VariableDefinition(ret);
                    m.Body.Variables.Add(local);
                    m.Body.InitLocals = true;
                    seq.Add(il.Create(OpCodes.Ldloca, local));
                    seq.Add(il.Create(OpCodes.Initobj, ret));
                    seq.Add(il.Create(OpCodes.Ldloc, local));
                }
                else seq.Add(il.Create(OpCodes.Ldnull));
                break;
        }
        if (seq.Count == 0) seq.Add(il.Create(OpCodes.Nop));
        ins.OpCode = seq[0].OpCode;
        ins.Operand = seq[0].Operand;
        var after = ins;
        for (int i = 1; i < seq.Count; i++)
        {
            il.InsertAfter(after, seq[i]);
            after = seq[i];
        }
    }

    public static int Run(string inDir, string outDir, string[] friends)
    {
        Directory.CreateDirectory(outDir);
        LoadRedirects(outDir);
        int patched = 0, copied = 0;
        foreach (string path in Directory.GetFiles(inDir))
        {
            string name = Path.GetFileName(path);
            string dest = Path.Combine(outDir, name);
            string lower = name.ToLowerInvariant();
            bool assembly = (lower.EndsWith(".dll") || lower.EndsWith(".exe")) && WmcTool.IsManaged(path);
            if (!assembly)
            {
                continue;
            }
            try
            {
                var asm = AssemblyDefinition.ReadAssembly(path, WmcTool.Reader(inDir));
                var notes = new List<string>();
                bool mixed = (asm.MainModule.Attributes & ModuleAttributes.ILOnly) == 0;
                int auto = WindowsCharSet(asm.MainModule);
                if (auto > 0) notes.Add(auto + " CharSet.Auto");
                AddFriends(asm, friends);
                int redirected = ApplyRedirects(asm.MainModule);
                if (redirected > 0) notes.Add(redirected + " calls redirected");
                if (mixed)
                {
                    int native = NeutraliseNativeCode(asm.MainModule);
                    notes.Add("mixed-mode: " + native + " native bodies removed");
                }
                asm.Write(dest);
                patched++;
                if (notes.Count > 0) Console.WriteLine("{0,-46} {1}", name, string.Join(", ", notes));
            }
            catch (Exception e)
            {
                Console.Error.WriteLine("{0,-46} FAILED {1}: {2}", name, e.GetType().Name, e.Message);
                File.Copy(path, dest, true);
                copied++;
            }
        }
        Console.WriteLine("{0} assemblies patched, {1} copied unchanged", patched, copied);
        foreach (string rule in s_rules.Distinct())
            if (!s_used.Contains(rule)) Console.WriteLine("rule matched nothing: " + rule);
        return 0;
    }

    // Our own assemblies (the host, the stand-ins) call into internal types the
    // way ehshell.dll does on Windows: by being named as friends.
    static void AddFriends(AssemblyDefinition asm, string[] friends)
    {
        var ctor = asm.MainModule.ImportReference(
            typeof(System.Runtime.CompilerServices.InternalsVisibleToAttribute).GetConstructor(new[] { typeof(string) }));
        foreach (string friend in friends)
        {
            var attr = new CustomAttribute(ctor);
            attr.ConstructorArguments.Add(new CustomAttributeArgument(asm.MainModule.TypeSystem.String, friend));
            asm.CustomAttributes.Add(attr);
        }
    }

    // On Windows NT, CharSet.Auto means UTF-16 and the "W" entry point. Mono
    // on Unix reads Auto as ANSI. Make the Windows meaning explicit.
    static int WindowsCharSet(ModuleDefinition module)
    {
        int n = 0;
        foreach (var type in WmcTool.AllTypes(module))
        {
            if ((type.Attributes & TypeAttributes.StringFormatMask) == TypeAttributes.AutoClass)
            {
                type.Attributes = (type.Attributes & ~TypeAttributes.StringFormatMask) | TypeAttributes.UnicodeClass;
            }
            foreach (var m in type.Methods)
            {
                if (!m.IsPInvokeImpl || m.PInvokeInfo == null) continue;
                var pi = m.PInvokeInfo;
                if (pi.IsCharSetAuto)
                {
                    pi.IsCharSetAuto = false;
                    pi.IsCharSetUnicode = true;
                    n++;
                }
            }
        }
        return n;
    }

    // C++/CLI assemblies carry x64 machine code beside their IL. That code
    // cannot run on Apple silicon, so methods implemented natively become
    // IL stubs that throw, and the module is marked IL-only so it loads.
    // Stand-ins replace the ones that matter (see managed/standins).
    static int NeutraliseNativeCode(ModuleDefinition module)
    {
        int n = 0;
        var notSupported = module.ImportReference(
            typeof(PlatformNotSupportedException).GetConstructor(new[] { typeof(string) }));
        foreach (var type in WmcTool.AllTypes(module))
        {
            foreach (var m in type.Methods)
            {
                // The module initialiser starts the C++ runtime (all native).
                // Without it the assembly's managed types still load.
                if (type.Name == "<Module>" && m.Name == ".cctor" && m.HasBody)
                {
                    StubBody(m);
                    n++;
                    continue;
                }
                bool native = (m.ImplAttributes & MethodImplAttributes.CodeTypeMask) == MethodImplAttributes.Native
                              || (m.ImplAttributes & MethodImplAttributes.Unmanaged) != 0;
                // C++/CLI also declares its own native functions as P/Invokes
                // into "this module" (no module name).
                bool self = m.IsPInvokeImpl && m.PInvokeInfo != null && string.IsNullOrEmpty(m.PInvokeInfo.Module.Name);
                if ((!native && !self) || m.IsAbstract) continue;
                if (m.IsPInvokeImpl && !self) continue;
                if (self)
                {
                    m.PInvokeInfo = null;
                    m.IsPInvokeImpl = false;
                }
                m.ImplAttributes &= ~(MethodImplAttributes.CodeTypeMask | MethodImplAttributes.Unmanaged
                                      | MethodImplAttributes.PreserveSig);
                m.ImplAttributes |= MethodImplAttributes.IL | MethodImplAttributes.Managed;
                m.Body = new MethodBody(m);
                var il = m.Body.GetILProcessor();
                il.Append(il.Create(OpCodes.Ldstr, "native code in " + module.Name + ": " + type.FullName + "::" + m.Name));
                il.Append(il.Create(OpCodes.Newobj, notSupported));
                il.Append(il.Create(OpCodes.Throw));
                n++;
            }
        }
        module.Attributes |= ModuleAttributes.ILOnly;
        module.Attributes &= ~ModuleAttributes.Required32Bit;
        module.Architecture = TargetArchitecture.I386;
        return n;
    }
}
