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
#   holder      a live `uv` process → nothing evicted, exit 7 (DEFERRED, not FAILED — agent-infra#2036),
#               the holder is named, and a REAL failure in the same pass still outranks the deferral
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
assert_ne() { if [ "$1" = "$2" ]; then bad "$3 (got: $1, which is exactly what it must not be)"; else ok "$3"; fi }

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
# The shapes that were MISSED until they were reproduced: a bare `pip3` (no absolute path at
# all), `env -u VAR uv`, and `env VAR=1 uvx`.
cat >"$T/bin/ps-pip3" <<'SH'
#!/bin/sh
printf '%s\n' "  5154 pip3 install requests"
SH
cat >"$T/bin/ps-envu" <<'SH'
#!/bin/sh
printf '%s\n' "  5155 /usr/bin/env -u TORTOISE_REPO uv sync"
SH
cat >"$T/bin/ps-envv" <<'SH'
#!/bin/sh
printf '%s\n' "  5156 /usr/bin/env UV_CACHE_DIR=/x uvx ruff check"
SH
cat >"$T/bin/uv-fail" <<'SH'
#!/bin/sh
exit 1
SH
# du that answers N times and then FAILS with a numeric partial: a du that stops answering
# MID-pass must stop the deletion, not leave the loop believing it is still over bound.
cat >"$T/bin/du-flaky" <<SH
#!/bin/sh
# Counts only the calls that measure the CACHE ROOT (the per-entry calls during enumeration are
# unaffected), so the failure lands mid-loop: before -> after prune -> after the 1st eviction.
case "\$*" in
  */uv)
    n=\$(cat "$T/du.calls" 2>/dev/null || echo 0)
    echo \$((n + 1)) >"$T/du.calls"
    if [ "\$n" -ge 2 ]; then printf '16\t%s\n' "\$*"; exit 1; fi
    ;;
esac
exec du "\$@"
SH
# df that answers twice and then says NOTHING: an unreadable df is not "plenty of space".
cat >"$T/bin/df-silent" <<SH
#!/bin/sh
n=\$(cat "$T/df.calls" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$T/df.calls"
if [ "\$n" -ge 2 ]; then exit 0; fi
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 100000 4000 \$(( 10000 + n * 16384 )) 4% /"
SH
# ps stub that answers `-o lstart=` with a FIXED string: the lock's holder-identity check reads
# the process start time, and the other stubs answer every invocation with the same two rows.
cat >"$T/bin/ps-lstart" <<'SH'
#!/bin/sh
case "$*" in
  *lstart*) printf '%s\n' "Sun Jan  1 00:00:00 2023"; exit 0 ;;
esac
printf '%s\n' "    1 /sbin/init" "  222 bash -l"
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
        CACHE_REAP_DU="${DU_STUB:-}" \
        CACHE_REAP_UV_DIR="${UV_DIR:-}" \
        CACHE_REAP_NPM_DIR="${NPM_DIR:-}" \
        CACHE_REAP_PIP_DIR="${PIP_DIR:-}" \
        CACHE_REAP_PIP_DIR_MAC="${PIP_DIR_MAC:-}" \
        CACHE_REAP_UV="${UV_STUB:-$T/bin/uv-noprune}" \
        CACHE_REAP_NPM="${UV_STUB:-$T/bin/uv-noprune}" \
        CACHE_REAP_MOUNTINFO="${MOUNTINFO:-}" \
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
UV_BEFORE="$(kb "$H/.cache/uv")"; NPM_BEFORE="$(kb "$H/.npm")"; PIP_BEFORE="$(kb "$H/.cache/pip")"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "an armed pass over three over-bound caches exits 0 (shrink verified)"
assert_le "$(kb "$H/.cache/uv")" "$BOUND_KB" "uv cache is UNDER the ${BOUND_MB}MB bound after the pass (a reaper that is not invoked leaves it over)"
assert_le "$(kb "$H/.npm")" "$BOUND_KB" "the npm cache ROOT is UNDER the bound after the pass (the bound covers _cacache, _npx and _logs, not only _cacache)"
assert_le "$(kb "$H/.cache/pip")" "$BOUND_KB" "pip cache is UNDER the bound after the pass"
[ "$(kb "$H/.cache/uv")" -lt "$UV_BEFORE" ] && ok "uv cache strictly SHRANK ($(( UV_BEFORE / 1024 ))MB -> $(( $(kb "$H/.cache/uv") / 1024 ))MB)" \
                                           || bad "uv cache did not shrink at all ($UV_BEFORE KB)"
[ "$(kb "$H/.npm")" -lt "$NPM_BEFORE" ] && ok "npm cache strictly SHRANK" || bad "npm cache did not shrink"
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
printf '%s\n' "pi-cache-reap" >"$H/.pi/agent/state/pi-cache-reap.lock/kind"
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
printf '%s\n' "pi-cache-reap" >"$H/.pi/agent/state/pi-cache-reap.lock/kind"
printf '%s\n' "$(( $(date +%s) - 7200 ))" >"$H/.pi/agent/state/pi-cache-reap.lock/started"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "a stale lock does not wedge the reaper forever (owners reboot, passes die)"
assert_le "$(kb "$H/.cache/uv")" "$BOUND_KB" "the pass that broke the stale lock actually bounded the cache"
[ ! -d "$H/.pi/agent/state/pi-cache-reap.lock" ] && ok "the lock was released on exit" || bad "a lock was left behind"

 echo
echo "── 4. a live holder: nothing evicted, and the pass DEFERS (agent-infra#2036) ──"
H="$T/h4"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
OUT="$(PS_STUB="$T/bin/ps-uv" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "7" "a cache over its bound with a live uv exits 7 (DEFERRED — a busy box is not a broken reaper)"
assert_ne "$RC" "3" "…and NOT 3: on a busy cell 3 is the hourly red unit this issue exists to remove"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "NOTHING was evicted while a uv process could be resolving against the cache"
assert_contains "$OUT" "DEFERRED" "the pass names the deferral, not a failure"
assert_contains "$OUT" "deferred: uv active" "the deferral carries the machine-readable reason the entry point lifts into its record"
assert_not_contains "$OUT" "FAILED" "…and it does not say FAILED, which is indistinguishable from breakage"
assert_not_contains "$OUT" "FAIL-CLOSED" "…nor fail-closed: nothing is broken, the box is in use"
assert_contains "$OUT" "live uv process is running" "the refusal names the tool-process rule"
assert_contains "$OUT" "uv sync" "the refusal names the actual holder process"
assert_contains "$OUT" "NOT a failure, exit 7" "the pass-end line states the vocabulary, so a log reader is not left guessing"

echo
echo "── 4a. a live npm / pip holder is seen too (they are not native binaries) ──"
# The holder class must match the CACHE class under test: npm's cache is $HOME/.npm (the ROOT —
# its `_cacache` child is what the matcher used to be written against), pip's is $HOME/.cache/pip
# (a uv-class fixture would never consult the npm/pip matcher).
for pair in "ps-npm:.npm" "ps-pip:.cache/pip" "ps-pip2:.cache/pip" \
            "ps-pip3:.cache/pip" "ps-envu:.cache/uv" "ps-envv:.cache/uv"; do
  stub="${pair%%:*}"; cdir="${pair#*:}"
  H="$T/h4a-$stub"
  new_cache "$H/$cdir" 3000 2000
  UV_BEFORE="$(kb "$H/$cdir")"
  OUT="$(PS_STUB="$T/bin/$stub" run_reap "$H" --apply 2>&1)"; RC=$?
  assert_eq "$RC" "7" "a live holder via $stub blocks the escalation (exit 7, deferred)"
  assert_eq "$(kb "$H/$cdir")" "$UV_BEFORE" "nothing was evicted while $stub was resolving against the cache"
done

echo
echo "── 4a-bis. A REAL FAILURE OUTRANKS A DEFERRAL (never the other way) ──"
# The point of the split is that a deferral must not swallow a failure: json cache over-bound with
# a live uv is 7, but the SAME pass with one unmeasurable cache is 3. Anything else would let a
# broken reaper report a busy box.
H="$T/h4a-bis"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
: >"$H/not-a-dir"
OUT="$(PS_STUB="$T/bin/ps-uv" PIP_DIR="$H/not-a-dir" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a deferral PLUS a real failure exits 3 (the failure wins)"
assert_contains "$OUT" "FAILED" "and the pass says FAILED for the broken cache"
assert_contains "$OUT" "outrank" "it says why the deferral did not decide the code"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "and NOTHING was evicted under the live uv"

echo
echo "── 4a-ter. A DRY RUN over bound with a live uv is 5, not a deferral (nothing was going to be deleted) ──"
H="$T/h4a-ter"
new_cache "$H/.cache/uv" 3000 2000
OUT="$(PS_STUB="$T/bin/ps-uv" run_reap "$H" --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "5" "dry-run over bound exits 5 (unchanged: there is no destructive half to defer)"
assert_not_contains "$OUT" "DEFERRED" "a dry run never defers — it deletes nothing either way"

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
assert_contains "$OUT" "cache=npm:$H/.npm" "--print-config reports the npm cache ROOT (the tool's own answer: _cacache's siblings _npx/_logs are unbounded trees too)"
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
echo "── 9i. a cache dir that is a SYMLINK is measured THROUGH the link ──"
H="$T/h9i"
mkdir -p "$H/.cache" "$H/bigdisk"
new_cache "$H/bigdisk/uv" 3000 2000
ln -sfn "$H/bigdisk/uv" "$H/.cache/uv"
BIG_BEFORE="$(kb "$H/bigdisk/uv")"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "a symlinked (relocated) cache is bounded, not reported as 0KB/under bound"
assert_contains "$OUT" "$H/bigdisk/uv" "the verdict names the RESOLVED tree (the link itself measures 0)"
assert_le "$(kb "$H/bigdisk/uv")" "$BOUND_KB" "the real tree behind the symlink came UNDER the bound"
[ "$(kb "$H/bigdisk/uv")" -lt "$BIG_BEFORE" ] && ok "the tree behind the symlink SHRANK (du/find on a link argument see nothing, so this used to exit 0 over the bound)" \
                                            || bad "the tree behind the symlink did not shrink"

echo
echo "── 9j. a MOUNT inside the cache is never deleted THROUGH (same-device bind mounts too) ──"
H="$T/h9j"
new_cache "$H/.cache/uv" 500
mkdir -p "$H/.cache/uv/precious"; dd if=/dev/zero of="$H/.cache/uv/precious/important.db" bs=1024 count=3000 2>/dev/null
PRECIOUS_BEFORE="$(md5sum "$H/.cache/uv/precious/important.db" | cut -d' ' -f1)"
: >"$T/mountinfo"
printf '1 0 8:1 / %s rw - ext4 /dev/sda1 rw\n' "/" >>"$T/mountinfo"
printf '2 0 8:1 / %s rw - ext4 /dev/sda1 rw\n' "$H/.cache/uv/precious" >>"$T/mountinfo"
OUT="$(MOUNTINFO="$T/mountinfo" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$(md5sum "$H/.cache/uv/precious/important.db" | cut -d' ' -f1)" "$PRECIOUS_BEFORE" \
    "the tree under a mount point inside the cache is UNTOUCHED (st_dev cannot see a same-device bind mount, so -xdev walks through it)"
assert_contains "$(cat "$H/reap.log" 2>/dev/null)" "THROUGH a mount" "the log says WHY the entry was kept"
assert_contains "$OUT" "preserved" "the verdict reports the preservation rather than claiming a full bound"

echo
echo "── 9k. a target that cannot be a cache is refused (a mis-set seam is not a delete order) ──"
H="$T/h9k"
mkdir -p "$H/precious"; dd if=/dev/zero of="$H/precious/db" bs=1024 count=3000 2>/dev/null
BEFORE="$(md5sum "$H/precious/db" | cut -d' ' -f1)"
OUT="$(env HOME="$H" CACHE_REAP_MAX_MB=2 CACHE_REAP_UV_DIR="$H/precious" CACHE_REAP_NPM_DIR="$H/none" \
        CACHE_REAP_PIP_DIR="$H/none2" CACHE_REAP_PIP_DIR_MAC="$H/none3" CACHE_REAP_LOG="$H/log" \
        CACHE_REAP_PS="$T/bin/ps-idle" CACHE_REAP_DF="$T/bin/df-gain" CACHE_REAP_UV="$T/bin/uv-noprune" \
        CACHE_REAP_NPM="$T/bin/uv-noprune" CACHE_REAP_PIP="$T/bin/uv-noprune" \
        bash "$REAPER" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a non-cache-shaped target exits 3 instead of pruning it"
assert_eq "$(md5sum "$H/precious/db" | cut -d' ' -f1)" "$BEFORE" "nothing inside the mis-set target was deleted"
OUT="$(env HOME="$H" CACHE_REAP_MAX_MB=2 CACHE_REAP_UV_DIR="$H" CACHE_REAP_NPM_DIR="$H/none" \
        CACHE_REAP_PIP_DIR="$H/none2" CACHE_REAP_PIP_DIR_MAC="$H/none3" CACHE_REAP_LOG="$H/log" \
        CACHE_REAP_PS="$T/bin/ps-idle" CACHE_REAP_DF="$T/bin/df-gain" CACHE_REAP_UV="$T/bin/uv-noprune" \
        CACHE_REAP_NPM="$T/bin/uv-noprune" CACHE_REAP_PIP="$T/bin/uv-noprune" \
        bash "$REAPER" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a target that IS \$HOME is refused even when its basename looks cache-shaped"
[ -f "$H/precious/db" ] && ok "\$HOME survived the refused pass" || bad "\$HOME was pruned"

echo
echo "── 9l. a lock whose pid was RECYCLED does not pin the reaper for ever ──"
H="$T/h9l"
new_cache "$H/.cache/uv" 3000 2000
LOCK_DIR="$H/.pi/agent/state/pi-cache-reap.lock"
mkdir -p "$LOCK_DIR"
# The owner pid must be one this user can signal: the test shell's own (it is alive throughout).
printf '%s\n' "pi-cache-reap" >"$LOCK_DIR/kind"
printf '%s\n' "$$" >"$LOCK_DIR/owner"; printf '%s\n' "$(( $(date +%s) - 99999 ))" >"$LOCK_DIR/started"
printf 'Thu Jan  1 00:00:00 1970\n' >"$LOCK_DIR/lstart"   # not this process's start time
OUT="$(PS_STUB="$T/bin/ps-lstart" run_reap "$H" --apply 2>&1)"; RC=$?
assert_ne "$RC" "4" "a recycled owner pid is treated as stale, not as a running pass (exit 4 pins the reaper for ever)"
assert_contains "$(cat "$H/reap.log" 2>/dev/null)" "RECYCLED" "the pass says why it broke a lock whose owner is alive"
mkdir -p "$LOCK_DIR"   # the pass above released its own lock
printf '%s\n' "pi-cache-reap" >"$LOCK_DIR/kind"
printf '%s\n' "$$" >"$LOCK_DIR/owner"; printf '%s\n' "$(( $(date +%s) - 5 ))" >"$LOCK_DIR/started"
printf '%s\n' "Sun Jan  1 00:00:00 2023" >"$LOCK_DIR/lstart"
OUT="$(PS_STUB="$T/bin/ps-lstart" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "4" "a lock whose owner pid AND start time match is honoured (exit 4, the pass does not run)"

echo
echo "── 9m. a stale BREAK TOKEN is cleared (it used to wedge the lock for ever) ──"
H="$T/h9m"
new_cache "$H/.cache/uv" 3000 2000
LOCK_DIR="$H/.pi/agent/state/pi-cache-reap.lock"
mkdir -p "$LOCK_DIR" "$LOCK_DIR.break"
printf '999999\n' >"$LOCK_DIR/owner"; printf '1\n' >"$LOCK_DIR/started"
printf 'pi-cache-reap\n' >"$LOCK_DIR/kind"
touch -t 200001010000 "$LOCK_DIR.break"
OUT="$(PS_STUB="$T/bin/ps-lstart" run_reap "$H" --apply 2>&1)"; RC=$?
assert_ne "$RC" "4" "a breaker that died does not pin the lock for ever"
assert_contains "$(cat "$H/reap.log" 2>/dev/null)" "stale break token" "the pass says it cleared the abandoned token"

echo
echo "── 9n. npx's package trees are inside the bound, not beside it ──"
H="$T/h9n"
new_cache "$H/.npm/_cacache" 10
mkdir -p "$H/.npm/_npx/hash/node_modules"; dd if=/dev/zero of="$H/.npm/_npx/hash/node_modules/blob" bs=1024 count=3000 2>/dev/null
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "the npm ROOT is bounded"
assert_le "$(kb "$H/.npm")" "$BOUND_KB" "~/.npm/_npx came under the bound (bounding only _cacache reported 'absent' and left it)"

echo
echo "── 10b. the armed remedy READS the reaper's exit status (executed, not grepped) ──"
# The supervisor's low-disk prune is the only ARMED caller, and the reaper has five exit codes.
# Grepping the supervisor's source proves nothing about the mapping, so this executes the SHIPPED
# bytes of cache_reaper_path()/reap_global_caches() with a stub reaper and watches what reaches
# the operator.
H="$T/h10b"; mkdir -p "$H"
awk '/^cache_reaper_path\(\)/,/^}/' "$SUPERVISOR" >"$H/fn.sh"
awk '/^reap_global_caches\(\)/,/^}/' "$SUPERVISOR" >>"$H/fn.sh"
grep -q 'reap_global_caches()' "$H/fn.sh" || bad "could not extract reap_global_caches() from the supervisor (the test needs the SHIPPED bytes)"
for want in 0 4 5 7 3; do
    printf '#!/bin/sh\nexit %s\n' "$want" >"$H/pi-cache-reap.sh"
    chmod +x "$H/pi-cache-reap.sh"
    out="$(env HOME="$H" bash -c 'say() { printf "%s\n" "$*"; }; . "$1"; reap_global_caches' _ "$H/fn.sh" 2>&1)"
    case "$want" in
        0|4|5|7) assert_not_contains "$out" "warn:" "exit $want is NOT a failure: no warning is raised (4 = did not run, 5 = over bound and not acted on, 7 = DEFERRED on a busy box — #2036)" ;;
        3)     assert_contains "$out" "warn: the cache reaper exited 3" "a fail-closed pass (exit 3) DOES warn, naming the status and the log" ;;
    esac
done

echo
echo "── 9o. a directory that is NOT this reaper's lock is never broken ──"
H="$T/h9o"
new_cache "$H/.cache/uv" 3000 2000
mkdir -p "$H/precious/state" "$H/precious/skills"
printf 'the fleet state dir\n' >"$H/precious/state/notes.md"
touch -t 200001010000 "$H/precious"
OUT="$(env HOME="$H" CACHE_REAP_MAX_MB="$BOUND_MB" CACHE_REAP_LOCK="$H/precious" \
        CACHE_REAP_LOG="$H/reap.log" CACHE_REAP_PS="$T/bin/ps-idle" CACHE_REAP_DF="$T/bin/df-gain" \
        CACHE_REAP_UV="$T/bin/uv-noprune" CACHE_REAP_NPM="$T/bin/uv-noprune" CACHE_REAP_PIP="$T/bin/uv-noprune" \
        bash "$REAPER" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a pre-existing directory at \$CACHE_REAP_LOCK that is not a lock exits 3 (not 0)"
[ -f "$H/precious/state/notes.md" ] && ok "the directory SURVIVED (breaking a 'stale lock' is rm -rf, so it must be provably ours)" \
                                     || bad "an arbitrary directory was removed by the stale-lock path"
assert_contains "$OUT" "not a lock this reaper made" "the refusal says why it will not remove it"
# …and a directory carrying an impostor credential (a file NAMED owner, contents unchecked before)
mkdir -p "$H/impostor"
printf 'not-a-pid\n' >"$H/impostor/owner"
touch -t 200001010000 "$H/impostor"
OUT="$(env HOME="$H" CACHE_REAP_MAX_MB="$BOUND_MB" CACHE_REAP_LOCK="$H/impostor" \
        CACHE_REAP_LOG="$H/reap.log" CACHE_REAP_PS="$T/bin/ps-idle" CACHE_REAP_DF="$T/bin/df-gain" \
        CACHE_REAP_UV="$T/bin/uv-noprune" CACHE_REAP_NPM="$T/bin/uv-noprune" CACHE_REAP_PIP="$T/bin/uv-noprune" \
        bash "$REAPER" --dry-run 2>&1)"; RC=$?
assert_eq "$RC" "3" "a directory holding a file NAMED owner (contents not a pid) is refused too"
[ -d "$H/impostor" ] && ok "the impostor directory survived" || bad "a file named 'owner' was enough to authorise an rm -rf"

echo
echo "── 9p. a RELOCATED cache keeps its bound even if the target dir is not cache-named ──"
H="$T/h9p"
mkdir -p "$H/.cache" "$H/bigdisk"; new_cache "$H/bigdisk/uv-cache" 3000 2000
ln -sfn "$H/bigdisk/uv-cache" "$H/.cache/uv"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "a relocated, cache-NAMED cache is bounded"
assert_le "$(kb "$H/bigdisk/uv-cache")" "$BOUND_KB" "the tree behind the symlink came under the bound"
# … and a relocation onto a NON-cache-named directory is refused, not wiped:
H="$T/h9p2"
mkdir -p "$H/.cache" "$H/Documents"; dd if=/dev/zero of="$H/Documents/thesis.dat" bs=1024 count=3000 2>/dev/null
ln -sfn "$H/Documents" "$H/.cache/uv"
OUT="$(run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a cache symlinked onto a data directory exits 3 (the declared name is always cache-shaped, so the RESOLVED one is what must be tested)"
[ -f "$H/Documents/thesis.dat" ] && ok "the data directory SURVIVED" || bad "a symlink at ~/.cache/uv wiped a data directory"

echo
echo "── 9t. a symlinked \$HOME cannot defeat the \$HOME refusal ──"
H="$T/h9t"
# The resolved target must be HOME *and* cache-shaped (`uv-real`), or the shape guard refuses first
# and this test would pass with the canonical-$HOME comparison removed (measured — it did).
mkdir -p "$H/uv-real/Documents" "$H/uv-real/.cache"
dd if=/dev/zero of="$H/uv-real/Documents/data.bin" bs=1024 count=3000 2>/dev/null
ln -sfn "$H/uv-real" "$H/linkhome"
OUT="$(env HOME="$H/linkhome" CACHE_REAP_MAX_MB=2 CACHE_REAP_UV_DIR="$H/linkhome" CACHE_REAP_LOG="$H/reap.log" \
        CACHE_REAP_PS="$T/bin/ps-idle" CACHE_REAP_DF="$T/bin/df-gain" CACHE_REAP_UV="$T/bin/uv-noprune" \
        CACHE_REAP_NPM="$T/bin/uv-noprune" CACHE_REAP_PIP="$T/bin/uv-noprune" bash "$REAPER" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a target that IS \$HOME through a symlink is refused (the comparison is canonical on both sides)"
assert_contains "$OUT" "or an ancestor of it" "the refusal is the \$HOME one — not the shape guard catching it by accident"
[ -f "$H/uv-real/Documents/data.bin" ] && ok "the home directory SURVIVED" || bad "a symlinked \$HOME defeated the home refusal"

echo
echo "── 9u. uvx is a uv holder (same cache) ──"
H="$T/h9u"
new_cache "$H/.cache/uv" 3000 2000
UV_BEFORE="$(kb "$H/.cache/uv")"
cat >"$T/bin/ps-uvx" <<SH
#!/bin/sh
printf '%s\n' "  4242 /usr/local/bin/uvx ruff check"
SH
chmod +x "$T/bin/ps-uvx"
OUT="$(PS_STUB="$T/bin/ps-uvx" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "7" "a live uvx blocks the whole-cache escalation (uvx resolves through the same uv cache) and DEFERS it"
assert_eq "$(kb "$H/.cache/uv")" "$UV_BEFORE" "nothing was evicted while uvx could be resolving against the cache"

echo
echo "── 9q. a du that stops answering MID-pass stops the deletion ──"
H="$T/h9q"
new_cache "$H/.cache/uv" 1000 1000 1000 1000 1000 1000 1000 1000 1000 1000
rm -f "$T/du.calls"
OUT="$(DU_STUB="$T/bin/du-flaky" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "an unmeasurable cache mid-pass fails closed"
assert_contains "$OUT" "STOPPING" "the pass says it STOPPED rather than continuing blind"
LEFT="$(find "$H/.cache/uv" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
[ "$LEFT" -ge 2 ] && ok "the deletion STOPPED early ($LEFT of 10 entries left) — it did not empty a cache it could not measure" \
                  || bad "the pass kept deleting after du stopped answering ($LEFT of 10 entries left)"

echo
echo "── 9r. a df that goes silent MID-pass stops the deletion (the brake cannot go blind) ──"
H="$T/h9r"
new_cache "$H/.cache/uv" 1000 1000 1000 1000 1000 1000 1000 1000 1000 1000
rm -f "$T/df.calls"
OUT="$(DF_STUB="$T/bin/df-silent" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "an unreadable df mid-pass fails closed"
assert_contains "$OUT" "df stopped answering" "the refusal names the df, not a phantom reclaim"
LEFT="$(find "$H/.cache/uv" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
[ "$LEFT" -gt 2 ] && ok "the deletion STOPPED early ($LEFT of 10 entries left) — an unreadable df is not 'plenty of space'" \
                  || bad "the pass emptied the cache while the free-space brake was blind ($LEFT left)"

echo
echo "── 9s. a BACKSLASH in the cache path does not break the live-holder guard ──"
H="$T/h9s"
D="$H/pa\th/uv"
new_cache "$D" 3000 1500
cat >"$T/bin/ps-backslash" <<SH
#!/bin/sh
printf '%s\n' "  999 cat $D/entry-1/blob"
SH
chmod +x "$T/bin/ps-backslash"
OUT="$(PS_STUB="$T/bin/ps-backslash" CACHE_REAP_UV_DIR="$D" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "the pass still bounds the cache around the held entry"
[ -f "$D/entry-1/blob" ] && ok "the entry a live process names SURVIVED (awk -v unescapes the path; ENVIRON does not)" \
                         || bad "a held entry was deleted because the path was mangled by awk -v"

echo
echo "── 9v. a FALLING df is another writer, not a failed reclaim ──"
H="$T/h9v"
new_cache "$H/.cache/uv" 2000 1200
# rise-then-fall: the FIRST post-eviction sample rises (this pass reclaimed), then a concurrent
# writer eats the gain — exactly the busy-box shape. A monotonically falling df is the different
# case (no observed gain => the reclaim is unverified), covered by 9v2.
cat >"$T/bin/df-shrink" <<SH
#!/bin/sh
n=\$(cat "$T/df.calls" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$T/df.calls"
case "\$n" in
  0) echo 48000 ;;
  1) echo 60000 ;;
  *) echo 10000 ;;
esac | { read v; echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/fake 100000 4000 \$v 4% /"; }
SH
chmod +x "$T/bin/df-shrink"
rm -f "$T/df.calls"
OUT="$(DF_STUB="$T/bin/df-shrink" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "a cache brought UNDER its bound exits 0 even when free space FELL (the delta is unattributable, not a failure)"
assert_le "$(kb "$H/.cache/uv")" "$BOUND_KB" "the bound was still enforced"
assert_contains "$OUT" "UNATTRIBUTABLE" "the verdict says the disk-gain claim cannot be attributed, instead of blaming hardlinks"
assert_not_contains "$OUT" "hardlinked into a .venv" "it does NOT blame hardlinked venvs for a delta it never saw"
assert_contains "$OUT" "WAS followed by a gain" "the verdict gives the evidence it DOES have instead of the raw df delta"

echo
echo "── 9v2. a delta that ONLY falls, with no observed gain, is NOT a verified reclaim ──"
# The counter-example that makes 9v safe to pass: unlinked bytes still pinned by an open descriptor
# free nothing. Here no eviction is followed by a gain, so the pass must NOT exit 0 on a falling
# delta — a pass that frees nothing must never clear the alarm the cell reads.
H="$T/h9v2"
new_cache "$H/.cache/uv" 2000 1200
cat >"$T/bin/df-always-falls" <<SH
#!/bin/sh
n=\$(cat "$T/df.calls" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$T/df.calls"
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 100000 4000 \$(( 48000 - n * 1024 )) 4% /"
SH
chmod +x "$T/bin/df-always-falls"
rm -f "$T/df.calls"
OUT="$(DF_STUB="$T/bin/df-always-falls" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a falling delta with NO observed gain fails closed (the reclaim is unverified)"
assert_contains "$OUT" "NOT ONE eviction of this pass was followed by a gain" "the refusal says what evidence was missing"

echo
echo "── 9w. a RELATIVE path in someone else's argv is not a holder (absolute-token rule) ──"
H="$T/h9w"
new_cache "$H/.cache/uv" 3000 2000
cat >"$T/bin/ps-grep" <<'SH'
#!/bin/sh
printf '%s\n' "  7777 grep -rn bin/uv /home/x/docs"
SH
chmod +x "$T/bin/ps-grep"
OUT="$(PS_STUB="$T/bin/ps-grep" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "a grep whose argv holds a RELATIVE 'bin/uv' is not a live uv (it used to refuse the escalation)"
assert_le "$(kb "$H/.cache/uv")" "$BOUND_KB" "the cache still came under its bound"

echo
echo "── 9x. the ACT-POINT re-probe: a holder that appears MID-pass stops it ──"
H="$T/h9x"
new_cache "$H/.cache/uv" 900 900 900 900
cat >"$T/bin/ps-actpoint" <<SH
#!/bin/sh
n=\$(cat "$T/ps.calls" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$T/ps.calls"
# ONE ps snapshot runs at pass start; the first ps call of a run is the lock-acquire `lstart`
# probe (this stub ignores its arguments, so it counts too). The ACT-POINT re-probe is the third
# call, so the holder appears from n=2 on. Counted here, not branched on the arguments, so the
# trigger stays visible in one line.
if [ "\$n" -ge 2 ]; then printf '%s\n' "  7777 /usr/local/bin/uv sync"; else printf '%s\n' "    1 /sbin/init"; fi
SH
chmod +x "$T/bin/ps-actpoint"
rm -f "$T/ps.calls"
OUT="$(PS_STUB="$T/bin/ps-actpoint" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "3" "a uv that appears after the pass-start snapshot stops the pass"
assert_contains "$OUT" "started during this pass" "the refusal says the holder appeared mid-pass"
assert_eq "$(find "$H/.cache/uv" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "4" "NOTHING was evicted (the pass-stop happens before the first removal)"

echo
echo "── 9y. lock_release removes only a lock that is PROVABLY ours ──"
H="$T/h9y"
new_cache "$H/.cache/uv" 3000 2000
LOCK_DIR="$H/.pi/agent/state/pi-cache-reap.lock"
cat >"$T/bin/ps-swaplock" <<SH
#!/bin/sh
n=\$(cat "$T/ps.calls" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$T/ps.calls"
if [ "\$n" -ge 1 ]; then printf '999999\n' >"$LOCK_DIR/owner"; fi
printf '%s\n' "    1 /sbin/init"
SH
chmod +x "$T/bin/ps-swaplock"
rm -f "$T/ps.calls"
OUT="$(PS_STUB="$T/bin/ps-swaplock" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "the pass completes"
assert_eq "$(cat "$LOCK_DIR/owner" 2>/dev/null)" "999999" "the lock another pass took is NOT deleted by this pass's EXIT trap"

echo
echo "── 9z. the log is rotated at CACHE_REAP_LOG_MAX_BYTES (it is a disk sink too) ──"
H="$T/h9z"
new_cache "$H/.cache/uv" 100
printf '%0400d\n' 0 >"$H/reap.log"
OUT="$(env HOME="$H" CACHE_REAP_MAX_MB="$BOUND_MB" CACHE_REAP_LOG="$H/reap.log" CACHE_REAP_LOG_MAX_BYTES=100 \
        CACHE_REAP_PS="$T/bin/ps-idle" CACHE_REAP_DF="$T/bin/df-gain" \
        CACHE_REAP_UV="$T/bin/uv-noprune" CACHE_REAP_NPM="$T/bin/uv-noprune" CACHE_REAP_PIP="$T/bin/uv-noprune" \
        bash "$REAPER" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "an under-bound pass completes"
[ -f "$H/reap.log.1" ] && ok "the oversized log was rotated to .1" || bad "the log was not rotated (it grows without bound)"

echo
echo "── 9aa. a df gain LARGER than the claim is not credited as this pass's reclaim ──"
H="$T/h9aa"
new_cache "$H/.cache/uv" 1200 1200
cat >"$T/bin/df-flood" <<SH
#!/bin/sh
n=\$(cat "$T/df.calls" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$T/df.calls"
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
if [ "\$n" -eq 0 ]; then echo "/dev/fake 4000000 4000 10000 4% /"; else echo "/dev/fake 4000000 4000 2000000 4% /"; fi
SH
chmod +x "$T/bin/df-flood"
rm -f "$T/df.calls"
OUT="$(DF_STUB="$T/bin/df-flood" run_reap "$H" --apply 2>&1)"; RC=$?
assert_eq "$RC" "0" "the pass verifies (the cache did shrink)"
assert_contains "$OUT" "NOT attributable to this pass" "a df gain beyond what the cache gave up is named as foreign, not folded into the reclaim"
# …and the CREDITED figure must be capped at the claim: the uncapped code prints the whole
# foreign gain as this pass's reclaim (measured: "verified reclaim" of 1943MB for a 1.2MB cache).
CREDITED="$(printf '%s' "$OUT" | sed -n 's/.*(+\([0-9][0-9]*\)KB verified reclaim.*/\1/p' | head -1)"
if [ -n "$CREDITED" ] && [ "$CREDITED" -le 2000 ]; then
    ok "the credited figure is ${CREDITED}KB — what the cache gave up, not the 1942MB foreign df delta"
else
    bad "the credited figure is not the cache's own reclaim (credit cap removed?): $OUT"
fi

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

echo
echo "── 10c. portability pins (the launchd clock is macOS) ──"
# `date -r <path>` is GNU-only: the BSD/macOS `date -r` takes EPOCH SECONDS, so it returns empty
# there — every age fell back to 0, a stale lock was never broken (exit 4 = silence to both
# callers) and the loud mis-set-lock refusal degraded to a silent skip. The family idiom is
# `stat -f %m || stat -c %Y`.
assert_not_contains "$(grep -v '^#' "$REAPER")" 'date -r' "no GNU-only 'date -r <path>' in EXECUTED code (it means epoch seconds on macOS)"
assert_contains "$(cat "$REAPER")" 'stat -f %m' "mtime is read with the family's portable stat idiom"

echo ""
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
