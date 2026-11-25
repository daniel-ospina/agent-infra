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
  # Only a CONTROLLER dispatch books an attempt, in `fixcount-<PR>` (the review-gate / CI-red / red-fixer
  # arms) or `conflictcount-<PR>` (the CONFLICT router) — WHICH one is recorded in
  # `state/spendcount-<PR>-<HEAD>`. See the refund in the load-refusal path below: a manual run must not
  # decrement a counter it never incremented.
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
# lease failed to parse (`_lease_of`'s anchored ASCII-digit match cannot match a minus sign), and an unparseable lease
# is never read as EXPIRED — so the head was frozen across ALL boxes and `claim_prune` could not
# reap it before #3203's bounded arm.
# FAIL-CLOSED, the opposite of the design's fail-open policy. `is_limit` (is_num AND at most 9
# digits) is the predicate orch-loop.sh applies to every other tunable for exactly this reason.
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
# ⛔ EXPORTED for the same reason as lane.sh: the SPAWN POINT is a child process (#1884), and a
# refusal that cannot name its item is a log line an operator has to reverse-engineer.
KIND=fixer; TAG="$PR"; export KIND TAG
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state"
# ⛔ THE WORK ROOT, DEFINED BEFORE THE FIRST SCRIPT PATH (#2095, fresh-context review of #3846, P1).
# The controller exports `O` = its STATE dir and `O_WORK` = the harness root, and the two differ whenever
# a state dir is named explicitly (`ORC_STATE_DIR`) or a copy is isolated. Everything this worker RUNS or
# SOURCES lives in the work root; everything it WRITES (`logs/`, `state/`, the claim lock) stays on `$O`.
_FIX_MOD_DIR="${O_WORK:-$O}"
L="$O/logs/fix-$PR"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST (#1988). The line above prepends the tool dirs, so a REAL gh in
# either of them outranks the seeded `$O_WORK/gh-rest` (Mac REST adapter) / `$O_WORK/gh-limit` (cell
# serialiser) — and a shim that is never resolved is an INERT layer: it reports protection and
# provides none. Re-assert both here, adapter last so `gh-rest` (which itself calls the same
# helper) wins where it exists. Guarded by `-d`, so a box that ships neither is unchanged.
# ⛔ THE WORK ROOT, NOT `$O` (#3846): on a state-dir instance `$O/gh-limit` is a directory that can
# never exist, so the shims would be dropped SILENTLY — the INERT layer this block exists to prevent.
if [ -d "${_FIX_MOD_DIR:-$O}/gh-limit" ]; then PATH="${_FIX_MOD_DIR:-$O}/gh-limit:$PATH"; fi
if [ -d "${_FIX_MOD_DIR:-$O}/gh-rest" ]; then PATH="${_FIX_MOD_DIR:-$O}/gh-rest:$PATH"; fi
# The wall-clock limit AND the load gate both live in the shared helper, so this script has no
# `pi` invocation of its own to forget to gate (agent-infra#1720). NB: L above is a LOG PATH, not a
# load reading — the gate takes its reading as an argument for exactly that reason.
# Fail LOUD if the helper is missing: an unsourced helper leaves `run_agent` undefined, and that must
# never degrade into "the fixer ran" — see README §9 on syncing $O.
# ⛔ SOURCED AFTER THE PATH EXPORT: spawn-gate.sh derives `_NCPU` at SOURCE time, so sourcing it
# under the pre-export PATH pins _NCPU=4 / MAX_LOAD=40 for every cell (the #1702 failure).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/spawn-gate.sh" || { echo "[fix $PR] FATAL: $SELF/spawn-gate.sh missing — refusing to run an ungated fixer" >&2; exit 78; }
# ── the worktree lifecycle helper (#2033) ──────────────────────────────────────────────────────
# Sourced after spawn-gate for the same $SELF (a `$O` seed copies the whole directory).
# ⛔ PROBED HERE, SOURCED ONLY WHERE IT IS NEEDED — AND THAT IS A CORRECTNESS REQUIREMENT (measured).
# An eager `. … || exit 78` at THIS point runs before the load/disk refusal accounting further down,
# which is where the controller's fixcount attempt is REFUNDED. `$O` is seeded file by file, so a new
# caller against an older `$O` (missing this helper) is a documented, TOLERATED skew — the same skew
# the AGENT_DISK_REFUSED tolerant reference below exists for. Exit 78 there would burn an attempt
# without running a fixer, and three of those PARK a PR "needs a human", which is precisely the
# agent-infra#1720 failure the refund exists to prevent. Measured: the shipped spawn-gate.test.sh
# fixture went red with the eager source — "a STALE helper still REFUNDS a load refusal: rc=75,
# fixcount 2->1 (rc=78, fixcount=2)". Only the materialise path below needs the helper, so the FATAL
# moves there: the refusal is still hard, it just no longer preempts accounting that must always run.
WT_LIFECYCLE_READY=0
if [ -f "$SELF/wt-lifecycle.sh" ]; then
  # shellcheck source=/dev/null
  . "$SELF/wt-lifecycle.sh" && WT_LIFECYCLE_READY=1
fi
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
  # ⛔ WHICH BUDGET THIS SPAWN CHARGED IS A FACT ON DISK, NOT A GUESS (fresh-context review, P2 —
  # #4126 round 3). The controller books `state/conflictcount-<PR>` for a CONFLICT rebase and
  # `state/fixcount-<PR>` for every other repair, and records which one it charged in
  # `state/spendcount-<PR>-<HEAD>` (`spend_book` in orch-loop.sh) BEFORE this lane starts. Refunding
  # `fixcount` unconditionally was silent in BOTH directions on a conflict spawn: the repair budget was
  # decremented for an attempt nothing had booked on it (inventing a fixer round on a review), while the
  # rebase attempt stayed spent for ever — so three gate refusals on a conflicting PR (a DISK refusal
  # never clears by waiting, so this is deterministic) parked it as "still CONFLICTING after N rebases"
  # with zero rebases ever attempted: the exact misdiagnosis class this refund exists to prevent.
  # A record whose content is not one of the two counters falls back to `fixcount` — the budget every
  # other booking site shares — so a corrupt record costs at most a repair round, never a rebase credit
  # it never paid for.
  local _budget="fixcount" _cf _nf
  if [ -n "${HEAD:-}" ] && [ -f "$O/state/spendcount-$PR-$HEAD" ]; then
    read -r _budget < "$O/state/spendcount-$PR-$HEAD" 2>/dev/null || true
    case "$_budget" in fixcount|conflictcount) : ;; *) _budget="fixcount" ;; esac
    rm -f "$O/state/spendcount-$PR-$HEAD" 2>/dev/null || true
  fi
  _cf="$O/state/$_budget-$PR"
  if [ -f "$_cf" ]; then
    _nf="$(cat "$_cf" 2>/dev/null || echo 0)"
    # `is_num`, not a hand-rolled `case`: the predicate is already in scope (spawn-gate.sh defines it,
    # and this script uses it for its own tunables), and a second, weaker copy is exactly how `08` grew
    # an octal read in the first place.
    is_num "$_nf" || _nf=0
    if [ "$_nf" -gt 0 ]; then
      echo $((_nf - 1)) > "$_cf"
      echo "[fix $PR] a gate refusal is not an attempt — $_budget refunded $_nf -> $((_nf - 1))" >> "$L.log"
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
# ⛔ AND BEFORE THE NUMBER CHECK BELOW (#4190 review P3). Both are pre-work refusals, and identity is
# the more fundamental fact: a lane that was BOTH mis-targeted AND handed a non-PR number used to be
# told only "the number is an issue" with a refunded attempt, so the operator had to discover the repo
# defect in a second round — and the two gh reads below are repo-scoped themselves (`--repo $OR`), so
# answering them about a target this box is not is answering about the wrong repo.
REPO_ASSERT_LINE="$(repo_target_assert "fixer #$PR target" "$REPO_ABS" "$OR" "")"; REPO_ASSERT_RC=$?
printf '%s\n' "$REPO_ASSERT_LINE" >> "$L.log"
if [ "$REPO_ASSERT_RC" -ne 0 ]; then
  echo "[fix $PR] REFUSED: the checkout $REPO_ABS and the target repo $OR disagree (exit $REPO_ASSERT_RC) — no fixer started, no branch touched" >> "$L.log"
  refund_gate_attempt
  exit "$REPO_ASSERT_RC"
fi
# ── IS THE NUMBER EVEN A PR? (agent-infra#4182 arm 3 — MEASURED 2026-11-21) ──────────────────
# [fixgate-prresolve:begin]
# A fixer is dispatched by PR NUMBER, and nothing here asked whether that number IS a pull request:
# the read above discards its status, so a number that resolves to NOTHING — an ISSUE number, a
# typo, a number from another repo — yields `HEAD=""` and the run continues. MEASURED: this box was
# dispatched for "PR #3301" while #3301 in this repo is an ISSUE; `git ls-remote` showed the handed
# branch at origin/main's tip with ZERO commits, `$L-comments.txt` held the GraphQL refusal, and the
# brief still asserted a reviewer had found real issues. A lane that obeys that brief fixes nothing,
# reports success, and pushes to a branch no PR tracks (#4182 arm 1) — and it materialises a worktree
# and a claim for it before anyone can tell.
# ⛔ THE POLARITY IS THE POINT: this refuses only on a POSITIVE IDENTIFICATION — gh can still read
# the ISSUE of that number while it cannot produce a PR for it. Two reads, no wording match:
#
#   * WHY NOT THE MESSAGE TEXT (#4190 review N1, and this block's first version — both VERIFIED
#     against the shipped shim). Keying on gh's sentence (`Could not resolve to a PullRequest`) is
#     DEFEATED on exactly the boxes where the measured dispatch happened: fix-one.sh prepends
#     `$O/gh-rest` to PATH (line 56), `number` is in that shim's `PR_FIELDS`, and its `pr view --json`
#     arm serves the read through REST — where a 404 arrives as `gh-rest: API error: Not Found`, not
#     the GraphQL sentence. Upstream gh cannot help either: it documents ONE generic code for "fails
#     for any reason" (`gh help exit-codes`: 0 ok, 1 any failure, 2 cancelled, 4 auth), so the exit
#     status does not discriminate. N1 also recorded that cli/cli#14038 emits the same GraphQL
#     sentence when the ACCOUNT LACKS ACCESS — a false refusal on a real PR, which this design removes
#     because an access-denied PR still has an issue projection only if a PR/issue of that number
#     exists, and the ISSUE read is what the arm below requires.
#   * WHY NOT `refs/pull/<N>/head` (the second attempt, replaced here). It is a NETWORK round trip in
#     a dispatch path and a GitHub-only convention — MEASURED: it turned 41 fixture runs of
#     spawn-gate.test.sh into rc=86, which is what a guard that over-blocks looks like from inside.
#   * ⛔ WHY THE PROJECTION, AND NOT THE ISSUE READ'S SUCCESS (#4190 review F1, P1 — MEASURED).
#     `gh issue view N` SUCCEEDS FOR A PULL REQUEST TOO, so its success proves only that SOME resource
#     of that number exists. GitHub's own REST contract: "GitHub's REST API considers every pull
#     request an issue, but not every issue is a pull request" (docs.github.com/rest/issues) —
#     MEASURED here, where `gh issue view 4190 --json number,url` answers rc=0 for #4190, which IS a
#     pull request, with the url `…/pull/4190`. This repo's own shim already knows it and DELEGATES
#     rather than invent a payload for a PR-numbered target (`gh-rest/gh`, the `kind = issue` arm).
#     So "the PR read failed and the issue read succeeded" reads as "the number exists", and every
#     state where the PR read fails for a reason OTHER than absence would refuse a LIVE PR — a
#     fine-grained PAT carries `Issues` and `Pull requests` as SEPARATE permissions, so an
#     issue-readable, PR-unreadable token is a real deployment, and a quota/transport split between
#     the two endpoints does the same. THE PREDICATE THEREFORE DEMANDS A DISCRIMINATING PROJECTION:
#     `gh issue view N --json url` is `…/issues/N` for an issue and `…/pull/N` for a pull request
#     (both measured on this repo and on the shipped shim, whose ISSUE_FIELDS carries `url`). Only
#     `/issues/<N>` refuses. When the projection does NOT name an issue, the PR read merely failed:
#     that is #4182 arm 2's recorded behaviour — UNKNOWN, proceed, refund nothing — never a refusal.
#   * STATED RESIDUALS. (i) A pure typo (a number that is neither a PR nor an issue) is NOT refused
#     here, because refusing it would require treating an unreadable read as an absence. It still gets
#     the UNKNOWN brief below and the review-read fix in the same PR. (ii) An adapter that answers the
#     issue read without a `url` projection is read as NOT identified — the fail-closed direction for
#     this guard, since a missing projection is not a positive identification. (iii) THE PER-HEAD
#     REFUND IS UNREACHABLE FROM THIS ARM, and it is recorded rather than papered over: `refund_gate_
#     attempt` books `fixgate-<PR>-<HEAD>` (and reads `spendcount-<PR>-<HEAD>`) ONLY when HEAD is
#     non-empty, and this refusal fires only when the head read came back EMPTY — so a controller that
#     pre-booked the head-keyed `redfix-<PR>` counter for this dispatch never sees it refunded by this
#     call, while `fixcount` is refunded exactly as the log line says. Nothing here can name that
#     head; the sentence in the log is therefore about `fixcount`, not about both.
#   * ⛔ THE PREDICATE WAS MEASURED AGAINST THE LIVE SHIM, IN BOTH DIRECTIONS (2026-11-21), because a
#     read verified only against a stub certifies the stub. Through the `gh` the fixer actually runs
#     (`$O/gh-rest` first on PATH): issue 3301 → `{ "url": "…/issues/3301" }` → the pattern MATCHES
#     (refuse); PR-numbered 4190 → `{"url":"…/pull/4190"}` (the shim DELEGATES a PR-numbered `issue
#     view`, so real gh's compact JSON arrives) → the pattern does NOT match (proceed). Both shapes
#     are covered by the arm-0 pin and arms 1/1b; the stub in `fix-one-prresolve.test.sh` models the
#     field SELECTION too, so a request that stops naming `url` cannot pass green.
PR_RESOLVE_UNKNOWN=""
if [ -z "${HEAD:-}" ]; then
  pr_probe="$(gh pr view "$PR" --repo "$OR" --json number 2>&1)"; pr_probe_rc=$?
  if [ "$pr_probe_rc" -ne 0 ]; then
    issue_probe="$(gh issue view "$PR" --repo "$OR" --json url 2>&1)"; issue_probe_rc=$?
    # A here-string, not `printf … | grep -q`: under pipefail a quiet grep that matches early closes
    # the pipe and the writer takes SIGPIPE, so the pipeline reports 141 and this reads as "not an
    # issue" exactly when the payload matched (`check-no-sigpipe-grep.sh`, #841/#864).
    # ⛔ `/issues/<N>` AND NOTHING LESS: `gh issue view` SUCCEEDING is not the identification — it
    # answers for a pull request too (see the block comment). A pull request's projection is its
    # `…/pull/<N>` url, which this pattern does not match.
    if [ "$issue_probe_rc" -eq 0 ] && grep -qE '"url"[[:space:]]*:[[:space:]]*"[^"]*/issues/[0-9]+' <<<"$issue_probe"; then
      echo "[fix $PR] REFUSED: $OR has no pull request numbered $PR, but it DOES have an ISSUE with that number (the issue projection is an ISSUE url: $(printf '%s' "$issue_probe" | head -1); gh pr view failed rc=$pr_probe_rc: $(printf '%s' "$pr_probe" | head -1)). This is a DISPATCH defect — an ISSUE number routed to the PR fixer — not a repair: there is no PR to fix, no head to test and no findings artifact to read. No worktree was materialised, no branch was touched, and the attempt is refunded. Route the number to the ISSUE path, or re-dispatch it with a real PR number." >> "$L.log"
      echo "[fix $PR] REFUSED: #$PR is an ISSUE in $OR, not a pull request — dispatch defect, no fixer started, attempt refunded" >&2
      refund_gate_attempt
      exit "${AGENT_NOT_A_PR_REFUSED:-86}"
    fi
    # ⛔ THE OTHER HALF OF THE SAME MEASUREMENT (#4190 review F1). Two arrivals here, and BOTH are
    # "proceed, refund nothing": (a) the projection names a PULL REQUEST, i.e. the number is a live PR
    # whose PR read failed on a permission/quota/transport split — the case a success-only predicate
    # refused outright; (b) the read answered without a discriminating url, which is not a positive
    # identification. Neither is an absence, so neither may spend the dispatch's attempt.
    PR_RESOLVE_UNKNOWN="gh produced no PR for this number (rc=$pr_probe_rc: $(printf '%s' "$pr_probe" | head -1)) and the issue read did NOT identify it as an ISSUE (rc=$issue_probe_rc: $(printf '%s' "$issue_probe" | head -1) — a pull request's own projection is its /pull/<N> url) — NOT read as a missing PR, because neither an unreadable read nor a PR-shaped projection is an absence"
  else
    PR_RESOLVE_UNKNOWN="the PR exists (gh answered) but its head read returned EMPTY, so the brief's staleness guard cannot name this head (#4182 arm 2)"
  fi
  echo "[fix $PR] WARN: $PR_RESOLVE_UNKNOWN — continuing, and the brief's head-dependent sentences render UNKNOWN instead of a blank" >> "$L.log"
fi
# ⛔ THE BRIEF'S HEAD-DEPENDENT SENTENCES RENDER THE HEAD — AND RENDER UNKNOWN WHEN IT IS UNKNOWN
# (#4190 review F1, P2). The staleness guards further down interpolated `$HEAD` VERBATIM, so with
# HEAD empty — precisely the arm-2/arm-3 case this block exists for — the brief rendered
# "THIS head (``)": the one sentence that could have exposed the mismatch was BLANKED by the same
# failed read, while the WARN above claimed anything head-dependent "reports UNKNOWN instead of
# asserting". Both halves are repaired here rather than by weakening the WARN: the head the brief
# SHOWS is computed from THIS SAME observation, so a known head renders as itself and an unknown one
# renders as an explicit UNKNOWN carrying its reason. The WARN above is therefore a true statement
# about the brief below, and the empty-head arm is testing a behaviour instead of a message (#3442).
if [ -n "${HEAD:-}" ]; then
  FIX_BRIEF_HEAD="$HEAD"
else
  FIX_BRIEF_HEAD="UNKNOWN — $PR_RESOLVE_UNKNOWN"
fi
# [fixgate-prresolve:end]

[ -z "$WT" ] && {
  # Foreign (other-machine) branch: materialise a local worktree so the fixer has somewhere to work.
  # ⛔ THROUGH THE SHARED HELPER (#2033), not `git worktree add … || exit 1`. That shape left the
  # branch behind when the add failed mid-checkout — and for this path the branch is one this box may
  # have JUST created from `origin/$BR`, i.e. residue with no owner, which then blocks the PR's issue
  # pre-flight on every box. `wt_provision` rolls back to a verified empty state, and ATTACHES an
  # existing branch that holds commits instead of failing on "branch exists".
  # The helper MUST be present on exactly this path (see the probe above): without its rollback, a
  # failed add leaves the branch behind, which is the residue #2033 is about.
  if [ "$WT_LIFECYCLE_READY" != 1 ]; then
    echo "[fix $PR] FATAL: $SELF/wt-lifecycle.sh missing — refusing to materialise a worktree without its rollback (#2033)" >> "$L.log"
    echo "[fix $PR] FATAL: $SELF/wt-lifecycle.sh missing — refusing to materialise a worktree without its rollback (#2033)" >&2
    exit 78
  fi
  # ⛔ NAME THE REPO, NOT A MATERIALISATION FAILURE (#2694). The measured message a human read first
  # was `cannot materialise <branch>`, which says nothing about the repo the branch is missing FROM.
  # If the branch is in neither this repo nor its origin after a fetch, say so — with the branch and
  # the slug — and stop before `wt_provision` can only report the generic add failure. A fetch that
  # failed for network reasons is covered too: the branch is unproven here, and the refusal names
  # both possibilities rather than blaming worktree creation.
  if ! git rev-parse --verify -q "refs/heads/$BR" >/dev/null; then
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
git fetch origin "+refs/heads/$BR:refs/remotes/origin/$BR" --quiet --quiet >> "$L.log" 2>&1
    if ! git rev-parse --verify -q "refs/remotes/origin/$BR" >/dev/null 2>&1; then
      # Reached only when the fetch genuinely could not read the branch (network, auth, a real
      # BRANCH/REPO mismatch) — the refspec above no longer produces a FALSE hit here.
      repo_target_branch_assert "fixer #$PR" "$REPO_ABS" "$BR" "$OR" >> "$L.log"
      echo "[fix $PR] REFUSED: branch '$BR' is not in $OR (checkout $REPO_ABS) — it could not be read after fetching origin. This is a BRANCH/REPO mismatch, not a worktree-materialisation failure; refusing before any fixer starts" >> "$L.log"
      refund_gate_attempt
      exit "$REPO_TARGET_REFUSED"
    fi
  fi
  wt_provision "$REPO" ".worktrees/fix-$PR" "$BR" "origin/$BR"
  _wt_rc=$?
  if [ "$_wt_rc" = 4 ]; then
    # ── THE PRE-START DISK REFUSAL (agent-infra#3395) ─────────────────────────────────────────
    # Nothing was created and no agent ran, so the attempt is REFUNDED and the exit code is the disk
    # gate's own (77): `adopt-fix.sh:93` reads 77 as the DISK gate and names WHICH of its three
    # causes fired before it names any remedy (that arm no longer prescribes one remedy for all
    # three), and folding it into a generic rc=1 (the old `exit 1` below) is the misattribution #2721
    # fixed for the live arm. Measured cost of NOT distinguishing it: the operator is sent to wait for a
    # load remedy that cannot arrive.
    # ⛔ `chain-merge.sh` IS NOT A READER OF THIS CODE (review P2, #3409 — an earlier revision of this
    # line named it, and that pointer does not exist). `chain-merge.sh` never references `fix-one.sh`
    # (`grep -n fix-one chain-merge.sh` → empty); its own `77` at `:261` (`disk) _cap_rc=77 ;;`) is a
    # PRODUCER that derives a disk code from a lane's capacity-refusal RECORD, and the only lane status
    # it INTERPRETS is `merge-one.sh`'s `rc=75` (`:500-503`) — every other code it merely propagates
    # (`:497-510`). Named here because a rationale that points at a guard which does not exist is the
    # same wrong-cause class this seam exists to remove, one comment over.
    echo "[fix $PR] REFUSED before creating a worktree: $WT_RESULT" >> "$L.log"
    # ⛔ THE REMEDY IS SELECTED FROM THE VERDICT, NOT HARDCODED (review cycle 4, P2 — MEASURED). BOTH
    # pre-start arms reach rc 4 with `REFUSED-UNKNOWN`: an unreadable `df`, and a half-deployed `$O`
    # missing `spawn-gate.sh` (the file's own arm G pins that skew). Telling the operator to "reclaim
    # space" for a version skew or a broken probe is a remedy that CANNOT ARRIVE — the exact
    # misattribution #2721 fixed for the live arm, re-introduced one step earlier.
    case "$WT_RESULT" in
      *REFUSED-UNKNOWN*)
        echo "[fix $PR] REFUSED-UNKNOWN (nothing created, attempt refunded) — the free-space probe could NOT answer, so this is NOT a full disk: check that \`df\` is on PATH and that this box's \$O carries spawn-gate.sh AND that the copy it carries DEFINES \`disk_admit\` — a presence check passes on an older copy that still refuses here (a half-deployed or skewed box fails closed, #2033). Waiting will NOT clear it." >> "$L.log" ;;
      *)
        echo "[fix $PR] REFUSED-DISK (nothing created, attempt refunded) — reclaim space; this will NOT clear by waiting" >> "$L.log" ;;
    esac
    refund_gate_attempt
    exit "${AGENT_DISK_REFUSED:-77}"
  fi
  if [ "$_wt_rc" != 0 ]; then
    echo "[fix $PR] ABORT: $WT_RESULT" >> "$L.log"
    # ⛔ REFUND HERE TOO (#3511). This arm exited without refunding while the branch refusal above
    # does. The rule is #1720's: a refusal that ran no fixer gives the attempt back — otherwise three
    # refusals reach MAX_FIX_TRIES and the PR is PARKED "needs a human" having never had a single fixer
    # run.
    # ⛔ THE DELIVERY DEPENDS ON WHERE THE CONTROLLER BOOKS, AND ONLY ONE OF THE FOUR SPAWN ARMS
    # PRE-BOOKS. The red-tree arm books `fixcount` BEFORE `wt_spawn` (that ordering was a fix in its own
    # right: booking after the spawn let the child's decrement be overwritten by the controller's
    # pre-refusal value). The CONFLICTED, NEEDS-FIX and CI-red arms still book AFTER the spawn, so a
    # refund landing in that window is overwritten and the attempt is consumed anyway. The per-head
    # `fixgate-<PR>-<HEAD>` marker this call also writes does not rescue them either: among those four
    # `fixcount` arms only the red-tree one consumes it, and no other consumer of that marker touches
    # `fixcount` — they refund or reclaim their OWN head-keyed budgets (`psick`; the reclaim-on-land
    # paths read no budget from it at all). That residual is filed (#3562); this call is still correct
    # and still the fix, because the arm that most needs it pre-books and the others shrink the window
    # rather than widening it.
    # The test is the exit code and nothing else: ANY non-zero `wt_provision` rc refunds. The helper
    # names the cause in `$WT_RESULT`, which is logged on the line above — this comment does not restate
    # the cause list, because a list here is a second definition that goes stale the next time the
    # helper grows an arm.
    # ⛔ NOT `prlock_refuse`'s RULE (the function below, with its note above it), which CONSUMES the
    # attempt: a `$PRLOCK` that is not a regular file, or a `$O/state` this box cannot write, is
    # bookkeeping no re-dispatch can change. ⛔ But the answer here is NOT "so consume a sticky one":
    # this file deliberately refunds refusals that never clear by themselves — the repo-IDENTITY
    # refusal above refunds a permanent misconfiguration by its own wording, and the #2223 per-head
    # note inside `refund_gate_attempt` refunds a DISK refusal whose comment says outright it "never
    # clears by waiting". The trade is stated there and applies here: parking the PR on "attempts
    # exhausted" is a FALSE sentence about work that never ran, so a sticky refusal is left LOUD in
    # `fix-$PR.log` and re-spawned rather than silently parked. ⛔ What bounds that re-spawn is per-cycle
    # capacity only (the `$MF` fix-lane ceiling, the cross-box claim, `can_spawn`) — it is THROTTLED per
    # cycle, not bounded across cycles, and the fix that would let it park is a `REPAIR:` line in
    # `wt_provision`'s refusals, which carries none today (its absence is recorded in the comment on
    # #2632; none of those refusals carries repair text, which is why a human gets a cause and no next
    # step). No line numbers in this block on purpose: a citation here already
    # rotted once when an edit to this comment shifted the function it pointed at.
    refund_gate_attempt
    exit 1
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
# ⛔ AN ORPHANED RECORD NAMES NO PID, SO NEITHER LIVENESS TEST CAN EVER RESOLVE IT — AND THAT IS THE
# DRAIN STALL. `prlock_live_owner` needs a pid > 0 that is alive, and `prlock_stale_owner` needs a pid
# > 0 that is dead, so a record whose content is EMPTY is BOTH "not live" and "not stale": it falls
# through `prlock_take` (the path exists, so the `ln` CAS refuses) into the "treated as LIVE" defer
# below, and stays there FOREVER. Measured 2026-10-30 on TWO of the three Linux cells (the lock counts below are cell-1's and
# cell-4's; cell-3's records were not counted): 4 of cell-1's 5 records and 4 of cell-4's 8 were 0-byte, unheld, and 1278-1286 / 2309-2314 MINUTES old, and every fixer that
# touched those PRs bailed on that sentence; `orch-loop.sh` then REFUNDED the attempt
# ("was not an attempt — budget refunded"), so the budget never parked them and the cycle re-spawned the
# same no-op fixer forever. Those PRs could never be pushed or merged, so the un-owned count never fell,
# so `merge-priority` held the ISSUE path shut — a controller that runs, logs loudly and yields no lane.
# The empty state is REAL but INSTANT: `prlock_take` writes the pid to a private file and `ln`s it into
# place precisely so the create and the content are one atomic step. A record that is STILL empty after
# the create window has outlived the explanation, so AGE is the missing third measurement — the same
# shape `prlock_stale_owner` uses (a measurement, not an inference), applied to the state it cannot see.
# ⛔ The grace is bounded WELL ABOVE the window (microseconds) and WELL BELOW the observed ages (hours),
# so an honest claim read mid-create is still treated as LIVE and never displaced.
PRLOCK_NO_OWNER_GRACE_MIN="${PRLOCK_NO_OWNER_GRACE_MIN:-2}"
prlock_no_owner_abandoned() { # prints the record's measured content; rc 0 ONLY when it names NO owner AND has outlived the create window
  local p
  [ -f "$PRLOCK" ] || return 1
  [ -L "$PRLOCK" ] && return 1
  # ⛔ `cat`'s OWN exit status, never a `|| echo 0` fallback: an UNREADABLE record is not evidence of
  # anything. The fallback turned it into the literal `0`, which the arm below ADMITS — so the caller
  # passed "0" as the pid it had measured and the takeover re-read the file, got the same "0", and
  # detached a record nobody had proven dead (review of #3096, P2).
  p="$(cat "$PRLOCK" 2>/dev/null)" || return 1
  # Empty, whitespace-only or 0 = no owner was ever written. A NON-numeric body is a different defect and
  # stays out of this arm: only "nothing was ever written here" is provable from the content alone.
  case "${p//[[:space:]]/}" in ''|0) : ;; *) return 1 ;; esac
  # `find -mmin` is the ONE age primitive that is POSIX-shaped on both this box's GNU userland and the
  # macOS harness hosts (GNU `stat -c` and BSD `stat -f` disagree), so the test is portable by construction.
  [ -n "$(find "$PRLOCK" -maxdepth 0 -mmin +"$PRLOCK_NO_OWNER_GRACE_MIN" 2>/dev/null)" ] || return 1
  # ⛔ IT PRINTS THE CONTENT IT MEASURED, AND THE CALLER MUST PASS IT BACK TO `prlock_takeover` (review of
  # #3096, P2). The takeover's first CAS compares the record on disk against the value it was given;
  # called with a hard-coded `""` it matched ONLY a 0-byte record, so a whitespace-only or `0` body — both
  # admitted above — failed that compare and the arm deferred with "the takeover LOST a race with a peer
  # that reclaimed it first", a race that never happened and a claim about a process with no artifact
  # behind it. Printing what was measured is what makes the compare meaningful.
  printf '%s\n' "$p"
  return 0
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
  local stale="$1" side cur _no_owner=0
  side="$PRLOCK.reclaim.$$"
  # ⛔ CONTENT CANNOT DISCRIMINATE TWO EMPTY RECORDS, SO THE VERIFY RE-CHECKS AGE (review of #3096, P3).
  # For the orphan case the measured content is `""`, so `[ "$cur" = "$stale" ]` would accept a DIFFERENT,
  # FRESH empty record that appeared between the read and the `mv` — and `merge-one.sh:205-207` and
  # `cloud-cell-doctor.sh:1336-1338` both do `rm -f "$lock"` followed by a noclobber create, so such a
  # record does exist briefly. The one measurement that tells the aged record from that peer's is `mmin`
  # (`mv` preserves it), so the empty case re-takes it on what was detached.
  case "${stale//[[:space:]]/}" in ''|0) _no_owner=1 ;; esac
  # ⛔ BOTH READS ARE `cat`'S OWN STATUS, NOT A `|| echo 0` FALLBACK (review of #3096, P3-3). The invariant
  # three lines of `prlock_no_owner_abandoned` state — an UNREADABLE record is not evidence of anything —
  # held only in one of the two reads: a record made unreadable (or replaced by a directory) between the
  # measurement and this compare fell back to the literal `0`, failed the compare, and the caller logged
  # "the takeover LOST a race with a peer that reclaimed it first" for a peer that never existed.
  cur="$(cat "$PRLOCK" 2>/dev/null)" || return 1
  [ "$cur" = "$stale" ] || return 1
  mv -f "$PRLOCK" "$side" 2>/dev/null || return 1
  cur="$(cat "$side" 2>/dev/null)" || {
    # ⛔ AN UNREADABLE DETACHED RECORD IS PUT BACK, NEVER DELETED (review of #3096, P3). An earlier draft
    # did `rm -f "$side"; return 1` — DELETING a record it had just failed to verify, under a line telling
    # the caller "this lane displaced nothing". Both halves of that sentence were false. Restore it; if the
    # path is already re-claimed the record is genuinely LOST, which is rc 2 and says so.
    if ln "$side" "$PRLOCK" 2>/dev/null; then rm -f "$side"; return 1; fi
    rm -f "$side"; return 2
  }
  if [ "$cur" != "$stale" ] || { [ "$_no_owner" = 1 ] && [ -z "$(find "$side" -maxdepth 0 -mmin +"$PRLOCK_NO_OWNER_GRACE_MIN" 2>/dev/null)" ]; }; then
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
elif PL_ORPHAN="$(prlock_no_owner_abandoned)"; then
  # The record names no owner and is older than the create window: an abandoned claim, not a lander
  # mid-claim. It goes through the SAME detach-verify-restore CAS as a dead-pid takeover, handed the
  # exact content that was MEASURED — an empty string matches only a 0-byte record, so the whitespace/`0`
  # shapes this arm admits would fail the takeover's first CAS and mis-report a peer race (review P2).
  # ⛔ AND BOTH DEFERRALS NAME THE STABLE CAUSE TOKEN `the PR-owner lock` (review of #3096, P2).
  # `adopt-fix.sh` maps that token (its `DEFERRED: the PR-owner lock` arm) to an operator line and exit 79;
  # they began `state/mergeclaim-$PR.lock held NO pid…`, which matches NO arm there — so `adopt-fix <PR>`
  # returned SUCCESS and wrote nothing into `adopt-$PR.log` for a run that pushed nothing, and an
  # `… && next` chain took the wrong branch. `fix-one.sh:442-445` records that exact failure once already.
  if prlock_takeover "$PL_ORPHAN"; then
    echo "[fix $PR] PR-owner lock: RECLAIMED an ORPHANED claim — state/mergeclaim-$PR.lock held NO pid (empty record) and was older than ${PRLOCK_NO_OWNER_GRACE_MIN}m, so no create window explains it; this lane took the claim over instead of refusing the PR" >> "$L.log"
  else
    case $? in
      2) prlock_defer "the PR-owner lock (state/mergeclaim-$PR.lock) held NO pid (empty) and outlived the create window, and a peer's claim that appeared while this lane was taking it over was DISPLACED AND COULD NOT BE RESTORED — the WARNING line above names that pid. Nothing was pushed by this lane; REPAIR: confirm no worker is live (pgrep -af 'fix-one.sh|merge-one.sh|cloud-cell-doctor.sh') and re-run" ;;
      *) prlock_defer "the PR-owner lock (state/mergeclaim-$PR.lock) held NO pid (empty) and outlived the create window, but the takeover LOST a race with a peer that reclaimed it first — this lane displaced nothing; the peer now holds it" ;;
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
# ── SINGLE-OWNER BRANCH CLAIM (agent-infra#3696) ───────────────────────────────────────
# ⛔ WHY THE PER-HEAD KEY ABOVE IS NOT ENOUGH, AND WHAT THIS ADDS. `claim_acquire` is keyed by
# `<PR>-<head12>`: it stops two lanes fixing the SAME head, and it is CORRECT — but the writer that
# caused #3696 does not collide on it, because **its push CREATES a new head**, so it takes a fresh
# key and wins its own CAS every time. Measured (tortoise PR #11385, 2026-11-07): lane A held
# `refs/claims/11385-a51050d7b` and lane B pushed `93b85f33d` on top of it, then 10 more heads over
# ~6 h — every push invalidated the other lane's head-bound review attestation, so five fresh reviews
# returned clean on five different heads and the PR never landed.
# The question the incident needed answered is COARSER than "this head": *does another lane own this
# BRANCH right now?* That is `refs/claims/branch-<slug>` — the key, CAS, fencing token, guard and
# reaper that #3328 already built and reviewed for batch branches, deliberately reused rather than
# a second registry. See branch-claim.sh's header for the loss it was built for; it is the same shape.
# ⛔ IT IS NOT THE LANDING KEY `pr-<N>` ON PURPOSE (claims.sh:963-970 RECORDS that `pr-<N>` is taken
# ONLY by the landing path, and ps_held in pr-sickness.sh reads it as "someone is LANDING this PR").
# ⛔ THE CITATION IS THE RECORD, NOT A PARAPHRASE OF IT (cycle-3 review F3b, verified against the tree):
# this used to read `claims.sh:1855-1858`, which is the PR-SICKNESS QUEUE comment — it says the decision
# lives elsewhere, it is not the decision. A conclusion resting on a pointer to a different paragraph is
# how the next lane re-derives and concludes the opposite, the failure mode agent-infra#2258 records.
# Taking `pr-<N>` here would reverse that recorded decision and make a live FIXER read as a live
# MERGER; the branch key answers the writer question without touching the landing one.
BRANCH_OWN=""
BRANCH_TOKEN=""
release_branch_claim() { # same 20s bound as release_fix_claim, for the same reason (EXIT path)
  local p w rc
  [ -n "${BRANCH_OWN:-}" ] || { [ -n "${BRANCH_TOKEN:-}" ] && claim_branch_forget "$BRANCH_TOKEN"; return 1; }
  claim_branch_release "$REPO" "$BR" "$BRANCH_OWN" >/dev/null 2>&1 &
  p=$!
  ( sleep 20; kill -TERM "$p" 2>/dev/null; sleep 5; kill -KILL "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$p" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null
  # ⛔ FORGET THE TOKEN ONLY WHEN THE RELEASE ACTUALLY LANDED (cycle-2 review P2, verified against
  # `branch-claim.sh`'s `cmd_release`, which forgets only on success). `_claim_release_at` returns 1
  # WITHOUT deleting the ref when the fenced push fails or the 20 s watchdog TERMs it — the expected
  # failure this file's own `release_fix_claim` bound documents. On that path the claim is STILL OURS
  # and the token is the only possession proof, so forgetting it would destroy recovery path (1) in the
  # lifetime note above (a same-box lane releases with the token) and strand the claim for the full
  # branch lease with no cooperating remedy left but deleting the ref by hand.
  [ "$rc" -eq 0 ] && [ -n "${BRANCH_TOKEN:-}" ] && claim_branch_forget "$BRANCH_TOKEN"
  return "$rc"
}
trap 'release_prlock; release_fix_claim; release_branch_claim' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
# ⛔ `_FIX_MOD_DIR` (the work root) is resolved at the TOP of this file, before the gh shims — see
# there. `$O` would be the STATE dir on an `ORC_STATE_DIR` instance, where claims.sh does not exist.
if [ -n "${HEAD:-}" ] && [ -f "${_FIX_MOD_DIR:-$O}/claims.sh" ]; then
  # shellcheck source=/dev/null
  . "${_FIX_MOD_DIR:-$O}/claims.sh"
  # The fallback used when a malformed FIX_TIMEOUT is refused: the SAME value the run would take.
  _FIX_BOUND_FALLBACK="${LANE_BACKSTOP_S:-36000}"
  is_limit "$_FIX_BOUND_FALLBACK" || _FIX_BOUND_FALLBACK=36000
  FIX_BOUND="${FIX_TIMEOUT:-$_FIX_BOUND_FALLBACK}"
  if ! is_limit "$FIX_BOUND"; then
    echo "[fix $PR] FIX_TIMEOUT='${FIX_TIMEOUT:-}' (resolved to '$FIX_BOUND') is not an integer in range (at most 9 digits) — using ${_FIX_BOUND_FALLBACK} (the cross-box lease needs a number that cannot overflow)" >> "$L.log"
    FIX_BOUND="$_FIX_BOUND_FALLBACK"
  fi
  # ⛔ ONE RESOLVED BOUND DRIVES BOTH THE LEASE AND THE RUN (agent-infra#2888 review, P1 — verified).
  # They were two independent literals: the run moved to the `${FIX_TIMEOUT:-$LANE_BACKSTOP_S}` backstop
  # (36000 s since agent-infra#4034; 7200 s when this was written) while this lease stayed `FIX_TIMEOUT:-2400 + 1200` = 3600 s. With `FIX_TIMEOUT` unset — the
  # shipped default; nothing outside the test suite sets it — the claim then expired an HOUR before the
  # fixer's own bound, a peer read the head as free and ran a SECOND fixer on the same branch: exactly
  # the duplicate dispatch `claims.sh`'s lease/ceiling block says the lease exists to prevent. Resolving
  # the bound ONCE removes the class instead of re-syncing two numbers on every future change.
  FIX_TIMEOUT="$FIX_BOUND"
  # Overflow-safe by construction: the guard above leaves FIX_TIMEOUT <= 999999999, so this sum is
  # < 2**31. claims.sh clamps the ttl a second time at its own arithmetic site — `CLAIM_TTL_MAX` is
  # sized ABOVE this lease (claims.sh), and a lease reaching the ceiling is reported, never silent.
  FIX_LEASE=$(( FIX_BOUND + 1200 ))
  # ── THE BRANCH CLAIM IS TAKEN FIRST, AND ITS REFUSAL IS THE FIX FOR #3696 ────────────────
  # Coarse-to-fine, the same order merge-one.sh takes its keys in: a lane that does not own the
  # BRANCH has no business reading it, let alone pushing a new head onto it. Taking it here — before
  # the fixer runs, therefore LONG before the push — is what makes a second worker see "a peer owns
  # this branch" at the moment it decides to work rather than after it has already superseded a head.
  # ⛔ A REFUSAL IS A PRE-WORK REFUSAL, so it refunds the attempt exactly as the head-claim refusal
  # below does: the controller books `fixcount` at SPAWN, so a lane that did nothing must not burn one
  # of MAX_FIX_TRIES (the 2026-10-14 P2 that marker exists for).
  # ⛔ AN OLD DEPLOYED claims.sh HAS NO `claim_branch_acquire`, AND THAT IS A NAMED STATE, NOT A
  # SILENT PASS — the same polarity merge-one.sh uses for `claim_pr_acquire`. Fail-open on the
  # branch key alone (the per-head CAS below still runs), and say so in the log.
  # [fixgate-branchclaim:begin]
  if command -v claim_branch_acquire >/dev/null 2>&1; then
    claim_branch_acquire "$REPO" "$BR" >/dev/null
    BR_RC=$?
    case "$BR_RC" in
      0) BRANCH_OWN="$CLAIM_COMMIT"
         echo "[fix $PR] single-owner branch claim: $CLAIM_RESULT" >> "$L.log"
         # ⛔ THE LIBRARY ACQUIRE DOES **NOT** WRITE THE FENCING TOKEN, AND WITHOUT IT THIS LANE'S OWN
         # PUSH IS REFUSED (P0, measured on a fixture before this line existed). `claim_branch_guard`
         # answers "may I push?" by POSSESSION — does this checkout's token file name the commit that
         # is currently the claim ref's tip? — and `claim_branch_record` is called by exactly ONE writer
         # in the tree, `branch-claim.sh`'s `cmd_acquire`, which this path does not go through. So a
         # fixer that acquired correctly was refused `reason=held-by-live` **by its own claim**, with a
         # message telling it to ask itself to release. The token must name the git dir of the WORKTREE
         # THE PUSH WILL COME FROM: it is per-checkout by design (claims.sh:1049-1059), and a linked
         # worktree has its own git dir (measured here: `<repo>/.git/worktrees/<name>`), so a token
         # written for $REPO would be invisible to the hook running in $WT.
         if [ -n "${WT:-}" ]; then
           _wt_gitdir="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)"
           if [ -n "$_wt_gitdir" ] && BRANCH_TOKEN="$(claim_branch_record "$(claim_branch_token_path "$BR" "$_wt_gitdir")" "$BR" "$BRANCH_OWN" 2>/dev/null)"; then
             echo "[fix $PR] branch claim fencing token written for worktree $WT" >> "$L.log"
           else
             BRANCH_TOKEN=""
             echo "[fix $PR] WARNING: acquired the branch claim but could NOT write its fencing token into $WT ('${_wt_gitdir:-no git dir}') — the push guard will REFUSE this lane's own push as held-by-live until the token exists. Fix the worktree's git dir; the claim is still released on exit" >> "$L.log"
           fi
           unset _wt_gitdir 2>/dev/null || true
         else
           echo "[fix $PR] WARNING: no worktree path is set, so the branch claim has NO fencing token — this lane's push would be refused as held-by-live" >> "$L.log"
         fi ;;
      1) case "${CLAIM_RESULT:-}" in
           *unreadable-clock*)
             # ⛔ rc=1 IS NOT ALWAYS A PEER (review P3, verified at claims.sh:1584-1592): an unreadable
             # local clock is minted as rc 1 on purpose so callers refuse on it. Reporting that as
             # "another lane owns this branch" blames a peer that does not exist and buries the real
             # repair — the wrong-cause class this file already documents.
             echo "[fix $PR] single-owner branch claim REFUSED: $CLAIM_RESULT — this box's CLOCK is unreadable, NOT a peer: the ownership window cannot be judged, so nothing was started. Recording a bail marker and exiting" >> "$L.log" ;;
           *)
             echo "[fix $PR] single-owner branch claim REFUSED: $CLAIM_RESULT — another lane already owns branch $BR; NOT starting a fixer and NOT pushing a new head on top of its work (agent-infra#3696). Recording a bail marker and exiting" >> "$L.log" ;;
         esac
         : > "$O/state/fixbail-$PR-$HEAD"
         exit 0 ;;
      *) echo "[fix $PR] single-owner branch claim UNAVAILABLE (rc=$BR_RC: $CLAIM_RESULT) — proceeding WITHOUT branch exclusion (fail-open on purpose, same polarity as the head claim below; ask the holder to release it: branch-claim.sh release $BR, or with no cooperation possible: git push origin :refs/claims/branch-$(claim_branch_slug "$BR") after confirming no worker is live)" >> "$L.log" ;;
    esac
  else
    echo "[fix $PR] single-owner branch claim UNAVAILABLE: claims.sh defines no claim_branch_acquire (it predates agent-infra#3328) — proceeding WITHOUT branch exclusion, so a peer lane writing $BR is NOT excluded. Re-provision claims.sh (install.sh seeds it)" >> "$L.log"
  fi
  # [fixgate-branchclaim:end]
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
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# ── FIX-ONE-REQ-SPLIT:BEGIN ────────────────────────────────────────────────────────────────────────
# WHICH REDS A FIX COULD ACTUALLY UNBLOCK (agent-infra#3461).
#
# THE DEFECT. `FAILING_CHECKS` above answers ONE question — "which checks are red" — and its polarity
# (the #1714 allow-list) is right. It says NOTHING about "does this red block the rail", yet every
# survivor was written under the heading `=== failing required check: <c> ===` and the brief below
# ASSERTED "REQUIRED CI CHECKS ARE ALSO FAILING". The word "required" was ASSERTED, never COMPUTED:
# nothing in this file read branch protection at all. MEASURED (tortoise PR #10726, head
# 6bbd1f2742ea, 2026-11-05): the only red group was `github-actions/redis-guard`, which is absent
# from main's required set — and the job had died in `Set up job` (0 steps, an action-archive
# download timeout), so it carried NO verdict on the tree either. A capped fix lane was dispatched on
# a premise that is false for every PR, and fixing that check could not have satisfied the rail; the
# repo had already corrected the same false claim in its own workflow header. Two labels answer the
# two questions, and the brief must carry both.
#
# ONE CONTRACT HOME, ONE READ PER DISPATCH. The required set is resolved by the same module
# `merge-one.sh` and `orch-loop.sh` source (`repo-authority.sh::resolve_required_checks`), so a third
# opinion cannot appear here. It is read ONCE, before the render below — never once per failing check,
# and never per poll: 22 workers share one rate-limited account.
#
# ⛔ FAIL CLOSED, AND THE DIRECTION IS THE OPPOSITE OF lane-merge.sh's. There, an unreadable contract
# makes every check REQUIRED (the loop must not merge). Here the harm to prevent is DROPPING a red, so
# an unreadable contract must not become "nothing is required" — that would silently demote a blocking
# red to an advisory one. It is also NOT widened to "all required" (that is the bug being fixed, and
# it invents a claim the repo does not make). It is recorded as `checks_required_unknown`, every
# heading is labelled `required-status UNKNOWN`, and the fixer is told to read protection itself.
FIX_REQ_RA=""; FIX_REQ_SRC=""; FIX_REQ=""; checks_required_unknown=""
if [ -n "$FAILING_CHECKS" ]; then
  for _rc in "$SELF" "${_FIX_MOD_DIR:-$O}" "$O"; do
    [ -n "$_rc" ] || continue
    if [ -f "$_rc/repo-authority.sh" ]; then FIX_REQ_RA="$_rc/repo-authority.sh"; break; fi
  done
  if [ -z "$FIX_REQ_RA" ]; then
    checks_required_unknown="no repo-authority.sh beside this script, in \${O_WORK:-} or in \$O"
  # shellcheck source=/dev/null
  elif ! . "$FIX_REQ_RA" 2>/dev/null; then
    checks_required_unknown="$FIX_REQ_RA did not source"
  elif ! command -v resolve_required_checks >/dev/null 2>&1; then
    checks_required_unknown="$FIX_REQ_RA is stale (no resolve_required_checks)"
  else
    # `REQ` in the environment is the operator override the other consumers honour; capture it ONCE
    # because the resolver overwrites `REQ` with the resolved value IN THIS SHELL — that in-place
    # contract is the only reason `REQ_SOURCE` is readable at all (a command substitution would
    # subshell it away, which is the trap repo-authority.sh documents at its own resolver).
    REQ_OVERRIDE="${REQ:-}"; REQ=""
    resolve_required_checks "$OR" >/dev/null 2>&1 || true
    FIX_REQ="${REQ:-}"; FIX_REQ_SRC="${REQ_SOURCE:-}"
    case "$FIX_REQ_SRC" in
      protection|env)
        [ -n "$FIX_REQ" ] || checks_required_unknown="the $OR required-check read returned NO NAMES (source=$FIX_REQ_SRC)" ;;
      *)
        checks_required_unknown="the $OR required-check read FAILED (source=${FIX_REQ_SRC:-none})" ;;
    esac
    # ⛔ THE RESOLVED SET MUST NOT REACH THE CHILD AS AN OPERATOR OVERRIDE. `REQ` is documented as an
    # INPUT override, the fleet launcher EXPORTS it, and in bash an ASSIGNMENT DOES NOT CLEAR THE
    # EXPORT ATTRIBUTE — so a resolved FALLBACK left in `REQ` would be re-read by merge-one.sh (run
    # from this file as a CHILD process holding this environment) as the operator's own input, its
    # `REQ_SOURCE` would read `env`, and its UNKNOWN-contract refusal could never fire. Hand the child
    # what the OPERATOR supplied, never what we resolved — the discipline lane-merge.sh applies before
    # it spawns its chain, and for the same measured reason.
    case "$FIX_REQ_SRC" in
      env) REQ="${REQ_OVERRIDE:-}" ;;
      *)   REQ="" ;;
    esac
    REQ_OVERRIDE=""
  fi
fi

# Is THIS surface check one of the repo's required contexts?
# ⛔ THE RULE IS lane-merge.sh's `_bare_is`, DELIBERATELY, because the brief and the loop that
# dispatched it must not disagree about one head: GitHub renders a reusable workflow's job as
# `<caller> / <job>`, while the required CONTEXT is the bare name branch protection declares — so a
# suffixed name must still match its required parent. The direction makes MORE names required, never
# fewer, so a red can be promoted to "required" but never demoted to "advisory" by this matcher.
fix_req_is() {
  local n="${1:-}" r
  if [ -n "${checks_required_unknown:-}" ]; then return 0; fi
  [ -n "${FIX_REQ:-}" ] || return 1
  for r in $FIX_REQ; do
    [ "$n" = "$r" ] && return 0
    case "$n" in *" / $r") return 0 ;; esac
  done
  return 1
}

# ONE section per check: its heading, then its failing log. The heading is the ONLY thing the fixer
# reads to tell "this red blocks the merge" from "this red is informational", so it is decided ONCE.
_fix_check_section() { # <check-name>
  local c="${1:-}" rid=""
  if [ -n "${checks_required_unknown:-}" ]; then
    printf '=== failing check (required-status UNKNOWN): %s ===\n' "$c" >> "$L-failing.txt"
  elif fix_req_is "$c"; then
    printf '=== failing required check: %s ===\n' "$c" >> "$L-failing.txt"
  else
    printf '=== failing NON-required check (not one of %s required contexts — fixing it cannot unblock the merge): %s ===\n' "$OR" "$c" >> "$L-failing.txt"
  fi
  rid="$(gh pr checks "$PR" --repo "$OR" --json name,link --jq ".[]|select(.name==\"$c\")|.link" 2>/dev/null | sed -nE 's#.*/runs/([0-9]+).*#\1#p' | head -1)"
  if [ -n "${rid:-}" ]; then gh run view "$rid" --repo "$OR" --log-failed 2>/dev/null | tail -80 >> "$L-failing.txt"; fi
}

FIX_REQ_FAIL=""; FIX_ADV_FAIL=""
for c in $FAILING_CHECKS; do
  if fix_req_is "$c"; then
    FIX_REQ_FAIL="${FIX_REQ_FAIL:+$FIX_REQ_FAIL }$c"
  else
    FIX_ADV_FAIL="${FIX_ADV_FAIL:+$FIX_ADV_FAIL }$c"
  fi
done
if [ -n "$checks_required_unknown" ]; then
  echo "=== NOTE: the required-check contract for $OR could not be read ($checks_required_unknown) — EVERY heading below is 'required-status UNKNOWN' and is NOT a claim that the check blocks the merge. Treat every failing check as possibly blocking, and read this repo's branch protection yourself before concluding that any of its reds are informational ===" >> "$L-failing.txt"
  echo "[fix $PR] required-check contract UNKNOWN ($checks_required_unknown) — every failing check is labelled 'required-status UNKNOWN' in $L-failing.txt (neither widened to 'all required' nor demoted to 'advisory')" >> "$L.log"
fi
if [ -n "$FIX_ADV_FAIL" ]; then
  echo "[fix $PR] ALSO RED and NOT required by $OR (reported here so it is never silently dropped — it is not the reason for this dispatch, and fixing it cannot unblock the merge): $FIX_ADV_FAIL" >> "$L.log"
fi
# REQUIRED FIRST: the fixer's budget should meet the blocking reds first, and that ordering is a fact
# about the repo's contract rather than a preference.
for c in $FIX_REQ_FAIL $FIX_ADV_FAIL; do _fix_check_section "$c"; done
# ── FIX-ONE-REQ-SPLIT:END ─────────────────────────────────────────────────────────────────────────

# capture the reviewer's findings (the latest code-review comment on the PR)
# ── THE FINDINGS ARTIFACT MUST SAY WHAT IT IS (agent-infra#3608 / #3937) ─────────────────────────
# [fixgate-reviewread:begin]
# `gh pr view --comments > file 2>&1` sends the FAILURE TEXT into the very file the brief calls "the
# review", so neither a reader nor the brief itself could tell an UNREADABLE review from a review
# with no findings. MEASURED (2026-11-21): the artifact held exactly `GraphQL: Could not resolve to a
# PullRequest with the number of 3301.` and the brief went on to assert "a fresh-context reviewer
# found real issues". The read is observed now: success keeps the comments verbatim, and a failure
# writes a SELF-DESCRIBING header so the file can never be mistaken for a review — while the brief's
# lead stops asserting a review it did not read.
#
# ⛔ A READ THAT SUCCEEDED AND DELIVERED NOTHING IS NOT A REVIEW EITHER (#4190 review F2, P1).
# Redirected, `gh pr view --comments` prints ONLY comments and reviews (GitHub CLI manual;
# cli/cli#14714), so a PR with none yields **exit 0 and zero bytes** — and the lead was computed from
# `$FIX_REVIEW_READ_RC` ALONE, so the fixer was handed a 0-BYTE findings file under a sentence
# asserting a reviewer found real issues. That is #3608's class surviving on the success path, and
# nothing gates it: this script has no "findings must exist" precondition, and the CI-red dispatch
# path is raised by a failing check rather than by a review comment. So the content is observed too.
# The three states are therefore distinct, and each renders a lead that is TRUE of the artifact:
#   read FAILED              → NOT-A-REVIEW header + "the review could not be read"
#   read OK, NO content      → NOT-A-REVIEW header + "the PR carries no review comment"
#   read OK, content present → verbatim (the artifact IS the PR's comments), and the lead claims
#                              findings ONLY when a findings heading is actually present in it.
# ⛔ The third state's lead says "no findings heading was DETECTED", never "the PR has no review":
# the heading test is a text match, and asserting absence from a text match would rebuild the very
# defect this block removes, one level down.
FIX_REVIEW_READ_RC=0
FIX_REVIEW_LEAD="A fresh-context reviewer found real issues; the full review is the LAST comment in this file: $L-comments.txt — read it in full"
FIX_REVIEW_FINDINGS_RE='^#{1,6}[[:space:]].*P[0-3]|\[P[0-3]\]'
gh pr view "$PR" --repo "$OR" --comments > "$L-comments.raw" 2>&1 || FIX_REVIEW_READ_RC=$?
if [ "$FIX_REVIEW_READ_RC" -eq 0 ]; then
  cat "$L-comments.raw" > "$L-comments.txt"
  if ! grep -q '[^[:space:]]' "$L-comments.txt"; then
    echo "⛔ THIS FILE IS NOT A REVIEW — the comment read SUCCEEDED (gh rc=0) but delivered NO content. When its output is redirected, gh pr view --comments prints ONLY comments and reviews, so this PR carries none. There are no findings in this file because there is nothing in this file: do not invent work from an absent review." > "$L-comments.txt"
    FIX_REVIEW_LEAD="⛔ THE PR CARRIES NO REVIEW COMMENT: the comment read succeeded but delivered an EMPTY findings file ($L-comments.txt says so on its first line), so this dispatch was not raised by reviewer findings — most likely by a failing check. Fix what the CI evidence names; if there is nothing to fix, say so plainly in your final message instead of manufacturing a change."
    echo "[fix $PR] WARN: the comment read succeeded but delivered NO content — $L-comments.txt is marked NOT-A-REVIEW and the brief no longer asserts a review that does not exist (#3608/#4190)" >> "$L.log"
  elif ! grep -qE "$FIX_REVIEW_FINDINGS_RE" "$L-comments.txt"; then
    FIX_REVIEW_LEAD="the comment read SUCCEEDED and $L-comments.txt holds this PR's comments verbatim, but no findings heading ('### N. Px' or '[P1]') was DETECTED in it — read it and decide. If there is nothing to fix, say so plainly in your final message instead of manufacturing a change."
    echo "[fix $PR] WARN: the comment read succeeded but no findings heading ('### N. Px' / '[P1]') was detected in $L-comments.txt — the brief no longer asserts findings it did not see (#4190 review F2)" >> "$L.log"
  fi
else
  {
    echo "⛔ THIS FILE IS NOT A REVIEW — the comment read FAILED (gh rc=$FIX_REVIEW_READ_RC), so this PR's comments were never read. Everything below is the raw failure text, kept so the failure is VISIBLE instead of absent."
    echo
    cat "$L-comments.raw"
  } > "$L-comments.txt"
  FIX_REVIEW_LEAD="⛔ THE REVIEW COULD NOT BE READ: the comment read failed (gh rc=$FIX_REVIEW_READ_RC), so $L-comments.txt holds a FAILURE, not a review. Do NOT invent work from it — read the PR itself (gh pr view $PR --repo $OR --comments) and, if there is nothing to fix, say so plainly in your final message instead of manufacturing a change."
  echo "[fix $PR] WARN: the reviewer's findings could not be read (gh rc=$FIX_REVIEW_READ_RC) — $L-comments.txt is marked NOT-A-REVIEW and the brief no longer asserts one (#3608)" >> "$L.log"
fi
rm -f "$L-comments.raw"
# [fixgate-reviewread:end]

# ⛔ agent-infra-SPECIFIC, and NOT in the tortoise original: the NO-SEARCH bound in the test bullet
# below. The fixer's worktree normally HAS a `.venv`, but when it does not the agent used to hunt for
# an interpreter across the filesystem — a `find` over $HOME blocks for minutes and has consumed whole
# agent budgets with nothing produced. Point it at `uv sync` instead. Do NOT drop it in a re-port.
cat > "$L-fixer.txt" <<EOF
$FIX_RESEARCH_BRIEF

$FIX_DELIVERY_BRIEF

You are a FIX agent for branch \`$BR\` (PR #$PR in $OR). $FIX_REVIEW_LEAD

If \`$O/state/sickbrief-$PR.md\` exists, READ IT FIRST: it was generated from THIS PR's failing CI job — the failing check, the run id and the failing job's own log excerpt — not from a template. It is the reason this lane was dispatched when no reviewer finding named the check. ⛔ IT NAMES THE HEAD IT WAS GENERATED AT (\`head12: <12 chars>\`), and nothing deletes it: if that prefix is not the first 12 characters of THIS head ($FIX_BRIEF_HEAD), the brief is STALE — a later dispatch at a new head — so ignore it and work from the files above.

If $O/state/reviewbrief-$PR.md exists, READ IT SECOND, AND BEFORE THE WORK: it was generated from THIS PR's REVIEW RECORD — the recorded verdict, the number of open findings, and the reviewer's own artifact (a review, or a comment on this PR) — not from a template. It is the reason this lane was dispatched when no CI failure named the work, and it is the reason the harness needed no agent to notice the verdict. It names the head it was generated at (head12: <12 chars>), and nothing deletes it: if that prefix is not the first 12 characters of THIS head ($FIX_BRIEF_HEAD), it is STALE — a later dispatch at a new head — so ignore it and work from the review the PR itself carries. Fix EVERY open finding the review names; a finding you will not fix must be recorded explicitly with the reason.

If $L-failing.txt is non-empty it carries THIS PR's failing checks and their logs, and EVERY heading in it says which kind of red each one is: \`=== failing required check:\` — it is in $OR's own required set, so it BLOCKS the merge and fixing it is your job; \`=== failing NON-required check (…):\` — it is RED but it is NOT a required context of $OR, so it does NOT block the merge and fixing it will NOT unblock this PR: fix it only if the cause is real and cheap inside this same change, otherwise say plainly in your final message that you left it alone and why — never spend the attempt on it and never report it as the reason the PR cannot merge; \`=== failing check (required-status UNKNOWN):\` — the required set could NOT be read, so no heading in the file claims anything about blocking, the build state is UNKNOWN rather than green, and you must read the PR's checks AND this repo's branch protection yourself before concluding anything. That is not a reviewer finding: it is the build. A committed conflict marker (<<<<<<< / >>>>>>>) anywhere is one such cause and must be resolved, not deleted wholesale. (find every "### N. Px" / "[P0|P1|P2]" section and its "Fix:" line).

Work ONLY in this worktree: \`$WT\` (its cwd). NEVER touch the repo's main checkout. You are already on \`$BR\`.
    cd $WT && git status -sb && git log --oneline -3
If \`.venv\` is missing in the worktree, run \`uv sync --extra embeddings --extra parity\` once before testing.
If the branch is behind \`origin/main\`, integrate it first (\`git fetch origin main\` then a plain merge of origin/main) and resolve any conflicts so the PR stays mergeable.
**If this PR is CONFLICTING (mergeable=CONFLICTING), resolving the conflict IS the task** — GitHub reports it as unmergeable right now, so integrate \`origin/main\`, resolve every conflict hunk keeping both sides' intent, run the targeted tests, commit and push. If there are no review findings, the conflict is the whole job.
⛔ YOUR RESOLUTION IS A CONTENT CHANGE, SO A FRESH REVIEW IS OWED AT YOUR NEW HEAD AND THAT IS CORRECT — the review record is bound to the artifact the reviewer signed, and you have just changed the artifact. Do NOT try to make an older record "pass", do NOT touch the record, and do NOT treat \`ai-review-gate\` going red as a defect to work around: re-binding a changed diff is exactly what the gate exists to refuse. (A base-only integration that leaves the normalized diff UNCHANGED is carried, not re-reviewed: \`merge-one.sh\`'s merge path asks \`record-review.sh --check-carry\` whether the record still describes what would merge, and re-binds it when it does. That path is not yours — the controller's merge worker runs it, so do NOT invoke it — and if the ONLY thing that changed is the base, say so in your final message instead of resolving code.)

Apply a fix for EVERY finding (P3 notes: address or record explicitly). Requirements:
- Make the fix at the stated location, and add/adjust tests so they genuinely FAIL on the pre-fix code (prove non-vacuity where you can).
- Register any new test file in \`config/ci-surfaces.yml\` (correct surface) — verify with \`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python tools/ci_selection.py --integrity\`.
- Run the targeted tests: \`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest <paths> -q -p no:cacheprovider\` (plus the sibling suites the review names). Never run the whole suite. Your worktree has its own \`.venv\` — use THAT one. ⛔ Never search the filesystem for an interpreter: no \`find\`/\`rg\`/\`du\` outside this worktree (a \`find\` under \`$HOME\` blocks for many minutes and has consumed whole agent budgets, producing no result). If \`.venv\` is genuinely missing here, run \`uv sync --extra embeddings --extra parity\` once.
- Stage specific files (never \`git add -A\`); commit with \`git commit -F <message-file>\`; push: \`git -C "$WT" push origin $BR\`.
- ⛔ PUSH FROM THE WORKTREE (\`git -C "$WT"\`), NOT FROM THE HARNESS CHECKOUT. The single-owner branch guard proves ownership by a per-CHECKOUT fencing token, written into the git dir of the checkout this lane will push from; a linked worktree has its own git dir, so a push issued from anywhere else is refused as \`held-by-live\` — by this lane's OWN claim (agent-infra#3696 cycle-2 review, measured). The token is deliberately NOT copied into the shared checkout's git dir, because that would let every lane on this box push this branch, which is the hazard \`branch-claim.sh\`'s header records.
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
# ⛔ AND A BACKSTOP, NOT THE PRIMARY BOUND (agent-infra#2888). `FIX_TIMEOUT` used to default to a
# flat 2400 s, which `walltime.tsv` shows is the MEDIAN of the `fixer` population (median = p90 =
# 2400 s): the same censoring as `prfix`, one kind over. The bound that decides wedged-vs-slow is
# `lane-bound.sh`'s PROGRESS allowance (45 min, the fleet's own); this argument is only the absolute
# ceiling, so it takes the ONE default (`LANE_BACKSTOP_S`, spawn-gate.sh) instead of a local literal.
DISK_GATE_PATH="$WT" WIP_PATH="$WT" run_agent "${FIX_TIMEOUT:-$LANE_BACKSTOP_S}" "$L.log" "$L-fixer.txt" "fixer for PR #$PR"
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
  elif [ "$ar" = "${AGENT_HARNESS_SKEW_REFUSED:-83}" ]; then
    # ⛔ A HARNESS DEFECT, LIKE THE BRIEF ARM ABOVE, AND FOR THE SAME REASON (follow-up review of
    # #2991, P2): the fixer's caller and the deployed `cell-lane-preflight.sh` disagree (a usage/version
    # skew) or the copy is corrupt, so the probe measured nothing. The capability arm below would have
    # this operator repair the box or dispatch the PR elsewhere — the extension set is fine and every
    # other box runs the same pair, so both remedies send them to an event that cannot arrive.
    why="HARNESS/MISMATCH gate: this fixer's caller and the deployed cell-lane-preflight.sh do not agree (usage/version skew, or a corrupt copy), so no measurement was possible (#2991), OR the spawn gate could not resolve `capacity.sh` at all (its `nodeploy` arm, #2293 follow-up). Both are harness defects, not a property of the box and not a finding about this PR: do NOT dispatch the PR elsewhere, sync the helper pair with a VERIFIED redeploy (bash scripts/orchestrator-harness/deploy-harness.sh --repo . --o \$O) and re-run. Nothing was consumed"
  elif [ "$ar" = "${AGENT_STALE_CODE_REFUSED:-85}" ]; then
    # ⛔ A STALE CHECKOUT IS ITS OWN REMEDY, AND IT IS NOT ON A PEER (agent-infra#3932, this change's
    # review, P1-2). Before this arm the refusal landed on the CAPABILITY text below — "repair the box
    # (installed pi/extension set, provider credential) or dispatch the PR elsewhere" — and all three are
    # wrong: the model call SUCCEEDED (that is how the reading was taken), and the measured wave had every
    # cell hundreds of commits behind, so the peer refuses identically. The fix is on THIS box's checkout.
    # ⛔ AND THE REMEDY NAMES THE ARTIFACT THIS PATH MEASURED, WHICH IS NOT A BASE (this change's review,
    # P2-4, source-certain). `run_agent` is given `WIP_PATH="$WT"` above, so the probe measures the
    # FIXER'S WORKTREE — a worktree on the PR BRANCH. The base-path sentence ("git fetch, then cut the
    # worktree from origin/main") is DESTRUCTIVE here: it discards the PR's own commits, and a PR branch
    # >MAX_BEHIND behind is exactly the state a fixer gets dispatched to repair. So the remedy is MERGE
    # INTO the branch, and it says explicitly that re-cutting is not the action.
    why="STALE-CODE gate: this box completed the model call but the checkout it measured is more than CELL_PREFLIGHT_MAX_BEHIND commits behind origin/main (#3932) — work done from it produces a plausible log and a WRONG diff. On THIS path the measured artifact is the FIXER's worktree, which is the PR BRANCH: bring the branch up to date (git -C $WT merge origin/main, resolve, push) and re-run; do NOT re-cut that worktree from origin/main, which would discard the PR's own commits. Do NOT dispatch the PR elsewhere — the measured fleet state was every cell hundreds of commits behind, so a peer is likely stale too. Waiting cannot clear it. Nothing was consumed"
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
  elif [ "$ar" = "${AGENT_MEM_REFUSED:-81}" ]; then
    # ⛔ THE MEMORY GATE'S OWN WORDING (agent-infra#2387), for the reason the disk branch exists: the
    # remedies differ and the wrong name sends the operator to the wrong number. "load" would have
    # them watch a 1-min average on a box whose load is fine while the OOM killer takes lanes; the
    # memory floor clears when resident lanes FINISH, so the action is to let them (or to stop one
    # deliberately), not to wait for a load reading. Tolerant reference like the disk one, so a
    # caller run against an older $O/spawn-gate.sh (file-by-file seeding) degrades instead of
    # aborting under `set -u` before the refund below.
    # ⛔ NO DERIVATION CLAIM HERE (review P3). This line used to say "(one pi lane plus one pytest shard,
    # measured)" — the derivation of the SHIPPED DEFAULT, not of whatever `MEM_MIN_AVAIL_MB` currently
    # holds. An operator who set the floor directly read a false arithmetic in the one log they have;
    # the gate's own `[mem-gate] REFUSED` line, three lines up, states which case applies.
    why="memory gate: available memory is below MEM_MIN_AVAIL_MB — this clears when resident lanes finish, NOT by waiting for load (the [mem-gate] line in this log carries the reading, the floor and how the floor was derived)"
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
# ⛔ THE BRANCH CLAIM IS **NOT** RELEASED HERE, UNLIKE THE HEAD CLAIM ABOVE — DELIBERATELY
# (agent-infra#3696). The head claim must be dropped because the chain re-claims the head it is about
# to act on; the branch claim has no successor key, so its right lifetime is the whole lane — fixer AND
# merge chain — and the EXIT trap is what ends it.
# ⛔ WHAT THAT IS **NOT** JUSTIFIED BY (a claim this comment used to make, verified FALSE before push):
# `merge-one.sh` does NOT push this branch. It pushes only CLAIM refs (its `git push` calls are the
# claim CAS and its release, `--force-with-lease` on `refs/claims/…`), and it resolves a CONFLICTING
# head by parking it for a fixer, not by rebasing and pushing (`merge-one.sh:1336-1353`). The actor
# that pushes a dirty PR is the AGENT in a fixer lane, not the merge chain.
# The real reasons to hold it past the handoff:
#   * This lane is still the writer for $BR until it exits, and #3696's measured window is exactly a
#     peer pushing WHILE the harness reviews/lands this head (lane B pushed 2 minutes after lane A's
#     attestation was recorded). Releasing at the handoff would re-open that window for the whole
#     audit + rail, and holding it costs nothing because nothing in the chain pushes this branch.
#   * The fixer's own later `git push` (a conflict-resolution turn) still passes the guard: the
#     token fence compares the CHECKOUT's claim commit, which is ours, so `held-by-you` allows it.
# The cost of holding it: if this process dies before its EXIT trap fires, the claim strands for the
# branch lease (CLAIM_BRANCH_TTL, 4 h) and peer pushes to this branch are refused until then — a
# FAIL-CLOSED direction. Recovery, in order: (1) any same-box lane that holds the token can
# `branch-claim.sh release <br>`; (2) with no cooperating holder, `git push origin
# :refs/claims/branch-<slug>` after confirming no worker is live; (3) `claim_prune` reaps it at expiry.
# ⛔ AND THE TERM IS SHORTER THAN THIS LANE'S OWN BOUND (review P1, stated rather than implied): the
# branch key's default AND ceiling is `CLAIM_BRANCH_TTL` (14400 s) while this lane may run to
# `LANE_BACKSTOP_S` (36000 s). A lane living past 4 h therefore loses exclusive ownership: a peer's
# re-acquire CAS succeeds on the expired claim and this box's next push is refused. That is #3328's own
# recorded residual for batch branches (`claims.sh:196-212`, which deliberately does NOT raise the
# default), inherited here rather than duplicated — not a new hazard, and the per-head CAS still stops
# a peer fixing THIS head. Raising `CLAIM_BRANCH_TTL` is the knob, and it is the operator's call, because
# it raises the default AND the ceiling for every batch that does not need 10 h.
# re-run the full chain at the new head
# ⛔ RELEASE THE PR-OWNER LOCK FIRST, AND BEFORE THE CHAIN — not only at exit. `merge-one.sh` takes
# this SAME lock as its first act and, finding a live pid, exits 0 with "already owns this PR" — so
# keeping ours across the handoff would turn the fixer's own re-review into a silent no-op (the
# "fixer pushed, nothing re-recorded" strand #2132 removed). Releasing here is the same reason the
# cross-box claim above is released here: after a push the downstream worker claims the NEW head,
# and without a push the SAME head is still ours, so leaving it held would refuse our own re-review.
release_prlock
bash "${_FIX_MOD_DIR:-$O}/merge-one.sh" "$REPO" "$OR" "$PR" "$BR" >> "$L.log" 2>&1
echo "[fix $PR] end $(date)" >> "$L.log"
# ── and the fixer's `.venv` goes with it (agent-infra#1932) ─────────────────────────────────────────
# LAST, deliberately: the re-review above is dispatched from this same worktree, so reaping before it
# would make the reviewer re-sync. merge-one's reviewer has no venv of its own (it runs in the main
# checkout and its prompt says testing is unavailable to it), so nothing needs this env after this
# point. The reaper re-probes for a live holder first, so a lane still working in $WT keeps its env.
# Best-effort and loud: a failed reap logs, and never changes this worker's exit status.
reap_lane_venv "$WT" "fix $PR" >> "$L.log" 2>&1
