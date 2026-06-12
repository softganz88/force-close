#!/bin/bash
set -euo pipefail

# force-close.sh: Advanced Process Recovery & Deep Analysis Tool
# Version: 5.0.3
# Repo: github.com/softganz88/force-close
#
# Exit codes (CLI mode):
#   0 = all confirmed targets terminated (or user declined / nothing to do)
#   1 = no matching processes
#   2 = at least one target could not be terminated

# --- Configuration ---
STAGE_TIMEOUT=4        # seconds to wait after each kill stage
MEM_THRESHOLD=15       # %MEM above which a row is flagged
SUSPICIOUS_CPU=80      # %CPU above which a row is flagged

# --- Colors & Symbols ---
# Gate on the *value* of `tput colors`: under TERM=dumb it prints -1 but exits 0,
# and a failed setaf under set -e would kill the script before the first frame.
COLORS=0
if [[ -t 1 ]]; then COLORS=$(tput colors 2>/dev/null || echo 0); fi
if [[ "$COLORS" =~ ^[0-9]+$ ]] && (( COLORS >= 8 )); then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    MAGENTA=$(tput setaf 5)
    BLUE=$(tput setaf 4)
    WHITE=$(tput setaf 7)
    BOLD=$(tput bold)
    NC=$(tput sgr0)
    # setaf 8 emits a dangling SGR ('\E[38m') on 8-color terminals — gate it
    if (( COLORS >= 16 )); then GRAY=$(tput setaf 8); else GRAY=""; fi
else
    RED="" GREEN="" YELLOW="" MAGENTA="" BLUE="" WHITE="" GRAY="" BOLD="" NC=""
fi

# Semantic colors
SEP="${GRAY}"          # table separators — visible but subtle
MUTED="${WHITE}"       # background/idle processes — readable, not bright
ACCENT="${BLUE}${BOLD}" # header accents

# Box-drawing characters
readonly H="─" V="│" TL="┌" BL="└" TJ="┬" BJ="┴"

# tput clear fails (rc 2) when TERM is unset; fall back to the ANSI sequence
clear_screen() { tput clear 2>/dev/null || printf '\033[2J\033[H'; }

# --- Terminal hygiene ---
# Use the alternate screen so the tool doesn't clobber scrollback, and always
# restore a sane terminal (visible cursor, reset attributes, leave alt-screen)
# on ANY exit — including Ctrl-C, SIGTERM, or an unexpected set -e abort.
# Capability-gated: if the terminal lacks smcup/rmcup these are no-ops, so a
# dumb/unset TERM degrades cleanly instead of emitting stray escapes.
ALT_ACTIVE=0
TUI_ACTIVE=0
enter_tui() {
    [[ -t 1 ]] || return 0
    TUI_ACTIVE=1
    tput smcup 2>/dev/null && ALT_ACTIVE=1 || true
    tput civis 2>/dev/null || true   # hide cursor while drawing
}
restore_term() {
    # Never let this trap fail: under set -e a failing EXIT trap OVERRIDES the
    # script's exit status (exit 0/2/130 all became 1 in CLI mode, where
    # ALT_ACTIVE=0 made the old `(( ALT_ACTIVE )) && …` tail return nonzero).
    # Cursor/screen restoration is also gated on the TUI having started, so
    # CLI mode emits no stray escapes into pipeable output.
    if (( TUI_ACTIVE )); then
        tput cnorm 2>/dev/null || true   # cursor back on (hidden in enter_tui)
        (( ALT_ACTIVE )) && { tput rmcup 2>/dev/null || true; }
    fi
    printf '%s' "${NC:-}"            # drop any pending color (empty when not a tty)
    return 0
}
trap restore_term EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Check Dependencies ---
check_deps() {
    local missing=()
    for tool in wmctrl ps lsof pgrep tput awk sed sort xargs head; do
        command -v "$tool" &> /dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "${RED}Error: Missing required tools: ${missing[*]}${NC}"
        exit 1
    fi
}
check_deps

# --- X11 Check ---
if [[ -z "${DISPLAY:-}" ]]; then
    echo "${RED}Error: DISPLAY is not set. This tool requires an X11 display.${NC}"
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        echo "Tip: On Wayland, try XWayland or switch to an X11 session."
    fi
    exit 1
fi

# --- Self-identity (never list or signal our own process tree) ---
SELF_PGID=$(ps -o pgid= -p $$ | xargs) || SELF_PGID=""
SELF_SID=$(ps -o sid= -p $$ | xargs) || SELF_SID=""
SELF_ANCESTORS=" $$ "
_p=$$
while :; do
    _p=$(ps -o ppid= -p "$_p" 2>/dev/null | xargs) || _p=""
    [[ -n "$_p" && "$_p" != "0" && "$_p" != "1" ]] || break
    SELF_ANCESTORS+="$_p "
done
unset _p

# pid [pgid] [sid] — true if pid is us, an ancestor (our shell/terminal),
# or shares our process group or session
is_self_tree() {
    local pid="$1" pgid="${2:-}" sid="${3:-}"
    [[ "$SELF_ANCESTORS" == *" $pid "* ]] && return 0
    if [[ -z "$pgid" ]]; then
        pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | xargs) || pgid=""
    fi
    [[ -n "$pgid" && "$pgid" == "$SELF_PGID" ]] && return 0
    if [[ -z "$sid" ]]; then
        sid=$(ps -o sid= -p "$pid" 2>/dev/null | xargs) || sid=""
    fi
    [[ -n "$sid" && "$sid" == "$SELF_SID" ]] && return 0
    return 1
}

# --- Helper Functions ---

# Scale "12.3" → 123 (one implicit decimal); garbage/empty → 0. Fork-free
# replacement for the old bc pipeline (which silently returned false on any
# malformed operand — GNU bc exits 0 even on stdin syntax errors).
to10() { # $1=outvar $2=value
    local v="${2%%.*}" f="0"
    [[ "$2" == *.* ]] && { f="${2#*.}"; f="${f:0:1}"; }
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    [[ "$f" =~ ^[0-9]$ ]] || f=0
    printf -v "$1" '%s' "$(( 10#$v * 10 + 10#$f ))"
}
to10 CPU_WARN10 "$SUSPICIOUS_CPU"
to10 MEM_WARN10 "$MEM_THRESHOLD"
to10 CPU_IDLE10 "1.0"

# starttime (field 22 of /proc/pid/stat) — identity anchor against PID reuse.
# Sets STARTTIME ("" if the process is gone). Fork-free (read builtin).
get_starttime() {
    STARTTIME=""
    local s=""
    # Whole-file read (-d ''), not line-based: comm may contain a NEWLINE
    # (any process can write one into /proc/self/comm), which makes stat a
    # multi-line file — a line-based read parses garbage and returns "",
    # blinding the identity anchor. read exits nonzero at EOF but fills s.
    # 2>/dev/null must precede the input redirect, else a failed open on a
    # gone process leaks "No such file" before stderr is suppressed.
    read -r -d '' s 2>/dev/null < "/proc/$1/stat" || true
    [[ -n "$s" ]] || return 0
    s="${s##*) }"                # strip "pid (comm) " — comm may contain spaces/newlines
    local -a f
    read -r -a f <<< "$s"        # starttime = 20th field after state
    STARTTIME="${f[19]:-}"
}

# Sets WCHAN_RES. Fork-free (read builtin; wchan has no trailing newline,
# so read exits nonzero but still fills the variable).
get_wchan() {
    WCHAN_RES="locked/sys"
    local w=""
    if [[ -r "/proc/$1/wchan" ]]; then
        read -r w 2>/dev/null < "/proc/$1/wchan" || true
        if [[ "$w" == "0" ]]; then WCHAN_RES="running"
        elif [[ -n "$w" ]]; then WCHAN_RES="${w:0:12}"
        fi
    fi
}

# Collect a PID and all its descendants (children, grandchildren, …) into the
# SUBTREE array, breadth-first via /proc. We kill the subtree — NOT the process
# group — because on a desktop session every GUI app shares the session leader's
# process group (e.g. cinnamon-session); `kill -- -PGID` would take down the
# whole session. A process's descendants are its actual helpers/renderers.
# Re-snapshotted each stage so freshly-spawned children are caught.
collect_subtree() { # $1=root pid → fills global array SUBTREE
    SUBTREE=()
    local -a queue=("$1")
    local cur kid
    while (( ${#queue[@]} > 0 )); do
        cur="${queue[0]}"; queue=("${queue[@]:1}")
        # Never include our own tree (the terminal/script): a descendant scan
        # can't reach us, but a recycled PID could — cheap guard, hard safety.
        is_self_tree "$cur" && continue
        SUBTREE+=("$cur")
        for kid in $(pgrep -P "$cur" 2>/dev/null || true); do
            queue+=("$kid")
        done
    done
}

# Any non-zombie process left in the subtree? (Zombies can't be signaled away —
# counting them as alive would report FAILED forever on unreaped children.)
subtree_alive() { # $1=root pid
    collect_subtree "$1"
    local p st
    for p in "${SUBTREE[@]}"; do
        st=$(ps -o state= -p "$p" 2>/dev/null) || continue
        [[ "$st" == Z* ]] || return 0
    done
    return 1
}

wait_subtree_exit() { # root seconds → 0 once the subtree has no live members
    local i
    for (( i=$2; i>0; i-- )); do
        subtree_alive "$1" || return 0
        echo -n "·"; sleep 1
    done
    return 1
}

# Send a signal to every member of the subtree (leaves first via reverse order,
# so parents can't re-fork children we already signalled). Skips our own tree.
signal_subtree() { # $1=signal $2=root pid
    collect_subtree "$2"
    local i
    for (( i=${#SUBTREE[@]}-1; i>=0; i-- )); do
        kill "-$1" "${SUBTREE[i]}" 2>/dev/null || true
    done
}

# Gate between kill stages: 0=proceed 1=subtree-gone(success) 2=identity-changed(abort).
kill_gate() { # pid anchor_start
    local pid="$1" anchor="$2"
    subtree_alive "$pid" || return 1
    get_starttime "$pid"
    # Root still alive but identity changed → PID was reused; abort.
    [[ -n "$STARTTIME" && "$STARTTIME" != "$anchor" ]] && return 2
    return 0
}

# Char-aware truncate + pad into $1 (no command-substitution fork).
# Pads by character count, correct for accented text; CJK double-width
# cells are still off by design (bash has no wcwidth).
trunc_str() { # $1=outvar $2=str $3=len
    local s="$2" len="$3"
    (( ${#s} > len )) && s="${s:0:len-3}..."
    printf -v "$1" '%s%*s' "$s" $(( len - ${#s} )) ""
}

repeat_char() {
    local char="$1" count="$2" str=""
    printf -v str "%${count}s" ""
    printf '%s' "${str// /$char}"
}

# ERE-escape a literal string for pgrep -f (escapes [ ] \ . ^ $ * + ? ( ) { } |).
escape_pattern() { # $1=literal string → escaped pattern on stdout
    printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

# --- Table geometry — single source of truth ---
# Cells render as " field "; 6 │ separators; 1 leading space.
COL_W=(3 6 4 4 2 12 26)   # ID PID %CPU %MEM ST WCHAN TITLE
TITLE_W=${COL_W[6]}
TABLE_W=1
for _w in "${COL_W[@]}"; do TABLE_W=$(( TABLE_W + _w + 2 )); done
TABLE_W=$(( TABLE_W + 6 ))   # = 78; header/footer boxes use the same width
unset _w

_sep_line() { # $1 = junction char
    local out="" i n=${#COL_W[@]}
    for (( i=0; i<n; i++ )); do
        out+="$(repeat_char "$H" $(( COL_W[i] + 2 )))"
        (( i < n-1 )) && out+="$1"
    done
    printf '%s' "$out"
}
SEP_TOP=$(_sep_line "$TJ")
SEP_BOT=$(_sep_line "$BJ")

# These format strings must mirror COL_W above (alignment varies per column).
HDR_FMT=" ${ACCENT} %-3s ${SEP}${V}${ACCENT} %-6s ${SEP}${V}${ACCENT} %4s ${SEP}${V}${ACCENT} %4s ${SEP}${V}${ACCENT} %-2s ${SEP}${V}${ACCENT} %-12s ${SEP}${V}${ACCENT} %-26s${NC}\n"

# --- Precomputed frame chrome (invariant — built once, not per refresh) ---
_rule=$(repeat_char "═" $((TABLE_W - 2)))
_title="ADVANCED PROCESS RECOVERY & DEEP ANALYSIS"
_inner=$((TABLE_W - 2))
_pl=$(( (_inner - ${#_title}) / 2 ))
_pr=$(( _inner - ${#_title} - _pl ))
HEADER_BLOCK="${BLUE}╔${_rule}╗${NC}
${BLUE}║${NC}${BOLD}$(repeat_char " " $_pl)${_title}$(repeat_char " " $_pr)${NC}${BLUE}║${NC}
${BLUE}╚${_rule}╝${NC}"
unset _rule _title _inner _pl _pr

FOOTER_BLOCK=$(
    echo
    echo -e " ${BOLD}Legend:${NC}  ${RED}${BOLD}■${NC} Frozen/Stopped/Zombie  ${YELLOW}${BOLD}■${NC} High Usage  ${GRAY}■${NC} Background  ${GREEN}${BOLD}■${NC} Active"
    echo
    label=" Actions "
    fill_len=$(( TABLE_W - 2 - ${#label} - 1 ))
    echo -e " ${SEP}${TL}${H}${label}$(repeat_char "$H" $fill_len)${NC}"
    echo -e " ${SEP}${V}${NC}  ${BOLD}<id>${NC}  Terminate    ${BOLD}a <id>${NC}  Analyze    ${BOLD}r${NC}  Refresh    ${BOLD}q${NC}  Quit"
    echo -e " ${SEP}${BL}$(repeat_char "$H" $((TABLE_W - 2)))${NC}"
)

header() {
    clear_screen
    printf '%s\n\n' "$HEADER_BLOCK"
}

table_header() {
    printf "$HDR_FMT" "ID" "PID" "%CPU" "%MEM" "ST" "WCHAN" "APP / WINDOW TITLE"
    echo -e " ${SEP}${SEP_TOP}${NC}"
}

table_footer() {
    echo -e " ${SEP}${SEP_BOT}${NC}"
}

footer() {
    printf '%s\n' "$FOOTER_BLOCK"
}

# --- Core Logic ---

deep_analyze() {
    local pid="$1"
    local name="$2"
    header
    local rule
    rule=$(repeat_char "─" 60)

    # printf, not echo -e: window titles are attacker-influenced text
    printf ' %sDEEP ANALYSIS%s  %s\n' "${MAGENTA}${BOLD}" "$NC" "$name"
    printf ' %sPID: %s%s\n' "$GRAY" "$pid" "$NC"
    echo -e " ${SEP}${rule}${NC}"
    echo
    get_wchan "$pid"
    echo -e "  ${ACCENT}WCHAN${NC}  ${WCHAN_RES}"

    local pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | xargs) || true
    echo -e "  ${ACCENT}PGID${NC}   ${pgid:-N/A}"
    echo

    echo -e " ${SEP}${rule}${NC}"
    echo -e " ${BOLD}Open Files / Network Connections${NC}"
    echo -e " ${SEP}${rule}${NC}"
    # Capture first: lsof | head under pipefail SIGPIPEs lsof on big output
    # and the old fallback fired after a fully successful listing.
    local lsof_out cols
    cols=$(tput cols 2>/dev/null) || cols=80
    if ! [[ "$cols" =~ ^[0-9]+$ && "$cols" -ge 20 ]]; then cols=80; fi
    lsof_out=$(lsof -n -p "$pid" 2>/dev/null || true)
    if [[ -n "$lsof_out" ]]; then
        head -n 12 <<< "$lsof_out" | while IFS= read -r line; do
            echo "  ${line:0:cols-3}"   # truncate to terminal width, don't wrap
        done
    else
        echo "  No open-file data (process gone, or permission denied — try sudo)."
    fi

    echo -e "\n ${SEP}${rule}${NC}"
    echo -ne " Press ${BOLD}Enter${NC} to return... "
    read -r || true
}

KILL_FAILED=0

terminate_group() {
    local pid="$1"
    local name="$2"
    local anchor_start="${3:-}"   # starttime captured at listing time

    # Re-check identity right before killing to avoid race conditions
    local pgid sid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | xargs) || true
    if [[ -z "$pgid" ]]; then
        echo -e " ${RED}Process $pid is already gone.${NC}"
        sleep 1 ; return 0
    fi
    sid=$(ps -o sid= -p "$pid" 2>/dev/null | xargs) || sid=""

    # Never signal our own tree (self-kill guard)
    if is_self_tree "$pid" "$pgid" "$sid"; then
        echo -e " ${RED}Refusing: PID $pid is part of this tool's own process tree.${NC}"
        sleep 1 ; return 0
    fi

    # Session-group guard: when a process group leader is also a session leader
    # (pgid == sid), the group spans the entire desktop session — on Cinnamon/
    # GNOME every GUI app shares cinnamon-session's group. We never group-kill
    # anyway (we kill the subtree), but refuse outright if the *target itself*
    # is the session leader: terminating it tears down the whole session.
    if [[ -n "$sid" && "$pid" == "$sid" ]]; then
        echo -e " ${RED}Refusing: PID $pid is a session leader — terminating it would close every app in the session.${NC}"
        sleep 1 ; return 0
    fi

    # Identity anchor: the PID must still be the process the user saw listed
    get_starttime "$pid"
    if [[ -z "$STARTTIME" ]]; then
        echo -e " ${RED}Process $pid is already gone.${NC}"
        sleep 1 ; return 0
    fi
    if [[ -n "$anchor_start" && "$STARTTIME" != "$anchor_start" ]]; then
        echo -e " ${YELLOW}PID $pid was recycled by another process since listing — aborting.${NC}"
        sleep 1 ; return 0
    fi
    anchor_start="$STARTTIME"

    # Zombies cannot be killed — only the parent reaping them clears the entry
    local st ppid
    st=$(ps -o state= -p "$pid" 2>/dev/null | xargs) || st=""
    if [[ "$st" == Z* ]]; then
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | xargs) || ppid=""
        printf ' %sZombie:%s %s cannot be killed — its parent (PID %s) must reap it (or be terminated itself).\n' \
               "${YELLOW}${BOLD}" "$NC" "$name" "${ppid:-?}"
        KILL_FAILED=1
        sleep 1 ; return 0
    fi

    # Show how many processes the subtree covers so the user knows the blast
    # radius before confirming (1 = just this process; >1 = it has children).
    collect_subtree "$pid"
    local nproc=${#SUBTREE[@]}
    printf '\n %sCONFIRM%s Terminate %s%s%s (PID %s, %s process%s)? [y/N]: ' \
           "${RED}${BOLD}" "$NC" "$BOLD" "$name" "$NC" "$pid" "$nproc" "$([[ $nproc -ne 1 ]] && echo es)"
    local CONFIRM
    read -r CONFIRM || CONFIRM=""    # EOF = decline, never set -e death
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return 0; fi

    echo -e "\n ${BOLD}Kill Chain ${GRAY}PID: $pid ($nproc process tree)${NC}"

    # STAGE 1: X11 close — every window belonging to this PID, looked up fresh
    local wids w
    mapfile -t wids < <(wmctrl -lp 2>/dev/null | awk -v p="$pid" '$3 == p {print $1}' || true)
    if (( ${#wids[@]} > 0 )); then
        echo -ne "  ${GRAY}1/3${NC} Window close request "
        for w in "${wids[@]}"; do
            wmctrl -ic "$w" 2>/dev/null || true
        done
        if wait_subtree_exit "$pid" "$STAGE_TIMEOUT"; then
            echo -e "${GREEN}${BOLD} OK${NC}"; sleep 1; return 0
        fi
        echo -e " ${YELLOW}timeout${NC}"
    fi

    # Re-validate identity before escalating
    local gate=0
    kill_gate "$pid" "$anchor_start" || gate=$?
    if (( gate == 1 )); then
        echo -e "  ${GREEN}${BOLD}Process tree exited${NC}"; sleep 1; return 0
    elif (( gate == 2 )); then
        echo -e "  ${YELLOW}Process identity changed under us — aborting${NC}"; sleep 1; return 0
    fi

    # STAGE 2: subtree SIGTERM
    echo -ne "  ${GRAY}2/3${NC} SIGTERM (graceful)   "
    signal_subtree 15 "$pid"
    if wait_subtree_exit "$pid" "$STAGE_TIMEOUT"; then
        echo -e "${GREEN}${BOLD} OK${NC}"; sleep 1; return 0
    fi
    echo -e " ${YELLOW}timeout${NC}"

    # Re-validate before SIGKILL
    gate=0
    kill_gate "$pid" "$anchor_start" || gate=$?
    if (( gate == 1 )); then
        echo -e "  ${GREEN}${BOLD}Process tree exited${NC}"; sleep 1; return 0
    elif (( gate == 2 )); then
        echo -e "  ${YELLOW}Process identity changed under us — aborting${NC}"; sleep 1; return 0
    fi

    # STAGE 3: subtree SIGKILL
    echo -ne "  ${GRAY}3/3${NC} SIGKILL (forced)     "
    signal_subtree 9 "$pid"
    sleep 1
    if ! subtree_alive "$pid"; then
        echo -e "${GREEN}${BOLD} TERMINATED${NC}"
    else
        echo -e "${RED}${BOLD} FAILED${NC} ${GRAY}(survivors in tree — try with sudo)${NC}"
        KILL_FAILED=1
    fi
    echo -ne "\n Press ${BOLD}Enter${NC} to continue... " ; read -r || true
    return 0
}

# X11-close-only path for windows whose app sets no _NET_WM_PID (wmctrl PID
# column 0 — old Xt toolkits, some Wine windows). Without a PID there is
# nothing to signal, but the WM can still deliver a close request by window
# id; no escalation past the request is possible.
close_window() { # $1=window id (0x...) $2=name
    local wid="$1" name="$2" i

    if ! wmctrl -l 2>/dev/null | grep -q "^$wid "; then
        echo -e " ${RED}Window is already gone.${NC}"
        sleep 1 ; return 0
    fi

    printf '\n %sCONFIRM%s Close window %s%s%s (%s)? No PID — close request only. [y/N]: ' \
           "${RED}${BOLD}" "$NC" "$BOLD" "$wid" "$NC" "$name"
    local CONFIRM
    read -r CONFIRM || CONFIRM=""    # EOF = decline, never set -e death
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return 0; fi

    echo -ne "\n  Window close request "
    wmctrl -ic "$wid" 2>/dev/null || true
    for (( i=STAGE_TIMEOUT; i>0; i-- )); do
        if ! wmctrl -l 2>/dev/null | grep -q "^$wid "; then
            echo -e "${GREEN}${BOLD} OK${NC}"; sleep 1; return 0
        fi
        echo -n "·"; sleep 1
    done
    echo -e " ${YELLOW}window ignored the close request — no PID to escalate with${NC}"
    echo -ne "\n Press ${BOLD}Enter${NC} to continue... " ; read -r || true
    return 0
}

# --- Test hook ---
# When sourced (tests/force-close.bats), stop here: helpers and environment
# checks above are loaded, but no UI or kill path runs.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

# --- Main Interaction ---

if [[ -n "${1:-}" ]]; then
    # Escape the whole pattern. Self-matches (our own cmdline contains $1) are
    # removed by the identity filter below — no [f]irst-char trick needed (it
    # produced broken patterns for metachar-leading arguments).
    PATTERN=$(escape_pattern "$1")
    mapfile -t PIDS < <(pgrep -f "$PATTERN" 2>/dev/null || true)
    FILTERED=()
    for pid in "${PIDS[@]}"; do
        [[ -z "$pid" ]] && continue
        is_self_tree "$pid" && continue
        # Drop already-gone matches (incl. the transient pgrep process-substitution
        # subshell, which inherits our cmdline and matches but exits immediately)
        get_starttime "$pid"
        [[ -z "$STARTTIME" ]] && continue
        FILTERED+=("$pid")
    done
    if [[ ${#FILTERED[@]} -eq 0 ]]; then
        printf '%sNo matching processes found for: %s%s\n' "$YELLOW" "$1" "$NC"
        exit 1
    fi
    printf '%sFound %d matching process(es) for: %s%s\n' "$BOLD" "${#FILTERED[@]}" "$1" "$NC"
    for pid in "${FILTERED[@]}"; do
        NAME=$(ps -p "$pid" -o comm= 2>/dev/null) || continue
        NAME="${NAME//[![:print:]]/}"
        get_starttime "$pid"
        terminate_group "$pid" "$NAME" "$STARTTIME"
    done
    (( KILL_FAILED )) && exit 2
    exit 0
fi

declare -A MAP_PID MAP_NAME MAP_START MAP_WID
declare -A PS_CPU PS_MEM PS_STATE PS_PGID PS_SID

enter_tui   # alt-screen for the interactive loop only (CLI mode stays linear)

while true; do
    header
    table_header

    WINDOW_DATA=$(wmctrl -lp 2>/dev/null | sort -k3 -n || true)

    COUNT=1
    MAP_PID=(); MAP_NAME=(); MAP_START=(); MAP_WID=()
    PS_CPU=(); PS_MEM=(); PS_STATE=(); PS_PGID=(); PS_SID=()

    # Pass 1: collect PIDs, then fetch stats for all of them with ONE ps call
    # (the old loop forked ps + 2×bc + a subshell per window per refresh)
    pids=()
    while read -r _ _ PID _ _; do
        [[ -n "$PID" && "$PID" != "0" ]] && pids+=("$PID")
    done <<< "$WINDOW_DATA"

    if (( ${#pids[@]} > 0 )); then
        printf -v _idlist '%s,' "${pids[@]}"
        while read -r _pid _pgid _sid _cpu _mem _st; do
            [[ -n "$_pid" ]] || continue
            PS_PGID[$_pid]=$_pgid; PS_SID[$_pid]=$_sid
            PS_CPU[$_pid]=$_cpu;   PS_MEM[$_pid]=$_mem
            PS_STATE[$_pid]=$_st
        done < <(ps -o pid=,pgid=,sid=,pcpu=,pmem=,state= -p "${_idlist%,}" 2>/dev/null || true)
    fi

    # Pass 2: render rows
    while read -r _WID _DESKTOP PID _HOST TITLE; do
        [[ -z "${PID:-}" ]] && continue

        # Strip control bytes — titles are attacker-influenced (web page titles)
        TITLE="${TITLE//[![:print:]]/}"

        if [[ "$PID" == "0" ]]; then
            # App sets no _NET_WM_PID (old Xt toolkits, some Wine windows):
            # PID unknown → signals impossible, but an X11 close request only
            # needs the window id. List as a close-only row instead of hiding it.
            PID_CELL="?" ; CPU="-" ; MEM="-" ; STATE="?" ; WCHAN_RES="no PID hint"
            COLOR="${MUTED}"
            MAP_PID[$COUNT]="" ; MAP_WID[$COUNT]=$_WID ; MAP_START[$COUNT]=""
        else
            [[ -n "${PS_STATE[$PID]+x}" ]] || continue

            # Never list our own tree (incl. the terminal hosting this script —
            # killing it takes the script down mid-chain)
            is_self_tree "$PID" "${PS_PGID[$PID]}" "${PS_SID[$PID]}" && continue

            PID_CELL="$PID"
            CPU="${PS_CPU[$PID]}" ; MEM="${PS_MEM[$PID]}" ; STATE="${PS_STATE[$PID]}"
            get_wchan "$PID"
            cpu10=0 ; mem10=0    # assigned indirectly via printf -v in to10
            to10 cpu10 "$CPU" ; to10 mem10 "$MEM"

            # Color priority: active < background < high usage < frozen/stopped/zombie
            COLOR="${GREEN}"
            if [[ "$STATE" == S* ]] && (( cpu10 <= CPU_IDLE10 )); then COLOR="${MUTED}"; fi
            if (( cpu10 > CPU_WARN10 || mem10 > MEM_WARN10 )); then COLOR="${YELLOW}${BOLD}"; fi
            if [[ "$STATE" == [DZTt]* ]]; then COLOR="${RED}${BOLD}"; fi

            MAP_PID[$COUNT]=$PID
            get_starttime "$PID"
            MAP_START[$COUNT]="$STARTTIME"
        fi

        trunc_str TITLE_CELL "$TITLE" "$TITLE_W"
        # Widths mirror COL_W (see table geometry above)
        printf " ${COLOR} %3s ${NC}${SEP}${V}${NC}${COLOR} %-6s ${NC}${SEP}${V}${NC}${COLOR} %4s ${NC}${SEP}${V}${NC}${COLOR} %4s ${NC}${SEP}${V}${NC}${COLOR} %-2s ${NC}${SEP}${V}${NC}${COLOR} %-12s ${NC}${SEP}${V}${NC}${COLOR} %s${NC}\n" \
               "$COUNT" "$PID_CELL" "$CPU" "$MEM" "$STATE" "$WCHAN_RES" "$TITLE_CELL"

        MAP_NAME[$COUNT]="$TITLE"
        COUNT=$((COUNT + 1))
    done <<< "$WINDOW_DATA"

    table_footer
    echo -e " ${GRAY}$((COUNT - 1)) window(s) listed${NC}"
    footer
    echo -ne "\n ${BOLD}Selection ${BLUE}▸${NC} "
    read -r CHOICE || { echo; exit 0; }    # EOF = quit cleanly

    case "$CHOICE" in
        q) exit 0 ;;
        r) continue ;;
        a\ *)
            ID=${CHOICE#a }; ID=${ID// /}    # drop any spaces (e.g. "a  3")
            if [[ "$ID" =~ ^[0-9]+$ ]]; then
                ID=$(( 10#$ID ))             # normalize leading zeros to match keys
                if [[ -n "${MAP_PID[$ID]+x}" ]]; then
                    if [[ -n "${MAP_PID[$ID]}" ]]; then
                        deep_analyze "${MAP_PID[$ID]}" "${MAP_NAME[$ID]}"
                    else
                        echo "No PID for this window (its app sets no _NET_WM_PID) — analysis unavailable." ; sleep 2
                    fi
                else
                    echo "Invalid ID: $ID" ; sleep 1
                fi
            else
                echo "Invalid ID: ${ID:-(none)}" ; sleep 1
            fi
            ;;
        [0-9]*)
            if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
                ID=$(( 10#$CHOICE ))         # normalize leading zeros to match keys
                if [[ -n "${MAP_PID[$ID]+x}" ]]; then
                    if [[ -n "${MAP_PID[$ID]}" ]]; then
                        terminate_group "${MAP_PID[$ID]}" "${MAP_NAME[$ID]}" "${MAP_START[$ID]}"
                    else
                        close_window "${MAP_WID[$ID]}" "${MAP_NAME[$ID]}"
                    fi
                else
                    echo "Invalid ID: $ID" ; sleep 1
                fi
            else
                echo "Invalid ID: $CHOICE" ; sleep 1
            fi
            ;;
        *) echo "Invalid choice." ; sleep 1 ;;
    esac
done
