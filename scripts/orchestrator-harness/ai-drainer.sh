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
#   RC_GRACE_S        how long to wait for the lane's exit-status file after its pid dies (s)
#                     default: 30 — a dispatcher that records the status from a detached watcher
#                     writes it a moment later, and calling that lane a refusal would be a false red
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
# ⛔ NOT DERIVED HERE. `$((LANE_TIMEOUT + 100))` on a RAW value is an abort: `LANE_TIMEOUT=30m` makes
# bash print "value too great for base", leaves this variable UNSET, and the `set -u` read in the
# wait loop then kills the tick mid-lock — so the guard that holds the lock for the lane's life would
# release it on the first iteration for every later tick. (`0300` is worse than an abort: it silently
# arithmetics in OCTAL, giving a 292s bound against a 300s lane.) Defaulted AFTER validation, below.
LANE_WAIT_MAX="${LANE_WAIT_MAX:-}"
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
    '') printf '%s' "$3" ;;                     # an unset seam is the DEFAULT, not a mistake
    *[!0-9]*) say "WARN: ${1}='${2}' is not a whole number — using ${3}" && printf '%s' "$3" ;;
    *) printf '%s' "$((10#$2))" ;;
  esac
}
MAX_LANES="$(_num MAX_LANES "$MAX_LANES" 4)"
MIN_SWAP_MB="$(_num MIN_SWAP_MB "$MIN_SWAP_MB" 700)"
LANE_TIMEOUT="$(_num LANE_TIMEOUT "$LANE_TIMEOUT" 3000)"
# VALIDATE FIRST, THEN DERIVE: the fallback below is computed from the already-validated integer.
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
# ⛔ THE LOCK IS CREATED ALREADY LABELLED. `mkdir "$LOCK"` and then writing `$LOCK/pid` leaves a
# window in which the lock EXISTS AND NAMES NOBODY — and a contender that sees a pid-less lock calls it
# stale and takes it, which is two lanes (the very defect the atomic reclaim was meant to close).
# So: stage a labelled directory, then `rename(2)` it into place, then VERIFY the pid inside is ours.
_lock_claim() {
  local stage="$AI/state/.ai-drainer.lock.$$" pid_now
  rm -rf "$stage" 2>/dev/null
  mkdir -p "$stage" 2>/dev/null || return 1
  printf '%s' "$$" >"$stage/pid" 2>/dev/null || { rm -rf "$stage"; return 1; }
  if [ -e "$LOCK" ]; then rm -rf "$stage" 2>/dev/null; return 2; fi
  # rename is atomic; if a competitor won, our staged dir lands INSIDE theirs, and the ownership check
  # below sees their pid — we then remove our own staged dir and report the lock as taken.
  mv "$stage" "$LOCK" 2>/dev/null || { rm -rf "$stage" 2>/dev/null; return 2; }
  pid_now="$(cat "$LOCK/pid" 2>/dev/null || printf '')"
  if [ "$pid_now" = "$$" ]; then return 0; fi
  rm -rf "$LOCK/$$" 2>/dev/null
  return 2
}
_lock_holder_alive() { # prints the live holder's pid, or nothing
  local p
  for p in "$(cat "$LOCK/pid" 2>/dev/null || printf '')" "$(cat "$LOCK/lane-pid" 2>/dev/null || printf '')"; do
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { printf '%s' "$p"; return 0; }
  done
  return 1
}
if ! _lock_claim; then
  holder="$(_lock_holder_alive)" \
    && { say "SKIP: drainer already running (pid $holder)"; exit 0; }
  pid="$(cat "$LOCK/pid" 2>/dev/null || printf '')"
  # ⛔ RECLAIM IS ATOMIC — `mv`, never `rm -rf` followed by `mkdir`. That pair is a race with a
  # measured failure: two ticks both fail to claim, both read the dead pid, both log "reclaiming"; A
  # re-creates the lock, then B's `rm -rf` DELETES A'S FRESH LOCK and B's own claim succeeds — two
  # lanes start, and A's exit trap later removes B's lock so a third can start too. `mv` of a
  # directory succeeds for exactly ONE contender.
  if mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
    say "STALE lock from pid ${pid:-?} — reclaimed atomically"
    rm -rf "$LOCK.stale.$$" 2>/dev/null
  else
    holder="$(_lock_holder_alive)" \
      && { say "SKIP: drainer already running (pid $holder)"; exit 0; }
    say "SKIP: another tick won the lock reclaim — it will dispatch, not this one"; exit 0
  fi
  _lock_claim || { say "SKIP: cannot take the lock at $LOCK"; exit 0; }
fi
cleanup() { rm -rf "$LOCK" 2>/dev/null; }
trap cleanup EXIT
# ──8<── /lock-guard ───────────────────────────────────────────────────────────────────────────
# ⛔ THE BEAT IS WRITTEN AS SOON AS THE TICK OWNS THE LOCK, BEFORE any guard that can skip. Its
# inventory row reads this file as the freshness signal, and a skipped tick is the NORMAL steady state
# on a swap-bound box — written only after a dispatch, every legitimate skip would read LATE for ever.
beat() { printf '%s\n' "$(date +%s)" >"$AI/state/ai-drainer.beat" 2>/dev/null; }
beat
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
# ⛔ LIVENESS BY ARGV SHAPE, NOT BY "THE COMMAND LINE STARTS WITH pi". The dispatchers this file
# supports record the pid of a BACKGROUNDED SUBSHELL (`( … run_agent … ) &`), whose argv is
# `bash …/nonblocking-dispatch.sh …` — `pi` is that subshell's CHILD. A `case "$c" in pi*)` therefore
# counted ZERO lanes on every real dispatch, so MAX_LANES could never fire in the exact state it
# exists for (a lane storm on a swap-bound box). Count a pidfile whose pid is ALIVE and whose argv
# names the worker runtime or one of the dispatchers that spawns it; a dead or recycled pid counts 0.
_counts_as_lane() { # <command-line>
  local c="$1" t b
  [ -n "$c" ] || return 1
  # The worker runtime is a NODE script: `pi` has a `#!/usr/bin/env node` shebang, so after exec the
  # process carries `node /opt/homebrew/bin/pi -p …` — argv[0] is `node`, and a `case "$c" in pi*)`
  # test (and any test for a bare `pi` token) misses it. Match a token whose BASENAME is `pi`, and
  # only when the token is a PATH: a shell that merely says the word (`bash -c 'echo pi'`) must not
  # count as a lane.
  for t in $c; do
    case "$t" in
      /*) b="${t##*/}"; [ "$b" = "pi" ] && return 0 ;;
      pi) return 0 ;;                        # argv[0] literally `pi` (no shebang rewrite)
    esac
  done
  for b in nonblocking-dispatch.sh bg-dispatch.sh lane.sh fix-one.sh merge-one.sh \
           chain-merge.sh dispatch-merge.sh; do
    case "$c" in *"$b"*) return 0 ;; esac
  done
  return 1
}
for f in "$O"/bg/*.pid; do
  [ -f "$f" ] || continue
  p="$(tr -dc '0-9' 2>/dev/null <"$f")"
  [ -n "$p" ] || continue
  kill -0 "$p" 2>/dev/null || continue          # a dead pidfile is not a lane
  c="$("$PS" -p "$p" -o command= 2>/dev/null | head -1)"
  _counts_as_lane "$c" && lanes=$((lanes + 1))
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
# ⛔ THE WORKTREE IS REMOVED ON EVERY EXIT PATH, because a tick is a fresh checkout: at the shipped
# 20-minute cadence an unremoved one is ~72 checkouts/day plus a `.git/worktrees` record per run in
# $SEED_REPO — the measured #1095 shape (407 worktrees / 179 GB, after which every git op fails).
# A TIMEOUT is the one path that leaves it: the lane may still be writing in it, and deleting a live
# lane's checkout is the P0 this fleet already paid for. Leftovers are pruned one per tick.
rm_worktree() {
  # ⛔ NEVER under a live lane. A signal to THIS tick (launchd bootout, a reboot, an operator's
  # Ctrl-C on a hand-run copy) says nothing about the lane, which may be mid-edit in that checkout —
  # `git worktree remove --force` there destroys uncommitted work, the P0 this fleet has already paid
  # for. The pid is the guard, and it is the same guard the timeout branch relies on.
  if [ -n "${lane_pid:-}" ] && kill -0 "$lane_pid" 2>/dev/null; then
    say "WARN: lane $lane_pid is still live — leaving worktree $wt in place (a later tick reaps it once the pid is gone)"
    return 0
  fi
  git -C "$SEED_REPO" worktree remove --force "$wt" >/dev/null 2>&1 \
    || say "WARN: could not remove the worktree at $wt — a later tick reaps it; it is named, not silent"
}
_on_signal() { beat 2>/dev/null; rm_worktree; cleanup; exit 143; }
trap 'beat 2>/dev/null; rm_worktree; cleanup' EXIT
trap _on_signal INT TERM
# ⛔ `git worktree prune` IS NOT A LEFTOVER REAPER: it only drops administrative entries whose
# directory is ALREADY GONE, and the one path that leaves a worktree (a TIMEOUT) leaves the directory
# in place — so an earlier claim that "leftovers are pruned one tick later" was false. Reap them by
# the pid the removal candidate's own name carries: a `wt-drainer-*` whose suffix pid is dead is
# reclaimable; a live one is still in use.
_reap_leftovers() {
  local w pid_suffix n=0
  for w in "$AI"/wt-drainer-*; do
    [ -d "$w" ] || continue
    pid_suffix="${w##*-}"
    case "$pid_suffix" in '' | *[!0-9]*) continue ;; esac
    kill -0 "$pid_suffix" 2>/dev/null && continue
    git -C "$SEED_REPO" worktree remove --force "$w" >/dev/null 2>&1 || rm -rf "$w" 2>/dev/null
    n=$((n + 1))
  done
  git -C "$SEED_REPO" worktree prune >/dev/null 2>&1 || true
  [ "$n" -eq 0 ] || say "REAPED: $n leftover worktree(s) whose lane was gone"
}
_reap_leftovers
if ! git -C "$SEED_REPO" worktree add -f "$wt" "$SEED_REF" >/dev/null 2>&1; then
  say "FAIL: cannot create a worktree at $wt from $SEED_REPO ($SEED_REF)"
  exit 1
fi

# ⛔ THE LANE NAME CARRIES THIS PID. A second-resolution name collides whenever two ticks dispatch in
# the same wall-clock second (a hand-run copy beside the scheduled tick — a case this file's own
# header names), and the dispatchers TRUNCATE `$O/bg/<name>.log` and `rm -f $O/bg/<name>.rc` on reuse:
# the running lane's transcript is destroyed and its exit status is lost, so this tick would poll
# ANOTHER lane's pid. Same shape as the worktree path above.
lane_pid=""
NAME="ai-drain-$(date +%H%M%S)-$$"
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
# ⛔ AN UNREADABLE LANE PID IS A FAILURE, NOT A ZERO-LENGTH WAIT. `$(tr … <"$O/bg/$NAME.pid")` masks
# a missing file, and an empty pid made the wait loop skip entirely: the tick logged "DONE: lane ?
# finished after 0s", released the lock and exited 0 while the lane it had just started was running
# — the exact failure this file's header forbids, invisible to every reader because the exit was 0.
if [ -z "$lane_pid" ]; then
  say "FAIL: dispatcher returned but $O/bg/$NAME.pid is missing or unreadable — the lock's lifetime cannot be established, so this tick reports failure instead of a false clean"
  exit 1
fi
# ⛔ THE LOCK KEEPS THE TICK'S OWN PID, and the LANE gets its own record. Overwriting `pid` with the
# lane's made the lock's "who holds this" answer point at a process that is NOT the drainer: anything
# signalling the lock killed a lane, and a reader could not tell a stuck tick from a running lane. Both
# are recorded because both mean "do not start another": a tick that died while its lane still runs
# must not have a second lane added beside it.
printf '%s' "$lane_pid" >"$LOCK/lane-pid" 2>/dev/null
# A BEAT WHILE WE HOLD THE LOCK. A pass can legitimately last `LANE_TIMEOUT` seconds, and the
# inventory row derives "fresh" from 2×this job's StartInterval — a healthy 50-minute pass would
# otherwise read LATE against its own 20-minute interval. `beat()` is defined above, together with
# the reason it is also written by every skip.
waited=0
while kill -0 "$lane_pid" 2>/dev/null && [ "$waited" -lt "$LANE_WAIT_MAX" ]; do
  "$SLEEP_BIN" "$LANE_POLL_S"
  beat
  waited=$((waited + LANE_POLL_S))
done
if kill -0 "$lane_pid" 2>/dev/null; then
  # The lane outlived its own cap: leave its worktree (it may still be writing — `rm_worktree` refuses
  # to touch a live lane's checkout) and release the lock, because holding it longer would stop every
  # future tick as well.
  say "TIMEOUT: lane $lane_pid still alive after ${waited}s — releasing the lock; worktree $wt left in place"
  exit 0
fi
# ⛔ THE LANE'S OWN EXIT STATUS IS THE VERDICT. Both shipped dispatchers write `$O/bg/<name>.rc`, and
# a spawn REFUSED by a gate (load / disk / land-backlog) dies in milliseconds — so "the pid is gone"
# is not "the work happened". Without this read, a gate refusal is indistinguishable from a completed
# lane: the tick logs DONE, exits 0, and the inventory row reads healthy while nothing was dispatched
# (the "installed but inert" state this change exists to end).
rc_file="$O/bg/$NAME.rc"
# ⛔ THE CONTRACT IS THE DISPATCHER'S, NOT THIS SCRIPT'S. `nonblocking-dispatch.sh` writes
# `$O/bg/<name>.rc` from the dying worker; the older overlay `bg-dispatch.sh` writes NO status file at
# all. Demanding one from a dispatcher that never produces it turns EVERY healthy lane on that box
# into a FAIL — a permanent false red on the one health screen, i.e. the same defect from the other
# side. So the capability is DETECTED (a dispatcher that names a `.rc` file writes one) and a
# dispatcher without it gets a WARN naming the gap, not a fabricated verdict.
if grep -q '\.rc' "$DISPATCH" 2>/dev/null; then RC_CAPABLE=1; else RC_CAPABLE=0; fi
rc="$(cat "$rc_file" 2>/dev/null || printf '')"
# A dispatcher that records the status from a DETACHED watcher writes it a moment AFTER the pid dies;
# read it with a bounded grace so a healthy lane is not called a refusal for being prompt.
g=0
while [ -z "$rc" ] && [ "$RC_CAPABLE" = "1" ] && [ "$g" -lt "${RC_GRACE_S:-30}" ]; do
  "$SLEEP_BIN" 1 2>/dev/null || "$SLEEP_BIN" 1
  g=$((g + 1))
  rc="$(cat "$rc_file" 2>/dev/null || printf '')"
done
if [ -z "$rc" ]; then
  if [ "$RC_CAPABLE" = "1" ]; then
    say "FAIL: lane $lane_pid vanished with NO exit status at $rc_file after ${g}s — it was refused or lost, not completed (see $O/bg/$NAME.log)"
    exit 1
  fi
  # Not this tick's failure to report: the DISPATCHER records no status. Say so, every tick, so the
  # gap is visible in the log rather than being either invented or hidden.
  say "WARN: lane $lane_pid finished, but $DISPATCH records no exit status ($rc_file absent) — this tick cannot tell a completed lane from a refused spawn; ship a dispatcher that writes .rc"
  exit 0
fi
if [ "$rc" != "0" ]; then
  say "FAIL: lane $lane_pid exited $rc — see $O/bg/$NAME.log"
  exit 1
fi
say "DONE: lane $lane_pid finished rc=0 after ${waited}s — lock released"
exit 0
