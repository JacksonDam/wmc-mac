#!/usr/bin/env python3
"""Make a small media folder for tests: build/fixtures/media/{Music,Pictures,Movies}.

Everything is synthesised (tones, test patterns, drawn pictures), so the
tests never read anyone's real files. Needs ffmpeg and Pillow.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "fixtures", "media")

ALBUMS = [
    ("The Sine Waves", "First Light", "Electronic", 2019, (200, 60, 40),
     [("Dawn Chorus", 330, 14), ("Half Past Six", 392, 11), ("Open Window", 440, 12), ("Kettle", 494, 9)]),
    ("The Sine Waves", "Second Wind", "Electronic", 2021, (40, 120, 200),
     [("Uphill", 262, 10), ("Level Ground", 294, 13), ("Downhill", 349, 8)]),
    ("Quiet Machines", "Idle", "Ambient", 2020, (60, 160, 90),
     [("Standby", 220, 15), ("Screensaver", 247, 12), ("Fan Curve", 277, 10)]),
    ("Ada Lowell", "Paper Boats", "Folk", 2018, (210, 170, 60),
     [("Harbour", 523, 9), ("Tide Table", 587, 11)]),
]


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cover(path, colour, title, artist):
    from PIL import Image, ImageDraw
    im = Image.new("RGB", (600, 600), colour)
    d = ImageDraw.Draw(im)
    for i in range(0, 600, 40):
        shade = tuple(min(255, c + 40) for c in colour)
        d.line([(0, i), (600 - i, 600)], fill=shade, width=6)
    d.rectangle([40, 420, 560, 560], fill=(20, 20, 20))
    d.text((60, 440), title, fill=(255, 255, 255))
    d.text((60, 500), artist, fill=(200, 200, 200))
    im.save(path, quality=90)


def windows_media():
    """Files played with FFmpeg here: an album of WMA songs, a WMV video and an
    AVI video, named to sort after the others. Made if missing."""
    folder = os.path.join(OUT, "Music", "Willow Field", "Windfall")
    os.makedirs(folder, exist_ok=True)
    for n, (title, hz, seconds) in enumerate([("Gust", 370, 10), ("Calm", 415, 9)], 1):
        dest = os.path.join(folder, "%02d %s.wma" % (n, title))
        if not os.path.exists(dest):
            run(["ffmpeg", "-y", "-f", "lavfi", "-i", "sine=frequency=%d:duration=%d" % (hz, seconds),
                 "-metadata", "title=" + title, "-metadata", "artist=Willow Field", "-metadata", "album=Windfall",
                 "-metadata", "album_artist=Willow Field", "-metadata", "genre=Ambient",
                 "-metadata", "track=%d" % n, "-metadata", "date=2022", "-c:a", "wmav2", "-b:a", "128k", dest])
    dest = os.path.join(OUT, "Movies", "Waterfall.wmv")
    if not os.path.exists(dest):
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        run(["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30", "-f", "lavfi",
             "-i", "sine=frequency=523", "-t", "12", "-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "128k",
             "-shortest", dest])
    # An AVI as most are: MPEG-4 (Xvid) pictures with MP3 sound.
    dest = os.path.join(OUT, "Movies", "Windmill.avi")
    if not os.path.exists(dest):
        run(["ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25", "-f", "lavfi",
             "-i", "sine=frequency=440", "-t", "12", "-c:v", "mpeg4", "-vtag", "XVID", "-q:v", "4",
             "-c:a", "libmp3lame", "-b:a", "128k", "-shortest", dest])


def main():
    if os.path.isdir(OUT) and "--force" not in sys.argv:
        windows_media()
        print("fixtures already in", OUT)
        return
    music = os.path.join(OUT, "Music")
    for artist, album, genre, year, colour, tracks in ALBUMS:
        folder = os.path.join(music, artist, album)
        os.makedirs(folder, exist_ok=True)
        art = os.path.join(folder, "cover-source.jpg")
        cover(art, colour, album, artist)
        for n, (title, hz, seconds) in enumerate(tracks, 1):
            ext = "m4a" if n % 2 == 0 else "mp3"
            dest = os.path.join(folder, "%02d %s.%s" % (n, title, ext))
            cmd = ["ffmpeg", "-y", "-f", "lavfi", "-i", "sine=frequency=%d:duration=%d" % (hz, seconds), "-i", art,
                   "-map", "0:a", "-map", "1:v", "-c:v", "mjpeg", "-disposition:v", "attached_pic",
                   "-metadata", "title=" + title, "-metadata", "artist=" + artist, "-metadata", "album=" + album,
                   "-metadata", "album_artist=" + artist, "-metadata", "genre=" + genre,
                   "-metadata", "track=%d/%d" % (n, len(tracks)), "-metadata", "date=%d" % year]
            cmd += ["-c:a", "aac", "-b:a", "96k"] if ext == "m4a" else ["-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", "3"]
            run(cmd + [dest])
        os.remove(art)
    from PIL import Image, ImageDraw
    pictures = os.path.join(OUT, "Pictures")
    for folder, base in (("Holiday", (30, 110, 170)), ("Garden", (40, 140, 60)), ("", (150, 90, 160))):
        d = os.path.join(pictures, folder)
        os.makedirs(d, exist_ok=True)
        for i in range(1, 5 if folder else 3):
            w, h = (1600, 1067) if i % 3 else (1067, 1600)
            im = Image.new("RGB", (w, h))
            px = ImageDraw.Draw(im)
            for y in range(0, h, 8):
                t = y / h
                px.rectangle([0, y, w, y + 8], fill=tuple(int(c * (0.4 + 0.6 * t) + 60 * (1 - t)) for c in base))
            px.ellipse([w * 0.1 * i, h * 0.2, w * 0.1 * i + w * 0.3, h * 0.2 + w * 0.3], fill=(250, 220, 90))
            px.polygon([(0, h), (w * 0.3, h * 0.55), (w * 0.55, h * 0.8), (w * 0.8, h * 0.5), (w, h)], fill=tuple(c // 2 for c in base))
            im.save(os.path.join(d, "%s %d.jpg" % (folder or "Loose", i)), quality=88)
    movies = os.path.join(OUT, "Movies")
    os.makedirs(movies, exist_ok=True)
    for name, source, hz in (("Test Pattern", "testsrc2=size=1280x720:rate=30", 440), ("Colour Bars", "smptehdbars=size=1280x720:rate=30", 330)):
        run(["ffmpeg", "-y", "-f", "lavfi", "-i", source, "-f", "lavfi", "-i", "sine=frequency=%d" % hz, "-t", "12",
             "-c:v", "h264_videotoolbox", "-b:v", "3M", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", os.path.join(movies, name + ".mp4")])
    for sub in ("Desktop", "Documents"):
        os.makedirs(os.path.join(OUT, sub), exist_ok=True)
    windows_media()
    print("fixtures in", OUT)


if __name__ == "__main__":
    main()
