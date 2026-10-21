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
T="$(mktemp -d "${TMPDIR:-/tmp}/harness-refresh.XXXXXX")"
trap 'rm -rf "$T"' EXIT
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
kill "$LANEPID" 2>/dev/null || true

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
kill "$LANEPID" 2>/dev/null || true

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
kill "$LANEPID" 2>/dev/null || true

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
setsid bash -c 'sleep 30; :' orc-log "$D/O/logs/orch-loop.log" >/dev/null 2>&1 & LOGCALLER=$!
setsid bash -c 'sleep 30; :' orc-ctl "$D/O/orch-loop.sh" >/dev/null 2>&1 & CTLPID=$!
# …and a `.sh` in a SUBDIRECTORY of $O: a lane is `$O/<name>.sh`, so the subdirectory guard (not the
# `.sh` suffix) is what excludes it — without the plant, that guard is untested and removing it is green.
setsid bash -c 'sleep 30; :' orc-sub "$D/O/logs/helper.sh" >/dev/null 2>&1 & SUBPID=$!
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
kill "$LANEPID" 2>/dev/null || true

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
kill "$LANEPID" 2>/dev/null || true

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
D="$T/c2"; mkdir -p "$D/bin" "$D/O" "$D/repo/.worktrees"
printf '#!/bin/bash\nexit 0\n'       > "$D/bin/git";    chmod +x "$D/bin/git"
printf '#!/bin/bash\nexit 0\n'       > "$D/bin/tmux";   chmod +x "$D/bin/tmux"
printf '#!/bin/bash\nexit 0\n'       > "$D/bin/sleep";  chmod +x "$D/bin/sleep"
printf '#!/bin/bash\necho load\n'    > "$D/bin/uptime"; chmod +x "$D/bin/uptime"
for f in lane.sh merge-one.sh chain-merge.sh claims.sh; do : > "$D/O/$f"; done
SPAWN="$(PATH="$D/bin:$PATH" O="$D/O" HARNESS_TOKEN="behind:111111111111" \
        bash "$DM" "$D/repo" owner/repo 7 2>&1 | grep 'lane-7')"
case "$SPAWN" in *"[harness=behind:111111111111]"*) ok "the lane-7 spawn line names the behind checkout" ;;
                  *) bad "the lane spawn line does not disclose it: '$SPAWN'" ;; esac
# An ABSENT token must not read as "current": the default is the honest unknown.
SPAWN2="$(PATH="$D/bin:$PATH" O="$D/O" bash "$DM" "$D/repo" owner/repo 8 2>&1 | grep 'lane-8')"
case "$SPAWN2" in *"[harness=unknown]"*) ok "an unsupplied token reads as unknown, never as current" ;;
                   *) bad "an absent token printed '$(printf '%s' "$SPAWN2" | tr -d '\n')'" ;; esac
# ⛔ AND AN EMPTY TOKEN IS A REAL ANSWER (the box is current), NOT AN ABSENT ONE. `${TOKEN:-unknown}`
# collapses the two, so every HEALTHY box stamped `[harness=unknown]` — the marker a reader needs in
# order to spot a stale box would then be present always, and therefore read never.
ALL9="$(PATH="$D/bin:$PATH" O="$D/O" HARNESS_TOKEN="" bash "$DM" "$D/repo" owner/repo 9 2>&1)"
case "$ALL9" in *harness=*) bad "an EMPTY (current) token still stamped a spawn line: '$(printf '%s' "$ALL9" | grep -o '\[harness=[^]]*\]' | head -1)'" ;;
                  *) ok "…and an EMPTY (current) token leaves BOTH spawn lines clean (lane- and chain-) — only UNSET is unknown" ;; esac
# The chain- line is a SECOND spawn path, and it used to stamp unconditionally: `[harness=]` on every
# current box, which is exactly the always-present marker this design refuses.
ALL7="$(PATH="$D/bin:$PATH" O="$D/O" HARNESS_TOKEN="behind:111111111111" bash "$DM" "$D/repo" owner/repo 9 2>&1)"
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
_hr_call_ctx="$(awk '{ w[NR%4]=$0 }
  /^  harness_refresh_cycle/ {
    if (w[(NR-1)%4] ~ /_HR_DONE=0/ || w[(NR-2)%4] ~ /_HR_DONE=0/ || w[(NR-3)%4] ~ /_HR_DONE=0/) print "yes"
    exit
  }' "$LOOP")"
[ "$_hr_call_ctx" = yes ] \
  && ok "orch-loop.sh releases the latch at the call site (a per-process latch would refresh once, ever)" \
  || bad "orch-loop.sh does not reset _HR_DONE before its call — the refresh runs once per PROCESS"

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
