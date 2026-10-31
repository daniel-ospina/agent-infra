#!/usr/bin/env bash
# fix-one.sh <repo-path> <owner/repo> <pr> <branch>
# fix-one.sh --argv <file>            (4 lines: repo, owner/repo, pr, branch)
# Runs a fixer on the PR's worktree to address the reviewer's findings, pushes, then re-runs the merge chain.
set -u
if [ "${1:-}" = "--argv" ]; then
  ARGV="${2:-}"
  [ -f "$ARGV" ] || { echo "[fix] missing argv file: $ARGV" >&2; exit 1; }
  { read -r REPO; read -r OR; read -r PR; read -r BR; } < "$ARGV"
  rm -f "$ARGV"
  # Only a CONTROLLER dispatch books an attempt in fixcount-<PR>. See the refund in the load-refusal
  # path below: a manual run must not decrement a counter it never incremented.
  CTRL=1
else
  REPO="$1"; OR="$2"; PR="$3"; BR="$4"; CTRL=0
fi
case "${PR:-}" in ''|*[!0-9]*) echo "[fix] refusing non-numeric PR: ${PR:-<empty>}" >&2; exit 1 ;; esac
# Guard-before-use for env tunables (same P1 class as merge-one.sh): FIX_TIMEOUT feeds ARITHMETIC
# below to derive the lease, and on /bin/bash 3.2.57 a failed arithmetic assignment aborts the rest
# of the enclosing `if` body with status 0 — silently disabling the claim.
# ⛔ REJECT LEADING ZEROS (P2, second review round, 2026-10-14): `''|*[!0-9]*` ACCEPTED `08`, so
# `FIX_LEASE=$(( 08 + 1200 ))` still reached the arithmetic and aborted the claim block with status
# 0. `$(( ))` parses base 0 (leading 0 = octal) and `08`/`09` are not octal. Accept only `0` or
# `[1-9][0-9]*`.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
# ⛔ MAGNITUDE, NOT JUST SHAPE (P2, third review round, 2026-10-14). `is_num` is UNBOUNDED, so it
# accepted `9223372036854775807`; `FIX_LEASE=$(( FIX_TIMEOUT + 1200 ))` then wrapped NEGATIVE, the
# lease failed to parse (`_lease_of`'s `[0-9]*` cannot match a minus sign), and an unparseable lease
# is read as LIVE — so the head was frozen across ALL boxes and `claim_prune` could never reap it.
# FAIL-CLOSED, the opposite of the design's fail-open policy. `is_limit` (is_num AND at most 9
# digits) is the predicate orch-loop.sh applies to every other tunable for exactly this reason.
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
# ⛔ EXPORTED for the same reason as lane.sh: the SPAWN POINT is a child process (#1884), and a
# refusal that cannot name its item is a log line an operator has to reverse-engineer.
KIND=fixer; TAG="$PR"; export KIND TAG
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
L="$O/logs/fix-$PR"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST (#1988). The line above prepends the tool dirs, so a REAL gh in
# either of them outranks the seeded `$O/gh-rest` (Mac REST adapter) / `$O/gh-limit` (cell
# serialiser) — and a shim that is never resolved is an INERT layer: it reports protection and
# provides none. Re-assert both here, adapter last so `$O/gh-rest` (which itself calls the same
# helper) wins where it exists. Guarded by `-d`, so a box that ships neither is unchanged.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
# The wall-clock limit AND the load gate both live in the shared helper, so this script has no
# `pi` invocation of its own to forget to gate (agent-infra#1720). NB: L above is a LOG PATH, not a
# load reading — the gate takes its reading as an argument for exactly that reason.
# Fail LOUD if the helper is missing: an unsourced helper leaves `run_agent` undefined, and that must
# never degrade into "the fixer ran" — see README §9 on syncing $O.
# ⛔ SOURCED AFTER THE PATH EXPORT: spawn-gate.sh derives `_NCPU` at SOURCE time, so sourcing it
# under the pre-export PATH pins _NCPU=4 / MAX_LOAD=40 for every cell (the #1702 failure).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/spawn-gate.sh" || { echo "[fix $PR] FATAL: $SELF/spawn-gate.sh missing — refusing to run an ungated fixer" >&2; exit 78; }
# ── the RESEARCH contract is part of the fixer's brief too (#2258) ──────────────────────────────────
# A fixer acts on a reviewer's findings, and the measured duplicate-PR incident (#2247 vs #2250) was
# two lanes fixing the same three things from two briefs that never forced either to look first. The
# block is the ONE canonical text (`brief-gate.sh --section fixer`), and the brief is CHECKED after it
# is written — a heredoc regression refuses here (78) instead of dispatching a fixer nobody asked to
# look first. Same shape as lane.sh's reviewer section (#2148).
brief_gate_sh="$(brief_gate_lib)" || {
  echo "[fix $PR] FATAL: brief-gate.sh not found — refusing to run a fixer whose brief nothing validated (#2258)" >&2; exit 78; }
FIX_RESEARCH_BRIEF="$(bash "$brief_gate_sh" --section fixer)" || {
  echo "[fix $PR] FATAL: brief-gate.sh --section failed — refusing to run a fixer whose brief omits the research contract (#2258)" >&2; exit 78; }
# ── COMMIT AS YOU GO is part of the fixer's brief too (#2981) ───────────────────────────────────────
# The measured batch behind #2981 was five `prfix` lanes — FIXERS — every one killed at its 2400 s cap
# with 0 commits and 0 PRs, holding its single commit for the end. A fixer is dispatched TO an existing
# PR, so it renders the `prfix` role: "commit and push onto it", never "open the PR". ONE home for the
# text (`reviewer-preflight.sh --delivery-brief`), the same way the research contract has one home.
for _rp in "$SELF/reviewer-preflight.sh" "${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/reviewer-preflight.sh" \
           "${HOME:-}/.pi/agent/scripts/orchestrator-harness/reviewer-preflight.sh"; do
  [ -n "$_rp" ] && [ -f "$_rp" ] && { delivery_sh="$_rp"; break; }
done
[ -n "${delivery_sh:-}" ] || {
  echo "[fix $PR] FATAL: reviewer-preflight.sh not found (looked in $SELF, \$AGENT_INFRA_PATH, ~/.pi/agent) — refusing to run a fixer whose brief never tells it to commit as it goes (#2981)" >&2; exit 78; }
FIX_DELIVERY_BRIEF="$(bash "$delivery_sh" --delivery-brief prfix)" || {
  echo "[fix $PR] FATAL: reviewer-preflight.sh --delivery-brief failed — refusing to run a fixer whose brief never tells it to commit as it goes (#2981)" >&2; exit 78; }
# ⛔ AN EMPTY RENDER IS A FAILED RENDER: spliced as a variable, an empty section is a blank line and
# every other assertion stays green.
[ -n "$FIX_DELIVERY_BRIEF" ] || {
  echo "[fix $PR] FATAL: reviewer-preflight.sh --delivery-brief rendered NOTHING — refusing to run a fixer that would hold its work to the cap (#2981)" >&2; exit 78; }
# ⛔ THE REPO-IDENTITY GATE (agent-infra#2694/#2724). This is the PR-lane half: a fixer given a
# checkout and a DIFFERENT target repo used to materialise a worktree in the checkout and run there,
# reporting failures about branches instead of about the repo. Missing = FATAL, because a silently
# skipped assertion is the defect. `REPO_TARGET_REFUSED` (72) is distinct from every gate code.
. "$SELF/repo-target.sh" || { echo "[fix $PR] FATAL: $SELF/repo-target.sh missing (or its repo-slug.sh parser is) — refusing to run a fixer whose repo cannot be asserted (#2694). Redeploy the harness: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $SELF" >&2; exit 78; }
command -v repo_target_assert >/dev/null 2>&1 && command -v repo_target_branch_assert >/dev/null 2>&1 \
  || { echo "[fix $PR] FATAL: $SELF/repo-target.sh is stale (no repo_target_assert/repo_target_branch_assert) — refusing to run a fixer whose repo cannot be asserted (#2694). Redeploy the harness: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $SELF" >&2; exit 78; }
# ── THE GATE DECISION IS MEASURED, NOT ASSUMED (agent-infra#2319) — see lane.sh for the full note.
. "$SELF/gate-policy.sh" 2>/dev/null || { echo "[fix $PR] FATAL: $SELF/gate-policy.sh missing — refusing to run a fixer that cannot say whether its gates are on" >&2; exit 78; }
apply_gate_policy fix-one
# ⛔ A DIFFERENT HATCH, DELIBERATELY UNTOUCHED: main-edits is a declared escape for writing to a main
# checkout, not a review bypass, and #2319 does not rule on it.
export AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none   # headless fixer uses no MCP servers — saves ~25 processes/run
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
cd "$REPO" || exit 1
# ⛔ PHYSICAL PATH: every assertion below names the checkout, and a RELATIVE $REPO resolved from
# inside itself names `$REPO/$REPO` (the C6 shape claim-cwd.test.sh pins for claims.sh).
REPO_ABS="$(pwd -P)"

# ── "THIS REFUSAL DID NOT COST AN ATTEMPT", IN ONE PLACE (#2762 review, 2nd cycle, P2) ─────────
# ⛔ A FUNCTION, NOT STRAIGHT-LINE, BECAUSE TWO PATHS NEED IT: the gate refusals inside `run_agent`
# (the marked block below, at the end) AND the repo-identity refusals further down, which exit BEFORE
# any agent could be booked. Both must refund: a wrong-repo pair is a permanent configuration error,
# and charging it to `fixcount` parks the PR as "attempts exhausted" having never run a fixer — the
# misdiagnosis class (#1720) this file's refund exists to prevent. It is defined HERE because the
# identity refusals run before the old block's position.
# [fixgate-refund:begin] (extracted and DRIVEN by red-fixer.test.sh — keep the markers)
# ⛔ THE MARKERS WRAP THE `CTRL` GUARD ITSELF, not just the body: the extracted function is driven
# with CTRL=1 AND CTRL=0, and a body without the guard made a MANUAL run refund an attempt the
# controller never booked (the test caught exactly that).
refund_gate_attempt() {
  [ "${CTRL:-0}" = "1" ] || return 0
  # ⛔ REFUND, AND ONLY ON THE CONTROLLER PATH. orch-loop.sh books the attempt (fixcount+1) when it
  # CREATES the session, which is UPSTREAM of every gate; this worker is the only party that knows no
  # agent ran. Without the refund, three refusals reach MAX_FIX_TRIES and the PR is PARKED "needs a
  # human" having never had a single fixer run (agent-infra#1720). A manual (positional) run booked
  # nothing, so it must refund nothing.
  local _cf="$O/state/fixcount-$PR" _nf
  if [ -f "$_cf" ]; then
    _nf="$(cat "$_cf" 2>/dev/null || echo 0)"
    # `is_num`, not a hand-rolled `case`: the predicate is already in scope (spawn-gate.sh defines it,
    # and this script uses it for its own tunables), and a second, weaker copy is exactly how `08` grew
    # an octal read in the first place.
    is_num "$_nf" || _nf=0
    if [ "$_nf" -gt 0 ]; then
      echo $((_nf - 1)) > "$_cf"
      echo "[fix $PR] a gate refusal is not an attempt — fixcount refunded $_nf -> $((_nf - 1))" >> "$L.log"
    fi
  fi
  # ⛔ THE SAME FACT FOR THE PER-HEAD BUDGET (agent-infra#2223, review P1 cycle 3). The controller's
  # red-fixer role keeps a HEAD-KEYED counter (`redfix-<PR>` = "<head> <n>", capped at 2) because a
  # refusal describes one tree. It books that counter at spawn, exactly as it books `fixcount` — and
  # this function is the only party that knows the agent never started. Without this marker two gate
  # refusals (a DISK refusal never clears by waiting, so this is deterministic) reach the cap and PARK
  # a red PR with the reason "2 fixer attempt(s) did not clear it" — a sentence that is false, since no
  # fixer ever ran. That is the stall this role exists to end, re-created by its own counter. The
  # marker is consumed (and the attempt refunded) by the controller; it names the head because a
  # refund for a superseded head would credit the wrong budget.
  if [ -n "${HEAD:-}" ]; then
    : > "$O/state/fixgate-$PR-$HEAD" 2>/dev/null || true
    echo "[fix $PR] a gate refusal is not an attempt — fixgate-$PR-$HEAD recorded for the controller's per-head refund" >> "$L.log"
  fi
  return 0
}
# [fixgate-refund:end]

# locate the branch's worktree
WT="$(git worktree list --porcelain | awk -v b="refs/heads/$BR" 'BEGIN{p=""} /^worktree /{p=$2} /^branch /{if($2==b) print p}')"
echo "[fix $PR] start $(date) worktree=$WT branch=$BR" > "$L.log"

# ⛔ THE HEAD IS READ BEFORE THE REFUSALS, NOT AFTER (#2762 review, 3rd cycle, P1).
# The refund for a pre-agent refusal names the head (`fixgate-<PR>-<HEAD>`), and the identity
# assertions below exit long before the old position of this line — so a repo-identity refusal
# refunded `fixcount` but could NOT refund the per-head budget, and after two such cycles the PR
# parked as "2 red-fixer attempt(s) at this head did not clear it" having never run a fixer.
HEAD="$(gh pr view "$PR" --repo "$OR" --json headRefOid --jq .headRefOid 2>/dev/null)"
# ── THE TARGET ASSERTION, BEFORE ANY WORK (agent-infra#2694) ──────────────────────────────────
# A fixer is handed BOTH a checkout ($1) and the repo it is fixing for ($2). If those disagree, every
# git and gh call below would act on one while reporting about the other — the measured wrong-repo
# lane. Refuse by name, before materialising anything. ⛔ AFTER the `start` truncation above, so this
# per-dispatch line survives in the log it is written to (A-verify finding, #2694).
REPO_ASSERT_LINE="$(repo_target_assert "fixer #$PR target" "$REPO_ABS" "$OR" "")"; REPO_ASSERT_RC=$?
printf '%s\n' "$REPO_ASSERT_LINE" >> "$L.log"
if [ "$REPO_ASSERT_RC" -ne 0 ]; then
  echo "[fix $PR] REFUSED: the checkout $REPO_ABS and the target repo $OR disagree (exit $REPO_ASSERT_RC) — no fixer started, no branch touched" >> "$L.log"
  refund_gate_attempt
  exit "$REPO_ASSERT_RC"
fi

[ -z "$WT" ] && {
  # Foreign (other-machine) branch: materialise a local worktree so the fixer has somewhere to work.
  if git rev-parse --verify -q "refs/heads/$BR" >/dev/null; then
    git worktree add ".worktrees/fix-$PR" "$BR" >> "$L.log" 2>&1
  else
    # ⛔ NAME THE DESTINATION, NOT JUST THE SOURCE (#3009, the SAME defect pr-doctor had).
    # `git fetch origin "$BR"` does NOT create `refs/remotes/origin/$BR`: with no colon the fetched
    # ref lands in FETCH_HEAD, and a remote-tracking ref is only ALSO updated when a CONFIGURED
    # `remote.<name>.fetch` refspec maps that source. A full clone maps every branch, so the bug is
    # invisible on a dev box — but a CELL checkout is a SINGLE-BRANCH clone
    # (`+refs/heads/main:refs/remotes/origin/main`), so the fetch SUCCEEDS (rc=0), creates nothing,
    # and the very next line asks for the ref it just declined to create. The guard then fires with
    # a FABRICATED diagnosis (`branch is not in <OR> — a BRANCH/REPO mismatch`) — a false accusation
    # of the wrong repo, which is worse than a silent failure because it sends the operator at the
    # remote instead of at the clone. The leading `+` keeps the update valid after the force-push a
    # PR branch routinely gets.
    git fetch origin "+refs/heads/$BR:refs/remotes/origin/$BR" --quiet >> "$L.log" 2>&1
    # ⛔ NAME THE REPO, NOT A MATERIALISATION FAILURE (#2694). The measured message a human read
    # first was `cannot materialise <branch>`, which says nothing about the repo the branch is
    # missing FROM. If the branch is not in THIS repo, say so — with the branch and the slug — and
    # stop. A fetch that failed for network reasons is covered too: the branch is unproven here, and
    # the refusal names both possibilities rather than blaming worktree creation.
    if ! git rev-parse --verify -q "refs/remotes/origin/$BR" >/dev/null 2>&1; then
      # Reached only when the fetch genuinely could not read the branch (network, auth, a real
      # BRANCH/REPO mismatch) — the refspec above no longer produces a FALSE hit here.
      repo_target_branch_assert "fixer #$PR" "$REPO_ABS" "$BR" "$OR" >> "$L.log"
      echo "[fix $PR] REFUSED: branch '$BR' is not in $OR (checkout $REPO_ABS) — it could not be read after fetching origin. This is a BRANCH/REPO mismatch, not a worktree-materialisation failure; refusing before any fixer starts" >> "$L.log"
      refund_gate_attempt
      exit "$REPO_TARGET_REFUSED"
    fi
    git worktree add ".worktrees/fix-$PR" -b "$BR" "origin/$BR" >> "$L.log" 2>&1
  fi
  WT="$(git worktree list --porcelain | awk -v b="refs/heads/$BR" 'BEGIN{p=""} /^worktree /{p=$2} /^branch /{if($2==b) print p}')"
  [ -z "$WT" ] && { echo "[fix $PR] ABORT: could not materialise a worktree for $BR" >> "$L.log"; exit 1; }
  echo "[fix $PR] materialised worktree=$WT" >> "$L.log"
}

# ── THE POST-BUILD ASSERTION (agent-infra#2694/#2724) ──────────────────────────────────────────
# The worktree now EXISTS. Read what it actually is and refuse to run the fixer when it is not the
# target repo. A pre-build check proves what we asked for; this proves what we got. The branch half
# distinguishes the right repo from a worktree checked out on another repo's branch.
WT_REPO_LINE="$(repo_target_assert "fixer #$PR" "$WT" "$OR" "$REPO_ABS")"; WT_REPO_RC=$?
printf '%s\n' "$WT_REPO_LINE" >> "$L.log"
if [ "$WT_REPO_RC" -ne 0 ]; then
  echo "[fix $PR] REFUSED: the materialised worktree is not $OR (exit $WT_REPO_RC) — no fixer started" >> "$L.log"
  refund_gate_attempt
  exit "$WT_REPO_RC"
fi
WT_BRANCH_LINE="$(repo_target_branch_assert "fixer #$PR" "$WT" "$BR" "$OR")"; WT_BRANCH_RC=$?
printf '%s\n' "$WT_BRANCH_LINE" >> "$L.log"
if [ "$WT_BRANCH_RC" -ne 0 ]; then
  echo "[fix $PR] REFUSED: branch/checkout assertion failed (exit $WT_BRANCH_RC) — no fixer started" >> "$L.log"
  refund_gate_attempt
  exit "$WT_BRANCH_RC"
fi

# ── cross-box claim for the FIXER (P3.3, 2026-10-14 adversarial review) ───────
# merge-one.sh claims before reviewing, but fix-one.sh ran the fixer FIRST and only then called
# merge-one.sh (the sole claim_acquire caller), so two boxes could each spawn a fixer for the same
# PR/head. Same key and lease shape as merge-one.sh's — the claim is on the PR's CURRENT head, so a
# fixer and a reviewer never race each other for the same content version.
# ── NO CI-QUEUE GATE IN THE FIXER: A FIXER IS REPAIR (#2927) ─────────────────────
# This block used to read the repo's CI queue and EXIT the fixer on a deep one, on the argument that a
# fixer's product is a new head and so a full CI pass. ⛔ THAT ARGUMENT IS TRUE AND STILL NOT A REASON TO
# GATE: a repair push does start a fresh run. What was wrong is the NUMBER — the queue depth the block
# read was GitHub-HOSTED concurrency belonging to NEW-PR work, and it was DERIVED from the in-progress
# job count, so it read smallest when the box was idle (#2927). Repair's bound is a lane slot, not a
# queue depth, and #2927 records that as a decision rather than as a cost claim. On 2026-10-27 it deferred 41
# consecutive repair dispatches on cell 4 verbatim (`skip #<n>: backpressure(q=27..33, r=~2)`, with 8
# idle self-hosted runners and ~11 free lane slots), and this file was the last-line half of that
# gate: a lane the controller had already decided to start could still refuse itself.
# ⛔ WHAT BOUNDS A FIXER, AND WHAT STAYS: the box's LANE SLOTS and the LOAD/disk gate
# (`spawn-gate.sh`, below and in the caller) — those are about whether THIS BOX can run the agent,
# which is what the fixer actually consumes. The CI queue is not consulted here and must not become
# so again: see `ci-queue.sh`'s header for the class rule (only work that ADDS a new CI run is
# queue-gated) and #2927 for the measurement. The cross-box claim below is unchanged and still runs
# before any work: a fixer that will not push must not hold a claim.
# ── THE LANDER'S LOCK: a fixer must not be in flight on a PR a lander owns ─────────
# ⛔ THE HOLE THIS CLOSES (measured 2026-10-23). `merge-one.sh` (the reviewer/lander chain) and the
# doctor's `merge` role both take `$O/state/mergeclaim-<PR>.lock` before doing anything to a PR, and
# the controller's `claim_live` reads that SAME file as its spawn guard. `fix-one.sh` took NEITHER
# it nor anything else the lander reads — only the cross-box `<PR>-<head>` claim, which the doctor
# also does not take. So on one box the lander and the ONE worker whose product is a PUSH could be
# in flight on the same PR at the same time: the lander re-resolves the head, the fixer pushes under
# it, and the rail refuses — with the attestation the review chain had just minted gone stale.
# Measured on the tortoise queue the same day: of 11 open non-draft PRs, 6 carried a CLEAN record
# bound to a head that had since moved, and `[merge] candidates=12 attempted=1 landed=0` — the
# lander's own fixer lanes are a pusher it cannot see.
#
# ⛔ WHY THIS FILE AND NOT THE CALLER. The controller already refuses to spawn when `claim_live`
# says the lock is held, but `fix-one.sh` is ALSO reached directly and by `adopt-fix.sh`, and a
# guard that lives only in the controller leaves those paths pushing at a live lander — the same
# argument the repo-identity assert above makes for itself (it runs here, not only in the spawner,
# because `adopt-fix.sh` reaches this script without the controller in the path at all).
#
# ⛔ THE DIRECTION IS DEFER, NEVER BLOCK-AND-HOLD. Contention writes the SAME refundable bail marker
# the cross-box refusal writes, so the controller refunds the attempt and re-decides from a fresh read
# next cycle: nothing is dropped, and a lander that lands the PR ends the work entirely. Nothing here
# is sticky — the marker describes one cycle, not a state.
#
# ⛔ A STALE CLAIM IS TAKEN OVER, NOT REFUSED (#2574 (b)) — AND THE TAKEOVER IS A RENAME, NEVER
# `rm && write`. Measured staleness is the whole licence: the record's pid is numeric and `kill -0`
# says it is GONE. The naive reclaim (`read owner -> is it live? -> rm -> write`) is two syscalls, so
# between them a peer can win the noclobber create — and the `rm`, issued on the strength of an
# EARLIER read, then deletes that peer's LIVE lock, re-opening the hole this block exists to close
# (review of PR #2576, P3, reproduced). `mv` moves whatever is at the path at the instant it runs, so
# what we detached is OBSERVABLE afterwards: if it is not the pid we measured, we detached someone's
# live claim, put it back with `ln` (create-if-absent — a real CAS) and defer. Nothing is deleted
# blind, and a refusal is still refundable, so the worst case is one re-decided cycle.
#
# ⛔ WHY A TAKEOVER AT ALL, WHEN `claim_live()` ALSO RECLAIMS. The controller's spawn guard reclaims a
# dead owner's claim, so on the CONTROLLER path a stale lock is already gone before this file runs.
# But this file is also reached directly and by `adopt-fix.sh` (nothing is dispatching, so no reclaim
# is coming), and `merge-one.sh` reclaims this same file by `rm` + retry on its own path — so a fixer
# that merely deferred would leave the PR blocked behind bookkeeping that recorded a past state and
# is never revalidated. The fleet has been blocked for hours by exactly that shape.
#
# ⛔ AN UNREADABLE RECORD IS **NOT** STALE, AND THAT IS THE ONE WAY TO STEAL A LIVE LANDER'S CLAIM.
# `merge-one.sh` claims with `( set -o noclobber; echo $$ > "$CLAIM" )`: the file exists for an
# instant BEFORE the pid is written, so "empty content ⇒ dead owner" would take a lock whose owner
# is alive and mid-claim. Only a numeric pid that `kill -0` proves gone is stale; empty, unparseable
# or unreadable content is treated as LIVE and deferred (#1985's recycled-pid risk is the mirror of
# this one: there a live pid reads dead, here a claiming pid has not been written yet).
#
# ⛔ THE LOOSE-LIVENESS READ IS THE FLEET'S EXISTING CONVENTION, NOT A NEW ONE. "Any live pid holds"
# is `claim_live`'s documented spawn-guard direction (a recycled pid means "do not spawn", one lost
# cycle, nothing deleted) and the doctor's `merge` role reads the same file the same way. The
# recycled-pid risk of reclaiming on liveness alone is #1985's, already filed; this arm joins the
# existing mechanism rather than inventing a second lock with its own semantics.
PRLOCK="$O/state/mergeclaim-$PR.lock"
prlock_live_owner() { # prints the owner pid and returns 0 only when the lock is held by a LIVE pid
  local p
  [ -f "$PRLOCK" ] || return 1
  p="$(cat "$PRLOCK" 2>/dev/null || echo 0)"
  case "${p:-}" in ''|*[!0-9]*) p=0 ;; esac
  [ "$p" -gt 0 ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  printf '%s\n' "$p"
  return 0
}
# ⛔ THE RECORD APPEARS WITH ITS PID ALREADY IN IT, AND THAT IS NOT TIDINESS. A noclobber create
# followed by a separate write leaves the file EMPTY for an instant, and the other three readers of
# this SAME file — `merge-one.sh:144-147`, the doctor's `merge` role and `claim_live()` in
# `orch-loop.sh` — treat an empty record as "no owner" and `rm` it. So the window let a lander delete a
# live fixer's claim by reading it mid-create, i.e. the hole this block closes, reopened from the other
# side (review of PR #2576, P2). Writing the pid to a private file and `ln`-ing it into place makes
# the create and the content ONE atomic step: `ln` refuses an existing destination (no `-f`), which IS
# the compare-and-swap.
prlock_take() {
  local tmp rc name
  tmp="$O/state/.mergeclaim-$PR.$$.tmp"
  name="${tmp##*/}"
  printf '%s\n' "$$" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  ln "$tmp" "$PRLOCK" 2>/dev/null; rc=$?
  rm -f "$tmp" 2>/dev/null
  [ "$rc" -eq 0 ] || return 1
  # ⛔ `ln` EXITS 0 WHEN THE DESTINATION IS A DIRECTORY — it links INSIDE it instead of replacing it, so
  # success is not proof that the record is ours (measured: a `mergeclaim-<PR>.lock` directory made this
  # function report a successful claim, and the unusable-path refusal below never fired). The path must
  # now BE our record. The stray inner link is removed so a corrupt path is not also littered.
  [ "$(cat "$PRLOCK" 2>/dev/null || echo 0)" = "$$" ] && return 0
  rm -f "$PRLOCK/$name" 2>/dev/null
  return 1
}
prlock_stale_owner() { # prints the pid and returns 0 ONLY when staleness is MEASURED
  # The three ways this returns 1 are all "not stale", and the last two are the two ways to steal a
  # LIVE claim: (a) the lock is gone or is not a regular file; (b) the pid is empty/unparseable —
  # `merge-one.sh`'s noclobber create and its `echo $$` are separate operations, so a claiming
  # lander's file is briefly EMPTY; (c) `kill -0` succeeds — a live pid holds, deliberately loose,
  # the same direction `claim_live` documents. A recycled pid therefore reads LIVE (one lost cycle,
  # nothing deleted) rather than as a claim to take (#1985).
  local p
  [ -f "$PRLOCK" ] || return 1
  p="$(cat "$PRLOCK" 2>/dev/null || echo 0)"
  case "${p:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$p" -gt 0 ] || return 1
  kill -0 "$p" 2>/dev/null && return 1
  printf '%s\n' "$p"; return 0
}
prlock_takeover() { # $1 = the pid we MEASURED stale; 0 = we own it · 1 = nothing displaced · 2 = a claim was LOST
  # ⛔ FOUR STEPS, AND EACH ONE IS A CAS OR A VERIFICATION. (1) the record must still be the pid we
  # measured — a re-read before the steal, so a peer that reclaimed while we were deciding is not
  # displaced; (2) DETACH by `mv`, never `rm`, so what we moved can be inspected; (3) verify what we
  # actually moved is the dead pid — if it is not, we took someone's LIVE claim in the instant between
  # (1) and (2), so put it back with `ln` (create-if-absent) and defer; (4) claim the vacated path.
  # A `mv` that finds the path already gone (a peer detached it first) fails, which is the CAS: only
  # one racer can detach a given record.
  # ⛔ THE RETURN CODES ARE DISTINCT BECAUSE THE OUTCOMES ARE OPPOSITE (review of PR #2576, P2). 1 =
  # nothing was displaced (the record changed, the mv found it gone, or the create lost a race), so
  # "the peer holds it, nothing was lost" is TRUE. 2 = we displaced a claim that could not be put back,
  # so a live peer's lock is GONE; reporting that as "nothing was deleted" would hand the operator two
  # contradictory lines and the wrong repair. The caller writes a different sentence for each.
  local stale="$1" side cur
  side="$PRLOCK.reclaim.$$"
  cur="$(cat "$PRLOCK" 2>/dev/null || echo 0)"
  [ "$cur" = "$stale" ] || return 1
  mv -f "$PRLOCK" "$side" 2>/dev/null || return 1
  cur="$(cat "$side" 2>/dev/null || echo 0)"
  if [ "$cur" != "$stale" ]; then
    if ln "$side" "$PRLOCK" 2>/dev/null; then
      rm -f "$side"
      return 1
    fi
    echo "[fix $PR] WARNING — a peer claimed state/mergeclaim-$PR.lock between the stale read and the takeover; its claim (pid ${cur:-unreadable}) was DETACHED and could NOT be restored (the path was re-claimed first)" >> "$L.log"
    rm -f "$side"
    return 2
  fi
  if prlock_take; then rm -f "$side"; return 0; fi
  rm -f "$side"   # lost the create race: drop only the stale artifact
  return 1
}
release_prlock() { # never removes a lock we do not own: a lander that outlived us keeps its claim
  [ -n "${PRLOCK:-}" ] || return 0
  [ "$(cat "$PRLOCK" 2>/dev/null)" = "$$" ] && rm -f "$PRLOCK" 2>/dev/null
  rm -f "$O/state/.mergeclaim-$PR.$$.tmp" 2>/dev/null   # a create interrupted between write and ln
  return 0
}
# The refusal has the SAME three arms as the other two gates: the controller refunds by consuming
# `fixbail-<PR>-<HEAD>`, and an empty HEAD (the cross-box marker's own documented hole) or a manual
# run must not pretend to have booked one.
# ⛔ THE FIRST LINE IS A STABLE TOKEN (`DEFERRED: the LANDER`), because `adopt-fix.sh` — the operator
# surface onto this script — has to name the cause in the log the operator reads, exactly as it does
# for the PR-owner lock arm below. A second, cosmetic reword would silently make `adopt-fix <PR>`
# report SUCCESS for a run that pushed nothing (review of PR #2576, P2).
prlock_defer() { # prlock_defer <why>
  echo "[fix $PR] DEFERRED: ${1} — nothing pushed, so no attestation was invalidated by this lane" >> "$L.log"
  if [ "${CTRL:-0}" = "1" ] && [ -n "${HEAD:-}" ]; then
    : > "$O/state/fixbail-$PR-$HEAD"
    echo "[fix $PR] attempt refundable (bail marker written for head $HEAD)" >> "$L.log"
  elif [ "${CTRL:-0}" = "1" ]; then
    echo "[fix $PR] the head could NOT be read, so no bail marker could be written — the controller cannot refund this attempt (re-decided next cycle)" >> "$L.log"
  else
    echo "[fix $PR] manual run: no attempt was booked and none is refunded" >> "$L.log"
  fi
  exit 0
}
# ⛔ A REFUSAL THAT CANNOT CLEAR BY ITSELF IS NOT REFUNDABLE (review of PR #2576, cycle 2 — P2). Every
# arm above writes the bail marker, so the controller refunds the attempt and re-decides — which is
# right for a lock a LANDER holds or one whose dead owner this lane could not take over (a lost
# race). It is WRONG for a lock state that no re-dispatch can change: a `$PRLOCK` that is not a regular
# file (a directory, an unreadable object) or a `$O/state` this box cannot write. There the refund
# makes spawn -> defer -> refund a PERMANENT SPIN: `fixcount` nets to zero every cycle, so MAX_FIX_TRIES
# never trips, nothing parks, and nothing surfaces — the same shape `orch-loop.sh` documents for a
# deferral that cannot clear itself. Those two arms therefore consume the attempt (no bail marker) and
# name the repair, so the cap parks the PR in front of a human instead of hiding the state forever.
prlock_refuse() { # prlock_refuse <why> — NOT refundable: re-dispatching cannot change this state
  echo "[fix $PR] REFUSED (NOT refundable — a re-dispatch cannot clear this): ${1} — nothing pushed" >> "$L.log"
  if [ "${CTRL:-0}" = "1" ]; then
    echo "[fix $PR] this attempt is CONSUMED so MAX_FIX_TRIES parks the PR in front of a human; no bail marker was written" >> "$L.log"
  else
    echo "[fix $PR] manual run: nothing was consumed" >> "$L.log"
  fi
  exit 0
}
if PL_OWNER="$(prlock_live_owner)"; then
  prlock_defer "the LANDER owns this PR (state/mergeclaim-$PR.lock held by live pid $PL_OWNER) — a push now would move the head out from under the attestation it is landing"
elif PL_STALE="$(prlock_stale_owner)"; then
  # ⛔ THE OVERRIDE IS LOGGED WITH ITS EVIDENCE, not just announced: WHICH lock, WHOSE pid, and the
  # measurement that made it stale. An operator reading `fix-<PR>.log` afterwards must be able to
  # tell a takeover from a normal acquisition without re-deriving it.
  if prlock_takeover "$PL_STALE"; then
    echo "[fix $PR] PR-owner lock: RECLAIMED a STALE claim — state/mergeclaim-$PR.lock named pid $PL_STALE, which is not alive (measured with kill -0), so this lane took the claim over instead of refusing the PR" >> "$L.log"
  else
    case $? in
      2) prlock_defer "the PR-owner lock (state/mergeclaim-$PR.lock) named pid $PL_STALE (not alive), and a peer's claim that appeared while this lane was taking it over was DISPLACED AND COULD NOT BE RESTORED — the WARNING line above names that pid. Nothing was pushed by this lane; REPAIR: confirm no worker is live (pgrep -af 'fix-one.sh|merge-one.sh|cloud-cell-doctor.sh') and re-run, and treat any worker that lost its claim as having lost it" ;;
      *) prlock_defer "the PR-owner lock (state/mergeclaim-$PR.lock) named pid $PL_STALE, which is NOT alive (measured with kill -0), but the takeover LOST a race with a peer that reclaimed it first — this lane displaced nothing; the peer now holds it. REPAIR only if this repeats with NO live worker and nothing dispatching this PR: confirm none is running (pgrep -af 'fix-one.sh|merge-one.sh|cloud-cell-doctor.sh'), then rm -f state/mergeclaim-$PR.lock" ;;
    esac
  fi
elif prlock_take; then
  echo "[fix $PR] PR-owner lock: acquired state/mergeclaim-$PR.lock (no lander is in flight on this PR)" >> "$L.log"
else
  # ⛔ A FAILED CAS IS NOT PROOF THAT AN OWNER EXISTS (review of PR #2576, cycle 2 — P3). It also fails
  # when the path is a directory or `$O/state` is unwritable, and the re-read below cannot tell an
  # ABSENT lock from a stale one — so each condition is named for what it is instead of being reported
  # as "the owner is not live", which sent an operator to wait for the reclaim of nothing.
  if PL_OWNER="$(prlock_live_owner)"; then
    prlock_defer "the LANDER claimed this PR while this lane was starting (state/mergeclaim-$PR.lock held by live pid $PL_OWNER)"
  fi
  if [ -e "$PRLOCK" ] || [ -L "$PRLOCK" ]; then
    if [ ! -f "$PRLOCK" ]; then
      prlock_refuse "state/mergeclaim-$PR.lock exists but is NOT a regular file (a directory, a dangling symlink, or an object this box cannot read), so no owner can be read and no claim can be taken. REPAIR: inspect it (ls -ld '$PRLOCK'), confirm no lander is running for #$PR, then rm -f (or rmdir) it"
    fi
    # A REGULAR FILE WE CANNOT MEASURE AS STALE: empty or unparseable content (a lander mid-claim), or
    # a pid that went live between the two reads above. NEVER stolen — see prlock_stale_owner.
    prlock_defer "the PR-owner lock (state/mergeclaim-$PR.lock) exists and holds no pid this lane can prove dead (its content is empty, unparseable, or names a pid that is now alive), so it is treated as LIVE and left untouched — nothing was deleted. REPAIR only if this persists with NO live worker and nothing dispatching this PR: confirm none is running (pgrep -af 'fix-one.sh|merge-one.sh|cloud-cell-doctor.sh'), then rm -f state/mergeclaim-$PR.lock"
  fi
  # The file is ABSENT at the re-read: its owner released it between the CAS and this read (a fast
  # lander exit runs its EXIT trap). That is not a stale claim — retry ONCE rather than reporting one.
  if prlock_take; then
    echo "[fix $PR] PR-owner lock: acquired state/mergeclaim-$PR.lock (an earlier holder released it while this lane was starting; no lander is in flight on this PR)" >> "$L.log"
  else
    prlock_refuse "state/mergeclaim-$PR.lock could not be CREATED although no file exists there — $O/state is unwritable, full, or not a directory. REPAIR: check the permissions and free space of '$O/state'"
  fi
fi
CROSS_OWN=""; CROSS_RC=0
release_fix_claim() { # bounded, like merge-one.sh's — it runs on the EXIT path
  # ⛔ THE 20s BOUND IS A DELIBERATE TRADE (P3, second review round, 2026-10-14): it CAN kill a
  # release that would eventually have succeeded — a `git push` slower than 20s is TERM'd, the
  # fenced push leaves the ref intact, and every box then refuses that head until the lease expires
  # (FIX_TIMEOUT+1200, up to ~1 h). Accepted because an UNBOUNDED exit path is strictly worse: it
  # holds the process open with the local lock already dropped, so the controller can spawn a second
  # fixer for the same head. DO NOT remove the bound; move the release OFF the exit path instead.
  local p w rc
  [ -n "${CROSS_OWN:-}" ] || return 1
  claim_release "$REPO" "$PR" "$HEAD" "$CROSS_OWN" >/dev/null 2>&1 &
  p=$!
  ( sleep 20; kill -TERM "$p" 2>/dev/null; sleep 5; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$p" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null
  return "$rc"
}
trap 'release_prlock; release_fix_claim' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
if [ -n "${HEAD:-}" ] && [ -f "$O/claims.sh" ]; then
  # shellcheck source=/dev/null
  . "$O/claims.sh"
  if ! is_limit "${FIX_TIMEOUT:-2400}"; then
    echo "[fix $PR] FIX_TIMEOUT='${FIX_TIMEOUT:-}' is not an integer in range (at most 9 digits) — using 2400 (the cross-box lease needs a number that cannot overflow)" >> "$L.log"
    FIX_TIMEOUT=2400
  fi
  # Overflow-safe by construction: the guard above leaves FIX_TIMEOUT <= 999999999, so this sum is
  # < 2**31. claims.sh clamps the ttl a second time at its own arithmetic site.
  FIX_LEASE=$(( ${FIX_TIMEOUT:-2400} + 1200 ))
  claim_acquire "$REPO" "$PR" "$HEAD" "$FIX_LEASE" >/dev/null
  CROSS_RC=$?
  case "$CROSS_RC" in
    0) CROSS_OWN="$CLAIM_COMMIT"
       echo "[fix $PR] cross-box fixer claim: $CLAIM_RESULT" >> "$L.log" ;;
    1) echo "[fix $PR] cross-box fixer claim REFUSED: $CLAIM_RESULT — another box is already fixing head $HEAD; recording a bail marker and exiting" >> "$L.log"
       # ⛔ BAIL MARKER (P2, second review round, 2026-10-14). The controller books the attempt
       # (fixcount+1) and DELETES the reviewer's findings marker at SPAWN, so this refusal — which
       # did no work at all — used to burn one of MAX_FIX_TRIES and leave the findings unrecorded.
       # Three refusals PARK the PR as needs-a-human although no fixer ever ran. orch-loop.sh reads
       # this marker and refunds both.
       : > "$O/state/fixbail-$PR-$HEAD"
       exit 0 ;;
    *) echo "[fix $PR] cross-box fixer claim UNAVAILABLE (rc=$CROSS_RC: $CLAIM_RESULT) — proceeding (fail-open on purpose)" >> "$L.log"
       if [ -n "${CLAIM_COMMIT:-}" ]; then
         CROSS_OWN="$CLAIM_COMMIT"
         release_fix_claim && CROSS_OWN=""
       fi ;;
  esac
fi

# Capture the FAILING REQUIRED CHECK and its log. The fixer is also dispatched for CI failures
# that are not a reviewer finding (docs lint, a committed conflict marker, legal-e2e,
# test-isolation, license-surface, pricing-artifact). Without this it would read only the review
# comment — which for such a PR may not exist at all — and fix blind.
: > "$L-failing.txt"
# ⛔ THE READ IS OBSERVED BEFORE IT IS TRUSTED (agent-infra#2121, empty-as-pass). `gh pr checks …
# 2>/dev/null | python3 -c` collapsed THREE different outcomes into the same empty string: the read
# FAILED (gh non-zero, stderr discarded), the payload was UNPARSEABLE (the old `except: raise
# SystemExit` exited 0 with nothing printed), and there genuinely ARE no failing checks. Only the
# third is a fact — but this file is the fixer's ONLY evidence that CI is red, so a fixer was
# dispatched believing the checks were green when the read had never happened. The read and the
# parse are now observed separately, and an observation that did not happen is written INTO that
# file as UNKNOWN (which also keeps it non-empty, so the fixer's prompt still sends it there).
checks_json="$(gh pr checks "$PR" --repo "$OR" --json name,state 2>/dev/null)" || checks_rc=$?
FAILING_CHECKS=''
checks_unknown=''
if [ "${checks_rc:-0}" -ne 0 ]; then
  checks_unknown="the required-check read FAILED (gh rc=$checks_rc)"
elif [ -z "$checks_json" ]; then
  checks_unknown="the required-check read returned NO JSON"
else
FAILING_CHECKS="$(printf '%s' "$checks_json" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: raise SystemExit(1)
# The SAME allow-list polarity the loop's classifier and admin-merge.sh use (agent-infra#1714): a
# check is FAILING only when its state is neither a NAMED in-flight spelling nor one of the NON-RED
# conclusions. CANCELLED/STALE are non-red by that rule - a superseded run
# (cancel-in-progress: true) is normal, and handing one to a fixer burns a capped attempt on a PR
# that is not red, while the old deny-list named CANCELLED as failing.
INFLIGHT=('queued','in_progress','waiting','requested','pending')
NONRED=('success','neutral','skipped','cancelled','stale')
red=[]
for c in (d if isinstance(d,list) else []):
    s=str(c.get('state') or '').lower()
    if s in INFLIGHT or s in NONRED: continue
    red.append(str(c.get('name') or ''))
print(' '.join(red))
" 2>/dev/null)"
# ⛔ THE END LINE ABOVE IS PINNED BY SHAPE, deliberately: scripts/orchestrator-harness/selftest.sh
# extracts this assignment with `awk '/^FAILING_CHECKS="/,/^" 2>\/dev\/null\)"$/'` and runs the
# result as python. Appending `|| parse_rc=$?` to that line made the END MARKER unreachable, awk then
# ran to EOF and the extracted "python" became the rest of the script — so the PARSE status is read
# on the NEXT line instead of on the closing one. Keep the two marker lines exactly as they are.
checks_parse_rc=$?
if [ "$checks_parse_rc" -ne 0 ]; then
  checks_unknown="the required-check payload could not be PARSED (rc=$checks_parse_rc)"
fi
fi
if [ -n "$checks_unknown" ]; then
  echo "=== NOTE: $checks_unknown — this file does NOT establish that CI is green. Treat the required checks as UNKNOWN and read them yourself before concluding the build is clean ===" >> "$L-failing.txt"
  echo "[fix $PR] required-check read UNKNOWN ($checks_unknown) — proceeding (fail-open on purpose, and recorded in $L-failing.txt so the fixer sees it)" >> "$L.log"
fi
for c in $FAILING_CHECKS; do
  echo "=== failing required check: $c ===" >> "$L-failing.txt"
  RID="$(gh pr checks "$PR" --repo "$OR" --json name,link --jq ".[]|select(.name==\"$c\")|.link" 2>/dev/null | sed -nE 's#.*/runs/([0-9]+).*#\1#p' | head -1)"
  if [ -n "${RID:-}" ]; then gh run view "$RID" --repo "$OR" --log-failed 2>/dev/null | tail -80 >> "$L-failing.txt"; fi
done

# capture the reviewer's findings (the latest code-review comment on the PR)
gh pr view "$PR" --repo "$OR" --comments > "$L-comments.txt" 2>&1

# ⛔ agent-infra-SPECIFIC, and NOT in the tortoise original: the NO-SEARCH bound in the test bullet
# below. The fixer's worktree normally HAS a `.venv`, but when it does not the agent used to hunt for
# an interpreter across the filesystem — a `find` over $HOME blocks for minutes and has consumed whole
# agent budgets with nothing produced. Point it at `uv sync` instead. Do NOT drop it in a re-port.
cat > "$L-fixer.txt" <<EOF
$FIX_RESEARCH_BRIEF

$FIX_DELIVERY_BRIEF

You are a FIX agent for branch \`$BR\` (PR #$PR in $OR). A fresh-context reviewer found real issues; the full review is the LAST comment in this file: $L-comments.txt — read it in full

If \`$O/state/sickbrief-$PR.md\` exists, READ IT FIRST: it was generated from THIS PR's failing CI job — the failing check, the run id and the failing job's own log excerpt — not from a template. It is the reason this lane was dispatched when no reviewer finding named the check. ⛔ IT NAMES THE HEAD IT WAS GENERATED AT (\`head12: <12 chars>\`), and nothing deletes it: if that prefix is not the first 12 characters of THIS head (\`$HEAD\`), the brief is STALE — a later dispatch at a new head — so ignore it and work from the files above.

If $L-failing.txt is non-empty, REQUIRED CI CHECKS ARE ALSO FAILING and their failing logs are in that file — read it and fix the cause as well: it either names the failing required checks (sections headed \`=== failing required check:\`) with their logs, or it records that the check read was UNKNOWN — in which case the build state is UNKNOWN, NOT green, and you must read the PR's checks yourself before concluding anything. That is not a reviewer finding: it is the build. A committed conflict marker (<<<<<<< / >>>>>>>) anywhere is one such cause and must be resolved, not deleted wholesale. (find every "### N. Px" / "[P0|P1|P2]" section and its "Fix:" line).

Work ONLY in this worktree: \`$WT\` (its cwd). NEVER touch the repo's main checkout. You are already on \`$BR\`.
    cd $WT && git status -sb && git log --oneline -3
If \`.venv\` is missing in the worktree, run \`uv sync --extra embeddings --extra parity\` once before testing.
If the branch is behind \`origin/main\`, integrate it first (\`git fetch origin main\` then a plain merge of origin/main) and resolve any conflicts so the PR stays mergeable.
**If this PR is CONFLICTING (mergeable=CONFLICTING), resolving the conflict IS the task** — GitHub reports it as unmergeable right now, so integrate \`origin/main\`, resolve every conflict hunk keeping both sides' intent, run the targeted tests, commit and push. If there are no review findings, the conflict is the whole job.

Apply a fix for EVERY finding (P3 notes: address or record explicitly). Requirements:
- Make the fix at the stated location, and add/adjust tests so they genuinely FAIL on the pre-fix code (prove non-vacuity where you can).
- Register any new test file in \`config/ci-surfaces.yml\` (correct surface) — verify with \`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python tools/ci_selection.py --integrity\`.
- Run the targeted tests: \`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest <paths> -q -p no:cacheprovider\` (plus the sibling suites the review names). Never run the whole suite. Your worktree has its own \`.venv\` — use THAT one. ⛔ Never search the filesystem for an interpreter: no \`find\`/\`rg\`/\`du\` outside this worktree (a \`find\` under \`$HOME\` blocks for many minutes and has consumed whole agent budgets, producing no result). If \`.venv\` is genuinely missing here, run \`uv sync --extra embeddings --extra parity\` once.
- Stage specific files (never \`git add -A\`); commit with \`git commit -F <message-file>\`; push: \`git push origin $BR\`.
- Do NOT merge. Do NOT amend already-pushed commits — add a new commit.

FINAL MESSAGE (<=15 lines): which findings you fixed, files changed, exact test commands + pass/fail counts, and any finding you deliberately did not fix with the reason.
EOF
# ── THE GENERATED FIXER BRIEF IS CHECKED AT BUILD TIME (#2258) ─────────────────────────────────────
# The fixer's brief is written HERE, so a failure is a harness defect (78, cannot run) and never a
# brief-authoring refusal (80). Checking it before the spawn means a heredoc regression is caught with
# the reason, instead of arriving as an empty fixer run that the caller reads as "the fix did not work".
bash "$brief_gate_sh" --check "$L-fixer.txt" fixer 2>>"$L.log" || {
  echo "[fix $PR] FATAL: the GENERATED fixer brief fails brief-gate.sh — refusing to run a fixer whose brief lost its research contract (a harness defect in the heredoc above) (#2258)" >> "$L.log"
  echo "[fix $PR] FATAL: generated fixer brief refused by brief-gate.sh (harness defect, see $L.log)" >&2
  exit 78
}
# ── AND THE DELIVERY CONTRACT IS CHECKED AT BUILD TIME TOO (#2981) ──────────────────────────────────
# `brief-gate.sh` validates the RESEARCH contract only, so a heredoc edit that drops this section would
# leave every other assertion green — the invisibility that cost 144 KB. The needle is the RENDERED
# heading's own first line, never a literal: a second copy of the text is the drift this refuses, and
# an EMPTIED constant would make `grep -F ""` match every line (an inert guard that reads as
# protection) — hence the `-n`.
FIX_DELIVERY_HEADING="$(printf '%s\n' "$FIX_DELIVERY_BRIEF" | head -1)"
[ -n "$FIX_DELIVERY_HEADING" ] && grep -qF -- "$FIX_DELIVERY_HEADING" "$L-fixer.txt" || {
  echo "[fix $PR] FATAL: the GENERATED fixer brief lost its COMMIT-AS-YOU-GO section — refusing to run a fixer that would hold its work to the cap (a harness defect in the heredoc above) (#2981)" >> "$L.log"
  echo "[fix $PR] FATAL: generated fixer brief lost its COMMIT-AS-YOU-GO section (harness defect, see $L.log)" >&2
  exit 78
}
# ⛔ THE VOLUME IS THE WORKTREE, AND IT MUST BE PASSED EXPLICITLY (review round 2, P2). This script
# does `cd "$REPO"` (above) and only NAMES the worktree inside the agent's prompt, so `$PWD` here is
# the MAIN CHECKOUT — the gate's `DISK_GATE_PATH:-$PWD` default would measure a directory the agent
# never writes to. That is latent on a cell ($WT lives under $REPO/.worktrees, one volume) and real on
# a box that splits them: a healthy main checkout would let the fixer start onto a full worktree
# volume, which is the precise "cannot name the volume that actually fills" failure #1765 exists to
# remove. `uv sync` writes the venv in $WT, so $WT is the reading that matters.
# ⛔ AND `WIP_PATH="$WT"` FOR THE SAME REASON, ONE STEP LATER (#2045). `DISK_GATE_PATH` names the
# volume the fixer FILLS; `WIP_PATH` names the worktree whose UNCOMMITTED WORK a cap kill would
# destroy. This script `cd`s into $REPO, so run_agent's default (`$PWD`, the main checkout) would
# snapshot the wrong tree and report a CLEAN worktree while the fixer's work sat unsaved one
# directory away — the loud-but-wrong verdict, which is worse than no snapshot at all.
DISK_GATE_PATH="$WT" WIP_PATH="$WT" run_agent "${FIX_TIMEOUT:-2400}" "$L.log" "$L-fixer.txt" "fixer for PR #$PR"
# ⛔ THE GATE'S OWN CODE, captured immediately. It is the ONLY thing that distinguishes the two
# refusals below, and `$?` read after any later command would be that command's status (§7.4).
ar=$?
# ⛔ AGENT_STARTED (set by run_agent) is the authority, NOT the exit code: `pi` shares the 0–255
# status namespace, so a pi that exited 75 for its own reason must not be read as a load refusal —
# that would silently skip the merge-chain re-run below (#1720 advisory).
if [ "$AGENT_STARTED" = "0" ]; then
  # Nothing was fixed, so re-running the merge chain would be a fresh-context review of an
  # unchanged head — pure cost on an already-overloaded box, and the re-review would be refused by
  # the same gate anyway. Exit and let the controller's next cycle re-dispatch.
  #
  # ⛔ WHICH GATE REFUSED DECIDES THE REMEDY, and they are OPPOSITE (#1765, and agent-infra#2293 for the
  # third). A load refusal clears when the box quietens and the controller re-dispatches next cycle; a
  # DISK refusal never clears on its own — no amount of waiting frees a filesystem; a FORK refusal never
  # clears on its own either AND the box cannot start the retry it is being told to wait for. Naming
  # either un-clearable one "load gate" sends the operator to wait for an event that cannot fix it,
  # which is the instrument false positive this file's callers exist to avoid.
  # ⛔ TOLERANT REFERENCE, AND THE REASON IS A REAL SKEW (review round 2, P2 — REPRODUCED). The daemon
  # executes `$O/<script>` and $O is seeded file by file (cloud-cell-supervisor.sh's seed_and_stamp),
  # so a NEW caller can run against an OLD `$O/spawn-gate.sh` — the pre-#1765 helper defines
  # AGENT_LOAD_REFUSED but NOT AGENT_DISK_REFUSED. Under `set -u` that reference aborts HERE, BEFORE
  # the refund below: measured `bash: AGENT_DISK_REFUSED: unbound variable`, rc=1, fixcount unchanged —
  # three such refusals park a PR "needs a human" having never run a fixer, exactly the
  # agent-infra#1720 failure the refund exists to prevent. The default is CORRECT, not merely safe: a
  # pre-#1765 helper can never return 77, so 77 falls through to the load branch on the tree it came
  # from. install.sh's DRIFTED list now carries spawn-gate.sh, so the skew is DETECTED as well as
  # survived.
  # ⛔ FORK FIRST AMONG THE CAPACITY CODES, AND IT IS THE P1 THE REVIEW FOUND: `run_agent` returns
  # AGENT_FORK_REFUSED (73) for a box that is out of PROCESSES, and before this arm both that code and
  # 75 reported "load gate: re-dispatched when 1-min load falls below MAX_LOAD" — a remedy for a box
  # that cannot spawn the retry, and one that says nothing about the external restart that is the only
  # thing that helps. The same tolerant default (73) covers AGENT_FORK_REFUSED: a pre-#2293 helper
  # cannot return it, so the fork arm is inert on that tree and the code falls through as before.
  #
  # ⛔ A BRIEF REFUSAL IS A THIRD REMEDY, AND NOT ONE OF THE CAPACITY ONES (#2258). The brief is
  # GENERATED here (`brief-gate.sh --section fixer`), so it can only be refused if the heredoc lost the
  # block or the helper drifted — a HARNESS defect. Naming it "load" or "disk" would send the operator
  # to wait for a box or a filesystem that is fine, and the refund below still applies: nothing ran, so
  # no attempt was consumed. Tolerant reference for the same $O-skew reason as the disk code.
  if [ "$ar" = "${AGENT_BRIEF_REFUSED:-80}" ]; then
    why="BRIEF gate: the generated fixer brief failed brief-gate.sh (a HARNESS defect, not a capacity refusal and not a finding about this PR) — read the [brief-gate] block in the log; the fix is in the brief's own build, not in the box"
  elif [ "$ar" = "${AGENT_HARNESS_SKEW_REFUSED:-81}" ]; then
    # ⛔ A HARNESS DEFECT, LIKE THE BRIEF ARM ABOVE, AND FOR THE SAME REASON (follow-up review of
    # #2991, P2): the fixer's caller and the deployed `cell-lane-preflight.sh` disagree (a usage/version
    # skew) or the copy is corrupt, so the probe measured nothing. The capability arm below would have
    # this operator repair the box or dispatch the PR elsewhere — the extension set is fine and every
    # other box runs the same pair, so both remedies send them to an event that cannot arrive.
    why="HARNESS/MISMATCH gate: this fixer's caller and the deployed cell-lane-preflight.sh do not agree (usage/version skew, or a corrupt copy), so no measurement was possible (#2991) — this is a harness defect, not a property of the box and not a finding about this PR: do NOT dispatch the PR elsewhere, sync the helper pair (cp scripts/orchestrator-harness/*.sh \$O/) and re-run. Nothing was consumed"
  elif [ "$ar" = "${AGENT_CAPABILITY_REFUSED:-71}" ]; then
    # ⛔ A FIFTH REMEDY, AND THE ONE THAT IS NEITHER "wait" NOR "reclaim" (review of #2991, P1): the
    # box could not complete one model call and RETURN (agent-infra#2935). It does NOT clear by waiting
    # — the box has to be repaired (its installed pi/extension set, or its provider credential) or the
    # PR dispatched elsewhere. Without this arm the fixer published `load gate: re-dispatched when 1-min
    # load falls below MAX_LOAD`, i.e. the opposite remedy, one line under `[capability-gate] REFUSED`.
    # Tolerant default for the same $O-skew reason as the codes below: a helper predating the code can
    # never return it, so the arm is inert there and the code falls through as before.
    why="CAPABILITY gate: this box could not complete one model call and RETURN (#2935) — read the [capability-gate] REFUSED line in the log for WHICH reading refused; waiting cannot clear it, so repair the box (installed pi/extension set, provider credential) or dispatch the PR elsewhere. Nothing was consumed"
  elif [ "$ar" = "${AGENT_FORK_REFUSED:-73}" ]; then
    why="fork gate: this box is out of PROCESSES (agent-infra#2293) — restart or drain the BOX from outside; waiting for load to fall cannot clear it and the box cannot start the retry"
  elif [ "$ar" = "${AGENT_DISK_REFUSED:-77}" ]; then
    # ⛔ CODE 77 IS TWO CONDITIONS (review round 1, P2): below the floor, and above it without the
    # headroom for one lane's tree (`DISK-NOHEADROOM`, agent-infra#2721). Naming only the floor told the
    # operator a full filesystem was the cause when it was not.
    why="disk gate: either below DISK_MIN_FREE_MB, or no headroom for one lane's dependency tree (DISK-NOHEADROOM) — the '[disk-gate] REFUSED' line above names which, with both terms; reclaim space (cloud-cell-supervisor.sh prune --caches) — this will NOT clear by waiting"
  else
    why="load gate: re-dispatched when 1-min load falls below MAX_LOAD"
  fi
  echo "[fix $PR] fixer NOT started ($why) — merge chain NOT re-run" >> "$L.log"
  refund_gate_attempt
  # Exit with the gate's OWN code, not a normalised 75: the caller (adopt-fix.sh, an operator) reads
  # it to choose the remedy, and 77 is the only thing that says "this one will not clear by waiting".
  exit "$ar"
fi
echo "[fix $PR] fixer done $(date) — re-running merge chain" >> "$L.log"
# Release BEFORE the merge chain. If the fixer pushed, merge-one.sh claims the NEW head. If it did
# NOT push, the SAME head is still claimed by us and merge-one.sh would refuse it as "another box
# owns head" — so the release is mandatory, not tidiness.
# ⛔ ONLY clear the latch when the release actually succeeded. A failed release (rc=1: fenced/torn
# push) must leave CROSS_OWN set so the EXIT trap (`trap 'release_fix_claim' EXIT`) retries it at
# process exit — otherwise the claim strands on the remote for the whole fixer lease
# (FIX_TIMEOUT+1200, up to ~1 h) and the controller, reading the live lease as data, stops
# re-dispatching that head. Same latch in merge-one.sh's claim block.
# The failure is also LOGGED (P3, second review round, 2026-10-14): a retained latch that leaves no
# trace is indistinguishable from a released claim to anyone reading the log afterwards.
if [ -n "${CROSS_OWN:-}" ]; then
  if release_fix_claim >/dev/null 2>&1; then
    CROSS_OWN=""
  else
    echo "[fix $PR] cross-box fixer claim: could not release ${CROSS_OWN:0:12} — the EXIT trap will retry" >> "$L.log"
  fi
fi
# re-run the full chain at the new head
# ⛔ RELEASE THE PR-OWNER LOCK FIRST, AND BEFORE THE CHAIN — not only at exit. `merge-one.sh` takes
# this SAME lock as its first act and, finding a live pid, exits 0 with "already owns this PR" — so
# keeping ours across the handoff would turn the fixer's own re-review into a silent no-op (the
# "fixer pushed, nothing re-recorded" strand #2132 removed). Releasing here is the same reason the
# cross-box claim above is released here: after a push the downstream worker claims the NEW head,
# and without a push the SAME head is still ours, so leaving it held would refuse our own re-review.
release_prlock
bash "$O/merge-one.sh" "$REPO" "$OR" "$PR" "$BR" >> "$L.log" 2>&1
echo "[fix $PR] end $(date)" >> "$L.log"
# ── and the fixer's `.venv` goes with it (agent-infra#1932) ─────────────────────────────────────────
# LAST, deliberately: the re-review above is dispatched from this same worktree, so reaping before it
# would make the reviewer re-sync. merge-one's reviewer has no venv of its own (it runs in the main
# checkout and its prompt says testing is unavailable to it), so nothing needs this env after this
# point. The reaper re-probes for a live holder first, so a lane still working in $WT keeps its env.
# Best-effort and loud: a failed reap logs, and never changes this worker's exit status.
reap_lane_venv "$WT" "fix $PR" >> "$L.log" 2>&1
