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

# ⛔ `ENV_FILE` IS PINNED TO A FIXTURE-OWNED (ABSENT) FILE, AND THAT IS NOT COSMETIC — IT IS WHAT MAKES
# THE SUITE HERMETIC IN THE FIRST PLACE. `lane.sh` dots `lane-env.sh`, which sources
# `${ENV_FILE:-$HOME/keys.env}`; `ENV_FILE` is exported by the CONTROLLER, so a suite run on a real box
# inherits the box's own `keys.env`. That file carries `PATH` and `HOME` (measured: 13 assignments, two
# of them those), so sourcing it AFTER `lane.sh:65` prepended `$O/gh-rest` **displaced the fixture's `gh`
# adapter** and returned the REAL repository's state to the creation gate (#2409).
# MEASURED 2026-11-04 while rebasing #3342 onto main: every arm below refused with
# `outcome=refused reason=land-backlog` because the gate read `41 open / 0.9 landings per hour` from the
# live repo — a number the fixture's own adapter answers as `0`. That is the false-RED/false-GREEN class
# this suite's `MAX_LOAD=999999` already exists to stop, one variable
# further up: **a fixture that inherits the runner's environment is green on an idle box and red on a busy
# one.** Pinning the seam (the same one `reviewer-preflight.test.sh` pins, "instead of depending on the
# box's") is the root fix; a `gh`-only stub would leave `HOME`/`OR`/`REPO`/`PATH` still inherited.
# ⛔ `PI_LANE_PROVIDER` / `PI_LANE_MODEL` ARE SCRUBBED FOR THE SAME REASON (review P2, measured 2026-11-04):
# the fleet exports them into every lane (`worker-terminal.sh` writes `export PI_LANE_PROVIDER=<prov>` into
# each pane), and `key-gate.sh` resolves the variable from `${PI_LANE_PROVIDER:-deepseek}`. The fixture's
# `models.json` names ONLY `deepseek`, so an ambient provider made the gate answer `check=skipped` and every
# key arm flip to `done` — green on a deepseek box, red on a zai one. `provider-credential.test.sh` already
# scrubs exactly these two for exactly this reason; this suite now does the same.
#
# drive <worktree> [<VAR>=<value> …] — run the SHIPPED lane.sh in that worktree; echoes nothing, sets
# LANE_RC. `pi` must already be exported by the caller. `TARGET_SLUG` overrides the repo the lane is told
# to work on (arm 7d uses a WRONG one on purpose, to reach a refusal with a dry run).
drive() {
  local wt="$1"; shift
  ( cd "$wt" && env -u "$KEYVAR" -u PI_LANE_PROVIDER -u PI_LANE_MODEL \
      O="$ARMDIR/o" HOME="$ARMDIR/home" ENV_FILE="$ARMDIR/home/keys.env" \
      REAP_LANE_VENV_DISABLE=1 LANE_PREFLIGHT=0 \
      MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$ARMDIR" "$@" \
      bash "$LANE" 3331 "$BR" "${TARGET_SLUG:-$SLUG}" ) > "$ARMDIR/out.txt" 2>&1
  LANE_RC=$?
}
# drivef <worktree> <extra LANE argv…> — the same, but passing ARGUMENTS. The key gate's escape is
# argv-only (`--key-gate-off`) precisely because an environment variable is inherited from the box: these
# arms have to prove BOTH that the flag works and that the variable does NOT.
drivef() {
  local wt="$1"; shift
  ( cd "$wt" && env -u "$KEYVAR" -u PI_LANE_PROVIDER -u PI_LANE_MODEL \
      O="$ARMDIR/o" HOME="$ARMDIR/home" ENV_FILE="$ARMDIR/home/keys.env" \
      REAP_LANE_VENV_DISABLE=1 LANE_PREFLIGHT=0 \
      MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$ARMDIR" \
      bash "$LANE" "$@" 3331 "$BR" "${TARGET_SLUG:-$SLUG}" ) > "$ARMDIR/out.txt" 2>&1
  LANE_RC=$?
}
# drive_bg <worktree> — the same, in the background, so a signal can reach the LANE process.
drive_bg() {
  local wt="$1"; shift
  ( cd "$wt" && exec env -u "$KEYVAR" -u PI_LANE_PROVIDER -u PI_LANE_MODEL \
      O="$ARMDIR/o" HOME="$ARMDIR/home" ENV_FILE="$ARMDIR/home/keys.env" \
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
# ⛔ AND THE LANE'S REMEDY PRINTS THE WORKING INVOCATION (round 10, P2, measured): #3443's item 1 is that the
# remedy is the MODEL FLAG, and only the BOX-DEFAULT refusal had an arm for it — deleting the clause from the
# `credential-missing` line left both suites green. This is the line a lane log carries, so it is the one an
# operator actually reads at 3am.
has "$(cat "$(LOG)" 2>/dev/null)" 'pi -p --no-session --provider deepseek --model deepseek-flash' \
    "1b2 …and the remedy gives the exact working invocation, not \"source keys.env\""
[ ! -s "$PI_MARK" ]; ck "1c pi was NEVER spawned — the refusal is BEFORE the agent, so no model call was spent" $?
check_terminal "1d" refused "key-gate:credential-missing:$KEYVAR" 82
# ⛔ AND THE TERMINAL TOKEN NAMES THE MODEL, NOT ONLY THE VARIABLE (agent-infra#3443). The failure this
# gate front-runs is named after the MODEL (`No API key found for the selected model.`), so a token
# carrying only `$VAR` sends an operator to a credential that may never have been the question — and this
# is the line a fleet scan greps, not the prose above it. The mutant (reverting the token to
# `key-gate:<reason>:<VAR>`) reddens 1d4/1d5 and nothing else (1d2/1d3 are the epoch/yield arms).
_kginfo="$(lastline | sed -n 's/.*reason=\(key-gate:[^ ]*\).*/\1/p')"
eqv "$(printf '%s' "$_kginfo" | awk -F: '{print NF}')" "4" \
    "1d4 the key-gate reason token carries FOUR fields — reason, variable AND the MODEL"
# ⛔ A LITERAL, NOT THE AMBIENT `$PI_LANE_MODEL` (review round 2, P3, measured): the lane subprocess is launched
# with `env -u PI_LANE_PROVIDER -u PI_LANE_MODEL`, so the token ALWAYS carries the built-in default — while an
# ambient `PI_LANE_MODEL` (which `README.md` tells operators to put in `keys.env`, and a controller session
# re-sources) made this arm fail on a correctly-behaving gate.
eqv "$(printf '%s' "$_kginfo" | awk -F: '{print $4}')" "deepseek-flash" \
    "1d5 …and the fourth is the model the gate asserted (the built-in default, since the lane runs env-scrubbed)"
# ⛔ lane.sh PASSES BOTH HALVES, AND THE CLAIM IS THE ONE THE ARM CAN ACTUALLY MAKE (round 11, P3, measured).
# The round-8 version said the pre-change 2-arg call "answers about venice here". After round 10's rule — the
# `provider/` prefix decides only for a model that was NAMED, never one inherited from `$PI_LANE_MODEL` — that
# became FALSE: both shapes resolve `deepseek`, the log text is byte-identical, and the arm could not distinguish
# any implementation (a surviving mutant dressed as a guard). So:
#   • the BEHAVIOURAL arm stays and keeps what it really proves — a prefixed ambient model is asserted against
#     the provider the lane will hand pi (`deepseek`), not the prefix;
#   • the CALL SHAPE is asserted statically, because no fixture can observe it: `lane.sh` sources the gate from
#     its own directory, so a stub cannot be injected, and the four-argument call is the fact that would regress.
#     This is a source check on purpose and says so — it reddens if lane.sh stops passing the resolved pair.
mk_arm pair; PI_MARK="$ARMDIR/pi-ran"; export PI_MARK
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi 2>/dev/null || true
drive "$ARMWT" PI_LANE_MODEL=venice/whatever
eqv "$LANE_RC" "82" "1e a prefixed PI_LANE_MODEL still refuses on the LANE's own provider, as pi would run it"
has "$(cat "$(LOG)" 2>/dev/null)" "[key-gate] lane 3331 check=fail result=REFUSED reason=credential-missing var=$KEYVAR provider=deepseek model=venice/whatever" \
    "1e2 …naming deepseek, the provider run_agent will hand pi, rather than the id's venice/ prefix"
[ ! -s "$PI_MARK" ]; ck "1e3 pi was never spawned" $?
# ⛔ SOURCE CHECK, DECLARED AS ONE. `lane.sh` must call the gate with the RESOLVED pair (four arguments); the
# pre-change 2-arg call is the regression this line exists to catch, and it is invisible at runtime.
_gkcall="$(grep -c 'key_gate_assert "lane \$N" "${HOME:-}" "${PI_LANE_PROVIDER:-deepseek}" "${PI_LANE_MODEL:-deepseek-flash}"' "$LANE" 2>/dev/null || true)"
eqv "${_gkcall:-0}" "1" \
    "1e4 lane.sh calls the gate with FOUR arguments — label, home, resolved provider, model — so the gate and the spawn cannot disagree"
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
# ⛔ THE REFUSAL MUST NOT READ AS "STILL WORKING", AND THESE TWO ARMS ARE THE SHAPES THAT DID. A pre-change
# log for exactly this lane ended on `[venv-reap] lane …: nothing to reap` — with the cause three lines
# above it — and was read as a live lane for hours. They are stated here, on the REFUSAL arm, because that
# is the arm whose log the comment is about (they used to sit on the stored-credential `done` arm, where a
# terminal `outcome=done` line made them unfalsifiable: a `done` log can never end on a cleanup line).
hasnt "$(lastline)" "[venv-reap]" "1e the REFUSAL log does NOT end on a cleanup/reap line (the shape mistaken for a working lane)"
hasnt "$(lastline)" "[wip]" "1f …nor on the wip-rescue line"

# ═══ 1f. A STORE VERDICT IS NOT A MISSING VARIABLE, AND THE TOKEN SAYS SO (round 22, P2, measured) ═══
# `lane.sh` writes `key-gate:${KEY_GATE_REASON:-credential-missing}:…`, so a `store-invalid` refusal that never
# sets the reason published `reason=key-gate:credential-missing:<VAR>:<MODEL>` — the exact misattribution this
# file's own header forbids — and its stand-down sentence told the operator to export the variable the refusal
# had just measured as NOT the problem (`export` does not rescue an entry pi cannot use: measured, pi answers
# `Provider is not configured` with the key exported).
mk_arm storeinvalid; WT="$ARMWT"
printf '{"deepseek":{"key":"sk_legacy_no_type"}}\n' > "$ARMDIR/home/.pi/agent/auth.json"
PI_MARK="$ARMDIR/pi-ran"; export PI_MARK
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi 2>/dev/null || true
drive "$WT"
check_terminal "1f" refused "key-gate:store-invalid" 82
eqv "$(printf '%s' "$(lastline | sed -n 's/.*reason=\(key-gate:[^ ]*\).*/\1/p')" | awk -F: '{print $2}')" \
    "store-invalid" \
    "1f2 the token's REASON is store-invalid, not the credential-missing default — a scan counts the real cause"
# ⛔ WIDENED IN ROUND 23, AFTER THE NARROW GREP WAS MEASURED AS A HOLE: 1f3 pinned the ONE phrase only the fixed
# capacity-transfer sentence contained, while the TWO lines that carry the refusal into the lane log and onto stderr
# still said "$VAR holds no value in the environment this lane would run with" — the prescription the gate refutes
# in the same log. A phrase-specific grep is an arm written to miss its own subject, so every prescription is named.
hasnt "$(cat "$(LOG)" 2>/dev/null)" "put the credential in the environment lanes run with" \
    "1f3 …and the stand-down sentence does NOT prescribe exporting a variable the refusal already ruled out"
hasnt "$(cat "$(LOG)" 2>/dev/null)" "holds no value in the environment this lane would run with" \
    "1f3b …nor do the NOT-started lines, which are the ones an operator reads in the lane log"
hasnt "$(cat "$(LOG)" 2>/dev/null)" "credential \$" \
    "1f3c …nor does any line call the credential MISSING for a verdict about the FILE"
# ⛔ SCOPED TO THE LANE'S OWN SENTENCE (round 28, P2, measured): a bare `has "$(cat LOG)" "auth.json"` is satisfied by
# the GATE's refusal line, which always names `${agent_dir}/auth.json` in the same log — so deleting the file from
# `lane.sh`'s remedy left every one of these arms GREEN. The lane's sentences are the only ones that carry the words
# `credential STORE`, so that is the text the assertion is about.
# ⛔ TWO SENTENCES CARRY `credential STORE` — the capacity-transfer stand-down and the `NOT started` line — and the old
# arm matched either, so deleting the file name from ONE of them left this suite green (round 29, P3, measured: the
# `NOT started` sentence de-named = 176/176 green). Each sentence is now pinned on its own.
has "$(grep -F 'NOT started: KEY gate refused' "$(LOG)" 2>/dev/null)" "auth.json" \
    "1f4 …the operator-facing NOT-started line names the FILE to repair (that sentence alone)"
has "$(grep -F 'capacity transfer' "$(LOG)" 2>/dev/null)" "auth.json" \
    "1f4b …and so does the capacity-transfer stand-down, pinned separately because a grep matching either cannot tell them apart"
# ⛔ AND NO REMEDY NAMES A VARIABLE THAT DOES NOT EXIST (round 25, P3, measured): on a box with NO models.json template
# the gate sets `KEY_GATE_VAR` to the literal `<none>`, and the store sentence below printed "exporting $<none>" — a
# shell token, inside an instruction the operator is meant to follow. The clause is now dropped when there is no name.
# (A REAL templateless fixture: with the fixture's own models.json present the sentence names a real variable, so the
# first cut of this arm was green for the wrong reason — it must be driven on the shape that PRODUCES `<none>`.)
mk_arm storenotemplate; WT="$ARMWT"
rm -f "$ARMDIR/home/.pi/agent/models.json"
printf '{"deepseek":{"key":"sk_legacy_no_type"}}\n' > "$ARMDIR/home/.pi/agent/auth.json"
PI_MARK="$ARMDIR/pi-ran"; export PI_MARK
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi 2>/dev/null || true
drive "$WT"
check_terminal "1h" refused "key-gate:store-invalid:<none>" 82
hasnt "$(cat "$(LOG)" 2>/dev/null)" 'exporting $<none>' \
    "1f5 …and no remedy tells an operator to export the sentinel $<none>, on the shape that produces it"
has "$(grep -F 'NOT started: KEY gate refused' "$(LOG)" 2>/dev/null)" "auth.json" \
    "1h2 …while the NOT-started sentence still names the file to repair"

# ⛔ AND THE NO-TEMPLATE CLAUSE IS A WHOLE SENTENCE (round 26, P3, measured): dropping only the export half left a
# dangling conjunction — "and neither a models.json template rescues that" — which also claims a template exists on the
# shape where none does. 1f5 rejects the SENTINEL but accepted the malformed sentence, so the grammar is pinned here.
hasnt "$(cat "$(LOG)" 2>/dev/null)" "and neither a models.json template rescues" \
    "1h3 …and the no-template branch is not a half "neither" clause"
has "$(cat "$(LOG)" 2>/dev/null)" "no models.json template applies here" \
    "1h4 …it names the shape out loud instead"
# ⛔ AND THE SECOND STORE REASON HAS ITS OWN ARM (round 24, P2, measured): `auth-store-unreadable` is a DIFFERENT arm
# of the gate (`key-gate.sh`'s rc 6), and the token/prose guards above were written for `store-invalid` only — deleting
# the `KEY_GATE_REASON="auth-store-unreadable"` assignment left BOTH suites fully green, because the gate's PRINTED
# line carries the reason as a literal while the lane token silently fell back to `credential-missing` and both prose
# lines took the `*` branch ("$VAR holds no value ... put the credential where this lane's own env sources it") — the
# misattribution rounds 22-23 removed for the other reason, restored by a one-line deletion.
mk_arm storeunreadable; WT="$ARMWT"
printf '{not json\n' > "$ARMDIR/home/.pi/agent/auth.json"
PI_MARK="$ARMDIR/pi-ran"; export PI_MARK
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi 2>/dev/null || true
drive "$WT"
check_terminal "1g" refused "key-gate:auth-store-unreadable" 82
eqv "$(printf '%s' "$(lastline | sed -n 's/.*reason=\(key-gate:[^ ]*\).*/\1/p')" | awk -F: '{print $2}')" \
    "auth-store-unreadable" \
    "1g2 the token carries the unreadable-STORE reason, not the credential-missing default"
hasnt "$(cat "$(LOG)" 2>/dev/null)" "holds no value in the environment this lane would run with" \
    "1g3 …and no line prescribes exporting the variable for a verdict about the FILE"
has "$(grep -F 'NOT started: KEY gate refused' "$(LOG)" 2>/dev/null)" "auth.json" \
    "1g4 …while the NOT-started sentence names auth.json, which is what has to be repaired"
[ ! -s "$PI_MARK" ]; ck "1g5 pi was never spawned for an unreadable store" $?
[ ! -s "$PI_MARK" ]; ck "1h5 pi was never spawned for a store verdict" $?

# ⛔ AND A JSON `null` STORE IS ITS OWN REFUSAL REASON (round 29, P3, measured): it PARSES and pi throws at read time
# (`Cannot read properties of null`), so the unreadable-store sentence — which says the file "does not PARSE" — sent the
# operator after a syntax error that is not there. The refusal is unchanged; the REASON and the remedy are its own, and
# the lane's prose must follow it instead of prescribing an export.
mk_arm storenullreason; WT="$ARMWT"
printf 'null\n' > "$ARMDIR/home/.pi/agent/auth.json"
PI_MARK="$ARMDIR/pi-ran"; export PI_MARK
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi 2>/dev/null || true
drive "$WT"
check_terminal "1i" refused "key-gate:auth-store-null" 82
hasnt "$(cat "$(LOG)" 2>/dev/null)" "holds no value in the environment this lane would run with" \
    "1i3 …and no line prescribes exporting a variable for a document pi cannot index"
[ ! -s "$PI_MARK" ]; ck "1i4 pi was never spawned for a null store" $?

# ── 1y: THE ESCAPE IS ARGV, AND THE ENVIRONMENT ROUTE IS RETIRED (review, P1, measured) ─────────
# ⛔ THE HEAD COMMIT'S WHOLE CLAIM, WHICH HAD NO ASSERTION (review, P1: deleting the guard left all three
# suites green). The escape used to be `LANE_KEY_GATE=0` read from the environment. Fencing it against the
# box's `keys.env` cannot work by saving/restoring the caller's value, because on a cell the controller
# sourced that file itself under `set -a` — the box's value and the "caller's" value are the same inherited
# string. So the switch is argv-only, and all three directions are pinned below.
mk_arm escapeenv; WT="$ARMWT"
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi
: > "$PI_MARK"
drive "$WT" LANE_KEY_GATE=0
eqv "$LANE_RC" "82" "1y1 LANE_KEY_GATE=0 in the ENVIRONMENT does NOT disable the gate (rc=$LANE_RC) — an inherited variable is a fleet-wide off switch, not a fixture escape"
[ ! -s "$PI_MARK" ]; ck "1y2 …and the agent was not spawned, so the assertion really ran" $?
has "$(cat "$(LOG)" 2>/dev/null)" "check=ignored var=LANE_KEY_GATE=0" \
    "1y3 …and the log SAYS the value was seen and ignored, so an operator whose fixture relied on it is told what changed"
# …and the same value arriving through the file `lane-env.sh` sources, which is how a cell's box really
# gets it (the supervisor's `set -a; . "$ENV_FILE"` is inherited by every descendant lane).
mk_arm escapefile; WT="$ARMWT"
printf 'export LANE_KEY_GATE=0\n' > "$ARMDIR/home/keys.env"
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi
: > "$PI_MARK"
drive "$WT"
eqv "$LANE_RC" "82" "1y4 the same value SOURCED FROM THE BOX'S keys.env also does NOT disable the gate (rc=$LANE_RC) — this is the route that made the previous cut's fix decorative"
[ ! -s "$PI_MARK" ]; ck "1y5 …and the agent was not spawned" $?
# …and the declared escape, the one no environment can inject, DOES work.
mk_arm escapeflag; WT="$ARMWT"
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi
: > "$PI_MARK"
drivef "$WT" --key-gate-off
eqv "$LANE_RC" "0" "1y6 --key-gate-off on the INVOCATION skips the assertion (rc=$LANE_RC) — the declared escape still exists, for fixtures that stub pi"
[ -s "$PI_MARK" ]; ck "1y7 …and the agent really ran" $?
has "$(cat "$(LOG)" 2>/dev/null)" "reason=--key-gate-off" \
    "1y8 …and the skip is LOUD and named (a silent skip is the bypass this whole change refuses)"
check_terminal "1y9" done "agent-exit-0" 0

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

# ═══ 2i. A STILL-RUNNING OLDER RUN CANNOT CLAIM THE CURRENT VERDICT ════════════════════════════
# Removing the per-run file at dispatch covers a stale FILE, not a stale WRITER: a previous run of the same
# issue can still be ALIVE — the stuck-lane shape this issue is about — and would overwrite the file with ITS
# verdict when its own trap finally fires (review round 5, P2). Each dispatch stamps an owner token and the
# trap writes the file only while it still owns it; the older run's line still lands in the append-only log.
mk_arm ownertok; WT="$ARMWT"
pi() { sleep 5; return 0; }
export -f pi
drive_bg "$WT" "$KEYVAR=sk_fixture"
_i=0
while [ "$_i" -lt 200 ]; do
  grep -q '\[agent\] provider=' "$(LOG)" 2>/dev/null && break
  kill -0 "$LANE_PID" 2>/dev/null || break
  _i=$((_i + 1)); sleep 0.1
done
drive "$WT" LANE_DRY_RUN=1
OWN_OUT="$ARMDIR/o/logs/lane-3331.outcome"
eqv "$(sed -n 's/.*reason=\([a-z-]*\).*/\1/p' "$OWN_OUT" 2>/dev/null)" "dry-run" "2i the SECOND dispatch owns the per-run verdict while the first is still alive"
kill -TERM "$LANE_PID" 2>/dev/null
wait "$LANE_PID" 2>/dev/null
has "$(cat "$OWN_OUT" 2>/dev/null)" "reason=dry-run" "2j the older run's late trap does NOT overwrite the current run's verdict (owner token)"
hasnt "$(cat "$OWN_OUT" 2>/dev/null)" "signal:TERM" "2k …the killed run's verdict never reaches the run-scoped read"
has "$(cat "$(LOG)" 2>/dev/null)" "a LATER dispatch of #3331 owns that file" "2l …and it SAYS so in the append-only transcript (naming a LATER dispatch, which is what it can observe), instead of dropping its own line silently"
has "$(cat "$(LOG)" 2>/dev/null)" "outcome=died reason=signal:TERM" "2m …while its own outcome= line is still in the log (the transcript keeps every run)"
# ⛔ AND THE DENY ARM OWES THE SAME LAST-LINE CONTRACT AS EVERY OTHER ARM (review cycle 2, P2, mutation-
# verified). This is the only arm that reaches the owner-DENY branch, and it never called `check_terminal`,
# so cycle 1's "the line is last in every arm" claim was pinned by NOTHING: re-echoing the explanation after
# the line left the suite at 136/136 green, and `tail -1` (the documented history fallback) then answered
# "nothing recorded" for a lane that HAD recorded one — the exact defect the reorder removed. `check_terminal`
# asserts exactly-one-terminal-line AND last-line-is-terminal, so the deny arm is now measured, not assumed.
# (the count is legitimately 2 here — this log carries TWO runs — so the deny arm pins the ORDER, which is
# the thing cycle 1 changed: whatever else is in the file, a terminal line is what it ENDS with.)
_DENY_LAST="$(tail -n 1 "$(LOG)" 2>/dev/null)"
case "$_DENY_LAST" in
  "outcome=died reason=signal:TERM "*) ck "2m2 the DENY arm's log still ENDS with the terminal line (prose cannot follow it)" 0 ;;
  *) bad "2m2 the DENY arm's log does not end with the terminal line (got: '$_DENY_LAST')" ;;
esac

# ⛔ THE HANDOVER ORDER IS PART OF THE FIX (review round 6, P2, measured). Removing the verdict file BEFORE
# stamping the token leaves a window in which an older run's trap still matches its own (old) token and writes
# its verdict back, after which the new dispatch stamps a token without clearing it — the old verdict then
# reads as the current run's. A timing window cannot be driven deterministically from a shell test, so the
# ORDER is pinned: the stamp must precede the removal.
_OWNLN="$(grep -n '> "\$O/logs/lane-\$N.owner" 2>/dev/null' "$LANE" | head -1 | cut -d: -f1)"
_RMLN="$(grep -n 'rm -f "\$O/logs/lane-\$N.outcome"' "$LANE" | head -1 | cut -d: -f1)"
{ [ -n "${_OWNLN:-}" ] && [ -n "${_RMLN:-}" ] && [ "$_OWNLN" -lt "$_RMLN" ]; }; rc=$?
ck "2n the owner token is stamped BEFORE the verdict file is removed (line ${_OWNLN:-?} < ${_RMLN:-?}) — the reverse order re-opens the stale-writer window" $rc

# ── 2o: A FAILED STAMP FAILS OPEN (review round 6, P2) ────────────────────────────────────────────
# If the token cannot be written (a transient ENOSPC/EACCES), this run must still publish ITS OWN verdict: the
# alternative is a lane that RAN reading as "still working" for ever because a write failed hours earlier. A
# DIRECTORY at the .owner path makes the stamp fail deterministically.
mk_arm ownerfail; WT="$ARMWT"
pi() { printf 'ran\n' >> "$PI_MARK"; return 0; }
export -f pi
mkdir -p "$ARMDIR/o/logs/lane-3331.owner"
drive "$WT" LANE_DRY_RUN=1
eqv "$LANE_RC" "0" "2o a dispatch whose owner stamp FAILS still completes the lane"
has "$(cat "$ARMDIR/o/logs/lane-3331.outcome" 2>/dev/null)" "reason=dry-run" "2p …and still publishes its OWN run-scoped verdict (fail-open, not silence)"

# ── 2q: AN EXTERNALLY CLEARED OWNER FILE MUST NOT SUPPRESS THE VERDICT (review round 7, P2) ────
# The ownership read is consulted only when it returns a NON-EMPTY token that is not ours. An absent or
# unreadable `lane-<N>.owner` (a cleaned logs/ directory, a failed dispatch-side write) means nothing is
# authoritative, so the run re-stamps and publishes — the other direction makes a lane that RAN read as
# "still working" for ever, which is the failure the whole mechanism exists to prevent.
mk_arm ownergone; WT="$ARMWT"
pi() { sleep 5; return 0; }
export -f pi
drive_bg "$WT" "$KEYVAR=sk_fixture"
_i=0
while [ "$_i" -lt 200 ]; do
  grep -q '\[agent\] provider=' "$(LOG)" 2>/dev/null && break
  kill -0 "$LANE_PID" 2>/dev/null || break
  _i=$((_i + 1)); sleep 0.1
done
rm -f "$ARMDIR/o/logs/lane-3331.owner"
kill -TERM "$LANE_PID" 2>/dev/null
wait "$LANE_PID" 2>/dev/null
GONE_OUT="$ARMDIR/o/logs/lane-3331.outcome"
has "$(cat "$GONE_OUT" 2>/dev/null)" "outcome=died reason=signal:TERM" "2q a lane whose owner file was cleared mid-run STILL publishes its own verdict (an unreadable token is not a deny)"

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

# ⛔ 4c/4d: THE OTHER TWO HANDLERS ARE PINNED TOO (review cycle 1, P2, mutation-verified). Only the TERM
# arm carried a status assertion, so `trap 'lane_terminate 0 HUP' HUP` — which publishes `rc=0` beside
# `outcome=died`, the exact disagreement the TERM arm exists to catch — left BOTH suites green (measured:
# lane-outcome 111/111 and reap-lane-venvs 0 failed on that mutant). HUP is the `tmux kill-session` path
# the code itself calls the usual operator kill, so the unpinned arm was the one most likely to be used.
for _sig in HUP INT; do
  case "$_sig" in HUP) _rc=129 ;; INT) _rc=130 ;; esac
  mk_arm "sig$_sig"; WT="$ARMWT"
  pi() { sleep 5; return 0; }
  export -f pi
  drive_bg "$WT" "$KEYVAR=sk_fixture"
  i=0
  while [ "$i" -lt 200 ]; do
    grep -q '\[agent\] provider=' "$(LOG)" 2>/dev/null && break
    kill -0 "$LANE_PID" 2>/dev/null || break
    i=$((i + 1)); sleep 0.1
  done
  kill -"$_sig" "$LANE_PID" 2>/dev/null
  wait "$LANE_PID" 2>/dev/null; LANE_RC=$?
  eqv "$LANE_RC" "$_rc" "4c a ${_sig}-ed lane exits by that signal's status (${_rc})"
  check_terminal "4d" died "signal:${_sig}" "$_rc"
done

# ⛔ 4e: THE FORMAT COMMENT'S GATE LIST IS THE WRITER'S VOCABULARY, AND IT HAD ALREADY DRIFTED (review
# cycle 1, P2). `lane.sh`'s FORMAT block said "one of the SIX refusal gates" and then listed seven, and
# `chain-merge.sh`'s return contract listed six while its `case` dispatched on seven — the reader this
# comment exists for (someone implementing a consumer of field 3) is the one who inherits the fold to
# `load`. Both halves are asserted against `cap_refusal_gate`, so a gate added to the vocabulary without
# its name in the contract reddens here rather than in an operator's misread.
_gates="$(sed -n '/^cap_refusal_gate()/,/^}/p' "$(dirname "$LANE")/chain-merge.sh" \
          | sed -n 's/^[[:space:]]*\([a-z][a-z-]*\))[[:space:]]*printf.*/\1/p' | sort -u | paste -sd ',' -)"
eqv "$_gates" "capability,disk,fork,key,land,mem,skew" \
    "4e the normaliser's own vocabulary is the expected named arms — eight of them, load being the FOLD and not an arm"
_fmt="$(sed -n '/^# FORMAT — one line/,/^# (`land` is the CREATION/p' "$LANE")"
for _g in load disk land fork capability skew key mem; do
  has "$_fmt" "\`$_g\`" "4e …and the FORMAT contract names the \`$_g\` gate (a consumer built from it cannot fold it)"
done
has "$_fmt" "EIGHT refusal gates" "4e …and the COUNT agrees with the list (it said SIX beside seven names, then SEVEN beside eight)"
# ⛔ LOCATE THE DECLARATION BY NAME, NOT BY LINE NUMBER (agent-infra#2095). This read used to be
# `head -n 80 … | grep -n '^cap_refusal_gate()'`, which gave the three arms below a SECOND, unstated
# precondition: that no unrelated change ever pushes the function past line 80. #2095 adds lines of
# comment above it (the work-root split) and moved the declaration 75 → 81, at which point `_ret` went
# EMPTY and all three arms failed — a red ABOUT A POSITION, reported as a red about the return
# contract, inside a suite nobody suspects because `bash-suites` reds are routinely attributed to the
# base. The property these arms assert is "the contract line names the gate its `case` dispatches on",
# and the contract lives ON the declaration line; position was never part of it. Same class as the
# #2095 P0: an assertion that silently encoded a positional assumption the diff never mentioned.
_ret="$(grep -n '^cap_refusal_gate()' "$(dirname "$LANE")/chain-merge.sh" | head -1)"
for _g in key skew mem; do
  has "$_ret" "$_g" "4e …and chain-merge's return contract names \`$_g\`, which its case arm dispatches on"
done

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
# A scanner's whole job is `grep -L '^outcome=\(done\|refused\|failed\|died\) reason=' "$O"/logs/lane-[0-9]*.log`
# (anchored — see lane.sh's contract block); this arm asserts the words it
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

# ═══ 9. WHO ENDED THE LANE (#2833) — attribution before any work-failure claim ═══════════════
# MEASURED before the change (this fleet's own logs, 2026-11-11): 53 lanes exited non-zero and ALL 53
# were `outcome=failed reason=agent-exit-<rc>`, including the 35 (66%) that `lane-bound.sh` had ended at
# the wall ceiling — every one of those logs already carried `[lane-bound] VERDICT
# verdict=exceeded-wallclock`. The line the census reads said "the work failed" about lanes that were
# never allowed to finish, which is the question this issue was filed over.
#
# ⛔ ONLY TWO OF THESE EIGHT ARMS REDDEN ON THE PRE-CHANGE TREE — and the two kinds of arm prove
# different things, so the distinction is stated rather than flattened (review finding on this very
# change, and it was right: the earlier text claimed all of them redden pre-change, which is false by
# construction).
#
#   * 9a and 9e are the BEHAVIOUR arms. On `origin/main` the non-zero branch is unconditional
#     (`lane_outcome failed "agent-exit-$rc"`), so the outputs they demand — `died
#     reason=transport-unreachable:…` and `died reason=exceeded-wallclock` — are UNREACHABLE there and
#     both arms go RED. That is the mutation the issue asks for.
#   * 9b/9c/9d/9f/9g/9h are OVER-REACH falsifiers, and they are GREEN on the pre-change tree BY
#     CONSTRUCTION (it called everything `failed`, which is what they ask for). They exist to redden
#     under the OPPOSITE mutation — a fix that attributes too much — and each one names the edit that
#     reverts the protection it guards:
#         9b  make the transport comparison unconditional (`-ge 0`, or drop the `elif` guard)
#         9c  `LANE_TRANSPORT_MIN_ROTATIONS=1` in the sanitiser's default arm
#         9d  set `LANE_AGENT_LOG_OFF=0` unconditionally (read the whole append-only log)
#         9f  hoist the attribution above the `rc = 0` arm
#         9g  replace `lane_bound_killer`'s `case` with a truthiness test (`[ -n "$v" ]`)
#         9h  add `unknown` to the killer allow-list — ⛔ CONDITIONAL, and said so: the arm
#             discriminates only while the fixture's `unknown` line is the LAST `[lane-bound] VERDICT`
#             in this run's output, because `tail -1` reads the last one and the reaped watchdog can
#             append its own `verdict=finished` after `pi` exits. It is pinned as a forward-guard on
#             the allow-list, not counted as proof on its own; the unconditional half of that rule is
#             9g, whose fixture cannot lose the comparison.
#     A work failure must NOT become retryable (9b/9c), a PREVIOUS run's connection storm must NOT
#     classify THIS run (9d), a lane that merely logged a blip and then completed must stay `done`
#     (9f), and a verdict word that names no bound must not be minted as a killer (9g/9h).

# 9a — the model/provider was unreachable: the agent's own transcript carries the rotations, the exit
# is not about the work, and the terminal line says RETRYABLE instead of `failed`.
mk_arm transport; WT="$ARMWT"
pi() {
  printf '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #1)\n'
  printf '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #2)\n'
  printf '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #3)\n'
  return 1
}
export -f pi
drive "$WT" "$KEYVAR=sk_fixture"
check_terminal "9a" died "transport-unreachable:rc1:rotations=3" 1
case "$(lastline)" in
  outcome=failed*) bad "9a2 a transport death is NOT reported as a work failure (got: '$(lastline)')" ;;
  *) ok "9a2 …and it is not the work-failure token, which is the whole point: a retryable death read as a failed attempt is the treadmill #2833 measured" ;;
esac

# 9b — THE FALSIFIER. A lane whose work failed, with no transport evidence, must NOT become retryable:
# an automatic retry of a real work failure burns a lane's budget and repeats the same outcome.
mk_arm workfail; WT="$ARMWT"
pi() { printf 'the change is wrong\n'; return 1; }
export -f pi
drive "$WT" "$KEYVAR=sk_fixture"
check_terminal "9b" failed "agent-exit-1" 1

# 9c — THE THRESHOLD'S LOWER EDGE. One or two rotations inside a run that then failed ON ITS OWN WORK is
# a work failure: a single rotation is a blip that the agent recovered from, and retrying on it is the
# false-retry direction. Pinned at 2 (one below the default) rather than at 0 so a future default of 1
# reddens here.
mk_arm belowthresh; WT="$ARMWT"
pi() {
  printf '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #1)\n'
  printf '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #2)\n'
  return 1
}
export -f pi
drive "$WT" "$KEYVAR=sk_fixture"
check_terminal "9c" failed "agent-exit-1" 1

# 9d — THE STALE-FLAG DIRECTION, which is the defect this file already closes once for `outcome=`. The
# lane log is APPEND-ONLY across runs, so a PREVIOUS attempt that died of a connection storm leaves its
# rotations in the file. Classifying the NEXT run's work failure as transport would silently convert
# every subsequent real failure of that issue into an endless retry — so the read is RUN-SCOPED.
mk_arm runsccoped; WT="$ARMWT"
printf '%s\n' \
  '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #1)' \
  '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #2)' \
  '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #3)' \
  '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #4)' \
  '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #5)' \
  > "$(LOG)"
pi() { printf 'the change is wrong\n'; return 1; }
export -f pi
drive "$WT" "$KEYVAR=sk_fixture"
check_terminal "9d" failed "agent-exit-1" 1

# 9e — THE BOUND ARM, driven END TO END rather than by hand-writing a verdict line: a real
# `lane-bound.sh` ends a real lane at a 4 s wall ceiling, and the terminal line must name the bound that
# killed it instead of claiming a work failure. This is item 4 of #2833 ("the kill reason must name the
# killer") at the only surface a census reads.
mk_arm boundkill; WT="$ARMWT"
pi() { sleep 30; return 0; }
export -f pi
drive "$WT" "$KEYVAR=sk_fixture" LANE_BOUND_WALL_S=4 LANE_BOUND_POLL_S=1
ecase="$(lastline)"
case "$ecase" in
  "outcome=died reason=exceeded-wallclock"*) ok "9e a lane the wall ceiling ENDED is attributed to the bound, not to its work (got: '$ecase')" ;;
  *) bad "9e expected outcome=died reason=exceeded-wallclock, got: '$ecase'" ;;
esac
has "$(cat "$(LOG)" 2>/dev/null)" 'ATTRIBUTED: the agent exited' \
    "9e2 …and the log carries the attribution line that tells an operator the bound's own readings are above it"

# 9f — THE OTHER FALSIFIER: rotations that did NOT end the lane. A lane that recovered from a storm and
# then COMPLETED is `done`, never `died reason=transport-unreachable` — retrying a lane that succeeded is
# the most wasteful form of this bug.
mk_arm recovered; WT="$ARMWT"
pi() {
  printf '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #1)\n'
  printf '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #2)\n'
  printf '[http-pool-hygiene] rotated connection pool (message_end: Connection error.; rotation #3)\n'
  return 0
}
export -f pi
drive "$WT" "$KEYVAR=sk_fixture"
check_terminal "9f" done "agent-exit-0" 0

# 9g — THE THIRD FALSIFIER, AND THE ONE THAT GUARDS THE WORK-FAILURE CLAIM ITSELF: `lane-bound.sh`
# emits a `VERDICT` line on EVERY path, including `verdict=finished` — the line it writes when the bound
# watched the agent END ON ITS OWN. `spawn-gate.sh` therefore CLEARS `finished` out of
# `AGENT_BOUND_VERDICT` ("empty means the agent finished on its own"), and a fallback read that accepts
# ANY non-empty verdict re-admits exactly the word the caller had filtered: a lane that failed ITS OWN
# WORK is then recorded `outcome=died reason=finished`, so the work-failure claim this change exists to
# keep is erased and the census sees a death nothing killed. The arm writes the finishing line the way
# `lane-bound.sh` writes it (into the lane log, which is what `run_agent` hands it as `--log`); WHICH of
# the two lands is a race the caller decides (it kills the watchdog the instant the agent's `wait`
# returns) and this arm pins the CLASSIFICATION for the case the bound wins it — the arm is about the
# read, not the race.
mk_arm finishedverdict; WT="$ARMWT"
pi() {
  printf '[lane-bound] VERDICT verdict=finished tag=lane-3331 pid=2 rc=na elapsed=1s wall_bound=2400s idle_bound=2700s silent=0s bytes=5 bytes_delta=5 cpu_cs=0 cpu_delta_cs=0 tol_cs=60 cpu_unreadable=0 signal=none\n'
  printf 'the change is wrong\n'
  return 1
}
export -f pi
drive "$WT" "$KEYVAR=sk_fixture"
check_terminal "9g" failed "agent-exit-1" 1

# 9h — THE SAME ALLOW-LIST, AT ITS OTHER EDGE (the polarity rule this repo applies to every verdict
# vocabulary): a verdict word nobody recognises is NOT a bound that ended a lane. `lane-bound.sh`'s
# `verdict_line` defaults the field to `unknown`, so the value is reachable, and reading it as a killer
# would mint `outcome=died reason=unknown` — a death that names no killer, which is the blindness #2833
# was filed over, reintroduced by its own fix. Only `stalled` and `exceeded-wallclock` name a bound.
mk_arm unknownverdict; WT="$ARMWT"
pi() {
  printf '[lane-bound] VERDICT verdict=unknown tag=lane-3331 pid=2 rc=na elapsed=1s wall_bound=2400s idle_bound=2700s silent=0s bytes=5 bytes_delta=5 cpu_cs=0 cpu_delta_cs=0 tol_cs=60 cpu_unreadable=0 signal=none\n'
  printf 'the change is wrong\n'
  return 1
}
export -f pi
drive "$WT" "$KEYVAR=sk_fixture"
check_terminal "9h" failed "agent-exit-1" 1

echo
if [ "$FAIL" -gt 0 ]; then
  printf '❌ lane-outcome suite: %s passed, %s FAILED\n' "$PASS" "$FAIL"
  exit 1
fi
printf '✅ lane-outcome suite: all %s assertions passed\n' "$PASS"
