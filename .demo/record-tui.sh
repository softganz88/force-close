#!/usr/bin/env bash
# Safe TUI demo driver for asciinema.
#
# SAFETY MODEL (this matters — a prior careless demo logged the user out):
#   * The only window this script ever terminates is a throwaway zenity popup
#     it spawns itself, titled with a unique marker.
#   * Before sending the terminate keystroke, it reads the TUI's CURRENT frame,
#     finds the row whose title is our marker, and selects THAT row number.
#   * Before sending "y", it captures the confirm prompt and aborts the whole
#     demo unless the prompt names our marker. No blind confirmation, ever.
#   * Runs inside its own tmux session; never touches the user's shell.
set -euo pipefail

MARKER="FC-DEMO-TARGET-$$"
SESS="fcdemo$$"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CAST="$HERE/.demo/tui.cast"
export DISPLAY="${DISPLAY:-:0}"

cleanup() {
    tmux kill-session -t "$SESS" 2>/dev/null || true
    pkill -f "zenity .*$MARKER" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Spawn the throwaway target window.
#    NOT setsid: a setsid'd process becomes its own session leader (pid==sid),
#    which force-close's own session-leader guard correctly REFUSES to kill. A
#    plain background job has pid!=sid, so it is a normal, safely-killable target
#    — and it's a persistent --progress dialog so it can't self-close mid-demo.
zenity --progress --pulsate --no-cancel --title="$MARKER" \
       --text="force-close demo target — safe to terminate" >/dev/null 2>&1 &
for _ in $(seq 1 50); do wmctrl -l 2>/dev/null | grep -q "$MARKER" && break; sleep 0.1; done
wmctrl -l 2>/dev/null | grep -q "$MARKER" || { echo "target window never appeared" >&2; exit 1; }

# 2. Start a recorded tmux session running the TUI.
tmux new-session -d -s "$SESS" -x 100 -y 30
# Record the pane to an asciinema cast by running asciinema inside it.
tmux send-keys -t "$SESS" "cd '$HERE' && asciinema rec --overwrite -c './force-close.sh' '$CAST'" Enter
sleep 3   # let the TUI draw its first frame

# 3. Find OUR row by reading the live frame (never a cached number).
frame() { tmux capture-pane -t "$SESS" -p; }
row=""
for _ in $(seq 1 20); do
    row=$(frame | awk -v m="$MARKER" '$0 ~ m {print $1; exit}')   # col 1 = ID (│ separators are their own fields)
    [[ "$row" =~ ^[0-9]+$ ]] && break
    sleep 0.3
done
[[ "$row" =~ ^[0-9]+$ ]] || { echo "could not locate demo row" >&2; exit 1; }

# Pause so the viewer sees the populated table, then type the id.
sleep 1.5
tmux send-keys -t "$SESS" "$row" Enter

# 4. Poll for the confirm prompt, then VERIFY it names our marker BEFORE 'y'.
#    The terminate confirm names the app TITLE (our marker), so it must appear.
prompt=""
for _ in $(seq 1 20); do
    prompt=$(frame | grep -i CONFIRM || true)
    [[ -n "$prompt" ]] && break
    sleep 0.25
done
if [[ -z "$prompt" ]] || ! grep -q "$MARKER" <<<"$prompt"; then
    echo "ABORT: confirm prompt absent or does not name our target: [$prompt]" >&2
    tmux send-keys -t "$SESS" "n" Enter   # decline, just in case
    exit 1
fi
echo "confirm prompt verified: $prompt" >&2
sleep 1.5   # let the viewer read the prompt
tmux send-keys -t "$SESS" "y" Enter
sleep 4     # kill chain runs; result (OK) shows, then "Press Enter to continue"

# The kill chain ends with a "Press Enter to continue" pause on the result —
# linger there so the viewer reads the outcome, then Enter returns to the list.
tmux send-keys -t "$SESS" "" Enter
sleep 1

# 5. Refresh so the demo ENDS on the list with our target GONE (count dropped).
#    We deliberately do NOT quit: 'q' clears the alt-screen, leaving a blank
#    final frame that reads as a broken GIF. Ending on the populated list keeps
#    the loop's last frame meaningful. asciinema is stopped by killing the pane.
sleep 0.5
tmux send-keys -t "$SESS" "r" Enter
sleep 3   # hold on the refreshed list — this becomes the GIF's resting frame

# Stop the recording without a screen-clearing quit: SIGINT the asciinema/TUI.
tmux send-keys -t "$SESS" C-c
sleep 1.5

echo "cast written: $CAST"
