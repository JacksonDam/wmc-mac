#!/usr/bin/env python3
"""Build the registry Media Center reads, from the .reg file tools/extract_iso.py writes.

    setup_registry.py <tree>/registry.reg <machine registry folder> [--first-run]
    setup_registry.py --file-types <machine registry folder>     (add the file-type keys to an existing one)

Mono keeps the registry as folders: one folder per key (lower case), with a
values.xml in each. This writes the installer's HKEY_LOCAL_MACHINE entries in
that form (and mirrors SOFTWARE\\Classes as HKEY_CLASSES_ROOT), then marks
Media Center's first-run set-up as completed, which is what the set-up wizard
writes when it finishes. With --first-run that mark is left out, so Media
Center starts with its Welcome screen and set-up wizard instead.
"""
import base64
import os
import re
import sys
from xml.sax.saxutils import escape


def parse_reg(text):
    """Yields (key path, {name: (type, value)}) for each [key] section."""
    lines = []
    for raw in text.splitlines():
        if lines and lines[-1].endswith("\\"):
            lines[-1] = lines[-1][:-1] + raw.strip()
        else:
            lines.append(raw.rstrip())
    key, values = None, {}
    for line in lines:
        if line.startswith("[") and line.endswith("]"):
            if key:
                yield key, values
            key, values = line[1:-1], {}
            if key.startswith("-"):
                key = None
            continue
        if key is None or "=" not in line:
            continue
        m = re.match(r'^(@|"(?:[^"\\]|\\.)*")=(.*)$', line)
        if not m:
            continue
        name = "" if m.group(1) == "@" else unescape(m.group(1)[1:-1])
        data = m.group(2).strip()
        if data.startswith('"'):
            values[name] = ("string", unescape(data[1:data.rindex('"')]))
        elif data.startswith("dword:"):
            v = int(data[6:], 16)
            values[name] = ("int", str(v - (1 << 32) if v >= (1 << 31) else v))
        elif data.startswith("hex"):
            kind, _, body = data.partition(":")
            blob = bytes(int(x, 16) for x in body.split(",") if x.strip())
            if kind == "hex(2)":
                values[name] = ("expand", blob.decode("utf-16-le", "replace").rstrip("\0"))
            elif kind == "hex(7)":
                parts = blob.decode("utf-16-le", "replace").split("\0")
                values[name] = ("string-array", [p for p in parts if p])
            elif kind == "hex(b)":
                values[name] = ("qword", str(int.from_bytes(blob[:8], "little")))
            else:
                values[name] = ("bytearray", base64.b64encode(blob).decode("ascii"))
    if key:
        yield key, values


def unescape(s):
    return re.sub(r"\\(.)", r"\1", s)


def write_key(root, hive, path, values):
    folder = os.path.join(root, hive, *[p.lower() for p in path.split("\\") if p])
    os.makedirs(folder, exist_ok=True)
    if not values:
        return
    out = ["<values>"]
    for name, (kind, value) in values.items():
        attr = escape(name, {'"': "&quot;"})
        if kind == "string-array":
            inner = "".join("<string>%s</string>" % escape(v) for v in value)
            out.append('<value name="%s"\ntype="string-array">%s</value>' % (attr, inner))
        else:
            out.append('<value name="%s"\ntype="%s">%s</value>' % (attr, kind, escape(value)))
    out.append("</values>")
    with open(os.path.join(folder, "values.xml"), "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")


# What Windows itself records about file types: the kind of each extension
# (Media Center decides from it what is a picture, a song or a video). Only
# the types that can be shown or played here are listed (Windows Media and
# AVI files through FFmpeg).
FILE_TYPES = {
    "image": {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".jpe": "image/jpeg", ".png": "image/png", ".gif": "image/gif",
              ".bmp": "image/bmp", ".tif": "image/tiff", ".tiff": "image/tiff", ".heic": "image/heic"},
    "audio": {".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/aac", ".wav": "audio/wav", ".aif": "audio/aiff",
              ".aiff": "audio/aiff", ".flac": "audio/flac", ".m4b": "audio/mp4", ".caf": "audio/x-caf",
              ".wma": "audio/x-ms-wma"},
    "video": {".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime", ".wmv": "video/x-ms-wmv",
              ".asf": "video/x-ms-asf", ".avi": "video/avi", ".divx": "video/divx"},
}


def write_file_types(root):
    """Adds the file-type keys if they are not there (safe to repeat)."""
    added = 0
    for kind, types in FILE_TYPES.items():
        for ext, mime in types.items():
            for hive, path in (("ClassesRoot", ext), ("LocalMachine", "SOFTWARE\\Classes\\" + ext)):
                folder = os.path.join(root, hive, *[p.lower() for p in path.split("\\") if p])
                if os.path.exists(os.path.join(folder, "values.xml")):
                    continue
                write_key(root, hive, path, {"PerceivedType": ("string", kind), "Content Type": ("string", mime)})
                added += 1
    return added


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    first_run = "--first-run" in sys.argv
    if len(args) == 1 and "--file-types" in sys.argv:
        write_file_types(args[0])
        return
    if len(args) != 2:
        sys.exit(__doc__)
    reg, root = args
    raw = open(reg, "rb").read()
    text = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("cp1252")
    count = 0
    for key, values in parse_reg(text):
        hive, _, path = key.partition("\\")
        if hive != "HKEY_LOCAL_MACHINE":
            continue
        write_key(root, "LocalMachine", path, values)
        count += 1
        if path.upper().startswith("SOFTWARE\\CLASSES\\"):
            write_key(root, "ClassesRoot", path[len("SOFTWARE\\Classes\\"):], values)

    settings = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Media Center\\Settings\\MCE.GlobalSettings"
    if first_run:
        write_key(root, "LocalMachine", settings, {})
    else:
        # What the set-up wizard records when it is finished (or skipped).
        write_key(root, "LocalMachine", settings, {
            "verFirstRun": ("int", "50"),
            "strPageFirstRun": ("string", ""),
        })
    write_file_types(root)
    print("%d registry keys under %s%s" % (count, root, " (first run pending)" if first_run else ""))


if __name__ == "__main__":
    main()
