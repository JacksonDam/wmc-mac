#!/usr/bin/env python3
"""Run one of the built host programs under the bundled Mono.

    run.py [--timeout SECONDS] [--log CHANNELS] [--show | --show-quiet]
           [--snapshot PNG [--after SECONDS]] [--series DIR [--every S] [--count N]]
           [--input SCRIPT] [--sound | --mute] [--first-run] [--drive DIR] [--trace-dll]
           <Program> [args ...]

    run.py WmcProbe tests/mcml/hello.mcml
    run.py --log all --timeout 20 WmcProbe

--show runs as a normal app (Dock icon, takes focus); without it the program
runs offscreen as an app macOS will not activate, so automated runs can
never take the focus.
--sound plays sound in an offscreen run (they are silent otherwise); --mute
silences a --show run. --first-run resets the registry so that Media Center
starts with its Welcome screen and set-up wizard.
--log sets WMC_LOG (stub, sp, msg, win, ... or all). --trace-dll turns on
Mono's own log of how each native call was resolved.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MONO = os.path.join(os.environ.get("WMC_TOOLCHAIN") or os.path.join(ROOT, "toolchain"), "mono", "bin", "mono")
# WMC_BUILD and WMC_TREE choose another build folder and unpacked installer (see build.py).
BUILD = os.environ.get("WMC_BUILD") or os.path.join(ROOT, "build")
TREE = os.environ.get("WMC_TREE") or os.path.join(ROOT, "work", "wmc", "tree")
APP = os.path.join(BUILD, "app", "ehome")
CONFIG = os.path.join(BUILD, "gen", "mono.config")


def main():
    args = sys.argv[1:]
    timeout = None
    env = dict(os.environ)
    mono_args = ["--debug", "--config", CONFIG]
    show = False
    first_run = False
    drive = None
    mute = True
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag == "--timeout":
            timeout = float(args.pop(0))
        elif flag == "--log":
            env["WMC_LOG"] = args.pop(0)
        elif flag == "--snapshot":
            # Render the window offscreen to a PNG after a delay, then quit.
            env["WMC_SNAPSHOT"] = os.path.abspath(args.pop(0))
            env["WMC_SNAPSHOT_EXIT"] = "1"
        elif flag == "--input":
            # Scripted input, e.g. "2 key down; 3 key right; 4 key enter; 5 click 400 300".
            env["WMC_INPUT"] = args.pop(0)
        elif flag == "--series":
            # Offscreen frames at a fixed interval into a folder, then quit.
            env["WMC_SERIES"] = os.path.abspath(args.pop(0))
        elif flag == "--every":
            env["WMC_SERIES_EVERY"] = args.pop(0)
        elif flag == "--count":
            env["WMC_SERIES_COUNT"] = args.pop(0)
        elif flag == "--show-quiet":
            # On screen, but without activating: for unattended checks.
            show = True
            env["WMC_NO_ACTIVATE"] = "1"
        elif flag == "--after":
            env["WMC_SNAPSHOT_AFTER"] = args.pop(0)
        elif flag == "--show":
            show = True
            mute = False
        elif flag == "--sound":
            mute = False
        elif flag == "--mute":
            mute = True
        elif flag == "--first-run":
            first_run = True
        elif flag == "--drive":
            # Another folder to stand for C:\\ (its registry and saved
            # settings), so that several runs do not share one.
            drive = os.path.abspath(args.pop(0))
        elif flag == "--trace-dll":
            env["MONO_LOG_LEVEL"] = "debug"
            env["MONO_LOG_MASK"] = "dll"
        else:
            sys.exit("unknown option " + flag)
    if not args:
        sys.exit(__doc__)
    program = os.path.join(APP, args[0] + ".exe")
    rest = [os.path.abspath(a) if os.path.exists(a) else a for a in args[1:]]
    env["WMC_WINDIR"] = os.path.join(BUILD, "app")          # stands for C:\\Windows
    env["WMC_DRIVE_C"] = drive or os.path.join(BUILD, "drive_c")     # stands for C:\\
    os.makedirs(env["WMC_DRIVE_C"], exist_ok=True)
    # Mono's registry lives in folders: the machine half where
    # MONO_REGISTRY_PATH says, the user half under HOME. Keep both (and so
    # everything Media Center saves) inside the project, not in the real home.
    home = os.path.join(env["WMC_DRIVE_C"], "home")
    machine = os.path.join(env["WMC_DRIVE_C"], "registry")
    os.makedirs(home, exist_ok=True)
    env.setdefault("WMC_MEDIA_HOME", os.path.expanduser("~"))   # the real Music, Pictures, Movies
    env["HOME"] = home
    # Lets .NET's Path class see "\\" as a separator, as on Windows (Media
    # Center builds many paths with it).
    env["MONO_IOMAP"] = "all"
    env["MONO_REGISTRY_PATH"] = machine
    if first_run and os.path.isdir(machine):
        import shutil
        shutil.rmtree(machine)
        shutil.rmtree(os.path.join(home, ".mono"), ignore_errors=True)
    if first_run:
        # (XP Media Center Edition 2002 keeps its first-run mark in its own settings file)
        try:
            os.remove(os.path.join(env["WMC_DRIVE_C"], "ProgramData", "Microsoft", "eHome", "ehshell.config"))
        except FileNotFoundError:
            pass
    if not os.path.isdir(machine):
        cmd = [sys.executable, "-I", os.path.join(ROOT, "tools", "setup_registry.py"),
               os.path.join(TREE, "registry.reg"), machine]
        if first_run:
            cmd.append("--first-run")
        subprocess.run(cmd, check=True)
    else:
        # A registry made by an earlier version: add what has been added since.
        subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tools", "setup_registry.py"), "--file-types", machine], check=True)
    if mute:
        env["WMC_MUTE"] = "1"
    if not show:
        # Test runs stay out of the Dock and never take focus from the user.
        env["WMC_HEADLESS"] = "1"
    try:
        r = subprocess.run([MONO] + mono_args + [program] + rest, env=env, timeout=timeout, cwd=APP)
        sys.exit(r.returncode)
    except subprocess.TimeoutExpired:
        print("run.py: stopped after %.0f s" % timeout, file=sys.stderr)
        sys.exit(124)


if __name__ == "__main__":
    main()
