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
#   wiring      the farm declares the script, the plist ships DRY-RUN and hourly,
#               and both triggers (Mac launchd, cell controller loop) name it —
#               a bound no box ever runs is the defect this issue is about

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SCRIPT_DIR/pi-cache-reap.sh"
TEMPLATE="$SCRIPT_DIR/../templates/launchd/com.eldato.pi-cache-reap.plist"
SETUP="$SCRIPT_DIR/../pi-bootstrap/setup.sh"
ORCH="$SCRIPT_DIR/orchestrator-harness/orch-loop.sh"
SUPERVISOR="$SCRIPT_DIR/cloud-cell-supervisor.sh"
BRINGUP="$SCRIPT_DIR/cloud-cell-bringup.sh"

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
# The REAL shapes: npm is a script run by node, pip a module run by python3 — neither has an
# argv[0] of "npm"/"pip", so an argv[0]-only matcher never sees them (measured: a live
# `npm install` did not block the escalation).
cat >"$T/bin/ps-npm" <<'SH'
#!/bin/sh
printf '%s\n' "    1 /sbin/init" " 5151 /usr/local/bin/node /usr/local/lib/node_modules/npm/bin/npm-cli.js install"
SH
cat >"$T/bin/ps-pip" <<'SH'
#!/bin/sh
printf '%s\n' "    1 /sbin/init" " 5152 /usr/bin/python3 -m pip install requests"
SH
# pip installed as a console script is `<python3> .../bin/pip install …` — argv[0] is python3, and
# the matcher knew only `bin/pip3`, so a canonical `pip install` did not block the escalation.
cat >"$T/bin/ps-pip2" <<'SH'
#!/bin/sh
printf '%s\n' "    1 /sbin/init" " 5153 /usr/bin/python3 /opt/venv/bin/pip install somepkg"
SH
# df that cannot answer at all: "cannot judge", never "plenty".
cat >"$T/bin/df-silent" <<'SH'
#!/bin/sh
exit 0
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
# escalation arm must handle, and it keeps the fixture deterministic. `uv cache dir`
# is answered with nothing (so the resolver falls back to $HOME/.cache/uv) and is NOT
# recorded, because a directory RESOLUTION is not a prune.
cat >"$T/bin/uv-noprune" <<SH
#!/bin/sh
# Only a PRUNE is recorded: `cache dir` (uv/pip) and `config get cache` (npm) are directory
# RESOLUTIONS, not prunes, and counting them would make "was uv invoked?" unanswerable.
if [ "\$1" = cache ] && [ "\$2" = prune ]; then
  echo "prune \$* UV_CACHE_DIR=\${UV_CACHE_DIR:-unset}" >>"$T/prune.calls"
fi
exit 0
SH
cat >"$T/bin/uv-fail" <<'SH'
#!/bin/sh
exit 1
SH
# du: a cache with one unreadable subdirectory still prints a NUMERIC partial total and
# exits 1 (measured: `16` for a 3016KiB tree). Accepting that number reports a cache as
# bounded while most of it was never seen.
cat >"$T/bin/du-partial" <<'SH'
#!/bin/sh
printf '16\t%s\n' "${@:-$1}"
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
assert_eq "$RC" "5" "dry-run over an over-bound cache exits 5 (checked and OVER — not 0, which a caller reads as cleared)"
assert_contains "$OUT" "are OVER the" "the pass-end line says the cache is over bound and was NOT acted on"
assert_not_contains "$OUT" "every present cache is under" "dry-run never claims a bound it did not enforce"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "dry-run deleted NOTHING"
assert_contains "$OUT" "DRY-RUN" "dry-run says so, naming the cache over its bound"

echo
echo "── 3b. an explicit --dry-run WINS over CACHE_REAP_APPLY=1 ──"
H="$T/h3b"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
OUT="$(run_reap "$H" --dry-run CACHE_REAP_APPLY=1 2>&1)"; RC=$?
assert_eq "$RC" "5" "an armed-by-env pass asked for --dry-run runs DRY and reports the over-bound state (exit 5)"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "CACHE_REAP_APPLY=1 did NOT turn a requested dry run into the destructive pass"
assert_contains "$OUT" "DRY-RUN" "the pass reports the mode it actually ran"

 echo
echo "── 3c. a second concurrent pass does not run (two clocks, one cache) ──"
H="$T/h3c"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
mkdir -p "$H/.pi/agent/state/pi-cache-reap.lock"
printf '%s\n' "$$" >"$H/.pi/agent/state/pi-cache-reap.lock/owner"
printf '%s\n' "$(date +%s)" >"$H/.pi/agent/state/pi-cache-reap.lock/started"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "4" "a pass that finds a LIVE lock exits 4 — NOT 0: a caller that clears its alert on 0 must not clear it on a pass that never ran"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "the locked-out pass mutated nothing — two passes cannot credit each other's reclaim"
assert_contains "$OUT" "another pass is running" "the skip names the holder, not a silent no-op"

 echo
echo "── 3d. a STALE lock is broken (dead owner) and the pass runs ──"
H="$T/h3d"
new_cache "$H/.cache/uv" 3000 2000
mkdir -p "$H/.pi/agent/state/pi-cache-reap.lock"
printf '%s\n' "999999" >"$H/.pi/agent/state/pi-cache-reap.lock/owner"   # a pid that cannot be alive
printf '%s\n' "$(( $(date +%s) - 7200 ))" >"$H/.pi/agent/state/pi-cache-reap.lock/started"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "a stale lock does not wedge the reaper forever (owners reboot, passes die)"
assert_le "$(kb "$H/.cache/uv")" "$BOUND_KB" "the pass that broke the stale lock actually bounded the cache"
[ ! -d "$H/.pi/agent/state/pi-cache-reap.lock" ] && ok "the lock was released on exit" || bad "a lock was left behind"

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
echo "── 4a. a live npm / pip holder is seen too (they are not native binaries) ──"
# The holder class must match the CACHE class under test: npm's cache is $HOME/.npm/_cacache,
# pip's is $HOME/.cache/pip (a uv-class fixture would never consult the npm/pip matcher).
for pair in "ps-npm:.npm/_cacache" "ps-pip:.cache/pip" "ps-pip2:.cache/pip"; do
  stub="${pair%%:*}"; cdir="${pair#*:}"
  H="$T/h4a-$stub"
  new_cache "$H/$cdir" 3000 2000
  UV_BEFORE="$(kb "$H/$cdir")"
  OUT="$(PS_STUB="$T/bin/$stub" run_reap "$H" --apply 2>&1)"; RC=$?
  assert_eq "$RC" "3" "a live holder via $stub blocks the escalation (exit 3)"
  assert_eq "$(kb "$H/$cdir")" "$UV_BEFORE" "nothing was evicted while $stub was resolving against the cache"
done

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

echo "── 4d. an entry name that FORGES a list record cannot delete outside the cache ──"
H="$T/h4d"
new_cache "$H/.cache/uv" 3000 2000
# Measured attack shape: a process able to write into the cache (a build backend, a postinstall
# script) plants a name whose newline starts a SECOND record, which sorts first and points at a
# cwd-relative victim. Without a containment check the reaper deleted that victim and printed
# VERIFIED.
mkdir -p "$H/wd/victimdir"
printf 'keep me\n' >"$H/wd/victimdir/data"
mkdir "$H/.cache/uv/evil"$'\n'"999999"$'\t'"victimdir"
OUT="$(cd "$H/wd" && run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "an unrepresentable entry name fails the pass closed"
[ -f "$H/wd/victimdir/data" ] && ok "a directory OUTSIDE the cache survived the forged record" \
                              || bad "a forged record deleted a path outside the cache"

echo "── 5. an unusable ps probe is never read as 'no holder' ──"
H="$T/h5"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
OUT="$(PS_STUB="$T/bin/ps-empty" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "an empty ps table exits 3 rather than escalating blind"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "nothing was evicted on an unproven cache"
assert_contains "$OUT" "ps probe could not answer" "the refusal names the probe, not a phantom holder"

echo
echo "── 5b. a PARTIAL du (numeric total, non-zero status) is not a measurement ──"
H="$T/h5b"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
OUT="$(DU_STUB=1 run_reap "$H" --apply CACHE_REAP_DU="$T/bin/du-partial" 2>&1)"; RC=$?
assert_eq "$RC" "3" "a du that exits non-zero exits 3 even though it printed a number"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "nothing was evicted on a measurement that only saw part of the cache"
assert_contains "$OUT" "cannot measure" "the refusal names the measurement, not the cache"

 echo
echo "── 5c. an unreadable df REFUSES to escalate (no way to prove the reclaim) ──"
H="$T/h5c"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
OUT="$(DF_STUB="$T/bin/df-silent" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a cache that cannot be measured against free space exits 3"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "NOTHING was deleted: the pass cannot prove what an empty df would hide"
assert_contains "$OUT" "free space could not be read" "the refusal names df, not a phantom success"

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
echo "── 6d. an entry that is STILL HARDLINKED is preserved (unlinking it frees nothing) ──"
H="$T/h6d"
new_cache "$H/.cache/uv" 3000 2000
mkdir -p "$H/.venv/lib"
ln "$H/.cache/uv/entry-1/blob" "$H/.venv/lib/blob"   # a .venv that hardlinks the cache entry
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a cache still over its bound after preserving shared entries exits 3 (it refuses to claim a bound it did not reach)"
[ -d "$H/.cache/uv/entry-1" ] && ok "the HARDLINKED entry was preserved — deleting it would have freed zero bytes for the hourly job to redo forever" \
                                  || bad "the hardlinked entry was deleted: the next hourly pass would delete the next one, for nothing"
[ ! -d "$H/.cache/uv/entry-2" ] && ok "the unshared entry was still evicted (preservation is per-entry, not per-cache)" \
                                 || bad "the unshared entry survived, so the escalation did not run"
assert_contains "$(cat "$H/reap.log" 2>/dev/null)" "still hardlinked" "the log says WHY that entry was kept"

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
assert_eq "$RC" "0" "--help exits 0, like every sibling reaper (a --help && … must not fail)"
assert_contains "$OUT" "--apply" "--help documents the arming flag"
assert_contains "$OUT" "Exit codes" "--help prints the exit codes (the contract a scheduled job is read by)"
assert_contains "$OUT" "fail-closed" "--help names the fail-closed exit"

echo
echo "── 9b. --print-config is the ONE description of the paths and the bound ──"
H="$T/h9b"
mkdir -p "$H"
OUT="$(env HOME="$H" CACHE_REAP_UV_DIR="$H/.cache/uv" CACHE_REAP_MAX_MB=2048 bash "$REAPER" --print-config 2>&1)"; RC=$?
assert_eq "$RC" "0" "--print-config exits 0"
assert_contains "$OUT" "bound_mb=2048" "--print-config reports the bound the reaper will enforce"
assert_contains "$OUT" "cache=uv:$H/.cache/uv" "--print-config reports the uv cache the reaper will bound"
assert_contains "$OUT" "cache=npm:$H/.npm/_cacache" "--print-config reports the npm cache"
assert_contains "$OUT" "cache=pip:$H/.cache/pip" "--print-config reports the pip cache"
assert_contains "$OUT" "bound_source=" "--print-config says WHERE the bound came from (a plist-tuned bound is not this process's env)"
assert_contains "$(cat "$BRINGUP")" "--print-config" "the cell's report reads the bound from the reaper, not from a second literal"

 echo
echo "── 9c. a cache relocated by the tool's own env is still bounded (not 'absent') ──"
H="$T/h9c"
mkdir -p "$H/.cache"
new_cache "$H/xdg/pip" 3000 2000
OUT="$(XDG_CACHE_HOME="$H/xdg" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "a pip cache under XDG_CACHE_HOME is bounded and verified"
assert_le "$(kb "$H/xdg/pip")" "$BOUND_KB" "the relocated pip cache came UNDER the bound (a \$HOME guess reports it 'absent' and exits 0)"
assert_not_contains "$OUT" "pip $H/.cache/pip absent (nothing to bound)" "the pass did not call the real cache 'absent'"

echo
echo "── 9d. a state dir that cannot hold a lock is fail-closed, not a benign skip ──"
H="$T/h9d"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
mkdir -p "$H/.pi/agent"
printf 'not a dir\n' >"$H/.pi/agent/state"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "an unusable state dir exits 3 — NOT 4 (which callers read as 'another pass is running')"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "nothing was deleted without mutual exclusion"
assert_contains "$OUT" "lock" "the refusal names the lock, not a phantom concurrent pass"

echo
echo "── 9e. an ARMED pass refuses to delete with no audit trail ──"
H="$T/h9e"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
mkdir -p "$H/blocker"; printf 'x\n' >"$H/blocker/x.log"
OUT="$(cd "$H" && env HOME="$H" CACHE_REAP_MAX_MB="$BOUND_MB" \
        CACHE_REAP_LOG="$H/blocker/x.log/sub/x.log" \
        CACHE_REAP_PS="$T/bin/ps-idle" CACHE_REAP_DF="$T/bin/df-gain" \
        CACHE_REAP_UV="$T/bin/uv-noprune" CACHE_REAP_NPM="$T/bin/uv-noprune" \
        CACHE_REAP_PIP="$T/bin/uv-noprune" bash "$REAPER" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "an armed pass with an unwritable log exits 3 (the family rule: no audit trail, no deletion)"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "nothing was deleted with no way to record it"
assert_contains "$OUT" "audit trail" "the refusal names the missing audit trail"

echo
echo "── 9f. an entry starting with two dots is ENUMERATED (never silently skipped) ──"
H="$T/h9f"
new_cache "$H/.cache/uv" 900
mkdir -p "$H/.cache/uv/..dots"; dd if=/dev/zero of="$H/.cache/uv/..dots/blob" bs=1024 count=3000 2>/dev/null
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "the pass bounds the cache including a '..'-prefixed entry"
assert_le "$(kb "$H/.cache/uv")" "$BOUND_KB" "the '..'-prefixed entry was evicted too (a plain glob misses it, so the bound could never be met)"

echo
echo "── 9g. an unreadable cache is not an ABSENT one ──"
H="$T/h9g"
new_cache "$H/.cache/pip" 3000
chmod 000 "$H/.cache"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
chmod 755 "$H/.cache"
assert_eq "$RC" "3" "a cache the pass cannot SEE exits 3 (never 'absent, nothing to bound')"
assert_contains "$OUT" "cannot be seen" "the refusal distinguishes unreadable from absent"

echo
echo "── 9h. a symlinked entry with a newline in its name cannot forge the log ──"
H="$T/h9h"
new_cache "$H/.cache/uv" 3000 2000
ln -sfn /etc/hostname "$H/.cache/uv/$(printf 'x\npi-cache-reap: npm VERIFIED evicted=999')"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a name that cannot be represented fails the pass closed, symlink or not"
assert_not_contains "$OUT" "pi-cache-reap: npm VERIFIED evicted=999" "the forged log line never reached the log"

echo
echo "── 10. wiring: a bound no box runs is the defect ──"
assert_contains "$(sed -n 's/^fleet_srcs=(\(.*\))$/\1/p' "$SETUP")" "pi-cache-reap.sh" \
    "pi-bootstrap/setup.sh's farm declares pi-cache-reap.sh (it is the copy the boxes execute)"
[ -f "$TEMPLATE" ] && ok "the launchd template exists" || bad "missing $TEMPLATE"
assert_contains "$(cat "$TEMPLATE" 2>/dev/null)" "{{HOME}}/.pi/agent/scripts/pi-cache-reap.sh" \
    "the plist runs the FARMED script ($HOME/.pi/agent/scripts), not a ~/Documents path"
assert_contains "$(cat "$TEMPLATE" 2>/dev/null)" "<string>--dry-run</string>" \
    "the plist ships DRY-RUN, the stance #1678's owner ruling requires"
assert_not_contains "$(cat "$TEMPLATE" 2>/dev/null)" "<string>--apply</string>" \
    "the tracked template ships UNARMED (a gate does not enforce this — #1678 owns that: the installer should refuse to render an armed plist)"
assert_contains "$(cat "$TEMPLATE" 2>/dev/null)" "#1678" \
    "the plist names the ruling it follows, so the next lane does not 'tidy' it either way"
assert_contains "$(cat "$TEMPLATE" 2>/dev/null)" "<integer>3600</integer>" "the plist is hourly"
assert_contains "$(cat "$ORCH" 2>/dev/null)" "\"\$_cache_reaper\" --dry-run" \
    "the CELL's clock also runs UNARMED (the armed arm is the supervisor's low-disk prune)"
assert_contains "$(cat "$ORCH" 2>/dev/null)" ".cache-reap-blocked" \
    "a fail-closed pass is recorded where the cell's status verb prints it (not only in a log)"
assert_contains "$(cat "$SUPERVISOR" 2>/dev/null)" ".cache-reap-blocked" \
    "the supervisor surfaces that record instead of leaving an hourly failure in a log"
assert_contains "$(cat "$SUPERVISOR" 2>/dev/null)" "pi-cache-reap.sh" \
    "the low-disk prune remedy reaches the machine-global caches too"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
