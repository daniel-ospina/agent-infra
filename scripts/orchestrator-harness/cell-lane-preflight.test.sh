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
# A16 fresh checkout                       → `ok`, exit 0, carrying `behind=0`. #3932's gate must PASS
#                                            a current box, or it is the outage it was built to prevent.
# A17 stale checkout                       → `refused why=stale-code`, exit 3, carrying the distance
#                                            (`behind=3 max_behind=2`); and the SAME repo at a higher
#                                            threshold is `ok` + `behind=3`, so the arm pins the
#                                            THRESHOLD rather than "any repo refuses".
# A18 a fetch that FAILS                   → `behind=unknown`, exit 0 — never the count left behind by
#                                            the last successful fetch. This is the false PASS the
#                                            reading exists to remove: a box 500 commits behind, last
#                                            fetched a month ago, answering `behind=8` and READY.
# A19 no checkout to measure               → `repo=none behind=unknown`, exit 0: the CI/dev path (every
#                                            other arm here runs it), reported and never refused.
# A20 a bad threshold                      → exit 2 (`why=usage`), not a silent `ok`.
# A21 a checkout at $PWD                   → measured with NOTHING named: the production default (this
#                                            change's review, P1-1). The pre-fix candidate list was
#                                            `$HOME/tortoise` / `$HOME/agent-infra` only, so on every
#                                            box the reading was measured on the gate answered
#                                            `repo=none behind=unknown → ok` — inert where it had to
#                                            fire — and no arm noticed, because every arm passed
#                                            `CELL_PREFLIGHT_REPO` explicitly.
# A22 the CELL layout                      → `HOME` has no checkout and the harness is at
#                                            `${CELL_HOME}/agent-infra`; still measured.
# A23 `HOME` unset                         → the verdict line STILL CARRIES `repo=`/`behind=`. Pre-fix,
#                                            `$HOME/tortoise` under `set -u` aborted inside `$( )` and
#                                            the readiness field VANISHED instead of saying `unknown`.
# A24 a NAMED checkout                     → `--repo` reaches the same reading; and a named path that
#                                            is not a checkout is REPORTED, never replaced by a guess
#                                            (looking somewhere other than where you were told is the
#                                            same defect one step later).
# A25 a checkout with NO fetch refspec     → the count is still MEASURED. `git fetch origin main`
#                                            refreshes `origin/main` only by git's OPPORTUNISTIC UPDATE,
#                                            which needs a configured `remote.origin.fetch`; without it
#                                            the fetch exits 0 and leaves the stale ref, so the gate
#                                            printed `behind=0` on a 3-behind checkout. Measured.
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
# (M3) read the count WITHOUT the fetch's status (drop the `wait`/`fetch_rc` guard and read `rev-list`
#      unconditionally — the first cut's shape): A18 goes red, `expected 'behind=unknown' … got:
#      …behind=0…`. That is the mutation that matters, because it makes the gate publish a number it
#      never measured, and it is invisible in production right up to the moment a stale base lands work.
# (M4) fetch with `origin main` instead of the explicit `+refs/heads/main:refs/remotes/origin/main`
#      destination: A25 goes red on a checkout whose `remote.origin.fetch` is unset (`behind=0` on a
#      3-behind box). Measured on that fixture before the destination was made explicit.
# (M5) drop `$PWD` from the default candidate list: A21 goes red (`repo=none`). Drop the cell paths:
#      A22 goes red. Read `$HOME` bare again: A23 goes red on the MISSING FIELD, not on a wrong value.
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
# ⛔ THE PROBE RUNS FROM `<dir>`, NOT FROM WHATEVER CWD THE SUITE WAS STARTED IN (this change's review,
# P1-1). The staleness reading resolves `$PWD` as a candidate, so an arm launched from the repo root
# measured the CHECKOUT THE SUITE LIVES IN — a real network fetch per arm, and an `ok` line whose
# `behind=` depended on the box. `<dir>` holds no `.git`, so these arms take the documented
# "no checkout to measure" path deterministically, which is what they are about (the capability read).
run_gate() {
  local d="$1" bound="$2"; shift 2
  OUT="$( cd "$d" && env -u DEEPSEEK_API_KEY -u CELL_HOME -u LANE_PREFLIGHT_KEYS \
          -u CELL_PREFLIGHT_REPO -u CELL_PREFLIGHT_MAX_BEHIND -u CELL_PREFLIGHT_FETCH_BOUND \
          PATH="$d/bin:$PATH" HOME="$d/home" bash "$TARGET" --keys "$d/keys.env" --bound "$bound" "$@" 2>&1)"
  RC=$?
}
mkdir -p "$WORK/home"

# ── staleness fixtures (#3932) ──────────────────────────────────────────────────────────────────
# "How far behind origin/main is this checkout" can only be answered by git, so these arms build real
# repositories: a bare origin, a clone of it, and commits pushed to origin AFTER the clone (so the
# clone is exactly N behind until it fetches). Every remote is a local path — no network.
# ⛔ The clones are created in sync and then upstream is advanced, so an arm can make the local
# `origin/main` ref STALE on purpose (A18): that is the shape a failed fetch leaves behind, and it is
# the one that makes an unconditional `rev-list` look like a measurement.
g() { git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
         -c tag.gpgsign=false -c init.defaultBranch=main "$@"; }
mk_ahead() { # mk_ahead <dir> <n> → n more commits on upstream's main, pushed
  local d="$1" n="${2:-0}" i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i+1))
    g -C "$d/up" commit -q --allow-empty -m "ahead $i" || return 1
  done
  [ "$n" -eq 0 ] || g -C "$d/up" push -q origin main || return 1
  return 0
}
mk_repo() { # mk_repo <dir> <n-ahead> → <dir>/repo is <n-ahead> commits behind its origin/main
  local d="$1" n="${2:-0}"
  mkdir -p "$d" || return 1
  g init -q --bare "$d/origin.git" || return 1
  g -C "$d/origin.git" symbolic-ref HEAD refs/heads/main || return 1
  g init -q "$d/up" || return 1
  g -C "$d/up" symbolic-ref HEAD refs/heads/main || return 1
  g -C "$d/up" remote add origin "$d/origin.git" || return 1
  g -C "$d/up" commit -q --allow-empty -m init || return 1
  g -C "$d/up" push -q origin main || return 1
  g clone -q "$d/origin.git" "$d/repo" || return 1
  mk_ahead "$d" "$n"
}
unreachable_remote() { # the clone keeps its last-fetched origin/main; every further fetch fails
  g -C "$1/repo" remote set-url origin "$1/does-not-exist.git"
}
# run_gate_in <cwd> <dir> <bound> [VAR=value …] → RC and OUT, the probe running FROM <cwd>
run_gate_in() {
  local cwd="$1" d="$2" bound="$3"; shift 3
  OUT="$( cd "$cwd" && env -u DEEPSEEK_API_KEY -u CELL_HOME -u LANE_PREFLIGHT_KEYS -u CELL_PREFLIGHT_REPO \
          -u CELL_PREFLIGHT_MAX_BEHIND -u CELL_PREFLIGHT_FETCH_BOUND \
          PATH="$d/bin:$PATH" HOME="$d/home" "$@" \
          bash "$TARGET" --keys "$d/keys.env" --bound "$bound" 2>&1)"
  RC=$?
}
# run_gate_cell <dir> <bound> [VAR=value …] → RC and OUT, extra env threaded through `env`
run_gate_cell() {
  local d="$1" bound="$2"; shift 2
  run_gate_in "$d" "$d" "$bound" "$@"
}

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

# ── A15: a USAGE error must EMIT A VERDICT, because the caller decides from the line (follow-up to
# #2991, P2, measured). `die_usage` used to exit 2 with a stderr message and NOTHING on stdout, so
# the caller's "no verdict" arm WARNed and proceeded: `LANE_PREFLIGHT_BOUND=45s` measured
# `probe rc=2 stdout=<>` and then `run_agent rc=0, agent launched`. Against this file's own EXIT
# table ("2 CANNOT MEASURE — EVERY caller must refuse too"). A refusal that cannot be read is an
# inert refusal, so the assertion is on the LINE, not on the exit code: the code was always 2.
OUT="$(bash "$TARGET" --quiet --bound 45s 2>/dev/null)"; RC=$?
[ "$RC" -eq 2 ] && ok "A15 a non-numeric --bound still exits 2 (CANNOT MEASURE)" || bad "A15 expected exit 2, got $RC: $OUT"
assert_has "A15 ...but it now carries a READABLE verdict on stdout" "LANE_CAPABILITY=refused why=usage" "$OUT"
assert_has "A15 ...with the reading that caused it, not a bare 'invalid'" "usage-error=--bound" "$OUT"
assert_not_has "A15 ...and it is never confused with the transient arm" "why=no-answer" "$OUT"
# The unknown-argument path is the one PRODUCTION hits: a consumer newer than this helper passes a flag
# this copy predates. It must be readable for the same reason.
OUT="$(bash "$TARGET" --quiet --line 2>/dev/null)"; RC=$?
[ "$RC" -eq 2 ] && ok "A15 an unknown argument exits 2" || bad "A15 expected exit 2, got $RC: $OUT"
assert_has "A15 ...and is readable as a refusal too (helper/consumer skew)" "why=usage" "$OUT"
assert_has "A15 ...naming the argument it rejected" "usage-error=unknown argument: --line" "$OUT"
# `-h` must NOT become a refusal: it is the one path that exits before measuring on purpose.
OUT="$(bash "$TARGET" --help 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "A15 --help still exits 0 and is not a refusal" || bad "A15 --help exited $RC"
assert_not_has "A15 ...emitting no verdict at all" "LANE_CAPABILITY" "$OUT"

# ── A16–A20: CODE STALENESS IS A READINESS FIELD (#3932) ───────────────────────────────────────
# The measured defect: all five cells were 496–7093 commits behind origin/main and every one emitted
# `LANE_CAPABILITY=ok`, because the gate only ever asked whether a model call could complete.

# A16 — a CURRENT checkout still passes, and says how it knows.
make_stub "$WORK/a16" answer; make_keys "$WORK/a16"
mk_repo "$WORK/a16" 0 || bad "A16 fixture: could not build a git repo (git missing?)"
run_gate_cell "$WORK/a16" 20 CELL_PREFLIGHT_REPO="$WORK/a16/repo" CELL_PREFLIGHT_MAX_BEHIND=2
[ "$RC" -eq 0 ] && ok "A16 a current checkout is still READY (exit 0)" || bad "A16 expected exit 0, got $RC: $OUT"
assert_has "A16 verdict" "LANE_CAPABILITY=ok" "$OUT"
assert_has "A16 carries the measurement it made" "behind=0" "$OUT"

# A17 — a stale checkout REFUSES, and the refusal carries the distance. THIS IS #3932.
make_stub "$WORK/a17" answer; make_keys "$WORK/a17"
mk_repo "$WORK/a17" 3 || bad "A17 fixture: could not build a git repo"
run_gate_cell "$WORK/a17" 20 CELL_PREFLIGHT_REPO="$WORK/a17/repo" CELL_PREFLIGHT_MAX_BEHIND=2
[ "$RC" -eq 3 ] && ok "A17 a stale checkout exits 3 (a gate verdict, like every other refusal)" \
                || bad "A17 expected exit 3, got $RC: $OUT"
assert_has "A17 names the staleness" "why=stale-code" "$OUT"
assert_has "A17 carries the distance it measured" "behind=3" "$OUT"
assert_has "A17 carries the threshold it applied" "max_behind=2" "$OUT"
assert_not_has "A17 is never reported ok (the defect this closes)" "LANE_CAPABILITY=ok" "$OUT"
assert_has "A17 tells the operator the remedy" "Advance the checkout" "$OUT"
# A17b — and the SAME repo at a higher threshold is READY: the arm pins the threshold, not "any repo
# refuses", which would be a gate that fails the fleet instead of protecting it.
run_gate_cell "$WORK/a17" 20 CELL_PREFLIGHT_REPO="$WORK/a17/repo" CELL_PREFLIGHT_MAX_BEHIND=5
[ "$RC" -eq 0 ] && ok "A17b the same stale checkout is READY under a threshold it satisfies" \
                || bad "A17b expected exit 0 at max_behind=5, got $RC: $OUT"
assert_has "A17b still reports the distance" "behind=3" "$OUT"

# A18 — a fetch that FAILS is `unknown`, never the count left behind by the last successful fetch.
# The clone's origin/main is 0 behind (it was cloned in sync), upstream is now 3 ahead, and the remote
# is unreachable — so the ONLY count available locally is a stale 0. Publishing it would declare a
# 3-behind (in production: 500-behind) box READY on the strength of a ref nobody refreshed.
make_stub "$WORK/a18" answer; make_keys "$WORK/a18"
mk_repo "$WORK/a18" 0 || bad "A18 fixture: could not build a git repo"
mk_ahead "$WORK/a18" 3
unreachable_remote "$WORK/a18"
run_gate_cell "$WORK/a18" 20 CELL_PREFLIGHT_REPO="$WORK/a18/repo" CELL_PREFLIGHT_MAX_BEHIND=2
[ "$RC" -eq 0 ] && ok "A18 an unanswerable network read is a WARN, not a refusal (exit 0)" \
                || bad "A18 expected exit 0, got $RC: $OUT"
assert_has "A18 says the reading is unknown" "behind=unknown" "$OUT"
assert_not_has "A18 never publishes an unrefreshed ref as a measurement" "behind=0" "$OUT"
assert_not_has "A18 does not refuse on a number it did not measure" "why=stale-code" "$OUT"

# A19 — nothing to measure is REPORTED, never refused (the CI/dev path every other arm here takes).
make_stub "$WORK/a19" answer; make_keys "$WORK/a19"; mkdir -p "$WORK/a19/home"
run_gate_cell "$WORK/a19" 20 CELL_PREFLIGHT_REPO="$WORK/a19/no-such-checkout" CELL_PREFLIGHT_MAX_BEHIND=2
[ "$RC" -eq 0 ] && ok "A19 a box with no checkout to measure is still READY (exit 0)" \
                || bad "A19 expected exit 0, got $RC: $OUT"
assert_has "A19 says there was no repo" "repo=none" "$OUT"
assert_has "A19 says the reading is unknown" "behind=unknown" "$OUT"

# A20 — a non-numeric threshold is a MISCONFIGURATION, not a silent `ok`. `[ "$n" -gt "abc" ]` returns
# FALSE, so an unvalidated bound is an inert enforcer: the staleness refusal could never fire again.
OUT="$(CELL_PREFLIGHT_MAX_BEHIND=lots bash "$TARGET" --quiet --bound 5 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "A20 a non-numeric CELL_PREFLIGHT_MAX_BEHIND exits 2" || bad "A20 expected exit 2, got $RC: $OUT"
assert_has "A20 ...naming the variable it rejected" "CELL_PREFLIGHT_MAX_BEHIND" "$OUT"
assert_not_has "A20 ...instead of reading ok on an unappliable bound" "LANE_CAPABILITY=ok" "$OUT"

# ── A21–A25: THE DEFAULT RESOLUTION, THE CELL LAYOUT, `HOME`, AND A NAMED CHECKOUT ───────────────
# ⛔ THE ARMS ABOVE ALL NAME THE CHECKOUT, so none of them could see that the DEFAULT resolved nothing
# on the boxes the reading was measured on (this change's review, P1-1). Every arm below is RED on the
# pre-fix code, and the mutation list says which edit makes which one red.

# A21 — the checkout the probe is RUNNING IN is the base a lane will build on, and it is measured with
# NOTHING named in the environment.
make_stub "$WORK/a21" answer; make_keys "$WORK/a21"
mk_repo "$WORK/a21" 0 || bad "A21 fixture: could not build a git repo"
run_gate_in "$WORK/a21/repo" "$WORK/a21" 20 CELL_PREFLIGHT_MAX_BEHIND=2
[ "$RC" -eq 0 ] && ok "A21 a current checkout at \$PWD is READY with nothing named in the env" \
                || bad "A21 expected exit 0, got $RC: $OUT"
assert_has "A21 the default resolution FOUND the checkout the lane will build on" "repo=repo" "$OUT"
assert_has "A21 ...and measured it" "behind=0" "$OUT"

# A22 — the CELL layout, which is the one that matters: `HOME=/tmp/cell-home` holds no checkout and the
# tortoise/agent-infra checkouts are `/tmp/cell-t3` and `/tmp/cell-ai` (docs/ops/disk-consumers.md),
# resolved by `cell-install.sh` / `ci_runner_fleet.sh` through `${CELL_HOME}`. The probe runs from a
# NEUTRAL cwd, so the cell path is the only way it can find this checkout.
# ⛔ AND THE ARM IS HERMETIC NOW, WHICH IS WHY `${CELL_HOME}/agent-infra` OUTRANKS THE `/tmp/cell-*`
# LITERALS in `resolve_repo` (this change's review, P2-3, measured). With the literals first, this arm
# resolved the LIVE `/tmp/cell-ai` on a cell — red for a value that is CORRECT there, and `git fetch`-ing
# a production checkout from inside a suite. The fixture below can now only be beaten by `$PWD` (which
# holds no `.git` here), so the arm proves the cell-layout candidate while being provably unable to reach
# a live path on any host.
make_stub "$WORK/a22" answer; make_keys "$WORK/a22"
mk_repo "$WORK/a22/src" 0 || bad "A22 fixture: could not build a git repo"
mkdir -p "$WORK/a22/cellhome"
cp -a "$WORK/a22/src/repo" "$WORK/a22/cellhome/agent-infra" || bad "A22 fixture: could not place the cell checkout"
run_gate_in "$WORK/a22" "$WORK/a22" 20 CELL_HOME="$WORK/a22/cellhome" CELL_PREFLIGHT_MAX_BEHIND=2
[ "$RC" -eq 0 ] && ok "A22 the cell layout (\$CELL_HOME/agent-infra, HOME has no checkout) is MEASURED" \
                || bad "A22 expected exit 0, got $RC: $OUT"
assert_has "A22 ...the cell path is in the default candidate list" "repo=agent-infra" "$OUT"
assert_has "A22 ...and carries its distance" "behind=0" "$OUT"
assert_not_has "A22 ...and it never falls through to a hard-coded /tmp/cell-* literal (a live production checkout on a cell)" "repo=cell-ai" "$OUT"

# A23 — `HOME` UNSET: the reading must still be ON THE LINE. Pre-fix the bare `$HOME/tortoise` aborted
# under `set -u` inside `$( )`, so `FRESHNESS` came back EMPTY and the `ok` line carried no `repo=` and
# no `behind=` at all — the readiness field disappeared rather than saying `unknown`, against this
# file's own contract that the output is one line and always carries what it read.
# ⛔ IT NO LONGER ASSERTS `repo=none`, BECAUSE THAT ASSERTION WAS ABOUT THE HOST, NOT ABOUT `$HOME` (this
# change's review, P2-3, measured). With `HOME` unset and nothing named, the DEFAULT LIST is walked — and
# on a cell that list reaches the LIVE `/tmp/cell-ai`, so the arm read `repo=cell-ai` (red for a correct
# value) while `git fetch`-ing a production checkout. The fixture below names, through `CELL_HOME`, a
# checkout this arm OWNS and that has no `origin` (so the fetch cannot reach anything and the distance is
# honestly `unknown`); `CELL_HOME` outranks the `/tmp/cell-*` literals, so no live path is reachable here.
# ⛔ AND IT STILL CARRIES THE BARE-`$HOME` MUTATION: a `for cand in … "$HOME/x"` word list is expanded
# BEFORE the first iteration, so putting the abort back reddens this arm (the field vanishes) no matter
# which candidate would have won — the mutation is not weakened by giving the arm a fixture.
make_stub "$WORK/a23" answer; make_keys "$WORK/a23"
mk_repo "$WORK/a23/src" 0 || bad "A23 fixture: could not build a git repo"
g -C "$WORK/a23/src/repo" remote remove origin || bad "A23 fixture: could not drop the remote"
mkdir -p "$WORK/a23/cellhome"
cp -a "$WORK/a23/src/repo" "$WORK/a23/cellhome/agent-infra" || bad "A23 fixture: could not place the cell checkout"
OUT="$( cd "$WORK/a23" && env -u HOME -u DEEPSEEK_API_KEY -u CELL_HOME -u LANE_PREFLIGHT_KEYS \
        -u CELL_PREFLIGHT_REPO -u CELL_PREFLIGHT_MAX_BEHIND -u CELL_PREFLIGHT_FETCH_BOUND \
        CELL_HOME="$WORK/a23/cellhome" \
        PATH="$WORK/a23/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$TARGET" --keys "$WORK/a23/keys.env" --quiet --bound 20 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "A23 a box with no \$HOME is still measurable (exit 0)" || bad "A23 expected exit 0, got $RC: $OUT"
assert_has "A23 ...and the readiness field is STILL on the line (it used to vanish)" "behind=" "$OUT"
assert_has "A23 ...naming the checkout it resolved, rather than reporting nothing at all" "repo=agent-infra" "$OUT"
assert_not_has "A23 ...and it never reaches a hard-coded /tmp/cell-* literal (a live production checkout on a cell)" "repo=cell-ai" "$OUT"

# A24 — `--repo` names the checkout (the caller already knows it), and a NAME THAT IS NOT A CHECKOUT IS
# REPORTED. The second half is the one a guess would hide: `$PWD` here IS a valid checkout, so a
# resolution that fell through to it would answer a question nobody asked.
make_stub "$WORK/a24" answer; make_keys "$WORK/a24"
mk_repo "$WORK/a24" 3 || bad "A24 fixture: could not build a git repo"
OUT="$( cd "$WORK/a24" && env -u DEEPSEEK_API_KEY -u CELL_HOME -u LANE_PREFLIGHT_KEYS -u CELL_PREFLIGHT_REPO \
        PATH="$WORK/a24/bin:$PATH" HOME="$WORK/a24/home" CELL_PREFLIGHT_MAX_BEHIND=2 \
        bash "$TARGET" --keys "$WORK/a24/keys.env" --repo "$WORK/a24/repo" --bound 20 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "A24 --repo names the checkout, and a stale one REFUSES (exit 3)" || bad "A24 expected exit 3, got $RC: $OUT"
assert_has "A24 ...carrying the distance from the named checkout" "behind=3" "$OUT"
OUT="$( cd "$WORK/a24/repo" && env -u DEEPSEEK_API_KEY -u CELL_HOME -u LANE_PREFLIGHT_KEYS -u CELL_PREFLIGHT_REPO \
        PATH="$WORK/a24/bin:$PATH" HOME="$WORK/a24/home" CELL_PREFLIGHT_MAX_BEHIND=2 \
        bash "$TARGET" --keys "$WORK/a24/keys.env" --repo "$WORK/a24/no-such-checkout" --quiet --bound 20 2>&1)"; RC=$?
assert_has "A24b a NAMED path that is not a checkout is REPORTED as such" "reason=not-a-checkout" "$OUT"
assert_not_has "A24b ...and is never silently replaced by \$PWD, which here IS a valid checkout" "repo=repo" "$OUT"

# A25 — THE FETCH'S DESTINATION IS EXPLICIT, AND THAT IS NOT REDUNDANT. `git fetch origin main` refreshes
# `refs/remotes/origin/main` only by git's OPPORTUNISTIC UPDATE, which requires a configured
# `remote.origin.fetch` mapping `main`. A checkout without one takes the fetch, exits 0, leaves
# `origin/main` at the clone's stale value — and the gate then prints a count it never measured. Built
# here exactly that way, so the arm is RED on a plain `git fetch origin main` (measured: it read
# `behind=0` on a checkout that was 3 commits behind).
make_stub "$WORK/a25" answer; make_keys "$WORK/a25"
mk_repo "$WORK/a25" 3 || bad "A25 fixture: could not build a git repo"
if g -C "$WORK/a25/repo" config --unset-all remote.origin.fetch >/dev/null 2>&1; then :; else bad "A25 fixture: could not unset remote.origin.fetch"; fi
run_gate_cell "$WORK/a25" 20 CELL_PREFLIGHT_REPO="$WORK/a25/repo" CELL_PREFLIGHT_MAX_BEHIND=2
[ "$RC" -eq 3 ] && ok "A25 a checkout with NO fetch refspec is still MEASURED (exit 3 on a stale one)" \
                || bad "A25 expected exit 3, got $RC: $OUT"
assert_has "A25 ...the explicit destination refreshed origin/main, so the distance is real" "behind=3" "$OUT"
assert_not_has "A25 ...never publishes the stale ref's 0 as a measurement" "behind=0" "$OUT"

printf '\ncell-lane-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
