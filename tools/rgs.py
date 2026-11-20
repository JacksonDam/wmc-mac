#!/usr/bin/env python3
"""Registry scripts (.rgs): what a COM server built with ATL writes into the
registry when it is registered. Windows XP Media Center Edition 2005's
servers carry theirs as REGISTRY resources; its set-up ran them. This turns
them into .reg text for tools/setup_registry.py.

    rgs.py <file.dll> ...        prints the .reg lines for their scripts

The language, as ATL's registrar reads it:

    HKCR { NoRemove CLSID { ForceRemove {guid} = s 'Name' { val ThreadingModel = s 'Both' } } }

A key is a name (a word, a 'quoted string' or a {guid}), optionally with a
default value (= s 'text', = d 123, = b 'hex'), and a block of subkeys and
"val" values. NoRemove, ForceRemove and Delete only matter when a server is
unregistered (Delete keys are left out). %MODULE% is the server's own path;
a key or value that needs any other %NAME% (filled in by the server's code)
is left out.
"""
import os
import re
import sys

ROOTS = {
    "HKCR": "HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes",
    "HKEY_CLASSES_ROOT": "HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes",
    "HKLM": "HKEY_LOCAL_MACHINE",
    "HKEY_LOCAL_MACHINE": "HKEY_LOCAL_MACHINE",
}


def tokens(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c == "'":
            j, out = i + 1, []
            while j < n:
                if text[j] == "'" and j + 1 < n and text[j + 1] == "'":
                    out.append("'")
                    j += 2
                elif text[j] == "'":
                    break
                else:
                    out.append(text[j])
                    j += 1
            yield ("str", "".join(out))
            i = j + 1
        elif c == "{" and i + 1 < n and re.match(r"[0-9A-Fa-f]", text[i + 1]):
            j = text.index("}", i)
            yield ("word", text[i:j + 1])
            i = j + 1
        elif c in "{}=":
            yield (c, c)
            i += 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in "{}='":
                j += 1
            yield ("word", text[i:j])
            i = j


class Parser:
    def __init__(self, text, replacements):
        self.toks = list(tokens(text))
        self.pos = 0
        self.repl = replacements
        self.out = []          # (key path, {name: (kind, value)})

    def peek(self):
        return self.toks[self.pos] if self.pos < len(self.toks) else (None, None)

    def take(self):
        tok = self.peek()
        self.pos += 1
        return tok

    def fill(self, s):
        """s with %NAME%s replaced, or None if one is unknown."""
        def sub(m):
            if m.group(1) == "":
                return "%"
            if m.group(1).upper() in self.repl:
                return self.repl[m.group(1).upper()]
            raise KeyError(m.group(1))
        try:
            return re.sub(r"%(\w*)%", sub, s)
        except KeyError:
            return None

    def value(self):
        kind = self.take()[1].lower()
        data = self.take()[1]
        data = self.fill(data)
        if data is None:
            return None
        if kind == "s":
            return ("string", data)
        if kind == "d":
            v = int(data, 0) & 0xFFFFFFFF
            return ("int", str(v - (1 << 32) if v >= (1 << 31) else v))
        return None   # (b: binary values are not used by Media Center's servers)

    def block(self, path, values):
        """Reads up to the closing brace."""
        while True:
            kind, word = self.peek()
            if kind is None:
                return
            if kind == "}":
                self.take()
                return
            if kind == "word" and word.lower() == "val":
                self.take()
                name = self.fill(self.take()[1])
                self.take()   # =
                v = self.value()
                if name is not None and v is not None and path is not None:
                    values[name] = v
                continue
            self.key(path)

    def key(self, parent):
        kind, word = self.take()
        delete = False
        while kind == "word" and word.lower() in ("noremove", "forceremove", "delete"):
            delete = delete or word.lower() == "delete"
            kind, word = self.take()
        name = self.fill(word)
        path = None if parent is None or name is None or delete else parent + "\\" + name
        values = {}
        if self.peek()[0] == "=":
            self.take()
            v = self.value()
            if v is not None:
                values[""] = v
        if path is not None:
            self.out.append((path, values))
        if self.peek()[0] == "{":
            self.take()
            self.block(path, values)

    def parse(self):
        while self.peek()[0] is not None:
            kind, word = self.take()
            root = ROOTS.get(word.upper()) if kind == "word" else None
            if self.peek()[0] != "{":
                continue
            self.take()
            self.block(root, {})   # (an unknown root's keys are read and left out)
        return self.out


def reg_lines(keys):
    def q(s):
        return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')
    lines = []
    for path, values in keys:
        lines.append("")
        lines.append("[%s]" % path)
        for name, (kind, v) in sorted(values.items()):
            left = "@" if name == "" else q(name)
            if kind == "int":
                lines.append("%s=dword:%08x" % (left, int(v) & 0xFFFFFFFF))
            else:
                lines.append("%s=%s" % (left, q(v)))
    return lines


def scripts(path):
    """The REGISTRY resources of a Windows program, as text."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import peinfo
    try:
        res = peinfo.resources(path, named=True)
    except (ValueError, OSError, IndexError, KeyError, __import__("struct").error):
        return []
    out = []
    for _rid, data in sorted(res.get("REGISTRY", {}).items(), key=lambda kv: str(kv[0])):
        if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
            out.append(data.decode("utf-16"))
        else:
            out.append(data.decode("cp1252", "replace"))
    return out


def server_keys(path, windows_path):
    """The registry keys a server writes, with %MODULE% as windows_path."""
    repl = {"MODULE": windows_path, "MODULE_RAW": windows_path}
    keys = []
    for text in scripts(path):
        keys += Parser(text, repl).parse()
    return keys


def main():
    for path in sys.argv[1:]:
        keys = server_keys(path, "C:\\WINDOWS\\eHome\\" + os.path.basename(path))
        print("\n".join(reg_lines(keys)))


if __name__ == "__main__":
    main()
