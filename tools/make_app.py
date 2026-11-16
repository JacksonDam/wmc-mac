#!/usr/bin/env python3
"""Make a Mac app of Windows Media Center from your own copy of it.

    make_app.py <windows7.iso> [--output FOLDER] [--work FOLDER]
                [--name NAME] [--no-check]

--output     where the app goes (default: /Applications if you can write
             there, else ~/Applications). An app of the same name is replaced.
--work       where tools, the unpacked files and the build are kept between
             runs (default: ~/Library/Caches/Windows Media Center Builder).
--no-check   skip starting the finished app offscreen to check it.

Every step prints a line "step: <what>", and "progress: <0 to 1>" lines tell
how far the whole job is; a failure prints "error: <why>" and exits with
status 1. The tools it needs (7-Zip, Mono, Mono's picture
library) are downloaded into the work folder; clang and Python come with
Apple's Command Line Tools (tools/make_app.sh installs those first).
"""
import ctypes
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
sys.path.insert(0, TOOLS)
import peinfo  # noqa: E402

BUNDLE_ID = "local.wmc-mac.media-center"
MACOS_MIN = (11, 0)     # the oldest macOS the app runs on (Big Sur)


def step(text):
    print("step: " + text, flush=True)


class Bar:
    """How far the whole job is, for the installer's progress bar: each part
    has a weight (about its seconds on a first run), and a part that reports
    its own progress (the toolchain's downloads) moves within its share."""

    def __init__(self, parts):
        total = float(sum(w for _k, w in parts))
        self.start, self.share, at = {}, {}, 0.0
        for key, weight in parts:
            self.start[key], self.share[key] = at / total, weight / total
            at += weight
        self.key = None
        self.shown = -1.0

    def begin(self, key):
        self.key = key
        self.show(self.start[key])

    def within(self, fraction):
        if self.key:
            self.show(self.start[self.key] + self.share[self.key] * max(0.0, min(1.0, fraction)))

    def show(self, value):
        if value >= self.shown + 0.002 or value >= 1.0:
            self.shown = value
            print("progress: %.3f" % value, flush=True)


BAR = Bar([("tools", 1)])


def fail(text):
    print("error: " + text, flush=True)
    sys.exit(1)


CHILD = None
BACKGROUND = []


def stop(signum, _frame):
    """Stopped (the installer's Stop button): stop the tool running now too."""
    for job in BACKGROUND:
        job.stop()
    if CHILD and CHILD.poll() is None:
        try:
            os.killpg(CHILD.pid, signal.SIGTERM)    # the tool and everything it started
        except OSError:
            pass
    print("error: stopped", flush=True)
    sys.exit(1)


def run(cmd, env=None, quiet=False, substeps=False):
    """Runs a tool, passing its lines through; stops on failure. With
    substeps its own "step:" lines are shown as details under the current step."""
    global CHILD
    # Named in a failure: the script, for Python, else the tool.
    name = os.path.basename(next((a for a in cmd[1:] if a.endswith(".py")), cmd[1])
                            if cmd[0] == sys.executable else cmd[0])
    if cmd[0] == sys.executable:
        cmd = [cmd[0], "-B"] + cmd[1:]          # no .pyc files beside the scripts (they may be inside an app)
    p = CHILD = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                 errors="replace", start_new_session=True)
    tail = []
    for line in p.stdout:
        line = line.rstrip("\n")
        tail = (tail + [line])[-20:]
        if line.startswith("error: "):
            print(line, flush=True)
            sys.exit(1)
        if line.startswith("progress: "):
            try:
                BAR.within(float(line[10:]))
            except ValueError:
                pass
            continue
        if substeps and line.startswith("step: "):
            line = "  " + line[6:]
        if not quiet or line.startswith("step: "):
            print(line, flush=True)
    if p.wait() != 0:
        if quiet:
            print("\n".join(tail), flush=True)
        fail("%s failed" % name)


def default_output():
    if os.access("/Applications", os.W_OK):
        return "/Applications"
    return os.path.expanduser("~/Applications")


def unpack(installer, work, toolchain):
    """Unpacks Media Center (once per installer file) into <work>/source."""
    source = os.path.join(work, "source")
    st = os.stat(installer)
    stamp = "%s\t%d\t%d\n" % (os.path.abspath(installer), st.st_size, int(st.st_mtime))
    stamp_file = os.path.join(source, "stamp")
    if os.path.exists(stamp_file) and open(stamp_file).read() == stamp and \
            os.path.isdir(os.path.join(source, "tree", "ehome")):
        step("Media Center is already unpacked from this file")
        return source
    if os.path.isdir(source):
        shutil.rmtree(source)
    env = dict(os.environ, WMC_TOOLCHAIN=toolchain)
    if not installer.lower().endswith(".iso"):
        fail("expected a Windows 7 disc image (.iso)")
    run([sys.executable, "-I", os.path.join(TOOLS, "extract_iso.py"), installer, source], env=env)
    with open(stamp_file, "w") as f:
        f.write(stamp)
    return source


def build(source, work, toolchain, ffmpeg):
    """The build; the native part (which needs FFmpeg) last, so that FFmpeg's
    own build (started in the background at the beginning) has the longest
    time to finish."""
    env = dict(os.environ, WMC_TOOLCHAIN=toolchain, WMC_TREE=os.path.join(source, "tree"),
               WMC_BUILD=os.path.join(work, "build"))
    parts = [("tool", "Building the metadata tool"),
             ("gen", "Reading Media Center's interfaces"),
             ("patch", "Patching Media Center's assemblies"),
             ("refs", "Making reference copies"),
             ("standins", "Compiling the .NET stand-ins"),
             ("host", "Compiling the host program")]
    for i, (name, text) in enumerate(parts):
        step(text)
        BAR.within(i / float(len(parts)))
        run([sys.executable, "-I", os.path.join(TOOLS, "build.py"), name], env=env, quiet=True)
    BAR.begin("ffmpeg")
    ffmpeg.wait_for()
    BAR.begin("native")
    step("Compiling the stand-ins for Windows")
    run([sys.executable, "-I", os.path.join(TOOLS, "build.py"), "native"], env=env, quiet=True)
    return os.path.join(work, "build")


class FFmpegBuild:
    """tools/setup_toolchain.py's FFmpeg part, run in the background (it takes
    about 20 seconds the first time, and is needed only for the native part)."""

    EXPECTED = 31.0     # seconds, about, on a first run (alongside everything else)

    def __init__(self, toolchain, work):
        self.log = os.path.join(work, "ffmpeg-build.log")
        self.started = time.time()
        self.proc = subprocess.Popen([sys.executable, "-B", "-I", os.path.join(TOOLS, "setup_toolchain.py"),
                                      "--toolchain", toolchain, "--parts", "ffmpeg"],
                                     stdout=open(self.log, "w"), stderr=subprocess.STDOUT, start_new_session=True)

    def wait_for(self):
        if self.proc.poll() is None:
            step("Finishing FFmpeg (Windows Media and AVI playback)")
        while self.proc.poll() is None:
            BAR.within((time.time() - self.started) / self.EXPECTED)
            time.sleep(0.25)
        if self.proc.returncode != 0:
            lines = open(self.log, errors="replace").read().strip().splitlines()
            errors = [l[7:] for l in lines if l.startswith("error: ")]
            fail(errors[-1] if errors else "FFmpeg did not build (see %s)" % self.log)

    def stop(self):
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except OSError:
                pass


_libc = ctypes.CDLL(None, use_errno=True)


def clone(src, dst, *, follow_symlinks=True):
    """A copy that shares the file's blocks (APFS clonefile): instant, and no
    extra space until one of them changes. A plain copy where that cannot be."""
    try:
        if _libc.clonefile(os.fsencode(os.path.realpath(src)), os.fsencode(dst), 0) == 0:
            return dst
    except (AttributeError, OSError):
        pass
    return shutil.copy2(src, dst)


def copy_tree(src, dst, keep_links=False, skip=()):
    shutil.copytree(src, dst, symlinks=keep_links, ignore=shutil.ignore_patterns(*skip) if skip else None,
                    dirs_exist_ok=True, copy_function=clone)


def mono_runtime(toolchain, dst):
    """The parts of Mono that run programs (not its compilers or reference assemblies)."""
    mono = os.path.join(toolchain, "mono")
    os.makedirs(os.path.join(dst, "lib"))
    for lib in os.listdir(os.path.join(mono, "lib")):
        if lib.endswith(".dylib") and (lib.startswith(("libmonosgen-2.0", "libMonoPosixHelper", "libmono-native",
                                                       "libmono-btls-shared"))):
            src = os.path.join(mono, "lib", lib)
            if os.path.islink(src):
                os.symlink(os.readlink(src), os.path.join(dst, "lib", lib))
            else:
                clone(src, os.path.join(dst, "lib", lib))
    # Mono's compilers and command-line tools stay out: the app never runs them.
    tools = ("Microsoft.CodeAnalysis*", "csc.*", "csi.*", "vbc.*", "VBCSCompiler.*", "mcs.*", "sqlmetal.*",
             "mkbundle.*", "mdoc.*", "ikdasm.*", "monop.*", "al.exe*", "mono-symbolicate.*", "ilasm.*",
             "mono-api-*", "xbuild*", "resgen.*", "sgen.exe*", "gacutil.*", "MSBuild")
    copy_tree(os.path.join(mono, "lib", "mono", "4.5"), os.path.join(dst, "lib", "mono", "4.5"), keep_links=True,
              skip=tools)
    copy_tree(os.path.join(mono, "lib", "mono", "gac"), os.path.join(dst, "lib", "mono", "gac"), keep_links=True)
    copy_tree(os.path.join(mono, "etc"), os.path.join(dst, "etc"), keep_links=True)


def too_new(app):
    """The programs and libraries in the app that need a newer macOS than
    MACOS_MIN (each Mach-O file states the oldest it runs on)."""
    found = []
    for folder, _dirs, files in os.walk(app):
        for name in files:
            path = os.path.join(folder, name)
            if os.path.islink(path):
                continue
            with open(path, "rb") as f:
                magic = f.read(4)
            if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                continue
            out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout.split("\n")
            for i, line in enumerate(out):
                word = line.strip()
                if word in ("cmd LC_BUILD_VERSION", "cmd LC_VERSION_MIN_MACOSX"):
                    for follow in out[i + 1:i + 5]:
                        parts = follow.split()
                        if parts and parts[0] in ("minos", "version"):
                            need = tuple(int(x) for x in parts[1].split(".")[:2])
                            if need > MACOS_MIN:
                                found.append("%s (macOS %s)" % (os.path.relpath(path, app), parts[1]))
                            break
    return found


def make_icon(ehome, out_icns, scratch):
    """The app icon, from Media Center's own (in ehshell.dll)."""
    png = os.path.join(scratch, "icon.png")
    try:
        peinfo.icon_png(os.path.join(ehome, "ehshell.dll"), png)
    except (OSError, ValueError, KeyError, TypeError):
        return False
    iconset = os.path.join(scratch, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = "icon_%dx%d%s.png" % (size, size, "@2x" if scale == 2 else "")
            subprocess.run(["sips", "-z", str(px), str(px), png, "--out", os.path.join(iconset, name)],
                           check=True, capture_output=True)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out_icns], check=True, capture_output=True)
    return True


def assemble(name, source, build_dir, toolchain, work):
    step("Putting the app together")
    staging = os.path.join(work, "app")
    if os.path.isdir(staging):
        shutil.rmtree(staging)
    app = os.path.join(staging, name + ".app")
    contents = os.path.join(app, "Contents")
    res = os.path.join(contents, "Resources")
    os.makedirs(os.path.join(contents, "MacOS"))
    os.makedirs(res)

    # The launcher, linked against Mono's runtime library in the app.
    launcher = os.path.join(contents, "MacOS", name)
    r = subprocess.run(["clang", "-arch", "arm64", "-mmacosx-version-min=%d.%d" % MACOS_MIN, "-O2", "-Wall",
                        "-o", launcher, os.path.join(TOOLS, "app", "launcher.c"),
                        "-L" + os.path.join(toolchain, "mono", "lib"), "-lmonosgen-2.0",
                        "-Wl,-rpath,@executable_path/../Resources/mono/lib"], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr, flush=True)
        fail("the launcher did not compile")

    mono_runtime(toolchain, os.path.join(res, "mono"))
    copy_tree(os.path.join(toolchain, "libgdiplus", "lib"), os.path.join(res, "libgdiplus", "lib"), keep_links=True)
    copy_tree(os.path.join(toolchain, "libgdiplus", "etc"), os.path.join(res, "libgdiplus", "etc"))
    clone(os.path.join(build_dir, "libwmcshim.dylib"), os.path.join(res, "libwmcshim.dylib"))
    # FFmpeg is built into libwmcshim (for Windows Media files): its licence goes with it.
    os.makedirs(os.path.join(res, "Licenses"), exist_ok=True)
    shutil.copy(os.path.join(toolchain, "ffmpeg", "COPYING.LGPLv2.1"), os.path.join(res, "Licenses", "FFmpeg (LGPL 2.1).txt"))
    # Media Center's folder as built: patched assemblies, our programs, and
    # (through links in the build) the rest of its files, copied for real.
    copy_tree(os.path.join(build_dir, "app", "ehome"), os.path.join(res, "windows", "ehome"),
              skip=("WmcProbe.*",))

    # The library map, with the app's folder left as @RES@ for the launcher.
    config = open(os.path.join(build_dir, "gen", "mono.config")).read()
    config = config.replace(os.path.join(build_dir, "libwmcshim.dylib"), "@RES@/libwmcshim.dylib")
    config = config.replace(os.path.join(toolchain, "libgdiplus", "lib"), "@RES@/libgdiplus/lib")
    if build_dir in config or toolchain in config:
        fail("the library map still names a build folder")
    with open(os.path.join(res, "mono.config.in"), "w") as f:
        f.write(config)

    # The registry Media Center starts with (the launcher copies it on first start).
    run([sys.executable, "-I", os.path.join(TOOLS, "setup_registry.py"),
         os.path.join(source, "tree", "registry.reg"), os.path.join(res, "registry")], quiet=True)

    ehome = os.path.join(source, "tree", "ehome")
    has_icon = make_icon(ehome, os.path.join(res, "AppIcon.icns"), work)
    version = peinfo.version(os.path.join(ehome, "ehshell.dll")) or "0.0.0.0"
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": name,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": ".".join(version.split(".")[:3]),
        "CFBundleVersion": version,
        "LSMinimumSystemVersion": "%d.%d" % MACOS_MIN,
        "LSApplicationCategoryType": "public.app-category.entertainment",
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "Made on this Mac from your own copy of Windows Media Center.",
    }
    if has_icon:
        info["CFBundleIconFile"] = "AppIcon"
    with open(os.path.join(contents, "Info.plist"), "wb") as f:
        plistlib.dump(info, f)
    with open(os.path.join(contents, "PkgInfo"), "w") as f:
        f.write("APPL????")

    newer = too_new(app)
    if newer:
        fail("parts of the app need a newer macOS than %d.%d: %s" % (MACOS_MIN + (", ".join(newer[:5]),)))

    step("Signing the app for this Mac")
    r = subprocess.run(["codesign", "--force", "--deep", "--sign", "-", app], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr, flush=True)
        fail("signing failed")
    return app


def check(app, work):
    """Starts the app offscreen (no window, no focus) and looks at what it drew."""
    step("Checking that the app starts")
    shot = os.path.join(work, "check.png")
    data = os.path.join(work, "check-data")
    for p in (shot, data):
        if os.path.isdir(p):
            shutil.rmtree(p)
        elif os.path.exists(p):
            os.remove(p)
    name = os.path.splitext(os.path.basename(app))[0]
    # Without the launch animation, and a picture as soon as the start menu
    # has settled (native/splash/sp_window.m, WMC_STEPS).
    env = dict(os.environ, WMC_HEADLESS="1", WMC_MUTE="1", WMC_APP_DATA=data,
               WMC_STEPS="ready 60 0.5; snap %s; exit" % shot)
    log = os.path.join(work, "check.log")
    with open(log, "w") as f:
        p = subprocess.Popen([os.path.join(app, "Contents", "MacOS", name), "/nostartupanimation"], env=env,
                             stdout=f, stderr=subprocess.STDOUT)
        try:
            p.wait(timeout=90)
        except subprocess.TimeoutExpired:
            p.kill()
            fail("the app did not finish its check within 90 s (see %s)" % log)
    shutil.rmtree(data, ignore_errors=True)
    if not os.path.exists(shot) or os.path.getsize(shot) < 10000:
        fail("the app started but drew nothing (see %s)" % log)
    print("checked: the app starts and draws Media Center (%s)" % shot, flush=True)


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    args = sys.argv[1:]
    installer = None
    output = work = None
    name = "Windows Media Center"
    checking = True
    while args:
        a = args.pop(0)
        if a == "--output" and args:
            output = args.pop(0)
        elif a == "--work" and args:
            work = args.pop(0)
        elif a == "--name" and args:
            name = args.pop(0)
        elif a == "--no-check":
            checking = False
        elif a.startswith("--"):
            sys.exit(__doc__)
        else:
            installer = a
    if not installer:
        sys.exit(__doc__)
    installer = os.path.abspath(os.path.expanduser(installer))
    if not os.path.isfile(installer):
        fail("no such file: " + installer)
    output = os.path.abspath(os.path.expanduser(output or default_output()))
    work = os.path.abspath(os.path.expanduser(work or "~/Library/Caches/Windows Media Center Builder"))
    os.makedirs(work, exist_ok=True)
    os.makedirs(output, exist_ok=True)
    started = time.time()

    if not shutil.which("clang"):
        fail("clang is missing: install Apple's Command Line Tools (xcode-select --install), "
             "or run tools/make_app.sh, which does that first")
    toolchain = os.path.join(work, "toolchain")
    # The weights are about each part's seconds; parts already done (tools
    # downloaded, the disc unpacked) take next to none.
    global BAR
    have_tools = all(os.path.exists(os.path.join(toolchain, p)) for p in ("7zip/7zz", "mono/bin/mono", "libgdiplus/.complete"))
    have_ffmpeg = os.path.exists(os.path.join(toolchain, "ffmpeg", ".complete"))
    unpacked = os.path.exists(os.path.join(work, "source", "stamp"))
    # (FFmpeg builds in the background meanwhile: what is left of it after
    # the other parts is its share.)
    # The weights are the seconds each part took on a 10-core Mac.
    tools_s, unpack_s, build_s = (1.3 if have_tools else 10), (0.1 if unpacked else 3), 6
    BAR = Bar([("tools", tools_s), ("unpack", unpack_s), ("build", build_s),
               ("ffmpeg", 0.2 if have_ffmpeg else max(1, FFmpegBuild.EXPECTED - tools_s - unpack_s - build_s)),
               ("native", 1.7), ("assemble", 3.6), ("move", 0.5), ("check", 7 if checking else 0)])
    os.makedirs(toolchain, exist_ok=True)
    ffmpeg = FFmpegBuild(toolchain, work)
    BACKGROUND.append(ffmpeg)
    BAR.begin("tools")
    step("Getting the tools: 7-Zip, Mono and its picture library (and FFmpeg, alongside)")
    run([sys.executable, "-I", os.path.join(TOOLS, "setup_toolchain.py"), "--toolchain", toolchain,
         "--parts", "7zip,mono,gdiplus"], substeps=True)
    BAR.begin("unpack")
    source = unpack(installer, work, toolchain)
    BAR.begin("build")
    build_dir = build(source, work, toolchain, ffmpeg)
    BAR.begin("assemble")
    app = assemble(name, source, build_dir, toolchain, work)

    final = os.path.join(output, os.path.basename(app))
    BAR.begin("move")
    step("Moving the app to " + output)
    if os.path.lexists(final):
        shutil.rmtree(final) if os.path.isdir(final) and not os.path.islink(final) else os.remove(final)
    shutil.move(app, final)
    if checking:
        BAR.begin("check")
        check(final, work)
    BAR.show(1.0)
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _s, fs in os.walk(final) for f in fs
               if not os.path.islink(os.path.join(d, f)))
    print("made: %s (%.0f MB, %.0f s)" % (final, size / 1e6, time.time() - started), flush=True)


if __name__ == "__main__":
    main()
