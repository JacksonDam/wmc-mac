#!/usr/bin/env python3
"""Fill a toolchain folder with what building Media Center for the Mac needs,
without Homebrew, an installer or administrator rights.

    setup_toolchain.py [--toolchain DIR] [--parts 7zip,mono,gdiplus,ffmpeg]   (default: <repo>/toolchain, all)

Makes:
    DIR/7zip/7zz                   7-Zip for macOS (reads Windows disc images and .wim files)
    DIR/mono/                      Mono 6.12.0.182: Homebrew's arm64 bottle, unpacked
    DIR/libgdiplus/lib/            Mono's GDI+ library (System.Drawing draws with it) and
                                   every library it loads, side by side, each finding the
                                   others next to itself (@loader_path)
    DIR/libgdiplus/etc/fonts/fonts.conf   a fontconfig configuration over the Mac's fonts
    DIR/ffmpeg/                    FFmpeg's libraries (LGPL), built here from its source with
                                   only what Windows Media and AVI files need, for playing
                                   what the Mac's own frameworks cannot

At run time FONTCONFIG_FILE must name DIR/libgdiplus/etc/fonts/fonts.conf: the
fontconfig library looks for its configuration under Homebrew's folder
otherwise, which is not there.

Mono and the libraries are Homebrew's builds for macOS 11 (Big Sur) on Apple
silicon, pinned as homebrew-core had them in July 2023 (commit 5884b29): the
same files on every Mac, and they run on macOS 11 and everything after it
(Homebrew builds current versions only for the latest few macOS versions).
Downloads (kept in DIR/dl) come from Homebrew's bottle store (ghcr.io) and
7-Zip's own release, and each is checked against its SHA-256. Parts already in place and working are left
alone, so running it again is cheap. Progress goes to stdout as "step: ..."
lines, and "progress: <0 to 1>" as the work goes; a failure prints
"error: ..." and exits with status 1. The downloads go in parallel, and
FFmpeg is built while the rest is unpacked.
"""
import concurrent.futures
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Homebrew's arm64_big_sur bottles, from homebrew-core at 5884b29 (2023-07-06):
# formula -> (version, SHA-256 of the bottle).
BOTTLE_URL = "https://ghcr.io/v2/homebrew/core/%s/blobs/sha256:%s"
MONO = ("6.12.0.182", "1a755293d5bd0b4d646c752be882493bbd272b8502998f78b673091a9a5e78e8")
PINNED = {
    "cairo": ("1.16.0_5", "2fc4da6029167f696fc0b3c0553d36abb8e77c75f0096396d4eb89d0ea912612"),
    "fontconfig": ("2.14.2", "5fea615f3524a847df9ea7e336a615fd4c8d9d8b2fb0e89b0e684173e6a1614c"),
    "freetype": ("2.13.1", "5aad113162129820c2926641a203db43139f0bf9dc2d7ae1b8f090ab29fb7011"),
    "fribidi": ("1.0.13", "d7c97dc2da426a3586d0c428f57d63300951ae23784769ebfdf3a4af0ab225f0"),
    "gettext": ("0.21.1", "90da957f7b8ad3d47fff7045a684060168e0433631921463fbbff09b5dc4b772"),
    "giflib": ("5.2.1", "e9a78b55a43f68f2552f845fff27d1c247ed865b1dd653f4c8ab259594411f86"),
    "glib": ("2.76.3", "bcb6039c3186acc3505258c48c0305a9b62e289821dd11490e4a9004ea923df7"),
    "graphite2": ("1.3.14", "544e2c344f6c0a7c2c3cb6541150f0d0d91cd1100460dac9c6a08578823f91c3"),
    "harfbuzz": ("7.3.0_1", "5374fcd4378d6561c4c213f69b7a41edbdd4e7d0739b37951b6efe53f0ffb915"),
    "jpeg-turbo": ("2.1.5.1", "9f88f50b6fb148d2edc5dd9138ee78e9d9c1a0f075e311b3a1398c6e43ca07df"),
    "libexif": ("0.6.24", "89e01320edd8d164b9a885c8f72b08215e175cece967f6c86a9bcf472e4d85bc"),
    "libpng": ("1.6.40", "bd0c0853926df0f1118b4b7f700ee7594cad881604fd76e711eeef1231700f50"),
    "libtiff": ("4.5.1", "760ba837679b14af360309108cdc3e682ddfed4c969ac1cec744927a7fcab67e"),
    "libx11": ("1.8.6", "5411fb6d4c702ee5413af825418e6157ca45f3d855710bcfc644bb0476cd207a"),
    "libxau": ("1.0.11", "1bd9a72f005e6d7e746a95baf003b561756076623a074d7ea9d6fd0207d15eff"),
    "libxcb": ("1.15_1", "42b2a0a1eee03d44c137195a485153f4a185bac30f64c5fffe28576fc8bbc611"),
    "libxdmcp": ("1.1.4", "3846fc5ceb4900e7bedb3ab6bcb8569f9beef52a60a6c2dfe3d16897ee7058f4"),
    "libxext": ("1.3.5", "232f1d192c14de36a9cb57dfedd73943d65fdd6ce3b75e80d4d0c2eb6c18dcd6"),
    "libxrender": ("0.9.11", "2ed6a16e43342c1a068a59c7f250111d88ef0f7d7e0ae7c935cb979f09542a57"),
    "mono-libgdiplus": ("6.1_2", "0d867f4956abbc40cbb77e02fa065e29f9b542cf62c241c8b9bdd63d1545386c"),
    "pango": ("1.50.14", "34d3bddaee4e322f64cb8a65763702d0037dd65f100772665b71a0ac108708d0"),
    "pcre2": ("10.42", "69483f445671a54f0e03f96b7ef41218913f793a84c32cf98de1e79aa029fbf1"),
    "pixman": ("0.42.2", "999830935fa581f1598d56834060bbfd8dbe818513ab39a1a15b1b5e0ef2afd9"),
    "xz": ("5.4.3", "f9d3283059582bf3eec0af86d8910e8409b0e1b092b7f018a9e7d6773f9ac4e4"),
    "zstd": ("1.5.5", "faf929cf92dad72eca2b16fb5aedb695f5d291aac18b496061b8b14003b2e224"),
}
MONO_VERSION = MONO[0]

FFMPEG_VERSION = "7.1.1"
FFMPEG_URL = "https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz"
FFMPEG_SHA256 = "733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"
# LGPL only (no --enable-gpl), static, for macOS 11: the formats the Mac's
# own frameworks cannot open. Windows Media (the ASF container: WMV, WMA) and
# AVI, with what AVI files usually carry: DivX and Xvid (MPEG-4 part 2),
# older DivX (MS-MPEG4), H.264, Motion JPEG, DV, MPEG-1/2, the old Windows
# codecs (Cinepak, Indeo, Microsoft Video 1 and RLE, uncompressed), and MP3,
# MP2, AC-3, AAC, PCM and ADPCM sound. (All FFmpeg's own LGPL decoders.)
FFMPEG_CONFIGURE = [
    "--cc=clang", "--arch=arm64", "--target-os=darwin",
    "--extra-cflags=-mmacosx-version-min=11.0", "--extra-ldflags=-mmacosx-version-min=11.0",
    "--disable-everything", "--disable-programs", "--disable-doc", "--disable-network",
    "--disable-autodetect", "--disable-debug", "--disable-shared", "--enable-static", "--enable-pic",
    "--disable-avdevice", "--disable-avfilter", "--enable-protocol=file", "--enable-demuxer=asf,avi",
    "--enable-decoder=wmv1,wmv2,wmv3,vc1,wmav1,wmav2,wmapro,wmalossless,wmavoice,"
    "msmpeg4v1,msmpeg4v2,msmpeg4v3,mpeg4,h264,mjpeg,dvvideo,mpeg1video,mpeg2video,"
    "cinepak,indeo3,indeo4,indeo5,msvideo1,msrle,rawvideo,"
    "mp3,mp3float,mp2,mp2float,ac3,aac,pcm_s16le,pcm_u8,pcm_s24le,adpcm_ms,adpcm_ima_wav",
    # (The HEVC parser is there for what it brings with it: FFmpeg 7.1.1's
    # H.264 decoder needs the film grain code only HEVC's SEI support builds.)
    "--enable-parser=vc1,mpegaudio,mpeg4video,h264,mjpeg,mpegvideo,ac3,aac,hevc",
]
FFMPEG_MAKE_STEPS = 408     # compile steps with this configuration (for the progress shown)

# Every download and its size in bytes (for the progress shown while they come).
SIZES = {
    "7z2606-mac.tar.xz": 965712, "ffmpeg-7.1.1.tar.xz": 11019500,
    "mono-6.12.0.182.arm64_big_sur.bottle.tar.gz": 140347488,
    "cairo": 1850450, "fontconfig": 647374, "freetype": 950666, "fribidi": 143990, "gettext": 9277226,
    "giflib": 155710, "glib": 6838782, "graphite2": 93108, "harfbuzz": 2413033, "jpeg-turbo": 849691,
    "libexif": 1044686, "libpng": 459758, "libtiff": 1792525, "libx11": 2247739, "libxau": 31204,
    "libxcb": 989047, "libxdmcp": 36037, "libxext": 107577, "libxrender": 53311, "mono-libgdiplus": 362168,
    "pango": 830660, "pcre2": 2084754, "pixman": 377610, "xz": 670800, "zstd": 814952,
}

SEVENZIP_VERSION = "26.06"
SEVENZIP_URL = "https://github.com/ip7z/7zip/releases/download/26.06/7z2606-mac.tar.xz"
SEVENZIP_SHA256 = "b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd"

USER_AGENT = "wmc-mac-setup"

FONTS_CONF = """<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- Written by tools/setup_toolchain.py: the Mac's own font folders. -->
<fontconfig>
  <dir>/System/Library/Fonts</dir>
  <dir>/Library/Fonts</dir>
  <dir prefix="xdg">fonts</dir>
  <dir>~/Library/Fonts</dir>
  <cachedir>~/Library/Caches/wmc-mac-fontconfig</cachedir>
  <match target="pattern">
    <test qual="any" name="family"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="same"><string>Helvetica</string></edit>
  </match>
  <match target="pattern">
    <test qual="any" name="family"><string>serif</string></test>
    <edit name="family" mode="prepend" binding="same"><string>Times</string></edit>
  </match>
  <match target="pattern">
    <test qual="any" name="family"><string>monospace</string></test>
    <edit name="family" mode="prepend" binding="same"><string>Menlo</string></edit>
  </match>
</fontconfig>
"""


class SetupError(Exception):
    pass


def step(text):
    print("step: " + text, flush=True)


# ---- downloads -----------------------------------------------------------------

def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, sha256, dest, progress=None):
    """dest, downloaded from url unless already there with the right SHA-256.
    progress(n) is told of each n bytes that arrive. The Mac's own curl
    fetches it (much faster than Python's urllib over HTTPS, and it does not
    pass Homebrew's Authorization header on to the storage host it is sent to)."""
    if os.path.exists(dest) and sha256_of(dest) == sha256:
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    part = dest + ".part"
    if os.path.exists(part):
        os.remove(part)
    cmd = ["/usr/bin/curl", "-sSfL", "--retry", "3", "-A", USER_AGENT, "-o", part, url]
    if urllib.parse.urlsplit(url).netloc == "ghcr.io":
        cmd[1:1] = ["-H", "Authorization: Bearer QQ=="]   # anonymous access to Homebrew's public bottles
    curl = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    seen = 0
    while curl.poll() is None:
        time.sleep(0.2)
        if progress and os.path.exists(part):
            size = os.path.getsize(part)
            if size > seen:
                progress(size - seen)
                seen = size
    if curl.returncode != 0:
        if os.path.exists(part):
            os.remove(part)
        raise SetupError("could not download %s: %s" % (url, curl.stderr.read().strip()))
    if progress and os.path.getsize(part) > seen:
        progress(os.path.getsize(part) - seen)
    got = sha256_of(part)
    if got != sha256:
        os.remove(part)
        raise SetupError("%s does not have the expected SHA-256 (got %s, expected %s)" % (url, got, sha256))
    os.replace(part, dest)
    return dest


# ---- Homebrew bottles ----------------------------------------------------------

def bottle(name, dl):
    """(path of the downloaded bottle, version) for one of the pinned formulae."""
    if name not in PINNED:
        raise SetupError("%s is needed but not among the pinned libraries" % name)
    version, sha = PINNED[name]
    path = os.path.join(dl, "%s-%s.arm64_big_sur.bottle.tar.gz" % (name, version))
    if not os.path.exists(path) or sha256_of(path) != sha:
        step("downloading %s %s" % (name, version))
    download(BOTTLE_URL % (name, sha), sha, path)
    return path, version


def tar_lib(bottle_path, basename):
    """The bytes of <formula>/<version>/lib/<basename> in a bottle, following
    symbolic links inside it; None if it is not there."""
    with tarfile.open(bottle_path, "r:gz") as t:
        members = {m.name: m for m in t.getmembers()}
        wanted = [n for n in members if n.endswith("/lib/" + basename) and n.count("/") == 3]
        if not wanted:
            return None
        name = wanted[0]
        for _ in range(16):
            m = members[name]
            if m.issym():
                name = os.path.normpath(os.path.join(os.path.dirname(name), m.linkname))
                if name not in members:
                    return None
                continue
            if not m.isfile():
                return None
            return t.extractfile(m).read()
    return None


# ---- Mach-O --------------------------------------------------------------------

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SetupError("%s failed: %s" % (os.path.basename(cmd[0]), (r.stderr or r.stdout).strip()))
    return r.stdout


def dylib_id(path):
    out = run(["otool", "-D", path]).splitlines()
    return out[1].strip() if len(out) > 1 else None


def dependencies(path):
    """The libraries a Mach-O file loads (its own id left out)."""
    own = dylib_id(path)
    deps = []
    for line in run(["otool", "-L", path]).splitlines()[1:]:
        dep = line.strip().split(" (compatibility")[0].strip()
        if dep and dep != own:
            deps.append(dep)
    return deps


def rpaths(path):
    out = run(["otool", "-l", path]).splitlines()
    found = []
    for i, line in enumerate(out):
        if line.strip() == "cmd LC_RPATH":
            for follow in out[i + 1:i + 4]:
                follow = follow.strip()
                if follow.startswith("path "):
                    found.append(follow[5:].split(" (offset")[0])
    return found


def provider(dep, referrer_formula):
    """(formula, basename) for a non-system library reference."""
    base = os.path.basename(dep)
    for marker in ("@@HOMEBREW_PREFIX@@/opt/", "/opt/homebrew/opt/"):
        if dep.startswith(marker):
            return dep[len(marker):].split("/")[0], base
    for marker in ("@@HOMEBREW_CELLAR@@/", "/opt/homebrew/Cellar/"):
        if dep.startswith(marker):
            return dep[len(marker):].split("/")[0], base
    if dep.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
        return referrer_formula, base
    raise SetupError("cannot tell where %s comes from" % dep)


def check_portable(lib_dir):
    """Every library refers only to the system or to its neighbours."""
    problems = []
    for name in sorted(os.listdir(lib_dir)):
        path = os.path.join(lib_dir, name)
        if not name.endswith(".dylib") or os.path.islink(path):
            continue
        for dep in dependencies(path):
            if dep.startswith(SYSTEM_PREFIXES):
                continue
            if dep.startswith("@loader_path/") and os.path.exists(os.path.join(lib_dir, dep[len("@loader_path/"):])):
                continue
            problems.append("%s -> %s" % (name, dep))
        for rp in rpaths(path):
            if "@@" in rp or rp.startswith("/opt/homebrew"):
                problems.append("%s rpath %s" % (name, rp))
        if "@@" in (dylib_id(path) or ""):
            problems.append("%s id" % name)
    return problems


# ---- the parts -----------------------------------------------------------------

def setup_7zip(tc):
    folder = os.path.join(tc, "7zip")
    exe = os.path.join(folder, "7zz")
    if os.path.exists(exe):
        r = subprocess.run([exe], capture_output=True, text=True)
        if SEVENZIP_VERSION in r.stdout:
            step("7-Zip %s is in place" % SEVENZIP_VERSION)
            return
    archive = download(SEVENZIP_URL, SEVENZIP_SHA256, os.path.join(tc, "dl", os.path.basename(SEVENZIP_URL)))
    step("unpacking 7-Zip")
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    run(["/usr/bin/tar", "-xf", archive, "-C", folder])
    r = subprocess.run([exe], capture_output=True, text=True)
    if SEVENZIP_VERSION not in r.stdout:
        raise SetupError("7-Zip does not run: " + (r.stderr or r.stdout).strip()[:200])


def mono_works(folder):
    exe = os.path.join(folder, "bin", "mono")
    needed = [exe, os.path.join(folder, "lib", "mono", "4.5", "csc.exe"),
              os.path.join(folder, "lib", "mono", "gac", "Mono.Cecil", "0.11.1.0__0738eb9f132ed756", "Mono.Cecil.dll")]
    if not all(os.path.exists(p) for p in needed):
        return False
    r = subprocess.run([exe, "--version"], capture_output=True, text=True)
    return r.returncode == 0 and ("version " + MONO_VERSION) in r.stdout


def setup_mono(tc):
    folder = os.path.join(tc, "mono")
    if mono_works(folder):
        step("Mono %s is in place" % MONO_VERSION)
        return
    dl = os.path.join(tc, "dl")
    path = download(BOTTLE_URL % ("mono", MONO[1]), MONO[1],
                    os.path.join(dl, "mono-%s.arm64_big_sur.bottle.tar.gz" % MONO_VERSION))
    step("unpacking Mono")
    partial = folder + ".partial"
    shutil.rmtree(partial, ignore_errors=True)
    os.makedirs(partial)
    run(["/usr/bin/tar", "-xzf", path, "-C", partial, "--strip-components", "2"])
    # The runtime needs no relocation: mono-sgen links only system libraries
    # and finds its own lib and etc folders next to itself. Its libraries'
    # ids still name Homebrew's folder; give them neutral ones.
    lib = os.path.join(partial, "lib")
    for name in os.listdir(lib):
        p = os.path.join(lib, name)
        if name.endswith(".dylib") and not os.path.islink(p) and "@@" in (dylib_id(p) or ""):
            os.chmod(p, 0o755)
            run(["install_name_tool", "-id", "@rpath/" + name, p])
            run(["codesign", "-f", "-s", "-", p])
    if not mono_works(partial):
        raise SetupError("the unpacked Mono does not run")
    shutil.rmtree(folder, ignore_errors=True)
    os.replace(partial, folder)


def setup_gdiplus(tc):
    folder = os.path.join(tc, "libgdiplus")
    lib_dir = os.path.join(folder, "lib")
    main = os.path.join(lib_dir, "libgdiplus.0.dylib")
    fonts = os.path.join(folder, "etc", "fonts", "fonts.conf")
    marker = os.path.join(folder, ".complete")
    # The marker names the pinned set the libraries came from: another set
    # (an older toolchain's) is replaced, even if it loads.
    fingerprint = "pinned " + hashlib.sha256(repr(sorted(PINNED.items())).encode()).hexdigest()[:16]
    current = open(marker).readline().strip() if os.path.exists(marker) else ""
    if current == fingerprint and os.path.exists(main) and not check_portable(lib_dir) and loads(main):
        write_fonts_conf(fonts)
        step("libgdiplus and its libraries are in place")
        return
    dl = os.path.join(tc, "dl")
    partial = folder + ".partial"
    shutil.rmtree(partial, ignore_errors=True)
    os.makedirs(partial)
    path, version = bottle("mono-libgdiplus", dl)
    step("unpacking libgdiplus %s" % version)
    run(["/usr/bin/tar", "-xzf", path, "-C", partial, "--strip-components", "2"])
    plib = os.path.join(partial, "lib")
    for name in os.listdir(plib):   # only the library itself (no static archive, pkg-config)
        p = os.path.join(plib, name)
        if name not in ("libgdiplus.0.dylib", "libgdiplus.dylib"):
            shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)

    # Walk what the library loads, and what those load, fetching each from
    # the bottle of the formula that provides it.
    owner = {"libgdiplus.0.dylib": "mono-libgdiplus"}
    queue = ["libgdiplus.0.dylib"]
    done = set()
    while queue:
        name = queue.pop(0)
        if name in done:
            continue
        done.add(name)
        for dep in dependencies(os.path.join(plib, name)):
            if dep.startswith(SYSTEM_PREFIXES):
                continue
            form, base = provider(dep, owner[name])
            if base not in owner:
                target = os.path.join(plib, base)
                if not os.path.exists(target):
                    bpath, _v = bottle(form, dl)
                    data = tar_lib(bpath, base)
                    if data is None:
                        raise SetupError("%s is not in the %s bottle" % (base, form))
                    with open(target, "wb") as f:
                        f.write(data)
                    os.chmod(target, 0o755)
                owner[base] = form
                queue.append(base)

    step("pointing %d libraries at each other" % len(owner))
    for name in sorted(owner):
        p = os.path.join(plib, name)
        os.chmod(p, 0o755)
        cmd = ["install_name_tool", "-id", "@rpath/" + name]
        for dep in dependencies(p):
            if not dep.startswith(SYSTEM_PREFIXES):
                cmd += ["-change", dep, "@loader_path/" + os.path.basename(dep)]
        for rp in rpaths(p):
            cmd += ["-delete_rpath", rp]
        run(cmd + [p])
        run(["codesign", "-f", "-s", "-", p])
    problems = check_portable(plib)
    if problems:
        raise SetupError("libraries still point outside the toolchain: " + "; ".join(problems[:5]))
    write_fonts_conf(os.path.join(partial, "etc", "fonts", "fonts.conf"))
    if not loads(os.path.join(plib, "libgdiplus.0.dylib")):
        raise SetupError("libgdiplus does not load")
    with open(os.path.join(partial, ".complete"), "w") as f:
        f.write(fingerprint + "\n" + "\n".join("%s\t%s" % (n, owner[n]) for n in sorted(owner)) + "\n")
    shutil.rmtree(folder, ignore_errors=True)
    os.replace(partial, folder)


def loads(path):
    """Whether the library and everything it loads can be loaded (in a child
    process, so a failure cannot take this one down)."""
    code = "import ctypes,sys; ctypes.CDLL(sys.argv[1]); print('ok')"
    r = subprocess.run([sys.executable, "-c", code, path], capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "ok"


def write_fonts_conf(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        with open(path) as f:
            if f.read() == FONTS_CONF:
                return
    with open(path, "w") as f:
        f.write(FONTS_CONF)


# ---- progress --------------------------------------------------------------------

class Progress:
    """The share of the work done, printed as "progress: x" lines (at most a
    few a second). Downloads are most of it on a first run."""

    def __init__(self):
        self.lock = threading.Lock()
        self.total = 1
        self.done = 0
        self.printed = 0

    def add(self, n):
        with self.lock:
            self.done += n
            now = time.time()
            if now - self.printed >= 0.25:
                self.printed = now
                print("progress: %.3f" % min(1.0, self.done / float(self.total)), flush=True)


PROGRESS = Progress()


def part_of(path):
    name = os.path.basename(path)
    if name.startswith("7z"):
        return "7zip"
    if name.startswith("ffmpeg"):
        return "ffmpeg"
    if name.startswith("mono-%s" % MONO_VERSION):
        return "mono"
    return "gdiplus"


def downloads(tc):
    """Every file the toolchain needs: (url, sha256, path, size)."""
    dl = os.path.join(tc, "dl")
    items = [(SEVENZIP_URL, SEVENZIP_SHA256, os.path.join(dl, os.path.basename(SEVENZIP_URL)), SIZES["7z2606-mac.tar.xz"]),
             (FFMPEG_URL, FFMPEG_SHA256, os.path.join(dl, os.path.basename(FFMPEG_URL)), SIZES["ffmpeg-7.1.1.tar.xz"]),
             (BOTTLE_URL % ("mono", MONO[1]), MONO[1],
              os.path.join(dl, "mono-%s.arm64_big_sur.bottle.tar.gz" % MONO_VERSION),
              SIZES["mono-6.12.0.182.arm64_big_sur.bottle.tar.gz"])]
    for name, (version, sha) in sorted(PINNED.items()):
        items.append((BOTTLE_URL % (name, sha), sha,
                      os.path.join(dl, "%s-%s.arm64_big_sur.bottle.tar.gz" % (name, version)), SIZES[name]))
    return items


def prefetch(tc, pool, parts):
    """Starts downloading whatever the parts need and is missing, several at a
    time: {path: future}."""
    items = [i for i in downloads(tc) if part_of(i[2]) in parts]
    # Downloads are half the work, unpacking 15% (three parts), building
    # FFmpeg 35% (about its share of the seconds on a fast connection).
    PROGRESS.total = int(sum(size for _u, _s, _p, size in items) * (2 if "ffmpeg" in parts else 1.25))
    missing = []
    for url, sha, path, size in items:
        if os.path.exists(path) and os.path.getsize(path) == size:
            PROGRESS.add(size)
        else:
            missing.append((url, sha, path, size))
    if not missing:
        return {}
    step("downloading %d files (%.0f MB)" % (len(missing), sum(m[3] for m in missing) / 1e6))
    # FFmpeg's source first: it is built while the rest arrives.
    missing.sort(key=lambda m: m[2] != os.path.join(tc, "dl", os.path.basename(FFMPEG_URL)))
    return {path: pool.submit(download, url, sha, path, PROGRESS.add) for url, sha, path, _size in missing}


def setup_ffmpeg(tc):
    folder = os.path.join(tc, "ffmpeg")
    marker = os.path.join(folder, ".complete")
    fingerprint = "%s %s" % (FFMPEG_VERSION, hashlib.sha256(" ".join(FFMPEG_CONFIGURE).encode()).hexdigest()[:16])
    if os.path.exists(marker) and open(marker).read().strip() == fingerprint and \
            os.path.exists(os.path.join(folder, "lib", "libavcodec.a")):
        step("FFmpeg %s is in place" % FFMPEG_VERSION)
        PROGRESS.add(int(PROGRESS.total * 0.35))
        return
    archive = download(FFMPEG_URL, FFMPEG_SHA256, os.path.join(tc, "dl", os.path.basename(FFMPEG_URL)))
    step("building FFmpeg %s (Windows Media and AVI playback)" % FFMPEG_VERSION)
    work = os.path.join(tc, "ffmpeg-build")
    partial = folder + ".partial"
    for d in (work, partial):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(work)
    run(["/usr/bin/tar", "-xf", archive, "-C", work])
    src = os.path.join(work, "ffmpeg-" + FFMPEG_VERSION)
    share = PROGRESS.total * 0.35
    r = subprocess.run(["./configure", "--prefix=" + partial] + FFMPEG_CONFIGURE, cwd=src, capture_output=True, text=True)
    if r.returncode != 0:
        raise SetupError("FFmpeg's configure failed: " + " | ".join((r.stdout + r.stderr).strip().splitlines()[-5:]))
    PROGRESS.add(int(share * 0.55))
    # make: about MAKE_STEPS steps ("CC ...", "AS ...") with this configuration.
    make = subprocess.Popen(["make", "-j%d" % (os.cpu_count() or 4)], cwd=src, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, errors="replace")
    tail, steps, per_step = [], 0, share * 0.45 / FFMPEG_MAKE_STEPS
    for line in make.stdout:
        tail = (tail + [line.strip()])[-5:]
        if line[:3] in ("CC\t", "AS\t", "AR\t"):
            steps += 1
            if steps <= FFMPEG_MAKE_STEPS:
                PROGRESS.add(int(per_step))
    if make.wait() != 0:
        raise SetupError("FFmpeg's make failed: " + " | ".join(tail))
    PROGRESS.add(int(per_step * max(0, FFMPEG_MAKE_STEPS - steps)))
    step("FFmpeg built (%d steps)" % steps)
    r = subprocess.run(["make", "install"], cwd=src, capture_output=True, text=True)
    if r.returncode != 0:
        raise SetupError("FFmpeg's make install failed: " + " | ".join((r.stdout + r.stderr).strip().splitlines()[-5:]))
    shutil.copy(os.path.join(src, "COPYING.LGPLv2.1"), os.path.join(partial, "COPYING.LGPLv2.1"))
    shutil.rmtree(os.path.join(partial, "share"), ignore_errors=True)
    shutil.rmtree(os.path.join(partial, "lib", "pkgconfig"), ignore_errors=True)
    with open(os.path.join(partial, ".complete"), "w") as f:
        f.write(fingerprint + "\n")
    shutil.rmtree(folder, ignore_errors=True)
    os.replace(partial, folder)
    shutil.rmtree(work, ignore_errors=True)


def prune_downloads(tc):
    """Removes downloads no longer part of the pinned set (an older toolchain's)."""
    dl = os.path.join(tc, "dl")
    keep = {os.path.basename(SEVENZIP_URL), os.path.basename(FFMPEG_URL),
            "mono-%s.arm64_big_sur.bottle.tar.gz" % MONO_VERSION}
    keep |= {"%s-%s.arm64_big_sur.bottle.tar.gz" % (n, v) for n, (v, _sha) in PINNED.items()}
    for name in os.listdir(dl) if os.path.isdir(dl) else []:
        if name not in keep and not name.endswith(".part"):   # (another run may be fetching it)
            os.remove(os.path.join(dl, name))


def main():
    args = sys.argv[1:]
    tc = os.path.join(ROOT, "toolchain")
    parts = ["7zip", "mono", "gdiplus", "ffmpeg"]
    while args:
        a = args.pop(0)
        if a == "--toolchain" and args:
            tc = os.path.abspath(args.pop(0))
        elif a == "--parts" and args:
            parts = args.pop(0).split(",")
        else:
            sys.exit(__doc__)
    if platform.machine() != "arm64":
        print("error: this needs a Mac with Apple silicon", flush=True)
        sys.exit(1)
    try:
        os.makedirs(tc, exist_ok=True)
        # FFmpeg is built (mostly on other cores) as soon as its source is
        # here, while the rest downloads and is unpacked.
        with concurrent.futures.ThreadPoolExecutor(8) as fetch, concurrent.futures.ThreadPoolExecutor(1) as build:
            pending = prefetch(tc, fetch, parts)
            ffmpeg = None
            if "ffmpeg" in parts:
                source = pending.get(os.path.join(tc, "dl", os.path.basename(FFMPEG_URL)))
                ffmpeg = build.submit(lambda: (source.result() if source else None, setup_ffmpeg(tc)))
            for f in pending.values():
                f.result()
            share = PROGRESS.total // 20        # each of the three unpacking parts: a twentieth
            for name, part in (("7zip", setup_7zip), ("mono", setup_mono), ("gdiplus", setup_gdiplus)):
                if name in parts:
                    part(tc)
                    PROGRESS.add(share)
            if ffmpeg:
                ffmpeg.result()                 # (it counts its own share)
        prune_downloads(tc)     # (keeps every pinned file, and what another run is fetching)
        print("progress: 1.000", flush=True)
    except SetupError as e:
        print("error: %s" % e, flush=True)
        sys.exit(1)
    except KeyboardInterrupt:
        print("error: stopped", flush=True)
        sys.exit(1)
    step("toolchain ready in %s (run with FONTCONFIG_FILE=%s)"
         % (tc, os.path.join(tc, "libgdiplus", "etc", "fonts", "fonts.conf")))


if __name__ == "__main__":
    main()
