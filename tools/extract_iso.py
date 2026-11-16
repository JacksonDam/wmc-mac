#!/usr/bin/env python3
"""Unpack Windows Media Center from a Windows 7 installation disc image (.iso).

    extract_iso.py <windows7.iso> <output folder>

Any Windows 7 disc whose editions include Media Center will do (Home
Premium, Professional, Ultimate, Enterprise; not Starter, Home Basic or the
N editions). The disc keeps Windows in sources/install.wim, one image per
edition. This takes Media Center's folder (Windows/ehome) and the registry
hive that holds its settings and COM registrations from the first edition
that has it, and writes:

    <out>/tree/ehome/         Media Center's files
    <out>/tree/registry.reg    its registry entries (from the SOFTWARE hive)
    <out>/info.txt            edition, architecture, language

The disc is mounted read-only and hidden if macOS allows it, so the 3 GB
install.wim is read in place; otherwise it is copied out first (the output
folder's disk then needs about 3.5 GB free while this runs).
"""
import glob
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import hive  # noqa: E402


def step(text):
    print("step: " + text, flush=True)


def fail(text):
    print("error: " + text, flush=True)
    sys.exit(1)


def find_7z():
    toolchain = os.environ.get("WMC_TOOLCHAIN") or os.path.join(ROOT, "toolchain")
    bundled = os.path.join(toolchain, "7zip", "7zz")
    if os.access(bundled, os.X_OK):
        return bundled
    for name in ("7zz", "7z", "7za"):
        path = shutil.which(name)
        if path:
            return path
    fail("7-Zip is needed (tools/setup_toolchain.py puts it in toolchain/7zip)")


def sevenzip(args, capture=True):
    r = subprocess.run([find_7z()] + args, capture_output=capture, text=True)
    if r.returncode != 0:
        lines = ((r.stderr or "") + (r.stdout or "")).strip().splitlines()
        fail("7-Zip failed" + (": " + lines[-1] if lines else ""))
    return r.stdout if capture else ""


def mount(iso):
    """Mounts the disc read-only and hidden; returns the mount point or None.
    (The mount point is in the system's temporary folder: macOS refuses one
    on an external disk.)"""
    where = tempfile.mkdtemp(prefix="wmc-iso.")
    try:
        r = subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen",
                            "-mountrandom", where, "-plist", iso], capture_output=True)
    except OSError:
        return None
    if r.returncode != 0:
        return None
    for entity in plistlib.loads(r.stdout).get("system-entities", []):
        if entity.get("mount-point"):
            return entity["mount-point"]
    return None


def unmount(point):
    subprocess.run(["hdiutil", "detach", "-quiet", point], capture_output=True)
    try:
        os.rmdir(os.path.dirname(point))
    except OSError:
        pass


def images_with_media_center(wim):
    out = sevenzip(["l", "-ba", "-ssc-", wim, "*/Windows/ehome/ehshell.exe"])
    found = []
    for line in out.splitlines():
        m = re.search(r"(\d+)[/\\]Windows[/\\]ehome[/\\]ehshell\.exe$", line, re.I)
        if m:
            found.append(int(m.group(1)))
    return sorted(set(found))


def edition_name(wim, index, scratch):
    """The image's name from the WIM's XML description ("Windows 7 HOMEPREMIUM")."""
    fallback = "image %d" % index
    try:
        r = subprocess.run([find_7z(), "x", "-y", "-o" + scratch, wim, "[1].xml"], capture_output=True)
        raw = open(os.path.join(scratch, "[1].xml"), "rb").read()
    except OSError:
        return fallback
    text = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8", "replace")
    m = re.search(r'<IMAGE INDEX="%d">(.*?)</IMAGE>' % index, text, re.S)
    name = re.search(r"<NAME>([^<]+)</NAME>", m.group(1)) if m else None
    return name.group(1) if name else fallback


def architecture(exe):
    with open(exe, "rb") as f:
        head = f.read(4096)
    pe = struct.unpack_from("<I", head, 0x3C)[0]
    machine = struct.unpack_from("<H", head, pe + 4)[0]
    return {0x8664: "x64", 0x14C: "x86"}.get(machine, "machine %#x" % machine)


def find_case(folder, *parts):
    """folder/parts, matching each part without regard to case."""
    path = folder
    for part in parts:
        names = os.listdir(path) if os.path.isdir(path) else []
        match = next((n for n in names if n.lower() == part.lower()), None)
        if match is None:
            return None
        path = os.path.join(path, match)
    return path


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    iso, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    if not os.path.isfile(iso):
        fail("no such file: " + iso)
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="wim.", dir=out)
    point = None
    try:
        step("Opening the disc image")
        point = mount(iso)
        wim = None
        if point:
            wim = find_case(point, "sources", "install.wim")
        if not wim:
            listing = sevenzip(["l", "-ba", iso, "sources/*"]).lower()
            if not re.search(r"sources/install\.wim$", listing, re.M):
                if re.search(r"\.(esd|swm)$", listing, re.M):
                    fail("this disc keeps Windows in a compressed or split image (install.esd/.swm); "
                         "a Windows 7 disc with sources/install.wim is needed")
                fail("no sources/install.wim: this does not look like a Windows 7 installation disc")
            if point:
                unmount(point)
                point = None
            free = shutil.disk_usage(out).free
            if free < 3.5e9:
                fail("the disc image could not be mounted, and copying its install.wim out needs about "
                     "3.5 GB free on the output disk (%.1f GB free)" % (free / 1e9))
            step("Copying install.wim out of the disc image (about 3 GB)")
            sevenzip(["x", "-y", "-o" + scratch, iso, "sources/install.wim"])
            wim = find_case(scratch, "sources", "install.wim")

        images = images_with_media_center(wim)
        if not images:
            fail("none of the editions on this disc includes Windows Media Center "
                 "(Starter, Home Basic and the N editions do not)")
        index = images[0]
        name = edition_name(wim, index, scratch)
        step("Unpacking Windows Media Center from %s" % name)
        unpacked = os.path.join(scratch, "x")
        sevenzip(["x", "-y", "-ssc-", "-o" + unpacked, wim,
                  "%d/Windows/ehome" % index, "%d/Windows/System32/config/SOFTWARE" % index])
        ehome = find_case(unpacked, str(index), "Windows", "ehome")
        software = find_case(unpacked, str(index), "Windows", "System32", "config", "SOFTWARE")
        if not ehome or not find_case(ehome, "ehshell.dll"):
            fail("Media Center's folder was not found in %s" % name)
        if not software:
            fail("the registry (SOFTWARE hive) was not found in %s" % name)

        tree = os.path.join(out, "tree")
        if os.path.isdir(tree):
            shutil.rmtree(tree)
        os.makedirs(tree)
        shutil.move(ehome, os.path.join(tree, "ehome"))
        ehome = os.path.join(tree, "ehome")

        step("Reading Media Center's registry entries")
        keys = hive.export(software, os.path.join(tree, "registry.reg"), ehome)

        arch = architecture(find_case(ehome, "ehshell.exe") or find_case(ehome, "ehshell.dll"))
        langs = sorted(n for n in os.listdir(ehome) if re.fullmatch(r"[a-z]{2,3}-[A-Za-z]{2,4}(-[A-Za-z]+)?", n)
                       and glob.glob(os.path.join(ehome, n, "ehres.dll.mui")))
        with open(os.path.join(out, "info.txt"), "w") as f:
            f.write("source\t%s\nedition\t%s\narchitecture\t%s\nlanguage\t%s\n"
                    % (os.path.basename(iso), name, arch, ",".join(langs)))
        files = sum(len(fs) for _d, _s, fs in os.walk(ehome))
        print("%d files and %d registry keys from %s (%s, %s)" % (files, keys, name, arch, ",".join(langs) or "?"))
    finally:
        if point:
            unmount(point)
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
