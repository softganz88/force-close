# Contributing to force-close

Thanks for your interest. This is a single-purpose Bash tool with an
opinionated, safety-first design — contributions are welcome, and the bar is
that changes are correct, tested, and don't widen the blast radius of a tool
whose whole job is to kill processes.

## Before you start

For anything beyond a small fix, **open an issue first** to discuss the
approach. The tool is deliberately minimal (see the design notes in the README
changelog), so a quick conversation saves you from building something that
won't fit the scope.

Good first contributions: bug reports with a reproducer, fixes for a clearly
wrong behavior, test coverage for the pure helpers, documentation improvements.

## Development setup

You need a Linux + X11 (or XWayland) session and these tools:

- Runtime: `wmctrl`, `ps`, `lsof`, `pgrep`, `tput`, `awk`, `sed`, `sort`,
  `xargs`, `head` (the script checks these at startup).
- Development: [`bats`](https://github.com/bats-core/bats-core) (test runner)
  and [`shellcheck`](https://www.shellcheck.net/) (linter).

```bash
git clone https://github.com/softganz88/force-close
cd force-close
bats tests/        # run the test suite
```

## The verification gate

Every change must pass all three before it's ready for review:

```bash
bash -n force-close.sh                 # syntax check
shellcheck -S warning force-close.sh   # must be clean at warning level
bats tests/                            # all tests pass
```

The script runs under `set -euo pipefail`. Two recurring footguns to keep in
mind:

- A function that returns nonzero where `set -e` applies aborts the script.
  The EXIT trap in particular must never fail (a failing EXIT trap overrides
  the script's exit status).
- Anything reading `/proc` or `ps` output must tolerate the process being gone
  (empty/partial reads), and must guard `pgrep`/`ps` exit status.

## Safety rules — read these before touching the kill path

This tool sends signals to live processes. The test suite is built around one
absolute rule:

- **Never let an automated test signal anything it did not spawn itself.** The
  bats suite only ever touches its own short-lived `sleep` processes. Do not
  add a test that exercises the kill chain against a real window or an arbitrary
  PID.
- **The kill chain signals a process *subtree*, never a process group.** On a
  desktop session every GUI app shares the session leader's process group
  (e.g. `cinnamon-session`), so a `kill -- -PGID` would take down the whole
  session and log the user out. This was a real bug; do not reintroduce
  group-based signaling. See the v5.0.3 changelog.
- If you must test interactive behavior by hand, run the TUI **directly in a
  terminal** (not inside `tmux`/`screen`, where the self-tree exclusion no
  longer protects your shell), and only terminate a throwaway window you spawn
  yourself. The `.demo/record-tui.sh` script shows the safe pattern: it reads
  the live frame, finds its own target's row, and refuses to confirm unless the
  prompt names that target.

## Commit and PR conventions

- Commit subjects follow the repo's existing style — a type prefix, imperative
  mood, no trailing period: `fix:`, `docs:`, `test:`, `release:`. Add a body
  when the *why* isn't obvious from the diff.
- One commit per logical change; don't bundle unrelated fixes.
- Keep the change surgical — match the surrounding style, don't refactor code
  the change doesn't touch.
- In the PR description, say what changed, why, and how you verified it (the
  three gate commands above, plus any manual steps).
- Update `tests/force-close.bats` for any new pure-helper behavior and the
  README changelog for any user-visible change.

## Reporting bugs

Open an issue with: your distro and desktop environment, `bash --version`,
exactly what you did, what you expected, and what happened. For a kill-related
bug, include the relevant `ps -o pid,ppid,pgid,sid,comm` output if you can —
process relationships are usually the key detail.
