#!/usr/bin/env bash
# cloud-cell-record-dep.test.sh — #1717: the record step is a CHECKED dependency, and a record
# failure reaches a TERMINAL state instead of re-paying for a review every cycle.
#
# The defect this pins has two halves, and they fail differently:
#
#   (1) FALSE GREEN + PAID LOOP. `cloud-cell-supervisor.sh cmd_check` printed
#       "CELL CAN RUN A CONTROLLER" without testing $HOME/.pi/agent/scripts/record-review.sh — the
#       file merge-one.sh EXECUTES to mint the signed marker ai-review-gate verifies. On a fresh
#       cell it is absent, so the cell ran a full fresh-context review (up to REVIEW_TIMEOUT =
#       1800 s, PAID), record-review.sh returned 127, and merge-one.sh aborted. Nothing was recorded
#       and nothing was parked, so the next cycle saw an unmarked FAILED:ai-review-gate and spawned
#       another review: one paid review per cycle, forever, with no terminal state.
#
#   (2) NO TERMINAL STATE. No state a cell could reach stopped the loop and said why.
#
# HOW THESE CHECKS ARE WRITTEN. Every one drives a SHIPPED script (`cloud-cell-supervisor.sh`,
# `merge-one.sh`) — never a re-implementation, which would pass on the broken copy too. The
# toolchain is stubbed and PATH is replaced, so the suite is hermetic (no network, no tmux server,
# no real gh/pi) AND the "dependency is missing" cases are reachable at all: with /usr/bin on PATH,
# git and python3 are present on every box and the negative cases could not exist.
#
# Two checks are marked RED→GREEN: they assert the two behaviours #1717 introduces, and both fail
# on the pre-fix tree (see the PR body for the recorded before/after run).
#
#   bash scripts/orchestrator-harness/cloud-cell-record-dep.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUP="$HERE/../cloud-cell-supervisor.sh"
MERGE="$HERE/merge-one.sh"
# Resolved BEFORE any PATH replacement — the supervisor is invoked through it.
BASH_BIN="$(command -v bash)"
[ -x "$SUP" ]   || { echo "❌ missing $SUP"; exit 1; }
[ -x "$MERGE" ] || { echo "❌ missing $MERGE"; exit 1; }

pass=0; fail=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1))
  else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); fi
}
note() { printf '      %s\n' "$*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "==> #1717 cloud-cell record dependency ($HERE)"

# ── the stub toolchain ────────────────────────────────────────────────────────
# PATH is set to this directory ALONE for every driven script, so what the host happens to have
# installed cannot make a negative case pass — and cannot let a real `gh`/`pi` reach the network.
# The coreutils are symlinked (they are the shells the driven scripts actually need); the tools
# under test are trivial `exit 0` stubs.
COREUTILS="date tr mkdir cp rm ls cat dirname env sed grep chmod head tail awk seq sleep diff stat touch true false"
mkstubs() { # mkstubs <dir>
  local d="$1" b p
  mkdir -p "$d"
  for b in $COREUTILS; do
    p="$(command -v "$b" 2>/dev/null)" || continue
    ln -sf "$p" "$d/$b"
  done
  ln -sf "$BASH_BIN" "$d/bash"
  # gh: `cmd_check` runs `gh auth status`; merge-one.sh runs `pr view`/`pr checks`/`pr merge`.
  cat > "$d/gh" <<'SH'
#!/bin/bash
case "$*" in
  *"pr view"*headRefOid*) printf '%s\n' "${FAKE_HEAD:-0123456789abcdef0123456789abcdef01234567}"; exit 0 ;;
  *"pr checks"*) printf 'SUCCESS\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$d/gh"
  # tmux: `start` must be able to CREATE a session and then SEE it, and a stub that always reports
  # "running" would silently skip the whole start path (it did, before this was stateful).
  cat > "$d/tmux" <<'SH'
#!/bin/bash
case "$1" in
  has-session) [ -f "$TM_STATE/up" ] && exit 0 || exit 1 ;;
  new-session) shift; printf '%s\n' "$*" > "$TM_STATE/cmd"; : > "$TM_STATE/up"; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$d/tmux"
  for b in git python3 pi; do printf '#!/bin/bash\nexit 0\n' > "$d/$b"; chmod +x "$d/$b"; done
  return 0
}

# ── a complete cell fixture, one missing dependency at a time ─────────────────
CELL="$TMP/cell"
CELL_HOME="$CELL/home"; CELL_REPO="$CELL/repo"; CELL_O="$CELL/o"; CELL_HARNESS="$CELL/harness"
CELL_STUBS="$CELL/stubs"
mkdir -p "$CELL_HOME" "$CELL_REPO/.git" "$CELL_O/logs" "$CELL_O/state" "$CELL_HARNESS"
cp "$HERE"/*.sh "$CELL_HARNESS/"
# `cmd_check` asserts the workers are in $O; production gets them from `start`'s seed of $HARNESS.
cp "$HERE"/*.sh "$CELL_O/"
mkstubs "$CELL_STUBS"
RECORDER="$CELL_HOME/.pi/agent/scripts/record-review.sh"
mkdir -p "$(dirname "$RECORDER")"
printf '#!/bin/bash\nexit 0\n' > "$RECORDER"; chmod +x "$RECORDER"
# The recorder's DECLARED SIBLING (#1362): record-review.sh resolves its diff normalizer from its own
# directory, so cmd_check refuses a cell that has the recorder without it — and `start` provisions the
# pair together, exactly as pi-bootstrap/setup.sh's lib farm does.
RECORDER_LIB="$CELL_HOME/.pi/agent/scripts/lib/diff-normalize.py"
mkdir -p "$(dirname "$RECORDER_LIB")"
printf '#!/usr/bin/env python3\n' > "$RECORDER_LIB"; chmod +x "$RECORDER_LIB"

cell_check() { # cell_check — drive the SHIPPED `check` under the fixture's stub PATH
  env -u SCOPE -u AI_REVIEW_GATE_KEY \
    PATH="$CELL_STUBS" HOME="$CELL_HOME" CELL_HOME="$CELL_HOME" REPO="$CELL_REPO" \
    O="$CELL_O" HARNESS="$CELL_HARNESS" ENV_FILE="$CELL/absent.env" \
    "$BASH_BIN" "$SUP" check 2>&1
}
cell_start() { # cell_start — drive the SHIPPED `start` with a tmux stub that records the session
  mkdir -p "$CELL/tmstate"
  env -u AI_REVIEW_GATE_KEY SCOPE=own \
    PATH="$CELL_STUBS" TM_STATE="$CELL/tmstate" HOME="$CELL_HOME" CELL_HOME="$CELL_HOME" \
    REPO="$CELL_REPO" O="$CELL_O" HARNESS="$CELL_HARNESS" OR="acme/widget" \
    "$BASH_BIN" "$SUP" start 2>&1
}
certified() { case "$1" in *'CELL CAN RUN A CONTROLLER'*) return 0 ;; *) return 1 ;; esac; }

# 1) NON-VACUITY: the complete fixture really is certified, so every refusal below is attributable
# to the one dependency that was removed and not to a fixture that never passed in the first place.
out="$(cell_check)"; rc=$?
[ "$rc" -eq 0 ] && certified "$out" && rc=0 || { rc=1; note "rc=$rc out=$(printf '%s' "$out" | tail -3)"; }
ck "non-vacuity: a complete cell is certified (rc=0, verdict printed)" $rc
case "$out" in *'ok: record step present and executable'*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "non-vacuity: cmd_check reports the record step it probed" $rc
# uv stays NON-FATAL (install.sh warns for it) — the two surfaces must agree, so the warn is pinned
# rather than left to drift into a second, disagreeing verdict.
case "$out" in *'warn: uv missing'*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "uv is a WARNING, not a refusal (agreeing with install.sh)" $rc

# 2) RED→GREEN — the issue's own acceptance criterion: with record-review.sh absent, cmd_check must
# NOT report the cell can run a controller. The pre-fix build prints the verdict and exits 0 here.
mv "$RECORDER" "$CELL/recorder.stash"
out="$(cell_check)"; rc=$?
[ "$rc" -ne 0 ] && ! certified "$out" && rc=0 || { rc=1; note "rc=$rc certified=$([ -n "$out" ] && certified "$out" && echo yes || echo no)"; }
ck "RED→GREEN: a cell without record-review.sh is NOT certified" $rc
case "$out" in *'record-review.sh MISSING at'*"$RECORDER"*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "the refusal names the missing record-review.sh path" $rc
case "$out" in *'provisions it from'*"$CELL_HARNESS/../record-review.sh"*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "the refusal names where the recorder can be provisioned from" $rc

# 3) A present-but-NOT-EXECUTABLE recorder is a different fault with a different remedy:
# merge-one.sh executes the file directly, so mode 644 fails (126) AFTER the paid review.
mv "$CELL/recorder.stash" "$RECORDER"; chmod 644 "$RECORDER"
out="$(cell_check)"; rc=$?
[ "$rc" -ne 0 ] && ! certified "$out" && rc=0 || { rc=1; note "rc=$rc"; }
ck "a non-executable record-review.sh is not certified" $rc
case "$out" in *'NOT EXECUTABLE'*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "the refusal names executability, not absence" $rc
chmod +x "$RECORDER"

# 3b) THE RECORDER'S OWN RUNTIME DEPENDENCY (#1362/#1717). record-review.sh resolves
# lib/diff-normalize.py from its OWN directory; without it it silently takes the RAW pre-#1362 digest
# arm, so every base-only `gh pr update-branch` refuses carry-forward and buys a fresh PAID review.
# A cell certified in that state is the same false-PASS/paid-loop class this PR exists to close — one
# step down the cost ladder — so cmd_check must refuse it and name the sibling it probed.
mv "$RECORDER_LIB" "$CELL/normalizer.stash"
out="$(cell_check)"; rc=$?
[ "$rc" -ne 0 ] && ! certified "$out" && rc=0 || { rc=1; note "rc=$rc certified=$([ -n "$out" ] && certified "$out" && echo yes || echo no)"; }
ck "RED→GREEN: a recorder WITHOUT its sibling diff-normalize.py is not certified" $rc
case "$out" in *'diff-normalize.py MISSING'*"$RECORDER_LIB"*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "the refusal names the missing normalizer path" $rc
case "$out" in *'provisions it from'*"$CELL_HARNESS/../lib/diff-normalize.py"*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "the refusal names where the normalizer can be provisioned from" $rc
mv "$CELL/normalizer.stash" "$RECORDER_LIB"

# 4) THE SIBLINGS THE ISSUE DID NOT NAME. Each of these, absent, turns a loop step into a silent
# no-op (python3 → an empty check classification, so no case arm matches and every PR is skipped in
# silence) or a dead worker (pi → 127 on every review and every fixer), so each is fatal.
for dep in git python3 pi; do
  mv "$CELL_STUBS/$dep" "$CELL/$dep.stub"
  out="$(cell_check)"; rc=$?
  [ "$rc" -ne 0 ] && ! certified "$out" && rc=0 || { rc=1; note "rc=$rc"; }
  ck "a cell with no $dep is not certified" $rc
  case "$out" in *"$dep missing on PATH"*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
  ck "the refusal names $dep" $rc
  mv "$CELL/$dep.stub" "$CELL_STUBS/$dep"
done

# 5) `start` PROVISIONS the dependency the issue says is "checked and provisioned": the canonical
# copy ships one directory up from the harness, exactly where recorder_src()/recorder_lib_src() look.
# The normalizer is the recorder's DECLARED SIBLING, so both must be provisioned, preserving the
# relative position (scripts/record-review.sh <-> scripts/lib/diff-normalize.py).
printf '#!/bin/bash\nexit 0\n' > "$CELL/record-review.sh"; chmod +x "$CELL/record-review.sh"
mkdir -p "$CELL/lib"; printf '#!/usr/bin/env python3\n' > "$CELL/lib/diff-normalize.py"
rm -f "$RECORDER" "$RECORDER_LIB" "$CELL/tmstate/up" "$CELL/tmstate/cmd"
out="$(cell_start)"; rc=$?
[ "$rc" -eq 0 ] && [ -x "$RECORDER" ] && rc=0 || { rc=1; note "rc=$rc recorder=$([ -x "$RECORDER" ] && echo present || echo absent) out=$(printf '%s' "$out" | tail -3)"; }
ck "start provisions record-review.sh from the checkout" $rc
[ -s "$RECORDER_LIB" ] && rc=0 || { rc=1; note "normalizer=$([ -s "$RECORDER_LIB" ] && echo present || echo absent) out=$(printf '%s' "$out" | tail -3)"; }
ck "RED→GREEN: start provisions the recorder's SIBLING diff-normalize.py in lib/" $rc
[ -f "$CELL/tmstate/cmd" ] && rc=0 || rc=1
ck "start then reached the session launch (the provision did not abort it)" $rc
out="$(cell_check)"; rc=$?
[ "$rc" -eq 0 ] && certified "$out" && rc=0 || { rc=1; note "$(printf '%s' "$out" | tail -3)"; }
ck "the provisioned cell is then certified" $rc
# …and the SIBLING alone is provisioned when an operator's recorder copy already exists (the
# "present but degraded" cell the lib check exists for): remove ONLY the normalizer and re-start.
rm -f "$RECORDER_LIB" "$CELL/tmstate/up" "$CELL/tmstate/cmd"
out="$(cell_start)"; rc=$?
[ "$rc" -eq 0 ] && [ -s "$RECORDER_LIB" ] && rc=0 || { rc=1; note "rc=$rc normalizer=$([ -s "$RECORDER_LIB" ] && echo present || echo absent) out=$(printf '%s' "$out" | tail -3)"; }
ck "start provisions ONLY the missing normalizer when the recorder already exists" $rc

# 6) …and when there is nothing to provision FROM, `start` refuses rather than creating a cell that
# can never merge. Non-vacuity: the same invocation WITHOUT the missing source succeeds above.
rm -f "$RECORDER" "$CELL/record-review.sh" "$CELL/tmstate/up" "$CELL/tmstate/cmd"
out="$(cell_start)"; rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$CELL/tmstate/cmd" ] && rc=0 || { rc=1; note "rc=$rc session=$([ -f "$CELL/tmstate/cmd" ] && echo created || echo none)"; }
ck "start refuses (and creates no session) when the recorder cannot be provisioned" $rc
case "$out" in *'cannot provision it from'*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "the refusal names the provisioning failure" $rc

# ══ the merge worker: a record failure is TERMINAL, and it will not re-pay ══════════════════════
HEAD="0123456789abcdef0123456789abcdef01234567"
PR=7
MRG="$TMP/mrg"

mkmrg() { # mkmrg — a fresh merge fixture: repo, HOME with a recorder, stubs, state dirs
  rm -rf "$MRG"
  mkdir -p "$MRG/home/.pi/agent/scripts" "$MRG/repo" "$MRG/o/logs" "$MRG/o/state"
  mkstubs "$MRG/stubs"
  : > "$MRG/pi-count"
}
# Drive the SHIPPED merge-one.sh. `pi`, `gh` and `git` are EXPORTED SHELL FUNCTIONS, not file stubs:
# merge-one.sh prepends /opt/homebrew/bin and /usr/local/bin to PATH itself, so a file stub could be
# shadowed by a real binary on another box — and a real `pi` here would be a live, paid model call
# against a real `gh`. A function wins over any PATH lookup, and the subshell keeps it out of the
# rest of this suite.
run_merge() {
  (
    # NB: the function bodies must NOT read $HEAD/$PR — bash imports an exported function into the
    # driven script, so those names are the SCRIPT's globals, and an unset $HEAD would print an
    # empty head (which makes every park assertion vacuous). Dedicated names only.
    pi() { [ -n "${PI_COUNT:-}" ] && echo x >> "$PI_COUNT"; printf '%s\n' "${FAKE_VERDICT:-CLEAN https://github.com/acme/widget/pull/${FAKE_PR}#issuecomment-12345}"; }
    gh() {
      case "$*" in
        *"pr view"*headRefOid*) printf '%s\n' "$FAKE_HEAD"; return 0 ;;
        *"pr checks"*) printf 'SUCCESS\n'; return 0 ;;
        *) return 0 ;;
      esac
    }
    git() { return 0; }
    export -f pi gh git
    env -u AI_REVIEW_GATE_KEY PATH="$MRG/stubs" HOME="$MRG/home" O="$MRG/o" \
      PI_COUNT="$MRG/pi-count" FAKE_HEAD="$HEAD" FAKE_PR="$PR" FAKE_VERDICT="${FAKE_VERDICT:-}" \
      "$BASH_BIN" "$MERGE" "$MRG/repo" acme/widget "$PR" fix/x
  ) 2>&1
}
pi_calls() { # the number of times the stubbed worker runtime was executed
  local n=0
  [ -f "$MRG/pi-count" ] && n="$(grep -c x "$MRG/pi-count" 2>/dev/null | head -1)"
  printf '%s' "${n:-0}"
}

# 7) RED→GREEN — a recorder that EXISTS but FAILS. This is the issue's exact sequence: the paid
# review runs, the record step fails, and the pre-fix `exit 3` left no marker at all.
mkmrg
printf '#!/bin/bash\nexit 127\n' > "$MRG/home/.pi/agent/scripts/record-review.sh"
chmod +x "$MRG/home/.pi/agent/scripts/record-review.sh"
out="$(run_merge)"
[ -f "$MRG/o/state/parked-$PR" ] && rc=0 || { rc=1; note "no parked-$PR; log: $(tail -3 "$MRG/o/logs/merge-$PR.log" 2>/dev/null)"; }
ck "RED→GREEN: a record-step failure writes the terminal marker" $rc
[ "$(cat "$MRG/o/state/parked-$PR" 2>/dev/null)" = "$HEAD" ] && rc=0 || { rc=1; note "parked=$(cat "$MRG/o/state/parked-$PR" 2>/dev/null) head=$HEAD"; }
ck "the marker is keyed to the reviewed head (the controller's exact comparison)" $rc
case "$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)" in *'rc=127'*) rc=0 ;; *) rc=1; note "reason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)";; esac
ck "the reason file says WHY (the failing rc), so the park is actionable" $rc
grep -q 'PARKED' "$MRG/o/logs/merge-$PR.log" && rc=0 || rc=1
ck "the worker's own log records the PARKED terminal state" $rc
[ ! -f "$MRG/o/state/merged-$PR.done" ] && rc=0 || rc=1
ck "a failed record does not fall through to the merge" $rc
[ "$(pi_calls)" = "1" ] && rc=0 || { rc=1; note "pi calls=$(pi_calls)"; }
ck "the review that was already paid for is not abandoned mid-flight" $rc
# …and the park holds at the WORKER, not only in the controller: chain-<N> and fix-one.sh invoke
# merge-one.sh directly and never consult the controller's parked guard, so a second run at the
# same head must re-review NOTHING. This is the "rather than retrying" half of the acceptance test.
out="$(run_merge)"; rc2=$?
[ "$(pi_calls)" = "1" ] && rc=0 || { rc=1; note "pi calls=$(pi_calls) — a parked head was re-reviewed"; }
ck "a second run at the parked head does not re-pay for a review" $rc
[ "$rc2" -eq 5 ] && rc=0 || { rc=1; note "rc=$rc2"; }
ck "the refusal to re-review exits with its own code (5), not a generic failure" $rc
grep -q 'refusing to re-review' "$MRG/o/logs/merge-$PR.log" && rc=0 || rc=1
ck "the refusal says it is refusing, and names the way out" $rc

# 8) RED→GREEN — the recorder is MISSING entirely. This must be caught BEFORE the paid review, not
# after it: that is what turns an unbounded paid loop into one cheap refusal per PR.
mkmrg
out="$(run_merge)"
[ "$(pi_calls)" = "0" ] && rc=0 || { rc=1; note "pi calls=$(pi_calls) — a review was paid for with no recorder"; }
ck "RED→GREEN: a missing recorder is caught BEFORE the paid review" $rc
[ "$(cat "$MRG/o/state/parked-$PR" 2>/dev/null)" = "$HEAD" ] && rc=0 || { rc=1; note "parked=$(cat "$MRG/o/state/parked-$PR" 2>/dev/null)"; }
ck "a missing recorder still reaches the terminal state" $rc
case "$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)" in *'MISSING at'*) rc=0 ;; *) rc=1; note "reason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)";; esac
ck "the reason names the missing path" $rc

# 8b) A CLEAN verdict with NO comment URL is the ONE terminal state a human reaches with no in-band
# route out: the controller `continue`s past the PR at that head, and merge-one.sh's own `exit 5`
# refusal (the log line that carries the remedy elsewhere) never runs on the controller path. So the
# parkreason itself must name BOTH the manual re-record command (the reviewer usually posted the
# comment; only the verdict line lacked the URL) and the unpark invocation — exactly like the
# MISSING / NOT-EXECUTABLE / record-failed siblings do.
mkmrg
printf '#!/bin/bash\nexit 0\n' > "$MRG/home/.pi/agent/scripts/record-review.sh"
chmod +x "$MRG/home/.pi/agent/scripts/record-review.sh"
out="$(FAKE_VERDICT='CLEAN (review posted above; URL unavailable)' run_merge)"
reason="$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"
case "$reason" in *"record-review.sh $PR $HEAD clean"*) rc=0 ;; *) rc=1; note "reason=$reason";; esac
ck "the no-URL park names the manual re-record command" $rc
case "$reason" in *"rm -f '$MRG/o/state/parked-$PR' '$MRG/o/state/parkreason-$PR'"*) rc=0 ;; *) rc=1; note "reason=$reason";; esac
ck "the no-URL park names the unpark invocation (the way out)" $rc

# 9) NON-VACUITY for the whole park arm: with a recorder that SUCCEEDS the worker proceeds to the
# merge, so the terminal state is a response to the failure and not a blanket refusal to merge.
mkmrg
printf '#!/bin/bash\nexit 0\n' > "$MRG/home/.pi/agent/scripts/record-review.sh"
chmod +x "$MRG/home/.pi/agent/scripts/record-review.sh"
out="$(run_merge)"
[ -f "$MRG/o/state/merged-$PR.done" ] && rc=0 || { rc=1; note "log: $(tail -3 "$MRG/o/logs/merge-$PR.log" 2>/dev/null)"; }
ck "non-vacuity: a successful record reaches MERGED" $rc
[ ! -f "$MRG/o/state/parked-$PR" ] && rc=0 || rc=1
ck "non-vacuity: a successful record writes no park" $rc
[ "$(pi_calls)" = "1" ] && rc=0 || rc=1
ck "non-vacuity: exactly one review is run on the happy path" $rc

echo
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
