#!/usr/bin/env bash
# Runs ONE lane's pi inside its own worktree (cwd must already be the worktree).
#   lane.sh <issue> <branch> <owner/repo>
set -u
N="$1"; BR="$2"; OR="$3"
# ⛔ EXPORTED, not just set: the SPAWN POINT (`pi` itself, agent-infra#1884) is a CHILD process, and a
# shell variable it cannot see makes its refusal say "untagged" about the very item it just refused.
# An operator reading "[pi-gate] REFUSED … item NOT started: <x>" must be able to name the lane.
KIND=lane; TAG="$N"; export KIND TAG
O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
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
export AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1 AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
export PI_MCP_SERVERS=none   # headless lanes use no MCP servers — saves ~25 processes/run
export PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1 LOOP_ENFORCER_DISABLED=1 SLACK_BRIDGE_DISABLE=1 VISION_INTERCEPTOR_DISABLED=1
echo "[lane $N] cwd=$(pwd) branch=$(git branch --show-current 2>/dev/null) $(date)" >> "$O/logs/lane-$N.log"
# ⛔ agent-infra-SPECIFIC, and NOT in the tortoise original: the NO-SEARCH bound in the test line
# below. A lane's worktree normally HAS a `.venv`, but when it does not the agent used to hunt for an
# interpreter across the filesystem — a `find` over $HOME blocks for minutes and has consumed whole
# agent budgets with nothing produced. Point it at `uv sync` instead. Do NOT drop it in a re-port.
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

## Rules
- The review/VGATE extensions are BYPASSED for you and you have NO "task" tool — do NOT dispatch. The PARENT runs the review gate.
- Commit with \`git commit -F <message-file>\` (repo-unique temp path per AGENTS.md "Editing Rules"). Stage specific files; never \`git add -A\`.
- Push (\`git push -u origin $BR\`), then open a PR against main: title "<type>(<scope>): <subject> (#$N)"; body must contain "Closes #$N" (or "Refs #$N" if partial), what changed, and exact test evidence. Do NOT merge.
- Do NOT change the MCP tool registry or the public TortoiseSDK surface (needs owner approval — STOP and report instead).
- Read skills/issue-workflow/SKILL.md and skills/issue-scoping/SKILL.md first.
- If the defect is already fixed (in-repo or elsewhere) report ALREADY_FIXED / OUT-OF-REPO with file/line/commit evidence instead of forcing a PR. A no-change verdict with evidence is a good outcome.
- **If you add a test file, you MUST register it in \`config/ci-surfaces.yml\`** — an unregistered file is never selected on the relevant source diff and the unconditional \`manifest-integrity\` leg fails. Verify with \`python tools/ci_selection.py --integrity\`.
- Use the research skill for non-trivial research; never call web_search directly. Auto-file any pre-existing bug with no open issue. Never ask the human anything.
- Collision pre-flight is CLEAN for this issue.

## Deliverable (final message, <=25 lines)
issue #, status (PR_OPENED | ALREADY_FIXED | OUT-OF-REPO | BLOCKED), branch + PR URL, files changed, exact test commands + pass/fail counts, blockers.
EOF
run_agent "${LANE_TIMEOUT:-2400}" "$O/logs/lane-$N.log" "$O/logs/prompt-$N.txt" "lane $N"
# Capture the status BEFORE anything else runs: `echo "… $?"` after another command reports that
# command's status, not the agent's (the defect §7.4 records for retired/do-merge.sh).
rc=$?
echo "[lane $N] exited $rc $(date)" >> "$O/logs/lane-$N.log"
# A gate refusal reports AGENT_LOAD_REFUSED (75) or AGENT_DISK_REFUSED (77); AGENT_STARTED is
# authoritative rather than the exit code, because `pi` shares the 0–255 status namespace and could
# exit 75 itself (#1720).
if [ "$AGENT_STARTED" = "0" ]; then
  # No agent ran and no PR was opened. The issue is not stranded: refresh-candidates.sh
  # un-blacklists a dispatched issue that has neither a PR nor a live lane session, so it returns
  # to the pool.
  # ⛔ NAME THE GATE THAT ACTUALLY REFUSED (#1765). They are not interchangeable: a load refusal is
  # cleared by the box quietening, a disk refusal only by reclaiming space. An operator told "load"
  # on a full filesystem waits for a remedy that cannot arrive.
  # ⛔ TOLERANT REFERENCE (review round 2, P2). `$O` is seeded file by file, so a NEW lane.sh can run
  # against an OLD `$O/spawn-gate.sh` that does not define AGENT_DISK_REFUSED — and under `set -u`
  # that aborts ABOVE the "NOT started" line, so the operator sees neither the refusal nor its
  # remedy. A pre-#1765 helper cannot return 77, so the default routes correctly to the load branch.
  if [ "$rc" = "${AGENT_DISK_REFUSED:-77}" ]; then
    echo "[lane $N] NOT started: DISK gate refused — the filesystem is below DISK_MIN_FREE_MB. Reclaim space (cloud-cell-supervisor.sh prune) before re-dispatching; this will NOT clear by waiting." >> "$O/logs/lane-$N.log"
  else
    echo "[lane $N] NOT started: load gate refused (see the line above) — issue returns to the queue" >> "$O/logs/lane-$N.log"
  fi
fi
exit "$rc"
