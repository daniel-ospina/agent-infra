#!/usr/bin/env bash
# chain-merge.sh <repo-path> <owner/repo> <issue> <branch>
# Waits for the lane to open its PR, then runs the full review->record->merge chain.
set -u
REPO="$1"; OR="$2"; N="$3"; BR="$4"
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
LOG="$O/logs/chain-$N.log"
echo "[chain $N] waiting for PR on $BR $(date)" > "$LOG"
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
# ✅ THE merge-one.sh HALF HAS LANDED (PR #1839): merge-one.sh now sources spawn-gate.sh and
# `exit "$AGENT_LOAD_REFUSED"` (75) when the load gate refuses (merge-one.sh:598, :693), and a
# refused reviewer is distinguished from a failed one via AGENT_STARTED (merge-one.sh:687) — so the
# refusal branch BELOW propagates a REAL 75, not a forward-looking one. Its early guards still exit
# 1/2/3/4, and those propagate too. (merge-one.sh's final reporting lines still return 0 on the
# reviewer-FAILED and clean paths — by design, not a residual.)
exit "$rc"
