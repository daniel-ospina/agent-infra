#!/usr/bin/env bash
# ai-drainer.sh — periodically start ONE bounded lane against a repo's PR backlog.
#
# ⛔ WHY THIS EXISTS (measured 2026-10-24). A SECOND controller for `agent-infra` is running (its own
# state dir, gate=pipeline-compliance) and it CYCLES — but it emits no `[refresh]`/`[dispatch]` line:
# its candidate funnel stays empty, so it has nothing to dispatch. That is the remaining half of
# agent-infra #2281 ("a machine that runs SEVERAL repos needs one dispatch…"). Rather than leave a
# 70-PR backlog dependent on a human remembering to dispatch, this schedules the ONE thing that
# demonstrably works: a bounded lane that makes PRs mergeable (evidence + branch refresh) and merges
# what goes green. It is NOT a replacement for the funnel — it is the smallest thing that keeps work
# happening while that is unbuilt.
#
# ── ⛔ THE LOCK MUST OUTLIVE THE DISPATCH CALL ───────────────────────────────────────────────────
# The dispatcher (`bg-dispatch.sh` / `nonblocking-dispatch.sh`) is *asynchronous by design*: it
# backgrounds the worker and RETURNS IMMEDIATELY. So the naive shape —
#
#     take lock; dispatch; release lock            # ← WRONG, and it looks correct
#
# — holds the lock for a few hundred milliseconds while the LANE runs for up to `LANE_TIMEOUT`
# seconds. The next scheduled tick (20 min later, or a hand-run copy minutes later) finds the lock
# free and starts a SECOND lane against the same PR slice: exactly the lane storm this guard exists to
# prevent, and one that *no instrument would report*, because every tick exited 0. The lock's scope is
# therefore the LANE'S OWN LIFETIME: after dispatch we poll the lane's pid until it dies (bounded just
# above the lane's own cap so a wedged lane cannot hold the lock forever), and only then release.
# `ai-drainer.test.sh` arm (b) is the regression test for exactly this: a fake dispatcher whose pid
# outlives the tick.
#
# ── ALL THREE GUARDS ───────────────────────────────────────────────────────────────────────────
#   * LOCK — only one drainer lane at a time, ever (held for the lane's lifetime, see above).
#   * CAPACITY — never start below the harness's swap floor, or when lanes are already at the cap.
#   * SLICE — a rotating window over the open list, so repeated runs do not all hit the same PRs.
#
# ── ENV (every path/label overridable; defaults are the shipped layout) ────────────────────────
#   O                 controller runtime dir — holds `bg/` (dispatcher + per-lane pidfiles)
#                     default: $HOME/orchestrator
#   AI                this drainer's STATE dir — lock, slice cursor, brief, log
#                     default: $HOME/orchestrator-ai
#   DISPATCH          the async dispatcher to call: <name> <worktree> <brief-file> <timeout>
#                     default: $O/bg/bg-dispatch.sh, else nonblocking-dispatch.sh beside this script
#   SEED_REPO         checkout to branch the lane's worktree from
#                     default: $HOME/agent-infra-main
#   SEED_REF          ref the worktree is created at            default: origin/main
#   REPO_SLUG         owner/name the brief names              default: daniel-ospina/agent-infra
#   MAX_LANES         refuse when this many `pi` lanes are up    default: 4
#   MIN_SWAP_MB       refuse below this free-swap floor (MB)     default: 700
#   LANE_TIMEOUT      the lane's own wall-clock cap (seconds)    default: 3000
#   LANE_WAIT_MAX     how long the lock waits for the lane (s)   default: LANE_TIMEOUT+100
#   LANE_POLL_S       poll interval while holding the lock (s)   default: 30
#   PR_BUDGET         PRs one lane may process                   default: 6
#   SLICE_WIDTH       PRs per slice                              default: 10
#   SLICE_TOTAL       open-list length the slice wraps over       default: 70
#   LOG               drainer log          default: $AI/logs/ai-drainer.log
#
# TEST SEAMS (read-only overrides; production sets none of them):
#   SWAP_FREE_MB      skip the platform swap read and use this value
#   PS                `ps` binary to call                        default: ps
#   SLEEP_BIN         `sleep` binary to call                     default: sleep
#
# Exit: 0 = ran, or skipped for a guard (a skip is not a failure — the tick was correctly a no-op).
#       1 = the dispatcher REFUSED/FAILED, or the seed worktree could not be created. Those are real
#           failures and `orchestrator-bringup.sh status` renders them as FAILING (last exit != 0).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || printf '.')"

O="${O:-${HOME:?HOME is required}/orchestrator}"
AI="${AI:-${HOME:?HOME is required}/orchestrator-ai}"
LOG="${LOG:-$AI/logs/ai-drainer.log}"
SEED_REPO="${SEED_REPO:-${HOME:?HOME is required}/agent-infra-main}"
SEED_REF="${SEED_REF:-origin/main}"
REPO_SLUG="${REPO_SLUG:-daniel-ospina/agent-infra}"
MAX_LANES="${MAX_LANES:-4}"
MIN_SWAP_MB="${MIN_SWAP_MB:-700}"
LANE_TIMEOUT="${LANE_TIMEOUT:-3000}"
LANE_WAIT_MAX="${LANE_WAIT_MAX:-$((LANE_TIMEOUT + 100))}"
LANE_POLL_S="${LANE_POLL_S:-30}"
PR_BUDGET="${PR_BUDGET:-6}"
SLICE_WIDTH="${SLICE_WIDTH:-10}"
SLICE_TOTAL="${SLICE_TOTAL:-70}"
PS="${PS:-ps}"
SLEEP_BIN="${SLEEP_BIN:-sleep}"

LOCK="$AI/state/ai-drainer.lock"
BRIEF="$AI/state/drainer-brief.md"
CURSOR="$AI/state/drainer-slice"

mkdir -p "$AI/state" "$AI/logs" 2>/dev/null || {
  # ⛔ LOUD, not silent: a drainer that cannot write its own state can never take the lock, so every
  # tick would be a no-op that exits 0 — the "installed but inert" state this repo keeps removing.
  printf 'ai-drainer: cannot create %s — every tick would be a silent no-op\n' "$AI/state" >&2
  exit 1
}
say() { printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG" 2>/dev/null; }

# Every numeric seam is validated: an unvalidated value turns a fence into an abort (`[ '' -lt 700 ]`
# is a bash error) or a silent skip. A bad value falls back to the shipped default and says so.
_num() { # <name> <value> <default>
  case "${2:-}" in
    '' | *[!0-9]*) say "WARN: ${1}='${2:-}' is not a whole number — using ${3}" && printf '%s' "$3" ;;
    *) printf '%s' "$((10#$2))" ;;
  esac
}
MAX_LANES="$(_num MAX_LANES "$MAX_LANES" 4)"
MIN_SWAP_MB="$(_num MIN_SWAP_MB "$MIN_SWAP_MB" 700)"
LANE_TIMEOUT="$(_num LANE_TIMEOUT "$LANE_TIMEOUT" 3000)"
LANE_WAIT_MAX="$(_num LANE_WAIT_MAX "$LANE_WAIT_MAX" "$((LANE_TIMEOUT + 100))")"
LANE_POLL_S="$(_num LANE_POLL_S "$LANE_POLL_S" 30)"
PR_BUDGET="$(_num PR_BUDGET "$PR_BUDGET" 6)"
SLICE_WIDTH="$(_num SLICE_WIDTH "$SLICE_WIDTH" 10)"
SLICE_TOTAL="$(_num SLICE_TOTAL "$SLICE_TOTAL" 70)"
[ "$LANE_POLL_S" -ge 1 ] || { say "WARN: LANE_POLL_S=0 — using 1"; LANE_POLL_S=1; }
[ "$SLICE_TOTAL" -ge 1 ] || { say "WARN: SLICE_TOTAL=0 — using 1"; SLICE_TOTAL=1; }

# ── DISPATCHER RESOLUTION ──────────────────────────────────────────────────────────────────────
# The live box's dispatcher is `$O/bg/bg-dispatch.sh` (unversioned). The VERSIONED equivalent is
# `nonblocking-dispatch.sh`, whose argv is compatible for the first four arguments, so a fresh box
# works without a hand-copied script — and a box that has neither fails LOUDLY instead of reporting a
# tick that dispatched nothing.
if [ -z "${DISPATCH:-}" ]; then
  for _c in "$O/bg/bg-dispatch.sh" "$SELF_DIR/nonblocking-dispatch.sh"; do
    [ -f "$_c" ] && { DISPATCH="$_c"; break; }
  done
fi
if [ -z "${DISPATCH:-}" ] || [ ! -f "$DISPATCH" ]; then
  say "FAIL: no dispatcher found (looked at \$DISPATCH, $O/bg/bg-dispatch.sh, $SELF_DIR/nonblocking-dispatch.sh)"
  exit 1
fi

# ── GUARD 1: ONE AT A TIME, AND THE LOCK IS THE LANE'S OWN LIFETIME ────────────────────────────
# ──8<── lock-guard ────────────────────────────────────────────────────────────────────────────
if ! mkdir "$LOCK" 2>/dev/null; then
  pid="$(cat "$LOCK/pid" 2>/dev/null || printf '')"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    say "SKIP: drainer already running (pid $pid)"; exit 0
  fi
  say "STALE lock from pid ${pid:-?} — reclaiming"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { say "SKIP: cannot take the lock at $LOCK"; exit 0; }
fi
cleanup() { rm -rf "$LOCK" 2>/dev/null; }
trap cleanup EXIT INT TERM
# The lock names ITS OWN holder, so a concurrent tick can tell a live drainer from a stale directory.
printf '%s' "$$" >"$LOCK/pid" 2>/dev/null
# ──8<── /lock-guard ───────────────────────────────────────────────────────────────────────────
# ── GUARD 2: CAPACITY — the measured floor, not a guess ────────────────────────────────────────
# (15 lanes drove swap to 586 MB against the harness's own 600 MB floor.)
swap_free_mb="${SWAP_FREE_MB:-}"
if [ -z "$swap_free_mb" ]; then
  if [ -r /proc/meminfo ]; then
    # Linux (a cell). `SwapFree:` is in kB.
    swap_free_mb="$(awk '/^SwapFree:/ {printf "%d", $2/1024; found=1} END {exit(found?0:1)}' /proc/meminfo 2>/dev/null)" || swap_free_mb=""
  else
    swap_free_mb="$(sysctl -n vm.swapusage 2>/dev/null | sed 's/.*free = //;s/M.*//' | awk '{printf "%d", $1}')"
  fi
fi
# ⛔ AN UNREADABLE SWAP READ IS NOT "0 MB FREE" AND NOT A SKIP. Folding it into the floor test made a
# box whose probe could not answer look like a correctly-idle one (the same abstention doctrine as
# docs/ops/fleet-liveness.md). Fail CLOSED, so the inventory row reads FAILING instead of a healthy
# skip for a guard that could not be evaluated at all.
swap_free_mb="$(_num SWAP_FREE_MB "$swap_free_mb" -1)"
if [ "$swap_free_mb" -lt 0 ]; then
  say "FAIL: free swap could not be read (no /proc/meminfo SwapFree, no sysctl vm.swapusage) and SWAP_FREE_MB was not set — the capacity floor cannot be evaluated"
  exit 1
fi
lanes=0
for f in "$O"/bg/*.pid; do
  [ -f "$f" ] || continue
  p="$(tr -dc '0-9' 2>/dev/null <"$f")"
  [ -n "$p" ] || continue
  c="$("$PS" -p "$p" -o command= 2>/dev/null | head -1)"
  case "$c" in pi | pi\ *) lanes=$((lanes + 1)) ;; esac
done
if [ "$swap_free_mb" -lt "$MIN_SWAP_MB" ]; then
  say "SKIP: swap ${swap_free_mb}MB < ${MIN_SWAP_MB}MB floor"; exit 0
fi
if [ "$lanes" -ge "$MAX_LANES" ]; then
  say "SKIP: ${lanes} lanes already running (cap ${MAX_LANES})"; exit 0
fi

# ── GUARD 3: ROTATE THE SLICE — repeated runs must not all hit the same PRs ────────────────────
cursor="$(cat "$CURSOR" 2>/dev/null || printf '0')"
case "$cursor" in '' | *[!0-9]*) cursor=0 ;; *) cursor=$((10#$cursor)) ;; esac
start=$(((cursor * SLICE_WIDTH) % SLICE_TOTAL))
printf '%s' "$((cursor + 1))" >"$CURSOR"

cat >"$BRIEF" <<BRIEFEOF
You are a scheduled drainer lane for **$REPO_SLUG**. Start at PR offset **$start** in the open list,
and process **at most $PR_BUDGET PRs**.

Goal: make PRs *mergeable*, then merge the ones that go green. Evidence is the work —
\`pipeline-compliance\` blocks most PRs and its dominant letter is **[c] head-bound review record**.

Per PR:
1. \`gh pr checks <N> --repo $REPO_SLUG\` and \`gh pr view <N> --repo $REPO_SLUG --json mergeStateStatus,mergeable\`.
2. **Green + MERGEABLE** → merge (squash). Confirm the sha.
3. **Only \`bash-suites\` / \`sigpipe-grep\` red** → those causes are **already fixed on main**; the
   check-runs are stale. Refresh with
   \`gh api -X PUT repos/$REPO_SLUG/pulls/<N>/update-branch\`, then move on (do not wait).
4. **\`pipeline-compliance\` red** → read the diff, then record a REAL verdict for that head
   (\`record-review.sh\` from the controller's runtime dir, \`<N> <head-sha> <verdict> $REPO_SLUG\`), or a
   real scoping comment, or a line-initial issue ref. Re-run the repo's own compliance checker.
5. **Genuinely broken** → skip and say why in one line.

⛔ Never fabricate: no record for a diff you did not read, no clean verdict on a broken diff.
"Not sound, skipped" is a success. Never force-push, never admin-merge, never merge with a failing
check. Report to \`$AI/logs/REPORT-drainer-\$(date +%H%M).md\`: per PR one line, then totals.
BRIEFEOF

wt="$AI/wt-drainer-$(date +%H%M%S)-$$"
if ! git -C "$SEED_REPO" worktree add -f "$wt" "$SEED_REF" >/dev/null 2>&1; then
  say "FAIL: cannot create a worktree at $wt from $SEED_REPO ($SEED_REF)"
  exit 1
fi

NAME="ai-drain-$(date +%H%M%S)"
say "START: slice=$start swap=${swap_free_mb}MB lanes=$lanes worktree=$wt lane=$NAME dispatcher=$DISPATCH"
if ! bash "$DISPATCH" "$NAME" "$wt" "$BRIEF" "$LANE_TIMEOUT" >>"$LOG" 2>&1; then
  say "FAIL: dispatcher refused ($DISPATCH)"
  exit 1
fi

# ⛔ HOLD THE LOCK FOR THE LANE'S LIFETIME (see the header). The dispatcher returns as soon as the
# worker is backgrounded, so releasing here would let the next tick start a SECOND lane while the
# first still runs. Poll the lane's own pid, bounded just above the lane's cap so a wedged lane
# cannot hold this lock forever.
lane_pid="$(tr -dc '0-9' 2>/dev/null <"$O/bg/$NAME.pid")"
[ -n "$lane_pid" ] && printf '%s' "$lane_pid" >"$LOCK/pid" 2>/dev/null
# ⛔ A BEAT WHILE WE HOLD THE LOCK, in its own file. A pass can legitimately last `LANE_TIMEOUT`
# seconds, and the inventory row derives "fresh" from 2×this job's StartInterval — so a healthy
# 50-minute pass would read LATE against its own 20-minute interval. The beat is the evidence that
# the drainer is WAITING rather than gone, and it is one small file overwritten per poll instead of
# ~100 log lines. `orchestrator-bringup.sh status` reads it as this job's freshness signal.
beat() { printf '%s\n' "$(date +%s)" >"$AI/state/ai-drainer.beat" 2>/dev/null; }
beat
waited=0
while [ -n "$lane_pid" ] && kill -0 "$lane_pid" 2>/dev/null && [ "$waited" -lt "$LANE_WAIT_MAX" ]; do
  "$SLEEP_BIN" "$LANE_POLL_S"
  beat
  waited=$((waited + LANE_POLL_S))
done
if [ -n "$lane_pid" ] && kill -0 "$lane_pid" 2>/dev/null; then
  say "TIMEOUT: lane $lane_pid still alive after ${waited}s — releasing the lock"
else
  say "DONE: lane ${lane_pid:-?} finished after ${waited}s — lock released"
fi
exit 0
