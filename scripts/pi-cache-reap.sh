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
#     REPORTED. The process table is re-read IMMEDIATELY BEFORE EACH REMOVAL, not
#     only at pass start: a resolver that starts mid-pass is invisible to a
#     pass-start snapshot, which is the #1105 class the sibling reapers re-probe
#     for (`pi-reap-idle.sh`: "settle re-verify BEFORE each signal uses a FRESH
#     per-pid ps probe"). Two concurrent passes are excluded by a lock, because
#     two passes computing free-space deltas over the same filesystem can credit
#     each other's reclaim.
#   * ALWAYS ONE LINE PER CACHE, with the before/after bytes in it, and exactly ONE
#     verdict per cache. A reaper whose log cannot be read at a glance is
#     indistinguishable from one that did nothing — and a log that says both
#     "VERIFIED" and "STILL over bound" is worse than either.
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
#     For the same reason an entry that still HAS another link is PRESERVED and
#     reported: unlinking it cannot free its bytes, so deleting it would trade a
#     performance asset for nothing. Same for an entry on another filesystem (a
#     mount inside the cache): never delete THROUGH a mount.
#   * STOP DESTROYING WHAT IS NOT RECLAIMING. On top of the link rule, two
#     consecutive evictions with no free-space gain end the escalation. A cache is a
#     performance asset; trading it for nothing is damage, so the pass stops and
#     reports instead of emptying it.
#   * FAIL CLOSED: a cache that cannot be MEASURED (unreadable, `du` failed, a
#     relative/empty path) is exit 3, never a pass. `du` exiting non-zero can still
#     print a NUMERIC PARTIAL total, so its STATUS — not just the number — decides
#     measurability. Same for an unusable `ps` probe when escalation is needed, and
#     for an entry whose sharing or filesystem cannot be determined. No pass may
#     exit 0 on an unverified claim.
#   * The cache directory is whatever the OWNING TOOL says it is (`uv cache dir`,
#     which honours XDG_CACHE_HOME) rather than a hardcoded `$HOME` guess: bounding a
#     directory the tool does not use is a report about a cache that does not exist.
#
# SCHEDULING (installed by default, DRY-RUN until an owner arms it)
#   * Mac:   templates/launchd/com.eldato.pi-cache-reap.plist (hourly).
#   * Cell:  a Linux cell has no launchd; its only scheduler is the controller loop,
#            which runs this hourly from scripts/orchestrator-harness/orch-loop.sh
#            (next to its hourly claim_prune). The reaper owns the POLICY on both;
#            the triggers only decide when it runs.
#   * Both triggers ship DRY-RUN. Arming a scheduled DELETION is an owner-level
#     consequence decision — agent-infra#1678, owner ruling 2026-10-11: "the reaper
#     may run unattended; arming it may not", and "Arming a deletion tool must not
#     be reachable by a lane at all". Every sibling reaper (`pi-reap-worktrees`,
#     `pi-task-session-prune`) ships unarmed for the same reason. ARMING IS THE
#     ARGUMENT: replace `--dry-run` with `--apply` in the plist's ProgramArguments
#     and re-run scripts/install-launchd.sh — a dated, reversible, owner-owned step.
#     ⛔ `CACHE_REAP_APPLY=1` in EnvironmentVariables does NOT arm that job: an
#     explicit flag wins over the env default (so a requested dry run really is one),
#     which means the env var can only arm an invocation that passes no flag.
#   * The destructive path a CELL still reaches automatically is the pre-existing
#     low-disk emergency one: `cloud-cell-supervisor.sh` calls `prune --caches`
#     unattended when free space falls under 2x MIN_FREE_MB (no live worker), and
#     `cmd_prune` delegates here with --apply. That is not new arming — it is the
#     existing emergency delete path, extended to a sink that is strictly safer to
#     reclaim than the `.venv` trees it already removes (regenerable, unowned, no
#     uncommitted work).
#     ⛔ ALL `prune` FORMS reach that arm (`prune`, `prune --caches`,
#     `prune --scratch`): `reap_global_caches` runs unconditionally inside
#     `cmd_prune`, and `--caches` only selects its early return. State it plainly so
#     nobody reads "prune --caches" as the only armed verb.
#     `cloud-cell-bringup.sh --check` REPORTS every cache size (with the bound), so a
#     growing disk is visible before it stops dispatch.
#
# Usage:
#   pi-cache-reap.sh [--dry-run] [--apply] [--print-config] [--help]   (--help exits 0)
#
#   (no mode flag)  dry-run: measure + report what WOULD be done, mutate nothing
#   --dry-run       explicit dry-run (wins over CACHE_REAP_APPLY=1)
#   --apply         armed pass (CACHE_REAP_APPLY=1 supplies the default mode only)
#   --print-config  print `bound_mb=<n>`, `bound_source=env|default` and
#                   `cache=<class>:<path>` for each sink, as the reaper resolves them
#                   (the bring-up report reads this instead of keeping its own copy of
#                   the paths and the bound; the source says whether this process's
#                   environment or the script default set it)
#   --help          this text
#
# Env seams (also the test suite's):
#   CACHE_REAP_MAX_MB     per-cache ceiling in MiB (default 2048)
#   CACHE_REAP_UV_DIR     uv cache dir      (default: `uv cache dir`, else $UV_CACHE_DIR,
#                         else $HOME/.cache/uv)
#   CACHE_REAP_NPM_DIR    npm cacache dir   (default $HOME/.npm/_cacache)
#   CACHE_REAP_PIP_DIR    pip cache dir     (default $HOME/.cache/pip; the macOS
#                         ~/Library/Caches/pip is probed as a second candidate)
#   CACHE_REAP_APPLY      "1" arms the pass (a default: explicit flags still win)
#   CACHE_REAP_MIN_RECLAIM_PCT  share of the claimed reduction that must appear as
#                         free disk before a pass counts as verified (default 50)
#   CACHE_REAP_LOG        pass log (default $HOME/.pi/agent/state/pi-cache-reap.log)
#   CACHE_REAP_LOG_MAX_BYTES  rotate the log past this size (default 1 MiB)
#   CACHE_REAP_LOCK       pass lock dir (default $HOME/.pi/agent/state/pi-cache-reap.lock)
#   CACHE_REAP_LOCK_STALE_SECONDS  break a lock older than this (default 3600)
#   CACHE_REAP_PS         ps binary  (default /bin/ps)
#   CACHE_REAP_DF         df binary  (default df)
#   CACHE_REAP_DU         du binary  (default du)
#   CACHE_REAP_UV/NPM/PIP the tool binaries used for the PRUNE step
#   CACHE_REAP_PIP_DIR_MAC  the macOS pip cache candidate (default
#                         $HOME/Library/Caches/pip)
#
# Exit codes: 0 every present cache is under its bound (a pass that acted also verified the
# reclaim) · 2 usage (unknown argument) · 3 fail-closed (the cache could not be measured or
# seen, an entry name could not be represented, an entry's sharing or filesystem could not be
# determined, a live tool run made eviction unsafe, the reclaim could not be verified, or the
# audit log cannot be written on an armed pass) · 4 did not run (another pass holds the lock) ·
# 5 a cache is OVER its bound and nothing was done about it (dry-run — the shipped stance).
# ⚠️ NOT the sibling reapers' vocabulary: pi-reap-worktrees.sh uses 4 for "a removal FAILED"
# and 3 for "lock held". Here 4 is a benign skip and 3 is always fail-closed; a fleet reader
# must not apply the other mapping.
# ── usage end ──

set -uo pipefail

SCRIPT_NAME="pi-cache-reap.sh"
ISSUE_REF="#1987"
TAB="$(printf '\t')"

MAX_MB="${CACHE_REAP_MAX_MB:-2048}"
PS_BIN="${CACHE_REAP_PS:-/bin/ps}"
DF_BIN="${CACHE_REAP_DF:-df}"
DU_BIN="${CACHE_REAP_DU:-du}"
UV_BIN="${CACHE_REAP_UV:-uv}"
NPM_BIN="${CACHE_REAP_NPM:-npm}"
PIP_BIN="${CACHE_REAP_PIP:-pip}"
STATE_DIR="${HOME:-}/.pi/agent/state"
LOG="${CACHE_REAP_LOG:-$STATE_DIR/pi-cache-reap.log}"
LOG_MAX_BYTES="${CACHE_REAP_LOG_MAX_BYTES:-1048576}"
LOCK_DIR="${CACHE_REAP_LOCK:-$STATE_DIR/pi-cache-reap.lock}"
# Half the hourly trigger period, like the sibling reapers (REAP_WT_LOCK_STALE_SECONDS=1800)
#: a bound equal to the interval lets the next tick break a pass that is still running.
LOCK_STALE_SECONDS="${CACHE_REAP_LOCK_STALE_SECONDS:-1800}"

MODE=dry-run
MODE_SET=0
PRINT_CONFIG=0
FAILS=0
# Caches found OVER their bound on a pass that is not armed. Exit 5, so a caller can tell
# "checked and over" from "checked and fine" (0) and from "did not run" (4).
OVER_ONLY=0
LOCK_HELD=0
TMPLIST=""
TMPLIST2=""

usage() {
    sed -n '/^# Usage:/,/^# ── usage end ──/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
    exit "${1:-2}"
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

now_epoch() { date +%s 2>/dev/null; }
is_pos_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

cleanup() {
    [ -n "$TMPLIST" ] && rm -f "$TMPLIST"
    [ -n "$TMPLIST2" ] && rm -f "$TMPLIST2"
}
trap cleanup EXIT

# kb_of <dir> — size of <dir> in KiB on stdout; non-zero when it cannot be
# MEASURED. ⛔ The `du` STATUS decides, not just the printed number: a `du` that
# cannot read a subdirectory still prints a NUMERIC PARTIAL total (measured: a
# 3016 KiB tree with one mode-000 subdir prints `16` and exits 1). Accepting that
# number reports a cache as bounded when most of it was never seen — the exact
# false PASS this script exists to remove. One retry, because a live cache can
# legitimately lose an entry mid-walk.
kb_of() {
    local kb try=0
    while :; do
        kb="$("$DU_BIN" -sk "$1" 2>/dev/null | awk 'NR==1 {print $1}')" || {
            try=$((try + 1))
            [ "$try" -lt 2 ] && continue
            return 1
        }
        break
    done
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
# rc 0 = pruned · 1 = the tool is not available · 2 = the tool ran and failed.
# The three are LOGGED SEPARATELY: "prune=none" used to conflate "uv is not on this
# job's PATH" with "pip has no safe half", and the first of those silently skips the
# safe half and goes straight to entry removal.
# The tool is pointed at THE DIRECTORY THIS PASS MEASURED (UV_CACHE_DIR / --cache),
# so pruning can never hit a different cache than the one being bounded.
prune_cache() {
    local class="$1" dir="$2" tool out rc
    tool="$(tool_of "$class")"
    case "$class" in
        uv|npm) ;;
        *)
            # pip has no unused-entry prune (`pip cache purge` is the whole-cache
            # delete, i.e. the ESCALATION arm). Nothing to do safely — not a failure.
            return 1 ;;
    esac
    if [ -z "$tool" ] || ! command -v "$tool" >/dev/null 2>&1; then
        plog "pi-cache-reap:   prune($class): '${tool:-?}' is NOT on PATH (${PATH:-}) — the safe half is unavailable, only the escalation arm can act"
        return 1
    fi
    case "$class" in
        uv)
            # UV_LOCK_TIMEOUT bounds uv's own wait for a concurrent uv to release the
            # cache lock (vendor-documented 5 min default). Unbounded, a synchronous
            # `prune --caches` on a busy box stalls before it reports anything.
            out="$(UV_CACHE_DIR="$dir" UV_LOCK_TIMEOUT=30 "$tool" cache prune 2>&1)"; rc=$? ;;
        npm)
            # npm's cache ROOT is the parent of `_cacache`; point --cache at whichever
            # of the two this pass was given, so prune and measure cannot disagree.
            case "$(basename "$dir")" in
                _cacache) out="$("$tool" cache verify --cache "$(dirname "$dir")" 2>&1)"; rc=$? ;;
                *)        out="$("$tool" cache verify --cache "$dir" 2>&1)"; rc=$? ;;
            esac ;;
    esac
    if [ "$rc" -ne 0 ]; then
        plog "pi-cache-reap:   prune($class) failed (rc=$rc): ${out:-no output}"
        return 2
    fi
    return 0
}

# ── process table ─────────────────────────────────────────────────────
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
# ⛔ This runs against a SNAPSHOT taken before the probe process existed, so the
# scanner can never match itself (a `grep` whose argv holds the cache path would
# otherwise make every pass report a phantom holder).
# ⛔ The tool match is on the EXECUTABLE (argv[0], or the token after `/usr/bin/env`),
# NOT on a substring of the whole command line. Substring matching made an operator's
# own shell — any command text containing `uv ` — report itself as a live uv process,
# which refused escalation on a box with no uv running at all (measured while writing
# this script). The exec test still catches every real case: `uv sync`, `uv run …`,
# `/usr/bin/env UV_CACHE_DIR=… uv …`.
# ⛔ The entry match is `index()` — a LITERAL substring test. A sed-escaped ERE broke on
# any path carrying `+ ? ( ) { } |`: `/tmp/a+work/.cache/uv` became `a+work` under ERE
# (a quantifier), matched nothing, so a live process's entry was deleted and the pass
# reported VERIFIED (measured control pair, one character apart).
ps_matches() {
    local kind="$1" class="$2" dir="$3"
    [ -n "$PS_SNAP" ] || return 2
    case "$kind" in
        tool)
            printf '%s\n' "$PS_SNAP" | awk -v me="$$" -v tool="$class" '
                $1 == me { next }
                {
                    exe = $2; sub(/.*\//, "", exe)
                    if (exe == tool) { print; next }
                    # ⛔ npm and pip are NOT native binaries: npm runs as
                    # `node .../node_modules/npm/bin/npm-cli.js`, pip as
                    # `python3 .../pip/__main__.py` (or `python3 -m pip`). An argv[0]
                    # comparison therefore NEVER matches them, and a measured probe
                    # showed a live `npm install` failing to block the escalation —
                    # the guard was untested because the suite only stubbed a native
                    # uv holder. Match what the process IS, not just its binary name.
                    if (tool == "npm" && (index($0, "npm-cli.js") || index($0, "bin/npm"))) { print; next }
                    if (tool == "pip" && (index($0, "pip/__main__.py") || index($0, " -m pip") || index($0, "bin/pip"))) { print; next }
                    if (tool == "uv" && index($0, "bin/uv ")) { print; next }
                    if (exe == "env") {
                        i = 3
                        while (i <= NF && $i ~ /=/) i++
                        e2 = $i; sub(/.*\//, "", e2)
                        if (e2 == tool) print
                    }
                }'
            return 0 ;;
        dir)
            printf '%s\n' "$PS_SNAP" | awk -v me="$$" -v d="$dir" '$1 != me && index($0, d) { print }'
            return 0 ;;
        *) return 2 ;;
    esac
}

# dev_of <path> — the device id owning <path> (stat's portable spelling differs by OS).
dev_of() {
    local d
    d="$(stat -c %d "$1" 2>/dev/null)" || d="$(stat -f %d "$1" 2>/dev/null)" || return 1
    case "${d:-}" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$d"
}

# same_device <entry> <cache-dir> — rc 0 same fs · rc 1 different fs (a MOUNT inside
# the cache) · rc 2 undecidable. Never delete THROUGH a mount: `rm -rf` on a bind/FUSE
# mount point inside the cache recurses into whatever is mounted there.
same_device() {
    local a b
    a="$(dev_of "$1")" || return 2
    b="$(dev_of "$2")" || return 2
    [ "$a" = "$b" ] && return 0
    return 1
}

# shared_file_in <entry> — rc 0 = an entry file still has another link (stdout: that
# file) · rc 1 = nothing in the entry is hardlinked · rc 2 = could not be determined.
# PRESERVING a shared entry is the point: a uv cache entry is hardlinked into every
# `.venv` built from it, so unlinking the cache name frees NO bytes (measured: 914MB
# evicted, 7MB gained). Deterministic, unlike a "stop after N non-reclaiming deletes"
# heuristic — and it cannot be reset by the next hourly pass.
shared_file_in() {
    local f
    f="$(find "$1" -type f -links +1 -print -quit 2>/dev/null)" || return 2
    [ -n "$f" ] || return 1
    printf '%s' "$f"
}

# remove_entry <entry> — delete an entry WITHOUT ever crossing a filesystem boundary.
# ⛔ `rm -rf` recurses through a mount ANYWHERE below the entry, not only at it: a tmpfs
# mounted at `$CACHE/archive-v0/inner` was deleted THROUGH in a measured probe, because the
# depth-1 `same_device` stat of the entry cannot see it. `-xdev` never descends into another
# filesystem, so whatever is mounted there survives; the entry then cannot be removed whole
# and the pass reports the residue instead of claiming the reclaim. `-links 1` is a second
# belt: the entry-level check already refused shared entries, and a file that acquired a
# link since then must not be unlinked here either.
remove_entry() {
    local e="$1"
    # `! -type d` (files, links, FIFOs, sockets), not `-type f -o -type l`: a fifo or socket with
    # another name would otherwise survive and pin the entry forever, leaving the bound unmeetable.
    find "$e" -xdev ! -type d -links 1 -delete 2>/dev/null || true
    find "$e" -xdev -depth -type d -empty -delete 2>/dev/null || true
    [ ! -e "$e" ]
}

# entries_by_size <dir> <outfile> — every top-level entry of <dir>, largest first, as
# "<KiB><TAB><path>" lines in <outfile>. No recursive walk: only the cache's OWN top
# level is enumerated (uv: archive-v0/builds-v0/wheels-v3/…; npm: content-v2/index-v5/…;
# pip: http-v2/wheels/…), and `du` walks each entry once. Symlinked entries are
# SKIPPED — a planted `$CACHE/x -> ~/.ssh` must never reach a delete path.
# rc 1 when an entry cannot be measured: an unmeasurable entry must fail the pass, not
# silently sort last as size 0 (which is how a 3MB subdirectory became "16KB").
entries_by_size() {
    local dir="$1" out="$2" e kb
    : >"$TMPLIST"
    # ⛔ `find -print0` + `read -d ''`, NOT a glob and NOT `find -print`:
    #   * the shell globs `"$dir"/* "$dir"/.[!.]*` MISS a name beginning with two dots
    #     (`..x`, `...`), which then never reaches the record, never gets logged, and can never
    #     be evicted — so the bound becomes unmeetable for that cache and the verdict's "after
    #     evicting every removable entry" is a claim the pass did not test (measured).
    #   * `find -print` cannot carry a NEWLINE in a name: it would arrive as two records.
    while IFS= read -r -d '' e; do
        # ⛔ A TAB or NEWLINE in an entry name FORGES a record in this file. Measured: a cache
        # entry named $'evil\n999999\t<name>' produced a second record that sorted FIRST, and
        # the eviction loop deleted a cwd-relative `<name>` OUTSIDE the cache. Any process that
        # can write into the cache (a build backend, a postinstall script) can plant such a name,
        # and the deletion happens later, unattended. Refuse the whole cache instead: a name that
        # cannot be represented in the record must not be acted on, and (because the log is the
        # only audit trail) must not be written to the log either — which is why this check runs
        # BEFORE the symlink skip.
        case "$e" in
            *"$TAB"*|*"
"*) plog "pi-cache-reap:   an entry name is not representable in the eviction list (tab/newline) — refusing to act on $dir"
                return 1 ;;
        esac
        [ -L "$e" ] && { plog "pi-cache-reap:   skip symlinked entry $e"; continue; }
        [ -e "$e" ] || continue
        kb="$(kb_of "$e")" || { plog "pi-cache-reap:   cannot measure entry $e — refusing to size it as 0"; return 1; }
        printf '%s\t%s\n' "$kb" "$e" >>"$TMPLIST"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    sort -rn -k1,1 "$TMPLIST" >"$out"
    return 0
}

# reap_target <class> <dir> — bound ONE cache. Prints exactly one verdict line.
reap_target() {
    local class="$1" dir="$2" before_kb before_free_kb now_kb new_kb after_kb after_free_kb
    local pruned=none evicted=0 kb e cur_free holders dir_holders held_entries="" keep_entries=""
    local no_gain_stop=0 no_gain=0 last_free="" claimed_kb gained_kb min_gain_kb stop_note=""
    local dev_rc share_rc fresh_holders free_str parent

    case "$dir" in
        /*) ;;
        *) fail_closed "$class: cache dir '$dir' is not an absolute path — refusing to measure or touch it"; return 0 ;;
    esac
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        # ⛔ `-e` is false when an ANCESTOR denies search permission, so an existing, over-bound,
        # unreadable cache used to be reported as "absent (nothing to bound)" and the pass exited 0
        # — a pass on an unverified claim, which the contract forbids. Absent is only absent when
        # the parent is actually searchable.
        parent="$(dirname "$dir")"
        if [ -d "$parent" ] && [ ! -x "$parent" ]; then
            fail_closed "$class: $dir cannot be seen (the parent $parent is not searchable) — an unreadable cache is NOT an absent one"
            return 0
        fi
        say "pi-cache-reap: $class $dir absent (nothing to bound)"
        return 0
    fi
    [ -d "$dir" ] || { fail_closed "$class: $dir exists but is not a directory"; return 0; }

    before_kb="$(kb_of "$dir")" \
        || { fail_closed "$class: cannot measure $dir (du failed) — the bound cannot be enforced"; return 0; }

    # Read free space only when the cache is OVER its bound: an under-bound pass is then one
    # `du` per cache and nothing else, which is what makes an hourly clock cheap.
    if [ "$before_kb" -le "$MAX_KB" ]; then
        say "pi-cache-reap: $class $dir $(mb_str "$before_kb") <= ${MAX_MB}MB bound — no action"
        return 0
    fi

    if [ "$MODE" != "apply" ]; then
        OVER_ONLY=$((OVER_ONLY + 1))
        say "pi-cache-reap: DRY-RUN $class $dir $(mb_str "$before_kb") > ${MAX_MB}MB bound — would prune, then evict the largest entries while no $class process holds the cache (re-run with --apply)"
        return 0
    fi

    before_free_kb="$(free_kb "$dir")"

    # ── (1) the safe half ────────────────────────────────────────────────────
    prune_cache "$class" "$dir"
    case $? in
        0) pruned=ok ;;
        2) pruned=failed ;;
        *) pruned=unavailable ;;
    esac
    now_kb="$(kb_of "$dir")" \
        || { fail_closed "$class: cannot measure $dir after the prune — the shrink cannot be verified"; return 0; }

    # ⛔ No pre-pass free-space reading means NO WAY TO PROVE THE RECLAIM, so escalating is
    # deleting on a claim that cannot be checked (and the no-gain brake, keyed on that same
    # reading, would be silently inert while the pass emptied the cache). Refuse first.
    if [ "$now_kb" -gt "$MAX_KB" ] && [ -z "${before_free_kb:-}" ]; then
        fail_closed "$class: $dir is $(mb_str "$now_kb") > ${MAX_MB}MB but free space could not be read before the pass (df) — escalating would delete without any way to prove the reclaim"
        return 0
    fi

    # ── (2) escalate: largest entries first, skipping anything a live process names ──
    if [ "$now_kb" -gt "$MAX_KB" ]; then
        ps_snapshot || { fail_closed "$class: $dir is $(mb_str "$now_kb") > ${MAX_MB}MB and the ps probe could not answer — NOT escalating an unproven cache"; return 0; }
        holders="$(ps_matches tool "$class" "$dir")" \
            || { fail_closed "$class: $dir is $(mb_str "$now_kb") > ${MAX_MB}MB and the ps probe could not answer — NOT escalating an unproven cache"; return 0; }
        if [ -n "$holders" ]; then
            fail_closed "$class: $dir is $(mb_str "$now_kb") > ${MAX_MB}MB and a live $class process is running, so the entries it holds cannot be known — NOT escalating; process(es): $holders (the cache is shared, so any live $class on this box may be resolving against it)"
            return 0
        fi
        if ! entries_by_size "$dir" "$TMPLIST2"; then
            fail_closed "$class: $dir is $(mb_str "$now_kb") > ${MAX_MB}MB but one of its entries could not be measured — refusing to evict a cache we cannot size"
            return 0
        fi
        # ⛔ STOP DESTROYING WHEN DELETION STOPS RECLAIMING. Two mechanisms, because they
        # catch different things: (a) a shared entry is PRESERVED (see shared_file_in) so
        # the hourly clock cannot re-delete what frees nothing; (b) if plain deletes still
        # reclaim nothing, two in a row end the escalation.
        no_gain_stop=0; no_gain=0; last_free="${before_free_kb:-}"
        while IFS="$TAB" read -r kb e; do
            [ -n "${e:-}" ] || continue
            [ "$now_kb" -gt "$MAX_KB" ] || break
            # A malformed record is not a delete instruction. Both halves are validated: the
            # size must be a number, and the path must be INSIDE the cache being bounded — the
            # containment rule is the one the whole script promises, so it is enforced here,
            # at the point of deletion, not assumed from how the list was built.
            case "${kb:-}" in
                ''|*[!0-9]*) fail_closed "$class: malformed eviction record ('${kb:-}' '$e') — refusing to delete from a list that cannot be trusted"; break ;;
            esac
            case "$e" in
                "$dir"/*) ;;
                *) fail_closed "$class: entry '$e' is NOT inside $dir — refusing to delete outside the cache"; break ;;
            esac
            # ── the ACT-POINT re-probe (a resolver spawned mid-pass is invisible to the
            #    pass-start snapshot; #1105 is that class in the sibling reaper) ──
            ps_snapshot || { fail_closed "$class: the ps probe could not answer immediately before removing $e — NOT deleting an unproven entry"; break; }
            if [ -n "$(ps_matches tool "$class" "$dir" || true)" ]; then
                fail_closed "$class: a $class process started during this pass — stopping before $e (the entries it holds cannot be known)"
                break
            fi
            fresh_holders="$(ps_matches dir "$class" "$dir" || true)"
            if [ -n "$fresh_holders" ] && grep -qF -- "$e" <<<"$fresh_holders"; then
                held_entries="${held_entries:+$held_entries, }$e"
                plog "pi-cache-reap:   preserving $e — a live process names it"
                continue
            fi
            same_device "$e" "$dir"; dev_rc=$?
            if [ "$dev_rc" -eq 1 ]; then
                keep_entries="${keep_entries:+$keep_entries, }$e"
                plog "pi-cache-reap:   preserving $e — a different filesystem (mount point inside the cache); nothing is deleted THROUGH a mount"
                continue
            elif [ "$dev_rc" -ne 0 ]; then
                fail_closed "$class: cannot determine the filesystem holding $e — refusing to delete an entry that may be a mount"
                break
            fi
            shared_file_in "$e"; share_rc=$?
            if [ "$share_rc" -eq 0 ]; then
                keep_entries="${keep_entries:+$keep_entries, }$e"
                plog "pi-cache-reap:   preserving $e — still hardlinked (another name holds these bytes, so unlinking this one frees nothing)"
                continue
            elif [ "$share_rc" -ne 1 ]; then
                fail_closed "$class: cannot determine whether $e is still hardlinked — refusing to delete an entry that may free nothing"
                break
            fi
            if remove_entry "$e"; then
                evicted=$((evicted + 1))
                # Re-measure the WHOLE cache, not the entry: an entry can be a directory
                # holding more than `du` charged to its own top level (block rounding).
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
        done <"$TMPLIST2"
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

    # ⛔ ONE VERDICT PER CACHE: the still-over-bound check comes BEFORE the success line.
    # Printing "VERIFIED" and then "FAIL-CLOSED … STILL over bound" leaves a log in which
    # `grep VERIFIED` reports a cache that was never bounded.
    if [ "$after_kb" -gt "$MAX_KB" ]; then
        free_str="could not be read"
        [ -n "${after_free_kb:-}" ] && free_str="$(mb_str "$after_free_kb")"
        fail_closed "$class: $dir was $(mb_str "$before_kb") -> $(mb_str "$after_kb") after evicting every removable entry (prune=$pruned evicted=$evicted) — still over the ${MAX_MB}MB bound; free $(mb_str "${before_free_kb:-0}") -> $free_str${held_entries:+ — PRESERVED because a live process names them: $held_entries}${keep_entries:+ — preserved: $keep_entries}${stop_note}"
        return 0
    fi

    if [ "$after_free_kb" -le "$before_free_kb" ]; then
        fail_closed "$class: $dir shrank $(mb_str "$before_kb") -> $(mb_str "$after_kb") but the filesystem did NOT gain free space ($(mb_str "$before_free_kb") -> $(mb_str "$after_free_kb")) — the entries are still holding their bytes elsewhere (hardlinked into a .venv); nothing was actually freed. The owner for those bytes is the per-worktree sweep: cloud-cell-supervisor.sh prune${stop_note}"
        return 0
    fi
    # The disk gain must be a real fraction of what the cache claims to have given up. A
    # 1:100 gain is the incident's own failure mode wearing a success line: MEASURED on
    # pi-cell-3 after this arm landed — 914MB of cache evicted, 7MB of disk gained,
    # because the entries were hardlinked into that box's worktree `.venv`s. Tunable,
    # because a busy box can legitimately write while the pass runs.
    claimed_kb=$(( before_kb - after_kb ))
    gained_kb=$(( after_free_kb - before_free_kb ))
    min_gain_kb=$(( claimed_kb * MIN_RECLAIM_PCT / 100 ))
    if [ "$gained_kb" -lt "$min_gain_kb" ]; then
        fail_closed "$class: $dir shrank $(mb_str "$before_kb") -> $(mb_str "$after_kb") ($(mb_str "$claimed_kb") claimed) but the filesystem gained only $(mb_str "$gained_kb") ($(mb_str "$before_free_kb") -> $(mb_str "$after_free_kb")) — under ${MIN_RECLAIM_PCT}% of the claim, so the bytes are NOT verified as reclaimed (hardlinked into a .venv? the owner for those is: cloud-cell-supervisor.sh prune)${stop_note}"
        return 0
    fi

    say "pi-cache-reap: $class $dir $(mb_str "$before_kb") -> $(mb_str "$after_kb") (prune=$pruned evicted=$evicted) max=${MAX_MB}MB; free $(mb_str "$before_free_kb") -> $(mb_str "$after_free_kb") (+$(mb_str "$gained_kb")) VERIFIED${keep_entries:+ (preserved: $keep_entries)}${stop_note}"
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

# ── lock (macOS has no flock) ────────────────────────────────────────────────
# TWO CLOCKS EXIST ON A MAC: the launchd job and the orchestrator harness both run
# this script (`install.sh` is macOS-only and orch-loop is what deploy-mac-orchestrator
# runs). The version of this script that relied on "each platform has one clock" let two
# --apply passes measure the same free-space delta, so one could print VERIFIED for a
# shrink the other performed. Same shape as pi-reap-worktrees.sh:425.
lock_release() {
    if [ "$LOCK_HELD" = 1 ]; then
        # ⛔ Only ever remove a lock that is PROVABLY OURS: a pass that broke this one as stale
        # and took it must not have its own lock deleted by the previous holder's EXIT trap.
        [ "$(cat "$LOCK_DIR/owner" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null || true
        LOCK_HELD=0
    fi
    return 0
}
lock_acquire() {
    local owner started now age mtime
    # rc 3 when the lock cannot exist at all (unusable state dir): that is fail-closed, NOT a
    # benign "another pass holds it". Suppressing this made an unwritable state dir look like a
    # skip forever — the reaper never ran and every surface reported success-by-silence.
    if ! mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null; then
        printf '%s\n' "pi-cache-reap: cannot create the lock directory ($(dirname "$LOCK_DIR")) — refusing to run without mutual exclusion (exit 3)" >&2
        return 3
    fi
    if [ -d "$LOCK_DIR" ]; then
        owner="$(cat "$LOCK_DIR/owner" 2>/dev/null || printf '')"
        started="$(cat "$LOCK_DIR/started" 2>/dev/null || printf '')"
        now="$(now_epoch)"
        # A missing/corrupt owner or start stamp must NOT read as "stale": the window
        # between `mkdir` and the owner write is real, and treating it as stale let two
        # passes run concurrently in pi-reap-worktrees. Unknown age => not stale.
        age=""
        if is_pos_int "$started" && is_pos_int "$now" && [ "$now" -ge "$started" ]; then
            age=$(( now - started ))
        else
            mtime="$(/bin/date -r "$LOCK_DIR" +%s 2>/dev/null || printf '')"
            if is_pos_int "$mtime" && is_pos_int "$now" && [ "$now" -ge "$mtime" ]; then
                age=$(( now - mtime ))
            fi
        fi
        [ -n "$age" ] || age=0
        # ⛔ A LIVE owner is never broken, however old the lock is: the age bound exists for a
        # pass that died without releasing, not for one that is still running (a multi-GB cache
        # can outlast the trigger period, and breaking it re-creates the double-pass this lock
        # exists to prevent). Only an unverifiable owner is subject to the age bound.
        if is_pos_int "$owner" && kill -0 "$owner" 2>/dev/null; then
            say "pi-cache-reap: another pass is running (pid $owner, ${age}s) — this one does not run ($ISSUE_REF)"
            return 1
        fi
        if [ "$age" -lt "$LOCK_STALE_SECONDS" ]; then
            say "pi-cache-reap: lock held (owner=${owner:-?} age ${age}s, owner unverifiable) — this pass does not run"
            return 1
        fi
        plog "pi-cache-reap: breaking a stale lock (owner=${owner:-?} age=${age}s)"
        # ⛔ The BREAK must have exactly one winner. A read-then-`rm -rf`-then-`mkdir` lets two
        # passes both observe the same stale lock, both remove it and both run — and a late
        # breaker deletes the fresh lock the winner just created (reproduced). One process wins
        # the break token; the loser does not run.
        if ! mkdir "$LOCK_DIR.break" 2>/dev/null; then
            say "pi-cache-reap: another pass is already clearing a stale lock — this one does not run"
            return 1
        fi
        # Re-read under the token: the lock may have been replaced while we were deciding.
        if [ -d "$LOCK_DIR" ] && [ "$(cat "$LOCK_DIR/started" 2>/dev/null)" = "$started" ]; then
            mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null || true
            rm -rf "$LOCK_DIR.stale.$$" 2>/dev/null || true
        fi
        rmdir "$LOCK_DIR.break" 2>/dev/null || true
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        # Could not create the lock although nobody holds it: an unusable state dir, not a race.
        if [ ! -d "$LOCK_DIR" ]; then
            printf '%s\n' "pi-cache-reap: cannot create the lock at $LOCK_DIR — refusing to run without mutual exclusion (exit 3)" >&2
            return 3
        fi
        say "pi-cache-reap: lock raced with another pass — this one does not run"
        return 1
    fi
    printf '%s\n' "$$" >"$LOCK_DIR/owner" 2>/dev/null || true
    printf '%s\n' "$(now_epoch)" >"$LOCK_DIR/started" 2>/dev/null || true
    LOCK_HELD=1
    return 0
}

# ── arguments ────────────────────────────────────────────────────────────────
for a in "$@"; do
    case "$a" in
        --dry-run) MODE=dry-run; MODE_SET=1 ;;
        --apply) MODE=apply; MODE_SET=1 ;;
        --print-config) PRINT_CONFIG=1 ;;
        # The sibling reapers exit 0 on --help (pi-reap-worktrees.sh:1130, pi-reap-idle.sh:1229,
        # pi-task-session-prune.sh:260): `reaper --help && ...` must not fail. 2 stays the code
        # for an UNKNOWN argument.
        --help|-h) usage 0 ;;
        *) printf '%s: unknown argument %s\n' "$SCRIPT_NAME" "$a" >&2; usage ;;
    esac
done
# ⛔ An explicit flag wins. `CACHE_REAP_APPLY=1` is a DEFAULT (arm this machine in a
# shell profile), so `CACHE_REAP_APPLY=1 pi-cache-reap.sh --dry-run` must inspect and
# mutate nothing — the previous order (env last) turned that inspection into the
# destructive pass it was meant to preview.
if [ "$MODE_SET" -eq 0 ] && [ "${CACHE_REAP_APPLY:-0}" = "1" ]; then MODE=apply; fi

# The log dir is created BEFORE validation so a rejected bound still leaves a trace:
# the launchd job captures no stderr, so a typo'd CACHE_REAP_MAX_MB would otherwise mint
# an hourly timer that is dead and invisible.
if [ -n "$LOG" ]; then
    if ! mkdir -p "$(dirname "$LOG")" 2>/dev/null || ! : >>"$LOG" 2>/dev/null; then
        # The family rule: a reaper that deletes with no audit trail is indistinguishable from
        # one that did nothing. Dry-run may proceed loudly on stderr; an ARMED pass may not run.
        if [ "$MODE" = apply ]; then
            printf '%s\n' "pi-cache-reap: cannot write the pass log ($LOG) — refusing to delete with no audit trail (exit 3)" >&2
            exit 3
        fi
        LOG=""
    fi
fi

case "${MAX_MB:-}" in
    ''|*[!0-9]*|0*)
        msg="$SCRIPT_NAME: CACHE_REAP_MAX_MB must be a positive whole number of MiB (got ${MAX_MB:-})"
        printf '%s\n' "$msg" >&2
        [ -n "$LOG" ] && printf '%s\n' "$msg" >>"$LOG" 2>/dev/null
        exit 2 ;;
esac
MAX_KB=$(( 10#$MAX_MB * 1024 ))
# The share of the claimed reduction that must actually appear as free disk (#1987 item 4).
MIN_RECLAIM_PCT="${CACHE_REAP_MIN_RECLAIM_PCT:-50}"
case "$MIN_RECLAIM_PCT" in ''|*[!0-9]*) MIN_RECLAIM_PCT=50 ;; esac
[ "$MIN_RECLAIM_PCT" -le 100 ] || MIN_RECLAIM_PCT=100

# ── the sinks (uv, npm, pip — the same class of machine-global sink) ─────────
# EVERY sink is resolved from its OWNING TOOL's answer, not from a `$HOME` guess. A guessed
# path bounds a directory the tool may not use, and the failure is silent: the pass reports
# "absent (nothing to bound)", exits 0, and the real cache stays over bound. Measured for uv
# (XDG_CACHE_HOME set → uv's cache is $XDG_CACHE_HOME/uv), and the same hole existed for pip
# (XDG_CACHE_HOME) and npm (NPM_CONFIG_CACHE / .npmrc `cache=`) until they were resolved too.
# Each falls back to the documented location when the tool is absent or answers nothing.
resolve_uv_dir() {
    local d
    if [ -n "${CACHE_REAP_UV_DIR:-}" ]; then printf '%s' "$CACHE_REAP_UV_DIR"; return 0; fi
    if command -v "$UV_BIN" >/dev/null 2>&1; then
        d="$("$UV_BIN" cache dir 2>/dev/null)"
        case "${d:-}" in /*) printf '%s' "$d"; return 0 ;; esac
    fi
    printf '%s' "${UV_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-}/.cache}/uv}"
}

# npm answers with the cache ROOT; the directory this script bounds is its `_cacache` child
# (prune_cache already special-cases that basename).
resolve_npm_dir() {
    local d
    if [ -n "${CACHE_REAP_NPM_DIR:-}" ]; then printf '%s' "$CACHE_REAP_NPM_DIR"; return 0; fi
    if command -v "$NPM_BIN" >/dev/null 2>&1; then
        d="$("$NPM_BIN" config get cache 2>/dev/null | tail -1)"
        case "${d:-}" in /*) printf '%s' "$d/_cacache"; return 0 ;; esac
    fi
    printf '%s' "${HOME:-}/.npm/_cacache"
}

# `pip cache dir` also resolves the macOS ~/Library/Caches/pip case, which the separate
# PIPD_MAC probe below keeps as a second candidate for an older pip.
resolve_pip_dir() {
    local d
    if [ -n "${CACHE_REAP_PIP_DIR:-}" ]; then printf '%s' "$CACHE_REAP_PIP_DIR"; return 0; fi
    if command -v "$PIP_BIN" >/dev/null 2>&1; then
        d="$("$PIP_BIN" cache dir 2>/dev/null)"
        case "${d:-}" in /*) printf '%s' "$d"; return 0 ;; esac
    fi
    printf '%s' "${XDG_CACHE_HOME:-${HOME:-}/.cache}/pip"
}

UVD="$(resolve_uv_dir)"
NPMD="$(resolve_npm_dir)"
PIPD="$(resolve_pip_dir)"
PIPD_MAC="${CACHE_REAP_PIP_DIR_MAC:-${HOME:-}/Library/Caches/pip}"

# --print-config: the ONE place that knows the paths and the bound. The bring-up report
# and the supervisor's remedy line read this instead of keeping their own copies, which
# is how a tuned bound ends up disagreeing with the report about the same cache.
if [ "$PRINT_CONFIG" = 1 ]; then
    printf 'bound_mb=%s\n' "$MAX_MB"
    if [ -n "${CACHE_REAP_MAX_MB:-}" ]; then printf 'bound_source=env\n'; else printf 'bound_source=default\n'; fi
    printf 'cache=uv:%s\n' "$UVD"
    printf 'cache=npm:%s\n' "$NPMD"
    printf 'cache=pip:%s\n' "$PIPD"
    [ "$PIPD_MAC" = "$PIPD" ] || printf 'cache=pip:%s\n' "$PIPD_MAC"
    exit 0
fi

TMPLIST="$(mktemp "${TMPDIR:-/tmp}/pi-cache-reap.XXXXXX")" || { printf '%s: cannot create a temp file\n' "$SCRIPT_NAME" >&2; exit 3; }
TMPLIST2="$(mktemp "${TMPDIR:-/tmp}/pi-cache-reap.XXXXXX")" || { printf '%s: cannot create a temp file\n' "$SCRIPT_NAME" >&2; exit 3; }

# ⛔ A SKIPPED PASS IS NOT A PASS (exit 4, distinct from 0). The callers clear their
# "cache bound not enforced" record on 0; a pass that never ran must neither clear it nor
# set it, or a launchd pass holding the lock makes the cell's hourly clock erase a real
# failure it did not re-measure.
lock_acquire; LOCK_RC=$?
case "$LOCK_RC" in
    0) ;;
    3) exit 3 ;;   # the lock cannot exist: fail closed, never a silent skip
    *) exit 4 ;;   # another pass holds it: did not run
esac
trap 'cleanup; lock_release' EXIT

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
# ⛔ THE PASS-END LINE MUST NOT CLAIM A BOUND THE PASS DID NOT ENFORCE. On the shipped dry-run
# stance an over-bound cache used to print "every present cache bounded and verified" and exit 0
# — and the cell's clock reads 0 as "the bound was cleared", so the incident state (cache over
# bound, reaper unarmed) was indistinguishable from a healthy one on every surface.
if [ "$OVER_ONLY" -gt 0 ]; then
    say "pi-cache-reap: pass end mode=$MODE — $OVER_ONLY cache(s) are OVER the ${MAX_MB}MB bound and were NOT acted on (dry-run: arming is an owner step, agent-infra#1678)"
    exit 5
fi
say "pi-cache-reap: pass end mode=$MODE — every present cache is under the ${MAX_MB}MB bound"
exit 0
