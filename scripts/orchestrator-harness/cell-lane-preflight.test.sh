#!/usr/bin/env bash
# cell-lane-preflight.test.sh — the capability gate must NAME which of the two defects it saw
# (agent-infra#2935).
#
# Everything here runs against a STUB `pi` on PATH. That is deliberate: the gate's whole value is
# that it distinguishes "the request never resolved" from "the request resolved and the process never
# returned", and those two are only distinguishable when you control when the answer appears and
# when the process ends. A test against the real provider can observe one of them and, on a healthy
# day, only the boring one.
#
# ── WHAT EACH ARM PINS, AND THE FAILURE IT PREVENTS ─────────────────────────────────────────────
# A1  answer + return                      → `ok`, exit 0.  The gate must PASS a good box, or it is
#                                            an outage dressed as a guard.
# A2  answer, then never return            → `refused why=exit-hang`, exit 3. THIS IS #2935: the
#                                            answer arrives and the process does not exit. A gate
#                                            that reports this as `ok` (because output appeared) or
#                                            as `no-answer` (because it grepped for output bytes)
#                                            sends the operator to the wrong owner.
# A3  nothing ever answers                 → `refused why=no-answer`, exit 3, and `attempts=2` — the
#                                            retry is pinned because a transient blip must not
#                                            refuse a dispatch wave on the first failure.
# A4  answered, exits non-zero             → `refused why=call-failed`, exit 3 (not `ok`: a call that
#                                            failed still "answered").
# A5  no key anywhere                      → exit 2 (CANNOT MEASURE). A keyless lane run is exactly
#                                            the run that reports `(no response)` 55 minutes later;
#                                            the gate must refuse rather than measure nothing.
# A6  `pi` absent                          → exit 2, `why=pi-missing`.
# A7  the keys file sets HOME              → this process's HOME is UNCHANGED. `keys.env` is arbitrary
#                                            code and `cloud-cell-bringup.sh` documents that it may
#                                            set HOME; sourcing it here would move `$HOME/.pi/agent`
#                                            out from under the very agent being measured.
# A8  the banner is not an answer          → a stub that writes 4 KB of extension banners and never
#                                            the token is A3's case, not `ok`. This is the artifact
#                                            the first cut of the measurement hit: `first byte` is a
#                                            banner at ~1 s on every box, including the broken ones.
# A10 hangs BEFORE it ever answers       → `refused why=no-return`, exit 3, `alive_at=`, `attempts=2`.
#                                            THIS IS THE ARM THE GATE WAS VACUOUS FOR: a box whose
#                                            provider is blackholed, whose proxy drops, or whose
#                                            extension set hangs before the first token never produces
#                                            the token, so before `no-return` existed it could only emit
#                                            `no-answer` — the WARN arm — and was dispatched anyway,
#                                            for ever. (Reproduced: `why=no-answer alive_at=3s
#                                            attempts=1`, run_agent proceeded and launched.)
# A11 a hang that does NOT repeat        → `why=no-answer` (the WARN side), attempts=2. The SAME first
#                                            sample as A10, with a fast failure second: this is what
#                                            makes A10 a property of the box rather than a verdict on
#                                            one slow sample, and it is why a healthy-but-slow box
#                                            (answer 29 s, exit 30.4 s at a 30 s bound) is not refused.
# A12 the probe kills the GROUP          → a stub whose `pi` spawns a child leaves NO child behind
#                                            (#2163's class, measured here on this file's own first cut:
#                                            `pgrep -fl "sleep 300"` found the surviving child). The
#                                            probe is re-invoked every controller cycle on the sick box,
#                                            so the leak compounds where it can least be afforded.
# A13 the credential follows --provider  → a `--provider venice` lane on a box holding only
#                                            `VENICE_API_KEY` is measurable, not `keys-unreadable`.
# A14 an empty `--model`                 → `refused why=misconfigured`, exit 2: a deterministic
#                                            misconfiguration, never an absent answer (measured before
#                                            this arm: `pi -p --provider  --model  …`, reported as a
#                                            network arm the caller warns on).
#
# ── MUTATION ────────────────────────────────────────────────────────────────────────────────────
# Every count below is what THIS file printed, measured by running it. Two mutations, because two
# different properties are pinned and they redden different arms:
#
# (M1) re-emit the pre-answer hang as the WARN-side reason — i.e. restore this arm:
#        if [ "$A_KILLED" -eq 1 ]; then last=no-return; else last=no-answer; fi
#      become
#        last=no-answer
#      (the first cut's behaviour, where a process killed at the bound was reported `no-answer`) —
#      A10 goes red with `FAIL A10 names the pre-answer hang expected 'why=no-return' in the verdict
#      line, got: …why=no-answer…`, and A12's reading assertion follows it. Counts are in the
#      `cell-lane-preflight:` footer of the run.
# (M2) refuse a hang on ONE sample (drop the retry): A11 goes red — a single slow sample would refuse
#      a working box.
# ⚠️ THE EARLIER HEADER ON THIS FILE NAMED A DIFFERENT MUTATION WITH COUNTS THAT BELONGED TO A THIRD
# ONE (review of #2991, P2, reproduced by the reviewer). The old counts are deleted rather than
# restated: a number that does not reproduce under the mutation it names is a claim about process
# with no artifact behind it, and the reviewer re-derived it in one run.
#
# Run: bash scripts/orchestrator-harness/cell-lane-preflight.test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/cell-lane-preflight.sh"
[ -f "$TARGET" ] || { echo "cannot find $TARGET" >&2; exit 1; }

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$*"; }
# assert_has <label> <needle> <haystack>
assert_has() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1 expected '$2' in the verdict line, got: $3" ;;
  esac
}
# assert_not_has <label> <needle> <haystack>
assert_not_has() {
  case "$3" in
    *"$2"*) bad "$1 must NOT contain '$2', got: $3" ;;
    *) ok "$1" ;;
  esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/clp-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

# ── stub builders ────────────────────────────────────────────────────────────────────────────────
# make_stub <dir> <mode>; writes <dir>/bin/pi
make_stub() {
  local d="$1" mode="$2"
  mkdir -p "$d/bin"
  cat >"$d/bin/pi" <<STUB
#!/usr/bin/env bash
case "\$1" in --version) echo "9.9.9-stub"; exit 0 ;; esac
echo "\$@" >>"$d/invocations"
echo "stub-home=\$HOME"
# 4 KB of extension banner, like every box emits in the first 1-2 s
i=0; while [ \$i -lt 60 ]; do echo "[stub-extension] banner line \$i — nothing to do with the answer"; i=\$((i+1)); done
case "$mode" in
  answer)        echo "PF_OK_4f2c"; exit 0 ;;
  answer-noret)  echo "PF_OK_4f2c"; sleep 600; exit 0 ;;
  silent)        exit 0 ;;
  silent-hang)   sleep 600; exit 0 ;;
  answer-fail)   echo "PF_OK_4f2c"; exit 7 ;;
  # hangs before the answer on the FIRST sample, fails fast on the second: a blip that wore a hang's
  # shape once. The counter lives in the stub's own directory, so arms cannot contaminate each other.
  hang-then-fail)
      f="$d/count"; n=\$(cat "\$f" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "\$f"
      [ "\$n" -gt 1 ] && { echo "connection reset" >&2; exit 1; }
      sleep 600; exit 0 ;;
  # spawns a CHILD, then hangs: the shape a real `pi` has (tool/extension children), and the one the
  # orphan leak was measured in.
  child-hang)    sleep 3131 & echo "started child \$!"; sleep 600; exit 0 ;;
esac
STUB
  chmod +x "$d/bin/pi"
}
# make_keys <dir> [extra-line]
make_keys() {
  local d="$1" extra="${2:-}"
  {
    echo 'export DEEPSEEK_API_KEY=sk-stub-0000000000000000000000000'
    [ -n "$extra" ] && echo "$extra"
  } >"$d/keys.env"
  chmod 600 "$d/keys.env"
}
# run_gate <dir> <bound> [extra args…] -> sets RC and OUT
run_gate() {
  local d="$1" bound="$2"; shift 2
  OUT="$(env -u DEEPSEEK_API_KEY -u CELL_HOME -u LANE_PREFLIGHT_KEYS PATH="$d/bin:$PATH" \
          HOME="$d/home" bash "$TARGET" --keys "$d/keys.env" --bound "$bound" "$@" 2>&1)"
  RC=$?
}
mkdir -p "$WORK/home"

# ── A1: answer + return → ok ────────────────────────────────────────────────────────────────────
make_stub "$WORK/a1" answer; make_keys "$WORK/a1"
run_gate "$WORK/a1" 20
[ "$RC" -eq 0 ] && ok "A1 exit 0 on a capable box" || bad "A1 expected exit 0, got $RC: $OUT"
assert_has "A1 verdict" "LANE_CAPABILITY=ok" "$OUT"
assert_has "A1 carries answered_ms" "answered_ms=" "$OUT"
assert_has "A1 carries returned_ms" "returned_ms=" "$OUT"

# ── A2: answer, then never return → exit-hang ──────────────────────────────────────────────────
make_stub "$WORK/a2" answer-noret; make_keys "$WORK/a2"
run_gate "$WORK/a2" 3
[ "$RC" -eq 3 ] && ok "A2 exit 3 (a gate verdict) on an exit-hanging box" || bad "A2 expected exit 3, got $RC: $OUT"
assert_has "A2 names the exit hang" "why=exit-hang" "$OUT"
assert_has "A2 proves the request resolved" "answered_ms=" "$OUT"
assert_not_has "A2 is never reported ok" "LANE_CAPABILITY=ok" "$OUT"

# ── A3: nothing answers → no-answer, and it retried ────────────────────────────────────────────
make_stub "$WORK/a3" silent; make_keys "$WORK/a3"
run_gate "$WORK/a3" 2
[ "$RC" -eq 3 ] && ok "A3 exit 3 on a box that never answers" || bad "A3 expected exit 3, got $RC: $OUT"
assert_has "A3 names the stall" "why=no-answer" "$OUT"
assert_has "A3 pins the retry (a transient blip must not refuse a wave)" "attempts=2" "$OUT"
# A3b: a banner-heavy, answer-free box is A3's class, never `ok` (the first-cut artifact)
assert_not_has "A3/A8 banners are not an answer" "LANE_CAPABILITY=ok" "$OUT"

# ── A4: answered, exited non-zero → call-failed ────────────────────────────────────────────────
make_stub "$WORK/a4" answer-fail; make_keys "$WORK/a4"
run_gate "$WORK/a4" 20
[ "$RC" -eq 3 ] && ok "A4 exit 3 when the call fails" || bad "A4 expected exit 3, got $RC: $OUT"
assert_has "A4 names the failed call" "why=call-failed" "$OUT"
assert_not_has "A4 is never reported ok" "LANE_CAPABILITY=ok" "$OUT"

# ── A5: no key anywhere → CANNOT MEASURE ──────────────────────────────────────────────────────
make_stub "$WORK/a5" answer
mkdir -p "$WORK/a5/home"
OUT="$(env -u DEEPSEEK_API_KEY -u CELL_HOME -u LANE_PREFLIGHT_KEYS PATH="$WORK/a5/bin:$PATH" \
        HOME="$WORK/a5/home" bash "$TARGET" --bound 5 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "A5 exit 2 when nothing can be measured" || bad "A5 expected exit 2, got $RC: $OUT"
assert_has "A5 names the unreadable keys" "why=keys-unreadable" "$OUT"

# ── A6: pi absent → CANNOT MEASURE ────────────────────────────────────────────────────────────
mkdir -p "$WORK/a6/bin"; make_keys "$WORK/a6"
OUT="$(env -u DEEPSEEK_API_KEY -u CELL_HOME PATH="$WORK/a6/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$WORK/a6/home" bash "$TARGET" --keys "$WORK/a6/keys.env" --bound 5 2>&1)"; RC=$?
case "$RC" in
  2) ok "A6 exit 2 when pi is absent" ;;
  0) bad "A6 must not pass a box with no pi: $OUT" ;;
  *) [ "$(printf '%s' "$OUT" | grep -c 'why=pi-missing')" -ge 1 ] && ok "A6 names the missing pi (exit $RC)" || bad "A6 expected why=pi-missing, got: $OUT" ;;
esac

# ── A7: the keys file must not leak HOME (or anything else) into this process ──────────────────
make_stub "$WORK/a7" answer; make_keys "$WORK/a7" 'export HOME=/nonexistent/from-keys-env'
run_gate "$WORK/a7" 20
[ "$RC" -eq 0 ] && ok "A7 a keys file that sets HOME does not break the measurement" || bad "A7 expected exit 0, got $RC: $OUT"
case "$OUT" in
  *"/nonexistent/from-keys-env"*) bad "A7 the keys file's HOME leaked into the probe: $OUT" ;;
  *) ok "A7 the keys file's HOME did not leak" ;;
esac

# ── A9: usage refusals are explicit, never a silent default ───────────────────────────────────
OUT="$(bash "$TARGET" --bound zero 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "A9 a non-numeric --bound is refused" || bad "A9 expected exit 2, got $RC: $OUT"

# ── A10: hangs BEFORE the answer → no-return (the permanent pre-answer failure) ────────────────
# ⛔ `--quiet` HERE ON PURPOSE: the WARN-side word appears in the operator HINT this file prints on
# stderr ("a box that FAILS FAST reports why=no-answer instead"), so the assertion below greps the
# verdict line alone. The hint is asserted separately by A10b.
make_stub "$WORK/a10" silent-hang; make_keys "$WORK/a10"
run_gate "$WORK/a10" 2 --quiet
[ "$RC" -eq 3 ] && ok "A10 exit 3 on a box that hangs before it ever answers" || bad "A10 expected exit 3, got $RC: $OUT"
assert_has "A10 names the pre-answer hang" "why=no-return" "$OUT"
assert_has "A10 carries the reading (still alive at the bound)" "alive_at=2s" "$OUT"
assert_has "A10 required the hang to REPEAT before refusing" "attempts=2" "$OUT"
assert_not_has "A10 is never the WARN-side reason (that would be dispatched for ever)" "why=no-answer" "$OUT"
# A10b: without --quiet the operator is told the two owners and the one comparison that separates them
run_gate "$WORK/a10" 2
assert_has "A10b names BOTH owners of a pre-answer hang" "TWO owners" "$OUT"

# ── A11: a hang that does NOT repeat is a blip, not a property ─────────────────────────────────
make_stub "$WORK/a11" hang-then-fail; make_keys "$WORK/a11"
run_gate "$WORK/a11" 2 --attempts 2
[ "$RC" -eq 3 ] && ok "A11 exit 3 (a gate verdict) when only the FIRST sample hung" || bad "A11 expected exit 3, got $RC: $OUT"
assert_has "A11 the LAST sample decides: a fast failure is the transient arm" "why=no-answer" "$OUT"
assert_not_has "A11 did not refuse a box that failed fast once the sample repeated" "why=no-return" "$OUT"

# ── A12: the probe kills the GROUP, not the leader (#2163) ─────────────────────────────────────
make_stub "$WORK/a12" child-hang; make_keys "$WORK/a12"
run_gate "$WORK/a12" 2
assert_has "A12 the pre-answer hang is named" "why=no-return" "$OUT"
sleep 1
if pgrep -f 'sleep 3131' >/dev/null 2>&1; then
  bad "A12 the probe left a CHILD alive (pgrep -f 'sleep 3131') — the controller re-probes every cycle, so this accumulates on the sick box"
  pkill -f 'sleep 3131' 2>/dev/null || true
else
  ok "A12 the group kill reached the child the probe spawned (no orphan)"
fi

# ── A13: the credential follows --provider, not a hardcoded deepseek variable ─────────────────
make_stub "$WORK/a13" answer; mkdir -p "$WORK/a13/home"
echo 'export VENICE_API_KEY=sk-venice-stub' >"$WORK/a13/keys.env"; chmod 600 "$WORK/a13/keys.env"
OUT="$(env -u DEEPSEEK_API_KEY -u VENICE_API_KEY -u CELL_HOME -u LANE_PREFLIGHT_KEYS PATH="$WORK/a13/bin:$PATH" \
        HOME="$WORK/a13/home" bash "$TARGET" --keys "$WORK/a13/keys.env" --provider venice \
        --model deepseek-v4-flash --bound 10 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "A13 a venice lane on a box holding only VENICE_API_KEY is measurable" || bad "A13 expected exit 0, got $RC: $OUT"
assert_has "A13 reports the provider it actually measured" "model=venice/" "$OUT"

# ── A14: an empty model id is a MISCONFIGURATION, not an absent answer ─────────────────────────
OUT="$(bash "$TARGET" --model "" --bound 5 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "A14 an empty --model exits 2" || bad "A14 expected exit 2, got $RC: $OUT"
assert_has "A14 names the misconfiguration" "why=misconfigured" "$OUT"
assert_not_has "A14 is never reported as a network arm" "why=no-answer" "$OUT"

printf '\ncell-lane-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
