#!/bin/sh
# Make a Mac app of Windows Media Center from your own Windows 7 disc image.
#
#   tools/make_app.sh <windows7.iso> [--output FOLDER] [--work FOLDER] [--no-check]
#
# Apple's Command Line Tools bring the compiler and Python this needs; if they
# are missing, macOS is asked to install them (a dialog appears) and this
# waits for that to finish. Everything else is downloaded by tools/make_app.py
# (see it for the options).
here="$(cd "$(dirname "$0")" && pwd)"

has_tools() {
    dir="$(xcode-select -p 2>/dev/null)" || return 1
    [ -x "$dir/usr/bin/clang" ] || [ -x "$dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" ]
}

if ! has_tools; then
    echo "step: Installing Apple's Command Line Tools (answer the dialog that appears)"
    xcode-select --install >/dev/null 2>&1
    waited=0
    until has_tools; do
        sleep 5
        waited=$((waited + 5))
        if [ "$waited" -ge 3600 ]; then
            echo "error: the Command Line Tools were not installed (run xcode-select --install)"
            exit 1
        fi
    done
fi
exec /usr/bin/python3 -B "$here/make_app.py" "$@"
