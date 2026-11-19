#!/usr/bin/env python3
r"""Read a Windows registry hive file and write Media Center's part of it as a .reg file.

    hive.py <SOFTWARE hive> <out.reg> [<ehome folder>]

A Windows 7 or Vista image carries its registry as hive files (Windows/System32/config).
Media Center's entries are in the SOFTWARE hive: its settings, and the COM
classes, interfaces, type libraries and file types its components registered.
This writes those, under HKEY_LOCAL_MACHINE\\SOFTWARE, as a .reg file for
tools/setup_registry.py. The names
of the files in Media Center's folder (ehome) help pick its COM classes.
The image was serviced as drive D:, so D:\ in paths becomes C:\.

The hive format: a 4 KB header, then "hbin" blocks of cells. A cell is a
32-bit size (negative while in use) and a record: "nk" a key, "vk" a value,
"lf"/"lh"/"li"/"ri" lists of subkeys, "db" a value too big for one cell.
Cell offsets count from the first hbin, at 0x1000.
"""
import os
import re
import struct
import sys

REG_SZ, REG_EXPAND_SZ, REG_BINARY, REG_DWORD, REG_MULTI_SZ, REG_QWORD = 1, 2, 3, 4, 7, 11


class Hive:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        if self.data[:4] != b"regf":
            raise ValueError("not a registry hive: " + path)
        self.root_offset = struct.unpack_from("<I", self.data, 0x24)[0]
        self.indexes = {}       # key offset -> {lower-case subkey name: Key}

    def cell(self, offset):
        """The record of the cell at offset (without its size field)."""
        at = 0x1000 + offset
        size = struct.unpack_from("<i", self.data, at)[0]
        return memoryview(self.data)[at + 4:at + abs(size)]

    def root(self):
        return Key(self, self.root_offset)


class Key:
    def __init__(self, hive, offset):
        self.hive = hive
        self.offset = offset
        rec = hive.cell(offset)
        if bytes(rec[:2]) != b"nk":
            raise ValueError("expected a key record at %#x" % offset)
        flags = struct.unpack_from("<H", rec, 2)[0]
        (self.nsub, ) = struct.unpack_from("<I", rec, 20)
        (self.sub_list, ) = struct.unpack_from("<I", rec, 28)
        self.nvalues, self.value_list = struct.unpack_from("<II", rec, 36)
        name_len = struct.unpack_from("<H", rec, 72)[0]
        raw = bytes(rec[76:76 + name_len])
        self.name = raw.decode("latin-1") if flags & 0x20 else raw.decode("utf-16-le", "replace")

    def subkeys(self):
        if not self.nsub or self.sub_list == 0xFFFFFFFF:
            return []
        out = []
        self._walk_list(self.sub_list, out)
        return out

    def _walk_list(self, offset, out):
        rec = self.hive.cell(offset)
        kind = bytes(rec[:2])
        count = struct.unpack_from("<H", rec, 2)[0]
        if kind in (b"lf", b"lh"):
            for i in range(count):
                out.append(Key(self.hive, struct.unpack_from("<I", rec, 4 + 8 * i)[0]))
        elif kind == b"li":
            for i in range(count):
                out.append(Key(self.hive, struct.unpack_from("<I", rec, 4 + 4 * i)[0]))
        elif kind == b"ri":
            for i in range(count):
                self._walk_list(struct.unpack_from("<I", rec, 4 + 4 * i)[0], out)
        else:
            raise ValueError("unknown subkey list %r" % kind)

    def subkey(self, name):
        # By name, from an index made once per key (Classes has tens of
        # thousands of subkeys, and the selection looks many of them up).
        index = self.hive.indexes.get(self.offset)
        if index is None:
            index = self.hive.indexes[self.offset] = {k.name.lower(): k for k in self.subkeys()}
        return index.get(name.lower())

    def path(self, path):
        k = self
        for part in path.split("\\"):
            if part:
                k = k.subkey(part) if k else None
        return k

    def values(self):
        """[(name, type, bytes)]"""
        if not self.nvalues or self.value_list == 0xFFFFFFFF:
            return []
        lst = self.hive.cell(self.value_list)
        out = []
        for i in range(self.nvalues):
            rec = self.hive.cell(struct.unpack_from("<I", lst, 4 * i)[0])
            if bytes(rec[:2]) != b"vk":
                continue
            name_len, size, data_off, vtype, flags = struct.unpack_from("<HIIIH", rec, 2)
            raw = bytes(rec[20:20 + name_len])
            name = raw.decode("latin-1") if flags & 1 else raw.decode("utf-16-le", "replace")
            if size & 0x80000000:                 # up to 4 bytes, kept in the offset field
                data = struct.pack("<I", data_off)[:size & 0x7FFFFFFF]
            elif size == 0:
                data = b""
            else:
                cell = self.hive.cell(data_off)
                if bytes(cell[:2]) == b"db" and size > 16344:
                    count, segs = struct.unpack_from("<HI", cell, 2)
                    seglist = self.hive.cell(segs)
                    parts = []
                    for j in range(count):
                        parts.append(bytes(self.hive.cell(struct.unpack_from("<I", seglist, 4 * j)[0])))
                    data = b"".join(parts)[:size]
                else:
                    data = bytes(cell[:size])
            out.append((name, vtype, data))
        return out

    def walk(self, prefix=""):
        """Yields (path, key) for this key and every key beneath it."""
        here = prefix + "\\" + self.name if prefix else self.name
        yield here, self
        for k in self.subkeys():
            yield from k.walk(here)


def text_of(vtype, data):
    if vtype in (REG_SZ, REG_EXPAND_SZ):
        return data.decode("utf-16-le", "replace").split("\0")[0]
    if vtype == REG_MULTI_SZ:
        return " ".join(data.decode("utf-16-le", "replace").split("\0"))
    return ""


def reg_value(name, vtype, data):
    """One line of a .reg file."""
    def quote(s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    lhs = "@" if name == "" else quote(name)
    if vtype == REG_SZ:
        return lhs + "=" + quote(data.decode("utf-16-le", "replace").split("\0")[0])
    if vtype == REG_DWORD and len(data) == 4:
        return lhs + "=dword:%08x" % struct.unpack("<I", data)[0]
    kind = {REG_BINARY: "hex", REG_EXPAND_SZ: "hex(2)", REG_MULTI_SZ: "hex(7)", REG_QWORD: "hex(b)"}.get(vtype, "hex(%x)" % vtype)
    return lhs + "=" + kind + ":" + ",".join("%02x" % b for b in data)


# --- Media Center's part of the SOFTWARE hive -------------------------------

# Strings that mark a COM registration as Media Center's: its folder, and its
# .NET assemblies registered through mscoree.
MARKS = ("\\ehome\\", "%windir%\\ehome", "microsoft.mediacenter", "ehshell", "ehiwmp", "mcstore", "ehrecobj",
         "ehiproxy", "ehiextens", "ehiuserxp", "ehiupnp", "ehivid", "mcplayerinterop", "mcglidhostobj", "mcx2dvcs",
         "ehcir")
# Media Center's own libraries that Windows 7 keeps in System32.
SYSTEM_FILES = {"mspbda.dll", "mcsrchph.dll", "mcmde.dll", "itvdata.dll", "cpfilters.dll", "encdec.dll"}
# ProgIDs of Media Center's classes that have no server entry of their own
# (its services provide them).
PROGID_PREFIXES = ("ehrecvr.", "ehsched.", "ehome.", "mediacenter.", "ehglid.", "ehmsas.", "irservice.")
SETTINGS = ["Microsoft\\Windows\\CurrentVersion\\Media Center"]
FILES = set()      # names of the files in Media Center's folder, lower case


def mentions_media_center(key):
    for _path, k in key.walk():
        for name, vtype, data in k.values():
            t = text_of(vtype, data).lower()
            if not t:
                continue
            if any(m in t for m in MARKS):
                return True
            if name == "" and k.name.lower() in ("inprocserver32", "localserver32"):
                base = t.strip('"').split('"')[0].replace("/", "\\").split("\\")[-1]
                if base in FILES or base in SYSTEM_FILES:
                    return True
            if name == "" and k.name.lower() in ("progid", "versionindependentprogid") and t.startswith(PROGID_PREFIXES):
                return True
    return False


def default_value(key, sub=""):
    k = key.path(sub) if sub else key
    if not k:
        return ""
    for name, vtype, data in k.values():
        if name == "":
            return text_of(vtype, data)
    return ""


def select(software):
    """The SOFTWARE subtrees that belong to Media Center (paths below SOFTWARE)."""
    classes = software.subkey("Classes")
    picked = []
    clsids = set()
    typelibs = set()
    for c in classes.subkey("CLSID").subkeys():
        if mentions_media_center(c):
            clsids.add(c.name.lower())
            picked.append("Classes\\CLSID\\" + c.name)
            for sub in ("ProgID", "VersionIndependentProgID"):
                prog = default_value(c, sub)
                if prog and classes.subkey(prog):
                    picked.append("Classes\\" + prog)
            appid = next((text_of(t, d) for n, t, d in c.values() if n.lower() == "appid"), "")
            if appid and classes.path("AppID\\" + appid):
                picked.append("Classes\\AppID\\" + appid)
            lib = default_value(c, "TypeLib")
            if lib:
                typelibs.add(lib.lower())
    # Programs named in AppID, and what they point at.
    appids = classes.subkey("AppID")
    for a in appids.subkeys():
        if a.name.lower() in FILES:
            picked.append("Classes\\AppID\\" + a.name)
            target = next((text_of(t, d) for n, t, d in a.values() if n.lower() == "appid"), "")
            if target and appids.subkey(target):
                picked.append("Classes\\AppID\\" + target)
    # DirectShow filter categories list Media Center's filters by class.
    for c in classes.subkey("CLSID").subkeys():
        inst = c.subkey("Instance")
        if inst:
            for i in inst.subkeys():
                if i.name.lower() in clsids:
                    picked.append("Classes\\CLSID\\%s\\Instance\\%s" % (c.name, i.name))
    for t in classes.subkey("TypeLib").subkeys():
        if t.name.lower() in typelibs or mentions_media_center(t):
            typelibs.add(t.name.lower())
            picked.append("Classes\\TypeLib\\" + t.name)
    for i in classes.subkey("Interface").subkeys():
        lib = default_value(i, "TypeLib").lower()
        proxy = default_value(i, "ProxyStubClsid32").lower()
        if lib in typelibs or (proxy in clsids):
            picked.append("Classes\\Interface\\" + i.name)
    # Media Center's own file types (.wtv, .dvr-ms, playlists) and their extensions.
    for k in classes.subkeys():
        n = k.name
        if n.lower().startswith(PROGID_PREFIXES + ("ehomedroptarget.",)):
            picked.append("Classes\\" + n)
        elif n.startswith(".") and default_value(k).lower().startswith("mediacenter."):
            picked.append("Classes\\" + n)
        elif n.startswith(".") and k.path("OpenWithList\\ehshell.exe"):
            picked.append("Classes\\%s\\OpenWithList\\ehshell.exe" % n)
    apps = classes.subkey("Applications")
    for a in apps.subkeys() if apps else []:
        if a.name.lower() in FILES:
            picked.append("Classes\\Applications\\" + a.name)
    for s in SETTINGS:
        if software.path(s):
            picked.append(s)
    # Each subtree once, parents before children.
    seen, out = set(), []
    for p in picked:
        if p.lower() not in seen:
            seen.add(p.lower())
            out.append(p)
    return out


def system_drive_c(vtype, data):
    """D:\\ (the drive the image was serviced as) becomes C:\\ in path values."""
    if vtype not in (REG_SZ, REG_EXPAND_SZ, REG_MULTI_SZ):
        return data
    text = data.decode("utf-16-le", "replace")
    fixed = re.sub(r"(?i)(?<![A-Za-z])D:\\", "C:\\\\", text)
    return fixed.encode("utf-16-le") if fixed != text else data


def export(hive_path, out_path, ehome=None):
    if ehome:
        FILES.update(n.lower() for n in os.listdir(ehome))
    software = Hive(hive_path).root()
    lines = ["Windows Registry Editor Version 5.00", ""]
    keys = 0
    for sub in select(software):
        k = software.path(sub)
        for path, key in k.walk():
            rel = sub.rsplit("\\", 1)[0] + "\\" + path if "\\" in sub else path
            lines.append("[HKEY_LOCAL_MACHINE\\SOFTWARE\\" + rel + "]")
            for name, vtype, data in key.values():
                lines.append(reg_value(name, vtype, system_drive_c(vtype, data)))
            lines.append("")
            keys += 1
    with open(out_path, "w", encoding="utf-16") as f:
        f.write("\r\n".join(lines) + "\r\n")
    return keys


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    n = export(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
    print("%d registry keys from %s" % (n, sys.argv[1]))


if __name__ == "__main__":
    main()
