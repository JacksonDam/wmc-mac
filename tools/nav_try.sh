#!/bin/sh
# Bring-up iteration with scripted input: re-patch, run offscreen with an
# input script, capture a frame a second, print the innermost exception and
# make a contact sheet.
#   tools/nav_try.sh "<input script>" [first frame] [frames] [name]
cd "$(dirname "$0")/.." || exit 1
name="${4:-nav}"
python3 -I tools/build.py patch refs standins host 2>&1 | grep -E "error|FAILED|mismatch|missing"
rm -rf "build/shots/$name"
python3 -I tools/run.py --timeout 100 --log err,stub,todo --input "$1" --series "build/shots/$name" --every 1 --count "${3:-21}" WmcHost > "build/$name.log" 2>&1
echo "--- innermost exception"
awk '/^host: /{buf=""} /^host: /,0{buf=buf $0 "\n"} END{printf "%s", buf}' "build/$name.log" | head -10 | cut -c1-230
ffmpeg -y -loglevel error -start_number "${2:-8}" -i "build/shots/$name/frame_%03d.png" -frames:v 1 -vf "scale=426:-1,tile=4x3:padding=4" "build/shots/${name}_sheet.png" && echo "sheet build/shots/${name}_sheet.png"
