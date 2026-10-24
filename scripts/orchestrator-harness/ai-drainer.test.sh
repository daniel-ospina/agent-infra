#!/usr/bin/env bash
# ai-drainer.test.sh — the guard regressions for scripts/orchestrator-harness/ai-drainer.sh.
#
# WHAT THIS SUITE IS FOR. The drainer is a SCHEDULED DISPATCHER, and every one of its guards fails in
# the expensive direction if it breaks:
#   * no lock              → two lanes drain the same PR slice, and every tick exits 0 (lane storm);
#   * lock released early  → the same storm, one interval later, because the dispatcher is async;
#   * a refusal counted as a completed lane → every tick reports DONE while no agent ever ran;
#   * no capacity floor    → a lane starts on a box already below the harness's swap floor;
#   * a stuck slice cursor → every pass works the same six PRs and the backlog never rotates.
# Each arm drives the REAL script (no reimplementation), with a fake dispatcher and a fake capacity
# read, so the arm tests the shipped code path rather than a copy of it.
#
# ⛔ THE STALE-LOCK ARM AND THE NON-VACUITY ARM ARE THE TWO THAT MATTER. A lock that is reclaimed by
# `rm -rf` + `mkdir` is not a lock (two contenders both "reclaim" it), and a concurrency test passes
# trivially if the second invocation never gets far enough to matter. So: arm (a) is asserted against
# a copy of the script with the lock block deleted and MUST fail there, and arm (a2) drives the
# reclaim path itself with two ticks racing over one STALE lock.
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
# Writes `$O/bg/<name>.pid` naming a process that lives FAKE_LANE_SECS and `$O/bg/<name>.rc`, exactly
# as both shipped dispatchers do. That is what the lock's lifetime AND the refusal verdict depend on,
# so these are the seams that make the guards testable rather than aspirational.
#   FAKE_LANE_SECS  how long the lane lives (0 = a lane that is already gone)
#   FAKE_RC         the exit status the lane records (default 0; "none" = write no status file)
#   FAKE_NO_PIDFILE write no pidfile at all (the "dispatcher returned, lane untrackable" shape)
DISPATCH="$ROOT/dispatch.sh"
cat >"$DISPATCH" <<'DISPATCH_EOF'
#!/usr/bin/env bash
set -u
NAME="$1"; WT="$2"; BRIEF="$3"
O="${O:?}"; D="$O/bg"; mkdir -p "$D"
printf '%s\n' "$(cd "$WT" && pwd)" > "$D/$NAME.wt"
SECS="${FAKE_LANE_SECS:-0}"
RC="${FAKE_RC:-0}"
if [ "${FAKE_NO_PIDFILE:-0}" = "1" ]; then exit 0; fi
( sleep "$SECS"; [ "$RC" = "none" ] || printf '%s\n' "$RC" > "$D/$NAME.rc" ) &
echo "$!" > "$D/$NAME.pid"
exit 0
DISPATCH_EOF
chmod +x "$DISPATCH"

# One drainer invocation, hermetically scoped. Every path is inside $ROOT, so nothing here can touch
# the live fleet's state dirs even when this runs on the operator's box.
_drainer_env() { # <tag> → echoes the env assignments, one per line (callers use `env`)
  local o="$ROOT/o-$1" ai="$ROOT/ai-$1"
  mkdir -p "$o/bg" "$ai"
  printf '%s\n' \
    "O=$o" "AI=$ai" "DISPATCH=$DISPATCH" "SEED_REPO=$SEED" "SEED_REF=$SEED_REF" \
    "MAX_LANES=${RUN_MAX_LANES:-4}" \
    "LANE_TIMEOUT=${RUN_LANE_TIMEOUT:-60}" "LANE_WAIT_MAX=${RUN_WAIT_MAX:-30}" "LANE_POLL_S=1" \
    "SLICE_WIDTH=${RUN_SLICE_WIDTH:-10}" "SLICE_TOTAL=${RUN_SLICE_TOTAL:-70}" \
    "FAKE_LANE_SECS=${FAKE_LANE_SECS:-0}" "FAKE_RC=${FAKE_RC:-0}" "FAKE_NO_PIDFILE=${FAKE_NO_PIDFILE:-0}"
  # SWAP_FREE_MB is passed only when the arm sets it: an absent value is what makes the script read
  # the box's own probe, which is the path the unreadable-swap arm exercises.
  [ -z "${RUN_SWAP:-}" ] || printf 'SWAP_FREE_MB=%s\n' "$RUN_SWAP"
  return 0
}
run_drainer_bg() { # <tag>
  local tag="$1" line
  local -a envs
  envs=()
  while IFS= read -r line; do envs+=("$line"); done < <(_drainer_env "$tag")
  env -u SWAP_FREE_MB "${envs[@]}" bash "$DRAINER" >/dev/null 2>&1 &
  echo "$!" >>"$ROOT/pids"
  LAST_O="$ROOT/o-$tag"; LAST_AI="$ROOT/ai-$tag"
}
run_drainer_fg() { # <tag> [drainer-path]
  local tag="$1" script="${2:-$DRAINER}" line
  local -a envs
  envs=()
  while IFS= read -r line; do envs+=("$line"); done < <(_drainer_env "$tag")
  env -u SWAP_FREE_MB "${envs[@]}" bash "$script" >/dev/null 2>&1
}
wait_for_path() { # <path> <tenths>
  local i=0
  while [ "$i" -lt "$2" ]; do [ -e "$1" ] && return 0; sleep 0.2; i=$((i + 1)); done
  return 1
}

echo "== ai-drainer guards =="

# ── ARM (a): TWO CONCURRENT INVOCATIONS → ONE RUN ─────────────────────────────────────────────
FAKE_LANE_SECS=8
run_drainer_bg a1
wait_for_path "$ROOT/ai-a1/state/ai-drainer.lock" 60 \
  || bad "(a) the first invocation never took the lock — nothing to test"
# Blocking second invocation, same state dir: it must SKIP, not start.
RUN_SWAP=9999 run_drainer_fg a1
starts="$(grep -c 'START:' "$ROOT/ai-a1/logs/ai-drainer.log" 2>/dev/null || true)"
skips="$(grep -c 'SKIP: drainer already running' "$ROOT/ai-a1/logs/ai-drainer.log" 2>/dev/null || true)"
check "(a) the second invocation SKIPPED on the lock" '[ "${skips:-0}" -ge 1 ]' "$(tail -3 "$ROOT/ai-a1/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"
check "(a) exactly ONE lane was dispatched" '[ "${starts:-0}" -eq 1 ]' "starts=$starts"

# ── ARM (a2): TWO TICKS RACING OVER A STALE LOCK → STILL ONE RUN (the atomic reclaim) ────────
# The measured defect this arm exists for: with `rm -rf "$LOCK"; mkdir "$LOCK"` BOTH contenders
# reclaim, B deletes A's fresh lock, and two lanes start. `mv` can only succeed once.
o="$ROOT/o-a2"; ai="$ROOT/ai-a2"; mkdir -p "$o/bg" "$ai/state"
mkdir -p "$ai/state/ai-drainer.lock"; printf '999999' >"$ai/state/ai-drainer.lock/pid"   # dead holder
FAKE_LANE_SECS=6
for i in 1 2 3; do                     # three contenders, to widen the window on a fast box
  ( O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" SWAP_FREE_MB=9999 \
    LANE_TIMEOUT=60 LANE_WAIT_MAX=20 LANE_POLL_S=1 FAKE_LANE_SECS=6 \
    bash "$DRAINER" >/dev/null 2>&1 & echo "$!" >>"$ROOT/pids" ) 2>/dev/null
done
i=0; while [ "$i" -lt 100 ]; do
  n="$(grep -c 'START:' "$ai/logs/ai-drainer.log" 2>/dev/null || true)"
  [ "${n:-0}" -ge 1 ] && break
  sleep 0.2; i=$((i + 1))
done
sleep 2                                 # let every contender get through the guard
astarts="$(grep -c 'START:' "$ai/logs/ai-drainer.log" 2>/dev/null || true)"
check "(a2) three ticks racing over ONE stale lock start exactly ONE lane" \
  '[ "${astarts:-0}" -eq 1 ]' "starts=$astarts — log: $(grep -E 'START:|reclaim|SKIP' "$ai/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"

# ── ARM (b): THE LOCK IS RELEASED ONLY WHEN THE LANE PID DIES (the 2-tick overlap) ───────────
# Reuse arm (a)'s live tick: it holds the lock, and its lane is still alive.
o="$ROOT/o-a1"; ai="$ROOT/ai-a1"
lock_pid="$(cat "$ai/state/ai-drainer.lock/pid" 2>/dev/null)"
check "(b) the lock names a LIVE holder while the lane lives" \
  '[ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null' "lock pid=${lock_pid:-none}"
beat_age=$(( $(date +%s) - $(cat "$ai/state/ai-drainer.beat" 2>/dev/null || echo 0) ))
check "(b) a held lock writes a FRESH beat while waiting" '[ "$beat_age" -le 5 ]' "beat age ${beat_age}s"
lane_pid="$(tr -dc '0-9' 2>/dev/null <"$o/bg/"*.pid 2>/dev/null | head -c 12)"
[ -n "$lane_pid" ] && kill "$lane_pid" 2>/dev/null
i=0; while [ -d "$ai/state/ai-drainer.lock" ] && [ "$i" -lt 60 ]; do sleep 0.25; i=$((i + 1)); done
check "(b) the lock is RELEASED once the lane pid dies" '[ ! -d "$ai/state/ai-drainer.lock" ]' \
  "still held after $((i / 4))s"
# A lane that was SIGNALLED has no exit status — and the tick must say so rather than claim success.
check "(b) a lane killed before recording a status is reported, never called DONE" \
  'grep -q "vanished with NO exit status" "$ai/logs/ai-drainer.log"' \
  "$(tail -2 "$ai/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"

# ── ARM (b2): A LANE THAT COMPLETES IS REPORTED DONE, at its own exit status ─────────────────
FAKE_LANE_SECS=2
RUN_SWAP=9999 run_drainer_fg b2; rc=$?
check "(b2) a lane that finishes rc=0 is DONE, and the tick exits 0" \
  '[ "$rc" -eq 0 ] && grep -q "DONE: lane .* finished rc=0" "$ROOT/ai-b2/logs/ai-drainer.log"' \
  "rc=$rc · $(tail -2 "$ROOT/ai-b2/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"
FAKE_LANE_SECS=2 FAKE_RC=3
run_drainer_fg b3; rc=$?
check "(b2) a lane that REFUSED (rc=3) makes the tick FAIL, not report DONE" \
  '[ "$rc" -ne 0 ] && grep -q "exited 3" "$ROOT/ai-b3/logs/ai-drainer.log"' "rc=$rc"
FAKE_LANE_SECS=0 FAKE_NO_PIDFILE=1
run_drainer_fg b4; rc=$?
check "(b2) a dispatcher that returns with NO pidfile makes the tick FAIL" \
  '[ "$rc" -ne 0 ] && grep -q "missing or unreadable" "$ROOT/ai-b4/logs/ai-drainer.log"' "rc=$rc"
FAKE_NO_PIDFILE=0; FAKE_RC=0

# ── ARM (c): SKIP BELOW THE CAPACITY FLOOR ───────────────────────────────────────────────────
RUN_SWAP=100
run_drainer_fg c1; rc=$?
check "(c) a pass below the swap floor SKIPS with exit 0" '[ "$rc" -eq 0 ]' "rc=$rc"
check "(c) the skip names the floor" \
  'grep -q "SKIP: swap 100MB < 700MB floor" "$ROOT/ai-c1/logs/ai-drainer.log"' \
  "$(cat "$ROOT/ai-c1/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"
check "(c) nothing was dispatched below the floor" \
  '[ "$(grep -c "START:" "$ROOT/ai-c1/logs/ai-drainer.log" 2>/dev/null || true)" -eq 0 ]'
check "(c) a skipping tick still refreshes the beat (idle ≠ dead)" \
  '[ -f "$ROOT/ai-c1/state/ai-drainer.beat" ]'

# ── ARM (c2): AN UNREADABLE CAPACITY READ FAILS CLOSED ───────────────────────────────────────
# Not a skip and not an OK: a probe that cannot answer must not look like an idle box.
RUN_SWAP=unreadable
run_drainer_fg c2; rc=$?
check "(c2) an unreadable swap read FAILS the tick" '[ "$rc" -ne 0 ]' "rc=$rc"
check "(c2) …and says why, instead of skipping" \
  'grep -q "free swap could not be read" "$ROOT/ai-c2/logs/ai-drainer.log"' \
  "$(cat "$ROOT/ai-c2/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"

# ── ARM (c3): A LIVE LANE SHAPED LIKE THE REAL DISPATCHER COUNTS TOWARD THE CAP ──────────────
# ⛔ The defect this arm exists for: both shipped dispatchers record the pid of a BACKGROUNDED
# SUBSHELL whose argv is `bash …/nonblocking-dispatch.sh …` (pi is its CHILD), so a "starts with pi"
# test counted ZERO lanes and MAX_LANES could never fire. The fixture is a live process whose argv
# carries the dispatcher's name — which is exactly what `ps` shows in production.
o="$ROOT/o-c3"; ai="$ROOT/ai-c3"; mkdir -p "$o/bg" "$ai"
# A live process whose `ps -o command=` carries the dispatcher's name, which is what a real lane's
# pidfile points at. A shell is used on purpose: copying a signed system binary and exec'ing it is
# killed on macOS, and a fixture that cannot run cannot prove anything.
printf '#!/usr/bin/env bash\nsleep "$1"; :\n' >"$ROOT/nonblocking-dispatch.sh"
bash "$ROOT/nonblocking-dispatch.sh" 30 &
planted=$!; echo "$planted" >>"$ROOT/pids"
printf '%s' "$planted" >"$o/bg/seed-lane.pid"
printf '999999' >"$o/bg/dead-lane.pid"          # a dead pidfile must count for nothing
RUN_MAX_LANES=1 RUN_SWAP=9999
run_drainer_fg c3
check "(c3) a live lane-shaped pid counts toward the cap and the pass SKIPS" \
  'grep -q "SKIP: 1 lanes already running (cap 1)" "$ROOT/ai-c3/logs/ai-drainer.log"' \
  "$(cat "$ROOT/ai-c3/logs/ai-drainer.log" 2>/dev/null | tr '\n' ' ')"
check "(c3) the dead pidfile did not inflate the count past the cap message" \
  'grep -q "SKIP: 1 lanes" "$ROOT/ai-c3/logs/ai-drainer.log"'
RUN_MAX_LANES=4

# ── ARM (c4): A NON-NUMERIC LANE_TIMEOUT MUST NOT DISABLE THE HELD LOCK ──────────────────────
# `LANE_TIMEOUT=30m` used to leave LANE_WAIT_MAX unset (bash: "value too great for base"), and the
# `set -u` read in the wait loop then killed the tick mid-lock — releasing a lock a LIVE lane owned.
o="$ROOT/o-c4"; ai="$ROOT/ai-c4"; mkdir -p "$o/bg" "$ai"
FAKE_LANE_SECS=6
( O="$o" AI="$ai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" SWAP_FREE_MB=9999 \
  LANE_TIMEOUT=30m LANE_POLL_S=1 FAKE_LANE_SECS=6 bash "$DRAINER" >/dev/null 2>&1 & echo "$!" >>"$ROOT/pids" )
wait_for_path "$ai/state/ai-drainer.lock" 60
sleep 3
c4_pid="$(cat "$ai/state/ai-drainer.lock/pid" 2>/dev/null)"
check "(c4) a non-numeric LANE_TIMEOUT still holds the lock while the lane lives" \
  '[ -n "$c4_pid" ] && kill -0 "$c4_pid" 2>/dev/null' "lock pid=${c4_pid:-none}"
check "(c4) …and the bad value is reported, not silently defaulted" \
  'grep -q "WARN: LANE_TIMEOUT=.*is not a whole number" "$ai/logs/ai-drainer.log"'
FAKE_LANE_SECS=0

# ── ARM (d): THE SLICE CURSOR ADVANCES AND WRAPS ─────────────────────────────────────────────
RUN_SLICE_WIDTH=10 RUN_SLICE_TOTAL=20
# ONE state dir across the three passes: the cursor is state, so three separate state dirs would each
# start at 0 and the arm would assert nothing.
for i in 1 2 3; do
  RUN_SWAP=9999 run_drainer_fg d
  cp "$ROOT/ai-d/state/drainer-brief.md" "$ROOT/brief-$i.md" 2>/dev/null
done
off() { sed -n 's/.*Start at PR offset \*\*\([0-9][0-9]*\)\*\*.*/\1/p' "$1" 2>/dev/null | head -1; }
check "(d) pass 1 starts at offset 0"  '[ "$(off "$ROOT/brief-1.md")" = "0" ]'  "$(off "$ROOT/brief-1.md")"
check "(d) pass 2 advances to offset 10" '[ "$(off "$ROOT/brief-2.md")" = "10" ]' "$(off "$ROOT/brief-2.md")"
check "(d) pass 3 WRAPS back to offset 0" '[ "$(off "$ROOT/brief-3.md")" = "0" ]' "$(off "$ROOT/brief-3.md")"
check "(d) the cursor file advanced past the wrap" \
  '[ "$(cat "$ROOT/ai-d/state/drainer-slice" 2>/dev/null)" = "3" ]'
check "(d) the tick did not leave its worktree behind" \
  '! ls -d "$ROOT/ai-d"/wt-drainer-* >/dev/null 2>&1'

# ── NON-VACUITY: remove the lock and the concurrency arm MUST fail ───────────────────────────
MUT="$ROOT/ai-drainer-nolock.sh"
awk '/──8<── lock-guard/{skip=1} !skip{print} /──8<── \/lock-guard/{skip=0}' "$DRAINER" >"$MUT"
check "mutation: the lock block was actually removed from the copy" \
  '! grep -q "mkdir \"\$LOCK\"" "$MUT" && [ -s "$MUT" ]'
mo="$ROOT/o-m"; mai="$ROOT/ai-m"; mkdir -p "$mo/bg" "$mai"
O="$mo" AI="$mai" DISPATCH="$DISPATCH" SEED_REPO="$SEED" SEED_REF="$SEED_REF" SWAP_FREE_MB=9999 \
  LANE_TIMEOUT=60 LANE_WAIT_MAX=30 LANE_POLL_S=1 FAKE_LANE_SECS=8 \
  bash "$MUT" >/dev/null 2>&1 &
echo "$!" >>"$ROOT/pids"
wait_for_path "$mo/bg/"*.pid 60
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
  r="$ROOT/mr"; mkdir -p "$r/pin"; printf 'deadbeef\n' >"$r/pin/HARNESS-PIN"
  out="$(OR="" REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: an unset OR is REFUSED (never defaulted)" '[ "$rc" -ne 0 ] && grep -q -- "OR is unset" <<<"$out"'
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: a MISSING state dir is refused with the init remedy" \
    '[ "$rc" -ne 0 ] && grep -q -- "--init" <<<"$out"'
  check "launcher: a refusal does not CREATE the state dir it refuses" '[ ! -d "$r/state" ]'
  mkdir -p "$r/state"
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" O_PRIMARY="$r/state" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: O equal to the PRIMARY state dir is refused" \
    '[ "$rc" -ne 0 ] && grep -q -- "IS the primary controller" <<<"$out"'
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/HARNESS-PIN" PIN_PRIMARY="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: HARNESS_PIN equal to the PRIMARY pin is refused" \
    '[ "$rc" -ne 0 ] && grep -q -- "primary controller.s pin" <<<"$out"'
  # A differently-SPELLED path to the primary pin is the same pin.
  out="$(OR=o/r REPO="$SEED" O="$r/state" HARNESS_PIN="$r/pin/./HARNESS-PIN" PIN_PRIMARY="$r/pin/HARNESS-PIN" bash "$LAUNCHER" 2>&1)"; rc=$?
  check "launcher: a non-canonical path to the PRIMARY pin is refused too" \
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
