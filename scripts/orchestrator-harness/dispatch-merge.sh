#!/usr/bin/env bash
# dispatch-merge.sh <repo-path> <owner/repo> <issue> [<issue> ...]
# For each issue: worktree -> lane (implement+PR) -> chain-merge (review+record+merge).
#
# ⛔ BOTH HALVES OF THE TARGET ARE MANDATORY AND ARE ASSERTED (agent-infra#2724/#2694). The checkout
# ($1) and the repo slug ($2) are separate inputs that can disagree — the measured wrong-repo lane
# was built from `/tmp/cell-t3` (tortoise) for an `agent-infra` brief. No target = REFUSED; a
# worktree whose own `origin` is not the target = REFUSED before any lane or chain is spawned, with
# both slugs named. Exit 72 is the repo-identity refusal, distinct from the capacity codes.
set -u
REPO="${1:-}"; OR="${2:-}"; shift 2 2>/dev/null || true
SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
# ⛔ PUBLISHED UP FRONT, OVERWRITTEN AT THE END (#2762 review, 4th cycle, P2). The controller recounts
# from this file, and it used to exist only on the paths that reached the loop's tail — so the two
# earlier "nothing started" exits (worker-terminal FATAL 78, a failed `cd`) left the batch counted as
# dispatched. An empty file here says "this call spawned nothing" from the first instant; the final
# write replaces it with the ids that did.
: > "$O/.dispatched-ids" 2>/dev/null || true
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
# until the lease ran out (CLAIM_ISSUE_TTL, 4h since #2029) — and the reaper would meanwhile return the issue to
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
# ── THE OTHER HALF OF "NOTHING STARTED": DROP THE BLACKLIST ROWS (#2762 review, P1) ─────────────
# The controller appends each id to `$O/dispatched.txt` and `.batch` BEFORE calling this script, so a
# refusal that only releases the claim leaves a row that makes this box skip a FREE issue until the
# reaper prunes it. The CI-queue deferral already did this correctly (and exits 3 so the cycle record
# says `dispatched=0`); the BATCH-level repo-target refusals must do the same, and do — every one of
# them exits 72, which orch-loop.sh's `_dmrc` arm turns into `K=0` for the batch. One helper, used by
# every refusal path, so no path can drop a claim and keep the row.
#   ⚠️ SCOPE: a PER-ISSUE refusal (`continue`, below) used to leave this script's exit status 0 — the
#   controller then counted a batch that started nothing as dispatched. It is not latent: the same arm
#   gates on the BRANCH assertion, and a REUSED `.worktrees/tm-<N>` (checked out on another named
#   branch, the `prfixup` shape) reaches it in the field. So the batch publishes what actually reached
#   a spawn in `$O/.dispatched-ids`, and the controller recounts from that instead of from claims.
SPAWNED_IDS=""
drop_dispatched_rows() {
  local ids="" n tmp
  for n in "$@"; do case "${n:-}" in ''|*[!0-9]*) continue ;; esac; ids="$ids $n"; done
  [ -n "$ids" ] || return 0
  [ -f "$O/dispatched.txt" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/dispatchmerge.XXXXXX" 2>/dev/null)" || return 0
  if awk -v ids="$ids" 'BEGIN{n=split(ids,a," "); for(i=1;i<=n;i++) if(a[i]!="") drop[a[i]]=1} !($0 in drop)' \
       "$O/dispatched.txt" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$O/dispatched.txt" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}
# ── NO TARGET = REFUSED, AND THE CLAIMS ARE RELEASED (agent-infra#2724/#2694) ────────────────────
# This runs AFTER `release_issue_claim_unspawned` is defined because the controller has ALREADY taken
# `refs/claims/issue-<N>` for every id it handed us. "Nothing will start" must therefore also mean
# "nothing stays claimed" — otherwise the issue is refused by every peer until the 3h lease expires.
# The target is a parameter (never a default or a guess, #1974): an absent one is a named refusal.
if [ -z "$OR" ]; then
  echo "dispatch-merge: REFUSED (no-target) — no owner/name repo was named. The target is a parameter, never a default or a guess (#1974/#2724); pass <repo-path> <owner/repo> <issue...>."
  for N in "$@"; do case "${N:-}" in ''|*[!0-9]*) continue ;; esac; release_issue_claim_unspawned "$N"; done
  drop_dispatched_rows "$@"
  exit 72
fi
if [ -z "$REPO" ]; then
  echo "dispatch-merge: REFUSED (no-repo-dir) — no checkout path was named; refusing to guess which checkout the lanes belong to (#1974/#2724)."
  for N in "$@"; do case "${N:-}" in ''|*[!0-9]*) continue ;; esac; release_issue_claim_unspawned "$N"; done
  drop_dispatched_rows "$@"
  exit 72
fi
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THIS IS NOW A `gh` CONSUMER, SO IT RE-ASSERTS THE SHIMS (#2333 review P2). The `export PATH`
# above puts the real `/opt/homebrew/bin/gh` FIRST, ahead of the controller's exported shim dirs, and
# the CI-queue read below is this script's FIRST `gh` call — so without this it would run outside the
# cell's rate-limit serialiser and the Mac REST adapter, while `README` §7.2h says every read goes
# through them. `fix-one.sh` carries the identical pair for the same reason; adapter last so
# `$O/gh-rest` (which itself calls the same helper) wins where it exists. `-d`-guarded, so a box
# shipping neither is unchanged.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
# ── the worker launcher (worker-terminal.sh) ─────────────────────────────────────────────────────
# Lanes and chains are WORKERS, so they are started by the same module orch-loop.sh uses — a durable
# terminal where the cmux daemon answers, tmux (with an explicit HOME + keys.env contract) where it does
# not. ⛔ The `~21 log lines` death that agent-infra#2210 first attributed to tmux is an ENVIRONMENT
# failure (agent-infra#2210, reopened 2026-10-22): `gh`'s credential is HOME-bound, and the pre-fix tmux
# arm passed no HOME, so a lane stopped at its first `gh` call. Leaving this path on `none` on a Linux
# cell is what made the controller refuse every spawn, every cycle.
for _wt_cand in "$O/worker-terminal.sh" "$(dirname "${BASH_SOURCE[0]:-$0}")/worker-terminal.sh"; do
  [ -f "$_wt_cand" ] && { WT_MOD="$_wt_cand"; break; }
done
[ -n "${WT_MOD:-}" ] && . "$WT_MOD"
# ⛔ The guard covers EVERY verb this script calls — `wt_launcher` (the startup/refusal line),
# `wt_launcher_why` (which `wt_spawn` now calls to explain a `none` refusal) and `wt_count` (the final
# worker count) included, not only the three that look load-bearing: a module that satisfies a narrower
# guard still leaves the controller printing `launcher=` (with an EMPTY reason, the #2366 defect) and
# a false `0`. ⚠️ The PARTIAL copy is the shape that bites — a wholly old module never references
# `wt_launcher_why`, but a half-updated one does, and its refusal then ends `— why: `.
for _wt_v in wt_spawn wt_alive wt_close wt_launcher wt_launcher_why wt_count; do
  command -v "$_wt_v" >/dev/null 2>&1 || { echo "dispatch-merge: FATAL worker-terminal.sh is missing or stale at ${WT_MOD:-$O} (no $_wt_v; needs wt_spawn/wt_alive/wt_close/wt_launcher/wt_launcher_why/wt_count) — refusing to dispatch lanes that cannot be started or stopped; fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O"; exit 78; }
done
cd "$REPO" || { echo "dispatch-merge: cannot cd into $REPO — releasing every claim in this batch (no lane and no chain can start here)"
  for N in "$@"; do release_issue_claim_unspawned "$N"; done
  drop_dispatched_rows "$@"
  exit 1; }
# Physical path, so every assertion and spawn below names the checkout even when the caller passed a
# relative one (after `cd`, `$REPO` would otherwise resolve from INSIDE itself).
REPO_ABS="$(pwd -P)"

# ── REQUIRED MODULE, AND ITS FAILURE UNDOES WHAT THE CONTROLLER DID (#2762 review, 3rd cycle, P2) ──
# Without repo-target.sh the worktree identity can never be asserted, so this is FATAL (78). The guard
# lives HERE — below the claim/row helpers — because a half-deployed `$O` must not strand the batch it
# was called for: the controller has already CLAIMED every issue and appended every row, so exiting 78
# at the top of the file left those claims running their 3 h lease and the batch counted as
# dispatched. Release them, drop the rows, and publish an EMPTY `.dispatched-ids` so the controller's
# recount records zero instead of a phantom dispatch.
_repo_target_fatal() { # <why> <issue...>
  local why="$1" n; shift
  echo "dispatch-merge: FATAL: $why"
  for n in "$@"; do
    case "${n:-}" in ''|*[!0-9]*) continue ;; esac
    release_issue_claim_unspawned "$n"
  done
  drop_dispatched_rows "$@"
  : > "$O/.dispatched-ids" 2>/dev/null || true
  exit 78
}
. "$SELF/repo-target.sh" || _repo_target_fatal "$SELF/repo-target.sh missing (or its repo-slug.sh parser is) — refusing to dispatch worktrees whose repo cannot be asserted" "$@"
command -v repo_target_assert >/dev/null 2>&1 && command -v repo_target_branch_assert >/dev/null 2>&1 \
  || _repo_target_fatal "$SELF/repo-target.sh is stale (no repo_target_assert/repo_target_branch_assert) — refusing to dispatch worktrees whose repo cannot be asserted" "$@"

# ── THE TARGET ASSERTION BEFORE ANY WORKSTREE IS BUILT (agent-infra#2724/#2694) ─────────────────
# A pre-build check proves what was asked for. The POST-BUILD check below (on each worktree) proves
# what was got; both are needed, and this one fails fast enough to release the batch's claims.
TARGET_LINE="$(repo_target_assert "dispatch" "$REPO_ABS" "$OR" "")"; TARGET_RC=$?
echo "$TARGET_LINE"
if [ "$TARGET_RC" -ne 0 ]; then
  echo "dispatch-merge: REFUSED — the checkout $REPO_ABS is not $OR; no lane and no chain will start (exit $TARGET_RC)"
  for N in "$@"; do release_issue_claim_unspawned "$N"; done
  drop_dispatched_rows "$@"
  exit "$TARGET_RC"
fi
git fetch origin main --quiet 2>/dev/null

# ── CI BACK-PRESSURE, READ ONCE FOR THE WHOLE BATCH ─────────────────────────────────────────────
# This is the tool that STAMPEDES: it takes every issue it is handed and starts a lane for each, and
# every lane ends in a PR that needs a full CI pass. Measured 2026-10-22 13:40 the queue was
# queued=92/in_progress=6 on 5 runners (tortoise) and queued=97/in_progress=7 (agent-infra) — a batch
# dispatched into that finishes nothing and makes the backlog worse. The read is the SAME module the
# controller reads (`ci-queue.sh`), so the two NEW-PR surfaces cannot disagree about the queue.
# ⛔ NOT SHARED WITH `fix-one.sh` ANY MORE (#2927): a fixer is REPAIR, so it stopped reading the module
# altogether rather than reading it and deferring. ⛔ BUT A DEFERRAL HERE IS NOT FREE (#2296 review cycle 4, P1): the controller takes the
# claim (`claim_issue_acquire "" "$ISS"` in orch-loop.sh's dispatch block) and appends N to `.batch`
# AND `dispatched.txt` BEFORE it hands the batch to this script, so "deferring claims nothing" was
# FALSE. Without the release below, every issue in a deferred batch would sit on a 3 h cross-box
# lease held by a box that started no work — refused by every peer — and be skipped by this box
# until the row was reaped. The release and the row drop are what make "the issues stay in the pool,
# re-decided on the next invocation" true. ⛔ SYMBOLS, NOT LINE NUMBERS (#2333 review, P2): this note
# used to cite a line number in that block, and it drifted on the very next edit to orch-loop.sh.
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
  # ⛔ THE GUARD NAMES EVERY FUNCTION THE CALLS ACTUALLY REACH, TRANSITIVELY (#2333 cycle 7, P2).
  # `ciq_ci_allowed` calls `ciq_verdict`, and `ciq_eval` calls `ciq_is_count`; with `ciq_verdict`
  # absent the predicate ran `ciq_verdict … >/dev/null 2>&1` -> rc 127 -> `case $? in 1) return 0
  # ;; *) return 1` -> 1 = DEFER, SILENTLY, ON EVERY CALL, while this guard reported the module
  # COMPLETE and printed no INCOMPLETE line — every fixer, rerun and batch stopped for ever by a
  # half-stale copy. A guard that under-specifies its module is the same permanent-stop class as an
  # unguarded call, reached through the guard instead.
  if declare -f ciq_read ciq_eval ciq_defer_note_here ciq_ci_allowed ciq_verdict ciq_is_count ciq_ceiling ciq_defer_line ciq_horizon_min ciq_job_p90_min >/dev/null 2>&1; then
    if ! ciq_ci_allowed "$OR"; then
      echo "dispatch-merge: nothing dispatched this run"
      ciq_defer_note_here "the whole batch ($* — $# issue(s); each lane ends in a PR needing a full CI pass)"
      # ⛔ UNDO WHAT THE CONTROLLER ALREADY DID (#2296 cycle 4, P1). Each issue here is CLAIMED
      # (`refs/claims/issue-<N>`, 3 h lease) and recorded in `dispatched.txt` before this script was
      # called. No lane and no chain will start, so nothing would ever reach the release in
      # `chain-merge.sh`'s EXIT trap — the same failure `release_issue_claim_unspawned` exists for on
      # the `cd` failure above. Release the claims AND drop the rows: a row with no dispatch makes
      # this box skip a FREE issue until the reaper prunes it, which is a turn consumed for work that
      # never started.
      for N in "$@"; do
        case "${N:-}" in ''|*[!0-9]*) continue ;; esac
        release_issue_claim_unspawned "$N"
      done
      drop_dispatched_rows "$@"
      echo "dispatch-merge: re-run when the queue has drained; a lane started now would queue behind it and its PR would invalidate any head-bound review record it produces"
      # ⛔ EXIT 3, NOT 0 (#2296 cycle 6, P2): the controller counted each of these issues as
      # DISPATCHED (`K`) before calling this script, so a plain `exit 0` left the funnel printing
      # `… -> N dispatched` and the cycle record `dispatched=N ids=… nothing=none` on the one
      # cycle the gate deferred everything. 3 is the code the controller reads to record
      # `dispatched=0` with a named reason — the same row says the truth as the claims it just
      # released.
      exit 3
    fi
  else
    # Keep the name list byte-identical to the `declare -f` guard above (#2333 review cycle 12, P2):
    # a stale `$O` copy is the case this message reports, so the list is LITERAL — it cannot be
    # rendered from a variable the module would define.
    echo "dispatch-merge: WARNING — $CIQ_MOD is present but INCOMPLETE (needs ciq_read/ciq_eval/ciq_defer_note_here/ciq_ci_allowed/ciq_verdict/ciq_is_count/ciq_ceiling/ciq_defer_line/ciq_horizon_min/ciq_job_p90_min); the CI-queue gate is INERT for this batch" >&2
  fi
else
  # ⛔ AN ABSENT MODULE IS ANNOUNCED TOO (#2333 cycle 3, P2). This is the stale-`$O` shape that
  # `install.sh` and `check-single-source.sh` now detect — and a silent skip here means the batch
  # stampedes exactly as before while every OTHER surface (the controller, `fix-one.sh`) says
  # UNMEASURED out loud. Silence in one of three callers is how a gate rots into a decoration.
  echo "dispatch-merge: WARNING — no ci-queue.sh at $CIQ_MOD; the CI-queue gate is UNMEASURED for this batch (the batch proceeds, and the controller's own arm already decided this cycle)" >&2
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
  WT_ABS="$REPO_ABS/.worktrees/$WT"
  # ── THE POST-BUILD ASSERTION (agent-infra#2724/#2694) ───────────────────────────────────────
  # The worktree EXISTS. Read its own origin and checkout identity; if they are not the target, the
  # lane would do its whole run in the wrong repository and every downstream gate (review, rail,
  # attestation) would certify it perfectly. Refuse, release the claim, and record the line.
  LANE_REPO_LINE="$(repo_target_assert "lane #$N" "$WT_ABS" "$OR" "$REPO_ABS")"; LANE_REPO_RC=$?
  LANE_BRANCH_LINE="$(repo_target_branch_assert "lane #$N" "$WT_ABS" "$BR" "$OR")"; LANE_BRANCH_RC=$?
  printf '%s\n%s\n' "$LANE_REPO_LINE" "$LANE_BRANCH_LINE" | tee -a "$O/logs/lane-$N.log"
  if [ "$LANE_REPO_RC" -ne 0 ] || [ "$LANE_BRANCH_RC" -ne 0 ]; then
    # ⛔ NAME THE ASSERTION THAT REFUSED (#2762 review, 2nd cycle, P1): the reason token lives on the
    # `[repo-target]` line above, and the human line claimed "the worktree is not $OR" even when the
    # repo half PASSED and only the branch was wrong (a reused worktree on another named branch).
    _refr="repo"
    [ "$LANE_REPO_RC" -eq 0 ] && _refr="branch"
    echo "#$N: REFUSED ($_refr assertion) — this lane's worktree/branch is not $OR; no lane, no chain, claim released (#2724/#2694)"
    release_issue_claim_unspawned "$N"
    drop_dispatched_rows "$N"
    continue
  fi
  # #2216 brought a second disclosure into this line: WHICH harness the spawn was computed from, so a
  # lane that behaves unlike a peer is traceable to a stale checkout. Both disclosures belong on the
  # same line — the launcher names HOW it was spawned (durable terminal vs tmux), the token names
  # WHAT it was spawned from.
  # ⛔ THE DISCLOSURE IS NOT CONDITIONAL ON THE SPAWN SUCCEEDING (agent-infra#2215's C2 arm drives a
  # box where the launcher REFUSES — no surface at all (no cmux answer AND no tmux), or a spawn the
  # credential contract refuses — and a refusal that says nothing
  # about the harness is the case where the operator most needs it: "why did this box not start a
  # lane?" and "which tree is it running?" are one question. So BOTH outcomes carry the token, and
  # the success line still only appears when the lane really started.
  # An EMPTY token (the box is current) appends nothing at all — `${T:+ …}`, never `${T:-…}`.
  _lan="$(wt_launcher)"
  _hd="${HARNESS_TOKEN:+ [harness=$HARNESS_TOKEN]}"
  if wt_spawn "lane-$N" "$WT_ABS" "bash '$O/lane.sh' --repo-dir '$REPO_ABS' --repo '$OR' $N '$BR'"; then
    SPAWNED_IDS="$SPAWNED_IDS $N"
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
  # RELEASED or to reach its CLAIM_ISSUE_TTL (4h) first — not because the gap is small. Do not shorten
  # the TTL without revisiting this line.
  chain_gen="$( . "$O/claims.sh" 2>/dev/null; claim_issue_record_commit "$O" "$N" 2>/dev/null )" || true
  # ⛔ `${REPO_ABS:-$REPO}`, NOT `$REPO_ABS` (#2762 review, 4th cycle, P1): refresh-scout.test.sh
  # EXTRACTS this branch and drives it under `set -u` without REPO_ABS, and the bare expansion aborted
  # the fragment — reding a registered shard and losing the only witness to the "stop the lane BEFORE
  # releasing the claim" ordering. Same rule as `${_lan-}` below: every variable this branch reads
  # must be safe when unset.
  if wt_spawn "chain-$N" "${REPO_ABS:-$REPO}" "CHAIN_CLAIM_COMMIT='$chain_gen' bash '$O/chain-merge.sh' '${REPO_ABS:-$REPO}' '$OR' $N '$BR'"; then
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
# ⛔ WHAT ACTUALLY REACHED A SPAWN, IN ONE FILE THE CONTROLLER READS (#2762 review, 2nd cycle, P1).
# `K` in orch-loop.sh is incremented per CLAIM, so a batch whose every lane was refused per-issue was
# still recorded as `dispatched=N … nothing=none` — a permanent false PASS (the pair does not clear by
# waiting) and an unattended no-progress loop. Written on EVERY run, including zero, and the controller
# recounts from it; the batch-level refusal exits 72 above, so it writes nothing and the rc arm governs.
printf '%s\n' $SPAWNED_IDS | sed '/^$/d' > "$O/.dispatched-ids" 2>/dev/null || true
echo "--- workers (launcher=$(wt_launcher)): $(wt_count lane- chain-) ---"
uptime | sed 's/.*load/load/'
