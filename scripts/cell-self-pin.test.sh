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
# weakening a single assertion — and ⛔ IT MUST NOT BE THE THING THAT MAKES A LEG PASS: an earlier version
# passed "the pass follows .harness-path" only because `supervisor_in()` fell back to a supervisor beside
# THIS script, i.e. a DIFFERENT tree than the resolved layer. That arm is gone, and the fixture's second
# clone now carries its own supervisor, so the leg is honest in both invocations.
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
# ⛔ AND IT IS `pwd -P`, because on macOS `/tmp` is a symlink to `/private/tmp`: git answers with the
# RESOLVED path, so every `layer=$T/...` assertion below missed and three legs failed on a healthy
# suite for no reason but the host.
T="$(cd /tmp && pwd -P)/cell-self-pin.selfcheck.$$"
mkdir -p "$T" || { echo "cannot create $T" >&2; exit 1; }
# ⛔ AND IT IS RECLAIMED ON SUCCESS. The first version left ~1 MB per run behind on every green run, on
# cells that sit at 91-98 % disk — a test suite that consumes the resource it is guarding. The failure
# path still prints the scratch path for a repro.
cleanup() {
  local rc=$?
  if [ "$rc" -eq 0 ] && [ "$bad_n" -eq 0 ]; then rm -rf "$T"; fi
  exit "$rc"
}
trap cleanup EXIT

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
# runat_keep_pinfile — the same, but the ambient `HARNESS_PIN_FILE` REACHES the child. `runat` scrubs it
# (`env -u`), so a leg that claimed to feed a hostile record through `runat` proved only that the
# FIXTURE scrubs — the pass never saw the value (review note). This variant is what actually exercises
# "the pass reads the one documented record, it does not carry a path of its own".
runat_keep_pinfile() {
  local h="$1"; shift
  env -u HARNESS -u HARNESS_PIN_DIR -u HARNESS_REPO -u O -u STAMP \
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
# The seed doubles as the target of the EXPLICIT-record leg below, so it carries a supervisor too — a
# record may point at any resolved layer, and a layer with no supervisor is its own RED (asserted later).
mkdir -p "$T/seed/scripts"
printf '#!/bin/bash\nexit 0\n' >"$T/seed/scripts/cloud-cell-supervisor.sh"

# The record the CONTROLLER reads — `.harness-path` — names the pin tree. One fact, two readers.
printf '%s\n' "$T/home/harness/pintree/scripts/orchestrator-harness" >"$T/home/.harness-path"
mkdir -p "$T/home/harness/pintree/scripts/orchestrator-harness"

# ── 1. `--print-unit` renders a unit with NO bootstrap path and NO WorkingDirectory= ────────────────
# ⛔ AND IT WRITES NOTHING. It is documented as a render-only verb; the first version placed the pass
# into $CELL_HOME while rendering — so a verb that says "render to stdout only" wrote a file (and failed
# outright on a read-only $CELL_HOME), and a REFUSED `--install` had already replaced the placed copy.
out="$(pinrun "$T/home" --print-unit 2>"$T/print.err")"; rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "--print-unit exits 0 (rc=$rc)"
if [ -f "$T/home/.pi/agent/scripts/cell-self-pin.sh" ]; then
  bad "--print-unit PLACED a copy of the pass into CELL_HOME — a render must write no file"
else ok "--print-unit writes nothing (no copy placed in CELL_HOME)"; fi
case "$(cat "$T/print.err" 2>/dev/null)" in
  *'is not placed yet'*) ok "…and it SAYS the pass is not placed, rather than naming a file it did not create" ;;
  *) bad "…but it did not say the pass is not placed: $(cat "$T/print.err" 2>/dev/null)" ;;
esac
# ⛔ ASSERT ON DIRECTIVES, NOT ON PROSE: the template documents the defect it replaced, so `/tmp/cell-ai`
# appears in its comments and must. A guard that refused the documentation too would force the next
# reader to delete the only explanation of why the line is banned.
dirs="$(printf '%s\n' "$out" | grep -vE '^[[:space:]]*#')"
# ⛔ AND THE ASSERTIONS BELOW ARE MEANINGLESS IF THE RENDER PRODUCED NOTHING — a refusal line is
# comment-free, so every test under it silently reports ok (review finding: three checks here were
# vacuous when the template was unreachable).
if [ -z "$dirs" ] || [[ $dirs == *'REFUSING:'* ]]; then
  bad "the render produced no directives, so the absence checks below would be vacuous: $out"
else
  case "$dirs" in
    *'/tmp/cell-ai'*) bad "a rendered DIRECTIVE names the provisioning clone /tmp/cell-ai — that path is absent on a running cell and systemd fails the unit at CHDIR before any payload runs (#3194)" ;;
    *) ok "no rendered directive names /tmp/cell-ai" ;;
  esac
  # ⛔ HERE-STRINGS, NOT `printf | grep -q`: under `pipefail` the quiet grep exits at its first match,
  # the writer takes SIGPIPE, and the pipeline reports non-zero — the false-negative idiom
  # `scripts/check-no-sigpipe-grep.sh` refuses (#841), which this suite tripped.
  if grep -qE '^[[:space:]]*WorkingDirectory=' <<<"$dirs"; then
    bad "the rendered unit declares WorkingDirectory= — one directive that refuses to start the unit when its directory is gone (EXIT_CHDIR 200)"
  else ok "the rendered unit declares no WorkingDirectory= (the pass cd's itself after resolving the layer)"; fi
  if grep -qE '^(SuccessExitStatus=)([[:space:]]*0)([[:space:]]|$)' <<<"$dirs"; then
    ok "only the pass's own success codes are green (SuccessExitStatus includes 0)"
  else bad "the unit does not declare SuccessExitStatus= with 0"; fi
  if grep -qE '^[[:space:]]*ConditionPathExists=' <<<"$dirs"; then
    bad "ConditionPathExists= is present — a failed condition SKIPS the unit and leaves it GREEN, which is strictly worse than the 200/CHDIR it replaced"
  else ok "no ConditionPathExists= (a skipped condition is a green no-op, not a RED)"; fi
  if grep -qE '^ExecStart=/bin/bash /' <<<"$dirs"; then ok "ExecStart is an absolute live-cell path"; else bad "ExecStart is not an absolute path"; fi
  if grep -qE '^Environment=HOME=/' <<<"$dirs"; then ok "HOME is carried explicitly (the service manager's HOME is not the cell home)"; else bad "HOME is not carried"; fi
fi

# ── 2. THE NEGATIVE CASE: the layer resolves from CELL_HOME on a box with no /tmp/cell-ai ─────────
out="$(pinrun "$T/home" --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a pass resolves on a hermetic cell home (rc=0)" || bad "a pass could not resolve on a hermetic cell home (rc=$rc): $out"
case "$out" in
  *"/tmp/cell-ai"*) bad "the pass resolved into /tmp/cell-ai — it is still anchored on the bootstrap clone" ;;
  *"layer=$T/home/harness/pintree"*) ok "it resolved the layer that .harness-path names, under CELL_HOME" ;;
  *) bad "the pass did not report the derived layer: $out" ;;
esac
# ⛔ AND THE ONE RECORD IT READS IS THE DOCUMENTED ONE. `HARNESS_PIN_FILE` is not a "hostile ambient
# variable" the pass should ignore — it IS the record (harness-apply-pass.sh reads the same one), so this
# leg asserts the pass HONOURS it, and `runat_keep_pinfile` is what lets the value reach the child.
printf '%s\n' "$T/seed" >"$T/foreign-path"
out="$(runat_keep_pinfile "$T/home" HARNESS_PIN_FILE="$T/foreign-path" bash "$PIN" --dry-run 2>&1)"
case "$out" in
  *"layer=$T/seed"*) ok "an EXPLICIT HARNESS_PIN_FILE is honoured — the pass reads the record, it carries no path of its own" ;;
  *) bad "the pass did not read the explicit HARNESS_PIN_FILE: $out" ;;
esac
# ⛔ A DRY RUN TOUCHES NOTHING — not even refs. `git fetch` here would mean the "read-only" verb writes.
before="$(git -C "$T/home/harness/pintree" rev-parse FETCH_HEAD 2>/dev/null || echo none)"
pinrun "$T/home" --dry-run >/dev/null 2>&1
after="$(git -C "$T/home/harness/pintree" rev-parse FETCH_HEAD 2>/dev/null || echo none)"
[ "$before" = "$after" ] && ok "--dry-run does not fetch (FETCH_HEAD unchanged)" || bad "--dry-run moved FETCH_HEAD — it is not read-only"
# ⛔ AND THE RECORD IS THE ONE THE CONTROLLER READS, not a second predicate: move `.harness-path` and
# the pass follows it, so "the tree that gets pinned" and "the tree that gets executed" stay one fact.
git clone -q "$T/origin.git" "$T/home/harness/other" 2>/dev/null
# ⛔ THE SECOND CLONE CARRIES ITS OWN SUPERVISOR. Without one, this leg only passed where a supervisor
# happened to sit beside THIS script (`supervisor_in`'s removed `$SELF_DIR` arm) — a supervisor from a
# different tree than the resolved layer, which is precisely what the leg claims is impossible.
mkdir -p "$T/home/harness/other/scripts" "$T/home/harness/other/scripts/orchestrator-harness"
printf '#!/bin/bash\nexit 0\n' >"$T/home/harness/other/scripts/cloud-cell-supervisor.sh"
printf '%s\n' "$T/home/harness/other" >"$T/home/.harness-path"
out="$(pinrun "$T/home" --dry-run 2>&1)"
case "$out" in
  *"layer=$T/home/harness/other"*) ok "the pass FOLLOWS .harness-path (the record the controller execs from) — it holds no path of its own" ;;
  *) bad "the pass did not follow .harness-path: $out" ;;
esac
# ⛔ AND A LAYER WITH NO SUPERVISOR IS A NAMED RED, NOT A BORROWED VERB.
mkdir -p "$T/bare/harness/nosup"
git init -q "$T/bare/harness/nosup" >/dev/null 2>&1
printf '%s\n' "$T/bare/harness/nosup" >"$T/bare/.harness-path"
out="$(pinrun "$T/bare" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "a resolved layer with NO supervisor is exit 2, not a borrowed supervisor" || bad "a supervisor-less layer exited $rc, expected 2: $out"
case "$out" in
  *'UNRESOLVED(no-supervisor)'*) ok "…and it names the reason (UNRESOLVED(no-supervisor))" ;;
  *) bad "…but it does not name the reason: $out" ;;
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
# been deleted with this leg still green.
# ⛔ AND EVERY LEG BELOW HAD TO BE REBUILT: the first version ran `--install` with the REAL `systemctl`, so
# `daemon-reload` was denied for a non-root user, `rc=1`, and ALL FIVE `REFUSES …` legs went green with
# `verify_unit` deleted entirely (measured in review: neutering the guard left 28 ok / 1 failed). A refusal
# that comes from the environment is not a refusal, and a gate with no discriminating power in exactly the
# "false PASS" class this issue is about is worse than no gate. Hence: a fake `systemctl`, and an
# assertion on the REASON each leg prints.
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 0\n' >"$T/fakebin/systemctl"
chmod +x "$T/fakebin/systemctl"
doctor() { # <name> <appended lines>  -> prints the doctored template dir
  local d="$T/doctored-$1"
  mkdir -p "$d" && cp "$TPL/cell-self-pin.timer" "$d/" && cp "$TPL/cell-self-pin.service" "$d/"
  printf '\n[Service]\n%s\n' "$2" >>"$d/cell-self-pin.service"
  printf '%s\n' "$d"
}
install_doctored() { # <dir> <unit-dir>
  runat "$T/home" TEMPLATES_DIR="$1" SYSTEMD_UNIT_DIR="$2" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
    PATH="$T/fakebin:$PATH" bash "$PIN" --install 2>&1
}
# refuses <name> <doctored-dir> <unit-dir> <must-appear-in-the-reason>
refuses() {
  local name="$1" d="$2" u="$3" why="$4" out rc
  out="$(install_doctored "$d" "$u")"; rc=$?
  if [ "$rc" -eq 0 ]; then bad "ACCEPTED $name — the gate does not exist: $out"; return; fi
  if [[ $out == *"$why"* ]]; then ok "REFUSES $name, and says why (\"$why\")";
  else bad "refused $name for the WRONG reason (wanted \"$why\") — an environment failure is not a refusal: $out"; fi
  [ -f "$u/cell-self-pin.service" ] && bad "a refused install ($name) still wrote the unit" \
    || ok "a refused install ($name) wrote nothing"
}
refuses 'WorkingDirectory=/tmp/cell-ai' "$(doctor bootpath 'WorkingDirectory=/tmp/cell-ai')" "$T/u1" 'provisioning clone'
refuses 'WorkingDirectory= outside the clone' "$(doctor workdir 'WorkingDirectory=/srv/harness-current')" "$T/u2" 'WorkingDirectory='
refuses 'ConditionPathExists=' "$(doctor cond 'ConditionPathExists=/srv/harness-current')" "$T/u3" 'ConditionPathExists='
refuses 'an ExecStart in the bootstrap clone' "$(doctor execboot 'ExecStart=/bin/bash /tmp/cell-ai/scripts/cell-self-pin.sh')" "$T/u4" 'provisioning clone'
# ⛔ THIS ONE MUST *REPLACE* THE ExecStart, NOT APPEND ONE. Appending makes it a two-`ExecStart=` unit, and
# the count rule then fires first — the leg would be green while testing a different rule (measured: the
# first version of this leg refused for the wrong reason).
d_execwt="$T/doctored-execwt"
mkdir -p "$d_execwt" && cp "$TPL/cell-self-pin.timer" "$d_execwt/"
sed "s|^ExecStart=/bin/bash .*$|ExecStart=/bin/bash $T/nowhere/cell-self-pin.sh|" \
  "$TPL/cell-self-pin.service" >"$d_execwt/cell-self-pin.service"
refuses 'an ExecStart outside CELL_HOME' "$d_execwt" "$T/u5" 'NOT under CELL_HOME'
# ⛔ A SECOND ExecStart= — `Type=oneshot` permits repeats and systemd runs ALL of them, so a gate that
# inspects only the first line installs an executable directive it never saw (measured: rc=0, both lines
# written). This doctor keeps the LEGITIMATE line first, so only the count rule can catch it.
refuses 'a SECOND ExecStart=' "$(doctor exec2 "ExecStart=/bin/bash $T/nowhere/cell-self-pin.sh")" "$T/u6" 'ExecStart= lines'
# ⛔ AND THE SAME TWO RULES IN THE SPELLINGS SYSTEMD ALSO ACCEPTS — `ExecStart = …` and ` ExecStart=…`
# (systemd strips whitespace before a directive and around `=`). MEASURED in review: the column-0,
# no-space matcher installed both green, and an INDENTED second ExecStart was neither counted nor read,
# so the $CELL_HOME prefix check, the `[ -f ]` check and the `/tmp/cell-ai` token check all inspected
# only the first, legitimate line. These doctors are the non-vacuity proof for a whitespace-tolerant
# parse — the neighbour rules already anchored with `^[[:space:]]*` and the repo's own unit reader
# (`scripts/orchestrator-harness/harness-roles.sh`) does the same for ExecStart.
refuses 'a SPACED WorkingDirectory=' "$(doctor workdir-spaced 'WorkingDirectory = /srv/harness-current')" "$T/u7" 'WorkingDirectory='
refuses 'a SPACED ConditionPathExists=' "$(doctor cond-spaced 'ConditionPathExists = /srv/nope')" "$T/u8" 'ConditionPathExists='
refuses 'an INDENTED second ExecStart=' "$(doctor exec2-indented " ExecStart=/bin/bash $T/nowhere/cell-self-pin.sh")" "$T/u9" 'ExecStart= lines'
refuses 'a SPACED second ExecStart=' "$(doctor exec2-spaced "ExecStart = /bin/bash $T/nowhere/cell-self-pin.sh")" "$T/u10" 'ExecStart= lines'

# ── 4b. ONE ACTUATOR PER PIN — the guard asks BOTH systemd managers ─────────────────────────────────
# ⛔ BARE `systemctl` IS THE SYSTEM MANAGER ONLY, and the shipped sibling installer this guard names as
# the one to keep NEGOTIATES the scope: `install-harness-apply-timer.sh` falls back to `systemctl --user`
# / `$HOME/.config/systemd/user` when passwordless sudo does not answer. On such a box the system probe
# answered "not enabled", the guard stayed silent, and `--install` put TWO mutating actors on one pin.
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-dup" PATH="$T/fakebin:$PATH" \
       bash "$PIN" --install 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "an enabled eldato-harness-apply.timer (SYSTEM manager) refuses the install" \
  || bad "installed beside an enabled eldato-harness-apply.timer in the system manager (rc=$rc): $out"
case "$out" in
  *'system manager'*) ok "…and NAMES the system manager it saw" ;;
  *) bad "…but does not name the scope it saw: $out" ;;
esac
# The user-manager-only box: `systemctl is-enabled …` says no, `systemctl --user is-enabled …` says yes.
mk_fake_user_systemctl() { # <dir> <state-dir> [stubborn]
  local d="$1" s="$2" stubborn="${3:-}"
  mkdir -p "$d" "$s"
  printf '%s\n' \
    '#!/bin/bash' \
    "S='$s'" \
    'case "$*" in' \
    '  "--user is-enabled eldato-harness-apply.timer") [ -f "$S/enabled" ] && exit 0 || exit 1 ;;' \
    '  "--user disable --now eldato-harness-apply.timer") [ -f "$S/stubborn" ] && exit 0; rm -f "$S/enabled"; exit 0 ;;' \
    '  "is-enabled eldato-harness-apply.timer") exit 1 ;;' \
    'esac' \
    'exit 0' >"$d/systemctl"
  chmod +x "$d/systemctl"
  : >"$s/enabled"
  [ -n "$stubborn" ] && : >"$s/stubborn"
  return 0
}
mk_fake_user_systemctl "$T/fakebin-user" "$T/fake-state"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-user" PATH="$T/fakebin-user:$PATH" \
       bash "$PIN" --install 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "…and refuses when only the USER manager carries it (the documented no-sudo fallback)" \
  || bad "installed beside a USER-manager eldato-harness-apply.timer (rc=$rc): $out"
case "$out" in
  *'user manager'*) ok "…naming the user manager, so the operator knows which one to retire" ;;
  *) bad "…but does not name the user manager: $out" ;;
esac
# ⛔ `--takeover` IS THE ONE-ACTOR MIGRATION: it RETIRES the shipped timer rather than racing it. This is
# the decision the review said the change did not make — it is now explicit, and it is the operator's.
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-user" PATH="$T/fakebin-user:$PATH" \
       bash "$PIN" --install --takeover 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then bad "--install --takeover failed (rc=$rc), so there is no one-actor path: $out"
else
  ok "--install --takeover installs (the ONE actuator)"
  case "$out" in
    *'RETIRED eldato-harness-apply.timer'*) ok "…and it RETIRED the shipped actuator, saying so" ;;
    *) bad "…but it did not report the retirement: $out" ;;
  esac
  [ -f "$T/fake-state/enabled" ] && bad "--takeover left eldato-harness-apply.timer ENABLED — two actors on one pin" \
    || ok "…and the timer really is disabled (read back, not assumed)"
fi
# ⛔ AND A RETIREMENT THAT DOES NOT TAKE IS A REFUSAL. A `disable` that returns 0 while the unit stays
# enabled leaves exactly the two-actor state the guard exists to prevent, so the gate reads it back.
mk_fake_user_systemctl "$T/fakebin-stub" "$T/fake-state2" stubborn
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-stub" PATH="$T/fakebin-stub:$PATH" \
       bash "$PIN" --install --takeover 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a retirement that does not TAKE is a refusal (not two actors)" || bad "installed after a failed retirement (rc=$rc): $out"
case "$out" in
  *'still reads ENABLED'*) ok "…and the refusal names the read-back that failed" ;;
  *) bad "…but the refusal does not name the failed read-back: $out" ;;
esac

# ── 5. the shipped template installs, and the written unit carries no bootstrap path ──────────────
runat "$T/home" TEMPLATES_DIR="$TPL" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 SYSTEMD_UNIT_DIR="$T/units2" \
  PATH="$T/fakebin:$PATH" bash "$PIN" --install >"$T/install.log" 2>&1
if [ -f "$T/units2/cell-self-pin.service" ]; then
  ok "the shipped template renders and installs"
  body="$(grep -vE '^[[:space:]]*#' "$T/units2/cell-self-pin.service")"
  if grep -qE 'WorkingDirectory=' <<<"$body" || [[ $body == *'/tmp/cell-ai'* ]]; then
    bad "the INSTALLED unit carries a bootstrap path or a WorkingDirectory="
  else ok "the INSTALLED unit carries neither a bootstrap path nor a WorkingDirectory="; fi
  # ⛔ AND THE EXECSTART MUST LIVE UNDER CELL_HOME — the pass copies itself there for exactly this.
  case "$body" in
    *"ExecStart=/bin/bash $T/home/.pi/agent/scripts/cell-self-pin.sh"*)
      ok "the installed ExecStart is a copy under CELL_HOME (it outlives the checkout it was installed from)" ;;
    *) bad "the installed ExecStart is not under CELL_HOME: $(printf '%s\n' "$body" | grep 'ExecStart')" ;;
  esac
  [ -f "$T/home/.pi/agent/scripts/cell-self-pin.sh" ] \
    && ok "the pass is materialised at the path the unit names" || bad "the unit names a pass that was never placed"
  [ -f "$T/units2/cell-self-pin.timer" ] && ok "the timer installs beside the service" || bad "the timer was not installed"
  # ⛔ AND A FIXED PASS REACHES THE BOX. `pin_script_for_unit` once returned early when the copy merely
  # existed, so install-once-then-reinstall-from-a-newer-checkout kept the OLD bytes — verbatim #3194
  # reproduced inside its own fix.
  printf '\n# freshness probe\n' >>"$T/home/.pi/agent/scripts/cell-self-pin.sh"
  runat "$T/home" TEMPLATES_DIR="$TPL" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 SYSTEMD_UNIT_DIR="$T/units2" \
    PATH="$T/fakebin:$PATH" bash "$PIN" --install >/dev/null 2>&1
  cmp -s "$PIN" "$T/home/.pi/agent/scripts/cell-self-pin.sh" \
    && ok "a re-install REFRESHES the placed copy (a fixed pass reaches the box)" \
    || bad "a re-install kept the stale placed copy — deployed code that was never deployed"
  # ⛔ THE BASE THE UNIT CARRIES IS THE BASE THE PASS USES. The service manager's HOME is not the cell home,
  # so a unit carrying only HOME= left the pass reading a DIFFERENT pin record than the controller.
  printf '%s\n' "$T/home/harness/pintree" >"$T/home/.harness-path"
  mkdir -p "$T/otherhome"
  printf '%s\n' "$T/seed" >"$T/otherhome/.harness-path"
  out="$(runat "$T/home" HOME="$T/otherhome" bash "$PIN" --dry-run 2>&1)"
  case "$out" in
    *"layer=$T/home/harness/pintree"*) ok "with HOME != CELL_HOME the pass reads the CELL_HOME record (no #2215 skew)" ;;
    *) bad "with HOME != CELL_HOME the pass read the wrong record: $out" ;;
  esac
else bad "the shipped template did not install: $(cat "$T/install.log")"; fi

# ── 6. `--status` reads the REF, not a stale local copy of it, and uses the repo's exit codes ───────
# ⛔ THE MEASURED BLINDNESS. #3194 was a pin RECORD that disagreed with the layer the cell executed for
# about a day. `--status` resolved `origin/main` with NO fetch, so against a stale local ref it answered
# "current" — the same lie with a green verdict, in the one verb an operator reads to decide. The pair
# below is the non-vacuity proof: the SAME tree reports `current` without a fetch and `DRIFT` with one.
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m second
if git -C "$T/seed" push -q origin main 2>/dev/null; then
  printf '%s\n' "$T/home/harness/pintree" >"$T/home/.harness-path"
  out="$(pinrun "$T/home" --status-nofetch 2>&1)"; rc=$?
  case "$out" in
    *'NOT fetched'*'verdict        current'*) ok "--status-nofetch shows the local-ref reading (current) and SAYS it may be stale" ;;
    *) bad "--status-nofetch did not report a possibly-stale reading: $out" ;;
  esac
  [ "$rc" -eq 0 ] && ok "…and a no-fetch 'current' exits 0 (this is the blind reading, kept for comparison)" || bad "a no-fetch 'current' exited $rc"
  out="$(pinrun "$T/home" --status 2>&1)"; rc=$?
  case "$out" in
    *'fetched just now'*'verdict        DRIFT'*) ok "--status FETCHES the ref and therefore reports DRIFT against a stale record" ;;
    *) bad "--status is blind: it did not fetch and report DRIFT: $out" ;;
  esac
  # ⛔ 1 FOR DRIFT, NOT 0: `scripts/check-deployed-drift.sh` speaks `0 match / 1 drift / 2 unknown`, and a
  # status verb that reports DRIFT and exits 0 cannot be gated on by anything (#1178's third dialect).
  [ "$rc" -eq 1 ] && ok "…and DRIFT exits 1 (the repo's own 0 match / 1 drift / 2 unknown)" || bad "DRIFT exited $rc, expected 1"
else bad "could not push a second commit — legs 6-8 not exercised"; fi

# ── 7. a FALSE PASS is impossible: apply exiting 0 without moving the record is RED ───────────────
# The fixture's supervisor exits 0 and writes nothing — the measured shape (`applied -> <no stamp
# written>`, exit 0, repeating every tick). The record must be the verdict, not the exit code.
if [ -n "$(git -C "$T/home/harness/pintree" rev-parse HEAD 2>/dev/null)" ]; then
  out="$(pinrun "$T/home" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "apply exits 0 but the record did not move => non-zero (an exit code is not a convergence)" \
    || bad "the pass reported success with the record unmoved — that is #3194's own shape: $out"
  case "$out" in
    *STALE-RECORD*) ok "…and it names the reading (STALE-RECORD: the record did not reach the ref tip)" ;;
    *DRIFT*) ok "…and it reports the drift it acted on" ;;
    *) bad "the pass did not diagnose the unmoved record: $out" ;;
  esac
fi

# ── 8. a LOST record is MENDED (exit 11), not a permanent unhealable RED ─────────────────────────
# ⛔ `harness_apply` writes $HARNESS_PIN_FILE only in its CHANGED branch, so a pin already at the tip
# takes `HARNESS_APPLIED=unchanged` and the record is never written. A cell whose record was lost then
# reads an empty record on EVERY tick and REDs for ever on a box that is in fact correct — #3133 one
# layer up. The recorded answer is `harness-apply-pass.sh`'s: mend the record to the tree `apply`
# created, and report the code that vocabulary already owns (11, `mended`).
TARGET="$(git -C "$T/origin.git" rev-parse main 2>/dev/null)"
SHA12="$(printf '%s' "$TARGET" | cut -c1-12)"
git clone -q "$T/origin.git" "$T/home/harness/$SHA12" 2>/dev/null
mkdir -p "$T/home/harness/$SHA12/scripts/orchestrator-harness"
printf '#!/bin/bash\nexit 0\n' >"$T/home/harness/$SHA12/scripts/cloud-cell-supervisor.sh"
rm -f "$T/home/.harness-path"
out="$(pinrun "$T/home" 2>&1)"; rc=$?
[ "$rc" -eq 11 ] && ok "a LOST pin record is MENDED and reports 11 (not an unhealable RED)" \
  || bad "a lost record exited $rc, expected 11 (mended): $out"
case "$out" in
  *'mended'*) ok "…and the pass SAYS it mended the record" ;;
  *) bad "…but the pass does not say it mended the record: $out" ;;
esac
RECORDED="$(head -1 "$T/home/.harness-path" 2>/dev/null)"
[ "$RECORDED" = "$T/home/harness/$SHA12/scripts/orchestrator-harness" ] \
  && ok "…and the record names the HARNESS DIR the controller execs (not a bare toplevel)" \
  || bad "…but the mended record is '${RECORDED}', not '<tree>/scripts/orchestrator-harness'"

printf '\n%d ok, %d failed\n' "$ok_n" "$bad_n"
[ "$bad_n" -eq 0 ] || { printf 'scratch left at %s\n' "$T"; trap - EXIT; exit 1; }
