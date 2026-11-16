#!/bin/sh
# Opens Media Center in a real window (without taking focus), records that
# window and its sound for a few seconds with the wincap tool, then closes it.
#   tools/record_show.sh <out.mp4> [seconds] [program args...]
# Needs: WINCAP=/path/to/wincap (a ScreenCaptureKit window recorder).
# Optional: WMC_RECORD_INPUT="<input script>" to play input, WMC_RECORD_MUTE=1 for no sound,
# WMC_RECORD_DRIVE=<folder> to use another folder as C:\ (see run.py --drive).
cd "$(dirname "$0")/.." || exit 1
out="$1"; secs="${2:-12}"; shift; [ $# -gt 0 ] && shift
log=build/record_show.log
: > "$log"
python3 -I tools/run.py --show-quiet ${WMC_RECORD_DRIVE:+--drive "$WMC_RECORD_DRIVE"} $([ -n "$WMC_RECORD_MUTE" ] && echo --mute || echo --sound) --timeout $((secs + 8)) --log err,sp,snd,input,wmp,video ${WMC_RECORD_INPUT:+--input "$WMC_RECORD_INPUT"} WmcHost "$@" > "$log" 2>&1 &
app=$!
id=""
for i in $(seq 1 200); do
    id=$(sed -n 's/.*window on screen: id \([0-9]*\).*/\1/p' "$log" | head -1)
    [ -n "$id" ] && break
    sleep 0.05
done
if [ -z "$id" ]; then echo "no window appeared"; tail -5 "$log"; kill $app 2>/dev/null; exit 1; fi
echo "window id $id"
"${WINCAP:-wincap}" "$id" "$secs" "$out" 60 --audio
wait $app
grep -E "err\]|^host:|snd\]|input\]" "$log" | cut -c1-200 | head -24
