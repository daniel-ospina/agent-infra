#!/usr/bin/env bash
# tests/admin-merge/rail-exit.test.sh — #3194: THE RAIL MUST ALWAYS TERMINATE.
#
# WHY THIS FILE EXISTS. The rail could be left running forever: measured 2026-11-01, one
# rail ran 6h53m while its PR had MERGED, and `auto-rail.sh` counts processes, so eight of
# them deadlocked every merge. The three fixes (terminal exit, whole-attempt deadline,
# per-PR lease) are each a place where an inverted `case` arm or a typo'd exit code ships
# SILENTLY — `orchestrator-harness/merge-one.sh:694-696` turns rail exit 0 into a written
# `state/merged-<PR>.done`, so a wrong exit code does not fail a test: it marks a PR as
# merged that nothing merged. A previous review measured exactly that class of regression
# (the reclaim race let BOTH rails acquire in 37 of 120 trials), which is why the race is
# pinned here rather than trusted.
#
# The rail's own functions are loaded the same way `tests/admin-merge/run.sh` loads them:
# `sed '$d'` strips the `main "$@"` entrypoint, leaving every definition callable.
set -uo pipefail

RAIL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/admin-merge.sh"
[ -f "$RAIL" ] || { echo "FATAL: rail not found at $RAIL" >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/rail-exit-test.XXXXXX")"
cleanup() { [ -n "${TMPROOT:-}" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

# A harness: the rail's definitions + test-only stubs for the logging helpers, so the
# functions can be called without main().
harness() {
  local out="$1"; shift
  sed '$d' "$RAIL" > "$out"
  cat >> "$out" <<'STUBS'
say_err() { printf 'ERR: %s\n' "$*" >&2; }
info()    { printf 'INF: %s\n' "$*" >&2; }
STUBS
  printf '%s\n' "$@" >> "$out"
}
H="$TMPROOT/harness.sh"

# ── 1. A DUPLICATE MUST EXIT 75, NEVER 0 ──────────────────────────────────────
# exit 0 here is written as a MERGE by merge-one.sh, so a duplicate would mark an
# unmerged PR as merged and the sweep would never retry it.
harness "$H" 'rail_lock_acquire "acme-widget-77"; echo HOLDER' 'sleep 20'
LOCKROOT="$TMPROOT/locks"
ADMIN_MERGE_LOCK_ROOT="$LOCKROOT" bash "$H" > "$TMPROOT/holder.log" 2>&1 &
HOLDER=$!
sleep 2
if [ -f "$LOCKROOT/acme-widget-77/pid" ]; then
  ok "lease is taken and written to disk"
else
  bad "lease was not taken (no pid file)"
fi
harness "$TMPROOT/dup.sh" 'rail_lock_acquire "acme-widget-77"; echo "DUPLICATE-PROCEEDED"'
ADMIN_MERGE_LOCK_ROOT="$LOCKROOT" bash "$TMPROOT/dup.sh" > "$TMPROOT/dup.out" 2>&1
rc=$?
[ "$rc" -eq 75 ] && ok "duplicate EXITS 75 (not 0 = not a merge)" || bad "duplicate exited $rc, expected 75"
grep -q 'ALREADY-RAILING' "$TMPROOT/dup.out" && ok "duplicate names ALREADY-RAILING(<pr>)" \
  || bad "duplicate did not print ALREADY-RAILING"
grep -q 'DUPLICATE-PROCEEDED' "$TMPROOT/dup.out" && bad "duplicate PROCEEDED past the lease" \
  || ok "duplicate did not proceed"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# ── 2. A LEASE WHOSE HOLDER IS DEAD IS RECLAIMED ──────────────────────────────
mkdir -p "$LOCKROOT/acme-widget-78"
printf '999999\n' > "$LOCKROOT/acme-widget-78/pid"
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$LOCKROOT/acme-widget-78/started"
harness "$TMPROOT/stale.sh" 'rail_lock_acquire "acme-widget-78"; echo "RECLAIMED"'
ADMIN_MERGE_LOCK_ROOT="$LOCKROOT" bash "$TMPROOT/stale.sh" > "$TMPROOT/stale.out" 2>&1
grep -q RECLAIMED "$TMPROOT/stale.out" && ok "dead holder's lease is reclaimed" \
  || bad "dead holder's lease was NOT reclaimed"
grep -q 'NO LONGER ALIVE' "$TMPROOT/stale.out" && ok "reclaim says WHY" || bad "reclaim gave no reason"

# ── 3. A LEASE OLDER THAN ITS TTL IS STOLEN EVEN IF THE PID LOOKS ALIVE ───────
# A SIGKILLed rail leaves the lease and runs no trap; `kill -0` cannot tell its pid from
# a later process that reused it. Without this bound a PR is blocked forever.
mkdir -p "$LOCKROOT/acme-widget-79"
printf '%s\n' "$$" > "$LOCKROOT/acme-widget-79/pid"          # deliberately ALIVE
printf '1000\n' > "$LOCKROOT/acme-widget-79/started"          # but ancient
harness "$TMPROOT/ttl.sh" 'rail_lock_acquire "acme-widget-79"; echo "STOLEN"'
ADMIN_MERGE_LOCK_ROOT="$LOCKROOT" ADMIN_MERGE_LOCK_TTL=60 bash "$TMPROOT/ttl.sh" \
  > "$TMPROOT/ttl.out" 2>&1
grep -q STOLEN "$TMPROOT/ttl.out" && ok "an EXPIRED lease is stolen (no permanent block)" \
  || bad "an expired lease was NOT stolen — a PR can be blocked forever"

# ── 4. THE RECLAIM RACE: EXACTLY ONE RAIL MAY WIN ─────────────────────────────
# MEASURED before the atomic steal: both rails acquired in 37 of 120 trials, because a
# naive reclaim `rm -rf`s a path the other rail already owns and then mkdirs over it —
# two rails proceed and double-hold, which is what the lease exists to prevent.
# ⛔ EIGHT CONCURRENT RECLAIMERS, AND EXACTLY ONE WINNER. The first version of this test used
# TWO rails and only failed when BOTH acquired — which (a) missed the defect entirely (it
# reproduces at 6-8 reclaimers: measured 19/120 trials with 2-3 simultaneous acquirers) and
# (b) passed VACUOUSLY when zero rails acquired, because `grep -c` on a missing file is 0 and
# the arm only rejected `n -eq 2`. It now asserts n == 1 exactly, over 8 rails (review cycle 3
# finding 3).
harness "$TMPROOT/race.sh" 'rail_lock_acquire "acme-widget-80" && echo ACQUIRED'
trials=40; wrong=0; zero=0
i=0
while [ "$i" -lt "$trials" ]; do
  i=$((i + 1))
  rm -rf "$LOCKROOT/acme-widget-80"
  mkdir -p "$LOCKROOT/acme-widget-80"
  printf '999999\n' > "$LOCKROOT/acme-widget-80/pid"
  printf '1000\n' > "$LOCKROOT/acme-widget-80/started"
  r=0
  while [ "$r" -lt 8 ]; do
    ADMIN_MERGE_LOCK_ROOT="$LOCKROOT" bash "$TMPROOT/race.sh" >> "$TMPROOT/race-$i.out" 2>/dev/null &
    r=$((r + 1))
  done
  wait
  n=$(grep -c ACQUIRED "$TMPROOT/race-$i.out" 2>/dev/null); n=${n:-0}
  [ "$n" -eq 0 ] && zero=$((zero + 1))
  [ "$n" -gt 1 ] && wrong=$((wrong + 1))
done
[ "$wrong" -eq 0 ] && ok "8 concurrent reclaimers: never more than ONE winner in $trials/$trials trials" \
  || bad "TWO OR MORE rails acquired in $wrong/$trials trials"
[ "$zero" -eq 0 ] && ok "every trial produced a winner (the assertion cannot pass vacuously)" \
  || bad "$zero/$trials trials produced ZERO winners — the race harness is broken, not the fix"

# ── 5. A PR-LESS RUN TAKES NO LEASE ───────────────────────────────────────────
harness "$TMPROOT/nopr.sh" 'rail_lock_acquire "acme-widget-"; echo "HELD=$RAIL_LOCK_HELD"'
ADMIN_MERGE_LOCK_ROOT="$LOCKROOT" bash "$TMPROOT/nopr.sh" > "$TMPROOT/nopr.out" 2>&1
grep -q 'HELD=0' "$TMPROOT/nopr.out" && ok "PR-less invocation takes no lease" \
  || bad "PR-less invocation took a lease (bare --print-bounds would collide)"

# ── 6. AN UNUSABLE LEASE ROOT IS A LOUD REFUSAL, NOT A SILENT NO-EXCLUSION ────
harness "$TMPROOT/noroot.sh" 'rail_lock_acquire "acme-widget-81"; echo "PROCEEDED"'
ADMIN_MERGE_LOCK_ROOT=/dev/null/definitely-not-creatable bash "$TMPROOT/noroot.sh" \
  > "$TMPROOT/noroot.out" 2>&1
rc=$?
[ "$rc" -eq 76 ] && ok "unusable lease root EXITS 76 (fail closed)" || bad "unusable root exited $rc, expected 76"
grep -q PROCEEDED "$TMPROOT/noroot.out" && bad "ran with NO exclusion" || ok "did not run without exclusion"

# ── 7. THE TERMINAL EXIT: ONLY A REAL MERGED EXITS 0 ──────────────────────────
# A multi-line / malformed read must NOT be taken as MERGED — that is a checkmark over
# an unmerged PR, because merge-one.sh writes merged-<PR>.done on exit 0.
printf '#!/bin/bash\nprintf "OPEN\\nMERGED\\t2026-01-01T00:00:00Z\\n"\n' > "$TMPROOT/gh-multiline"
printf '#!/bin/bash\nprintf "CLOSED\\t"\n' > "$TMPROOT/gh-closed"
printf '#!/bin/bash\nprintf "MERGED\\t2026-11-01T14:53:07Z\\n"\n' > "$TMPROOT/gh-merged"
chmod +x "$TMPROOT"/gh-multiline "$TMPROOT"/gh-closed "$TMPROOT"/gh-merged

harness "$TMPROOT/term.sh" 'RAIL_LOCK_PR="10483"' 'rail_stop_if_pr_terminal' 'echo SURVIVED'
for case in multiline closed merged; do
  ADMIN_MERGE_GH="$TMPROOT/gh-$case" bash "$TMPROOT/term.sh" > "$TMPROOT/t-$case.out" 2>&1
  echo "$case:$?" >> "$TMPROOT/t.rc"
done
rc_multiline=$(grep '^multiline:' "$TMPROOT/t.rc" | cut -d: -f2)
rc_closed=$(grep '^closed:' "$TMPROOT/t.rc" | cut -d: -f2)
rc_merged=$(grep '^merged:' "$TMPROOT/t.rc" | cut -d: -f2)
[ "$rc_multiline" -eq 0 ] && grep -q SURVIVED "$TMPROOT/t-multiline.out" \
  && ok "a MULTI-LINE read does NOT exit 0" || bad "a multi-line read was taken as MERGED"
[ "$rc_closed" -eq 3 ] && ok "CLOSED exits 3, never 0 (no checkmark over an unmerged PR)" \
  || bad "CLOSED exited $rc_closed, expected 3"
[ "$rc_merged" -eq 0 ] && ok "a real MERGED exits 0" || bad "a real MERGED exited $rc_merged, expected 0"

# ── 8. THE DEADLINE TRIPS AND NAMES ITSELF ────────────────────────────────────
harness "$TMPROOT/dl.sh" 'RAIL_STARTED_AT=$(( $(date +%s) - 999999 )); RAIL_DEADLINE=10' \
  'rail_guard_poll' 'echo "DEADLINE-NOT-ENFORCED"'
bash "$TMPROOT/dl.sh" > "$TMPROOT/dl.out" 2>&1
rc=$?
[ "$rc" -eq 1 ] && ok "an expired whole-attempt deadline EXITS 1" || bad "deadline exited $rc, expected 1"
grep -q 'REFUSED(rail-deadline' "$TMPROOT/dl.out" && ok "the deadline names itself REFUSED(rail-deadline:…)" \
  || bad "the deadline did not name itself"
grep -q 'DEADLINE-NOT-ENFORCED' "$TMPROOT/dl.out" && bad "the rail kept running past its deadline" \
  || ok "the rail stopped at its deadline"

# ── 9. THE NEW KNOBS REFUSE A TYPO AT STARTUP ─────────────────────────────────
# Measured: `ADMIN_MERGE_RAIL_DEADLINE=7h` made the comparison error out, so the arm read
# FALSE and the rail ran with NO bound — silently. That is the hang restored by a typo.
harness "$TMPROOT/bounds.sh" 'validate_rail_bounds' 'echo BOUNDS-OK'
for badval in "RAIL:7h" "RAIL:0" "TTL:forever" "TERM:60s"; do
  knob="${badval%%:*}"; val="${badval#*:}"
  case "$knob" in
    RAIL) ADMIN_MERGE_RAIL_DEADLINE="$val" bash "$TMPROOT/bounds.sh" > "$TMPROOT/b.out" 2>&1 ;;
    TTL)  ADMIN_MERGE_LOCK_TTL="$val"       bash "$TMPROOT/bounds.sh" > "$TMPROOT/b.out" 2>&1 ;;
    TERM) ADMIN_MERGE_TERMINAL_CHECK_EVERY="$val" bash "$TMPROOT/bounds.sh" > "$TMPROOT/b.out" 2>&1 ;;
  esac
  rc=$?
  if [ "$rc" -eq 2 ] && ! grep -q 'BOUNDS-OK' "$TMPROOT/b.out"; then
    ok "a typo'd ${knob} knob is REFUSED at startup ($val)"
  else
    bad "a typo'd ${knob} knob was accepted ($val, exit $rc) — the bound is silently gone"
  fi
done
bash "$TMPROOT/bounds.sh" > "$TMPROOT/b-ok.out" 2>&1
grep -q BOUNDS-OK "$TMPROOT/b-ok.out" && ok "valid knobs pass validation" || bad "valid knobs were refused"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
