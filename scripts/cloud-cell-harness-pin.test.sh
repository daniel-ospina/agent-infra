#!/usr/bin/env bash
# cloud-cell-harness-pin.test.sh — a NEW cell is born PINNED, and the launcher's env survives into the
# tmux session.
#
# WHY THIS TEST EXISTS (all three measured 2026-10-21, on new boxes, in one day):
#   (a) `$HOME/harness` was a DIRECTORY OF SHA-NAMED SUBDIRECTORIES — not a worktree — so a pin FILE
#       existed while the harness it named did not (`pinned=none`), and the controller started from a
#       LANE CHECKOUT instead: every fix applied to the pin ran nowhere.
#   (b) `keys.env` exported `GH_REPO=daniel-ospina/tortoise` GLOBALLY, so agent-infra rails read the
#       WRONG repo and printed `ALREADY MERGED` for a September tortoise PR — success over zero work.
#       The repo-side half of that is "the cell env writer must not export a repo"; the rail-side half
#       is PR #2241 (an inherited GH_REPO is refused by evidence), commented there rather than forked.
#   (c) env passed to `tmux new-session` is INHERITED FROM THE TMUX SERVER, not from the caller, so an
#       `export REPO=…` in the launcher's shell reached nothing and the loop died `FATAL REPO is not
#       set`. The launch command string carries the values (it already did); what was missing is that
#       the session writes back WHAT IT HOLDS so `start` refuses on the artifact, naming the variable.
#
# Hermetic: temp dirs, a throwaway git repo, stubbed supervisor. No network, no tmux, no cell.
# Run: bash scripts/cloud-cell-harness-pin.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BRINGUP="${BRINGUP:-$HERE/cloud-cell-bringup.sh}"
SUP="${SUP:-$HERE/cloud-cell-supervisor.sh}"

PASS=0; FAIL=0
ok(){ PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
say_case(){ printf '\n── %s ──\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cell-pin.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

[ -f "$BRINGUP" ] || { echo "FATAL: $BRINGUP not found"; exit 1; }
[ -f "$SUP" ] || { echo "FATAL: $SUP not found"; exit 1; }

# ── extract the shipped pin check (never restate its logic here) ────────────────────────────────
EXTRACT="$T/pin-fns.sh"
for fn in pin_supervisor is_worktree pin_root_conforms check_harness_pin; do
  # ⛔ A PREFIX match plus a "closes here" test, because some of these are ONE-LINERS
  # (`is_worktree() { … }`) and some carry a trailing comment on the opener line. Matching the exact
  # string `fn() {` extracted NOTHING for them, and an empty extract makes every assertion below
  # vacuous — measured in the first run of this suite.
  awk -v fn="$fn" '
    index($0, fn "() {") == 1 { f = 1; print; if ($0 ~ /}[[:space:]]*$/) exit; next }
    f { print; if ($0 ~ /^}[[:space:]]*$/) exit }
  ' "$BRINGUP"
done > "$EXTRACT"
for want in 'is_worktree() {' 'pin_root_conforms() {' 'check_harness_pin() {'; do
  grep -qF -- "$want" "$EXTRACT" && ok "the shipped pin check exposes $want" \
    || bad "could not extract $want from $BRINGUP — every assertion below would be vacuous"
done

say(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die(){ printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ── a real (throwaway) git repo + linked worktree, so "is a worktree" is a FACT, not a fixture claim
REPO="$T/infra"
mkdir -p "$REPO/scripts/orchestrator-harness"
git -C "$REPO" init -q 2>/dev/null
# The harness is COMMITTED into the fixture checkout: a materialised pin must carry it because the
# COMMIT carries it, not because a test shell happened to create the file afterwards.
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/scripts/orchestrator-harness/orch-loop.sh"
git -C "$REPO" add scripts/orchestrator-harness/orch-loop.sh 2>/dev/null
git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -q -m "seed" 2>/dev/null
WORKTREE="$T/pinroot/$(git -C "$REPO" rev-parse --short=12 HEAD 2>/dev/null)"
mkdir -p "$T/pinroot"
git -C "$REPO" worktree add -q --detach "$WORKTREE" HEAD 2>/dev/null
PIN_GOOD="$WORKTREE/scripts/orchestrator-harness"
# ⛔ DROP THE EXPORT ATTRIBUTE FROM `REPO`. A shell that inherits an EXPORTED `REPO` from its caller
# keeps it exported after re-assigning it here — so the session this test launches would see THIS
# fixture's path, and case (d2)'s mutant would look non-empty for a reason that has nothing to do with
# the launcher. (It is also the real-world hazard: an ambient export is exactly what silently supplies
# a value the launch line was supposed to carry.)
export -n REPO 2>/dev/null || true

run_pin(){ # run_pin <cell_home> <layer_root>; prints output, returns the function's status
  (
    set +u
    CELL_HOME="$1"; LAYER_ROOT="$2"; WORKDIR="$T/cell"; REPO_SLUG="daniel-ospina/tortoise"
    HARNESS_PIN_DIR="${HARNESS_PIN_DIR:-$1/harness}"
    HARNESS_PIN_FILE="${HARNESS_PIN_FILE:-$1/.harness-path}"
    # shellcheck disable=SC1090
    # A LITERAL operand in its own directory, never a `$VAR` path: the worktree hazard gate refuses an
    # interpreter spawned on a path it cannot resolve, and a suite must not need an escape hatch.
    cd "$T" || return 1
    . ./pin-fns.sh
    check_harness_pin
  ) 2>&1
}

say_case "(a) a pin that names a tree which does not exist is REFUSED, and the refusal names it"
H1="$T/h1"; mkdir -p "$H1"
printf '%s\n' "$H1/harness/gone/scripts/orchestrator-harness" > "$H1/.harness-path"
OUT="$(run_pin "$H1" "")"; RC=$?
[ "$RC" -ne 0 ] && ok "a stale pin is refused (rc=$RC)" || bad "a stale pin was ACCEPTED: $OUT"
case "$OUT" in *"$H1/harness/gone/scripts/orchestrator-harness"*) ok "the refusal NAMES the path it could not use" ;; *) bad "the refusal does not name the path: $OUT" ;; esac
case "$OUT" in *"does NOT exist"*) ok "the refusal says the tree is gone (not 'not provisionable')" ;; *) bad "the refusal does not say why: $OUT" ;; esac

say_case "(a2) the measured trap: a pin naming a plain (non-git) directory of sha-named subdirs"
H2="$T/h2"; mkdir -p "$H2/harness/abc1234567/scripts/orchestrator-harness"
printf '#!/usr/bin/env bash\nexit 0\n' > "$H2/harness/abc1234567/scripts/orchestrator-harness/orch-loop.sh"
printf '%s\n' "$H2/harness/abc1234567/scripts/orchestrator-harness" > "$H2/.harness-path"
OUT="$(run_pin "$H2" "")"; RC=$?
[ "$RC" -ne 0 ] && ok "a pin into a non-worktree directory is refused (rc=$RC)" || bad "a non-worktree pin was ACCEPTED: $OUT"
case "$OUT" in *"$H2/harness/abc1234567/scripts/orchestrator-harness"*) ok "the refusal names the path" ;; *) bad "the refusal does not name the path: $OUT" ;; esac
case "$OUT" in *"NOT inside a git worktree"*) ok "the refusal says it is not a worktree (the defect, not a symptom)" ;; *) bad "the refusal does not name the defect: $OUT" ;; esac

say_case "(a3) a pin ROOT that holds no worktree at all is refused, naming the root"
H3="$T/h3"; mkdir -p "$H3/harness/abc1234567" "$H3/harness/def4567890"
OUT="$(run_pin "$H3" "")"; RC=$?
[ "$RC" -ne 0 ] && ok "a pin root of empty sha dirs is refused (rc=$RC)" || bad "a dead pin root was ACCEPTED: $OUT"
case "$OUT" in *"$H3/harness"*) ok "the refusal names the pin root" ;; *) bad "the refusal does not name the pin root: $OUT" ;; esac
case "$OUT" in *"pinned=none"*) ok "the refusal names the measured state (pinned=none)" ;; *) bad "the refusal does not name the measured state: $OUT" ;; esac

say_case "(a4) a HEALTHY per-commit pin root (worktrees that carry the harness) is ACCEPTED, not 'repaired'"
# ⛔ THE POSITIVE HALF OF (a3). `is_worktree` once asked for `orch-loop.sh` AT THE PIN PATH with the
# ROOT's relpath `.`, which is false for every worktree ROOT — so pin_root_conforms rejected the SHIPPED
# layout and the refusal told the operator to delete a healthy root (a false refusal plus an inert
# enforcer). This case is the falsifier: the same root shape (a)3 refuses must pass here.
H5="$T/h5"; mkdir -p "$H5/harness"
# A REAL linked worktree (a `cp -R` copies the `.git` POINTER FILE, so the copy is not a worktree and the
# case would test the wrong thing — which is what it did on the first run).
git -C "$REPO" worktree add -q --detach "$H5/harness/$(git -C "$REPO" rev-parse --short=12 HEAD)" HEAD 2>/dev/null
# The fixture checkout needs an origin/main the materialiser can resolve (a real cell clones one).
git -C "$REPO" update-ref refs/remotes/origin/main HEAD 2>/dev/null
OUT="$(run_pin "$H5" "$REPO")"; RC=$?
[ "$RC" -eq 0 ] && ok "a pin root holding a real worktree that carries the harness is accepted" || bad "a HEALTHY pin root was refused (rc=$RC): $OUT"
case "$OUT" in *"pinned=none"*) bad "a healthy root was still reported as pinned=none — the operator would be told to delete it" ;; *) ok "a healthy root is not reported as pinned=none" ;; esac

say_case "(b) a REAL linked worktree pin is accepted, and HARNESS-PIN carries sha AND timestamp"
H4="$T/h4"; mkdir -p "$H4"
printf '%s\n' "$PIN_GOOD" > "$H4/.harness-path"
OUT="$(run_pin "$H4" "")"; RC=$?
[ "$RC" -eq 0 ] && ok "a valid worktree pin is accepted" || bad "a valid pin was REFUSED (rc=$RC): $OUT"
PINFILE="$H4/.pi/agent/state/HARNESS-PIN"
[ -s "$PINFILE" ] && ok "HARNESS-PIN was written ($PINFILE)" || bad "HARNESS-PIN was not written"
WANT_SHA="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null)"
[ "$(head -1 "$PINFILE" 2>/dev/null)" = "$WANT_SHA" ] && ok "line 1 is the worktree's HEAD sha (the contract every existing reader uses)" || bad "line 1 is '$(head -1 "$PINFILE" 2>/dev/null)', want $WANT_SHA"
grep -q '^at=[0-9][0-9]*' "$PINFILE" && ok "line 2 records WHEN the pin was taken (at=<epoch>)" || bad "HARNESS-PIN carries no timestamp: $(cat "$PINFILE" 2>/dev/null)"

say_case "(c) nothing pinned: the pin is MATERIALISED as a linked worktree, from the ref"
H5="$T/h5"; mkdir -p "$H5"
# No stub: bring-up materialises through the checkout it resolved (`LAYER_ROOT`), whose shape is the one
# cloud-cell-supervisor.sh's `harness_apply` leaves — a linked, detached worktree PER COMMIT under the
# pin root. The throwaway repo above plays the checkout, and HARNESS_REF=HEAD is its ref (it has no
# origin remote by construction, which is the point: a pin must not need the network to be VERIFIABLE).
OUT="$(LAYER_ROOT="$REPO" HARNESS_REF=HEAD run_pin "$H5" "$REPO")"; RC=$?
[ "$RC" -eq 0 ] && ok "an unpinned cell is materialised, not refused" || bad "materialisation failed (rc=$RC): $OUT"
_got_pin="$(head -1 "$H5/.harness-path" 2>/dev/null)"
case "$_got_pin" in
  "$H5/harness"/*/scripts/orchestrator-harness) ok "the pin file records the per-commit tree under the pin root: $_got_pin" ;;
  *) bad "the pin file records '$_got_pin', want a per-commit tree under $H5/harness" ;;
esac
[ -f "$_got_pin/orch-loop.sh" ] && ok "the pinned path really carries the harness (orch-loop.sh)" || bad "the pinned path carries no harness"
[ "$(git -C "$_got_pin" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] && ok "the materialised tree IS a git worktree (not a copy)" || bad "the materialised tree is not a worktree"
[ -s "$H5/.pi/agent/state/HARNESS-PIN" ] && ok "a materialised pin is also recorded in HARNESS-PIN" || bad "no HARNESS-PIN after materialising"
case "$(sed -n '2p' "$H5/.pi/agent/state/HARNESS-PIN" 2>/dev/null)" in
  at=*) ok "the materialised record carries its timestamp too" ;;
  *) bad "the materialised HARNESS-PIN has no at= line" ;;
esac

say_case "(b2) the cell env writer never exports a repo globally (#2235's repo-side half)"
grep -qE '^[[:space:]]*export[[:space:]]+GH_REPO=' "$BRINGUP" "$SUP" 2>/dev/null \
  && bad "a launcher EXPORTS GH_REPO globally — every rail without --repo would read that repo" \
  || ok "neither launcher exports GH_REPO globally (the repo is per-invocation state)"

say_case "(d) the launcher's env SURVIVES into the session (and the session receipts it)"
LAUNCH_LINE="$(grep -n 'tmux new-session -d -s "\$SESSION"' "$SUP" | head -1 | cut -d: -f1)"
[ -n "$LAUNCH_LINE" ] && ok "the controller launch exists in $SUP (line $LAUNCH_LINE)" || bad "no controller launch found in $SUP"
CMDTXT="$(sed -n "$((LAUNCH_LINE + 1))p" "$SUP")"
case "$CMDTXT" in
  *'REPO='*) ok "the launch command string ASSIGNS REPO inside the session (not in the caller's shell)" ;;
  *) bad "the launch command string does not assign REPO: $CMDTXT" ;;
esac
case "$CMDTXT" in
  *'session-env'*) ok "the session writes an environment receipt for start to verify" ;;
  *) bad "the launch command string writes no receipt, so start cannot verify what the session holds" ;;
esac

# ⛔ S (the session's state dir) and its fake harness come FIRST: the launch string is rendered with
# $S in it, and `set -u` makes a use-before-assignment a hard error rather than an empty value.
S="$T/session"; mkdir -p "$S/orch/scripts/orchestrator-harness" "$S/orch/logs" "$S/home"
printf '#!/usr/bin/env bash\nmkdir -p "%s/orch/state"; printf "loop-saw-REPO=%%s\\n" "${REPO:-}" >> "%s/orch/state/loop-env"\n' "$S" "$S" \
  > "$S/orch/scripts/orchestrator-harness/orch-loop.sh"
chmod +x "$S/orch/scripts/orchestrator-harness/orch-loop.sh"
# `HARNESS` names the harness DIRECTORY (the one holding orch-loop.sh), exactly as on a real cell.
HARNESS="$S/orch/scripts/orchestrator-harness"

# Render the shipped command string EXACTLY as the launcher does: one double-quoted expansion, in a
# shell that holds the same variables. The inner `eval` is the launcher's own assignment, not a
# re-implementation of it — so a value dropped from the string is a value dropped here too.
# The shipped line is INDENTED; `eval "STR=<indented text>"` is not an assignment, so trim the leading
# whitespace first (the launcher's own shell sees the same text, but only as an argument to tmux).
CMDTXT="$(printf '%s' "$CMDTXT" | sed 's/^[[:space:]]*//')"
STR="$(CMDTXT="$CMDTXT" O="$S/orch" HARNESS="$HARNESS" ENV_FILE="$S/home/keys.env" \
  CELL_HOME="$S/home" REPO="/tmp/cell-repo-under-test" OR="daniel-ospina/agent-tortoise" \
  SCOPE="auto" HARNESS_REPO="$S/orch" HARNESS_REF="origin/main" \
  HARNESS_PIN_DIR="$S/home/harness" HARNESS_PIN_FILE="$S/home/.harness-path" SUP_SELF="$SUP" \
  bash -c 'eval "STR=$CMDTXT"; printf "%s" "$STR"' 2>/dev/null)"
if [ -n "$STR" ]; then
  # The string is handed to tmux, which runs it with sh -c — so run it the same way.
  ( cd "$S/orch" && sh -c "$STR" ) >"$S/session.log" 2>&1
  _se="$S/orch/state/session-env"
  if [ -s "$_se" ]; then
    ok "the session wrote its environment receipt"
    grep -qx 'REPO=/tmp/cell-repo-under-test' "$_se" \
      && ok "REPO is SET INSIDE the session (the launcher's value survived the tmux boundary)" \
      || bad "the session holds $(grep '^REPO=' "$_se" || echo 'no REPO line') — the value did not survive"
    grep -qs 'loop-saw-REPO=/tmp/cell-repo-under-test' "$S/orch/state/loop-env" \
      && ok "the harness the session launched saw REPO (proved from inside, not from the launch line)" \
      || bad "the harness inside the session did not see REPO: $(cat "$S/orch/state/loop-env" 2>/dev/null)"
  else
    bad "the session wrote no receipt ($_se): $(tail -3 "$S/session.log")"
  fi
else
  bad "could not render the launch command string from the shipped line"
fi

say_case "(d2) MUTATION — drop REPO from the command string and the receipt goes empty"
MUTCMD="$(printf '%s' "$STR" | sed "s|REPO='/tmp/cell-repo-under-test' ||")"
if [ "$MUTCMD" = "$STR" ]; then
  bad "the mutation did not apply — the assertion above is not reading REPO from the command string"
else
  S2="$T/session2"; mkdir -p "$S2/orch/scripts/orchestrator-harness" "$S2/orch/logs" "$S2/home"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$S2/orch/scripts/orchestrator-harness/orch-loop.sh"
  chmod +x "$S2/orch/scripts/orchestrator-harness/orch-loop.sh"
  M2="$(printf '%s' "$MUTCMD" | sed "s|$S/orch|$S2/orch|g")"
  ( cd "$S2/orch" && sh -c "$M2" ) >"$S2/session.log" 2>&1
  if [ -s "$S2/orch/state/session-env" ] && grep -qx 'REPO=' "$S2/orch/state/session-env"; then
    ok "without the assignment the session's REPO is EMPTY — which is exactly what start now refuses"
  else
    bad "the mutant session still held a REPO: $(cat "$S2/orch/state/session-env" 2>/dev/null)"
  fi
  grep -q "the controller's session holds an EMPTY REPO" "$SUP" \
    && ok "the shipped start refuses on that receipt, naming the variable" \
    || bad "start does not refuse an empty REPO in the session"
fi

printf '\n----------------------------------------\n'
if [ "$FAIL" -eq 0 ]; then printf '✅ cloud-cell-harness-pin: %d checks passed\n' "$PASS"; exit 0; fi
printf '❌ cloud-cell-harness-pin: %d of %d checks FAILED\n' "$FAIL" "$((PASS + FAIL))"; exit 1
