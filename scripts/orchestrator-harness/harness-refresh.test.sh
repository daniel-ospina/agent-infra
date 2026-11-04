#!/usr/bin/env bash
# harness-refresh.test.sh — the regression contract for agent-infra#2215.
#
# THE DEFECT. MEASURED 2026-10-20: three cells sat on a checkout 27 commits behind origin/main with
# an EMPTY harness pin. Nothing fetched, nothing compared, and an empty pin was indistinguishable
# from a current one because no reader refused it — so fixes that had landed hours earlier were
# running nowhere, and the only way one reached a cell was a human pulling it by hand. Separately, a
# live-tested patch was lost from a checkout by the next pull because it existed only as a
# working-tree edit.
#
# HOW THESE CHECKS ARE WRITTEN. Every one drives the SHIPPED script — or the shipped orch-loop.sh
# block / dispatch-merge.sh spawn line, extracted verbatim by its markers / driven with stubs — never
# a re-implementation, which would pass on the broken copy too. No network: the "remote" is a bare
# repo created in $TMP, and the runner is always invoked with --no-fetch against an explicit ref.
#
# ⛔ THE CASES PIN THE POLARITY, NOT JUST THE HAPPY PATH. A refresh that re-pins over a dirty tree, or
# that reads an unresolvable ref as current, is worse than no refresh at all: it would silently run
# the commit INSTEAD of the operator's work — the exact data loss in the incident above.
#
# Run:  bash scripts/orchestrator-harness/harness-refresh.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RR="$HERE/harness-refresh.sh"
LOOP="$HERE/orch-loop.sh"
DM="$HERE/dispatch-merge.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
# ⛔ REAP A PLANT AND ITS CHILDREN. Every plant in this suite is `bash <script>` where the script's last
# command is `sleep 120`, so the process the case holds the pid of is the WRAPPER and the sleeper is its
# CHILD. `kill "$_Pxx"` alone therefore kills the wrapper and orphans a two-minute sleeper at ppid 1 on
# every run (MEASURED: 9 survivors after one suite run). `-P` targets exactly that wrapper's children, so
# no other fixture's plant — and nothing else on the host — can be signalled. Falls back to the old
# behaviour (a leak) if `pkill` is absent, so a box without it still runs the suite.
reap() {
  command -v pkill >/dev/null 2>&1 && pkill -9 -P "$1" 2>/dev/null
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
  return 0
}
# ⛔ START EACH CONTROLLER IN ITS OWN PROCESS GROUP AND REAP THE GROUP (agent-infra#3011). The
# previous teardown here was `trap 'rm -rf "$T"' EXIT` alone, and a deleted cwd does not end a
# process: every run left its REAL controllers resident, parked on a fifo `read` at 0 CPU and
# reparented to 1. MEASURED 2026-10-28 on `pi-cell-4`: 145 leaked controllers, load 33–39 on 8 cores.
# `fixture-hermetic.sh` starts each fixture in its own group, records the group, and on EXIT reaps it
# and VERIFIES it is gone (a survivor fails the suite, because a false PASS is half the defect).
# shellcheck source=/dev/null
# ⛔ FAIL CLOSED ON THE LOAD ITSELF (review, cycle 2). Under `set -uo pipefail` (no `set -e`) a failed
# `.` prints a diagnostic and the script CONTINUES: `fixture_guard_placement` then dies with 127, the
# suite runs unguarded, and there is no EXIT reaper — the exact pre-#3011 behaviour, while looking
# normal. `run-bash-shards.sh` already refuses in this situation; a suite run directly owes the same
# contract, or the "enforcer that cannot fire" class returns through the other door.
[ -r "$HERE/fixture-hermetic.sh" ] || {
  echo "  ❌ missing $HERE/fixture-hermetic.sh — refusing to run fixtures that cannot be guarded or reaped" >&2
  exit 2
}
. "$HERE/fixture-hermetic.sh"
command -v fixture_guard_placement >/dev/null 2>&1 || {
  echo "  ❌ $HERE/fixture-hermetic.sh did not define the placement guard — refusing to run unguarded" >&2
  exit 2
}
# ⛔ AND REFUSE TO RUN AT ALL ON A LIVE CELL (#3011): a cell is a capacity resource, and its load is
# the fleet's own dispatch signal. Keyed on a controller EXECUTING from a cell root, never on the
# directory existing — a stale `/tmp/cell-home` on a laptop must not block a local run.
fixture_guard_placement "harness-refresh.test.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-refresh.XXXXXX")"
fixture_hermetic_init "$T/.fixture-pgids" "$T"
echo "==> harness-refresh contract ($HERE)"

[ -f "$RR" ]   || { echo "  ❌ missing $RR"; exit 1; }
[ -f "$LOOP" ] || { echo "  ❌ missing $LOOP"; exit 1; }
[ -f "$DM" ]   || { echo "  ❌ missing $DM"; exit 1; }

# ── fixture ──────────────────────────────────────────────────────────────────────────────────────
# A bare "remote", a plain clone as the source checkout, and disposable HARNESS trees that stand in
# for the pinned worktree the controller runs from. C1..C3 let each case pick its relation:
#   up-to-date : harness AT the tip        behind : harness at C1, tip at C2
#   ahead      : harness at C3 (a local commit never pushed)     diverged : harness at an orphan
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
git init -q --bare "$T/remote.git"
git init -q -b main "$T/src" && git -C "$T/src" remote add origin "$T/remote.git"

mk_commit() { # <checkout> <label> -> sha on stdout
  local d="$1" label="$2"
  mkdir -p "$d/scripts/orchestrator-harness"
  printf 'echo %s\n' "$label" > "$d/scripts/orchestrator-harness/orch-loop.sh"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm "$label" >/dev/null 2>&1
  git -C "$d" rev-parse HEAD
}

C1="$(mk_commit "$T/src" C1)"; git -C "$T/src" push -q origin HEAD:refs/heads/main
C2="$(mk_commit "$T/src" C2)"; git -C "$T/src" push -q origin HEAD:refs/heads/main
C3="$(mk_commit "$T/src" C3)"   # deliberately NOT pushed: the "ahead" case
git -C "$T/src" fetch -q origin

# harness_at <sha> -> the harness dir of a detached worktree at that commit (created once per sha)
harness_at() {
  local want="$1" d="$T/h-$1"
  [ -d "$d" ] || git -C "$T/src" worktree add --detach "$d" "$want" >/dev/null 2>&1
  printf '%s\n' "$d/scripts/orchestrator-harness"
}
pin_of() { head -1 "$1" 2>/dev/null | tr -d '[:space:]'; }
# ⛔ A LOCAL `short()`: the shipped script defines one, but a case block runs in THIS shell, so calling it
# here expanded to the EMPTY STRING and the two separator assertions below degraded to `*" == "*` — they
# could not fail for the property their own message names (review finding).
short() { printf '%s' "${1:-}" | cut -c1-12; }

# A materialiser stub. It stands in for `cloud-cell-supervisor.sh apply` — the ONE thing allowed to
# materialise a pin — and records that it was CALLED, so "did the runner delegate, or invent its own
# pin write" is observable rather than asserted from prose.
mk_stub_mat() { # <dir> -> path; calls are appended to <dir>/mat.calls
  mkdir -p "$1"
  cat > "$1/mat.sh" <<'SH'
#!/bin/bash
# A stub for the ONE engine allowed to materialise a pin; it records that it was CALLED. `exit 0` is
# load-bearing: without it the script's status is the `[ -n ]` test's, which is 1 for an unset
# MAT_REFUSE — a stub that reported failure on every successful call.
echo "apply $*" >> "$(dirname "$0")/mat.calls"
if [ -n "${MAT_REFUSE:-}" ]; then echo "FATAL: stub materialiser refused"; exit 1; fi
exit 0
SH
  chmod +x "$1/mat.sh"
  printf '%s\n' "$1/mat.sh"
}

_CASE=0
_CASE=$((_CASE+1)); echo "=== A1: behind + clean -> the pin ADVANCES to the tip, and old -> new is logged ==="
D="$T/a1"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C1" > "$PIN"
MAT="$(mk_stub_mat "$D")"
R="$(HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" \
      --self "$(harness_at "$C1")" 2>&1)"; RC=$?
[ "$RC" = 10 ] && ok "exit 10 (repinned)" || bad "exit $RC, expected 10 — output: $R"
[ "$(pin_of "$PIN")" = "$C2" ] && ok "the pin now names the ref tip ($C2)" \
                              || bad "the pin is '$(pin_of "$PIN")', expected $C2"
case "$R" in *"${C1:0:12} -> ${C2:0:12}"*) ok "the log names the OLD and the NEW sha (a re-pin nobody can read is not a record)" ;;
              *) bad "the log does not name old -> new: $R" ;; esac
[ "$(grep -c '^apply' "$D/mat.calls" 2>/dev/null)" = 1 ] \
  && ok "adoption was DELEGATED to the materialiser exactly once" \
  || bad "the materialiser was called $(grep -c '^apply' "$D/mat.calls" 2>/dev/null || echo 0) time(s), expected 1"
# ⛔ `--pin-only` is not a detail: without it the materialiser re-seeds $O under a running controller and
# a loop ends up calling NEW helpers from an OLD orch-loop.sh. Asserted on the argv the stub saw.
case "$(cat "$D/mat.calls" 2>/dev/null)" in *--pin-only*) ok "the materialiser is called with --pin-only (advance the pin, never re-seed a live \$O)" ;;
              *) bad "the materialiser was NOT called with --pin-only: $(cat "$D/mat.calls" 2>/dev/null)" ;; esac
# After the pin names the tip, the box is NOT `current`: the process still executes the previous commit
# until it is relaunched. `behind` would put a stale token on every spawn line; `current` is a false PASS.
case "$R" in *relation=restart-pending*running="${C1:0:12}"*pin="${C2:0:12}"*action=repinned*) ok "a re-pin reports restart-pending (pin=new tip, running=old), never 'current'" ;;
              *) bad "post-re-pin record should be restart-pending with the new pin: $R" ;; esac

_CASE=$((_CASE+1)); echo "=== A2: up to date -> a true no-op (no write, no delegation, exit 0) ==="
D="$T/a2"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C2" > "$PIN"
MAT="$(mk_stub_mat "$D")"
R="$(HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" \
      --self "$(harness_at "$C2")" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "exit 0 (current)" || bad "exit $RC, expected 0 — output: $R"
[ "$(pin_of "$PIN")" = "$C2" ] && ok "the pin still names the tip" || bad "the pin moved to '$(pin_of "$PIN")'"
[ ! -f "$D/mat.calls" ] && ok "the materialiser was NOT called on a no-op" || bad "a no-op delegated to the materialiser"
case "$R" in *relation=current*action=none*) ok "record: relation=current action=none" ;; *) bad "record wrong: $R" ;; esac

_CASE=$((_CASE+1)); echo "=== A3: EMPTY PIN + current code -> MENDED and SAID (the measured three-cells state) ==="
D="$T/a3"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; : > "$PIN"
R="$(bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C2")" 2>&1)"; RC=$?
[ "$RC" = 11 ] && ok "exit 11 (mended), not 0 — an empty pin is a state, never a quiet absence" \
              || bad "exit $RC, expected 11 — output: $R"
[ "$(pin_of "$PIN")" = "$C2" ] && ok "the pin records the commit the box actually runs" || bad "pin is '$(pin_of "$PIN")'"
case "$R" in *MENDED*) ok "the mend is announced" ;; *) bad "the mend was silent: $R" ;; esac

_CASE=$((_CASE+1)); echo "=== A4: a MISSING pin file is the same defect, not a different one ==="
D="$T/a4"; mkdir -p "$D/pin"; PIN="$D/pin/nested/HARNESS-PIN"
R="$(bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C2")" 2>&1)"; RC=$?
{ [ "$RC" = 11 ] && [ "$(pin_of "$PIN")" = "$C2" ]; } \
  && ok "an absent pin is created (parent dir included), exit 11" || bad "exit $RC, pin '$(pin_of "$PIN")'"

_CASE=$((_CASE+1)); echo "=== A5: DIRTY harness surface -> REFUSE, name the file, touch nothing ==="
D="$T/a5"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
MAT="$(mk_stub_mat "$D")"
# A live-tested patch that exists only as a working-tree edit — the measured data-loss shape. It is
# planted in its OWN detached worktree (never the fixture's main checkout), so no discard is needed to
# clean up: the case is thrown away with $T.
git -C "$T/src" worktree add --detach "$T/src-dirty" "$C2" >/dev/null 2>&1
printf 'echo PATCHED\n' > "$T/src-dirty/scripts/orchestrator-harness/orch-loop.sh"
R="$(HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src-dirty" --ref origin/main --pin "$PIN" \
      --self "$(harness_at "$C1")" 2>&1)"; RC=$?
[ "$RC" = 20 ] && ok "exit 20 (dirty)" || bad "exit $RC, expected 20 — output: $R"
case "$R" in *dirty*) ok "the refusal NAMES dirty" ;; *) bad "the refusal does not name dirty: $R" ;; esac
case "$R" in *orch-loop.sh*) ok "it names the offending file, so the operator can act" ;; *) bad "the file is unnamed: $R" ;; esac
[ "$(pin_of "$PIN")" = "$C1" ] && ok "the pin was NOT advanced over uncommitted work" || bad "the pin moved to '$(pin_of "$PIN")'"
[ ! -f "$D/mat.calls" ] && ok "the materialiser was NOT called (nothing was adopted)" || bad "a dirty tree was adopted"

_CASE=$((_CASE+1)); echo "=== A6: local commits AHEAD -> REFUSE, name it, touch nothing ==="
D="$T/a6"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN"
MAT="$(mk_stub_mat "$D")"
R="$(HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" \
      --self "$(harness_at "$C3")" 2>&1)"; RC=$?
[ "$RC" = 21 ] && ok "exit 21 (ahead)" || bad "exit $RC, expected 21 — output: $R"
case "$R" in *ahead*) ok "the refusal NAMES ahead (a distinct state from 'diverged')" ;; *) bad "the refusal does not name ahead: $R" ;; esac
[ "$(pin_of "$PIN")" = "$C2" ] && ok "the pin still names the old sha (the local commit was not dropped)" || bad "pin moved to '$(pin_of "$PIN")'"
[ ! -f "$D/mat.calls" ] && ok "the materialiser was NOT called" || bad "an ahead tree was adopted"

_CASE=$((_CASE+1)); echo "=== A7: diverged -> REFUSE, and say it cannot be compared ==="
D="$T/a7"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
# An ORPHAN commit — a real object in the same store with no parent, so it is neither an ancestor nor
# a descendant of origin/main. Built with commit-tree: no branch is moved and no tree is checked out.
ORPH="$(git -C "$T/src" commit-tree "$(git -C "$T/src" rev-parse "${C1}^{tree}")" -m ORPHAN)"
R="$(bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$ORPH")" 2>&1)"; RC=$?
[ "$RC" = 22 ] && ok "exit 22 (diverged)" || bad "exit $RC, expected 22 — output: $R"
case "$R" in *diverged*) ok "the refusal NAMES diverged" ;; *) bad "does not name diverged: $R" ;; esac

_CASE=$((_CASE+1)); echo "=== A8: an UNRESOLVABLE ref is UNKNOWN, never 'current' ==="
D="$T/a8"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
R="$(bash "$RR" --no-fetch --repo "$T/src" --ref origin/no-such-branch --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
[ "$RC" = 23 ] && ok "exit 23 (unknown), not 0 — cannot-verify is not a pass" || bad "exit $RC, expected 23 — output: $R"
[ "$(pin_of "$PIN")" = "$C1" ] && ok "the pin was left alone" || bad "the pin moved on an unknown ref"

_CASE=$((_CASE+1)); echo "=== A9: behind with NO materialiser -> exit 25, pin NOT advanced (a pin must name a real tree) ==="
D="$T/a9"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
R="$(bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
[ "$RC" = 25 ] && ok "exit 25 (behind, unmaterialised)" || bad "exit $RC, expected 25 — output: $R"
[ "$(pin_of "$PIN")" = "$C1" ] && ok "the pin was NOT advanced to a tree that does not exist" || bad "pin moved to '$(pin_of "$PIN")'"
case "$R" in *"NO materialiser"*) ok "it names the reason and the remedy" ;; *) bad "the reason is unnamed: $R" ;; esac

_CASE=$((_CASE+1)); echo "=== A10: a FAILING materialiser -> no pin advance, and the failure is quoted ==="
D="$T/a10"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
MAT="$(mk_stub_mat "$D")"
R="$(MAT_REFUSE=1 HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" \
      --self "$(harness_at "$C1")" 2>&1)"; RC=$?
[ "$RC" = 23 ] && ok "exit 23 — a failed adoption never records success" || bad "exit $RC, expected 23 — output: $R"
[ "$(pin_of "$PIN")" = "$C1" ] && ok "the pin was NOT advanced" || bad "pin moved to '$(pin_of "$PIN")'"
case "$R" in *"stub materialiser refused"*) ok "the materialiser's own failure is quoted" ;; *) bad "the failure is unreported: $R" ;; esac

_CASE=$((_CASE+1)); echo "=== A11: idempotence — the cycle after a re-pin is NOT a second re-pin ==="
D="$T/a11"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
MAT="$(mk_stub_mat "$D")"
HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" \
  --self "$(harness_at "$C1")" >/dev/null 2>&1
# The pin already names the tip, and the RUNNING tree is still the old commit — pin-per-commit means a
# controller adopts a new harness at its NEXT launch. A refresh that re-adopts here would call the
# materialiser (and re-seed $O) EVERY cycle, forever.
MAT2="$(mk_stub_mat "$T/a11b")"
R="$(HARNESS_MATERIALISER="$MAT2" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" \
      --self "$(harness_at "$C1")" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "the second cycle exits 0 (nothing is re-deployed)" || bad "exit $RC, expected 0 — output: $R"
[ ! -f "$T/a11b/mat.calls" ] && ok "and does not re-materialise" || bad "the second cycle re-materialised"
case "$R" in *relation=restart-pending*) ok "it reports restart-pending, not 'current' — the controller still runs the old tree" ;;
              *) bad "a stale running tree read as something else: $R" ;; esac

# The PATH pin is the cell's real configuration: it names the tree `apply` created, so its HEAD is the
# deployed commit even when the sha record was never written.
_CASE=$((_CASE+1)); echo "=== A13: the PATH pin names the deployed tree -> no adoption, no storm ==="
D="$T/a13"; mkdir -p "$D/pin"
PINDIR="$D/harness/$C2"; mkdir -p "$PINDIR"
git -C "$T/src" worktree add --detach "$PINDIR" "$C2" >/dev/null 2>&1
printf '%s\n' "$PINDIR/scripts/orchestrator-harness" > "$D/pin/path-pin"
MAT="$(mk_stub_mat "$D")"
R="$(HARNESS_MATERIALISER="$MAT" HARNESS_PIN_FILE="$D/pin/path-pin" \
      bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$D/pin/HARNESS-PIN" \
      --self "$(harness_at "$C1")" 2>&1)"; RC=$?
[ "$RC" = 11 ] && ok "exit 11 — the deployed tree IS current, the sha record was empty, so it is mended" \
              || bad "exit $RC, expected 11 — output: $R"
[ "$(pin_of "$D/pin/HARNESS-PIN")" = "$C2" ] && ok "the sha record now names the path-pin tree's commit" || bad "sha pin is '$(pin_of "$D/pin/HARNESS-PIN")'"
[ ! -f "$D/mat.calls" ] && ok "and NOTHING was materialised (the tree already existed)" || bad "it materialised a tree that was already deployed"
case "$R" in *restart-pending*) ok "…and it still discloses that the running controller is older" ;; *) bad "restart-pending not reported: $R" ;; esac

_CASE=$((_CASE+1)); echo "=== A12: --no-adopt gives the verdict without recording (operator form) ==="
D="$T/a12"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
MAT="$(mk_stub_mat "$D")"
R="$(HARNESS_MATERIALISER="$MAT" bash "$RR" --no-adopt --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
[ "$RC" = 25 ] && ok "exit 25 (behind, adoption disabled)" || bad "exit $RC, expected 25 — output: $R"
[ ! -f "$D/mat.calls" ] && ok "nothing was delegated" || bad "--no-adopt still delegated"

# ── A22..A28: the LANE CONTRACT ──────────────────────────────────────────────────────────────────
# THE DEFECT THIS PINS. Measured 2026-10-21 on all three cells: every box ran a pinned checkout at
# ce987bb2 while origin/main was 15f9262a, so four merged fixes (#2254, #2253, #2054, the research
# contract gate) were in main and on NO machine, for five hours. `harness-refresh.sh` was on every box
# and had not advanced the pin since a hand-bootstrap — because the only safe-looking advance was
# assumed to kill live lanes, so nobody ran it. Two separate things had to be true at once, and this
# block pins both:
#   (a) the advance NEVER touches a live lane (pin-per-commit: new worktree, atomic pin write), so it is
#       safe under a running controller and mid-turn lanes — and it is safe EVERY cycle, because an
#       already-current pin is a no-op exit 0;
#   (b) the ONE destructive form (`--re-seed`, which re-seeds $O under a running loop) REFUSES by
#       default with exit 26 and needs `--force` — so "a refresh that must kill something" cannot
#       happen by accident;
#   (c) the reason the pin could not advance at all — a hand-launched controller has no
#       HARNESS_MATERIALISER, so every cycle exited 25 `unmaterialised` — is fixed by resolving the
#       materialiser from the CELL POSTURE (HARNESS_PIN_FILE + CELL_HOME), never from an ambient script.
# ⛔ EVERY CASE ASSERTS THE LANE PROCESS IS STILL ALIVE. "Nothing was killed" is the whole claim; a
# suite that only checked the exit code would pass on a refresh that also did `pkill -f lane.sh`.
mk_fake_lane() { # <O-dir> -> pid on stdout; argv names `$O/<name>.sh`, like a real lane
  local o="$1" f
  mkdir -p "$o"
  f="$o/run-fix-9901.sh"
  printf 'sleep 30\n' > "$f"
  bash "$f" >/dev/null 2>&1 &
  printf '%s\n' "$!"
}
lane_alive() { kill -0 "$1" 2>/dev/null; }

_CASE=$((_CASE+1)); echo "=== A22: a lane is MID-TURN -> the advance still happens, and the lane is NEVER signalled ==="
D="$T/a22"; mkdir -p "$D/pin" "$D/O"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
printf '%s\n' "$$" > "$D/O/.orch.lock"     # a live controller, as on a real cell
LANEPID="$(mk_fake_lane "$D/O")"
MAT="$(mk_stub_mat "$D")"
R="$(O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
lane_alive "$LANEPID" && ok "the in-flight lane process was NOT signalled (pid $LANEPID still alive)" \
                     || bad "the refresh KILLED the lane process $LANEPID — the exact defect this PR removes"
[ "$RC" = 10 ] && ok "exit 10 — it ADVANCED rather than deferring for ever (a busy cell would never move otherwise)" \
                || bad "exit $RC, expected 10 — output: $R"
[ "$(pin_of "$PIN")" = "$C2" ] && ok "the pin advanced to the tip while the lane kept running" || bad "pin is '$(pin_of "$PIN")'"
case "$R" in *lanes=1*) ok "the record discloses lanes=1 — the deferred restart is visible, not silent" ;; *) bad "no lane disclosure in the record: $R" ;; esac
case "$R" in *"IN-FLIGHT at the advance"*) ok "…and the prose says nothing was signalled" ;; *) bad "the in-flight fact is unstated: $R" ;; esac
case "$(cat "$D/mat.calls" 2>/dev/null)" in *--pin-only*) ok "the advance used --pin-only (a new per-commit tree; \$O untouched)" ;; *) bad "the advance did not use --pin-only: $(cat "$D/mat.calls" 2>/dev/null)" ;; esac
reap "$LANEPID"

# ⛔ A22b: AN AMBIENT `COLUMNS` MUST NOT HIDE A LIVE LANE (#2926). `in_flight_pids` reads `ps … command=`
# and matches the token `$O/<name>.sh`. `ps(1)` honours `COLUMNS` BEFORE its "not a tty ⇒ unlimited"
# default (FreeBSD/Apple ps(1): "the default output width is that requested by the COLUMNS environment
# variable if present"), and the path is the LAST token of the line, so an exported COLUMNS cuts it first.
# Measured on the cell: `COLUMNS=40 ps -o command= -p $$` → 41 bytes; the same read with `-ww` → the whole
# 305-byte line. Truncated, this read answers lanes=0 for a LIVE lane — and lanes=0 is exactly what lets
# `--re-seed` swap `$O` under it, so the direction is DESTRUCTIVE, not cosmetic. The width is 20 on
# purpose: below any fixture path, so the truncation is certain rather than lucky. Asserting only `lanes=1`
# would under-test it — the destructive ARMS are asserted too.
_CASE=$((_CASE+1)); echo "=== A22b: an ambient COLUMNS cannot hide a live lane from the in-flight read (ps -ww) ==="
D="$T/a38"; mkdir -p "$D/pin" "$D/O"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
printf '%s\n' "$$" > "$D/O/.orch.lock"     # a live controller, as on a real cell
LANEPID="$(mk_fake_lane "$D/O")"
MAT="$(mk_stub_mat "$D")"
R="$(COLUMNS=20 O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" \
      --ref origin/main --pin "$PIN" --self "$(harness_at "$C1")" --re-seed 2>&1)"; RC=$?
lane_alive "$LANEPID" && ok "the live lane was NOT signalled under a narrow COLUMNS" \
                     || bad "a COLUMNS-truncated lane count let the re-seed kill lane $LANEPID"
[ "$RC" = 26 ] && ok "exit 26 — a lane invisible only because of COLUMNS still refuses the destructive advance" \
                || bad "exit $RC, expected 26 — a truncated table let --re-seed through: $R"
case "$R" in *lanes=1*) ok "the lane is still counted with COLUMNS=20 — the table read is width-independent" ;;
             *lanes=0*) bad "COLUMNS truncated the process table and hid a LIVE lane (lanes=0) — the #2926 defect" ;;
             *) bad "no lane count in the record: $R" ;; esac
reap "$LANEPID"

_CASE=$((_CASE+1)); echo "=== A23: the DESTRUCTIVE advance (--re-seed) under a mid-turn lane -> REFUSES 26, names what blocks it ==="
D="$T/a23"; mkdir -p "$D/pin" "$D/O"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
printf '%s\n' "$$" > "$D/O/.orch.lock"
LANEPID="$(mk_fake_lane "$D/O")"
MAT="$(mk_stub_mat "$D")"
R="$(O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" --re-seed 2>&1)"; RC=$?
[ "$RC" = 26 ] && ok "exit 26 (refused blocked) — a re-seed under live work is not an accident that can happen" \
               || bad "exit $RC, expected 26 — output: $R"
lane_alive "$LANEPID" && ok "the lane process is still alive after the refusal" || bad "the run killed the lane while refusing"
[ "$(pin_of "$PIN")" = "$C1" ] && ok "the pin was NOT advanced (nothing was touched)" || bad "pin moved to '$(pin_of "$PIN")'"
[ ! -f "$D/mat.calls" ] && ok "the materialiser was never called" || bad "a refused run still called the materialiser"
case "$R" in *"$LANEPID"*) ok "the refusal NAMES the in-flight lane pid" ;; *) bad "the blocker is unnamed: $R" ;; esac
case "$R" in *"WITHOUT --re-seed"*) ok "…and gives the non-destructive remedy" ;; *) bad "no remedy offered: $R" ;; esac
# ⛔ AND THE REMEDY MUST BE TRUE FOR THIS BOX (review finding): with the pin ALREADY at the tip, "re-run
# WITHOUT --re-seed and the pin moves" is false — that path is a no-op. The clause is chosen from the fact.
D2="$T/a23b"; mkdir -p "$D2/pin" "$D2/O"; PIN2="$D2/pin/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN2"
printf '%s\n' "$$" > "$D2/O/.orch.lock"
MAT2="$(mk_stub_mat "$D2")"
R2="$(O="$D2/O" HARNESS_MATERIALISER="$MAT2" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN2" --self "$(harness_at "$C1")" --re-seed 2>&1)"; RC2=$?
[ "$RC2" = 26 ] && ok "a re-seed under a live controller refuses 26 even when the pin is at the tip" || bad "exit $RC2, expected 26 — output: $R2"
case "$R2" in *"the pin moves to"*) bad "the remedy predicts a pin move that cannot happen (the pin already names the tip)" ;; *) ok "…and the remedy does NOT promise a pin move that cannot happen" ;; esac
case "$R2" in *"--force"*) ok "…it names the override that does re-seed" ;; *) bad "no true remedy named: $R2" ;; esac
# ⛔ AND THE DISCRIMINATOR IS THE DEPLOYED TREE (review finding): with the sha record at the tip but the PATH
# record naming an older tree, dropping the flag DOES advance the deployed tree — "nothing would change"
# would be a false remedy about the one action that repairs the box.
D3="$T/a23c"; mkdir -p "$D3/pin" "$D3/O"; PIN3="$D3/pin/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN3"
printf '%s\n' "$(dirname "$(harness_at "$C1")")" > "$D3/path-pin"
printf '%s\n' "$$" > "$D3/O/.orch.lock"
MAT3="$(mk_stub_mat "$D3")"
R3="$(O="$D3/O" HARNESS_PIN_FILE="$D3/path-pin" HARNESS_MATERIALISER="$MAT3" bash "$RR" --no-fetch \
       --repo "$T/src" --ref origin/main --pin "$PIN3" --self "$(harness_at "$C1")" --re-seed 2>&1)"; RC3=$?
[ "$RC3" = 26 ] && ok "a two-records-disagree box refuses 26 like any other live box" || bad "exit $RC3, expected 26 — output: $R3"
case "$R3" in *"nothing"*) bad "the remedy says nothing would change on a box whose DEPLOYED tree would advance" ;; *) ok "…and does not claim nothing would change (the deployed tree CAN advance)" ;; esac
case "$R3" in *"WITHOUT --re-seed"*|*"dropping the flag"*) ok "…it gives the remedy that really advances the deployed tree" ;; *) bad "no true remedy: $R3" ;; esac
# …and when the sha RECORD already names the tip (only the path record is stale), "the pin moves to <tip>" is
# false — what a flagless run advances is the deployed tree.
D6="$T/a23d"; mkdir -p "$D6/pin" "$D6/O"; PIN6="$D6/pin/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN6"
printf '%s\n' "$(dirname "$(harness_at "$C1")")" > "$D6/path-pin"
printf '%s\n' "$$" > "$D6/O/.orch.lock"
R7="$(O="$D6/O" HARNESS_PIN_FILE="$D6/path-pin" HARNESS_MATERIALISER="$(mk_stub_mat "$D6")" bash "$RR" --no-fetch \
       --repo "$T/src" --ref origin/main --pin "$PIN6" --self "$(harness_at "$C1")" --re-seed 2>&1)"; RC7=$?
[ "$RC7" = 26 ] && ok "a sha-record-at-tip box refuses 26 like any other live box" || bad "exit $RC7, expected 26 — output: $R7"
case "$R7" in *"the pin moves to"*) bad "the remedy promises a pin move the sha record already made" ;; *) ok "…and does not promise a pin move the record already made" ;; esac
case "$R7" in *"deployed tree"*) ok "…it names the deployed tree as what advances" ;; *) bad "the deployed tree is unnamed: $R7" ;; esac
reap "$LANEPID"

_CASE=$((_CASE+1)); echo "=== A24: --re-seed --force -> the deliberate override goes through (the gate is not a wall) ==="
D="$T/a24"; mkdir -p "$D/pin" "$D/O"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
printf '%s\n' "$$" > "$D/O/.orch.lock"
LANEPID="$(mk_fake_lane "$D/O")"
MAT="$(mk_stub_mat "$D")"
R="$(O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" --re-seed --force 2>&1)"; RC=$?
[ "$RC" = 10 ] && ok "exit 10 — --force is the deliberate re-seed" || bad "exit $RC, expected 10 — output: $R"
case "$(cat "$D/mat.calls" 2>/dev/null)" in *--pin-only*) bad "--re-seed --force still passed --pin-only" ;;
                                                 *) ok "the materialiser was called WITHOUT --pin-only (a real re-seed)" ;; esac
lane_alive "$LANEPID" && ok "even the forced re-seed signalled no lane" || bad "the forced re-seed killed the lane"
# ⛔ AND IT MUST NOT CLAIM NON-DESTRUCTION (review finding): a re-seed mirrors $O and removes lane scripts
# the harness does not ship, so "no lane tree was touched" would be false on THIS arm.
case "$R" in *"no lane tree was touched"*) bad "the re-seed arm claims no lane tree was touched (it re-seeds \$O)" ;; *) ok "…and does not claim the lane tree was untouched" ;; esac
case "$R" in *"RE-SEEDED"*) ok "…it discloses that \$O was re-seeded" ;; *) bad "the re-seed is not disclosed on the kept line: $R" ;; esac
reap "$LANEPID"

_CASE=$((_CASE+1)); echo "=== A25: the controller and the launcher's log path are NOT lanes (token match, not substring) ==="
D="$T/a25"; mkdir -p "$D/pin" "$D/O/logs"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
# The real tmux launcher's argv names `$O/logs/orch-loop.log`; a substring match counts it as a lane on
# EVERY cycle, which would make `lanes=N` a permanent lie and the refusal permanent.
# ⛔ THE PLANTS MUST SURVIVE WITH THE TOKEN IN THEIR ARGV (review finding: `sleep 30 <path>` DIES — sleep
# rejects the extra operand — and `bash -c 'sleep 30' <arg>` leaves the arg in the shell's argv, which a
# `command=`-shaped read can lose. Both plants were dead/unnamed, so `lanes=0` held no matter HOW the
# token was matched and neither guard was tested). `bash -c … <name> <token>` keeps the token in argv of
# a live process, and the assertions below prove it is visible to `ps` before the refresh runs.
# ⛔ `sleep 30; :` — a bare `sleep 30` would be EXEC'd by bash as the last command, and the argv (with
# the token) would be replaced by `sleep 30`, which is how the earlier plants lost their token.
bash -c 'sleep 30; :' orc-log "$D/O/logs/orch-loop.log" >/dev/null 2>&1 & LOGCALLER=$!
bash -c 'sleep 30; :' orc-ctl "$D/O/orch-loop.sh" >/dev/null 2>&1 & CTLPID=$!
# …and a `.sh` in a SUBDIRECTORY of $O: a lane is `$O/<name>.sh`, so the subdirectory guard (not the
# `.sh` suffix) is what excludes it — without the plant, that guard is untested and removing it is green.
bash -c 'sleep 30; :' orc-sub "$D/O/logs/helper.sh" >/dev/null 2>&1 & SUBPID=$!
sleep 1
_ps_now="$(ps -eo command= 2>/dev/null)"
case "$_ps_now" in *"$D/O/logs/orch-loop.log"*) ok "the log-path plant is ALIVE with its \$O/logs/… token in argv" ;; *) bad "the log-path plant never carried the token — this case would pass vacuously" ;; esac
case "$_ps_now" in *"$D/O/orch-loop.sh"*) ok "the controller plant is ALIVE with its \$O/orch-loop.sh token in argv" ;; *) bad "the controller plant never carried the token — this case would pass vacuously" ;; esac
case "$_ps_now" in *"$D/O/logs/helper.sh"*) ok "…and a subdirectory .sh plant carries its token too" ;; *) bad "the subdirectory-.sh plant never carried the token" ;; esac
MAT="$(mk_stub_mat "$D")"
R="$(O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
case "$R" in *lanes=0*) ok "lanes=0 — the controller and a \$O/logs/… path are not counted" ;; *) bad "false lane count: $R" ;; esac
[ "$RC" = 10 ] && ok "…and the advance still happened" || bad "exit $RC, expected 10"
kill "$LOGCALLER" "$CTLPID" "$SUBPID" 2>/dev/null || true

_CASE=$((_CASE+1)); echo "=== A26: the resolved dir the controller reads matches the new pin (REAL materialiser) ==="
# Driven through `cloud-cell-supervisor.sh apply --pin-only` — the ONE engine allowed to materialise a
# pin — not a stub, because the claim under test is exactly "the pin names a tree that EXISTS and whose
# HEAD is the pinned commit". A stub would assert its own opinion instead.
SUP="$HERE/../cloud-cell-supervisor.sh"
if [ -f "$SUP" ]; then
  D="$T/a26"; mkdir -p "$D/pinroot" "$D/O" "$D/cellhome"; : > "$D/env"
  PIN="$D/cellhome/.pi/agent/state/HARNESS-PIN"; mkdir -p "$(dirname "$PIN")"; printf '%s\n' "$C1" > "$PIN"
  R="$(unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; \
        O="$D/O" CELL_HOME="$D/cellhome" HOME="$D/cellhome" HARNESS_REPO="$T/src" \
        HARNESS_PIN_DIR="$D/pinroot" HARNESS_PIN_FILE="$D/pinroot/HARNESS-PIN" ENV_FILE="$D/env" \
        HARNESS_MATERIALISER="$SUP" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
          --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
  [ "$RC" = 10 ] && ok "exit 10 through the real materialiser" || bad "exit $RC, expected 10 — output: $R"
  [ "$(pin_of "$PIN")" = "$C2" ] && ok "the sha record names the new pin" || bad "sha record is '$(pin_of "$PIN")'"
  RESOLVED="$(head -1 "$D/pinroot/HARNESS-PIN" 2>/dev/null)"
  if [ -n "$RESOLVED" ] && [ -d "$RESOLVED" ]; then
    ok "the path the controller reads resolves to a REAL tree ($RESOLVED)"
    [ "$(git -C "$RESOLVED" rev-parse HEAD 2>/dev/null)" = "$C2" ] \
      && ok "…and that tree's HEAD IS the pinned commit (the pin is not a sha with no tree behind it)" \
      || bad "the resolved tree's HEAD is '$(git -C "$RESOLVED" rev-parse HEAD 2>/dev/null)', expected $C2"
  else
    bad "HARNESS_PIN_FILE does not name an existing tree: '$RESOLVED'"
  fi
  [ "$(git -C "$(harness_at "$C1")/../.." rev-parse HEAD 2>/dev/null)" = "$C1" ] \
    && ok "the tree the controller was RUNNING is still at $C1 — untouched" \
    || bad "the running tree moved: $(git -C "$(harness_at "$C1")/../.." rev-parse HEAD 2>/dev/null)"
else
  bad "missing $SUP — cannot drive the real materialiser"
fi

_CASE=$((_CASE+1)); echo "=== A27: a hand-launched PIN-PER-COMMIT cell auto-resolves its materialiser (the measured blocker) ==="
# MEASURED 2026-10-21: the controller's env carried HARNESS_PIN_DIR/HARNESS_PIN_FILE/CELL_HOME and NO
# HARNESS_MATERIALISER (started by hand, not by `start`, which exports it) — so EVERY cycle exited 25
# `unmaterialised` and the pin could never advance, however often the refresh ran. That is the five-hour
# undeployed fix, and the reason it looked like a kill problem: nobody could run the advance, so nobody
# could watch it not kill. This case drives the posture-scoped resolution that fixes it.
# The fixture repo gets the REAL supervisor in its scripts/ (the file the auto arm looks for).
git -C "$T/src" worktree add --detach "$T/src-cell" "$C2" >/dev/null 2>&1
cp "$HERE/../cloud-cell-supervisor.sh" "$T/src-cell/scripts/cloud-cell-supervisor.sh" 2>/dev/null || true
if [ -f "$T/src-cell/scripts/cloud-cell-supervisor.sh" ]; then
  D="$T/a27"; mkdir -p "$D/pinroot" "$D/O" "$D/cellhome"; : > "$D/env"
  PIN="$D/cellhome/.pi/agent/state/HARNESS-PIN"; mkdir -p "$(dirname "$PIN")"; printf '%s\n' "$C1" > "$PIN"
  R="$(O="$D/O" CELL_HOME="$D/cellhome" HOME="$D/cellhome" \
        HARNESS_PIN_DIR="$D/pinroot" HARNESS_PIN_FILE="$D/pinroot/HARNESS-PIN" ENV_FILE="$D/env" \
        bash "$RR" --no-fetch --repo "$T/src-cell" --ref origin/main --pin "$PIN" \
          --self "$(harness_at "$C1")" 2>&1)"; RC=$?
  [ "$RC" = 10 ] && ok "exit 10 — ADVANCED, not 25: a hand-launched cell is no longer stuck unmaterialised for ever" \
                 || bad "exit $RC, expected 10 — the measured five-hour blocker is NOT fixed: $R"
  case "$R" in *"auto:pin-per-commit-cell"*) ok "…and it names the posture it resolved from, rather than reading as configured" ;;
              *) bad "the auto-resolution is undisclosed: $R" ;; esac
  [ "$(pin_of "$PIN")" = "$C2" ] && ok "the pin really moved to the tip" || bad "pin is '$(pin_of "$PIN")'"
  # ⛔ AND IT DOES NOT RESOLVE ON A LAPTOP: the SAME repo (an ambient supervisor script in scripts/),
  # without the cell posture — no HARNESS_PIN_FILE, no CELL_HOME — must still be exit 25.
  D="$T/a27b"; mkdir -p "$D/O" "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
  R="$(O="$D/O" HOME="$T/a27b-home" bash "$RR" --no-fetch --repo "$T/src-cell" --ref origin/main \
        --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
  [ "$RC" = 25 ] && ok "without cell posture it is STILL unmaterialised (exit 25) — no ambient-script licence" \
                 || bad "exit $RC: an ambient supervisor script licensed a cell verb without the cell posture"
else
  bad "could not place the supervisor in the fixture repo"
fi

_CASE=$((_CASE+1)); echo "=== A29: pin already current + a lane MID-TURN -> exit 0, NOTHING restarted, lane untouched ==="
# THE SAFE-TO-RUN-EVERY-CYCLE PROPERTY, asserted with a live lane present: a current pin is a no-op that
# exits 0. This is the case that makes the per-cycle schedule in orch-loop.sh affordable, and the one a
# refresh that "advances unconditionally" would break (see the mutation note in the PR body).
D="$T/a29"; mkdir -p "$D/pin" "$D/O"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN"
printf '%s\n' "$$" > "$D/O/.orch.lock"
LANEPID="$(mk_fake_lane "$D/O")"
MAT="$(mk_stub_mat "$D")"
R="$(O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C2")" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "exit 0 (current is a no-op)" || bad "exit $RC, expected 0 — output: $R"
[ ! -f "$D/mat.calls" ] && ok "nothing was materialised, so nothing was restarted" || bad "a current pin still re-deployed"
[ "$(pin_of "$PIN")" = "$C2" ] && ok "the pin is unchanged" || bad "the pin moved to '$(pin_of "$PIN")'"
lane_alive "$LANEPID" && ok "the in-flight lane is untouched" || bad "a no-op refresh killed a lane"
case "$R" in *action=none*) ok "record: action=none (nothing was done, and it says so)" ;; *) bad "record wrong: $R" ;; esac
case "$R" in *lanes=1*) ok "…and it still discloses the lane that was in flight" ;; *) bad "no lane disclosure: $R" ;; esac
reap "$LANEPID"

_CASE=$((_CASE+1)); echo "=== A28: a DIRTY harness surface refuses AND discards nothing (the operator's patch survives) ==="
D="$T/a28"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
git -C "$T/src" worktree add --detach "$T/src-dirty2" "$C2" >/dev/null 2>&1
printf '%s\n' '# a live-tested patch that exists only as a working-tree edit' >> "$T/src-dirty2/scripts/orchestrator-harness/orch-loop.sh"
BEFORE_HEAD="$(git -C "$T/src-dirty2" rev-parse HEAD)"
MAT="$(mk_stub_mat "$D")"
R="$(O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src-dirty2" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
[ "$RC" = 20 ] && ok "exit 20 (refused dirty)" || bad "exit $RC, expected 20 — output: $R"
case "$R" in *orch-loop.sh*) ok "the refusal names the offending file" ;; *) bad "the file list is missing: $R" ;; esac
case "$R" in *"uncommitted change"*) ok "…and the count, so the operator knows the size of it" ;; *) bad "no count: $R" ;; esac
grep -q 'live-tested patch' "$T/src-dirty2/scripts/orchestrator-harness/orch-loop.sh" 2>/dev/null \
  && ok "the working-tree edit is STILL THERE (nothing was discarded)" \
  || bad "the refusal DISCARDED the operator's patch"
[ "$(git -C "$T/src-dirty2" rev-parse HEAD)" = "$BEFORE_HEAD" ] && ok "…and no commit was created or moved" || bad "HEAD moved during a dirty refusal"
[ ! -f "$D/mat.calls" ] && ok "…and nothing was materialised or re-seeded" || bad "a dirty refusal still delegated"

# ⛔ A RE-SEED WITH NO `$O` MUST STILL PRODUCE ONE ACTIONABLE LINE (review finding). The refusal used to
# interpolate a COMMAND SUBSTITUTION (`ps` in backticks) into its own message, so in the exact state a
# laptop or a hand-fired refresh hits — `$O` unset — it spliced the whole process table (hundreds of
# lines) into the single line the refusal exists to be. The arm is only reachable from a case that
# supplies NO lane with `$O` ABSENT (A23 always sets `O`), which is why it had no test before.
_CASE=$((_CASE+1)); echo "=== A30: --re-seed with \$O UNSET -> exit 26 AND one short line (no ps dump in its own message) ==="
D="$T/a30"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
MAT="$(mk_stub_mat "$D")"
R="$(env -u O HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" --re-seed 2>&1)"; RC=$?
[ "$RC" = 26 ] && ok "exit 26 (cannot-verify the in-flight set is not a pass)" || bad "exit $RC, expected 26 — output: $R"
case "$R" in *"cannot be read"*) ok "the refusal says the in-flight set cannot be read" ;; *) bad "the blocker is unnamed: $R" ;; esac
case "$R" in *"PID TTY"*|*"CMD"*) bad "the refusal embedded a process-table dump (a backticked command ran in its message)" ;; *) ok "…and did NOT execute anything into its own message" ;; esac
_NPROSE="$(printf '%s\n' "$R" | awk '!/^harness relation=/ && NF' | wc -l | tr -d ' ')"
[ "$_NPROSE" -le 2 ] && ok "…so the refusal is $_NPROSE prose line(s), not a dump" || bad "the refusal is $_NPROSE prose lines — a message, not a process table"
[ ! -f "$D/mat.calls" ] && ok "the materialiser was never called" || bad "a refused re-seed still delegated"

_CASE=$((_CASE+1)); echo "=== A31: --re-seed on an ALREADY-CURRENT pin -> it RE-SEEDS (not a silent exit 0) ==="
# THE STATE THIS SCRIPT CREATES ON EVERY ADVANCE: pin == tip, `$O` still on the old tree. `--re-seed` is
# the one flag that re-seeds `$O` from the pin, and the current-pin short-circuit used to swallow it and
# answer `action=none` exit 0 — a requested state change reported as success without being performed.
D="$T/a31"; mkdir -p "$D/pin" "$D/O"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN"
MAT="$(mk_stub_mat "$D")"
R="$(O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C2")" --re-seed 2>&1)"; RC=$?
[ "$RC" = 10 ] && ok "exit 10 (a re-seed is an action, not a no-op)" || bad "exit $RC, expected 10 — output: $R"
case "$(cat "$D/mat.calls" 2>/dev/null)" in *--pin-only*) bad "a re-seed passed --pin-only (that is NOT a re-seed)" ;; *apply*) ok "the materialiser WAS called, WITHOUT --pin-only (a real re-seed)" ;; *) bad "the re-seed never reached the materialiser: $(cat "$D/mat.calls" 2>/dev/null)" ;; esac
case "$R" in *action=repinned*) bad "a re-seed that moved NO pin is recorded as a re-pin (a pin advance that did not happen)" ;; *action=reseeded*) ok "the record distinguishes a re-seed (action=reseeded) from a pin advance" ;; *) bad "the re-seed is still recorded as a no-op: $R" ;; esac
# ⛔ AND THE PROSE MUST NOT CONTRADICT THE MACHINE LINE (review finding). With `--self` at the tip the
# running controller IS on the pin, so "restart-pending, not current" beside `relation=current` is a
# self-contradicting verdict, and "records the new sha" claims a move that did not happen.
case "$R" in *"RESEEDED:"*) ok "the verdict names the action it took (RESEEDED)" ;; *) bad "the verdict does not name the re-seed: $R" ;; esac
case "$R" in *"pin did NOT move"*) ok "…and says the pin did not move" ;; *) bad "the pin-move claim is missing: $R" ;; esac
case "$R" in *"records the new sha"*) bad "a re-seed claims a NEW sha it did not write" ;; *) ok "…and does not claim to have written a new sha" ;; esac
case "$R" in *"restart-pending, not current"*) bad "a re-seed beside relation=current still says 'restart-pending, not current'" ;; *) ok "…and does not contradict its own relation line" ;; esac

_CASE=$((_CASE+1)); echo "=== A33: --re-seed with a STALE/EMPTY pin does not get swallowed by the MEND arm ==="
# `REL = current` is reachable with an empty pin record (the PR's own measured fleet state). The mend arm
# ran BEFORE the flag was looked at, so `--re-seed` was recorded as a quiet `action=mended` exit 11 with
# the materialiser never called — the flag silently dropped again, one arm over from A31.
D="$T/a33"; mkdir -p "$D/pin" "$D/O"; PIN="$D/pin/HARNESS-PIN"; : > "$PIN"
MAT="$(mk_stub_mat "$D")"
R="$(O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C2")" --re-seed 2>&1)"; RC=$?
[ "$RC" = 10 ] && ok "exit 10 — the flag reached the materialiser, not a quiet mend (11)" || bad "exit $RC, expected 10 — output: $R"
case "$(cat "$D/mat.calls" 2>/dev/null)" in *apply*) ok "the materialiser WAS called (the re-seed was not dropped)" ;; *) bad "the re-seed was never performed: $(cat "$D/mat.calls" 2>/dev/null)" ;; esac
[ "$(pin_of "$PIN")" = "$C2" ] && ok "…and the pin now names the tip (the mend is not lost by falling through)" || bad "pin is '$(pin_of "$PIN")'"
case "$R" in *action=repinned*) ok "the pin DID move (empty -> tip), so action=repinned is the truthful one" ;; *) bad "a real pin move is not recorded as repinned: $R" ;; esac

case "$R" in *"$(short "$C2") == $(short "$C2")"*) ok "…and the separator is == because the deployed tree did not move" ;; *) bad "the verdict does not use == for an unmoved deployed tree: $R" ;; esac
case "$R" in *"$(short "$C2") -> $(short "$C2")"*) bad "an arrow between two IDENTICAL commits" ;; *) ok "…and never draws an arrow between identical shas" ;; esac

# …and the STALE-pin mend (RESEED=0) must report ONE sha, never the short one concatenated with the full
# one — the corrupt `was 3efaead5178433efaead517…` this line used to print in the operator-facing record.
# Reachable exactly as a cell reaches it: the PATH record ($HARNESS_PIN_FILE) names a tree at the tip, so
# REL is `current`, while the sha record still names an older commit — the mend arm, with a STALE value.
# (A stale `--pin` with NO path record is `behind`, which is the advance arm, not the mend.)
printf '%s\n' "$C1" > "$PIN"
printf '%s\n' "$(dirname "$(harness_at "$C2")")" > "$D/harness-path"
MAT2="$(mk_stub_mat "$D/m2")"
R2="$(O="$D/O" HARNESS_PIN_FILE="$D/harness-path" HARNESS_MATERIALISER="$MAT2" bash "$RR" --no-fetch \
       --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C2")" 2>&1)"; RC2=$?
[ "$RC2" = 11 ] && ok "a stale sha record MENDs to the tip the path record names (exit 11)" || bad "exit $RC2, expected 11 — output: $R2"
case "$R2" in *"was ${C1:0:12};"*) ok "the mend names the previous record as ONE sha" ;; *) bad "the mend does not name one previous sha: $R2" ;; esac
case "$R2" in *"was ${C1:0:12}${C1}"*) bad "the mend concatenated the short sha with the full sha" ;; *) ok "…and never prints the short and full sha concatenated" ;; esac

_CASE=$((_CASE+1)); echo "=== A34: --re-seed with the TWO PIN RECORDS DISAGREEING -> the ADVANCE is recorded as one (REAL materialiser) ==="
# A pin is TWO records and they can disagree (#2216's measured shape, and `harness-up:41-46` exists
# because of it): the sha record names the tip while the PATH record still names the older tree. `apply`
# rewrites the path record, so the deployed tree DOES move — and keying the verdict to the sha record
# alone recorded that real advance as "reseeded / nothing moved" and printed `c1 == c2`, an equality
# between two different commits, in the line the controller writes to `$LOG`.
SUP34="$HERE/../cloud-cell-supervisor.sh"
if [ -f "$SUP34" ]; then
  D="$T/a34"; mkdir -p "$D/pinroot" "$D/O" "$D/cellhome"; : > "$D/env"
  PIN="$D/cellhome/.pi/agent/state/HARNESS-PIN"; mkdir -p "$(dirname "$PIN")"
  printf '%s\n' "$C2" > "$PIN"                                                   # sha record: the tip
  # The PATH record lives OUTSIDE the pin root: the supervisor refuses a pin dir that holds a stray
  # 'HARNESS-PIN' entry ("not a pin directory"), which is its own guard, not this case's subject.
  printf '%s\n' "$(dirname "$(harness_at "$C1")")" > "$D/path-pin"                # path record: the OLD tree
  R="$(unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; \
        O="$D/O" CELL_HOME="$D/cellhome" HOME="$D/cellhome" HARNESS_REPO="$T/src" \
        HARNESS_PIN_DIR="$D/pinroot" HARNESS_PIN_FILE="$D/path-pin" ENV_FILE="$D/env" \
        HARNESS_MATERIALISER="$SUP34" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
          --pin "$PIN" --self "$(harness_at "$C1")" --re-seed 2>&1)"; RC=$?
  RESOLVED34="$(head -1 "$D/path-pin" 2>/dev/null)"
  [ "$RC" = 10 ] && ok "exit 10 through the real materialiser" || bad "exit $RC, expected 10 — output: $R"
  [ "$(git -C "${RESOLVED34:-/nonexistent}" rev-parse HEAD 2>/dev/null)" = "$C2" ] \
    && ok "the PATH record moved onto the tip tree (the deployed commit really advanced)" \
    || bad "the path record is '${RESOLVED34:-none}' — the advance did not happen"
  case "$R" in *action=repinned*) ok "…and the record calls that an ADVANCE (action=repinned)" ;;
                *action=reseeded*) bad "a real advance was filed as 'nothing moved' (action=reseeded)" ;;
                *) bad "unexpected action: $R" ;; esac
  case "$R" in *"${C1:0:12} -> ${C2:0:12}"*) ok "the verdict draws the real move (<c1> -> <c2>)" ;; *) bad "the move is not named: $R" ;; esac
  case "$R" in *"${C1:0:12} == ${C2:0:12}"*) bad "the verdict asserts EQUALITY between two different commits" ;; *) ok "…and never asserts equality between two different commits" ;; esac
else
  bad "missing $SUP34 — cannot drive the real materialiser"
fi

_CASE=$((_CASE+1)); echo "=== A35: --re-seed on a BEHIND box with NO materialiser is REFUSED, not answered by the behind verdict ==="
# The refusal used to be guarded by `[ "$REL" = current ]`, so a behind laptop answered `--re-seed` with
# the ordinary behind/unmaterialised verdict (exit 25) and never said the flag was not performed.
D="$T/a35"; mkdir -p "$D/pin" "$D/O"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
R="$(env -u HARNESS_MATERIALISER O="$D/O" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" --re-seed 2>&1)"; RC=$?
[ "$RC" = 23 ] && ok "exit 23 (refused), not 25 — the flag cannot be carried out, so it is not a 'behind' verdict" \
               || bad "exit $RC, expected 23 — output: $R"
case "$R" in *"--re-seed"*) ok "the refusal NAMES the flag it did not perform" ;; *) bad "the flag is unmentioned: $R" ;; esac
case "$R" in *action=unmaterialised*) bad "a requested re-seed is still recorded as a plain unmaterialised box" ;; *) ok "…and it is not recorded as a plain behind/unmaterialised cycle" ;; esac
# ⛔ THE RECORD MUST SAY WHAT IS (review finding): `relation` is the authoritative freshness field, so a
# refusal that computed `behind` may not stamp `unknown` while the prose on the same line names it.
case "$R" in *"relation=behind"*) ok "…and the record keeps the relation it computed (relation=behind, not unknown)" ;; *) bad "the refusal stamped a relation it did not compute: $R" ;; esac
case "$R" in *"relation=unknown"*) bad "cannot-verify is recorded about a relation the script established" ;; *) ok "…and does not claim cannot-verify about it" ;; esac
# …and the PROSE must not assert a pin the record does not hold (review finding): `relation=current` with
# `pin=none` is a real row (empty sha record, deployed tree IS the tip).
D4="$T/a35b"; mkdir -p "$D4/pin" "$D4/O"; PIN4="$D4/pin/HARNESS-PIN"; : > "$PIN4"
R4="$(env -u HARNESS_MATERIALISER O="$D4/O" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN4" --self "$(harness_at "$C2")" --re-seed 2>&1)"; RC4=$?
[ "$RC4" = 23 ] && ok "an empty sha record + a deployed tip refuses a re-seed too" || bad "exit $RC4, expected 23 — output: $R4"
case "$R4" in *"The pin record already names"*) bad "the refusal claims a pin record that is empty (pin=none)" ;; *) ok "…and does not claim the empty record already names the tip" ;; esac
case "$R4" in *"Nothing is recorded"*) ok "…it says the record is empty and the deployed tree is the tip" ;; *) bad "the empty-record state is unnamed: $R4" ;; esac
# ⛔ A STALE RECORD WITH A CURRENT DEPLOYMENT IS A THIRD STATE (review finding): the record HOLDS a sha, so
# "Nothing is recorded" is false — and the truthful, actionable fact is that a flagless run MINDS it.
D5="$T/a35c"; mkdir -p "$D5/pin" "$D5/O"; PIN5="$D5/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN5"
printf '%s\n' "$(dirname "$(harness_at "$C2")")" > "$D5/path-pin"
R5="$(env -u HARNESS_MATERIALISER O="$D5/O" HARNESS_PIN_FILE="$D5/path-pin" bash "$RR" --no-fetch \
       --repo "$T/src" --ref origin/main --pin "$PIN5" --self "$(harness_at "$C2")" --re-seed 2>&1)"; RC5=$?
[ "$RC5" = 23 ] && ok "a stale record + current deployment refuses a re-seed" || bad "exit $RC5, expected 23 — output: $R5"
case "$R5" in *"Nothing is recorded"*) bad "the refusal says nothing is recorded about a record that HOLDS a sha" ;; *) ok "…and does not claim the record is empty" ;; esac
case "$R5" in *"STALE"*) ok "…it names the record as stale and the mend as the remedy" ;; *) bad "the stale record is unnamed: $R5" ;; esac
# …and the same state under a LIVE controller must not say a flagless run "would change nothing".
printf '%s\n' "$$" > "$D5/O/.orch.lock"
R6="$(O="$D5/O" HARNESS_PIN_FILE="$D5/path-pin" HARNESS_MATERIALISER="$(mk_stub_mat "$D5")" bash "$RR" --no-fetch \
       --repo "$T/src" --ref origin/main --pin "$PIN5" --self "$(harness_at "$C2")" --re-seed 2>&1)"; RC6=$?
[ "$RC6" = 26 ] && ok "…and with a controller live it refuses 26" || bad "exit $RC6, expected 26 — output: $R6"
case "$R6" in *"change nothing"*) bad "the remedy says a flagless run would change nothing, on a box where it MINDS the record" ;; *) ok "…and does not claim a flagless run would change nothing" ;; esac
case "$R6" in *"mend"*) ok "…it names the mend" ;; *) bad "the mend is unnamed: $R6" ;; esac
case "$R6" in *"${C1:0:12}${C1}"*) bad "the remedy concatenated the short sha with the full sha" ;; *) ok "…and prints ONE sha, never short+full concatenated" ;; esac
R2="$(env -u HARNESS_MATERIALISER O="$D/O" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC2=$?
[ "$RC2" = 25 ] && ok "WITHOUT the flag the box still reports behind/unmaterialised (25) — the refusal did not change the ordinary verdict" \
                || bad "exit $RC2, expected 25 without --re-seed"

_CASE=$((_CASE+1)); echo "=== A32: the controller's ONE retained line still carries REPINNED + the materialiser ==="
# orch-loop.sh keeps only the LAST non-record line and writes it to `$LOG`. A second prose line after the
# verdict DISPLACES it, so the old->new sha, the materialiser path and the auto-resolution disclosure
# never reach the file an operator reads. This pins the single-line contract at the consumer's own filter.
D="$T/a32"; mkdir -p "$D/pin" "$D/O"; PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"
LANEPID="$(mk_fake_lane "$D/O")"
MAT="$(mk_stub_mat "$D")"
R="$(O="$D/O" HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
KEPT="$(printf '%s\n' "$R" | awk '!/^harness relation=/ && NF' | tail -1)"
case "$KEPT" in *REPINNED*) ok "the line the loop KEEPS is the verdict" ;; *) bad "the loop would log something else: $KEPT" ;; esac
case "$KEPT" in *"${C1:0:12} -> ${C2:0:12}"*) ok "…and it carries old -> new" ;; *) bad "old -> new is not in the kept line: $KEPT" ;; esac
case "$KEPT" in *"$MAT"*) ok "…and the materialiser that did it" ;; *) bad "the materialiser is not in the kept line: $KEPT" ;; esac
case "$KEPT" in *"lane process(es)"*|*lanes=*) ok "…and what was in flight (the disclosure survives the filter)" ;; *) bad "the lane disclosure is not in the kept line: $KEPT" ;; esac
case "$KEPT" in *'\$O'*) bad "the kept line prints a literal backslash-\$O" ;; *) ok "…with no literal backslash in the operator-facing text" ;; esac
reap "$LANEPID"

# ── the loop's per-cycle block, driven as shipped ────────────────────────────────────────────────
# Placed INSIDE a scripts/orchestrator-harness/ path in the sandbox so the block's own fallback
# lookup (beside the loop) cannot reach the real harness: each case decides what exists.
BLK="$T/blk/scripts/orchestrator-harness"
mkdir -p "$BLK"
sed -n '/# BEGIN harness-refresh/,/# END harness-refresh/p' "$LOOP" | sed '1d;$d' > "$BLK/block.sh"
[ -s "$BLK/block.sh" ] && grep -q 'harness_refresh_cycle()' "$BLK/block.sh" \
  && ok "the per-cycle block is extracted VERBATIM from the shipped loop" \
  || bad "the harness-refresh block is missing or does not parse"

_CASE=$((_CASE+1)); echo "=== B1: once per cycle, the refusal is logged, and the token is recorded ==="
D="$T/b1"; mkdir -p "$D/O/state" "$D/O/logs"
cat > "$D/O/harness-refresh.sh" <<'SH'
#!/bin/bash
echo "call" >> "$(dirname "$0")/calls"
echo "harness relation=behind running=111111111111 ref=222222222222 pin=111111111111 action=refused"
echo "REFUSE behind: stubbed"
exit 25
SH
chmod +x "$D/O/harness-refresh.sh"
(
  O="$D/O"; LOG="$D/O/logs/orch-loop.log"; HARNESS_REF=origin/main; : > "$LOG"
  . "$BLK/block.sh"
  harness_refresh_cycle
  printf 'T1=%s\n' "$HARNESS_TOKEN" > "$D/t1"
  harness_refresh_cycle            # SAME cycle: must be a no-op
)
[ "$(grep -c '^call' "$D/O/calls" 2>/dev/null)" = 1 ] \
  && ok "a second call in the same cycle does NOT refresh again (once per cycle)" \
  || bad "the refresh ran $(grep -c '^call' "$D/O/calls" 2>/dev/null || echo 0) times in one cycle"
[ "$(cat "$D/t1")" = "T1=behind:111111111111" ] \
  && ok "the spawn-line token is <relation>:<running-sha> when behind" \
  || bad "token was '$(cat "$D/t1")', expected T1=behind:111111111111"
grep -q 'REFUSE behind' "$D/O/logs/orch-loop.log" \
  && ok "the refusal is written to \$LOG (the file an operator reads)" \
  || bad "the refusal never reached \$LOG"
grep -q 'relation=behind.*action=refused' "$D/O/state/harness-refresh" 2>/dev/null \
  && ok "the per-cycle verdict is recorded for later readers (status, diagnosis)" \
  || bad "no usable state/harness-refresh record was written"

_CASE=$((_CASE+1)); echo "=== B2: current -> an EMPTY token (a token that is always present is a token nobody reads) ==="
D="$T/b2"; mkdir -p "$D/O/state" "$D/O/logs"
cat > "$D/O/harness-refresh.sh" <<'SH'
#!/bin/bash
echo "harness relation=current running=333333333333 ref=333333333333 pin=333333333333 action=none"
echo "harness current: 333333333333 == origin/main — pin already names it"
exit 0
SH
chmod +x "$D/O/harness-refresh.sh"
(
  O="$D/O"; LOG="$D/O/logs/orch-loop.log"; HARNESS_REF=origin/main; : > "$LOG"
  . "$BLK/block.sh"; harness_refresh_cycle; printf 'T=%s\n' "$HARNESS_TOKEN" > "$D/tok"
)
[ "$(cat "$D/tok")" = "T=" ] && ok "no token when the box is current" || bad "token was '$(cat "$D/tok")'"
grep -q 'harness current' "$D/O/logs/orch-loop.log" \
  && ok "…but the cycle still records that it checked (an unobservable gate is not a gate)" \
  || bad "a current cycle logged nothing"

_CASE=$((_CASE+1)); echo "=== B3: an ABSENT refresh script is CANNOT-VERIFY, never current ==="
D="$T/b3"; mkdir -p "$D/O/state" "$D/O/logs"
(
  O="$D/O"; LOG="$D/O/logs/orch-loop.log"; HARNESS_REF=origin/main; : > "$LOG"
  . "$BLK/block.sh"; harness_refresh_cycle; printf 'T=%s\n' "$HARNESS_TOKEN" > "$D/tok"
)
[ "$(cat "$D/tok")" = "T=unknown" ] && ok "the token is 'unknown', not empty" || bad "token was '$(cat "$D/tok")'"
grep -q 'CANNOT-VERIFY' "$D/O/logs/orch-loop.log" && ok "the absence is named in the log" || bad "silent absence"

_CASE=$((_CASE+1)); echo "=== B4: HARNESS_REFRESH=off is loud about what it gives up ==="
D="$T/b4"; mkdir -p "$D/O/state" "$D/O/logs"
printf '#!/bin/bash\necho call >> "$(dirname "$0")/calls"\nexit 0\n' > "$D/O/harness-refresh.sh"
chmod +x "$D/O/harness-refresh.sh"
(
  O="$D/O"; LOG="$D/O/logs/orch-loop.log"; HARNESS_REF=origin/main; HARNESS_REFRESH=off; : > "$LOG"
  . "$BLK/block.sh"; harness_refresh_cycle; printf 'T=%s\n' "$HARNESS_TOKEN" > "$D/tok"
)
[ "$(cat "$D/tok")" = "T=refresh-off" ] && ok "the token says the refresh is off, so a spawn line can still disclose it" \
  || bad "token was '$(cat "$D/tok")'"
[ ! -f "$D/O/calls" ] && ok "it did not run the refresher" || bad "it ran the refresher despite being off"
grep -qi 'DISABLED' "$D/O/logs/orch-loop.log" && ok "and says so, once per cycle" || bad "the kill switch was silent"

_CASE=$((_CASE+1)); echo "=== C1: every dispatch row carries the harness (the ONE place a spawn is reported) ==="
sed -n '/# \[prdisp:begin\]/,/# \[prdisp:end\]/p' "$LOOP" | sed '1d;$d' > "$T/disp.sh"
{ [ -s "$T/disp.sh" ] && grep -q 'HARNESS_TOKEN' "$T/disp.sh"; } \
  && ok "disp() is extracted and it stamps the token" \
  || bad "disp() does not carry the harness token — a spawn line would not disclose it"
D="$T/c1"; mkdir -p "$D/O/state"
(
  O="$D/O"; HARNESS_TOKEN="behind:111111111111"
  . "$T/disp.sh"
  disp 42 abc123 FAILED:x act "fixer spawned"
  HARNESS_TOKEN=""
  disp 43 abc123 - wait "nothing to do"
)
_row42="$(awk -F'\t' '$1==42{print $5}' "$D/O/state/prdisp.tsv" 2>/dev/null)"
_row43="$(awk -F'\t' '$1==43{print $5}' "$D/O/state/prdisp.tsv" 2>/dev/null)"
case "$_row42" in *"[harness=behind:111111111111]"*) ok "a spawn row names the behind checkout" ;;
                   *) bad "the spawn row does not disclose the harness: '$_row42'" ;; esac
case "$_row43" in *harness=*) bad "a current box's row carries a token anyway: '$_row43'" ;;
                   *) ok "…and a current box's row stays clean" ;; esac

_CASE=$((_CASE+1)); echo "=== C2: the issue-lane spawn line carries it too (dispatch-merge.sh, driven with stubs) ==="
D="$T/c2"; mkdir -p "$D/bin" "$D/O" "$D/repo/.git" "$D/repo/.worktrees/tm-7" "$D/repo/.worktrees/tm-8" "$D/repo/.worktrees/tm-9"
# ⛔ THE STUB MUST ANSWER THE REPO-IDENTITY READS (#2762 review, 4th cycle, P1). `dispatch-merge.sh`
# now asserts the checkout's origin before ANY lane work, so a stub that answers nothing makes the
# batch refuse 72 and every spawn/chain assertion below goes empty — a registered shard red for a
# reason it does not test. The origin read is the module's `config --local --get remote.origin.url`;
# `--git-common-dir` answers "./.git" and `$D/repo/.git` exists, so the post-build dir half matches.
cat > "$D/bin/git" <<GITS
#!/bin/bash
case "\$*" in
  *"config --local --get remote.origin.url"*) echo "https://github.com/owner/repo.git" ;;
  # ABSOLUTE, so the post-build dir half compares equal for the worktree and its checkout.
  *"rev-parse --git-dir"*|*"rev-parse --git-common-dir"*) echo "$D/repo/.git" ;;
esac
exit 0
GITS
chmod +x "$D/bin/git"
printf '#!/bin/bash\nexit 0\n'       > "$D/bin/tmux";   chmod +x "$D/bin/tmux"
printf '#!/bin/bash\nexit 0\n'       > "$D/bin/sleep";  chmod +x "$D/bin/sleep"
printf '#!/bin/bash\necho load\n'    > "$D/bin/uptime"; chmod +x "$D/bin/uptime"
for f in lane.sh merge-one.sh chain-merge.sh claims.sh; do : > "$D/O/$f"; done
# ⛔ THE CI-QUEUE READING THIS RIG MUST SUPPLY (#2296, cycle-3 P1). `dispatch-merge.sh` now reads the
# CI queue before it dispatches a batch, and an UNREADABLE queue DEFERS (fail-closed — an unreadable
# queue is not an empty one). This rig has no `gh`, so without a reading every line the three
# assertions below assert would be deferred away and they would fail for a reason they do not test
# (measured: 191 passed, 3 failed, all three of them this). The reading is SUPPLIED through the
# module's documented `CIQ_GH` seam with a SHALLOW queue — the production precondition under which a
# batch may run — rather than switching the gate off: a gate an env var can open is not a gate.
cat > "$D/bin/gh-queue" <<'GHQ'
#!/bin/sh
case "$2" in
  *status=queued*)      echo '{"total_count": 1}' ;;
  *status=in_progress*) echo '{"total_count": 0}' ;;
  *actions/runners*)    echo '{"total_count": 3, "runners": [{"status": "online", "busy": false}]}' ;;
  *) exit 1 ;;
esac
GHQ
chmod +x "$D/bin/gh-queue"
SPAWN="$(PATH="$D/bin:$PATH" O="$D/O" CIQ_GH="$D/bin/gh-queue" HARNESS_TOKEN="behind:111111111111" \
        bash "$DM" "$D/repo" owner/repo 7 2>&1 | grep 'lane-7')"
case "$SPAWN" in *"[harness=behind:111111111111]"*) ok "the lane-7 spawn line names the behind checkout" ;;
                  *) bad "the lane spawn line does not disclose it: '$SPAWN'" ;; esac
# An ABSENT token must not read as "current": the default is the honest unknown.
SPAWN2="$(PATH="$D/bin:$PATH" O="$D/O" CIQ_GH="$D/bin/gh-queue" bash "$DM" "$D/repo" owner/repo 8 2>&1 | grep 'lane-8')"
case "$SPAWN2" in *"[harness=unknown]"*) ok "an unsupplied token reads as unknown, never as current" ;;
                   *) bad "an absent token printed '$(printf '%s' "$SPAWN2" | tr -d '\n')'" ;; esac
# ⛔ AND AN EMPTY TOKEN IS A REAL ANSWER (the box is current), NOT AN ABSENT ONE. `${TOKEN:-unknown}`
# collapses the two, so every HEALTHY box stamped `[harness=unknown]` — the marker a reader needs in
# order to spot a stale box would then be present always, and therefore read never.
ALL9="$(PATH="$D/bin:$PATH" O="$D/O" CIQ_GH="$D/bin/gh-queue" HARNESS_TOKEN="" bash "$DM" "$D/repo" owner/repo 9 2>&1)"
case "$ALL9" in *harness=*) bad "an EMPTY (current) token still stamped a spawn line: '$(printf '%s' "$ALL9" | grep -o '\[harness=[^]]*\]' | head -1)'" ;;
                  *) ok "…and an EMPTY (current) token leaves BOTH spawn lines clean (lane- and chain-) — only UNSET is unknown" ;; esac

# ⛔ A DEFERRED BATCH MUST UNDO WHAT THE CONTROLLER DID (#2296 cycle 4, P1). The controller CLAIMS
# `refs/claims/issue-<N>` and appends the id to `dispatched.txt` BEFORE it calls this script, so an
# early `exit 0` that only printed a line left every issue in the batch on a 3 h cross-box lease held
# by a box that started nothing — and skipped by this box until the row was reaped. Measured here:
# the claims are released and the rows are dropped, so the batch really is back in the pool.
_CASE=$((_CASE+1)); echo "=== C2b: a CI-CONGESTED batch releases the claims and rows it never used ==="
DQ="$T/c2b"; mkdir -p "$DQ/bin" "$DQ/O/state" "$DQ/repo/.git" "$DQ/repo/.worktrees/tm-7" "$DQ/repo/.worktrees/tm-9"
cat > "$DQ/bin/git" <<GITQ
#!/bin/bash
case "\$*" in
  *"config --local --get remote.origin.url"*) echo "https://github.com/owner/repo.git" ;;
  *"rev-parse --git-dir"*|*"rev-parse --git-common-dir"*) echo "$DQ/repo/.git" ;;
esac
exit 0
GITQ
chmod +x "$DQ/bin/git"
printf '#!/bin/bash\nexit 0\n' > "$DQ/bin/tmux";  chmod +x "$DQ/bin/tmux"
printf '#!/bin/bash\nexit 0\n' > "$DQ/bin/uptime"; chmod +x "$DQ/bin/uptime"
# ⛔ NO EMPTY worker-terminal.sh IN THIS RIG (#2296 cycle 4 verification): an EMPTY module is worse
# than none — `dispatch-merge.sh` prefers `$O/worker-terminal.sh` when it exists, finds no `wt_spawn`,
# and exits 78 before any of the congestion logic below runs. Left absent, it falls through to the
# sibling shipped module (which is what the neighbouring C2 case relies on too).
# A claims module that records what it was asked to release — the assertion is on the CALL, because a
# release that is attempted and fails is a different (loud) outcome the helper already reports.
cat > "$DQ/O/claims.sh" <<'CLS'
claim_issue_release_record() { echo "RELEASED $3" >> "$CLAIM_LOG"; return 0; }
CLS
printf '7\n9\n' > "$DQ/O/dispatched.txt"
# DEEP: 999 queued against 2 runners => ceiling 4 => every batch defers.
cat > "$DQ/bin/gh-queue" <<'GHQD'
#!/bin/sh
case "$2" in
  *status=queued*)      echo '{"total_count": 999}' ;;
  *status=in_progress*) echo '{"total_count": 1}' ;;
  *actions/runners*)    echo '{"total_count": 2, "runners": [{"status": "online", "busy": true}, {"status": "online", "busy": true}]}' ;;
  *) exit 1 ;;
esac
GHQD
chmod +x "$DQ/bin/gh-queue"
: > "$T/c2b-claims.log"
DOUT="$(PATH="$DQ/bin:$PATH" O="$DQ/O" CIQ_GH="$DQ/bin/gh-queue" CLAIM_LOG="$T/c2b-claims.log" \
        bash "$DM" "$DQ/repo" owner/repo 7 9 2>&1)"
DRC=$?
case "$DOUT" in *"nothing dispatched this run"*) ok "a congested queue defers the whole batch, and says so" ;;
                 *) bad "the congested batch did not defer: $(printf '%s' "$DOUT" | tr '\n' ' ' | cut -c1-160)" ;; esac
# ⛔ THE EXIT CODE IS THE CONTRACT (#2333 cycle 6 review, P2). The controller counts each issue as
# DISPATCHED before it calls this script, so a deferral that exits 0 left the funnel printing
# `-> N dispatched` and the cycle record `dispatched=N nothing=none` on the one cycle the gate
# stopped everything. Reverting `exit 3` → `exit 0` used to leave every suite green: no arm read the
# rc — this arm captured stdout (`DOUT="$( … )"`) and never read `$?` at all. ⛔ THE CAUSE IS THAT
# NOBODY READ IT, AND THIS BLOCK IS THE COUNTER-EXAMPLE TO THE TWO OBVIOUS MISATTRIBUTIONS: `$( )`
# does NOT discard a status (`X="$(cmd)"; rc=$?` preserves it — the `DOUT=…/DRC=$?` pair directly
# above depends on exactly that), and there is no pipe in this block (`| grep 'lane-7'` lives in the
# separate C2 spawn-line case, and the suite runs `set -uo pipefail` anyway, so a pipeline would
# propagate a non-zero status). Recording either of those as the cause sends the next author to
# restructure a capture that was never the problem (#1720: a log naming the wrong cause).
case "$DRC" in 3) ok "…and it exits 3 — the code the controller reads to record dispatched=0 instead of counting it" ;;
              *) bad "a deferred batch exited $DRC, not 3 — the controller would report the batch as DISPATCHED" ;; esac
CLAIMS="$(cat "$T/c2b-claims.log" 2>/dev/null | tr '\n' ' ')"
case "$CLAIMS" in *"RELEASED 7"*"RELEASED 9"*) ok "…and BOTH issue claims it never used are released (no 3 h stranded lease)" ;;
                  *) bad "a deferred batch stranded its claims: released=[$CLAIMS] — every peer refuses those issues until the lease expires" ;; esac
if [ -f "$DQ/O/dispatched.txt" ] && [ ! -s "$DQ/O/dispatched.txt" ]; then
  ok "…and the dispatched.txt rows are dropped, so this box re-reads them next cycle (no turn consumed)"
else
  bad "a deferred batch left dispatched.txt rows: [$(tr '\n' ' ' < "$DQ/O/dispatched.txt" 2>/dev/null)] — this box skips free issues until the reaper prunes them"
fi
# The chain- line is a SECOND spawn path, and it used to stamp unconditionally: `[harness=]` on every
# current box, which is exactly the always-present marker this design refuses.
ALL7="$(PATH="$D/bin:$PATH" O="$D/O" CIQ_GH="$D/bin/gh-queue" HARNESS_TOKEN="behind:111111111111" bash "$DM" "$D/repo" owner/repo 9 2>&1)"
case "$ALL7" in *"chain-9"*"[harness=behind:111111111111]"*) ok "the CHAIN spawn line names the behind checkout too" ;;
               *) bad "the chain spawn line does not disclose it: $(printf '%s' "$ALL7" | tr '\n' ' ' | cut -c1-200)" ;; esac

# ── A14/A15: the two false-PASS paths a review found, each reproduced before it was fixed ─────────
_CASE=$((_CASE+1)); echo "=== A14: the materialiser pinned a DIFFERENT commit than the ref tip -> UNKNOWN, never current ==="
# Reachable on a real box: `apply` re-resolves $HARNESS_REF itself and a concurrent fetch can move that
# ref between this script's comparison and the pin. Reporting `current` there empties the token and
# spawns every lane from a behind box with no disclosure at all.
D="$T/a14"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C1" > "$PIN"
cat > "$D/mat.sh" <<SH
#!/bin/bash
git -C "$T/src" update-ref refs/remotes/origin/main "$C3"
exit 0
SH
chmod +x "$D/mat.sh"
R="$(HARNESS_MATERIALISER="$D/mat.sh" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
git -C "$T/src" update-ref refs/remotes/origin/main "$C2"   # restore the fixture
[ "$RC" = 23 ] && ok "exit 23 (unknown) when the pin does not name the compared tip" \
              || bad "exit $RC, expected 23 — output: $R"
case "$R" in *relation=unknown*) ok "the relation is unknown, not current (current would empty the token)" ;;
              *) bad "a pin/tip mismatch was not reported as unknown: $R" ;; esac
[ "$(pin_of "$PIN")" = "$C1" ] && ok "nothing was recorded as deployed (the old pin stands)" \
                                || bad "the pin was overwritten with '$(pin_of "$PIN")'"

# ⛔ A15: a ref this script did NOT fetch is a LOCAL ref, and a local ref is not a freshness answer.
# Measured in a review: local main one commit behind origin/main reported `current` silently.
_CASE=$((_CASE+1)); echo "=== A15: a non-origin ref is compared LOCALLY and the staleness is said out loud ==="
D="$T/a15"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C1" > "$PIN"
R="$(bash "$RR" --repo "$T/src" --ref main --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
case "$R" in *"not an origin/* ref"*) ok "a non-fetchable ref warns that the comparison is LOCAL and may be stale" ;;
              *) bad "a bare-branch ref was compared with no warning: $R" ;; esac
case "$R" in *relation=behind*) ok "…and it still compares (a warning is not a refusal)" ;;
              *) bad "a bare-branch ref did not compare: $R" ;; esac
# ⛔ THE FIELD, NOT JUST THE PROSE. `fetch=local` is what the controller turns into a token; a suite that
# asserts only the wording still passes if the record says `ok` (mutation-verified), and then a comparison
# nothing fetched is published as fresh with an empty spawn token.
case "$R" in *fetch=local*) ok "…and the RECORD says fetch=local (the field the controller reads)" ;;
              *) bad "a local-ref comparison was recorded as fresh: $R" ;; esac

# ⛔ A22: THE TIP MUST BE WHAT THIS FETCH PRODUCED — a successful fetch is NOT a freshly-updated ref, and
# FETCH_HEAD is one shared file per .git that any concurrent fetch rewrites. Two independent false-PASSes
# were reproduced in review: (1) with `remote.origin.fetch` mapped elsewhere the fetch exits 0, the local
# ref stays stale, and the box reported `current` while a commit behind; (2) a concurrent bare
# `git fetch origin` (refresh-candidates.sh does exactly that) wrote another branch first, and the first
# FETCH_HEAD line named a foreign commit. Both must now compare the fetched commit.
_CASE=$((_CASE+1)); echo "=== A22: a successful fetch whose refspec does NOT map must still compare the FETCHED commit ==="
D="$T/a22"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C1" > "$PIN"
# ⛔ NO REMOTE MUTATION IN THIS FIXTURE: origin/main is already C2 and C3 is deliberately local-only. The
# non-mapping shape is produced by moving the TRACKING ref back to C1, so a fetch that only writes its own
# destination ref leaves `refs/remotes/origin/main` stale at C1 while the fetched commit is C2 — exactly the
# measured shape, and every later case keeps the ref it expects.
git -C "$T/src" config remote.origin.fetch '+refs/heads/*:refs/remotes/upstream/*'
git -C "$T/src" update-ref refs/remotes/origin/main "$C1"   # deliberately stale tracking ref
R="$(bash "$RR" --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C1")" 2>&1)"; RC=$?
case "$R" in *relation=behind*) ok "a non-mapping refspec still compares the FETCHED commit (behind, not current)" ;;
              *) bad "a successful-but-stale-refspec fetch was read as current: $R" ;; esac
case "$R" in *fetch=ok*) ok "…and the comparison is still recorded as fresh (the fetch DID succeed)" ;;
              *) bad "a successful fetch was recorded as stale: $R" ;; esac
# Restore the standard refspec and the tracking ref for the cases below (the remote itself was never moved).
git -C "$T/src" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$T/src" update-ref refs/remotes/origin/main "$C2"

# ⛔ A24: THE SHARED-FILE RACE, STAGED DETERMINISTICALLY. FETCH_HEAD is one file per .git, rewritten by ANY
# fetch on the box (`refresh-candidates.sh` runs a bare `git fetch origin`, one line per branch). A real
# concurrent writer cannot be scheduled from a test, so the stub IS the concurrent writer: it performs the
# real fetch and then appends a FOREIGN line to FETCH_HEAD, exactly as a peer would. Reading FETCH_HEAD's
# first line then yields a foreign commit (a false `ahead`/`diverged`, whose remedy tells a healthy
# operator to rebase); reading the private ref yields the fetched tip. This is the case that discriminates.
_CASE=$((_CASE+1)); echo "=== A24: a foreign FETCH_HEAD (a concurrent fetch) cannot become the tip ==="
D="$T/a24"; mkdir -p "$D/pin" "$D/bin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C3" > "$PIN"
_REALGIT3="$(command -v git)"
cat > "$D/bin/git" <<SH
#!/bin/bash
_is_fetch=0
for _a in "\$@"; do [ "\$_a" = fetch ] && _is_fetch=1; done
if [ "\$_is_fetch" = 1 ]; then
  "$_REALGIT3" "\$@" || exit 1
  # …and a PEER's fetch lands right after ours: FETCH_HEAD's first line becomes a foreign commit.
  _gd="\$("$_REALGIT3" -C "$T/src" rev-parse --absolute-git-dir 2>/dev/null)"
  printf '%s\t\tbranch %s of %s\n' "$C3" "'foreign'" "example.invalid" > "\$_gd/FETCH_HEAD"
  exit 0
fi
exec "$_REALGIT3" "\$@"
SH
chmod +x "$D/bin/git"
# ⛔ THE DISCRIMINATING SHAPE: pin/running tree = C3, which is AHEAD of origin/main (C2) and is exactly the
# commit a peer's fetch leaves first in FETCH_HEAD. Reading FETCH_HEAD makes the tip C3 → `relation=current`
# (silent, exit 0) about a tree that is NOT on origin/main's line — the false PASS this file exists to end,
# with the worst remedy of all: none. Reading the fetched tip says `ahead` and refuses (21). A pin that is
# merely BEHIND does NOT discriminate: it is behind both commits, so both reads agree (measured).
R="$(PATH="$D/bin:$PATH" bash "$RR" --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C3")" 2>&1)"; RC=$?
[ "$RC" = 21 ] && ok "an off-line pin is still refused (21) when a foreign FETCH_HEAD exists" \
              || bad "exit $RC, expected 21 — a foreign FETCH_HEAD changed the verdict: $R"
case "$R" in *relation=current*) bad "a foreign FETCH_HEAD line made an off-line tree read as current: $R" ;;
              *relation=ahead*) ok "…and the verdict is 'ahead', not 'current' (a FETCH_HEAD read would silence it)" ;;
              *) bad "unexpected verdict under a foreign FETCH_HEAD: $R" ;; esac
# ⛔ NON-VACUITY: the race must actually have been staged. Without this, a stub that failed to write leaves
# FETCH_HEAD equal to the fetched commit, and the assertion above passes for the wrong reason (measured).
_gd24="$(git -C "$T/src" rev-parse --absolute-git-dir 2>/dev/null)"
[ "$(head -1 "$_gd24/FETCH_HEAD" 2>/dev/null | cut -f1)" = "$C3" ] \
  && ok "…and the foreign line really was the FIRST line of FETCH_HEAD (the race was staged)" \
  || bad "the fixture did not stage the race: FETCH_HEAD's first line is '$(head -1 "$_gd24/FETCH_HEAD" 2>/dev/null | cut -f1)', expected the foreign $C3"

# ⛔ A25: A FETCH THAT SUCCEEDS BUT LEAVES NOTHING READABLE IS `stale`, NOT `ok` + a silent local fallback.
# Otherwise the one claim this file exists to make — "this comparison was fresh" — is asserted by a run whose
# fetch produced nothing this script could read.
_CASE=$((_CASE+1)); echo "=== A25: a successful fetch whose destination ref cannot be read is stale, not fresh ==="
D="$T/a25"; mkdir -p "$D/pin" "$D/bin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C2" > "$PIN"
_REALGIT4="$(command -v git)"
cat > "$D/bin/git" <<SH
#!/bin/bash
for _a in "\$@"; do [ "\$_a" = fetch ] && exit 0; done   # claims success, writes nothing
exec "$_REALGIT4" "\$@"
SH
chmod +x "$D/bin/git"
# The private ref must NOT already exist from an earlier case, or "unreadable" is untested and this case
# silently re-tests the happy path (measured: it did, and passed a fetch that produced nothing).
git -C "$T/src" update-ref -d refs/harness-refresh/main
R="$(PATH="$D/bin:$PATH" bash "$RR" --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C2")" 2>&1)"; RC=$?
case "$R" in *fetch=stale*) ok "an unreadable fetch result is recorded as stale" ;;
              *fetch=ok*) bad "a fetch that produced nothing readable was recorded as fresh: $R" ;;
              *) bad "unexpected record: $R" ;; esac
# on stderr, printed relation=current, and the CONTROLLER kept only the last non-record line — so the
# warning vanished and the spawn-line token was empty about a box one commit behind. The staleness now
# rides in the record (`fetch=stale`), and the loop turns that into a token.
# ⛔ A16: A FAILED FETCH IS NOT `current`. Measured in review: with origin unreachable the script warned
# on stderr, printed relation=current, and the CONTROLLER kept only the last non-record line — so the
# warning vanished and the spawn-line token was empty about a box one commit behind. The staleness now
# rides in the record (`fetch=stale`), and the loop turns that into a token.
_CASE=$((_CASE+1)); echo "=== A16: an unreachable origin makes the record say fetch=stale, never a silent current ==="
D="$T/a16"; mkdir -p "$D/pin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C2" > "$PIN"
_OURL="$(git -C "$T/src" remote get-url origin)"
git -C "$T/src" remote set-url origin "$T/does-not-exist.git"
R="$(bash "$RR" --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C2")" 2>&1)"; RC=$?
git -C "$T/src" remote set-url origin "$_OURL"; git -C "$T/src" fetch -q origin
case "$R" in *"relation=current"*"fetch=stale"*) ok "the record carries fetch=stale alongside the relation" ;;
              *) bad "a failed fetch produced no staleness in the record: $R" ;; esac
# …and the controller must not go quiet on it.
D="$T/a16b"; mkdir -p "$D/O/state" "$D/O/logs"
cat > "$D/O/harness-refresh.sh" <<'SH'
#!/bin/bash
echo "harness relation=current running=333333333333 ref=333333333333 pin=333333333333 action=none fetch=stale"
echo "harness current: 333333333333 == origin/main — pin already names it"
exit 0
SH
chmod +x "$D/O/harness-refresh.sh"
(
  O="$D/O"; LOG="$D/O/logs/orch-loop.log"; HARNESS_REF=origin/main; : > "$LOG"
  . "$BLK/block.sh"; harness_refresh_cycle; printf 'T=%s\n' "$HARNESS_TOKEN" > "$D/tok"
)
[ "$(cat "$D/tok")" = "T=stale:333333333333" ] \
  && ok "a stale comparison yields the token 'stale:<running>', not an empty one" \
  || bad "token was '$(cat "$D/tok")', expected T=stale:333333333333 (an empty token here is a silent box)"

# ⛔ THE LOOP'S FRESHNESS GUARD IS NOT ONLY ABOUT `stale`: `local` and `notfetched` are the same class — a
# comparison that was not made fresh — and a guard that only recognises `stale` (measured mutation) empties
# the token for the other two. Both are driven here.
for _fs in local notfetched; do
  D="$T/b6-$_fs"; mkdir -p "$D/O/state" "$D/O/logs"
  cat > "$D/O/harness-refresh.sh" <<SH
#!/bin/bash
echo "harness relation=current running=333333333333 ref=333333333333 pin=333333333333 action=none fetch=$_fs"
exit 0
SH
  chmod +x "$D/O/harness-refresh.sh"
  (
    O="$D/O"; LOG="$D/O/logs/orch-loop.log"; HARNESS_REF=origin/main; : > "$LOG"
    . "$BLK/block.sh"; harness_refresh_cycle; printf 'T=%s\n' "$HARNESS_TOKEN" > "$D/tok"
  )
  [ "$(cat "$D/tok")" = "T=$_fs:333333333333" ] \
    && ok "a '$_fs' comparison yields the token '$_fs:<running>', not an empty one" \
    || bad "fetch=$_fs produced token '$(cat "$D/tok")'"
done

# ⛔ A17: an unresolvable commit is UNVERIFIABLE, not `diverged`. merge-base exits 128 for an object the
# repo does not have, and that non-zero used to be read as "neither ancestor nor descendant" — naming the
# 2026-10-14 off-line shape and telling an operator to re-pin a tree that may be fine.
_CASE=$((_CASE+1)); echo "=== A17: a stamp naming a commit this checkout does not have -> UNKNOWN, not diverged ==="
D="$T/a17"; mkdir -p "$D/O/pin"; PIN="$D/O/pin/HARNESS-PIN"
printf '{"commit": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}\n' > "$D/O/.agent-infra-stamp.json"
R="$(O="$D/O" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$D/O" 2>&1)"; RC=$?
[ "$RC" = 23 ] && ok "exit 23 (unknown) for a commit the repo cannot resolve" \
              || bad "exit $RC, expected 23 — output: $R"
case "$R" in *relation=diverged*) bad "an unresolvable commit was named 'diverged' (and given a re-pin remedy): $R" ;;
              *relation=unknown*) ok "…and it is not mislabelled diverged" ;;
              *) bad "unexpected relation: $R" ;; esac

# ⛔ A23: A REFUSAL THAT HAPPENS BEFORE THE FETCH DECISION MUST NOT CLAIM `fetch=ok`. The record is emitted
# on every path, so a pre-fetch refusal (no repo, no tip) used to stamp `fetch=ok` — the one field that means
# "this comparison was fresh" — asserted by a run that never compared.
_CASE=$((_CASE+1)); echo "=== A23: a pre-fetch refusal records fetch=notfetched, never fetch=ok ==="
D="$T/a23"; mkdir -p "$D/notrepo" "$D/pin"; PIN="$D/pin/HARNESS-PIN"
R="$(bash "$RR" --repo "$D/notrepo" --ref origin/main --pin "$PIN" --self "$D/notrepo" 2>&1)"; RC=$?
[ "$RC" = 23 ] && ok "exit 23 for a non-checkout repo" || bad "exit $RC, expected 23 — output: $R"
case "$R" in *fetch=notfetched*) ok "…and it does NOT claim a fresh comparison" ;;
              *fetch=ok*) bad "a refusal before the fetch claimed fetch=ok: $R" ;;
              *) bad "unexpected record: $R" ;; esac

# ⛔ A18: the PIN default must be the file a CELL reads. The controller's HOME is the cell home, but an
# operator running this by hand has HOME = their own account: a bare $HOME default mended a file nothing
# reads, printed "pin MENDED", and `status` still showed an empty pin.
_CASE=$((_CASE+1)); echo "=== A18: the pin default follows CELL_HOME (an operator shell is not the controller) ==="
D="$T/a18"; mkdir -p "$D/cell" "$D/home"
( cd "$D/cell" && HOME="$D/home" CELL_HOME="$D/cell" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --self "$(harness_at "$C2")" >/dev/null 2>&1 )
[ -f "$D/cell/.pi/agent/state/HARNESS-PIN" ] && ok "the pin was written under CELL_HOME" \
  || bad "no pin under CELL_HOME (the operator-shell default wrote somewhere nothing reads)"
[ ! -f "$D/home/.pi/agent/state/HARNESS-PIN" ] && ok "…and NOT under the operator's own HOME" \
  || bad "the pin went to \$HOME — a file no cell surface reads"

# ⛔ A19: THE CELL'S PRIMARY SHAPE — `$O` is NOT a git checkout, so identity comes from the stamp. Every
# earlier case passes `--self <git worktree>`, which is why review round 3 found `set -u` aborting this
# exact branch (`CONTROLLER_LIVE` read before it was defined) with NO record and an undocumented exit 1:
# on a live cell every `current` cycle died, the pin mend was unreachable, and state/harness-refresh was
# rewritten forever as unknown/no-record. A fixture that only ever exercises the easy shape cannot see it.
_CASE=$((_CASE+1)); echo "=== A19: a cell-shaped box (self is not a git checkout, identity from the stamp) does not crash ==="
D="$T/a19"; mkdir -p "$D/o/pin" "$D/o/state"; PIN="$D/o/pin/HARNESS-PIN"
printf '{"commit": "%s"}\n' "$C2" > "$D/o/.agent-infra-stamp.json"
R="$(O="$D/o" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$D/o" 2>&1)"; RC=$?
[ "$RC" = 11 ] && ok "a stamp-only box mends its empty pin (exit 11) instead of aborting" \
              || bad "exit $RC, expected 11 — output: $(printf '%s' "$R" | tail -2 | tr '\n' ' ')"
case "$R" in *"unbound variable"*) bad "the stamp branch aborts under set -u: $R" ;;
              *relation=current*) ok "…and it prints a record, not an abort" ;;
              *) bad "unexpected output: $R" ;; esac
[ "$(pin_of "$PIN")" = "$C2" ] && ok "the pin now names what the box runs" || bad "the pin was not written"
# …and the LIVE-controller arm: same box, pin == tip, a live lock held by THIS test's own shell.
printf '%s\n' "$C2" > "$PIN"; printf '%s\n' "$$" > "$D/o/.orch.lock"
R="$(O="$D/o" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$D/o" 2>&1)"; RC=$?
rm -f "$D/o/.orch.lock"
case "$R" in *relation=restart-pending*) ok "a live controller whose identity comes only from the stamp is restart-pending, not current" ;;
              *) bad "a live controller on stamp-only identity was reported: $R" ;; esac

# ⛔ A36 (#2641): THE CELL THAT IS ACTIVATED AND STILL SAYS `restart-pending`. MEASURED 2026-10-24 on
# pi-cell-3, twelve minutes after a correct activation: pin == `$O`'s stamp == the tree the controller
# executed == `848ba4b1`, and the record still printed `relation=restart-pending running=848ba4b133a7`.
# Cause: `$SELF` is `$O`, a cell's `$O` is a flat seed with NO git identity, so `self:` never resolves
# there and the stamp fallback (then the `stamp:*` downgrade) owns the answer forever. The running
# identity IS available — `$O/.orch.lock` names the owning controller and ITS argv names the tree it
# executes — so this case drives a real process with that argv and requires the record to name ITS
# commit, not the stale stamp's.
_CASE=$((_CASE+1)); echo "=== A36: a pin-per-commit cell resolves RUNNING from the live controller's tree, not the flat seed's stamp ==="
D="$T/a24"; mkdir -p "$D/o/state" "$D/pins" "$D/pin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C2" > "$PIN"
# The seed's stamp names C1: the STALE answer this case must not accept.
printf '{"commit": "%s"}\n' "$C1" > "$D/o/.agent-infra-stamp.json"
_T24="$D/pins/$(short "$C2")"
git -C "$T/src" worktree add --detach "$_T24" "$C2" >/dev/null 2>&1
# A controller-shaped process: `bash <tree>/scripts/orchestrator-harness/orch-loop.sh` — the exact argv
# `cloud-cell-supervisor.sh start` launches, and the shape both sibling readers match on. The fixture's
# orch-loop.sh is a one-line echo, so it is replaced with a sleeper; the tree stays a valid git worktree
# whose HEAD is still $C2 (`rev-parse` ignores the working tree), which is the only thing read here.
printf '#!/bin/bash\nsleep 120\n' > "$_T24/scripts/orchestrator-harness/orch-loop.sh"
_O26="$_T24/scripts/orchestrator-harness/orch-loop.sh"
bash "$_O26" & _P24=$!
sleep 1
printf '%s\n' "$_P24" > "$D/o/.orch.lock"
R="$(O="$D/o" HARNESS_PIN_DIR="$D/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$D/o" 2>&1)"; RC=$?
rm -f "$D/o/.orch.lock"
case "$R" in *relation=current*) ok "a correctly-activated cell reports current — not restart-pending forever" ;;
              *restart-pending*) bad "an activated cell still reads restart-pending (the always-on alarm): $R" ;;
              *) bad "unexpected record: $R" ;; esac
case "$R" in *"running=$(short "$C2")"*) ok "…and running= names the tree the controller EXECUTES" ;;
              *"running=$(short "$C1")"*) bad "running= still came from the (stale) seed stamp: $R" ;;
              *) bad "running= is neither the running tree nor the seed stamp: $R" ;; esac

# ⛔ A36c: A PROCESS THAT ONLY MENTIONS THE PATH IS NOT THE CONTROLLER. This is the false-PASS direction
# the repo already settled twice (supervisor `_controller_ps_awk`: "Match the INVOCATION, not the
# string"; drift tool: shell at `t[1]`, path at `t[2]`): a `sed`/`tail`/`diff` that merely READS the new
# tree would report `current` while the controller still executes the old one — and would fire the
# ahead/diverged refusals off a reader's argv on a healthy box. The real controller is killed first and
# the LOCK names the reader, so a mention-based read answers C2 (tip) while the invocation rule must
# leave RUNNING on the stamp (C1).
_CASE=$((_CASE+1)); echo "=== A36c: a process that only MENTIONS the harness path (a reader) is not the controller ==="
reap "$_P24"
_O26R="$_T24/scripts/orchestrator-harness/orch-loop.sh"
tail -f "$_O26R" >/dev/null 2>&1 & _R24=$!
sleep 1
printf '%s\n' "$_R24" > "$D/o/.orch.lock"
R3="$(O="$D/o" HARNESS_PIN_DIR="$D/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN" --self "$D/o" 2>&1)"; RC3=$?
rm -f "$D/o/.orch.lock"; kill "$_R24" 2>/dev/null; wait "$_R24" 2>/dev/null
case "$R3" in *"running=$(short "$C2")"*) bad "a READER of the tip tree answered for the box (false current): $R3" ;;
               *"running=$(short "$C1")"*) ok "a mention of the path does not resolve RUNNING (the lock named a live reader)" ;;
               *) bad "the record named neither tree — the stage was skipped, not exercised: $R3" ;; esac

# ⛔ A36i: AN AMBIENT `COLUMNS` MUST NOT TRUNCATE THE ARGV READ (#2926), and A36 cannot see this — the
# fixture runs with COLUMNS unset, so the witness has to SET it rather than hope. Same mechanism as A22b:
# `ps(1)` honours COLUMNS before its unlimited-width default, and the path is the LAST token, so a narrow
# COLUMNS cuts `*/orchestrator-harness/orch-loop.sh` mid-name — no match, the stage falls through to the
# stamp SILENTLY, and #2641's permanent `restart-pending` is back with the fix looking present. Not
# hypothetical: a real cell controller's invocation on this box measures EXACTLY 80 characters
# (`bash /home/cmux/harness/04bc1ddefed6/scripts/orchestrator-harness/orch-loop.sh`), one column from
# "no controller" at the 80-column tmux default. Re-driven on A36's fixture, which keeps a live
# controller shape and a pin root that already resolves.
_CASE=$((_CASE+1)); echo "=== A36i: a narrow COLUMNS cannot truncate the controller's argv (ps -ww) ==="
bash "$_O26" & _P31=$!
sleep 1
printf '%s\n' "$_P31" > "$D/o/.orch.lock"
R9="$(COLUMNS=20 O="$D/o" HARNESS_PIN_DIR="$D/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN" --self "$D/o" 2>&1)"
rm -f "$D/o/.orch.lock"; reap "$_P31"
case "$R9" in *"running=$(short "$C2")"*)
                ok "the running tree is still resolved with COLUMNS=20 — the argv read is width-independent" ;;
             *) bad "a narrow COLUMNS truncated the argv read — the stage gave up silently and #2641 returns: $R9" ;; esac

# ⛔ A36j: THE SHELL ALLOW-LIST IS ITS OWN GUARD AND HAD NO WITNESS (review cycle 6, measured: deleting the
# `case " bash sh dash zsh ksh " in` arm left the suite green at 211/211). A36c cannot be its witness — its
# reader is `tail -f <path>`, whose argv[1] is `-f`, so the SHAPE test rejects it before the shell test is
# ever evaluated. The arm is load-bearing: it is what stops a process whose argv[1] IS the path but whose
# argv[0] is not a shell — a `cat <path> -f`, a `diff`, an editor. Without it that reader's tree resolves
# `current` for a tree the controller is not executing, and `current` feeds `REL_RUN` (the ahead/diverged
# refusals). The plant is asserted to be argv-shaped before the outcome is read (the A25 lesson: a dead or
# unnamed plant makes every assertion below vacuously pass).
#
# ⛔ AND THE PLANT MUST BE PORTABLE (review cycle 10, P2 — the macOS measurement is this PR's own
# 2026-10-27T22:03Z review comment). The first version drove `tail <path> -f`: GNU tail permutes a trailing
# option, but BSD/macOS tail uses getopt and STOPS at the first operand, so `<path> -f` became TWO file
# operands — tail printed, exited, `ps` was empty, the plant assertion below redded, and the Mac half of the
# fleet got a red suite on a change that is green in CI (CI has no macos runner). Moving `-f` in front of
# the operand is not a fix either: argv[1] then holds the flag and the case witnesses nothing. So the
# OPERAND blocks by itself — a FIFO at the harness path, held open by a writer, and `tail` with NO flag
# blocks reading it. Same shape on Linux and BSD, and argv stays `cat <path>` with the path at argv[1].
# The tree is a real worktree INSIDE the pin root, so the recorded-root bound, the toplevel guard and the
# age rule all accept it: the shell allow-list is the ONLY thing that can reject this plant.
_CASE=$((_CASE+1)); echo "=== A36j: argv[1] IS the path but argv[0] is NOT a shell -> cannot answer (allow-list) ==="
_T36J="$D/pins/jtree"
git -C "$T/src" worktree add --detach "$_T36J" "$C2" >/dev/null 2>&1
_F36J="$_T36J/scripts/orchestrator-harness/orch-loop.sh"
rm -f "$_F36J"; mkfifo "$_F36J" 2>/dev/null
if [ ! -p "$_F36J" ]; then
  ok "mkfifo is unavailable on this host — nothing to block on (A36c/A36h/A36o still witness the allow-list)"
else
  sleep 120 > "$_F36J" & _W36J=$!
  bash -c 'exec -a cat tail "$1"' _ "$_F36J" >/dev/null 2>&1 & _P32=$!
  sleep 1
  case "$(ps -ww -o command= -p "$_P32" 2>/dev/null)" in
    "cat "*"orch-loop.sh"*) ok "the plant's argv really is `cat <path>` (argv[1] = the path, argv[0] not a shell)" ;;
    *) bad "the plant is not the shape this case exists to test: $(ps -ww -o command= -p "$_P32" 2>/dev/null)" ;; esac
  printf '%s\n' "$_P32" > "$D/o/.orch.lock"
  RA="$(O="$D/o" HARNESS_PIN_DIR="$D/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
         --pin "$PIN" --self "$D/o" 2>&1)"
  rm -f "$D/o/.orch.lock"; reap "$_P32"; reap "$_W36J"; rm -f "$_F36J"
  case "$RA" in *"running=$(short "$C2")"*)
                  bad "a NON-SHELL argv[1] answered for the box (false current) — the shell allow-list is gone: $RA" ;;
               *"running=$(short "$C1")"*)
                  ok "a non-shell that names the path as an argument cannot answer — the shell allow-list holds" ;;
               *) bad "the record named neither tree: $RA" ;; esac
fi

# ⛔ A36k: THE PIN-FILE ARM IS THE ONLY RECORD THAT CAN NAME A READ DIR OUTSIDE THE PIN ROOT (#2216), AND IT
# HAD NO WITNESS (review cycle 6, measured: deleting the block left the suite green at 211/211 — every A36*
# invocation passes HARNESS_PIN_DIR and none passes HARNESS_PIN_FILE). Without it every box of that shape
# falls back to `stamp:*` → `restart-pending`, which is #2641 itself. Driven with HARNESS_PIN_DIR UNSET so
# the arm is the only thing that can resolve, and the file holds the first line a real one holds
# (`<tree>/scripts/orchestrator-harness`, written by install.sh).
_CASE=$((_CASE+1)); echo "=== A36k: with NO pin root, the HARNESS_PIN_FILE tree still resolves RUNNING ==="
_P33="$T/a24/path-pin"
printf '%s\n' "$_T24/scripts/orchestrator-harness" > "$_P33"
bash "$_O26" & _P34=$!
sleep 1
printf '%s\n' "$_P34" > "$D/o/.orch.lock"
RB="$(env -u HARNESS_PIN_DIR O="$D/o" HARNESS_PIN_FILE="$_P33" bash "$RR" --no-fetch --repo "$T/src" \
       --ref origin/main --pin "$PIN" --self "$D/o" 2>&1)"
rm -f "$D/o/.orch.lock"; rm -f "$_P33"; reap "$_P34"
case "$RB" in *"running=$(short "$C2")"*)
                ok "the pin-file tree answers with NO pin root — the #2216 shape is not left on the stamp" ;;
             *"running=$(short "$C1")"*)
                bad "the HARNESS_PIN_FILE arm did not resolve (dead code in CI): RUNNING fell to the stamp: $RB" ;;
             *) bad "the record named neither tree: $RB" ;; esac

# ⛔ A36l: THE LEGACY FLAT-PIN ARM HAS ITS OWN WITNESS (review cycle 7, measured: deleting the arm's one
# line at `_acc` left the suite green at 218/218). A flat pin is a DIFFERENT recorded root shape from the
# per-commit child `apply` creates: there the pin root IS the worktree, so the controller tree is
# `<HARNESS_PIN_DIR>/scripts` with NO sha12 component. Every other A36* case drives either a child
# (`$D/pins/<sha12>/scripts`), the pin-file tree (A36k), or nothing, and the generic
# `<pin-root>/<one component>/scripts` fallback CANNOT serve this shape — `_rest` is then the literal
# `scripts`, which does not match its `*/scripts` prefix test (verified: `case scripts in */scripts)` is
# no match). So this arm is the ONLY thing that resolves a box on a flat pin, and without it that box
# keeps the permanent `restart-pending` this whole change exists to remove. Driven on its own seed (its
# own stale stamp at C1) so no earlier case can supply the answer.
_CASE=$((_CASE+1)); echo "=== A36l: a LEGACY FLAT pin (the pin root IS the worktree) still resolves RUNNING ==="
D="$T/a24"; _T25="$D/flatpin"
git -C "$T/src" worktree add --detach "$_T25" "$C2" >/dev/null 2>&1
printf '#!/bin/bash\nsleep 120\n' > "$_T25/scripts/orchestrator-harness/orch-loop.sh"
_O27="$_T25/scripts/orchestrator-harness/orch-loop.sh"
mkdir -p "$D/o2/state"
printf '{"commit": "%s"}\n' "$C1" > "$D/o2/.agent-infra-stamp.json"
bash "$_O27" & _P35=$!
sleep 1
# The plant is asserted to be argv-shaped BEFORE the outcome is read (the A25 lesson: a dead or unnamed
# plant makes every assertion below vacuously pass).
case "$(ps -ww -o command= -p "$_P35" 2>/dev/null)" in
  *"$_O27"*) ok "the plant really executes <flat-pin-root>/scripts/orchestrator-harness/orch-loop.sh" ;;
  *) bad "the plant is not the shape this case exists to test: $(ps -ww -o command= -p "$_P35" 2>/dev/null)" ;;
esac
printf '%s\n' "$_P35" > "$D/o2/.orch.lock"
RL="$(O="$D/o2" HARNESS_PIN_DIR="$_T25" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN" --self "$D/o2" 2>&1)"; RCL=$?
rm -f "$D/o2/.orch.lock"; reap "$_P35"
case "$RL" in *"running=$(short "$C2")"*)
                ok "the flat-pin tree answers — <pin-root>/scripts passes the recorded-root bound" ;;
             *"running=$(short "$C1")"*)
                bad "the flat-pin arm did not resolve (dead code): RUNNING fell to the seed stamp: $RL" ;;
             *) bad "the record named neither tree — the stage was skipped, not exercised: $RL" ;; esac
case "$RL" in *relation=current*) ok "…and a correctly-activated flat-pin cell reports current, not restart-pending forever" ;;
              *) bad "a flat-pin cell still cannot say it is current: $RL" ;; esac
[ "$RCL" = 0 ] || bad "exit $RCL on the flat-pin read: $RL"

# ⛔ A36m: A NON-REGULAR `HARNESS_PIN_FILE` MUST NOT HANG THE REFRESH (review cycle 8, P3). The block that
# reads the pin guards the LOCK against a FIFO eighty lines earlier (`:321`) for exactly this reason —
# `head` BLOCKS ON OPEN on a non-regular file — and then read the PIN with `-r`, which is TRUE for a FIFO.
# On a cell that is a hang with no output, EVERY cycle, silently: the refresh is a synchronous child of
# `orch-loop.sh`, so the whole controller cycle stops. `-f` is the gate this same file already uses for
# this same path at the `DEPLOYED` read, and the one `launchd-cycle.sh`/`install.sh` use.
#
# ⛔ THE PLANT AND THE LOCK ARE LOAD-BEARING, NOT DECORATION. The pin-file read sits inside
# `if [ -n "$_ctrl_tree" ]`, and `_ctrl_tree` is resolved from the LOCKED process's argv — so a fixture
# with no live controller never reaches line 403 at all and the case passes without touching the gate
# (MEASURED: the first draft of this case had no plant and stayed GREEN with the gate mutated back to
# `-r` — vacuous, the exact A36h/A36l defect). So the shape is A36k's: a real `orch-loop.sh`-argv sleeper
# at C2, the lock naming it, `HARNESS_PIN_DIR` UNSET so the pin-file arm is the only accept-root entry.
#
# ⛔ BOTH ARMS ARE ASSERTED, AND THAT IS WHAT MAKES THE FIXTURE SELF-PROVING (review cycle 9, P3). `-f`
# makes the FIFO contribute nothing, `_ok` stays 0 and RUNNING falls to the seed stamp's C1 — but C1 is
# ALSO what a fixture whose plant died or whose lock was never written prints, so an arm asserting only
# C1 would read `ok` on a rotted fixture and the vacuity above could silently return. So the SAME fixture
# is driven first with a REGULAR pin file (which must resolve C2 — proving the stage is reached and the
# plant is live) and only then with the FIFO (which must fall to C1). Neither arm alone is evidence.
_CASE=$((_CASE+1)); echo "=== A36m: a FIFO HARNESS_PIN_FILE does not hang the refresh (the gate is -f, not -r) ==="
_F26="$T/a24/path-fifo"
rm -f "$_F26"; mkfifo "$_F26" 2>/dev/null
if [ ! -p "$_F26" ]; then
  ok "mkfifo is unavailable on this host — nothing to hang on (A36k still pins the -f read on a regular file)"
else
  rm -f "$D/o/fifo.out"
  bash "$_O26" & _P36=$!
  sleep 1
  printf '%s\n' "$_P36" > "$D/o/.orch.lock"
  # The plant is asserted to be argv-shaped BEFORE either outcome is read (the A25/A36l lesson).
  case "$(ps -ww -o command= -p "$_P36" 2>/dev/null)" in
    *"$_O26"*) ok "the plant really executes <pin-tree>/scripts/orchestrator-harness/orch-loop.sh" ;;
    *) bad "the plant is not the shape this case exists to test: $(ps -ww -o command= -p "$_P36" 2>/dev/null)" ;;
  esac
  # CONTROL ARM — a REGULAR pin file on this same fixture must resolve C2. This is what proves the stage
  # is reached, so the FIFO arm's C1 below cannot be a skip wearing an ok.
  _K26="$T/a24/path-ctrl"
  printf '%s\n' "$_T24/scripts/orchestrator-harness" > "$_K26"
  _KC26="$(env -u HARNESS_PIN_DIR O="$D/o" HARNESS_PIN_FILE="$_K26" bash "$RR" --no-fetch --repo "$T/src" \
            --ref origin/main --pin "$PIN" --self "$D/o" 2>&1)"
  case "$_KC26" in
    *"running=$(short "$C2")"*) ok "control: the same fixture with a REGULAR pin file resolves C2 — the stage is reached" ;;
    *) bad "control: a REGULAR pin file did not resolve C2, so this case proves nothing about the FIFO: $_KC26" ;;
  esac
  rm -f "$_K26"
  env -u HARNESS_PIN_DIR O="$D/o" HARNESS_PIN_FILE="$_F26" bash "$RR" --no-fetch --repo "$T/src" \
      --ref origin/main --pin "$PIN" --self "$D/o" >"$D/o/fifo.out" 2>&1 & _R36=$!
  _i26=0
  while kill -0 "$_R36" 2>/dev/null && [ "$_i26" -lt 60 ]; do sleep 0.25; _i26=$((_i26+1)); done
  if kill -0 "$_R36" 2>/dev/null; then
    # Regression branch: clean up BOTH the refresh and any `head` blocked on the FIFO, by the FIFO's own
    # unique path so nothing else on the host can be signalled, and never let a red test leak a hang.
    kill -9 "$_R36" 2>/dev/null; pkill -9 -f "$_F26" 2>/dev/null; wait "$_R36" 2>/dev/null
    bad "the refresh was still blocked after 15s on a FIFO pin file — head blocks on open; the gate must be -f, not -r"
  else
    wait "$_R36" 2>/dev/null
    ok "the refresh returned instead of blocking on the FIFO — the -f gate rejected a non-regular pin"
    case "$(cat "$D/o/fifo.out")" in
      *"running=$(short "$C1")"*)
        ok "…and RUNNING fell to the seed stamp (the safe direction) — the FIFO was not accepted as a root" ;;
      *"running=$(short "$C2")"*)
        bad "the FIFO was accepted as a recorded root — the gate is not filtering non-regular files" ;;
      *relation=*)
        bad "the refresh wrote a record but named neither tree — the pin stage was skipped, not exercised: $(cat "$D/o/fifo.out")" ;;
      *)
        bad "the refresh returned but produced no record: $(cat "$D/o/fifo.out")" ;;
    esac
  fi
  # ⛔ `reap`, not `kill`: `$_O26` is `#!/bin/bash` + `sleep 120`, so the pid this case holds is the
  # WRAPPER and the sleeper is its CHILD — a bare `kill` orphans a 2-minute sleeper at ppid 1.
  reap "$_P36"
  rm -f "$D/o/.orch.lock" "$_F26" "$D/o/fifo.out"
fi

# ⛔ A36n: THE LOCK READ'S `-f` IS LOAD-BEARING AND HAD NO WITNESS (review cycle 10, P2). The stage guards
# `$O/.orch.lock` with `-f` for exactly the reason A36m guards the pin file with it — `head` BLOCKS ON OPEN
# on a non-regular file — and nothing distinguished `-f` from `-r` there: MEASURED on a scratch copy,
# `-f` → `-r` at the lock read left the suite at 226 passed / 0 failed. On a cell that is a silent hang of
# the controller's WHOLE cycle, every cycle (the refresh is a synchronous child of `orch-loop.sh`).
#
# ⛔ THE CONTROL ARM COMES FIRST, AND THAT IS WHAT KEEPS THIS CASE FROM BEING A SKIP IN DISGUISE: a REGULAR
# lock on the same fixture must resolve C2, so the FIFO arm's C1 cannot be read as "the stage never ran"
# (the A36m lesson).
_CASE=$((_CASE+1)); echo "=== A36n: a FIFO \$O/.orch.lock does not hang the refresh (the gate is -f, not -r) ==="
_L36N="$D/o/.orch.lock"
rm -f "$_L36N"
bash "$_O26" & _P36N=$!
sleep 1
case "$(ps -ww -o command= -p "$_P36N" 2>/dev/null)" in
  *"$_O26"*) ok "the plant really executes <pin-tree>/scripts/orchestrator-harness/orch-loop.sh" ;;
  *) bad "the plant is not the shape this case exists to test: $(ps -ww -o command= -p "$_P36N" 2>/dev/null)" ;; esac
printf '%s\n' "$_P36N" > "$_L36N"
_KC36N="$(O="$D/o" HARNESS_PIN_DIR="$D/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
           --pin "$PIN" --self "$D/o" 2>&1)"
case "$_KC36N" in
  *"running=$(short "$C2")"*) ok "control: a REGULAR lock on this fixture resolves C2 — the stage is reached" ;;
  *) bad "control: a REGULAR lock did not resolve C2, so this case proves nothing about the FIFO: $_KC36N" ;; esac
rm -f "$_L36N"; mkfifo "$_L36N" 2>/dev/null
if [ ! -p "$_L36N" ]; then
  ok "mkfifo is unavailable on this host — nothing to hang on (A36m pins the same gate on the pin file)"
else
  O="$D/o" HARNESS_PIN_DIR="$D/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$D/o" >"$D/o/lockfifo.out" 2>&1 & _R36N=$!
  _i36n=0
  while kill -0 "$_R36N" 2>/dev/null && [ "$_i36n" -lt 60 ]; do sleep 0.25; _i36n=$((_i36n+1)); done
  if kill -0 "$_R36N" 2>/dev/null; then
    # Clean up BOTH the refresh and any `head` blocked on the FIFO, by the FIFO's own unique path so nothing
    # else on the host can be signalled, and never let a red test leak a hang.
    kill -9 "$_R36N" 2>/dev/null; pkill -9 -f "$_L36N" 2>/dev/null; wait "$_R36N" 2>/dev/null
    bad "the refresh was still blocked after 15s on a FIFO lock — head blocks on open; the gate must be -f, not -r"
  else
    wait "$_R36N" 2>/dev/null
    ok "the refresh returned instead of blocking on the FIFO lock — the -f gate rejected a non-regular lock"
    case "$(cat "$D/o/lockfifo.out")" in
      *"running=$(short "$C1")"*)
        ok "…and RUNNING fell to the seed stamp (the safe direction) — the FIFO was not read as an owner" ;;
      *"running=$(short "$C2")"*)
        bad "the FIFO lock was read as a controller's pid file" ;;
      *relation=*)
        bad "the refresh wrote a record but named neither tree — the lock stage was skipped, not exercised: $(cat "$D/o/lockfifo.out")" ;;
      *)
        bad "the refresh returned but produced no record: $(cat "$D/o/lockfifo.out")" ;;
    esac
  fi
fi
rm -f "$_L36N" "$D/o/lockfifo.out"; reap "$_P36N"

# ⛔ A36o: THE TOKEN SPLIT MUST NOT GLOB (review cycle 10, P2). `for _w in $_argv` splits the ONE `ps`
# string on whitespace, which is the point — but with globbing ON a `*`/`?` token is expanded against the
# filesystem, so a word that was never in argv can be INVENTED, and an invented word that looks like a
# controller path then answers for the box. MEASURED on a scratch copy: replacing the
# `case $- in *f*) … set -f ;; esac` line with `_glob_had=0` left the suite at 226 passed / 0 failed.
#
# ⛔ THE TWO ARMS DIFFER IN ONE CHARACTER — `?` vs `h` — so this case cannot pass by the stage being
# skipped: argv[1] = the REAL path must resolve C2 (control), and argv[1] = the GLOB that matches that same
# file must not. The plant is `yes`: it never OPENS its argument (so the literal glob really survives in the
# process table) and never exits (so `ps` has something to read). Both are asserted before the outcome.
_CASE=$((_CASE+1)); echo "=== A36o: a glob token in argv is not expanded into a controller path (set -f) ==="
_G36O="$_T24/scripts/orchestrator-harness/orch-loop.s?"
bash -c 'exec -a bash yes "$1"' _ "$_G36O" >/dev/null 2>&1 & _P36O=$!
sleep 1
case "$(ps -ww -o command= -p "$_P36O" 2>/dev/null)" in
  "bash "*"orch-loop.s?") ok "the plant's argv[1] really is the GLOB, and argv[0] is a shell (the allow-list cannot be what rejects it)" ;;
  *) bad "the plant did not keep the literal glob in argv[1]: $(ps -ww -o command= -p "$_P36O" 2>/dev/null)" ;; esac
printf '%s\n' "$_P36O" > "$D/o/.orch.lock"
_RO36O="$(O="$D/o" HARNESS_PIN_DIR="$D/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
           --pin "$PIN" --self "$D/o" 2>&1)"
case "$_RO36O" in *"running=$(short "$C2")"*) bad "a GLOB token was expanded into a controller path (globbing on in the token split): $_RO36O" ;;
                 *"running=$(short "$C1")"*) ok "a glob token is not expanded — an invented word cannot answer for the box" ;;
                 *) bad "the record named neither tree — the stage was skipped, not exercised: $_RO36O" ;; esac
reap "$_P36O"
bash -c 'exec -a bash yes "$1"' _ "$_T24/scripts/orchestrator-harness/orch-loop.sh" >/dev/null 2>&1 & _P36Q=$!
sleep 1
printf '%s\n' "$_P36Q" > "$D/o/.orch.lock"
_RC36O="$(O="$D/o" HARNESS_PIN_DIR="$D/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
           --pin "$PIN" --self "$D/o" 2>&1)"
case "$_RC36O" in *"running=$(short "$C2")"*) ok "control: the same plant naming the REAL path resolves C2 — the stage is reached" ;;
                 *) bad "control: the real path did not resolve C2, so the glob arm proves nothing: $_RC36O" ;; esac
rm -f "$D/o/.orch.lock"; reap "$_P36Q"

# ⛔ A36p: THE RECORDED-ROOT BOUND IS WHOLE-PATH, NOT A SUFFIX MATCH (review cycle 10, P2). `_nl=$'\n'` is
# what keeps the membership test an EQUALITY between one recorded entry and one candidate path; with it
# empty, `_acc` is one run-on string and the test degrades to a SUBSTRING match — a tree whose raw path is
# only a textual SUFFIX of a recorded path then answers for this box. MEASURED on a scratch copy:
# `_nl=$'\n'` → `_nl=""` left the suite at 226 passed / 0 failed.
#
# The fixture makes the raw strings differ while the recorded entry still ENDS WITH the controller's path:
# the pin root is `<…>/nlroot` CONCATENATED with the controller tree's own path, so `_acc` ends with
# `<ctrl>/scripts/…` while `<ctrl>` is a real worktree — its own toplevel — OUTSIDE that pin root.
#
# ⛔ AND THE CONTROL ARM IS THE POINT: the same plant under a pin root that legitimately CONTAINS it (the
# single-child arm) must resolve C2, so the negative arm cannot be a skipped stage in disguise.
_CASE=$((_CASE+1)); echo "=== A36p: a tree that is only a textual SUFFIX of a recorded root cannot answer (whole-path bound) ==="
_T36P="$T/a24/nlsuffix"
git -C "$T/src" worktree add --detach "$_T36P" "$C2" >/dev/null 2>&1
printf '#!/bin/bash\nsleep 120\n' > "$_T36P/scripts/orchestrator-harness/orch-loop.sh"
bash "$_T36P/scripts/orchestrator-harness/orch-loop.sh" & _P36R=$!
sleep 1
case "$(ps -ww -o command= -p "$_P36R" 2>/dev/null)" in
  *"$_T36P/scripts/orchestrator-harness/orch-loop.sh"*) ok "the plant really executes its own tree's harness path" ;;
  *) bad "the plant is not the shape this case exists to test: $(ps -ww -o command= -p "$_P36R" 2>/dev/null)" ;; esac
printf '%s\n' "$_P36R" > "$D/o/.orch.lock"
_RC36P="$(O="$D/o" HARNESS_PIN_DIR="$T/a24" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
           --pin "$PIN" --self "$D/o" 2>&1)"
case "$_RC36P" in *"running=$(short "$C2")"*) ok "control: the SAME plant under a pin root that CONTAINS it resolves C2 — the stage is reached" ;;
                 *) bad "control: the containing pin root did not resolve C2, so the suffix arm proves nothing: $_RC36P" ;; esac
_P36PR="$T/a24/nlroot$_T36P"
mkdir -p "$_P36PR"
_RS36P="$(O="$D/o" HARNESS_PIN_DIR="$_P36PR" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
           --pin "$PIN" --self "$D/o" 2>&1)"
case "$_RS36P" in *"running=$(short "$C2")"*) bad "a tree that is only a textual SUFFIX of the pin root answered (the bound degraded to a substring match): $_RS36P" ;;
                 *"running=$(short "$C1")"*) ok "a suffix of a recorded root is not a recorded root — the stamp stands" ;;
                 *) bad "the record named neither tree — the stage was skipped, not exercised: $_RS36P" ;; esac
rm -f "$D/o/.orch.lock"; reap "$_P36R"

# ⛔ A36b: A TREE OUTSIDE EVERY RECORDED ROOT CANNOT ANSWER FOR THIS BOX. The harness path is SHARED
# across repos on one machine, so "a controller is running" and "MY controller is running" are different
# questions (the #1856 shape the supervisor answers with its ownership read). A peer repo's controller
# must never supply this box's commit — that would report `current` from another repo's tree — so with
# the lock naming a controller OUTSIDE `HARNESS_PIN_DIR`, RUNNING must stay on the stamp.
_CASE=$((_CASE+1)); echo "=== A36b: a controller outside the recorded pin root cannot answer for this box ==="
_T24B="$D/elsewhere/src-other"
_mkdir_p="$(dirname "$_T24B")"
mkdir -p "$_mkdir_p"
git -C "$T/src" worktree add --detach "$_T24B" "$C2" >/dev/null 2>&1
printf '#!/bin/bash\nsleep 120\n' > "$_T24B/scripts/orchestrator-harness/orch-loop.sh"
_O26B="$_T24B/scripts/orchestrator-harness/orch-loop.sh"
bash "$_O26B" & _P24C=$!
sleep 1
printf '%s\n' "$_P24C" > "$D/o/.orch.lock"
R2="$(O="$D/o" HARNESS_PIN_DIR="$D/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN" --self "$D/o" 2>&1)"; RC2=$?
rm -f "$D/o/.orch.lock"; reap "$_P24C"
case "$R2" in *relation=current*) bad "a foreign controller's tree bought a current verdict: $R2" ;;
               *relation=restart-pending*) ok "a foreign controller's tree does not buy a current verdict" ;;
               *) bad "unexpected record: $R2" ;; esac
case "$R2" in *"running=$(short "$C1")"*) ok "…and RUNNING stayed on the stamp, not on the foreign tree" ;;
               *) bad "the fallback did not name the stamp's commit: $R2" ;; esac

# ⛔ A36d: THE OWN-TOPLEVEL GUARD HAS A WITNESS. Cycle-3 review found the guard at `_want_root` had NO
# case that could distinguish its removal: delete it and the suite stayed green while `git -C` on a
# stale child that LOST its `.git` ASCENDED into the enclosing worktree and reported ITS head — a
# `current` for a tree the controller is not executing, i.e. the false-PASS defence deletable in
# silence. The pin root here IS a worktree at the TIP; inside it sits a stale `<sha12>/` copy without a
# `.git`, which is exactly what a killed `apply` leaves behind. RUNNING must stay on the stamp (C1).
_CASE=$((_CASE+1)); echo "=== A36d: a stale copy that lost its own .git cannot ascend into an enclosing worktree ==="
D="$T/a25"; mkdir -p "$D/o/state" "$D/pin" "$D/pin2"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C2" > "$PIN"
printf '{"commit": "%s"}\n' "$C1" > "$D/o/.agent-infra-stamp.json"
_P25="$D/pin2"
git -C "$T/src" worktree add --detach "$_P25" "$C2" >/dev/null 2>&1
mkdir -p "$_P25/$(short "$C1")/scripts/orchestrator-harness"
printf '#!/bin/bash\nsleep 120\n' > "$_P25/$(short "$C1")/scripts/orchestrator-harness/orch-loop.sh"
_O27="$_P25/$(short "$C1")/scripts/orchestrator-harness/orch-loop.sh"
# The lock is written AFTER the process starts, as `orch-loop.sh` does: the age half must ACCEPT this
# owner (shape+age), so the case exercises the TOPLEVEL guard and nothing else.
bash "$_O27" & _P26=$!
sleep 1
printf '%s\n' "$_P26" > "$D/o/.orch.lock"
R4="$(O="$D/o" HARNESS_PIN_DIR="$_P25" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN" --self "$D/o" 2>&1)"; RC4=$?
rm -f "$D/o/.orch.lock"; reap "$_P26"
case "$R4" in *"running=$(short "$C2")"*) bad "a stale copy without .git ascended into the enclosing worktree (false current): $R4" ;;
               *"running=$(short "$C1")"*) ok "a tree that is not its own toplevel cannot answer — the stamp stands" ;;
               *) bad "the record named neither tree — the stage was skipped, not exercised: $R4" ;; esac

# ⛔ A36e: PATHS ARE COMPARED PHYSICALLY — the witness for the `pwd -P` normalisation that cycle-4 review
# found MISSING (it was measured on a Mac: the fixture root is `TMPDIR`, and `/var` is a symlink into
# `/private/var`, so A36 redded there while CI — Linux-only — went green). A symlinked pin root makes
# the same defect reproducible on Linux: the argv token carries the LOGICAL path the launcher wrote,
# `git rev-parse --show-toplevel` answers PHYSICAL, and compared raw they never match — the stage then
# gives up silently and #2641's permanent `restart-pending` is back. This case MUST report `current`
# from the controller's tree.
_CASE=$((_CASE+1)); echo "=== A36e: a pin root reached through a SYMLINK still resolves RUNNING (physical compare) ==="
mkdir -p "$D/link-target"
git -C "$T/src" worktree add --detach "$D/link-target/$(short "$C2")" "$C2" >/dev/null 2>&1
ln -s "$D/link-target" "$D/link2"
printf '#!/bin/bash\nsleep 120\n' > "$D/link-target/$(short "$C2")/scripts/orchestrator-harness/orch-loop.sh"
# The controller is launched through the SYMLINKED path — the shape a symlinked cell home produces.
_O28="$D/link2/$(short "$C2")/scripts/orchestrator-harness/orch-loop.sh"
bash "$_O28" & _P27=$!
sleep 1
printf '%s\n' "$_P27" > "$D/o/.orch.lock"
R5="$(O="$D/o" HARNESS_PIN_DIR="$D/link2" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN" --self "$D/o" 2>&1)"; RC5=$?
rm -f "$D/o/.orch.lock"; reap "$_P27"
case "$R5" in *relation=current*) ok "a symlinked pin root still resolves the running tree — not a silent give-up" ;;
               *restart-pending*) bad "a symlinked pin root silently gave up (logical vs physical compare): $R5" ;;
               *) bad "unexpected record: $R5" ;; esac
case "$R5" in *"running=$(short "$C2")"*) ok "…and running= names the controller's tree, not the seed stamp" ;;
               *) bad "running= did not come from the controller's tree: $R5" ;; esac

# ⛔ A36f: A RECYCLED-PID LOCK IS NOT AN OWNER (the age half, review P1 twice). `$O/.orch.lock` is data on
# disk and outlives a `kill -9`/OOM/reboot; the OS can RECYCLE the pid onto a peer lane's controller,
# which on a cell is the SAME basename from the SAME shared harness path — so the argv SHAPE matches
# perfectly and a shape-only read reports `current` for a tree this box is not executing. A controller
# writes `$LOCK` AFTER it starts, so a process that BEGAN after the lock was written cannot be its
# owner. Driven by backdating the LOCK: the live controller began long after it, so the stage must
# refuse it and leave RUNNING on the stamp (C1) instead of certifying C2.
_CASE=$((_CASE+1)); echo "=== A36f: a lock whose pid began AFTER the lock was written is not the controller (age) ==="
printf '#!/bin/bash\nsleep 120\n' > "$_T24/scripts/orchestrator-harness/orch-loop.sh"
bash "$_O26" & _P28=$!
printf '%s\n' "$_P28" > "$D/o/.orch.lock"
# BACKDATE the lock by an hour: this process provably began after the lock was written, which is the
# recycled-pid shape the age rule exists for (the pid is alive and its argv matches).
touch -t 202001010000 "$D/o/.orch.lock" 2>/dev/null || touch -d '2020-01-01 00:00' "$D/o/.orch.lock" 2>/dev/null || true
R6="$(O="$D/o" HARNESS_PIN_DIR="$T/a24/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN" --self "$D/o" 2>&1)"; RC6=$?
rm -f "$D/o/.orch.lock"; reap "$_P28"
case "$R6" in *"running=$(short "$C2")"*) bad "a recycled-pid lock certified the tree it names (no age test): $R6" ;;
               *"running=$(short "$C1")"*) ok "a process that began after the lock was written is not its owner" ;;
               *) bad "the record named neither tree — the age path was skipped, not exercised: $R6" ;; esac

# ⛔ A36g: AN AGE THAT CANNOT BE READ IS NOT OWNERSHIP (review P1, cycle 5). The `|| return 1` arm this
# case drives is the one that stops a stale lock buying `current` when `ps` is broken — and it had NO
# witness, so it could be flipped to "unreadable ⇒ I own it" with the suite green. Driven through the
# `PS_BIN` seam the three canonical copies already carry, because a bare `ps` left this arm untestable.
_CASE=$((_CASE+1)); echo "=== A36g: an unreadable age is not ownership — a failing ps leaves RUNNING on the stamp ==="
mkdir -p "$T/a25/bin"
# ⛔ THE SHIM FAILS THE AGE READ ONLY. `PS_BIN` feeds BOTH reads in this stage: the age read
# (`-o etime=`, harness-refresh.sh:299) AND the argv read (`-ww -o command=`, :343). A shim that failed
# unconditionally therefore emptied `_argv` too, so RUNNING fell to the stamp whether or not the arm
# under test existed — the first version of this case was VACUOUS, and the body's mutation claim about
# it was false (MEASURED: flipping BOTH `|| return 1` unreadable-age arms to `|| return 0` left the
# suite at 225 passed / 0 failed). Passing the argv read through to the real `ps` keeps the plant's
# tree resolvable, so the ONLY thing between it and a false `current` is the arm this case witnesses.
REAL_PS_BIN="$(command -v ps)"
cat > "$T/a25/bin/ps-noage" <<SH
#!/bin/sh
case "\$*" in *etime*) exit 1 ;; esac
exec "$REAL_PS_BIN" "\$@"
SH
chmod +x "$T/a25/bin/ps-noage"
# …and the shim must still ANSWER the argv read, or this case degrades silently back to vacuous and a
# future reader inherits a green that witnesses nothing.
case "$("$T/a25/bin/ps-noage" -ww -o command= -p "$$" 2>/dev/null)" in
  '') bad "the ps-noage shim cannot answer the argv read — the unreadable-age case is vacuous again" ;;
   *) ok "…and the shim still answers the argv read, so the unreadable-age arm is the only thing under test" ;; esac
bash "$_O26" & _P29=$!
sleep 1
printf '%s\n' "$_P29" > "$T/a25/o/.orch.lock"
R7="$(O="$T/a25/o" HARNESS_PIN_DIR="$T/a24/pins" PS_BIN="$T/a25/bin/ps-noage" bash "$RR" --no-fetch \
       --repo "$T/src" --ref origin/main --pin "$PIN" --self "$T/a25/o" 2>&1)"
rm -f "$T/a25/o/.orch.lock"; reap "$_P29"
case "$R7" in *"running=$(short "$C2")"*) bad "an unreadable age was read as ownership (false current): $R7" ;;
               *"running=$(short "$C1")"*) ok "an age that cannot be read is not ownership — the stamp stands" ;;
               *) bad "the record named neither tree: $R7" ;; esac

# ⛔ A36h: THE PATH MUST BE THE SHELL'S SCRIPT OPERAND (argv[1]), NOT A WORD ANYWHERE IN THE ARGUMENTS.
# Cycle-5 review measured this through the shipped script: `perl -e 'sleep 120' bash <path>` resolved
# `relation=current` under a predecessor-token rule, although every precedent (`_controller_ps_awk`
# `tok[2]`, `lock_controller_pid` `${2##*/}`, `check-deployed-drift.sh` `t[2]`) reads POSITIONALLY. Here
# the wrapper is `bash -c 'sleep 120 & wait' bash <path>`: the same words in the same order, one wrapper
# deep, with the path as ARGUMENT rather than as the script being executed.
#
# ⛔ THE PLANT MUST NOT BE EXEC'D, OR THIS CASE WITNESSES NOTHING (review cycle 11, P1). The first
# version drove `bash -c 'sleep 120' bash <path>` — a SINGLE-COMMAND `-c`, which bash optimises into an
# `execve`: measured, `ps -ww -o command= -p <pid>` answers `sleep 120`, with NO shell token and no
# harness path anywhere in argv. Nothing can resolve a tree from that — not the shipped rule, not a
# predecessor-token rule, not a whole-argv scan — so the `bad` arm below was UNREACHABLE and the case
# passed on the PRE-FIX code as well (measured: reverting the read to a predecessor-token rule left the
# suite at 236 passed / 0 failed, A36h ✅ in both). The `& wait` keeps bash in the parent role, so argv
# stays `bash -c sleep 120 & wait bash <path>` and the path is genuinely an argument. Asserted BEFORE the
# outcome is read (the A25/A36j lesson: an unnamed or mis-shaped plant makes everything below vacuous).
_CASE=$((_CASE+1)); echo "=== A36h: a wrapper that only PASSES the path as an argument is not the controller ==="
bash -c 'sleep 120 & wait' bash "$_O26" & _P30=$!
sleep 1
case "$(ps -ww -o command= -p "$_P30" 2>/dev/null)" in
  *bash*"orch-loop.sh"*) ok "the plant's argv really carries the path as an ARGUMENT, with the shell still in flight" ;;
  *) bad "the plant is not the shape this case exists to test (exec'd single-command -c drops the path): $(ps -ww -o command= -p "$_P30" 2>/dev/null)" ;; esac
printf '%s\n' "$_P30" > "$T/a25/o/.orch.lock"
R8="$(O="$T/a25/o" HARNESS_PIN_DIR="$T/a24/pins" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
       --pin "$PIN" --self "$T/a25/o" 2>&1)"
rm -f "$T/a25/o/.orch.lock"; reap "$_P30"
case "$R8" in *"running=$(short "$C2")"*) bad "a wrapper's ARGUMENT list resolved RUNNING (not argv[1] of the shell): $R8" ;;
               *"running=$(short "$C1")"*) ok "the pair is read positionally — an argument-list mention is not the invocation" ;;
               *) bad "the record named neither tree: $R8" ;; esac

# ⛔ A37: THE SLACK IS THE FLEET'S ONE VALUE, NOT THIS FILE'S (#1856: "one predicate, three answers").
# This script is a FOURTH standalone copy of the ownership rule (it is farmed into a flat `$O` and
# cannot source `scripts/lib/`), so its slack must be PUSHED from the canonical declaration instead of
# remembered. Without this arm, moving the shared default leaves this reader at the old value — and a
# pid that began after the lock is then accepted as its owner.
_CASE=$((_CASE+1)); echo "=== A37: the lock-age slack is the same value as scripts/lib/pid-identity.sh ==="
_ROOT="$(cd "$HERE/../.." && pwd)"
_canon="$(grep -oE 'PID_START_SLACK_SECONDS(:-|=)[0-9]+' "$_ROOT/scripts/lib/pid-identity.sh" 2>/dev/null | head -1 | sed -E 's/.*(:-|=)//')"
_here="$(grep -oE 'HARNESS_LOCK_START_SLACK_SECONDS(:-|=)[0-9]+' "$RR" 2>/dev/null | head -1 | sed -E 's/.*(:-|=)//')"
[ -n "$_canon" ] && [ -n "$_here" ] \
  && ok "both copies declare a numeric default (pid-identity=$_canon harness-refresh=$_here)" \
  || bad "a copy no longer declares its slack (pid-identity=[$_canon] harness-refresh=[$_here]) — the drift arm cannot compare"
[ "$_canon" = "$_here" ] \
  && ok "the lock-age slack is the canonical value ($_canon s), not a stale literal" \
  || bad "lock-age slack DIVERGED — pid-identity=$_canon harness-refresh=$_here (a pid that began after the lock would be accepted)"

# ⛔ A20: THE BOUND MUST EXIST ON macOS, WHERE `timeout` DOES NOT. A bare `timeout` call is rc=127 on the
# Mac half of the fleet, and `if !` reads 127 as a FAILED FETCH — so the box would never fetch and would
# warn on every cycle: the defect this script removes, re-created by its own bound. Driven through the
# in-shell fallback (HARNESS_TIMEOUT_BIN="" pins the absence of a usable binary) with a `git` that hangs.
_CASE=$((_CASE+1)); echo "=== A20: with no timeout(1) (macOS) the fetch is still BOUNDED, and expiry is 'stale' ==="
D="$T/a20"; mkdir -p "$D/pin" "$D/bin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C2" > "$PIN"
# A git that DELEGATES everything (worktree list, rev-parse, cat-file) and hangs ONLY on `fetch` — a stub
# that swallows every git call makes the repo unresolvable, and the test then fails on the wrong refusal.
_REALGIT="$(command -v git)"
cat > "$D/bin/git" <<SH
#!/bin/bash
for _a in "\$@"; do [ "\$_a" = fetch ] && { : > "$D/fetch.started"; sleep 5; exit 1; }; done
exec "$_REALGIT" "\$@"
SH
chmod +x "$D/bin/git"
# ⛔ This marker line is deliberate: without it the NEXT statement's `$(date …)` is read by the repo's
# working-tree-discard scanner as the verb of the `chmod …/git` path token, which fails closed as a
# whole-tree discard and makes this file unrunnable from any session. A comment between them keeps the
# scanner's pairing out of reach (measured).
_t0="$(date +%s)"
# Only the FETCH is intercepted; resolving the ref needs a real git, so hand the stub a PATH that puts it
# first and a bound of 1s: on a box with no bound this test would take 5s and report `current`.
R="$(PATH="$D/bin:$PATH" HARNESS_TIMEOUT_BIN="" HARNESS_FETCH_TIMEOUT=1 bash "$RR" --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C2")" 2>&1)"; RC=$?
_el=$(( $(date +%s) - _t0 ))
[ "$_el" -le 3 ] && ok "the fetch was cut off at the bound (${_el}s, not the stub's 5s) with no timeout(1)" \
                || bad "the fetch ran $_el s — the bound did not fire on a box without timeout(1)"
# ⛔ A BOUND THAT PREVENTS THE COMMAND FROM STARTING WOULD SATISFY THE TWO CHECKS BELOW WHILE BEING THE
# P0 THIS FILE EXISTS TO REMOVE ("the box never fetches, and warns forever"). So the stub records that
# it was ENTERED, and that marker is asserted: cut off after starting, never skipped.
[ -f "$D/fetch.started" ] && ok "…and the fetch actually STARTED (a skipped fetch is the defect, not a pass)" \
                          || bad "the fetch never started — the bound prevented it instead of bounding it"
case "$R" in *fetch=stale*) ok "…and a cut-off fetch is recorded as stale, not as a fresh comparison" ;;
              *) bad "a timed-out fetch was reported as fresh: $R" ;; esac
# The arm that actually runs on the Linux CI runner (a real `timeout`): its expiry must map to `stale` too.
_CASE=$((_CASE+1)); echo "=== A21: with timeout(1) PRESENT, an expired fetch is also 'stale' (the CI-runner arm) ==="
D="$T/a21"; mkdir -p "$D/pin" "$D/bin"; PIN="$D/pin/HARNESS-PIN"
printf '%s\n' "$C2" > "$PIN"
_REALGIT2="$(command -v git)"
cat > "$D/bin/git" <<SH
#!/bin/bash
for _a in "\$@"; do [ "\$_a" = fetch ] && { : > "$D/fetch.started"; sleep 5; exit 1; }; done
exec "$_REALGIT2" "\$@"
SH
chmod +x "$D/bin/git"
if command -v timeout >/dev/null 2>&1; then
  _t0="$(date +%s)"
  R="$(PATH="$D/bin:$PATH" HARNESS_FETCH_TIMEOUT=1 bash "$RR" --repo "$T/src" --ref origin/main --pin "$PIN" --self "$(harness_at "$C2")" 2>&1)"
  _el=$(( $(date +%s) - _t0 ))
  [ "$_el" -le 3 ] && [ -f "$D/fetch.started" ] && ok "timeout(1) bounded the hanging fetch (${_el}s) after it started" \
      || bad "timeout(1) did not bound a hanging fetch (elapsed ${_el}s, started=$([ -f "$D/fetch.started" ] && echo yes || echo no))"
  case "$R" in *fetch=stale*) ok "…and expiry through timeout(1) is 'stale' too" ;;
                *) bad "expiry through timeout(1) was reported fresh: $R" ;; esac
else
  ok "timeout(1) is absent on this host — A20 already covers the watchdog arm (nothing to assert here)"
fi

# ⛔ B5: THE LATCH IS RELEASED EVERY CYCLE, NOT ONCE PER PROCESS. A per-process latch refreshes once in
# the controller's whole lifetime, then returns early forever: every later cycle keeps the first cycle's
# token (empty on a box that started current), a box that falls behind afterwards is spawned silently,
# and state/harness-refresh stops being rewritten — the exact failure this block exists to end.
_CASE=$((_CASE+1)); echo "=== B5: the refresh runs again in the NEXT cycle (a per-process latch runs exactly once, ever) ==="
D="$T/b5"; mkdir -p "$D/O/state" "$D/O/logs"
cat > "$D/O/harness-refresh.sh" <<'SH'
#!/bin/bash
echo "call" >> "$(dirname "$0")/calls"
echo "harness relation=current running=333333333333 ref=333333333333 pin=333333333333 action=none"
exit 0
SH
chmod +x "$D/O/harness-refresh.sh"
(
  O="$D/O"; LOG="$D/O/logs/orch-loop.log"; HARNESS_REF=origin/main; : > "$LOG"
  . "$BLK/block.sh"
  _HR_DONE=0; harness_refresh_cycle   # cycle 1 (the loop releases the latch at the call site)
  _HR_DONE=0; harness_refresh_cycle   # cycle 2 — a NEW cycle must refresh again
)
[ "$(grep -c '^call' "$D/O/calls" 2>/dev/null)" = 2 ] \
  && ok "a second CYCLE refreshes again (2 invocations)" \
  || bad "the refresh ran $(grep -c '^call' "$D/O/calls" 2>/dev/null || echo 0) time(s) across two cycles, expected 2"
# …and the release must live in the LOOP, or B5 above is only testing the test's own reset.
# No pipe: `grep … | grep -q` is the SIGPIPE false-negative idiom the repo's own guard rejects (a quiet
# consumer exiting early can make the producer die with SIGPIPE under `pipefail`, and the assertion then
# reads as a plain "no match"). awk reads the file once and exits on the first hit.
# The reset is its own STATEMENT, not a one-liner: comments (and later per-cycle resets, e.g. the
# #2308 refresh-resolution reset) legitimately sit between `_HR_DONE=0` and the call, so the look-back
# must span the intervening block rather than a fixed 3 lines — a narrow window reported a FALSE RED
# on a correct call site the moment a comment was added between the two statements.
_hr_call_ctx="$(awk '{ w[NR%32]=$0 }
  /^[[:space:]]*harness_refresh_cycle[[:space:]]*($|#)/ {
    for (i=1; i<=24; i++) if (w[(NR-i)%32] ~ /_HR_DONE=0/) { print "yes"; exit }
    exit
  }' "$LOOP")"
[ "$_hr_call_ctx" = yes ] \
  && ok "orch-loop.sh releases the latch at the call site (a per-process latch would refresh once, ever)" \
  || bad "orch-loop.sh does not reset _HR_DONE before its call — the refresh runs once per PROCESS"

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# agent-infra#2641 — `restart-pending` as a STATE WITH A TRANSITION, and the RUNNING identity read
# from the CONTROLLER'S OWN ARGV.
#
# THE DEFECT. MEASURED 2026-10-24 on pi-cell-3: `running` == `pin` == `ref` == 848ba4b1 and the record
# still said `restart-pending`, every cycle, since activation. A cell's `$O` is a FLAT SEED with no git
# identity, so `git -C "$SELF"` never resolved there, the identity fell back to the STAMP (a claim
# `apply` writes, not evidence of what is executing), and the `stamp:*` arm correctly downgraded every
# `current` to `restart-pending` — correctly, because it could not prove otherwise. The defect was
# upstream: the truthful answer WAS available (the controller's argv names the tree it executes) and
# nothing read it. So the token rode on every spawn line for ever (an always-on alarm carries no
# information), and when a restart really was needed the only way to apply it was a hand restart that
# reaps in-flight work — which is what every harness change that night needed.
#
# HOW THESE CASES ARE WRITTEN. Every one drives the SHIPPED script, with a REAL controller process (a
# real `bash <tree>/scripts/orchestrator-harness/orch-loop.sh` in a real git worktree) so the identity
# arm is exercised as it is on a cell — never a stub that asserts its own opinion. The pin roots are
# real per-commit worktrees. Each refusal arm is driven with the shape that would produce a FALSE
# `current` if its bound were dropped, because a false `current` is the failure that matters here: a
# box certified as executing code it is not.

# mk_pin_tree <pinroot> <sha> -> the tree (a real detached worktree of the fixture repo, as `apply` makes)
mk_pin_tree() {
  local root="$1" sha="$2" d
  d="$root/$(printf '%s' "$sha" | cut -c1-12)"
  [ -d "$d" ] || { mkdir -p "$root"; git -C "$T/src" worktree add --detach "$d" "$sha" >/dev/null 2>&1; }
  printf '%s\n' "$d"
}
# start_ctrl <tree> -> the pid of a LIVE controller executing that tree (== its process-group id)
# The script is overwritten AFTER the worktree exists: identity comes from `git rev-parse HEAD`, which a
# dirty worktree does not change, and the fixture's own `orch-loop.sh` just echoes a label (it would
# exit before it could be observed).
start_ctrl() {
  # ⛔ `sleep 300` WOULD FORK, and a forked child of the controller is (correctly) counted by the `tree`
  # population — so the fixture would read as "1 lane child" and `actuation=safe` would be unreachable
  # for a reason that is about the FIXTURE, not the box. A `read` on a fifo blocks INSIDE bash.
  # The fifo lives INSIDE $T (not /tmp) so the teardown that removes $T also removes it — 145 stray
  # `/tmp/ctrl-fifo.*` files were the other half of the #3011 residue.
  local f; f="$(mktemp -u "$T/ctrl-fifo.XXXXXX")"; mkfifo "$f" 2>/dev/null
  printf 'read -r _ < %s\n' "$f" > "$1/scripts/orchestrator-harness/orch-loop.sh"
  # ⛔ GROUPED START, NOT `bash … &` (#3011). A plain background job stays in THIS suite's process
  # group, so the id it returns is not a group id and a reaper signalling it can miss the live
  # process. `fixture_start_group` sets the group id before `exec` (so the id it prints IS the group)
  # and records it, so `fixture_reap_all` ends exactly this controller and nothing else on the box.
  fixture_start_group bash "$1/scripts/orchestrator-harness/orch-loop.sh"
}
stop_ctrl() { [ -n "${1:-}" ] && { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }; }
# req_of <O> <field> -> the field's value from the request record
req_of() { sed -n "s/.*[[:space:]]$2=\([^[:space:]]*\).*/\1/p" "$1/state/restart-request" 2>/dev/null | awk 'NF{print; exit}'; }

_CASE=$((_CASE+1)); echo "=== A36: a CELL whose live controller executes the pinned tree reports CURRENT (#2641) ==="
D="$T/a36"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
PIN="$D/cellhome/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '%s\n' "$TREE2" > "$D/pinfile"
CTRL="$(start_ctrl "$TREE2")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
# A real stamp naming the SAME commit: the point is that the record must NOT be resting on it.
printf '{"commit": "%s", "harness": "%s"}\n' "$C2" "$TREE2" > "$D/O/.agent-infra-stamp.json"
R="$(O="$D/O" CELL_HOME="$D/cellhome" HARNESS_PIN_DIR="$D/pinroot" HARNESS_PIN_FILE="$D/pinfile" \
      bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$D/O" 2>&1)"; RC=$?
stop_ctrl "$CTRL"
[ "$RC" = 0 ] && ok "exit 0 (the pin already names the tip — no advance was needed)" \
              || bad "exit $RC, expected 0 — output: $(printf '%s' "$R" | tail -2 | tr '\n' ' ')"
case "$R" in *"relation=current"*"running=$(short "$C2")"*) ok "relation=current, running=$(short "$C2") — read from the CONTROLLER'S ARGV, not from the stamp" ;;
              *) bad "a cell executing the pinned tree was NOT reported current (the #2641 defect itself): $R" ;; esac
case "$R" in *"pending=none"*) ok "…and \`pending=none\`: the state is not restart-pending at all" ;;
              *) bad "the record still carries a pending reason on a current box: $R" ;; esac
# The assertion that makes the one above non-vacuous: the stamp is NOT what answered. Point the stamp at a
# foreign commit and the answer must not move — an identity read from the stamp would follow it.
printf '{"commit": "%s"}\n' "$C3" > "$D/O/.agent-infra-stamp.json"
CTRL="$(start_ctrl "$TREE2")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R2="$(O="$D/O" CELL_HOME="$D/cellhome" HARNESS_PIN_DIR="$D/pinroot" HARNESS_PIN_FILE="$D/pinfile" \
      bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$D/O" 2>&1)"
stop_ctrl "$CTRL"
case "$R2" in *"relation=current"*"running=$(short "$C2")"*) ok "…and it does not follow the STAMP: a stamp naming a foreign commit leaves the verdict unchanged (the read is from the process)" ;;
              *) bad "the running identity followed the stamp — the #2641 defect wearing a different hat: $R2" ;; esac

_CASE=$((_CASE+1)); echo "=== A36b: a process that MENTIONS the harness path does not answer (invocation, not mention) ==="
D="$T/a36b"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
PIN="$D/cellhome/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"; printf '%s\n' "$TREE2" > "$D/pinfile"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
# A live process whose ARGUMENT is the controller script: the path is in the argv, the invocation is
# not. ⛔ THIS IS THE MEASURED FALSE POSITIVE, not a contrived one: cloud-cell-supervisor.sh records that
# a `bash -c` whose script text merely MENTIONS the path matched a substring test and read as a live
# controller. The shell is `bash` (so the shell-name bound does NOT save us) and the path is tok4 —
# only the POSITIONAL shape refuses it. (`sed`/`tail -f` were the first fixtures; both are refused by the
# shell-name bound as well, which would make this case pass for a reason other than the one it names.)
# ⛔ TWO COMMANDS, not one: bash EXECS a lone simple command (`bash -c 'sleep 300' <path>` collapses to
# `sleep 300` and the mention is gone — measured, and the case would then pass for the wrong reason).
bash -c 'sleep 300; :' "$TREE2/scripts/orchestrator-harness/orch-loop.sh" >/dev/null 2>&1 &
MENTION=$!; printf '%s\n' "$MENTION" > "$D/O/.orch.lock"
R="$(O="$D/O" CELL_HOME="$D/cellhome" HARNESS_PIN_DIR="$D/pinroot" HARNESS_PIN_FILE="$D/pinfile" \
      bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$D/O" 2>&1)"; RC=$?
stop_ctrl "$MENTION"
case "$R" in *"relation=restart-pending"*) ok "a MENTION (sed reading the script) does not answer: still restart-pending, never a blessed current" ;;
              *) bad "a process that only MENTIONS the path was accepted as the running controller: $R" ;; esac
case "$R" in *"pending=unprovable"*) ok "…and it says WHY: pending=unprovable (the stamp is a claim, not evidence)" ;;
              *) bad "the unprovable state is not named in the record: $R" ;; esac
# The refusal is RECORDED, not just printed — "refused because Y" is the requirement.
case "$(cat "$D/O/state/restart-request" 2>/dev/null)" in
  "restart request=refused"*"reason=running-identity-unprovable"*"actuation=blocked"*)
    ok "…and the request record says it REFUSED to ask for a restart, with the reason" ;;
  *) bad "no refused-request record: $(cat "$D/O/state/restart-request" 2>/dev/null)" ;;
esac

_CASE=$((_CASE+1)); echo "=== A36c: a tree OUTSIDE every recorded pin root does not answer (a peer repo's controller) ==="
D="$T/a36c"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
PIN="$D/cellhome/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"; printf '%s\n' "$TREE2" > "$D/pinfile"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
# A controller at C1 living in a harness dir that belongs to NO pin root on this box.
FOREIGN="$(harness_at "$C1")"
CTRL="$(start_ctrl "$(dirname "$FOREIGN")/..")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R="$(O="$D/O" CELL_HOME="$D/cellhome" HARNESS_PIN_DIR="$D/pinroot" HARNESS_PIN_FILE="$D/pinfile" \
      bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$D/O" 2>&1)"
stop_ctrl "$CTRL"
case "$R" in *"running=$(short "$C1")"*) bad "a FOREIGN tree answered for this box (running=$(short "$C1")) — a peer's controller certified this cell: $R" ;;
              *) ok "the foreign tree did NOT answer (running is not $(short "$C1"))" ;; esac
case "$R" in *"relation=restart-pending"*"pending=unprovable"*) ok "…and the verdict fails closed: restart-pending/unprovable, not current" ;;
              *) bad "expected restart-pending/unprovable over a foreign controller: $R" ;; esac

_CASE=$((_CASE+1)); echo "=== A36d: a pin-root child with no git identity cannot ascend into an enclosing worktree ==="
D="$T/a36d"; mkdir -p "$D/O/state" "$D/cellhome"
PIN="$D/cellhome/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN"
TREE2="$(mk_pin_tree "$T/src/pins" "$C2")"; printf '%s\n' "$TREE2" > "$D/pinfile"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
# The measured shape: a pin child that carries no git identity of its own (an `apply` that half-finished)
# and therefore sits INSIDE the `$T/src` checkout. A naive `rev-parse --show-toplevel` answers $T/src —
# whose HEAD is C3, a commit that is not even on the remote. That wrong answer is what this case refuses.
# ⛔ NOT a real worktree: a sha-shaped child of the pin root that carries NO git identity of its own
# (a half-finished `apply`). A real `git worktree add` child would resolve its own toplevel and the arm
# under test would never be reached — the case would pass for the wrong reason.
DEAD="$T/src/pins/feedfacecafe"
mkdir -p "$DEAD/scripts/orchestrator-harness"
printf 'sleep 300\n' > "$DEAD/scripts/orchestrator-harness/orch-loop.sh"
bash "$DEAD/scripts/orchestrator-harness/orch-loop.sh" >/dev/null 2>&1 &
CTRL=$!; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
# ⛔ THE PIN ROOT **IS** THE ENCLOSING CHECKOUT HERE, which is the DOCUMENTED legacy flat-pin layout
# ("the ROOT is the worktree", cloud-cell-bringup.sh). That is what makes this case discriminate: with
# the root-membership bound doing the work, the ascent would be refused anyway and the own-toplevel
# bound could be deleted without any test noticing (measured — the first version of this case stayed
# green with that bound removed). Here membership PASSES and only the own-toplevel bound refuses.
R="$(O="$D/O" CELL_HOME="$D/cellhome" HARNESS_PIN_DIR="$T/src" HARNESS_PIN_FILE="$D/pinfile" \
      bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$PIN" --self "$D/O" 2>&1)"
stop_ctrl "$CTRL"
case "$R" in *"running=$(short "$C3")"*) bad "a tree with no git identity ASCENDED into an enclosing worktree and reported ITS head ($(short "$C3")) — the own-toplevel bound is missing: $R" ;;
              *) ok "the git-less child did NOT ascend (running is not the enclosing checkout's $(short "$C3"))" ;; esac
case "$R" in *"relation=restart-pending"*"pending=unprovable"*) ok "…and it fails closed to restart-pending/unprovable" ;;
              *) bad "expected restart-pending/unprovable over an unreadable pin child: $R" ;; esac

_CASE=$((_CASE+1)); echo "=== A36e: an UNREADABLE process table is unprovable, never a blessed current ==="
D="$T/a36e"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
PIN="$D/cellhome/HARNESS-PIN"; printf '%s\n' "$C2" > "$PIN"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"; printf '%s\n' "$TREE2" > "$D/pinfile"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
CTRL="$(start_ctrl "$TREE2")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R="$(PS_BIN=/nonexistent/ps O="$D/O" CELL_HOME="$D/cellhome" HARNESS_PIN_DIR="$D/pinroot" \
      HARNESS_PIN_FILE="$D/pinfile" bash "$RR" --no-fetch --repo "$T/src" --ref origin/main \
      --pin "$PIN" --self "$D/O" 2>&1)"
stop_ctrl "$CTRL"
case "$R" in *"relation=current"*) bad "an unreadable ps produced 'current' — cannot-verify was read as a pass: $R" ;;
              *) ok "an unreadable process table does NOT produce current" ;; esac
case "$R" in *"pending=unprovable"*) ok "…it is named: pending=unprovable" ;;
              *) bad "expected pending=unprovable with ps unreadable: $R" ;; esac

# ── THE STATE MACHINE: deferred / safe / honoured ────────────────────────────────────────────────
# cell_case <D> <pin-sha> <pinroot> <pinfile-tree> <O> ; prints the script's output. `--self $O` is the
# flat seed a cell has (no git identity), which is what makes the controller arm the only readable one.
cell_case() {
  local D="$1" pinsha="$2" root="$3" ptree="$4" o="$5"
  local pin="$D/cellhome/HARNESS-PIN"
  printf '%s\n' "$pinsha" > "$pin"; printf '%s\n' "$ptree" > "$D/pinfile"
  O="$o" CELL_HOME="$D/cellhome" HARNESS_PIN_DIR="$root" HARNESS_PIN_FILE="$D/pinfile" \
    bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$pin" --self "$o" 2>&1
}

_CASE=$((_CASE+1)); echo "=== S1: a restart that IS needed with a lane in flight -> REQUESTED, actuation=blocked, lane named ==="
D="$T/s1"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE1="$(mk_pin_tree "$D/pinroot" "$C1")"; TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
CTRL="$(start_ctrl "$TREE1")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
# A lane wrapper in $O, as a real cell has (`lane.sh`, `fix-one.sh`, …): the argv population.
printf 'sleep 300\n' > "$D/O/lane.sh"; bash "$D/O/lane.sh" >/dev/null 2>&1 &
LANE=$!
R="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
case "$R" in *"relation=restart-pending"*"pending=deferred"*) ok "running=$(short "$C1") vs pin $(short "$C2") with a lane live: restart-pending, pending=deferred" ;;
              *) bad "expected restart-pending/deferred: $R" ;; esac
# ⛔ `pending=` and `actuation=` ARE TWO FIELDS, and the operator line is where they get conflated: the
# first draft printed `actuation=deferred`. A `deferred` REQUEST is `actuation=blocked` — the reason and
# the verdict must not swap places in the one sentence a human reads.
case "$R" in *"pending=deferred, actuation=blocked"*) ok "…and the operator line keeps pending= and actuation= distinct (deferred / blocked)" ;;
              *) bad "the prose conflates the pending reason with the actuation verdict: $R" ;; esac
REQB="$D/O/state/restart-request"
case "$(cat "$REQB" 2>/dev/null)" in
  "restart request=pending"*) ok "a REQUEST was recorded (the state has a transition, not just a word)" ;;
  *) bad "no request record was written: $(cat "$REQB" 2>/dev/null)" ;; esac
[ "$(req_of "$D/O" actuation)" = blocked ] && ok "actuation=blocked — the loop refuses to apply it" \
  || bad "actuation=$(req_of "$D/O" actuation), expected blocked"
[ "$(req_of "$D/O" blocked)" = lanes ] && ok "blocked=lanes — the population that blocks it is NAMED, not implied" \
  || bad "blocked=$(req_of "$D/O" blocked), expected lanes"
# ⛔ `pin=` must name the DEPLOYED TIP the process should be on (`RUN_SHORT` vs `pin` is the whole
# question), never the sha record and never `unknown` — a record that cannot say what it is waiting for
# is the same defect as a word with no transition.
[ "$(req_of "$D/O" pin)" = "$(short "$C2")" ] && ok "…and pin= names the deployed tip ($(short "$C2")) the restart would land on" \
  || bad "pin=$(req_of "$D/O" pin), expected $(short "$C2") — the record cannot say what it is waiting for"
case "$(cat "$REQB" 2>/dev/null)" in
  *"checked=argv,roles,tree"*) ok "…and the populations actually consulted are recorded (checked=argv,roles,tree)" ;;
  *) bad "the record does not say which populations were consulted: $(cat "$REQB" 2>/dev/null)" ;; esac
case "$(cat "$REQB" 2>/dev/null)" in
  *"blind=reparented-no-wrapper"*) ok "…and the DECLARED blind spot is recorded (a reparented lane child that runs no \$O/*.sh is in none of them)" ;;
  *) bad "the blind spot is undeclared — 'safe' would read as a guarantee: $(cat "$REQB" 2>/dev/null)" ;; esac
# The reader the requirement asks for: `--print-restart` answers without git, repo or network.
PR="$(O="$D/O" bash "$RR" --print-restart 2>&1)"
case "$PR" in "restart request=pending"*"pending=deferred"*) ok "--print-restart prints the same state (the reader needs no repo, no network)" ;;
              *) bad "--print-restart did not report the pending request: $PR" ;; esac
stop_ctrl "$LANE"; stop_ctrl "$CTRL"

_CASE=$((_CASE+1)); echo "=== S2: nothing in flight -> actuation=safe; a role pass ALONE is enough to block it ==="
D="$T/s2"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot" "$D/O/state/roles"
TREE1="$(mk_pin_tree "$D/pinroot" "$C1")"; TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
CTRL="$(start_ctrl "$TREE1")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
case "$R" in *"pending=safe"*) ok "no lane, no role pass, no controller child: pending=safe" ;;
              *) bad "expected pending=safe on an idle box: $R" ;; esac
[ "$(req_of "$D/O" actuation)" = safe ] && ok "actuation=safe — the request is addressed to an actuator, and this script still applies nothing" \
  || bad "actuation=$(req_of "$D/O" actuation), expected safe"
[ "$(req_of "$D/O" lanes)" = 0 ] && ok "lanes=0 is a MEASURED zero (the populations were read), not an absent field" \
  || bad "lanes=$(req_of "$D/O" lanes), expected a measured 0"
# …and ONE role lock (a reap/merge/hygiene pass, which merge-reminder.py already refuses to restart under)
# flips it to blocked. Without this arm, `actuation=safe` could be a constant.
mkdir -p "$D/O/state/roles/.reap.lock"; printf '%s|t\n' "$$" > "$D/O/state/roles/.reap.lock/own"
R="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
[ "$(req_of "$D/O" blocked)" = roles ] && ok "…a live role lock alone makes blocked=roles (the safe verdict is not a constant)" \
  || bad "with a live role lock, blocked=$(req_of "$D/O" blocked), expected roles — $R"
# ⛔ THE COUNT IS THE NUMBER OF LIVE ROLE PASSES, NOT THE NUMBER OF OUTPUT LINES. `role_pids` prints every
# owner SPACE-separated on ONE line, so a line count is 1 whenever ANY pass is live — two live passes used
# to be reported as "1 role pass(es) in flight (pids a,b)". The gate decision (`-gt 0`) was never wrong,
# so this witnesses the DISCLOSURE, which is what an operator reads to decide whether to wait.
mkdir -p "$D/O/state/roles/.merge.lock"; printf '%s|t\n' "$$" > "$D/O/state/roles/.merge.lock/own"
R="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
case "$R" in
  *"2 role pass(es)"*) ok "…and two live role passes are reported as TWO (a field count, not a line count)" ;;
  *"1 role pass"*) bad "two live role passes were reported as 1 — ROLE_N counted output LINES, so the count was always 1: $R" ;;
  *) bad "the record does not name the role count at all: $R" ;; esac
# ⛔ S2b: AN UNREADABLE / UNSIGNALABLE ROLE POPULATION IS NOT AN EMPTY ONE. `role_pids` ends with a
# `kill -0 … || continue`, and `kill -0` answers EPERM (rc 1) for a process that EXISTS but that this
# user may not signal — so a live reap/merge/hygiene pass owned by ANOTHER USER was skipped, the
# population read EMPTY, and `inflight_gate` answered `actuation=safe` over it. Driven with pid 1: it is
# always live and, on a non-root runner, always EPERM. `ps -p` is the second opinion that closes it.
# ⛔ THE ARM CANNOT BE DRIVEN AS ROOT (`kill -0 1` succeeds), so this case SAYS SO instead of passing
# quietly — a silently-vacuous case is the defect this suite records three times (A36g, A36o, A36h).
_CASE=$((_CASE+1)); echo "=== S2b: a live role owner this user may not signal still BLOCKS the actuation (EPERM is not gone) ==="
D="$T/s2b"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot" "$D/O/state/roles/.reap.lock"
TREE1="$(mk_pin_tree "$D/pinroot" "$C1")"; TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
printf '%s|t\n' 1 > "$D/O/state/roles/.reap.lock/own"     # a live owner we do not own
if kill -0 1 2>/dev/null; then
  echo "  ⚠️  NOT A WITNESS ON THIS HOST: running as $(id -un) can signal pid 1, so the EPERM arm is" \
       "unreachable here. The count assertion below still runs; the `ps -p` second opinion is not exercised."
else
  ok "the plant really is unsignalable by us (kill -0 1 → EPERM), so the arm under test is the one driven"
fi
ps -p 1 >/dev/null 2>&1 && ok "…and it provably EXISTS (ps -p 1 answers), which is what makes it an owner" \
                           || bad "pid 1 is not readable by ps on this host — the plant proves nothing"
CTRL="$(start_ctrl "$TREE1")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
stop_ctrl "$CTRL"
[ "$(req_of "$D/O" blocked)" = roles ] && ok "…an unsignalable but LIVE role owner makes blocked=roles, not actuation=safe" \
  || bad "an unsignalable live role owner was read as absent: actuation=$(req_of "$D/O" actuation) blocked=$(req_of "$D/O" blocked), expected blocked=roles — $R"

# ⛔ S2c: THE `--print-restart` DEFAULT MUST NAME THE DIRECTORY THE LOOP WROTE. `O` is
# `$CELL_HOME/orchestrator` (`cloud-cell-supervisor.sh:146`) or `$HOME/orchestrator` (`orch-loop.sh:37`)
# — NOT the pin's `$CELL_HOME/.pi/agent`. A default pointing at the pin's tree does not abstain; it
# asserts `request=none` about a box that HAS a request, a confident false absence. This is case A18's
# defect one directory over ("a bare $HOME default mended a file nothing reads"). Driven from an
# OPERATOR shell: `O` unset, so only the default can find the record.
_CASE=$((_CASE+1)); echo "=== S2c: --print-restart finds the record without O set (an operator shell is not the controller) ==="
D="$T/s2c"; mkdir -p "$D/cellhome/orchestrator/state" "$D/home"
printf 'restart request=pending requested_at=1700000000 requested_by=x running=aaaa11112222 pin=bbbb33334444 pending=deferred actuation=blocked blocked=lanes lanes=2 checked=argv,roles,tree blind=reparented-no-wrapper actuator=stop+apply+start\n' \
  > "$D/cellhome/orchestrator/state/restart-request"
PRU="$(env -u O CELL_HOME="$D/cellhome" HOME="$D/home" bash "$RR" --print-restart 2>&1)"
case "$PRU" in
  # ⛔ `$D/cellhome`, NOT `$CELL_HOME`: this is an ASSERTION MESSAGE, and `CELL_HOME` is unset in the
  # suite's own shell — under the `set -u` at the top of this file the reference ABORTED the entire
  # suite at this line (measured on origin/main 2026-10-28: 265 ✅, 0 ❌, then
  # `line 2062: CELL_HOME: unbound variable`, so every later case — the A36/S3 controller-identity
  # arms — never ran). A message must never be able to fail the run it is reporting on.
  "restart request=pending"*) ok "the default located $D/cellhome/orchestrator/state/restart-request — the record the loop writes" ;;
  *no-O-set*) bad "the operator-shell reader abstained instead of reading the record: $PRU" ;;
  *) bad "the reader asserted an absence about a box that HAS a request: $PRU" ;; esac
case "$PRU" in *"pending=deferred"*) ok "…and it printed the state verbatim, including pending=deferred" ;;
  *) bad "the record was not printed verbatim: $PRU" ;; esac
# The laptop shape: CELL_HOME unset, so the default must be $HOME/orchestrator (orch-loop.sh:37).
mkdir -p "$D/home/orchestrator/state"
printf 'restart request=honoured requested_at=1700000000 honoured_at=1700000400 after=400s was=aaaa11112222 now=bbbb33334444\n' \
  > "$D/home/orchestrator/state/restart-request"
PRH="$(env -u O -u CELL_HOME HOME="$D/home" bash "$RR" --print-restart 2>&1)"
case "$PRH" in "restart request=honoured"*) ok "…and with no CELL_HOME it reads \$HOME/orchestrator, the laptop controller's \$O" ;;
  *) bad "the laptop shape did not find \$HOME/orchestrator: $PRH" ;; esac
# …and with NOTHING to derive from it still ABSTAINS rather than inventing a path.
PRA="$(env -u O -u CELL_HOME -u HOME bash "$RR" --print-restart 2>&1)"
case "$PRA" in *no-O-set*) ok "…and with neither CELL_HOME nor HOME it abstains (unknown), it does not guess" ;;
  *) bad "an underivable O answered instead of abstaining: $PRA" ;; esac
# ⛔ AN ABSENT RECORD IS NOT `none`. Nothing has ever recorded a request, which is a DIFFERENT fact from
# "a cycle measured nothing pending" — and `none` is the fleet's measured-nothing word (`pending=none`).
# The absent arm must abstain and carry the distinction in `reason=`, or a consumer cannot tell the two
# apart. (Pinned because the absent arm shipped as `request=none` while this very block's comment said
# an absent record is not `none`.)
PRN="$(env -u O CELL_HOME="$D/norecord" HOME="$D/home" bash "$RR" --print-restart 2>&1)"
case "$PRN" in
  "restart request=unknown reason=no-cycle-has-recorded-one o="*) ok "…an ABSENT record abstains as unknown (never 'none'), and names the path it read" ;;
  "restart request=none"*) bad "an absent record answered request=none — 'nothing recorded yet' is indistinguishable from 'a cycle measured nothing pending': $PRN" ;;
  *) bad "unexpected answer for an absent record: $PRN" ;; esac
stop_ctrl "$CTRL"

_CASE=$((_CASE+1)); echo "=== S3: the transition is OBSERVABLE — requested at T, HONOURED at T+n when the process moves ==="
D="$T/s3"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE1="$(mk_pin_tree "$D/pinroot" "$C1")"; TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
CTRL="$(start_ctrl "$TREE1")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R1="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
case "$(cat "$D/O/state/restart-request" 2>/dev/null)" in
  "restart request=pending"*"requested_at="*) ok "cycle 1: a request is recorded with requested_at" ;;
  *) bad "cycle 1 recorded no request: $(cat "$D/O/state/restart-request" 2>/dev/null)" ;; esac
AT1="$(req_of "$D/O" requested_at)"
# The actuator does its job: the controller is relaunched ON THE PINNED TREE — exactly what
# `stop -> apply -> start` produces. Nothing else about the box changes.
stop_ctrl "$CTRL"
CTRL="$(start_ctrl "$TREE2")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R2="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
case "$R2" in *"relation=current"*) ok "cycle 2: the box is current now (running == pin)" ;;
              *) bad "cycle 2 did not report current: $R2" ;; esac
RQ="$(cat "$D/O/state/restart-request" 2>/dev/null)"
case "$RQ" in
  "restart request=honoured"*) ok "…and the request became request=honoured — the transition is recorded, not inferred" ;;
  *) bad "the honoured transition was not recorded: $RQ" ;; esac
case "$RQ" in *"was=$(short "$C1")"*"now=$(short "$C2")"*) ok "…naming both ends (was=$(short "$C1") now=$(short "$C2"))" ;;
              *) bad "the honoured record does not name what moved: $RQ" ;; esac
case "$RQ" in *"after="*s*) ok "…and how long it took (after=<n>s)" ;;
              *) bad "the honoured record carries no interval: $RQ" ;; esac
[ "$(req_of "$D/O" requested_at)" = "$AT1" ] && ok "…and requested_at is the ORIGINAL ask, not the cycle that noticed" \
  || bad "requested_at moved from '$AT1' to '$(req_of "$D/O" requested_at)' — the clock reset, so 'pending for days' is unreadable"
stop_ctrl "$CTRL"

# ⛔ S4: ONLY AN OUTSTANDING `pending` MAY BE HONOURED. Without the `prev_req = pending` guard, ANY prior
# record whose `running=` differs from the current one is certified `honoured` — so a `refused` record,
# which is NOT an ask, would be closed out as a restart that HAPPENED.
# ⛔ THE PRIOR MUST BE FACT-SOURCED (`running_from=self:`), NOT `stamp:`-SOURCED. The claim bound (S6)
# clears a `stamp:` prior before this guard is ever consulted, so a `stamp:` fixture would let this case
# stay GREEN with the guard deleted — measured: guard removed + `stamp:` fixture = 289 passed / 0 failed.
# A `self:` prior isolates the `prev_req` bound, which is the only thing this case is here to witness.
_CASE=$((_CASE+1)); echo "=== S4: a refused record is never certified honoured (only an outstanding pending can be) ==="
D="$T/s4"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
printf 'restart request=refused reason=running-identity-unprovable requested_at=1700000000 refused_at=1700000060 requested_by=harness-refresh.sh@%s running=%s running_from=self:%s pin=%s pending=unprovable actuation=blocked blocked=identity actuator=none\n' \
  "$(short "$C1")" "$(short "$C1")" "$D/O" "$(short "$C2")" > "$D/O/state/restart-request"
CTRL="$(start_ctrl "$TREE2")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R4="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
stop_ctrl "$CTRL"
R4Q="$(cat "$D/O/state/restart-request" 2>/dev/null)"
case "$R4" in *"relation=current"*) ok "the fixture really is current, so the honoured arm is reachable (the bait is live)" ;;
              *) bad "the box was not current, so this case proves nothing about the honour guard: $R4" ;; esac
case "$R4Q" in
  "restart request=honoured"*) bad "a REFUSED record was certified 'honoured' on an identity-source move — a restart that never happened: $R4Q" ;;
  "restart request=cleared"*) ok "…a refused record is CLEARED, not honoured — no restart is certified that did not happen" ;;
  *) bad "unexpected record after a refused prior: $R4Q" ;; esac
case "$R4Q" in *"reason=no-longer-pending"*) ok "…and the reason says the premise went away, not that the process moved" ;;
  *) bad "the cleared record does not say why it was cleared: $R4Q" ;; esac

# ⛔ S5: AN `unprovable` CYCLE MUST NOT DISCARD AN OUTSTANDING REQUEST, NOR RESET ITS CLOCK. This branch
# used to OVERWRITE a `pending` record with `refused`, so one unreadable-identity cycle made the ask
# VANISH from the file an actuator polls, and the next pending cycle restarted `requested_at` — which the
# code's own comment forbids ("requested_at is the FIRST ask … never reset the clock"). Reachable with no
# exotic config: `apply` rewrites the pin, and one unreadable `ps` cycle is enough. Driven through the
# `PS_BIN` seam, which makes `controller_identity` unreadable while the record is still `pending`.
_CASE=$((_CASE+1)); echo "=== S5: an unprovable cycle keeps the outstanding request and its clock (PS_BIN unreadable) ==="
D="$T/s5"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
# The pin-per-commit cell shape the request is recorded on: write the pin (as `cell_case` does) so the
# cycle reaches the restart-request stage instead of trying to ADVANCE an empty pin.
printf '%s\n' "$C2" > "$D/cellhome/HARNESS-PIN"; printf '%s\n' "$TREE2" > "$D/pinfile"
printf '{"commit": "%s"}\n' "$C1" > "$D/O/.agent-infra-stamp.json"
# The FIRST ask, an hour and a half before this cycle: a reset to `now` must red.
printf 'restart request=pending requested_at=1600000000 requested_by=harness-refresh.sh@%s running=%s running_from=stamp:%s pin=%s pending=deferred actuation=blocked blocked=lanes lanes=1 checked=argv,roles,tree blind=reparented-no-wrapper actuator=stop+apply+start\n' \
  "$(short "$C1")" "$(short "$C1")" "$(short "$C1")" "$(short "$C2")" > "$D/O/state/restart-request"
CTRL="$(start_ctrl "$TREE2")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R5="$(O="$D/O" CELL_HOME="$D/cellhome" HARNESS_PIN_DIR="$D/pinroot" HARNESS_PIN_FILE="$D/pinfile" PS_BIN=/nonexistent/ps \
      bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$D/cellhome/HARNESS-PIN" --self "$D/O" 2>&1)"
stop_ctrl "$CTRL"
R5Q="$(cat "$D/O/state/restart-request" 2>/dev/null)"
case "$R5" in *"pending=unprovable"*) ok "the fixture really drove the unprovable arm (an unreadable identity)" ;;
              *) bad "the unprovable arm was not reached, so this case proves nothing: $R5" ;; esac
case "$R5Q" in
  "restart request=pending"*) ok "…the outstanding request SURVIVES as request=pending (an actuator polling the file still sees the ask)" ;;
  "restart request=refused"*) bad "an unprovable cycle OVERWROTE the outstanding request with 'refused' — the ask vanished from the file an actuator polls: $R5Q" ;;
  *) bad "unexpected record after an unprovable cycle: $R5Q" ;; esac
[ "$(req_of "$D/O" requested_at)" = 1600000000 ] && ok "…and requested_at is still the FIRST ask (1600000000), not this cycle's now" \
  || bad "requested_at became '$(req_of "$D/O" requested_at)' — the clock reset, so a long-pending ask reads as a fresh one"
case "$R5Q" in *"identity=unprovable"*) ok "…and the record still discloses WHY it cannot be proven" ;;
  *) bad "the pending record does not disclose the unprovable identity: $R5Q" ;; esac

# ⛔ S6: A MOVE OUT OF A CLAIM IS NOT A RESTART — EVEN WHEN THE PROCESS REALLY IS ON THE PIN NOW. S5 leaves
# exactly this shape behind: an `unprovable` cycle writes `request=pending … running_from=stamp:<C1>`, so
# the FIRST readable cycle afterwards sees an outstanding ask whose recorded identity was a CLAIM. If that
# cycle then reports `honoured`, the record certifies a restart nobody observed — the identity SOURCE moved
# (stamp -> controller), which is not the process moving. This is the case that made the bound NON-INERT:
# the guard was first written `[ "$x" != stamp:* ]`, which is always TRUE (`[`/test does no pattern
# matching — only `[[ ]]` and `case` do), so it read as protection while permitting precisely this.
_CASE=$((_CASE+1)); echo "=== S6: a pending ask recorded against a STAMP claim is cleared, never certified honoured ==="
D="$T/s6"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C1" > "$D/O/.agent-infra-stamp.json"
printf 'restart request=pending requested_at=1700000000 requested_by=harness-refresh.sh@%s running=%s running_from=stamp:%s pin=%s pending=unprovable identity=unprovable actuation=blocked blocked=identity lanes=unknown checked=argv,roles,tree blind=reparented-no-wrapper actuator=stop+apply+start\n' \
  "$(short "$C1")" "$(short "$C1")" "$(short "$C1")" "$(short "$C2")" > "$D/O/state/restart-request"
CTRL="$(start_ctrl "$TREE2")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R6="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
stop_ctrl "$CTRL"
R6Q="$(cat "$D/O/state/restart-request" 2>/dev/null)"
case "$R6" in *"relation=current"*) ok "the box is current with the controller on the pinned tree, so the bait is live (the mock restart really did happen)" ;;
              *) bad "the box was not current, so this case proves nothing about the claim bound: $R6" ;; esac
case "$R6Q" in
  "restart request=honoured"*) bad "a move OUT OF A STAMP CLAIM was certified 'honoured' — an identity-source change recorded as a restart that happened: $R6Q" ;;
  "restart request=cleared"*) ok "…a pending ask recorded against a CLAIM is CLEARED (the process was not observed to move), never honoured" ;;
  *) bad "unexpected record after a claim-sourced prior: $R6Q" ;; esac
case "$R6Q" in *"reason=no-longer-pending"*) ok "…and the reason names the premise going away, not a move" ;;
  *) bad "the cleared record does not say why it was cleared: $R6Q" ;; esac

# ⛔ S7: A RE-PIN ONTO THE COMMIT ALREADY RUNNING IS NOT A MOVE. With the `prev_run != RUN_SHORT` clause
# dropped, an outstanding ask whose recorded `running=` EQUALS the current one is certified `honoured` —
# `was == now`, a restart recorded when nothing moved. That clause had no witness. The prior here is
# FACT-sourced (`controller:`) and `pending`, so neither the claim bound (S6) nor the refused guard (S4)
# can explain a green: only `prev_run != RUN_SHORT` stands between this fixture and a false honour.
_CASE=$((_CASE+1)); echo "=== S7: a re-pin onto the commit already running certifies no move (was == now is not honoured) ==="
D="$T/s7"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
printf 'restart request=pending requested_at=1700000000 requested_by=harness-refresh.sh@%s running=%s running_from=controller:pid=1@/nonexistent pin=%s pending=deferred actuation=blocked blocked=lanes lanes=1 checked=argv,roles,tree blind=reparented-no-wrapper actuator=stop+apply+start\n' \
  "$(short "$C2")" "$(short "$C2")" "$(short "$C2")" > "$D/O/state/restart-request"
CTRL="$(start_ctrl "$TREE2")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R7="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
stop_ctrl "$CTRL"
R7Q="$(cat "$D/O/state/restart-request" 2>/dev/null)"
case "$R7" in *"relation=current"*) ok "the box is current, so the honoured arm is reachable (the bait is live)" ;;
              *) bad "the box was not current, so this case proves nothing about the move test: $R7" ;; esac
case "$R7Q" in
  "restart request=honoured"*) bad "a record whose was == now was certified 'honoured' — a restart recorded with nothing moving: $R7Q" ;;
  "restart request=cleared"*) ok "…was == now is CLEARED, not honoured (the process was not observed to move)" ;;
  *) bad "unexpected record when nothing moved: $R7Q" ;; esac

# ⛔ S8: THE CONTROLLER GOING AWAY IS ITS OWN TRANSITION (`reason=no-live-controller`). The `inert` arm is
# reached by `|| [ "$PENDING" = inert ]` in the OUTER condition; without that clause the whole block is
# skipped for a box whose relation is still `restart-pending`, and the documented `no-live-controller`
# transition becomes unreachable — the ask then reads `pending=inert` for ever on a box with nothing to
# restart. No `.orch.lock` here: that IS the inert shape.
_CASE=$((_CASE+1)); echo "=== S8: with no live controller the outstanding request is CLEARED as no-live-controller ==="
D="$T/s8"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C1" > "$D/O/.agent-infra-stamp.json"
printf 'restart request=pending requested_at=1700000000 requested_by=harness-refresh.sh@%s running=%s running_from=stamp:%s pin=%s pending=deferred actuation=blocked blocked=lanes lanes=1 checked=argv,roles,tree blind=reparented-no-wrapper actuator=stop+apply+start\n' \
  "$(short "$C1")" "$(short "$C1")" "$(short "$C1")" "$(short "$C2")" > "$D/O/state/restart-request"
R8="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
R8Q="$(cat "$D/O/state/restart-request" 2>/dev/null)"
case "$R8" in *"relation=restart-pending"*) ok "the fixture reached restart-pending with no controller, so the inert arm is the one exercised" ;;
              *) bad "the fixture did not reach restart-pending, so this case is vacuous: $R8" ;; esac
case "$R8Q" in
  *"reason=no-live-controller"*) ok "…the request is CLEARED as no-live-controller (nothing to restart, so nothing outstanding)" ;;
  *"pending=inert"*) bad "the ask survived as pending=inert on a box with no controller — it can never be cleared: $R8Q" ;;
  *) bad "unexpected record with no live controller: $R8Q" ;; esac

# ⛔ S9: A `refused` RECORD IS ALSO A PRIOR ASK, so its `requested_at` must carry forward into the next
# `pending` cycle. Dropping `refused` from that pattern resets the clock to `now`, which is the S5 defect
# one branch over: an ask refused once and then re-requested reads as brand new instead of `waited=` days.
# S5 cannot cover it — the record it preserves is `pending`, never `refused`.
_CASE=$((_CASE+1)); echo "=== S9: a refused record's requested_at carries into the next pending cycle (no clock reset) ==="
D="$T/s9"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE1="$(mk_pin_tree "$D/pinroot" "$C1")"; TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C1" > "$D/O/.agent-infra-stamp.json"
printf 'restart request=refused reason=running-identity-unprovable requested_at=1600000000 refused_at=1600000060 requested_by=harness-refresh.sh@%s running=%s running_from=stamp:%s pin=%s pending=unprovable actuation=blocked blocked=identity actuator=none\n' \
  "$(short "$C1")" "$(short "$C1")" "$(short "$C1")" "$(short "$C2")" > "$D/O/state/restart-request"
CTRL="$(start_ctrl "$TREE1")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
# The pin names the NEW tree (C2) while the controller still executes C1 — the ordinary restart-pending
# shape S3 uses; passing TREE1 as the pinfile would make the box `behind` and never reach the ask.
R9="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
stop_ctrl "$CTRL"
R9Q="$(cat "$D/O/state/restart-request" 2>/dev/null)"
case "$R9" in *"relation=restart-pending"*) ok "the fixture re-entered restart-pending, so the ask is live again" ;;
              *) bad "the fixture did not reach restart-pending, so this case is vacuous: $R9" ;; esac
case "$R9Q" in "restart request=pending"*) ok "…a new request is recorded" ;;
  *) bad "no pending request was recorded: $R9Q" ;; esac
[ "$(req_of "$D/O" requested_at)" = 1600000000 ] && ok "…and requested_at is still the REFUSED record's first ask (1600000000), not this cycle's now" \
  || bad "requested_at became '$(req_of "$D/O" requested_at)' — the clock reset across a refused cycle"

# ⛔ S10: NOTHING OUTSTANDING MEANS NOTHING TO WRITE. After an `honoured` record there is no ask, so a
# later current cycle must LEAVE THE RECORD ALONE — the `case "$prev_req" in pending|refused)` guard is
# what stops a routine cycle from overwriting the `honoured` history with a `cleared` line, which would
# erase the very transition this record exists to make readable.
_CASE=$((_CASE+1)); echo "=== S10: an honoured record is not overwritten by a later routine cycle (nothing outstanding) ==="
D="$T/s10"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
printf 'restart request=honoured requested_at=1600000000 honoured_at=1600000400 after=400s requested_by=harness-refresh.sh@%s was=%s now=%s\n' \
  "$(short "$C1")" "$(short "$C1")" "$(short "$C2")" > "$D/O/state/restart-request"
CTRL="$(start_ctrl "$TREE2")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R10="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
stop_ctrl "$CTRL"
R10Q="$(cat "$D/O/state/restart-request" 2>/dev/null)"
case "$R10" in *"relation=current"*) ok "the routine cycle ran and the box is current, so a write would have happened" ;;
               *) bad "the box was not current, so this case is vacuous: $R10" ;; esac
case "$R10Q" in
  "restart request=honoured"*) ok "…and the honoured record is UNTOUCHED — nothing outstanding, nothing written" ;;
  *) bad "a routine cycle overwrote the honoured record (nothing was outstanding, so nothing should have been written): $R10Q" ;; esac

# ⛔ S11: A ROLES DIRECTORY THAT EXISTS BUT CANNOT BE LISTED IS `unknown`, NOT EMPTY. The `-r`/`-x`
# guard's absence is the fail-open it was written for: the glob does not expand, the loop prints nothing,
# `ROLE_N` lands 0, and the gate answers `actuation=safe` over a LIVE role pass. That guard was itself
# unwitnessed until this case. chmod 000 is the faithful shape; under uid 0 it is still listable, so the
# case DECLARES that instead of passing quietly.
_CASE=$((_CASE+1)); echo "=== S11: an unlistable state/roles is roles-unreadable, not an empty population ==="
D="$T/s11"; mkdir -p "$D/O/state/roles/.reap.lock" "$D/cellhome" "$D/pinroot"
TREE1="$(mk_pin_tree "$D/pinroot" "$C1")"; TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "%s"}\n' "$C2" > "$D/O/.agent-infra-stamp.json"
printf '%s|t\n' "$$" > "$D/O/state/roles/.reap.lock/own"     # a LIVE role pass that must not be missed
chmod 000 "$D/O/state/roles" 2>/dev/null
CTRL="$(start_ctrl "$TREE1")"; printf '%s\n' "$CTRL" > "$D/O/.orch.lock"
R11="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
stop_ctrl "$CTRL"
if [ -r "$D/O/state/roles" ]; then
  echo "  ⚠️  NOT A WITNESS ON THIS HOST: uid $(id -u) can still list a 000 directory, so the" \
       "unlistable arm is unreachable here. The assertion below still runs. (CI runs as a non-root uid.)"
else
  ok "the plant really is unlistable by us, so the arm under test is the one driven"
fi
[ "$(req_of "$D/O" blocked)" = roles-unreadable ] && ok "…blocked=roles-unreadable and actuation=$(req_of "$D/O" actuation) — a live role pass is never read as an empty population" \
  || bad "an unlistable state/roles was read as EMPTY: blocked=$(req_of "$D/O" blocked) actuation=$(req_of "$D/O" actuation), expected blocked=roles-unreadable — $R11"
chmod 755 "$D/O/state/roles" 2>/dev/null

# ⛔ S12: THE CLAIM BOUND IS TWO-SIDED, AND THE SECOND SIDE HAD NO WITNESS. S6 covers a `stamp:` on the
# PRIOR end; this covers a `stamp:` on the CURRENT end — the case `:953-955` states as "on EITHER side".
# Without it, a box with NO controller and an identity that resolves only from the stamp's CLAIM certifies
# `honoured` with `now=unknown`: a restart recorded from a claim, which is the one thing the contract
# forbids. No `.orch.lock` (no controller), and the stamp names UNKNOWN so the current identity is a claim.
_CASE=$((_CASE+1)); echo "=== S12: a CLAIM on the current end is not a move either (no controller, stamp=UNKNOWN) ==="
D="$T/s12"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
printf '{"commit": "UNKNOWN"}\n' > "$D/O/.agent-infra-stamp.json"
printf 'restart request=pending requested_at=1700000000 requested_by=harness-refresh.sh@%s running=%s running_from=self:%s pin=%s pending=deferred actuation=blocked blocked=lanes lanes=1 checked=argv,roles,tree blind=reparented-no-wrapper actuator=stop+apply+start\n' \
  "$(short "$C1")" "$(short "$C1")" "$D/O" "$(short "$C2")" > "$D/O/state/restart-request"
R12="$(cell_case "$D" "$C2" "$D/pinroot" "$TREE2" "$D/O")"
R12Q="$(cat "$D/O/state/restart-request" 2>/dev/null)"
case "$R12" in *"relation=current"*) ok "the box is current with no controller, so the honour arm is reachable (the bait is live)" ;;
               *) bad "the fixture did not reach the honour arm, so this case is vacuous: $R12" ;; esac
case "$R12Q" in
  "restart request=honoured"*) bad "a restart was certified from a STAMP claim on the current end — no controller exists and now= is not even a commit: $R12Q" ;;
  "restart request=cleared"*) ok "…a claim on the CURRENT end is CLEARED, not honoured" ;;
  *) bad "unexpected record when the current identity is a claim: $R12Q" ;; esac

# ⛔ S13: THE TMUX LAUNCHER'S ARGV **QUOTES** THE SCRIPT PATH, AND NO OTHER CASE HAS A QUOTE IN ARGV.
# Both readers dequote before comparing (`:563` in the source-2 split, `:405` in `controller_identity`), and
# both comments call this the real cell shape — yet every other plant is launched as
# `bash "<path>"`, so until this case the dequote could be deleted with the suite green. `COLUMNS=20`
# rides along because the same read needs `-ww`: an exported COLUMNS truncates the command column and the
# path is the LAST token, so without `-ww` the quoted operand is cut mid-name and the stage gives up
# silently (#2926). One plant, two bounds.
#   ⛔ `exec -a bash yes` — `yes` never OPENS its operand (so the quoted string really survives in the
#   process table) and never exits (so `ps` has something to read). `exec -a` is what puts a SHELL name in
#   argv[0] while argv[1] stays a quoted path; a plain `bash '<path>'` would try to open a file whose name
#   contains quotes and exit immediately.
#   ⛔ WHAT THIS CASE DOES **NOT** PROVE, SAID PLAINLY: the dequote and `-ww` each exist in TWO copies (the
#   source-2 reader and `controller_identity`), they are the SAME predicate, and on this fixture each copy
#   answers for the other — measured: removing EITHER dequote alone leaves 304/0, removing BOTH reddens
#   this case; same for `-ww` (both removed reddens this case AND A36i). So this is an AGGREGATE witness
#   of the bound, not a per-copy one. That is a property of the redundant readers, not of the case: do not
#   "tidy" one copy away believing the other is covered — the suite cannot tell you it was.
_CASE=$((_CASE+1)); echo "=== S13: a QUOTED argv path still resolves under COLUMNS (dequote + ps -ww) ==="
D="$T/s13"; mkdir -p "$D/O/state" "$D/cellhome" "$D/pinroot"
TREE2="$(mk_pin_tree "$D/pinroot" "$C2")"
# ⛔ THE PIN MUST EXIST BEFORE THE RUN. Without it the cycle is in MEND mode and `running=` comes from the
# tip, so the case passed while reading NEITHER argv reader — a green that witnessed nothing (caught by
# mutating the dequote and `-ww` and watching the suite stay green). Stamp names C1 so a failed argv read
# is distinguishable from a successful one: C2 means the controller's tree answered, C1 means it did not.
printf '%s\n' "$C2" > "$D/cellhome/HARNESS-PIN"; printf '%s\n' "$TREE2" > "$D/pinfile"
printf '{"commit": "%s"}\n' "$C1" > "$D/O/.agent-infra-stamp.json"
_Q="$TREE2/scripts/orchestrator-harness/orch-loop.sh"
bash -c 'exec -a bash yes "$1"' _ "'$_Q'" >/dev/null 2>&1 & _PQ=$!
sleep 1
case "$(COLUMNS=20 ps -ww -o command= -p "$_PQ" 2>/dev/null)" in
  # ⛔ THE PATTERN MUST CONTAIN REAL GLOBS (`*` OUTSIDE the quotes): a fully-quoted pattern in `case` is
  # LITERAL, so `"bash '*"` would match the six characters `bash '*` and nothing else — the same
  # inert-match class this whole change exists to remove.
  *"bash '"*) ok "the plant's argv[0] is a shell and argv[1] really is the QUOTED path (the allow-list cannot be what rejects it)" ;;
  *) bad "the plant did not keep a quoted path in argv[1]: $(ps -ww -o command= -p "$_PQ" 2>/dev/null)" ;; esac
printf '%s\n' "$_PQ" > "$D/O/.orch.lock"
R13="$(O="$D/O" CELL_HOME="$D/cellhome" HARNESS_PIN_DIR="$D/pinroot" COLUMNS=20 \
        bash "$RR" --no-fetch --repo "$T/src" --ref origin/main --pin "$D/cellhome/HARNESS-PIN" --self "$D/O" 2>&1)"
rm -f "$D/O/.orch.lock"; reap "$_PQ"
case "$R13" in *"running=$(short "$C2")"*) ok "…the QUOTED path resolved to the tree the controller executes (dequoted, and not truncated)" ;;
               *"running=$(short "$C1")"*) bad "a quoted argv path fell back to the stamp — the dequote (or -ww) is missing, which is #2641 back on every cell: $R13" ;;
               *) bad "the record named neither tree: $R13" ;; esac

# ⛔ S14: THE ADVANCE PATH MUST MAKE THE SAME CANNOT-VERIFY DOWNGRADE AS THE CURRENT-PIN PATH. This is the
# branch where the pin has just moved, and `RUNNING` can be the stamp's CLAIM naming the NEW tip while the
# controller still executes the OLD tree. ⛔ THE STAMP IS NOT REWRITTEN BY THIS CYCLE: the default advance
# is `apply --force --pin-only`, which leaves `$O` (and the stamp) alone — a stamp naming the tip is written
# by `start`'s `seed_and_stamp`, a `--re-seed` advance, or a hand seed, and it is only ever a CLAIM about
# what was SEEDED. The advance branch used to compare `RUNNING` to `TIP` alone and report `current`: a false
# PASS with no `pending=` on the spawn line and no request recorded. Driven with an unreadable identity
# (`PS_BIN=/nonexistent/ps`) so the only source left is the stamp, planted naming the TIP while the pin
# names an older commit — the shape a cell is in after a previous `start` seeded `$O` ahead of a re-pin.
_CASE=$((_CASE+1)); echo "=== S14: a stamp-only identity naming the tip is NOT 'current' on the advance path ==="
D="$T/s14"; mkdir -p "$D/o/state" "$D/pin" "$D/mat"
PIN="$D/pin/HARNESS-PIN"; printf '%s\n' "$C1" > "$PIN"     # behind the tip, so the advance fires
printf '{"commit": "%s"}\n' "$C2" > "$D/o/.agent-infra-stamp.json"   # the claim `apply` writes = the NEW tip
printf '%s\n' "$$" > "$D/o/.orch.lock"                      # a LIVE controller, as on every box
MAT="$(mk_stub_mat "$D/mat")"
R14="$(O="$D/o" PS_BIN=/nonexistent/ps HARNESS_MATERIALISER="$MAT" bash "$RR" --no-fetch --repo "$T/src" \
        --ref origin/main --pin "$PIN" --self "$D/o" 2>&1)"; RC14=$?
case "$RC14" in 10) ok "the fixture really took the ADVANCE path (exit 10), so the branch under test is the one driven" ;;
                *) bad "expected exit 10 (an advance) with a behind pin, got $RC14 — the case would be vacuous: $R14" ;; esac
case "$R14" in
  *"relation=current"*) bad "a stamp-only identity naming the tip was reported CURRENT on the advance path — the controller may still execute the old tree, and no request was recorded: $R14" ;;
  *"relation=restart-pending"*) ok "…a stamp-only identity is restart-pending on the advance path too (cannot-verify is not a pass)" ;;
  *) bad "the record named neither relation: $R14" ;; esac
case "$R14" in
  *"already on $(short "$C2")"*) bad "the prose asserted the controller is 'already on' the tip from a CLAIM: $R14" ;;
  *) ok "…and the prose does NOT claim the controller is already on the new commit" ;; esac

_CASE=$((_CASE+1)); echo "=== B6: the spawn-line token carries WHICH pending state (and stays bare for every other relation) ==="
D="$T/b6"; mkdir -p "$D/O/state" "$D/O/logs"
cat > "$D/O/harness-refresh.sh" <<'SH'
#!/bin/bash
echo "harness relation=restart-pending running=111111111111 ref=222222222222 pin=111111111111 action=none pending=deferred"
exit 0
SH
chmod +x "$D/O/harness-refresh.sh"
(
  O="$D/O"; LOG="$D/O/logs/orch-loop.log"; HARNESS_REF=origin/main; : > "$LOG"
  . "$BLK/block.sh"; harness_refresh_cycle; printf 'T=%s\n' "$HARNESS_TOKEN" > "$D/tok"
)
[ "$(cat "$D/tok")" = "T=restart-pending:deferred:111111111111" ] \
  && ok "the token names the state AND why (restart-pending:deferred:<running>)" \
  || bad "token was '$(cat "$D/tok")', expected T=restart-pending:deferred:111111111111"
grep -q 'pending=deferred' "$D/O/state/harness-refresh" 2>/dev/null \
  && ok "…and the per-cycle record keeps the field for later readers" \
  || bad "state/harness-refresh dropped the pending field"
# A non-restart relation that also reports pending=none must NOT grow the field on the token: a constant
# segment on every line is the always-on shape this whole change removes.
cat > "$D/O/harness-refresh.sh" <<'SH'
#!/bin/bash
echo "harness relation=behind running=111111111111 ref=222222222222 pin=111111111111 action=refused pending=none"
exit 25
SH
(
  O="$D/O"; LOG="$D/O/logs/orch-loop.log"; HARNESS_REF=origin/main; _HR_DONE=0
  . "$BLK/block.sh"; harness_refresh_cycle; printf 'T=%s\n' "$HARNESS_TOKEN" > "$D/tok2"
)
[ "$(cat "$D/tok2")" = "T=behind:111111111111" ] \
  && ok "…and every other relation keeps the bare <relation>:<running> token (no ':none' grew on it)" \
  || bad "token was '$(cat "$D/tok2")', expected T=behind:111111111111"

echo
# ⛔ A SWALLOWED BLOCK IS A SILENT SKIP. Found in review round 3: ONE unbalanced quote turned the A15-A17
# blocks into an argument of a `bad` that never ran, and the suite still printed "68 passed, 0 failed" —
# green, while the only assertions for three of the fixes under test did not execute. The expected count
# is derived from THIS FILE, so a block that stops running cannot hide behind a passing suite.
_CASE_EXPECT=$(grep -c '^_CASE=$((_CASE+1)); echo "=== ' "$0")
[ "$_CASE" = "$_CASE_EXPECT" ] \
  && ok "every case block ran ($_CASE of $_CASE_EXPECT — an unbalanced quote cannot skip one silently)" \
  || bad "only ${_CASE:-0} of $_CASE_EXPECT case block(s) executed — a quote/paren fault skipped one silently"

echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
