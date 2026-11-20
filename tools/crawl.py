#!/usr/bin/env python3
"""Open many places in Media Center, each in its own offscreen run, and report
what happened: did it stop, what exception, which unwritten functions were
reached, and a strip of frames (before, after, later, after Back).

    crawl.py [--jobs N] [--only NAME[,NAME...]] [--list] [--keep-going S] [--targets FILE] [--app APP]

A target is a name and the keys that reach it from the start menu, e.g.

    music.library      : enter
    tasks.settings     : down down down right enter
    settings.general   : down down down right enter enter

(`tools/crawl_targets.txt` is the default list.) `|` in the keys marks where
the "before" frame is taken; without it that is before the last key.
Results go to build/crawl/<name>/ and build/crawl/summary.txt, with one
picture per target in build/crawl/sheets/.

Each run waits for Media Center rather than the clock (WMC_STEPS in
native/splash/sp_window.m): it starts without the launch animation, and
after every key waits until Media Center has settled before the next. It
takes four frames: before the last key, 1.5 s after arriving, just before
Back (--keep-going S after arriving, default 3.5), and after Back.
--app crawls a made app (tools/make_app.py) instead of the development build.
"""
import concurrent.futures
import os
import site
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# WMC_BUILD and WMC_TREE: another build folder and unpacked installer (see build.py).
OUT = os.path.join(os.environ.get("WMC_BUILD") or os.path.join(ROOT, "build"), "crawl")
TREE = os.environ.get("WMC_TREE") or os.path.join(ROOT, "work", "wmc", "tree")
MEDIA = os.path.join(ROOT, "build", "fixtures", "media")
FRAMES = ("before", "after", "later", "back")
# Reached by every run (start-up and shut-down), so not worth repeating.
COMMON_STUBS = {"ehtrace.dll!ehUnregisterTraceGUIDs", "ehuihlp.dll!EhRegisterForWpcNotifications", "ehuihlp.dll!EhUnregisterForWpc",
                "ehuihlp.dll!WmdmCreateHelper", "ehuihlp.dll!WmdmRegisterCallback", "ntdll.dll!EtwNotificationRegister",
                "powrprof.dll!CallNtPowerInformation", "wtsapi32.dll!WTSUnRegisterSessionNotification"}
NOISE = re.compile(r"has no implementation yet|should have RVA data|BDATunePIA|^\s*$")


def load_targets(path):
    targets = []
    for line in open(path):
        line = line.split("#")[0].strip()
        if not line:
            continue
        name, keys = line.split(":", 1)
        targets.append((name.strip(), keys.split()))
    return targets


def pristine_drive():
    """A C:\\ as it is after installing: every run starts from a copy, so the
    keys always lead to the same place (Media Center remembers the last strip)."""
    folder = os.path.join(OUT, "_pristine")
    if not os.path.isdir(os.path.join(folder, "registry")):
        os.makedirs(os.path.join(folder, "home"), exist_ok=True)
        subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tools", "setup_registry.py"),
                        os.path.join(TREE, "registry.reg"), os.path.join(folder, "registry")], check=True)
    return folder


def steps_for(keys, frames, linger):
    """The step script for a target (see WMC_STEPS in native/splash/sp_window.m)."""
    def snap(which):
        return "snap " + os.path.join(frames, which + ".png")
    plain = [k for k in keys if k != "|"]
    marked = "|" in keys
    steps = ["ready"]
    inputs = 0
    for i, k in enumerate(keys):
        if k == "|":
            steps.append(snap("before"))
            continue
        if k.startswith("wait"):
            steps.append("wait %s" % (k[4:] or "1"))
            continue
        inputs += 1
        if not marked and inputs == len([p for p in plain if not p.startswith("wait")]):
            steps.append(snap("before"))
        if k.startswith("click@") or k.startswith("move@"):
            kind, pos = k.split("@")
            x, y = pos.split(",")
            steps.append("%s %s %s" % (kind, x, y))
        elif k.startswith("type="):
            steps += ["char %s" % ch for ch in k[5:]]
        else:
            steps.append("key %s" % k)
        # A wait written after a key is the target's own timing (a key while
        # a video plays, say): no settling then, which a video never does.
        if not (i + 1 < len(keys) and keys[i + 1].startswith("wait")):
            steps.append("settle")
    steps += ["wait 1.5", snap("after"), "wait %.1f" % max(0.0, linger - 1.5), snap("later"),
              "key back", "settle", snap("back"), "quit"]
    return steps


def run_target(name, keys, linger, app=None):
    folder = os.path.join(OUT, name)
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    frames_dir = os.path.join(folder, "frames")
    os.makedirs(frames_dir)
    steps = steps_for(keys, frames_dir, linger)
    log = os.path.join(folder, "log.txt")
    env = dict(os.environ)
    env["WMC_MEDIA_HOME"] = MEDIA     # a made-up Music/Pictures/Movies, not the user's own
    env["WMC_STEPS"] = "; ".join(steps)
    channels = "err,stub,todo,input,wmp,video,hang,steps"
    timeout = 90 + 6 * len(keys)
    drive = os.path.join(folder, "drive")
    if app:
        # The made app sets itself up in a data folder of its own (a fresh registry each time).
        name_ = os.path.splitext(os.path.basename(app))[0]
        cmd = [os.path.join(app, "Contents", "MacOS", name_), "/nostartupanimation"]
        env.update(WMC_APP_DATA=drive, WMC_HEADLESS="1", WMC_MUTE="1", WMC_LOG=channels)
    else:
        shutil.copytree(pristine_drive(), drive)
        cmd = [sys.executable, "-I", os.path.join(ROOT, "tools", "run.py"), "--drive", drive,
               "--log", channels, "WmcHost", "/nostartupanimation"]
    with open(log, "w") as f:
        try:
            r = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, env=env, timeout=timeout)
            code = r.returncode
        except subprocess.TimeoutExpired:
            code = "timeout after %d s" % timeout
    shutil.rmtree(drive, ignore_errors=True)
    frames = [os.path.join(frames_dir, w + ".png") for w in FRAMES if os.path.exists(os.path.join(frames_dir, w + ".png"))]
    text = open(log, errors="replace").read()
    lines = [l for l in text.splitlines() if not NOISE.search(l)]
    result = {"name": name, "code": code, "frames": len(frames), "expected": len(FRAMES)}
    # The innermost exception the host reported, or Mono's own crash report.
    # (Not the host's own last line: "Launch returned", "Main returned" on XP.)
    host = [i for i, l in enumerate(lines) if l.startswith("host: ") and "Launch returned" not in l
            and "Main returned" not in l]
    result["exception"] = ""
    if host:
        i = host[-1]
        result["exception"] = "\n".join(l[:230] for l in lines[i:i + 7])
    for marker in ("Unhandled Exception", "Native Crash Reporting", "SIGSEGV", "SIGABRT", "Assertion", "* Assertion"):
        if marker in text and not result["exception"]:
            i = next(i for i, l in enumerate(lines) if marker in l)
            result["exception"] = "\n".join(l[:230] for l in lines[i:i + 12])
    # What was reached after the start menu came up (by the order of the log).
    stubs, todos, boxes = [], [], []
    seen_before = set()
    startup = True
    # Times the UI thread left its input untaken (the watchdog in
    # native/core/threadq.c): finished ones in seconds, and whether one never ended.
    stalls, stalled = [], False
    for l in lines:
        m = re.match(r"\[(\d+\.\d+) (\w+)\] (.*)", l)
        if not m:
            continue
        kind, body = m.group(2), m.group(3)
        if kind == "input":
            startup = False
        if kind == "hang" and not startup:
            if "has not taken" in body:
                stalled = True
            elif "again after" in body and stalled:
                stalled = False
                stalls.append(float(re.search(r"after ([\d.]+) s", body).group(1)))
        if kind == "stub":
            fn = body.replace("UNIMPLEMENTED ", "").split(" (")[0]
            if startup:
                seen_before.add(fn)
            elif fn not in seen_before:
                stubs.append(fn)
        elif kind == "todo" and not startup:
            todos.append(body[:110])
        elif kind == "msgbox":
            boxes.append(body[:200])
    result["stalls"] = stalls
    result["frozen"] = stalled
    result["stubs"] = sorted(set(stubs))
    result["todos"] = sorted(set(todos))
    result["boxes"] = boxes
    result["managed"] = sorted(set(re.findall(r"(?:System\.)?\w*Exception: [^\n]{0,160}", "\n".join(lines))))[:6]
    picks = frames
    os.makedirs(os.path.join(OUT, "sheets"), exist_ok=True)
    sheet = os.path.join(OUT, "sheets", name + ".png")
    if picks:
        inputs = []
        for p in picks:
            inputs += ["-i", p]
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error"] + inputs + [
            "-filter_complex", "".join("[%d:v]scale=480:-1[s%d];" % (i, i) for i in range(len(picks))) +
            "".join("[s%d]" % i for i in range(len(picks))) + "hstack=inputs=%d" % len(picks) if len(picks) > 1 else "scale=480:-1",
            "-frames:v", "1", sheet])
    result["sheet"] = sheet if picks else ""
    return result


def overview(names, path, columns=3):
    """One picture of every target: the frame before the last key and the
    frame after arriving, with the target's name."""
    from PIL import Image, ImageDraw
    cells = []
    for n in names:
        sheet = os.path.join(OUT, "sheets", n + ".png")
        if not os.path.exists(sheet):
            continue
        im = Image.open(sheet).convert("RGB")
        h = im.height
        w = im.width // 4 if im.width >= 1920 else im.width
        cell = Image.new("RGB", (w * 2, h + 16), (40, 40, 40))
        cell.paste(im.crop((0, 0, w, h)), (0, 16))
        cell.paste(im.crop((im.width - 2 * w, 0, im.width - w, h)) if im.width >= 3 * w else im.crop((0, 0, w, h)), (w, 16))
        ImageDraw.Draw(cell).text((4, 2), n, fill=(255, 255, 0))
        cells.append(cell)
    if not cells:
        return
    w, h = cells[0].size
    rows = (len(cells) + columns - 1) // columns
    out = Image.new("RGB", (w * columns, h * rows))
    for i, c in enumerate(cells):
        out.paste(c, ((i % columns) * w, (i // columns) * h))
    out.save(path)


def describe(r):
    out = []
    state = "ok"
    if r["frames"] < r["expected"]:
        state = "STOPPED EARLY (%d of %d frames, exit %s)" % (r["frames"], r["expected"], r["code"])
    elif r["exception"]:
        state = "EXCEPTION"
    elif r["frozen"]:
        state = "FROZE (stopped taking input and never took it again)"
    out.append("== %-28s %s" % (r["name"], state))
    if r["stalls"]:
        out.append("   stalls: " + ", ".join("%.1f s" % s for s in r["stalls"]))
    if r["exception"]:
        lines = r["exception"].splitlines()
        # The exception, then the first frames of the trace that are Media Center's own.
        out.append("   " + lines[0][:200])
        own = [l.strip() for l in lines[1:] if l.strip().startswith("at ") and not l.strip().startswith("at System.")]
        out += ["     " + re.sub(r" \[0x[0-9a-f]+\] in .*", "", l)[:170] for l in own[:3]]
    for m in r["managed"]:
        if m not in r["exception"] and "TargetInvocationException" not in m:
            out.append("   seen: " + m)
    for b in r["boxes"]:
        out.append("   box: " + b)
    if r["stubs"]:
        out.append("   stubs: " + ", ".join(x for x in r["stubs"] if x not in COMMON_STUBS))
    if r["todos"]:
        out.append("   todo: " + "; ".join(r["todos"][:8]))
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    # Each run is mostly waiting for Media Center, not computing: one per
    # processor core (12 at a time were still faster than 8 on a 10-core Mac).
    jobs = os.cpu_count() or 8
    only = None
    app = None
    linger = 3.5
    path = os.path.join(ROOT, "tools", "crawl_targets.txt")
    while args:
        a = args.pop(0)
        if a == "--jobs":
            jobs = int(args.pop(0))
        elif a == "--only":
            only = args.pop(0).split(",")
        elif a == "--keep-going":
            linger = float(args.pop(0))
        elif a == "--targets":
            path = args.pop(0)
        elif a == "--app":
            app = os.path.abspath(args.pop(0))
        elif a == "--list":
            for name, keys in load_targets(path):
                print("%-28s %s" % (name, " ".join(keys)))
            return
        else:
            sys.exit(__doc__)
    targets = load_targets(path)
    if only:
        targets = [t for t in targets if any(t[0] == o or t[0].startswith(o + ".") or (o.endswith("*") and t[0].startswith(o[:-1])) for o in only)]
    os.makedirs(OUT, exist_ok=True)
    if not os.path.isdir(MEDIA):
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "make_fixtures.py")], check=True)
    if not app:
        pristine_drive()
    results = []
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        for r in pool.map(lambda t: run_target(t[0], t[1], linger, app), targets):
            results.append(r)
            print(describe(r), flush=True)
    with open(os.path.join(OUT, "summary.txt"), "w") as f:
        f.write("\n".join(describe(r) for r in results) + "\n")
    try:
        per = 18
        names = [r["name"] for r in results]
        for i in range(0, len(names), per):
            overview(names[i:i + per], os.path.join(OUT, "overview_%d.png" % (i // per)), 2)
    except ImportError:
        pass
    bad = [r["name"] for r in results if r["frames"] < r["expected"] or r["exception"] or r["frozen"]]
    print("\n%d targets, %d with a stop, an exception or a freeze: %s" % (len(results), len(bad), ", ".join(bad)))


if __name__ == "__main__":
    main()
