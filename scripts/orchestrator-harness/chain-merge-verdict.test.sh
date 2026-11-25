#!/usr/bin/env bash
# chain-merge-verdict.test.sh — the controller's chain must YIELD to a lane's merge phase, and must
# not read a mid-loop verdict as a handoff.
#
# HERMETIC: throwaway $O/$HOME, a stub `gh` (answers the one `pr list` the chain makes), and a stub
# `merge-one.sh` that records "RAN" in a marker file. No network, no tmux, no git.
#
# ⛔ WHY THIS SUITE EXISTS. The first version of the merge-phase wait special-cased only `MERGED`, so
# every other verdict token — including `FIX_REQUIRED`, whose whole purpose is to tell the lane to
# PUSH A FIX — was read as "the lane handed off" and the chain reviewed immediately, at the head the
# lane was about to change. That strands the attestation (record binds head H, the lane pushes H+1):
# the gate reddens on an unchanged verdict, the review is paid for twice, and a rail repo then refuses
# to move a branch carrying a record bound to it. Nothing in the repo exercised chain-merge.sh, so the
# defect could only be found by reading it. These cases drive the shipped script.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/chain-merge.sh"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
[ -s "$SCRIPT" ] || { bad "chain-merge.sh is missing or empty"; exit 1; }
mkdir -p "$T/bin" "$T/repo" "$T/home"
# ⛔ THE STUB MUST ALSO OCCUPY THE DIRECTORIES chain-merge.sh PREPENDS (landing-review P1, hermeticity).
# chain-merge.sh:7-11 does `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH` and then prepends
# `$O/gh-limit` and `$O/gh-rest` — ABSOLUTE paths it puts AHEAD of the caller's PATH — so a stub that
# only lives on the inherited PATH loses to the real, authenticated `gh` on any box that has one (and to
# /opt/homebrew/bin on a Mac). The suite then silently made REAL API calls instead of asserting against a
# fixture. `rig()` seeds the same helper into both prepended dirs — ⛔ IT IS THE ONLY PLACE THAT CAN:
# it runs AFTER this heredoc creates `$T/bin/gh`, whereas the loop that used to sit here copied a file
# that did not exist yet, so it printed `cp: cannot stat` on every run and seeded nothing (noise that
# hides a real red). `rig()` also recreates `$T/o` per arm, so both dirs are re-seeded there anyway.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# TWO different questions reach this stub, and a stub that always prints a value makes the merge
# confirmation UNFALSIFIABLE (reviewer finding, P2, verified: mutating `chain_merged_confirmed(){ return
# 0; }` left the suite 10/10 green). So answer them separately:
#   `pulls/<n>`  → "is THIS repo's PR merged?"      → ${MERGED_AT_STUB-} (set-but-empty = NOT merged)
#   anything else→ "which open PR is on this branch?" → 5
case " $* " in
  # ⛔ THE ISSUE STATE IS ITS OWN QUESTION (#4230). `chain-merge.sh` now asks `repos/<o/r>/issues/<n>`
  # whether the MERGED PR actually CLOSED the issue, because "merged" and "finished" are different
  # facts on GitHub (a merge auto-closes only via a closing keyword on the default branch). Without
  # this arm the catch-all below answered 5 for an issue state — i.e. "neither open nor closed" — and
  # every new assertion would have graded the uninterpretable branch instead of the real one.
  *"issues/"*)
    # ISSUE_API_FAIL=1 = the READ failed (rate limit / DNS): exit non-zero, print nothing. An
    # unreadable state is NOT "closed", and the chain must keep the claim on it (fail-closed).
    [ "${ISSUE_API_FAIL:-0}" != 0 ] && exit 1
    printf '%s\n' "${ISSUE_STATE_STUB-open}" ;;
  *"pulls/"*)
    printf 'READ\n' >> "${GH_PULLS_COUNT:-/dev/null}"
    # MERGED_API_FAIL=1 = the READ failed (rate limit / DNS): exit non-zero, print nothing. A failed
    # read and an answered "not merged" are DIFFERENT facts and the chain must not collapse them.
    # MERGED_API_FAIL=<n> = fail the first <n> reads, then answer. The recovery path ("a transient
    # failure must not be permanent") needs the stub to CHANGE ITS MIND mid-run.
    # (MERGED_API_FAIL=1 also lands here: fail the first read, answer the second — which is exactly
    # the transient failure the "not permanent" case needs.)
    if [ "${MERGED_API_FAIL:-0}" != 0 ]; then
      # ⛔ `wc -l` PADS with spaces on BSD/macOS, so the numeric guard below would see "      2" and
      # reset it to 0 — an always-failing stub, i.e. a case that cannot pass for the right reason.
      _nr="$(wc -l < "${GH_PULLS_COUNT:-/dev/null}" 2>/dev/null | tr -d ' ' || true)"
      case "${_nr:-0}" in ''|*[!0-9]*) _nr=0 ;; esac
      [ "$_nr" -le "${MERGED_API_FAIL}" ] && exit 1
    fi
    [ -n "${MERGED_AT_STUB+x}" ] && printf '%s\n' "$MERGED_AT_STUB" ;;
  *) printf '5\n' ;;
esac
EOF
chmod +x "$T/bin/gh"

rig() { # rig — fresh $O with a stub chain (records RAN) and no claims.sh (the release no-ops loudly)
  rm -rf "$T/o"; mkdir -p "$T/o/state" "$T/o/logs"
  cat > "$T/o/merge-one.sh" <<EOF
#!/usr/bin/env bash
printf 'RAN\n' >> "$T/chain-ran"
# ⛔ THE GAP ARM (#4230 review, P2). The real merge-one writes state/merged-<PR>.done at the instant the
# rail merges, and THIS caller sets its own CHAIN_MERGED only once this script RETURNS — so a signal in
# between used to reach the EXIT trap with the marker present and the flag still 0. The stub reproduces
# that gap on demand (state/kill-at-merge), leaving every other arm untouched.
if [ -f "$T/o/state/kill-at-merge" ]; then
  printf 'x\n' > "$T/o/state/merged-5.done"
  kill -TERM "\$PPID" 2>/dev/null
fi
EOF
  chmod +x "$T/o/merge-one.sh"
  # The claim release is the EXIT path's other job; record it so "the early exit released the claim"
  # is an ASSERTION, not a hope. (Without a captured generation chain-merge deliberately refuses.)
  # ⛔ THE RENEWAL STUB RECORDS ITS FOURTH ARGUMENT TOO (#4230 review, P3): the generation the chain
  # captured at dispatch start is the fence that stops an hours-old chain renewing a lease it no longer
  # holds, and a stub that dropped it left `"${CHAIN_CLAIM_COMMIT:-}"` at the call site UNPINNED — a
  # mutant passing "" kept all five arms green. `<none>` names the empty value explicitly, so the
  # assertion cannot pass on an absent argument either.
  cat > "$T/o/claims.sh" <<EOF
claim_issue_release_record() { printf 'RELEASED %s\n' "\$3" >> "$T/released"; return 0; }
claim_issue_renew_record() { printf 'RENEWED %s %s\n' "\$3" "\${4:-<none>}" >> "$T/released"; return 0; }
EOF
  rm -f "$T/chain-ran" "$T/released"
  # rig() recreates $T/o, so the PATH-prepended shim dirs must be re-seeded with it.
  for _d in gh-limit gh-rest; do
    mkdir -p "$T/o/$_d"; cp "$T/bin/gh" "$T/o/$_d/gh"; chmod +x "$T/o/$_d/gh"
  done
}
ran() { [ -f "$T/chain-ran" ]; }
PID=""
drive() { # drive <phase-grace> <handoff-wait> — starts the chain, sets $PID (never echoes: a caller
           # running this in $( ) would own the child in a SUBSHELL and could not wait/kill it)
  # ⛔ `O_WORK` IS PINNED INTO THE THROWAWAY TREE (#4230 review, measured). chain-merge.sh resolves its
  # WORK ROOT as `${O_WORK:-$O}` and prepends `${O_WORK}/gh-rest` and `${O_WORK}/gh-limit` to PATH —
  # ABSOLUTE paths, AHEAD of `$T/bin`. On a fleet box (any agent/controller session, or anything that
  # exports it) `O_WORK` names the LIVE harness, so the REAL `gh` outranked this suite's stub: `gh pr
  # list` answered nothing, the chain sat out all 90 polls, and the suite reported a FALSE RED on arms
  # it never reached (measured here: arms 1-2 red then a 90-minute hang, with the stub provably working).
  # Pinning it keeps the shim dirs the rig seeds — and makes the HERMETIC claim at the top true.
  PATH="$T/bin:$PATH" O="$T/o" O_WORK="$T/o" HOME="$T/home" CHAIN_CLAIM_COMMIT="deadbeef" MERGED_AT_STUB="${MERGED_AT_STUB-}" MERGED_API_FAIL="${MERGED_API_FAIL-0}" \
    ISSUE_STATE_STUB="${ISSUE_STATE_STUB-open}" ISSUE_API_FAIL="${ISSUE_API_FAIL-0}" \
    LANE_PHASE_GRACE="$1" LANE_HANDOFF_WAIT="$2" CHAIN_POLL="${CHAIN_POLL:-15}" \
    CHAIN_CONFIRM_RETRY="${CHAIN_CONFIRM_RETRY:-60}" GH_PULLS_COUNT="${GH_PULLS_COUNT:-}" \
    bash "$SCRIPT" "$T/repo" o/r 42 feat/42-tm >> "$T/o/logs/chain-42.log" 2>&1 &
  PID=$!
}
stop() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; }

echo "==> chain-merge verdict suite"

# ── 1. NO phase marker (a pre-merge-phase lane) → the chain reviews immediately, as before ────────
rig
drive 0 30
for _ in 1 2 3 4 5 6 7 8 9 10; do ran && break; sleep 1; done
stop
ck "a lane with NO phase marker is not delayed — the chain reviews immediately (old-template lanes are safe)" \
   $(ran && grep -q "no merge-phase marker" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# ── 2. phase + a CURRENT FIX_REQUIRED verdict → keep waiting; do NOT review ──────────────────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'FIX_REQUIRED this head owns checks are RED: lint\n' > "$T/o/state/lanemerge-5.verdict"
drive 90 30
sleep 6
GOT=0; ran && GOT=1
ck "a CURRENT FIX_REQUIRED verdict is NOT a handoff — the chain waits instead of reviewing a head about to change" \
   $([ "$GOT" = 0 ] && grep -q "still working (FIX_REQUIRED)" "$T/o/logs/chain-42.log" && echo 0 || echo 1)
# ⛔ THE MARKER ALONE IS NOT A MERGE (reviewer finding, P2, verified). `state/merged-<PR>.done` is keyed
# by PR NUMBER ONLY and `$O/state` is shared by every repo on the box, so a merge of another repo's PR
# #5 ended this chain `exit 0` — skipping the review AND the merge. Arm (a): the marker exists but the
# API reports no merged_at → the chain must NOT exit 0; it reviews at the tip instead.
printf 'abc\n' > "$T/o/state/merged-5.done"
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "…an UNCONFIRMED state/merged-5.done does NOT end the chain: it names the API read and reviews at the tip" \
   $([ "$RC" = 0 ] && ran && grep -q "reports no merged_at" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# Arm (a2): the read FAILED → the chain says it could not READ it (not "reports no merged_at", which
# would be a claim about an answer that never arrived) and still reviews at the tip.
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'FIX_REQUIRED this head owns checks are RED: lint\n' > "$T/o/state/lanemerge-5.verdict"
MERGED_API_FAIL=1 drive 90 30
sleep 3
printf 'abc\n' > "$T/o/state/merged-5.done"
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "…a FAILED confirmation read is reported as UNREAD (not as 'reports no merged_at'), and the chain still reviews" \
   $([ "$RC" = 0 ] && ran \
      && grep -q "could not READ the merge confirmation" "$T/o/logs/chain-42.log" \
      && ! grep -q "reports no merged_at" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# Arm (b): the SAME marker WITH a confirmed merged_at → exit 0, no review — the pair is what makes the
# confirmation discriminating rather than decorative.
rig
GOT=0
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'FIX_REQUIRED this head owns checks are RED: lint\n' > "$T/o/state/lanemerge-5.verdict"
MERGED_AT_STUB='2026-10-19T00:00:00Z' drive 90 30
sleep 3
printf 'abc\n' > "$T/o/state/merged-5.done"
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "…a CONFIRMED merged_at ends the wait with no review (the confirmation is what decides)" \
   $([ "$RC" = 0 ] && ! ran && grep -q "MERGED by the lane" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# ── 3. phase + a CURRENT BLOCKED_ATTESTATION verdict → the lane handed off; review now ───────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'BLOCKED_ATTESTATION needs a fresh-context review record\n' > "$T/o/state/lanemerge-5.verdict"
drive 90 30
for _ in 1 2 3 4 5 6 7 8 9 10; do ran && break; sleep 1; done
stop
ck "a CURRENT BLOCKED_* verdict IS a handoff — the chain reviews the head the lane left behind" \
   $(ran && grep -q "handed off" "$T/o/logs/chain-42.log" && echo 0 || echo 1)

# ── 4. phase + a STALE verdict (older than the phase) → ignored, the chain keeps waiting ─────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'BLOCKED_ATTEMPTS from a previous dispatch\n' > "$T/o/state/lanemerge-5.verdict"
touch -t 202001010000 "$T/o/state/lanemerge-5.verdict" 2>/dev/null || true
drive 90 20
sleep 5
GOT=0; ran && GOT=1
ck "a verdict OLDER than the phase marker is IGNORED (a re-dispatched issue does not inherit the previous attempt's verdict)" \
   $([ "$GOT" = 0 ] && echo 0 || echo 1)
for _ in $(seq 1 40); do ran && break; sleep 1; done
wait "$PID" 2>/dev/null
ck "…and after the bounded wait it reviews (the wait is bounded, never a hang)" \
   $(ran && echo 0 || echo 1)

# ── 4b. a STALE phase marker is a claim about the PAST — do not honour it ───────────────────────
# The marker carries its own epoch ("<issue> <epoch>"). Testing only `[ -f ]` meant a lane killed at
# its wall limit left a marker that stalled this chain for the FULL handoff wait (30 min) on a PR
# nobody was working — and those 30 minutes are what push the issue claim past its lease.
rig
printf '42 %s\n' "$(( $(date +%s) - 999999 ))" > "$T/o/state/lanemerge-5.phase"
printf 'FIX_REQUIRED from a lane that is long gone\n' > "$T/o/state/lanemerge-5.verdict"
drive 0 30
for _ in 1 2 3 4 5 6 7 8 9 10; do ran && break; sleep 1; done
stop
ck "a phase marker OLDER than the lane's wall limit is STALE: the chain reviews now instead of waiting" \
   $(ran && grep -q "STALE merge-phase marker" "$T/o/logs/chain-42.log" && echo 0 || echo 1)
ck "…and it removes the dead marker (a stale flag that is never revalidated is how a lane is blocked twice)" \
   $([ ! -f "$T/o/state/lanemerge-5.phase" ] && echo 0 || echo 1)
# The age is DERIVED from the epoch the marker carries (STALL_TERM_REGISTRY term `_PHASE_AGE`,
# value: null): a hard-coded constant here would make the staleness verdict depend on a second clock
# that drifts from the lane's. Asserted in source shape, because that is the property — the behaviour
# above already covers the outcome.
ck "_PHASE_AGE is still DERIVED from the marker's own epoch (not a fixed literal)" \
   $(grep -q '_PHASE_AGE="\$(_phase_age)"' "$SCRIPT" && echo 0 || echo 1)

# ── 5. the claim release still happens on both exit paths (the EXIT trap is not bypassed) ────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'MERGED abc\n' > "$T/o/state/lanemerge-5.verdict"
drive 90 30
for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null
ck "the early MERGED exit still RELEASES the issue claim (the traps are installed before it)" \
   $(grep -q "RELEASED 42" "$T/released" 2>/dev/null && echo 0 || echo 1)

# ── 5b. A MERGE THAT DID NOT CLOSE THE ISSUE MUST NOT FREE ITS CLAIM (agent-infra#4230) ────────────
# ⛔ THE MEASURED DEFECT THIS PINS (and the reason it can go RED): on GitHub "merged" and "finished"
# are different facts — a merge auto-closes a linked issue only when the PR body carries a closing
# keyword AND the PR targets the default branch. A partial `Refs #N` merges and leaves the issue OPEN,
# and the chain's EXIT trap released `refs/claims/issue-<N>` on EVERY exit anyway. `refresh-candidates.sh`
# then re-selected the open, now-unclaimed issue and a SECOND lane opened a second PR for the same work:
# three issues, each carrying two open PRs (#14560 -> #14572 + #14596), and no claim left in the
# registry for any of them. The assertion is the registry, not the log line.
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'MERGED abc\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
MERGED_AT_STUB='2026-10-19T00:00:00Z' ISSUE_STATE_STUB=open drive 90 30
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "an OPEN issue after a CONFIRMED merge KEEPS its claim — the trap does not free work that is not finished (#4230)" \
   $([ "$RC" = 0 ] && ! ran && grep -q "still OPEN" "$T/o/logs/chain-42.log" \
      && ! grep -q "RELEASED 42" "$T/released" 2>/dev/null && echo 0 || echo 1)
ck "…and the KEPT claim is RENEWED (a term minted at DISPATCH perishes mid-follow-up — the same duplicate, one lease later)" \
   $(grep -q "RENEWED 42" "$T/released" 2>/dev/null && echo 0 || echo 1)
ck "…and the renewal carries the CAPTURED GENERATION (deadbeef), the fence that stops an hours-old chain renewing a lease it no longer holds" \
   $(grep -q "RENEWED 42 deadbeef" "$T/released" 2>/dev/null && echo 0 || echo 1)

# ── 5c. the SAME merge with the issue CLOSED releases, as before — the pair is what makes the
#        condition discriminating rather than "never release again" ─────────────────────────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'MERGED abc\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
MERGED_AT_STUB='2026-10-19T00:00:00Z' ISSUE_STATE_STUB=closed drive 90 30
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "a CLOSED issue after a confirmed merge still RELEASES the claim (the condition has both arms)" \
   $([ "$RC" = 0 ] && grep -q "RELEASED 42" "$T/released" 2>/dev/null \
      && ! grep -q "RENEWED 42" "$T/released" 2>/dev/null && echo 0 || echo 1)

# ── 5d. an UNREADABLE state is NOT "closed" (fail-closed), and it is likeliest exactly when the API
#        is rate-limited — a retry storm of halted merges would otherwise free every open issue at once
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'MERGED abc\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
MERGED_AT_STUB='2026-10-19T00:00:00Z' ISSUE_API_FAIL=1 drive 90 30
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "a FAILED issue-state read is NOT 'closed': the claim is kept and renewed (fail-closed, #4230)" \
   $([ "$RC" = 0 ] && grep -q "could not READ whether issue" "$T/o/logs/chain-42.log" \
      && ! grep -q "RELEASED 42" "$T/released" 2>/dev/null \
      && grep -q "RENEWED 42" "$T/released" 2>/dev/null && echo 0 || echo 1)

# ── 5e. THE OTHER HALF: a chain that merged NOTHING must STILL release (R8). Without this arm the
#        change would "pass" by never releasing again — stranding every refused issue for a lease ────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'BLOCKED_ATTEMPTS the rail refused twice\n' > "$T/o/state/lanemerge-5.verdict"
ISSUE_STATE_STUB=open drive 90 30
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "a chain that merged NOTHING still RELEASES its claim (an open issue must stay dispatchable by a peer — R8)" \
   $(ran && grep -q "RELEASED 42" "$T/released" 2>/dev/null \
      && ! grep -q "RENEWED 42" "$T/released" 2>/dev/null && echo 0 || echo 1)

# ── 5f. A SIGNAL IN THE GAP BETWEEN THE MERGE AND THE CHAIN'S OWN FLAG (agent-infra#4230, review P2) ──
# ⛔ THE MEASURED DEFECT: `merge-one.sh` writes `state/merged-<PR>.done` at the instant the rail merges,
# and this chain assigns `CHAIN_MERGED=1` only after that call RETURNS. A TERM in between (a reaped
# lane, a stopped cell, a killed box) fired the EXIT trap with the evidence present and the flag still
# 0 — RELEASING an open issue's claim: the exact duplicate #4230 measures, on the one path nobody
# watches. The same shape exists on the wait loop, which confirms the marker at most once per poll. So
# the trap must consult the MARKER (the same pair the loop uses), not only its own flag. The stub above
# reproduces the gap exactly: it writes the marker and then TERMs its parent.
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"
printf 'BLOCKED_ATTEMPTS the rail refused twice\n' > "$T/o/state/lanemerge-5.verdict"
: > "$T/o/state/kill-at-merge"
MERGED_AT_STUB='2026-10-19T00:00:00Z' ISSUE_STATE_STUB=open drive 0 30
for _ in $(seq 1 25); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
wait "$PID" 2>/dev/null; RC=$?
ck "a TERM in the GAP between merge-one's marker and CHAIN_MERGED still KEEPS the open issue's claim — the marker is the evidence, not the flag (#4230)" \
   $([ "$RC" = 143 ] && ran && grep -q "still OPEN" "$T/o/logs/chain-42.log" \
      && ! grep -q "RELEASED 42" "$T/released" 2>/dev/null \
      && grep -q "RENEWED 42 deadbeef" "$T/released" 2>/dev/null && echo 0 || echo 1)

echo
# ── 13. the confirmation is asked ONCE PER RETRY WINDOW, and a later window may still ask ───────
# ⛔ THIS GATE WAS UNPINNED (reviewer finding, P2, measured): reverting `if [ "${_marker_read:-0}" = 0 ]`
# to `if true` left the suite 12/12 green, so the ~120-reads-per-wait defect could come back silently.
# And "exactly once per appearance" was itself a defect — `merged-<PR>.done` is never pruned, so ONE
# rate-limited read meant the question was never asked again and the chain went on to review and
# dispatch at a PR the marker said was already merged. Both halves are asserted here with a read
# counter in the stub: several ticks inside one window cost ONE read, and a later window DOES re-ask.
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"; printf '1\n' > "$T/o/state/lanemerge-5.round"
printf 'WAITING\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
: > "$T/pulls-count"
GH_PULLS_COUNT="$T/pulls-count" CHAIN_POLL=1 CHAIN_CONFIRM_RETRY=600 MERGED_API_FAIL=1 drive 0 8
sleep 5
# ⛔ THE COUNT IS TAKEN **BEFORE** `stop`, and that is the property being pinned: `stop` kills the
# chain, and its EXIT/TERM trap re-verifies the marker itself (the #4230 gap arm — otherwise a signal
# between merge-one's marker and the chain's own flag releases an open issue's claim). That is ONE read
# on the way out, not a tick, and folding it into this count would make the row fail for doing the
# right thing. So: the WAIT spends exactly one read, and the whole RUN spends at most one more.
_n="$(grep -c READ "$T/pulls-count" 2>/dev/null || true)"
stop
sleep 1
_n_all="$(grep -c READ "$T/pulls-count" 2>/dev/null || true)"
ck "several wait ticks inside ONE retry window cost exactly ONE confirmation read (the gate has teeth)" \
   $([ "${_n:-0}" = 1 ] && echo 0 || echo 1)
ck "…and the EXIT path adds at most ONE more read (the trap re-verifies the marker, it does not re-poll)" \
   $([ "${_n_all:-9}" -ge 1 ] && [ "${_n_all:-9}" -le 2 ] && echo 0 || echo 1)

# ── 14. …and a LATER retry window DOES re-ask, so one transient failure is not permanent ────────
rig
printf '42 %s\n' "$(date +%s)" > "$T/o/state/lanemerge-5.phase"; printf '1\n' > "$T/o/state/lanemerge-5.round"
printf 'WAITING\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
: > "$T/pulls-count"
GH_PULLS_COUNT="$T/pulls-count" CHAIN_POLL=1 CHAIN_CONFIRM_RETRY=2 MERGED_API_FAIL=1 MERGED_AT_STUB=2026-01-01T00:00:00Z drive 0 12
for _ in $(seq 1 12); do [ -s "$T/o/state/cell" ] && break; ! kill -0 "$PID" 2>/dev/null && break; sleep 1; done
sleep 2
_was_alive=0; kill -0 "$PID" 2>/dev/null && _was_alive=1
stop
_n2="$(grep -c READ "$T/pulls-count" 2>/dev/null || true)"
ck "a LATER retry window re-asks: a transient read failure is not permanent (≥2 reads, and the chain ends without dispatching)" \
   $([ "${_n2:-0}" -ge 2 ] && [ "$_was_alive" = 0 ] && ! ran && echo 0 || echo 1)

# ── 15. a NON-NUMERIC CHAIN_POLL must not turn the wait into an unbounded (or instantly dying) run ─
# ⛔ THE FIXTURES MUST NAME THE PR THE STUB RETURNS (reviewer finding, P1, measured): `gh pr list` prints
# 5, so a `lanemerge-7.*` fixture was never read — the chain logged "no merge-phase marker", never
# reached `sleep $CHAIN_POLL`, and the PRE-FIX script scored 15/15 against this suite. The case now keys
# everything to PR 5 and asserts the phase wait was ENTERED before it asserts the bound.
rig
printf 'open\n' > "$T/o/state/lanemerge-5.phase"; printf 'WAITING\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
PATH="$T/bin:$PATH" O="$T/o" O_WORK="$T/o" HOME="$T/home" CHAIN_CLAIM_COMMIT="deadbeef" MERGED_API_FAIL=1 \
  CHAIN_POLL=abc CHAIN_CONFIRM_RETRY=1 LANE_PHASE_GRACE=0 LANE_HANDOFF_WAIT=2 \
  bash "$SCRIPT" "$T/repo" o/r 5 feat/5-x >/dev/null 2>"$T/poll-err.log" &
PID=$!
_bounded=0
for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || { _bounded=1; break; }; sleep 1; done
stop
_entered="$(grep -c 'in its merge phase' "$T/o/logs/chain-5.log" 2>/dev/null || true)"
# ⛔ THE SHARP DISCRIMINATOR IS THE SHELL ITSELF (measured): with the guard removed the chain reaches
# `sleep "$CHAIN_POLL"` / `$((waited + CHAIN_POLL))` and dies with `integer expression expected` and
# `abc: unbound variable` on stderr. "Bounded" alone passes on that death; a clean stderr does not.
_shellerr="$(grep -cE 'integer expression expected|unbound variable|invalid time interval' "$T/poll-err.log" 2>/dev/null || true)"
_reviewed="$(grep -c 'merge-one rc=' "$T/o/logs/chain-5.log" 2>/dev/null || true)"
ck "a NON-NUMERIC CHAIN_POLL is refused: the WAIT IS ENTERED, stays bounded, keeps stderr clean, and still reaches the review" \
   $([ "${_entered:-0}" -ge 1 ] && [ "$_bounded" = 1 ] && [ "${_shellerr:-1}" = 0 ] && [ "${_reviewed:-0}" = 1 ] && echo 0 || echo 1)

# ── 16. a ZERO poll is refused too: `0` passes the non-numeric guard and never advances the bound ──
# ⛔ MEASURED (reviewer finding, R8): deleting the floor left 15/15 green while `CHAIN_POLL=0` survived
# 150s against LANE_HANDOFF_WAIT=2 — an unbounded wait with no stderr to show for it. The case asserts
# the wait was ENTERED and that the run TERMINATED inside its own bound.
rig
printf 'open\n' > "$T/o/state/lanemerge-5.phase"; printf 'WAITING\n' > "$T/o/state/lanemerge-5.verdict"
printf 'x\n' > "$T/o/state/merged-5.done"
PATH="$T/bin:$PATH" O="$T/o" O_WORK="$T/o" HOME="$T/home" CHAIN_CLAIM_COMMIT="deadbeef" MERGED_API_FAIL=1 \
  CHAIN_POLL=0 CHAIN_CONFIRM_RETRY=0 LANE_PHASE_GRACE=0 LANE_HANDOFF_WAIT=2 \
  bash "$SCRIPT" "$T/repo" o/r 5 feat/5-x >/dev/null 2>"$T/zero-err.log" &
PID=$!
_zero_bounded=0
for _ in $(seq 1 60); do kill -0 "$PID" 2>/dev/null || { _zero_bounded=1; break; }; sleep 1; done
stop
_zero_entered="$(grep -c 'in its merge phase' "$T/o/logs/chain-5.log" 2>/dev/null || true)"
_zero_err="$(grep -cE 'integer expression expected|unbound variable|invalid time interval' "$T/zero-err.log" 2>/dev/null || true)"
ck "a ZERO poll is refused: the wait is ENTERED, it TERMINATES inside its own bound, and stderr stays clean" \
   $([ "${_zero_entered:-0}" -ge 1 ] && [ "$_zero_bounded" = 1 ] && [ "${_zero_err:-1}" = 0 ] && echo 0 || echo 1)

if [ "$fail" -eq 0 ]; then
  printf '\033[32mALL %d chain-merge verdict checks passed\033[0m\n' "$pass"
else
  printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
