#!/usr/bin/env bash
# dispatch-merge.sh <repo-path> <owner/repo> <issue> [<issue> ...]
# For each issue: worktree -> lane (implement+PR) -> chain-merge (review+record+merge).
set -u
REPO="$1"; OR="$2"; shift 2
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
chmod +x "$O/lane.sh" "$O/merge-one.sh" "$O/chain-merge.sh" 2>/dev/null

# ── release the cross-box ISSUE claim on the NO-CHAIN path (agent-infra#1850) ────────────────
# `orch-loop.sh` takes `refs/claims/issue-<N>` when it dispatches, and `chain-merge.sh` releases it
# from its EXIT trap — the NORMAL path. This is the path that never reaches that trap: the worktree
# could not be created, so no lane and no chain are spawned and NOTHING else will ever release the
# claim. Without this, a single failed `git worktree add` would hold a FREE issue across every box
# until the lease ran out (CLAIM_ISSUE_TTL, 3h) — and the reaper would meanwhile return the issue to
# the pool, where every box would read it as another box's live claim.
# The record/fence convention is claims.sh's `claim_issue_release_record` (one implementation; see
# its comment for why the handover file exists rather than the acquiring process doing the release).
release_issue_claim_unspawned() { # <issue>
  local n="$1" csh="$O/claims.sh" out rc=0
  [ -f "$csh" ] || return 0
  # ⛔ NOT `( … ) >/dev/null 2>&1`: reporting success only left a refused fence, a network failure or
  # a stale registry indistinguishable from a release that worked (2026-10-16 review) — the claim
  # then ran to its full lease with nothing in the dispatch log to say why.
  CLAIM_REPO="$REPO"
  if ! . "$csh" 2>/dev/null; then
    echo "#$n: ⚠️ $csh failed to source — the issue claim is NOT released (it runs to its lease)"
    return 0
  fi
  if ! declare -f claim_issue_release_record >/dev/null 2>&1; then
    echo "#$n: ⚠️ $csh predates the issue-claim release (no claim_issue_release_record) — the claim is NOT released; fix: cp scripts/orchestrator-harness/*.sh ~/orchestrator/"
    return 0
  fi
  # ⚠️ The generation guard is deliberately INERT on this path, and that is correct rather than an
  #      omission: this releases seconds after the record was written by the box that took the claim,
  #      so the record IS this dispatch's generation — there is no older holder to refuse. A capture
  #      at "chain start" would only exist here if a caller exported one, so the value is normally
  #      empty and the release leans on the RECORD's value as its fence (`--force-with-lease` refuses
  #      a ref that moved under it). The guard earns its keep in `chain-merge.sh`, whose trap can fire
  #      HOURS later, after the same box has re-acquired and overwritten the record.
  if out="$(claim_issue_release_record "$O" "$REPO" "$n" "${CHAIN_CLAIM_COMMIT:-}")"; then
    echo "#$n: released refs/claims/issue-$n (no chain was spawned)"
  else
    rc=$?
    echo "#$n: ⚠️ the issue claim was NOT released (rc=$rc): ${out:-${CLAIM_RESULT:-no reason given}} — it runs to its lease"
  fi
  return 0
}
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ── the worker launcher (worker-terminal.sh) ─────────────────────────────────────────────────────
# Lanes and chains are WORKERS, so they are started by the same module orch-loop.sh uses — a durable
# terminal on a cmux surface, tmux only on the launchd surface. A tmux lane on a cloud cell dies at
# ~21 log lines (measured on all three cells, 2026-10-20); this is the lane-spawning path, so leaving
# it on tmux would have fixed the fixers and left the lanes dying.
for _wt_cand in "$O/worker-terminal.sh" "$(dirname "${BASH_SOURCE[0]:-$0}")/worker-terminal.sh"; do
  [ -f "$_wt_cand" ] && { WT_MOD="$_wt_cand"; break; }
done
[ -n "${WT_MOD:-}" ] && . "$WT_MOD"
# ⛔ The guard covers EVERY verb this script calls — `wt_launcher` (the startup/refusal line) and
# `wt_count` (the final worker count) included, not only the three that look load-bearing: a module
# that satisfies a narrower guard still leaves the controller printing `launcher=` and a false `0`.
for _wt_v in wt_spawn wt_alive wt_close wt_launcher wt_count; do
  command -v "$_wt_v" >/dev/null 2>&1 || { echo "dispatch-merge: FATAL worker-terminal.sh is missing or stale at ${WT_MOD:-$O} (no $_wt_v; needs wt_spawn/wt_alive/wt_close/wt_launcher/wt_count) — refusing to dispatch lanes that cannot be started or stopped; fix: cp scripts/orchestrator-harness/*.sh \$O/"; exit 78; }
done
cd "$REPO" || { echo "dispatch-merge: cannot cd into $REPO — releasing every claim in this batch (no lane and no chain can start here)"
  for N in "$@"; do release_issue_claim_unspawned "$N"; done
  exit 1; }
git fetch origin main --quiet 2>/dev/null

for N in "$@"; do
  # Issue numbers come from the GitHub API via candidates.txt; never let one reach a shell string.
  case "${N:-}" in ''|*[!0-9]*) echo "#$N: SKIPPED (non-numeric issue id)"; continue ;; esac
  WT="tm-$N"; BR="feat/$N-tm"
  # Capture, then classify in the SHELL — never `… | grep -q`, whose false negative
  # under `pipefail` would send this lane down the `worktree add` path, fail on the
  # existing worktree, and silently SKIP the issue (#864).
  wt_registered=0
  case "$(git worktree list 2>/dev/null || true)" in *"/$WT "*) wt_registered=1 ;; esac
  if [ "$wt_registered" -eq 0 ]; then
    git worktree add ".worktrees/$WT" -b "$BR" origin/main >/dev/null 2>&1 \
      || { echo "#$N: worktree add failed (branch exists?) — skipping"; release_issue_claim_unspawned "$N"; continue; }
  fi
  _lan="$(wt_launcher)"
  wt_spawn "lane-$N" "$REPO/.worktrees/$WT" "bash '$O/lane.sh' $N '$BR' '$OR'" \
    && echo "#$N: lane-$N (implement+PR, launcher=$_lan)"
  # ⛔ IF THE CHAIN CANNOT BE STARTED, NO TRAP WILL EVER RELEASE THE CLAIM (2026-10-16 review): this
  # was the second no-chain path, and it was covered by nothing. A stale `chain-$N` session name, a
  # dead tmux server or tmux missing all land here, and the issue then stays claimed on every box for
  # the whole lease. (A failed LANE spawn is deliberately NOT released here: the chain IS alive and
  # waiting for that PR, so releasing would let a peer duplicate the work. That wait is bounded —
  # 90 minutes, then chain-merge.sh's own trap releases it.)
  # ⛔ HAND THE CHAIN ITS GENERATION (adversarial review). The record here is the one THIS dispatch
  # wrote — the one fact a chain cannot safely discover for itself later (see chain-merge.sh's comment).
  # ⚠️ The window is NOT microseconds for every member of a batch: the loop sleeps between issues, so
  # the k-th issue's record is read ~30·(k-1)s after it was written. The read is still correct because
  # the record can only be OVERWRITTEN by a re-acquire, and a re-acquire needs the current claim to be
  # RELEASED or to reach its CLAIM_ISSUE_TTL (3h) first — not because the gap is small. Do not shorten
  # the TTL without revisiting this line.
  chain_gen="$( . "$O/claims.sh" 2>/dev/null; claim_issue_record_commit "$O" "$N" 2>/dev/null )" || true
  if wt_spawn "chain-$N" "$REPO" "CHAIN_CLAIM_COMMIT='$chain_gen' bash '$O/chain-merge.sh' '$REPO' '$OR' $N '$BR'"; then
    echo "        chain-$N (review->record->merge)"
  else
    # ⛔ THE LANE IS ALREADY RUNNING (the spawn two lines up) — so "no chain will ever run" is true
    # while "nothing is running" is NOT, and releasing here would declare an issue this box is
    # ACTIVELY IMPLEMENTING free: a peer claims it, duplicates the work, and this box still opens a PR
    # that nothing will merge (cycle-2 adversarial review). Reachable without any peer — a leftover
    # `chain-$N` session name, since nothing reaps `chain-*` — and the claim then comes back to the
    # pool on its lease. So STOP THE LANE FIRST and release only once it is confirmed gone; if it
    # cannot be stopped, KEEP the claim: the lease expiring it is the safe direction.
    echo "#$N: chain-$N could NOT be started — stopping lane-$N (its PR would never be merged)"
    if wt_alive "lane-$N"; then
      wt_close "lane-$N" || true
    fi
    if wt_alive "lane-$N"; then
      echo "#$N: ⚠️ lane-$N is still alive — KEEPING the issue claim (releasing it would let a peer duplicate this work); it expires with the lease"
    else
      echo "#$N: lane-$N stopped — releasing the issue claim"
      release_issue_claim_unspawned "$N"
    fi
  fi
  sleep 30   # stagger uv sync
done
echo "--- workers (launcher=$(wt_launcher)): $(wt_count lane- chain-) ---"
uptime | sed 's/.*load/load/'
