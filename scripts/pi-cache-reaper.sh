#!/usr/bin/env bash
# pi-cache-reaper.sh — bound the MACHINE-GLOBAL package caches (agent-infra#1987).
#
# WHY THIS EXISTS (measured, 2026-10-18). Cell `pi-cell-3`
# (vm-915c3930c4e94e4884229d974522d05d, 32 GB disk) sat at **258 MB free** and refused every
# dispatch while its controller kept beating and its queue read perfectly fine:
#
#     /tmp/cell-home/.cache/uv    7.1 GB
#     df /                        258M free   ->  ABORT: disk 258MB < 1200MB
#
# Clearing just the package cache freed 7.1 GB and the SAME box immediately launched a lane
# (258 MB -> 7.7 GB free). It was the second disk death for that cell; the first was an abandoned
# 5.8 GB worktree.
#
# The distinction that made it invisible: this cache is **machine-global**, not per-lane.
# `~/.cache/uv` accumulates every `uv sync`/`uv run` that ANY lane on the box performs, so it grows
# fastest exactly on the boxes that dispatch most, and nothing bounded it:
#   * #1949 reaps a LANE's `.venv` once the lane is gone (per-worktree);
#   * #1851 / #1858 measure and bound WORKTREE disk weight;
#   * #1745's `cloud-cell-supervisor.sh prune` sweeps caches at each WORKTREE ROOT.
# None of them touches the shared package cache — which is where the measured space actually went.
# So the cell's own disk floor (`spawn-gate.sh` DISK_MIN_FREE_MB) is the only thing that ever saw
# it, and by then the answer was "refuse to work", not "reclaim".
#
# THE LADDER, per sink ($UV_CACHE_DIR, $NPM_CACHE_DIR, $PIP_CACHE_DIR — default 2 GiB each):
#   1. MEASURE. At or under CACHE_REAPER_MAX_MB -> report and change nothing.
#   2. PRUNE with the tool's own in-use-safe command — `uv cache prune` / `npm cache verify`.
#      Both are the upstream's definition of "remove what nothing uses"; neither needs the cache to
#      be idle, and `uv cache prune` waits on its own lock rather than corrupting a concurrent run
#      (verified: with `.lock` held it prints "Cache is currently in-use, waiting …").
#   3. ESCALATE only if the sink is STILL over the bound, and only while NO LANE HOLDS IT:
#        uv  — remove the LARGEST EXCLUSIVELY CACHE-OWNED `archive-v0` entries until under the bound.
#              "Exclusively owned" is MEASURED, not assumed: every file's link count must be 1, i.e.
#              this cache holds the last name on those inodes. That distinction is the difference
#              between reclaiming disk and pretending to — a venv holds HARDLINKS into these entries
#              (measured and recorded in pi-reap-worktrees.sh), and the first version of this ladder
#              deleted 4.1 GB of "largest entries" on the live box while `df` moved 5 MB, because 174
#              of 266 entries were alive inside 29 worktree venvs. Those bytes are not the cache's to
#              give back: they are charged to the worktrees that hold them (#1745 / #1095 reap those).
#              The gate is the cache's OWN lock — `flock(LOCK_EX|LOCK_NB)` on `$UV_CACHE_DIR/.lock`,
#              the same lock uv waits on (verified against uv 0.12.5: with `.lock` held,
#              `uv cache prune` prints "Cache is currently in-use, waiting for other uv processes
#              to finish"), so "lock free" is uv's own answer to "is a lane working in this cache".
#        npm — `npm cache clean --force` (npm has no partial prune; index-v5 is not ours to edit).
#        pip — `pip cache purge` (pip has no prune at all).
#      npm/pip ship no lock file, so their gate is a `ps` probe for a live npm/npx/pip/pip3; a
#      probe that cannot run is treated as BUSY (fail closed — nothing is deleted).
#   4. ONE LINE per sink, before -> after, with the rung that produced the change (this is the
#      REAL line from the box this was built on, 2026-10-18):
#        pi-cache-reaper: uv  /tmp/cell-home/.cache/uv  6090MB -> 1990MB  (prune+escalate)  max=2048MB
#
# REFUSE-TO-ACT (the issue's point 4). A reaper that reports success while freeing nothing is the
# failure mode this repo keeps hitting. Exit 0 means EVERY present sink is at or under the bound,
# measured after the ladder ran. Exit 3 means at least one sink is still over the bound, or the
# ladder could not be attempted (lock held / lock state undeterminable / tool missing / a step
# failed / a sink could not be measured / the log cannot be written), and the line says which sink
# and why — including, for uv, how many bytes sit in entries a venv still hardlinks into. A sink
# that is absent, or already within the bound, is never a failure.
#
# NOT BY AGE, deliberately: an "older than N days" rule keeps the wrong entries. A cache entry is
# worthless because nothing references it, not because its mtime is old — and the boxes that fill
# this cache are the ones that re-create entries right after touching them.
#
# Usage:
#   pi-cache-reaper.sh [--dry-run] [--apply] [--max-mb N] [--help]
#     (no mode flag)  act: prune, and escalate under the lock gate (or CACHE_REAPER_DRY_RUN=0)
#     --dry-run       report what would be done, delete nothing (CACHE_REAPER_DRY_RUN=1)
#     --apply         explicit act
#     --max-mb N      per-sink bound in MiB (default CACHE_REAPER_MAX_MB or 2048)
#
# Env seams (tests drive these; nothing else should need them):
#   UV_CACHE_DIR NPM_CACHE_DIR PIP_CACHE_DIR   the sinks (defaults under $HOME)
#   CACHE_REAPER_MAX_MB (2048)  CACHE_REAPER_DRY_RUN (0)  CACHE_REAPER_LOG
#   UV_BIN NPM_BIN PIP_BIN   tool binaries (default: `command -v <tool>`)
#   PS_BIN (default /bin/ps)  PYTHON_BIN (default `command -v python3`)
#
# Exit codes: 0 = every present sink within the bound, 2 = usage, 3 = fail-closed (see above).

set -uo pipefail

SCRIPT_NAME="pi-cache-reaper.sh"
ISSUE_REF="#1987"

MAX_MB="${CACHE_REAPER_MAX_MB:-2048}"
DRY_RUN="${CACHE_REAPER_DRY_RUN:-0}"
PS_BIN="${PS_BIN:-/bin/ps}"
LOG="${CACHE_REAPER_LOG:-}"
MODE="act"

say() { printf '%s %s\n' "$SCRIPT_NAME:" "$*"; }
warn() { printf '%s REFUSED: %s\n' "$SCRIPT_NAME:" "$*" >&2; }
# log — the evidence trail the issue asks for ("log the before/after in one line"). setup_log
# refuses to run a pass whose log cannot be written: a pass with no record is not evidence.
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG" 2>/dev/null; }

usage() {
    cat <<EOF
$SCRIPT_NAME — bound the machine-global package caches ($ISSUE_REF)

Usage:
  $SCRIPT_NAME [--dry-run] [--apply] [--max-mb N] [--help]

  (no mode flag)  act: prune, then escalate under the lock gate
  --dry-run       report what would be done, delete nothing
  --apply         explicit act
  --max-mb N      per-sink bound in MiB (default ${MAX_MB})

Sinks: \$UV_CACHE_DIR, \$NPM_CACHE_DIR, \$PIP_CACHE_DIR (defaults under \$HOME).
Ladder: measure -> prune (uv cache prune / npm cache verify) -> escalate only while no live
process holds the sink (uv: its own .lock; npm/pip: a ps probe).
Exit 0 = every present sink is at or under the bound; 3 = still over, or the ladder could not be
attempted (and the line says which sink and why).
EOF
}

# ── argument parsing ──────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; MODE="dry-run" ;;
        --apply)   DRY_RUN=0; MODE="act" ;;
        --max-mb)  shift; MAX_MB="${1:-}" ;;
        --max-mb=*) MAX_MB="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) printf '%s: unknown argument %s\n' "$SCRIPT_NAME" "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
case "${MAX_MB:-}" in ''|*[!0-9]*) printf '%s: --max-mb must be a whole number of MiB (got %s)\n' "$SCRIPT_NAME" "${MAX_MB:-<empty>}" >&2; exit 2 ;; esac
# A zero bound would ask the reaper to empty every cache, and a 10-digit one is not a disk. Coerce
# the absurd to the documented default rather than acting on it.
[ "$((10#$MAX_MB))" -ge 1 ] || MAX_MB=2048
[ "${#MAX_MB}" -le 6 ] || MAX_MB=2048
MAX_MB="$((10#$MAX_MB))"
case "${DRY_RUN:-}" in 0|1) ;; *) DRY_RUN=1 ;; esac

# ── sinks ─────────────────────────────────────────────────────────────────────
# resolve_paths — NEVER guess a cache path from an unset HOME. `${HOME:-}/.cache/uv` expands to
# `/.cache/uv`, and a reaper pointed at the filesystem root is exactly the silent-destruction class
# this repo refuses. An unset HOME requires every sink to be named explicitly.
resolve_paths() {
    if [ -z "${HOME:-}" ]; then
        local missing=""
        [ -n "${UV_CACHE_DIR:-}" ] || missing="$missing UV_CACHE_DIR"
        [ -n "${NPM_CACHE_DIR:-}" ] || missing="$missing NPM_CACHE_DIR"
        [ -n "${PIP_CACHE_DIR:-}" ] || missing="$missing PIP_CACHE_DIR"
        [ -z "$missing" ] || { printf '%s: HOME is unset and%s unset — refusing to guess a cache path\n' "$SCRIPT_NAME" "$missing" >&2; exit 3; }
    fi
    UV_CACHE_DIR="${UV_CACHE_DIR:-$HOME/.cache/uv}"
    NPM_CACHE_DIR="${NPM_CACHE_DIR:-$HOME/.npm/_cacache}"
    PIP_CACHE_DIR="${PIP_CACHE_DIR:-$HOME/.cache/pip}"
    LOG="${LOG:-$HOME/.pi/agent/state/pi-cache-reaper.log}"
}

sink_path() {
    case "$1" in
        uv)  printf '%s' "$UV_CACHE_DIR" ;;
        npm) printf '%s' "$NPM_CACHE_DIR" ;;
        pip) printf '%s' "$PIP_CACHE_DIR" ;;
        *)   return 1 ;;
    esac
}

setup_log() {
    local dir
    dir="$(dirname "$LOG")"
    mkdir -p "$dir" 2>/dev/null || true
    if ! { printf '' >>"$LOG"; } 2>/dev/null; then
        printf '%s: cannot write the log at %s — a pass with no record is not evidence; refusing (exit 3)\n' "$SCRIPT_NAME" "$LOG" >&2
        exit 3
    fi
}

# ── measurement ───────────────────────────────────────────────────────────────
# dir_mb <dir> — MiB on stdout; returns 1 when the size cannot be MEASURED (which is never "0").
dir_mb() {
    local kb
    [ -e "$1" ] || { printf '0\n'; return 0; }
    [ -d "$1" ] || return 1
    kb="$(du -sk "$1" 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1}')"
    [ -n "${kb:-}" ] || return 1
    printf '%s\n' "$(( 10#$kb / 1024 ))"
}

human_mb() { printf '%sMB' "$1"; }

# ── holders: is a live process working in this sink? ─────────────────────────────
# uv_lock_free <cache-root> — uv's own answer, on uv's own lock file.
#   0 = free/absent (no uv process is working in this cache)
#   1 = HELD     (a uv process is mid-operation; uv itself waits here)
#   2 = cannot determine (no python3, lock unreadable) — the caller must treat it as HELD
# Verified against uv 0.12.5: with `.lock` held, `uv cache prune` prints "Cache is currently
# in-use, waiting for other uv processes to finish".
uv_lock_free() {
    local root="$1" lock="$1/.lock" py
    [ -e "$lock" ] || return 0
    py="${PYTHON_BIN:-$(command -v python3 2>/dev/null)}"
    [ -n "${py:-}" ] || return 2
    "$py" - "$lock" <<'PY'
import fcntl, sys
try:
    handle = open(sys.argv[1], "r+b")
except OSError:
    sys.exit(2)          # unreadable lock: cannot determine -> treat as held
try:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)          # held by a live uv process
try:
    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
finally:
    handle.close()
sys.exit(0)
PY
}

# ps_busy <ere> — 0 = a matching process is live, 1 = none, 2 = the probe itself failed
# (a failed probe is BUSY to the caller: fail closed, never delete on an unknown).
ps_busy() {
    local re="$1" out
    out="$("$PS_BIN" -axo pid=,command= 2>/dev/null)" || return 2
    [ -n "${out:-}" ] || return 2
    if [[ "$out" =~ $re ]]; then return 0; fi
    return 1
}

# ── prune rung (upstream's in-use-safe command) ──────────────────────────────────
# run_prune <sink> — 0 ran, 1 no prune exists / tool absent (caller escalates), 2 the tool failed
run_prune() {
    local sink="$1" bin rc
    case "$sink" in
        uv)
            bin="${UV_BIN:-$(command -v uv 2>/dev/null)}"
            [ -n "${bin:-}" ] || return 1
            UV_CACHE_DIR="$(sink_path uv)" "$bin" cache prune >>"$LOG" 2>&1; rc=$?
            ;;
        npm)
            bin="${NPM_BIN:-$(command -v npm 2>/dev/null)}"
            [ -n "${bin:-}" ] || return 1
            "$bin" cache verify >>"$LOG" 2>&1; rc=$?
            ;;
        pip) return 1 ;;   # pip has no prune; escalation is the only reclaim it offers
        *)   return 1 ;;
    esac
    [ "$rc" -eq 0 ] || return 2
    return 0
}

# ── escalation rung (only under the holder gate) ───────────────────────────────
# holder_gate_ps <sink> <path> <ere> — 0 = clear to act, 1 = BLOCKED. A live process blocks, and so
# does a probe that could not answer: a probe failure is never clearance to delete something.
holder_gate_ps() {
    local sink="$1" path="$2" re="$3" rc
    ps_busy "$re"; rc=$?
    case "$rc" in
        0) say "deferred: an $sink process is LIVE — not touching the $sink cache under it"
           log "deferred sink=$sink path=$path reason=process-live"
           return 1 ;;
        1) return 0 ;;
        *) say "deferred: the process probe ($PS_BIN) could not run — cannot prove no $sink process is using $path, so nothing was deleted"
           log "deferred sink=$sink path=$path reason=probe-failed"
           return 1 ;;
    esac
}

# uv_escalate <cache-root> <max-mb> — unlink the LARGEST *exclusively cache-owned* archive entries
# until under the bound. Sets REMOVED / SHARED_ENTRIES / SHARED_KB / UNKNOWN_ENTRIES; returns 0, or 2
# when the pass could not complete.
#
# ⛔ EXCLUSIVITY IS THE WHOLE POINT, and it is measured, not assumed. A venv on this machine does not
# hold a COPY of a wheel — it holds a HARDLINK into `archive-v0/<hash>` (the measurement is recorded
# in pi-reap-worktrees.sh: `du` over-reports per-worktree .venvs by 84 GB vs 22 GB actually freed).
# So an entry whose files are all link-count 1 is the LAST name on those inodes: deleting it frees
# the bytes. An entry with any multiply-linked file is fully alive inside some worktree's venv, and
# deleting its cache name frees NOTHING — it only guarantees a re-download later.
#
# MEASURED on the live box (2026-10-18, right before this gate was added): a size-ordered pass
# removed 4.1 GB of "largest entries", and `df` moved 5 MB — because 174 of the 266 entries were
# hardlinked into 29 worktree venvs. 92 exclusive entries (358 MB) were the only real reclaim. That
# run is the exact "shrank the cache, freed nothing" shape the issue forbids; this gate is its fix.
REMOVED=0
SHARED_ENTRIES=0
SHARED_KB=0
UNKNOWN_ENTRIES=0

# entry_exclusive <entry> — 0 = every file's inode is held only by this cache (deleting it frees
# disk), 1 = something else hardlinks into it (deleting it frees ~nothing), 2 = cannot determine.
# A failed probe is NEVER "exclusive": an unknown must not authorise a delete.
entry_exclusive() {
    local out rc
    out="$(find "$1" -type f ! -links 1 -print -quit 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return 2
    [ -z "${out:-}" ]
}

uv_escalate() {
    local root="$1" max="$2" limit_kb total_kb removed=0 kb path excl rc
    local arch="$1/archive-v0"
    REMOVED=0; SHARED_ENTRIES=0; SHARED_KB=0; UNKNOWN_ENTRIES=0
    limit_kb=$(( max * 1024 ))
    # One measurement of the whole cache, then per-entry sizes; the running total is adjusted by
    # each entry's own size so the loop does not re-walk a multi-GB tree per entry.
    total_kb="$(du -sk "$root" 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1}')"
    [ -n "${total_kb:-}" ] || return 2
    [ -d "$arch" ] || return 0        # nothing entry-shaped to reclaim (uv may change its layout)
    set -- "$arch"/*
    [ -e "${1:-}" ] || return 2       # an empty glob is not "free of charge": nothing to reclaim
    while IFS="$(printf '\t')" read -r kb path; do
        [ -n "${kb:-}" ] || continue
        # Containment: only an entry DIRECTLY under this cache's archive-v0, never a path the listing
        # could have carried out of it (a symlinked or malformed entry).
        case "$path" in "$arch"/*) ;; *) continue ;; esac
        case "${path#"$arch"/}" in ''|*/*) continue ;; esac
        [ "$total_kb" -gt "$limit_kb" ] || break
        entry_exclusive "$path"; excl=$?
        if [ "$excl" -ne 0 ]; then
            if [ "$excl" -eq 1 ]; then
                SHARED_ENTRIES=$(( SHARED_ENTRIES + 1 )); SHARED_KB=$(( SHARED_KB + kb ))
            else
                UNKNOWN_ENTRIES=$(( UNKNOWN_ENTRIES + 1 ))
            fi
            continue
        fi
        [ "$total_kb" -gt "$limit_kb" ] || break
        if rm -rf -- "$path" 2>/dev/null; then
            total_kb=$(( total_kb - kb )); removed=$(( removed + 1 ))
        else
            return 2
        fi
    done < <(du -sk "$arch"/* 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1"\t"$2}' | sort -rn)
    REMOVED=$removed
    return 0
}

# escalate <sink> <path> — 0 = reclaimed and re-measured, 1 = gate said no (nothing deleted),
# 2 = attempted and failed. The re-measure is the caller's job.
escalate() {
    local sink="$1" path="$2" bin rc
    case "$sink" in
        uv)
            uv_lock_free "$path"; rc=$?
            case "$rc" in
                0) : ;;
                1) say "deferred: $sink cache is IN USE (uv holds $path/.lock) — not deleting a cache a lane is resolving against"
                   log "deferred sink=uv path=$path reason=lock-held"
                   return 1 ;;
                *) say "deferred: $sink cache lock state UNDETERMINABLE at $path/.lock (no python3, or unreadable) — cannot prove no lane is using it, so nothing was deleted"
                   log "deferred sink=uv path=$path reason=lock-unknown"
                   return 1 ;;
            esac
            uv_escalate "$path" "$MAX_MB"; rc=$?
            case "$rc" in
                0) log "escalated sink=uv path=$path entries=$REMOVED shared=$SHARED_ENTRIES/$(human_mb "$(( SHARED_KB / 1024 ))") unknown=$UNKNOWN_ENTRIES" ;;
                *) log "escalate-failed sink=uv path=$path rc=$rc"; return 2 ;;
            esac
            ;;
        npm)
            holder_gate_ps npm "$path" '(^|[[:space:]/])(npm|npx)([[:space:]]|$)' || return 1
            bin="${NPM_BIN:-$(command -v npm 2>/dev/null)}"
            [ -n "${bin:-}" ] || { say "cannot escalate: no npm on PATH and $path is over the bound"; log "escalate-failed sink=npm path=$path reason=tool-absent"; return 2; }
            "$bin" cache clean --force >>"$LOG" 2>&1 || { log "escalate-failed sink=npm path=$path reason=clean-rc"; return 2; }
            log "escalated sink=npm path=$path via=npm-cache-clean"
            ;;
        pip)
            holder_gate_ps pip "$path" '(^|[[:space:]/])(pip|pip3)([[:space:]]|$)' || return 1
            bin="${PIP_BIN:-$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null)}"
            [ -n "${bin:-}" ] || { say "cannot escalate: no pip on PATH and $path is over the bound"; log "escalate-failed sink=pip path=$path reason=tool-absent"; return 2; }
            "$bin" cache purge >>"$LOG" 2>&1 || { log "escalate-failed sink=pip path=$path reason=purge-rc"; return 2; }
            log "escalated sink=pip path=$path via=pip-cache-purge"
            ;;
        *) return 2 ;;
    esac
    return 0
}

# ── the pass over one sink ──────────────────────────────────────────────────────
# reap_sink <sink> — 0 = at or under the bound, 1 = still over / could not be verified.
reap_sink() {
    local sink="$1" path before after rung="none" rc
    path="$(sink_path "$sink")" || return 1
    if [ ! -e "$path" ]; then
        say "$sink  (absent) — nothing to bound"
        log "absent sink=$sink path=$path"
        return 0
    fi
    before="$(dir_mb "$path")" || {
        say "$sink  $path  UNMEASURABLE (du failed) — cannot verify a bound, so this is not a pass"
        log "fail sink=$sink path=$path reason=unmeasurable"
        return 1
    }
    if [ "$before" -le "$MAX_MB" ]; then
        say "$sink  $path  $(human_mb "$before") within max=$(human_mb "$MAX_MB") — no action"
        log "within-bound sink=$sink path=$path mb=$before max=$MAX_MB"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        say "$sink  $path  $(human_mb "$before") OVER max=$(human_mb "$MAX_MB") — DRY-RUN, nothing deleted (prune, then escalate)"
        log "dry-run sink=$sink path=$path mb=$before max=$MAX_MB"
        return 0
    fi
    # Rung 2: prune.
    run_prune "$sink"; rc=$?
    [ "$rc" -eq 0 ] && rung="prune"
    [ "$rc" -eq 2 ] && log "prune-failed sink=$sink path=$path"
    after="$(dir_mb "$path")" || {
        say "$sink  $path  UNMEASURABLE after prune — cannot verify the bound"
        log "fail sink=$sink path=$path reason=unmeasurable-after-prune"
        return 1
    }
    # Rung 3: escalate, only when still over the bound.
    if [ "$after" -gt "$MAX_MB" ]; then
        escalate "$sink" "$path"; rc=$?
        case "$rc" in
            0) rung="${rung}+escalate" ;;
            1) rung="${rung}+deferred" ;;
            *) rung="${rung}+escalate-failed" ;;
        esac
        after="$(dir_mb "$path")" || {
            say "$sink  $path  UNMEASURABLE after escalation — cannot verify the bound"
            log "fail sink=$sink path=$path reason=unmeasurable-after-escalate"
            return 1
        }
    fi
    # One line: before -> after, the rung that produced it, and the bound.
    say "$sink  $path  $(human_mb "$before") -> $(human_mb "$after")  ($rung)  max=$(human_mb "$MAX_MB")"
    log "pass sink=$sink path=$path before_mb=$before after_mb=$after rung=$rung max_mb=$MAX_MB"
    # REFUSE-TO-ACT (the issue's point 4): still over the bound is a NON-PASS, and when the ladder
    # freed nothing the line says so — a reaper that reports success while freeing nothing is the
    # failure mode this whole change exists to stop.
    if [ "$after" -gt "$MAX_MB" ]; then
        if [ "$after" -ge "$before" ]; then
            say "$sink  STILL OVER the bound after the ladder ($(human_mb "$after") > $(human_mb "$MAX_MB")) and it freed NOTHING ($(human_mb "$before") -> $(human_mb "$after"), $rung)"
            log "fail sink=$sink path=$path reason=over-bound-no-reduction before_mb=$before after_mb=$after rung=$rung"
        else
            say "$sink  STILL OVER the bound after the ladder ($(human_mb "$after") > $(human_mb "$MAX_MB")) — the next line says what is left behind it"
            log "fail sink=$sink path=$path reason=over-bound before_mb=$before after_mb=$after rung=$rung"
        fi
        # WHY the residue is unreclaimable, when that is the reason: those bytes are the SAME inodes
        # a worktree venv is using, so deleting the cache's names would free nothing and force a
        # re-download. Naming the actual holder is what turns "nothing happened" into a next step.
        if [ "$sink" = uv ] && [ "$SHARED_ENTRIES" -gt 0 ]; then
            say "$sink  of that, $(human_mb "$(( SHARED_KB / 1024 ))") in $SHARED_ENTRIES entries is HARDLINKED into live venvs — deleting it would free no disk and force a re-download; those inodes belong to the worktrees holding them (reap them: cloud-cell-supervisor.sh prune / pi-reap-worktrees.sh)"
            log "residue-shared sink=uv entries=$SHARED_ENTRIES mb=$(( SHARED_KB / 1024 )) unknown=$UNKNOWN_ENTRIES"
        fi
        return 1
    fi
    return 0
}

main() {
    resolve_paths
    setup_log
    local sink rc=0
    log "start mode=$MODE max_mb=$MAX_MB uv=$UV_CACHE_DIR npm=$NPM_CACHE_DIR pip=$PIP_CACHE_DIR"
    for sink in uv npm pip; do
        reap_sink "$sink" || rc=3
    done
    if [ "$rc" -ne 0 ]; then
        warn "a package cache is over the ${MAX_MB}MB bound and was NOT brought under it — the disk this reaper exists to protect is still being consumed (see the lines above and $LOG)"
        log "end rc=$rc"
        exit 3
    fi
    log "end rc=0"
    exit 0
}

main "$@"
