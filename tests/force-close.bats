#!/usr/bin/env bats
# Tests for force-close.sh pure helpers (to10, trunc_str, escape_pattern,
# get_starttime, is_self_tree). The kill chain is never exercised — nothing
# here sends a signal to anything it didn't spawn.
#
# The script is sourced inside disposable `bash -c` shells (see fc) so its
# traps and `set -euo pipefail` never touch the bats process. Sourcing stops
# at the script's test hook, before any UI or kill path.

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../force-close.sh"
    # The script's X11 check only requires DISPLAY to be non-empty;
    # no connection is made while sourcing.
    export DISPLAY="${DISPLAY:-:0}"
}

teardown() {
    # Kill the spawned process and any descendants it left (setsid trees don't
    # die with the parent). Best-effort; never fail teardown.
    if [[ -n "${TEST_PID:-}" ]]; then
        local p
        for p in $(pgrep -P "$TEST_PID" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
        kill "$TEST_PID" 2>/dev/null || true
    fi
}

# Run a snippet in a shell with force-close.sh sourced.
fc() { bash -c "source '$SCRIPT'; $1"; }

# ── to10 ──────────────────────────────────────────────────────────────────

@test "to10: scales one decimal place (12.3 → 123)" {
    run fc 'to10 r "12.3"; printf %s "$r"'
    [ "$status" -eq 0 ]
    [ "$output" = "123" ]
}

@test "to10: integer gets implicit .0 (7 → 70)" {
    run fc 'to10 r "7"; printf %s "$r"'
    [ "$output" = "70" ]
}

@test "to10: only the first fraction digit counts (0.59 → 5)" {
    run fc 'to10 r "0.59"; printf %s "$r"'
    [ "$output" = "5" ]
}

@test "to10: leading zeros are decimal, not octal (08.09 → 80)" {
    run fc 'to10 r "08.09"; printf %s "$r"'
    [ "$output" = "80" ]
}

@test "to10: empty and garbage fall back to 0 without dying under set -e" {
    run fc 'to10 r ""; printf %s "$r"'
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    run fc 'to10 r "garbage"; printf %s "$r"'
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "to10: locale comma value degrades to 0, not a crash" {
    run fc 'to10 r "1,5"; printf %s "$r"'
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ── trunc_str ─────────────────────────────────────────────────────────────

@test "trunc_str: short string is padded to exact width" {
    run fc 'trunc_str r "abc" 10; printf "[%s]" "$r"'
    [ "$output" = "[abc       ]" ]
}

@test "trunc_str: long string is truncated to width with ellipsis" {
    run fc 'trunc_str r "abcdefghijkl" 10; printf "[%s]" "$r"'
    [ "$output" = "[abcdefg...]" ]
}

@test "trunc_str: exact-width string passes through unchanged" {
    run fc 'trunc_str r "abcdefghij" 10; printf "[%s]" "$r"'
    [ "$output" = "[abcdefghij]" ]
}

@test "trunc_str: accented chars count as single cells" {
    run fc 'trunc_str r "café" 6; printf "[%s]" "$r"'
    [ "$output" = "[café  ]" ]
}

# ── escape_pattern ────────────────────────────────────────────────────────

@test "escape_pattern: escapes dot and star" {
    run fc 'escape_pattern "a.b*c"'
    [ "$output" = 'a\.b\*c' ]
}

@test "escape_pattern: escapes brackets, braces, anchors, backslash" {
    run fc 'escape_pattern "[x]{1}^y\$z\\\\"'
    [ "$output" = '\[x\]\{1\}\^y\$z\\\\' ]
}

@test "escape_pattern: escaped pattern no longer regex-matches (a.c vs abc)" {
    run fc 'p=$(escape_pattern "a.c"); if printf %s "abc" | grep -qE "$p"; then echo MATCH; else echo NOMATCH; fi'
    [ "$output" = "NOMATCH" ]
}

@test "escape_pattern: escaped pattern still matches the literal text" {
    run fc 'p=$(escape_pattern "a.c"); if printf %s "a.c" | grep -qE "$p"; then echo MATCH; else echo NOMATCH; fi'
    [ "$output" = "MATCH" ]
}

@test "escape_pattern: metachar-leading argument yields a valid ERE" {
    # An unescaped leading '*' is an invalid ERE — grep would error (exit 2).
    run fc 'p=$(escape_pattern "*foo"); if printf %s "*foo" | grep -qE "$p"; then echo MATCH; else echo NOMATCH; fi'
    [ "$output" = "MATCH" ]
}

# ── get_starttime ─────────────────────────────────────────────────────────

@test "get_starttime: matches stat field 22 for a normal process" {
    sleep 30 & TEST_PID=$!
    # sleep's comm is a single token, so a naive field split is valid ground truth
    expected=$(awk '{print $22}' "/proc/$TEST_PID/stat")
    run fc "get_starttime $TEST_PID; printf %s \"\$STARTTIME\""
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "get_starttime: empty (not a crash) for a nonexistent PID" {
    pid_max=$(cat /proc/sys/kernel/pid_max)   # never allocated: PIDs stay below pid_max
    run fc "get_starttime $pid_max; printf '[%s]' \"\$STARTTIME\""
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

# Spawn a sleeper that renames its own comm via $1, then assert get_starttime
# returns the same (immutable) starttime before and after the rename. A parser
# confused by the new comm would return a shifted field or "" instead.
# The trailing ':' stops bash exec-ing the final sleep (which would reset comm).
assert_anchor_stable_across_comm_rename() { # $1=comm writer command
    bash -c "sleep 1; $1 > /proc/\$\$/comm; sleep 30; :" & TEST_PID=$!
    before=$(fc "get_starttime $TEST_PID; printf %s \"\$STARTTIME\"")
    [ "$(cat "/proc/$TEST_PID/comm")" = "bash" ] || skip "comm flipped before baseline read"
    for _ in $(seq 1 40); do
        [ "$(cat "/proc/$TEST_PID/comm")" = "we) ird" ] && break
        sleep 0.1
    done
    [ "$(cat "/proc/$TEST_PID/comm")" = "we) ird" ] || skip "comm rename did not land"
    after=$(fc "get_starttime $TEST_PID; printf %s \"\$STARTTIME\"")
    [ -n "$before" ]
    [[ "$before" =~ ^[0-9]+$ ]]
    [ "$after" = "$before" ]
}

@test "get_starttime: immune to ') ' inside comm (PID-reuse anchor stays stable)" {
    assert_anchor_stable_across_comm_rename "printf '%s' 'we) ird'"
}

@test "get_starttime: immune to a NEWLINE inside comm (multi-line stat file)" {
    # echo appends \n; the kernel stores it in comm, so stat becomes a
    # two-line file — a line-based read parses garbage and blinds the anchor
    assert_anchor_stable_across_comm_rename "echo 'we) ird'"
}

# ── restore_term (EXIT trap) ──────────────────────────────────────────────
# Regression: under set -e a failing EXIT trap OVERRIDES the exit status.
# v5.0.1's restore_term returned nonzero whenever the TUI never started,
# collapsing every documented CLI exit code (0/1/2/130) to 1.

@test "EXIT trap preserves exit status 0 when TUI never started" {
    run bash -c "source '$SCRIPT'; exit 0"
    [ "$status" -eq 0 ]
}

@test "EXIT trap preserves exit status 2 when TUI never started" {
    run bash -c "source '$SCRIPT'; exit 2"
    [ "$status" -eq 2 ]
}

@test "EXIT trap emits no escape codes into non-TUI (pipeable) output" {
    run bash -c "source '$SCRIPT'; printf marker"
    [ "$status" -eq 0 ]
    [ "$output" = "marker" ]
}

# ── collect_subtree ───────────────────────────────────────────────────────
# The fix for the session-logout bug: we kill the process SUBTREE, never the
# process group (a desktop app shares the session leader's group). These tests
# spawn a parent→child sleep tree and assert collection — no signals are sent.

# setsid puts the test tree in its OWN session, so is_self_tree (which excludes
# anything sharing the sourcing shell's session) doesn't filter it out — this
# mirrors reality, where the target app is in a different session from the tool.
@test "collect_subtree: gathers the root and its descendants" {
    # Parent bash spawns a child sleep; the trailing ':' stops bash exec-ing
    # the sleep (which would leave a single process, not a tree).
    setsid bash -c 'sleep 30 & sleep 30; :' & TEST_PID=$!
    # Wait for the child to appear under the parent.
    local child=""
    for _ in $(seq 1 40); do
        child=$(pgrep -P "$TEST_PID" | head -1)
        [ -n "$child" ] && break
        sleep 0.1
    done
    [ -n "$child" ] || skip "child never spawned"
    run fc "collect_subtree $TEST_PID; printf '%s\n' \"\${SUBTREE[@]}\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"$TEST_PID"* ]]   # root included
    [[ "$output" == *"$child"* ]]      # descendant included
}

@test "collect_subtree: single process yields exactly itself" {
    setsid sleep 30 & TEST_PID=$!
    # setsid may exec sleep directly (TEST_PID becomes the sleep) or fork; wait
    # until the PID resolves to a real process, then collect.
    for _ in $(seq 1 40); do [ -d "/proc/$TEST_PID" ] && break; sleep 0.1; done
    run fc "collect_subtree $TEST_PID; printf '%s' \"\${#SUBTREE[@]}\""
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "collect_subtree: gone PID yields empty (drives terminate_group's nproc==0 already-gone guard)" {
    # A never-allocated PID: collect_subtree must return an empty SUBTREE, which
    # is what terminate_group keys on to print "already gone" instead of falsely
    # reporting TERMINATED after signalling nothing.
    pid_max=$(cat /proc/sys/kernel/pid_max)
    run fc "collect_subtree $pid_max; printf '%s' \"\${#SUBTREE[@]}\""
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "collect_subtree: excludes our own process tree" {
    # The sourcing shell itself must never appear in a subtree rooted at it.
    run fc 'collect_subtree $$; printf "%s" "${#SUBTREE[@]}"'
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

# ── close_window ──────────────────────────────────────────────────────────

@test "close_window: nonexistent window id reports gone, no set -e death" {
    # 0xfffffff0 is not a real X window id; needs a reachable X display.
    run fc 'close_window 0xfffffff0 "test"; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"already gone"* ]]
    [[ "$output" == *"rc=0"* ]]
}

# ── is_self_tree ──────────────────────────────────────────────────────────

@test "is_self_tree: detects the sourcing shell itself" {
    run fc 'if is_self_tree $$; then echo SELF; else echo OTHER; fi'
    [ "$output" = "SELF" ]
}

@test "is_self_tree: PID 1 is not self" {
    run fc 'if is_self_tree 1; then echo SELF; else echo OTHER; fi'
    [ "$output" = "OTHER" ]
}
