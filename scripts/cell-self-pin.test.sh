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
# a cell lane exports (cloud-cell-supervisor.sh::3562/3607 exports them into every controller) and points
# ⛔ `::3092/3137` WAS THE STALE SPELLING OF THIS CITATION (round-13 review, P2): it was correct at
# `eb7e4e81` and the exports moved with later merges from main. A pointer into the wrong line is a reader
# checking code that does not do what the sentence claims, which is worse than no pointer at all.
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
# ⛔ THE DROP-IN ROOT IS HERMETIC PER RUN (round-12 review, P2). Unsetting the seam made the installer
# scan the REAL `/etc/systemd/system`, `/run`, `/usr/local/lib` and `/usr/lib` roots — measured at 151
# reads of each real root per run, including 66 reads of this host's own
# `/etc/systemd/system/cell-self-pin.service.d/user.conf`. A host drop-in that is benign makes every install
# leg pass for a reason unrelated to the code under test; the same file carrying `WorkingDirectory=` or a
# `Condition*` (precisely the classes `verify_dropins` refuses) reds them all. A suite that gates the
# effective unit must not READ the host's effective unit.
mkdir -p "$T/dropins-hermetic"
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
# AN — which value PARSER the pass is told to ask. `none` is the DEFAULT so every leg is hermetic and
# deterministic (no leg depends on whether THIS host has systemd-analyze); a leg that exercises the
# delegation tier sets AN to a fake for one call and puts it back, so the tier cannot leak between legs.
AN=none
runat() {
  local h="$1"; shift
  # ⛔ AND PATHS: no leg may reach the HOST's real `systemctl`. `do_pass` now re-reads the one-actor
  # invariant every tick, so a pass running with the real manager on a cell that carries both timers
  # would RETIRE the cell's actuator from a test run — a suite that mutates the box it is guarding.
  # `fakebin-none` answers "not enabled" to everything; the legs that exercise systemd state prepend
  # their own fake, which wins (a later `env` assignment overrides an earlier one).
  env -u HARNESS -u HARNESS_PIN_FILE -u HARNESS_PIN_DIR -u HARNESS_REPO -u O -u STAMP \
      -u TEMPLATES_DIR -u SYSTEMD_UNIT_DIR -u CELL_SELF_PIN_INTERVAL_MIN \
      -u CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR -u CELL_SELF_PIN_SRC -u HARNESS_REF \
      -u CELL_SELF_PIN_SYSTEMCTL -u CELL_SELF_PIN_ANALYZE \
      CELL_SELF_PIN_DROPIN_ROOTS="$T/dropins-hermetic" \
      CELL_SELF_PIN_SYSTEMCTL=systemctl \
      CELL_SELF_PIN_ANALYZE="${AN:-none}" \
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
      -u CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR -u CELL_SELF_PIN_SRC -u HARNESS_REF \
      -u CELL_SELF_PIN_SYSTEMCTL -u CELL_SELF_PIN_ANALYZE \
      CELL_SELF_PIN_DROPIN_ROOTS="$T/dropins-hermetic" \
      CELL_SELF_PIN_SYSTEMCTL=systemctl \
      CELL_SELF_PIN_ANALYZE="${AN:-none}" \
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
# ⛔ AND THE STUB MUST ANSWER THE WAY systemd DOES. `is-enabled` prints its ANSWER WORD (`enabled` /
# `disabled` / `masked` / …); a stub that exits 1 having printed NOTHING is a manager that failed to
# answer, not one that answered "disabled", and the two are now (correctly) different verdicts. The
# fixture said "not enabled" with silence, so it silently certified the same fail-open `scope_state`
# had — found by review, fixed on both sides rather than by weakening the reader.
printf '#!/bin/bash\ncase "$*" in *is-enabled*) echo disabled; exit 1 ;; esac\nexit 0\n' >"$T/fakebin-none/systemctl"
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

# ── 2b. THE PIN-ROOT FALLBACK: NEWEST BY mtime, AND IT SAYS WHAT IT IS NOT ──────────────────────────
# ⛔ TWO RULES NOTHING PINNED (measured in review: `ls -1dt` → `ls -1d`, and the deletion of the stderr
# warning, each left the suite at 280 ok / 0 failed). The fallback picks WHICH TREE GETS PINNED when the
# record is unusable, so picking lexicographically means pinning an arbitrary commit — and it is that
# commit's supervisor which then executes. And a fallback that does not SAY it is unproven is the drift this
# unit exists to prevent, inside the unit itself. The fixture makes the two orders disagree: `aaa` sorts
# FIRST but is OLDER; `zzz` sorts LAST but is NEWER, so only `-t` can select `zzz`.
FB="$T/home-fb"
mkdir -p "$FB/harness" "$FB/orchestrator"
git init -q "$FB/harness/aaa" 2>/dev/null; mkdir -p "$FB/harness/aaa/scripts/orchestrator-harness"; mk_sup "$FB/harness/aaa/scripts/cloud-cell-supervisor.sh"
sleep 1
git init -q "$FB/harness/zzz" 2>/dev/null; mkdir -p "$FB/harness/zzz/scripts/orchestrator-harness"; mk_sup "$FB/harness/zzz/scripts/cloud-cell-supervisor.sh"
printf '%s\n' "$FB/not-a-git-tree" >"$FB/.harness-path"   # an unusable record → the pin-root fallback runs
out_fb="$(pinrun "$FB" --dry-run 2>&1)"
case "$out_fb" in
  *"$FB/harness/zzz"*) ok "the pin-root fallback picks the NEWEST tree by mtime (zzz), not the lexicographic first (aaa)" ;;
  *) bad "the fallback did not pick the mtime-newest tree — a lexicographic pick pins an ARBITRARY commit and that commit's supervisor executes: $out_fb" ;;
esac
case "$out_fb" in
  *'NOT proven to be the layer the controller EXECUTES'*) ok "…and the fallback SAYS the tree it chose is not proven to be the executed layer" ;;
  *) bad "the fallback chose a tree in silence — a silent fallback IS the drift this unit exists to prevent: $out_fb" ;;
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
# ⛔ `record_outcome` IS THE ONLY THING BEHIND `--status`'s "last outcome" LINE, AND NOTHING GATED IT
# (round-13 review, P2). Replacing its one write with `true` left the suite at 370 ok / 0 failed: the
# `--status` verb advertises a last outcome, the header calls the record the answer to "what did this timer
# do last tick", and a read-back with nothing behind it is the kind of claim this file refuses elsewhere
# (`--print-unit`'s "a verb that advertises a last outcome and prints none"). The record is asserted on the
# LOUD path, which is the path an operator actually reads it on: a RED must leave its reason behind.
[ -s "$T/empty/orchestrator/self-pin.last" ] \
  && ok "a RED tick RECORDS its outcome ($(tail -1 "$T/empty/orchestrator/self-pin.last")) — the line --status advertises exists" \
  || bad "a RED tick wrote NO outcome record — --status' 'last outcome' line has nothing behind it"
case "$(tail -1 "$T/empty/orchestrator/self-pin.last" 2>/dev/null)" in
  *'unresolved(no-layer)'*) ok "…and the record names the REASON, not merely that something failed" ;;
  *) bad "the outcome record does not name the reason: $(tail -1 "$T/empty/orchestrator/self-pin.last" 2>/dev/null)" ;;
esac
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
# mk_analyzer <dir> <accept|refuse|table> — a fake `systemd-analyze`. The pass no longer grades a value's
# SHAPE: it asks the manager's own parser (`calendar -- <v>` / `timespan -- <v>`, rc=0 = ok). That makes the
# parser the AUTHORITY, so the suite has to be able to speak for it — otherwise every leg silently depends
# on the host's binaries, and a leg could pass for the wrong reason on a box without systemd-analyze.
#   accept  → every value is ok        (proves the pass does NOT re-grade what the parser accepted)
#   refuse  → no value is ok           (proves the pass does not accept what the parser refused)
#   table   → ok iff the value is listed in <dir>/accept
mk_analyzer() { # <dir> [accept|refuse|table] <accept-list…>
  local d="$1" mode="${2:-accept}"; shift 2 || true
  mkdir -p "$d"
  { printf '#!/bin/bash\n'; printf 'd=%q\n' "$d"
    case "$mode" in
      accept) printf 'exit 0\n' ;;
      refuse) printf 'exit 1\n' ;;
      table)  printf 'want=""; shift 2>/dev/null || true; for a in "$@"; do [ "$a" = "--" ] && continue; want="$a"; done\n'
              printf 'grep -Fxq -- "$want" %q && exit 0\nexit 1\n' "$d/accept" ;;
    esac
  } >"$d/systemd-analyze"
  chmod +x "$d/systemd-analyze"
  [ "$mode" = table ] && shift 0
  for v in "$@"; do printf '%s\n' "$v" >>"$d/accept"; done
  printf '%s\n' "$d"
}
install_doctored() { # <dir> <unit-dir>
  runat "$T/home" TEMPLATES_DIR="$1" SYSTEMD_UNIT_DIR="$2" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
    PATH="$T/fakebin:$PATH" bash "$PIN" --install 2>&1
}
# ⛔ AN UNEXPECTED SUCCESS RE-SEEDS THE PLACED-PASS SENTINEL, AND ONLY AN UNEXPECTED SUCCESS MAY.
# Under a MUTANT that reverts a rule the install SUCCEEDS and legitimately (re)places the pass, so
# without a re-seed every LATER refusal leg reports "REPLACED the placed pass" for a replacement
# that was correct, and one reverted rule reds a cascade instead of its own legs.
# ⛔ BUT THE RE-SEED CANNOT BE UNCONDITIONAL, AND THAT IS NOT A STYLE POINT: `refuses` asserts the
# refusal left the pass UNTOUCHED by comparing `$T/placed.before` with `$PLACED`. A `cp` that runs
# on the refusal path too overwrites `$PLACED` FROM the expected bytes and then compares them with
# themselves — every one of those assertions becomes a tautology that can never red, i.e. the
# placed-pass gate is DELETED while still printing "ok". So the re-seed goes in the rc=0 branch,
# before its `return`, and nowhere else (round-14 review, P1).
# refuses <name> <doctored-dir> <unit-dir> <must-appear-in-the-reason>
refuses() {
  local name="$1" d="$2" u="$3" why="$4" out rc
  out="$(install_doctored "$d" "$u")"; rc=$?
  if [ "$rc" -eq 0 ]; then bad "ACCEPTED $name — the gate does not exist: $out"; cp "$T/placed.before" "$PLACED"; return; fi   # re-seed ONLY on an unexpected success
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
# ⛔ AND THE CONDITION FAMILY IS CLOSED BY PREFIX, NOT BY ONE NAME. Refusing only `ConditionPathExists=`
# left the other members of `systemd.unit(5)`'s condition set reachable — `ConditionFileNotEmpty=`,
# `ConditionPathIsDirectory=`, `ConditionEnvironment=`, `ConditionUser=`, … — and EVERY member has the same
# behaviour on a false condition: the unit is SKIPPED and left GREEN, which is strictly worse than the
# 200/CHDIR it replaced. These two legs name members the artifact rules above never mention, so a guard
# that reverted to the single-name check fails them.
refuses 'a ConditionFileNotEmpty= (the family, not the one name)' "$(doctor condfam 'ConditionFileNotEmpty=/srv/nope')" "$T/u17" 'ConditionFileNotEmpty='
refuses 'a ConditionUser= (the family, a third name)' "$(doctor conduser 'ConditionUser=cmux')" "$T/u18" 'ConditionUser='
# ⛔ `Environment=` IS LAST-WINS, SO THE BASE RULE ABOVE IS A COUNT RULE, NOT A PRESENCE TEST. The rule used
# to accept "a line matching `CELL_HOME=${CELL_HOME}` exists" — and a SECOND assignment OVERRIDES it, so the
# unit's EFFECTIVE base was another path while `ExecStart` (and so the $CELL_HOME prefix rule) still sat
# under the real one, and nothing else caught it. MEASURED before the rule existed: this doctor installed
# rc=0 and wrote both lines. These legs FAIL on the presence-test version and pass on the count version,
# which is what makes the rule load-bearing rather than decorative.
refuses 'an OVERRIDING Environment=CELL_HOME=' "$(doctor overridehome 'Environment=CELL_HOME=/tmp/other-home')" "$T/u19" 'LAST-WINS'
# ⛔ AND THE COUNT IS NOT ENOUGH ON ITS OWN — the ONE assignment must NAME the cell home. A unit that carries
# exactly one `CELL_HOME=` pointing somewhere else is the same skew one spelling over, so this doctor
# REWRITES the existing line instead of appending (a second line would trip the count rule first and the leg
# would pass on a rule it never named — the same wrong-reason trap the ExecStart leg hit).
refuses 'ONE Environment=CELL_HOME= naming a different base' "$(doctor_rw cmhome-wrong "s|^Environment=CELL_HOME=.*\$|Environment=CELL_HOME=/tmp/other-home|")" "$T/u20" 'is not the cell home'
# ⛔ A RULE THAT GRADES A DIRECTIVE systemd DROPS IS A FALSE PASS (round-11 review, P1). `Environment=`,
# `SuccessExitStatus=` and `User=` are `[Service]`-only; written in any other section systemd IGNORES them
# ("Unknown key name … ignoring."). The rules read the WHOLE body section-blind, so BOTH `Environment=`
# lines MOVED under a trailing `[Unit]` head passed the count rule, the value rule and the allow-list;
# `--install` printed "installed" and `systemd-analyze verify` reported both lines as ignored — so the
# installed unit ran with NO `CELL_HOME` and fell back to `${CELL_HOME:-$HOME}`, a DIFFERENT pin record
# than the controller reads (#2215's skew, made permanent in /etc/systemd/system). This leg MOVES the
# lines rather than appending them: appending one to a `[Service]` that still has a good one is harmless
# and must NOT be refused, so only a move can tell a section-aware rule from a section-blind one.
d_envsec="$T/doctored-env-wrong-section"
mkdir -p "$d_envsec" && cp "$TPL/cell-self-pin.timer" "$d_envsec/"
{ grep -vE '^Environment=' "$TPL/cell-self-pin.service"; printf '\n[Unit]\n'; grep -E '^Environment=' "$TPL/cell-self-pin.service"; } >"$d_envsec/cell-self-pin.service"
refuses 'Environment= moved into a section systemd IGNORES ([Unit])' "$d_envsec" "$T/u20b" 'assignment(s)'
# ⛔ AND THE ARTIFACT'S IDENTITY WAS THE ONE PROPERTY NOTHING ASSERTED (round-11 review, P1). `print_unit`
# derives `User=` from the owner of `$CELL_HOME` because `User=root` was MEASURED to break the pin — this
# file's own comment quotes the fleet's drop-in: "running as root makes git refuse the fetch (dubious
# ownership) so the unit could never pin anything" — yet no rule read the value back off the artifact. A
# template carrying a second `User=` (systemd is LAST-WINS for a single-valued key) or a hardcoded
# `User=root` installed rc=0 with a positive claim: #3194's own shape one directive over, on a unit that
# also execs a payload living in a cell-user-writable directory.
refuses 'a SECOND User= (LAST-WINS identity)' "$(doctor usersecond 'User=nobody')" "$T/u20c" 'User= line(s)'
refuses 'a User= that is not the owner of CELL_HOME' "$(doctor_rw userwrong "s|^User=.*\$|User=nobody|")" "$T/u20d" "is not '"
# ⛔ `EnvironmentFile=` IS THE SAME HOLE ONE DIRECTIVE OVER: systemd READS the named file and its values
# OVERRIDE `Environment=`, so it can re-base `CELL_HOME` while the count rule above still sees exactly one
# assignment and passes. Refused by name, because the rendered pass needs no environment file at all.
refuses 'an EnvironmentFile= (overrides Environment=)' "$(doctor envfile 'EnvironmentFile=/srv/cell-pin.env')" "$T/u21" 'EnvironmentFile='
# ── 4c. WHAT SYSTEMD READS IS NOT WHAT A LINE READER READS (round-5 review findings) ───────────────
# ⛔ EVERY LEG BELOW INSTALLED rc=0 BEFORE ITS RULE EXISTED. These are not hypothetical spellings: each is
# documented in `systemd.syntax(7)` / `systemd.exec(5)` and each one changes the pass's EFFECTIVE base
# while `verify_unit`'s count rule still sees exactly one correct `Environment=CELL_HOME=`.
#
# A BACKSLASH CONTINUATION IS ONE DIRECTIVE TO THE MANAGER AND TWO PHYSICAL LINES TO US. systemd: "Lines
# ending in a backslash are concatenated with the following line while reading and the backslash is
# replaced by a space character." So the joined directive carries a SECOND `CELL_HOME=`, which is LAST-WINS.
d_cont="$T/doctored-cont"
mkdir -p "$d_cont" && cp "$TPL/cell-self-pin.timer" "$d_cont/" && cp "$TPL/cell-self-pin.service" "$d_cont/"
{
  printf '\n[Service]\n'
  printf 'Environment=HOME=%s \\\n' "$HOME"
  printf 'CELL_HOME=/tmp/other-home\n'
} >>"$d_cont/cell-self-pin.service"
refuses 'a BACKSLASH CONTINUATION hiding a second CELL_HOME=' "$d_cont" "$T/u22" 'CONCATENATES'
# …and the C-STYLE ESCAPE spelling of the same trick: `\x43` is `C` to systemd, an unknown name to a sed.
refuses 'a C-STYLE ESCAPE spelling CELL_HOME=' "$(doctor escape 'Environment=\x43ELL_HOME=/tmp/other-home')" "$T/u23" 'CONCATENATES'
# AN EMPTY `Environment=` IS A LIST RESET, and a word-split read of it yields NO words — so the count rule
# saw one correct assignment while the manager had erased it. `systemd.exec(5)`: "If the empty string is
# assigned to this option, the list of environment variables is reset, all prior assignments have no effect."
refuses 'an EMPTY Environment= (a LIST RESET)' "$(doctor envreset 'Environment=')" "$T/u24" 'LIST RESET'
# THE ENVIRONMENT-MUTATING FAMILY, refused by name and in ONE list: `UnsetEnvironment=` is documented as
# applied AFTER everything (so it undoes `Environment=`), and `PassEnvironment=` imports the manager's own
# variables. Both re-base the pass without the `Environment=` rules ever seeing it.
refuses 'an UnsetEnvironment= (undoes Environment=)' "$(doctor unsetenv 'UnsetEnvironment=CELL_HOME')" "$T/u25" 'UnsetEnvironment='
refuses 'a PassEnvironment= (imports the manager environment)' "$(doctor passenv 'PassEnvironment=CELL_HOME')" "$T/u26" 'PassEnvironment='
# EXECSTART CONTAINMENT IS ON THE RESOLVED PATH. `<CELL_HOME>/../nowhere/x.sh` passes a string prefix test
# and resolves outside the home — measured rc=0 — so two characters defeated the rule that keeps the pass
# inside the one root a cell keeps. The parent here EXISTS, so the verdict must come from containment.
mkdir -p "$T/nowhere"   # so the `..` below RESOLVES, and the verdict must come from containment
refuses 'an ExecStart that escapes CELL_HOME via ..' "$(doctor_rw execdotdot "s|^ExecStart=/bin/bash .*\$|ExecStart=/bin/bash $T/home/../nowhere/cell-self-pin.sh|")" "$T/u27" 'NOT under CELL_HOME'
# …and when the `..` path does not resolve at all, the containment rule cannot be evaluated, so it is refused
# as such instead of guessed (a oneshot cannot exec an unresolvable path either way).
refuses 'an ExecStart with an UNRESOLVABLE .. path' "$(doctor_rw execdotnope "s|^ExecStart=/bin/bash .*\$|ExecStart=/bin/bash $T/home/../no-such-dir/x.sh|")" "$T/u27c" 'traverses'
# AND THE PAYLOAD MUST BE THE PASS THIS RUN PLACES. The rule used to be "somewhere under CELL_HOME", while
# the existence check read the COMPUTED path rather than the artifact's — measured: a rendered unit naming
# `${CELL_HOME}/scripts/gone.sh` installed rc=0 and would go 203/EXEC every tick. Parent exists here, so the
# refusal can only be the identity rule.
refuses 'an ExecStart naming a payload this run does not place' "$(doctor_rw execother "s|^ExecStart=/bin/bash .*\$|ExecStart=/bin/bash $T/home/scripts/gone.sh|")" "$T/u28" 'this install places the pass at'
# ── 4d. THE REMAINING DIRECTIVES THAT RESOLVE BEFORE THE PAYLOAD RUNS, AND THE %-SPECIFIER ─────────
# ⛔ `RootDirectory=` IS NAMED IN THIS FILE'S OWN HEADER as the same "unit that never began" class and was
# checked NOWHERE. `systemd.exec(5)`: it sets the root directory for executed processes with `pivot_root(2)`
# or `chroot(2)` — so a path that is not a live-cell invariant is `200/CHDIR` with a different syscall.
# MEASURED rc=0, unit installed, "ONE actuator" printed.
refuses 'a RootDirectory= (systemd enters it before the payload)' "$(doctor rootdir 'RootDirectory=/srv/harness-current')" "$T/u29" 'never began'
# ⛔ AND THE MOUNT-REDIRECTION MEMBERS OF THAT SAME CLASS (round-19 review, P1). The root-directory arm
# closed the CHROOT route and left the BIND route open: `BindPaths=/srv/evil:<the verified pass>` makes the
# unit exec bytes no rule in this file has ever read, at a path that EXISTS, so there is no 203/EXEC to turn
# it into a RED — the pin runs attacker-chosen code with the timer enabled and every surface green.
# MEASURED rc=0 before this arm. The reason is name-based, so the value below is deliberately realistic but
# not load-bearing; `TemporaryFileSystem=` is the third member (it replaces a path with an empty tmpfs) and
# is refused by the same arm, so neither can be re-opened without reddening a leg here.
# ⛔ EVERY MEMBER OF THE MOUNT FAMILY, IN EVERY GRADER THAT GATES IT (round-21 review, P3). The previous
# two rounds each added ONE leg per member to ONE alternation, so 14 of the 24 (grader, member) pairs could
# be dropped with the suite GREEN — MEASURED: removing `BindReadOnlyPaths=` from the DROP-IN alternation
# left `471 ok / 0 failed`, which is verbatim the coverage defect the round before was opened for. A loop
# over ONE shared list closes the class instead of one name per review: a member added to the list and the
# arms is gated in all four graders at once, and dropping any single member from any alternation reds its
# own leg. `TemporaryFileSystem=`/`MountImages=` reach the exec differently (hide the path / mount an image
# over it) and `ExtensionImages=`/`ExtensionDirectories=` reach the INTERPRETER (`/bin/bash` is
# `/usr/bin/bash` on a merged host) — all four are the same "bytes this run never read reach the exec" class.
MOUNT_DIRECTIVES="BindPaths BindReadOnlyPaths TemporaryFileSystem MountImages ExtensionImages ExtensionDirectories"
for _md in $MOUNT_DIRECTIVES; do
  refuses "a ${_md}= (a mount in the unit's view)" "$(doctor "mount-$_md" "${_md}=/srv/evil:/srv/payload/cell-self-pin.sh")" "$T/u29-$_md" 'mounts into'
done
# ⛔ AND `%` IS A SPECIFIER, NOT A CHARACTER. Both `Environment=` values and the `ExecStart=` command line
# are %-specifier-expanded by the manager (`%h` = the manager user's home), so a base that CONTAINS `%` is
# verified as that literal string and RUNS expanded — the unit's effective CELL_HOME stops being the value
# the verification approved, while the "equal bases" rule still sees the literal match and passes. rc=0
# before this rule. The leg makes CELL_HOME itself carry the `%`, so NO OTHER RULE CAN ANSWER FOR IT: every
# other doctor below would be refused by the base-mismatch rule instead, and the leg would then go green on
# a rule it never tested (measured: with the `%` arm removed, a doctored value was refused by the WRONG
# rule). A copy of the pass is placed first, so the refusal is also proved to mutate nothing.
pcthome="$T/home-pct%h"
mkdir -p "$pcthome"
cp "$T/placed.before" "$PLACED"
out_pct="$(env -u HARNESS -u HARNESS_PIN_FILE -u HARNESS_PIN_DIR -u HARNESS_REPO -u O -u STAMP \
  -u TEMPLATES_DIR -u SYSTEMD_UNIT_DIR -u CELL_SELF_PIN_INTERVAL_MIN \
  -u CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR -u CELL_SELF_PIN_SRC -u HARNESS_REF \
  PATH="$T/fakebin-none:$PATH" CELL_HOME="$pcthome" HOME="$pcthome" \
  CELL_SELF_PIN_DROPIN_ROOTS="$T/dropins-hermetic" \
  TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-pct" bash "$PIN" --install 2>&1)"; rc_pct=$?
[ "$rc_pct" -ne 0 ] && ok "REFUSES a %-specifier in a rendered value (systemd would EXPAND it; rc=$rc_pct)" \
  || bad "a CELL_HOME carrying '%' installed green — systemd expands %-specifiers, so the verified base is not the executed base: $out_pct"
case "$out_pct" in
  *'%-specifiers'*) ok "…and says why (%-specifiers: %h is the manager user's home)" ;;
  *) bad "…but the refusal does not name the specifier expansion: $out_pct" ;;
esac
# ⛔ THE `cmp -s "$T/placed.before" "$PLACED"` THAT STOOD HERE WAS VACUOUS, which is the same defect this
# round fixed in the three refusal helpers (round-14 review, P2): the line above re-seeded `$PLACED` from
# the expected bytes and then compared them with themselves, so it could never red — proved by hoisting
# `place_pass` above verification, which reds 59 other legs and left this one green. And `$PLACED` is not
# even this leg's destination: its CELL_HOME is `$pcthome`, so the path a leak would write is that home's
# own `.pi/agent/scripts/cell-self-pin.sh`. Asserted on the real path instead.
if [ -f "$pcthome/.pi/agent/scripts/cell-self-pin.sh" ]; then
  bad "a refused install (%-specifier) PLACED the pass at $pcthome/.pi/agent/scripts/cell-self-pin.sh — deployed code that was never verified"
else ok "…and that refusal placed no pass into this home (the artifact it would have leaked)"; fi
[ -f "$T/units-pct/cell-self-pin.service" ] && bad "a refused install (%-specifier) still wrote the unit" \
  || ok "…and it wrote no unit"
# ⛔ THE SUCCESS VOCABULARY IS GATED IN THE ONE DIRECTION THAT CAN BE A FALSE PASS, AND IN THE ONE THAT CAN
# BE AN UNHEALABLE RED. `SuccessExitStatus=0` alone makes a MENDED record (exit 11) a failed unit — an
# unhealable RED on a correct box (#3133). The reverse rule (“must include 0”) is NOT gated and does not
# exist: `systemd.service(5)` says the listed values are successful “in addition to the normal successful
# exit status 0”, so 0 needs no listing — an earlier gate claiming “'current' and 'applied' are only green
# as 0” could never prevent the false PASS it described and could only REFUSE a valid unit. A rule with a
# false premise has no doctor worth writing; it was removed (verified against the man page, not the code).
refuses 'a SuccessExitStatus WITHOUT 11 (only 0) — a mend would be an unhealable RED' "$(doctor_rw no11 's|^SuccessExitStatus=.*$|SuccessExitStatus=0|')" "$T/u31" 'must include 11'
# ⛔ A LATER EMPTY `SuccessExitStatus=` IS A LIST RESET, NOT A NO-OP. `systemd.service(5)`: "if the empty
# string is assigned to this option, the list is reset, all prior assignments … will have no effect". So a
# unit carrying the template's `SuccessExitStatus=0 11` AND an empty assignment has an EFFECTIVE vocabulary
# of nothing — 11 is green no more, and every mend becomes an unhealable RED (#3133), the exact class the
# required-11 rule above exists to prevent. A line reader latches 11 from the first line and never sees the
# reset, so this installed at rc=0 before the rule existed (MEASURED). The doctor has to place the empty
# assignment AFTER the real one and INSIDE `[Service]` — appending it at EOF would land it in `[Install]`,
# which systemd ignores, and the leg would then pass on a file that is not the defect.
d_reset="$T/doctored-sstreset"
mkdir -p "$d_reset" && cp "$TPL/cell-self-pin.timer" "$d_reset/"
awk '{print} /^SuccessExitStatus=/{print "SuccessExitStatus="}' "$TPL/cell-self-pin.service" >"$d_reset/cell-self-pin.service"
refuses 'an EMPTY SuccessExitStatus= after the real one (a LIST RESET)' "$d_reset" "$T/u31c" 'LIST RESET'
# …and the NON-VACUITY control for that rule: a reset FOLLOWED by a real value is a VALID list, so it must
# INSTALL. Without this leg the cheap fix (refuse any empty `SuccessExitStatus=`) would pass the doctor while
# refusing a correct unit.
d_resetrf="$T/doctored-sstresetrefill"
mkdir -p "$d_resetrf" && cp "$TPL/cell-self-pin.timer" "$d_resetrf/"
awk '{print} /^SuccessExitStatus=/{print "SuccessExitStatus="; print "SuccessExitStatus=11"}' "$TPL/cell-self-pin.service" >"$d_resetrf/cell-self-pin.service"
out_resetrf="$(install_doctored "$d_resetrf" "$T/u31d")"; rc_resetrf=$?
[ "$rc_resetrf" -eq 0 ] && ok "ACCEPTS a reset FOLLOWED by SuccessExitStatus=11 — the effective list is real, the reset is honoured not refused" \
  || bad "refused a valid unit whose empty SuccessExitStatus= is followed by 11 — the guard refuses the SPELLING instead of evaluating the LIST: $out_resetrf"
cp "$T/placed.before" "$PLACED"   # the refusal legs below re-assert that a REFUSAL cannot replace it
# …and the NON-VACUITY control for the removal: `0` is not required, so a unit listing only 11 must
# INSTALL. Without this leg the rule could be re-added (or the removal be a no-op) and nothing would notice.
d_ok11="$(doctor_rw ok11only 's|^SuccessExitStatus=.*$|SuccessExitStatus=11|')"
out_ok11="$(install_doctored "$d_ok11" "$T/u31b")"; rc_ok11=$?
[ "$rc_ok11" -eq 0 ] && ok "ACCEPTS SuccessExitStatus=11 without 0 — 0 is successful regardless (systemd.service(5)); only a MISSING 11 is refused" \
  || bad "refused a unit that omits the redundant 0 from SuccessExitStatus — a valid unit, refused: $out_ok11"
cp "$T/placed.before" "$PLACED"   # the refusal legs below re-assert that a REFUSAL cannot replace it
# ── 4a-bis. THE OTHER ARTIFACT THIS VERB INSTALLS: THE TIMER ITSELF ─────────────────────────────
# ⛔ `--install` WRITES TWO UNITS AND VERIFIED ONE (round-10 review, P1). `verify_unit` was asserted on
# `$tmp/cell-self-pin.service` only; the rendered `cell-self-pin.timer` was written, placed and ENABLED
# with no assertion at all. The timer's DROP-INS were verified while the timer ITSELF was not — so a
# `Unit=` re-target and a timer with no repeating trigger both installed rc=0 under the positive claim
# "installed — ONE actuator on this pin", producing a pin that never runs again: #3194's symptom through
# the artifact path. These legs are that defect, fed back in, one doctor per rule.
doctor_timer() { # <name> <sed-expr applied to the TIMER template> [<line inserted after the FIRST Unit=>]
  local d="$T/doctored-$1"
  mkdir -p "$d" && cp "$TPL/cell-self-pin.service" "$d/"
  sed "$2" "$TPL/cell-self-pin.timer" >"$d/cell-self-pin.timer"
  # ⛔ NOT `\n` IN A sed REPLACEMENT — that is a GNU extension. FreeBSD/macOS `sed(1)` says "To specify a
  # newline character in the replacement string, precede it with a backslash", so `\n` yields a literal
  # `n` and the two lines fuse into `Unit=cell-self-pin.servicenUnit=/bin/true.service`. Measured: on such
  # a host the COUNT rule this leg exists to pin is never exercised and the leg reds with "refused for the
  # WRONG reason" — a red suite on a host this file explicitly supports, for a reason that has nothing to
  # do with the defect. `awk` prints the extra line after the first `Unit=` and is portable to both.
  [ -z "${3:-}" ] || { awk -v extra="$3" '1; /^Unit=/ && !done { print extra; done=1 }' \
    "$d/cell-self-pin.timer" >"$d/.timer.tmp" && mv "$d/.timer.tmp" "$d/cell-self-pin.timer"; }
  printf '%s\n' "$d"
}
doctor_timer_append() { # <name> <sed-expr or ''> <text appended verbatim at EOF>
  local d="$T/doctored-$1"
  mkdir -p "$d" && cp "$TPL/cell-self-pin.service" "$d/"
  if [ -n "$2" ]; then sed "$2" "$TPL/cell-self-pin.timer" >"$d/cell-self-pin.timer"
  else cp "$TPL/cell-self-pin.timer" "$d/cell-self-pin.timer"; fi
  printf '%b' "$3" >>"$d/cell-self-pin.timer"
  printf '%s\n' "$d"
}
refuses_timer() { # <name> <doctored-dir> <unit-dir> <must-appear-in-the-reason>
  local name="$1" d="$2" u="$3" why="$4" out rc
  out="$(install_doctored "$d" "$u")"; rc=$?
  if [ "$rc" -eq 0 ]; then bad "ACCEPTED $name — the timer gate does not exist: $out"; cp "$T/placed.before" "$PLACED"; return; fi   # re-seed ONLY on an unexpected success
  if [[ $out == *"$why"* ]]; then ok "REFUSES $name, and says why (\"$why\")"
  else bad "refused $name for the WRONG reason (wanted \"$why\"): $out"; fi
  [ -f "$u/cell-self-pin.timer" ] && bad "a refused install ($name) still wrote the TIMER" \
    || ok "a refused install ($name) wrote no timer"
  if cmp -s "$T/placed.before" "$PLACED"; then ok "a refused install ($name) did NOT replace the already-placed pass"
  else bad "a refused install ($name) REPLACED the placed pass"; cp "$T/placed.before" "$PLACED"; fi
}
# ⛔ RE-TARGETED: `Unit=` must name the pass this run places. systemd defaults a MISSING `Unit=` to the
# same-name service, so a re-target is silent on every surface this file prints.
refuses_timer 'a timer Unit= re-targeted away from the pass' \
  "$(doctor_timer unit-elsewhere 's|^Unit=.*$|Unit=/bin/true.service|')" "$T/tu1" 'is not the pass this install places'
# ⛔ NO REPEATING TRIGGER: `OnBootSec=` fires ONCE, three minutes after boot. The shipped template's own
# comment says the cadence is `OnUnitActiveSec=` for exactly this reason; with it deleted the pin runs a
# single time and then stops for ever, with every surface green.
refuses_timer 'a timer with only the ONE-SHOT OnBootSec=' \
  "$(doctor_timer no-clock '/^OnUnitActiveSec=/d')" "$T/tu2" 'no REPEATING trigger'
# ⛔ A `[Service]`-ONLY DIRECTIVE IN `[Timer]` IS INERT, AND THE GATE FOR IT HAD NO DOCTOR AT ALL
# (round-13 review, P2 — the arm's RATIONALE was false, citing `EXIT_CHDIR / 203`, a failure mode a timer
# cannot have). Measured: `systemd-analyze verify` answers `Unknown key name 'WorkingDirectory' in section
# 'Timer', ignoring.` The refusal stays — a line the render believes constrains the clock and the manager
# drops in silence is the green no-op class this file exists for — and this leg is what makes the arm
# LOAD-BEARING rather than an unexplained refusal. `doctor_timer`'s extra line is inserted directly after
# `Unit=`, which the template places inside `[Timer]`, so the doctor reproduces the measured state.
refuses_timer 'a [Service]-only directive inside [Timer] (systemd IGNORES it — a green no-op)' \
  "$(doctor_timer timerinert 's|^Unit=.*$|Unit=cell-self-pin.service|' 'WorkingDirectory=/srv/harness-current')" "$T/tu20" 'Unknown key name'
# …and the MOUNT family in the same place, EVERY member (round-21 review, P3): `verify_timer` refused
# `WorkingDirectory=`/`RootDirectory=` here and accepted the whole mount family rc=0 (measured,
# round-20 review), so the rendered timer could carry a mount nobody acts on while the equally inert
# `WorkingDirectory=` was refused — inconsistent verdicts on one class, which is how a rule stops being an
# invariant. One leg per member, so the arm cannot be narrowed one name at a time.
for _md in $MOUNT_DIRECTIVES; do
  refuses_timer "a ${_md}= inside [Timer] (systemd IGNORES it — a green no-op)" \
    "$(doctor_timer "timermount-$_md" 's|^Unit=.*$|Unit=cell-self-pin.service|' "${_md}=/srv/evil:/srv/x")" "$T/tu-$_md" 'the rendered timer declares'
done
# ⛔ AND AN EMPTY VALUE IS THE SAME DEFECT ONE SPELLING OVER: systemd ignores `OnUnitActiveSec=` with no
# value, so the timer silently degrades to the one-shot case while the directive is present.
refuses_timer 'an EMPTY OnUnitActiveSec=' \
  "$(doctor_timer empty-clock 's|^OnUnitActiveSec=.*$|OnUnitActiveSec=|')" "$T/tu3" 'no REPEATING trigger'
# ⛔ AND A SECOND `Unit=` IS LAST-WINS, exactly like `Environment=CELL_HOME=` and `ExecStart=`: a presence
# test installs the wrong target green. The shipped target stays FIRST, so only the count rule can catch it.
refuses_timer 'a SECOND Unit=' \
  "$(doctor_timer unit-second 's|^Unit=.*$|Unit=cell-self-pin.service|' 'Unit=/bin/true.service')" "$T/tu4" 'Unit= line(s)'
# ⛔ A SKIPPED TIMER IS A GREEN NO-OP, and on the TIMER it is unrecoverable: nothing runs, so the pass's own
# loudness never gets a chance to fire. Closed by PREFIX, so a condition name systemd adds later is closed.
refuses_timer 'a ConditionPathExists= on the TIMER (a skip is a green no-op)' \
  "$(doctor_timer cond-timer 's|^Unit=.*$|Unit=cell-self-pin.service|' 'ConditionPathExists=/srv/nope')" "$T/tu5" 'ConditionPathExists='
# ⛔ AND A TRIGGER IN A SECTION SYSTEMD IGNORES IS NOT A TRIGGER (measured in review — this rule FAILED
# OPEN before it was section-aware). Deleting `OnUnitActiveSec=` from `[Timer]` and appending
# `[Service]` + `OnUnitActiveSec=10min` installed **rc=0**; `systemd-analyze verify` said only
# "Unknown section 'Service'. Ignoring.", so the timer kept `OnBootSec=3min` alone and fired ONCE three
# minutes after boot and never again — the exact state the repeating-trigger rule exists to refuse,
# reached through the rule itself. Unlike a service (where a mis-sectioned `ExecStart=` fails `enable
# --now`), an ignored section on a TIMER has nothing to fail: it is silent, so nothing but this leg is
# between the box and a dead clock.
refuses_timer 'a repeating trigger moved into an IGNORED section ([Service])' \
  "$(doctor_timer_append clock-wrong-section '/^OnUnitActiveSec=/d' '[Service]\nOnUnitActiveSec=10min\n')" "$T/tu6" 'no REPEATING trigger'
# ⛔ AND THE `[Timer]` SECTION MUST EXIST: with none, every trigger fails the same way and no other rule
# in this function can fire (the count rule and the trigger rule both read that section).
refuses_timer 'a timer with NO [Timer] section at all' \
  "$(doctor_timer_append no-timer-section 's|^\[Timer\]$|[Timers]|' '')" "$T/tu7" 'no [Timer] section'
# ⛔ AND THE TRIGGER MUST SURVIVE TO THE EFFECTIVE LIST (round-11 review, P1). The rule LATCHED the first
# non-blank `OnUnitActiveSec=`/`OnCalendar=` and returned success, but `systemd.timer(5)` on both: "If the
# empty string is assigned to ANY of these options, the list of timers is reset (both monotonic timers and
# OnCalendar= timers), and all prior assignments will have no effect." So the shipped `OnUnitActiveSec=`
# followed by an EMPTY `OnCalendar=` DISCARDS it — and `OnBootSec=` with it — and re-adding `OnBootSec=`
# after the reset leaves a clock that fires once and never again. MEASURED in review: rc=0, "installed".
# This leg is the difference between "a repeating trigger is WRITTEN" and "the effective list REPEATS";
# the latch version ACCEPTS it, because it only ever looked for a non-blank line.
refuses_timer 'the repeating trigger DISCARDED by a later empty OnCalendar= (a LIST RESET)' \
  "$(doctor_timer_append clock-reset '' '[Timer]\nOnCalendar=\nOnBootSec=3min\n')" "$T/tu8" 'no REPEATING trigger'
# ⛔ AND A VALUE THE MANAGER CANNOT PARSE IS NOT AN EFFECTIVE TRIGGER (round-12 review, P1). The replay
# asked only "is there a non-blank value?", and systemd DISCARDS a value it cannot parse — `Failed to parse
# timer value, ignoring: 10minx` (systemd.timer(5)) — leaving the one-shot `OnBootSec=` alone. MEASURED
# against the live systemd 255 manager (`systemctl show -p TimersMonotonic` on a probe unit):
# `OnUnitActiveSec=10minx` installed rc=0 with `TimersMonotonic={ OnBootUSec=3min }` alone, while the control
# `10min` read back as BOTH `OnUnitActiveUSec=10min` and `OnBootUSec=3min`. So the rule that exists to refuse
# a dead clock certified one, one spelling further out from the LIST RESET it already handled. The
# TRAILING COMMENT leg is the realistic one: systemd.syntax(7) has no trailing comments, so an operator
# editing the cadence and annotating it produces exactly this.
refuses_timer 'a repeating trigger with an UNPARSEABLE timespan (10minx)' \
  "$(doctor_timer unit-badspan 's|^OnUnitActiveSec=.*$|OnUnitActiveSec=10minx|')" "$T/tu9" 'cannot parse'
refuses_timer 'a repeating trigger with a TRAILING COMMENT (systemd has none)' \
  "$(doctor_timer unit-comment 's|^OnUnitActiveSec=.*$|OnUnitActiveSec=10min # every ten minutes|')" "$T/tu10" 'cannot parse'
refuses_timer 'an OnCalendar= that is NOT a calendar expression (10min)' \
  "$(doctor_timer unit-badcal 's|^OnUnitActiveSec=.*$|OnCalendar=10min|')" "$T/tu11" 'cannot parse'
refuses_timer 'a repeating trigger of exactly infinity (a VALID timespan that means NEVER)' \
  "$(doctor_timer unit-inf 's|^OnUnitActiveSec=.*$|OnUnitActiveSec=infinity|')" "$T/tu12" 'cannot parse'
# ⛔ AND THE REFUSAL ABOVE WAS LOAD-BEARING AND UNGATED (round-13 review, P1). It ran under the suite's
# default tier — `CELL_SELF_PIN_ANALYZE=none`, where `timer_timespan_ok`'s narrow grammar rejects `infinity`
# BY SHAPE — so the explicit arm in `timer_value_ok` could be DELETED and the suite stayed at 370 ok / 0
# failed. It is the only refusal on a box that HAS a parser: measured, `systemd-analyze timespan --
# infinity` answers `μs: 18446744073709551615`, **rc=0** — the parser accepts a clock that means NEVER.
# This leg puts the arm in the tier where it is the sole line of defence: an analyzer that ACCEPTS
# everything (`mk_analyzer accept`), i.e. exactly the verdict the real manager gives this value.
an_inf="$(mk_analyzer "$T/an-infinity" accept)"
AN="$an_inf/systemd-analyze"
refuses_timer 'a repeating trigger of exactly infinity WITH A PARSER PRESENT (the parser ACCEPTS it — rc=0)' \
  "$(doctor_timer unit-inf-analyzer 's|^OnUnitActiveSec=.*$|OnUnitActiveSec=infinity|')" "$T/tu19" 'cannot parse'
AN=none
# ⛔ AND A VALUE'S SHAPE IS NOT ITS RANGE (round-13 review, P1 — the last spelling this rule could hide
# behind). The reply above certified `number+unit SHAPED` and `contains h:mm`, which is not what the manager
# grades: systemd RANGE-CHECKS every field and DISCARDS the value otherwise. MEASURED at the head these
# legs were added for: each of the five spellings below installed rc=0, while systemd 255 answered
# `systemd-analyze calendar -- '24:00:00'` => "Invalid argument" and left `TimersCalendar=` ABSENT from the
# loaded property of a probe unit. `24:00:00` is how an operator spells MIDNIGHT, so this is not a
# contrived spelling; and a timespan past the manager's usec range is `Numerical result out of range`.
# Each leg must FAIL on the pre-fix reply (mutation-measured: 5 legs red with the range checks removed).
refuses_timer 'an OnCalendar= hour OUT OF RANGE (25:00)' \
  "$(doctor_timer cal-h25 's|^OnUnitActiveSec=.*$|OnCalendar=25:00|')" "$T/tu13" 'cannot parse'
refuses_timer 'an OnCalendar= spelled 24:00:00 (midnight, which systemd REFUSES)' \
  "$(doctor_timer cal-midnight 's|^OnUnitActiveSec=.*$|OnCalendar=24:00:00|')" "$T/tu14" 'cannot parse'
refuses_timer 'an OnCalendar= second OUT OF RANGE (04:00:99)' \
  "$(doctor_timer cal-s99 's|^OnUnitActiveSec=.*$|OnCalendar=04:00:99|')" "$T/tu15" 'cannot parse'
refuses_timer 'an OnCalendar= whose TIME field is out of range inside a date (\*-\*-\* 25:00:00)' \
  "$(doctor_timer cal-dt25 's|^OnUnitActiveSec=.*$|OnCalendar=*-*-* 25:00:00|')" "$T/tu16" 'cannot parse'
refuses_timer 'an OnCalendar= whose DATE field is out of range (2026-13-45)' \
  "$(doctor_timer cal-month13 's|^OnUnitActiveSec=.*$|OnCalendar=2026-13-45 04:00:00|')" "$T/tu17" 'cannot parse'
refuses_timer 'a timespan PAST the manager integer range (1000000000000000000y)' \
  "$(doctor_timer unit-overflow 's|^OnUnitActiveSec=.*$|OnUnitActiveSec=1000000000000000000y|')" "$T/tu18" 'cannot parse'
# ⛔ THE POSITIVE CONTROL, because "refuse every value" would satisfy all four legs above. A real calendar
# expression and the shortcut word must INSTALL: the rule refuses what systemd DISCARDS, never what it can
# read — and an over-block here would close the one edit an operator is most likely to make.
# ⛔ THE CONTROL THAT STOPS "refuse every value" FROM PASSING, and it must run in the tier where an
# explicit expression is certifiable at all: with a parser available, a real calendar expression installs.
an_real="$(mk_analyzer "$T/an-table" table '*-*-* 04:00:00' 'daily')"
u_cal="$T/units-cal"; AN="$an_real/systemd-analyze"; out="$(install_doctored "$(doctor_timer cal-ok 's|^OnUnitActiveSec=.*$|OnCalendar=*-*-* 04:00:00|')" "$u_cal")"; rc=$?; AN=none
[ "$rc" -eq 0 ] && [ -f "$u_cal/cell-self-pin.timer" ] && ok "…and a VALID OnCalendar= expression still installs (the rule refuses unparseable values, not calendars)" \
  || bad "refused a valid OnCalendar=*-*-* 04:00:00 (rc=$rc): $out"
u_daily="$T/units-daily"; out="$(install_doctored "$(doctor_timer cal-daily 's|^OnUnitActiveSec=.*$|OnCalendar=daily|')" "$u_daily")"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$u_daily/cell-self-pin.timer" ] && ok "…and the OnCalendar= shortcut word 'daily' installs" \
  || bad "refused OnCalendar=daily (rc=$rc): $out"
u_multi="$T/units-multiunit"; out="$(install_doctored "$(doctor_timer unit-multiunit 's|^OnUnitActiveSec=.*$|OnUnitActiveSec=5h 30min|')" "$u_multi")"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$u_multi/cell-self-pin.timer" ] && ok "…and a multi-unit timespan (OnUnitActiveSec=5h 30min) installs — the narrow tier is a bound on nonsense, not on ordinary values" \
  || bad "refused a valid multi-unit timespan OnUnitActiveSec=5h 30min (rc=$rc): $out"

# ── 4a-bis. THE VALUE PARSER IS THE MANAGER'S, NOT THIS FILE'S ──────────────────────────────────────
# ⛔ THREE REVIEW ROUNDS EACH FOUND ANOTHER SPELLING THE HAND-WRITTEN GRAMMAR CERTIFIED WHILE systemd
# DISCARDED IT (`10minx`; then `24:00:00`/`25:00`/`1000000000000000000y`; then `1..5 04:00:00`,
# `2200-01-01 04:00:00`, `32 04:00:00`, `04..03:00`, `04:0/0:00`, a duplicate field). MEASURED at the head
# before this: 77 of a 240-form cross-product were ACCEPTED here and thrown away by the manager. Each patch
# moved the boundary, because a re-implementation of systemd's calendar parser IS the defect. So the pass
# now ASKS `systemd-analyze calendar|timespan`. These legs pin BOTH directions of that delegation: a value
# the parser REFUSES is refused however ordinary it looks, and a value the parser ACCEPTS is installed
# however exotic it looks — i.e. the pass does not re-grade what the parser decided.
u_del="$(mk_analyzer "$T/an-refuse" refuse)"
AN="$u_del/systemd-analyze"; out="$(install_doctored "$(doctor_timer cal-delegated 's|^OnUnitActiveSec=.*$|OnCalendar=*-*-* 04:00:00|')" "$T/units-deleg-refuse")"; rc=$?; AN=none
[ "$rc" -ne 0 ] && ok "…and a value the PARSER refuses is refused even though it is well formed (the verdict is the manager's, not this file's)" \
  || bad "installed OnCalendar=*-*-* 04:00:00 while the parser REFUSED it — the grammar is grading shape again (rc=$rc): $out"
u_acc="$(mk_analyzer "$T/an-accept" accept)"
AN="$u_acc/systemd-analyze"; out="$(install_doctored "$(doctor_timer cal-exotic 's|^OnUnitActiveSec=.*$|OnCalendar=1..5 04:00:00|')" "$T/units-deleg-accept")"; rc=$?; AN=none
[ "$rc" -eq 0 ] && [ -f "$T/units-deleg-accept/cell-self-pin.timer" ] && ok "…and a value the parser ACCEPTS is installed without this file re-grading it (OnCalendar=1..5 04:00:00 — a form the old grammar could only guess at)" \
  || bad "refused OnCalendar=1..5 04:00:00 although the parser ACCEPTED it — the pass is still re-implementing the parser (rc=$rc): $out"

# ── 4a-ter. THE ENABLEMENT ITSELF — THE ONE THING `--install` NEVER VERIFIED ─────────────────────────
# ⛔ `systemctl enable` EXITS 0 AND CREATES NO SYMLINK for a unit with no installation config. MEASURED on
# systemd 255.4 in this review round: rc=0, "The unit files have no installation config (WantedBy=,
# RequiredBy=, UpheldBy=, Also=, or Alias= …)", `timers.target.wants/` never created — while the control
# WITH `[Install] WantedBy=timers.target` links, and `is-enabled` answers `enabled` (without it: `static`,
# rc=0). So EVERY line below `enable` — the one-actor read-back, the final "installed —" note — was printed
# over a pin that never fires: #3194's symptom, produced by the verb that exists to end it. The same
# measured mechanism was already refused in a DROP-IN (`verify_dropin_file`'s `[Install]` arm, which cites
# this exact measurement); the RENDERED unit, whose enablement is what `--install` claims, had no rule.
# ⛔ A RESEED BEFORE THE REFUSAL LEGS BELOW, AND THE REASON IS THE SENTINEL'S OWN DESIGN. `$PLACED` is
# seeded with a SENTINEL (`# a copy placed by an EARLIER install …`), not with this file's bytes, so that
# a mutant moving `place_pass` above `verify_unit` is caught by `cmp`. The POSITIVE CONTROLS above
# (`u_cal`, `u_daily`, `u_multi`, the delegation legs) install SUCCESSFULLY and therefore legitimately
# replace it with the real pass — which would make every refusal leg below report "REPLACED the placed
# pass" for a replacement that was correct. This is the same reseed shape the timer and drop-in sections
# already use; without it one correct install reds a cascade of unrelated legs.
cp "$T/placed.before" "$PLACED"   # the refusal legs below re-assert that a REFUSAL cannot replace it
refuses_timer 'a timer template with NO installation config ([Install] WantedBy= dropped)' \
  "$(doctor_timer noinstall '/^WantedBy=/d')" "$T/tu40" 'installation config'
refuses_timer 'a timer template whose WantedBy= is EMPTY (a LIST RESET — the same no-config state)' \
  "$(doctor_timer noinstall-empty 's|^WantedBy=.*$|WantedBy=|')" "$T/tu41" 'non-blank WantedBy='
# ⛔ THE POSITIVE CONTROL, BECAUSE "REFUSE EVERY INSTALLATION CONFIG" WOULD SATISFY BOTH LEGS ABOVE.
# `UpheldBy=` is a legitimate enablement — systemd's own "no installation config" message lists it, and
# MEASURED on 255.4 a timer carrying ONLY `[Install] UpheldBy=timers.target` links
# (`timers.target.upholds/<unit>`) and reads `enabled`. The first version of the rule counted only
# `WantedBy=`/`RequiredBy=` and thus FALSE-REFUSED this shape (round-17 review, P3); this leg is what stops
# the narrow grammar from being narrowed back.
u_upheld="$T/units-upheld"; out="$(install_doctored "$(doctor_timer noinstall-upheld 's|^WantedBy=.*$|UpheldBy=timers.target|')" "$u_upheld")"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$u_upheld/cell-self-pin.timer" ] && ok "…and UpheldBy= is accepted as an installation config (a timer enabled only through 'timers.target.upholds/' installs)" \
  || bad "FALSE-REFUSED UpheldBy=timers.target, a legitimate installation config (rc=$rc): $out"
cp "$T/placed.before" "$PLACED"   # the positive control above legitimately re-placed the pass; the refusal legs below re-assert the sentinel
# ⛔ AND THE RESET IS REPLAYED, NOT COUNTED (round-17 review, P3). The rule's own comment claimed LIST-RESET
# awareness while `_nw` counted non-blank values across every line, so `WantedBy=timers.target` followed by
# an empty `WantedBy=` — systemd's "no installation config" state, MEASURED (enable rc=0, no link,
# `is-enabled` → `static`) — was ACCEPTED at the input gate. Only the enable read-back stood between that
# shape and a green install, and an unanswerable manager degrades the read-back to a warning. The replay is
# the shape `SuccessExitStatus=` already uses.
refuses_timer 'a WantedBy= RESET by a later EMPTY WantedBy= (the list is discarded, no config left)' \
  "$(doctor_timer_append noinstall-reset 's|^OnUnitActiveSec=.*$|OnUnitActiveSec=10min|' 'WantedBy=\n')" "$T/tu42" 'installation config'
# ⛔ AND AN `Alias=` IS NOT AN INSTALLATION CONFIG — IT WAS A FALSE PASS, IN THE ONE SHAPE THE READ-BACK CANNOT
# CATCH (round-18 review, P2). `Alias=` links a DIFFERENT NAME pointing at this unit; it never puts this unit
# into any target's `.wants/`, so nothing starts it. MEASURED on systemd 255.4: an `Alias=`-only timer gives
# `enable` rc=0, creates `cell-self-pin-legacy.timer -> …` with NO `timers.target.wants/`, and then
# `is-enabled` answers **`enabled`** (rc=0) — so `own_state` reads green and `--install` prints its own
# success over a pin that never fires. `Also=` fails safe here only because it answers `indirect`; `Alias=`
# is the one that lies. This leg is what stops the accept-set being widened back: re-adding `Alias` to the
# replay's alternation makes this template INSTALL, and the leg reds.
refuses_timer 'a timer whose ONLY installation config is Alias= (a name for THIS unit, never a schedule)' \
  "$(doctor_timer alias-only 's|^WantedBy=.*$|Alias=cell-self-pin-legacy.timer|')" "$T/tu43" 'installation config'

# ⛔ AND WITH NO PARSER ON THE BOX, THE FALLBACK IS A WHITELIST, NOT A GUESS: the ten documented shortcut
# words are certifiable by construction, and any explicit EXPRESSION is REFUSED with the two routes out
# named. That direction is deliberate — a refusal an operator fixes with one line, never a false PASS —
# and this leg exists so the over-block is RECORDED rather than discovered by an operator.
AN=none; out="$(install_doctored "$(doctor_timer cal-noparser 's|^OnUnitActiveSec=.*$|OnCalendar=Mon..Fri 04:00:00|')" "$T/units-noparser")"; rc=$?
if [ "$rc" -ne 0 ] && [[ $out == *"systemd-analyze"* ]]; then
  ok "…and with NO parser available an explicit OnCalendar= is REFUSED and the refusal names the route (the documented fail-closed tier)"
else
  bad "with no parser available, an explicit OnCalendar= was not refused by name (rc=$rc): $out"
fi
AN=none; out="$(install_doctored "$(doctor_timer cal-noparser-daily 's|^OnUnitActiveSec=.*$|OnCalendar=daily|')" "$T/units-noparser-daily")"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$T/units-noparser-daily/cell-self-pin.timer" ] && ok "…while the shortcut word 'daily' still installs with no parser (a whitelist, so it cannot certify nonsense)" \
  || bad "refused OnCalendar=daily with no parser (rc=$rc): $out"

# ── 4b. THE EFFECTIVE UNIT: the drop-in systemd MERGES over the rendered one ──────────────────────
# ⛔ THE FALSE PASS THIS CLOSES. `verify_unit` reads the file this run WRITES; systemd merges
# `<unit>.service.d/*.conf` OVER it, in both managers, whether the drop-in was written before the unit or
# after. So an installed legacy drop-in can carry the exact defect this change removes while `--install`
# prints "installed — ONE actuator on this pin" and exits 0. This is a REACHABLE state, not a hypothetical:
# the defect in the issue was itself carried in a DROP-IN (`WorkingDirectory=/tmp/cell-ai`), and a box in
# this fleet still carries `cell-self-pin.service.d/user.conf` today. Every leg below is the drop-in half
# of a rule the artifact legs above already pin, so a guard that reads only the rendered file fails them.
dropin_doctor() { # <name> <conf body> [drop-in dir name] -> prints a unit dir carrying a drop-in with that body
  local u="$T/dropin-$1" dd="${3:-cell-self-pin.service.d}"
  mkdir -p "$u/$dd"
  printf '[Service]\n%s\n' "$2" >"$u/$dd/legacy.conf"
  printf '%s\n' "$u"
}
refuses_dropin() { # <name> <unit-dir> <must-appear-in-the-reason>
  local name="$1" u="$2" why="$3" out rc
  # The UNDOCTORED template, so the ONLY reason to refuse is the drop-in: an artifact rule that also fired
  # here would make the leg pass on a reason it did not name.
  out="$(install_doctored "$TPL" "$u")"; rc=$?
  if [ "$rc" -eq 0 ]; then bad "ACCEPTED a drop-in that $name — the effective-unit gate does not exist: $out"; cp "$T/placed.before" "$PLACED"; return; fi   # re-seed ONLY on an unexpected success
  if [[ $out == *"$why"* ]]; then ok "REFUSES a drop-in that $name, and names the file (\"$why\")"
  else bad "refused a drop-in that $name for the WRONG reason (wanted \"$why\"): $out"; fi
  [ -f "$u/cell-self-pin.service" ] && bad "a refused install (drop-in: $name) still wrote the unit" \
    || ok "a refused install (drop-in: $name) wrote nothing"
}
refuses_dropin 'carries the provisioning clone' "$(dropin_doctor bootpath 'WorkingDirectory=/tmp/cell-ai')" 'provisioning clone'
refuses_dropin 'declares WorkingDirectory=' "$(dropin_doctor workdir 'WorkingDirectory=/srv/harness-current')" 'WorkingDirectory='
refuses_dropin 'declares a Condition (a green skip)' "$(dropin_doctor cond 'ConditionPathExists=/srv/nope')" 'ConditionPathExists='
refuses_dropin 'declares an executable directive' "$(dropin_doctor execpre 'ExecStartPre=/bin/bash /srv/nowhere/x.sh')" 'ExecStartPre='
refuses_dropin 'widens the success vocabulary' "$(dropin_doctor okvals 'SuccessExitStatus=0 11 1')" 'SuccessExitStatus='
# ⛔ THE IDENTITY ALLOWANCE IS EXACTLY ONE VARIABLE WIDE (`Environment=HOME=`), and these legs are why. A
# drop-in OVERRIDES the rendered unit, so a drop-in carrying `Environment=CELL_HOME=` (or any other variable
# this pass READS) re-points the pass at a different pin record while the rendered unit still carries the
# correct one and `--install` reports success — the effective-unit false PASS this whole section exists for,
# one directive over from `WorkingDirectory=`. Refused as a CLASS (`HOME=` is the closed allow-list), not by
# naming `CELL_HOME=`, so a variable a future revision adds is closed without another review.
refuses_dropin 'sets Environment=CELL_HOME= (re-basing the pass)' "$(dropin_doctor envhome 'Environment=CELL_HOME=/tmp/other-home')" 'never the base'
refuses_dropin 'sets Environment=HARNESS_PIN_FILE= (re-pointing the record)' "$(dropin_doctor envpin 'Environment=HARNESS_PIN_FILE=/tmp/other-path')" 'never the base'
refuses_dropin 'declares an EnvironmentFile= (overrides Environment=)' "$(dropin_doctor envfile 'EnvironmentFile=/srv/cell-pin.env')" 'EnvironmentFile='
# THE SAME PARSE-LEVEL CLASS, ONE LAYER DOWN (round-5 review findings, all rc=0 before the rules existed):
# a drop-in is a MORE dangerous place for these than the unit, because it is merged OVER the unit and an
# operator reading the unit will never see it. `Environment=` in a drop-in also clears the list the MAIN
# UNIT built — the documented way to remove an entry.
refuses_dropin 'assigns an EMPTY Environment= (clears the unit list too)' "$(dropin_doctor envreset 'Environment=')" 'LIST RESET'
refuses_dropin 'declares an UnsetEnvironment= (undoes Environment=)' "$(dropin_doctor unsetenv 'UnsetEnvironment=CELL_HOME')" 'UnsetEnvironment='
refuses_dropin 'declares a PassEnvironment=' "$(dropin_doctor passenv 'PassEnvironment=CELL_HOME')" 'PassEnvironment='
refuses_dropin 'declares a Unit= (re-targets the timer)' "$(dropin_doctor unit 'Unit=/bin/true.service')" 're-targets'
refuses_dropin 'declares an OnCalendar= (re-schedules the timer)' "$(dropin_doctor oncal 'OnCalendar=*-*-* 00:00:00')" 're-schedules'
# ⛔ AND THE DROP-IN IS FOUND WHEREVER systemd LOOKS, NOT ONLY IN `<unit>.service.d` (round-5 review
# finding). `systemd.unit(5)`: a unit name with dashes also searches the directories made by repeatedly
# truncating it after a dash, and `type.d/` applies to every unit of that type. Measured before:
# `cell-.service.d/legacy.conf` carrying `Environment=CELL_HOME=/tmp/other-home` installed rc=0 and nothing
# in the run mentioned the file — the same false PASS one directory over.
refuses_dropin 'lives in a DASH-TRUNCATED drop-in dir (cell-.service.d)' "$(dropin_doctor dashdir 'WorkingDirectory=/srv/harness-current' 'cell-.service.d')" 'WorkingDirectory='
# ⛔ AND THE ROOT LIST ITSELF IS AN ASSERTION A TEST CAN MAKE, NOT A LIST NOTHING READS. `dropin_dirs`
# scanned three hardcoded paths and omitted `/usr/local/lib/systemd/system` — a SYSTEM unit directory on
# systemd 255 (`systemd-analyze unit-paths` prints it), and the one `systemd.unit(5)` Table 1 lists ABOVE
# `/usr/lib/systemd/system` as "System units installed by the administrator". A drop-in there is merged OVER
# the rendered unit and was read by NOTHING, while `--install` printed "installed — ONE actuator on this
# pin" and exited 0: the same false PASS one directory over, in the directory an operator building a cell
# by hand is most likely to use. MEASURED: deleting `/run` and `/usr/lib` from that list left this suite at
# 240 ok / 0 failed, so nothing pinned the enumeration at all.
roots_out="$(runat "$T/home" CELL_SELF_PIN_DROPIN_ROOTS= bash "$PIN" --print-dropin-roots 2>&1)"
# ⛔ AND THE LIST WAS STILL A SUBSET OF WHAT systemd MERGES (round-4 review, P1). `systemd-analyze
# unit-paths` on systemd 255 prints TWELVE entries; MEASURED with a probe drop-in and
# `systemd-analyze verify --root`, the four `.control`/`.attached` roots below DO merge a
# `<unit>.d/*.conf` over the unit — and none of them was scanned, so a hostile drop-in there was applied
# by systemd and read by nothing: #3194's false PASS one directory over, in the load path `systemd.unit(5)`
# Table 1 ranks ABOVE /etc/systemd/system. The four-name leg above could not see a root that is MISSING.
for _r in /etc/systemd/system.control /run/systemd/system.control /etc/systemd/system.attached /run/systemd/system.attached; do
  if grep -qxF "$_r" <<<"$roots_out"; then ok "…and the drop-in gate SCANS ${_r} — a .control/.attached root systemd MERGES over the unit (measured)"
  else bad "the drop-in gate does not scan ${_r}: a drop-in there is merged over the rendered unit by systemd and read by NOTHING — #3194's false PASS in the dbus-managed load path — [$roots_out]"; fi
done
# ⛔ AND THE MATCH MUST BE THE WHOLE LINE. These four were SUBSTRING tests (`case "$roots_out" in *"$_r"*)`),
# so `/etc/systemd/system` was satisfied by `/etc/systemd/system.control` and `/run/systemd/system` by
# `/run/systemd/system.attached` — MEASURED: deleting `/etc/systemd/system` from the list, and then deleting
# BOTH plain roots, left the suite at 411 ok / 0 failed. With `SYSTEMD_UNIT_DIR` redirected (every leg here,
# and the documented case) the root list is the ONLY source for those two, so their removal shipped green
# and re-opened #3194's drop-in false PASS silently. `grep -qxF` is the test that a leg can lose.
for _r in /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system; do
  if grep -qxF "$_r" <<<"$roots_out"; then ok "…and the drop-in gate SCANS ${_r} — a systemd SYSTEM unit directory it merges for this unit"
  else bad "the drop-in gate does not scan ${_r}: a legacy drop-in there is merged over the rendered unit and read by NOTHING, which is #3194's false PASS one directory over — [$roots_out]"; fi
done
# ⛔ AND EVERY OTHER LEG IS HERMETIC (round-12 review, P2). Unsetting the seam did NOT make the scan
# hermetic: it fell back to the REAL roots above — measured at 151 reads of each real root per run,
# including 66 reads of this host's own `/etc/systemd/system/cell-self-pin.service.d/user.conf`. This host
# happens to carry an identity-only drop-in, which is the only reason the install legs are green here; the
# same file carrying `WorkingDirectory=` or a `Condition*` (precisely the classes `verify_dropins` refuses)
# would red every install leg for a reason unrelated to the code, and a REFUSAL leg could be satisfied by
# host state instead of by its doctor. The leg above asks for the DEFAULT roots deliberately; this one pins
# that nothing else touches them.
hermetic_out="$(runat "$T/home" bash "$PIN" --print-dropin-roots 2>&1)"
case "$hermetic_out" in
  *'/etc/systemd/system'*) bad "a leg WITHOUT the seam scanned the host's real /etc/systemd/system — the suite gates the effective unit while reading the host's own: [$hermetic_out]" ;;
  *"$T/dropins-hermetic"*) ok "…and every other leg scans a PER-RUN drop-in root, never the host's real unit directories" ;;
  *) bad "the per-run drop-in root is not what a default leg scans: [$hermetic_out]" ;;
esac
# The real roots are root-owned on every box that has them, so the ENUMERATION is exercised through its
# documented seam rather than asserted by grep: a drop-in planted under a CONFIGURED root, outside the unit
# dir, must be refused and name the file. A gate that only reads the unit dir passes the legs above.
u_alt="$T/units-altroot"; mkdir -p "$u_alt" "$T/altroot/cell-self-pin.service.d"
printf '[Service]\nWorkingDirectory=/tmp/cell-ai\n' >"$T/altroot/cell-self-pin.service.d/legacy.conf"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$u_alt" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
         CELL_SELF_PIN_DROPIN_ROOTS="$T/altroot" PATH="$T/fakebin:$PATH" bash "$PIN" --install 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "ACCEPTED a drop-in living under a configured SYSTEM root OUTSIDE the unit dir — so a box carrying /usr/local/lib/systemd/system/cell-self-pin.service.d/legacy.conf installs rc=0 and keeps the defect: $out"
elif [[ $out == *'provisioning clone'* ]]; then
  ok "…and a drop-in under a root OTHER than the unit dir is REFUSED by name, so the root list is load-bearing"
else bad "refused an out-of-unit-dir drop-in for the WRONG reason: $out"; fi
refuses_dropin 'lives in the TYPE-LEVEL drop-in dir (service.d)' "$(dropin_doctor typedir 'ConditionPathExists=/srv/nope' 'service.d')" 'ConditionPathExists='
refuses_dropin 'declares a RootDirectory= (systemd enters it before the payload)' "$(dropin_doctor rootdir 'RootDirectory=/srv/harness-current')" 'never began'
# …and the whole MOUNT family, in the file systemd merges OVER the artifact this run verified. The loop is
# the point (round-21 review): one leg per grader-and-member pair, so no member can be silently re-opened.
for _md in $MOUNT_DIRECTIVES; do
  refuses_dropin "declares a ${_md}= (a mount in the unit's view)" "$(dropin_doctor "mount-$_md" "${_md}=/srv/evil:/srv/payload/cell-self-pin.sh")" 'mounts into'
done
refuses_dropin 'declares a DynamicUser= (an allocated identity cannot pin the tree)' "$(dropin_doctor dynamicuser 'DynamicUser=yes')" 'DynamicUser='
# ⛔ AND THE TIMER'S DROP-INS ARE A SEPARATE SET, WHICH NOTHING READ. `dropin_dirs` enumerates what systemd
# merges FOR THE NAME IT IS GIVEN, and `--install` verified only `cell-self-pin.service` — so
# `cell-self-pin.timer.d/`, `cell-self-.timer.d/`, `timer.d/` and the `/run` + `/usr/lib` copies went unread,
# and the `Unit=|On*=` arm written for exactly that threat could only ever fire on a SERVICE drop-in, where
# systemd ignores both keys. MEASURED rc=0: `OnCalendar=` (fires at midnight, not every ten minutes) and
# `Unit=/bin/true.service` (activates nothing) each installed green and silently — a pin that never runs.
refuses_dropin 're-schedules the timer, in the TIMER drop-in dir (cell-self-pin.timer.d)' "$(dropin_doctor timerondir 'OnCalendar=*-*-* 00:00:00' 'cell-self-pin.timer.d')" 're-schedules'
refuses_dropin 're-targets the timer, in the TIMER drop-in dir (Unit=)' "$(dropin_doctor timerunit 'Unit=/bin/true.service' 'cell-self-pin.timer.d')" 're-targets'
# ⛔ AND THE REASON MUST BE TRUE FOR THE UNIT TYPE IT IS READING (round-3 review, P2). This reader serves
# BOTH unit names, and a service's cause is false for a timer: a timer executes nothing, so `WorkingDirectory=`
# cannot fail it at CHDIR. Measured on this box: `systemd-analyze verify` answers "Unknown section 'Service'.
# Ignoring." / "Unknown key name 'WorkingDirectory' in section 'Timer', ignoring." — the key is INERT there.
# The refusal is right either way; the CAUSE is what these two legs pin, because an operator who is refused
# for a failure mode that cannot occur deletes the wrong line for the wrong reason.
refuses_dropin 'declares WorkingDirectory= in a TIMER drop-in (the key is inert there)' \
  "$(dropin_doctor timerwd 'WorkingDirectory=/srv/harness-current' 'cell-self-pin.timer.d')" 'Unknown key name'
refuses_dropin 'declares a RootDirectory= in a TIMER drop-in (the key is inert there)' \
  "$(dropin_doctor timerroot 'RootDirectory=/srv/harness-current' 'cell-self-pin.timer.d')" 'Unknown key name'
# ⛔ THE MOUNT ARM IS THE NEXT SERVICE-ONLY ARM, AND IT WAS NOT CARRIED INTO THE TIMER GRADER (round-20
# review, P3). `is_timer`'s whole point is that it guards the FAMILY so "a new service-only arm added later
# is covered without another review" — and the very next arm added was not. Measured before this leg: a
# `cell-self-pin.timer.d/` drop-in declaring `BindPaths=` WAS refused, but with the SERVICE cause ("…put
# different bytes over the ExecStart…"), a failure mode a timer cannot have — the exact wrong-cause class
# round 4 fixed for `User=`/`DynamicUser=`/`RootDirectory=`. One leg per member, on the TIMER wording, so
# the cause cannot fall back to the service text one name at a time.
for _md in $MOUNT_DIRECTIVES; do
  refuses_dropin "declares a ${_md}= in a TIMER drop-in (the key is inert there)" \
    "$(dropin_doctor "timermount-$_md" "${_md}=/srv/evil:/srv/x" 'cell-self-pin.timer.d')" 'TIMER drop-in'
done
# ⛔ AND THE IDENTITY ARMS ARE THE SAME CLASS (round-4 review, P2). `User=` and `DynamicUser=` were added
# to this reader with a SERVICE's reason ("the pass would run as that user", "cannot show that the pass
# still runs as the owner") — both false in a `[Timer]`, where every `[Service]`-only key is inert
# (`systemd-analyze verify`: "Unknown key name 'User' in section 'Timer', ignoring.", measured). One
# family guard now covers the whole set, so these two legs pin the reason and any future service-only arm
# inherits it.
refuses_dropin 'declares User=root in a TIMER drop-in (the key is inert there)' \
  "$(dropin_doctor timeruser 'User=root' 'cell-self-pin.timer.d')" 'IGNORES it in a [Timer]'
refuses_dropin 'declares DynamicUser=yes in a TIMER drop-in (the key is inert there)' \
  "$(dropin_doctor timerdyn 'DynamicUser=yes' 'cell-self-pin.timer.d')" 'IGNORES it in a [Timer]'
# ⛔ AND A DROP-IN MAY NOT CARRY `[Install]` — THE ENABLEMENT PATH WAS THE LAST DOOR (round-6 review, P1).
# systemd applies `[Install]` at ENABLE time, so no load-time rule above can see it, and `WantedBy=` is a
# LIST with the same empty-assignment RESET this file already refuses elsewhere. MEASURED on systemd 255:
# `[Install]` + `WantedBy=` in a timer drop-in makes `systemctl enable` answer "The unit files have no
# installation config" and exit **0** while creating NO symlink — so the install prints its positive claim
# over a pin that is never enabled. Two legs: the EMPTY list-reset (the measured spelling) and a NON-empty
# `WantedBy=` (a drop-in cannot add enablement the rendered unit does not already declare).
refuses_dropin 'carries [Install] with an EMPTY WantedBy= (a LIST RESET; enable exits 0 and creates no link)' \
  "$(dropin_doctor installreset '[Install]
WantedBy=' 'cell-self-pin.timer.d')" 'NO symlink'
refuses_dropin 'carries [Install] at all (systemd applies it at ENABLE time, not load time)' \
  "$(dropin_doctor installsec '[Install]
WantedBy=timers.target' 'cell-self-pin.service.d')" 'NO symlink'
# ⛔ THE IDENTITY ALLOWANCE WAS ADVERTISED AND NEVER READ (round-13 review, P1). This section's own header
# says a drop-in "MAY adjust IDENTITY (User=, Environment=HOME=)" — and `verify_unit` refuses any `User=`
# that is not the owner of `$CELL_HOME` because that is the identity whose git can answer for the tree the
# pass pins. The drop-in path had NO `User)` arm at all, so the two rules disagreed and the LENIENT one
# won: a drop-in is merged OVER the rendered unit, so `User=root` there reinstates the exact #3194 outcome
# (`UNRESOLVED(no-layer)` every tick, root's git refusing the cell user's checkout as dubious ownership)
# while `--install` prints "installed — ONE actuator on this pin". MEASURED rc=0 before this arm.
# The cell home here is `$T/home`, owned by the INVOKING user, so `User=root` is hostile only when that user
# is not root — where it is not, the leg says so honestly instead of asserting nothing (the suite's
# established pattern for every identity-discriminating fixture, see the `owner_of /` leg below).
if [ "$(id -u)" -eq 0 ]; then
  ok "SKIPS the User=root drop-in leg honestly: this suite is running AS root, so root IS the owner of the cell home here and the value is not the defect"
else
  refuses_dropin 'sets User=root — an identity whose git cannot answer for the tree' "$(dropin_doctor userroot 'User=root')" 'cannot answer for the tree'
fi
# ⛔ AND AN EMPTY `User=` IS THE SAME DEFECT, NOT A HARMLESS RESET. `systemd.exec(5)`: an empty assignment
# restores the manager's DEFAULT identity, which for a SYSTEM unit is root — so the file that was supposed
# to correct the identity silently re-installs the one that cannot pin. `$(directive …)` cannot express
# this (an empty value and an absent one both yield ""), which is why the arm reads RAW LINES and this leg
# is unconditional: it is hostile under every identity this suite can run as.
refuses_dropin 'declares an EMPTY User= (a reset to the manager default, i.e. root for a system unit)' "$(dropin_doctor userempty 'User=')" 'resets to the manager'
# ⛔ THE NON-VACUITY CONTROL, and it is load-bearing: a drop-in that only sets IDENTITY is the operator's
# DOCUMENTED remedy for the `User=root` render. Without this leg the gate above could "pass" by refusing
# every drop-in, which would block the one migration this file recommends.
u_bene="$T/dropin-benign"
mkdir -p "$u_bene/cell-self-pin.service.d"
printf '[Service]\nUser=%s\nEnvironment=HOME=%s\n' "$(id -un)" "$HOME" >"$u_bene/cell-self-pin.service.d/user.conf"
out_bene="$(install_doctored "$TPL" "$u_bene")"; rc_bene=$?
if [ "$rc_bene" -eq 0 ]; then ok "ACCEPTS a drop-in that only sets IDENTITY (User=/HOME=) — the gate discriminates; it does not refuse every drop-in"
else bad "REFUSED a benign identity-only drop-in — that is the operator's documented remedy for the User=root render: $out_bene"; fi
# ⛔ RE-SEED THE PLACED-PASS SENTINEL. The benign leg above is the only SUCCESSFUL install in this region,
# and a successful install legitimately (re)places the pass at $PLACED — which is precisely the artifact the
# `refuses` legs assert a REFUSED install leaves untouched. Without this line the next refusal is reported
# as "REPLACED the placed pass" for a replacement that was correct, i.e. the sentinel would be measuring the
# wrong install.
cp "$T/placed.before" "$PLACED"
# ── 4b-bis. A DROP-IN THIS RUN CANNOT READ IS NOT A DROP-IN WITH NOTHING IN IT ────────────────────
# ⛔ THE SAME FALSE PASS, ONE SYSCALL OVER (round-3 review, P1). `verify_dropin_file` ran
# `body="$(grep -vE … "$f")"` and DISCARDED grep's exit status, so an unreadable drop-in (0600 and
# root-owned, an I/O error) produced an EMPTY body — every rule in that function ran on nothing, and
# `--install` went on to print "installed — ONE actuator on this pin" while systemd merged that file OVER
# the unit. Measured on this host, both routes, before the fix:
#   * `grep -vE … /an-unreadable-file`  → rc=2 on STDERR, EMPTY stdout, body empty;
#   * `grep -vE … ./nul.conf` (NUL byte) → rc=0, EMPTY stdout on BSD/macOS grep, one
#     "Binary file … matches" line on GNU grep — in neither case the file's directives.
#   * and `verify_dropins` iterated a glob that does not expand in a directory it cannot SEARCH, so the
#     body never ran and the function still returned PASS.
# Every leg feeds the gate the DEFECT (a real `WorkingDirectory=` inside the unreadable/binary file), so a
# gate that "passes" by refusing any drop-in cannot satisfy them — the benign identity-only leg above
# still has to install.
u_nul="$T/dropin-nul"; mkdir -p "$u_nul/cell-self-pin.service.d"
printf '[Service]\n\000\nWorkingDirectory=/tmp/cell-ai\nExecStartPre=/bin/bash /srv/nowhere/x.sh\n' >"$u_nul/cell-self-pin.service.d/legacy.conf"
refuses_dropin 'is a BINARY file (a NUL byte), so grep answers with no directives at all' "$u_nul" 'NUL byte'
u_unread="$T/dropin-unread"; mkdir -p "$u_unread/cell-self-pin.service.d"
printf '[Service]\nWorkingDirectory=/srv/harness-current\nConditionPathExists=/srv/nope\n' >"$u_unread/cell-self-pin.service.d/legacy.conf"
chmod 000 "$u_unread/cell-self-pin.service.d/legacy.conf"
if [ "$(id -u)" -eq 0 ]; then
  ok "SKIPS the unreadable-drop-in leg honestly: running as root, where mode 000 does not hide a file (the route can not be reproduced, so it is not claimed)"
else
  refuses_dropin 'cannot be READ at all (0600, not ours) — its directives were never verified' "$u_unread" 'cannot be READ by this run'
fi
chmod 644 "$u_unread/cell-self-pin.service.d/legacy.conf"
u_nosearch="$T/dropin-nosearch"; mkdir -p "$u_nosearch/cell-self-pin.service.d"
printf '[Service]\nWorkingDirectory=/tmp/cell-ai\n' >"$u_nosearch/cell-self-pin.service.d/legacy.conf"
chmod 000 "$u_nosearch/cell-self-pin.service.d"
if [ "$(id -u)" -eq 0 ]; then
  ok "SKIPS the unsearchable-drop-in-directory leg honestly: running as root, where mode 000 does not hide a directory (the route can not be reproduced, so it is not claimed)"
else
  refuses_dropin 'lives in a drop-in directory this run cannot SEARCH (the glob never expanded)' "$u_nosearch" 'cannot be READ/SEARCHED'
fi
chmod 755 "$u_nosearch/cell-self-pin.service.d"
# ⛔ AND THE ROOT ITSELF: AN UNSEARCHABLE ROOT IS NOT A ROOT WITH NO DROP-INS (round-13 review, P1). The
# guard above fires on a `.d` it FOUND; this one is the case where nothing can be found at all. The old
# enumeration opened with `[ -d "$root" ] || continue` — and a 000-mode directory STATS TRUE, so the root
# was PROCEEDED PAST, not skipped: every candidate under it failed `[ -d "$root/<name>.d" ]` for want of
# search permission, the loop body never ran, and `--install` printed "installed — ONE actuator on this
# pin". MEASURED rc=0 with a `cell-self-pin.service.d/legacy.conf` carrying `WorkingDirectory=/tmp/cell-ai`
# under that root — systemd (root, not bound by this run's permissions) merges it anyway. So the verdict is
# taken ON THE ROOT, before anything under it is enumerated.
u_root000="$T/units-nosearch-root"; mkdir -p "$u_root000"
roothidden="$T/roothidden"
mkdir -p "$roothidden/cell-self-pin.service.d"
printf '[Service]\nWorkingDirectory=/tmp/cell-ai\n' >"$roothidden/cell-self-pin.service.d/legacy.conf"
chmod 000 "$roothidden"
if [ "$(id -u)" -eq 0 ]; then
  ok "SKIPS the unsearchable-drop-in-ROOT leg honestly: running as root, where mode 000 does not hide a directory (the route can not be reproduced, so it is not claimed)"
else
  out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$u_root000" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
           CELL_SELF_PIN_DROPIN_ROOTS="$roothidden" PATH="$T/fakebin:$PATH" bash "$PIN" --install 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "ACCEPTED an unsearchable drop-in ROOT — a 000-mode root carrying a WorkingDirectory= drop-in installed rc=0, so 'nothing found here' was reported about a directory this run could not open: $out"
  elif [[ $out == *'cannot be READ/SEARCHED'* ]]; then
    ok "…and an unsearchable drop-in ROOT is REFUSED by name (the root, not a file it could not list)"
  else bad "refused an unsearchable drop-in root for the WRONG reason: $out"; fi
  [ -f "$u_root000/cell-self-pin.service" ] && bad "a refused install (unsearchable root) still wrote the unit" \
    || ok "a refused install (unsearchable root) wrote nothing"
fi
chmod 755 "$roothidden"
# ⛔ AND ONE LEVEL UP, WHERE `[ -e "$root" ]` STOPS BEING A READING AND BECOMES A GUESS (round-14 review,
# P2). `stat` needs every component of the path SEARCHABLE, so a root whose PARENT is 000 answers `-e`
# FALSE — "absent" — when the truth is "this run cannot see". Measured: `$T/parhidden` at 000 with
# `root/cell-self-pin.service.d/legacy.conf` carrying `WorkingDirectory=/tmp/cell-ai` installed rc=0 and
# nothing in the run mentioned the file. `root_decidable` walks the ancestors first, and undecidable is a
# refusal: "nothing found here" may not be reported about a directory this run cannot look into.
u_par000="$T/units-nosearch-parent"; mkdir -p "$u_par000"
parhidden="$T/parhidden"
mkdir -p "$parhidden/root/cell-self-pin.service.d"
printf '[Service]\nWorkingDirectory=/tmp/cell-ai\n' >"$parhidden/root/cell-self-pin.service.d/legacy.conf"
chmod 000 "$parhidden"
if [ "$(id -u)" -eq 0 ]; then
  ok "SKIPS the unsearchable-PARENT leg honestly: running as root, where mode 000 does not hide a directory (the route can not be reproduced, so it is not claimed)"
else
  out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$u_par000" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
           CELL_SELF_PIN_DROPIN_ROOTS="$parhidden/root" PATH="$T/fakebin:$PATH" bash "$PIN" --install 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "ACCEPTED a drop-in root whose PARENT cannot be searched — the run reported 'no drop-ins' about a directory it could not stat, so a box carrying that legacy drop-in installs rc=0 and keeps the defect: $out"
  elif [[ $out == *'cannot be DECIDED'* ]]; then
    ok "…and a drop-in root whose PARENT is unsearchable is REFUSED as UNDECIDABLE, not silently treated as absent"
  else bad "refused an undecidable drop-in root for the WRONG reason: $out"; fi
  [ -f "$u_par000/cell-self-pin.service" ] && bad "a refused install (undecidable root) still wrote the unit" \
    || ok "a refused install (undecidable root) wrote nothing"
fi
chmod 755 "$parhidden"
# ⛔ AND A NON-DIRECTORY ANCESTOR IS A DECIDED ANSWER, NOT AN UNDECIDABLE ONE (round-14 review, P2). `stat`
# fails because nothing can live under a regular file — the root PROVABLY does not exist — but the first
# version of `root_decidable` used `[ -x ]` for that component, which is false for a plain file, so it
# reported UNDECIDABLE and refused a healthy box while asserting a false cause ("a parent is not
# searchable") about a searchable directory whose child happens to be a file. This leg is the
# non-vacuity direction of the same rule: the install must SUCCEED.
regular_file_anc="$T/regular-file-ancestor"
: >"$regular_file_anc"
u_filed_anc="$T/units-file-ancestor"; mkdir -p "$u_filed_anc"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$u_filed_anc" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
         CELL_SELF_PIN_DROPIN_ROOTS="$regular_file_anc/root" PATH="$T/fakebin:$PATH" bash "$PIN" --install 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "ACCEPTS a drop-in root under a regular FILE (that path provably cannot exist, so there is nothing to refuse)"
else
  bad "REFUSED a drop-in root whose ancestor is a regular file — an absent path is not an undecidable one, and the refusal asserts a cause that is false: $out"
fi
# ⛔ AND A ROOT THAT IS ITSELF A REGULAR FILE IS A REFUSAL, NOT AN EMPTY RESULT — and the arm saying so had
# no leg at all (round-5 review, P2: `if [ ! -d "$_root" ]` → `if false` left 411 ok / 0 failed). The fixture
# above is the OPPOSITE case and must stay: a root under a file ancestor provably does not exist and is
# accepted, while a path that IS a file is decided but cannot hold drop-ins, so a run that trusted it would
# report "nothing found here" about something systemd resolves differently. `-e` is true, it is not a dir.
u_file_root="$T/units-fileroot"; mkdir -p "$u_file_root"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$u_file_root" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
         CELL_SELF_PIN_DROPIN_ROOTS="$regular_file_anc" PATH="$T/fakebin:$PATH" bash "$PIN" --install 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "ACCEPTED a drop-in ROOT that is a regular FILE — 'nothing found here' was reported about a path systemd does not treat as a drop-in directory: $out"
elif [[ $out == *'NOT a directory'* ]]; then
  ok "…and a drop-in ROOT that is a regular FILE is REFUSED by name (a decided path that cannot hold drop-ins)"
else bad "refused a file-shaped drop-in root for the WRONG reason: $out"; fi
# ⛔ AND THE ENUMERATION'S OUTPUT MUST NOT BE WORD-SPLIT EITHER (round-14 review, P2). The root list was
# fixed and its OUTPUT was not, so a unit dir containing a space was re-interpreted by the shell as two
# paths: measured, this exact fixture either refused naming a directory that never existed (with a blank
# mode) or — when a same-named relative directory existed in the CWD — installed rc=0 while never reading
# the hostile drop-in the real directory holds. A path with a space in it is the whole point of the leg.
u_space="$T/units-with space"; mkdir -p "$u_space/cell-self-pin.service.d"
printf '[Service]\nWorkingDirectory=/srv/harness-current\n' >"$u_space/cell-self-pin.service.d/legacy.conf"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$u_space" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
         PATH="$T/fakebin:$PATH" bash "$PIN" --install 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "ACCEPTED a unit dir containing a SPACE — the enumeration's output was word-split, so the hostile drop-in in it was never read: $out"
elif [[ $out == *'WorkingDirectory='* ]]; then
  ok "…and a unit dir containing a SPACE is enumerated as ONE path, so its drop-in is refused by name"
else bad "refused a spaced unit dir for the WRONG reason: $out"; fi
# ⛔ AND THE SEAM'S OWN VALUE IS THE SAME CLASS ONE LEVEL UP (round-3 review, P2). The unit dir was fixed
# and `CELL_SELF_PIN_DROPIN_ROOTS`/`SYSTEMD_UNIT_ROOTS` were still word-split, so a ROOT whose path contains
# a space became two roots that do not exist: measured at this head, `--install` printed "installed" and
# exited rc=0 while the hostile drop-in inside that very root — merged by systemd — was never read. The list
# is now newline-separated end to end (one root per line), which is the only separator a path cannot carry.
space_root="$T/root with space"; mkdir -p "$space_root/cell-self-pin.service.d"
printf '[Service]\nWorkingDirectory=/srv/harness-current\n' >"$space_root/cell-self-pin.service.d/legacy.conf"
u_spaceroot="$T/units-spaceroot"; mkdir -p "$u_spaceroot"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$u_spaceroot" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 \
         CELL_SELF_PIN_DROPIN_ROOTS="$space_root" PATH="$T/fakebin:$PATH" bash "$PIN" --install 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  bad "ACCEPTED a drop-in ROOT whose path contains a SPACE — the seam was word-split, so the root was never enumerated and a systemd-merged WorkingDirectory= went unread: $out"
elif [[ $out == *'WorkingDirectory='* ]]; then
  ok "…and a drop-in ROOT containing a SPACE is enumerated as ONE path, so its drop-in is refused by name"
else bad "refused a spaced drop-in root for the WRONG reason: $out"; fi
# ⛔ THE NON-VACUITY CONTROL FOR *THESE* LEGS TOO: a readable, benign drop-in must still INSTALL, or the
# three legs above could "pass" by refusing every drop-in the file cannot read for any reason.
u_nul_ok="$T/dropin-nul-ok"; mkdir -p "$u_nul_ok/cell-self-pin.service.d"
printf '[Service]\nUser=%s\nEnvironment=HOME=%s\n' "$(id -un)" "$HOME" >"$u_nul_ok/cell-self-pin.service.d/user.conf"
out_nul_ok="$(install_doctored "$TPL" "$u_nul_ok")"; rc_nul_ok=$?
[ "$rc_nul_ok" -eq 0 ] && ok "…and a TEXT drop-in with no NUL is still read and accepted (the NUL rule refuses binaries, not drop-ins)" \
  || bad "refused a plain TEXT identity-only drop-in after the NUL rule was added: $out_nul_ok"
cp "$T/placed.before" "$PLACED"
# ⛔ AND "grep SELECTED NOTHING" IS NOT "THE READ FAILED" (round-8 review, measured over-block). The read
# gate above treats rc>=2 as a read failure — correct — but the first version treated EVERY non-zero as one,
# so an EMPTY or comment-only drop-in (rc=1: no non-comment line, nothing to verify, benign) was REFUSED with
# a remedy naming permissions that were already correct. A drop-in with no directives must INSTALL.
u_empty="$T/dropin-empty"; mkdir -p "$u_empty/cell-self-pin.service.d"
printf '# nothing but a comment\n' >"$u_empty/cell-self-pin.service.d/empty.conf"
out_empty="$(install_doctored "$TPL" "$u_empty")"; rc_empty=$?
[ "$rc_empty" -eq 0 ] && ok "ACCEPTS a comment-only/empty drop-in (grep rc=1 is 'no directives', not a read failure)" \
  || bad "refused a benign comment-only drop-in and blamed its permissions: $out_empty"
cp "$T/placed.before" "$PLACED"
# ── 4c. THE RENDER'S IDENTITY IS THE TREE'S OWNER, NOT THE INVOKER'S ────────────────────
# ⛔ `--install` writes a SYSTEM unit under /etc/systemd/system and needs `systemctl enable`, so the
# documented install path is `sudo … --install` — and rendering `{{USER}}` from `id -un` therefore baked
# `User=root` into a unit that must run as the owner of the tree it pins. This fleet's own drop-in records
# the consequence verbatim: root's git refuses the operator-owned checkout on ownership grounds, so the
# pass finds no layer and exits `UNRESOLVED(no-layer)` every tick — #3194 reached by following this
# change's own migration. THE DISCRIMINATOR IS A CELL_HOME WHOSE OWNER IS NOT THE INVOKING USER: `/` is
# root-owned on every box this suite runs on, so an `id -un` render yields the invoking user and fails.
owner_of() { ls -ld "$1" 2>/dev/null | awk '{print $3}'; }
out_id="$(runat "$T/home" CELL_HOME=/ TEMPLATES_DIR="$TPL" bash "$PIN" --print-unit 2>&1)"
got_user="$(printf '%s\n' "$out_id" | sed -n 's/^User=//p' | head -1)"
want_user="$(owner_of /)"
if [ "$want_user" = "$(id -un)" ]; then
  ok "SKIPS the owner-derivation discriminator honestly: / is owned by the INVOKING user here, so User= cannot tell the two renders apart on this box"
elif [ "$got_user" = "$want_user" ]; then
  ok "the rendered User= is the OWNER of CELL_HOME ('$want_user'), not the invoking user ('$(id -un)') — an id-un render would have baked User=$(id -un)"
else bad "the rendered User= is '$got_user', not the owner of CELL_HOME ('$want_user') — the render followed the INVOKING identity, which is how User=root reached a box that can only pin as its owner"; fi
got_home="$(printf '%s\n' "$out_id" | sed -n 's/^Environment=HOME=//p' | head -1)"
if [ "$want_user" != "$(id -un)" ]; then
  if [ "$got_home" = "$(eval "printf '%s' ~$want_user" 2>/dev/null)" ]; then ok "and its HOME= is that owner's home ('$got_home'), not the installer's"
  else bad "the rendered HOME= is '$got_home', not the owner's home — the pass would derive its base from the installer's home"; fi
fi
# ⛔ FOUR RULES THAT HAD NO DOCTOR AT ALL — deleting any one of them left this suite green, which the body's
# «one doctor per rule» claim does not survive. Each doctor below trips ITS rule and nothing else:
#   · the INTERPRETER rule is individually gating only because ExecStart is parsed as interpreter+payload;
#     `/bin/sh <a path under CELL_HOME>` passes every other rule, so nothing else can answer for it.
#   · the CELL_HOME environment rule is the only check on `Environment=`;
#   · the two SuccessExitStatus rules (present; and only 0/11) are the difference between a RED and a green
#     on every failure this unit exists to surface. ⛔ AND THAT CLAIM WAS HALF-TRUE: 11 was only allowed, not
#     required, so a unit could be made permanently red on a mend without this suite noticing. It is required
#     now, with a doctor (section 4d) — and the companion “must include 0” rule was REMOVED there, because
#     `systemd.service(5)` makes 0 successful regardless, so it only refused valid units.
refuses 'an ExecStart that is not /bin/bash' "$(doctor_rw interp "s|^ExecStart=/bin/bash .*$|ExecStart=/bin/sh $T/home/.pi/agent/scripts/cell-self-pin.sh|")" "$T/u13" "not '/bin/bash'"
refuses 'a MISSING Environment=CELL_HOME=' "$(doctor_rw nocellhome '/^Environment=CELL_HOME=/d')" "$T/u14" 'Environment=CELL_HOME='
refuses 'a MISSING SuccessExitStatus=' "$(doctor_rw noexit '/^SuccessExitStatus=/d')" "$T/u15" 'must declare SuccessExitStatus'
refuses 'a WIDENED SuccessExitStatus=' "$(doctor_rw wideexit 's|^SuccessExitStatus=.*$|SuccessExitStatus=0 11 1|')" "$T/u16" 'neither 0'
# ⛔ AND THE IDENTITY IS NOT ONE DIRECTIVE. `User=` was refused and `DynamicUser=yes` installed rc=0
# (measured, round-14 review P2): `systemd.exec(5)` allocates that identity AT START-UP, so the payload
# does not run as the owner of `$CELL_HOME` and its git cannot answer for the tree — the same dead pin the
# `User=` rule exists to prevent, one name over. The doctor APPENDS (keeping the legitimate `User=` line),
# so no other rule can answer for it.
refuses 'a DynamicUser= (systemd ALLOCATES the identity — it cannot pin the tree)' "$(doctor dynamicuser 'DynamicUser=yes')" "$T/u35" 'DynamicUser='
# ⛔ AND THE macOS SPELLING OF THE CLONE. `/tmp` IS `/private/tmp` there, and the token rule required the
# literal `/tmp/` — so this installed GREEN. It is reachable as an `Environment=` value, which NOTHING else
# inspects (the `declares`/`$CELL_HOME` rules read only `WorkingDirectory=` and `ExecStart=`), and the pass
# that read it would derive a different pin record than the controller. This suite already resolves `/tmp`
# for its own git paths (`pwd -P`); the guard has to see the same spelling.
# ⛔ EVERY LEG GETS ITS OWN UNIT DIR. These three were reusing `$T/u17`/`$T/u18`/`$T/u19`, which an
# earlier leg in this file also installed into — so under a MUTANT that reverts one of those rules the
# install succeeds, the shared dir keeps the written unit, and the NEXT leg's "wrote nothing" assertion
# measures the PREVIOUS leg's install: one reverted rule reds a cascade of unrelated legs and the mutation
# count stops measuring the rule it names (round-13 review, P2). `u32`–`u34` are unused anywhere else.
refuses 'an Environment= naming /private/tmp/cell-ai' "$(doctor privtmp 'Environment=HARNESS_PIN_FILE=/private/tmp/cell-ai/.harness-path')" "$T/u32" 'provisioning clone'
# ⛔ AND THE ENVIRONMENT ALLOWANCE IS ONE VARIABLE WIDE *IN THE RENDERED UNIT TOO* (round-8 review, P1).
# The unit arm used to COUNT `Environment=CELL_HOME=` and ignore every other assignment, while the drop-in arm
# already refused everything but `HOME=` — so a template carrying `Environment=HARNESS_PIN_FILE=/srv/elsewhere`
# installed rc=0, wrote the line, and the pass then derived its layer from a record the controller never reads.
# Each leg REPLACES `HOME=` (rather than appending a line) so the plain count/value rule cannot answer for it:
# the verdict can only come from the allow-list, which is what these legs exist to pin.
refuses 'an Environment= re-pointing the pin RECORD (HARNESS_PIN_FILE) in the rendered unit' \
  "$(doctor_rw envrec 's|^Environment=HOME=.*$|Environment=HARNESS_PIN_FILE=/srv/elsewhere/.harness-path|')" "$T/u33" 'Environment=HARNESS_PIN_FILE='
refuses 'an Environment= re-pointing the pin ROOT (HARNESS_PIN_DIR) in the rendered unit' \
  "$(doctor_rw envroot 's|^Environment=HOME=.*$|Environment=HARNESS_PIN_DIR=/srv/elsewhere/pins|')" "$T/u34" 'Environment=HARNESS_PIN_DIR='

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
    'printf "%s %s\n" "$verb" "$unit" >>"$S/calls.log" 2>/dev/null' \
    'st="$S/$scope-$unit"' \
    'case "$verb" in' \
    '  is-enabled) if [ -f "$st" ]; then echo enabled; exit 0; fi; echo disabled; exit 1 ;;' \
    '  disable) [ -f "$S/$scope-stubborn" ] && exit 0; rm -f "$st"; exit 0 ;;' \
    '  enable) if [ "$unit" = cell-self-pin.timer ] && [ -f "$S/fail-enable-self" ]; then exit 1; fi; : >"$st"; exit 0 ;;' \
    'esac' \
    'exit 0' >"$d/systemctl"
  chmod +x "$d/systemctl"
  return 0
}
SHIPPED=eldato-harness-apply.timer
# mk_vanish_systemctl — the manager ANSWERS its reads, then LOSES ITS BUS after a `disable`. This is not a
# hypothetical: `Failed to connect to bus: No medium found` is this box's real answer from the identity a
# system unit runs as, and it is why an EXIT CODE cannot answer "was it retired?".
mk_vanish_systemctl() { # <dir> <state-dir>
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
    'if [ -f "$S/gone" ] && [ "$verb" = "is-enabled" ]; then echo "Failed to connect to bus: No medium found" >&2; exit 1; fi' \
    'case "$verb" in' \
    '  is-enabled) if [ -f "$st" ]; then echo enabled; exit 0; fi; echo disabled; exit 1 ;;' \
    '  disable) rm -f "$st"; : >"$S/gone"; exit 0 ;;' \
    '  enable) : >"$st"; rm -f "$S/gone"; exit 0 ;;' \
    'esac' \
    'exit 0' >"$d/systemctl"
  chmod +x "$d/systemctl"
  return 0
}
# mk_denied_systemctl — the SYSTEM manager ANSWERS, and REFUSES every `disable`. This is polkit's answer to# a non-root `systemctl disable --now` of a system unit (measured as this identity: `Failed to disable
# unit: Access denied`), and it is the one shape `mk_scoped_systemctl` cannot model: that fixture's
# `disable` either succeeds or LIES by exiting 0 and changing nothing.
mk_denied_systemctl() { # <dir> <state-dir>
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
    '  is-enabled) if [ -f "$st" ]; then echo enabled; exit 0; fi; echo disabled; exit 1 ;;' \
    '  disable) echo "Failed to disable unit: Access denied" >&2; exit 1 ;;' \
    '  enable) : >"$st"; exit 0 ;;' \
    'esac' \
    'exit 0' >"$d/systemctl"
  chmod +x "$d/systemctl"
  return 0
}
# mk_nolink_systemctl — the manager ACCEPTS the `enable` and LINKS NOTHING. This is not a hypothetical
# stub: it is systemd's own measured answer for a unit with no installation config. MEASURED on systemd
# 255.4 — `systemctl enable` on a timer carrying no `[Install] WantedBy=`/`RequiredBy=` answers "The unit
# files have no installation config (WantedBy=, RequiredBy=, UpheldBy=, Also=, or Alias= …)", exits **0**
# and creates NO symlink in `timers.target.wants/`; the control fixture WITH `[Install]
# WantedBy=timers.target` links, and `is-enabled` answers `enabled`. And `is-enabled` AFTERWARDS answers
# `static` **with rc=0**, which is what made an exit-code read-back report "enabled" about a clock that
# never fires. `enable` here writes no state at all, so the read-back can only see `static`.
mk_nolink_systemctl() { # <dir> <state-dir>
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
    '  is-enabled) if [ -f "$st" ]; then echo enabled; exit 0; fi; if [ "$unit" = cell-self-pin.timer ]; then echo static; exit 0; fi; echo disabled; exit 1 ;;' \
    '  disable) rm -f "$st"; exit 0 ;;' \
    '  enable) exit 0 ;;' \
    'esac' \
    'exit 0' >"$d/systemctl"
  chmod +x "$d/systemctl"
  return 0
}
# mk_indirect_systemctl — the manager answers `indirect`, which `systemd.unit(5)` defines as "the unit file
# itself is not enabled, but it has a non-empty Also= setting in the [Install] section". It is the one
# rc=0 answer that says NOT enabled, so mapping it to `enabled` would green a read-back over the very state
# it exists to catch (round-17 review, P3). Anything else is `disabled` unless real state exists, so the
# duplicate-actuator gate cannot answer for this leg.
mk_indirect_systemctl() { # <dir> <state-dir>
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
    '  is-enabled) if [ "$unit" = cell-self-pin.timer ]; then echo indirect; exit 0; fi; if [ -f "$st" ]; then echo enabled; exit 0; fi; echo disabled; exit 1 ;;' \
    '  disable) rm -f "$st"; exit 0 ;;' \
    '  enable) : >"$st"; exit 0 ;;' \
    'esac' \
    'exit 0' >"$d/systemctl"
  chmod +x "$d/systemctl"
  return 0
}
# mk_rearm_systemctl — the shipped actuator is RE-ARMED by the very `enable` that completes the migration.
# That is `cloud-cell-bringup.sh`'s `check_harness_apply` (it runs `install-harness-apply-timer.sh
# --install` on EVERY bring-up, and that ends in `systemctl enable --now eldato-harness-apply.timer`),
# collapsed into the ONE window the install cannot see: `$scopes` is read BEFORE the install, so a scope
# that goes enabled during it is in neither `$scopes` nor the retirement loop.
mk_rearm_systemctl() { # <dir> <state-dir>
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
    '  is-enabled) if [ -f "$st" ]; then echo enabled; exit 0; fi; echo disabled; exit 1 ;;' \
    '  disable) rm -f "$st"; exit 0 ;;' \
    '  enable) : >"$st"; if [ "$unit" = cell-self-pin.timer ]; then : >"$S/user-'"$SHIPPED"'"; fi; exit 0 ;;' \
    'esac' \
    'exit 0' >"$d/systemctl"
  chmod +x "$d/systemctl"
  return 0
}
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
# ⛔ AND A REFUSED INSTALL MUST MUTATE NOTHING ON *THIS* REFUSAL TOO. Every refusal leg above passes
# CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 — which switches OFF the duplicate-actuator refusal, the DEFAULT
# case on this fleet (both timers enabled). So the suite was blind to `place_pass` sitting ABOVE it: an
# `--install` that exits 1 because a second actor is enabled had already replaced
# $CELL_HOME/.pi/agent/scripts/cell-self-pin.sh — deployed code no verification ever saw, the class this
# change exists to remove, reached on the refusal path. No flag here, so this refusal actually runs.
mk_scoped_systemctl "$T/fake-1sys-dup" "$T/state-1sys-dup"; : >"$T/state-1sys-dup/system-$SHIPPED"
printf '#!/bin/bash\n# the copy a PREVIOUS install placed — a refusal must not replace these bytes\n' >"$T/dup.before"
cp "$T/dup.before" "$PLACED"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-dup" PATH="$T/fake-1sys-dup:$PATH" \
       bash "$PIN" --install 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a duplicate actuator refuses the install on the DEFAULT path (no override flag)" \
  || bad "installed beside an enabled eldato-harness-apply.timer with no override (rc=$rc): $out"
if cmp -s "$T/dup.before" "$PLACED"; then ok "…and that REFUSAL did not replace the already-placed pass (a refused install mutates nothing)"
else bad "a REFUSED install (duplicate actuator) REPLACED the placed pass before refusing — the installation mutated the box and then said no"; cp "$T/dup.before" "$PLACED"; fi
[ -f "$T/units-dup/cell-self-pin.service" ] && bad "a refused install (duplicate actuator) still wrote the unit" \
  || ok "…and it wrote no unit"
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
# ── (b2) A MANAGER THAT DOES NOT ANSWER IS NOT A MANAGER WITH NO ACTUATOR ────────────────────────
# ⛔ MEASURED ON THIS BOX, IN THE ENVIRONMENT A SYSTEM UNIT ACTUALLY HAS: `systemctl --user is-enabled`
# answers "Failed to connect to bus: No medium found" and exits 1 — INDISTINGUISHABLE, by exit code, from
# "disabled" — while `--install` went on to print "read back in both managers": a positive claim about a
# manager that said nothing. A box whose shipped timer lives ONLY in the user manager (the documented
# no-sudo fallback) would be reported as having ONE actuator while carrying TWO. The fake below makes the
# system manager answer and the user manager NOT ANSWER, which no exit-code-only probe can tell apart.
mk_blind_user_systemctl() { # <dir> <state-dir> — SYSTEM answers; the USER manager has NO BUS
  local d="$1" s="$2"
  mkdir -p "$d" "$s"
  printf '%s\n' \
    '#!/bin/bash' \
    "S='$s'" \
    'if [ "${1:-}" = "--user" ]; then echo "Failed to connect to bus: No medium found" >&2; exit 1; fi' \
    'verb="${1:-}"; shift 2>/dev/null || true' \
    '[ "${1:-}" = "--now" ] && shift' \
    'unit="${1:-}"' \
    'st="$S/system-$unit"' \
    'case "$verb" in' \
    '  is-enabled) if [ -f "$st" ]; then echo enabled; exit 0; fi; echo disabled; exit 1 ;;' \
    '  enable) : >"$st"; exit 0 ;;' \
    '  disable) rm -f "$st"; exit 0 ;;' \
    'esac' \
    'exit 0' >"$d/systemctl"
  chmod +x "$d/systemctl"
}
mk_blind_user_systemctl "$T/fake-blind" "$T/state-blind"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-blind" PATH="$T/fake-blind:$PATH" \
       bash "$PIN" --install 2>&1)"; rc=$?
# ⛔ rc=0 IS CORRECT HERE AND THE DISTINCTION IS DELIBERATE: the units WERE installed and enabled, so a
# non-zero exit would be a false RED on a box that is fine. What must change is the CLAIM — and the
# `--takeover` path, where an unreadable scope really is dangerous, is the one that refuses (leg b3).
[ "$rc" -eq 0 ] && ok "an UNANSWERABLE user manager does not turn a completed install into a false failure" \
  || bad "an unreachable user manager made a completed install exit $rc: $out"
case "$out" in
  *'read back in both managers'*) bad "claimed 'read back in both managers' while the user manager did NOT answer — the exact false claim this leg exists for: $out" ;;
  *'user manager did NOT ANSWER'*) ok "…and the claim names the scope it could NOT read, instead of claiming both" ;;
  *) bad "…but does not name the unverified scope: $out" ;;
esac
# ── (b3) `--takeover` WILL NOT RETIRE BLIND ────────────────────────────────────────────────────
# Retirement DISABLES the shipped actuator, so a scope that cannot be read is a scope whose state this run
# does not know: retiring blind can leave TWO actors (the race this guard exists for) or ZERO (no pin at
# all — #3194's own state). It must refuse, and refuse BEFORE writing.
: >"$T/state-blind/system-$SHIPPED"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-blind2" PATH="$T/fake-blind:$PATH" \
       bash "$PIN" --install --takeover 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "--takeover REFUSES when the user manager does not answer (a blind retirement can leave two actors or none)" \
  || bad "--takeover retired blind with an unreadable user scope (rc=$rc): $out"
case "$out" in
  *'cannot retire safely'*) ok "…and says why, naming the scope it could not read" ;;
  *) bad "…but does not explain the blind-retirement refusal: $out" ;;
esac
[ -f "$T/units-blind2/cell-self-pin.service" ] && bad "a refused blind --takeover still wrote the unit" \
  || ok "a refused blind --takeover wrote nothing"
# ── (b3-bis) …AND IT REFUSES WHEN THE BLIND SCOPE IS THE *ONLY* PLACE THE ACTUATOR LIVES ─────────
# ⛔ THE ARM ABOVE PASSES ONLY BECAUSE THE SYSTEM SCOPE ALREADY ANSWERED "ENABLED", i.e. because the run had
# ALREADY SEEN an actuator — so it could not catch the shape below, which is the one the documented no-sudo
# box produces. The refusal was gated on `[ -n "$scopes" ]`, the OPPOSITE of the condition it names: on a box
# whose shipped timer lives only in `systemctl --user` (unreachable from a system unit) the guard was skipped,
# the timer installed and enabled itself, exit was 0, and the run printed "nothing to retire" — a positive
# claim about a manager that said nothing, on top of TWO mutating actors.
rm -f "$T/state-blind/system-$SHIPPED"      # the system manager answers and carries NOTHING
: >"$T/state-blind/user-$SHIPPED"           # the shipped timer is enabled ONLY in the manager that cannot answer
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-blind3" PATH="$T/fake-blind:$PATH" \
       bash "$PIN" --install --takeover 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "--takeover REFUSES when the ONLY shipped actuator lives in the manager that did not answer (rc=$rc)" \
  || bad "--takeover installed and enabled a SECOND actuator while the only shipped one sat in an unreadable manager (rc=$rc): $out"
case "$out" in
  *'cannot retire safely'*'user'*) ok "…and it names the manager it could not read, instead of claiming 'nothing to retire'" ;;
  *'nothing to retire'*) bad "…but it claimed 'nothing to retire' about a manager that never answered: $out" ;;
  *) bad "…but the blindness is not named: $out" ;;
esac
case "$out" in
  *'CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1'*) ok "…and it names the deliberate-decision hatch, so a box where that manager can never be reached is not a dead end" ;;
  *) bad "…but the refusal offers no route out for a box whose user manager can NEVER answer (a root install has no user manager of its own): $out" ;;
esac
[ -f "$T/units-blind3/cell-self-pin.service" ] && bad "a refused blind --takeover (user-only actuator) still wrote the unit" \
  || ok "a refused blind --takeover (user-only actuator) wrote nothing"
# ── (b3-ter) …AND THE REFUSAL MAY NOT BE A DEAD END — both verbs pointed at each other ───────────
# ⛔ THE FLEET SHAPE, measured on this box in the identity that actually installs (root writes
# /etc/systemd/system and needs daemon-reload): `systemctl --user` answers "Failed to connect to bus: No
# medium found" because root has no user manager of its own (`/run/user` empty). So EVERY `--user` probe is
# `unknown`, and the unconditional refusal closed `--takeover` on exactly the cells it exists for — while
# `--install` refuses too (the duplicate arm sends the operator to `--takeover`). The two remedies pointed at
# each other and the documented ONE-actuator migration could not be executed at all. The existing
# deliberate-decision hatch is therefore honoured HERE, and the read-back must say what was MEASURED rather
# than assert a count it could not take.
mk_blind_user_systemctl "$T/fake-blind-hatch" "$T/state-blind-hatch"
: >"$T/state-blind-hatch/system-$SHIPPED"          # the readable scope DOES carry the shipped actuator
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-hatch" PATH="$T/fake-blind-hatch:$PATH" \
       CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 bash "$PIN" --install --takeover 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "--takeover with CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 completes on a box whose user manager can NEVER be reached from the installing identity" \
  || bad "the documented migration could not be completed anywhere: --install sends the operator to --takeover, and --takeover refuses on a manager that is structurally unreachable (rc=$rc): $out"
[ -f "$T/state-blind-hatch/system-$SHIPPED" ] \
  && bad "the readable scope's shipped timer survived the accepted-blind migration — the retirement covered nothing" \
  || ok "…and it retired the scope it could READ"
case "$out" in
  *'NOT fully verified'*'user'*) ok "…and the read-back names the unread scope and says the invariant was NOT fully verified, instead of asserting a count" ;;
  *'TWO actuators on this pin, as'*) bad "…but it asserted TWO actuators when it never read that scope: $out" ;;
  *) bad "…but the read-back does not name the unread scope: $out" ;;
esac
# ⛔ AND THE MIGRATION NOTE NAMES THE SCOPE THAT WILL ACTUALLY BE RETIRED, NOT THE ONE THAT DID NOT ANSWER
# (round-14 review, P2). `$who` is reassigned to the UNREADABLE scopes inside the `--takeover` arm, and the
# note below it reused `$who` — so on this exact shape (the documented no-sudo migration: readable system
# scope carries the shipped timer, `--user` is structurally unreachable, hatch set) it printed
# "retiring the duplicate actuator in the user manager(s) LAST" and then retired the SYSTEM one. The
# operator's only read of the migration named the wrong manager. MEASURED pre-fix on this fixture:
# `… (retiring the duplicate actuator in the user manager(s) LAST, after the units are placed)`.
case "$out" in
  *'retiring the duplicate actuator in the system manager(s)'*) ok "…and the migration note names the scope it will ACTUALLY retire (system), not the scope that did not answer" ;;
  *) bad "…but the migration note does not name the scope being retired (system) — it must not reuse the unreadable-scope name: $out" ;;
esac
: >"$T/state-blind/user-$SHIPPED"
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
# ⛔ AND A READ-BACK THAT CANNOT ANSWER IS NOT A RETIREMENT (round-12 review, P2). `actuator_enabled_in` is
# `systemctl is-enabled … >/dev/null 2>&1`, whose exit code is 1 BOTH for "disabled" and for "cannot reach the
# bus" — so a manager that goes away after the disable read as RETIRED, in the one place whose comment claims
# "VERIFIED, NOT ASSUMED". This is not exotic: `Failed to connect to bus: No medium found` is this box's real
# answer from the identity a system unit runs as.
mk_vanish_systemctl "$T/fake-vanish" "$T/state-vanish"
: >"$T/state-vanish/system-$SHIPPED"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-vanish" PATH="$T/fake-vanish:$PATH" \
       bash "$PIN" --install --takeover 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a manager that DISAPPEARS after the disable is a REFUSAL — an unanswerable read-back is not a retirement" \
  || bad "an unverifiable read-back was read as RETIRED (rc=$rc): $out"
case "$out" in
  *'UNVERIFIED'*) ok "…and it says the retirement is UNVERIFIED, instead of claiming the actuator is gone" ;;
  *) bad "…but the refusal does not distinguish an unanswerable read-back from a retirement: $out" ;;
esac
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

# ── (f0) THE READ-BACK AT THE POINT OF THE CLAIM, NOT ONLY AT THE INPUT ──────────────────────────
# ⛔ `verify_timer` refuses a rendered unit with no installation config, but a template is not the only way
# to reach a unit the manager never links (a manager that ignores the unit dir, a `--root` mismatch, a
# future `[Install]` spelling). So the enablement is READ BACK from the manager's own answer where the
# positive claim is printed, instead of being inferred from `enable`'s exit code. `mk_nolink_systemctl`
# models systemd's MEASURED behaviour for such a unit: `enable` exits 0, links nothing, and `is-enabled`
# then answers `static` with **rc=0** — the word that made an exit-code read-back say "enabled" about a
# clock that never fires. It answers `disabled` for any OTHER unit, so the duplicate-actuator gate cannot
# answer for this leg.
mk_nolink_systemctl "$T/fake-nolink" "$T/state-nolink"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-nolink" PATH="$T/fake-nolink:$PATH" \
       bash "$PIN" --install 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "an 'enable' that exits 0 and links NOTHING fails the install instead of being certified (rc=$rc)" \
  || bad "installed (rc=0) after an 'enable' that created no link — the positive claim printed over a dead pin: $out"
case "$out" in
  *'ONE actuator on this pin'*) bad "…and it still printed the ONE-actuator claim over a timer the manager never enabled" ;;
  *) ok "…and it does NOT print the one-actuator claim over it" ;;
esac
case "$out" in
  *'NOT enabled'*) ok "…and the refusal says what it READ (the unit reads as not enabled)" ;;
  *) bad "…but the refusal does not say the unit reads as not enabled: $out" ;;
esac
# ⛔ AND THE ONE rc=0 ANSWER THAT MEANS **NOT ENABLED** IS NOT ACCEPTED (round-17 review, P3). `indirect` is
# systemd's word for "the unit file itself is not enabled" (`systemd.unit(5)`) — the manager answering it is
# telling us this unit has no link of its own. Mapping it to `enabled` would make the read-back green over
# the state it exists to catch, and no other leg can see that: every passing gate produces a real link.
mk_indirect_systemctl "$T/fake-indirect" "$T/state-indirect"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-indirect" PATH="$T/fake-indirect:$PATH" \
       bash "$PIN" --install 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "an 'indirect' answer (rc=0, but the unit itself is NOT enabled) fails the install (rc=$rc)" \
  || bad "installed (rc=0) on an 'indirect' answer, which means the unit itself has no link: $out"
case "$out" in
  *'ONE actuator on this pin'*) bad "…and it printed the ONE-actuator claim over a unit the manager says is not enabled" ;;
  *) ok "…and it does NOT print the one-actuator claim over it" ;;
esac

# ── (f) A SCOPE THAT GOES ENABLED *DURING* THE INSTALL IS STILL CAUGHT ─────────────────────────────
# ⛔ THE POST-MIGRATION READ-BACK IS THE SOLE DECIDER OF THE ONE-ACTOR CLAIM, and deleting it left this
# suite at 421 ok / 0 failed (round-16 review, P1). `retire_actuator`'s per-scope read-back can only see
# scopes that were ALREADY enabled when `actuator_scopes` ran BEFORE the install, so a scope re-armed
# DURING it — the documented `cloud-cell-bringup.sh` `check_harness_apply` re-arm, on every bring-up — is
# in neither `$scopes` nor the retirement loop. Without the read-back, `--install` prints "installed — ONE
# actuator on this pin" and exits 0 over a pin with TWO mutating actors: a race, silently greened.
mk_rearm_systemctl "$T/fake-rearm" "$T/state-rearm"
out="$(runat "$T/home" TEMPLATES_DIR="$TPL" SYSTEMD_UNIT_DIR="$T/units-rearm" PATH="$T/fake-rearm:$PATH" \
       bash "$PIN" --install 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "an actuator RE-ARMED in a scope the install never saw enabled fails the install (rc=$rc)" \
  || bad "installed (rc=0) while a shipped actuator was re-armed DURING the install: $out"
case "$out" in
  *'still reads ENABLED'*) ok "…and the refusal names the scope that still carries it" ;;
  *) bad "…but it did not report the still-enabled actuator: $out" ;;
esac
case "$out" in
  *'ONE actuator on this pin'*) bad "…and it printed the ONE-actuator claim over two actors" ;;
  *) ok "…and it does NOT print the one-actuator claim over it" ;;
esac

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
# ⛔ AND THE OPERATOR'S FIRST SCREEN MAY NOT CALL AN UNREAD SCOPE "NONE" (round-8 review, P2). `do_status`
# was the ONE caller of `actuator_scopes` that never consulted `actuator_unknown_scopes`, so the verb whose
# documented job is "what it resolved, where it came from, the LAST OUTCOME" printed `second actuator <none>`
# for a manager that said nothing — the tick was honest about the same reading, the headline was not.
mk_blind_user_systemctl "$T/fake-blind-status" "$T/state-blind-status"
: >"$T/state-blind-status/user-$SHIPPED"
out="$(runat "$TICK" PATH="$T/fake-blind-status:$PATH" bash "$PIN" --status-nofetch 2>&1)"
case "$out" in
  *'second actuator <none>'*) bad "--status printed 'second actuator <none>' while the user manager did NOT answer: $out" ;;
  *'second actuator <UNVERIFIED'*'user'*) ok "--status says UNVERIFIED (naming the scope) when a manager did not answer, instead of 'none'" ;;
  *) bad "--status did not report the unread scope: $out" ;;
esac
# ⛔ AND "DID NOT ANSWER" IS NOT A FIXED LIST OF MESSAGES (round-11 review, P1). `scope_state` ended
# `[ rc -eq 0 ] && enabled || disabled` — a DENY-LIST: any failure spelling not in BUS_UNREACHABLE_PAT fell
# through to `disabled`, so a manager that said NOTHING was published as "no actuator". systemd's real
# system-scope wording is exactly such a spelling: `Failed to connect to system scope bus via local
# transport: No such file or directory` — the words `system scope bus via local transport` sit between
# `connect to` and `bus`, so `Failed to connect to bus` does not match it. MEASURED before the fix:
# `--status` printed `second actuator <none>` over an UNREAD scope, the precise false PASS the block above
# exists to refuse, one failure spelling further out. Polarity is the fix: `disabled` is a CLAIM, so only
# the manager's own answer words may produce it and everything unrecognised is UNKNOWN.
mkdir -p "$T/fake-unreadable"
printf '%s\n' '#!/bin/bash' 'case "$*" in' \
  '  *is-enabled*) echo "Failed to connect to system scope bus via local transport: No such file or directory" >&2; exit 1 ;;' \
  'esac' 'exit 0' >"$T/fake-unreadable/systemctl"
chmod +x "$T/fake-unreadable/systemctl"
out="$(runat "$TICK" PATH="$T/fake-unreadable:$PATH" bash "$PIN" --status-nofetch 2>&1)"
case "$out" in
  *'second actuator <none>'*) bad "--status published 'no actuator' from a manager answer it could not CLASSIFY: $out" ;;
  *'second actuator <UNVERIFIED'*) ok "--status refuses to call an UNCLASSIFIABLE manager answer 'none' (it says UNVERIFIED)" ;;
  *) bad "--status did not report the unclassifiable scope: $out" ;;
esac
# ⛔ AND THE TICK'S OWN NOTE IS GATED — it is the message the UNATTENDED path prints, and it was the one
# copy of the claim nothing read (the install read-back and `--status` versions are both gated). Deleting
# the tick's `log "note: … UNVERIFIED there, not satisfied"` left the suite at 280 ok / 0 failed (measured
# in review), so a tick that could not check a manager said nothing about it.
mk_blind_user_systemctl "$T/fake-blind-tick" "$T/state-blind-tick"
: >"$T/state-blind-tick/system-$SHIPPED"
: >"$T/state-blind-tick/system-cell-self-pin.timer"
out_tick="$(runat "$TICK" PATH="$T/fake-blind-tick:$PATH" bash "$PIN" 2>&1)"
case "$out_tick" in
  *'one-actor invariant is UNVERIFIED'*) ok "the TICK itself says the invariant is UNVERIFIED when a manager did not answer (not only install/--status)" ;;
  *) bad "the tick stayed silent about a manager it could not read, so an unattended box cannot be told its invariant is unverified: $out_tick" ;;
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
# ⛔ AND THE RETIREMENT MUST BE ABLE TO TAKE FROM THE IDENTITY THAT RUNS THIS PASS (round-12 review, P1).
# The rendered unit runs as the OWNER of $CELL_HOME (non-root — measured render: `User=cmux`) and bring-up
# re-arms the shipped timer in the SYSTEM manager as root, so a bare `systemctl disable --now` is polkit's
# `Access denied` — MEASURED as this identity: `Failed to disable unit: Access denied`, before any unit
# lookup. The re-take then RED'd every ten minutes and never reached the apply, i.e. the pin stopped
# advancing (#3194's outcome, reached by following this change's own migration). `systemctl_system`
# negotiates the privilege the sibling installer already requires (its `[ -z "${SUDO+x}" ] && sudo -n true` probe),
# and these legs pin both halves: the escalation is TAKEN, and a manager that refuses is still a named RED.
mk_scoped_systemctl "$T/fake-esc" "$T/state-esc"
: >"$T/state-esc/system-cell-self-pin.timer"
: >"$T/state-esc/system-$SHIPPED"
mkdir -p "$T/fakebin-sudo"
printf '%s\n' '#!/bin/bash' \
  '[ "${1:-}" = "-n" ] && shift' \
  "printf '%s\\n' \"\$*\" >>'$T/sudo.calls.log'" \
  'exec "$@"' >"$T/fakebin-sudo/sudo"
chmod +x "$T/fakebin-sudo/sudo"
: >"$T/sudo.calls.log"
# `CELL_SELF_PIN_SYSTEMCTL=` (EMPTY) is the documented way to ask for the AUTO probe; it resolves to
# `sudo -n systemctl` only because the fake `sudo` answers `sudo -n true`, which is exactly the sibling's test.
out="$(runat "$TICK" CELL_SELF_PIN_SYSTEMCTL= PATH="$T/fakebin-sudo:$T/fake-esc:$PATH" bash "$PIN" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a re-armed SYSTEM actuator is retired by a NON-ROOT tick (the privilege is negotiated)" \
  || bad "a non-root tick could not retire the re-armed SYSTEM actuator (rc=$rc): $out"
# ⛔ NO BACKTICKS IN THESE MESSAGES (round-21 review, P3). A backticked span inside a DOUBLE-QUOTED string is
# COMMAND SUBSTITUTION, not literal text — so the citation this line exists to carry was executed and the
# prose printed with a hole in it (measured in the suite's own log: "…install-harness-apply-timer.sh's  relies
# on", double space). Worse, the command it ran was the host's real `sudo -n true`: `SUDO` is unset in the
# suite, and the per-leg `PATH="$T/fakebin-sudo:…"` override belongs to the preceding `runat`, not to this
# `ok` line. A suite that must never reach the host's manager must not be able to reach the host's `sudo`
# either. Same root at `:1255`/`:1257` (`User=` and `id -un` were being executed and dropped) — fixed there
# too, so the text is literal and the only escalation path is the shimmed one.
[ -s "$T/sudo.calls.log" ] && ok "…and it escalated through 'sudo -n' — the same probe install-harness-apply-timer.sh's [ -z \"\${SUDO+x}\" ] && sudo -n true relies on" \
  || bad "…but the retirement used NO escalation, so on a real box it is polkit's Access denied: $out"
[ -f "$T/state-esc/system-$SHIPPED" ] && bad "…and the shipped timer is STILL enabled after the tick claimed to re-take the pin" \
  || ok "…and the shipped SYSTEM timer is really disabled, not merely claimed"
case "$(cat "$T/sudo.calls.log" 2>/dev/null)" in
  *'is-enabled'*) bad "a READ was escalated — 'is-enabled' needs no privilege, and escalating it would make the guard's verdicts depend on sudo" ;;
  *) ok "…and no READ was escalated (only the mutation needs root)" ;;
esac
# The refusal half: a manager that WILL NOT disable. Nothing may print "re-took the pin" for it, and the
# remedy must name the privilege rather than telling the operator to run the same command again.
mk_denied_systemctl "$T/fake-denied" "$T/state-denied"
: >"$T/state-denied/system-cell-self-pin.timer"
: >"$T/state-denied/system-$SHIPPED"
out="$(runat "$TICK" PATH="$T/fake-denied:$PATH" bash "$PIN" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a manager that REFUSES the disable is a RED, not a silent second actor (polkit's Access denied, on a non-root unit)" \
  || bad "a tick whose retirement was REFUSED still exited 0 (rc=$rc): $out"
case "$out" in
  *'re-took the pin'*) bad "…but it CLAIMED to have re-taken the pin over a disable that failed: $out" ;;
  *'passwordless sudo'*) ok "…and the remedy names the privilege ('passwordless sudo'), so the operator is not sent to the same command again" ;;
  *) bad "…but the refusal does not name what would make it work: $out" ;;
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

# ── 4d. THE RE-TAKE MAY NOT COST THE BOX ITS LAST ACTUATOR ──────────────────────────────────────
# ⛔ THE OTHER HALF OF THE INVARIANT, AND IT WAS THE HALF NOTHING READ (round-3 review, P1).
# `retire_actuator` runs `systemctl disable --now eldato-harness-apply.timer`, and the call used to sit
# ABOVE `resolve_layer`, `supervisor_in`, the `cd`, the fetch and the tip resolution — every one of which
# can exit non-zero. `do_install` REFUSES to end at zero actuators (it writes the units first, retires
# last, and rolls back); the tick had no equivalent. Measured end state of the shipped order: the shipped
# timer DISABLED and STOPPED, this unit ENABLED and failing every ten minutes, nothing advancing the
# layer — which is #3194's own state, reached by following this change's own documented migration.
# Leg (1): a tick that cannot even RESOLVE a layer must not touch the shipped timer at all.
mk_scoped_systemctl "$T/fake-nolayer" "$T/state-nolayer"
: >"$T/state-nolayer/system-cell-self-pin.timer"      # this unit IS the installed actuator
: >"$T/state-nolayer/system-$SHIPPED"                 # …and bringup re-armed the shipped one
mkdir -p "$T/home-nolayer"                            # a home with NO record and NO pin root
: >"$T/state-nolayer/calls.log"
out="$(runat "$T/home-nolayer" PATH="$T/fake-nolayer:$PATH" bash "$PIN" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "a tick on a home with NO resolvable layer still exits 2 (UNRESOLVED)" \
  || bad "a tick with no layer exited $rc instead of 2: $out"
[ -f "$T/state-nolayer/system-$SHIPPED" ] \
  && ok "…and it did NOT retire the shipped actuator — the retirement is taken only once the pass has established it can ACT" \
  || bad "a tick that could not resolve a layer RETIRED eldato-harness-apply.timer and then failed: zero pin actuators, reached by a read-only failure"
# ⛔ AND THE ASSERTION IS ON THE ACTION, NOT ON A LOG LINE. The file check above cannot see the ORDER, and a
# rollback alone would satisfy it (the tick could disable and then re-enable on every read-only failure,
# stopping and re-arming the shipped timer every ten minutes). `mk_scoped_systemctl` records every verb it
# is asked for, so "the retirement was never TAKEN" is a fact about the fake's own log.
# ⛔ AND THE PATTERN IS ERE, NOT BRE WITH `\|` (round-14 review, P2). `grep -q "^disable X$\|^disable --now X$"`
# relies on GNU reading `$` as an anchor before `\|`; BSD/macOS grep has no `\|` alternation and reads the
# whole thing as a literal, so it matches NOTHING. The two halves then had opposite consequences: the
# POSITIVE leg below (leg 2) red'd on macOS ("the failing tick never issued a disable", while the calls log
# contained `disable eldato-harness-apply.timer`), and this NEGATIVE leg passed VACUOUSLY — an assertion that
# cannot red is not a gate. Linux-only CI stayed green, so neither surfaced. `mk_scoped_systemctl` logs
# `"$verb $unit"` with `--now` already shifted away, so the optional group covers both spellings.
if grep -qE "^disable( --now)? $SHIPPED$" "$T/state-nolayer/calls.log" 2>/dev/null; then
  bad "a tick that could not even resolve a LAYER still issued 'disable' on eldato-harness-apply.timer (calls log: $(tr '\n' ';' <"$T/state-nolayer/calls.log")) — a read-only failure must not touch the box's pin actuator at all, let alone stop and re-arm it"
else
  ok "…and it never even ISSUED a disable (the calls log has no retirement for it), so a read-only failure cannot stop and re-arm the box's actuator"
fi
# Leg (2): a tick that DOES retire and then FAILS AT APPLY must put the actuator back.
# ⛔ THE RECORD MUST **NOT CONTAIN** THE TIP — that is the shape that reaches the mutation. Under the
# equality-era decision a commit ON TOP of the tip read as DRIFT and got here; now that the tick decides by
# CONTAINMENT (the same predicate `--status` and the post-apply rule use — one state, one answer), a record
# that contains the tip is correctly a no-op. And this fixture runs BEFORE origin's second commit, so its
# clone sits AT the tip and there is nothing behind to check out: the record is put on an UNRELATED
# history instead (a real shape — a pin record naming a tree that is not on the ref's line), while
# `origin/main` still resolves there so `check_pin_resolution` is not what refuses the tick.
FAILPIN="$T/tick-applyfail"
mkdir -p "$FAILPIN/harness" "$FAILPIN/orchestrator"
git clone -q "$T/origin.git" "$FAILPIN/harness/tree" 2>/dev/null
mkdir -p "$FAILPIN/harness/tree/scripts"
printf '#!/bin/bash\nexit 1\n' >"$FAILPIN/harness/tree/scripts/cloud-cell-supervisor.sh"
chmod +x "$FAILPIN/harness/tree/scripts/cloud-cell-supervisor.sh"
git -C "$FAILPIN/harness/tree" checkout -q --orphan off-the-line 2>/dev/null \
  && git -C "$FAILPIN/harness/tree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "a record OFF the ref's line" \
  || bad "could not place the apply-failure fixture's record OFF the ref's line, so the mutation is never reached"
printf '%s\n' "$FAILPIN/harness/tree" >"$FAILPIN/.harness-path"
mk_scoped_systemctl "$T/fake-applyfail" "$T/state-applyfail"
: >"$T/state-applyfail/system-cell-self-pin.timer"
: >"$T/state-applyfail/system-$SHIPPED"
: >"$T/state-applyfail/calls.log"
out="$(runat "$FAILPIN" PATH="$T/fake-applyfail:$PATH" bash "$PIN" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "a tick whose apply FAILS after retiring the re-armed actuator is a RED" \
  || bad "a tick whose apply failed exited 0 (rc=$rc): $out"
[ -f "$T/state-applyfail/system-$SHIPPED" ] \
  && ok "…and the retired actuator is put BACK, so a failed tick never leaves the box with ZERO pin actuators" \
  || bad "a tick that retired eldato-harness-apply.timer and then failed at apply left it DISABLED and this unit RED — zero pin actuators, i.e. #3194's own state"
# …and it is a ROLLBACK that undoes a retirement that really happened, not a leg passing because the tick
# never retired in the first place: both verbs are in the fake's own call log.
if grep -qE "^disable( --now)? $SHIPPED$" "$T/state-applyfail/calls.log" 2>/dev/null; then
  ok "…after ACTUALLY retiring it first (the calls log has the disable), so the rollback is exercised, not assumed"
else
  bad "the failing tick never issued a disable, so the rollback leg above proved nothing (calls log: $(tr '\n' ';' <"$T/state-applyfail/calls.log"))"
fi
case "$out" in
  *'ROLLED BACK'*) ok "…and it says ROLLED BACK on stderr, so journald carries the reason instead of silence" ;;
  *) bad "…but nothing says the retirement was rolled back: $out" ;;
esac

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

# ── 5b. A SYMLINKED CELL_HOME IS THE SAME HOME, NOT A CONTAINMENT BREACH ───────────────────────────
# ⛔ THE CONTAINMENT RULE'S TWO SIDES MUST BE RESOLVED-OR-LEXICAL *TOGETHER* (round-14 review, P2).
# `home_real` was always `cd "$CELL_HOME" && pwd -P` (RESOLVED) while `exec_real` stayed the RAW
# `$CELL_HOME/…` string whenever the payload's parent did not resolve — which is EVERY FIRST INSTALL,
# because `place_pass` runs AFTER `verify_unit`, so `$CELL_HOME/.pi/agent/scripts` does not exist yet.
# On any box whose `$CELL_HOME` is reached through a symlink — an operator-set `CELL_HOME=/tmp/cell-home`
# → `/private/tmp/cell-home` on macOS is the measured example (the legacy home is not a DEFAULT anywhere
# since agent-infra#3453, but it can still be SET) — the two strings could never match
# and the FIRST install was refused with a cause naming the containment rule, on a payload that was
# inside the home. The second attempt passed only because the first had created the parent in between,
# i.e. the operator's remedy was "run it twice". MEASURED here: rc=1, "ExecStart resolves to
# '…/symhome/.pi/agent/scripts/cell-self-pin.sh', which is NOT under CELL_HOME ('…/realhome')".
# The leg is DISCRIMINATING rather than cosmetic: `symhome` → `realhome` makes the resolved and the
# lexical spellings differ, which on a host whose `/tmp` is not itself a symlink is the only way to
# exercise the asymmetry at all.
mkdir -p "$T/realhome"
ln -s "$T/realhome" "$T/symhome"
[ ! -d "$T/realhome/.pi/agent/scripts" ] \
  || bad "the symlink leg's home already carries .pi/agent/scripts, so it cannot exercise the FIRST install (the shape the fix is about)"
runat "$T/symhome" TEMPLATES_DIR="$TPL" CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR=1 SYSTEMD_UNIT_DIR="$T/units-sym" \
  PATH="$T/fakebin:$PATH" bash "$PIN" --install >"$T/install-sym.log" 2>&1; sym_rc=$?
[ "$sym_rc" -eq 0 ] \
  && ok "the FIRST --install on a SYMLINKED CELL_HOME is accepted — the home and the payload are compared in the SAME spelling, so a not-yet-created payload parent cannot refuse a payload that is inside the home" \
  || bad "the first --install on a symlinked CELL_HOME was refused (rc=$sym_rc), so an operator on a box whose CELL_HOME is reached through a symlink has to run it twice: $(cat "$T/install-sym.log")"

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
  # ⛔ AND THE GREEN VERDICT NAMES WHAT IT DID NOT CHECK (review finding). The template claims a current pin
  # beside a stale RUNNING controller is a real state and that "the pass says so in its log line rather than
  # greening it away" — but only the APPLIED branch said so. This is the state #3194 lived in for a day
  # ("the record said current while the pid executed a 17-commits-behind tree"), re-asserted on the one
  # surface an operator reads all day, so the caveat is pinned here.
  case "$out" in
    *'RUNNING controller'*) ok "…and the 'current' verdict says a RUNNING controller keeps the layer it STARTED on — the record is not claimed to be the executed tree" ;;
    *) bad "the 'current' verdict does not say the executed layer may differ from the record — the exact overclaim #3194 punished: $out" ;;
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
# ── 6b. THE REF THAT IS FETCHED IS THE REF THE DECISION USES ─────────────────────────────────
# ⛔ `HARNESS_REF` IS A DOCUMENTED KNOB (the file header prints it, and the layer/ref/verb all come from
# one tree), and BOTH verbs fetched `origin main` while deciding on `$HARNESS_REF`. So for any other value
# the pass refreshed ONE ref and compared ANOTHER — and `--status` printed "`origin/rel` fetched just now"
# about a ref it never touched, i.e. the fetch-blindness the surrounding comments say they fixed, one
# variable over. The layer here has NO local `origin/rel` (it was cloned before the branch existed), so the
# pre-fix code cannot resolve it at all and the leg discriminates on the resolved SHA, not on wording.
git -C "$T/seed" checkout -q -B rel main
git -C "$T/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "a ref the default fetch never refreshes"
if git -C "$T/seed" push -q origin rel 2>/dev/null; then
  REL="$(git -C "$T/origin.git" rev-parse rel 2>/dev/null)"
  printf '%s\n' "$T/home/harness/pintree" >"$T/home/.harness-path"
  out="$(runat "$T/home" HARNESS_REF=origin/rel bash "$PIN" --status 2>&1)"; rc=$?
  case "$out" in
    *"origin/rel $REL"*) ok "--status FETCHES the configured HARNESS_REF, not a hard-coded origin main (the resolved SHA is the one the remote has)" ;;
    *) bad "--status did not resolve the configured HARNESS_REF 'origin/rel' at ${REL:-<unreadable>} — the fetch target and the decision ref are not the same ref: $out" ;;
  esac
  [ "$rc" -eq 1 ] && ok "…and decides on it (DRIFT against the record, exit 1), rather than on main" \
    || bad "--status decided on a ref other than HARNESS_REF (rc=$rc, expected 1=DRIFT): $out"
  out="$(runat "$T/home" HARNESS_REF=origin/rel bash "$PIN" 2>&1)"; rc=$?
  case "$out" in
    *"target=$REL"*) ok "…and the PASS refreshes and compares the configured ref too (same fetch, same decision)" ;;
    *) bad "the pass did not act on the configured HARNESS_REF (expected target=$REL): $out" ;;
  esac
  [ "$rc" -ne 0 ] && ok "…so a stale record against that ref is a non-zero tick, not a green no-op" \
    || bad "the pass reported success while its record does not contain the configured ref's tip (rc=$rc): $out"
  git -C "$T/seed" checkout -q main
else bad "could not push the 'rel' branch — the HARNESS_REF leg was not exercised"; fi
# ── 6c. THE DECISION IS ON THE COMMIT THE FETCH BROUGHT, AND ON A COMMIT AT ALL ────────────────
# ⛔ A REF'S SPELLING IS NOT A REVISION. `git fetch origin main` moves `refs/remotes/origin/main`, while
# `git rev-parse main` (or `refs/heads/main`) reads the LOCAL branch the fetch never touched — so the knob this
# file documents and prints could yield `current` + exit 0 against a newer remote tip, which is #3194's own
# symptom reached through the knob. And `git rev-parse <unknown>` PRINTS ITS ARGUMENT and exits 128, so an
# unguarded read puts the ref's NAME in the commit column and answers DRIFT for a ref the PASS calls
# unreadable; a local annotated tag resolves to its TAG OBJECT, which never equals a commit. The record here
# is the pintree's C1 while `origin/main` is C2 and `attip` is an annotated tag ON C1, so every leg below
# distinguishes the three readings by VALUE.
printf '%s\n' "$T/home/harness/pintree" >"$T/home/.harness-path"
FIRSTC="$(git -C "$T/origin.git" rev-list --max-parents=0 main 2>/dev/null | tail -1)"
git -C "$T/seed" -c user.email=t@t -c user.name=t -c tag.gpgSign=false tag -f -a attip -m "an annotated tag on the record's commit" "$FIRSTC" >/dev/null 2>&1
if git -C "$T/seed" push -q origin refs/tags/attip 2>/dev/null; then
  out="$(runat "$T/home" HARNESS_REF=refs/heads/main bash "$PIN" --status 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && ok "HARNESS_REF=refs/heads/main is NOT decided on the STALE local branch (DRIFT, exit 1)" \
    || bad "HARNESS_REF=refs/heads/main answered rc=$rc: the decision read the local branch the fetch never moved, i.e. a green tile over an unmoved layer: $out"
  out="$(runat "$T/home" HARNESS_REF=main bash "$PIN" --status 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && ok "…and neither is the BARE branch spelling ('main')" \
    || bad "HARNESS_REF=main answered rc=$rc instead of DRIFT: $out"
  out="$(runat "$T/home" HARNESS_REF=attip bash "$PIN" --status 2>&1)"; rc=$?
  case "$out" in
    *"attip $FIRSTC"*) ok "…an ANNOTATED TAG is peeled to its COMMIT (the tag-object sha would never read 'current')" ;;
    *) bad "--status did not report the annotated tag's commit (${FIRSTC:-<unreadable>}) in the commit column: $out" ;;
  esac
  [ "$rc" -eq 0 ] && ok "…and a tag pointing AT the record is 'current' (the peeling is discriminating, not cosmetic)" \
    || bad "an annotated tag on the record's own commit was reported as rc=$rc, not 0=current: $out"
  out="$(runat "$T/home" HARNESS_REF=refs/heads/rel bash "$PIN" --status 2>&1)"; rc=$?
  case "$out" in
    *"refs/heads/rel refs/heads/rel"*|*"refs/heads/rel <unreadable"*) bad "--status put the ref's NAME (or <unreadable>) where the fetched COMMIT belongs — it fetched refs/heads/rel successfully: $out" ;;
    *"refs/heads/rel "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ok "…a remote-only ref resolves to a COMMIT, never to its own spelling" ;;
    *) bad "--status did not resolve the remote-only ref to a commit: $out" ;;
  esac
  [ "$rc" -eq 1 ] && ok "…and it decides DRIFT against the record (exit 1)" \
    || bad "the remote-only ref was decided as rc=$rc, expected 1=DRIFT: $out"
  # ⛔ THE PASS TOO, NOT ONLY `--status`. The verb that actually runs on the ten-minute timer is the PASS,
  # and every leg above drives `--status`: reverting the pass's decision line to `${HARNESS_REF}^{commit}`
  # left this suite at 228 ok / 0 failed (MEASURED), i.e. the half of the fix that matters was ungated. The
  # 6b pass leg cannot discriminate either — `git fetch origin rel` also moves `refs/remotes/origin/rel`, so
  # old and new code read the same commit for that spelling. It DOES discriminate here: the fixture's local
  # `main` sits at C1 (the record), while the fetch brings C2.
  # The run happens in a COPY of the home so a pass that applies cannot move the shared fixture's record
  # under the legs that follow, and the record is re-pointed at C1 explicitly rather than inherited.
  MAIN2="$(git -C "$T/origin.git" rev-parse main 2>/dev/null)"
  cp -a "$T/home" "$T/home-pass"
  printf '%s\n' "$T/home-pass/harness/pintree" >"$T/home-pass/.harness-path"
  git -C "$T/home-pass/harness/pintree" checkout -q --detach "$FIRSTC" 2>/dev/null \
    || bad "could not place the pass-side fixture's record at ${FIRSTC:-<unreadable>}"
  if [ "$(git -C "$T/home-pass/harness/pintree" rev-parse HEAD 2>/dev/null)" = "$FIRSTC" ]; then
    ok "(control) the pass-side fixture's record is C1 while the fetched ref is C2 — the legs below discriminate by VALUE"
  else bad "the pass-side fixture's record is not C1, so the legs below could pass vacuously"; fi
  out="$(runat "$T/home-pass" HARNESS_REF=refs/heads/main bash "$PIN" 2>&1)"; rc=$?
  case "$out" in
    *"target=${MAIN2:-<unreadable>}"*) ok "the PASS acts on the COMMIT the fetch brought for refs/heads/main, not the stale local branch" ;;
    *) bad "the PASS did not resolve HARNESS_REF=refs/heads/main to the fetched commit ${MAIN2:-<unreadable>} — it decided on the LOCAL branch the fetch never moved, which is #3194 through the knob: $out" ;;
  esac
  [ "$rc" -ne 0 ] && ok "…and a record at C1 against that C2 tick is a non-zero pass, not a green no-op" \
    || bad "the PASS reported success against a newer fetched tip (rc=$rc) — a false green on the timer's own verb: $out"
  out="$(runat "$T/home-pass" HARNESS_REF=main bash "$PIN" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "…and the BARE branch spelling ('main') is not decided on the stale local branch either" \
    || bad "the PASS with HARNESS_REF=main answered rc=$rc — a bare spelling read the local branch: $out"
  # ⛔ AND IT IS REFUSED BY NAME, BEFORE ANY MUTATION — not left to RED as STALE-RECORD for ever. `apply`
  # pins what IT resolves LOCALLY (the `want=` `rev-parse` in `cloud-cell-supervisor.sh`'s `harness_apply`), so for a spelling that names a LOCAL ref
  # the record can NEVER advance; and the remedy the STALE-RECORD line prints (`git fetch origin main &&
  # apply --force --pin-only`) cannot change that either, because that fetch does not move the local branch
  # it pins. MEASURED before this guard, tick after tick on a two-clone fixture: `DRIFT … -- applying
  # --force --pin-only`, then `STALE-RECORD: … does not contain main …`, rc=1, pin tree never advancing —
  # i.e. `apply` (a MUTATION) re-run ten times an hour on a box whose pin can never converge. An unhealable
  # RED is as useless as a false GREEN, and a useless remedy is worse than a name.
  case "$out" in
    *'UNRESOLVED(ref-spelling)'*) ok "…and the BARE spelling is REFUSED BY NAME (ref-spelling) before the mutation, instead of re-applying for ever" ;;
    *'STALE-RECORD'*) bad "the bare spelling was not refused up front: the tick ran apply and then blamed an unmoved record — the diagnosis repeats for ever and its remedy cannot work: $out" ;;
    *) bad "the bare spelling exited rc=$rc without naming why it can never converge: $out" ;;
  esac
  # ⛔ THE CANONICAL SPELLING OF THE DEFAULT VALUE MUST NOT DIE IN `git fetch`. `ref_fetch_branch` stripped
  # only `origin/` and `refs/heads/`, so `refs/remotes/origin/main` — the name of THIS repo's tracking ref,
  # which the sibling reader resolves happily (`git rev-parse refs/remotes/origin/main^{commit}`, rc=0) —
  # was handed to `git fetch` verbatim as a REMOTE source: `fatal: couldn't find remote ref
  # refs/remotes/origin/main`, rc=128 (MEASURED). The tick then exited 2 `fetch-failed` for ever on a value
  # that worked before this file decided on the fetched commit, and the `2>/dev/null` on that fetch threw
  # git's own reason away, so the journal could not say why.
  out="$(runat "$T/home-pass" HARNESS_REF=refs/remotes/origin/main bash "$PIN" 2>&1)"; rc=$?
  case "$out" in
    *'fetch-failed'*) bad "HARNESS_REF=refs/remotes/origin/main cannot be fetched — the tracking-ref spelling was handed to git as a REMOTE ref, so the tick exits 2 for ever: $out" ;;
    *"${MAIN2:-<unreadable>}"*) ok "…and the tracking-ref spelling 'refs/remotes/origin/main' is FETCHED as 'main' and decided on the fetched commit, not handed to git as a remote ref" ;;
    *) bad "HARNESS_REF=refs/remotes/origin/main did not reach the fetched commit ${MAIN2:-<unreadable>} (rc=$rc): $out" ;;
  esac
  # ⛔ AND A SPELLING THAT NAMES ANOTHER REMOTE MUST FAIL CLOSED, NOT BE ANSWERED FROM `origin`. A blanket
  # `refs/remotes/*/*` strip turned `refs/remotes/upstream/main` into the fetch source `main` — i.e. into
  # ORIGIN's `main` — so `--status` printed origin's tip under the OTHER ref's name, labelled it "(… fetched
  # just now)", and answered `current` + exit 0 about a ref it never fetched (MEASURED: the same ref's
  # `--status-nofetch` reading said DRIFT). The verb the header calls the operator's first read therefore
  # returned a false green, and nothing on that path failed closed. Every fetch here is hardcoded to
  # `origin`, so the only honest answer is a NAMED refusal (exit 2 = UNKNOWN, the status vocabulary).
  out="$(runat "$T/home-pass" HARNESS_REF=refs/remotes/upstream/main bash "$PIN" --status 2>&1)"; rc=$?
  case "$out" in
    *'verdict        current'*) bad "--status reported 'current' for refs/remotes/upstream/main, a ref it never fetched — the reading came from origin's branch and was printed under another remote's name: $out" ;;
    *'UNRESOLVED(ref-spelling)'*) [ "$rc" -eq 2 ] && ok "…and a spelling naming ANOTHER remote is REFUSED by name (ref-spelling, exit 2 = UNKNOWN), not answered from origin" \
        || bad "refused a foreign-remote spelling but exited $rc, not 2=UNKNOWN: $out" ;;
    *) bad "a foreign-remote spelling was not refused (rc=$rc), so this path does not fail closed: $out" ;;
  esac
  # ⛔ AND NEITHER IS AN EMPTY BRANCH PART. `${r:-main}` turned `origin/` into `main`, so `--status` fetched
  # main, printed `(origin/ fetched just now)` and answered `verdict current` + exit 0 about a name that
  # resolves to nothing — a green on the operator's first screen for a knob whose `--status-nofetch` said
  # UNKNOWN (2) and whose PASS exited 2. The fallback exists for the DEFAULT, but `HARNESS_REF` is already
  # defaulted to `origin/main` at the top of the file, so it can only ever hide a malformed spelling.
  out="$(runat "$T/home-pass" HARNESS_REF=origin/ bash "$PIN" --status 2>&1)"; rc=$?
  case "$out" in
    *'verdict        current'*) bad "--status reported 'current' for HARNESS_REF=origin/ — an empty branch part was rewritten to 'main', so the screen greened a knob the timer's own verb refuses: $out" ;;
    *'UNRESOLVED(ref-spelling)'*) [ "$rc" -eq 2 ] && ok "…and an EMPTY branch part ('origin/') is REFUSED by name (exit 2 = UNKNOWN), not silently rewritten to 'main'" \
        || bad "refused an empty branch part but exited $rc, not 2=UNKNOWN: $out" ;;
    *) bad "an empty branch part was not refused (rc=$rc): the defaulting fallback answers a branch nobody asked for: $out" ;;
  esac
  # The pass-side PEELING control: `attip` is an annotated tag ON the record's commit, so a pass that
  # compares the TAG OBJECT sha to a commit reads DRIFT forever, and one that peels reads current.
  out="$(runat "$T/home-pass" HARNESS_REF=attip bash "$PIN" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "…and a PASS on an annotated tag AT the record converges (exit 0), so the pass peels too" \
    || bad "the PASS on an annotated tag pointing at the record's own commit exited $rc, not 0=current — it read a tag object where a commit belongs: $out"
  # ⛔ AND `FETCH_HEAD` IS NOT OURS TO READ. It is a plain mutable file in the worktree, bound to no run: any
  # other git process in the SAME tree that fetches between our fetch and our read becomes OUR result. That
  # coexistence is by design here — `cloud-cell-supervisor.sh`'s two `fetch --quiet origin main` sites
  # (`classify_harness`, `harness_apply`) run `git fetch origin main` in
  # this repository, and bring-up re-arms `eldato-harness-apply.timer` beside this unit. MEASURED on the
  # pre-fix code: the record sat at MAIN's tip, our ref was `origin/rel` (one commit ahead), a coexisting
  # `git fetch origin main` landed, and `--status` printed a MAIN commit under the `origin/rel` label and
  # answered `current` + exit 0 — a foreign fetch greening a stale layer. A race is not testable by timing,
  # so the foreign writer is INTERPOSED deterministically: a `git` shim that delegates everything and,
  # after any successful `fetch`, overwrites FETCH_HEAD with main's tip — exactly what the other actor does.
  # Only a decision that reads a ref THIS RUN WROTE can survive it.
  # ⛔ THE SHIM ALSO SIMULATES A PEER INVOCATION WITH A DIFFERENT `HARNESS_REF` (RACE_OTHER_SRC): it fetches
  # that OTHER source into `refs/cell-self-pin/fetch`, the single shared destination the cheaper fix used.
  # A destination keyed by source is untouched by it; a single shared one is clobbered, so the leg below
  # fails the moment two different questions share one ref — the last-writer-wins skew `HARNESS_REF` makes
  # reachable on a real box (a manual `--status origin/rel` beside a timer asking about `main`).
  REALGIT="$(command -v git)"
  d_race="$T/fakebin-race"; mkdir -p "$d_race"
  {
    printf '#!/usr/bin/env bash\n'
    printf '"%s" "$@"; rc=$?\n' "$REALGIT"
    printf 'case " $* " in *" fetch "*)\n'
    printf '  if [ "$rc" -eq 0 ] && [ -n "${RACE_REPO:-}" ] && [ -n "${RACE_SHA:-}" ]; then\n'
    printf '    fp="$("%s" -C "$RACE_REPO" rev-parse --git-path FETCH_HEAD 2>/dev/null)"\n' "$REALGIT"
    printf '    case "$fp" in /*) ;; *) fp="$RACE_REPO/$fp" ;; esac\n'
    printf '    printf "%%s\\t\\tbranch main of a foreign fetch\\n" "$RACE_SHA" >"$fp" 2>/dev/null\n'
    printf '  fi\n'
    printf '  if [ "$rc" -eq 0 ] && [ -n "${RACE_REPO:-}" ] && [ -n "${RACE_OTHER_SRC:-}" ]; then\n'
    printf '    "%s" -C "$RACE_REPO" fetch -q origin "+${RACE_OTHER_SRC}:refs/cell-self-pin/fetch" >/dev/null 2>&1\n' "$REALGIT"
    printf '  fi ;;\n'
    printf 'esac\n'
    printf 'exit $rc\n'
  } >"$d_race/git"
  chmod +x "$d_race/git"
  RELRACE="$(git -C "$T/origin.git" rev-parse rel 2>/dev/null)"
  cp -a "$T/home" "$T/home-race"
  printf '%s\n' "$T/home-race/harness/pintree" >"$T/home-race/.harness-path"
  # The record is AT main's tip and the ref we ask about is `rel` (a commit ahead), so the defended reading
  # (the tip of `rel`) is DRIFT, while the foreign reading (main's tip) equals the record and would be green.
  git -C "$T/home-race/harness/pintree" checkout -q --detach "$MAIN2" 2>/dev/null \
    || bad "could not place the race fixture's record at main's tip"
  out="$(runat "$T/home-race" PATH="$d_race:$T/fakebin-none:$PATH" RACE_REPO="$T/home-race/harness/pintree" \
           RACE_SHA="$MAIN2" HARNESS_REF=origin/rel bash "$PIN" --status 2>&1)"; rc=$?
  case "$out" in
    *'verdict        current'*) bad "a FOREIGN fetch of main greened our layer: --status read FETCH_HEAD, which the other actor in this tree rewrites, and reported 'current' for ${HARNESS_REF:-origin/rel} — a false PASS the timer would print every ten minutes: $out" ;;
    *) if [ "$rc" -eq 1 ]; then ok "a FOREIGN fetch of main cannot green a stale layer — the decision reads the ref THIS RUN wrote, not FETCH_HEAD"
       else bad "with a foreign fetch interposed, --status answered rc=$rc (expected 1=DRIFT for rel at ${RELRACE:-<unreadable>}): $out"; fi ;;
  esac
  # ⛔ THE TIMER'S OWN VERB, UNDER THE SAME INTERPOSITION. Every leg above (and the FS race leg above it)
  # drives `--status`; reverting ONLY `do_pass`'s decision to `'FETCH_HEAD^{commit}'` left this suite green
  # (MEASURED at the previous head: 238 ok / 0 failed), so the half of the fix that runs on the ten-minute
  # clock was gated by nothing. Same fixture, same shim, the PASS instead of the status verb.
  cp -a "$T/home" "$T/home-racep"
  printf '%s\n' "$T/home-racep/harness/pintree" >"$T/home-racep/.harness-path"
  git -C "$T/home-racep/harness/pintree" checkout -q --detach "$MAIN2" 2>/dev/null \
    || bad "could not place the pass-race fixture's record at main's tip"
  out="$(runat "$T/home-racep" PATH="$d_race:$T/fakebin-none:$PATH" RACE_REPO="$T/home-racep/harness/pintree" \
           RACE_SHA="$MAIN2" HARNESS_REF=origin/rel bash "$PIN" 2>&1)"; rc=$?
  case "$out" in
    *'current'*) bad "the timer's verb read FETCH_HEAD: a foreign fetch of main greened the PASS against a ${HARNESS_REF:-origin/rel} record that is behind — the false PASS this unit exists to prevent, on the verb systemd runs: $out" ;;
    *) [ "$rc" -ne 0 ] && ok "…and the PASS — the verb the timer runs — is immune to the same foreign fetch, not only --status" \
         || bad "the PASS reported success while FETCH_HEAD had been rewritten by a foreign fetch (rc=$rc): $out" ;;
  esac
  # ⛔ AND ONE SHARED DESTINATION IS NOT OWNED. `HARNESS_REF` is a documented knob, so a manual invocation
  # asking about `main` can run beside the timer asking about `origin/rel`; with a single destination they
  # write the SAME ref with DIFFERENT sources and the value is last-writer-wins across runs (measured: a
  # 12-way concurrent fetch of one refspec gave 8x success — contention serialises and overwrites rather
  # than failing closed). The shim performs exactly that peer write; a destination keyed by source is
  # untouched by it, a shared one is clobbered and the tick reports `current` over a stale layer.
  cp -a "$T/home" "$T/home-keyed"
  printf '%s\n' "$T/home-keyed/harness/pintree" >"$T/home-keyed/.harness-path"
  git -C "$T/home-keyed/harness/pintree" checkout -q --detach "$MAIN2" 2>/dev/null \
    || bad "could not place the keyed-ref fixture's record at main's tip"
  out="$(runat "$T/home-keyed" PATH="$d_race:$T/fakebin-none:$PATH" RACE_REPO="$T/home-keyed/harness/pintree" \
           RACE_OTHER_SRC=main HARNESS_REF=origin/rel bash "$PIN" --status 2>&1)"; rc=$?
  case "$out" in
    *'verdict        current'*) bad "a PEER invocation asking about 'main' clobbered this run's fetched commit: one shared ref destination is last-writer-wins across invocations, so the tick compared against the wrong tip and greened a stale layer: $out" ;;
    *) [ "$rc" -eq 1 ] && ok "…and a peer invocation with a DIFFERENT HARNESS_REF cannot overwrite this run's commit — the destination is keyed by source" \
         || bad "with a peer invocation interposed, --status answered rc=$rc (expected 1=DRIFT for rel at ${RELRACE:-<unreadable>}): $out" ;;
  esac
else bad "could not push the annotated tag — the peeling legs were not exercised"; fi

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
# ⛔ AND THE OPERATOR'S VERB MUST GIVE THE SAME ANSWER AS THE TICK — ONE PREDICATE, NOT TWO (#1178).
# `do_status` decided `current` by EQUALITY while the pass decides by CONTAINMENT, so THIS EXACT FIXTURE —
# the one the leg above pins as green — read `verdict DRIFT` + exit 1 from `--status`. Two answers to one
# question on one box is the third drift dialect this file refuses, and it false-REDs every consumer of the
# `0=current / 1=DRIFT` vocabulary the header reuses. The leg is non-vacuous because the fixture is the
# state where the two rules genuinely disagree: an identical-commit record would pass under either.
out_st="$(runat "$T/home-ahead" bash "$PIN" --status 2>&1)"; rc_st=$?
[ "$rc_st" -eq 0 ] && ok "--status also reads a record AHEAD of the tip as current — one predicate, not two" \
  || bad "--status reported rc=$rc_st for the record the pass calls green — the two verbs disagree on one state: $out_st"
case "$out_st" in
  *'verdict        current'*) ok "…and the verdict LINE says current (not just the exit code)" ;;
  *) bad "…but the verdict line does not say current: $out_st" ;;
esac
# ⛔ AND THE TICK'S **OWN** VERDICT MUST SAY IT — an exit code is not the claim. Moving only the read-back
# to containment left the DECISION by equality, so on THIS fixture the tick logged `DRIFT … -- applying`
# and walked the whole MUTATING path (`one_actor_check apply` can `disable --now` the shipped timer) on a
# pin that already contained the tip, while `--status` and the post-apply rule called the same state
# converged. Both surfaces now decide by containment, and this leg reads the message the unattended path
# actually prints — the one copy of that claim nothing gated.
case "$out" in
  *DRIFT*|*'-- applying'*) bad "the tick still announces DRIFT/apply for a record that CONTAINS the tip — its decision and --status disagree on one state (#1178), and the mutating path runs on a converged pin: $out" ;;
  *) ok "…and the TICK's own verdict says current for it — the DECISION, not just the exit code, is one predicate" ;;
esac
# ⛔ AND A SUCCESSFUL RE-TAKE KEEPS ITS RETIREMENT (the failure rollback is not a blanket undo). The
# fixture is a record BEHIND the tip whose stub `apply` MOVES it onto a tree that CONTAINS the tip: the
# APPLIED path with a GREEN read-back, which the `home-ahead` fixture can no longer reach (its record
# already contains the tip, so the tick correctly no-opes there — that is the leg above). The applied
# path clears the rollback flag before exiting, and this leg is what pins it: a mutation of that one line
# re-enables the shipped timer on EVERY successful tick, which reads as "the one-actor invariant healed,
# then un-healed", for ever, on a converging box.
BEH="$T/home-behind"
mkdir -p "$BEH/harness"
git clone -q "$T/origin.git" "$BEH/harness/pintree" 2>/dev/null
git -C "$BEH/harness/pintree" checkout -q --detach "$FIRST" 2>/dev/null \
  || bad "could not place the applied-path fixture's record BEHIND the tip"
# ⛔ THE CONVERGED TREE MUST BE AT THE **TARGET**, not one commit past it, because the containment check is
# computed in the PIN TREE's object database (`git -C "$repo" merge-base`): a commit minted only inside
# another clone is not in it, so `merge-base --is-ancestor` fails and a correct apply reads as
# STALE-RECORD. A tree checked out AT the tip needs no object the fetch did not bring.
git clone -q "$T/origin.git" "$BEH/harness/converged" 2>/dev/null
mk_sup_pin "$BEH/harness/pintree/scripts/cloud-cell-supervisor.sh" "$BEH/harness/converged"
printf '%s\n' "$BEH/harness/pintree" >"$BEH/.harness-path"
mk_scoped_systemctl "$T/fake-applied" "$T/state-applied"
: >"$T/state-applied/system-cell-self-pin.timer"
: >"$T/state-applied/system-$SHIPPED"
out="$(runat "$BEH" PATH="$T/fake-applied:$PATH" bash "$PIN" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "a converging DRIFT tick exits 0 with a re-armed duplicate it retired" \
  || bad "a converging DRIFT tick exited $rc with a retirable duplicate: $out"
# ⛔ AND IT REALLY IS THE APPLIED PATH (this fixture's record sits behind the tip, so the tick must announce
# the apply). Without this the leg above would pass on a no-op — which is exactly the vacuity the fixture
# change was made to avoid.
case "$out" in
  *'-- applying'*) ok "…and that tick really took the APPLIED path (its record sits behind the tip), so the retirement rule is exercised, not assumed" ;;
  *) bad "the converging fixture NO-OPED instead of applying, so the retirement leg above proved nothing: $out" ;;
esac
[ -f "$T/state-applied/system-$SHIPPED" ] \
  && bad "a SUCCESSFUL tick rolled its own retirement back — the shipped timer is re-enabled on a box whose pin it had just taken, so the one-actor invariant un-heals every tick" \
  || ok "…and a SUCCESSFUL re-take KEEPS the retirement (only a FAILED tick rolls back)"

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
# ⛔ AND IT MINDS ONLY FROM A TREE THAT IS **AT** THE TARGET. `mend_record`'s `[ rev-parse HEAD = target ]`
# is the only guard between "mended" (exit 11, a SUCCESS verdict that keeps the retirement) and writing a pin
# record naming a tree that does NOT contain the ref tip — i.e. manufacturing #3194's own defect (a record
# that disagrees with the tree it is supposed to describe) on the success path. A pin root holds one
# directory per commit, so a `<sha12>` directory that exists but sits on ANOTHER commit is a real shape.
# Deleting that one line left the suite at 280 ok / 0 failed (measured in review), so nothing pinned it.
MG="$T/home-mendbad"
mkdir -p "$MG/harness"
git clone -q "$T/origin.git" "$MG/harness/$SHA12" 2>/dev/null
git -C "$MG/harness/$SHA12" checkout -q "$FIRST" 2>/dev/null
mkdir -p "$MG/harness/$SHA12/scripts/orchestrator-harness"
mk_sup "$MG/harness/$SHA12/scripts/cloud-cell-supervisor.sh"
rm -f "$MG/.harness-path"
out_mb="$(pinrun "$MG" 2>&1)"; rc_mb=$?
[ "$rc_mb" -ne 11 ] && ok "a pin-root tree NOT at the target is refused as a MEND source (never 11)" \
  || bad "the pass MENDED the record to a tree that is not at the target (rc=$rc_mb, 11 is a success verdict): $out_mb"
case "$out_mb" in
  *'STALE-RECORD'*) ok "…and it reports STALE-RECORD instead of mending to a tree off the target" ;;
  *) bad "…but it did not diagnose the un-mendable record: $out_mb" ;;
esac
[ -s "$MG/.harness-path" ] && bad "a record was WRITTEN naming a tree that is not at the target: $(head -1 "$MG/.harness-path")" \
  || ok "…and no record was written for it"
# ⛔ AND IT MINDS ONLY FROM A TREE THAT CARRIES THE HARNESS DIR — the arm that is the difference between a
# `mended` (exit 11, a SUCCESS verdict that keeps the retirement) and a record naming a directory that does
# not exist. Deleting that ONE test left this suite at **421 ok / 0 failed** (round-16 review, P1) while the
# verdict flipped from rc=1 (STALE-RECORD) to rc=11 over a record the controller cannot exec from
# (`cloud-cell-supervisor.sh start` dies "harness not found at $HARNESS — that is the path RECORDED"), and
# the mend write, then the read-back `pinned_head` comes back EMPTY, which is logged and greened.
# A pin-root tree at the target whose `scripts/` carries the supervisor but NO `orchestrator-harness`
# subdirectory is a real shape: the pin only has to be a worktree of the target, not a working harness
# layout — and the record is supposed to name the HARNESS DIR, which does not exist there.
MH="$T/home-mendnoharness"
mkdir -p "$MH/harness"
git clone -q "$T/origin.git" "$MH/harness/$SHA12" 2>/dev/null
mkdir -p "$MH/harness/$SHA12/scripts"
mk_sup "$MH/harness/$SHA12/scripts/cloud-cell-supervisor.sh"
rm -rf "$MH/harness/$SHA12/scripts/orchestrator-harness"
rm -f "$MH/.harness-path"
out_mh="$(pinrun "$MH" 2>&1)"; rc_mh=$?
[ "$rc_mh" -ne 11 ] && ok "a pin-root tree at the target with NO scripts/orchestrator-harness is refused as a MEND source (never 11)" \
  || bad "the pass MENDED the record to a tree that carries no harness dir (rc=$rc_mh, 11 is a success verdict): $out_mh"
case "$out_mh" in
  *'STALE-RECORD'*) ok "…and it reports STALE-RECORD rather than greening an unexecutable record" ;;
  *) bad "…but it did not diagnose the un-mendable record: $out_mh" ;;
esac
[ -s "$MH/.harness-path" ] && bad "a record was WRITTEN naming a tree with no scripts/orchestrator-harness: $(head -1 "$MH/.harness-path")" \
  || ok "…and no record was written for it"

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
# ⛔ AND THE FAILURE MUST CARRY GIT'S OWN REASON (round-13 review, P2). Both fetches redirected stderr to
# `/dev/null`, so the RED said only "git fetch … failed" — the exact pattern this file's own comment names
# as why "the journal could not even say why" an earlier pin tick failed. Git had already written the answer
# (`fatal: '…' does not appear to be a git repository`); it was deleted. A boolean is not a diagnosis, and
# the comment that calls that pattern out is BELOW the line that committed it.
case "$out" in
  *"git's own reason"*) ok "…and the reading names GIT'S OWN REASON for the failed fetch (stderr is captured, not discarded)" ;;
  *) bad "the failed fetch discarded git's own reason — an operator gets a boolean where git wrote the diagnosis: $out" ;;
esac
case "$out" in
  *'no-such-origin'*|*'does not appear to be a git repository'*|*'fatal'*) ok "…and the reason is git's actual message, not a placeholder" ;;
  *) bad "the captured reason is a placeholder, not what git said: $out" ;;
esac
# The TICK is the path that runs every ten minutes and writes the journal, so its refusal has to carry the
# same diagnosis — it was a SEPARATE `2>/dev/null`, i.e. fixing one would have left the other blind. The
# fixture above carries no supervisor, so the tick would stop at `no-supervisor` BEFORE the fetch; this one
# carries one, so the failure the leg measures is the FETCH and nothing else.
TICKBAD="$T/home-badfetch-tick"
mkdir -p "$TICKBAD/harness" "$TICKBAD/orchestrator"
git clone -q "$T/origin.git" "$TICKBAD/harness/tree" 2>/dev/null
git -C "$TICKBAD/harness/tree" remote set-url origin "$T/no-such-origin.git"
mkdir -p "$TICKBAD/harness/tree/scripts"
mk_sup "$TICKBAD/harness/tree/scripts/cloud-cell-supervisor.sh"
printf '%s\n' "$TICKBAD/harness/tree" >"$TICKBAD/.harness-path"
out="$(pinrun "$TICKBAD" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "the TICK also exits 2 on a failed fetch" || bad "the tick exited $rc on a failed fetch, expected 2: $out"
case "$out" in
  *"git's own reason"*) ok "…and the TICK's refusal carries git's own reason too (both fetches capture stderr, not one)" ;;
  *) bad "the tick's fetch refusal still discarded git's own reason: $out" ;;
esac
# ⛔ AND THE PHRASE ABOVE IS NOT ENOUGH ON ITS OWN (round-14 review, P2). It is literal text in the refusal
# TEMPLATE, printed whether or not stderr was captured — so reverting ONLY the tick's `2>&1 >/dev/null`
# left the suite at 390 ok / 0 failed, i.e. the tick half of this fix was ungated while the `--status` half
# was. The discriminating assertion is that what git ACTUALLY SAID reaches the refusal: the fixture's
# remote URL, which only appears in git's own stderr. The placeholder prints instead when nothing was
# captured, and then this leg reds.
case "$out" in
  *'<git wrote nothing to stderr>'*) bad "the tick captured NOTHING from git — 2>/dev/null is back and the refusal only has the template's placeholder: $out" ;;
  *'no-such-origin'*) ok "…and what GIT actually said reaches the refusal (the fixture's remote path), so stderr is captured and not merely described" ;;
  *) bad "the tick's refusal does not carry git's own words: $out" ;;
esac
# ⛔ (a-bis) …AND THE ARM IS ONLY DISCRIMINATING WHEN THE RUN-PRIVATE REF ALREADY EXISTS (round-15 review,
# P2). `$BADHOME` above is a FRESH clone, so TWO independent rules produce the same verdict on it: the
# failed-fetch arm AND the unreadable-target arm (`git rev-parse --verify "${fetch_ref}^{commit}"` is empty
# because no fetch ever wrote that ref). `if false; then` over the fetch-failed arm therefore left the suite
# at 418 ok / 0 failed — the leg could not say WHICH rule it had exercised, so neither rule was gated. The
# shape a converged box is actually in on every tick after the first is the one below: a SUCCESSFUL reading
# first (which writes `refs/cell-self-pin/fetch-*`), the remote broken AFTERWARDS, and the record still at
# the old tip — so the unrefreshed ref is the ONLY thing that can decide, and what the arm-less code decides
# is `current` + exit 0. MEASURED with the arm deleted: rc=0, `verdict        current`.
GOODHOME="$T/home-goodfetch-then-broken"
mkdir -p "$GOODHOME/harness" "$GOODHOME/orchestrator"
git clone -q "$T/origin.git" "$GOODHOME/harness/tree" 2>/dev/null
printf '%s\n' "$GOODHOME/harness/tree" >"$GOODHOME/.harness-path"
out="$(pinrun "$GOODHOME" --status 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "(control) a healthy --status on this fixture reads current, so the run-private fetch ref EXISTS before the remote is broken" \
  || bad "(control) the pre-break --status exited $rc, not 0, so the leg below could pass through the unreadable-target rule instead of the fetch arm: $out"
git -C "$GOODHOME/harness/tree" remote set-url origin "$T/no-such-origin.git"
out="$(pinrun "$GOODHOME" --status 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "…and with the run-private fetch ref ALREADY present, a failed fetch still exits 2 — the fetch arm is REACHED, so this verdict is the arm's and not the unreadable-target rule's" \
  || bad "a failed fetch on a fixture that ALREADY has the run-private ref exited $rc, not 2 (unknown): the unreadable-target rule cannot answer here, so this is the fetch arm failing to decide: $out"
case "$out" in
  *'verdict        current'*) bad "…but with the run-private ref present, a FAILED fetch printed 'verdict current' — an unrefreshed ref decided a reading the pass itself calls not a green, which is #3194's false PASS with a green exit" ;;
  *'UNKNOWN (2) — the fetch failed'*) ok "…and the verdict names the FAILED FETCH as its reason, so the two rules are distinguishable on the operator's line too" ;;
  *) bad "…but the verdict does not name the failed fetch: $out" ;;
esac
# ⛔ (b) A RENDER REFUSES WHEN `CELL_HOME` IS UNSET. The value is now DERIVED
# (`scripts/lib/cell-home.sh`, agent-infra#3453) and the READER of the record it derives from —
# cloud-cell-supervisor.sh — consumes the SAME resolver, so the two can no longer disagree about which home
# is the cell's. What a derivation cannot supply is the OPERATOR'S decision, and rendering bakes
# `Environment=CELL_HOME=` into /etc/systemd/system for ever, while `verify_unit`'s CELL_HOME assertion is
# self-referential (it compares the artifact with the same value). Refusing at the one moment the value
# becomes permanent is the only fail-closed answer — and the refusal must NAME the derived value it would
# have written, so the operator sees what they are about to make permanent.
out="$(env -u CELL_HOME -u HARNESS -u HARNESS_PIN_FILE -u HARNESS_PIN_DIR -u HARNESS_REPO -u O -u STAMP \
     -u TEMPLATES_DIR -u SYSTEMD_UNIT_DIR -u CELL_SELF_PIN_INTERVAL_MIN \
     -u CELL_SELF_PIN_ALLOW_DUPLICATE_ACTUATOR -u CELL_SELF_PIN_SRC \
     PATH="$T/fakebin-none:$PATH" HOME="$T/home" bash "$PIN" --print-unit 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "--print-unit REFUSES to render when CELL_HOME is unset (an explicit base is required to make it permanent)" \
  || bad "a render with CELL_HOME unset succeeded (rc=$rc) — it bakes an unconfirmed base into the unit: $out"
# ⛔ AND IT NAMES THE DERIVED VALUE, not the pre-#3453 divergence. This arm used to assert the string
# `/tmp/cell-home` — the LEGACY home the old message pointed at — which is now the one answer the resolver
# must never produce. A test asserting a literal there would pin the defect in place.
# ⛔ AND IT IS NOT A FIXTURE LITERAL EITHER. The first version of this arm asserted the fixture's
# `$T/home` — which is WRONG ON EVERY REAL HOST, because the resolver's precedence puts the PASSWD
# record's home AHEAD of `$HOME`: on a CI runner the derived value is `/home/runner`, on a cell
# `/home/cmux`, never the temp-dir fixture home. So the arm read as a defect in the product and was a
# host assumption in the test (measured: `505 ok, 1 failed` on the `cmux` cell, the one leg red).
# The assertion is therefore against the value THE ONE RESOLVER ANSWERS for this same environment —
# that IS the contract ("the refusal names the derived value"), it is host-independent, and it is
# non-vacuous: on pre-#3453 code `lib/cell-home.sh` does not exist, so the derivation below yields
# nothing and this leg still fails.
derived=""; derived="$(cd "$T" && env -u CELL_HOME -u HOME_ORIG -u CELL_HOME_FLEET_DEFAULT \
  PATH="$T/fakebin-none:$PATH" HOME="$T/home" \
  bash -c '. "$1/lib/cell-home.sh" && cell_home_resolve' _ "$SELF" 2>/dev/null)"
[ -n "$derived" ] && ok "…the derivation is READABLE (scripts/lib/cell-home.sh answers '$derived' in this env), so the assertion below measures the product and not an absent file" \
  || bad "…scripts/lib/cell-home.sh did not answer a derived value in this env, so the arm below cannot measure anything"
case "$out" in
  *"$derived"*) ok "…and the refusal names the DERIVED value it would have written ('$derived' — the resolver's answer, not a fixture literal)" ;;
  *) bad "…but the refusal does not name the derived value '$derived' it refused over: $out" ;;
esac
case "$out" in
  *'3453'*) ok "…citing agent-infra#3453 as the reason the two sides now agree" ;;
  *) bad "…but the refusal does not cite the change that unified the derivation: $out" ;;
esac

printf '\n%d ok, %d failed\n' "$ok_n" "$bad_n"
[ "$bad_n" -eq 0 ] || { printf 'scratch left at %s\n' "$T"; trap - EXIT; exit 1; }
