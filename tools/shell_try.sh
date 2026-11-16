#!/bin/sh
# One bring-up iteration: re-patch, run the shell offscreen for a while, and
# print the innermost exception (if any) and the snapshot line.
#   tools/shell_try.sh [seconds before snapshot] [extra log channels]
cd "$(dirname "$0")/.." || exit 1
python3 -I tools/build.py patch refs standins host 2>&1 | grep -E "error|FAILED|mismatch|missing"
python3 -I tools/run.py --timeout 90 --log "err,sp,snd${2:+,$2}" --snapshot build/shots/shell.png --after "${1:-12}" WmcHost > build/shell_try.log 2>&1
grep -v "has no implementation yet\|should have RVA data\|^$\|BDATunePIA" build/shell_try.log | grep -v "^  at " | cut -c1-300 | tail -25
echo "--- innermost exception"
awk '/^host: /{buf=""} /^host: /,0{buf=buf $0 "\n"} END{printf "%s", buf}' build/shell_try.log | head -12 | cut -c1-240
