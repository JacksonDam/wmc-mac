"""Read a .NET assembly's metadata tables far enough to count its types and
methods and to list every P/Invoke (ImplMap) entry by native module."""
import struct
import sys
from collections import Counter, defaultdict


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def load(path):
    b = open(path, "rb").read()
    pe = u32(b, 0x3C)
    nsec = u16(b, pe + 6)
    opt = pe + 24
    magic = u16(b, opt)
    ddir = opt + (96 if magic == 0x10B else 112)
    sec = opt + u16(b, pe + 20)
    sections = []
    for i in range(nsec):
        s = sec + i * 40
        sections.append((u32(b, s + 12), u32(b, s + 8), u32(b, s + 20)))

    def off(rva):
        for va, vsize, raw in sections:
            if va <= rva < va + max(vsize, 1):
                return rva - va + raw
        raise ValueError("rva %x" % rva)

    cli = u32(b, ddir + 14 * 8)
    if not cli:
        return None
    md = off(u32(b, off(cli) + 8))
    vlen = u32(b, md + 12)
    p = md + 16 + vlen
    nstreams = u16(b, p + 2)
    p += 4
    streams = {}
    for _ in range(nstreams):
        so, ss = u32(b, p), u32(b, p + 4)
        p += 8
        e = b.index(b"\0", p)
        name = b[p:e].decode()
        p = (e + 4) & ~3
        streams[name] = (md + so, ss)
    return b, streams


TABLES = {
    0x00: ["2", "S", "G", "G", "G"],
    0x01: ["ResolutionScope", "S", "S"],
    0x02: ["4", "S", "S", "TypeDefOrRef", "t4", "t6"],
    0x03: ["t4"],
    0x04: ["2", "S", "B"],
    0x05: ["t6"],
    0x06: ["4", "2", "2", "S", "B", "t8"],
    0x07: ["t8"],
    0x08: ["2", "2", "S"],
    0x09: ["t2", "TypeDefOrRef"],
    0x0A: ["MemberRefParent", "S", "B"],
    0x0B: ["2", "HasConstant", "B"],
    0x0C: ["HasCustomAttribute", "CustomAttributeType", "B"],
    0x0D: ["HasFieldMarshal", "B"],
    0x0E: ["2", "HasDeclSecurity", "B"],
    0x0F: ["2", "4", "t2"],
    0x10: ["4", "t4"],
    0x11: ["B"],
    0x12: ["t2", "t20"],
    0x13: ["t20"],
    0x14: ["2", "S", "TypeDefOrRef"],
    0x15: ["t2", "t23"],
    0x16: ["t23"],
    0x17: ["2", "S", "B"],
    0x18: ["2", "t6", "HasSemantics"],
    0x19: ["t2", "MethodDefOrRef", "MethodDefOrRef"],
    0x1A: ["S"],
    0x1B: ["B"],
    0x1C: ["2", "MemberForwarded", "S", "t26"],
}

CODED = {
    "TypeDefOrRef": (2, [2, 1, 0x1B]),
    "HasConstant": (2, [4, 8, 0x17]),
    "HasCustomAttribute": (5, [6, 4, 1, 2, 8, 9, 0x0A, 0, 0x0E, 0x17, 0x14, 0x11,
                               0x1A, 0x1B, 0x20, 0x23, 0x26, 0x27, 0x28, 0x2A, 0x2C, 0x2B]),
    "HasFieldMarshal": (1, [4, 8]),
    "HasDeclSecurity": (2, [2, 6, 0x20]),
    "MemberRefParent": (3, [2, 1, 0x1A, 6, 0x1B]),
    "HasSemantics": (1, [0x14, 0x17]),
    "MethodDefOrRef": (1, [6, 0x0A]),
    "MemberForwarded": (1, [4, 6]),
    "CustomAttributeType": (3, [6, 0x0A]),
    "ResolutionScope": (2, [0, 0x1A, 0x23, 1]),
}


def analyse(path):
    loaded = load(path)
    if loaded is None:
        return None
    b, streams = loaded
    name = "#~" if "#~" in streams else "#-"
    t, _ = streams[name]
    heaps = b[t + 6]
    valid = struct.unpack_from("<Q", b, t + 8)[0]
    p = t + 24
    rows = {}
    for i in range(64):
        if valid >> i & 1:
            rows[i] = u32(b, p)
            p += 4
    ssz = 4 if heaps & 1 else 2
    gsz = 4 if heaps & 2 else 2
    bsz = 4 if heaps & 4 else 2

    def width(col):
        if col in ("2", "4"):
            return int(col)
        if col == "S":
            return ssz
        if col == "G":
            return gsz
        if col == "B":
            return bsz
        if col[0] == "t":
            return 4 if rows.get(int(col[1:]), 0) > 0xFFFF else 2
        bits, tables = CODED[col]
        biggest = max(rows.get(x, 0) for x in tables)
        return 4 if biggest >= (1 << (16 - bits)) else 2

    start = {}
    rowsize = {}
    for i in sorted(rows):
        if i not in TABLES:
            break
        rowsize[i] = sum(width(c) for c in TABLES[i])
        start[i] = p
        p += rowsize[i] * rows[i]

    sbase, _ = streams["#Strings"]

    def string(index):
        e = b.index(b"\0", sbase + index)
        return b[sbase + index:e].decode("utf-8", "replace")

    def read(o, w):
        return u32(b, o) if w == 4 else u16(b, o)

    modules = []
    for r in range(rows.get(0x1A, 0)):
        modules.append(string(read(start[0x1A] + r * rowsize[0x1A], ssz)))

    by_module = defaultdict(set)
    if 0x1C in start:
        fw = width("MemberForwarded")
        for r in range(rows[0x1C]):
            o = start[0x1C] + r * rowsize[0x1C]
            imp = string(read(o + 2 + fw, ssz))
            scope = read(o + 2 + fw + ssz, width("t26"))
            mod = modules[scope - 1] if 0 < scope <= len(modules) else "?"
            by_module[mod.lower()].add(imp)
    return rows, by_module


total = defaultdict(set)
for path in sys.argv[1:]:
    result = analyse(path)
    short = path.split("/")[-1]
    if result is None:
        print("%-44s not managed" % short)
        continue
    rows, by_module = result
    pinvokes = sum(len(v) for v in by_module.values())
    print("%-44s types %5d  methods %6d  native entry points %4d" % (
        short, rows.get(2, 0), rows.get(6, 0), pinvokes))
    for mod, names in by_module.items():
        total[mod] |= names

print()
print("Distinct native entry points called, by module:")
for mod, names in sorted(total.items(), key=lambda kv: -len(kv[1])):
    print("  %-28s %4d" % (mod, len(names)))
print("  %-28s %4d" % ("TOTAL", sum(len(v) for v in total.values())))
for want in ("ehui.dll", "ehuihlp.dll"):
    if want in total:
        print()
        print(want, "entry points:", ", ".join(sorted(total[want])))
