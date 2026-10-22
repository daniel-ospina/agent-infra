#!/usr/bin/env bash
# dispatch-merge.sh <repo-path> <owner/repo> <issue> [<issue> ...]
# For each issue: worktree -> lane (implement+PR) -> chain-merge (review+record+merge).
set -u
REPO="$1"; OR="$2"; shift 2
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
# ⛔ THE SPAWN LINE MUST SAY SO WHEN THE BOX IS STALE (agent-infra#2215). `orch-loop.sh` exports this
# from its once-per-cycle refresh: EMPTY when the controller's harness IS origin/main's tip, else
# `<relation>:<sha12>` (behind / dirty / ahead / unknown …) or `refresh-off`.
# ⛔ `-` AND NOT `:-`: `${HARNESS_TOKEN:-unknown}` collapses an EMPTY token into `unknown`, and empty is a
# real, documented answer (the box is current) while `unknown` is cannot-verify. With the colon, every
# healthy box stamped `[harness=unknown]` on every spawn line — the token a reader most needs to
# distinguish a stale box would be present always, and therefore read never. Only UNSET is unknown.
# The marker is attached conditionally, exactly like `disp()` in orch-loop.sh, so the two disclosure
# paths cannot disagree about what an empty token means.
HARNESS_TOKEN="${HARNESS_TOKEN-unknown}"
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
    echo "#$n: ⚠️ $csh predates the issue-claim release (no claim_issue_release_record) — the claim is NOT released; fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o ~/orchestrator"
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
  command -v "$_wt_v" >/dev/null 2>&1 || { echo "dispatch-merge: FATAL worker-terminal.sh is missing or stale at ${WT_MOD:-$O} (no $_wt_v; needs wt_spawn/wt_alive/wt_close/wt_launcher/wt_count) — refusing to dispatch lanes that cannot be started or stopped; fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O"; exit 78; }
done
cd "$REPO" || { echo "dispatch-merge: cannot cd into $REPO — releasing every claim in this batch (no lane and no chain can start here)"
  for N in "$@"; do release_issue_claim_unspawned "$N"; done
  exit 1; }
git fetch origin main --quiet 2>/dev/null

# ── CI BACK-PRESSURE, READ ONCE FOR THE WHOLE BATCH ─────────────────────────────────────────────
# This is the tool that STAMPEDES: it takes every issue it is handed and starts a lane for each, and
# every lane ends in a PR that needs a full CI pass. Measured 2026-10-22 13:40 the queue was
# queued=92/in_progress=6 on 5 runners (tortoise) and queued=97/in_progress=7 (agent-infra) — a batch
# dispatched into that finishes nothing and makes the backlog worse. The read is the SAME module the
# controller and fix-one.sh read (`ci-queue.sh`), so the three surfaces cannot disagree about the
# queue. Deferring here claims nothing and starts nothing: the issues stay in the pool, and the very
# next invocation re-reads the queue and proceeds once it has drained (no record of "we deferred").
CIQ_MOD="$O/ci-queue.sh"
[ -f "$CIQ_MOD" ] || CIQ_MOD="$(dirname "${BASH_SOURCE[0]:-$0}")/ci-queue.sh"
if [ -f "$CIQ_MOD" ]; then
  # shellcheck source=/dev/null
  . "$CIQ_MOD"
  # ⛔ AN INCOMPLETE MODULE IS SAID OUT LOUD, NOT SWALLOWED (#2333 review cycle 2, P2). With the
  # interface guard missing one of the functions it then calls, `! ciq_ci_allowed` against an
  # UNSOURCED function is `! 127` = TRUE — this dispatcher would print "nothing dispatched this run"
  # and exit 0 for EVER, with nothing naming the broken gate (the same polarity trap `orch-loop.sh`
  # names). So the absence is announced and the batch proceeds — the controller's own arm already
  # made the fail-closed decision about this cycle.
  if declare -f ciq_read ciq_eval ciq_defer_note_here ciq_ci_allowed >/dev/null 2>&1; then
    if ! ciq_ci_allowed "$OR"; then
      echo "dispatch-merge: nothing dispatched this run"
      ciq_defer_note_here "the whole batch ($* — $# issue(s); each lane ends in a PR needing a full CI pass)"
      echo "dispatch-merge: re-run when the queue has drained; a lane started now would queue behind it and its PR would invalidate any head-bound review record it produces"
      exit 0
    fi
  else
    echo "dispatch-merge: WARNING — $CIQ_MOD is present but INCOMPLETE (needs ciq_read/ciq_eval/ciq_defer_note_here/ciq_ci_allowed); the CI-queue gate is INERT for this batch" >&2
  fi
fi

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
  # #2216 brought a second disclosure into this line: WHICH harness the spawn was computed from, so a
  # lane that behaves unlike a peer is traceable to a stale checkout. Both disclosures belong on the
  # same line — the launcher names HOW it was spawned (durable terminal vs tmux), the token names
  # WHAT it was spawned from.
  # ⛔ THE DISCLOSURE IS NOT CONDITIONAL ON THE SPAWN SUCCEEDING (agent-infra#2215's C2 arm drives a
  # box where the launcher REFUSES — Linux with no cmux surface — and a refusal that says nothing
  # about the harness is the case where the operator most needs it: "why did this box not start a
  # lane?" and "which tree is it running?" are one question. So BOTH outcomes carry the token, and
  # the success line still only appears when the lane really started.
  # An EMPTY token (the box is current) appends nothing at all — `${T:+ …}`, never `${T:-…}`.
  _lan="$(wt_launcher)"
  _hd="${HARNESS_TOKEN:+ [harness=$HARNESS_TOKEN]}"
  if wt_spawn "lane-$N" "$REPO/.worktrees/$WT" "bash '$O/lane.sh' $N '$BR' '$OR'"; then
    echo "#$N: lane-$N (implement+PR, launcher=$_lan)$_hd"
  else
    echo "#$N: lane-$N NOT spawned (launcher=$_lan)$_hd"
  fi
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
    echo "        chain-$N (review->record->merge)${HARNESS_TOKEN:+ [harness=$HARNESS_TOKEN]}"
  else
    # The same disclosure on the refusal path (see the lane spawn above): a chain that never started
    # is the other half of "what did this box do, and from which tree".
    # ⛔ `${_lan-}` AND NOT `$_lan`: this branch is EXTRACTED AND DRIVEN STANDALONE by
    # refresh-scout.test.sh (which anchors on the `if wt_spawn "chain-` line and runs the fragment
    # with stubbed launcher verbs), so every variable it reads must be safe when unset — the suite
    # runs under `set -u` and a bare `$_lan` aborted the fragment into a false "released 0 times".
    echo "        chain-$N NOT spawned (launcher=${_lan-})${HARNESS_TOKEN:+ [harness=$HARNESS_TOKEN]}"
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
