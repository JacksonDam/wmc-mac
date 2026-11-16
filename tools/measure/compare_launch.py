#!/usr/bin/env python3
"""Compare the launch logo's size over time in a run of ours with the
reference recording (ref/video/reference.mp4).

    compare_launch.py <series folder> <run log>

Make the two inputs with a run at the recording's window size and both log
channels, e.g.

    tools/run.py --log series,anim --input "0.2 resize 1726 1080" \\
        --series build/shots/launch_hi --every 0.0333 --count 120 WmcHost > build/shots/launch_hi.log 2>&1

and the recording's frames with

    ffmpeg -ss 2 -t 7 -i ref/video/reference.mp4 -vf fps=30 ref/video/launch/f_%03d.png

The logo's lettering scales 3 -> 1 in the first second ("EaseIn, 2.0, 0.80"),
then 1 -> 0.85 by 2.2 s and -> 0.75 by 2.7 s in two straight segments. The
straight segments fix the recording's clock: the kink between them is at
2.2 s, which puts the animation's start at frame 38.1 of the extracted
frames, and the width at scale 1 at 881 pixels.
"""
import os
import re
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
VIDEO_FRAMES = os.path.join(ROOT, "ref", "video", "launch")
VIDEO_START = 38.1       # frame of the extracted set at which the launch animation starts
VIDEO_WIDTH_1 = 881.0    # the lettering's width at scale 1


def widths(folder, pattern, first, last):
    out = subprocess.run([sys.executable, "-I", os.path.join(HERE, "logo_width.py"), folder, pattern, str(first), str(last)],
                         capture_output=True, text=True, check=True).stdout
    table = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) > 3:
            table[int(p[0])] = float(p[3])
    return table


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    folder, log_path = sys.argv[1], sys.argv[2]
    log = open(log_path, errors="replace").read()
    start = re.search(r"\[(\d+\.\d+) anim\] play \S+ scale on \S+ \(now 1,1,1\) repeat 0 stop 2: 0.00s=3,3,1", log)
    if not start:
        sys.exit("no launch animation in the log (run with --log series,anim)")
    t0 = float(start.group(1))
    times = {int(m.group(2)): float(m.group(1)) - t0 for m in re.finditer(r"\[(\d+\.\d+) series\] frame (\d+) at", log)}
    frames = [f for f in sorted(times) if 0.5 < times[f] < 2.5]
    if not frames:
        sys.exit("no frames between 0.5 and 2.5 s of the launch")
    mine = widths(folder, "frame_%03d.png", frames[0], frames[-1])
    video = widths(VIDEO_FRAMES, "f_%03d.png", 55, 112)
    vt = np.array([(f - VIDEO_START) / 30 for f in sorted(video)])
    vs = np.array([video[f] / VIDEO_WIDTH_1 for f in sorted(video)])
    # our width at scale 1: where the first straight segment starts (t = 1.0)
    mt = np.array([times[f] for f in sorted(mine)])
    mw = np.array([mine[f] for f in sorted(mine)])
    straight = (mt > 1.1) & (mt < 2.1)
    slope, offset = np.polyfit(mt[straight], mw[straight], 1)
    width1 = slope * 1.0 + offset
    print("width at scale 1: ours %.1f, recording %.1f" % (width1, VIDEO_WIDTH_1))
    print("     t    ours  recording   diff")
    worst = 0.0
    for t, w in zip(mt, mw):
        if t < 0.57 or t > 2.45:
            continue
        v = float(np.interp(t, vt, vs))
        worst = max(worst, abs(w / width1 - v))
        print("%6.3f  %6.4f  %6.4f  %+7.4f" % (t, w / width1, v, w / width1 - v))
    print("largest difference in scale: %.4f" % worst)


if __name__ == "__main__":
    main()
