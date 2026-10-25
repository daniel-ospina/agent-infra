#!/usr/bin/env bash
# pr-owner-liveness.sh — IS THE THING THAT CLAIMS THIS PR STILL ALIVE? AND WHEN THE PR PATH IS INERT,
# DOES THE BOX EVER GET TO DO ITS OTHER JOB?
#
# ⛔ THE DEFECT THIS FILE ENCODES (agent-infra#2831, measured on the live box).
#
#   [select] 11 PRs: 3 un-owned (8 owned, 0 parked/needs-human excluded) -> PR takeover:
#            NO WORKER SPAWNED this cycle (0 action(s) recorded, 0 workers)
#   [pr] PR path: NO UNIT SPAWNED this cycle — 8 row(s) with a named reason
#            (most common: 5 a worker already owns this PR)
#   [dispatch] issues BLOCKED — 3 un-owned PR(s) remain; this cycle's work is the PR queue
#
#   No such workers existed. The local fleet census read `lanes=0/0` while eight `pi` lanes were
#   alive, so "owned" was asserted from a RECORD, not from a PROCESS: the record outlived the worker,
#   the PR could be neither taken (owned) nor released (nothing releases it), and because it counted
#   as owned it also did not count as un-owned — so it never even appeared in the queue the issue
#   path was waiting on. The box was left unable to do either of the two things it exists to do.
#
# THE TWO RULES, IN CODE
# ----------------------
#  1. OWNERSHIP IS PROVEN OR RELEASED. A PR is owned iff something that DIES WITH A WORKER says so:
#     a live process whose cwd is in the PR's checkout (live-ownership.sh's `lo_pr_owned`), a live
#     merge worker whose COMMAND LINE names this PR, a live worker record (fix-<PR>/merge-<PR>), or a
#     cross-box lease. A local lock whose pid is gone — or whose pid now belongs to some unrelated
#     process (pids recycle) — is NOT ownership: it is reaped, with a logged reason, and the PR goes
#     back into the un-owned queue. This is the SAME proof-of-life `[reap]` already applies to
#     checked.txt entries (`released … no queued/dispatched/PR/lane/claim fact`).
#     ⛔ NOTHING PROVEN ⇒ RELEASE. That is the direction the owner's rule takes: the queue un-worked
#     is the failure being fixed; a double-spawned fixer is refused by the worker's own rail and the
#     cross-box CAS. And the release is only taken when NOT ONE arm proves life, so a live worker
#     holding its lock is never reaped by a weaker reading.
#  2. A DETECTOR THAT CANNOT ACT IS A LOG LINE. `[dispatch] DRAIN STALLED` detected zero merges for
#     360m, un-owned PRs, and a closed issue path — and then did nothing, cycle after cycle. The stall
#     now feeds a bounded counter of passes in which the PR path STARTED NOTHING, and at the bound the
#     issue path OPENS with one auditable line naming the counts and the bound. The counter is
#     BOUNDED and SELF-RESETTING: it only advances on a MEASURED zero spawns (an unmeasured cycle is
#     not progress and not a count), any spawn resets it, and the escape resets it after firing — so
#     the box can idle for at most N cycles before doing the other half of its job, and it can never
#     spin (one escape per N inert passes, each recorded in state/drain-escape).
#
# ⛔ OVERRIDES: the 2026-10-18 owner ruling "the issue path stays CLOSED while un-owned PRs remain, and
# a stall is never a release valve" — the ruling is kept for every stall where the PR path is WORKING
# (spawns > 0: the queue is land/capacity-bound, and opening new work would hide it). It is departed
# from ONLY in the one state the ruling did not consider: the PR path spawning NOTHING for N
# consecutive stall passes, where "drain first" has degenerated into "do neither". agent-infra#2831
# ask 2 is that escalation; the departure is bounded, logged, and named at the point of decision.
#
# SOURCED (functions only, sets no shell options — the caller's `set -u` is the caller's). Also
# executed by pr-owner-liveness.test.sh, which drives every function against REAL processes and REAL
# lock files in temp dirs.

# base-10-only integer test (leading zeros rejected: they parse as OCTAL inside $(( ))).
pl_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

# ── the process facts ────────────────────────────────────────────────────────────────────────────
pl_pid_alive() { # <pid> -> 0 alive
  local p="${1:-}"
  pl_num "$p" || return 1
  [ "$p" -gt 0 ] || return 1
  kill -0 "$p" 2>/dev/null
}

pl_cmdline() { # <pid> -> the command line, or nothing
  local p="${1:-}" _ps="${PL_PS:-ps}"
  "$_ps" -o command= -p "$p" 2>/dev/null
}

# pl_names_merge_worker <pr> <cmdline> -> 0 when the command line IS a merge worker FOR THIS PR.
# ⛔ THE TWO SPAWN FORMS ARE BOTH LOAD-BEARING (inherited from pr_owned's review R2): the controller's
# rail path spawns `bash merge-one.sh --argv state/argv-<PR>` (the number appears only in a FILENAME),
# while chain-merge.sh/fix-one.sh pass it positionally. Matching only one form made a genuinely live
# worker read UN-OWNED. The matcher is the SAME one pr_owned uses — a looser one here would let an
# unrelated recycled pid block a PR for ever, which is the defect this file exists to remove.
pl_names_merge_worker() { # <pr> <cmdline>
  local pr="${1:-}" cl="${2:-}"
  pl_num "$pr" || return 1
  [ -n "$cl" ] || return 1
  case "$cl" in
    *merge-one*|*dispatch-merge*) : ;;
    *) return 1 ;;
  esac
  case " $cl " in
    *" $pr "*) return 0 ;;
    *"/argv-$pr "*) return 0 ;;
  esac
  return 1
}

# ── the lock ─────────────────────────────────────────────────────────────────────────────────────
pl_lock_path() { printf '%s/mergeclaim-%s.lock' "${1:-}" "${2:-}"; }

pl_lock_pid() { # <state> <pr> -> the recorded pid, or nothing
  local f; f="$(pl_lock_path "$1" "$2")"
  [ -f "$f" ] || return 1
  tr -dc '0-9' < "$f" 2>/dev/null
}

# ── THE VERDICT ─────────────────────────────────────────────────────────────────────────────────
# pl_verdict <state-dir> <pr> <other-proof-rc> <sess-proof-rc>
#   other-proof-rc  0 when an EXTERNAL live fact proves ownership (the cwd scan / cross-box lease —
#                   the caller computes it; this file does not duplicate `lo_pr_owned`)
#   sess-proof-rc   0 when a worker RECORD for this PR reads alive (census: `dead` excluded)
# prints one line: "OWNED<TAB><why>" or "RELEASED<TAB><why>"; rc 0 owned, 1 released.
# SIDE EFFECT: a lock that proves nothing is REMOVED, so the PR is genuinely releasable — a verdict
# that says "not owned" while the record that made it un-spawnable still sits on disk would leave the
# PR exactly as stuck as before, which is the defect, not the fix.
pl_verdict() {
  local st="${1:-}" pr="${2:-}" other="${3:-1}" sess="${4:-1}" f p cl why
  pl_num "$pr" || { printf 'RELEASED\tnon-numeric PR ref (%s) is not a PR\n' "${pr:-<empty>}"; return 1; }
  f="$(pl_lock_path "$st" "$pr")"
  # 1. THE LIVE FACT (cwd scan / cross-box lease) — a process that is working the PR right now.
  if [ "$other" = "0" ]; then
    printf 'OWNED\t%s\n' "a live process (cwd in the PR's checkout) or a live cross-box lease holds it"
    return 0
  fi
  # 2. THE LOCAL LOCK, BOUND TO ITS WORKER. A live pid alone is NOT ownership: pids recycle, and a
  #    recycled pid then blocks this PR for ever — the dangerous direction, and self-reinforcing (the
  #    controller never spawns the worker that would delete the lock).
  p="$(pl_lock_pid "$st" "$pr" 2>/dev/null)"
  if [ -n "${p:-}" ] && pl_pid_alive "$p"; then
    cl="$(pl_cmdline "$p")"
    if pl_names_merge_worker "$pr" "$cl"; then
      printf 'OWNED\t%s\n' "lock pid $p is a live merge worker for #$pr"
      return 0
    fi
    why="pid $p is ALIVE but is not a merge worker for #$pr (\"$(printf '%s' "${cl:-<no command line>}" | cut -c1-80)\") — a recycled pid is a record, not a worker"
  elif [ -n "${p:-}" ]; then
    why="lock pid $p is GONE"
  else
    why="lock has no readable pid"
  fi
  # 3. THE WORKER RECORD (census). `dead` was already excluded by the caller; `unknown` counts as
  #    alive there on purpose (a census read failure must not free a slot under a live worker).
  if [ "$sess" = "0" ]; then
    printf 'OWNED\t%s\n' "a live worker record (fix-$pr/merge-$pr) holds it"
    return 0
  fi
  # 4. NOTHING PROVEN ⇒ RELEASE (and say exactly what died).
  if [ -f "$f" ]; then
    if rm -f "$f" 2>/dev/null; then
      printf 'RELEASED\t%s; stale lock mergeclaim-%s.lock REMOVED — the PR is un-owned and releasable\n' "$why" "$pr"
    else
      printf 'RELEASED\t%s; the stale lock mergeclaim-%s.lock could NOT be removed (state/ is unwritable) — the PR reads un-owned but the record will be re-examined next pass\n' "$why" "$pr"
    fi
    return 1
  fi
  printf 'RELEASED\t%s\n' "no live process, no live lease, no live worker record and no lock"
  return 1
}

# ── THE ESCAPE: A DETECTOR THAT CAN ACT ─────────────────────────────────────────────────────────
# The streak counts CONSECUTIVE drain-stall passes in which the PR path started NOTHING. It lives in a
# file because a controller cycle is a new process.
pl_idle_file() { printf '%s/pr-path-idle' "${1:-}"; }

pl_idle_streak() { # <state> -> the current streak (0 when absent/unreadable)
  local f n; f="$(pl_idle_file "$1")"
  n="$(sed -n 's/^streak=//p' "$f" 2>/dev/null | head -1)"
  pl_num "${n:-}" || n=0
  printf '%s\n' "$n"
}

pl_streak_reset() { # <state> — a land, an open issue path, or a spawn makes the streak meaningless
  rm -f "$(pl_idle_file "$1")" 2>/dev/null || true
}

# pl_note_pass <state> <spawns|''> <unowned> -> prints the new streak
# ⛔ AN UNMEASURED SPAWN COUNT IS NOT ZERO. With no reading the pass neither advances nor resets the
# streak: advancing would manufacture the deadlock claim out of a directory it could not read, and
# resetting would silently discard the inert passes it did measure.
# ⛔ AND A SPAWN > 0 RESETS. This is the whole difference between the two stalls: workers run and
# nothing lands (a LAND problem — the owner's ruling applies unchanged, and opening new work would
# hide it) versus nothing runs at all (the deadlock).
pl_note_pass() {
  local st="${1:-}" sp="${2:-}" un="${3:-}" f n
  f="$(pl_idle_file "$st")"
  n="$(pl_idle_streak "$st")"
  if ! pl_num "${sp:-}"; then printf '%s\n' "$n"; return 0; fi
  if [ "${sp:-0}" -gt 0 ]; then pl_streak_reset "$st"; printf '0\n'; return 0; fi
  # A measured zero spawns. Only a POSITIVE un-owned count keeps the box in the state being escaped
  # from; without it the issue path is not blocked by un-owned PRs and there is nothing to escape.
  if ! pl_num "${un:-}" || [ "${un:-0}" -le 0 ]; then printf '%s\n' "$n"; return 0; fi
  n=$(( n + 1 ))
  if [ -d "$st" ] && printf 'streak=%s\nat=%s\nspawns=0\nunowned=%s\n' "$n" "$(date +%s 2>/dev/null || true)" "$un" \
       > "$f" 2>/dev/null; then :; else n="$(pl_idle_streak "$st")"; fi
  printf '%s\n' "$n"
}

# pl_escape_bound [<raw>] -> a usable bound (default 3, never < 1)
pl_escape_bound() {
  local b="${1:-}"
  pl_num "${b:-}" || b=3
  [ "${b:-0}" -ge 1 ] || b=3
  printf '%s\n' "$b"
}

# pl_escape_open <state> <unowned> [<bound>] -> 0 when the escape must fire
# The predicate is deliberately narrow: a MEASURED positive un-owned count (an unreadable one must not
# open work on a number nobody read) and a measured streak at the bound.
pl_escape_open() {
  local st="${1:-}" un="${2:-}" b n
  b="$(pl_escape_bound "${3:-}")"
  pl_num "${un:-}" || return 1
  [ "${un:-0}" -gt 0 ] || return 1
  n="$(pl_idle_streak "$st")"
  [ "${n:-0}" -ge "$b" ]
}

# pl_escape_line <state> <unowned> <bound> -> the one auditable line (no side effect)
pl_escape_line() {
  local st="${1:-}" un="${2:-}" b="${3:-}" n
  n="$(pl_idle_streak "$st")"
  printf '[dispatch] DRAIN ESCAPE — the PR path started NOTHING for %s consecutive stalled pass(es) (bound %s) while %s un-owned PR(s) remain; OPENING the issue path for this cycle (agent-infra#2831). The 2026-10-18 "un-owned PRs first" ruling is kept whenever the PR path is WORKING (any spawn resets this streak) — it is departed from only where draining has become a NO-OP. Bounded: the streak resets on this escape, so one escape is taken per %s inert passes; the record is %s/drain-escape.' \
    "${n:-?}" "$b" "$un" "$b" "$st"
}

# pl_escape_record <state> <unowned> <spawns|''> -> writes the escape record and RESETS the streak.
# rc 0 only when the record LANDED: an escape the box cannot persist is an escape that dies with the
# pass it was printed in, and the next cycle would take it again as if nothing had happened.
pl_escape_record() {
  local st="${1:-}" un="${2:-}" sp="${3:-}" b n
  b="$(pl_escape_bound "${PL_ESCAPE_BOUND:-}")"
  n="$(pl_idle_streak "$st")"
  if [ -d "$st" ] && printf 'at=%s\nstreak=%s\nbound=%s\nunowned=%s\nspawns=%s\nissue=OPENED-BY-ESCAPE\n' \
       "$(date +%s 2>/dev/null || true)" "$n" "$b" "$un" "${sp:-UNMEASURED}" \
       > "$st/drain-escape" 2>/dev/null; then
    pl_streak_reset "$st"
    return 0
  fi
  return 1
}
