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
COREUTILS="date tr mkdir cp rm mv ls cat dirname env sed grep chmod head tail awk seq sleep diff stat touch true false"
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
# cmd_check also judges DISPATCH PROVISIONING (agent-infra#1736): the target repo must carry its
# own tools/collision_preflight.py (or resolve a tortoise checkout), else the whole cell is refused
# as MERGE-ONLY before the recorder assertions below are ever reached — which would make them pass
# for the wrong reason. Give the fixture its own tool so every recorder assertion is decided by the
# recorder probe it names, not by an earlier refusal.
mkdir -p "$CELL_REPO/tools"; printf '#!/usr/bin/env python3\n' > "$CELL_REPO/tools/collision_preflight.py"
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

# 3c) A ZERO-BYTE recorder is the P1 shape of this same class: it IS a regular file, IS executable
# and runs — but it exits 0 WITHOUT minting the signed marker. So the gate could never go green,
# merge-one.sh's `rc=0` would write no park, and the loop would re-pay for a fresh review every
# cycle: the #1717 loop with one input shifted. Presence + executability are not enough.
: > "$RECORDER"
out="$(cell_check)"; rc=$?
[ "$rc" -ne 0 ] && ! certified "$out" && rc=0 || { rc=1; note "rc=$rc certified=$([ -n "$out" ] && certified "$out" && echo yes || echo no)"; }
ck "RED→GREEN: a ZERO-BYTE record-review.sh is not certified" $rc
case "$out" in *'EMPTY (0 bytes)'*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "the refusal names the zero-byte shape, not absence or executability" $rc
chmod +x "$RECORDER"

# 3d) A DIRECTORY at the recorder path: `[ -x dir ]` is true, so a presence+executability probe
# blesses it, merge-one.sh buys the paid review, and the record step fails 126 — the exact
# "paid to discover it cannot run" sequence this PR closes. Require a regular file.
rm -f "$RECORDER"; mkdir -p "$RECORDER"
out="$(cell_check)"; rc=$?
[ "$rc" -ne 0 ] && ! certified "$out" && rc=0 || { rc=1; note "rc=$rc certified=$([ -n "$out" ] && certified "$out" && echo yes || echo no)"; }
ck "a DIRECTORY at the recorder path is not certified" $rc
case "$out" in *'NOT A REGULAR FILE'*) rc=0 ;; *) rc=1; note "$(printf '%s' "$out" | tail -3)";; esac
ck "the refusal names the non-regular-file shape" $rc
rmdir "$RECORDER"; printf '#!/bin/bash\nexit 0\n' > "$RECORDER"; chmod +x "$RECORDER"
# A recorder WITHOUT its declared sibling: record-review.sh resolves
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

# 3e) The SIBLING check must require a regular file too: `[ -s dir ]` is true for a non-empty
# directory, so a directory at the normalizer path would slip past a bare `-s`.
mv "$RECORDER_LIB" "$CELL/normalizer.stash"
mkdir -p "$RECORDER_LIB"
out="$(cell_check)"; rc=$?
[ "$rc" -ne 0 ] && ! certified "$out" && rc=0 || { rc=1; note "rc=$rc certified=$([ -n "$out" ] && certified "$out" && echo yes || echo no)"; }
ck "a DIRECTORY at the normalizer path is not certified" $rc
rmdir "$RECORDER_LIB"; mv "$CELL/normalizer.stash" "$RECORDER_LIB"

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

# 5b) A ZERO-BYTE recorder must be RE-provisioned by `start`, not left in place: the old provision
# ran only when the path was ABSENT, so a `cp` killed mid-write (or a full disk) would persist
# across every restart and then be blessed by `cmd_check`. The write is atomic (tmp + mv), so a
# concurrent reader cannot observe a half-written recorder either.
printf '#!/bin/bash\nexit 0\n' > "$CELL/record-review.sh"; chmod +x "$CELL/record-review.sh"
: > "$RECORDER"          # a truncated/zero-byte operator copy
rm -f "$CELL/tmstate/up" "$CELL/tmstate/cmd"
out="$(cell_start)"; rc=$?
[ "$rc" -eq 0 ] && [ -s "$RECORDER" ] && rc=0 || { rc=1; note "rc=$rc recorder=$([ -s "$RECORDER" ] && echo nonempty || echo empty) out=$(printf '%s' "$out" | tail -3)"; }
ck "RED→GREEN: start re-provisions a ZERO-BYTE recorder" $rc
out="$(cell_check)"; rc=$?
[ "$rc" -eq 0 ] && certified "$out" && rc=0 || { rc=1; note "$(printf '%s' "$out" | tail -3)"; }
ck "the re-provisioned cell is then certified" $rc

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
  : > "$MRG/pr-body"
}
# A recorder REPLICA that honours record-review.sh's ACTUAL contract: it posts the SIGNED marker
# into the PR body — the artifact ai-review-gate reads. `rc=0` alone is not that artifact, which is
# the fail-open §8f pins. The gh stub above serves this file back for `pr view --json body`.
mkrecorder_posts() {
  cat > "$MRG/home/.pi/agent/scripts/record-review.sh" <<EOF
#!/bin/bash
printf 'review recorded: reviews/%s.json verdict=clean @ %s (acme/widget) sig=%s\n' "\$1" "\$2" "0000000000000000000000000000000000000000000000000000000000000000" >> '$MRG/pr-body'
exit 0
EOF
  chmod +x "$MRG/home/.pi/agent/scripts/record-review.sh"
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
        *"pr view"*body*) cat "$FAKE_BODY_FILE" 2>/dev/null; return 0 ;;
        *"pr checks"*) printf 'SUCCESS\n'; return 0 ;;
        *) return 0 ;;
      esac
    }
    git() { return 0; }
    export -f pi gh git
    env -u AI_REVIEW_GATE_KEY PATH="$MRG/stubs" HOME="$MRG/home" O="$MRG/o" \
      PI_COUNT="$MRG/pi-count" FAKE_HEAD="${FAKE_HEAD_OVERRIDE-$HEAD}" FAKE_PR="$PR" FAKE_VERDICT="${FAKE_VERDICT:-}" \
      FAKE_BODY_FILE="$MRG/pr-body" \
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

# 7b) A transient `gh` blip after a park must NOT overwrite the park's reason. The unresolvable-head
# branch also calls park(), and it runs BEFORE the already-parked guard; with HEAD empty it writes no
# `parked-<PR>` marker, but an unconditional `parkreason` write would replace the real cause with
# "could not resolve head". When gh recovers the worker matches the park, exits 5, and the exit-5 log
# — the only remedy surfaced on the chain-<N>/fix-one.sh paths — would name the wrong cause.
out="$(FAKE_HEAD_OVERRIDE='' run_merge)"; rc=$?
[ "$(cat "$MRG/o/state/parked-$PR" 2>/dev/null)" = "$HEAD" ] && rc=0 || { rc=1; note "parked=$(cat "$MRG/o/state/parked-$PR" 2>/dev/null) head=$HEAD"; }
ck "a gh blip after a park does not move the park marker" $rc
[ "$(pi_calls)" = "1" ] && rc=0 || { rc=1; note "pi calls=$(pi_calls) — a blip paid for a review"; }
ck "a gh blip after a park does not re-pay for a review" $rc
case "$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)" in *'rc=127'*) rc=0 ;; *) rc=1; note "reason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null) — the transient blip clobbered it";; esac
ck "RED→GREEN: a gh blip does not clobber the original park reason" $rc
# …and once gh recovers, the refusal still reports the ORIGINAL cause, not the transient blip.
out="$(run_merge)"; rc2=$?
[ "$rc2" -eq 5 ] && rc=0 || { rc=1; note "rc=$rc2"; }
ck "the refusal after a recovered blip still exits 5" $rc
grep -q 'reason: .*rc=127' "$MRG/o/logs/merge-$PR.log" && rc=0 || { rc=1; note "$(tail -1 "$MRG/o/logs/merge-$PR.log" 2>/dev/null)"; }
ck "the exit-5 refusal names the original reason, not the transient blip" $rc

# 7c) A push MOVES the head, so the PR re-arms (the controller's guard compares only the head) and
# the worker must park at the NEW head with a reason that describes THAT head's failure. Keeping the
# previous head's reason beside a new head would tell the operator the wrong cause — the same
# wrong-cause defect 7b closes on the blip path, reached the other way.
HEAD2="89abcdef0123456789abcdef0123456789abcdef"
out="$(FAKE_HEAD_OVERRIDE="$HEAD2" run_merge)"; rc=$?
[ "$(cat "$MRG/o/state/parked-$PR" 2>/dev/null)" = "$HEAD2" ] && rc=0 || { rc=1; note "parked=$(cat "$MRG/o/state/parked-$PR" 2>/dev/null) head2=$HEAD2"; }
ck "a moved head re-parks at the NEW head" $rc
case "$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)" in *"head=$HEAD2"*) rc=0 ;; *) rc=1; note "reason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null) — stale reason from the previous head";; esac
ck "RED→GREEN: the re-park's reason names the NEW head, not the stale one" $rc

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

# 8d) RED→GREEN — a recorder that EXISTS but is EMPTY. It is executable and exits 0 without
# minting the signed marker, so the pre-fix `[ ! -e ]`/`[ ! -x ]` probe admits it, the worker takes
# `rc=0`, writes NO park, waits out the gate and exits 4 — one paid review per cycle forever. Refuse
# it BEFORE the paid review, exactly like the missing case.
mkmrg
: > "$MRG/home/.pi/agent/scripts/record-review.sh"
chmod +x "$MRG/home/.pi/agent/scripts/record-review.sh"
out="$(run_merge)"; rc=$?
[ "$(pi_calls)" = "0" ] && rc=0 || { rc=1; note "pi calls=$(pi_calls) — a review was paid for with an empty recorder"; }
ck "RED→GREEN: an EMPTY recorder is caught BEFORE the paid review" $rc
[ "$(cat "$MRG/o/state/parked-$PR" 2>/dev/null)" = "$HEAD" ] && rc=0 || { rc=1; note "parked=$(cat "$MRG/o/state/parked-$PR" 2>/dev/null)"; }
ck "an empty recorder reaches the terminal state (no silent rc=0 fall-through)" $rc
case "$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)" in *'EMPTY (0 bytes)'*) rc=0 ;; *) rc=1; note "reason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)";; esac
ck "the reason names the zero-byte shape, so the park is actionable" $rc

# 8e) …and a DIRECTORY at the recorder path is refused the same way (`[ -x dir ]` is true).
mkmrg
mkdir -p "$MRG/home/.pi/agent/scripts/record-review.sh"
out="$(run_merge)"; rc=$?
[ "$(pi_calls)" = "0" ] && rc=0 || { rc=1; note "pi calls=$(pi_calls) — a review was paid for with a directory at the recorder path"; }
ck "a DIRECTORY at the recorder path is caught BEFORE the paid review" $rc
case "$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)" in *'NOT A REGULAR FILE'*) rc=0 ;; *) rc=1; note "reason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)";; esac
ck "the reason names the non-regular-file shape" $rc

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

# 8c) RED→GREEN — an UNRESOLVABLE HEAD is the same class of pre-review dependency as the recorder.
# `gh pr view` swallows its failure, so a transient API/network blip leaves HEAD empty; the pre-fix
# flow STILL paid for the whole review (and, with a recorder that exits 0, even reached the merge
# with an empty head). record-review.sh refuses a non-40-hex sha, and park() cannot key a marker to
# an empty head, so the controller re-paid every cycle — the paid loop #1717 removes. Refuse BEFORE
# the review, and name the way out. Non-vacuity: the same fixture with a resolvable head runs one
# review and merges (section 9).
mkmrg
printf '#!/bin/bash\nexit 0\n' > "$MRG/home/.pi/agent/scripts/record-review.sh"
chmod +x "$MRG/home/.pi/agent/scripts/record-review.sh"
out="$(FAKE_HEAD_OVERRIDE='' run_merge)"; rc=$?
[ "$rc" -ne 0 ] && rc=0 || { rc=1; note "rc=$rc out=$(printf '%s' "$out" | tail -3)"; }
ck "RED→GREEN: an empty head is refused (non-zero exit)" $rc
[ "$(pi_calls)" = "0" ] && rc=0 || { rc=1; note "pi calls=$(pi_calls) — a review was paid for with an unresolvable head"; }
ck "RED→GREEN: an empty head is caught BEFORE the paid review" $rc
[ ! -f "$MRG/o/state/merged-$PR.done" ] && rc=0 || { rc=1; note "the empty-head run fell through to the merge"; }
ck "an empty head does not fall through to the merge" $rc
reason="$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)"
case "$reason" in *'could not resolve'*'head'*) rc=0 ;; *) rc=1; note "reason=$reason";; esac
ck "the refusal names the unresolvable head" $rc
case "$reason" in *"rm -f '$MRG/o/state/parked-$PR' '$MRG/o/state/parkreason-$PR'"*) rc=0 ;; *) rc=1; note "reason=$reason";; esac
ck "the unresolvable-head reason names the way out" $rc
# …and a head that is present but NOT a 40-char lower-hex sha is the same refusal (the shape
# record-review.sh:649 enforces), not a review that can never be recorded.
out="$(FAKE_HEAD_OVERRIDE='deadbeef' run_merge)"; rc=$?
[ "$rc" -ne 0 ] && [ "$(pi_calls)" = "0" ] && rc=0 || { rc=1; note "rc=$rc pi calls=$(pi_calls)"; }
ck "a non-40-hex head is refused before the paid review" $rc
out="$(FAKE_HEAD_OVERRIDE='0123456789ABCDEF0123456789ABCDEF01234567' run_merge)"; rc=$?
[ "$rc" -ne 0 ] && [ "$(pi_calls)" = "0" ] && rc=0 || { rc=1; note "rc=$rc pi calls=$(pi_calls)"; }
ck "a non-lowercase head is refused before the paid review (record-review.sh's exact shape)" $rc

# 8f) RED→GREEN — `rc=0` IS NOT PROOF THE SIGNED MARKER REACHED THE PR BODY. record-review.sh posts
# the marker BEST-EFFORT and never fails the record, so it has reachable rc=0 paths with NO post
# (the body GET/PATCH failed, or gh/repo is unavailable). The pre-fix worker trusted rc=0, saw
# gate=SUCCESS (the stub), and MERGED — so this fails on the pre-fix tree. The signed marker is the
# only artifact the gate reads, so its absence must be the same terminal failure as a non-zero rc.
mkmrg
printf '#!/bin/bash\nexit 0\n' > "$MRG/home/.pi/agent/scripts/record-review.sh"
chmod +x "$MRG/home/.pi/agent/scripts/record-review.sh"
out="$(run_merge)"; rc=$?
[ "$(pi_calls)" = "1" ] && rc=0 || { rc=1; note "pi calls=$(pi_calls)"; }
ck "a rc=0 record still pays for exactly one review" $rc
[ ! -f "$MRG/o/state/merged-$PR.done" ] && rc=0 || { rc=1; note "rc=0 with no marker fell through to the merge"; }
ck "RED→GREEN: rc=0 with NO signed marker does not merge" $rc
[ "$(cat "$MRG/o/state/parked-$PR" 2>/dev/null)" = "$HEAD" ] && rc=0 || { rc=1; note "parked=$(cat "$MRG/o/state/parked-$PR" 2>/dev/null)"; }
ck "RED→GREEN: rc=0 with NO signed marker writes the terminal park" $rc
case "$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)" in *'NO signed marker'*) rc=0 ;; *) rc=1; note "reason=$(cat "$MRG/o/state/parkreason-$PR" 2>/dev/null)";; esac
ck "the no-marker park names the missing signed marker" $rc
out="$(run_merge)"; rc2=$?
[ "$(pi_calls)" = "1" ] && rc=0 || { rc=1; note "pi calls=$(pi_calls) — a parked no-marker head was re-reviewed"; }
ck "a parked no-marker head does not re-pay on the next run" $rc
[ "$rc2" -eq 5 ] && rc=0 || { rc=1; note "rc=$rc2"; }
ck "the no-marker park refuses re-review with exit 5" $rc

# 9) NON-VACUITY for the whole park arm: with a recorder that SUCCEEDS the worker proceeds to the
# merge, so the terminal state is a response to the failure and not a blanket refusal to merge.
# The recorder must POST the signed marker (not merely exit 0) — that is now the precondition the
# worker checks before the gate, so a `: > /dev/null` stub would park and this would be vacuous.
mkmrg
mkrecorder_posts
out="$(run_merge)"
[ -f "$MRG/o/state/merged-$PR.done" ] && rc=0 || { rc=1; note "log: $(tail -3 "$MRG/o/logs/merge-$PR.log" 2>/dev/null)"; }
ck "non-vacuity: a successful record reaches MERGED" $rc
[ ! -f "$MRG/o/state/parked-$PR" ] && rc=0 || rc=1
ck "non-vacuity: a successful record writes no park" $rc
[ "$(pi_calls)" = "1" ] && rc=0 || rc=1
ck "non-vacuity: exactly one review is run on the happy path" $rc

# ══ the controller's own park: the reason must move with the marker ══════════════════════════
# 10) `parkreason-<PR>` is the only in-band remedy a human sees (merge-one.sh's exit-5 refusal prints
# it, and the chain-<N>/fix-one.sh paths read nothing else). The controller used to write
# `parked-<PR>` at its three park sites and NEVER touch the reason, so a park at a NEW head (after a
# push moved the old one) left the OLD head's reason beside it — the operator was told to
# "re-provision the recorder" for a PR parked for an unrelated cause. Drive the shipped helper and
# require the pair to move together, and require every controller site to use it.
LOOP="$HERE/orch-loop.sh"
[ -x "$LOOP" ] || { echo "❌ missing $LOOP"; exit 1; }
sed -n '/^park_ctrl() {/,/^}/p' "$LOOP" > "$TMP/parkctrl.sh"
[ -s "$TMP/parkctrl.sh" ] && rc=0 || { rc=1; note "park_ctrl() is not in the shipped orch-loop.sh"; }
ck "RED→GREEN: the controller has a park helper that writes marker+reason together" $rc
if [ -s "$TMP/parkctrl.sh" ]; then
  (
    set -u; PR=7; O="$TMP/ctrl"; mkdir -p "$O/state"
    # a park from an EARLIER head, with its own (now stale) reason
    printf '%s\n' "old-head" > "$O/state/parked-$PR"
    printf '%s\n' "recorder MISSING at the old head" > "$O/state/parkreason-$PR"
    # shellcheck disable=SC1090
    . "$TMP/parkctrl.sh"
    park_ctrl "$PR" "$HEAD" "still CONFLICTING after 3 fixes"
  )
  [ "$(cat "$TMP/ctrl/state/parked-7")" = "$HEAD" ] && rc=0 || { rc=1; note "parked=$(cat "$TMP/ctrl/state/parked-7" 2>/dev/null)"; }
  ck "park_ctrl moves the marker to the new head" $rc
  case "$(cat "$TMP/ctrl/state/parkreason-7" 2>/dev/null)" in *'still CONFLICTING'*) rc=0 ;; *) rc=1; note "reason=$(cat "$TMP/ctrl/state/parkreason-7" 2>/dev/null) — the stale reason survived";; esac
  ck "RED→GREEN: park_ctrl REPLACES a stale reason from an earlier head" $rc
  case "$(cat "$TMP/ctrl/state/parkreason-7" 2>/dev/null)" in *'recorder MISSING'*) rc=1 ;; *) rc=0 ;; esac
  ck "the stale reason does not survive beside the new marker" $rc
fi
# …and every controller park site must go THROUGH that helper: a bare `> parked-$PR` write anywhere
# would reintroduce the stale-reason defect at that site. (The guarded read at the top of the sweep
# is a `cat`, not a write, so it does not match.)
bare="$(grep -cE '>[[:space:]]*"\$O/state/parked-\$PR"' "$LOOP")"
[ "$bare" = "0" ] && rc=0 || { rc=1; note "$bare controller site(s) still write parked-\$PR directly"; }
ck "no controller park site writes parked-\$PR without its reason" $rc

echo
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
