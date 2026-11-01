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
  # ⛔ AND PATHS: no leg may reach the HOST's real `systemctl`. `do_pass` now re-reads the one-actor
  # invariant every tick, so a pass running with the real manager on a cell that carries both timers
  # would RETIRE the cell's actuator from a test run — a suite that mutates the box it is guarding.
  # `fakebin-none` answers "not enabled" to everything; the legs that exercise systemd state prepend
  # their own fake, which wins (a later `env` assignment overrides an earlier one).
  env -u HARNESS -u HARNESS_PIN_FILE -u HARNESS_PIN_DIR -u HARNESS_REPO -u O -u STAMP \
      -u TEMPLATES_DIR -u SYSTEMD_UNIT_DIR -u CELL_SELF_PIN_INTERVAL_MIN \
      -u CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR -u CELL_SELF_PIN_SRC \
      PATH="$T/fakebin-none:$PATH" \
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
      PATH="$T/fakebin-none:$PATH" \
      CELL_HOME="$h" HOME="$h" "$@"
}
pinrun() { local h="$1"; shift; runat "$h" bash "$PIN" "$@"; }

# mk_sup <path> [argv-log] — a supervisor fixture. WITHOUT a log it exits 0 and writes nothing (the
# "apply said 0 and did nothing" shape); WITH one it RECORDS THE ARGV it was called with, because the
# flag pair `--force --pin-only` is the one contract the header calls load-bearing and, until this was
# added, NOTHING in this suite read it (measured in review: mutating the call to a bare `apply` left the
# suite at 66 ok / 0 failed — a mutant that survives the whole suite is an ungated behaviour).
mk_sup() {
  local p="$1" log="${2:-}"
  mkdir -p "$(dirname "$p")"
  if [ -n "$log" ]; then
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\nexit 0\n' "$log" >"$p"
  else
    printf '#!/bin/bash\nexit 0\n' >"$p"
  fi
  chmod +x "$p"
}
# mk_sup_pin <path> <record-file-contents> — a supervisor that MOVES the pin record, so a leg can pin the
# containment rule (it must refuse a record that moved onto a tree off the ref's line) independently of
# the unmoved-record rule.
mk_sup_pin() {
  local p="$1" rec="$2"
  mkdir -p "$(dirname "$p")"
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" >"${HARNESS_PIN_FILE:-$CELL_HOME/.harness-path}"\nexit 0\n' "$rec" >"$p"
  chmod +x "$p"
}

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
# ⛔ THE PIN TREE'S SUPERVISOR RECORDS ITS ARGV — see `mk_sup`. Every apply leg goes through it.
mk_sup "$T/home/harness/pintree/scripts/cloud-cell-supervisor.sh" "$T/argv.log"
# ⛔ A MANAGER WITH NO UNITS, on PATH for every `runat`. See the note there: no leg may reach the host's
# real systemd, because `do_pass` now re-reads (and can re-retire) the one-actor invariant every tick.
mkdir -p "$T/fakebin-none"
printf '#!/bin/bash\ncase "$*" in *is-enabled*) exit 1 ;; esac\nexit 0\n' >"$T/fakebin-none/systemctl"
chmod +x "$T/fakebin-none/systemctl"
mkdir -p "$T/home/orchestrator" "$T/empty"
# The seed doubles as the target of the EXPLICIT-record leg below, so it carries a supervisor too — a
# record may point at any resolved layer, and a layer with no supervisor is its own RED (asserted later).
mkdir -p "$T/seed/scripts"
mk_sup "$T/seed/scripts/cloud-cell-supervisor.sh"

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
mkdir -p "$T/home/harness/other/scripts/orchestrator-harness"
mk_sup "$T/home/harness/other/scripts/cloud-cell-supervisor.sh"
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
# ⛔ A COPY OF THE PASS IS ALREADY PLACED, BEFORE ANY REFUSAL IS EXERCISED. Leg 1 asserted that
# `--print-unit` writes nothing (no copy here yet), so this is the first placement — and it is what makes
# «a REFUSED install must not replace the placed copy» assertable at all. Its bytes are a sentinel, not
# this file: a mutant that moves `place_pass` above `verify_unit` overwrites it and `cmp` catches it.
PLACED="$T/home/.pi/agent/scripts/cell-self-pin.sh"
mkdir -p "$(dirname "$PLACED")"
printf '#!/bin/bash\n# a copy placed by an EARLIER install — a refused install must not replace these bytes\n' >"$PLACED"
cp "$PLACED" "$T/placed.before"
doctor() { # <name> <appended lines>  -> prints the doctored template dir
  local d="$T/doctored-$1"
  mkdir -p "$d" && cp "$TPL/cell-self-pin.timer" "$d/" && cp "$TPL/cell-self-pin.service" "$d/"
  printf '\n[Service]\n%s\n' "$2" >>"$d/cell-self-pin.service"
  printf '%s\n' "$d"
}
# doctor_rw <name> <sed-expr> — a doctor that must REWRITE an existing line rather than append one: the
# rules on `Environment=CELL_HOME=`, `SuccessExitStatus=` and the ExecStart INTERPRETER are all about a
# line the shipped template already carries, so an appended duplicate tests nothing (systemd merges the
# section, and a second `ExecStart=` would trip the count rule first — the leg would pass on a rule it
# did not name, which is exactly the vacuity the doctors exist to remove).
doctor_rw() { # <name> <sed-expr applied to the service template>
  local d="$T/doctored-$1"
  mkdir -p "$d" && cp "$TPL/cell-self-pin.timer" "$d/"
  sed "$2" "$TPL/cell-self-pin.service" >"$d/cell-self-pin.service"
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
  # ⛔ AND IT MUST NOT HAVE REPLACED THE PASS EITHER. «Deployed code that was never verified» is this
  # change's own headline defect, and the refusal path is where it came back: `place_pass` used to run
  # inside the renderer, so a REFUSED `--install` had already overwritten the copy at
  # `$CELL_HOME/.pi/agent/scripts/cell-self-pin.sh` before `verify_unit` could refuse. Nothing asserted it:
  # the old legs ran before ANY copy existed, so moving `place_pass` above `verify_unit` changed no result.
  # `$PLACED` is seeded once, before the doctors, and every refusal re-checks those exact bytes.
  if cmp -s "$T/placed.before" "$PLACED"; then ok "a refused install ($name) did NOT replace the already-placed pass"
  else bad "a refused install ($name) REPLACED the placed pass before verification — deployed code that was never verified"; cp "$T/placed.before" "$PLACED"; fi
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
# ⛔ THE REST OF THE EXECUTABLE-DIRECTIVE FAMILY, refused BY NAME. Measured in review:
# `ExecStartPre=/bin/bash /srv/nowhere/bootstrap.sh` appended to the template installed with rc=0 and every
# leg green — `Type=oneshot` RUNS it, and `directive $body ExecStart` never saw it. A guard that covers one
# name in a family is a guard the next template edit walks around.
refuses 'an ExecStartPre=' "$(doctor execpre "ExecStartPre=/bin/bash $T/nowhere/bootstrap.sh")" "$T/u11" 'ExecStartPre='
refuses 'a SPACED ExecStopPost=' "$(doctor stoppost "ExecStopPost = /bin/bash $T/nowhere/cleanup.sh")" "$T/u12" 'ExecStopPost='
# ⛔ FOUR RULES THAT HAD NO DOCTOR AT ALL — deleting any one of them left this suite green, which the body's
# «one doctor per rule» claim does not survive. Each doctor below trips ITS rule and nothing else:
#   · the INTERPRETER rule is individually gating only because ExecStart is parsed as interpreter+payload;
#     `/bin/sh <a path under CELL_HOME>` passes every other rule, so nothing else can answer for it.
#   · the CELL_HOME environment rule is the only check on `Environment=`;
#   · the two SuccessExitStatus rules (present; and only 0/11 with 0 included) are the difference between a
#     RED and a green on every failure this unit exists to surface.
refuses 'an ExecStart that is not /bin/bash' "$(doctor_rw interp "s|^ExecStart=/bin/bash .*$|ExecStart=/bin/sh $T/home/.pi/agent/scripts/cell-self-pin.sh|")" "$T/u13" "not '/bin/bash'"
refuses 'a MISSING Environment=CELL_HOME=' "$(doctor_rw nocellhome '/^Environment=CELL_HOME=/d')" "$T/u14" 'Environment=CELL_HOME='
refuses 'a MISSING SuccessExitStatus=' "$(doctor_rw noexit '/^SuccessExitStatus=/d')" "$T/u15" 'must declare SuccessExitStatus'
refuses 'a WIDENED SuccessExitStatus=' "$(doctor_rw wideexit 's|^SuccessExitStatus=.*$|SuccessExitStatus=0 11 1|')" "$T/u16" 'neither 0'
# ⛔ AND THE macOS SPELLING OF THE CLONE. `/tmp` IS `/private/tmp` there, and the token rule required the
# literal `/tmp/` — so this installed GREEN. It is reachable as an `Environment=` value, which NOTHING else
# inspects (the `declares`/`$CELL_HOME` rules read only `WorkingDirectory=` and `ExecStart=`), and the pass
# that read it would derive a different pin record than the controller. This suite already resolves `/tmp`
# for its own git paths (`pwd -P`); the guard has to see the same spelling.
refuses 'an Environment= naming /private/tmp/cell-ai' "$(doctor privtmp 'Environment=HARNESS_PIN_FILE=/private/tmp/cell-ai/.harness-path')" "$T/u17" 'provisioning clone'

# ── 4b. ONE ACTUATOR PER PIN — the guard asks BOTH systemd managers, and retires BOTH ────────────
# ⛔ BARE `systemctl` IS THE SYSTEM MANAGER ONLY, and the shipped sibling installer this guard names as
# the one to keep NEGOTIATES the scope: `install-harness-apply-timer.sh` falls back to `systemctl --user`
# / `$HOME/.config/systemd/user` when passwordless sudo does not answer. On such a box the system probe
# answered "not enabled", the guard stayed silent, and `--install` put TWO mutating actors on one pin.
# ⛔ ONE FAKE MANAGER, PER-SCOPE AND PER-UNIT STATE. The old fixture faked ONE scope at a time and
# every `refuses …` leg below fails inside `verify_unit`, which runs BEFORE any retirement — so no leg
# could pin what `--takeover` does once it starts retiring. This fake keys its state by
# `<scope>-<unit>`, so both managers can carry the shipped timer, ours can be enabled or not, and a
# retirement can be made to lie (a `disable` that exits 0 and changes nothing) or to be refused.
mk_scoped_systemctl() { # <dir> <state-dir>
  local d="$1" s="$2"
  mkdir -p "$d" "$s"
  printf '%s\n' \
    '#!/bin/bash' \
    "S='$s'" \
    'scope=system' \
    'if [ "${1:-}" = "--user" ]; then scope=user; shift; fi' \
    'verb="${1:-}"; shift 2>/dev/null || true' \
    '[ "${1:-}" = "--now" ] && shift' \
    'unit="${1:-}"' \
    'st="$S/$scope-$unit"' \
    'case "$verb" in' \
    '  is-enabled) [ -f "$st" ] && exit 0 || exit 1 ;;' \
    '  disable) [ -f "$S/$scope-stubborn" ] && exit 0; rm -f "$st"; exit 0 ;;' \
    '  enable) if [ "$unit" = cell-self-pin.timer ] && [ -f "$S/fail-enable-self" ]; then exit 1; fi; : >"$st"; exit 0 ;;' \
    'esac' \
    'exit 0' >"$d/systemctl"
  chmod +x "$d/systemctl"
  return 0
}
SHIPPED=eldato-harness-apply.timer
# ── (a) a SYSTEM-manager-only box refuses, and names that scope ────────────────────────────────
mk_scoped_systemctl "$T/fake-1sys" "$T/state-1sys"; : >"$T/state-1sys/system-$SHIPPED"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-sys" PATH="$T/fake-1sys:$PATH" \
       bash "$PIN" --install 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "an enabled eldato-harness-apply.timer (SYSTEM manager) refuses the install" \
  || bad "installed beside an enabled eldato-harness-apply.timer in the system manager (rc=$rc): $out"
case "$out" in
  *'system manager'*) ok "…and NAMES the system manager it saw" ;;
  *) bad "…but does not name the scope it saw: $out" ;;
esac
# ── (b) the documented no-sudo fallback: only the USER manager carries it ─────────────────────────
mk_scoped_systemctl "$T/fake-1user" "$T/state-1user"; : >"$T/state-1user/user-$SHIPPED"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-usr" PATH="$T/fake-1user:$PATH" \
       bash "$PIN" --install 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "…and refuses when only the USER manager carries it (the documented no-sudo fallback)" \
  || bad "installed beside a USER-manager eldato-harness-apply.timer (rc=$rc): $out"
case "$out" in
  *'user manager'*) ok "…naming the user manager, so the operator knows which one to retire" ;;
  *) bad "…but does not name the user manager: $out" ;;
esac
# ── (c) BOTH managers carry it: `--takeover` must retire BOTH, not the first one it finds ────────
# ⛔ MEASURED FALSE PASS, NOT A HYPOTHETICAL: `actuator_scope` returned ONLY the first enabled scope, so
# on a box with the system install AND the no-sudo user fallback `--takeover` retired the system one,
# read THAT one back, printed "ONE actuator on this pin" and exited 0 — while the user-scope timer was
# never touched, never re-read, and kept running. Two mutating `apply --force --pin-only` actors, a
# success exit, and a claim of single ownership.
mk_scoped_systemctl "$T/fake-both" "$T/state-both"
: >"$T/state-both/system-$SHIPPED"; : >"$T/state-both/user-$SHIPPED"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-both" PATH="$T/fake-both:$PATH" \
       bash "$PIN" --install --takeover 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then bad "--install --takeover refused on a box where BOTH managers carry the shipped timer (rc=$rc): $out"
else
  ok "--install --takeover installs on a box carrying the shipped timer in BOTH managers"
  case "$out" in
    *'RETIRED eldato-harness-apply.timer (system manager)'*'RETIRED eldato-harness-apply.timer (user manager)'*|*'RETIRED eldato-harness-apply.timer (user manager)'*'RETIRED eldato-harness-apply.timer (system manager)'*)
      ok "…retiring it in BOTH managers, each read back" ;;
    *) bad "…but it did not report retiring every scope it found: $out" ;;
  esac
  if [ -f "$T/state-both/system-$SHIPPED" ] || [ -f "$T/state-both/user-$SHIPPED" ]; then
    bad "--takeover left eldato-harness-apply.timer ENABLED in $( [ -f "$T/state-both/system-$SHIPPED" ] && printf 'the system ' ; [ -f "$T/state-both/user-$SHIPPED" ] && printf 'the user ' )manager — two actors on one pin"
  else ok "…and the timer really is disabled in BOTH managers (read back, not assumed)" ; fi
  [ -f "$T/state-both/system-cell-self-pin.timer" ] && ok "…and this unit is enabled, so the pin has an actuator" \
    || bad "--takeover retired the shipped actuator and did NOT enable this one — zero actors"
fi
# ── (d) a retirement that does not TAKE is a refusal, and the ones that DID take are put back ────
# A `disable` that returns 0 while the unit stays enabled leaves exactly the two-actor state the guard
# exists to prevent, so the gate reads it back. And because the system scope is retired FIRST, a lying
# user scope must not leave the box with the system actuator gone and nothing else in place.
mk_scoped_systemctl "$T/fake-stub" "$T/state-stub"
: >"$T/state-stub/system-$SHIPPED"; : >"$T/state-stub/user-$SHIPPED"; : >"$T/state-stub/user-stubborn"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-stub" PATH="$T/fake-stub:$PATH" \
       bash "$PIN" --install --takeover 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a retirement that does not TAKE is a refusal (not two actors)" || bad "installed after a failed retirement (rc=$rc): $out"
case "$out" in
  *'still reads ENABLED'*) ok "…and the refusal names the read-back that failed" ;;
  *) bad "…but the refusal does not name the failed read-back: $out" ;;
esac
[ -f "$T/state-stub/system-$SHIPPED" ] \
  && ok "…and the retirement that DID take was ROLLED BACK (the box keeps an actuator, not zero)" \
  || bad "a failed migration left the system-scope actuator DISABLED and this unit not enabled — zero pin actuators"
# ── (e) an install that fails AFTER the retirement rolls it back ──────────────────────────────────
# ⛔ THE FIRST VERSION RETIRED FIRST AND INSTALLED SECOND, with no rollback: any failure in mkdir, the
# writes, `daemon-reload` or `enable` returned non-zero with the shipped timer already disabled AND
# stopped, and nothing re-enabled it — measured, `--takeover` against an unwritable unit dir left ZERO
# pin actuators, i.e. the "nothing advances the layer" state #3194 is about, reached by following this
# change's own documented migration.
mk_scoped_systemctl "$T/fake-enfail" "$T/state-enfail"
: >"$T/state-enfail/system-$SHIPPED"; : >"$T/state-enfail/fail-enable-self"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-enfail" PATH="$T/fake-enfail:$PATH" \
       bash "$PIN" --install --takeover 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "an install that fails after the retirement returns non-zero" || bad "a failed enable reported success (rc=$rc): $out"
case "$out" in
  *'ROLLED BACK'*) ok "…and it ROLLS BACK, saying so, instead of leaving the box unpinned" ;;
  *) bad "…but nothing rolled the retired actuator back: $out" ;;
esac
[ -f "$T/state-enfail/system-$SHIPPED" ] \
  && ok "…the shipped timer is enabled again (one actuator preserved through a failed migration)" \
  || bad "a failed migration left ZERO pin actuators where the box started with one"

# ── 4c. THE ONE-ACTOR INVARIANT IS RE-READ ON EVERY TICK, NOT ONLY AT INSTALL TIME ────────────────
# ⛔ THE RE-ARM IS BY DESIGN, IN THE SHIPPED CODE: `cloud-cell-bringup.sh`'s `check_harness_apply` runs
# `install-harness-apply-timer.sh --install` on EVERY bring-up (`die` on a non-zero rc), and that
# installer ends in `systemctl enable --now eldato-harness-apply.timer` precisely because it is what
# re-arms a timer somebody disabled by hand. So a box that went through `--takeover` gets the SECOND
# actor back at its next bring-up. Nothing read that: the invariant the installer refuses to break was
# re-broken minutes later, silently, with the box's colour staying green. A hermetic, CURRENT home: the
# pass's only job in these legs is the re-check, and "current" keeps the pin out of the assertions.
TICK="$T/tick"
mkdir -p "$TICK/harness" "$TICK/orchestrator"
git clone -q "$T/origin.git" "$TICK/harness/tree" 2>/dev/null
mkdir -p "$TICK/harness/tree/scripts"
mk_sup "$TICK/harness/tree/scripts/cloud-cell-supervisor.sh"
printf '%s\n' "$TICK/harness/tree" >"$TICK/.harness-path"
mk_scoped_systemctl "$T/fake-rearm" "$T/state-rearm"
: >"$T/state-rearm/system-cell-self-pin.timer"      # this unit IS the installed actuator
: >"$T/state-rearm/system-$SHIPPED"                 # …and bringup has just re-armed the shipped one
out="$(runat "$TICK" PATH="$T/fake-rearm:$PATH" bash "$PIN" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a pass on a current box still EXITS 0 when it finds a re-armed second actuator (it heals, it does not RED)" \
  || bad "the pass failed (rc=$rc) on a box whose current state was fine and whose duplicate it could retire: $out"
[ -f "$T/state-rearm/system-$SHIPPED" ] \
  && bad "a RE-ARMED eldato-harness-apply.timer survived the tick — two mutating actors on one pin, unobserved" \
  || ok "…and the re-armed eldato-harness-apply.timer is retired again (the invariant is durable, not an install-time ritual)"
case "$out" in
  *'RE-ARMED'*) ok "…and the pass SAYS the second actor came back, rather than healing in silence" ;;
  *) bad "…but nothing in the output says the actuator had been re-armed: $out" ;;
esac
# ⛔ AND THE OPERATOR'S READ SHOWS IT TOO. `--status` is the verb an operator runs first; “is a second
# actor back?” must be answerable there, not only in journald. Advisory: the 0/1/2 verdict stays the
# drift vocabulary.
: >"$T/state-rearm/system-$SHIPPED"
out="$(runat "$TICK" PATH="$T/fake-rearm:$PATH" bash "$PIN" --status-nofetch 2>&1)"
case "$out" in
  *'second actuator system '*|*'second actuator user '*|*'second actuator system user '*) ok "--status also reports the re-armed second actuator (the operator's read, not just journald)" ;;
  *) bad "--status does not report the re-armed second actuator: $out" ;;
esac
# And a re-arm that cannot be retired is a RED, never a warning: on a current box the pin needs no work,
# so the duplicate is the ONLY thing that can make the tick fail — the leg cannot pass on another guard.
mk_scoped_systemctl "$T/fake-rearm-stub" "$T/state-rearm-stub"
: >"$T/state-rearm-stub/system-cell-self-pin.timer"
: >"$T/state-rearm-stub/system-$SHIPPED"; : >"$T/state-rearm-stub/system-stubborn"
out="$(runat "$TICK" PATH="$T/fake-rearm-stub:$PATH" bash "$PIN" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a re-armed actuator that cannot be retired is a RED, not a silent second actor" \
  || bad "a tick that could NOT retire the re-armed actuator still exited 0 (rc=$rc): $out"
case "$out" in
  *'DUPLICATE-ACTUATOR'*) ok "…and it names the state (DUPLICATE-ACTUATOR) and the manager it saw" ;;
  *) bad "…but the failure is not named: $out" ;;
esac
# ⛔ AND A MANUAL RUN MUST NOT RETIRE SOMEONE ELSE'S ACTUATOR. If this unit is not installed in either
# manager, the pass is not a second scheduled actor: it reports and touches nothing.
mk_scoped_systemctl "$T/fake-manual" "$T/state-manual"
: >"$T/state-manual/system-$SHIPPED"
out="$(runat "$TICK" PATH="$T/fake-manual:$PATH" bash "$PIN" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a MANUAL run beside the shipped actuator exits 0 (it is not a second scheduled actor)" \
  || bad "a manual run failed (rc=$rc) instead of reporting that it is not a scheduled actor: $out"
[ -f "$T/state-manual/system-$SHIPPED" ] \
  && ok "…and it did NOT retire an actuator it does not replace (a rehearsal never disables the shipped timer)" \
  || bad "a manual run RETIRED the shipped actuator — a test or a rehearsal must never disable the box's pin"

# ── 5. the shipped template installs, and the written unit carries no bootstrap path ──────────────
# ⛔ THE EXIT CODE IS ASSERTED, not merely "the files exist": a leg that only looks for the artifacts
# passes when `--install` returns 1 AFTER writing them, which is exactly the shape a half-migration has.
runat "$T/home" TEMPLATES_DIR="$TPL" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 SYSTEMD_UNIT_DIR="$T/units2" \
  PATH="$T/fakebin:$PATH" bash "$PIN" --install >"$T/install.log" 2>&1; install_rc=$?
[ "$install_rc" -eq 0 ] && ok "the shipped template installs (rc=0)" || bad "the shipped template install exited ${install_rc}: $(cat "$T/install.log")"
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

# ── 7. a FALSE PASS is impossible: `apply` exiting 0 is not a convergence ─────────────────────────
# ⛔ THE TWO RULES THAT USED TO LIVE HERE OVERLAPPED, SO NEITHER WAS GATED. There was "the record must
# have MOVED" and "the record must CONTAIN the tip"; on every state where the first fired the second
# fired too, so a mutant disabling EITHER ONE ALONE survived the whole suite (measured in review:
# `:294 → if false` and `:299 → if false` each at 66 ok / 0 failed, both at 65 ok / 1 failed).
# Containment IS the convergence rule — it fails on #3194's own shape (an unmoved record that was 17
# commits behind does not contain the tip) — and the legs below pin it in BOTH directions: an unmoved
# record that does NOT contain the tip is RED, a record that MOVED off the ref's line is RED, and a
# record that legitimately sits AHEAD (it contains the tip) is GREEN rather than the false RED the
# deleted equality rule would have produced.
if [ -n "$(git -C "$T/home/harness/pintree" rev-parse HEAD 2>/dev/null)" ]; then
  : >"$T/argv.log"
  out="$(pinrun "$T/home" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "apply exits 0 but the record did not move => non-zero (an exit code is not a convergence)" \
    || bad "the pass reported success with the record unmoved — that is #3194's own shape: $out"
  case "$out" in
    *STALE-RECORD*'did not move'*) ok "…and it names the reading AND the shape (STALE-RECORD: the record did not move, so it does not contain the ref tip)" ;;
    *) bad "the pass did not diagnose the unmoved record: $out" ;;
  esac
  # ⛔ AND THE SUPERVISOR'S ARGV IS THE CONTRACT. `apply --force --pin-only` is the ONE invocation the
  # header calls load-bearing — `--pin-only` because a bare `apply` dies on a live controller, `--force`
  # WITHOUT it because that re-seeds the state dir the controller is executing from (the #2215 skew).
  # NOTHING read the argv, so mutating the call to a bare `apply` left the suite green (measured). The
  # fixture records what it was called with; this asserts the exact string, both flags, nothing else.
  ARGV="$(tail -1 "$T/argv.log" 2>/dev/null)"
  [ "$ARGV" = "apply --force --pin-only" ] \
    && ok "the pass invokes 'apply --force --pin-only' — BOTH flags, in that order (#2215)" \
    || bad "the pass invoked the supervisor as '${ARGV:-<never called>}', not 'apply --force --pin-only' (a bare '--force' re-seeds a live controller's state dir; a bare 'apply' dies on it)"
fi
# ⛔ A RECORD THAT *MOVED* ONTO A TREE OFF THE REF'S LINE IS STILL RED, and only the containment rule can
# say so: the old unmoved-equality rule cannot see it (the value changed). Fixture: one clone at the ref
# tip's PARENT (the record), an orphan-side commit on the same object database (where the supervisor will
# repoint the record), so `now != applied` and `now` still does not contain the ref tip — and every rev
# resolves in the repo the check runs in, so the verdict is "not an ancestor", not "unknown object".
OFFREPO="$T/home-off/harness/repo"
mkdir -p "$T/home-off/harness" "$T/home-off/orchestrator"
git clone -q "$T/origin.git" "$OFFREPO" 2>/dev/null
git -C "$OFFREPO" checkout -q --orphan side >/dev/null 2>&1
git -C "$OFFREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "a line of history origin never had"
SIDE="$(git -C "$OFFREPO" rev-parse HEAD 2>/dev/null)"
FIRST="$(git -C "$OFFREPO" rev-list --max-parents=0 main 2>/dev/null | tail -1)"
git -C "$OFFREPO" worktree add -f -q "$T/offapplied" "$FIRST" >/dev/null 2>&1
git -C "$OFFREPO" worktree add -f -q "$T/offmoved" "$SIDE" >/dev/null 2>&1
mk_sup_pin "$T/offapplied/scripts/cloud-cell-supervisor.sh" "$T/offmoved"
printf '%s\n' "$T/offapplied" >"$T/home-off/.harness-path"
out="$(pinrun "$T/home-off" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a record that MOVED onto a tree off the ref's line is still RED" \
  || bad "the pass reported success for a record that moved to a tree which does not contain the ref tip (rc=$rc): $out"
case "$out" in
  *'does not contain the ref tip'*) ok "…and the diagnosis names CONTAINMENT (moved, but off the ref's line)" ;;
  *'did not move'*) bad "…but it reported the WRONG shape (unmoved) for a record that moved: $out" ;;
  *) bad "the pass did not diagnose the off-line record: $out" ;;
esac
# ⛔ AND A RECORD ALREADY AHEAD OF THE TIP IS GREEN. The deleted rule compared the record to the ref for
# EQUALITY, so a box whose record sat on a commit containing the tip — apply legitimately no-opes — RED'd
# every tick: a periodic false RED on `systemctl --failed`, which is how operators learn to ignore the
# colour this whole change depends on. Containment, not equality.
mkdir -p "$T/home-ahead/harness" "$T/home-ahead/orchestrator"
git clone -q "$T/origin.git" "$T/home-ahead/harness/tree" 2>/dev/null
git -C "$T/home-ahead/harness/tree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "a commit ON TOP of the tip"
mk_sup "$T/home-ahead/harness/tree/scripts/cloud-cell-supervisor.sh"
printf '%s\n' "$T/home-ahead/harness/tree" >"$T/home-ahead/.harness-path"
out="$(pinrun "$T/home-ahead" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a record that ALREADY CONTAINS the ref tip is green — containment, not equality (no false RED)" \
  || bad "a record ahead of the ref tip was reported as ${rc} — that is the periodic false RED this rule exists to avoid: $out"

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

# ── 9. two ways a reading that is NOT a green used to come back GREEN ──────────────────────────
# ⛔ (a) A FAILED FETCH IS `2 = unknown`, NOT `0 = current`, AND MUST NOT PRINT «current». The status verb
# prints "this is not a green" and then fell through to the SAME equality test against the LOCAL ref it
# never refreshed, returning `verdict current` + exit 0 — the artifact contradicting itself in one screen,
# with the only monitorable signal saying green for exactly the reading the header calls unverified. The
# fixture is a clone whose `origin` URL answers nothing, sitting AT its own local `origin/main`, so a
# fetch-agnostic comparison reports `current` while a fetch-aware one must refuse to decide.
BADHOME="$T/home-badfetch"
mkdir -p "$BADHOME/harness" "$BADHOME/orchestrator"
git clone -q "$T/origin.git" "$BADHOME/harness/tree" 2>/dev/null
git -C "$BADHOME/harness/tree" remote set-url origin "$T/no-such-origin.git"
printf '%s\n' "$BADHOME/harness/tree" >"$BADHOME/.harness-path"
# NON-VACUITY: the same tree IS `current` on the unfetched reading, so the leg below is discriminating
# rather than passing because the tree happens to be behind.
out="$(pinrun "$BADHOME" --status-nofetch 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "(control) the same tree reads 'current' on the UNFETCHED comparison, so the leg below discriminates" \
  || bad "(control) the unfetched reading is $rc, not 0 — the fetch-failure leg would pass for the wrong reason: $out"
out="$(pinrun "$BADHOME" --status 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "a FAILED fetch exits 2 (unknown) — an unrefreshed ref cannot tell current from DRIFT" \
  || bad "a failed fetch exited $rc, expected 2 (unknown): $out"
case "$out" in
  *'verdict        current'*) bad "a FAILED fetch still printed 'verdict current' — a reading the pass itself called unverified, reported GREEN" ;;
  *'UNKNOWN'*) ok "…and the verdict line says UNKNOWN, so the self-contradiction is gone" ;;
  *) bad "…but the verdict line does not name UNKNOWN: $out" ;;
esac
# ⛔ (b) A RENDER REFUSES WHEN `CELL_HOME` IS UNSET. The installer's default is `$HOME`; the READER of the
# record it derives from defaults to `/tmp/cell-home` (cloud-cell-supervisor.sh:134). Rendering bakes
# `Environment=CELL_HOME=` into /etc/systemd/system for ever, and `verify_unit`'s CELL_HOME assertion is
# self-referential (it compares the artifact with the same already-wrong value), so nothing else can catch
# it. Refusing at the one moment the value becomes permanent is the only fail-closed answer.
out="$(env -u CELL_HOME -u HARNESS -u HARNESS_PIN_FILE -u HARNESS_PIN_DIR -u HARNESS_REPO -u O -u STAMP \
     -u TEMPLATES_DIR -u SYSTEMD_UNIT_DIR -u CELL_SELF_PIN_INTERVAL_MIN \
     -u CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR -u CELL_SELF_PIN_SRC \
     PATH="$T/fakebin-none:$PATH" HOME="$T/home" bash "$PIN" --print-unit 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "--print-unit REFUSES to render when CELL_HOME is unset (the base would be \$HOME, not the supervisor's)" \
  || bad "a render with CELL_HOME unset succeeded (rc=$rc) — it bakes a WRONG base into the unit: $out"
case "$out" in
  *'CELL_HOME'*'/tmp/cell-home'*) ok "…and the refusal names the divergence (CELL_HOME vs the supervisor's /tmp/cell-home)" ;;
  *) bad "…but the refusal does not name the divergence it refused for: $out" ;;
esac

printf '\n%d ok, %d failed\n' "$ok_n" "$bad_n"
[ "$bad_n" -eq 0 ] || { printf 'scratch left at %s\n' "$T"; trap - EXIT; exit 1; }
