#!/usr/bin/env bash
# pi-cache-reap.sh — bound the MACHINE-GLOBAL package caches (agent-infra#1987).
#
# WHY THIS EXISTS (the measured defect)
# -------------------------------------
# `pi-cell-3` (vm-915c3930c4e94e4884229d974522d05d, 32 GB disk) reached 258 MB
# free and refused every dispatch:
#
#     /tmp/cell-home/.cache/uv    7.1 GB
#     df /                        258M free   ->  ABORT: disk 258MB < 1200MB
#
# Clearing ONLY the package cache freed 7.1 GB and the same box immediately
# launched a lane (258 MB -> 7.7 GB free). The cache is not per-lane: `~/.cache/uv`
# accumulates every `uv sync`/`uv run` ANY lane on that box performs, so it grows
# without bound on exactly the boxes that dispatch most — and it fails in the most
# misleading way, because the controller keeps beating, the queue reads fine, and
# every dispatch is refused for disk.
#
# The existing reapers do not cover it, by construction:
#   * pi-reap-worktrees.sh (#1095) reaps a LANE's checkout, per worktree;
#   * cloud-cell-supervisor.sh `prune` sweeps per-worktree `.venv`/`node_modules`/
#     `.pytest_cache`/`__pycache__` (sweep_root_caches) — every one of them is
#     resolved from a worktree root. Nothing on that path can reach `$HOME/.cache/uv`,
#     which is where the space actually went.
# This script is that missing owner for the shared sinks: uv, npm and pip.
#
# POLICY CONTRACT
#   * BOUNDED BY SIZE, never by age. Package-cache entries stay "recently used"
#     for as long as any lane resolves against them, and the failure mode is a
#     byte bound being crossed, not an entry getting old. `CACHE_REAP_MAX_MB`
#     (default 2048) is therefore a ceiling PER CACHE, checked every pass.
#   * PRUNE FIRST, then escalate — and escalate only what nothing is holding.
#     `uv cache prune` / `npm cache verify` remove UNUSED entries and are safe to
#     run while a lane works. Only if the cache is STILL over its bound does the
#     pass remove entries itself, largest first, and only after reading the process
#     table: a live `uv`/`npm`/`pip` process preserves the WHOLE cache (we cannot
#     know what it is resolving against), while a process whose argv merely NAMES
#     one entry preserves exactly that entry and nothing else. That distinction is
#     measured, not hypothetical: `uv` leaks build-backend processes inside
#     `$CACHE/builds-v0/.tmp*` (ppid 1, hours old, never exiting — three were
#     running on pi-cell-3), and a whole-cache veto on those is the same
#     never-reaps non-action this script exists to remove. Anything preserved is
#     REPORTED; nothing is ever raced.
#   * ALWAYS ONE LINE PER CACHE, with the before/after bytes in it. A reaper whose
#     log cannot be read at a glance is indistinguishable from one that did nothing.
#   * REFUSE-TO-ACT VERIFICATION (the point of #1987's item 4). A pass that acted on
#     a cache must PROVE the reclaim:
#       - the cache's own size must have decreased, AND
#       - the filesystem must actually gain free space, at least
#         CACHE_REAP_MIN_RECLAIM_PCT (default 50) of what the cache gave up.
#     Anything else is exit 3 with the reason. This is not pedantry — a uv cache
#     entry is HARDLINKED into every `.venv` built from it, so unlinking entries can
#     free ZERO bytes while the cache's apparent size drops by gigabytes. MEASURED
#     on pi-cell-3 while this script was being written: 914 MB of cache evicted,
#     7 MB of disk gained. A pass that reports that as a success is exactly "a
#     reaper reports success while freeing nothing", the failure mode #1987 names.
#   * STOP DESTROYING WHAT IS NOT RECLAIMING. Two consecutive evictions with no free
#     -space gain end the escalation. A cache is a performance asset; trading it for
#     nothing is damage, so the pass stops and reports instead of emptying it.
#   * FAIL CLOSED: a cache that cannot be MEASURED (unreadable, `du` failed, a
#     relative/empty path) is exit 3, never a pass. Same for an unusable `ps`
#     probe when escalation is needed. No pass may exit 0 on an unverified claim.
#
# SCHEDULING (one owner, two triggers — deliberate, not duplicated machinery)
#   * Mac:   templates/launchd/com.eldato.pi-cache-reap.plist (hourly, --apply).
#   * Cell:  a Linux cell has no launchd; its only scheduler is the controller
#            loop, which runs this hourly from scripts/orchestrator-harness/
#            orch-loop.sh (next to its hourly claim_prune). The reaper is the
#            single owner of the POLICY in both cases; the two triggers only
#            decide when it runs, and a pass is idempotent and cheap when a
#            cache is under its bound.
#   * Operator verbs also reach it: `cloud-cell-supervisor.sh prune --caches`
#            (the low-disk remedy, agent-infra#1745) and `cloud-cell-bringup.sh
#            --check` (which now REPORTS the sizes, so a growing disk is visible
#            before it stops dispatch).
#
# Usage:
#   pi-cache-reap.sh [--dry-run] [--apply] [--help]
#
#   (no mode flag)  dry-run: measure + report what WOULD be done, mutate nothing
#   --dry-run       explicit dry-run
#   --apply         armed pass (or env CACHE_REAP_APPLY=1)
#   --help          this text
#
# Env seams (also the test suite's):
#   CACHE_REAP_MAX_MB     per-cache ceiling in MiB (default 2048)
#   CACHE_REAP_UV_DIR     uv cache dir      (default $UV_CACHE_DIR, else $HOME/.cache/uv)
#   CACHE_REAP_NPM_DIR    npm cacache dir   (default $HOME/.npm/_cacache)
#   CACHE_REAP_PIP_DIR    pip cache dir     (default $HOME/.cache/pip; the macOS
#                         ~/Library/Caches/pip is probed as a second candidate)
#   CACHE_REAP_APPLY      "1" arms the pass (equivalent to --apply)
#   CACHE_REAP_MIN_RECLAIM_PCT  share of the claimed reduction that must appear as
#                         free disk before a pass counts as verified (default 50)
#   CACHE_REAP_LOG        pass log (default $HOME/.pi/agent/state/pi-cache-reap.log)
#   CACHE_REAP_LOG_MAX_BYTES  rotate the log past this size (default 1 MiB)
#   CACHE_REAP_PS         ps binary  (default /bin/ps)
#   CACHE_REAP_DF         df binary  (default df)
#   CACHE_REAP_UV/NPM/PIP the tool binaries used for the PRUNE step
#   CACHE_REAP_PIP_DIR_MAC  the macOS pip cache candidate (default
#                         $HOME/Library/Caches/pip)
#
# Exit codes: 0 bounded / reclaim verified · 2 usage · 3 fail-closed (the cache could
# not be measured, a live tool run made eviction unsafe, or the reclaim could not be
# verified).

set -uo pipefail

SCRIPT_NAME="pi-cache-reap.sh"
ISSUE_REF="#1987"
TAB="$(printf '\t')"

MAX_MB="${CACHE_REAP_MAX_MB:-2048}"
PS_BIN="${CACHE_REAP_PS:-/bin/ps}"
DF_BIN="${CACHE_REAP_DF:-df}"
UV_BIN="${CACHE_REAP_UV:-uv}"
NPM_BIN="${CACHE_REAP_NPM:-npm}"
PIP_BIN="${CACHE_REAP_PIP:-pip}"
LOG="${CACHE_REAP_LOG:-${HOME:-}/.pi/agent/state/pi-cache-reap.log}"
LOG_MAX_BYTES="${CACHE_REAP_LOG_MAX_BYTES:-1048576}"

MODE=dry-run
FAILS=0
TMPLIST=""

usage() {
    sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

# ── helpers ───────────────────────────────────────────────────────────────────
say() { printf '%s\n' "$*"; plog "$*"; }
plog() {
    [ -n "$LOG" ] || return 0
    printf '%s\n' "$*" >>"$LOG" 2>/dev/null || true
}

# fail_closed <reason> — report a pass that could not finish honestly, and
# remember it. The final exit code is 3 if ANY arm failed: partial verification
# of four caches is not a pass.
fail_closed() {
    FAILS=$((FAILS + 1))
    say "pi-cache-reap: FAIL-CLOSED — $*"
}

cleanup() { [ -n "$TMPLIST" ] && rm -f "$TMPLIST"; }
trap cleanup EXIT

# kb_of <dir> — size of <dir> in KiB on stdout; non-zero (and nothing usable) when
# it cannot be MEASURED. Callers must treat that as fail-closed, never as 0.
kb_of() {
    local kb
    kb="$(du -sk "$1" 2>/dev/null | awk 'NR==1 {print $1}')"
    case "${kb:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$kb"
}

mb_str() { # $1 = KiB -> a size that is honest at both scales (bash 3.2: no floats)
    local kb="${1:-0}"
    if [ "$kb" -ge 10240 ]; then printf '%sMB' "$(( kb / 1024 ))"; else printf '%sKB' "$kb"; fi
}

# free_kb <path> — KiB AVAILABLE on the filesystem holding <path>, on stdout.
# `df -Pk` reports 1 KiB blocks ("-P" = the portable single-line format). Empty
# output means df could not answer: "cannot judge", never "plenty".
free_kb() {
    "$DF_BIN" -Pk "$1" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4; exit}'
}

# tool_of <class> — the binary that prunes a given cache class.
tool_of() {
    case "$1" in
        uv) printf '%s' "$UV_BIN" ;;
        npm) printf '%s' "$NPM_BIN" ;;
        pip) printf '%s' "$PIP_BIN" ;;
        *) printf '' ;;
    esac
}

# prune_cache <class> <dir> — the SAFE half: ask the owning tool to drop entries
# nothing references. Never fatal: a tool that is absent, or that fails, only
# means the cache is still over its bound, which the caller checks anyway.
# The tool is pointed at THE DIRECTORY THIS PASS MEASURED (UV_CACHE_DIR / --cache),
# so pruning can never hit a different cache than the one being bounded.
prune_cache() {
    local class="$1" dir="$2" tool out
    tool="$(tool_of "$class")"
    case "$class" in
        uv)
            [ -n "$tool" ] || return 1
            command -v "$tool" >/dev/null 2>&1 || return 1
            out="$(UV_CACHE_DIR="$dir" "$tool" cache prune 2>&1)" || { plog "pi-cache-reap:   prune($class) failed: ${out:-no output}"; return 1; }
            return 0 ;;
        npm)
            [ -n "$tool" ] || return 1
            command -v "$tool" >/dev/null 2>&1 || return 1
            # npm's cache ROOT is the parent of `_cacache`; point --cache at whichever
            # of the two this pass was given, so prune and measure cannot disagree.
            case "$(basename "$dir")" in
                _cacache) out="$("$tool" cache verify --cache "$(dirname "$dir")" 2>&1)" ;;
                *)        out="$("$tool" cache verify --cache "$dir" 2>&1)" ;;
            esac || { plog "pi-cache-reap:   prune($class) failed: ${out:-no output}"; return 1; }
            return 0 ;;
        *)
            # pip has no unused-entry prune (`pip cache purge` is the whole-cache
            # delete, i.e. the ESCALATION arm). Nothing to do safely.
            return 1 ;;
    esac
}

# ── process table: ONE read per pass ─────────────────────────────────
# MEASURED ON THE INCIDENT BOX (pi-cell-3, 2026-10-16): `uv` LEAKS its build-backend
# processes — three `python -c 'import setuptools.build_meta'` children running inside
# `$UV_CACHE/builds-v0/.tmpXXXX`, ppid 1, 4-8 hours old. They will never exit. A probe
# that treats "any process whose argv names the cache" as a veto therefore never reaps
# that box at all, which is the same non-action this issue exists to remove. So the
# snapshot is used two ways:
#   * a live TOOL process (`uv`/`npm`/`pip`) → the whole target is preserved: we cannot
#     know which entries it is resolving against;
#   * a process whose argv names a SPECIFIC ENTRY → that entry is preserved and the rest
#     are still eligible. Over-preserving one stuck entry costs bytes; refusing the whole
#     cache costs the box.
PS_SNAP=""
ps_snapshot() {
    PS_SNAP="$("$PS_BIN" -axo pid=,command= 2>/dev/null)"
    # An EMPTY table is a broken probe, not an idle box (the same rule as pi-reap-idle).
    [ -n "$PS_SNAP" ] || return 2
    return 0
}

# ps_matches <tool|dir> <class> <dir> — snapshot lines that could hold this cache.
# rc 0 = at least one line on stdout, 1 = none, 2 = no usable snapshot.
# ⛔ This runs against the SNAPSHOT taken before any probe process existed, so the
# scanner can never match itself (a `grep` whose argv holds the cache path would
# otherwise make every pass report a phantom holder).
# ⛔ The tool match is on the EXECUTABLE (argv[0], or the token after `/usr/bin/env`),
# NOT on a substring of the whole command line. Substring matching made an operator's
# own shell — any command text containing `uv ` — report itself as a live uv process,
# which refused escalation on a box with no uv running at all (measured while writing
# this script). The exec test still catches every real case: `uv sync`, `uv run …`,
# `/usr/bin/env UV_CACHE_DIR=… uv …`.
ps_matches() {
    local kind="$1" class="$2" dir="$3" pat
    [ -n "$PS_SNAP" ] || return 2
    case "$kind" in
        tool)
            printf '%s\n' "$PS_SNAP" | awk -v me="$$" -v tool="$class" '
                $1 == me { next }
                {
                    exe = $2; sub(/.*\//, "", exe)
                    if (exe == tool) { print; next }
                    if (exe == "env") {
                        i = 3
                        while (i <= NF && $i ~ /=/) i++
                        e2 = $i; sub(/.*\//, "", e2)
                        if (e2 == tool) print
                    }
                }'
            return 0 ;;
        dir)
            pat="$(printf '%s' "$dir" | sed 's/[][\.*^$/]/\\&/g')"
            printf '%s\n' "$PS_SNAP" | awk -v me="$$" '$1 != me' | grep -E -e "$pat"
            return 0 ;;
        *) return 2 ;;
    esac
}

# entries_by_size <dir> — every top-level entry of <dir>, largest first, as
# "<KiB><TAB><path>" lines. No recursive walk: only the cache's OWN top level is
# enumerated (uv: archive-v0/builds-v0/wheels-v3/…; npm: content-v2/index-v5/…;
# pip: http-v2/wheels/…), and `du` walks each entry once. Symlinked entries are
# SKIPPED — a planted `$CACHE/x -> ~/.ssh` must never reach a delete path.
entries_by_size() {
    local dir="$1" e kb
    : >"$TMPLIST"
    for e in "$dir"/* "$dir"/.[!.]*; do
        [ -e "$e" ] || continue
        [ -L "$e" ] && { plog "pi-cache-reap:   skip symlinked entry $e"; continue; }
        kb="$(kb_of "$e")" || kb=0
        printf '%s\t%s\n' "$kb" "$e" >>"$TMPLIST"
    done
    sort -rn -k1,1 "$TMPLIST"
}

# reap_target <class> <dir> — bound ONE cache. Prints exactly one summary line.
reap_target() {
    local class="$1" dir="$2" before_kb before_free_kb now_kb new_kb after_kb after_free_kb
    local pruned=none evicted=0 kb e cur_free holders dir_holders held_entries rc
    local no_gain_stop=0 no_gain=0 last_free="" claimed_kb gained_kb min_gain_kb stop_note=""

    case "$dir" in
        /*) ;;
        *) fail_closed "$class: cache dir '$dir' is not an absolute path — refusing to measure or touch it"; return 0 ;;
    esac
    if [ ! -e "$dir" ]; then
        say "pi-cache-reap: $class $dir absent (nothing to bound)"
        return 0
    fi
    [ -d "$dir" ] || { fail_closed "$class: $dir exists but is not a directory"; return 0; }

    before_kb="$(kb_of "$dir")" \
        || { fail_closed "$class: cannot measure $dir (du failed) — the bound cannot be enforced"; return 0; }
    before_free_kb="$(free_kb "$dir")"

    if [ "$before_kb" -le "$MAX_KB" ]; then
        say "pi-cache-reap: $class $dir $(mb_str "$before_kb") <= ${MAX_MB}MB bound — no action"
        return 0
    fi

    if [ "$MODE" != "apply" ]; then
        say "pi-cache-reap: DRY-RUN $class $dir $(mb_str "$before_kb") > ${MAX_MB}MB bound — would prune, then evict the largest entries while no $class process holds the cache (re-run with --apply)"
        return 0
    fi

    # ── (1) the safe half ────────────────────────────────────────────────────
    if prune_cache "$class" "$dir"; then pruned=ok; else pruned=none; fi
    now_kb="$(kb_of "$dir")" \
        || { fail_closed "$class: cannot measure $dir after the prune — the shrink cannot be verified"; return 0; }

    # ── (2) escalate: largest entries first, skipping anything a live process names ──
    if [ "$now_kb" -gt "$MAX_KB" ]; then
        ps_snapshot || { fail_closed "$class: $dir is $(mb_str "$now_kb") > ${MAX_MB}MB and the ps probe could not answer — NOT escalating an unproven cache"; return 0; }
        holders="$(ps_matches tool "$class" "$dir")" \
            || { fail_closed "$class: $dir is $(mb_str "$now_kb") > ${MAX_MB}MB and the ps probe could not answer — NOT escalating an unproven cache"; return 0; }
        if [ -n "$holders" ]; then
            fail_closed "$class: $dir is $(mb_str "$now_kb") > ${MAX_MB}MB and a live $class process is running, so the entries it holds cannot be known — NOT escalating; process(es): $holders"
            return 0
        fi
        # Entry-level holders: a process whose argv NAMES an entry keeps that entry.
        dir_holders="$(ps_matches dir "$class" "$dir" || true)"
        held_entries=""
        # ⛔ STOP DESTROYING WHEN DELETION STOPS RECLAIMING. A uv cache entry is HARDLINKED into
        # every `.venv` built from it, so unlinking it can free nothing while the cache's apparent
        # size drops by hundreds of MB — MEASURED on pi-cell-3: evicting 914MB of cache gained 7MB
        # of disk. Two consecutive evictions with no free-space gain means the remaining entries are
        # shared, and continuing would trade a perf asset for nothing. Stop and report instead.
        no_gain_stop=0; no_gain=0; last_free="${before_free_kb:-}"
        while IFS="$TAB" read -r kb e; do
            [ -n "${e:-}" ] || continue
            [ "$now_kb" -gt "$MAX_KB" ] || break
            if [ -n "$dir_holders" ] && grep -qF -- "$e" <<<"$dir_holders"; then
                held_entries="${held_entries:+$held_entries, }$e"
                plog "pi-cache-reap:   preserving $e — a live process names it"
                continue
            fi
            if rm -rf -- "$e" 2>/dev/null; then
                evicted=$((evicted + 1))
                # Re-measure the WHOLE cache, not the entry: an entry can be a directory
                # holding more than `du` charged to its own top level (block rounding).
                # A failed re-measure keeps the last good value — the verification below
                # governs the verdict, so a stale number can only make it stricter.
                if new_kb="$(kb_of "$dir")"; then now_kb="$new_kb"; fi
                cur_free="$(free_kb "$dir")"
                if [ -n "$last_free" ] && [ -n "$cur_free" ]; then
                    if [ "$cur_free" -gt "$last_free" ]; then
                        no_gain=0
                    else
                        no_gain=$((no_gain + 1))
                        [ "$no_gain" -ge 2 ] && { no_gain_stop=1; stop_note=" (eviction STOPPED EARLY: deleting this cache no longer reclaims disk)"; break; }
                    fi
                    last_free="$cur_free"
                fi
            else
                plog "pi-cache-reap:   could not remove $e"
            fi
        done < <(entries_by_size "$dir")
    fi

    # ── (3) verify — a pass that acted must PROVE the shrink ─────────────────
    after_kb="$(kb_of "$dir")" \
        || { fail_closed "$class: cannot measure $dir after the pass — the shrink cannot be verified"; return 0; }
    after_free_kb="$(free_kb "$dir")"

    if [ "$after_kb" -ge "$before_kb" ]; then
        fail_closed "$class: acted on $dir ($(mb_str "$before_kb"), prune=$pruned, evicted=$evicted) but the size did NOT decrease — the shrink is NOT verified"
        return 0
    fi
    case "${before_free_kb:-}:${after_free_kb:-}" in
        :*|*:)
            fail_closed "$class: $dir shrank $(mb_str "$before_kb") -> $(mb_str "$after_kb") but free space could not be read before and after (df) — the bytes actually freed are NOT verified (the entries may be hardlinked into live .venv trees)"
            return 0 ;;
    esac
    if [ "$after_free_kb" -le "$before_free_kb" ]; then
        fail_closed "$class: $dir shrank $(mb_str "$before_kb") -> $(mb_str "$after_kb") but the filesystem did NOT gain free space ($(mb_str "$before_free_kb") -> $(mb_str "$after_free_kb")) — the entries are still holding their bytes elsewhere (hardlinked into a .venv); nothing was actually freed. The owner for those bytes is the per-worktree sweep: cloud-cell-supervisor.sh prune${stop_note}"
        return 0
    fi
    # The disk gain must be a real fraction of what the cache claims to have given up. A 1:100
    # gain is the incident's own failure mode wearing a success line: MEASURED on pi-cell-3 after
    # this arm landed — 914MB of cache evicted, 7MB of disk gained, because the entries were
    # hardlinked into that box's worktree `.venv`s. Tunable, because a busy box can legitimately
    # write while the pass runs.
    claimed_kb=$(( before_kb - after_kb ))
    gained_kb=$(( after_free_kb - before_free_kb ))
    min_gain_kb=$(( claimed_kb * MIN_RECLAIM_PCT / 100 ))
    if [ "$gained_kb" -lt "$min_gain_kb" ]; then
        fail_closed "$class: $dir shrank $(mb_str "$before_kb") -> $(mb_str "$after_kb") ($(mb_str "$claimed_kb") claimed) but the filesystem gained only $(mb_str "$gained_kb") ($(mb_str "$before_free_kb") -> $(mb_str "$after_free_kb")) — under ${MIN_RECLAIM_PCT}% of the claim, so the bytes are NOT verified as reclaimed (hardlinked into a .venv? the owner for those is: cloud-cell-supervisor.sh prune)${stop_note}"
        return 0
    fi

    say "pi-cache-reap: $class $dir $(mb_str "$before_kb") -> $(mb_str "$after_kb") (prune=$pruned evicted=$evicted) max=${MAX_MB}MB; free $(mb_str "$before_free_kb") -> $(mb_str "$after_free_kb") (+$(mb_str "$gained_kb")) VERIFIED${stop_note}"

    if [ "$after_kb" -gt "$MAX_KB" ]; then
        fail_closed "$class: $dir is STILL $(mb_str "$after_kb") > ${MAX_MB}MB after evicting every removable entry${held_entries:+ — PRESERVED because a live process names them: $held_entries}"
    fi
    return 0
}

# cap_log — keep the reaper's own log from becoming a disk sink.
cap_log() {
    local size
    [ -n "$LOG" ] || return 0
    [ -f "$LOG" ] || return 0
    size="$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')"
    case "${size:-}" in ''|*[!0-9]*) return 0 ;; esac
    [ "$size" -le "$LOG_MAX_BYTES" ] && return 0
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
}

# ── arguments ────────────────────────────────────────────────────────────────
for a in "$@"; do
    case "$a" in
        --dry-run) MODE=dry-run ;;
        --apply) MODE=apply ;;
        --help|-h) usage ;;
        *) printf '%s: unknown argument %s\n' "$SCRIPT_NAME" "$a" >&2; usage ;;
    esac
done
[ "${CACHE_REAP_APPLY:-0}" = "1" ] && MODE=apply

case "${MAX_MB:-}" in
    ''|*[!0-9]*|0*) printf '%s: CACHE_REAP_MAX_MB must be a positive whole number of MiB (got %s)\n' "$SCRIPT_NAME" "${MAX_MB:-}" >&2; exit 2 ;;
esac
MAX_KB=$(( 10#$MAX_MB * 1024 ))
# The share of the claimed reduction that must actually appear as free disk (#1987 item 4).
MIN_RECLAIM_PCT="${CACHE_REAP_MIN_RECLAIM_PCT:-50}"
case "$MIN_RECLAIM_PCT" in ''|*[!0-9]*) MIN_RECLAIM_PCT=50 ;; esac
[ "$MIN_RECLAIM_PCT" -le 100 ] || MIN_RECLAIM_PCT=100

if [ -n "$LOG" ]; then
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG=""
fi
TMPLIST="$(mktemp "${TMPDIR:-/tmp}/pi-cache-reap.XXXXXX")" || { printf '%s: cannot create a temp file\n' "$SCRIPT_NAME" >&2; exit 3; }

# ── the sinks (uv, npm, pip — the same class of machine-global sink) ─────────
UVD="${CACHE_REAP_UV_DIR:-${UV_CACHE_DIR:-${HOME:-}/.cache/uv}}"
NPMD="${CACHE_REAP_NPM_DIR:-${HOME:-}/.npm/_cacache}"
PIPD="${CACHE_REAP_PIP_DIR:-${HOME:-}/.cache/pip}"
PIPD_MAC="${CACHE_REAP_PIP_DIR_MAC:-${HOME:-}/Library/Caches/pip}"

say "pi-cache-reap: pass start mode=$MODE max=${MAX_MB}MB per cache ($ISSUE_REF)"
reap_target uv "$UVD"
reap_target npm "$NPMD"
reap_target pip "$PIPD"
# macOS pip keeps its cache under ~/Library/Caches; bound it too when it exists.
[ "$PIPD_MAC" = "$PIPD" ] || reap_target pip "$PIPD_MAC"

cap_log

if [ "$FAILS" -gt 0 ]; then
    say "pi-cache-reap: FAILED — $FAILS cache(s) could not be bounded or verified this pass (exit 3)"
    exit 3
fi
say "pi-cache-reap: pass end — every present cache bounded and verified"
exit 0
