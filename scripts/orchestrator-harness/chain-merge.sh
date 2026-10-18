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
  # repo's ref and the release would be a no-op. Every git call in claims.sh is `-C "$CLAIM_REPO"`,
  # so the cwd is irrelevant and no `cd` (a gated shape) is needed.
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
    echo "[chain $N] ⚠️ $csh predates the issue-claim RELEASE (no claim_issue_release_record) — the claim is NOT released; fix: cp scripts/orchestrator-harness/*.sh ~/orchestrator/" >> "$LOG"
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
for i in $(seq 1 90); do
  PR="$(gh pr list --repo "$OR" --state open --head "$BR" --json number --jq '.[0].number' 2>/dev/null)"
  [ -n "$PR" ] && [ "$PR" != "null" ] && break
  sleep 60
done
if [ -z "${PR:-}" ] || [ "$PR" = "null" ]; then
  echo "[chain $N] no PR appeared for $BR after 90 min" >> "$LOG"; exit 1
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
