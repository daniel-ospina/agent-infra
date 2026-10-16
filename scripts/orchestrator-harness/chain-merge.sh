#!/usr/bin/env bash
# chain-merge.sh <repo-path> <owner/repo> <issue> <branch>
# Waits for the lane to open its PR, then runs the full review->record->merge chain.
set -u
REPO="$1"; OR="$2"; N="$3"; BR="$4"
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
LOG="$O/logs/chain-$N.log"
echo "[chain $N] waiting for PR on $BR $(date)" > "$LOG"

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
  local csh="${CLAIMS_SH:-$O/claims.sh}"
  trap - EXIT INT TERM
  [ -f "$csh" ] || return 0
  # CLAIM_REPO is the repo the claim was pushed to (refs/claims live in the TARGET repo's origin),
  # which is the same value orch-loop.sh used when it acquired — a mismatch here would read the
  # WRONG repo's ref and the release would be a no-op. Every git call in claims.sh is `-C
  # "$CLAIM_REPO"`, so the cwd is irrelevant and no `cd` (a gated shape) is needed.
  ( CLAIM_REPO="$REPO"; . "$csh"; claim_issue_release_record "$O" "$REPO" "$N" ) >/dev/null 2>&1 \
    && echo "[chain $N] released refs/claims/issue-$N" >> "$LOG"
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
