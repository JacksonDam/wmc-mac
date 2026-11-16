# Internals

Notes for working on the project. The README covers using it.

## Architecture

| Windows | Here |
|---|---|
| `ehshell.exe` (starts the .NET runtime) | `WmcHost.exe` on Mono |
| The .NET assemblies (`ehshell.dll`, `Microsoft.MediaCenter.UI.dll`, ...) | The same files, with a few mechanical metadata edits |
| `EhUI.dll` (render engine, Direct3D 9) | `native/splash`: the same message protocol, drawn with Metal |
| `ehuihlp.dll`, `user32`, `kernel32`, `gdi32`, ... | `native/win32`, `native/ehuihlp`: stand-ins in `libwmcshim.dylib` |

The UI framework never draws. It describes its scene to the render engine in
fixed-layout messages (create a visual, set its position, upload these
pixels). The stand-in engine reads the message layouts from the framework's
own metadata and keeps the scene the framework describes.

## Development set-up

```sh
tools/setup_toolchain.py                                  # 7-Zip, Mono, Mono's GDI+ library into toolchain/
tools/extract_iso.py ~/Downloads/windows7.iso work/wmc    # or extract_msi.py with an 8.1 installer
tools/build.py
tools/run.py --show WmcHost
```

`tools/setup_toolchain.py` needs no Homebrew: it downloads the official
7-Zip and Homebrew's Mono 6.12 and `libgdiplus` bottles (with every library
`libgdiplus` loads, relocated beside it and re-signed), and builds FFmpeg
7.1.1 from its source (LGPL, static, only the ASF container and the Windows
Media codecs: about 20 seconds). Everything is checked by SHA-256 and
fetched with the system's `curl`, eight at a time (Python's `urllib` was
often 30 times slower over HTTPS). `--parts` sets up only some of it.
The bottles are Homebrew's builds for macOS 11 on Apple silicon, pinned as
homebrew-core had them in July 2023, and used on every Mac: Homebrew builds
current versions only for the latest few macOS versions, and the official
Mono package for macOS is Intel-only.

## macOS 11

Everything is made to run on macOS 11 (Big Sur) and later, and checked
without a macOS 11 machine as follows:

- The native code is compiled for macOS 11 with
  `-Werror=unguarded-availability-new`: an API newer than 11 without an
  `@available` check stops the build. The one such API (the macOS 14
  display link) also has an SDK check, so macOS 11's own SDK compiles it.
- The Metal shaders are compiled as Metal Shading Language 2.3, the newest
  macOS 11 has.
- `make_app.py` refuses an app with any Mach-O file whose minimum macOS is
  above 11 (every one states it), and the app's `LSMinimumSystemVersion` is 11.
- The installer is compiled for macOS 11, which makes the Swift compiler
  reject newer APIs: SwiftUI views in an AppKit window, no Swift concurrency.
  Libraries macOS 11 lacks (Spatial, OSLog) are only weakly linked.
- The scripts the app-making chain runs need Python 3.8 at most
  (`vermin`), the version of macOS 11's Command Line Tools.
Also needed: `toolchain/dotnet` + `toolchain/dotnet-tools/ilspycmd` for
`tools/decompile.py` only, and ffmpeg and Pillow for the tests (they make the
test media and the picture sheets).

`WMC_TREE` (an unpacked installer), `WMC_BUILD` (a build folder) and
`WMC_TOOLCHAIN` (a toolchain folder) let `build.py`, `run.py` and
`crawl.py` work on another copy without touching the default one.

## Sources of Media Center

- **Windows 7 disc** (`tools/extract_iso.py`): Media Center 6.1.7601. The
  disc keeps each edition as an image in `sources/install.wim`; the first
  one with `Windows/ehome` is used. Its registry entries come from that
  image's `SOFTWARE` hive (`tools/hive.py` reads the hive format and picks
  Media Center's settings and COM registrations; the image was serviced as
  drive D:, so `D:\` becomes `C:\`).
- **8.1 installer** (`tools/extract_msi.py`): Media Center 6.3.9600, as
  repackaged for Windows 10; registry entries from its `Install.reg`.

The two differ little where this project touches them: Windows 7 has one
window message fewer (generated names carry no message numbers, so the
engine compiles against either), and opens its database through
`ObjectStoreOpener` where 8.1 has `ObjectStoreManager`. The patcher lists
every rule in `redirects.txt` that matched nothing, which is where a
renamed method shows up first.

## Windows Media and AVI files

`.wmv`, `.wma`, `.asf`, `.avi` and `.divx` files, which AVFoundation cannot
open, are played and read with FFmpeg (an LGPL build with only the ASF and
AVI readers and the decoders such files use: Windows Media, MPEG-4 (DivX,
Xvid), H.264, MJPEG, DV, MPEG-1/2, Cinepak, Indeo, Microsoft Video 1 and RLE;
MP3, AC-3, AAC, PCM and ADPCM sound; `native/platform/ffmedia.m`), behind the same
functions as everything else (`wmc_video_*`, `wmc_audio_*`,
`wmc_media_tags`, `wmc_media_artwork`, the video thumbnails). A player has
one reader thread: it splits the file into a queue of compressed packets per
stream (files differ in how far ahead of the sound they keep the pictures),
decodes sound whenever less than half a second is scheduled on an
AVAudioEngine player node, and pictures whenever the queue of decoded ones
(about a second) has room. The sound card's clock is the player's clock (a
wall clock without sound, or at speeds other than 1); each frame drawn takes
the picture due, converted to BGRA only then. A song has ended when the file
is read and every scheduled buffer has been played out (counted by the
node's callbacks, which take no lock: stopping the node under the player's
lock calls them). Pixels that are not square (DV, many DivX files) are
reported to Media Center in the shape they are shown at, from the file or,
for DV, from the decoded pictures. The crawl plays a WMA album, a WMV video
and an Xvid AVI from the test media (`tools/make_fixtures.py` makes them with
FFmpeg's encoders).

## Files that come and go

`native/platform/watch.m` watches folders with FSEvents, for two users.
Media Center's picture and video pages register for the Windows shell's
change notifications on the folder they show
(`EhRegisterForChangeNotifyOnFilename`); each registration gets a stream, and
each change is posted to the registered window message as a record that
`EhBeginChangeNotifyEvent` and `EhCrackChangeNotifyEvent` hand back. The
music pages use Windows Media Player's library instead: a stream over the
library folders counts changes, and the Player stand-in looks at the count
every two seconds on the UI thread, scans again and raises
`MediaCollectionChange`. Hidden files and the insides of other programs'
packages (an iMovie library, say) do not count.

## The app

`tools/make_app.py` (behind `tools/make_app.sh`, which first installs
Apple's Command Line Tools if needed) runs the whole chain into a work
folder and puts the result together:

```
Windows Media Center.app/Contents/
  MacOS/Windows Media Center   tools/app/launcher.c: sets up, then runs Mono in-process (mono_main)
  Resources/mono/              Mono's runtime only (lib/mono/4.5, gac, etc/mono)
  Resources/libgdiplus/        the GDI+ library and its libraries, fonts.conf
  Resources/windows/ehome/     Media Center as built (stands for C:\Windows\ehome)
  Resources/libwmcshim.dylib
  Resources/mono.config.in     library map; the launcher fills in the app's folder
  Resources/registry/          the registry Media Center starts with
  Resources/AppIcon.icns       from Media Center's own icon (ehshell.dll), made on the user's Mac
```

What Media Center saves goes to `~/Library/Application Support/Windows Media
Center/drive_c`. Its registry starts as a copy of the app's; when the app is
replaced by a newer one, the launcher adds what the new registry has and the
saved one lacks (a new file type, say), keeping everything already there
(`registry-stamp` names the app it last did this for). The app is signed ad hoc for the Mac it is made on, and
carries FFmpeg's licence (`Resources/Licenses`). The last step starts it
offscreen (`WMC_HEADLESS`, `WMC_APP_DATA` for a throwaway data folder,
`WMC_STEPS="ready; snap; exit"`) and checks that it drew the start menu.

Speed: FFmpeg builds in the background from the start (`--parts ffmpeg`)
while the rest is set up, the disc unpacked and the .NET side built; the
native part, which links it, comes last. Files go into the app as APFS
clones. A first run takes about 40 seconds on a 10-core Mac, later ones
about 18. `make_app.py` prints `progress: <0 to 1>` lines (each part
weighted by its measured seconds; the downloads by their bytes) for the
installer's bar.

`installer/build.sh` builds the SwiftUI installer (needs Xcode). It carries a
copy of `tools`, `native` and `managed` and runs `make_app.sh` from it,
showing its `step:` lines. For unattended checks it takes `--source FILE
--output DIR --work DIR --start`, `--quit-when-done` or
`--quit-after S`, and `--snapshots DIR`, which keeps it out of the Dock,
never activates it and saves a picture of its window every 3 seconds.

## Build

`tools/build.py` steps: `tool` (the metadata tool), `gen` (native call list,
protocol header, stubs, Mono configuration), `native` (`libwmcshim.dylib`),
`patch` (runtime copies of the assemblies), `refs` (compile-time references
and the generated COM base classes), `standins` (managed stand-ins, compiled
against the patched assemblies), `host` (`WmcProbe.exe`, `WmcHost.exe`).

## Running

`tools/run.py` options:

| Option | Effect |
|---|---|
| `--show` | Run as a normal app: a window, focus, sound |
| `--show-quiet` | The same window, but without taking focus (for unattended checks) |
| (neither) | Offscreen: nothing appears on screen, nothing takes focus, no sound |
| `--snapshot out.png [--after N]` | Render offscreen to a PNG after N seconds (default 3), then quit |
| `--series dir [--every S] [--count N]` | Offscreen frames at a fixed interval, for looking at motion |
| `--input "script"` | Play input at given seconds, e.g. `"9 key down; 11 key enter; 14 move 400 150; 16 click 400 150; 20 key back"`. `key` (a name such as `enter`, `back`, `apps` for the context-menu key, `f1`, or a letter, optionally with `ctrl+`, `shift+`, `alt+`), `char x` (a typed character), `move`, `click` and `resize W H` go straight to the framework; `nskey <mac key code>`, `nsmove` and `nsclick` send real Mac events through the window (needs `--show` or `--show-quiet`) |
| `--sound`, `--mute` | Sound on in an offscreen run; sound off in a `--show` run |
| `--first-run` | Reset the registry so Media Center starts with its Welcome screen and set-up wizard |
| `--drive dir` | Another folder to stand for `C:\` (registry, saved settings), so that runs do not share one |
| `--log a,b` | Log channels: `stub` (unwritten functions), `todo` (unhandled messages, unwritten COM members), `trace` (Media Center's own diagnostic tracing, including its playback log), `wmp` and `wmpq` (the media library and each query made of it), `video`, `file`, `msg` (every message), `scene` (the visual tree at snapshot), `hang` (stalls of the UI thread), `text`, `img`, `snd`, `mod`, `win`, `sp`, or `all` |
| `--timeout N` | Stop after N seconds |

Programs:

- `WmcHost` calls Media Center's real entry point.
- `WmcProbe <page>` hosts the UI framework alone and loads one markup (MCML)
  page: the test bed for the render engine. Pages are in `tests/mcml`
  (`tools/run.py --snapshot out.png WmcProbe tests/mcml/tilt.mcml`).

Other tools: `tools/shell_try.sh` (one bring-up iteration: patch, run
offscreen, show the innermost exception), `tools/nav_try.sh "<input script>"`
(the same with scripted input and a contact sheet of frames),
`tools/record_show.sh out.mp4` (show the window and record it with its
sound; needs a ScreenCaptureKit window recorder in `$WINCAP`;
`WMC_RECORD_INPUT` plays an input script), `tools/setup_registry.py`,
`tools/list_resources.py`. `WMC_DUMP_POOLS=<folder>` with `--snapshot` writes
the engine's texture atlases; `--log scene` prints the visual tree with its
gradients; `--log anim` every animation as it starts and ends; `--log
series` the exact time of each `--series` frame (the timer is not exact, so
motion is measured against these).

`WMC_MEDIA_HOME=<folder>` makes the libraries start out as
`<folder>/Music` and so on instead of the home folder's.

`WMC_STRICT=1` makes an exception in any page end Media Center, as it does
on Windows, instead of being reported and stepped around (see Guard below).

## Testing

`tools/crawl.py` opens every place listed in `tools/crawl_targets.txt` (each
start-menu tile, each settings page, folders, albums, playing a song, a
picture, a video), each in its own offscreen run from a freshly installed
registry and a made-up media folder (`tools/make_fixtures.py`), and reports
what stopped, what froze, which exceptions were guarded and which unwritten
functions were reached. `build/crawl/overview_*.png` shows every target before
and after. `tools/crawl_one.sh <names>` rebuilds and crawls just those.
`--app <made app>` crawls an app from `tools/make_app.py` instead.

Runs wait for Media Center, not the clock: each starts with
`/nostartupanimation`, and its keys go through `WMC_STEPS`
(`native/splash/sp_window.m`), where `settle` waits until no animation is
playing, the UI thread has taken its input and the scene has stayed the same
for 0.3 s (at most 4 s: a playing video never settles). Animations that
repeat for ever or last over 2 s (a pulsing highlight, a drifting
background) do not count. A wait written in a target (`wait3` after the key
that starts a video) keeps its own timing. Each run saves four frames
(before the last key, arrived, just before Back, after Back), and one run
per processor core goes at a time: about 20 s a target and 4.5 minutes for
all 110 on a 10-core Mac (it was 12 minutes on fixed timers).

A frozen page still draws (the engine animates on its own), so freezes are
found by a watchdog instead (`native/core/threadq.c`, log channel `hang`): it
reports when Media Center's UI thread leaves its input untaken for 2 seconds,
and when it takes it again (not once it has been asked to close: shutting
down takes a while when something is playing). The crawl lists such stalls
and fails a target whose UI thread never recovers.

Every Windows function not written yet is a stub that logs
`UNIMPLEMENTED module!name` the first time it is called, and every unwritten
member of a COM stand-in logs too, so `--log stub,todo` is the to-do list.

A stub returns 0, which to many Windows calls means success. That is
harmless almost everywhere, but a loop that runs "while the call succeeds"
never ends: Windows Media Center Setup froze that way, asking Windows
Installer which products use PlayReady (`native/win32/msi.c` now answers
that none do).

## Stand-ins for Windows components

- **Windows Media Player** (`managed/WmcStandins/Wmp`). Media Center hosts
  the Player as an ActiveX control and uses it as its music, picture and
  video library and as its music player. The stand-in implements the
  Player's interfaces over a scan of the library folders, scanned again
  when files come and go, and plays sound with AVAudioPlayer (FFmpeg for
  Windows Media).
- **The video player** (`managed/WmcStandins/Playback`, `native/splash/sp_video.m`).
  Media Center plays video through a native player behind a few interfaces
  of its own. The stand-in implements them over AVPlayer, whose frames go
  into the render engine's video surface.
- **Windows libraries** (`Libraries.cs`): the lists of folders that make up
  Music, Pictures and Videos.
- **The triple-tap input module** (`Input/KeypadInputModule.cs`): text entry
  with a remote's number keys.
- **The object store** (`Store/`). Media Center keeps the guide, its
  recordings, tuner set-up and much else as objects in a database, reached
  through a C++/CLI assembly (SQL Server Compact over OLE DB) that cannot
  run here. The store itself is plain .NET down to four abstract classes
  (store, session, row cursor, transaction); `Store/MemoryStore.cs`
  implements them over an in-memory database (`MemoryDatabase.cs`: tables,
  ordered indexes, key ranges and seeks over OLE DB-style row buffers;
  `MemorySql.cs`: the few SQL statements the store sends as text). The
  store starts empty, imports its own initial data, and is gone when Media
  Center quits. Its cross-process parts (named mutexes, memory-mapped id
  counters) run single-process: mutexes are plain ones and the shim maps
  files with `mmap`.
- **Extenders** (`Extender.cs`): the device manager exists and finds none.
- **Visualizations** (`Wmp/Visualizations.cs`): the functions Media Center's
  Player skin (MCSkin.wmz) would hand it, over the Player's own list of
  visualizations.
- **Windows Installer** (`native/win32/msi.c`): nothing here was installed by
  it, so it knows no products.
- **Guard** (`Guard.cs`). On Windows an unhandled exception ends Media
  Center. Here a failure in one page should not take the rest down: the
  calls that run each piece of queued work and each page notification are
  wrapped, the exception is printed (`host: guarded: ...`), and if it
  happened while a page was opening Media Center steps back to the page
  before and shows a dialog.

COM interfaces have dozens of members of which Media Center uses a few.
`wmctool bases` generates, from the interop assembly, a base class per
stand-in that implements every member as "log that this was reached, return
the default"; the hand-written classes override what matters. `wmctool uses
<folder> <assembly>` lists which members of an assembly the others call.

## Managed-side changes

`managed/redirects.txt` lists the few calls in Media Center's assemblies that
are rewritten at patch time, each with its reason:

- `Type::Method => Name` sends the call to `WmcStandins.Compat.Name`.
- `Type::Method => @default` drops the call and uses null/0/false.
- `Type::Method => @stub` replaces the method's own body the same way
  (needed where the call is virtual or made by reflection).
- `Type::Method => @body Name` replaces the method's body by a call to
  `WmcStandins.Compat.Name`.
- `Type::Method => @guard` wraps each call so that an exception is reported
  instead of travelling on.
- `Type::Method => @path` translates the call's file-path argument first.
  Media Center writes paths the Windows way (`C:\...`, backslashes) and
  hands them to .NET's file classes, which on a Mac take them literally;
  `native/core/paths.c` maps them (and `MONO_IOMAP=all` makes .NET's `Path`
  class treat `\` as a separator).

Differences between .NET on Windows and Mono on a Mac that Media Center
runs into, and where they are handled:

- "Auto" strings (`CharSet.Auto`, `Marshal.PtrToStringAuto`) are UTF-16 on
  Windows and UTF-8 on Mono: the patcher makes them UTF-16.
- `%windir%` and `%SystemRoot%` are not set on a Mac: `WmcHost` sets them.
- Mono compiles small generated methods at once, and refuses a constructor
  call on an abstract type that Windows would only reject if it ran.
- `Marshal.GetHRForLastWin32Error` is not in Mono.
- A class field inside a structure passed to native code (the picture
  requirements' colour filters) cannot be marshalled by Mono.
- A synchronization context that waits through Win32
  `WaitForMultipleObjects` waits on Mono's own handles: the wait goes back
  to the runtime.

C++/CLI assemblies are made loadable: their module initialiser is emptied and
their native-only methods throw `PlatformNotSupportedException` naming
themselves.

## Layout

```
tools/      make_app.sh, make_app.py, app/launcher.c, setup_toolchain.py, extract_iso.py, hive.py,
            peinfo.py, extract_msi.py, decompile.py, build.py, run.py, gen_stubs.py, setup_registry.py,
            list_resources.py, crawl.py, crawl_one.sh, crawl_targets.txt,
            make_fixtures.py, shell_try.sh, nav_try.sh, record_show.sh, screenrec.swift,
            measure/ (logo_width.py, compare_launch.py)
installer/  the SwiftUI installer (Sources/InstallerApp.swift, build.sh, make_icon.swift)
ref/        your own reference pictures and recordings of the real thing (not in git)
managed/    wmctool (metadata tool, patcher, COM base generator), WmcStandins (Wmp, Playback,
            Input, Guard, Libraries, ...), WmcProbe, WmcHost, redirects.txt
native/     core (logging, thread queue, paths), win32, ehuihlp, ehtrace, platform (AppKit,
            media, FFmpeg, folder watching), splash (engine)
docs/       internals.md (this file), images/ (the README's diagram and its SVG source)
tests/mcml  test pages
```
