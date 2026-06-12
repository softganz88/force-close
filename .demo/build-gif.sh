#!/usr/bin/env bash
# Trim the recorded cast so it ends on the populated list (target gone), not on
# the alt-screen-leave that force-close emits on exit (which blanks the frame),
# then render to docs/tui-demo.gif. Idempotent: re-run any time after recording.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CAST="$HERE/.demo/tui.cast"
TRIM="$HERE/.demo/tui-trimmed.cast"
OUT="$HERE/docs/tui-demo.gif"

python3 - "$CAST" "$TRIM" <<'PY'
import json, re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).readlines()
hdr, events = lines[0], lines[1:]
strip = lambda t: re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]', '', t).replace('\x1b', '')
last_list = max(
    (i for i, l in enumerate(events) if l.strip()
     and 'window(s) listed' in strip(json.loads(l)[2])),
    default=len(events) - 1,
)
# Keep one extra beat after the final list draw, then stop before the
# alt-screen-leave / cursor-restore the exit trap emits.
keep = events[: last_list + 1]
with open(dst, 'w') as f:
    f.write(hdr)
    f.writelines(keep)
print(f"trimmed {len(events)} -> {len(keep)} events (ends on populated list)")
PY

mkdir -p "$HERE/docs"
agg --theme monokai --font-size 16 --speed 1.3 --idle-time-limit 1.5 \
    --last-frame-duration 3 "$TRIM" "$OUT"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
