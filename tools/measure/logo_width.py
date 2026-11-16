#!/usr/bin/env python3
"""Width of the launch logo's lettering ("Windows Media Center") in each
frame of a folder, to a fraction of a pixel: the lettering is the only
near-white thing in the lower middle of the picture.

    logo_width.py <folder> <pattern, e.g. f_%03d.png> <first> <last>

Prints: frame, left edge, right edge, width, centre y.
"""
import sys
import numpy as np
from PIL import Image


def edges(profile, level):
    """First and last crossing of `level`, between pixels."""
    above = np.nonzero(profile >= level)[0]
    if len(above) == 0:
        return None
    a, b = above[0], above[-1]
    left = float(a)
    if a > 0:
        left = a - (profile[a] - level) / max(profile[a] - profile[a - 1], 1e-6)
    right = float(b)
    if b + 1 < len(profile):
        right = b + (profile[b] - level) / max(profile[b] - profile[b + 1], 1e-6)
    return left, right


def measure(path):
    im = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    h, w, _ = im.shape
    white = im.min(axis=2)                       # high only where all of R, G, B are
    y0, y1 = int(h * 0.50), int(h * 0.95)
    band = white[y0:y1]
    # the lettering's rows: where many pixels are much whiter than the row's median
    excess = band - np.median(band, axis=1, keepdims=True)
    rows = (excess > 60).sum(axis=1)
    if rows.max() < 20:
        return None
    centre = int(np.argmax(np.convolve(rows, np.ones(15), "same")))
    top = centre
    while top > 0 and rows[top - 1] > 3:
        top -= 1
    bottom = centre
    while bottom + 1 < len(rows) and rows[bottom + 1] > 3:
        bottom += 1
    strip = excess[top:bottom + 1]
    profile = strip.max(axis=0)
    profile = np.convolve(profile, np.ones(3) / 3, "same")
    peak = np.percentile(profile, 99.5)
    e = edges(profile, peak * 0.5)
    if not e:
        return None
    return e[0], e[1], e[1] - e[0], y0 + (top + bottom) / 2.0, peak


def main():
    folder, pattern, first, last = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    for i in range(first, last + 1):
        m = measure("%s/%s" % (folder, pattern % i))
        if m:
            print("%d %.2f %.2f %.2f %.1f %.0f" % ((i,) + m))
        else:
            print("%d -" % i)


if __name__ == "__main__":
    main()
