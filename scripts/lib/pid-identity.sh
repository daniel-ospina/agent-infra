#!/usr/bin/env bash
# pid-identity.sh — the fleet's ONE process-identity rule (#1178).
#
# WHY THIS FILE EXISTS
# --------------------
# "Does this pid still hold this session?" is a safety question with two
# consumers in two languages: the reviewed kill path (scripts/pi-reap-idle.sh,
# Bash) and the fleet liveness classifier (tools/fleet/liveness.py, Python).
# Before #1178 each formed its own opinion — and a Python module cannot source a
# Bash function, while `pi-bootstrap/setup.sh` farms individual files. So the
# rule is extracted ONCE here and exposed both as sourceable functions (the
# reaper) and as a process-boundary CLI (the classifier).
#
# THE RULE
# --------
#   1. A cmux record's `pidStartSeconds` (a store value) must be a usable
#      decimal before it is fed to any arithmetic — see `store_number_ok`
#      (`$(( ))` re-parses an operand as an ARITHMETIC EXPRESSION).
#   2. A pid HOLDS the session its record names only if a FRESH ps read shows
#      it present, NOT a zombie (`Z*`), and its `lstart` is within
#      ±FENCE_TOLERANCE_SECONDS of the recorded start.
#   3. The fence exists because second-granularity rounding differs up to ~1s
#      in live data. Its whole purpose is to make an identity UNCERTAINTY fail
#      safe: an off-fence process is an ABSTENTION, never a death witness.
#      This is the direction scripts/pi-reap-idle.sh already takes
#      (`[ "$diff" -gt "$FENCE_TOLERANCE_SECONDS" ] && continue  # stale
#      sibling: no vote`, and `SKIP incarnation-unmatched` when nothing
#      matches) — cite the reaper, do not invent the direction (#1178 C1).
#
# PROBE CLI CONTRACT (the process boundary a non-Bash consumer uses)
# -----------------------------------------------------------------
#   pid-identity.sh probe <pid> <startSeconds>   # a cmux record's incarnation
#   pid-identity.sh probe-argv <pid>             # the process claims its own session
#   pid-identity.sh argv-candidates <sid>        # pids whose argv names <sid>
#
# Exit codes — the ONLY thing that may witness "dead" is exit 1:
#   0  HOLDER     present, live (not a zombie), and fence-matched (probe), or
#                 self-claimed by argv (probe-argv).
#   1  POSITIVELY NOT A HOLDER — the pid was OBSERVED absent from a fresh ps
#                 read, or OBSERVED as a zombie. Dead-witness shape.
#   2  UNKNOWN    the read failed or the table was empty, `lstart` was
#                 unparseable, the recorded startSeconds was unusable, or the
#                 process is live but OFF-FENCE. NEVER witnesses "dead" (C1).
#
# stdout is one line: "<status> key=value ..." with status in
#   holder | absent | zombie | off-fence | unknown
#
# `unknown` is a distinct EXIT CODE (2) from `absent`/`zombie` (1) by design: a
# probe that conflated them would manufacture "dead" out of a failed `ps`
# invocation (#1178 C3). `argv-candidates` exits 2 when its read failed, so a
# broken read can never read as "no candidates".
#
# SOURCING
# --------
# Sourced by scripts/pi-reap-idle.sh (functions + globals) and executed directly
# for the CLI (guarded main, the same pattern as scripts/record-review.sh:120).
# This file deliberately does NOT call `set` — a sourced library must not mutate
# its caller's shell options (`pi-reap-idle.sh` runs `set -uo pipefail` with NO
# `-e`). Every function defaults its parameters, so the direct CLI path is safe
# with or without `-u`.

# ── config ─────────────────────────────────────────────────────────────
# Defaulted here (not only in each caller) so that `set -u` cannot abort the
# guarded main when the file is executed directly (#1178 C7).
PS_BIN="${PS_BIN:-/bin/ps}"
DATE_BIN="${DATE_BIN:-/bin/date}"
# ±3s: second-granularity rounding differs up to ~1s in live data.
FENCE_TOLERANCE_SECONDS="${FENCE_TOLERANCE_SECONDS:-3}"
DATE_MODE=""

# ── date capability probe + lstart parsing (moved verbatim from the reaper) ──
# date_bin_probe_mode — capability-probe ${DATE_BIN} (never uname): feed a
# BSD-shaped invocation; exit 0 => BSD -j branch, else GNU -d branch. A
# macOS-shape-only stub therefore forces the BSD branch on ANY platform.
date_bin_probe_mode() {
    if [ -n "$DATE_MODE" ]; then printf '%s\n' "$DATE_MODE"; return 0; fi
    if LC_ALL=C "$DATE_BIN" -j -f '%a %b %e %H:%M:%S %Y' 'Sat Jan  1 00:00:00 2000' +%s >/dev/null 2>&1; then
        DATE_MODE=bsd
    else
        DATE_MODE=gnu
    fi
    printf '%s\n' "$DATE_MODE"
}

# lstart_to_epoch <ps-lstart-str> — "Sat Sep  5 12:34:56 2026" OR the
# real macOS ps day-first order "Sat  5 Sep 12:34:56 2026" -> epoch.
# Both orders are attempted on the BSD branch (ps lstart has shipped both).
# Prints 0 when the parse failed — callers must treat 0 as "unparseable",
# never as an epoch.
lstart_to_epoch() {
    local lstart="${1:-}" mode fmt e
    mode="$(date_bin_probe_mode)"
    if [ "$mode" = bsd ]; then
        for fmt in '%a %b %e %H:%M:%S %Y' '%a %e %b %H:%M:%S %Y'; do
            e="$(LC_ALL=C "$DATE_BIN" -j -f "$fmt" "$lstart" +%s 2>/dev/null)"
            if [ -n "$e" ] && [ "$e" -gt 0 ] 2>/dev/null; then printf '%s\n' "$e"; return 0; fi
        done
        echo 0
    else
        LC_ALL=C "$DATE_BIN" -d "$lstart" +%s 2>/dev/null || echo 0
    fi
}

# ── untrusted store numbers ────────────────────────────────────────────
# store_number_ok <value> <now> — the strictness gate for EVERY store-derived
# number this library (and the reaper) does arithmetic on. Store values are
# UNTRUSTED: bash `$(( ))` re-parses an operand as an ARITHMETIC EXPRESSION, so
# a crafted `pidStartSeconds` of the form `epoch[$(cmd)]` EXECUTES code as the
# user while a bare word aborts the pass. Only a strict decimal inside a
# plausible epoch window passes; callers ignore anything else (fail closed — an
# unusable stamp can only withhold a verdict, never cause one). Arithmetic on an
# accepted value is still done through `awk -v`, which never evaluates.
store_number_ok() {
    local v="$1" now="$2"
    grep -qE '^[0-9]+(\.[0-9]+)?$' <<<"$v" || return 1
    awk -v u="$v" -v n="$now" 'BEGIN{exit !(u >= 1000000000 && u <= n + 86400)}'
}
updated_stamp_ok() { store_number_ok "$1" "$2"; }

# positive_int <value> — 0 when the value is a plain positive decimal integer.
positive_int() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -gt 0 ] 2>/dev/null
}

# ── the fence ──────────────────────────────────────────────────────────
# pid_fence_diff <ps_epoch> <recorded_start> -> |difference| (integer).
# Both operands must already have passed store_number_ok / positive_int.
pid_fence_diff() {
    awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if (d<0) d=-d; printf "%d", d}'
}

# ── ps read ────────────────────────────────────────────────────────────
# The pinned ps contract — the SAME shape scripts/pi-reap-idle.sh enumerates
# with, so there is one table contract and one parser for the fleet.
pid_ps_table() {
    "$PS_BIN" -axo pid=,ppid=,pgid=,tty=,lstart=,stat=,rss=,command= 2>/dev/null
}

# pid_table_nonempty <table> — 0 when the read produced at least one
# non-whitespace byte. A read that "succeeds" but prints no table is not "no
# such process" — the probing process itself must appear in any real table —
# so an empty table is an UNREADABLE read, never absence (#1178 C3).
pid_table_nonempty() {
    case "${1:-}" in
        *[![:space:]]*) return 0 ;;
        *) return 1 ;;
    esac
}

# pid_row <pid> — look the pid up in a FRESH ps table.
# stdout: "<lstart>|<stat>"; rc: 0 found, 1 positively absent, 2 unreadable.
# The 1-vs-2 split is the whole point (#1178 C3): only a read that RAN and
# produced a table can witness absence.
pid_row() {
    local pid="${1:-}" table row
    case "$pid" in ''|*[!0-9]*) return 2 ;; esac
    table="$(pid_ps_table)" || return 2
    pid_table_nonempty "$table" || return 2
    row="$(awk -v p="$pid" '
        $1 == p {
            # fields: pid ppid pgid tty lstart... stat rss command — the year
            # token ends lstart; scan from field 5 so a 4-digit ppid/pgid can
            # never be mistaken for the year.
            yr = 0
            for (i = 5; i <= NF; i++) { if ($i ~ /^[0-9]{4}$/) { yr = i; break } }
            if (yr == 0) next
            l = ""
            for (j = 5; j <= yr; j++) { l = (l == "" ? $j : l " " $j) }
            print l "|" $(yr + 1)
            exit
        }' <<<"$table")"
    [ -n "$row" ] || return 1
    printf '%s\n' "$row"
    return 0
}

# ── the probe ──────────────────────────────────────────────────────────
# pid_probe <pid> <recorded-startSeconds> — see the CLI contract above.
pid_probe() {
    local pid="${1:-}" rec="${2:-}" row rc lstart stat ps_epoch diff
    row="$(pid_row "$pid")"; rc=$?
    if [ "$rc" != 0 ]; then
        if [ "$rc" = 1 ]; then
            printf '%s\n' "absent pid=$pid"
        else
            printf '%s\n' "unknown pid=$pid reason=ps-read-failed"
        fi
        return "$rc"
    fi
    lstart="${row%%|*}"
    stat="${row##*|}"
    case "$stat" in
        Z*) printf '%s\n' "zombie pid=$pid stat=$stat"; return 1 ;;
    esac
    ps_epoch="$(lstart_to_epoch "$lstart")"
    if ! positive_int "$ps_epoch"; then
        printf '%s\n' "unknown pid=$pid reason=unparseable-lstart"; return 2
    fi
    # A store value: gate it before ANY arithmetic. An unusable stamp abstains.
    if ! store_number_ok "$rec" "$ps_epoch"; then
        printf '%s\n' "unknown pid=$pid reason=unusable-start-seconds"; return 2
    fi
    diff="$(pid_fence_diff "$ps_epoch" "$rec")"
    if [ "$diff" -le "$FENCE_TOLERANCE_SECONDS" ]; then
        printf '%s\n' "holder pid=$pid ps_epoch=$ps_epoch fence=$diff"; return 0
    fi
    # Live but off-fence: an identity UNCERTAINTY. Abstain (exit 2) — never a
    # death witness (#1178 C1).
    printf '%s\n' "off-fence pid=$pid ps_epoch=$ps_epoch rec=$rec diff=$diff"; return 2
}

# pid_probe_argv <pid> — the process ITSELF claims the session (`pi --session
# <id>` / `pi -r <id>`), so no fence is needed: the argv is a direct identity
# claim, not a pid-indexed tag that a reused pid could inherit. This is the
# candidate source that stops a resumed session holding a STALE record (dead
# pid) from being declared dead (#1178 C2).
pid_probe_argv() {
    local pid="${1:-}" row rc stat
    row="$(pid_row "$pid")"; rc=$?
    if [ "$rc" != 0 ]; then
        if [ "$rc" = 1 ]; then
            printf '%s\n' "absent pid=$pid"
        else
            printf '%s\n' "unknown pid=$pid reason=ps-read-failed"
        fi
        return "$rc"
    fi
    stat="${row##*|}"
    case "$stat" in
        Z*) printf '%s\n' "zombie pid=$pid stat=$stat"; return 1 ;;
    esac
    printf '%s\n' "holder pid=$pid claimed=argv"
    return 0
}

# pid_argv_candidates <sid> — pids whose argv names <sid> in a resume form.
# One pid per line. rc 0 on a successful read (possibly zero pids); rc 2 when
# the read failed or the sid is unusable — a failed read must never read as
# "no candidates".
pid_argv_candidates() {
    local sid="${1:-}" table
    case "$sid" in
        ''|*[*?[]*|*[[:space:]]*) return 2 ;;
    esac
    table="$(pid_ps_table)" || return 2
    pid_table_nonempty "$table" || return 2
    awk -v s="$sid" '
        {
            yr = 0
            for (i = 5; i <= NF; i++) { if ($i ~ /^[0-9]{4}$/) { yr = i; break } }
            if (yr == 0) next
            cmd = ""
            for (j = yr + 3; j <= NF; j++) { cmd = (cmd == "" ? $j : cmd " " $j) }
            n = split(cmd, parts, /[ \t]+/)
            for (k = 1; k <= n; k++) {
                if ((parts[k] == "--session" || parts[k] == "-r" || parts[k] == "--resume") &&
                    k + 1 <= n && parts[k + 1] == s) { print $1; break }
                if (parts[k] == "--session=" s) { print $1; break }
            }
        }' <<<"$table"
    return 0
}

# ── guarded main (executable when run, inert when sourced) ─────────────
pid_identity_usage() {
    printf '%s\n' "usage: pid-identity.sh probe <pid> <startSeconds>" \
                  "       pid-identity.sh probe-argv <pid>" \
                  "       pid-identity.sh argv-candidates <sid>" >&2
}

pid_identity_main() {
    local cmd="${1:-}"
    case "$cmd" in
        probe)
            if [ $# -ne 3 ]; then pid_identity_usage; return 2; fi
            pid_probe "$2" "$3" ;;
        probe-argv)
            if [ $# -ne 2 ]; then pid_identity_usage; return 2; fi
            pid_probe_argv "$2" ;;
        argv-candidates)
            if [ $# -ne 2 ]; then pid_identity_usage; return 2; fi
            pid_argv_candidates "$2" ;;
        *)
            pid_identity_usage; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    pid_identity_main "$@"
    exit $?
fi
