#!/usr/bin/env python3
"""Build everything from an unpacked installer.

    build.py [step ...]          steps: tool gen native patch refs standins host  (default: all)

Inputs   work/wmc/tree/ehome      (from tools/extract_iso.py)
Outputs  build/tools/wmctool.exe   the metadata tool
         build/gen/                generated: native call list, protocol header,
                                   stubs, Mono configuration
         build/libwmcshim.dylib    the stand-in for the Windows libraries
         build/app/ehome/          patched assemblies, the installer's other
                                   files, and our host programs
         build/refs/               compile-time reference copies (all public)
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import peinfo  # noqa: E402
# WMC_TOOLCHAIN: another toolchain folder (see tools/setup_toolchain.py).
TOOLCHAIN = os.environ.get("WMC_TOOLCHAIN") or os.path.join(ROOT, "toolchain")
MONO_DIR = os.path.join(TOOLCHAIN, "mono")
MONO = os.path.join(MONO_DIR, "bin", "mono")
CSC = os.path.join(MONO_DIR, "lib", "mono", "4.5", "csc.exe")
CECIL = os.path.join(MONO_DIR, "lib", "mono", "gac", "Mono.Cecil",
                     "0.11.1.0__0738eb9f132ed756", "Mono.Cecil.dll")
# WMC_TREE and WMC_BUILD choose another unpacked installer and build folder.
TREE = os.environ.get("WMC_TREE") or os.path.join(ROOT, "work", "wmc", "tree")
EHOME = os.path.join(TREE, "ehome")
BUILD = os.environ.get("WMC_BUILD") or os.path.join(ROOT, "build")
GEN = os.path.join(BUILD, "gen")
APP = os.path.join(BUILD, "app", "ehome")
REFS = os.path.join(BUILD, "refs")
DYLIB = os.path.join(BUILD, "libwmcshim.dylib")
WMCTOOL = os.path.join(BUILD, "tools", "wmctool.exe")

FRAMEWORKS = ["Cocoa", "QuartzCore", "CoreText", "CoreGraphics", "ImageIO",
              "AVFoundation", "AudioToolbox", "CoreVideo", "CoreMedia", "IOSurface", "Metal", "Accelerate",
              "CoreServices"]

# Friends: our own assemblies that the patched copies let see their internals.
FRIENDS = ["WmcProbe", "WmcHost", "WmcStandins"]


# Generated base classes for COM stand-ins: (output, interop assembly, classes).
COM_BASES = [
    ("WmcComBases.dll", "ehiwmp.dll", [
        "PlayerBase=IWMPPlayer4+_WMPOCXEvents_Event+IWMPLibraryServices+IWMPPlayerServices2+IWMPFolderMonitorServices",
        "MediaBase=IWMPMedia3",
        "PlaylistBase=IWMPPlaylist",
        "MediaCollectionBase=IWMPMediaCollection2",
        "StringCollectionBase=IWMPStringCollection2",
        "QueryBase=IWMPQuery",
        "LibraryBase=IWMPLibrary2|IWMPLibrary",       # Vista: IWMPLibrary only
        "ControlsBase=IWMPControls3",
        "SettingsBase=IWMPSettings2",
        "NetworkBase=IWMPNetwork",
        "CdromCollectionBase=IWMPCdromCollection",
        "PlaylistCollectionBase=IWMPPlaylistCollection",
        "PlaylistArrayBase=IWMPPlaylistArray",
        "MetadataPictureBase=IWMPMetadataPicture",
        "ErrorBase=IWMPError",
        "PlayerApplicationBase=IWMPPlayerApplication",
    ]),
    # Vista's video player (managed/WmcStandins/Playback/VistaPlayer.cs);
    # Windows 7 has no ehiPlay.dll.
    ("WmcPlayBases.dll", "ehiPlay.dll", [
        "FilePlayerBase=IPlayer+IFilePlayer+IWmpOcxPlayer",
    ]),
]


def release():
    """Which Media Center the tree holds: "vista" (6.0) or "7" (6.1), from
    ehshell.dll's version."""
    names = os.listdir(EHOME) if os.path.isdir(EHOME) else []
    shell = next((n for n in names if n.lower() == "ehshell.dll"), None)
    return "vista" if shell and peinfo.version(os.path.join(EHOME, shell)).startswith("6.0.") else "7"


def csc_defines():
    """Our C# is compiled with VISTA defined for Vista's Media Center, whose
    assemblies lack some of the types Windows 7's stand-ins are built on."""
    return ["-define:VISTA"] if release() == "vista" else []


def run(cmd, **kw):
    r = subprocess.run(cmd, **kw)
    if r.returncode != 0:
        sys.exit("failed: " + " ".join(cmd[:4]) + " ...")


def newer(target, sources):
    if not os.path.exists(target):
        return True
    t = os.path.getmtime(target)
    return any(os.path.getmtime(s) > t for s in sources)


def sources(folder, exts):
    out = []
    for base, _dirs, files in os.walk(os.path.join(ROOT, folder)):
        for f in sorted(files):
            if f.endswith(exts) and not f.startswith("._"):
                out.append(os.path.join(base, f))
    return out


def step_tool():
    os.makedirs(os.path.dirname(WMCTOOL), exist_ok=True)
    src = sources("managed/wmctool", (".cs",))
    if newer(WMCTOOL, src):
        shutil.copy(CECIL, os.path.dirname(WMCTOOL))
        run([MONO, CSC, "-nologo", "-debug", "-r:" + CECIL, "-out:" + WMCTOOL] + src)
        print("built wmctool")


def step_gen():
    os.makedirs(GEN, exist_ok=True)
    run([MONO, WMCTOOL, "pinvokes", EHOME, os.path.join(GEN, "pinvokes.tsv")])
    run([MONO, WMCTOOL, "protocol", os.path.join(EHOME, "Microsoft.MediaCenter.UI.dll"),
         os.path.join(GEN, "splash_protocol.h")])
    run([sys.executable, "-I", os.path.join(ROOT, "tools", "gen_stubs.py"),
         os.path.join(GEN, "pinvokes.tsv"), os.path.join(GEN, "stubs.c"),
         os.path.join(GEN, "mono.config"), DYLIB])


# The oldest macOS the result runs on. Using anything newer without an
# @available check is an error, not a warning.
MACOS_MIN = "11.0"
# FFmpeg (tools/setup_toolchain.py builds it): Windows Media playback.
FFMPEG = os.path.join(TOOLCHAIN, "ffmpeg")
FFMPEG_LIBS = ["avformat", "avcodec", "swscale", "swresample", "avutil"]
CFLAGS = ["-arch", "arm64", "-O1", "-g", "-fvisibility=hidden",
          "-Wall", "-Wno-unused-function", "-Wno-deprecated-declarations",
          "-mmacosx-version-min=" + MACOS_MIN, "-Werror=unguarded-availability-new",
          "-I" + os.path.join(FFMPEG, "include")]


def step_native():
    objdir = os.path.join(BUILD, "obj")
    os.makedirs(objdir, exist_ok=True)
    srcs = sources("native", (".c", ".m")) + [os.path.join(GEN, "stubs.c"),
                                              os.path.join(GEN, "splash_protocol_names.c")]
    headers = sources("native", (".h",)) + [os.path.join(GEN, "splash_protocol.h")]
    # Different flags from last time: everything is compiled again.
    stamp = os.path.join(objdir, "flags")
    flags = " ".join(CFLAGS)
    if not os.path.exists(stamp) or open(stamp).read() != flags:
        for name in os.listdir(objdir):
            if name.endswith(".o"):
                os.remove(os.path.join(objdir, name))
    objs = []
    jobs = []
    for s in srcs:
        o = os.path.join(objdir, os.path.relpath(s, ROOT).replace(os.sep, "_") + ".o")
        objs.append(o)
        if newer(o, [s] + headers):
            cmd = ["clang", "-c"] + CFLAGS + [
                   "-I" + os.path.join(ROOT, "native", "core"), "-I" + os.path.join(ROOT, "native"),
                   "-I" + GEN, "-o", o, s]
            if s.endswith(".m"):
                cmd.insert(1, "-fobjc-arc")
            jobs.append((s, subprocess.Popen(cmd)))
    failed = [s for s, p in jobs if p.wait() != 0]
    if failed:
        sys.exit("native compile failed: " + ", ".join(os.path.basename(f) for f in failed))
    with open(stamp, "w") as f:
        f.write(flags)
    if not os.path.exists(os.path.join(FFMPEG, "lib", "libavcodec.a")):
        sys.exit("FFmpeg is missing from %s (run tools/setup_toolchain.py)" % TOOLCHAIN)
    link = ["clang", "-dynamiclib", "-arch", "arm64", "-mmacosx-version-min=" + MACOS_MIN,
            "-o", DYLIB, "-install_name", "@rpath/libwmcshim.dylib"] + objs
    link += [os.path.join(FFMPEG, "lib", "lib%s.a" % name) for name in FFMPEG_LIBS]
    for fw in FRAMEWORKS:
        link += ["-framework", fw]
    run(link)
    print("built libwmcshim.dylib (%d files, %d recompiled)" % (len(srcs), len(jobs)))


def step_standins():
    """Our own managed stand-ins, which patched assemblies call into. They are
    compiled against the patched assemblies (through the reference copies),
    so they can implement and use Media Center's own types."""
    os.makedirs(APP, exist_ok=True)
    src = sources(os.path.join("managed", "WmcStandins"), (".cs",))
    out = os.path.join(APP, "WmcStandins.dll")
    refs = [os.path.join(REFS, n) for n in sorted(os.listdir(REFS)) if n.lower().endswith(".dll")]
    if newer(out, src + refs):
        run([MONO, CSC, "-nologo", "-debug", "-unsafe", "-target:library", "-nowarn:1701,1702,0436,0618",
             "-out:" + out] + csc_defines() + ["-r:" + r for r in refs] + ["-r:System.Drawing.dll", "-r:System.Xml.dll", "-r:System.Core.dll"] + src)
        print("built WmcStandins.dll")


def step_patch():
    os.makedirs(APP, exist_ok=True)
    env = dict(os.environ, WMC_REDIRECTS=os.path.join(ROOT, "managed", "redirects.txt"), WMC_RELEASE=release())
    run([MONO, WMCTOOL, "patch", EHOME, APP] + FRIENDS, env=env)
    # Everything that is not a .NET assembly (resources, fonts, data) is used
    # as it is: link it into the app folder.
    for name in os.listdir(EHOME):
        src = os.path.join(EHOME, name)
        dst = os.path.join(APP, name)
        if os.path.lexists(dst):
            continue
        os.symlink(src, dst)


def step_refs():
    os.makedirs(REFS, exist_ok=True)
    jobs = []
    for name in sorted(os.listdir(APP)):
        if not name.lower().endswith((".dll", ".exe")):
            continue
        src = os.path.join(APP, name)
        if os.path.islink(src) or name.startswith("Wmc"):
            continue
        dst = os.path.join(REFS, name)
        if newer(dst, [src]):
            jobs.append(subprocess.Popen([MONO, WMCTOOL, "publicize", src, dst]))
            if len(jobs) >= (os.cpu_count() or 4):      # several at a time
                if jobs.pop(0).wait() != 0:
                    sys.exit("failed: publicize")
    if any(j.wait() != 0 for j in jobs):
        sys.exit("failed: publicize")
    # Skeletons of the COM interfaces that have managed stand-ins (see
    # managed/wmctool/bases.cs). Used at compile time and at run time.
    for out, interop, specs in COM_BASES:
        dst = os.path.join(REFS, out)
        src = os.path.join(REFS, interop)
        if not os.path.exists(src):
            continue            # not in this version of Media Center
        if newer(dst, [src, WMCTOOL]):
            run([MONO, WMCTOOL, "bases", src, dst] + specs)
        shutil.copy(dst, os.path.join(APP, out))
    print("reference copies in build/refs")


def step_host():
    refs = ["-r:" + os.path.join(REFS, n) for n in sorted(os.listdir(REFS))
            if n.lower().endswith(".dll")]
    refs += ["-r:" + os.path.join(APP, "WmcStandins.dll"), "-r:System.Drawing.dll", "-r:System.Xml.dll"]
    for name in ("WmcProbe", "WmcHost"):
        src = sources(os.path.join("managed", name), (".cs",))
        if not src:
            continue
        out = os.path.join(APP, name + ".exe")
        run([MONO, CSC, "-nologo", "-debug", "-unsafe", "-nowarn:1701,1702,0436,0618",
             "-out:" + out] + csc_defines() + refs + src)
        config = os.path.join(ROOT, "managed", name, "app.config")
        if os.path.exists(config):
            shutil.copy(config, out + ".config")
        print("built", name + ".exe")


STEPS = [("tool", step_tool), ("gen", step_gen), ("native", step_native),
         ("patch", step_patch), ("refs", step_refs), ("standins", step_standins),
         ("host", step_host)]


def main():
    wanted = sys.argv[1:] or [n for n, _ in STEPS]
    for name, fn in STEPS:
        if name in wanted:
            fn()


if __name__ == "__main__":
    main()
