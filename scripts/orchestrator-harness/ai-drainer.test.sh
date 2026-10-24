#!/usr/bin/env bash
# ai-drainer.test.sh — the guard regressions for scripts/orchestrator-harness/ai-drainer.sh.
#
# WHAT THIS SUITE IS FOR. The drainer is a SCHEDULED DISPATCHER, and every one of its guards fails in
# the expensive direction if it breaks:
#   * no lock              → two lanes drain the same PR slice, and every tick exits 0 (lane storm);
#   * lock released early  → the same storm, one interval later, because the dispatcher is async;
#   * no capacity floor    → a lane starts on a box already below the harness's swap floor;
#   * a stuck slice cursor → every pass works the same six PRs and the backlog never rotates.
# Each arm below drives the REAL script (no reimplementation), with a fake dispatcher and a fake
# capacity read, so the arm tests the shipped code path rather than a copy of it.
#
# ⛔ ARM (a) IS ASSERTED AGAINST A MUTATION (non-vacuity). A concurrency test passes trivially if the
# second invocation never gets far enough to matter — e.g. because the harness is misconfigured, the
# fake dispatcher fails, or the first run never took the lock at all. So the suite ALSO runs the same
# arm against a copy of the script with the lock block deleted (the `──8<── lock-guard` markers delimit
# it) and REQUIRES that arm to fail there. A guard test that cannot detect the guard's absence proves
# nothing; this one is measured both ways.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAINER="${DRAINER:-$HERE/ai-drainer.sh}"
LAUNCHER="$HERE/multi-repo-controller.sh"
[ -f "$DRAINER" ] || { echo "ai-drainer.test: no drainer at $DRAINER" >&2; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1${3:+ — $3}"; fi; }

ROOT="$(mktemp -d)" || exit 1
cleanup() {
  # Bounded: kill only pids THIS test recorded, never a pattern-matched population.
  [ -f "$ROOT/pids" ] && while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done <"$ROOT/pids"
  rm -rf "$ROOT"
}
trap cleanup EXIT

# ── a fixture seed repo: the drainer branches its lane's worktree from SEED_REF ────────────────
SEED="$ROOT/seed"
mkdir -p "$SEED"
git -C "$SEED" init -q >/dev/null 2>&1
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed >/dev/null 2>&1
SEED_REF="$(git -C "$SEED" rev-parse HEAD)"

# ── the fake dispatcher ───────────────────────────────────────────────────────────────────────
# Writes $O/bg/<name>.pid exactly as the real one does, naming a process that lives FAKE_LANE_SECS.
# That is the one behaviour the lock's lifetime depends on (async return + a live lane pid), so this is
# the seam that makes the guard testable rather than aspirational.
DISPATCH="$ROOT/dispatch.sh"
cat >"$DISPATCH" <<'DISPATCH_EOF'
#!/usr/bin/env bash
set -u
NAME="$1"; WT="$2"; BRIEF="$3"
O="${O:?}"; D="$O/bg"; mkdir -p "$D"
printf '%s\n' "$(cd "$WT" && pwd)" > "$D/$NAME.wt"
SECS="${FAKE_LANE_SECS:-0}"
if [ "$SECS" -gt 0 ]; then
  sleep "$SECS" &
  echo "$!" > "$D/$NAME.pid"
else
  # A pid that is already gone, so the drainer's wait loop ends on its first probe.
  sleep 0 >/dev/null 2>&1 &
  echo "$!" > "$D/$NAME.pid"
fi
exit 0
DISPATCH_EOF
chmod +x "$DISPATCH"

# One drainer invocation, hermetically scoped. Every path is inside $ROOT, so nothing here can touch
# the live fleet's state dirs even when this runs on the operator's box.
run_drainer() { # <name> [extra env as KEY=VALUE…]
  local tag="$1"; shift
  local o="$ROOT/o-$tag" ai="$ROOT/ai-$tag"
  mkdir -p "$o/bg" "$ai"
  env -u SWAP_FREE_MB \
    O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
    SWAP_FREE_MB="${RUN_SWAP:-9999}" MAX_LANES="${RUN_MAX_LANES:-4}" \
    LANE_TIMEOUT="${RUN_LANE_TIMEOUT:-60}" LANE_WAIT_MAX="${RUN_WAIT_MAX:-30}" LANE_POLL_S=1 \
    SLICE_WIDTH="${RUN_SLICE_WIDTH:-10}" SLICE_TOTAL="${RUN_SLICE_TOTAL:-70}" \
    FAKE_LANE_SECS="${FAKE_LANE_SECS:-0}" "$@" \
    bash "$DRAINER" >/dev/null 2>&1 &
  echo "$!" >>"$ROOT/pids"
  LAST_O="$o"; LAST_AI="$ai"
}
run_drainer_foreground() { # <tag> — same env, blocking (used where the point is the exit code)
  local tag="$1"
  local o="$ROOT/o-$tag" ai="$ROOT/ai-$tag"
  mkdir -p "$o/bg" "$ai"
  O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" \
    SWAP_FREE_MB="${RUN_SWAP:-9999}" MAX_LANES="${RUN_MAX_LANES:-4}" \
    LANE_TIMEOUT="${RUN_LANE_TIMEOUT:-60}" LANE_WAIT_MAX="${RUN_WAIT_MAX:-30}" LANE_POLL_S=1 \
    SLICE_WIDTH="${RUN_SLICE_WIDTH:-10}" SLICE_TOTAL="${RUN_SLICE_TOTAL:-70}" \
    FAKE_LANE_SECS="${FAKE_LANE_SECS:-0}" \
    bash "$DRAINER" >/dev/null 2>&1
}

wait_for_file() { # <path> <seconds>
  local i=0
  while [ "$i" -lt "$2" ]; do [ -e "$1" ] && return 0; sleep 0.2; i=$((i + 1)); done
  return 1
}

echo "== ai-drainer guards =="

# ── ARM (a): TWO CONCURRENT INVOCATIONS → ONE RUN ─────────────────────────────────────────────
FAKE_LANE_SECS=8
run_drainer a1
wait_for_file "$ROOT/ai-a1/state/ai-drainer.lock" 50 \
  || bad "(a) the first invocation never took the lock — nothing to test"
# Blocking second invocation, same state dir: it must SKIP, not start.
o="$ROOT/o-a1"; ai="$ROOT/ai-a1"
O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" SWAP_FREE_MB=9999 \
  LANE_POLL_S=1 bash "$DRAINER" >/dev/null 2>&1
starts="$(grep -c '^.*START:' "$ai/logs/ai-drainer.log" 2>/dev/null || true)"
skips="$(grep -c 'SKIP: drainer already running' "$ai/logs/ai-drainer.log" 2>/dev/null || true)"
check "(a) the second invocation SKIPPED on the lock" '[ "${skips:-0}" -ge 1 ]' "log: $(tail -3 "$ai/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"
check "(a) exactly ONE lane was dispatched" '[ "${starts:-0}" -eq 1 ]' "starts=$starts"

# ── ARM (b): THE LOCK IS RELEASED ONLY WHEN THE LANE PID DIES (the 2-tick overlap) ───────────
lane_pid="$(tr -dc '0-9' 2>/dev/null <"$o/bg/"*.pid 2>/dev/null | head -c 12)"
check "(b) the lock still EXISTS while the lane lives" '[ -d "$ai/state/ai-drainer.lock" ] && kill -0 "$(cat "$ai/state/ai-drainer.lock/pid" 2>/dev/null)" 2>/dev/null' \
  "lock pid=$(cat "$ai/state/ai-drainer.lock/pid" 2>/dev/null)"
beat_age=$(( $(date +%s) - $(cat "$ai/state/ai-drainer.beat" 2>/dev/null || echo 0) ))
check "(b) a held lock writes a FRESH beat while waiting" '[ "$beat_age" -le 5 ]' "beat age ${beat_age}s"
# Kill the LANE (not the drainer) — the drainer must notice and release on its own.
[ -n "$lane_pid" ] && kill "$lane_pid" 2>/dev/null
i=0; while [ -d "$ai/state/ai-drainer.lock" ] && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
check "(b) the lock is RELEASED once the lane pid dies" '[ ! -d "$ai/state/ai-drainer.lock" ]' \
  "still held after $((i / 4))s"
check "(b) the release was recorded as DONE, not as a timeout" \
  'grep -q "DONE: lane .* finished" "$ai/logs/ai-drainer.log"' "$(tail -2 "$ai/logs/ai-drainer.log" | tr '\n' ' ')"

# ── ARM (c): SKIP BELOW THE CAPACITY FLOOR ───────────────────────────────────────────────────
RUN_SWAP=100
run_drainer_foreground c1; rc=$?
check "(c) a pass below the swap floor SKIPS with exit 0" '[ "$rc" -eq 0 ]' "rc=$rc"
check "(c) the skip names the floor" \
  'grep -q "SKIP: swap 100MB < 700MB floor" "$ROOT/ai-c1/logs/ai-drainer.log"' \  "$(cat "$ROOT/ai-c1/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"
check "(c) nothing was dispatched below the floor" \
  '[ "$(grep -c "START:" "$ROOT/ai-c1/logs/ai-drainer.log" 2>/dev/null || true)" -eq 0 ]'

# A lane cap is the second half of the same guard: a pidfile naming a live `pi` must count.
RUN_SWAP=9999
RUN_MAX_LANES=0
run_drainer_foreground c2
check "(c) at the lane cap (MAX_LANES=0) the pass SKIPS" \
  'grep -q "SKIP: 0 lanes already running (cap 0)" "$ROOT/ai-c2/logs/ai-drainer.log"'
RUN_MAX_LANES=4

# ── ARM (d): THE SLICE CURSOR ADVANCES AND WRAPS ─────────────────────────────────────────────
RUN_SLICE_WIDTH=10 RUN_SLICE_TOTAL=20
# ONE state dir across the three passes: the cursor is state, so three separate state dirs would each
# start at 0 and the arm would assert nothing (the first version of this arm did exactly that).
for i in 1 2 3; do
  run_drainer_foreground d
  cp "$ROOT/ai-d/state/drainer-brief.md" "$ROOT/brief-$i.md" 2>/dev/null
done
off() { sed -n 's/.*Start at PR offset \*\*\([0-9][0-9]*\)\*\*.*/\1/p' "$1" 2>/dev/null | head -1; }
check "(d) pass 1 starts at offset 0"  '[ "$(off "$ROOT/brief-1.md")" = "0" ]'  "$(off "$ROOT/brief-1.md")"
check "(d) pass 2 advances to offset 10" '[ "$(off "$ROOT/brief-2.md")" = "10" ]' "$(off "$ROOT/brief-2.md")"
check "(d) pass 3 WRAPS back to offset 0" '[ "$(off "$ROOT/brief-3.md")" = "0" ]' "$(off "$ROOT/brief-3.md")"
check "(d) the cursor file advanced past the wrap" \
  '[ "$(cat "$ROOT/ai-d/state/drainer-slice" 2>/dev/null)" = "3" ]'

# ── NON-VACUITY: remove the lock and the concurrency arm MUST fail ───────────────────────────
MUT="$ROOT/ai-drainer-nolock.sh"
awk '/──8<── lock-guard/{skip=1} !skip{print} /──8<── \/lock-guard/{skip=0}' "$DRAINER" >"$MUT"
check "mutation: the lock block was actually removed from the copy" \
  '! grep -q "mkdir \"\$LOCK\"" "$MUT" && [ -s "$MUT" ]'
FAKE_LANE_SECS=8
mo="$ROOT/o-m"; mai="$ROOT/ai-m"; mkdir -p "$mo/bg" "$mai"
O="$mo" AI="$mai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" SWAP_FREE_MB=9999 \
  LANE_TIMEOUT=60 LANE_WAIT_MAX=30 LANE_POLL_S=1 FAKE_LANE_SECS=8 \
  bash "$MUT" >/dev/null 2>&1 &
mpid=$!; echo "$mpid" >>"$ROOT/pids"
wait_for_file "$mo/bg/"*.pid 60
O="$mo" AI="$mai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" SWAP_FREE_MB=9999 \
  LANE_TIMEOUT=60 LANE_WAIT_MAX=30 LANE_POLL_S=1 FAKE_LANE_SECS=8 \
  bash "$MUT" >/dev/null 2>&1 &
echo "$!" >>"$ROOT/pids"
sleep 3
mstarts="$(grep -c 'START:' "$mai/logs/ai-drainer.log" 2>/dev/null || true)"
# This is the assertion that gives arm (a) its meaning: WITHOUT the lock, two lanes start.
check "non-vacuity: without the lock TWO lanes start (so arm (a) can fail)" \
  '[ "${mstarts:-0}" -ge 2 ]' "starts=$mstarts (the lock, not the harness, is what makes (a) pass)"

# ── the LAUNCHER's refusals (the silent-sharing failures, by name) ───────────────────────────
echo "== multi-repo-controller refusals =="
if [ -f "$LAUNCHER" ]; then
  r="$ROOT/mr"; mkdir -p "$r/pin"; : >"$r/pin/HARNESS-PIN"; printf 'deadbeef\n' >"$r/pin/HARNESS-PIN"
  out="$(OR="" REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: an unset OR is REFUSED (never defaulted)" '[ "$rc" -ne 0 ] && grep -q -- "OR is unset" <<<"$out"'
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: a MISSING state dir is refused with the --init remedy" \
    '[ "$rc" -ne 0 ] && grep -q -- "--init" <<<"$out"'
  mkdir -p "$r/state"
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" O_PRIMARY="$r/state" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: O equal to the PRIMARY state dir is refused" \
    '[ "$rc" -ne 0 ] && grep -q -- "IS the primary controller" <<<"$out"'
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" PIN_PRIMARY="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: HARNESS_PIN equal to the PRIMARY pin is refused" \
    '[ "$rc" -ne 0 ] && grep -q -- "primary controller.s pin" <<<"$out"'
  : >"$r/pin/EMPTY"
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/EMPTY" bash "$LAUNCHER" --check 2>&1)"; rc=$?
  check "launcher: an EMPTY pin is refused" '[ "$rc" -ne 0 ] && grep -q -- "absent or empty" <<<"$out"'
else
  bad "launcher missing at $LAUNCHER"
fi

echo
printf 'ai-drainer.test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
