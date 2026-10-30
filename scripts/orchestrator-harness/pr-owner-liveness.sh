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
#     a live process whose cwd is in the PR's checkout (live-ownership.sh's `lo_pr_owned`), a LIVE pid
#     holding `mergeclaim-<PR>.lock`, a live worker record (fix-<PR>/merge-<PR>), or a cross-box lease.
#     A local lock whose pid is GONE is not ownership: it is reaped, with a logged reason, and the PR
#     goes back into the un-owned queue. This is the SAME proof-of-life `[reap]` already applies to
#     checked.txt entries (`released … no queued/dispatched/PR/lane/claim fact`).
#     ⛔ WHAT IS NOT REAPED, AND WHY (review P0, 2026-10-25). Anything alive stays: a live pid on the
#     lock, or a lock with no readable pid (the noclobber create window). Three roles write that same
#     file (`merge-one.sh`, `fix-one.sh` — held for a fixer's whole run — and `cloud-cell-doctor.sh`),
#     so a matcher on the command line NOT being merge-one.sh is not evidence of a recycled pid; it
#     reaped live fixers. Loose liveness is the fleet's convention (fix-one.sh's `prlock_live_owner`,
#     `claim_live`, the doctor) for exactly this reason. The residue — a recycled pid reads live until
#     it exits — is #1985, already filed, and it is the SAFE direction: one PR waits, versus a second
#     worker pushing to a branch a live worker already holds.
#     ⚠️ AMENDED by #3096 (review P1-1). This is a DEPARTURE FROM THE LITERAL WORD of the rule above
#     while KEEPING its rule: "empty ⇒ dead owner" stays FORBIDDEN, because the create→write window is
#     real — but an empty record that has OUTLIVED any possible create window is a MEASUREMENT, not an
#     inference, and is reclaimed through a detach-and-verify CAS (`pl_reap_no_owner`) exactly as
#     `fix-one.sh`'s `prlock_no_owner_abandoned` reclaims the SAME file. What must never happen is the
#     content-only inference, and it still cannot: outside the grace, and for every non-empty
#     unparseable body, the verdict is unchanged — LIVE, never reaped. Why it had to be amended:
#     measured 2026-10-30, this verdict answered `OWNED … never reaped` for 0-byte records 1278-2314
#     MINUTES old, and `pr_owner_live` short-circuits on that rc (`orch-loop.sh:3150`) ahead of all five
#     fixer/rail spawn arms — so the fixer arm that reclaims those records was unreachable on every box
#     where this module is deployed. The evidence for the amendment is on #3096.
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

# ── the lock ─────────────────────────────────────────────────────────────────────────────────────
pl_lock_path() { printf '%s/mergeclaim-%s.lock' "${1:-}" "${2:-}"; }

pl_lock_pid() { # <state> <pr> -> the recorded pid, or nothing
  local f; f="$(pl_lock_path "$1" "$2")"
  [ -f "$f" ] || return 1
  tr -dc '0-9' < "$f" 2>/dev/null
}

# ── WHEN "NO OWNER" IS MEASURED RATHER THAN INFERRED (#3096) ────────────────────────────────────
# ⛔ THE HOLE THESE THREE FUNCTIONS CLOSE. `pl_lock_pid` strips every non-digit, so a record that
# names NOBODY — 0 bytes, whitespace, or a `noclobber` create caught before its `echo $$` — yields the
# empty pid and lands in the "claim mid-creation" arm below, which is correct for the WINDOW and wrong
# for ever. Measured 2026-10-30 on three Linux cells: `state/mergeclaim-<PR>.lock` records were 0-byte,
# unheld and **1278-2314 MINUTES** old, so THIS verdict told the controller `OWNED … never reaped`, the
# fixer arms spawned nothing, while `pr_owned` (which needs a pid > 0) counted the same PRs UN-owned and
# held the whole issue path shut. One state, two opposite verdicts, zero lanes — and a second arm in
# `fix-one.sh` that reclaims exactly these records could never run, because this gate refuses to spawn
# the fixer in the first place (review of #3096, P1-1).
#
# THE ANSWER IS THE MEASUREMENT THE RULE ALREADY ASKED FOR, NOT A LOOSER READING. The rule above forbids
# the INFERENCE "empty ⇒ dead owner", because the create→write window is real; it does not claim the
# window is unbounded. So the question is not "is the record empty" but "has it outlived any possible
# create window" — `mmin` on the record, the same third measurement `fix-one.sh`'s
# `prlock_no_owner_abandoned` takes on the same file, and the convergent practice for a pid-less lock
# (Prefect #21388 reclaims a lock whose content is empty after an mtime threshold; `flufl.lock` expires
# by timestamp; `filelock` recommends read → RENAME → re-verify → unlink). The grace is bounded far
# above the window (microseconds) and far below the observed ages (hours).
# OUTSIDE the grace, and for any NON-empty unparseable body, nothing changes: still LIVE, still kept.
# Reaping is a DETACH-AND-VERIFY, never `rm`, so a peer that claimed in between is put back.
PL_NO_OWNER_GRACE_MIN="${PRLOCK_NO_OWNER_GRACE_MIN:-2}"
pl_record_no_owner() { # <record path> -> prints its content and rc 0 ONLY when it names NO owner
  local f="${1:-}" p
  [ -f "$f" ] || return 1
  [ -L "$f" ] && return 1
  # `cat`'s exit status, not a `|| echo 0` fallback: an UNREADABLE record is not evidence of anything,
  # and turning it into "0" would admit it to an arm that then reaps what it could not read.
  p="$(cat "$f" 2>/dev/null)" || return 1
  case "${p//[[:space:]]/}" in ''|0) printf '%s\n' "$p"; return 0 ;; esac
  return 1
}
pl_record_outlived_create_window() { # <record path> -> 0 when the RECORD itself is older than the grace
  local f="${1:-}"
  [ -f "$f" ] || return 1
  # `find -mmin` is the ONE age primitive that means the same thing on this box's GNU userland and the
  # macOS harness hosts (GNU `stat -c` and BSD `stat -f` disagree), so this is portable by construction.
  [ -n "$(find "$f" -maxdepth 0 -mmin +"${PL_NO_OWNER_GRACE_MIN:-2}" 2>/dev/null)" ]
}
pl_reap_no_owner() { # <state> <pr> -> 0 reaped · 1 nothing touched · 3 a peer's claim was detached and RESTORED · 4 …and could NOT be
  local st="${1:-}" pr="${2:-}" f side
  f="$(pl_lock_path "$st" "$pr")"
  side="$f.reclaim.$$"
  pl_record_no_owner "$f" >/dev/null || return 1
  # DETACH by `mv`, never `rm`: what was moved can be inspected, and only one racer can move a given
  # record, which is the compare-and-swap. This is `fix-one.sh`'s `prlock_takeover` shape, applied to
  # the one state it cannot see from a pid.
  mv -f "$f" "$side" 2>/dev/null || return 1
  if ! pl_record_no_owner "$side" >/dev/null; then
    # What we detached is NOT the abandoned record we measured: a peer claimed it in the instant between
    # the read and the `mv`. Put it back with `ln` (create-if-absent), so a claim displaced for an
    # instant is not lost — and say so loudly if a third party re-claimed the path first.
    if ln "$side" "$f" 2>/dev/null; then rm -f "$side"; return 3; fi
    rm -f "$side"; return 4
  fi
  rm -f "$side"
  return 0
}

# ── THE VERDICT ───────────────────────────────────────────────────────────────────────────────
# pl_verdict <state-dir> <pr> <other-proof-rc> <sess-proof-rc>
#   other-proof-rc  0 when an EXTERNAL live fact proves ownership (the cwd scan / cross-box lease —
#                   the caller computes it; this file does not duplicate `lo_pr_owned`)
#   sess-proof-rc   0 when a worker RECORD for this PR reads alive (census: `dead` excluded)
# prints one line: "OWNED<TAB><why>" or "RELEASED<TAB><why>"; rc 0 owned, 1 released.
# SIDE EFFECT: a lock whose pid is PROVABLY GONE is REMOVED, so the PR is genuinely releasable — a
# verdict that says "not owned" while the record that made it un-spawnable still sits on disk would
# leave the PR exactly as stuck as before, which is the defect, not the fix.
# ⛔ WHAT MAY BE REAPED, AND NOTHING ELSE (review P0/P1, 2026-10-25). The fleet's lock convention —
# `fix-one.sh`'s `prlock_live_owner`, `claim_live`, the doctor's `merge` role — is LOOSE LIVENESS: any
# live pid holds. Two independent reasons, both measured by review:
#   • The lock is written by three different roles (lander, fixer, doctor), and a fixer holds it for
#     its whole run, so "the pid is not a merge-one.sh" is NOT evidence the holder is unrelated.
#   • `merge-one.sh` claims with `noclobber; echo $$ > LOCK`, so the file exists EMPTY for an instant
#     before the pid is written. "Empty ⇒ dead owner" reaps a claim that is mid-creation.
# So only a NUMERIC pid that `kill -0` proves GONE is stale; empty, unparseable or alive is LIVE.
# The residue is #1985's (a recycled pid reads live until it exits) — stated, already filed, and the
# mirror image of the one that MUST NOT happen here (deleting a live worker's lock).
pl_verdict() {
  local st="${1:-}" pr="${2:-}" other="${3:-1}" sess="${4:-1}" f p why _rr
  pl_num "$pr" || { printf 'RELEASED\tnon-numeric PR ref (%s) is not a PR\n' "${pr:-<empty>}"; return 1; }
  f="$(pl_lock_path "$st" "$pr")"
  # 1. THE LIVE FACT (cwd scan / cross-box lease) — a process that is working the PR right now.
  if [ "$other" = "0" ]; then
    printf 'OWNED\t%s\n' "a live process (cwd in the PR's checkout) or a live cross-box lease holds it"
    return 0
  fi
  # 2. THE LOCAL LOCK — loose liveness, and the ONE thing that may be reaped is a pid proven GONE.
  p="$(pl_lock_pid "$st" "$pr" 2>/dev/null)"
  if [ -f "$f" ]; then
    if [ -z "${p:-}" ]; then
      # ⛔ THE CREATION WINDOW IS NOT A DEAD OWNER (fix-one.sh documents this exact hole): the record
      # exists before its pid does, so an unreadable/empty lock is a claim IN PROGRESS — for as long as
      # a create window can last. Past it, "no owner" is a MEASUREMENT rather than an inference, and
      # the verdict is the one `fix-one.sh`'s `prlock_no_owner_abandoned` already acts on: reconciled
      # here (#3096 review P1-1) so ONE state cannot read OWNED to the spawn gate and ABANDONED to the
      # fixer. Outside the grace — and for every non-empty unparseable body — nothing below fires.
      if pl_record_no_owner "$f" >/dev/null && pl_record_outlived_create_window "$f"; then
        pl_reap_no_owner "$st" "$pr"; _rr=$?
        if [ "$_rr" -eq 0 ]; then
          printf 'RELEASED\t%s\n' "lock mergeclaim-$pr.lock named NO owner (empty/whitespace/0 content, so neither liveness test could ever resolve it) and was older than ${PL_NO_OWNER_GRACE_MIN}m — no create window explains it, so the ABANDONED record was REMOVED and the PR is un-owned and releasable"
          return 1
        fi
        if [ "$_rr" -eq 4 ]; then
          printf 'OWNED\t%s\n' "lock mergeclaim-$pr.lock named NO owner and outlived the create window, but it was re-claimed in the instant before the reclaim and that peer's claim could NOT be put back (the path was re-claimed first) — the reclaimed peer's lock is GONE; REPAIR only if this repeats with no live worker (pgrep -af 'fix-one.sh|merge-one.sh|cloud-cell-doctor.sh')"
          return 0
        fi
        if [ "$_rr" -eq 3 ]; then
          printf 'OWNED\t%s\n' "lock mergeclaim-$pr.lock named NO owner but a PEER claimed it in the instant before the reclaim — that claim was RESTORED, nothing was lost, and the peer holds it"
          return 0
        fi
        # The detach never happened, so the record on disk is STILL the abandoned one — do not report a
        # peer that does not exist (the distinction step 4's unremovable arm makes for a stale pid).
        if pl_record_no_owner "$f" >/dev/null; then
          printf 'OWNED\t%s\n' "lock mergeclaim-$pr.lock names NO owner and outlived the create window, but it could NOT be detached for reclaim (state/ is unwritable) — the record is unchanged and will be re-examined next pass"
          return 0
        fi
      fi
      printf 'OWNED\t%s\n' "lock exists but carries no readable pid (a claim mid-creation, or an unreadable record) — treated LIVE, never reaped"
      return 0
    fi
    if pl_pid_alive "$p"; then
      printf 'OWNED\t%s\n' "lock pid $p is ALIVE — a lander/fixer/doctor worker holds it for its whole run (a recycled pid is indistinguishable here by design; that residue is #1985, and reaping on it would delete a live worker's lock)"
      return 0
    fi
    why="lock pid $p is GONE"
  else
    why="no lock"
  fi
  # 3. THE WORKER RECORD (census). `dead` was already excluded by the caller; `unknown` counts as
  #    alive there on purpose (a census read failure must not free a slot under a live worker).
  if [ "$sess" = "0" ]; then
    printf 'OWNED\t%s\n' "a live worker record (fix-$pr/merge-$pr) holds it"
    return 0
  fi
  # 4. NOTHING ALIVE ⇒ RELEASE, and say exactly what died.
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
