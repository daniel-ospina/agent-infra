#!/usr/bin/env bash
# cell-self-pin.test.sh — pins agent-infra #3194: a pin unit must DERIVE the layer it pins, and must
# never be anchored on the provisioning recipe's bootstrap clone.
#
# WHAT IT PREVENTS (the measured defect, not a hypothetical). `cell-self-pin.service` shipped
# `WorkingDirectory=/tmp/cell-ai` in a drop-in and `cd /tmp/cell-ai` in its script. `/tmp/cell-ai` is the
# PROVISIONING RECIPE's clone; on a running cell it is absent, so systemd failed the unit at CHDIR with
# 200/CHDIR every ten minutes and the unit NEVER ONCE RAN. On cell-1 the pin RECORD named `6da181efd`
# (origin/main, carrying #3108) while the controller's pid executed a worktree 17 commits behind that no
# longer existed — for roughly a day of "active (running)". This suite is the gate that would have
# caught it: it asserts the NEGATIVE case — a cell home that contains no `/tmp/cell-ai` at all.
#
# ⛔ THE NEGATIVE CASE IS THE WHOLE TEST. A suite that only renders on THIS dev box proves nothing,
# because this box happens to carry a bootstrap clone at `/tmp/cell-ai` — the exact coincidence that let
# the defect ship. So every leg below runs through `runat`, which scrubs the ambient `HARNESS*` variables
# a cell lane exports (cloud-cell-supervisor.sh::3092/3137 exports them into every controller) and points
# `CELL_HOME` at a hermetic temp dir. The assertions are that (a) the resolved layer lives under THAT
# home, never the clone, and (b) the rendered unit carries no bootstrap path and no `WorkingDirectory=`
# even though this box could have supplied one.
#
# ⛔ `CELL_SELF_PIN_SRC` IS A SEAM, and the fleet needs it: this suite is routinely run from a `/tmp` copy
# because the session's own worktree-discard guard refuses `bash ./scripts/*.test.sh` as
# script-indirection (measured on this box 2026-11-01: a suite this change never touched,
# `check-farm-drift.test.sh`, was refused identically). The seam keeps the suite runnable there without
# weakening a single assertion.
SELF="${CELL_SELF_PIN_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}"
PIN="$SELF/cell-self-pin.sh"
TPL="$SELF/../templates/systemd"
ok_n=0 bad_n=0
ok()  { ok_n=$((ok_n + 1));  printf 'ok   %s\n' "$*"; }
bad() { bad_n=$((bad_n + 1)); printf 'FAIL %s\n' "$*"; }
ck()  { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

# ⛔ A UNIQUE SCRATCH ROOT PER RUN, AND NO PRE-RUN WHOLE-TREE DELETE. A fixed root plus
# `find "$T" -mindepth 1 -delete` means two concurrent lanes on one box delete each other's trees mid-run
# — and a whole-tree discard is exactly what the session guard refuses (`check-farm-drift.test.sh` records
# 6 refusals / 4 runs on identical bytes from that form). `$$` is enough: one suite run per shell.
T="/tmp/cell-self-pin.selfcheck.$$"
mkdir -p "$T" || { echo "cannot create $T" >&2; exit 1; }

# runat <home> [VAR=VAL…] <command…> — ONE isolated invocation. Every leg goes through this (review
# finding: legs that called `env` directly inherited the ambient record and resolved a FOREIGN tree, so
# the suite went red on exactly the box it exists to guard).
runat() {
  local h="$1"; shift
  env -u HARNESS -u HARNESS_PIN_FILE -u HARNESS_PIN_DIR -u HARNESS_REPO -u O -u STAMP \
      -u TEMPLATES_DIR -u SYSTEMD_UNIT_DIR -u CELL_SELF_PIN_INTERVAL_MIN \
      -u CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR -u CELL_SELF_PIN_SRC \
      CELL_HOME="$h" HOME="$h" "$@"
}
pinrun() { local h="$1"; shift; runat "$h" bash "$PIN" "$@"; }

# ── a hermetic cell: bare origin + a clone that IS the pin tree. NOTHING here is /tmp/cell-ai. ─────
git init -q --bare "$T/origin.git" >/dev/null 2>&1 || { echo "FAIL git init"; exit 1; }
git -C "$T/origin.git" symbolic-ref HEAD refs/heads/main
mkdir -p "$T/seed"
git -C "$T/seed" init -q -b main >/dev/null 2>&1
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
git -C "$T/seed" remote add origin "$T/origin.git"
git -C "$T/seed" push -q origin main 2>/dev/null
git clone -q "$T/origin.git" "$T/home/harness/pintree" 2>/dev/null   # the pin tree, under CELL_HOME
mkdir -p "$T/home/harness/pintree/scripts"
printf '#!/bin/bash\nexit 0\n' >"$T/home/harness/pintree/scripts/cloud-cell-supervisor.sh"
mkdir -p "$T/home/orchestrator" "$T/empty"

# The record the CONTROLLER reads — `.harness-path` — names the pin tree. One fact, two readers.
printf '%s\n' "$T/home/harness/pintree/scripts/orchestrator-harness" >"$T/home/.harness-path"
mkdir -p "$T/home/harness/pintree/scripts/orchestrator-harness"

# ── 1. `--print-unit` renders a unit with NO bootstrap path and NO WorkingDirectory= ────────────────
out="$(pinrun "$T/home" --print-unit 2>&1)"; rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "--print-unit exits 0 (rc=$rc)"
# ⛔ ASSERT ON DIRECTIVES, NOT ON PROSE: the template documents the defect it replaced, so `/tmp/cell-ai`
# appears in its comments and must. A guard that refused the documentation too would force the next
# reader to delete the only explanation of why the line is banned.
dirs="$(printf '%s\n' "$out" | grep -vE '^[[:space:]]*#')"
# ⛔ AND THE ASSERTIONS BELOW ARE MEANINGLESS IF THE RENDER PRODUCED NOTHING — a refusal line is
# comment-free, so every `grep -q` under it silently reports ok (review finding: three checks here were
# vacuous when the template was unreachable).
if [ -z "$dirs" ] || printf '%s\n' "$dirs" | grep -q '^REFUSING:'; then
  bad "the render produced no directives, so the absence checks below would be vacuous: $out"
else
  case "$dirs" in
    *'/tmp/cell-ai'*) bad "a rendered DIRECTIVE names the provisioning clone /tmp/cell-ai — that path is absent on a running cell and systemd fails the unit at CHDIR before any payload runs (#3194)" ;;
    *) ok "no rendered directive names /tmp/cell-ai" ;;
  esac
  if printf '%s\n' "$dirs" | grep -qE '^[[:space:]]*WorkingDirectory='; then
    bad "the rendered unit declares WorkingDirectory= — one directive that refuses to start the unit when its directory is gone (EXIT_CHDIR 200)"
  else ok "the rendered unit declares no WorkingDirectory= (the pass cd's itself after resolving the layer)"; fi
  printf '%s\n' "$dirs" | grep -q '^SuccessExitStatus=0$' \
    && ok "only exit 0 is green (SuccessExitStatus=0)" || bad "the unit does not pin SuccessExitStatus=0"
  if printf '%s\n' "$dirs" | grep -qE '^[[:space:]]*ConditionPathExists='; then
    bad "ConditionPathExists= is present — a failed condition SKIPS the unit and leaves it GREEN, which is strictly worse than the 200/CHDIR it replaced"
  else ok "no ConditionPathExists= (a skipped condition is a green no-op, not a RED)"; fi
  printf '%s\n' "$dirs" | grep -qE '^ExecStart=/bin/bash /' \
    && ok "ExecStart is an absolute live-cell path" || bad "ExecStart is not an absolute path"
  printf '%s\n' "$dirs" | grep -qE '^Environment=HOME=/' \
    && ok "HOME is carried explicitly (the service manager's HOME is not the cell home)" || bad "HOME is not carried"
fi

# ── 2. THE NEGATIVE CASE: the layer resolves from CELL_HOME on a box with no /tmp/cell-ai ─────────
# ⛔ WITH A HOSTILE AMBIENT RECORD. A cell lane exports HARNESS_PIN_FILE; if the pass honoured it, this
# leg would resolve (and pin) a foreign tree — the measured review finding.
printf '%s\n' "$T/seed" >"$T/foreign-path"
out="$(HARNESS_PIN_FILE="$T/foreign-path" pinrun "$T/home" --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a pass resolves on a hermetic cell home (rc=0)" || bad "a pass could not resolve on a hermetic cell home (rc=$rc): $out"
case "$out" in
  *"/tmp/cell-ai"*) bad "the pass resolved into /tmp/cell-ai — it is still anchored on the bootstrap clone" ;;
  *"layer=$T/home/harness/pintree"*) ok "it resolved the layer that .harness-path names, under CELL_HOME — NOT the ambient HARNESS_PIN_FILE" ;;
  *) bad "the pass did not report the derived layer: $out" ;;
esac
# ⛔ A DRY RUN TOUCHES NOTHING — not even refs. `git fetch` here would mean the "read-only" verb writes.
before="$(git -C "$T/home/harness/pintree" rev-parse FETCH_HEAD 2>/dev/null || echo none)"
pinrun "$T/home" --dry-run >/dev/null 2>&1
after="$(git -C "$T/home/harness/pintree" rev-parse FETCH_HEAD 2>/dev/null || echo none)"
[ "$before" = "$after" ] && ok "--dry-run does not fetch (FETCH_HEAD unchanged)" || bad "--dry-run moved FETCH_HEAD — it is not read-only"
# ⛔ AND THE RECORD IS THE ONE THE CONTROLLER READS, not a second predicate: move `.harness-path` and
# the pass follows it, so "the tree that gets pinned" and "the tree that gets executed" stay one fact.
git clone -q "$T/origin.git" "$T/home/harness/other" 2>/dev/null
printf '%s\n' "$T/home/harness/other" >"$T/home/.harness-path"
out="$(pinrun "$T/home" --dry-run 2>&1)"
case "$out" in
  *"layer=$T/home/harness/other"*) ok "the pass FOLLOWS .harness-path (the record the controller execs from) — it holds no path of its own" ;;
  *) bad "the pass did not follow .harness-path: $out" ;;
esac

# ── 3. an unresolvable layer is a LOUD named non-zero exit, never a green no-op ─────────────────────
out="$(pinrun "$T/empty" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "no layer => exit 2 (RED), not a silent 0" || bad "no layer exited $rc, expected 2: $out"
case "$out" in
  *'UNRESOLVED(no-layer)'*) ok "the failure NAMES its reason (UNRESOLVED(no-layer)) in stderr" ;;
  *) bad "the failure does not name a reason: $out" ;;
esac
# ⛔ THE DEAD-ASSERTION FORM IS GONE: the old line was `if out="$(…)" && [ -z "$out" ]`, and because the
# run exits 2 the `&&` short-circuited, so its `bad` could never fire. Assert on the reading, once.
[ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] && ok "an unresolvable layer produced output (a unit that exits quietly is the defect)" \
  || bad "an unresolvable layer produced NO output at all — a unit that exits quietly is the defect"
# ⛔ A pin worktree whose gitdir was reclaimed (cell-1's shape) is a DIRECTORY full of files no git
# command can answer from. Accepting it on `-d` alone is the same class of lie as the unit this replaces.
mkdir -p "$T/orphan/harness/deadbeeff00d/scripts"
printf 'gitdir: %s\n' "$T/gone/.git/worktrees/deadbeeff00d" >"$T/orphan/harness/deadbeeff00d/.git"
printf '%s\n' "$T/orphan/harness/deadbeeff00d/scripts" >"$T/orphan/.harness-path"
out="$(pinrun "$T/orphan" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "a pin tree whose gitdir is GONE is refused (exit 2), not pinned from" || bad "an orphaned pin tree exited $rc, expected 2: $out"
case "$out" in
  *'no git command can answer from'*) ok "…and the orphan is named, so the reader learns which record lies" ;;
  *) bad "the orphaned record was not diagnosed: $out" ;;
esac

# ── 4. the guard itself, RULE BY RULE, on doctored artifacts ─────────────────────────────────────
# ⛔ ONE DOCTOR PER RULE. The first version doctored `WorkingDirectory=/tmp/cell-ai`, which the
# `/tmp/cell-ai` rule rejects FIRST — so the `WorkingDirectory=` rule was never reached and could have
# been deleted with this leg still green (review finding). Each probe below trips exactly one rule.
doctor() { # <name> <appended lines>  -> prints the doctored template dir
  local d="$T/doctored-$1"
  mkdir -p "$d" && cp "$TPL/cell-self-pin.timer" "$d/" && cp "$TPL/cell-self-pin.service" "$d/"
  printf '\n[Service]\n%s\n' "$2" >>"$d/cell-self-pin.service"
  printf '%s\n' "$d"
}
install_doctored() { # <dir> <unit-dir>
  runat "$T/home" TEMPLATES_DIR="$1" SYSTEMD_UNIT_DIR="$2" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
    bash "$PIN" --install 2>&1
}
d1="$(doctor bootpath 'WorkingDirectory=/tmp/cell-ai')"
out="$(install_doctored "$d1" "$T/u1")"; rc=$?
[ "$rc" -ne 0 ] && ok "REFUSES WorkingDirectory=/tmp/cell-ai (the shipped defect)" || bad "ACCEPTED the shipped defect: $out"
[ -f "$T/u1/cell-self-pin.service" ] && bad "a refused install still wrote the unit" || ok "a refused install wrote nothing"
d2="$(doctor workdir 'WorkingDirectory=/srv/harness-current')"
out="$(install_doctored "$d2" "$T/u2")"; rc=$?
[ "$rc" -ne 0 ] && ok "REFUSES WorkingDirectory= even when the path is not the clone (rule 2 is reachable)" || bad "ACCEPTED an absolute WorkingDirectory=: $out"
d3="$(doctor cond 'ConditionPathExists=/srv/harness-current')"
out="$(install_doctored "$d3" "$T/u3")"; rc=$?
[ "$rc" -ne 0 ] && ok "REFUSES ConditionPathExists= (a skipped condition is a green no-op, rule 3 is reachable)" || bad "ACCEPTED ConditionPathExists=: $out"
# ⛔ THE EXECSTART FORM: a token after `/bin/bash `, not after `=` — the reachable bypass.
d4="$(doctor execboot "ExecStart=/bin/bash /tmp/cell-ai/scripts/cell-self-pin.sh")"
out="$(install_doctored "$d4" "$T/u4")"; rc=$?
[ "$rc" -ne 0 ] && ok "REFUSES an ExecStart whose script lives in the bootstrap clone (token, not '='-prefixed)" || bad "ACCEPTED ExecStart=/bin/bash /tmp/cell-ai/…: $out"
# ⛔ AND AN EXECSTART OUTSIDE CELL_HOME — a lane worktree, which is PRUNED when the lane merges (203/EXEC).
d5="$(doctor execwt "ExecStart=/bin/bash $T/nowhere/cell-self-pin.sh")"
out="$(install_doctored "$d5" "$T/u5")"; rc=$?
[ "$rc" -ne 0 ] && ok "REFUSES an ExecStart outside CELL_HOME (a path that can be pruned out from under the unit)" || bad "ACCEPTED an ExecStart outside CELL_HOME: $out"

# ── 5. the shipped template installs, and the written unit carries no bootstrap path ──────────────
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 0\n' >"$T/fakebin/systemctl"
chmod +x "$T/fakebin/systemctl"
runat "$T/home" TEMPLATES_DIR="$TPL" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 SYSTEMD_UNIT_DIR="$T/units2" \
  PATH="$T/fakebin:$PATH" bash "$PIN" --install >"$T/install.log" 2>&1
if [ -f "$T/units2/cell-self-pin.service" ]; then
  ok "the shipped template renders and installs"
  body="$(grep -vE '^[[:space:]]*#' "$T/units2/cell-self-pin.service")"
  if printf '%s\n' "$body" | grep -qE 'WorkingDirectory=|/tmp/cell-ai'; then
    bad "the INSTALLED unit carries a bootstrap path or a WorkingDirectory="
  else ok "the INSTALLED unit carries neither a bootstrap path nor a WorkingDirectory="; fi
  # ⛔ AND THE EXECSTART MUST LIVE UNDER CELL_HOME — the pass copies itself there for exactly this.
  case "$body" in
    *"ExecStart=/bin/bash $T/home/.pi/agent/scripts/cell-self-pin.sh"*)
      ok "the installed ExecStart is a copy under CELL_HOME (it outlives the checkout it was installed from)" ;;
    *) bad "the installed ExecStart is not under CELL_HOME: $(printf '%s\n' "$body" | grep '^ExecStart=')" ;;
  esac
  [ -f "$T/home/.pi/agent/scripts/cell-self-pin.sh" ] \
    && ok "the pass is materialised at the path the unit names" || bad "the unit names a pass that was never placed"
  [ -f "$T/units2/cell-self-pin.timer" ] && ok "the timer installs beside the service" || bad "the timer was not installed"
else bad "the shipped template did not install: $(cat "$T/install.log")"; fi

# ── 6. a FALSE PASS is impossible: apply exiting 0 without moving the record is RED ───────────────
# The fixture's supervisor exits 0 and writes nothing — the measured shape (`applied -> <no stamp
# written>`, exit 0, repeating every tick). The record must be the verdict, not the exit code.
# The ref tip must actually be AHEAD of the pinned HEAD for this to exercise the apply path at all —
# without a second commit the pass is a legitimate no-op, which is a different reading entirely.
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m second
if git -C "$T/seed" push -q origin main 2>/dev/null; then
  printf '%s\n' "$T/home/harness/pintree" >"$T/home/.harness-path"
  out="$(pinrun "$T/home" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "apply exits 0 but the record did not move => non-zero (an exit code is not a convergence)" \
    || bad "the pass reported success with the record unmoved — that is #3194's own shape: $out"
  case "$out" in
    *STALE-RECORD*) ok "…and it names the reading (STALE-RECORD: the record did not reach the ref tip)" ;;
    *DRIFT*) ok "…and it reports the drift it acted on" ;;
    *) bad "the pass did not diagnose the unmoved record: $out" ;;
  esac
else bad "could not push a second commit — leg 6 not exercised"; fi

printf '\n%d ok, %d failed\n' "$ok_n" "$bad_n"
[ "$bad_n" -eq 0 ] || { printf 'scratch left at %s\n' "$T"; exit 1; }
