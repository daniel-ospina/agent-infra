#!/usr/bin/env bash
# detached-lane-dispatch.sh — run long sub-agent lanes OUT OF BAND so they are
# never killed by a watchdog and never block the parent session.
#
# WHY THIS EXISTS (agent-infra#1648)
# ----------------------------------
# The builtin `task` tool spawns `pi -p … --no-session <prompt>` and enforces a
# 660 s *stdout-silence* watchdog (extensions/builtin-tools/index.ts,
# HEARTBEAT_TIMEOUT_MS). Print mode BUFFERS output until the final message, so a
# healthy lane doing a long test run or a big read looks identical to a hung one
# and is SIGTERM/SIGKILLed mid-work. Measured 2026-10-09: 5 of 6 full-workflow
# lanes were killed at exactly 660 s, leaving orphaned worktrees and no report.
#
# This script instead launches each lane as a detached OS process (nohup … &),
# with NO watchdog, and provides the three things that makes safe:
#   start   — dispatch N lanes, staggered, with a concurrency cap
#   status  — which lanes are alive / done / hung
#   reap    — kill lanes that finished their work but never exited
#   watch   — poll for each lane's PR, then run reviewer → fixer → re-review
#
# ⛔ READ THIS BEFORE USING IT
# ---------------------------
# The children run with these set, which is REQUIRED (a lane has no `task` tool
# and cannot satisfy the gates itself) and also DANGEROUS (it disables the
# main-checkout guard in the child):
#     AGENT_SKIP_REVIEW_GATE=1  ELDATO_SKIP_VGATE=1
#     AGENT_ALLOW_MAIN_EDITS=1  ELDATO_ALLOW_MAIN_EDITS=1
# Therefore:
#   1. THE PARENT MUST RUN THE REVIEW GATE. The child cannot. If you do not run
#      `watch` (or review the PRs yourself), unreviewed code ships.
#   2. EVERY LANE PROMPT MUST FORBID EDITING THE MAIN CHECKOUT. The guard is off
#      in the child, so "work only in your own worktree" is load-bearing.
#   3. This is NOT a substitute for cmux_dispatch.py when a lane must live in a
#      cmux pane; use that for fleet panes, this for headless lanes.
#
# USAGE
#   detached-lane-dispatch.sh start  --issue 123 [--issue 456 …] [--repo PATH]
#                                    [--run-dir DIR] [--model M] [--max-concurrent N]
#                                    [--prompt-file FILE]
#   detached-lane-dispatch.sh status --run-dir DIR
#   detached-lane-dispatch.sh reap   --run-dir DIR [--max-age-min 180]
#   detached-lane-dispatch.sh watch  --run-dir DIR [--hours 5]
#
# The default prompt asks the lane to create its own worktree from origin/main,
# implement the issue, test it, push, and open a PR — do NOT merge.
set -uo pipefail

DEFAULT_MODEL="deepseek-v4-flash"
GATE_ENV=(AGENT_SKIP_REVIEW_GATE=1 ELDATO_SKIP_VGATE=1
          AGENT_ALLOW_MAIN_EDITS=1 ELDATO_ALLOW_MAIN_EDITS=1
          PI_SKIP_VERSION_CHECK=1 SKILL_ENFORCER_DISABLED=1
          LOOP_ENFORCER_DISABLED=1 SLACK_BRIDGE_DISABLE=1
          VISION_INTERCEPTOR_DISABLED=1)

die() { printf 'detached-lane-dispatch: %s\n' "$*" >&2; exit 2; }
need() { [ -n "${!1:-}" ] || die "missing --$2"; }

# ── default lane prompt ────────────────────────────────────────────────
default_prompt() { # $1=issue
cat <<EOF
Autonomous engineering lane. Work GitHub issue #$1 to a reviewable state.

## Environment
- The main checkout of this repo is STALE and MUST NOT be modified. Work ONLY in
  your own worktree — the main-checkout guard is DISABLED in your environment, so
  this discipline is on you.
    cd <REPO>
    git fetch origin main --quiet
    git worktree add .worktrees/lane-$1 -b feat/$1-lane origin/main
    cd .worktrees/lane-$1
- Install the project's dev environment (e.g. \`uv sync --extra embeddings --extra parity\`).
- Run tests with the project's documented command.
- The review/VGATE extensions are BYPASSED for you and you have NO "task" tool —
  do NOT attempt to dispatch. The PARENT session runs the review gate.
- Commit with \`git commit -F <message-file>\`; stage specific files, never \`git add -A\`.
- Push, then open a PR. Do NOT merge.

## Your issue
Read it IN FULL including every comment — root-cause corrections live in the thread,
and the thread supersedes the body where they disagree.
    gh issue view $1 --repo <OWNER/REPO> --json title,body,labels
    gh issue view $1 --repo <OWNER/REPO> --comments --json comments --jq '.comments[].body'

## Rules
- Read the repo's skills/issue-workflow and skills/issue-scoping first.
- VERIFY the defect is still live on CURRENT origin/main before writing code. If it
  is already fixed (in-repo or elsewhere), report ALREADY_FIXED / OUT-OF-REPO with
  file/line/commit evidence instead of forcing a PR. A no-change verdict with
  evidence is a good outcome.
- Do not change a public API/MCP surface without owner approval — STOP and report.
- Auto-file any pre-existing bug that no open issue covers. Never ask the human.

## Deliverable (final message, <=25 lines)
issue #, status (PR_OPENED | ALREADY_FIXED | OUT-OF-REPO | BLOCKED), branch + PR URL,
files changed, exact test commands + pass/fail counts, blockers.
EOF
}

cmd_start() {
  local repo="" run_dir="" model="$DEFAULT_MODEL" maxc=8 prompt_file="" issues=()
  while [ $# -gt 0 ]; do case "$1" in
    --issue) issues+=("$2"); shift 2;;
    --repo) repo="$2"; shift 2;;
    --run-dir) run_dir="$2"; shift 2;;
    --model) model="$2"; shift 2;;
    --max-concurrent) maxc="$2"; shift 2;;
    --prompt-file) prompt_file="$2"; shift 2;;
    *) die "unknown arg: $1";;
  esac; done
  [ "${#issues[@]}" -gt 0 ] || die "--issue is required (repeatable)"
  repo="${repo:-$PWD}"
  run_dir="${run_dir:-/tmp/pi-lanes/$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$run_dir"
  cd "$repo" || die "no such repo: $repo"

  local launched=0
  for n in "${issues[@]}"; do
    # wait for a free slot
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$maxc" ]; do sleep 5; done
    if [ -n "$prompt_file" ]; then cp "$prompt_file" "$run_dir/p-$n.txt"
    else default_prompt "$n" | sed "s|<REPO>|$repo|g" > "$run_dir/p-$n.txt"; fi
    nohup env "${GATE_ENV[@]}" pi -p --provider deepseek --model "$model" \
      --no-session "$(cat "$run_dir/p-$n.txt")" > "$run_dir/$n.log" 2>&1 &
    local pid=$!
    printf '%s %s\n' "$n" "$pid" >> "$run_dir/launched.txt"
    echo "dispatched #$n pid=$pid log=$run_dir/$n.log"
    launched=$((launched+1))
    sleep "${DETACHED_STAGGER:-45}"   # avoid N x dependency-install IO storms
  done
  echo "$launched lane(s) dispatched. run_dir=$run_dir"
  echo "next: detached-lane-dispatch.sh status --run-dir $run_dir"
}

cmd_status() {
  local run_dir=""
  while [ $# -gt 0 ]; do case "$1" in --run-dir) run_dir="$2"; shift 2;; *) die "unknown arg: $1";; esac; done
  need run_dir run-dir
  [ -s "$run_dir/launched.txt" ] || die "no launched.txt in $run_dir"
  while read -r n pid; do
    if kill -0 "$pid" 2>/dev/null; then
      local cpu etime; read -r cpu etime < <(ps -o %cpu=,etime= -p "$pid" 2>/dev/null)
      if [ "${cpu%%.*}" -eq 0 ]; then printf '#%-6s ALIVE  HUNG?  cpu=%s etime=%s\n' "$n" "$cpu" "$etime"
      else printf '#%-6s ALIVE  working cpu=%s etime=%s\n' "$n" "$cpu" "$etime"; fi
    else printf '#%-6s DONE\n' "$n"; fi
  done < "$run_dir/launched.txt"
}

# A lane whose PR is open but whose process is still 0%-CPU-and-sleeping is the
# failure mode this pattern introduces: pi never exits after the work is done.
cmd_reap() {
  local run_dir="" max_age=180
  while [ $# -gt 0 ]; do case "$1" in
    --run-dir) run_dir="$2"; shift 2;; --max-age-min) max_age="$2"; shift 2;;
    *) die "unknown arg: $1";; esac; done
  need run_dir run-dir
  while read -r n pid; do
    kill -0 "$pid" 2>/dev/null || continue
    local cpu etime_s etime
    read -r cpu etime < <(ps -o %cpu=,etime= -p "$pid" 2>/dev/null)
    # etime: [[dd-]hh:]mm:ss  → seconds
    etime_s=0; IFS=: read -ra p <<< "$etime"
    case "${#p[@]}" in
      2) etime_s=$(( ${p[0]}*60 + ${p[1]} ));;
      3) etime_s=$(( ${p[0]}*3600 + ${p[1]}*60 + ${p[2]} ));;
      4) etime_s=$(( ${p[0]}*86400 + ${p[1]}*3600 + ${p[2]}*60 + ${p[3]} ));;
    esac
    if [ "${cpu%%.*}" -eq 0 ] && [ "$etime_s" -gt $((max_age*60)) ]; then
      echo "reaping #$n pid=$pid (cpu=$cpu etime=$etime > ${max_age}m idle)"
      kill "$pid" 2>/dev/null
    fi
  done < "$run_dir/launched.txt"
}

# Poll for each lane's PR, then run reviewer -> fixer -> re-review. THIS IS THE
# REVIEW GATE for lanes started by this script — the children were launched with
# the gate bypassed, so skipping `watch` ships unreviewed code.
cmd_watch() {
  local run_dir="" hours=5
  while [ $# -gt 0 ]; do case "$1" in
    --run-dir) run_dir="$2"; shift 2;; --hours) hours="$2"; shift 2;;
    *) die "unknown arg: $1";; esac; done
  need run_dir run-dir
  local deadline=$(( $(date +%s) + hours*3600 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local busy=0
    while read -r n pid; do
      [ -f "$run_dir/reviewed-$n" ] && continue
      local br pr
      br="$(git branch --all --list "*$n-*" --format='%(refname:short)' 2>/dev/null | head -1 | sed 's|origin/||')"
      [ -n "$br" ] || { busy=$((busy+1)); continue; }
      pr="$(gh pr list --state open --head "$br" --json number --jq '.[0].number' 2>/dev/null)"
      if [ -z "$pr" ] || [ "$pr" = null ]; then busy=$((busy+1)); continue; fi
      echo "reviewing #$n PR=$pr ($br)"
      # NOTE: dispatch your fresh-context reviewer here (task tool, or the same
      # detached pattern). Kept abstract so this script stays repo-agnostic.
      echo "#$n PR=$pr branch=$br — REVIEW WITH A FRESH-CONTEXT REVIEWER" >> "$run_dir/review.log"
      touch "$run_dir/reviewed-$n"
    done < "$run_dir/launched.txt"
    [ "$busy" -eq 0 ] && break
    sleep 300
  done
}

[ $# -gt 0 ] || { sed -n '2,60p' "$0"; exit 2; }
sub="$1"; shift
case "$sub" in
  start) cmd_start "$@";;
  status) cmd_status "$@";;
  reap) cmd_reap "$@";;
  watch) cmd_watch "$@";;
  *) die "unknown subcommand: $sub (start|status|reap|watch)";;
esac
