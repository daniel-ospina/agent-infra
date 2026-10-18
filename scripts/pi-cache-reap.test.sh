#!/usr/bin/env bash
# pi-cache-reap.test.sh — self-check for scripts/pi-cache-reap.sh, its launchd
# template and the two triggers that make it run unprompted (agent-infra#1987).
#
# Run: bash scripts/pi-cache-reap.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Hermetic: every cache is a
# fixture directory in a temp HOME, and ps/df/the tool binaries are stubs — the
# real ~/.cache/uv of the machine running this suite is never read or touched.
#
# THE LOAD-BEARING CASE (the issue's own validation item): A FIXTURE CACHE OVER
# THE BOUND MUST COME BACK UNDER IT. That is what a "reaper that is not invoked"
# fails — the fixture stays over its bound, no matter how green the rest of the
# suite is. It is asserted on the FIXTURE's size after the pass, not on the
# reaper's own prose.
#
# Coverage:
#   bounded     over-bound uv + npm + pip fixtures are all shrunk under the bound
#               in ONE armed pass (exit 0); under-bound caches are untouched
#   dry-run     the default mode mutates NOTHING and says so
#   holder      a live `uv` process → nothing evicted, exit 3, the holder is named
#   probe       an unusable ps probe (empty table) → nothing evicted, exit 3
#   hardlinks   the cache shrinks but the filesystem does not gain a byte (a uv
#               cache entry hardlinked into a .venv) → exit 3, named as such. This
#               is the "reports success while freeing nothing" failure mode #1987
#               calls out; asserting only the cache size would pass it.
#   measure     an unmeasurable cache (a path that is not a directory) → exit 3
#   symlinks    a symlinked entry inside a cache is skipped, never followed
#   policy      prune (the safe half) runs BEFORE any entry is removed
#   wiring      the farm declares the script, the plist ships ARMED and hourly,
#               and both triggers (Mac launchd, cell controller loop) name it —
#               a bound no box ever runs is the defect this issue is about

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/pi-cache-reap.sh"
TEMPLATE="$SCRIPT_DIR/../templates/launchd/com.eldato.pi-cache-reap.plist"
SETUP="$SCRIPT_DIR/../pi-bootstrap/setup.sh"
ORCH="$SCRIPT_DIR/orchestrator-harness/orch-loop.sh"
SUPERVISOR="$SCRIPT_DIR/cloud-cell-supervisor.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
assert_le() { if [ "${1:-x}" -le "${2:-y}" ] 2>/dev/null; then ok "$3"; else bad "$3 (got: ${1:-?}, want <= ${2:-?})"; fi }

T="$(mktemp -d "${TMPDIR:-/tmp}/pi-cache-reap-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

[ -f "$REAPER" ] || { echo "❌ missing $REAPER"; exit 1; }

BOUND_MB=2
BOUND_KB=$(( BOUND_MB * 1024 ))

kb() { du -sk "$1" 2>/dev/null | awk 'NR==1 {print $1}'; }

# ── fixtures: package caches big enough to cross a 2MB bound ──────────────
# The uv entries are real files, so `du` measures real bytes and the eviction
# order (largest first) is verifiable.
new_cache() { # $1 = dir, $2.. = sizes in KB
    local d="$1" n=0
    shift
    rm -rf "$d"
    for s in "$@"; do
        n=$((n + 1))
        mkdir -p "$d/entry-$n"
        dd if=/dev/zero of="$d/entry-$n/blob" bs=1024 count="$s" 2>/dev/null
    done
}

# ── stubs ────────────────────────────────────────────────────────────────
mkdir -p "$T/bin"

# ps: a table with NO holder, a table WITH a uv, and an unusable (empty) probe.
cat >"$T/bin/ps-idle" <<'SH'
#!/bin/sh
printf '%s\n' "    1 /sbin/init" "  222 bash -l"
SH
cat >"$T/bin/ps-uv" <<'SH'
#!/bin/sh
printf '%s\n' "    1 /sbin/init" " 4242 /usr/local/bin/uv sync --frozen"
SH
cat >"$T/bin/ps-empty" <<'SH'
#!/bin/sh
exit 0
SH

# df: real (delegates) and one that never reports a gain — the hardlink case.
cat >"$T/bin/df-gain" <<SH
#!/bin/sh
# +16 MiB of available space per call, so a verified pass clears the reclaim ratio.
n_file="$T/df.calls"
n=\$(cat "\$n_file" 2>/dev/null || echo 0)
echo \$((n + 1)) >"\$n_file"
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 100000 4000 \$(( 10000 + n * 16384 )) 4% /"
SH
cat >"$T/bin/df-flat" <<'SH'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 100000 4000 10000 4% /"
SH
# A 1:70 gain — the shape measured on pi-cell-3 (914MB evicted, 7MB gained). It must FAIL the
# reclaim test: a success line here is exactly the false PASS #1987 calls out.
cat >"$T/bin/df-tiny" <<SH
#!/bin/sh
n_file="$T/df-tiny.calls"
n=\$(cat "\$n_file" 2>/dev/null || echo 0)
echo \$((n + 1)) >"\$n_file"
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 100000 4000 \$(( 10000 + n * 100 )) 4% /"
SH
chmod +x "$T/bin/"*

# uv stub: "prunes" (records the call) but removes nothing — the WORST case the
# escalation arm must handle, and it keeps the fixture deterministic.
cat >"$T/bin/uv-noprune" <<SH
#!/bin/sh
echo "prune \$* UV_CACHE_DIR=\${UV_CACHE_DIR:-unset}" >>"$T/prune.calls"
exit 0
SH
cat >"$T/bin/uv-fail" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$T/bin/"*

run_reap() { # run_reap <home> <mode> [extra env assignments...]
    local home="$1" mode="$2"
    shift 2
    env HOME="$home" \
        CACHE_REAP_MAX_MB="$BOUND_MB" \
        CACHE_REAP_LOG="$home/reap.log" \
        CACHE_REAP_PS="${PS_STUB:-$T/bin/ps-idle}" \
        CACHE_REAP_DF="${DF_STUB:-$T/bin/df-gain}" \
        CACHE_REAP_UV="${UV_STUB:-$T/bin/uv-noprune}" \
        CACHE_REAP_NPM="${UV_STUB:-$T/bin/uv-noprune}" \
        CACHE_REAP_PIP="${UV_STUB:-$T/bin/uv-noprune}" \
        "$@" \
        bash "$REAPER" "$mode"
}

echo "── 1. over-bound caches come back UNDER the bound (the load-bearing case) ──"
H="$T/h1"
new_cache "$H/.cache/uv" 3000 2000
new_cache "$H/.npm/_cacache" 2600
new_cache "$H/.cache/pip" 2400
new_cache "$H/.cache/keepme" 10
UV_BEFORE="$(kb "$H/.cache/uv")"; NPM_BEFORE="$(kb "$H/.npm/_cacache")"; PIP_BEFORE="$(kb "$H/.cache/pip")"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "an armed pass over three over-bound caches exits 0 (shrink verified)"
assert_le "$(kb "$H/.cache/uv")" "$BOUND_KB" "uv cache is UNDER the ${BOUND_MB}MB bound after the pass (a reaper that is not invoked leaves it over)"
assert_le "$(kb "$H/.npm/_cacache")" "$BOUND_KB" "npm cache is UNDER the bound after the pass"
assert_le "$(kb "$H/.cache/pip")" "$BOUND_KB" "pip cache is UNDER the bound after the pass"
[ "$(kb "$H/.cache/uv")" -lt "$UV_BEFORE" ] && ok "uv cache strictly SHRANK ($(( UV_BEFORE / 1024 ))MB -> $(( $(kb "$H/.cache/uv") / 1024 ))MB)" \
                                           || bad "uv cache did not shrink at all ($UV_BEFORE KB)"
[ "$(kb "$H/.npm/_cacache")" -lt "$NPM_BEFORE" ] && ok "npm cache strictly SHRANK" || bad "npm cache did not shrink"
[ "$(kb "$H/.cache/pip")" -lt "$PIP_BEFORE" ] && ok "pip cache strictly SHRANK" || bad "pip cache did not shrink"
assert_contains "$OUT" "VERIFIED" "the pass says the shrink is VERIFIED"
assert_contains "$OUT" "->" "the pass logs the before/after in one line (| -> |)"
assert_contains "$(cat "$H/reap.log")" "VERIFIED" "the same verdict reaches the log file (a scheduled job's only surface)"

echo
echo "── 2. under-bound caches are left alone, and the safe half runs first ──"
H="$T/h2"
new_cache "$H/.cache/uv" 100
UV_BEFORE="$(kb "$H/.cache/uv")"
: >"$T/prune.calls"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "an under-bound cache exits 0"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "an under-bound cache is NOT touched (no needless deletion)"
assert_not_contains "$OUT" "prune=" "no prune is reported for a cache under its bound"
[ -s "$T/prune.calls" ] && bad "uv was invoked although the cache was under the bound" \
                        || ok "uv was NOT invoked for an under-bound cache"

H="$T/h2b"
new_cache "$H/.cache/uv" 3000 2000
: >"$T/prune.calls"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_contains "$(cat "$T/prune.calls" 2>/dev/null)" "cache prune" "the SAFE half ran: 'uv cache prune' was invoked before any eviction"
assert_contains "$(cat "$T/prune.calls" 2>/dev/null)" "UV_CACHE_DIR=$H/.cache/uv" "prune is pointed at the cache this pass MEASURED (never a different one)"
assert_contains "$OUT" "prune=ok" "the pass reports that the prune ran"

echo
echo "── 3. dry-run (the default) mutates nothing ──"
H="$T/h3"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
OUT="$(run_reap "$H" --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "0" "dry-run exits 0"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "dry-run deleted NOTHING"
assert_contains "$OUT" "DRY-RUN" "dry-run says so, naming the cache over its bound"

echo
echo "── 4. a live holder: nothing evicted, and the pass refuses ──"
H="$T/h4"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
OUT="$(PS_STUB="$T/bin/ps-uv" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a cache over its bound with a live uv exits 3 (the bound was not enforced)"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "NOTHING was evicted while a uv process could be resolving against the cache"
assert_contains "$OUT" "live uv process is running" "the refusal names the tool-process rule"
assert_contains "$OUT" "uv sync" "the refusal names the actual holder process"

echo
echo "── 4b. a process naming ONE entry preserves only that entry ──"
H="$T/h4b"
new_cache "$H/.cache/uv" 700 3000
# A leaked uv build backend: its parent is gone, its argv names builds-v0/.tmpXXXX, and it will
# never exit. MEASURED on pi-cell-3 (three of them, 4-8 hours old). A whole-cache veto on one of
# these is the never-reaps non-action, so the entry it names is skipped and the rest evicted.
cat >"$T/bin/ps-entry" <<SH
#!/bin/sh
printf '%s\n' "    1 /sbin/init" " 4242 $H/.cache/uv/entry-1/.tmpXYZ/bin/python -c import setuptools.build_meta"
SH
chmod +x "$T/bin/ps-entry"
OUT="$(PS_STUB="$T/bin/ps-entry" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "the pass SUCCEEDS: one stuck holder does not disable the bound"
[ -d "$H/.cache/uv/entry-1" ] && ok "the entry a live process NAMES is preserved" \
                                 || bad "the entry a live process names was deleted"
[ ! -d "$H/.cache/uv/entry-2" ] && ok "the OTHER entries were still evicted (largest first)" \
                                   || bad "entry-2 survived — the escalation did not run at all"
assert_le "$(kb "$H/.cache/uv")" "$BOUND_KB" "the cache came back UNDER the bound with the held entry kept"

echo
echo "── 4c. held entries alone above the bound: refused, and named ──"
H="$T/h4c"
new_cache "$H/.cache/uv" 3000 2000
cat >"$T/bin/ps-entry2" <<SH
#!/bin/sh
printf '%s\n' "    1 /sbin/init" " 4242 $H/.cache/uv/entry-1/.tmpXYZ/bin/python -c import setuptools.build_meta"
SH
chmod +x "$T/bin/ps-entry2"
OUT="$(PS_STUB="$T/bin/ps-entry2" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a cache STILL over its bound after every removable entry exits 3"
[ -d "$H/.cache/uv/entry-1" ] && ok "the held entry was still never touched" || bad "the held entry was deleted"
assert_contains "$OUT" "PRESERVED because a live process names them" "the refusal names what blocked the bound (not a vague 'failed')"

echo "── 5. an unusable ps probe is never read as 'no holder' ──"
H="$T/h5"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
OUT="$(PS_STUB="$T/bin/ps-empty" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "an empty ps table exits 3 rather than escalating blind"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "nothing was evicted on an unproven cache"
assert_contains "$OUT" "ps probe could not answer" "the refusal names the probe, not a phantom holder"

echo
echo "── 6. the hardlink case: cache shrank, disk did not gain a byte ──"
H="$T/h6"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
OUT="$(DF_STUB="$T/bin/df-flat" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a shrink that frees no disk exits 3 (NOT a success)"
[ "$(kb "$H/.cache/uv")" -lt "$UV_BEFORE" ] && ok "the cache itself did shrink (so only the VERIFICATION can catch this)" \
                                           || bad "the fixture did not shrink — the case does not exercise the guard"
assert_contains "$OUT" "did NOT gain free space" "the refusal names the disk, not the cache size"
assert_contains "$OUT" "hardlink" "the refusal explains WHY (entries hardlinked into a .venv)"

echo
echo "── 6b. deletion that stops reclaiming STOPS (it does not destroy the rest) ──"
H="$T/h6b"
new_cache "$H/.cache/uv" 3000 2500 2000 1800
OUT="$(DF_STUB="$T/bin/df-flat" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a cache still over its bound with no disk gain exits 3"
[ -d "$H/.cache/uv/entry-3" ] && [ -d "$H/.cache/uv/entry-4" ] \
  && ok "eviction STOPPED after two non-reclaiming deletions (the rest of the cache was not destroyed for nothing)" \
  || bad "the pass kept deleting entries that reclaim nothing — it destroyed the cache for no disk"
assert_contains "$OUT" "STOPPED EARLY" "the log says WHY it stopped, so a reader is not left guessing"

echo
echo "── 6c. a token gain (1:70) is NOT a verified reclaim ──"
H="$T/h6c"
new_cache "$H/.cache/uv" 3000 2500
OUT="$(DF_STUB="$T/bin/df-tiny" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a gain far below the claimed reduction exits 3 (the pi-cell-3 shape: 914MB evicted, 7MB gained)"
assert_contains "$OUT" "under 50% of the claim" "the refusal names the reclaim ratio it failed"
assert_contains "$OUT" "cloud-cell-supervisor.sh prune" "the refusal points at the owner for hardlinked venv bytes"

echo
echo "── 7. an unmeasurable cache fails closed ──"
H="$T/h7"
mkdir -p "$H/.cache"
printf 'not a directory\n' >"$H/.cache/uv"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a cache path that cannot be measured exits 3"
assert_contains "$OUT" "not a directory" "the refusal names the reason"
assert_eq "$(cat "$H/.cache/uv")" "not a directory" "the offending path was not touched"

echo
echo "── 8. a symlinked entry inside a cache is skipped, never followed ──"
H="$T/h8"
new_cache "$H/.cache/uv" 3000 2000
mkdir -p "$H/.precious"
printf 'source of truth\n' >"$H/.precious/data"
ln -sfn "$H/.precious" "$H/.cache/uv/entry-9"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "the pass still completes with a symlinked entry present"
assert_eq "$(cat "$H/.precious/data")" "source of truth" "the symlink TARGET survived untouched"
[ -e "$H/.precious/data" ] && ok "the target tree still exists (no containment escape)" || bad "the symlink target was deleted"

echo
echo "── 9. input validation: an unusable bound is refused, not silently defaulted ──"
OUT="$(env CACHE_REAP_MAX_MB=abc bash "$REAPER" --apply 2>&1)"; RC=$?
assert_eq "$RC" "2" "a non-numeric CACHE_REAP_MAX_MB is a usage error (exit 2)"
assert_contains "$OUT" "CACHE_REAP_MAX_MB" "the refusal names the variable"
OUT="$(bash "$REAPER" --bogus 2>&1)"; RC=$?
assert_eq "$RC" "2" "an unknown argument is a usage error"
OUT="$(bash "$REAPER" --help 2>&1)"; RC=$?
assert_eq "$RC" "2" "--help prints usage (documented exit 2)"
assert_contains "$OUT" "--apply" "--help documents the arming flag"

echo
echo "── 10. wiring: a bound no box runs is the defect ──"
assert_contains "$(sed -n 's/^fleet_srcs=(\(.*\))$/\1/p' "$SETUP")" "pi-cache-reap.sh" \
    "pi-bootstrap/setup.sh's farm declares pi-cache-reap.sh (it is the copy the boxes execute)"
[ -f "$TEMPLATE" ] && ok "the launchd template exists" || bad "missing $TEMPLATE"
assert_contains "$(cat "$TEMPLATE" 2>/dev/null)" "{{HOME}}/.pi/agent/scripts/pi-cache-reap.sh" \
    "the plist runs the FARMED script ($HOME/.pi/agent/scripts), not a ~/Documents path"
assert_contains "$(cat "$TEMPLATE" 2>/dev/null)" "<string>--apply</string>" \
    "the plist ships ARMED (a reporting-only job leaves the 7.1GB incident free to recur)"
assert_contains "$(cat "$TEMPLATE" 2>/dev/null)" "<integer>3600</integer>" "the plist is hourly"
assert_contains "$(cat "$ORCH" 2>/dev/null)" "pi-cache-reap.sh" \
    "a CELL has no launchd: the controller loop names the reaper as its trigger"
assert_contains "$(cat "$SUPERVISOR" 2>/dev/null)" "pi-cache-reap.sh" \
    "the low-disk prune remedy reaches the machine-global caches too"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
