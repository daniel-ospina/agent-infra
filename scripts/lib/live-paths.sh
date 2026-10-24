#!/usr/bin/env bash
# live-paths.sh — the ONE census of what live processes name on the filesystem (cwd, exe, argv).
#
# WHY THIS IS A LIBRARY AND NOT TWO COPIES. Two reclamation policies now need the same
# question answered — "is a live process inside this directory?" — for the same reason and with
# the same failure mode:
#
#   * `reap-abandoned-worktrees.sh` must not delete a `/tmp` worktree a lane is still sitting in;
#   * `reap-duplicate-installs.sh` must not delete a CI runner install whose listener/exe/argv is
#     inside it (a runner killed mid-job is a lost job — worse than a full disk).
#
# A second copy of this predicate is how the two drift, and the drift here is silent in the
# dangerous direction: the copy that forgets one arm deletes live work. So there is ONE census,
# ONE matching rule, and ONE fail-closed rule, and both owners source it.
#
# ⛔ THE POPULATION COMES FROM THE PROCESS TABLE, NEVER FROM `pgrep -f`. Measured 2026-10-24
# (#2542): `pgrep -f` self-matches the shell that runs the check (its own command line carries the
# pattern), and it matches the *pattern*, not the *population* — it shows the nesting stack of
# whatever launched the sweep rather than who is actually working. Reading `/proc/<pid>/cwd` for
# every pid is the predicate that earned its place: on the three cells it KEPT five directories
# whose age alone would have condemned them (`cell-wt-tmainred70` 226 m, `cell-wt-zombiepi` 742 m,
# `cell-wt-trebase6` 823 m, `cell-wt-venvlink` 1,080 m, `wt-pinfix` 2,200 m) while a live process
# sat inside each.
#
# ⛔ THIS IS THE SAME PROBE AS `scripts/orchestrator-harness/live-ownership.sh::lo_cwd_rows`, and
# that is deliberate: the merged #2594 hygiene pass (`root_excluded()`) proves per root whether a
# live process holds it from exactly this read. It is reimplemented here rather than sourced
# because `orchestrator-harness/` is NOT farmed (only `scripts/*.sh` and `scripts/lib/*` are), so a
# farmed reaper cannot resolve that file. If the two ever disagree about how a cwd is read, this
# one is wrong — the semantics are pinned by orchestrator-harness/claim-cwd.test.sh.
#
# WHAT A ROW IS. One line, TAB separated: `<kind>\t<pid>\t<path>` where kind is cwd | exe | arg.
# Paths are absolute, resolved through the kernel's own symlink (`/proc/<pid>/cwd`), with the
# kernel's ` (deleted)` suffix stripped — a process whose cwd was removed still NAMES the path we
# are about to reuse, so matching on the stripped form is the safe direction.
#
# FAIL-CLOSED (the whole point). `lp_census` returns 1 when the population cannot be read at all:
# no probe available, the probe produced nothing, or the probe command is missing. The CALLER must
# then skip its sweep and SAY SO — never read "could not enumerate" as "nothing is live". A PARTIAL
# read (this user cannot see root's /proc entries) is still a real census and is reported as one,
# with the count of unreadable pids, because refusing on a partial read would make every sweep on a
# real box permanently inert — the inert-enforcer shape this family exists to remove.
#
# READ-ONLY. This file deletes nothing and writes only inside the caller's census directory.
# Bounded: one `ls` over /proc (or one `lsof`), no per-pid fork, no recursion. The caller owns the
# watchdog — every invocation here is a handful of bulk reads.

# ── integer helper (no octal surprises: leading zeros parse as OCTAL inside $(( ))) ──────────────
lp_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

# lp_census <dir> — build <dir>/live-paths.tsv, and the counters in LP_*.
#   LP_CENSUS_ROWS  rows written
#   LP_CENSUS_PIDS  distinct pids seen (readable cwd OR exe OR argv)
# Returns 0 on a real census (including a partial one), 1 when it could not be read at all.
LP_CENSUS_ROWS=0; LP_CENSUS_PIDS=0; LP_CENSUS_MECH=""
lp_census() { # <dir>
    local dir="${1:-}" out probe proc="${LP_PROC_ROOT:-/proc}" rows pids
    [ -n "$dir" ] || return 1
    # ⛔ THE FAIL-CLOSED ARM NEEDS A SEAM A TEST CAN DRIVE ON EVERY HOST. Pointing /proc somewhere
    # missing is not enough: the macOS/container arm falls through to `lsof` and succeeds, so the
    # unreadable case would be untestable exactly where it matters (CI). This forces the SAME return
    # every arm produces when it cannot read the table — never a different code, never a different
    # message shape.
    if [ "${LP_CENSUS_UNAVAILABLE:-0}" = 1 ]; then LP_CENSUS_MECH="forced-unavailable"; return 1; fi
    mkdir -p "$dir" 2>/dev/null || return 1
    out="$dir/live-paths.tsv"
    : >"$out" 2>/dev/null || return 1
    LP_CENSUS_ROWS=0; LP_CENSUS_PIDS=0; LP_CENSUS_MECH=""

    if [ -d "$proc" ] && [ -e "$proc/self/cwd" ]; then
        # ── Linux: the kernel's own per-process links ──────────────────────────────────────────
        # ONE `ls` over the whole table (a per-pid probe is ~50ms x N and is what makes agents
        # abandon this kind of scan). Capture FIRST: a pipeline reports awk's status, so a broken
        # probe would otherwise look exactly like a census that found nobody.
        probe="${LP_LS_PROBE:-ls}"
        command -v "$probe" >/dev/null 2>&1 || return 1
        _lp_cwd="$("$probe" -l "$proc"/[0-9]*/cwd 2>/dev/null)"
        _lp_exe="$("$probe" -l "$proc"/[0-9]*/exe 2>/dev/null)"
        if [ -z "$_lp_cwd" ] && [ -z "$_lp_exe" ]; then
            LP_CENSUS_MECH="unreadable"
            return 1
        fi
        LP_CENSUS_MECH="/proc"
        {
            printf '%s\n' "$_lp_cwd" | _lp_parse_ls cwd
            printf '%s\n' "$_lp_exe" | _lp_parse_ls exe
            # argv: one small read per pid; absolute tokens only (a relative token names nothing
            # we could resolve, and resolving it against OUR cwd would be a lie).
            local _f _pid _tok
            for _f in "$proc"/[0-9]*/cmdline; do
                [ -r "$_f" ] || continue
                _pid="${_f#"$proc"/}"; _pid="${_pid%/cmdline}"
                lp_num "$_pid" || continue
                tr '\0' '\n' <"$_f" 2>/dev/null | while IFS= read -r _tok; do
                    case "$_tok" in /*) printf 'arg\t%s\t%s\n' "$_pid" "$_tok" ;; esac
                done
            done
        } >>"$out" 2>/dev/null
    else
        # ── no /proc (macOS, and the CI runner's own container): lsof for cwd + ps for argv ────
        # Same contract, same TSV. `lsof` is the population probe the macOS arm of
        # live-ownership.sh uses; `ps` supplies argv (its first token is the executable on every
        # platform we run, which is what an `exe` row means here).
        probe="${LP_LSOF_PROBE:-lsof}"
        command -v "$probe" >/dev/null 2>&1 || return 1
        _lp_raw="$("$probe" -w -a -d cwd -Fpn 2>/dev/null)" || return 1
        [ -n "$_lp_raw" ] || return 1
        LP_CENSUS_MECH="lsof"
        {
            printf '%s\n' "$_lp_raw" | awk '
                /^p/ { pid = substr($0, 2); next }
                /^n/ { p = substr($0, 2); sub(/ \(deleted\)$/, "", p)
                       if (pid ~ /^[0-9]+$/ && p ~ /^\//) printf "cwd\t%s\t%s\n", pid, p }'
            _lp_ps_probe="${LP_PS_PROBE:-ps}"
            command -v "$_lp_ps_probe" >/dev/null 2>&1 || return 0
            "$_lp_ps_probe" -axo pid=,args= 2>/dev/null | awk '
                { pid = $1; if (pid !~ /^[0-9]+$/) next
                  for (i = 2; i <= NF; i++) if ($i ~ /^\//) printf "arg\t%s\t%s\n", pid, $i }'
        } >>"$out" 2>/dev/null
    fi

    rows="$(wc -l <"$out" 2>/dev/null | tr -d ' ')"
    lp_num "$rows" || rows=0
    pids="$(awk -F'\t' 'NF==3 {print $2}' "$out" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
    lp_num "$pids" || pids=0
    LP_CENSUS_ROWS="$rows"; LP_CENSUS_PIDS="$pids"
    # A census with no cwd and no exe row read nothing we can prove idleness with.
    if [ "$rows" -eq 0 ]; then LP_CENSUS_MECH="unreadable"; return 1; fi
    if ! awk -F'\t' '$1=="cwd" || $1=="exe" {found=1; exit} END {exit(found?0:1)}' "$out" 2>/dev/null; then
        LP_CENSUS_MECH="no-cwd-or-exe"; return 1
    fi
    return 0
}

# _lp_parse_ls <kind> — stdin: `ls -l /proc/<pid>/{cwd,exe}` lines -> TSV rows.
#   lr-x------ 1 u g 0 Oct 24 07:11 /proc/123/cwd -> /tmp/wt-x
_lp_parse_ls() { # <kind>
    awk -v kind="$1" '
        match($0, /\/proc\/[0-9]+\/(cwd|exe)/) {
            pid = substr($0, RSTART + 6, RLENGTH - 10)
            i = index($0, " -> ")
            if (pid ~ /^[0-9]+$/ && i > 0) {
                t = substr($0, i + 4)
                sub(/ \(deleted\)$/, "", t)
                if (t ~ /^\//) printf "%s\t%s\t%s\n", kind, pid, t
            }
        }'
}

# _lp_rel <path> <base> — is <path> equal to <base> or under it? rc 0 yes.
# ⛔ BOUNDARY-AWARE, BOTH SIDES CANONICAL. A bare `case "$p" in "$base"*)` matches
# `/tmp/cell-wt-x-sibling` against `/tmp/cell-wt-x` and reads a live lane as free. Both sides are
# canonicalised by the caller (`lp_canon`); this test is the one place the boundary is decided.
_lp_rel() {
    local p="$1" b="$2"
    [ -n "$p" ] && [ -n "$b" ] || return 1
    [ "$p" = "$b" ] && return 0
    case "$p" in "$b"/*) return 0 ;; esac
    return 1
}

# lp_canon <path> — physical path, or empty when it cannot be resolved (never a guess).
lp_canon() { [ -n "${1:-}" ] && ( cd "$1" 2>/dev/null && pwd -P ); }

# lp_path_held <census-file> <path> — rc 0 when a live process's CWD or EXE is inside <path>.
# Sets LP_HOLD_WHY to a printable reason (`cwd pid 4242`), which is what a KEEP line must name.
LP_HOLD_WHY=""
lp_path_held() { # <census> <canonical-path>
    local f="$1" path="$2" kind pid p
    LP_HOLD_WHY=""
    [ -n "$path" ] && [ -r "$f" ] || return 1
    while IFS="$(printf '\t')" read -r kind pid p; do
        case "$kind" in cwd|exe) ;; *) continue ;; esac
        if _lp_rel "$p" "$path"; then LP_HOLD_WHY="$kind pid $pid"; return 0; fi
    done <"$f"
    return 1
}

# lp_path_named <census-file> <path> — rc 0 when a live process's ARGV names <path> (or something
# under it). This is the arm #2542 asks for by name: "never a root a live controller's
# /proc/<pid>/args names". A controller can be started from elsewhere and still hold the tree it
# was pointed at, so argv is a different witness from cwd.
LP_NAME_WHY=""
lp_path_named() { # <census> <canonical-path>
    local f="$1" path="$2" kind pid p
    LP_NAME_WHY=""
    [ -n "$path" ] && [ -r "$f" ] || return 1
    while IFS="$(printf '\t')" read -r kind pid p; do
        [ "$kind" = arg ] || continue
        if _lp_rel "$p" "$path"; then LP_NAME_WHY="argv pid $pid"; return 0; fi
    done <"$f"
    return 1
}

# lp_description — one line naming the mechanism and the population, for a pass to disclose.
lp_description() {
    printf 'live-paths census via %s: %s rows over %s pids' \
        "${LP_CENSUS_MECH:-none}" "${LP_CENSUS_ROWS:-0}" "${LP_CENSUS_PIDS:-0}"
}
