#!/usr/bin/env bash
# Runs ONE lane's pi inside its own worktree (cwd must already be the worktree).
#   lane.sh <issue> <branch> <owner/repo>
set -u
N="$1"; BR="$2"; OR="$3"
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
# ── the reviewer requirement is disclosed BEFORE the work (#2148) ───────────────────────────────────
# The ≥1-dispatch rule and the merge-registry gate are correct and both spoke ONLY at the finish line
# (measured 2026-10-19: three lanes did the whole job, then were refused at the rail). A lane's gate is
# BYPASSED here (the parent enforces review), so nothing in the lane's own session ever says the
# requirement out loud — it is therefore printed here, once, before any work, AND carried into the
# generated brief below. Fail LOUD if the helper is missing: an unsourced helper would silently drop
# both halves, and a lane that never heard the requirement is the defect this exists to remove.
. "$SELF/reviewer-preflight.sh" || { echo "[lane $N] FATAL: $SELF/reviewer-preflight.sh missing — refusing to start a lane that is never told a reviewer is mandatory (#2148)" >&2; exit 78; }
# ── the lane's own `.venv` is reaped on the way out (agent-infra#1932) ──────────────────────────────
# A venv is a build artifact that belongs to a RUNNING lane: `uv sync` writes it inside the worktree,
# and nothing removed it, so 5 lanes held 7.3 GB (~4 lanes, not 6, on a 32 GB box). The EXIT trap is
# the right place because at lane exit the lane is KNOWN to be done — no liveness has to be inferred —
# and it covers EVERY exit path, including a TERM'd session (bash runs EXIT traps on SIGTERM: verified).
# The reaper still re-probes for a live holder before deleting, so a worktree another lane is using,
# or a `pi`/pytest child still running after the agent returned, keeps its env. Best-effort and loud:
# `reap_lane_venv` never changes the lane's exit status, and logs every outcome to the lane log.
trap 'reap_lane_venv "$PWD" "lane $N"' EXIT
# ⛔ ...but NOT on a DRY RUN (agent-infra#2148's `LANE_DRY_RUN` seam, below). No agent ran, so the
# worktree's `.venv` has no dead holder to reap — and a preview that DELETES a build artifact is
# exactly the destructive-side-effect class a dry run exists to avoid. The trap is installed
# conditionally because it is installed before the dry-run branch is reached.
if [ "${LANE_DRY_RUN:-0}" = "1" ]; then
  trap - EXIT
fi
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none   # headless lanes use no MCP servers — saves ~25 processes/run
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
echo "[lane $N] cwd=$(pwd) branch=$(git branch --show-current 2>/dev/null) $(date)" >> "$O/logs/lane-$N.log"
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
    echo "[lane $N] ⚠️ $O/lane-merge.sh is absent (this \$O predates the lane-owns-merge change) — the brief names $LANE_MERGE_CMD instead. Sync: cp scripts/orchestrator-harness/*.sh $O/" >> "$O/logs/lane-$N.log"
  else
    # ⛔ THE BRIEF MUST SAY WHAT THIS LINE SAYS (landing-review finding 2): the merge-loop section below is
    # rendered from $MERGE_LOOP_NOTE, so this arm now really does tell the lane the tool is missing and
    # what to do instead — previously the log promised that and the brief named a path that did not exist
    # (exit 127, unmapped by the brief's own exit-code table).
    MERGE_LOOP_NOTE="⛔ THE MERGE LOOP IS NOT INSTALLED ON THIS BOX ($LANE_MERGE_CMD does not exist). Do NOT hand-roll a polling loop: if you cannot reach \`merged\`, report the exact blocker as a hand-off comment per **Handoff** below and stop. An operator can install it with: \`cp $SELF/*.sh $O/\`"
    echo "[lane $N] ⛔ $O/lane-merge.sh is ABSENT and this harness was loaded FROM $SELF — there is no other copy to name. The brief now says so and tells the lane to hand off instead of running a missing path; sync first: cp $SELF/*.sh $O/" >> "$O/logs/lane-$N.log"
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
- Push (\`git push -u origin $BR\`), then open a PR against main: title "<type>(<scope>): <subject> (#$N)". The body MUST contain "Closes #$N". ⛔ Do NOT reach for "Refs #$N" on work you have finished: GitHub never closes an issue from a \`Refs\`, and NOTHING in this fleet re-reads an open issue whose PR merged — measured 2026-10-13, 25 of 36 open P0-blockers already had MERGED PRs on main while 48 PRs merged in one day and 0 blockers closed (#8468). Use "Refs #$N" ONLY when a specific acceptance indicator is genuinely unmet, and then name it on its own line as \`Still open: <indicator>\` — a bare \`Refs\` is a lane failing to take a position, not a partial delivery. Include what changed and exact test evidence.
- Do NOT change the MCP tool registry or the public TortoiseSDK surface (needs owner approval — STOP and report instead).
- REMEMBER what load is: 22 landers share one rate-limited GitHub account. Read the PR once per loop turn, use \`lane-merge.sh\` (REST + local state), and never poll in a tight loop.
- Read skills/issue-workflow/SKILL.md and skills/issue-scoping/SKILL.md first.
- If the defect is already fixed (in-repo or elsewhere) report ALREADY_FIXED / OUT-OF-REPO with file/line/commit evidence instead of forcing a PR. A no-change verdict with evidence is a good outcome.
- **If you add a test file, you MUST register it in \`config/ci-surfaces.yml\`** — an unregistered file is never selected on the relevant source diff and the unconditional \`manifest-integrity\` leg fails. Verify with \`python tools/ci_selection.py --integrity\`.
- Use the research skill for non-trivial research; never call web_search directly. Auto-file any pre-existing bug with no open issue. Never ask the human anything.
- Collision pre-flight is CLEAN for this issue.

$REVIEWER_BRIEF

## Deliverable (final message, <=25 lines)
issue #, status (**MERGED | BLOCKED_ATTESTATION | BLOCKED_ATTEMPTS | BLOCKED | ALREADY_FIXED | OUT-OF-REPO**),
branch + PR URL, the MERGE SHA when merged, files changed, exact test commands + pass/fail counts, and — if
not merged — the single blocking reason and the PR comment URL where you recorded it. Write the status token
EXACTLY as one of those words on its own line: the fleet's merge-rate instrument reads this line, and a lane
that ends "PR_OPENED" is counted as unfinished.
EOF
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
# A gate refusal reports AGENT_LOAD_REFUSED (75) or AGENT_DISK_REFUSED (77); AGENT_STARTED is
# authoritative rather than the exit code, because `pi` shares the 0–255 status namespace and could
# exit 75 itself (#1720).
if [ "$AGENT_STARTED" = "0" ]; then
  # No agent ran and no PR was opened. The issue is not stranded: refresh-candidates.sh
  # un-blacklists a dispatched issue that has neither a PR nor a live lane session, so it returns
  # to the pool.
  #
  # ⛔ AND THE REFUSAL IS RECORDED, so "returns to the pool" is not merely claimed here — see the
  # CAPACITY TRANSFER block above for the format and its two readers. `load`, `disk` and `land` are
  # the three values the gate can refuse on, and each is chosen by the code its own caller already
  # distinguishes, so the record can never disagree with the exit status.
  if [ -n "${capacity_record:-}" ]; then
    case "$rc" in
      "${AGENT_DISK_REFUSED:-77}") _cap_gate=disk ;;
      "${AGENT_LAND_BACKLOG:-74}") _cap_gate=land ;;
      *)                          _cap_gate=load ;;
    esac
    # ⛔ THE YIELD IS GATE-INDEPENDENT, AND THAT IS A RECORDED DECISION — NOT AN OVERSIGHT TO TIDY.
    # README §7.2 says it in as many words ("**The yield is gate-independent, deliberately**"), and
    # ARCHITECTURE repeats it. A `land` refusal looks like it wants a SHORT window: it is repo-wide,
    # so every box measures the same ratio and a long stand-down only circulates the same answer.
    # That reasoning is correct and it was still REFUSED here (review cycle 2, P2), because reversing
    # a recorded decision belongs in that decision's own home with the evidence in front of the owner
    # — not in a lane's commit. What the change DOES do about it: chain-merge.sh ends the chain on
    # exit 74 immediately (no 90-minute wait), and the refusal line below says plainly that waiting
    # will not clear it. The window itself stays uniform.
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
  # cleared by the box quietening, a disk refusal only by reclaiming space. An operator told "load"
  # on a full filesystem waits for a remedy that cannot arrive.
  # ⛔ TOLERANT REFERENCE (review round 2, P2). `$O` is seeded file by file, so a NEW lane.sh can run
  # against an OLD `$O/spawn-gate.sh` that does not define AGENT_DISK_REFUSED — and under `set -u`
  # that aborts ABOVE the "NOT started" line, so the operator sees neither the refusal nor its
  # remedy. A pre-#1765 helper cannot return 77, so the default routes correctly to the load branch.
  if [ "$rc" = "${AGENT_DISK_REFUSED:-77}" ]; then
    echo "[lane $N] NOT started: DISK gate refused — the filesystem is below DISK_MIN_FREE_MB. Reclaim space (cloud-cell-supervisor.sh prune) before re-dispatching; this will NOT clear by waiting." >> "$O/logs/lane-$N.log"
  elif [ "$rc" = "${AGENT_LAND_BACKLOG:-74}" ]; then
    # ⛔ NAMED, AND NAMEABLE AS SOMETHING OTHER THAN CAPACITY (#1765's rule, applied to a gate whose
    # remedy is not on this box at all). An operator told "load gate" here waits for a box that is
    # already idle; the reading they need is the repo's open-PR count against its landing rate, which
    # is on the `[land-backlog] REFUSED` line in the same log.
    echo "[lane $N] NOT started: LAND-BACKLOG — the repo holds more open PRs than its own measured landing rate can absorb (#2409), so new creation is held. This is NOT a capacity refusal: the box is fine and waiting will not clear it. The work is the PR queue — review, rebase or land an open PR; a P0-blocker or a base-red repair is exempt by evidence. Issue returns to the pool." >> "$O/logs/lane-$N.log"
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
