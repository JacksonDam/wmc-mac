#!/usr/bin/env python3
"""Decompile every .NET assembly of an unpacked installer to C# for reading.

    decompile.py <tree>/ehome <output folder> [name-filter ...]

The output is reference material for writing the stand-ins. It is Microsoft's
code: it stays in work/ (ignored by git) and never goes in the repository.
"""
import os
import struct
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOTNET = os.path.join(ROOT, "toolchain", "dotnet", "dotnet")
ILSPY = os.path.join(ROOT, "toolchain", "dotnet-tools", "ilspycmd")


def is_managed(path):
    try:
        with open(path, "rb") as f:
            b = f.read(4096)
        if b[:2] != b"MZ":
            return False
        pe = struct.unpack_from("<I", b, 0x3C)[0]
        magic = struct.unpack_from("<H", b, pe + 24)[0]
        ddir = pe + 24 + (96 if magic == 0x10B else 112)
        return struct.unpack_from("<I", b, ddir + 14 * 8)[0] != 0
    except (OSError, struct.error):
        return False


def main():
    src, out = sys.argv[1], sys.argv[2]
    filters = [f.lower() for f in sys.argv[3:]]
    env = dict(os.environ)
    env.update({
        "DOTNET_ROOT": os.path.dirname(DOTNET),
        "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
        "DOTNET_NOLOGO": "1",
        "DOTNET_ROLL_FORWARD": "Major",
        "DOTNET_CLI_HOME": os.path.join(ROOT, "toolchain", "dotnet-home"),
        "NUGET_PACKAGES": os.path.join(ROOT, "toolchain", "nuget"),
    })
    names = []
    for name in sorted(os.listdir(src)):
        path = os.path.join(src, name)
        if not os.path.isfile(path) or not name.lower().endswith((".dll", ".exe")):
            continue
        if filters and not any(f in name.lower() for f in filters):
            continue
        if is_managed(path):
            names.append(name)

    def one(name):
        dest = os.path.join(out, os.path.splitext(name)[0])
        os.makedirs(dest, exist_ok=True)
        r = subprocess.run(
            [ILSPY, "-p", "--nested-directories", "-r", src, "-o", dest,
             os.path.join(src, name)],
            env=env, capture_output=True, text=True)
        count = sum(len([f for f in fs if f.endswith(".cs")]) for _, _, fs in os.walk(dest))
        return name, r.returncode, count, (r.stderr or r.stdout).strip()[-300:]

    with ThreadPoolExecutor(max_workers=10) as pool:
        for name, code, count, tail in pool.map(one, names):
            print("%-48s %s  %5d files%s" % (
                name, "ok  " if code == 0 else "FAIL", count,
                "" if code == 0 else "  " + tail.replace("\n", " | ")))


if __name__ == "__main__":
    main()
