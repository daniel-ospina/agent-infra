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
# ⛔ THE WORK ROOT (#2095, review of #3846, P1). The controller exports `O` = its STATE dir and `O_WORK`
# = the harness root. `lane.sh` is the file this dispatcher HANDS TO A TMUX PANE: resolving it from `$O`
# on a state-dir instance spawns a pane that dies 127 while `wt_spawn` still returns 0, so the dispatch
# books as spawned and nothing runs — the "reports healthy and can dispatch nothing" shape.
_DM_WORK="${O_WORK:-$O}"
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
chmod +x "$_DM_WORK/lane.sh" "$_DM_WORK/merge-one.sh" "$_DM_WORK/chain-merge.sh" 2>/dev/null

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
  local n="$1" csh="$_DM_WORK/claims.sh" out rc=0
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
# every refusal path, so no path can drop a claim and keep the row — EXCEPT the chain-could-not-start
# site, which KEEPS its row on purpose (see the block at the third per-issue cleanup site).
#   ⚠️ SCOPE: a PER-ISSUE refusal (`continue`, below) used to leave this script's exit status 0 — the
#   controller then counted a batch that started nothing as dispatched. It is not latent: the same arm
#   gates on the BRANCH assertion, and a REUSED `.worktrees/tm-<N>` (checked out on another named
#   branch, the `prfixup` shape) reaches it in the field. So the batch publishes what actually reached
#   a spawn in `$O/.dispatched-ids`, and the controller recounts from that instead of from claims.
SPAWNED_IDS=""
# ⛔ AND THE IDS WHOSE **CHAIN** WAS STARTED, which is NOT `SPAWNED_IDS` (review round 3, P3).
# `SPAWNED_IDS` only grows on a SUCCESSFUL lane spawn, while the chain is attempted regardless — and a
# failed lane spawn with a LIVE chain is exactly the case this file's own comment forbids releasing
# ("the chain IS alive and waiting for that PR, so releasing would let a peer duplicate the work"). The
# disk arm below must skip these too, or a batch stop releases a claim something is still working on.
CHAIN_IDS=""
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
# ── A CHECKOUT THE DISPATCHER PROVISIONED AND NO LANE EVER RAN IN IS RESIDUE AT ONCE (#2047) ────
# `wt_provision` proves a USABLE checkout was created; the LANE is a later, separate step and it can
# fail — the launcher has no surface (no cmux answer AND no tmux), the credential contract refuses,
# the spawn dies. Until this existed, that outcome left the worktree AND the branch `-b` had just
# created sitting on disk, at 0 commits ahead and with nothing ever having run in them — which is
# exactly the artifact the intake pre-flight reads as IN FLIGHT. Measured (2026-10-18, #8090):
# `refs/heads/feat/8090-tm — 0 commit(s) ahead` made a FREE issue permanently undispatchable on
# EVERY box, with 19 of 20 lane slots free, while the batch reported a lane it never started.
# `wt_reap_if_empty` is the SAME function the lane's own EXIT trap and the no-chain path below run —
# not a second teardown — and it REFUSES on anything that could be work: commits ahead, a pushed
# branch, a dirty tree, an ignored-data tree, a live holder, a checkout on another branch, an
# unevaluable probe. So a lane that pushed before its spawn was reported failed keeps both, and a
# resumed branch keeps both; only a provably EMPTY checkout goes back. Exit status is the verdict
# (0 reaped · 1 preserved · 2 refused/failed) and every one of them is printed, never absorbed.
# ⛔ THIS HELPER TAKES BACK ONLY A CHECKOUT. WHETHER THE ISSUE CLAIM IS RELEASED IS PER-PATH, AND
# THIS HELPER DECIDES NONE OF IT (cycle-2 review, P1 — the unscoped form of this sentence read
# "nothing on these paths releases" while `these paths` in the paragraph above INCLUDES the no-chain
# path, which releases deliberately; acting on it would have deleted that release and held a dead
# lane's claim for the whole lease). The two paths in full:
#   · LANE-NEVER-STARTED — KEEPS the claim. The chain below is ABOUT TO BE started and will wait for
#     that PR; if that spawn ALSO fails, the NO-CHAIN bullet below releases once the lane is proven
#     gone. Releasing HERE would declare an issue this box is actively working free and a peer would
#     duplicate it.
#   · NO-CHAIN — RELEASES, exactly once, and only after `wt_alive` confirms the lane is gone; if it
#     cannot be stopped the claim is KEPT, because the lease expiring it is the safe direction (#2033).
# The release belongs to the CALL SITE and to the ordering the lane that wrote it measured; never to
# this helper, and never to a comment that describes both paths as one.
# ⚠️ SCOPE, so this header cannot be read as "every exit": the PER-ISSUE repo/branch assertion below
# also `continue`s after a checkout was provisioned, and deliberately does NOT take it back — that
# refusal says the checkout/branch is not what the target claims, so the owner of the thing is
# exactly what is in question; it is reported (`REFUSED … claim released`) instead of deleted.
reap_unused_worktree() { # <issue> <why> — reports; never changes the caller's status
  # ⛔ IT DERIVES ITS OWN TARGET FROM THE ISSUE IT REPORTS ON. `$WT`/`$BR` are LOOP GLOBALS set per
  # iteration, so a helper that took `$1` for its REPORT and the globals for its KILL could delete one
  # issue's checkout while reporting under another's id — and `wt_reap_if_empty`'s "only a provably
  # EMPTY checkout goes back" gate would not catch it, because an empty checkout is exactly what a
  # wrong target usually is. Both current call sites are inside the same iteration, so this is not a
  # live bug; it is a helper whose two inputs could disagree, which is one input too many.
  local WT="tm-$1" BR="feat/$1-tm"
  # ⛔ NO VERDICT IS ANNOUNCED BEFORE IT IS REACHED (#3577 review). This line used to read
  # "— taking the checkout back" and printed UNCONDITIONALLY, so on exactly the arms where a safety
  # gate fires (commits ahead, a dirty tree, a live holder) the log claimed a deletion that did not
  # happen and then contradicted itself on the next line — and the dispatch log is the only record of
  # what the box did to a lane's checkout, read by the next lane and by the human triaging a stuck
  # issue. The reason is stated; the verdict line that follows says what actually happened.
  echo "#$1: $2"
  # ⛔ AND THE VERDICT IS CLEARED AND THE VERB PROVEN PRESENT FIRST. `wt_provision` leaves its own
  # verdict in `WT_RESULT`, and `$WTL` is sourced beside this script with NO verb guard (the file only
  # has to source cleanly), so a script directory whose module predates `wt_reap_if_empty` ran
  # `command not found` (rc 127) straight into the `*)` arm — which then reported the PROVISION's
  # sentence, `created … on feat/N-tm from origin/main`, as the reason the reap FAILED. The one arm
  # that exists to surface a failed take-back named a wrong cause while the residue survived.
  # ⚠️ SCOPED (#3577 review, P2 — VERIFIED against both files): what the guard makes unreachable is a
  # STALE verdict, NOT this arm. `wt_reap_if_empty` resets `WT_RESULT` at its OWN entry — its first
  # version (e83d41a15) already did — and the guard below returns without reading `WT_RESULT` at all, so
  # nothing here can bill `wt_provision`'s `created …` sentence. The `*)` arm itself is LIVE and
  # load-bearing: the module returns 2 for its OWN refusals (the checkout contains the caller's cwd, an
  # unresolvable refs/heads/<br>, a refused `worktree remove`, a failed ref delete) and those verdicts
  # are exactly what this arm must print. The clear below is belt-and-braces, not load-bearing — it is
  # this caller's only protection if either the module's reset-at-entry or the guard is ever weakened.
  # ⛔ So: do NOT delete the `*)` arm on the strength of this note, and do not read the note as evidence
  # that a stale verdict is reachable through the shipped path.
  WT_RESULT=""
  if ! command -v wt_reap_if_empty >/dev/null 2>&1; then
    echo "#$1: ⚠️ worktree NOT reaped — the sourced ${WTL:-wt-lifecycle.sh} has no wt_reap_if_empty (it predates the take-back); fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O"
    return 0
  fi
  wt_reap_if_empty "${REPO_ABS:-$REPO}" ".worktrees/$WT" "$BR" "dispatch #$1"
  case $? in
    0) echo "#$1: $WT_RESULT" ;;
    1) echo "#$1: worktree kept — $WT_RESULT" ;;
    *) echo "#$1: ⚠️ worktree NOT reaped — $WT_RESULT (bash scripts/pi-reap-worktrees.sh --repo '$REPO' reports it)" ;;
  esac
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
# ── the worktree/branch lifecycle (#2033) ─────────────────────────────────────────────────────
# ⛔ SOURCED, NOT RE-IMPLEMENTED. Every lane worktree is created through `wt_provision`, which either
# leaves a USABLE checkout or NOTHING; the old inline `git worktree add … || skip` left a branch (and
# a half-materialised directory) behind on failure, and the collision pre-flight counts exactly those
# two surfaces as in-flight work — so one failed add made a FREE issue permanently undispatchable.
# The helper lives beside this script so it is seeded into $O by the same copy that seeds this file.
# A missing helper is FATAL (78): continuing would create worktrees whose rollback does not exist,
# which is the very leak this change removes.
WTL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wt-lifecycle.sh"
# shellcheck source=/dev/null
. "$WTL" || { echo "dispatch-merge: FATAL: $WTL is missing — refusing to create lane worktrees without their rollback (a failed add would leave a branch behind, #2033). Fix: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O" >&2; exit 78; }

# ⛔ TWO MODULES, ONE `wt_` NAMESPACE, AND NO SHARED NAME — for now. `worker-terminal.sh` and
# `wt-lifecycle.sh` both prefix their verbs `wt_`, so a future addition to either can silently SHADOW
# the other (the second `wt_foo` wins, with no error). The verb lists are pinned against each other
# by `wt-lifecycle.test.sh`'s L9 arm, which reds when the two verb sets intersect — run it before
# adding a verb to either module.
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
CIQ_MOD="$_DM_WORK/ci-queue.sh"
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
  # ── create the lane's worktree, or leave NOTHING behind (#2033) ──────────────────────────────
  # This used to be: probe `worktree list` for the directory name, then `git worktree add -b …`.
  # Three failure modes of that shape, all measured:
  #   1. an add killed mid-checkout leaves the branch (0 commits ahead) + a registered, LOCKED,
  #      half-materialised directory — the `worktree list` probe then said "already there", so the
  #      lane was spawned INTO the partial checkout, and the reaper preserved it for ever (a partial
  #      tree reads as `dirty` — deleted files — and its record reads as `locked`);
  #   2. a leftover branch with 0 commits (the pre-flight residue) made `add -b` fail with "branch
  #      exists", and the issue was skipped on every box, for ever;
  #   3. the directory-name probe tested the NAME, not the branch, so a worktree of another branch
  #      at the same path read as "already provisioned".
  # `wt_provision` answers all three: it repairs an interrupted add, deletes a 0-ahead ghost branch
  # by CAS, ATTACHES an existing branch that holds commits (resume, never delete), and rolls back to
  # a verified empty state if the add fails.
  wt_provision "$REPO" ".worktrees/$WT" "$BR" origin/main
  _wt_rc=$?
  case "$_wt_rc" in
    0) echo "#$N: worktree ok — $WT_RESULT" ;;
    4) # ── THE DISK REFUSAL (agent-infra#3395) STOPS THE BATCH, NOT JUST THIS ISSUE ─────────────
       # Every issue in this batch creates its worktree on the SAME volume, so a refusal here is a
       # fact about the BOX: continuing would run the next `git worktree add` into the same full
       # disk and produce the measured `fatal: cannot create directory …: No space left on device`,
       # once per remaining issue. The refusal names its own numbers (free/need/box) and the batch stops.
       # ⛔ AND A STOPPED BATCH RELEASES **EVERY** CLAIM IT WILL NOT ATTEMPT (review round 2, P1).
       # The controller has ALREADY taken `refs/claims/issue-<N>` for every id it handed us, and this
       # file's own rule says "Nothing will start" must also mean "nothing stays claimed" — otherwise
       # each skipped issue is refused by every peer until `CLAIM_ISSUE_TTL` (18,000 s) expires. The
       # first version released only `$N` and broke, which BOTH left the rest claimed for the lease and
       # was a regression against the old `*)` arm, where each issue released its own claim as it went.
       echo "#$N: $WT_RESULT"
       # ⛔ THE REMEDY IS SELECTED FROM THE VERDICT, NOT HARDCODED (review round 8, P2 — MEASURED).
       # THIS file was the THIRD rc-4 caller and the only one left printing a single remedy. THREE
       # arms reach rc 4 carrying `REFUSED-UNKNOWN`, and only one of them is a disk fact:
       # `wt-lifecycle.sh`'s missing-`spawn-gate.sh` arm (version skew, #2033), `spawn-gate.sh`'s
       # unreadable-`df` arm, and `wt-lifecycle.sh`'s "refused without naming its numbers" fallback.
       # Telling an operator whose box cannot answer `df` — or is half-deployed — to "reclaim space"
       # is a remedy that CANNOT ARRIVE, and because this arm stops the WHOLE batch it stays dark
       # every cycle until someone reasons past the log line. That is the #2721 wrong-cause class this
       # PR fixes in the other two callers; `wt-lifecycle.sh`'s own comment said "Both callers", and
       # that count is why this one was missed. `$WT_RESULT` already names the arm, so read it.
       # ⛔ NO MULTI-ARM `case` BLOCK HERE ON PURPOSE: dispatch-merge's rc-4 arm is extracted by
       # disk-admission.test.sh's `arm_of`, which terminates at the first line ENDING in a double
       # semicolon, so a multi-line `case` placed ahead of this arm's own terminator would truncate
       # the census's view of it. The one-line `case … esac` below ends in `esac`, so extraction still
       # reaches the terminator intact.
       _dm_unknown=0
       case "$WT_RESULT" in *REFUSED-UNKNOWN*) _dm_unknown=1 ;; esac
       if [ "$_dm_unknown" -eq 1 ]; then
         echo "dispatch-merge: stopping the batch — REFUSED-UNKNOWN: the free-space probe could NOT answer, or this box's \$O lacks spawn-gate.sh, or carries a copy that predates \`disk_admit\`, so this is NOT a full disk. Nothing was created. Check that \`df\` is on PATH and that the box's \$O carries spawn-gate.sh WITH \`disk_admit\` defined in it (a half-deployed or skewed box fails closed here, #2033) — waiting will NOT clear it, so re-dispatch once the probe answers."
       else
         echo "dispatch-merge: stopping the batch — the disk refusal is a fact about this box, not this issue; reclaim space ('cloud-cell-supervisor.sh prune') and re-dispatch, or let a peer box take the remaining issues"
       fi
       # ⛔ NEVER RELEASE A CLAIM FOR AN ISSUE THIS BATCH ALREADY **SPAWNED A LANE OR A CHAIN** FOR
       # (review rounds 2 and 3). `SPAWNED_IDS` holds the lanes that ARE running; `CHAIN_IDS` holds the
       # ids whose chain was started even when the lane spawn failed — releasing either lets a peer
       # duplicate live work (the rule this file states at the chain-start failure path). Only the
       # remainder — this issue and everything after it that nothing was started for — is released.
       _dm_unspawned=""
       _dm_seen=0
       # ⛔ ITERATE `"$@"` — NOT `"$N" "$@"` (review round 5, P2 — MEASURED). `$N` is already the
       # element being processed, so putting it FIRST set `_dm_seen=1` on iteration 1 and made the
       # at-or-after guard below unreachable: a driver with batch `10 11 12` refusing at 11 released
       # `10 11 12` instead of `11 12`, re-releasing an id an earlier per-issue arm had already
       # released (`claims.sh` then returns 1 and the log gains a false alarm about work that was never
       # started). The flag is set BEFORE the spawn/duplicate skips, so reaching this issue opens the
       # window even when this issue itself is then skipped.
       for _dm in "$@"; do
         case "${_dm:-}" in ''|*[!0-9]*) continue ;; esac
         [ "$_dm" = "$N" ] && _dm_seen=1
         [ "$_dm_seen" -eq 1 ] || continue
         case " $SPAWNED_IDS $CHAIN_IDS " in *" $_dm "*) continue ;; esac
         case " $_dm_unspawned " in *" $_dm "*) continue ;; esac
         _dm_unspawned="$_dm_unspawned $_dm"
         release_issue_claim_unspawned "$_dm"
       done
       drop_dispatched_rows $_dm_unspawned 2>/dev/null || true
       break ;;
    *) echo "#$N: $WT_RESULT — skipping (no lane, no chain)"; release_issue_claim_unspawned "$N"; drop_dispatched_rows "$N"; continue ;;
  esac
  WT_ABS="$REPO_ABS/.worktrees/$WT"
  # ── THE POST-BUILD ASSERTION (agent-infra#2724/#2694) ───────────────────────────────────────
  # The worktree EXISTS. Read its own origin and checkout identity; if they are not the target, the
  # lane would do its whole run in the wrong repository and every downstream gate (review, rail,
  # attestation) would certify it perfectly. Refuse, release the claim, and record the line.
  # ⛔ `wt_provision` PROVING the checkout is usable is NOT the same proof: it checks the branch
  # identity, not the REPOSITORY the checkout belongs to. Both arms are required.
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
  if wt_spawn "lane-$N" "$WT_ABS" "bash '$_DM_WORK/lane.sh' --repo-dir '$REPO_ABS' --repo '$OR' $N '$BR'"; then
    SPAWNED_IDS="$SPAWNED_IDS $N"
    echo "#$N: lane-$N (implement+PR, launcher=$_lan)$_hd"
  else
    echo "#$N: lane-$N NOT spawned (launcher=$_lan)$_hd"
    # ⛔ THE WORKTREE MUST NOT OUTLIVE A LANE THAT NEVER STARTED (#2047). Everything above this
    # line succeeded — the checkout was provisioned and proven usable — so on this path the
    # dispatcher owns an artifact nobody will ever use, and leaving it is the #8090 residue: 0
    # commits ahead, so the pre-flight reads the issue as in flight on EVERY box while its slots are
    # free. The CLAIM stays held: the chain below is ABOUT TO BE started and will wait for that PR,
    # and only the NO-CHAIN exit below (its spawn failing, then the lane proven gone) releases it —
    # nothing here does. So this releases nothing: it takes back a checkout, and nothing else.
    # ⛔ AND IT ASKS THE LAUNCHER FIRST, exactly as the no-chain path below does. A spawn that
    # reported failure while a terminal DID start is the one shape where reaping could pull a live
    # lane's checkout out from under it (#2499/#2787) — so a lane that answers alive keeps its
    # worktree, whatever the spawn's status said.
    if wt_alive "lane-$N"; then
      echo "#$N: lane-$N reported NOT spawned but is alive — keeping its worktree (no reap of a live lane, #2047)"
    else
      reap_unused_worktree "$N" "the lane never started, so nothing ran in this checkout"
    fi
  fi
  # ⛔ IF THE CHAIN CANNOT BE STARTED, NO TRAP WILL EVER RELEASE THE CLAIM (2026-10-16 review): this
  # was the second no-chain path, and it was covered by nothing. A stale `chain-$N` session name, a
  # dead tmux server or tmux missing all land here, and the issue then stays claimed on every box for
  # the whole lease. (A failed LANE spawn is not released by the lane-spawn arm above; the NO-CHAIN arm
  # below releases it once the lane is proven gone. If the chain DOES start, its wait is bounded —
  # 90 minutes, then chain-merge.sh's own trap releases it. ⚠️ This sentence read "the chain IS alive
  # and waiting for that PR", which is false on the doubly-failed dispatch — no chain exists to trap —
  # and contradicted the corrected header above. Cycle-4 review, P1.)
  # ⛔ HAND THE CHAIN ITS GENERATION (adversarial review). The record here is the one THIS dispatch
  # wrote — the one fact a chain cannot safely discover for itself later (see chain-merge.sh's comment).
  # ⚠️ The window is NOT microseconds for every member of a batch: the loop sleeps between issues, so
  # the k-th issue's record is read ~30·(k-1)s after it was written. The read is still correct because
  # the record can only be OVERWRITTEN by a re-acquire, and a re-acquire needs the current claim to be
  # RELEASED or to reach its CLAIM_ISSUE_TTL (4h) first — not because the gap is small. Do not shorten
  # the TTL without revisiting this line.
  chain_gen="$( . "$_DM_WORK/claims.sh" 2>/dev/null; claim_issue_record_commit "$O" "$N" 2>/dev/null )" || true
  # ⛔ `${REPO_ABS:-$REPO}`, NOT `$REPO_ABS` (#2762 review, 4th cycle, P1): refresh-scout.test.sh
  # EXTRACTS this branch and drives it under `set -u` without REPO_ABS, and the bare expansion aborted
  # the fragment — reding a registered shard and losing the only witness to the "stop the lane BEFORE
  # releasing the claim" ordering. Same rule as `${_lan-}` below: every variable this branch reads
  # must be safe when unset.
  if wt_spawn "chain-$N" "${REPO_ABS:-$REPO}" "CHAIN_CLAIM_COMMIT='$chain_gen' bash '$O/chain-merge.sh' '${REPO_ABS:-$REPO}' '$OR' $N '$BR'"; then
    CHAIN_IDS="$CHAIN_IDS $N"   # the disk arm must not release a claim a live chain holds (round 3, P3)
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
      # ⛔ THIS IS THE THIRD PER-ISSUE CLEANUP SITE IN THE LOOP, AND IT DOES **NOT** DROP THE ROW — a
      # KNOWN, DELIBERATE gap (#3511 review), not an oversight. The other two arms that release the
      # claim (the `wt_provision` refusal and the post-build repo/branch assertion) also call
      # `drop_dispatched_rows`, so "claim released ⇒ row dropped" is the invariant everywhere BUT here.
      # The naive fix was written and reverted: dropping the row lets the NEXT cycle re-dispatch this
      # issue, and `wt_provision`'s reuse arm had no holder probe, so the new lane could be spawned
      # into a checkout an ORPHANED GRANDCHILD is still writing in (`wt_close` signals the pane pid
      # only) — two writers on one branch and one checkout. The probe that would close that
      # (`wt_live_holders` in the reuse arm) was ALSO written and reverted: its argv witness matches
      # any process whose command line names the path, and a box's tmux SERVER inherits the argv of the
      # client that created it (`new-session … cd '<wt>' && …`, reparented to ppid 1, argv never
      # changes), so the probe refuses that checkout for ever and the issue becomes undispatchable on
      # that box — a permanent false block, which is worse than the skip it fixes.
      # So the row is kept here ON PURPOSE until the probe can tell a daemon that merely MENTIONS the
      # path from a process WORKING in it (corroborate the argv match against the pid's own cwd), and
      # until that probe's false-positive class is witnessed by a test. Recorded on #3511.
      # The cost meanwhile is a skip whose END depends on which class the row is in, and the two are not
      # the same: for an issue inside the 500-newest open window the reaper's dispatched re-check drops
      # the row on its next pass — but ONLY when no PR in that window's listing names it, because that
      # loop keeps an entry whose branch a listed PR names (`has_pr` over `.pr_brs`), and a stopped lane
      # may already have pushed and opened one; a WINDOW-BLIND entry is released ONLY when the issue
      # CLOSES (that file: "SO ONLY A CLOSED ISSUE IS RELEASED" — it may not requeue on an OPEN issue
      # whose PR already merged), and `orch-loop` skips on any row still present, so an OPEN window-blind
      # issue stays undispatchable on this box until it closes. The reaper counts and NAMES that class on
      # the operator line every pass (measured: 169 of 203 rows outside the window), so it is a stated
      # deficit rather than an invisible one.
      # ── and take its EMPTY worktree back (#2033) ─────────────────────────────────────────────
      # The lane is confirmed gone and no chain will ever look at this checkout, so an empty one is
      # residue by definition — and residue is what makes the issue undispatchable everywhere. Same
      # take-back as the lane-never-started path above; its gates (commits ahead, a pushed branch, a
      # dirty tree, a live holder) are documented at the helper.
      reap_unused_worktree "$N" "the chain could not start, so no chain will ever look at it"
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
