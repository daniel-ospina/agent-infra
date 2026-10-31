#!/usr/bin/env bash
# Runs ONE lane's pi inside its own worktree (cwd must already be the worktree).
#   lane.sh [--repo-dir <checkout>] [--repo <owner/name>] <issue> <branch> [<owner/name>]
#
# ⛔ THE TARGET REPO IS AN ARGUMENT, AND IT IS ASSERTED (agent-infra#2724/#2694). The positional
# `<owner/name>` is the legacy spelling; `--repo` and `--repo-dir` are the explicit ones. There is NO
# default: a lane with no target REFUSES (reason=no-target) rather than guessing from the brief.
# After the worktree exists (this cwd) the lane reads its OWN origin and checkout identity and
# refuses to start when they are not the target — a lattice of pre-build checks can only prove what
# was asked for. A refusal is exit 72 and is logged as one `[repo-target]` line naming the repo, the
# worktree and the result, so a wrong-repo lane is a grep rather than an investigation.
set -u
N=""; BR=""; OR=""; _or_pos=""; _lt_pos=0
LANE_REPO_DIR=""; LANE_REPO_SLUG=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --repo-dir)
      [ $# -ge 2 ] || { echo "[lane] refusing: --repo-dir needs a checkout path" >&2; exit 78; }
      LANE_REPO_DIR="$2"; shift 2 ;;
    --repo)
      [ $# -ge 2 ] || { echo "[lane] refusing: --repo needs an owner/name slug" >&2; exit 78; }
      LANE_REPO_SLUG="$2"; shift 2 ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        _lt_pos=$((_lt_pos + 1))
        [ "$_lt_pos" -le 3 ] || { echo "[lane] refusing: too many positional arguments (expected <issue> <branch> [<owner/name>])" >&2; exit 78; }
        case "$_lt_pos" in 1) N="$1" ;; 2) BR="$1" ;; 3) _or_pos="$1" ;; esac
        shift
      done ;;
    -*) echo "[lane] refusing unknown option: $1" >&2; exit 78 ;;
    *)
      _lt_pos=$((_lt_pos + 1))
      [ "$_lt_pos" -le 3 ] || { echo "[lane] refusing: too many positional arguments (expected <issue> <branch> [<owner/name>])" >&2; exit 78; }
      case "$_lt_pos" in 1) N="$1" ;; 2) BR="$1" ;; 3) _or_pos="$1" ;; esac
      shift ;;
  esac
done
# A flag and a positional that disagree are a contradiction in the dispatch itself — refuse rather
# than let one silently win.
if [ -n "$LANE_REPO_SLUG" ] && [ -n "$_or_pos" ] && [ "$LANE_REPO_SLUG" != "$_or_pos" ]; then
  echo "[lane] refusing: --repo '$LANE_REPO_SLUG' contradicts the positional target '$_or_pos'" >&2
  exit 72
fi
OR="${LANE_REPO_SLUG:-$_or_pos}"
# Validate the two values every artifact below is built from. lane.sh is also invoked by hand, and
# `$N=../../x` would build a path outside $O/state (the same reason its capacity record is screened).
case "${N:-}" in
  ''|*[!0-9]*) echo "[lane] refusing non-numeric issue id: ${N:-<empty>}" >&2; exit 78 ;;
esac
[ -n "${BR:-}" ] || { echo "[lane] refusing: no branch named" >&2; exit 78; }
# ⛔ EXPORTED, not just set: the SPAWN POINT (`pi` itself, agent-infra#1884) is a CHILD process, and a
# shell variable it cannot see makes its refusal say "untagged" about the very item it just refused.
# An operator reading "[pi-gate] REFUSED … item NOT started: <x>" must be able to name the lane.
KIND=lane; TAG="$N"; export KIND TAG
# `$O/state` joins `$O/logs`: the capacity-transfer ledger (agent-infra#1909) lives there.
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST (#1988). The line above prepends the tool dirs, so a REAL gh in
# either of them outranks the seeded `$O/gh-rest` (Mac REST adapter) / `$O/gh-limit` (cell
# serialiser) — and a shim that is never resolved is an INERT layer: it reports protection and
# provides none. Re-assert both here, adapter last so `$O/gh-rest` (which itself calls the same
# helper) wins where it exists. Guarded by `-d`, so a box that ships neither is unchanged.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
# The wall-clock limit AND the load gate both live in the shared helper, so this script has no
# `pi` invocation of its own to forget to gate (agent-infra#1720). Fail LOUD if the helper is
# missing: an unsourced helper would leave `run_agent` undefined, and an undefined helper must never
# degrade into "the agent ran" or "the review failed" — see README §9 on syncing $O.
# ⛔ SOURCED AFTER THE PATH EXPORT, not before it (a deliberate departure from the tortoise
# original): spawn-gate.sh derives `_NCPU` at SOURCE time via `sysctl`/`nproc`/`getconf`, so sourcing
# it under the pre-export PATH pins `_NCPU=4` and MAX_LOAD=40 for every cell — the exact #1702
# failure the portable probe exists to prevent.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/spawn-gate.sh" || { echo "[lane $N] FATAL: $SELF/spawn-gate.sh missing — refusing to start an ungated agent" >&2; exit 78; }
# ⛔ THE REPO-IDENTITY GATE (agent-infra#2724/#2694). Required, not optional: a lane that cannot
# prove which repository its worktree is has no business starting an agent in it. Missing helper =
# FATAL, because a silently skipped assertion is exactly the "nothing refuses" failure being fixed.
. "$SELF/repo-target.sh" || { echo "[lane $N] FATAL: $SELF/repo-target.sh missing (or its repo-slug.sh parser is) — refusing to start a lane whose repo cannot be asserted (#2724)" >&2; exit 78; }
# ⛔ NAME EVERY SYMBOL THIS FILE REACHES, TRANSITIVELY (#2762 review, 4th cycle, P2). The assert alone
# is not enough: `repo_target_head_branch` GATES the branch half (`if [ -n "$HEAD_BRANCH" ]`), so a
# module that has the assertions but not the head read made `HEAD_BRANCH` empty — the branch
# assertion was SKIPPED SILENTLY, the one direction in which this gate can be defeated (the `prfixup`
# shape this file exists to refuse). `repo_target_slug`/`repo_target_refuse` happen to fail closed;
# `head_branch` does not, so the guard has to be the whole set, not the two obvious ones.
command -v repo_target_assert >/dev/null 2>&1 && command -v repo_target_branch_assert >/dev/null 2>&1 \
  && command -v repo_target_head_branch >/dev/null 2>&1 && command -v repo_target_slug >/dev/null 2>&1 \
  && command -v repo_target_refuse >/dev/null 2>&1 && [ -n "${REPO_TARGET_REFUSED:-}" ] \
  || { echo "[lane $N] FATAL: $SELF/repo-target.sh is stale (needs repo_target_assert/repo_target_branch_assert/repo_target_head_branch/repo_target_slug/repo_target_refuse and REPO_TARGET_REFUSED) — refusing to start a lane whose repo cannot be asserted (#2724)" >&2; exit 78; }
# ── THE LANE'S OWN CREDENTIALS (agent-infra#3060) ───────────────────────────────────────────────────
# A lane started OUTSIDE the controller inherits no keys and dies in ~7 s with "No API key found for
# deepseek" — after passing every gate, because the capability gate sources the key file for its own probe
# call and therefore cannot see that the lane has none. The sourcing lives in lane-env.sh so it is testable
# without a worktree, a pi binary or a provider (lane-env.test.sh), and it is a TOP-LEVEL snippet on
# purpose: `. file` inside a function means something different (see that file's header for the three
# defects that produced from wrapping it). Fail LOUD if it is missing — an unsourced snippet would silently
# restore the 7-second death this exists to remove.
[ -r "$SELF/lane-env.sh" ] || { echo "[lane $N] FATAL: $SELF/lane-env.sh missing — refusing to start a lane whose credentials nothing sourced (#3060)" >&2; exit 78; }
LANE_ENV_LOG="$O/logs/lane-$N.log" LANE_ENV_LABEL="lane $N" . "$SELF/lane-env.sh"

# ── the reviewer requirement is disclosed BEFORE the work (#2148) ───────────────────────────────────
# The ≥1-dispatch rule and the merge-registry gate are correct and both spoke ONLY at the finish line
# (measured 2026-10-19: three lanes did the whole job, then were refused at the rail). A lane's gate is
# BYPASSED here (the parent enforces review), so nothing in the lane's own session ever says the
# requirement out loud — it is therefore printed here, once, before any work, AND carried into the
# generated brief below. Fail LOUD if the helper is missing: an unsourced helper would silently drop
# both halves, and a lane that never heard the requirement is the defect this exists to remove.
. "$SELF/reviewer-preflight.sh" || { echo "[lane $N] FATAL: $SELF/reviewer-preflight.sh missing — refusing to start a lane that is never told a reviewer is mandatory (#2148)" >&2; exit 78; }
# ── the RESEARCH contract is part of the brief, not the orchestrator's memory (#2258) ───────────────
# Measured twice in one day: a lane re-derived a root the tracker already held, and a lane opened a
# DUPLICATE PR (#2247 vs #2250). Both were brief defects. The block below is the ONE canonical text
# (`brief-gate.sh --section`), spliced into the generated brief, and the brief is then CHECKED with
# that same validator before the agent starts — so a heredoc regression that loses the block refuses
# the lane with exit 78 instead of dispatching a lane nobody asked to look first. Same discipline as
# #2148's reviewer section directly above, for the same reason: a requirement that lives only in the
# dispatcher's head is invisible to the lane.
brief_gate_sh="$(brief_gate_lib)" || {
  echo "[lane $N] FATAL: brief-gate.sh not found (looked in \$O, $SELF, \$AGENT_INFRA_PATH/scripts/orchestrator-harness, ~/.pi/agent/scripts) — refusing to start a lane whose brief nothing validated (#2258)" >&2; exit 78; }
RESEARCH_BRIEF="$(bash "$brief_gate_sh" --section lane)" || {
  echo "[lane $N] FATAL: brief-gate.sh --section failed — refusing to start a lane whose brief omits the research contract (#2258)" >&2; exit 78; }
RESEARCH_PREFLIGHT="$(bash "$brief_gate_sh" --line lane)"
printf '%s\n' "$RESEARCH_PREFLIGHT" | tee -a "$O/logs/lane-$N.log"
# ── the lane's own `.venv` is reaped on the way out (agent-infra#1932) ──────────────────────────────
# A venv is a build artifact that belongs to a RUNNING lane: `uv sync` writes it inside the worktree,
# and nothing removed it, so 5 lanes held 7.3 GB (~4 lanes, not 6, on a 32 GB box). The EXIT trap is
# the right place because at lane exit the lane is KNOWN to be done — no liveness has to be inferred —
# and it covers EVERY exit path, including a TERM'd session (bash runs EXIT traps on SIGTERM: verified).
# The reaper still re-probes for a live holder before deleting, so a worktree another lane is using,
# or a `pi`/pytest child still running after the agent returned, keeps its env. Best-effort and loud:
# `reap_lane_venv` never changes the lane's exit status, and logs every outcome to the lane log.
#
# ── and the WORKTREE + BRANCH go with it when the lane produced nothing (agent-infra#2033) ────────
# This is the other half of the same trap, and it is the half that keeps the ISSUE dispatchable. A
# lane that exits with no commit, no push and a clean tree leaves a branch that is 0 commits ahead of
# origin/main — and the collision pre-flight infers "in flight" from exactly that branch, so a free
# issue becomes permanently undispatchable on every box (measured: #8090, `feat/8090-tm`, 0 ahead).
# `wt_reap_if_empty` refuses on anything that could be work (commits ahead, a pushed branch, a dirty
# tree, a live holder, an unevaluable probe), and a dirty tree is deliberately NOT reaped here: the
# backup-then-remove policy (`reaped-patches`) belongs to the reaper, not to the dying lane.
# `SELF` is the ONE from above (the harness/$O directory that also holds spawn-gate.sh) — a second
# declaration here would be harmless today and a trap the day one of them changes.
# shellcheck source=/dev/null
. "$SELF/wt-lifecycle.sh" || { echo "[lane $N] FATAL: $SELF/wt-lifecycle.sh missing — refusing to run a lane whose empty worktree could never be reclaimed (#2033)" >&2; exit 78; }
LANE_WT="$PWD"
lane_exit_cleanup() {
  [ -n "${LANE_WT:-}" ] || return 0
  reap_lane_venv "$LANE_WT" "lane $N"
  local repo
  repo="$(cd "$LANE_WT" 2>/dev/null && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || repo=""
  case "$repo" in */.git) repo="${repo%/.git}" ;; esac
  [ -n "$repo" ] || return 0
  wt_reap_if_empty "$repo" "$LANE_WT" "$BR" "lane $N" || true
  echo "[lane $N] worktree: $WT_RESULT" >> "$O/logs/lane-$N.log" 2>/dev/null || true
  return 0
}
# ⛔ THE SIGNAL TRAPS ARE LOAD-BEARING, NOT TIDINESS (measured on /bin/bash 3.2.57, 2026-10-18): a
# shell killed by SIGHUP with only an EXIT trap installed does NOT run that trap. `tmux kill-session`
# — which `dispatch-merge.sh` uses on its no-chain path, and which an operator uses by hand — delivers
# SIGHUP, so the cleanup has to be reached by an explicit handler that `exit`s. Each handler clears
# the traps on entry so the `exit` cannot re-enter it (one cleanup, one exit, status matched to the
# signal).
trap 'trap - EXIT INT TERM HUP; lane_exit_cleanup; exit 143' TERM
trap 'trap - EXIT INT TERM HUP; lane_exit_cleanup; exit 130' INT
trap 'trap - EXIT INT TERM HUP; lane_exit_cleanup; exit 129' HUP
trap 'lane_exit_cleanup' EXIT
# ⛔ ...but NOT on a DRY RUN (agent-infra#2148's `LANE_DRY_RUN` seam, below). No agent ran, so the
# worktree's `.venv` has no dead holder to reap — and a preview that DELETES a build artifact is
# exactly the destructive-side-effect class a dry run exists to avoid. The trap is installed
# conditionally because it is installed before the dry-run branch is reached.
# ⛔ AND IT CLEARS *ALL FOUR* TRAPS, not just EXIT: `lane_exit_cleanup` is now also reached by the
# signal handlers, so leaving THOSE armed would let a Ctrl-C in a dry run run the very cleanup the
# guard is disabling.
if [ "${LANE_DRY_RUN:-0}" = "1" ]; then
  trap - EXIT INT TERM HUP
fi
# ── THE GATE DECISION IS MEASURED, NOT ASSUMED (agent-infra#2319)
# This line used to export `AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1` UNCONDITIONALLY — a permanent
# bypass the canon calls emergency-only, on the one machine that lands the most work. The decision is
# now made by `gate-policy.sh`, which probes whether the lane path can SATISFY both gates and — when it
# cannot — records an audited line naming #2319 and the missing component. When the satisfier lands the
# export disappears by itself, with no second change and no forgotten flip.
. "$SELF/gate-policy.sh" 2>/dev/null || { echo "[lane $N] FATAL: $SELF/gate-policy.sh missing — refusing to start a carrier that cannot say whether its gates are on" >&2; exit 78; }
# ⛔ A DRY RUN WRITES NOTHING TO STDERR (it runs no agent, so a warning about a worker that never
# started is noise an operator would learn to ignore — `reviewer-preflight.test.sh` asserts this). The
# DECISION is still recorded; only the human-facing line is suppressed.
[ "${LANE_DRY_RUN:-0}" = "1" ] && export GP_QUIET=1
apply_gate_policy lane
# ⛔ A DIFFERENT HATCH, DELIBERATELY UNTOUCHED: main-edits is a declared escape for writing to a main
# checkout, not a review bypass, and #2319 does not rule on it.
export AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none   # headless lanes use no MCP servers — saves ~25 processes/run
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
echo "[lane $N] cwd=$(pwd) branch=$(repo_target_head_branch "$PWD") $(date)" >> "$O/logs/lane-$N.log"
# ── THE POST-BUILD ASSERTION, BEFORE ANY LANE ARTIFACT (agent-infra#2724/#2694) ─────────────────
# The worktree exists (it is cwd). Read WHAT IT IS and refuse when it is not the target. The line is
# written to the lane log AND echoed, so it is the one grep that answers "which repo did this lane
# run in, and did anything check?". A valid target is mandatory: an absent one is a REFUSAL, not a
# default (#1974: a shipped default is a path two programs invented).
REPO_ASSERT_LINE="$(repo_target_assert "lane $N" "$PWD" "$OR" "$LANE_REPO_DIR")"; REPO_ASSERT_RC=$?
printf '%s\n' "$REPO_ASSERT_LINE" | tee -a "$O/logs/lane-$N.log"
if [ "$REPO_ASSERT_RC" -ne 0 ]; then
  echo "[lane $N] NOT started: repo-target REFUSED (exit $REPO_ASSERT_RC) — no agent, no PR, nothing measured in the wrong repository" >> "$O/logs/lane-$N.log"
  exit "$REPO_ASSERT_RC"
fi
# ⛔ A `--repo-dir`-ONLY CALL MUST NOT LEAVE `$OR` EMPTY (#2762 review, P1). The module supports
# naming ONLY a directory, and it derives the target slug internally — but `$OR` is what the brief's
# `gh issue view … --repo $OR` and the branch assertion use. Left empty, the lane STARTS and writes a
# brief whose `--repo` argument is empty: `gh` then falls back to ambient `GH_REPO` (the #2235
# wrong-repo fail-open this change exists to close) or errors. The dir assertion has just PROVED this
# worktree is the target, so deriving the slug from it is not a guess; if it still cannot be read,
# refuse rather than start.
if [ -z "$OR" ]; then
  OR="$(repo_target_slug "$PWD" 2>/dev/null || true)"
  if [ -z "$OR" ]; then
    echo "$(repo_target_refuse "lane $N" target-underivable "the target directory passed the assertion but its origin slug cannot be read, so the lane has no repo to name in its brief or its gh calls")" | tee -a "$O/logs/lane-$N.log"
    echo "[lane $N] NOT started: no target slug could be derived from the asserted worktree" >> "$O/logs/lane-$N.log"
    exit "$REPO_TARGET_REFUSED"
  fi
fi
# The branch half: a worktree of the right repo checked out on a DIFFERENT named branch is the
# `prfixup` shape. A DETACHED HEAD is deliberately allowed — the cell template creates `worktree add
# --detach` and the lane creates its branch at push time — so the branch assertion applies only when
# HEAD is attached to a named branch.
HEAD_BRANCH="$(repo_target_head_branch "$PWD")"
if [ -n "${BR:-}" ] && [ -n "$HEAD_BRANCH" ]; then
  BRANCH_ASSERT_LINE="$(repo_target_branch_assert "lane $N" "$PWD" "$BR" "$OR")"; BRANCH_ASSERT_RC=$?
  printf '%s\n' "$BRANCH_ASSERT_LINE" | tee -a "$O/logs/lane-$N.log"
  if [ "$BRANCH_ASSERT_RC" -ne 0 ]; then
    echo "[lane $N] NOT started: branch assertion REFUSED (exit $BRANCH_ASSERT_RC) — no agent started" >> "$O/logs/lane-$N.log"
    exit "$BRANCH_ASSERT_RC"
  fi
fi
# ONCE, up front, and to BOTH surfaces: the lane log (what an operator greps) and the lane's own
# stdout (what the controller reads). The brief carries the long form; this is the one-line reminder
# that the requirement exists at all, so no lane can discover it only by being refused at the rail.
REVIEWER_PREFLIGHT="$(reviewer_preflight_line harness)" || {
  echo "[lane $N] FATAL: reviewer_preflight_line failed — refusing to start a lane with no disclosure" >&2; exit 78; }
printf '%s\n' "$REVIEWER_PREFLIGHT" | tee -a "$O/logs/lane-$N.log"
# The brief's reviewer section, rendered ONCE here and spliced into the heredoc as a VARIABLE.
# ⛔ NOT a `$(...)` inside the heredoc: the heredoc is UNQUOTED, so a command substitution in it runs
# at prompt-build time — and selftest.sh's unescaped-backtick rig exists precisely because that bug
# class silently erases prompt text (agent-infra#1835). Precomputing keeps the expansion inert.
REVIEWER_BRIEF="$(reviewer_brief_section harness)" || {
  echo "[lane $N] FATAL: reviewer_brief_section failed — refusing to start a lane whose brief omits the reviewer step" >&2; exit 78; }
# ── the LANDING ARTIFACTS, disclosed for the same reason (#2325) ──────────────────────────────────
# `pipeline-compliance` blocked 36 of 40 open agent-infra PRs and the count GREW faster than lanes
# could be rescued (33 → 36 in one hour). The brief told a lane to READ the pipeline skills and
# never to PRODUCE what they exist to create, so each lane finished real work, opened a PR, and was
# refused — with its evidence retro-fitted afterwards. Same treatment as the reviewer step above:
# rendered ONCE, spliced as a VARIABLE (never a `$(...)` inside the unquoted heredoc — #1835), and
# FAIL LOUD if the helper cannot render it, because a brief that silently drops it is the defect.
LANDING_BRIEF="$(landing_artifacts_brief_section harness)" || {
  echo "[lane $N] FATAL: landing_artifacts_brief_section failed — refusing to start a lane whose brief omits the landing artifacts" >&2; exit 78; }
# ── COMMIT AS YOU GO, disclosed for the same reason (#2981) ──────────────────────────────────────
# Five `prfix` lanes were killed at their caps with ZERO commits and 144 KB of work that reached no
# PR, because every one of them held its single commit for the end and the end was a `kill -TERM`.
# This brief already stated the research contract, the reviewer step and the landing artifacts; the
# cheapest rule of all was missing. Same treatment as the two sections above: rendered ONCE, spliced
# as a VARIABLE (never a `$(...)` inside the unquoted heredoc — #1835), FAIL LOUD if the helper
# cannot render it, and CHECKED at build time below — a brief that silently drops it is the defect.
DELIVERY_BRIEF="$(delivery_brief_section lane)" || {
  echo "[lane $N] FATAL: delivery_brief_section failed — refusing to start a lane whose brief never tells it to commit as it goes (#2981)" >&2; exit 78; }
# ⛔ AN EMPTY RENDER IS A FAILED RENDER. The section is spliced below as a variable, so a helper that
# returns nothing would insert a blank line and every other assertion would stay green.
[ -n "$DELIVERY_BRIEF" ] || {
  echo "[lane $N] FATAL: delivery_brief_section rendered NOTHING — refusing to start a lane whose brief never tells it to commit as it goes (#2981)" >&2; exit 78; }

# ⛔ agent-infra-SPECIFIC, and NOT in the tortoise original: the NO-SEARCH bound in the test line
# below. A lane's worktree normally HAS a `.venv`, but when it does not the agent used to hunt for an
# interpreter across the filesystem — a `find` over $HOME blocks for minutes and has consumed whole
# agent budgets with nothing produced. Point it at `uv sync` instead. Do NOT drop it in a re-port.
# ⛔ THE BRIEF NAMES A COMMAND, SO IT MUST NAME ONE THAT EXISTS ON THIS BOX (A12). install.sh never
# copies — `$O` is synced by the operator — so on a cell that has not been re-synced `$O/lane-merge.sh`
# is absent while the shipped copy sits beside this script. Emitting the `$O` path unconditionally
# would tell the lane "use it, do not hand-roll a polling loop" and then hand it nothing (the lane's
# only remaining options are an invented loop or a handoff). Resolve once, here, and say so in the log.
LANE_MERGE_CMD="$O/lane-merge.sh"
# Always set (the brief interpolates it): empty means "the tool exists, say nothing extra".
MERGE_LOOP_NOTE=""
if [ ! -f "$LANE_MERGE_CMD" ]; then
  # ⛔ THE FALLBACK IS ONLY A FALLBACK IF IT IS A DIFFERENT PATH (reviewer finding, P2, verified). When
  # this script was itself loaded FROM `$O` (the shipped `dispatch-merge.sh` route) `$SELF == $O`, so
  # the "fallback" resolves to the very file that is missing: the log claimed a substitute was named
  # while the brief pointed at nothing. Say nothing rather than something false, and name the remedy.
  if [ "$SELF/lane-merge.sh" != "$LANE_MERGE_CMD" ] && [ -f "$SELF/lane-merge.sh" ]; then
    LANE_MERGE_CMD="$SELF/lane-merge.sh"
    echo "[lane $N] ⚠️ $O/lane-merge.sh is absent (this \$O predates the lane-owns-merge change) — the brief names $LANE_MERGE_CMD instead. Redeploy: bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o $O/" >> "$O/logs/lane-$N.log"
  else
    # ⛔ THE BRIEF MUST SAY WHAT THIS LINE SAYS (landing-review finding 2): the merge-loop section below is
    # rendered from $MERGE_LOOP_NOTE, so this arm now really does tell the lane the tool is missing and
    # what to do instead — previously the log promised that and the brief named a path that did not exist
    # (exit 127, unmapped by the brief's own exit-code table).
    MERGE_LOOP_NOTE="⛔ THE MERGE LOOP IS NOT INSTALLED ON THIS BOX ($LANE_MERGE_CMD does not exist). Do NOT hand-roll a polling loop: if you cannot reach \`merged\`, report the exact blocker as a hand-off comment per **Handoff** below and stop. An operator can install it from the agent-infra checkout (NOT from this lane worktree) with: \`bash scripts/orchestrator-harness/deploy-harness.sh --repo <agent-infra> --o $O\`"
    echo "[lane $N] ⛔ $O/lane-merge.sh is ABSENT and this harness was loaded FROM $SELF — there is no other copy to name. The brief now says so and tells the lane to hand off instead of running a missing path; redeploy first FROM THE agent-infra CHECKOUT (not this lane worktree) with bash scripts/orchestrator-harness/deploy-harness.sh --repo <agent-infra> --o $O/" >> "$O/logs/lane-$N.log"
  fi
fi
cat > "$O/logs/prompt-$N.txt" <<EOF
Autonomous engineering lane. You are ALREADY inside your own worktree (that is your cwd, on branch \`$BR\`). Do NOT create, switch, or remove worktrees, and NEVER touch the repo's main checkout.

## Your issue
**#$N** — read it IN FULL including every comment (root-cause corrections live there):
    gh issue view $N --repo $OR --json title,body,labels
    gh issue view $N --repo $OR --comments --json comments --jq '.comments[].body'
The comment thread supersedes the body where they disagree. Several issues here are labelled provenance-stale — RE-MEASURE before trusting the body.

## Setup (you are already in the worktree)
    uv sync --extra embeddings --extra parity        # tortoise: installs the canonical dev env
Tests: \`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest <paths> -q -p no:cacheprovider\`  (NEVER bare \`uv run\` — it strips the extras). If \`.venv\` is missing in YOUR worktree, run \`uv sync --extra embeddings --extra parity\` once — ⛔ never search the filesystem for an interpreter (no \`find\`/\`rg\`/\`du\` outside this worktree: a \`find\` under \`$HOME\` blocks for many minutes and has consumed whole agent budgets, producing no result).

## ⛔ ACCEPTANCE CRITERIA — the PR is not the finish line
**You are done when your PR is MERGED, or when you report the one thing that blocks the merge that nobody
else can supply.** A lane that stops at "PR opened" has NOT finished: the fleet measured 22 open PRs against
3 merged, because every lane treated the opened PR as success and left the merge work behind 16 running lanes.
So after the PR exists you must:
  1. drive YOUR OWN checks to terminal and fix what is red (lint, tests, a committed conflict marker);
  2. keep the PR mergeable — if it goes DIRTY, re-apply your own change onto current main and force-push
     YOUR branch (see Conflicts below);
  3. take it to the repo's merge path and stay until it is merged. Do not ask the parent to do the fixing
     you can do here.

## The merge loop is a TOOL, not an instruction — use it
${MERGE_LOOP_NOTE:+$MERGE_LOOP_NOTE
}
    bash $LANE_MERGE_CMD <PR> --issue $N --repo $OR --branch $BR
It is bounded BY CODE (3 fix rounds, then it refuses); do not hand-roll a polling loop and do not run
\`gh pr merge\` yourself. Its exit code IS your next action:
    0  MERGED              done — report the merge sha
    10 FIX_REQUIRED        the printed check names are red — fix, commit, push, run the tool again
    15 FIX_CONFLICT        PR is dirty — see Conflicts below, force-push, run again
    11 WAITING             the harness's merge chain owns the PR now; call
                           \`bash $LANE_MERGE_CMD <PR> --watch --issue $N --repo $OR\` (a bounded chunk —
                           repeat it). It is DETACHED on purpose, so it keeps running even if your wall
                           clock ends. ⛔ READ the printed line before repeating: a chunk that says the
                           PR head MOVED past the chain's head means run the loop again, not --watch.
    12 BLOCKED_ATTESTATION green and mergeable, but there is no signed review at this head and you may
                           not mint one — hand off (this is the one thing only a fresh reviewer supplies)
    13/14 BLOCKED_*        stop fixing and HAND OFF (see Handoff below)
The merge itself is \`$O/merge-one.sh\`, the harness's one per-PR chain: it resolves the repo's own merge
authority (a rail repo merges through its rail; a gate repo dispatches a FRESH-CONTEXT reviewer, records the
verdict, and only then merges). ⛔ **NEVER call \`record-review.sh\` yourself and never post a review verdict of
your own** — a lane attesting to its own review is a review that did not happen, and it is the one thing the
chain exists to make impossible.

## Conflicts
If the PR is DIRTY, re-apply YOUR OWN change onto current main (\`git fetch origin main\`, then rebase or
merge origin/main onto your branch), resolve conflicts keeping both sides' intent, re-run your tests, and
force-push YOUR OWN branch (\`git push --force-with-lease origin $BR\`). ⛔ **Never resolve a conflict in a
GENERATED file by picking a side** — regenerate it with its own generator (lockfile, snapshot, manifest, codegen).
Never force-push anyone else's branch, and never touch the repo's main checkout.

## Attestation — read this BEFORE you touch the PR body
Once a review has been recorded at your head, **any PR body edit WIPES the attestation the gate reads** (that
exact failure has happened twice on real PRs). So: write the body ONCE, before the merge loop starts; after
that, do not edit it. Put new information in a **comment**, never in the body. And never re-record a review
to "refresh" it.

## Handoff — a diagnosis, not a mystery
If you cannot merge, the exact blocking reason MUST be on the PR as a comment. \`lane-merge.sh\` posts it for
the terminal BLOCKED_* exits; for any other handoff you write it yourself:
    gh pr comment <PR> --repo $OR --body "<the exact blocker: the check name + its failure, the conflict, the missing precondition, and what you already tried>"
Then report it. "Blocked" with no reason forces the next lane to re-derive everything you learned.

## Rules
- The review/VGATE extensions are BYPASSED for you and you have NO "task" tool — do NOT dispatch. The PARENT runs the review gate (that is the chain in the merge loop above, not you).
- Commit with \`git commit -F <message-file>\` (repo-unique temp path per AGENTS.md "Editing Rules"). Stage specific files; never \`git add -A\`.
- Push (\`git push -u origin $BR\`), then open a PR against main: title "<type>(<scope>): <subject> (#$N)". The body MUST carry "Closes #$N" ON ITS OWN LINE — check [a] reads the LINE position, so a mid-sentence "(fixes #$N)" does not count. ⛔ Do NOT reach for "Refs #$N" on work you have finished: GitHub never closes an issue from a \`Refs\`, and NOTHING in this fleet re-reads an open issue whose PR merged — measured 2026-10-13, 25 of 36 open P0-blockers already had MERGED PRs on main while 48 PRs merged in one day and 0 blockers closed (#8468). Use "Refs #$N" ONLY when a specific acceptance indicator is genuinely unmet, and then name it on its own line as \`Still open: <indicator>\` — a bare \`Refs\` is a lane failing to take a position, not a partial delivery. Include what changed and exact test evidence.
- Do NOT change the MCP tool registry or the public TortoiseSDK surface (needs owner approval — STOP and report instead).
- REMEMBER what load is: 22 landers share one rate-limited GitHub account. Read the PR once per loop turn, use \`lane-merge.sh\` (REST + local state), and never poll in a tight loop.
- Read skills/issue-workflow/SKILL.md and skills/issue-scoping/SKILL.md first.
- If the defect is already fixed (in-repo or elsewhere) report ALREADY_FIXED / OUT-OF-REPO with file/line/commit evidence instead of forcing a PR. A no-change verdict with evidence is a good outcome.
- **If you add a test file, you MUST register it in \`config/ci-surfaces.yml\`** — an unregistered file is never selected on the relevant source diff and the unconditional \`manifest-integrity\` leg fails. Verify with \`python tools/ci_selection.py --integrity\`.
- Use the research skill for non-trivial research; never call web_search directly. Auto-file any pre-existing bug with no open issue. Never ask the human anything.
- Collision pre-flight is CLEAN for this issue.

$RESEARCH_BRIEF

$DELIVERY_BRIEF

$LANDING_BRIEF

$REVIEWER_BRIEF

## Deliverable (final message, <=25 lines)
issue #, status (**MERGED | BLOCKED_ATTESTATION | BLOCKED_ATTEMPTS | BLOCKED | ALREADY_FIXED | OUT-OF-REPO**),
branch + PR URL, the MERGE SHA when merged, files changed, exact test commands + pass/fail counts, and — if
not merged — the single blocking reason and the PR comment URL where you recorded it. Write the status token
EXACTLY as one of those words on its own line: the fleet's merge-rate instrument reads this line, and a lane
that ends "PR_OPENED" is counted as unfinished.
EOF
# ── THE GENERATED BRIEF IS CHECKED AT BUILD TIME (#2258) ───────────────────────────────────────
# Before the dry-run seam and before any capacity bookkeeping. `LANE_DRY_RUN=1` then proves the brief
# a lane would ACTUALLY receive (the #2148 suite drives that seam), and a heredoc regression that
# drops the research block refuses at BUILD time instead of being discovered by the gate inside
# `run_agent` minutes later. When this fires the author is not at fault — the brief is GENERATED
# here — so it is 78 (cannot run), never 80 (brief refused).
bash "$brief_gate_sh" --check "$O/logs/prompt-$N.txt" lane 2>>"$O/logs/lane-$N.log" || {
  echo "[lane $N] FATAL: the GENERATED brief fails brief-gate.sh — refusing to start a lane whose brief lost its research contract (a harness defect in the heredoc above, NOT a brief-authoring error) (#2258)" >&2
  exit 78
}
# ⛔ AND THE DELIVERY CONTRACT IS CHECKED HERE TOO (#2981). `brief-gate.sh` validates the RESEARCH
# contract only; a heredoc edit that drops this section would leave every other assertion green — the
# exact invisibility that cost 144 KB. Cheap, build-time, and it refuses BEFORE a lane is started.
# ⛔ THE `-n` IS PART OF THE GUARD, NOT DECORATION: `grep -F ""` matches EVERY line, so an emptied
# heading constant would make this check INERT while it still read as protection (a no-op gate).
[ -n "$DELIVERY_BRIEF_HEADING" ] && grep -qF -- "$DELIVERY_BRIEF_HEADING" "$O/logs/prompt-$N.txt" || {
  echo "[lane $N] FATAL: the GENERATED brief lost its COMMIT-AS-YOU-GO section — refusing to start a lane that would hold its work to the cap (a harness defect in the heredoc above) (#2981)" >&2
  exit 78
}
# ── CAPACITY TRANSFER: make the refusal a DURABLE, READABLE record (agent-infra#1909) ──────
# R8: "when a machine refuses an item for capacity, the item remains eligible for another
# machine." The refusal itself is fine and stays (R1); what made it fleet-wide idleness was that
# NOTHING downstream could tell a refused lane from a working one. Two consequences followed, and
# both are what `state/capacity-refused-<N>` now lets the rest of the harness fix:
#
#   • `chain-merge.sh` waited the full 90 minutes for a PR that could never appear, holding the
#     cross-box claim `refs/claims/issue-<N>` the whole time. Every peer's pre-flight reads a live
#     claim as COLLISION, so ONE box's load spike made the issue ineligible on ALL FIVE boxes for
#     90 min. Reading this record, the chain exits at once and its EXIT trap releases the claim.
#   • nothing stopped THIS box from re-winning the claim the next cycle and being refused again,
#     which starves the peers it just yielded to. The second field is the yield, read by
#     `orch-loop.sh`'s `capacity_yield_live()`.
#
# FORMAT — one line, three tab-separated fields, and the field ORDER is the contract with both
# readers: `<refused_epoch>\t<yield_until>\t<gate>`, `gate` one of `load`, `disk` or `land`.
# (`land` is the CREATION back-pressure refusal, agent-infra#2409 — see run_agent in spawn-gate.sh.
# It is written by the same line and read by the same two readers; chain-merge.sh maps it to exit 74
# and says in its own words that it is NOT a capacity transfer, because no peer box can clear a
# repo-wide backlog.) The epoch is
# what makes the record PER-DISPATCH: a chain compares it against its own start time, so a record
# left by an earlier run of the same issue can never make a live lane's chain exit early.
# ⛔ The gate is named, not implied, for the reason lane.sh's own reporting line below spells out: a
# load refusal clears when the box quietens, a disk refusal never does.
CAPACITY_YIELD_SECS="${CAPACITY_YIELD_SECS:-900}"
# Clamped with the shared `is_limit` (digits, at most nine) rather than a local predicate, so a
# typo cannot mint an unreadable record — and bounded at 24h because a larger yield is not a
# transfer but a permanent stand-down of this box: `0` is REFUSED rather than honoured, since a
# zero-length yield would silently restore the defect R8 exists to remove while looking configured.
if ! is_limit "${CAPACITY_YIELD_SECS:-}" || [ "${CAPACITY_YIELD_SECS:-0}" -lt 1 ] || [ "${CAPACITY_YIELD_SECS:-0}" -gt 86400 ]; then
  echo "[lane $N] WARN: CAPACITY_YIELD_SECS='${CAPACITY_YIELD_SECS:-}' is not a whole number of seconds in 1..86400 — using 900" >> "$O/logs/lane-$N.log"
  CAPACITY_YIELD_SECS=900
fi
# A path is built from $N, so it is validated HERE even though dispatch-merge.sh already refuses a
# non-numeric id: lane.sh is also invoked by hand, and `$N=../../x` would write outside $O/state.
case "${N:-}" in ''|*[!0-9]*) capacity_record= ;; *) capacity_record="$O/state/capacity-refused-$N" ;; esac
# LANE_DRY_RUN=1 stops HERE, after every artifact the lane would be given exists. It is the seam
# the #2148 regression test drives: the pre-flight line and the generated brief are asserted from the
# real artifacts a lane receives, not from a grep of this file's source (a source-shape assertion
# passes on a script whose runtime output lost the text — the "test that cannot fail" class).
if [ "${LANE_DRY_RUN:-0}" = "1" ]; then
  echo "[lane $N] DRY RUN — prompt written to $O/logs/prompt-$N.txt; no agent started" | tee -a "$O/logs/lane-$N.log"
  exit 0
fi
# ⛔ THE WALL LIMIT GREW BECAUSE THE JOB DID (3300s, was 2400s). A lane now owns its merge: after the
# PR exists it waits for its own checks, fixes them, and supervises the merge chain — a merge phase that
# queues behind 24-minute CI. At 2400s the kill would land mid-merge on a lane that had done nothing
# wrong, and the lane log would end with no MERGED line even on a PR that merges (the chain is detached,
# so the merge itself still completes — which is exactly why the missing line would be silent). The
# bound is still a bound, and LANE_TIMEOUT overrides it as before.
run_agent "${LANE_TIMEOUT:-3300}" "$O/logs/lane-$N.log" "$O/logs/prompt-$N.txt" "lane $N"
# Capture the status BEFORE anything else runs: `echo "… $?"` after another command reports that
# command's status, not the agent's (the defect §7.4 records for retired/do-merge.sh).
rc=$?
echo "[lane $N] exited $rc $(date)" >> "$O/logs/lane-$N.log"
# ⛔ A LANE THAT ENDS WITHOUT A MERGE-PHASE VERDICT IS A RECORDED FAILURE, NOT SILENCE (#2029).
# The merge phase is the lane's own job now, so its absence is the exact defect this change targets —
# and the only place it is visible is here. `merge-rate.sh` counts such a lane as UNKNOWN (it reads
# the log's last status token), so the line below is what lets an operator see WHY a lane is UNKNOWN
# without re-reading a 25-minute transcript. It never changes the exit status.
# ⛔ GATE ON "THIS LANE OPENED A PR" (E5). The bare verdict test fired for every lane that
# legitimately never reached a PR — ALREADY_FIXED and OUT-OF-REPO are documented GOOD outcomes in the
# same brief — and told the operator merge-rate would count them as UNKNOWN, which is false: its
# classifier includes both tokens, so they land in `other`, never `unknown`. An instrument that alarms
# on the healthy path and misstates its own measurement teaches the next reader to ignore it.
if grep -qE 'github\.com/[^ ]+/pull/[0-9]+|(^|[^A-Z_])PR_OPENED([^A-Z_]|$)' "$O/logs/lane-$N.log" 2>/dev/null \
   && [ ! -s "$O/state/lanemerge-issue-$N.verdict" ]; then
  echo "[lane $N] ⚠️ NO merge-phase verdict (state/lanemerge-issue-$N.verdict absent) — the lane ended without either reaching merged or naming a blocker; merge-rate.sh will count it as PR_OPENED (or UNKNOWN if the log carries no status token), never as MERGED." >> "$O/logs/lane-$N.log"
fi
# A gate refusal reports AGENT_FORK_REFUSED (73), AGENT_LOAD_REFUSED (75), AGENT_LAND_BACKLOG (74),
# AGENT_BRIEF_REFUSED (80), AGENT_CAPABILITY_REFUSED (71)
# or AGENT_DISK_REFUSED (77);
# AGENT_STARTED is authoritative rather than the exit code, because `pi` shares the 0–255 status
# namespace and could exit 75 itself (#1720).
if [ "$AGENT_STARTED" = "0" ]; then
  # No agent ran and no PR was opened. The issue is not stranded: refresh-candidates.sh
  # un-blacklists a dispatched issue that has neither a PR nor a live lane session, so it returns
  # to the pool.
  #
  # ⛔ AND THE REFUSAL IS RECORDED, so "returns to the pool" is not merely claimed here — see the
  # CAPACITY TRANSFER block above for the format and its two readers. `fork`, `load`, `disk`,
  # `capability` and `land` are the five values the gate can refuse on, and each is chosen by the code
  # its own caller already distinguishes, so the record can never disagree with the exit status.
  # ⛔ THE BRIEF REFUSAL IS NOT A CAPACITY REFUSAL, AND SAYING SO IS THE WHOLE POINT (#2258). A
  # capacity refusal clears (load) or clears when the volume is reclaimed (disk), and both travel
  # with the BOX — so `capacity-refused-<N>` correctly yields the item to a peer, and
  # refresh-candidates.sh correctly returns it to the pool. A BRIEF refusal has neither property: it
  # is a property of the brief, it never clears by waiting or reclaiming, and re-dispatching the item
  # to another machine refuses there too. Recording it as `gate=load` would tell the whole fleet a
  # remedy that cannot arrive and would hide the one writer who CAN fix it. So: NO capacity record,
  # a loud line on both surfaces, and the item is NOT yielded — it stays this box's to re-author.
  # ⛔ AND IT IS DECIDED FIRST, ABOVE the capacity record, because that block's `else` is `load`:
  # falling through to it would mint the very capacity record this arm exists to prevent.
  if [ "$rc" = "${AGENT_BRIEF_REFUSED:-80}" ]; then
    echo "[lane $N] NOT started: THE BRIEF WAS REFUSED (brief gate, exit $rc) — no agent ran, nothing was consumed, and this is NOT a capacity refusal, so the issue is NOT yielded to a peer: re-author the brief (the [brief-gate] block above names every missing element and prints the canonical section), then re-dispatch." >> "$O/logs/lane-$N.log"
    echo "[lane $N] brief refused — see $O/logs/lane-$N.log; re-author and re-dispatch (not a capacity refusal)" >&2
    exit "$rc"
  fi
  if [ -n "${capacity_record:-}" ]; then
    # ⛔ FORK IS CONSUMED, NOT BUCKETED AS LOAD (review P1, agent-infra#2293). `run_agent` returns
    # AGENT_FORK_REFUSED for a box that is out of PROCESSES, and this branch used to fold every code
    # except disk into `load` — publishing the remedy "re-dispatched when 1-min load falls" for a box
    # that cannot even spawn the retry, which is exactly the rule spawn-gate.sh states at its own fork
    # code ("a caller that reads a fork refusal as a load refusal retries forever on a box that cannot
    # start a process to retry with"). The tolerant defaults keep an `$O/spawn-gate.sh` predating either
    # code — which can never return it — routing exactly as it did.
    # ⛔ FORK IS 73, NOT 74 (#2293 x #2409): 74 is the LAND-BACKLOG gate below, whose remedy is the
    # opposite of a fork refusal's, so one code for both made this very case statement label one gate
    # with the other's remedy (the integration batch's review caught it as a P0).
    # ⛔ CAPABILITY IS ITS OWN VALUE (review of #2991, P1), AND IT IS THE ONE THAT PROVES THE RULE: a
    # fifth refusal code was added to `spawn-gate.sh` with no reader anywhere, so a box that cannot
    # complete one call and RETURN published `gate=load` and the reason "issue returns to the queue" —
    # the line below the correct `[capability-gate] REFUSED` one. Waiting never clears it.
    # ⛔ IT STILL MINTS A CAPACITY RECORD, unlike the brief refusal above, and the difference is not an
    # oversight: a brief refusal follows the ITEM to any box, while a capability refusal is a property
    # of THIS box, so yielding the issue to a peer is exactly the right remedy (the brief-refusal
    # argument, read in the other direction). Tolerant default for the same $O-skew reason as the rest:
    # a helper predating the code can never return it.
    if [ "$rc" = "${AGENT_FORK_REFUSED:-73}" ]; then _cap_gate=fork
    elif [ "$rc" = "${AGENT_DISK_REFUSED:-77}" ]; then _cap_gate=disk
    elif [ "$rc" = "${AGENT_LAND_BACKLOG:-74}" ]; then _cap_gate=land
    elif [ "$rc" = "${AGENT_CAPABILITY_REFUSED:-71}" ]; then _cap_gate=capability
    else _cap_gate=load; fi
    # ⛔ THE YIELD IS GATE-INDEPENDENT, AND THAT IS A RECORDED DECISION — NOT AN OVERSIGHT TO TIDY.
    # README §7.2 says it in as many words ("**The yield is gate-independent, deliberately**"), and
    # ARCHITECTURE repeats it. A `land` refusal looks like it wants a SHORT window: it is repo-wide,
    # so every box measures the same ratio and a long stand-down only circulates the same answer.
    # That reasoning is correct and it was still REFUSED here (review cycle 2, P2), because reversing
    # a recorded decision belongs in that decision's own home with the evidence in front of the owner
    # — not in a lane's commit. What the change DOES do about it: chain-merge.sh ends the chain on
    # exit 74 immediately (no 90-minute wait), and the refusal line below says plainly that waiting
    # will not clear it. The window itself stays uniform. A `fork` refusal is subject to the same
    # uniform window for the same reason, and the same non-claim: it does not clear by waiting.
    _cap_yield="$CAPACITY_YIELD_SECS"
    _cap_now="$(date +%s)"
    if printf '%s\t%s\t%s\n' "$_cap_now" "$(( _cap_now + _cap_yield ))" "$_cap_gate" > "$capacity_record" 2>/dev/null; then
      # ⛔ THE WORDS MUST MATCH THE GATE (review cycle 3, P2). This line used to call EVERY refusal a
      # "capacity transfer ... yielded to peers", so a `land` lane log carried that claim three lines
      # above its own "This is NOT a capacity refusal" — and an operator grepping `capacity transfer`
      # found the false one first. The WINDOW stays uniform (README §7.2 records it as gate-independent);
      # only the description of what the stand-down buys changes.
      if [ "$_cap_gate" = "land" ]; then
        echo "[lane $N] stand-down recorded: gate=land, until +${_cap_yield}s — this stops THIS box re-claiming #$N while the ratio is re-read; it does NOT free the item for a peer to clear, because the backlog is repo-wide. chain-merge.sh releases refs/claims/issue-$N now instead of after 90 min; the drain is landing the open queue, not waiting." >> "$O/logs/lane-$N.log"
      else
        echo "[lane $N] capacity transfer: yielded to peers for ${_cap_yield}s (gate=$_cap_gate) — chain-merge.sh releases refs/claims/issue-$N now instead of after 90 min, and orch-loop.sh will not re-claim it from this box while the yield is live" >> "$O/logs/lane-$N.log"
      fi
    else
      echo "[lane $N] WARN: could not write $capacity_record — the refusal will still release the claim via chain-merge.sh's timeout path, but not promptly" >> "$O/logs/lane-$N.log"
    fi
  fi
  # ⛔ NAME THE GATE THAT ACTUALLY REFUSED (#1765). They are not interchangeable: a load refusal is
  # cleared by the box quietening, a disk refusal only by reclaiming space, and a FORK refusal only
  # from OUTSIDE the box (agent-infra#2293). An operator told "load" on a full filesystem waits for a
  # remedy that cannot arrive; told "load" on a fork-exhausted box, the retry itself cannot start.
  # ⛔ TOLERANT REFERENCE (review round 2, P2). `$O` is seeded file by file, so a NEW lane.sh can run
  # against an OLD `$O/spawn-gate.sh` that does not define AGENT_DISK_REFUSED — and under `set -u`
  # that aborts ABOVE the "NOT started" line, so the operator sees neither the refusal nor its
  # remedy. A pre-#1765 helper cannot return 77, so the default routes correctly to the load branch;
  # a pre-#2293 one cannot return 73 (the fork code — 74 is the LAND-BACKLOG code), so the fork
  # default routes to the load branch too.
  if [ "$rc" = "${AGENT_FORK_REFUSED:-73}" ]; then
    echo "[lane $N] NOT started: FORK gate refused — this box is out of PROCESSES (agent-infra#2293). Waiting cannot clear it and this box cannot start the retry: restart or drain it from OUTSIDE, or let its lanes finish and the issue be re-dispatched elsewhere." >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_DISK_REFUSED:-77}" ]; then
    # ⛔ TWO CONDITIONS SHARE CODE 77 (review round 1, P2): below `DISK_MIN_FREE_MB`, AND above it but
    # without the headroom for one lane's tree (`DISK-NOHEADROOM`, agent-infra#2721). This line used to
    # claim only the first, so the operator grepping it was told the filesystem was full when the floor
    # had been MET — a false cause, and the same #1765 class (a remedy for the wrong condition) this
    # block exists to prevent. Both are named, and the refusing line above carries the numbers.
    echo "[lane $N] NOT started: DISK gate refused — either the filesystem is below DISK_MIN_FREE_MB, or it is above the floor but has no headroom for one lane's dependency tree (DISK-NOHEADROOM, agent-infra#2721). The '[disk-gate] REFUSED' line above says which, with both terms. Reclaim space (cloud-cell-supervisor.sh prune --caches; --scratch for /tmp) before re-dispatching; this will NOT clear by waiting." >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_LAND_BACKLOG:-74}" ]; then
    # ⛔ NAMED, AND NAMEABLE AS SOMETHING OTHER THAN CAPACITY (#1765's rule, applied to a gate whose
    # remedy is not on this box at all). An operator told "load gate" here waits for a box that is
    # already idle; the reading they need is the repo's open-PR count against its landing rate, which
    # is on the `[land-backlog] REFUSED` line in the same log.
    echo "[lane $N] NOT started: LAND-BACKLOG — the repo holds more open PRs than its own measured landing rate can absorb (#2409), so new creation is held. This is NOT a capacity refusal: the box is fine and waiting will not clear it. The work is the PR queue — review, rebase or land an open PR; a P0-blocker or a base-red repair is exempt by evidence. Issue returns to the pool." >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_CAPABILITY_REFUSED:-71}" ]; then
    # ⛔ NAMED, BECAUSE THE REMEDY IS THE ONE THING WAITING CANNOT BUY (review of #2991, P1). Without
    # this arm a capability refusal fell into the `else` below and the operator read "load gate refused
    # — issue returns to the queue", one line under the `[capability-gate] REFUSED` line saying the
    # opposite. The `[capability-gate]` line above names WHICH reading refused (a hang, an unreadable
    # key, no pi, an empty model pair) and therefore which repair applies; this line's job is to stop
    # the reader concluding that the queue will fix it.
    echo "[lane $N] NOT started: CAPABILITY gate refused — this box could not complete one model call and RETURN (agent-infra#2935). Waiting will NOT clear it and load has nothing to do with it: the [capability-gate] line above carries the reading it refused on, so repair THAT on this box (its installed pi/extension set, its provider credential) or dispatch the issue to another box. Nothing was consumed; the issue does not need re-authoring." >> "$O/logs/lane-$N.log"
  else
    echo "[lane $N] NOT started: load gate refused (see the line above) — issue returns to the queue" >> "$O/logs/lane-$N.log"
  fi
elif [ -n "${capacity_record:-}" ] && [ -f "$capacity_record" ]; then
  # A lane that actually ran SUPERSEDES an earlier refusal for the same issue, so the record is
  # cleared rather than left to make a LATER chain exit early: the epoch bound already protects
  # that chain, and this keeps the state directory from accumulating one stale file per issue.
  rm -f "$capacity_record" 2>/dev/null || true
fi
exit "$rc"
