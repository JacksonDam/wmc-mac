#!/usr/bin/env python3
"""The icon and version of a Windows program, from its resources.

    peinfo.py version <file.exe|.dll>
    peinfo.py icon <file.exe> <out.png>      the largest image of its first icon

A Windows program keeps them in its resource section (.rsrc): a directory
tree of type -> name -> language -> data. Icons are RT_GROUP_ICON (14), a
list of sizes pointing at RT_ICON (3) images (PNG, or a bitmap); the version
is RT_VERSION (16), whose fixed part starts with the signature FEEF04BD.
"""
import os
import struct
import subprocess
import sys
import tempfile

RT_ICON, RT_GROUP_ICON, RT_VERSION = 3, 14, 16


def resources(path, named=False):
    """{type: {id: data}} for the program's numbered resources (first language
    of each). With named=True, named types and names are included too, as
    their upper-case strings ("REGISTRY")."""
    with open(path, "rb") as f:
        b = f.read()
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    opt_size = struct.unpack_from("<H", b, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", b, opt)[0]
    ddir = opt + (96 if magic == 0x10B else 112)
    rsrc_rva = struct.unpack_from("<I", b, ddir + 2 * 8)[0]
    sections = []
    for i in range(nsec):
        s = opt + opt_size + 40 * i
        vsize, va, rawsize, raw = struct.unpack_from("<IIII", b, s + 8)
        sections.append((va, max(vsize, rawsize), raw))

    def offset(rva):
        for va, size, raw in sections:
            if va <= rva < va + size:
                return raw + rva - va
        raise ValueError("address outside the file")

    if not rsrc_rva:
        return {}
    base = offset(rsrc_rva)

    def entries(at):
        count_named, ids = struct.unpack_from("<HH", b, base + at + 12)
        for i in range(count_named + ids):
            name, target = struct.unpack_from("<II", b, base + at + 16 + 8 * i)
            if name & 0x80000000:
                if not named:
                    yield None, target
                    continue
                at_name = base + (name & 0x7FFFFFFF)
                length = struct.unpack_from("<H", b, at_name)[0]
                name = b[at_name + 2:at_name + 2 + 2 * length].decode("utf-16-le", "replace").upper()
            yield name, target

    out = {}
    for rtype, t in entries(0):
        if rtype is None or not t & 0x80000000:
            continue
        for rid, n in entries(t & 0x7FFFFFFF):
            if rid is None or not n & 0x80000000:
                continue
            for _lang, leaf in entries(n & 0x7FFFFFFF):
                if leaf & 0x80000000:
                    continue
                rva, size = struct.unpack_from("<II", b, base + leaf)
                out.setdefault(rtype, {})[rid] = b[offset(rva):offset(rva) + size]
                break
    return out


def version(path):
    """"6.1.7601.17514", or "" if the file has no version."""
    data = next(iter(resources(path).get(RT_VERSION, {}).values()), b"")
    at = data.find(b"\xbd\x04\xef\xfe")
    if at < 0:
        return ""
    ms, ls = struct.unpack_from("<II", data, at + 8)
    return "%d.%d.%d.%d" % (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)


def icon_png(path, out_png):
    """Writes the largest image of the program's first icon as a PNG; returns its size."""
    res = resources(path)
    groups = res.get(RT_GROUP_ICON, {})
    if not groups:
        raise ValueError("no icon in " + path)
    group = groups[min(groups)]
    count = struct.unpack_from("<H", group, 4)[0]
    best = None
    for i in range(count):
        w, h, colors, _r, planes, bits, size, rid = struct.unpack_from("<BBBBHHIH", group, 6 + 14 * i)
        w, h = w or 256, h or 256
        key = (w * h, bits)
        if rid in res.get(RT_ICON, {}) and (best is None or key > best[0]):
            best = (key, w, h, colors, planes, bits, rid)
    _key, w, h, colors, planes, bits, rid = best
    image = res[RT_ICON][rid]
    if image[:8] == b"\x89PNG\r\n\x1a\n":
        with open(out_png, "wb") as f:
            f.write(image)
        return w
    # A bitmap: wrap it in a one-image .ico and let the Mac convert it.
    ico = struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", w % 256, h % 256, colors, 0, planes, bits,
                                                    len(image), 22) + image
    with tempfile.NamedTemporaryFile(suffix=".ico", delete=False) as t:
        t.write(ico)
    try:
        subprocess.run(["sips", "-s", "format", "png", t.name, "--out", out_png], check=True, capture_output=True)
    finally:
        os.unlink(t.name)
    return w


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "version":
        print(version(sys.argv[2]))
    elif len(sys.argv) == 4 and sys.argv[1] == "icon":
        print("%d px" % icon_png(sys.argv[2], sys.argv[3]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
