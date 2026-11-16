#!/usr/bin/env python3
"""List (or extract) the Win32 resources inside a DLL from the installer.

    list_resources.py <file.dll>                       types with counts
    list_resources.py <file.dll> <TYPE>                names of one type
    list_resources.py <file.dll> <TYPE> <NAME> <out>   write one resource to a file

TYPE and NAME are strings as stored (upper case) or integers.
"""
import struct
import sys

TYPES = {1: "CURSOR", 2: "BITMAP", 3: "ICON", 4: "MENU", 5: "DIALOG", 6: "STRING", 9: "ACCELERATOR",
         10: "RCDATA", 11: "MESSAGETABLE", 12: "GROUP_CURSOR", 14: "GROUP_ICON", 16: "VERSION",
         23: "HTML", 24: "MANIFEST"}


class Pe:
    def __init__(self, path):
        self.b = open(path, "rb").read()
        b = self.b
        pe = struct.unpack_from("<I", b, 0x3C)[0]
        nsec = struct.unpack_from("<H", b, pe + 6)[0]
        opt = pe + 24
        magic = struct.unpack_from("<H", b, opt)[0]
        dirs = opt + (112 if magic == 0x20B else 96)
        sec = opt + struct.unpack_from("<H", b, pe + 20)[0]
        self.sections = []
        for i in range(nsec):
            s = sec + i * 40
            vsize, rva, rawsize, raw = struct.unpack_from("<IIII", b, s + 8)
            self.sections.append((rva, max(vsize, rawsize), raw))
        rsrc_rva = struct.unpack_from("<I", b, dirs + 16)[0]
        self.rsrc = self.off(rsrc_rva) if rsrc_rva else None

    def off(self, rva):
        for start, span, raw in self.sections:
            if start <= rva < start + span:
                return rva - start + raw
        raise ValueError("rva")

    def entries(self, dir_off):
        b = self.b
        base = self.rsrc + dir_off
        named, ids = struct.unpack_from("<HH", b, base + 12)
        out = []
        for i in range(named + ids):
            key, data = struct.unpack_from("<II", b, base + 16 + i * 8)
            if key & 0x80000000:
                s = self.rsrc + (key & 0x7FFFFFFF)
                n = struct.unpack_from("<H", b, s)[0]
                key = b[s + 2:s + 2 + n * 2].decode("utf-16le")
            out.append((key, data))
        return out

    def child(self, dir_off, key):
        for k, data in self.entries(dir_off):
            if str(k).upper() == str(key).upper() or (isinstance(k, int) and TYPES.get(k) == str(key).upper()):
                return data
        return None

    def data(self, leaf):
        rva, size = struct.unpack_from("<II", self.b, self.rsrc + leaf)
        o = self.off(rva)
        return self.b[o:o + size]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    pe = Pe(sys.argv[1])
    if pe.rsrc is None:
        sys.exit("no resources")
    if len(sys.argv) == 2:
        for key, data in pe.entries(0):
            name = TYPES.get(key, key) if isinstance(key, int) else key
            print("%-20s %d" % (name, len(pe.entries(data & 0x7FFFFFFF))))
        return
    t = pe.child(0, sys.argv[2])
    if t is None:
        sys.exit("no such type")
    if len(sys.argv) == 3:
        for key, data in pe.entries(t & 0x7FFFFFFF):
            langs = pe.entries(data & 0x7FFFFFFF)
            size = struct.unpack_from("<I", pe.b, pe.rsrc + langs[0][1] + 4)[0]
            print("%-60s %8d" % (key, size))
        return
    n = pe.child(t & 0x7FFFFFFF, sys.argv[3])
    if n is None:
        sys.exit("no such name")
    leaf = pe.entries(n & 0x7FFFFFFF)[0][1]
    blob = pe.data(leaf)
    if len(sys.argv) > 4:
        open(sys.argv[4], "wb").write(blob)
        print("%d bytes -> %s" % (len(blob), sys.argv[4]))
    else:
        sys.stdout.buffer.write(blob)


if __name__ == "__main__":
    main()
