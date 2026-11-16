#!/bin/sh
# Rebuild what changed on the managed side, then crawl the named targets.
#   tools/crawl_one.sh <target[,target...]> [crawl.py options]
cd "$(dirname "$0")/.." || exit 1
python3 -I tools/build.py tool patch refs standins host 2>&1 | grep -E "error|FAILED|not applied|failed"
only="$1"; shift
python3 -I tools/crawl.py --jobs 6 --only "$only" "$@" 2>&1 | grep -v "^   stubs: $" | cut -c1-240
