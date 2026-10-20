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
- Push (\`git push -u origin $BR\`), then open a PR against main: title "<type>(<scope>): <subject> (#$N)". The body MUST contain "Closes #$N". ⛔ Do NOT reach for "Refs #$N" on work you have finished: GitHub never closes an issue from a \`Refs\`, and NOTHING in this fleet re-reads an open issue whose PR merged — measured 2026-10-13, 25 of 36 open P0-blockers already had MERGED PRs on main while 48 PRs merged in one day and 0 blockers closed (#8468). Use "Refs #$N" ONLY when a specific acceptance indicator is genuinely unmet, and then name it on its own line as \`Still open: <indicator>\` — a bare \`Refs\` is a lane failing to take a position, not a partial delivery. Include what changed and exact test evidence. Do NOT merge.
- Do NOT change the MCP tool registry or the public TortoiseSDK surface (needs owner approval — STOP and report instead).
- Read skills/issue-workflow/SKILL.md and skills/issue-scoping/SKILL.md first.
- If the defect is already fixed (in-repo or elsewhere) report ALREADY_FIXED / OUT-OF-REPO with file/line/commit evidence instead of forcing a PR. A no-change verdict with evidence is a good outcome.
- **If you add a test file, you MUST register it in \`config/ci-surfaces.yml\`** — an unregistered file is never selected on the relevant source diff and the unconditional \`manifest-integrity\` leg fails. Verify with \`python tools/ci_selection.py --integrity\`.
- Use the research skill for non-trivial research; never call web_search directly. Auto-file any pre-existing bug with no open issue. Never ask the human anything.
- Collision pre-flight is CLEAN for this issue.

$REVIEWER_BRIEF

## Deliverable (final message, <=25 lines)
issue #, status (PR_OPENED | ALREADY_FIXED | OUT-OF-REPO | BLOCKED), branch + PR URL, files changed, exact test commands + pass/fail counts, blockers.
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
# readers: `<refused_epoch>\t<yield_until>\t<gate>`, `gate` one of `load` or `disk`. The epoch is
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
  #
  # ⛔ AND THE REFUSAL IS RECORDED, so "returns to the pool" is not merely claimed here — see the
  # CAPACITY TRANSFER block above for the format and its two readers. `load` and `disk` are the only
  # two values the gate can refuse on; the disk one is chosen by the same code the exit status
  # already distinguishes, so the two can never disagree.
  if [ -n "${capacity_record:-}" ]; then
    if [ "$rc" = "${AGENT_DISK_REFUSED:-77}" ]; then _cap_gate=disk; else _cap_gate=load; fi
    _cap_now="$(date +%s)"
    if printf '%s\t%s\t%s\n' "$_cap_now" "$(( _cap_now + CAPACITY_YIELD_SECS ))" "$_cap_gate" > "$capacity_record" 2>/dev/null; then
      echo "[lane $N] capacity transfer: yielded to peers for ${CAPACITY_YIELD_SECS}s (gate=$_cap_gate) — chain-merge.sh releases refs/claims/issue-$N now instead of after 90 min, and orch-loop.sh will not re-claim it from this box while the yield is live" >> "$O/logs/lane-$N.log"
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
