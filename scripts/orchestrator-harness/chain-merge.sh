#!/usr/bin/env bash
# chain-merge.sh <repo-path> <owner/repo> <issue> <branch>
# Waits for the lane to open its PR, then runs the full review->record->merge chain.
set -u
REPO="$1"; OR="$2"; N="$3"; BR="$4"
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST (#1988). The line above prepends the tool dirs, so a REAL gh in
# either of them outranks the seeded `$O/gh-rest` (Mac REST adapter) / `$O/gh-limit` (cell
# serialiser) — and a shim that is never resolved is an INERT layer: it reports protection and
# provides none. Re-assert both here, adapter last so `$O/gh-rest` (which itself calls the same
# helper) wins where it exists. Guarded by `-d`, so a box that ships neither is unchanged.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
LOG="$O/logs/chain-$N.log"
echo "[chain $N] waiting for PR on $BR $(date)" > "$LOG"
# The instant THIS chain started. It is the epoch every capacity-refusal record is compared
# against, and it is read ONCE so the bound cannot drift while the wait runs.
CHAIN_START="$(date +%s)"

# ── the wait's own bounds — testable, and an operator knob (agent-infra#1909) ────────────────
# These were the literals 90 and 60. They are named because the CAPACITY TRANSFER regression suite
# below the loop has to prove a STALE refusal record does NOT end the wait, and it can only do that
# if it can make a bounded wait short enough to observe. Both are validated here rather than
# trusted: an unreadable value must not turn into a zero-iteration loop that exits as if the lane
# had never produced a PR (which would release the claim under a live lane — duplicate work on
# every peer, the failure R4 exists to prevent).
# `case` and not `is_num`: this script sources only `claims.sh`, and only inside the release
# function, so it has no numeric predicate of its own to borrow (same shape as claims.sh's clamp).
chk_pos_int() { case "${1:-}" in ''|*[!0-9]*|0) return 1 ;; esac; [ "${#1}" -le 9 ]; }
CHAIN_POLLS="${CHAIN_POLLS:-90}"
CHAIN_POLL_SECS="${CHAIN_POLL_SECS:-60}"
chk_pos_int "$CHAIN_POLLS" || { echo "[chain $N] WARN: CHAIN_POLLS='$CHAIN_POLLS' is not a positive integer — using 90" >> "$LOG"; CHAIN_POLLS=90; }
chk_pos_int "$CHAIN_POLL_SECS" || { echo "[chain $N] WARN: CHAIN_POLL_SECS='$CHAIN_POLL_SECS' is not a positive integer — using 60" >> "$LOG"; CHAIN_POLL_SECS=60; }

# ── ORDERING SLACK around the per-dispatch epoch bound (agent-infra#1909, round-1 review P1) ────
# ⛔ A BARE `refused_epoch >= CHAIN_START` DISCARDS REAL REFUSALS. `dispatch-merge.sh` spawns the
# LANE first and the CHAIN second, and the lane writes the record a few ms after ITS spawn while this
# chain reads `CHAIN_START` after its own — so the record is normally written BEFORE this chain reads
# its start, and the two agree only when both land in the same second. Measured: the lane's whole
# refusal path is ~4 ms and this chain reaches `date +%s` ~8-15 ms after its fork, so a second boundary
# falls between them a few percent of the time when idle — and a refusal only happens when the box is
# at capacity, which is exactly when a fork can stall past a second. The failure was SILENT and total:
# the chain logged the ordinary `no PR appeared` timeout and held `refs/claims/issue-<N>` for the whole
# 90 minutes — R8's defect, intact, for that dispatch.
#
# The slack is STRICTLY SHORTER than the RECORD'S OWN yield window (`until - epoch` — see the clamp in
# `cap_refusal_gate`), so it still cannot admit a record from an EARLIER dispatch: the refusing box
# stands down for exactly that window (`orch-loop.sh`'s `capacity_yield_live()`), so it cannot
# re-dispatch the same issue inside it, and a record older than its own window is not this dispatch's.
# ⛔ "STRICTLY" is the load-bearing word: capping the slack AT the window would admit the previous
# dispatch's record at the one second this box may first re-dispatch (round-2 review P2 — it is
# reachable from the knobs alone, e.g. `CAPACITY_YIELD_SECS=60`). 0 restores the strict comparison.
CAPACITY_REFUSAL_GRACE_SECS="${CAPACITY_REFUSAL_GRACE_SECS:-60}"
case "$CAPACITY_REFUSAL_GRACE_SECS" in ''|*[!0-9]*)
  echo "[chain $N] WARN: CAPACITY_REFUSAL_GRACE_SECS='$CAPACITY_REFUSAL_GRACE_SECS' is not a whole number of seconds — using 60" >> "$LOG"
  CAPACITY_REFUSAL_GRACE_SECS=60 ;;
esac

# ── CAPACITY TRANSFER: end a wait that can never succeed (agent-infra#1909) ──────────────────
# `lane.sh` writes `state/capacity-refused-<N>` the moment the spawn gate refuses, and the format is
# `<refused_epoch>\t<yield_until>\t<gate>` (see the writer there; it is the ONE definition).
# This is the reader that turns that refusal into "another box may take this": this chain stops
# waiting, its EXIT trap releases `refs/claims/issue-<N>` with the existing FENCED release, and
# every peer's `claim_issue_preflight` therefore answers CLEAN instead of COLLISION.
#
# ⛔ NOT RELEASING IS WHAT R8 IS ABOUT. The old shape waited 90 minutes for a PR that could not
# appear, and the claim it held made the issue ineligible on every box for those 90 minutes — so a
# per-machine capacity refusal became fleet-wide idleness, exactly the reported 2026-10-17 stall.
#
# ⛔ THE EPOCH BOUND IS THE SAFETY PROPERTY, NOT A NICETY. A record left by an earlier run of the
# same issue must never end a LIVE lane's chain: that would release the claim while the lane is
# still working, and a peer would then open a second lane for the same issue. `refused_epoch >=
# CHAIN_START` (same clock, same box) admits only a refusal from this very dispatch.
cap_refusal_gate() { # -> prints `load|disk|land` and returns 0 iff THIS dispatch was refused by a gate
  local f="$O/state/capacity-refused-${N:-}" ep until gate grace win
  [ -n "${N:-}" ] || return 1
  case "${N:-}" in *[!0-9]*) return 1 ;; esac
  [ -r "$f" ] || return 1
  read -r ep until gate < "$f" 2>/dev/null || return 1
  case "${ep:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${until:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#ep}" -le 18 ] || return 1
  [ "${#until}" -le 18 ] || return 1
  # The slack is the RECORD's own stand-down window, capped by the operator knob — see above. An
  # incoherent pair (`until <= ep`) buys no slack at all: it is still evidence that a refusal happened
  # (field 1 is what this reader consumes), but it must not widen the admission window.
  win=$(( until - ep ))
  [ "$win" -lt 0 ] && win=0
  grace="$CAPACITY_REFUSAL_GRACE_SECS"
  [ "$grace" -gt "$win" ] && grace="$win"
  # ⛔ THE SLACK MUST STAY STRICTLY SHORTER THAN THE RECORD'S OWN STAND-DOWN (round-2 review P2).
  # `grace == win` does not bound the epoch rule, it CANCELS it: this box may not legitimately
  # re-dispatch the issue before `until`, so every legitimately-arriving chain satisfies
  # `ep <= CHAIN_START - win`, while admission is `ep >= CHAIN_START - grace`. With `grace == win`
  # the single second `ep == CHAIN_START - win` is admitted — an EARLIER dispatch's record ending a
  # LIVE lane's wait, whose EXIT trap then releases the claim under it so a peer opens a second lane
  # for the same issue (R4's duplicate work, the failure this bound exists to prevent).
  # It is reachable from the documented knobs alone, without any corruption: `min()` yields
  # `grace == win` IFF `CAPACITY_REFUSAL_GRACE_SECS >= CAPACITY_YIELD_SECS` — e.g. the plausible
  # `CAPACITY_YIELD_SECS=60` "one minute" tuning under the default 60s slack. So the bound is
  # enforced for EVERY accepted pairing, not only the shipped defaults (60 < 900), and the required
  # relation is stated in README §7.2d at the point a future tuning would change it.
  # `win == 0` (an incoherent `until <= ep` pair) keeps the strict `ep >= CHAIN_START` bound instead
  # of turning the slack negative — it buys no slack, exactly as documented above.
  if [ "$win" -gt 0 ] && [ "$grace" -ge "$win" ]; then grace=$(( win - 1 )); fi
  [ "$ep" -ge "$(( CHAIN_START - grace ))" ] || return 1
  # Field 3 is the REMEDY this chain reports to whoever reads the exit code (75 load / 77 disk /
  # 74 land-backlog), not a gate: an unrecognised value is reported as `load` because the refusal
  # itself is already proven by fields 1-2, and refusing to end the wait over one corrupt byte is the
  # fleet-wide idleness R8 removes. Field 2 is deliberately NOT consulted here — the yield window is
  # the controller's business (`capacity_yield_live`), and an incoherent window must not make a proven
  # refusal unreadable. README §7.2d states exactly this per-reader split.
  case "${gate:-}" in disk) printf 'disk' ;; land) printf 'land' ;; *) printf 'load' ;; esac
  return 0
}

# ⛔ THE GENERATION IS INHERITED FROM WHOEVER SPAWNED THIS CHAIN, NEVER READ HERE (adversarial review).
# The handover record is keyed on the ISSUE, and the same box can hold the same issue twice while this
# chain is alive (its lease lapsed and the loop re-acquired; this chain is still waiting on a PR). A
# trap that read the record when it FIRED would fence on the newer commit — which IS the ref tip — and
# delete a live claim. Capturing at START fixed that for the trap, but a read at start is still a read
# of shared state: a chain RE-RUN by hand (both this file's own timeout message and
# nonblocking-dispatch.sh invite that) starts *after* a re-acquire, so it would capture a generation
# it never took and release the holder's claim on exit — reproduced.
# So `dispatch-merge.sh`, which spawns this chain in the same loop body that wrote the record
# milliseconds earlier, passes `CHAIN_CLAIM_COMMIT` in the environment. Nothing else sets it: a manual
# re-run has NO generation, and the refusal below then keeps the claim instead of deleting someone
# else's. That is the fail-closed direction, and it costs one lease.
CHAIN_CLAIM_COMMIT="${CHAIN_CLAIM_COMMIT:-}"

# ── release the cross-box ISSUE claim (#1850) ────────────────────────────────────────────────
# `orch-loop.sh` claimed `refs/claims/issue-<N>` when it dispatched this issue, and that claim is
# this box's declaration that the issue is IN FLIGHT. Holding it after the chain is over would keep
# a FREE issue undispatchable by every box until the lease ran out — up to CLAIM_ISSUE_TTL (3h) — so
# it is released on EVERY exit path: a clean merge, a failed one, and the "no PR appeared" timeout.
#
# ⛔ THE RELEASE IS FENCED (`--force-with-lease=<ref>:<own>`), so it refuses to delete a ref that no
# longer points at the commit THIS box pushed: a holder whose lease expired and was reclaimed by a
# peer cannot delete the winner's claim. The recorded commit is read and consumed by
# `claim_issue_release_record` (claims.sh), which is the ONE implementation of that handover — this
# function only owns the TRAP and the log line.
release_issue_claim() {
  local csh="$O/claims.sh" out rc=0
  trap - EXIT INT TERM
  [ -f "$csh" ] || return 0
  # CLAIM_REPO is the repo the claim was pushed to (refs/claims live in the TARGET repo's origin),
  # which is the value orch-loop.sh used when it acquired — a mismatch here would read the WRONG
  # repo's ref and the release would be a no-op. Every git call in claims.sh resolves the repo from
  # CLAIM_REPO itself (it `cd`s into it inside a subshell, 2026-10-18 — a `git -C` there was NOT
  # cwd-independent and returned an empty claim commit on the launchd cells), so THIS file's cwd is
  # irrelevant and no `cd` (a gated shape) is needed here.
  # ⛔ SOURCED INTO THIS SHELL, NOT A SUBSHELL, AND ITS FAILURES ARE LOGGED (2026-10-16 review).
  # `( … ) >/dev/null 2>&1 && echo released` reported SUCCESS ONLY: a refused fence, a network
  # failure, or a registry too old to HAVE the release function left the claim running to its full
  # lease with NOTHING in the chain log to say so — the operator's only signal was a missing
  # "released" line. The reason lives in CLAIM_RESULT, which a subshell discards.
  CLAIM_REPO="$REPO"
  if ! . "$csh" 2>/dev/null; then
    echo "[chain $N] ⚠️ $csh failed to source — the issue claim is NOT released (it runs to its lease, CLAIM_ISSUE_TTL=${CLAIM_ISSUE_TTL:-10800}s)" >> "$LOG"
    return 0
  fi
  if ! declare -f claim_issue_release_record >/dev/null 2>&1; then
    echo "[chain $N] ⚠️ $csh predates the issue-claim RELEASE (no claim_issue_release_record) — the claim is NOT released; fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator" >> "$LOG"
    return 0
  fi
  # ⛔ NO CAPTURED GENERATION → DO NOT RELEASE (acceptance-review finding). The capture at chain start
  # is empty when the handover record did not exist yet (the `claim_issue_record` in orch-loop.sh
  # failed — the loop logs that this chain cannot fence the release), when `$O/claims.sh` predates the
  # reader, or when the record exists but is unreadable. `claim_issue_release_record` treats an EMPTY
  # expectation as "read the record now", which is right for dispatch-merge.sh (its release is milliseconds after the write) but wrong
  # HERE: a chain that fires hours later would then fence on whatever generation the record holds —
  # the newer holder's own commit, which IS the ref tip — and delete a live claim. Refusing costs this
  # box one lease; deleting the wrong claim duplicates work on two boxes, so this is the fail-closed
  # side of the same asymmetry as the pre-flight. Loud, and the lease still reaps it.
  if [ -z "${CHAIN_CLAIM_COMMIT:-}" ]; then
    echo "[chain $N] ⚠️ no captured claim generation (the handover record was absent at chain start) — NOT releasing refs/claims/issue-$N: a stale chain must never delete a NEWER claim. It runs to its lease (CLAIM_ISSUE_TTL=${CLAIM_ISSUE_TTL:-10800}s)." >> "$LOG"
    return 0
  fi
  if out="$(claim_issue_release_record "$O" "$REPO" "$N" "${CHAIN_CLAIM_COMMIT:-}")"; then
    echo "[chain $N] released refs/claims/issue-$N" >> "$LOG"
  else
    rc=$?
    echo "[chain $N] ⚠️ the issue claim was NOT released (rc=$rc): ${out:-${CLAIM_RESULT:-no reason given}} — it runs to its lease (CLAIM_ISSUE_TTL=${CLAIM_ISSUE_TTL:-10800}s)" >> "$LOG"
  fi
  return 0
}
# ⛔ INT/TERM ARE SEPARATE AND THEY EXIT. A handler that only RETURNS does not terminate the shell
# for INT/TERM — bash RESUMES the interrupted command loop — so a single `trap f EXIT INT TERM`
# would release the claim and then keep WAITING 90 MINUTES for a PR that will never come. The
# handler clears all three traps on entry, so the `exit` cannot re-enter it (one release, one exit,
# and the exit status matches the signal).
trap 'release_issue_claim' EXIT
trap 'release_issue_claim; exit 130' INT
trap 'release_issue_claim; exit 143' TERM
PR=""
for i in $(seq 1 "$CHAIN_POLLS"); do
  # Checked BEFORE the PR lookup every iteration: the lane's refusal is a local file read, so this
  # costs microseconds, and it caps the transfer latency at one poll interval instead of 90 minutes.
  if _cap_gate="$(cap_refusal_gate)"; then
    case "$_cap_gate" in
      disk) _cap_rc=77 ;;
      # 74 is spawn-gate.sh's AGENT_LAND_BACKLOG: the lane was refused because the REPO's open-PR
      # backlog is over its own measured landing ceiling (#2409), not because this box is short of
      # anything. The exit code must differ for the same reason 75 and 77 differ from each other —
      # the remedy is different — and it must be a STOP here for the same reason: no PR can appear.
      land) _cap_rc=74 ;;
      *)    _cap_rc=75 ;;
    esac
    if [ "$_cap_gate" = "land" ]; then
      echo "[chain $N] land-backlog: lane-$N was refused because the repo's open-PR backlog is over its own landing ceiling (#2409), so no PR can appear — exiting now instead of after ${CHAIN_POLLS} x ${CHAIN_POLL_SECS}s. The EXIT trap releases refs/claims/issue-$N. This is NOT a capacity transfer: the backlog is repo-wide, so handing the issue to a peer box would not clear it — the remedy is to LAND the open queue (or dispatch a P0-blocker / base-red repair, which are exempt)" >> "$LOG"
    else
      echo "[chain $N] capacity transfer: lane-$N was refused at the $_cap_gate gate, so no PR can appear — exiting now instead of after ${CHAIN_POLLS} x ${CHAIN_POLL_SECS}s. The EXIT trap releases refs/claims/issue-$N, so a peer with capacity can claim it; this box stands down via state/capacity-refused-$N for the record's yield window (agent-infra#1909)" >> "$LOG"
    fi
    exit "$_cap_rc"
  fi
  # ⛔ A PRESENT-BUT-REJECTED RECORD IS THE ONLY MISS THIS MECHANISM CAN PRODUCE, and it used to be
  # indistinguishable from a lane that simply has not opened its PR yet: the chain logged the ordinary
  # timeout and the operator had no way to tell a discarded refusal from a slow lane. Say it once (the
  # loop runs up to CHAIN_POLLS times; one line is signal, ninety are noise).
  if [ "$i" = "1" ] && [ -r "$O/state/capacity-refused-$N" ]; then
    echo "[chain $N] capacity record state/capacity-refused-$N is present but was NOT admitted as this dispatch's (epoch older than this chain's start by more than the ${CAPACITY_REFUSAL_GRACE_SECS}s slack, or older than its own yield window, unreadable, or malformed) — waiting as before. If this recurs, the lane is refusing with a record this chain cannot attribute; nothing was released (agent-infra#1909)" >> "$LOG"
  fi
  PR="$(gh pr list --repo "$OR" --state open --head "$BR" --json number --jq '.[0].number' 2>/dev/null)"
  [ -n "$PR" ] && [ "$PR" != "null" ] && break
  sleep "$CHAIN_POLL_SECS"
done
if [ -z "${PR:-}" ] || [ "$PR" = "null" ]; then
  echo "[chain $N] no PR appeared for $BR after ${CHAIN_POLLS} min (CHAIN_POLLS=${CHAIN_POLLS} x CHAIN_POLL_SECS=${CHAIN_POLL_SECS}s)" >> "$LOG"; exit 1
fi
echo "[chain $N] PR #$PR found — starting merge chain $(date)" >> "$LOG"
bash "$O/merge-one.sh" "$REPO" "$OR" "$PR" "$BR" >> "$LOG" 2>&1
rc=$?
# A load refusal (75) is not a failure of the work: nothing ran and nothing was consumed. Name it
# HERE, in the log the operator reads for this chain — the reviewer's own line is inside
# merge-$PR.log, and on a box with no controller running nothing else would ever re-dispatch it.
echo "[chain $N] merge-one rc=$rc $(date)" >> "$LOG"
if [ "$rc" = "75" ]; then
  echo "[chain $N] reviewer NOT started (load gate) — re-run this chain (or let the controller re-dispatch it) when 1-min load is below MAX_LOAD" >> "$LOG"
fi
echo "[chain $N] done $(date)" >> "$LOG"
# ⛔ EXIT WITH merge-one.sh's STATUS (#1720 review). This script used to end on the `echo …done…`
# above, so `$?` was the STATUS OF `echo` — always 0 — and a caller doing `chain-merge.sh … && next`
# took the success branch whatever happened.
# ⚠️ WHAT THIS DOES NOT YET FIX (review round 2026-10-15): `merge-one.sh` ITSELF still ends on a
# reporting `echo` and contains no `exit 75` / `AGENT_STARTED` (0 hits), so on the paths that reach
# its end — a reviewer that FAILED, and a clean pass — it returns 0, and the refusal branch BELOW is
# FORWARD-LOOKING. Its early guards do exit 1/2/3/4, and those propagate now; the 75 will propagate
# once the blocked `#8521` half lands in merge-one.sh (PR #1769/#1730 hold that file). Until then the
# reporting lines stay truthful about a refusal while the EXIT CODE cannot distinguish a refused
# reviewer from a successful one. Recorded in port-provenance.txt as a residual, not claimed as done.
exit "$rc"
