#!/usr/bin/env bash
# lane-outcome.test.sh — EVERY LANE LOG ENDS BY SAYING WHAT HAPPENED (agent-infra#3331).
#
# THE MEASURED DEFECT. Two lanes were dispatched to cloud cells on 2026-11-02 and both vanished. Neither
# log carried an error; each simply STOPPED —
#
#     [venv-reap] lane 3121: no .venv in /tmp/wt-3121 — nothing to reap
#     [reflect-hook] Skipped — empty session
#
# — while the dispatcher's record still said "launched", because `nohup … &` had returned. The cause was
# three lines up, buried: `No API key found for the selected model.` A print-mode `pi` BUFFERS, so a log
# that ends silently is indistinguishable from a lane that is still working, and `pgrep -f "pi -p"`
# matched the diagnostic's own command line on top of it. Three false-positive signals over one event.
#
# THE CONTRACT THIS SUITE PINS — the LAST line of `$O/logs/lane-<N>.log` is
#
#     outcome=<done|refused|failed|died> reason=<token> lane=<N> rc=<status> utc=<stamp>
#
# exactly once, on EVERY exit path, and the refusal that started this issue carries its OWN status
# (82) rather than borrowing 72/75/80 (three different remedies).
#
# ⛔ EVERY ARM DRIVES THE SHIPPED `lane.sh` — not a copy of its logic, and not a grep of its source. A
# source-shape assertion passes on a script whose RUNTIME output lost the text, which is the
# "test that cannot fail" class. `pi` is stubbed with an exported FUNCTION (a PATH stub loses to
# lane.sh's own `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, which was measured resolving the
# machine's REAL pi and running a live agent for 98 s).
#
# ⛔ AND THE SUITE REDDENS ON THE PRE-CHANGE TREE: with no terminal line written, every `outcome=` arm
# below fails on `grep -c` returning 0 (`grep -L '^outcome='` then lists the log) — while the rest of
# each arm still passes, which is exactly the silence being fixed.
#
# Run:  bash lane-outcome.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE="$HERE/lane.sh"
[ -r "$LANE" ] || { echo "FATAL: lane.sh not found beside this test ($LANE)" >&2; exit 2; }
REAL_GIT="$(command -v git)" || { echo "FATAL: git is required" >&2; exit 2; }
T="$(mktemp -d "${TMPDIR:-/tmp}/lane-outcome-test.XXXXXX")" || { echo "FATAL: no temp dir" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }
eqv() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac; }
hasnt(){ case "$1" in *"$2"*) bad "$3 (unexpected: $2)" ;; *) ok "$3" ;; esac; }

SLUG="daniel-ospina/agent-infra"
BR="feat/3331-tm"
# ⛔ THE CREDENTIAL CANARY IS NOT CREDENTIAL-SHAPED ON PURPOSE: the harness redacts values bound to
# secret-looking names, and an arm asserting on `[REDACTED-SECRET…]` measures the redactor, not the lane.
KEYVAR="LANE_OUTCOME_CANARY_KEY"

# ── one fixture per arm: a repo whose origin names the target, a worktree on $BR, a bag of $O with the
# answering gh adapter the creation gate reads (#2409), and a HOME whose models.json names the canary.
mk_arm() { # <name> -> sets ARMDIR and ARMWT (the worktree)
  # ⛔ IT SETS GLOBALS INSTEAD OF PRINTING: the arms below need the $O bag as well as the worktree, and
  # `WT="$(mk_arm x)"` runs in a SUBSHELL, so a printed path plus a stranded ARMDIR reads as an unbound
  # variable one line later (measured on this suite's first draft).
  local n="$1" d="$T/$1"
  mkdir -p "$d/o/logs" "$d/o/state" "$d/o/gh-rest" "$d/home/.pi/agent"
  cat > "$d/o/gh-rest/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'pulls?state=open'*)   printf '0\n' ;;
  *'pulls?state=closed'*) : ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$d/o/gh-rest/gh"
  printf '{"providers":{"deepseek":{"apiKey":"$%s","models":[{"id":"m"}]}}}\n' "$KEYVAR" \
    > "$d/home/.pi/agent/models.json"
  "$REAL_GIT" init -q -b main "$d/repo"
  "$REAL_GIT" -C "$d/repo" config user.email t@t
  "$REAL_GIT" -C "$d/repo" config user.name t
  printf 'base\n' > "$d/repo/base.txt"
  "$REAL_GIT" -C "$d/repo" add -A
  "$REAL_GIT" -C "$d/repo" commit -qm init
  "$REAL_GIT" -C "$d/repo" remote add origin "https://github.com/$SLUG.git"
  "$REAL_GIT" -C "$d/repo" worktree add -q "$d/repo/.worktrees/tm-3331" -b "$BR" main
  ARMDIR="$d"
  ARMWT="$d/repo/.worktrees/tm-3331"
}

# drive <worktree> [<VAR>=<value> …] — run the SHIPPED lane.sh in that worktree; echoes nothing, sets
# LANE_RC. `pi` must already be exported by the caller. `TARGET_SLUG` overrides the repo the lane is told
# to work on (arm 7d uses a WRONG one on purpose, to reach a refusal with a dry run).
drive() {
  local wt="$1"; shift
  ( cd "$wt" && env -u "$KEYVAR" O="$ARMDIR/o" HOME="$ARMDIR/home" \
      REAP_LANE_VENV_DISABLE=1 LANE_PREFLIGHT=0 \
      MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$ARMDIR" "$@" \
      bash "$LANE" 3331 "$BR" "${TARGET_SLUG:-$SLUG}" ) > "$ARMDIR/out.txt" 2>&1
  LANE_RC=$?
}
# drive_bg <worktree> — the same, in the background, so a signal can reach the LANE process.
drive_bg() {
  local wt="$1"; shift
  ( cd "$wt" && exec env -u "$KEYVAR" O="$ARMDIR/o" HOME="$ARMDIR/home" \
      REAP_LANE_VENV_DISABLE=1 LANE_PREFLIGHT=0 \
      MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$ARMDIR" "$@" \
      bash "$LANE" 3331 "$BR" "${TARGET_SLUG:-$SLUG}" ) > "$ARMDIR/out.txt" 2>&1 &
  LANE_PID=$!
}
LOG() { printf '%s\n' "$ARMDIR/o/logs/lane-3331.log"; }
lastline() { tail -n 1 "$(LOG)" 2>/dev/null; }

# ── the outcome vocabulary, read off the ARTIFACT: exactly one terminal line, last in the log ─────
check_terminal() { # <arm-label> <expected-outcome> <expected-reason-prefix> [<expected-rc>]
  local lab="$1" want="$2" wantwhy="$3" wantrc="${4:-}" log n last
  log="$(LOG)"
  n="$(grep -c '^outcome=' "$log" 2>/dev/null || true)"
  eqv "${n:-0}" "1" "$lab: the log carries EXACTLY ONE terminal line (a log with none is the defect; two means the writer is not idempotent)"
  last="$(lastline)"
  case "$last" in
    outcome=*" reason="*) ok "$lab: the LAST line of the log is the terminal line — nothing can append after it" ;;
    *) bad "$lab: the last line is not the terminal line (got: '$last')" ;;
  esac
  case "$last" in
    "outcome=$want "*) ok "$lab: outcome=$want (got: '$last')" ;;
    *) bad "$lab: expected outcome=$want, got: '$last'" ;;
  esac
  has "$last" "reason=$wantwhy" "$lab: the reason names the cause ('$wantwhy'), not just the outcome"
  # ⛔ `rc=` IS ASSERTED, NOT DECORATION (review P1). The field exists so a reader can tell a clean end
  # from a kill, and the one arm where the two disagree is the one where it matters most: the signal
  # handler clears the EXIT trap, so it must record the status ITSELF or the line reports the
  # initialiser (`rc=0` beside `outcome=died` on a lane that exited 143). Without this assertion the
  # whole suite stayed green on exactly that defect.
  if [ -n "$wantrc" ]; then
    has "$last" "rc=$wantrc" "$lab: rc= reports the status the process actually exited with ($wantrc)"
  fi
  # ⛔ THE VOCABULARY IS CLOSED. A writer that invents a fifth word records nothing an instrument can
  # count, so the four are pinned here rather than trusted.
  case "$last" in
    outcome=done\ *|outcome=refused\ *|outcome=failed\ *|outcome=died\ *) ok "$lab: the outcome is one of the four contract words" ;;
    *) bad "$lab: outcome is outside the closed vocabulary: '$last'" ;;
  esac
}

echo "==> lane-outcome self-test ($LANE)"

# ═══ 1. A LANE WITH NO MODEL CREDENTIAL REFUSES AND SAYS SO (the measured death) ══════════════════
mk_arm refused; WT="$ARMWT"
PI_MARK="$ARMDIR/pi-ran"; export PI_MARK
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi 2>/dev/null || true
drive "$WT"
eqv "$LANE_RC" "82" "1a a lane whose \$HOME models.json names a variable the environment does not hold exits 82 — the key gate's OWN code, not 72/75/80"
has "$(cat "$(LOG)" 2>/dev/null)" "[key-gate] lane 3331 check=fail result=REFUSED reason=credential-missing var=$KEYVAR" \
    "1b the log names the missing variable and where the name came from"
[ ! -s "$PI_MARK" ]; ck "1c pi was NEVER spawned — the refusal is BEFORE the agent, so no model call was spent" $?
check_terminal "1d" refused "key-gate:credential-missing:$KEYVAR" 82
# ⛔ THE REFUSAL YIELDS THE ITEM (review round 3, P2). `chain-merge.sh`'s ONLY early bail-out reads
# `state/capacity-refused-<N>`, and the key gate refuses 270 lines BEFORE the arm that writes it — so
# without this record the chain waits its full 90 minutes holding `refs/claims/issue-<N>` for a PR that
# cannot appear, and every peer's pre-flight reads COLLISION (the R8 defect the record exists to
# remove). `capability` writes one for the same reason: the credential is a property of THIS box.
KGREC="$ARMDIR/o/state/capacity-refused-3331"
[ -s "$KGREC" ]; ck "1d1 a key refusal writes state/capacity-refused-<N> (else chain-merge waits 90 min on a claim a peer must see released)" $?
KG_GATE=""; _kgep=""; _kguntil=""
[ -s "$KGREC" ] && read -r _kgep _kguntil KG_GATE < "$KGREC" 2>/dev/null
i=""; case "${_kgep:-}" in ''|*[!0-9]*) : ;; *) [ "${_kguntil:-0}" -gt "${_kgep:-0}" ] && i=ok ;; esac
eqv "$i" "ok" "1d2 …with a coherent epoch/yield pair ('${_kgep:-<none>}' -> '${_kguntil:-<none>}')"
eqv "${KG_GATE:-<none>}" "key" "1d3 …and field 3 names the KEY gate (an unnamed gate is folded to 'load' by every reader, the #2991 defect)"

# ── 1z: A STORED CREDENTIAL IS NOT A MISSING ONE (review round 3, P1) ────────────────────────────
# `pi` consults `auth.json` (what `pi /login` writes) BEFORE the environment, so a provider logged in
# that way runs with the variable unset. A gate that refused on the variable alone refused a lane that
# WOULD have worked — on a supported configuration — so this arm drives it end to end: same fixture, same
# absent variable, one stored credential added, and the lane must RUN.
mk_arm storedcred; WT="$ARMWT"
printf '{"deepseek":{"type":"api_key","key":"sk_stored_fixture"}}\n' > "$ARMDIR/home/.pi/agent/auth.json"
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi
: > "$PI_MARK"
drive "$WT"
eqv "$LANE_RC" "0" "1z a lane whose provider is logged in (auth.json, no env variable) RUNS — the gate does not refuse a working box"
[ -s "$PI_MARK" ]; ck "1z2 …and the agent really started" $?
has "$(cat "$(LOG)" 2>/dev/null)" "check=skipped reason=stored-credential" \
    "1z3 …because the gate says WHICH source answered, instead of passing silently"
check_terminal "1z4" done "agent-exit-0" 0
[ ! -s "$ARMDIR/o/state/capacity-refused-3331" ]; ck "1z5 …and no stand-down record is written for a lane that ran" $?
# ⛔ THE WHOLE POINT: THE REFUSAL MUST NOT READ AS "STILL WORKING". A pre-change log for this arm ended
# on a cleanup line with the cause buried above it — the shape that was read as a live lane for hours.
hasnt "$(lastline)" "[venv-reap]" "1e the log does NOT end on a cleanup/reap line (the shape mistaken for a working lane)"
hasnt "$(lastline)" "[wip]" "1f …nor on the wip-rescue line"

# ═══ 2. A LANE WHOSE AGENT RUNS AND RETURNS 0 ═══════════════════════════════════════════════════════
mk_arm done; WT="$ARMWT"
: > "$PI_MARK"
drive "$WT" "$KEYVAR=sk_fixture"
eqv "$LANE_RC" "0" "2a the lane exits 0"
[ -s "$PI_MARK" ]; ck "2b the agent DID run (the gate passes what it cannot object to, and pi was spawned)" $?
check_terminal "2c" done "agent-exit-0" 0
# ⛔ THE PER-RUN VERDICT (review round 4, P2, measured). The lane LOG is append-only, so a re-dispatched
# issue keeps the previous attempt's `outcome=` line and `tail -1` on the log can hand a reader that
# earlier verdict while the current run is still working. The per-run sibling is what a liveness read must
# use: it is written by the same trap and REMOVED at the next dispatch, so its ABSENCE — not a stale line —
# is "no verdict yet". Both halves are asserted here.
RUNOUT="$ARMDIR/o/logs/lane-3331.outcome"
[ -s "$RUNOUT" ]; ck "2d the run-scoped verdict file exists (logs/lane-<N>.outcome)" $?
eqv "$(cat "$RUNOUT" 2>/dev/null)" "$(lastline)" "2e …and carries the SAME line the log ends on"
printf 'outcome=failed reason=STALE-PREVIOUS-RUN lane=3331 rc=9 utc=1999-01-01T00:00:00Z\n' > "$RUNOUT"
drive "$WT" LANE_DRY_RUN=1
has "$(cat "$RUNOUT" 2>/dev/null)" "reason=dry-run" "2f a re-dispatch OVERWRITES it — a pre-seeded previous-run verdict is gone, so no reader can act on it"
hasnt "$(cat "$RUNOUT" 2>/dev/null)" "STALE-PREVIOUS-RUN" "2g …and the stale line does not survive anywhere in the run-scoped read"
# …while the LOG legitimately keeps both runs (it is the transcript, and truncating it would destroy the
# previous attempt's record) — the per-run file is what makes the two compatible.
[ "$(grep -c '^outcome=' "$(LOG)" 2>/dev/null || true)" -ge 2 ]; ck "2h the append-only LOG keeps both runs (the run-scoped file is the answer to 'which one is now')" $?

# ═══ 3. A LANE WHOSE AGENT FAILS ════════════════════════════════════════════════════════════════════
mk_arm failed; WT="$ARMWT"
pi() { printf 'No API key found for the selected model.\n'; return 3; }
export -f pi
drive "$WT" "$KEYVAR=sk_fixture"
eqv "$LANE_RC" "3" "3a the lane exits with the agent's status (3)"
check_terminal "3b" failed "agent-exit-3" 3

# ═══ 4. A LANE THAT IS KILLED ═══════════════════════════════════════════════════════════════════════
# The signal handlers clear the EXIT trap, so nothing else will write the line: `died` is the record
# that the lane did not END, it was ENDED — the fact a log that just stops cannot carry.
mk_arm died; WT="$ARMWT"
# ⛔ THE STUB SLEEPS IN THE FOREGROUND AND IS **NOT** KILLED BY THE TEST. A shell-function stub's own
# bash job notice ("Terminated: 15 sleep …") is written to the log by the surviving subshell, so an arm
# that pkill'd it would be measuring bash's notice rather than the lane's last word.
pi() { sleep 5; return 0; }
export -f pi
drive_bg "$WT" "$KEYVAR=sk_fixture"
i=0
while [ "$i" -lt 200 ]; do
  grep -q '\[agent\] provider=' "$(LOG)" 2>/dev/null && break
  kill -0 "$LANE_PID" 2>/dev/null || break
  i=$((i + 1)); sleep 0.1
done
kill -TERM "$LANE_PID" 2>/dev/null
wait "$LANE_PID" 2>/dev/null; LANE_RC=$?
eqv "$LANE_RC" "143" "4a a TERMed lane exits by the signal's status (143)"
check_terminal "4b" died "signal:TERM" 143

# ═══ 5. A LANE THAT NEVER GOT AS FAR AS AN OUTCOME ══════════════════════════════════════════════════# The half-synced-`$O` shape: lane.sh is present and its libraries are not. It refuses with 78 — which is
# NOT a gate refusal — and the terminal line must still appear, naming the exit. Without this, the
# exits that happen BEFORE any gate are exactly the ones that leave a silently truncated log.
STRIPPED="$T/stripped"; mkdir -p "$STRIPPED/O/logs"
cp "$LANE" "$STRIPPED/lane.sh"
( cd "$T" && O="$STRIPPED/O" bash "$STRIPPED/lane.sh" 3331 "$BR" "$SLUG" ) > "$STRIPPED/out.txt" 2>&1
SRC=$?
eqv "$SRC" "78" "5a a lane whose libraries are missing refuses with 78 (cannot run)"
SLOG="$STRIPPED/O/logs/lane-3331.log"
eqv "$(grep -c '^outcome=' "$SLOG" 2>/dev/null || true)" "1" "5b …and STILL writes exactly one terminal line"
has "$(tail -n 1 "$SLOG" 2>/dev/null)" "outcome=died reason=no-outcome-recorded:exit-78" \
    "5c …which reports an outcome of died, because nothing recorded one and nothing ran — never a silent end"

# ═══ 6. A CAPACITY REFUSAL IS NAMED, NOT LUMPED ════════════════════════════════════════════════════
# `outcome=refused` alone would repeat the defect the line exists to remove: load (75), disk (77) and
# fork (73) have mutually exclusive remedies (#1765, #2293), so the reason names the gate.
mk_arm loadref; WT="$ARMWT"
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi
drive "$WT" "$KEYVAR=sk_fixture" MAX_LOAD=0
eqv "$LANE_RC" "75" "6a a load refusal still exits 75"
check_terminal "6b" refused "load-gate" 75

# ── 6c: A GATE THAT COULD NOT RUN IS NOT A REFUSAL (review round 4, P2, measured) ────────────────
# The gate writes its output to a file in `$O/state`, and the FIRST cut put that redirect inside the refusal
# decision: on a read-only `$O` bash never ran the function, status was 1, and the lane announced a MISSING
# MODEL CREDENTIAL with `var=?` and a credential remedy — for a disk condition the DISK gate (77) exists to
# name, 200 lines LATER. The file is now created first and anything that is not exactly the gate's own
# refusal status is reported as the gate being UNABLE TO RUN.
if [ "$(id -u)" != "0" ]; then
  mk_arm gatenotrun; WT="$ARMWT"
  pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
  export -f pi
  chmod 500 "$ARMDIR/o/state"
  drive "$WT" "$KEYVAR=sk_fixture"
  chmod 700 "$ARMDIR/o/state" 2>/dev/null || true
  eqv "$LANE_RC" "78" "6c an UNWRITABLE \$O/state reports the gate as unable to run (78), not as a credential refusal"
  has "$(lastline)" "outcome=died reason=key-gate-not-run" "6d …and its outcome says the gate did not run"
  hasnt "$(cat "$(LOG)" 2>/dev/null)" "holds no value in the environment" "6e …and it does NOT claim the credential is missing (the credential was PRESENT here)"
  [ ! -s "$ARMDIR/o/state/capacity-refused-3331" ]; ck "6f …and nothing is yielded, because nothing was measured" $?
else
  bad "6c the unwritable-\$O arm cannot run as root (chmod does not block root) — the check is skipped, not passed"
fi

# ═══ 7. THE DRY RUN (the CLEANUP is disarmed; the line is STILL written by the EXIT trap — see 7d) ═════════════
mk_arm dryrun; WT="$ARMWT"
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi
: > "$PI_MARK"
drive "$WT" LANE_DRY_RUN=1
eqv "$LANE_RC" "0" "7a a dry run exits 0"
[ ! -s "$PI_MARK" ]; ck "7b …and starts no agent" $?
check_terminal "7c" done "dry-run" 0

# ── 7d: A DRY RUN THAT REFUSES STILL SAYS SO (review P2 — this arm is why the fix exists) ────────
# The pre-review shape CLEARED all four traps under LANE_DRY_RUN, so every exit between that line and
# the dry-run seam wrote NO terminal line — and that window contains the repo-target refusals (72) and
# seven `78` harness refusals, i.e. exactly the half-synced-`$O` shapes a dry run is used to debug. The
# fix disables the CLEANUP, never the traps. This arm reaches a refusal WITH a dry run (a target the
# worktree's origin does not name) and requires the line.
mk_arm dryrefuse; WT="$ARMWT"
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi
: > "$PI_MARK"
TARGET_SLUG="acme/widget" drive "$WT" LANE_DRY_RUN=1
ebv="$(cat "$(LOG)" 2>/dev/null | tail -3)"
case "$ebv" in
  *'repo-target REFUSED'*) ok "7d a dry run whose target is wrong is REFUSED by the identity gate (the arm's premise holds)" ;;
  *) bad "7d the dry-run refusal did not happen, so the arm measured nothing (tail: $ebv)" ;;
esac
eqv "$LANE_RC" "72" "7e …and exits 72"
check_terminal "7f" refused "repo-target:REFUSED" 72
[ ! -s "$PI_MARK" ]; ck "7g …and no agent was started" $?
unset TARGET_SLUG

# ═══ 8. THE VOCABULARY IS ONE SOURCE OF TRUTH ═══════════════════════════════════════════════════
# A scanner's whole job is `grep -L '^outcome=' "$O"/logs/lane-[0-9]*.log`; this arm asserts the words it
# can ever see are the ones the contract declares, so a fifth cannot be introduced without reddening.
# ⛔ IT PINS THE WRITER'S CASE ARM, NOT A COMMENT (review round 3, P2, measured). The first cut grepped
# the whole file for the literal `done|refused|failed|died`, which is BRE (so `|` is a plain character) and
# matched the HEADER COMMENT — adding a fifth word to `lane_outcome`'s `case` left all 65 assertions
# green, i.e. the arm asserted a doc line while claiming the vocabulary. Extracted from the FUNCTION
# BODY, an added word changes the pattern and reddens this.
W_BODY="$(awk '/^lane_outcome\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$LANE")"
case "$W_BODY" in
  *'done|refused|failed|died)'*) ok "8 the writer's closed vocabulary is declared in ONE place (done|refused|failed|died), read from lane_outcome's own case" ;;
  *) bad "8 lane_outcome's case does not declare exactly done|refused|failed|died — a fourth word was added or one was dropped" ;;
esac
# …and an OUT-OF-VOCABULARY word can never be written as a legitimate outcome: it becomes `failed` and
# says so, which is the other half of a closed vocabulary (a writer that accepts anything records
# nothing). Pinned on the body for the same reason as above.
case "$W_BODY" in
  *unmapped-outcome*) ok "8e an unmapped outcome word is reported as failed + unmapped-outcome (the vocabulary is closed, and a bad word is visible)" ;;
  *) bad "8e lane_outcome has no unmapped-outcome arm — a fifth word would be written as if it were an outcome" ;;
esac
FOUND="$(cat "$T"/*/o/logs/lane-3331.log "$STRIPPED"/O/logs/lane-3331.log 2>/dev/null \
         | sed -n 's/^outcome=\([a-z]*\) .*/\1/p' | sort -u | tr '\n' ' ')"
has " $FOUND" "done " "8a the arms produced a 'done' outcome"
has " $FOUND" "refused " "8b …a 'refused' outcome"
has " $FOUND" "failed " "8c …a 'failed' outcome"
has " $FOUND" "died " "8d …a 'died' outcome (all four are reachable, not just declared)"

echo
if [ "$FAIL" -gt 0 ]; then
  printf '❌ lane-outcome suite: %s passed, %s FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '✅ lane-outcome suite: all %s assertions passed\n' "$PASS"
