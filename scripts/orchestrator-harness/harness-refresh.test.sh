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
grep -B2 '^  harness_refresh_cycle' "$LOOP" | grep -q '_HR_DONE=0' \
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
