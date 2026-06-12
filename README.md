# force-close

Advanced X11 process recovery and deep-analysis tool — an interactive TUI for inspecting and force-terminating stuck windows/processes, plus a non-interactive CLI mode for killing by name pattern.

## Requirements

Linux + X11 (or XWayland). Depends on: `wmctrl`, `ps`, `lsof`, `pgrep`, `tput`, `awk`, `sed`, `sort`, `xargs`, `head` (all checked at startup).

> **X11-only:** native Wayland windows are invisible to `wmctrl` and will not appear. Run under an X11 session (or XWayland for X11 clients).

## Usage

```bash
./force-close.sh              # interactive TUI: list windows, terminate or analyze by id
./force-close.sh <pattern>    # CLI: confirm-and-kill every process matching <pattern>
```

**TUI keys:** `<id>` terminate · `a <id>` analyze · `r` refresh · `q` quit.

**Kill chain** (graceful → forced): X11 window close → group `SIGTERM` → group `SIGKILL`, each with a timeout and a re-validation of process identity before escalating.

## CLI exit codes

| Code | Meaning |
|------|---------|
| `0`  | all confirmed targets terminated (or nothing to do / declined) |
| `1`  | no matching processes |
| `2`  | at least one target could not be terminated |

## Safety

- Never lists or signals its own process tree (PID / ancestors / process group / session) — survives renaming the script.
- Anchors each target to its `/proc/<pid>/stat` start time, captured at listing time, to defeat PID reuse before sending any signal.
- Refuses to signal its own process group.
- Treats zombies as un-killable and reports that their parent must reap them, rather than looping on a kill that can never succeed.
- Sanitizes attacker-influenced window titles before printing.

## Tests

The pure helpers (`to10`, `trunc_str`, `escape_pattern`, `get_starttime`, `is_self_tree`) and the EXIT-trap exit-code contract are covered by a [bats](https://github.com/bats-core/bats-core) suite:

```bash
bats tests/
```

The suite spawns only its own short-lived `sleep` processes — the kill chain itself is never exercised automatically.

## Changelog

### v5.0.2

- **Fix: CLI exit codes** — in CLI mode every exit collapsed to `1` (a nonzero return from the `restore_term` EXIT trap overrode the real status under `set -e`), breaking the documented `0`/`2`/`130` codes. The trap is now infallible and only restores cursor/screen when the TUI actually started, which also keeps piped CLI output free of stray escape sequences.
- **Fix: identity anchor vs newline-in-comm** — a process with a newline in its comm (writable via `/proc/self/comm`) made `/proc/<pid>/stat` multi-line; the line-based read returned an empty start time, so the tool reported such processes as "already gone" and `kill_gate` skipped identity re-validation. `get_starttime` now reads the whole stat file.
- **Tests** — bats suite for the pure helpers (`tests/force-close.bats`, 24 cases); the inline pattern escaping was extracted into `escape_pattern()` to make it testable.

### v5.0.1

- **Terminal hygiene** — a `trap` restores the terminal on any exit (including `Ctrl-C`, `SIGTERM`, or an unexpected abort): leaves the alternate screen, restores the cursor, and clears pending color. The interactive TUI now runs on the alternate screen so it no longer clobbers scrollback; CLI mode stays linear and pipeable.
- **Selection-id normalization** — leading-zero and spaced inputs such as `a 03` and `a  3` now resolve correctly, with strict digit validation so malformed input can't abort the script.

### v5.0.0

- Initial reviewed release: identity-anchored kill chain (defeats PID reuse), group-aware liveness, self-tree exclusion, zombie handling, sanitized rendering, single-source table geometry, and a fork-free batched refresh. `shellcheck`-clean.
