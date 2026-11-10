#!/usr/bin/env bash
# cadence-nudge.sh -- GUARANTEE the heartbeat message cadence, independent of the tick.
#
# WHY THIS EXISTS (measured 2026-10-04).
#   The owner's requirement is that the MESSAGES RECEIVED land in a 5-9 min band, not merely that
#   the loop passes. Measured over the last 14 delivered nudges: in-band 1/13, worst gap 353 min.
#   The loop was passing every ~9 min the whole time -- the messages were not.
#
#   Two independent gates were eating the message:
#     (a) step 1 (`orchestrator-heartbeat.sh`) was bounded at `TARGET - DISPATCH_BUDGET` = 300s
#         (measured 2026-10-04; today it is `TARGET - IN_PASS_RESERVE` = 390s, and the
#         DISPATCH_BUDGET reserve it was subtracted from no longer exists -- agent-infra#1874), and it
#         is killed (rc=143) under load BEFORE it reaches its `cmux send`
#         (`orchestrator-heartbeat.sh`; the number rots — grep `cmux send`). The slow reads
#         (`lane-status.py` 167-273s, `beta-progress.py`) all sit ABOVE the send in that file, so a
#         kill removes the message while the pass still logs `PASS done in 540s`.
#     (b) even when it gets there, the `Working` guard withholds the nudge unless PULSE_FIRED is set.
#
#   Both gates are defensible individually and jointly fatal to the promise: the cadence is held
#   hostage by expensive work whose completion is not guaranteed. THE CURE IS ORDERING -- ask whether a
#   message is DUE before doing anything expensive, and if it is, send a CHEAP one now. A message that
#   has already left cannot be killed by a later timeout.
#
# WHAT IT DOES. Reads the last NUDGE ATTEMPT from the log (cheap, local) -- every attempt that reaches
# the receipt stamps `NUDGE at=`, and the `delivered=` field beside it carries the verdict for that
# attempt (see the note above `last=` for why the read must not require `yes`). THREE states stamp NO
# receipt, all deliberately, and they recover on DIFFERENT clocks:
#   * the checker printed no verdict -> only the `NOT CERTIFIED` line, retried on the NEXT tick;
#   * the run was killed WITH its EXIT trap (SIGTERM, rc=143) -> it releases the lock and writes
#     nothing, so the next tick is DUE again and may RE-SEND;
#   * the run was killed WITHOUT it (SIGKILL/OOM, rc=137) -> the lock survives, so the retry waits for
#     that lock to be reclaimed (10 min if the pid is provably dead, the 20-min ceiling if nothing is
#     named -- see the lock rules below).
# None of them is counted as an attempt. If one is not due, exits immediately (the common case -- a few ms, so it never costs the pass anything). If one IS due, builds
# a minimal heartbeat from CACHED/local state only -- NO network, NO `gh`, NO lane classification -- and
# sends it by ONE OF TWO PATHS:
#   * checker usable -- `lib/cmux_payload.py verify`, which types the payload and submits it as a
#     SEPARATE Enter, then reports a verdict. Only `VERIFIED` earns `delivered=yes`.
#   * checker missing / broken / not advertising `--surface` / the `CADENCE_NUDGE_VERIFY_TIMEOUT` value
#     rejected -- ONE raw `cmux send "$MSG\n"`, recorded as `delivered=UNVERIFIED`. Nothing verifies
#     it, deliberately: the floor's job is that a beat leaves even on a broken box, and it refuses to
#     certify what it could not check. The verdict token names WHICH of those was measured
#     (`NO-USABLE-CHECKER` or `BAD-VERIFY-TIMEOUT`), because a receipt must not assert an absence the
#     box contradicts.
#   ⛔ AND THERE IS A THIRD STATE WHERE NEITHER PATH SENDS: the checker runs and prints NO verdict. The
#   floor cannot know whether it sent before dying, so it does not send again in the same tick -- it
#   reports `verdict=NO-VERDICT` and leaves the next tick to retry (see the note at the receipt). That
#   is the one state where this file's invariant ("a heartbeat leaves even on a broken box") is carried
#   by the TICK instead of by the floor, and it is stated here rather than implied.
#   ⛔ CHEAP IS THE DUE CHECK, NOT THE SEND (#3795 review P1). This paragraph used to promise the send
#   could not be slow, and that it was "one atomic `text\n` call" -- the single-call-implies-delivery
#   premise this change retires, false about the checker path, and still literally true only on the raw
#   fallback. The verification window is bounded but NOT short: up to ~413 s of cmux reads and polls on
#   a slow box (budget table at the receipt). That is why the lock at the top of this file checks WHO
#   holds it, and not only how old it is. Read this as a promise that a NOT-due pass is fast, never that
#   a due one is.
#
# It deliberately does NOT try to be as informative as the tick. The tick still runs, still classifies
# lanes, and still sends its own richer message when it survives. It no longer feeds a lane table --
# that dispatcher was retired 2026-10-17 (#1874), and its queue counts are gone from this file too.
# This is the FLOOR: a low-information heartbeat on time beats a rich one that never arrives.
set -uo pipefail

SCRIPTS="$HOME/.pi/agent/scripts"
# ⛔ THE FLEET'S ONE PROCESS-IDENTITY RULE, SOURCED BEFORE THE LOCK BLOCK USES IT (#3795 review
# cycle 6, P2). `scripts/lib/pid-identity.sh` ships in `pi-bootstrap/setup.sh`'s `lib_srcs`, i.e. it
# lands in this same `lib/` directory on every farmed box. It is OPTIONAL here for the same reason
# `beat-pair.sh` is: the floor must still beat on a partial deploy, and `_nudge_holder_state` degrades
# to the fail-closed answer (unknown -> the ceiling) when it is absent.
if [ -r "$SCRIPTS/lib/pid-identity.sh" ]; then
  # shellcheck source=lib/pid-identity.sh
  . "$SCRIPTS/lib/pid-identity.sh"
fi
STATE="$HOME/.pi/agent/state"
LOG="$STATE/orchestrator-heartbeat.log"
PULSE_MIN="${PULSE_MIN:-5}"
# A small grace so this cannot race the tick it protects: if the tick is about to deliver, we do not
# want to pre-empt it and then have BOTH in flight.
# ⛔ THE GRACE WAS WRONG AND IT PUT THE HEARTBEAT OUTSIDE THE BAND IN THE OTHER DIRECTION.
# It was `due = PULSE_MIN - GRACE` with GRACE=1, i.e. fire once 4 minutes have elapsed -- BELOW the
# owner's 5-min floor. Combined with the pass ALSO nudging, the measured gaps came out at 4m: too
# frequent, and just as out-of-band as the 54m failure in the other direction. The band is 5-9 and the
# floor matters as much as the ceiling.
# `due = PULSE_MIN` with no grace is correct now that the nudge has exactly ONE driver (cadence-timer.sh);
# the grace existed only to avoid racing a second caller, and that second caller has been removed.
GRACE=0

[ -f "$STATE/HEARTBEAT-OFF" ] && exit 0

# ⛔ ONE NUDGE AT A TIME. The timer is now fire-and-forget (see cadence-timer.sh: it must never wait on a
# send), so a slow cmux can leave one nudge in flight when the next tick fires. Without a lock, both
# would read the same "is it due?" answer from the log and both would send -- two messages seconds apart,
# which is out-of-band in the over-frequent direction. The loser does not send, and says so (a silent
# skip is how the floor died with a clean log -- see the block below); the next tick retries.
# A STALE lock is taken over -- that is the same failure that stranded the loop on a dead pid file
# earlier today, so it is handled here. What counts as stale is decided by the block below and is NOT a
# bare age bound: a holder is reclaimed only by the absolute ceiling, a pid that is provably not this
# script by the short grace, and an unidentifiable lock by the ceiling. See the rules there.
LOCK="$STATE/cadence-nudge.lock"
# ⛔ THE HOLDER'S RECORD LIVES BESIDE THE LOCK, NOT INSIDE IT, AND THE RECLAIM TOKEN IS THAT RECORD
# (#3795 review cycle 6, P1). Three load-bearing reasons:
#   * a pid file INSIDE the directory makes the previous version's bare `rmdir` reclaim FAIL
#     permanently (it would `rmdir`-fail, then `mkdir`-fail, then exit 0 for ever);
#   * an EMPTY directory is what lets `rm -rf "$LOCK"` clear a lock left by the intermediate version;
#   * the reclaim is won by `rename(2)` of THIS FILE (rule 7 below): the object we move is exactly the
#     object we judged, so judging and acting cannot straddle two different locks.
LOCKPID="$LOCK.pid"
# ⛔ THE TAKEOVER MUST NEVER RACE A LIVE NUDGE, AND MUST NEVER WEDGE FOREVER (#3795 review P1+P1).
# Both halves were measured failures, in opposite directions:
#   * AGE-ONLY (the original) raced a live nudge. The critical section now runs up to ~413 s of
#     verification (budget table at the receipt) plus pre-send work, so at 360 s (`-mmin +6`) a run
#     could still be typing -- a second tick rmdir'd its lock, found no stamp from the in-flight run,
#     read the PREVIOUS one, judged itself DUE, and BOTH typed a full heartbeat seconds apart
#     (measured: two receipts 5 s apart). Out of band in the over-frequent direction, which is the
#     exact failure the attempt-counting due read was widened to prevent.
#   * PID-ONLY (the first version of this fix) traded that for an UNBOUNDED SILENT STOP. A nudge
#     killed without its EXIT trap leaves the pid file behind; once that number is recycled by any
#     unrelated process the pid "is alive" for ever, every tick took the loser path, and NOTHING was
#     ever written -- the floor permanently dead with a clean log (measured: three consecutive runs,
#     rc=0, zero sends, zero log lines). This is not a hypothetical: `pid_max` on a cell is 4194304
#     and the live range was within 11k of it.
#
# The predicate is the one this repo ALREADY ruled for this problem
# (`scripts/orchestrator-harness/auto-rail.sh:315-345`: "a pid is not an identity ... ALIVE non-matching
# or unreadable pid is only reclaimable once the lock is OLDER than LOCK_AGE_GRACE ... the actuator was
# permanently dead with a clean log"). Applied here:
#   1. a pid is not an identity -- the holder's argv must NAME this script (`cadence-nudge.sh`, the
#      same conjunction `cloud-cell-supervisor.sh:820-828` applies). TWO ARMS, DELIBERATELY NOT ONE
#      CONJUNCTION (#3795 review cycle 8, P2 -- the prose here claimed an "AND" the code does not
#      apply): the SHAPE `<shell> <…/cadence-nudge.sh>` short-circuits and is accepted immediately,
#      and only the looser NAME arm is additionally fenced on the process not having BEGUN after the
#      record was written (`pid_began_after`).
#      ⛔ OVER-MATCHING IS DELIBERATE, AND IT IS WHY THE FALSE POSITIVE THE SUBSTRING FORM SHIPPED IS
#      KEPT HERE (#3795 review cycle 7, P2 -- this rule used to claim the opposite of what the code
#      does). A process that merely NAMES this file in its argv -- an editor with it open, `sleep 300
#      cadence-nudge.sh` -- DOES read as a holder. The opposite error is the dangerous one: a live
#      holder read as FOREIGN gets rule 4's 6-min grace, which is SHORTER than this file's own ~413 s
#      critical section, so a run could be reclaimed mid-send. The over-match is fail-closed and
#      bounded by rule 3's 20-min ceiling (its only cost is held ticks, never a duplicate send), and
#      an undatable record also keeps the holder, for the same reason. A false "foreign" is the one
#      answer this predicate must never give;
#   2. a genuine live holder is not taken over by AGE alone; it is taken over only by the ABSOLUTE
#      CEILING in rule 3. Every skip is LOGGED, because a silent skip is how the floor died once;
#   3. a genuine live holder past the 20-min ceiling IS taken over -- bounded, because past 2.7
#      intervals its message is stale anyway and a duplicate heartbeat is explicitly not the dangerous
#      duplicate a duplicate lane ORDER is (see the residual note at the receipt);
#   4. a pid that is ALIVE but not this script (recycled, or foreign) is reclaimed at the SHORT grace:
#      it is provably not the nudge that wrote it, so nothing is raced by reclaiming;
#   5. a pid file naming a DEAD process is its own state, reclaimed at a bound above the ~413 s window
#      and well under the ceiling: the holder is provably gone, so waiting the ceiling out buys nothing
#      and costs 2.7 ticks. (SIGTERM runs the EXIT trap and releases the lock; SIGKILL/OOM does not,
#      and that is this state.)
#   6. a lock naming NOTHING (no pid file, an empty or unreadable one, or one left INSIDE the dir by
#      the intermediate version) is held to the CEILING: that is the arm where only the clock stands
#      between a second contender and a live sender. MEASURED: with a short bound here, a holder whose
#      pid write had failed was reclaimed mid-run and two receipts landed 4 s apart.
#   7. THE RECLAIM IS ONE-WINNER ON THE RECORD THAT WAS JUDGED (#3795 review cycle 6, P1). This
#      replaces a fixed-name `mkdir` RECLAIM MUTEX, and that mutex was UNSOUND -- measured two ways:
#        * it FREED ITS OWN NAME. `mv "$TAKEOVER" …` makes the name available, so another contender's
#          plain `mkdir` re-claims it while the process that moved it is still inside the section;
#        * its `elif [ -e "$TAKEOVER" ]` arm then `rm -rf`'d the mutex it had just moved when that
#          mutex turned out to be FRESH -- i.e. one a LIVE holder still owned.
#      MEASURED on the pre-fix block: 5 of 27 sixteen-contender trials logged TWO OR MORE
#      `lock-reclaimed` lines, i.e. two processes inside the section whose banner called it exclusive.
#      The conversion to a duplicate SEND is deterministic: `rmdir "$LOCK"` always succeeds on the
#      always-empty directory, `rm -f "$LOCKPID"` then removes the LIVE holder's own record, and
#      `mkdir "$LOCK"` succeeds for the second process too -- so both send, and the first can no
#      longer release (its record is gone, so its ownership-checked trap declines).
#      The token is now `rename(2)` OF THE RECORD WE JUDGED. A loser's `mv` fails ENOENT, and the
#      winner re-reads what it moved and GIVES IT BACK if it does not name the pid it judged -- so a
#      judgement that straddled a newer lock cannot reclaim it. No mutex is needed: the record rename
#      already is the once-winnable primitive, and no window exists in which the lock is free for a
#      second acquisition to slip through.
NUDGE_LOCK_CEILING_MIN=20      # naming nothing, or unreadable: only the clock protects a live sender
NUDGE_LOCK_DEAD_MIN=10         # a pid that is provably gone: no reason to wait out the ceiling
NUDGE_LOCK_GRACE_MIN=6         # alive but NOT this script: provably not the holder
# ⛔ THE HOLDER PREDICATE IS `scripts/lib/pid-identity.sh`'s DOCTRINE, NOT A SUBSTRING MATCH (#3795
# review cycle 6, P2). That library is the fleet's ONE process-identity rule (#1178) and is farmed
# beside this file (`pi-bootstrap/setup.sh`'s `lib_srcs`), so it is sourced immediately above. The two
# in-tree lock predicates that already apply it are `orchestrator-bringup.sh`'s `lock_pid` and
# `cloud-cell-supervisor.sh`'s `lock_controller_pid`; this file was a fourth hand-rolled copy, and it
# had both of the defects those two were fixed for:
#   * a SUBSTRING argument match reads `cadence-nudge.sh` in ANY argv, an editor's included -- the
#     exact false positive the supervisor's own comment names. The shape is
#     `<shell> <…/cadence-nudge.sh>`;
#   * an EMPTY `ps` answer is not a death witness -- it is equally "the read failed". The library's
#     contract is 0 holder / 1 positively not / 2 unknown, and 2 must reach the caller AS 2 so it can
#     fail closed (#1178 C3: "a probe that conflated them would manufacture 'dead' out of a failed ps
#     invocation"). Here "unknown" is HELD TO THE CEILING, never given the dead arm's shorter bound.
_hpid=""
_hstate=""
_nudge_holder_state() {   # sets _hpid and _hstate ∈ absent|dead|unknown|present
  _hpid=$(tr -cd '0-9' < "$LOCKPID" 2>/dev/null)
  _hstate="unknown"
  [ -n "$_hpid" ] || { _hstate="absent"; return 0; }
  local _rc
  if command -v pid_row >/dev/null 2>&1; then
    # The library's three answers: a read that RAN and produced a table may witness absence, a read
    # that FAILED may not.
    if pid_row "$_hpid" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
    case "$_rc" in
      0) _hstate="present" ;;
      1) _hstate="dead" ;;
      *) _hstate="unknown" ;;
    esac
  else
    # Degraded (library not farmed). `kill -0` proves PRESENCE reliably but a failure cannot be split
    # into "no such process" (ESRCH) and "not our uid" (EPERM) from the shell, so a failure is
    # UNKNOWN, never death. That costs the dead arm its short bound on such a box -- the lock is then
    # held to the ceiling. Stated rather than implied: the fail-closed direction is the one this
    # predicate must fail in.
    if kill -0 "$_hpid" 2>/dev/null; then _hstate="present"; else _hstate="unknown"; fi
  fi
  return 0
}
_nudge_holder_is_ours() {  # rc 0 = _hpid is a live process that IS this script (SHAPE short-circuits;
                          # otherwise NAME, then AGE -- see the two arms below, they are NOT one conjunction)
  local _pargs _sh _arg _lm _brc
  _pargs=$(ps -p "$_hpid" -o args= 2>/dev/null)
  # ⛔ AN EMPTY ARGV IS NOT A DEATH WITNESS (#3795 review cycle 9, P2). This read used to be
  # `[ -n "$_pargs" ] || return 1`, which mapped "the argv read failed" onto FOREIGN -- and FOREIGN is
  # rule 4's 6-min grace, SHORTER than this file's own ~413 s critical section, so a live holder whose
  # `ps` hiccuped would be reclaimed MID-SEND. The caller only reaches this function on the `present`
  # arm of `_nudge_holder_state`, i.e. a SEPARATE read (`pid_row`, or `kill -0`) has already proven the
  # pid exists and is live, and a live process always has an argv -- so an empty answer here can only
  # be the READ failing. The whole file already rules this way one arm up (`_hstate=unknown` -> the
  # CEILING) and in `auto-rail.sh`'s "when the lock cannot be dated it is HELD". Hold, therefore.
  [ -n "$_pargs" ] || return 0
  # ⛔ NOT A PIPE INTO `grep -q` (#3795 review cycle 3, P2). `scripts/check-no-sigpipe-grep.sh` bans
  # that idiom and cannot see this site (`ps` is not one of its recognised producers); under
  # `set -o pipefail` a large enough payload after the match makes the pipeline report 141, which
  # `|| return 1` would read as "not this script" -- failing OPEN in the duplicate-send direction.
  IFS=' ' read -r _sh _arg _ <<<"$_pargs"
  # SHAPE first: `<shell> <…/cadence-nudge.sh>` is the exact form `cadence-timer.sh` invokes, and the
  # form cloud-cell-supervisor.sh:820-822 requires. It is the FAST PATH, never the GATE.
  # ⛔ AND IT SHORT-CIRCUITS THE AGE FENCE BELOW, DELIBERATELY (#3795 review cycle 8, P2). This docstring
  # and rule 1 used to read as one conjunction -- "SHAPE … AND the process must not have BEGUN after the
  # record" -- which is what `cloud-cell-supervisor.sh:838-845` does. Here it is an OR-with-a-fence on
  # ONE arm only, and the asymmetry is the fail-closed direction: a pid recycled onto a process whose
  # argv is literally `<bash> <…/cadence-nudge.sh>` is a LATER invocation of THIS script, so reading it
  # as the holder only holds the floor to the 20-min ceiling (harmless: it costs a delayed tick), while
  # reading it as FOREIGN would hand the lock a 6-min grace that is SHORTER than this file's ~413 s
  # critical section. The same reasoning is why a same-second `pid_began_after` answer must never be
  # able to demote this arm: a false "foreign" is the only outcome here that can duplicate a send.
  # The age fence therefore guards the NAME arm, where the alternative is trusting a bare substring.
  case "${_sh##*/}" in bash|sh|dash|zsh|ksh) case "${_arg##*/}" in cadence-nudge.sh) return 0 ;; esac ;; esac
  # ⛔ THE FALLBACK OVER-MATCHES ON PURPOSE, AND THE POLARITY IS THE WHOLE POINT. Under-matching is
  # the DANGEROUS direction here: a live holder read as "foreign" gets the 6-min grace, which is
  # SHORTER than this file's own ~413 s (6.9 min) critical section, so a run could be reclaimed
  # mid-send -- the measured two-receipts-4s-apart failure. Over-matching (an editor with this file
  # open reads as a holder) only holds the floor to the ceiling, which is fail-closed and bounded.
  # A name in argv therefore counts; the FENCE below is what removes the case that actually bit.
  grep -q 'cadence-nudge[.]sh' <<<"$_pargs" || return 1
  # AGE FENCE: a process that BEGAN after the record was written cannot be the process the record
  # names -- the recycled-pid case, which is the one that made the floor permanently dead with a
  # clean log. It is the library's `pid_began_after` when the library is present.
  _lm=$(date -r "$LOCKPID" +%s 2>/dev/null) || return 0   # cannot date the record -> not provably a
  case "$_lm" in ''|*[!0-9]*) return 0 ;; esac            # recycled pid, so keep the fail-closed arm
  if command -v pid_began_after >/dev/null 2>&1; then
    if pid_began_after "$_hpid" "$_lm"; then _brc=0; else _brc=$?; fi
    # ⛔ THE LIBRARY'S THREE ANSWERS, AND `2` IS NOT `1` (#3795 review cycle 9, P2). `pid_began_after`
    # is 0 = began after, 1 = did not, 2 = THE AGE CANNOT BE READ -- and this `case` folded 2 into
    # "not provably ours", i.e. FOREIGN, i.e. the 6-min grace that is shorter than the send window.
    # That is the same conflation `pid-identity.sh`'s own contract forbids ("a probe that conflated
    # them would manufacture 'dead' out of a failed `ps` invocation", #1178 C3) and the same one the
    # sibling `date -r` arm above already resolves the other way. Only an ANSWERED "began after"
    # demotes; a question that could not be put holds the lock to the ceiling.
    case "$_brc" in
      0) return 1 ;;   # answered: began AFTER the record -> recycled, not ours
      *) return 0 ;;   # 1 = began before (ours); 2 = cannot tell -> HOLD, fail-closed
    esac
  fi
  return 0
}
_lock_taken=0
if [ -d "$LOCK" ]; then
  _nudge_holder_state
  if [ "$_hstate" = "dead" ]; then
    # The pid is known and it is not a process: its run was killed. Reclaimed well above the
    # verification window and well below the ceiling (rule 5).
    _bound=$NUDGE_LOCK_DEAD_MIN
    _why="holder pid $_hpid is not running (its run was killed before it could release the lock)"
    _holder="none (pid $_hpid is dead)"
  elif [ "$_hstate" = "unknown" ]; then
    _bound=$NUDGE_LOCK_CEILING_MIN
    _why="the holder could not be read (pid ${_hpid:-none} — a failed read is not a death witness)"
    _holder="unreadable (pid ${_hpid:-none})"
  elif [ "$_hstate" = "absent" ]; then
    # Naming nothing at all: no pid file, an empty/unreadable one, or one left inside the dir. Only
    # the clock protects a live sender here, so the bound is the CEILING (rule 6).
    _bound=$NUDGE_LOCK_CEILING_MIN
    _why="no holder is named (no pid file, or an empty one)"
    _holder="none"
  elif _nudge_holder_is_ours; then
    _bound=$NUDGE_LOCK_CEILING_MIN
    _why="a nudge is still running (pid $_hpid)"
    _holder="$_hpid"
  else
    _bound=$NUDGE_LOCK_GRACE_MIN
    _why="pid $_hpid is alive but is not this script (recycled or foreign)"
    _holder="$_hpid"
  fi
  if [ -z "$(find "$LOCK" -maxdepth 0 -mmin +"$_bound" 2>/dev/null)" ]; then
    # Held. Say so on EVERY arm -- a silent skip is how the floor died with a clean log.
    printf '%s CADENCE-NUDGE lock-skip holder=%s bound=%sm — %s, so this pass made no attempt; the next tick retries (#1187).\n' \
      "$(date '+%m-%d %H:%M:%S')" "$_holder" "$_bound" "$_why" >> "$LOG"
    exit 0
  fi
  # STALE. Claim the reclaim by RENAMING THE RECORD WE WOKE UP FOR (rule 7). `rename(2)` succeeds for
  # exactly one contender; a loser gets ENOENT and makes no attempt.
  if [ -n "$_hpid" ]; then
    if ! mv "$LOCKPID" "$LOCKPID.doomed.$$" 2>/dev/null; then
      printf '%s CADENCE-NUDGE lock-skip holder=none — another pass reclaimed this lock first; this one made no attempt\n' \
        "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
      exit 0
    fi
    # ⛔ VERIFY WHAT WE MOVED. A judgement can straddle: we read record L1 (dead pid), and before the
    # rename another contender reclaimed L1 and wrote a LIVE record L2. The rename then wins L2. If
    # what we moved does not name the pid we judged, give it BACK and leave -- reclaiming here is how
    # a live holder's lock is stolen, and two senders leave the box.
    _moved=$(tr -cd '0-9' < "$LOCKPID.doomed.$$" 2>/dev/null)
    if [ "$_moved" != "$_hpid" ]; then
      mv "$LOCKPID.doomed.$$" "$LOCKPID" 2>/dev/null
      printf '%s CADENCE-NUDGE lock-skip holder=%s — the record changed between judging it and claiming it; this pass made no attempt\n' \
        "$(date '+%m-%d %H:%M:%S')" "${_moved:-unknown}" >> "$LOG"
      exit 0
    fi
    rm -f "$LOCKPID.doomed.$$" 2>/dev/null
  fi
  # ⛔ THE DIRECTORY IS CLAIMED BY RENAME IN BOTH ARMS, AND THE LIVE NAME IS NEVER `rm -rf`'d (#3795
  # review cycle 9, P2). The record arm used to fall through to an unconditional `rm -rf "$LOCK"`, and
  # that removed a directory it had NOT judged: once the record is renamed away the lock briefly has no
  # record, so a second contender takes the NO-RECORD arm, judges the (still old) directory stale,
  # renames it aside, removes it and re-creates it -- and the first process then deletes THAT fresh
  # directory and `mkdir`s its own. Both send. That is the identical defect round 6 removed from the
  # reclaim MUTEX ("`rm -rf`'d the mutex it had just moved when that mutex turned out to be FRESH"),
  # one object up, and the old residual note falsely called the record arm the safe one.
  #   `rename(2)` is the once-winnable primitive for the directory too: a loser's `mv` fails ENOENT and
  # makes no attempt, and the winner refuses to remove what it moved unless it is still as old as it
  # judged. The residual is unchanged and still stated: a THIRD contender can re-create the name
  # between our `mv` and this verify, where the restore can replace a fresh directory instead of the
  # one we moved -- two senders in that corner, bounded, and the consequence is a duplicate HEARTBEAT,
  # which this file already declares not the dangerous duplicate a duplicate lane ORDER is.
  if ! mv "$LOCK" "$LOCK.doomed.$$" 2>/dev/null; then
    printf '%s CADENCE-NUDGE lock-skip holder=none — another pass reclaimed this lock first; this one made no attempt\n' \
      "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
    exit 0
  fi
  if [ -z "$(find "$LOCK.doomed.$$" -maxdepth 0 -mmin +"$_bound" 2>/dev/null)" ]; then
    mv "$LOCK.doomed.$$" "$LOCK" 2>/dev/null
    printf '%s CADENCE-NUDGE lock-skip holder=none — the lock was re-created between judging it and claiming it; this pass made no attempt\n' \
      "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
    exit 0
  fi
  rm -rf "$LOCK.doomed.$$" 2>/dev/null
  printf '%s CADENCE-NUDGE lock-reclaimed bound=%sm — %s; taking the lock (#1187).\n' \
    "$(date '+%m-%d %H:%M:%S')" "$_bound" "$_why" >> "$LOG"
fi
if mkdir "$LOCK" 2>/dev/null; then
  printf '%s\n' "$$" > "$LOCKPID" 2>/dev/null || true
  _lock_taken=1
else
  # Someone took the lock between our reclaim and this `mkdir`, or the filesystem refused. Say so
  # rather than skipping silently.
  printf '%s CADENCE-NUDGE lock-skip holder=none — the lock could not be created after the reclaim; this pass made no attempt\n' \
    "$(date '+%m-%d %H:%M:%S')" >> "$LOG"
fi
[ "$_lock_taken" = "1" ] || exit 0
# ⛔ AN OWNERSHIP-CHECKED TRAP (#3795 review P2). An unconditional `rm -f "$LOCKPID"` deletes whatever
# pid is there -- if this run's own pid write failed and a later tick reclaimed the lock, this run's EXIT
# would remove the NEW holder's pid and then `rmdir` SUCCEED on an empty dir, dropping a live nudge's
# lock and re-opening the duplicate-send race. Guard both steps on the pid still being ours.
trap '_t=$(cat "$LOCKPID" 2>/dev/null | tr -cd "0-9"); if [ "$_t" = "$$" ]; then rm -f "$LOCKPID" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; fi' EXIT

now=$(date +%s)
# ⛔ `now` IS THE TICK START, AND `NUDGE at=` ON THE RECEIPT IS THIS EXACT NUMBER (#3795 review
# cycle 7, P2). Say it plainly, because two readers depend on knowing which instant it is: `gap_min`
# below and `orchestrator-heartbeat.sh:475`'s rate limiter both measure TICK-TO-TICK intervals, not
# beat-to-beat ones. Stamping the TICK is what keeps the field honest -- the number is the instant this
# pass DECIDED to send, and the pre-send distance to the actual submit is bounded by those parts of
# this file's budget that HAVE a bound: ~181 s of checker session resolution plus the `goal-state.py`
# watchdog (20 s + 3 s).
# ⛔ AND NOT BY THE REST OF IT (#3795 review cycle 8, P2). The `objective.py` reads between here and
# the send have NO timeout in this file -- the receipt's own budget note says so at "the pre-send work
# this file cannot bound" and again at "the `objective.py` reads have no timeout in this file". So δ is
# bounded by cmux/python behaviour and by those three unbounded calls, NOT by the 413 s window that
# note totals (which is the VERIFICATION window, measured from a later instant). An earlier wording of
# this paragraph said "bounded by this file's own budget", which contradicted the receipt; if
# `objective.py` hangs, the lock is held past the 450 s interval, the next tick logs `lock-skip`, and
# the beat drifts past the 9-min ceiling -- so the honest statement is the decomposition, not a bound.
# ⛔ ITS MEASURED CONSEQUENCE, STATED RATHER THAN IMPLIED: beat spacing is `450 s + δ_k − δ_(k−1)`,
# where δ is that pre-send distance, so two adjacent beats can sit closer together than `PULSE_MIN`
# (measured on a two-tick fixture: stamp gap 61 s while the real sends were 35 s apart) and can also
# exceed the 9-min ceiling when δ moves the other way. NOT repaired by stamping the submit instant
# instead: the verification TAIL (up to 138 s) runs AFTER the submit, so a post-verdict stamp is just
# as wrong in the opposite direction, and the true instant is only knowable inside the checker. What
# bounds the damage is stated, not hidden: the lock makes a concurrent second sender impossible, and
# the consequence of the drift is a duplicate HEARTBEAT, which the receipt's residual note already
# declares not the dangerous duplicate a duplicate lane ORDER is. Recorded on #1187 rather than
# implied to be absent.
# ⛔ THE FIRST VERSION OF THIS LINE WAS WRONG AND SILENTLY SO. It read:
#     last=$(grep -o 'NUDGE at=[0-9]* delivered=yes' "$LOG" | tail -1 | grep -o '[0-9]*$')
# The second grep is `[0-9]*$`, which matches the EMPTY STRING at the end of `...delivered=yes` --
# `*` allows zero digits -- so `last` was always empty -> 0, and the very first run logged
# `gap=29852468m` (56 years) while still delivering. A check that computes a nonsense number and
# proceeds anyway is the same shape as the gates this file exists to catch. Capture the digits with
# an ANCHORED pattern that cannot match empty (`[0-9]\{1,\}` / `[0-9]+`), or not at all.
# ⛔ THE DUE READ COUNTS EVERY ATTEMPT, NOT ONLY THE VERIFIED ONES — and the receipt it reads has the
# same SHAPE this file writes, in the same log. (It is NOT written by this file alone:
# `orchestrator-heartbeat.sh` writes the same shape beside it from a weaker predicate — see the note at
# the send below. Counting those attempts is still what the floor wants: an attempt is an attempt.)
# It used to require `delivered=yes`, which was correct only while
# `delivered=yes` was written unconditionally (#1187): now that the field carries the checker's
# verdict, requiring `yes` would make a run of unprovable verifications (`the orchestrator was
# mid-turn, its transcript had not flushed`) look like NO nudge for a growing gap — so the floor
# would re-fire on every tick and flood the pane. The band is 5-9 min; an attempt 5 min ago is an
# attempt, and the verdict beside it says whether it was proven. Both facts are on the line.
last=$(sed -n 's/.*NUDGE at=\([0-9][0-9]*\) delivered=.*/\1/p' "$LOG" 2>/dev/null | tail -1)
# Fail LOUD on an unparseable timestamp rather than treating it as epoch 0: if the log format
# changes, a silent 0 means "due" on EVERY pass and the floor turns into a flood.
#
# ⛔ HERE-STRING, NOT A PIPE INTO `grep -q` -- because of a POLICY BAN, not because this call site
# is broken. `scripts/check-no-sigpipe-grep.sh` (#841) bans the idiom outright, and it cannot do
# otherwise: the SIGPIPE race needs ALL of `pipefail` active, a payload larger than the ~64 KiB pipe
# buffer AFTER the match, and the match on an early line -- a property of the PAYLOAD, which the
# guard cannot see. So the ban is unconditional and this site must comply.
#
# State the mechanism honestly for THIS site: `last` is captured digits-only from an anchored `sed`
# (one line, ~10 bytes), far below the ~64 KiB window, so the race does NOT occur here today. The
# old form would have been correct at runtime and is still refused. What the ban protects is the
# FUTURE: the same idiom at a site whose payload does grow would silently invert a successful match
# into "could not parse" and `exit 0` without sending. A here-string has no upstream writer, so its
# status is grep's own at any payload size, which is why it is the sanctioned form.
if ! grep -qE '^[0-9]{9,}$' <<<"${last:-}"; then
  printf '%s CADENCE-NUDGE: could not parse a previous NUDGE timestamp from %s -- not sending\n' \
    "$(date '+%m-%d %H:%M:%S')" "$LOG" >> "$LOG"
  exit 0
fi
gap_min=$(( (now - last) / 60 ))
due=$(( PULSE_MIN - GRACE ))
[ "$gap_min" -lt "$due" ] && exit 0     # not due -- the cheap, common path

# ---- build the message from cached/local state ONLY (no network) ----
OBJ="$STATE/objective.last"
q=""
if [ -f "$OBJ" ]; then
  q=$(grep -oE '(open|drafts|nondraft|blocked|conflicting)=[^ ,}]*' "$OBJ" 2>/dev/null | tr '\n' ' ' | cut -c1-160)
fi
# ⛔ THE DURABLE QUEUE-COUNTS ARE GONE WITH THE QUEUE DISPATCHER (agent-infra#1874). Three reads
# lived here: `nq`/`nrem` counted rows in `state/queues/LANDABLE.tsv|REMEDY.tsv`, and `qcount`
# grepped the objective line for `open=`. ALL THREE were already DEAD -- nothing interpolated them
# into `$MSG` or the log line (the NUDGE line's `queue=[%s]` carries `$q` from objective.last).
# With the lane-table dispatcher retired and `refresh-queues.py` no longer run by the beat, a count
# read here would report a FROZEN number as live backlog: a stale signal is worse than none.

# ---- GOAL + LANE STATE: the two things the owner named as missing -----------------------------
# The owner's requirement (2026-10-05): the heartbeat must carry THE GOAL, the CONTEXT (the graph),
# and the STATE (a lane recap) -- not a meta-note about which sender fired. The floor previously
# announced only its own cadence, which told the orchestrator nothing it could act on.
# GOAL is a persisted one-liner (no network); LANES comes from state/lane-recap.last, which
# orchestrator-heartbeat.sh now writes BEFORE its slow steps (that file exists because the rich
# tick was being killed at its 540s budget and never reached its own cmux send).
# ⛔ THE GOAL MAP IS QUERIED FROM THE GRAPH, LIVE — THERE IS NO DOCUMENT (owner directive, 2026-10-09).
# This used to read `state/GOAL.last`. That file was still a DOCUMENT: regenerated on a schedule, it
# drifts the moment its writer stops, and it asserts state it did not itself compute — the same class of
# bug as the static stage string it had replaced. The owner's correction: "you're now reading a goals doc,
# but that goals doc is not the graph's goals... why not use tortoise directly as a live map?" So the beat
# asks the graph. `goal-state.py --line` writes nothing.
# BOUNDED + FAIL-LOUD. FalkorDB is a LOCAL socket (127.0.0.1:16379), but a socket can fail where a plain
# file read cannot — so an unreadable graph is reported AS UNREADABLE and NEVER falls back to a stale line.
# A stale line reads as current state, which is precisely the failure this whole rework exists to remove.
# Measured cost: ~0.7s — one small Cypher query, well inside the beat's budget.
goal=""
_goalc="$HOME/Documents/GitHub/tortoise/.venv/bin/python"
if [ -x "$_goalc" ]; then
  ( "$_goalc" "$SCRIPTS/goal-state.py" --line ) >"$STATE/.goal-line.$$" 2>/dev/null & _gp=$!
  ( sleep 20; kill -TERM "$_gp" 2>/dev/null; sleep 3; kill -KILL "$_gp" 2>/dev/null ) 2>/dev/null & _gw=$!
  wait "$_gp" 2>/dev/null
  kill "$_gw" 2>/dev/null; wait "$_gw" 2>/dev/null
  goal=$(sed -n '1p' "$STATE/.goal-line.$$" 2>/dev/null | cut -c1-150)
  rm -f "$STATE/.goal-line.$$"
else
  goal="(no repo venv at tortoise/.venv — the graph cannot be queried from here)"
fi
[ -n "${goal//[[:space:]]/}" ] || goal="(GRAPH UNREADABLE — the goal map was NOT read; this is not 'all met')"
# ⛔ PARSE PER LINE, NOT WITH GREEDY SEDS (2026-10-05). The recap holds one field per line, and the
# previous `.*key=\(.*\) other=.*` form breaks the moment a key is inserted between two others:
# `\(.*\)` is greedy, so it swallows every field between the one it was aiming at and the last
# match. Inserting `continue=` between `alerts=` and `wip=` would have silently folded three fields
# into `alerts`. A per-line extractor cannot have that failure mode and needs no format migration.
_rec(){ sed -n "s/^$1=//p" "$STATE/lane-recap.last" 2>/dev/null | head -1; }
# The recap/beat PAIR rule (_mdsha + beat_pair_ok), shared with heartbeat-loop.sh so the rule exists
# ONCE. Sourcing is defensive: a partially-deployed script set must not break the FLOOR, and a
# missing helper can only ever SUPPRESS the act clause (the caller tests for the function), never
# publish an unverified number.
if [ -f "$SCRIPTS/lib/beat-pair.sh" ]; then
  . "$SCRIPTS/lib/beat-pair.sh"
else
  echo "cadence-nudge: $SCRIPTS/lib/beat-pair.sh is MISSING -- the recap/beat pair cannot be verified;" \
       "the act clause will be suppressed (fail closed) until it is deployed" >&2
fi
# Initialised OUTSIDE the branch: the nudge is the one sender that must never fail under `set -u`,
# so a missing recap must leave these defined (empty) rather than unbound.
act=""; actfull=0
if [ -f "$STATE/lane-recap.last" ]; then
  fleet=$(_rec fleet | cut -c1-70)
  # ⛔ THESE CAPS WERE SILENTLY CUTTING THE ACTION LIST (owner-reported "it is not showing the
  # list", diagnosed 2026-10-05). Every field was capped at 120-150 chars, and adding the
  # workspace handle costs ~11 chars per lane -- so a list of 5-6 lanes ran past the cap and was
  # SLICED MID-TOKEN (the beat read `...| π - tortoise(147m)[E` with GOAL immediately after). A
  # truncated list is worse than a short one: it silently drops lanes while looking complete. The
  # cap is now generous enough for every realistic list, and it stays as a guard against a
  # runaway field, not as a design limit.
  alerts=$(_rec alerts | cut -c1-300)
  cont=$(_rec continue | cut -c1-400)
  wip=$(_rec wip | cut -c1-400)
  free=$(_rec free | cut -c1-400)
  human=$(_rec human | cut -c1-400)
  ext=$(_rec ext | cut -c1-300)
  stall=$(_rec stall | cut -c1-300)
  # ⛔ LANES ALREADY AUTO-NUDGED (2026-10-05). They are published as a COUNT + names and NEVER as
  # an action, because the nudger has already told them to continue and they are working again.
  # Offering them as "say CONTINUE" is exactly what makes the orchestrator message a lane twice --
  # the confusion the owner named. Their split is deliberate: "[#] are busy is fine, but which are
  # the actionable ones".
  busy=$(_rec busy | cut -c1-400)
  # ⛔ THE AUTOMATIC CLASSIFIER'S ACTION CLAUSE (2026-10-05). Written by lane-actions.py from the
  # decision tree (state/LANE-STATE-DECISION-TREE.md), which is the ONLY action input here produced
  # by an automatic process that reads EVERY lane: Steps 0-4 in deterministic code, Step 5 in one
  # batched Jev call. The full lists -- idle / say-continue / wedged, each entry carrying the lane
  # LAST MESSAGE and the WHY -- are in state/NEEDS-ACTION.md; only this short pointer clause rides
  # the beat, because the beat must stay ONE line and is already near its display limit.
  # READ FROM THE SIDECAR, NOT FROM THE RECAP. The classifier runs in heartbeat-loop.sh AFTER the
  # tick, precisely because the tick is killed at its own bound before it could ever write this -- so
  # there is nothing in the recap to read, and the floor is the only sender that survives.
  # FRESHNESS-GATED: a stale sidecar (over 20 min, i.e. more than two passes) is not current state
  # and must not be published as if it were; the beat then falls back to its previous clauses.
  # `actfull=1` means the words layer was READ, and only then does this clause SUPERSEDE the weaker
  # mechanical/Jev-triage clauses (wip/continue/free/stall) -- otherwise one lane would be named
  # twice with two different instructions. When the words layer was NOT read, the older clauses
  # stand, so a Jev outage degrades to the previous beat instead of publishing an empty list.
  act=""; actfull=0
  B="$STATE/NEEDS-ACTION.beat"
  if [ -s "$B" ] && [ -z "$(find "$B" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then
    # A fresh mtime is NOT enough: verify the beat belongs to the recap on disk before publishing
    # it. On a torn or unverifiable pair the clause is dropped and the older clauses stand -- the
    # `actfull=0` degradation this file already relies on, never a number we cannot vouch for.
    # ⛔ THE VERIFY-AND-READ IS ONE CALL FROM THE SHARED LIB, NOT TWO STEPS HERE (#1897 review, P2).
    # Written out by hand it could be INVERTED -- and an inverted guard still matches every string a
    # text-based wiring test looks for, which is exactly how this shipped past a green suite.
    _bp_ok=0; _bp_why=""
    if ! command -v beat_clause_verified >/dev/null 2>&1; then
      _bp_why="beat_clause_verified unavailable -- $SCRIPTS/lib/beat-pair.sh not sourced (partial deploy?)"
    elif act=$(beat_clause_verified "$STATE" 420); then
      _bp_ok=1
      actfull=$(sed -n 's/^actfull=//p' "$B" | head -1)
    else
      # The REASON is re-derived for the log line only; nothing is published on either branch, so a
      # pair that healed between the two reads costs a misleading log word, never a clause.
      _bp_why=$(beat_pair_ok "$STATE" 2>&1)
      [ -n "$_bp_why" ] || _bp_why="pair not verifiable, no reason reported"
    fi
    if [ "$_bp_ok" != 1 ]; then
      # ⛔ A SUPPRESSION MUST BE RECORDED, OR IT IS INVISIBLE (#1897 review). The driver is
      # `cadence-timer.sh`, which runs this script as `( … ) >/dev/null 2>&1 &` -- so
      # beat_pair_ok's stderr and the MISSING-helper warning above are BOTH DISCARDED. Without this
      # line a PERMANENT suppression (e.g. beat-pair.sh absent from the lib farm, which is exactly how
      # this guard first shipped) is indistinguishable from a healthy beat: same message, no clause,
      # nothing anywhere saying so. The log is where an operator actually looks.
      printf '%s NUDGE-SUPPRESSED recap/beat pair not verifiable: %s -- act clause withheld\n' \
        "$(date '+%m-%d %H:%M:%S')" "$_bp_why" >> "$LOG"
    fi
  fi
  case "$actfull" in 1) actfull=1 ;; *) actfull=0 ;; esac
  # ⛔ IS THIS THE ENRICHED RECAP OR THE EARLY FALLBACK? (2026-10-05) The tick writes the recap
  # TWICE: a cheap fallback immediately after classification, then an enriched one after the JEV
  # triage. When a tick is slow the fallback is what survives -- and it carries the MECHANICAL
  # lane list with no action classes, so the beat silently loses WIP / ASK-USER / STALL with no
  # sign that anything is missing. Measured 2026-10-05 08:13: a beat showed only IDLE with `(Nm)`
  # ages and no other clause, which reads as "nothing needs attention" when the truth was "the
  # triage has not run yet". The flag makes that visible instead of misleading.
  # ⛔ DEFAULT TO NOT-CRYING-WOLF (2026-10-05). A recap written by a tick that predates this key has
  # NO `rich=` line, and the first cut treated that absence as `0` -- so the floor stamped
  # [PROVISIONAL] on a perfectly ENRICHED recap that carried every triage class (measured 08:18: a
  # beat showed the banner AND `continue=A(0.50) | W0 Test substrate(0.46)` together, which the
  # banner says is impossible). Only an EXPLICIT `rich=0` means the fallback write; absence means
  # unknown, and unknown must not accuse. A banner that fires when nothing is wrong stops being
  # read, which would cost us the real case it exists for.
  rich=$(_rec rich)
  case "$rich" in 0) rich=0 ;; *) rich=1 ;; esac
  [ -n "$fleet" ] || fleet="UNKNOWN"
  recap="$free"
else
  fleet="UNKNOWN (tick has not completed a classification pass)"
  alerts="UNKNOWN -- do NOT read absence as idle"
  cont=""; wip=""; human=""; ext=""; stall=""; busy=""; rich="0"
  free="UNKNOWN"
  recap="$free"
fi
# Friday's shape carries the OBJECTIVE verdict, which objective.py caches here. Read it, do not recompute:
# the floor must stay offline (its whole reason to exist is that it cannot be killed by a slow call).
# ⛔ PUT THE AGE IN THE LINE (2026-10-10, #7871). A reader could not tell a 900s-old line from a
# 5h-old one, and objective.py SKIPS the write when a read is blind -- so the 2026-10-03 change turned
# a BOUNDED staleness into an UNBOUNDED one. This file reads the cache directly, so it inherits neither
# the serve window (VERDICT_SERVE_MAX_S=120) nor the head-liveness check. Measured four times.
# The age is NOT a new invention: `objective.last` line 1 is the write STAMP and carries the age of the
# READING (not of the file), and turn-classify.py has rendered it as `cache_age=` since 2026-10-06
# (OBJECTIVE_FRESH_S=900, tested). SAME NAME, SAME UNIT, SAME WINDOW -- deliberately. A second name for
# one quantity on one line is how one contract becomes two (tortoise/status_vocabulary.py, roadmap
# §7.9 ADOPTED 2026-09-17), and the convergent convention for exposing a cached value's age is a
# delta in seconds compared against a window with the value still PUBLISHED, not omitted (HTTP `Age`,
# RFC 9111 §5.1; k8s `observedGeneration`/`lastTransitionTime`). This whole term is one hunk
# because its only novel part is on the gate below.
# Do NOT shorten the TTL (burns `gh` calls); do NOT make it live on every read without measuring cost.
_cache_age_s() {
  /usr/bin/python3 - "$STATE/objective.last" <<'PYAGE'
import sys, datetime
try:
    with open(sys.argv[1]) as fh:
        first = fh.readline().strip()
    dt = datetime.datetime.fromisoformat(first.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    print(max(0, int((datetime.datetime.now(datetime.timezone.utc) - dt).total_seconds())))
except Exception:
    print("")
PYAGE
}
# The per-class tokens NAME their PRs, so the old 150-char cut severed exactly the part that makes
# them readable. #1872 lengthened the segment twice: the label is now
# `QUEUE(state): ` (relabelled 2026-10-18: the old `; pr-doctor dispatches` parenthetical
# claimed the token was a dispatch record, and it is the queue's SHAPE -- so the counts cannot
# be mistaken for an instruction the
# automatic dispatcher already owns) and `running` is named like every other class.
#
# ⛔ THIS IS A TRUNCATION POINT, NOT A WORST CASE, AND NO NUMBER BELONGS HERE. The width was raised
# three times on this branch alone -- 400 -> 700 -> 820 -> 900, each value REPRODUCIBLE rather than
# remembered (`git log -G'cut -c1-[0-9]+' --oneline -- scripts/cadence-nudge.sh` lists exactly the
# commits that changed it) -- and every one was falsified by the next measurement, because the length
# is a function of DIGITS x NAMED PRs x per-entry gate names x the overlay x the STUCK escalation: any
# figure is a claim about the FLEET, not about the format, and it goes stale the first time the queue
# grows. (An earlier version of this comment listed intermediate widths measured in a WORKING TREE
# and never committed, so no reader could reproduce them; that is why the series above is cited with
# the command that finds it rather than as bare figures.)
# What is true, and does not go stale:
#   * what a cut CAN sever: the tail of the queue segment and then the CI indicators;
#   * what a cut CANNOT sever, because of where it is emitted (`objective.py`, pinned by
#     `test_the_FAIL_CLOSED_caveat_precedes_the_counts_it_qualifies`): `queue_read=BLIND(...)` --
#     the token that says the counts are NOT a clearance -- and `ASK-USER: surface=N: #...`, the
#     owner's actionable list. Both precede the queue segment; neither may move back to the tail.
# 900 is a CUT, not a guarantee, and this comment will not name the depth at which it starts to
# bite -- the paragraph above says exactly why any such figure goes stale. What is true: the tail of
# the queue segment (its last class's named PRs) and then the CI indicators ARE lost once the line
# outgrows the cut, which is a known residual, not a promise.
obj=$(sed -n '2p' "$STATE/objective.last" 2>/dev/null | cut -c1-900)

# ── RES: the system-resource segment, on its OWN line (objective.last line 3) ──────────
# Its own line for TWO reasons, and NEITHER of them is a length claim about the objective line
# (#1872 review round 17: an earlier version of this comment said that line was "ALREADY past the
# length it is read with", which a 4-PR fixture refutes -- it measures ~300 chars against a 900
# cut). (1) Appending it would put the CURRENT resource numbers BEHIND everything the objective
# segment can grow into, and the tail is what a cut reaches first -- so #1872 moved it OUT of that
# line rather than arguing about widths. (2) Its own line can be refreshed EVERY BEAT without
# re-deciding the verdict (see the cache paragraph below, which is the reason that actually bit).
# (`fix-ci` is not rendered in the objective segment at all -- it appears as
# `IN-PROGRESS: fixing <check>=<n>` -- so nothing here depends on it.)
# It is NOT truncated: the line is short and every field is load-bearing.
# ⛔ FRESH EVERY BEAT, NEVER FROM THE CACHE. Reading line 3 of `objective.last` inherited that
# file's 900 s TTL: two beats 7m33s apart printed BYTE-IDENTICAL values, including `runq=79`
# and a `top=` consumer at exactly 157.6% -- which cannot repeat on a live box. A resource
# reading is valid for SECONDS and this line AUTHORISES CONCURRENCY, so a stale LOW dispatches
# into a saturated box. `--res` is local-only (no network), so freshness costs nothing.
res=$(/usr/bin/python3 "$HOME/.pi/agent/scripts/objective.py" --res 2>/dev/null)
[ -n "$res" ] && res="· $res"
_age=""; _age_h=""
if [ -n "$obj" ]; then
  _age=$(_cache_age_s)
  if [ -n "$_age" ]; then
    _age_h="$(( _age / 60 ))m"
    obj="$obj cache_age=${_age_h}"
    [ "$_age" -gt 900 ] && obj="$obj STALE(>900s)"
  else
    obj="$obj cache_age=?"
  fi
else
  obj="OBJECTIVE: cache absent"
fi
hms=$(date '+%H:%M:%S')

ts=$(date '+%Y-%m-%dT%H:%M:%S%z')

# ---- resolve the orchestrator pane (same two fallbacks the tick uses) ----
# ⛔ DO NOT HARDCODE A SECOND COPY OF THE PANE. The tick hardcodes ORCH_WS/ORCH_SURFACE in
# orchestrator-heartbeat.sh, and a copy here would silently rot into a DIFFERENT pane the day that
# line changes -- sending heartbeats to the wrong terminal, which is worse than not sending them.
# Read the same single source instead: whatever the tick will send to, this sends to.
TICK="$SCRIPTS/orchestrator-heartbeat.sh"
ORCH_WS="$(grep -m1 '^ORCH_WS=' "$TICK" 2>/dev/null | cut -d'"' -f2)"
ORCH_SURFACE="$(grep -m1 '^ORCH_SURFACE=' "$TICK" 2>/dev/null | cut -d'"' -f2)"
if [ -z "$ORCH_WS" ] || [ -z "$ORCH_SURFACE" ]; then
  printf '%s CADENCE-NUDGE skipped: could not resolve the orchestrator pane from %s\n' \
    "$(date '+%m-%d %H:%M:%S')" "$TICK" >> "$LOG"
  exit 0
fi
# ⛔ NO REACHABILITY PROBE BEFORE THE SEND. The first version probed with `cmux read-screen` and only sent
# if it answered -- a slow-but-working cmux then consumed the budget BEFORE the message went out, which is
# the same ordering defect as the tick's. Probing first only adds a way to fail without having tried.
#
# ⛔ AND "THE SEND IS THE TEST" IS RETIRED (#3795 review F1, carried unfixed through cycles 1/4/5). This
# line used to continue "`cmux send` already tells us whether it worked", and that half is the premise
# #1187 FALSIFIED: the measured 1,962-byte message arrived as its FIRST SENTENCE and a 5,464-byte one
# arrived COMPLETE, both with `OK`, and an 8-byte `/reload` was lost entirely. The send's exit code is a
# HINT, never a delivery verdict — the verdict comes from `scripts/lib/cmux_payload.py` (transcript
# evidence, after a pre-send baseline) and is recorded in `delivered=` beside every `NUDGE at=`. Leaving
# the old sentence in place let the next editor of this tail cite the file's own doctrine to restore
# `delivered=yes`-by-`$rc`, and made the new block below false about this file. On failure we log and
# exit; the next pass retries, and the lock THIS FILE takes at its top (`$STATE/cadence-nudge.lock`, the
# `mkdir` near the head of this file) is what prevents a pile-up. (It was previously attributed to
# `heartbeat-loop.sh`, which takes no such lock — grep it: the only locks it mentions are its detached
# helpers'. Corrected while this paragraph was already being rewritten, because a file arguing that a
# claim must name its evidence may not keep one that names the wrong file. The first version of THIS
# correction then said the lock is taken "below", which is the same error one direction over: the send
# is at the bottom of the file and the lock at the top.)

# ⛔ ONE MESSAGE, ONE LINE -- NO EMBEDDED NEWLINES (2026-10-05, owner report).
# MEASURED DEFECT: the multi-line form of this message arrived as 5-6 SEPARATE turns in the pane.
# `cmux send "$MSG\n"` SUBMITS EACH NEWLINE AS ITS OWN TURN, so a body of N lines is N messages.
# The owner's report: "it's a mess... many individual messages, creating massive noise and
# distraction." The tick's own message is a single long line for precisely this reason.
# SO: every section below is joined with a ' · ' separator and the body MUST NOT CONTAIN A NEWLINE.
# ⛔ FRIDAY'S SHAPE, RESTORED (owner instruction, 2026-10-05). The owner's ask was an explicit
# ROLLBACK: "roll back to the heartbeat version we had friday that gave a heartbeat on the lanes
# and a message but not many individual messages" -- Friday's version WORKED FOR AUTONOMY because
# it carried the per-lane verdicts (ACT:) and the objective verdict, i.e. THE STATE OF THE CMUX
# SESSIONS. My one-line rewrite kept the goal and the free list but DROPPED `ACT:`, which is the
# field the orchestrator actually acts on. Restored field-for-field from the tick's own template
# (the tick's own template, `orchestrator-heartbeat.sh`, the `MSG="[HEARTBEAT ${TS}] ..."` assignment --
# grep `^MSG="\[HEARTBEAT`; the line number rots), which was never changed -- it simply never delivers,
# because this floor pre-empts it. So the floor must speak Friday's language.
# STILL ONE MESSAGE, ONE LINE: `cmux send` submits every newline as its own turn (that was the
# noise defect). Friday's shape was always a single line; it is reproduced as one.
# ⛔ WHICH LANES, AND WITH WHAT (owner ask, 2026-10-05): the beat reported a COUNT + a bare
# capacity list, so acting on it still meant opening 29 panes to learn what each lane needed.
# Every class now ships with the action the decision tree prescribes for it, in the order they
# should be worked: WIP lanes first (they are mid-task and cheapest to unblock -- one instruction),
# then truly idle lanes (need work selected), then anything needing investigation.
# ⛔ `do` is a bash RESERVED WORD -- the variable must not be named that.
doact=""
# The automatic classifier's clause goes FIRST, and when its words layer was read it SUPERSEDES the
# four clauses it covers (wip / continue / free / stall). It is the decision-tree-authoritative one
# and it carries the lane last message in the file, so the older lines are duplicates with a second
# instruction rather than extra information. human / ext / busy / alerts are NOT covered by it and
# stay: ASK-USER routing must survive a classifier that emits only the two dispatch lists.
if [ -n "${act:-}" ]; then
  doact="${act} | "
  if [ "$actfull" = "1" ]; then
    wip=""; cont=""; free=""; stall=""
  fi
fi
# WIP and CONTINUE are the SAME action (say continue) reported by two different classifiers -- the
# mechanical one and the JEV triage -- so they are merged into ONE clause rather than naming a lane
# twice with the same instruction. They cannot contradict each other: the tick's DO-DEDUPE drops
# every WIP-IDLE lane out of the READY list before writing this recap.
_cont="${wip:-}"
[ -n "${cont:-}" ] && _cont="${_cont}${_cont:+ | }${cont}"
[ -n "$_cont" ] && doact="${doact}WIP->say CONTINUE (unfinished work in hand; do NOT hand a new task): ${_cont} | "
[ -n "${free:-}" ] && doact="${doact}IDLE->hand the next unheld item: ${free} | "
[ -n "${human:-}" ] && doact="${doact}ASK-USER->raise a user question: ${human} | "
[ -n "${ext:-}" ] && doact="${doact}BLOCKED-EXTERNAL->report only, never nudge: ${ext} | "
[ -n "${stall:-}" ] && doact="${doact}STALL->investigate (pane + CPU time first): ${stall} | "
[ -n "${busy:-}" ] && doact="${doact}BUSY(auto-nudged, now working -- do NOT message): ${busy} | "
[ -n "${alerts:-}" ] && doact="${doact}ATTENTION->check the pane AND CPU-time delta BEFORE acting: ${alerts} | "
[ -n "$doact" ] || doact="(none classified -- do NOT read that as all-idle) "
# ⛔ A PROVISIONAL RECAP MUST ANNOUNCE ITSELF (2026-10-05). The fallback carries the MECHANICAL
# lane list and NO action classes, so its silence reads as "nothing needs attention" while the
# truth is "the JEV triage has not run yet". Measured 2026-10-05 08:13: a beat showed only IDLE
# with (Nm) ages and no WIP / ASK-USER / STALL clause at all -- indistinguishable from a clean
# fleet, and the reason the owner reported the list looking wrong.
# ⛔ NET-GROWTH FREEZE (owner escalation 2026-10-05 19:2x). Measured over 3h: 9 PRs MERGED but 13 were
# OPENED, so open went 21 -> 27 and the queue grew WHILE landings succeeded. A queue cannot drain while
# intake matches outflow, and no CI repair changes that arithmetic. Deterministic + local: compares this
# beat's `open=` to the previous beat's. No network, no gh (the beat must stay network-free).
#
# ⛔ BUT NET-GROWTH ALONE IS NOT THE FREEZE — IT IS THE SYMPTOM, AND IT INVERTS ONCE THE QUEUE IS DRAINED
# (owner correction 2026-10-09, via #6792). The owner's predicate for INTAKE-FROZEN is `waiting >=
# TARGET_PRS(10)`; the freeze is DERIVED, never decided, and a SATISFIED PRECONDITION IS NOT A LIVE
# ⛔ THE DERIVED TRIGGER, AND THE ONLY ONE: `waiting >= TARGET_PRS` (the constant NAMED, not numbered —
# it is `objective.py`'s `TARGET_PRS = 10  # queue depth at target: fewer than 10 non-draft PRs waiting
# to land`; a line number here pointed at the wrong line within a day of being written). Both the
# constant and `waiting` are read from
# their owner, objective.py, so there is no second source of truth and no state file.
#
# THREE PROXIES REMOVED HERE, each caught asserting a freeze its own numbers denied:
#   (1) `open_now >= open_prev` alone — held FOREVER once the queue was drained and stable (`5 >= 5`),
#       so the beat emitted INTAKE-FROZEN while its own instrument said AT-TARGET in the SAME message.
#   (2) `... && verdict != AT-TARGET` — a better proxy, still a proxy. Measured 2026-10-09T15:35 it
#       emitted `INTAKE-FROZEN(5->7)` while `waiting=5` sat at HALF the stated trigger of 10. A queue
#       that lands one and opens one is "non-decreasing" on EVERY beat, so growth cannot distinguish a
#       ballooning queue from a healthy one — it can only ever fire, which is why it inverted.
#   (3) `$STATE/.open-prev` — a cross-tick state file: a second source of truth that goes stale.
# The freeze is DERIVED, not decided. Read the trigger; do not infer one from an arithmetic that cannot
# express it. If a future reader wants a flow-based rule, it must be a NEW recorded decision, not this.
_waiting=$(sed -n 's/.*[[:space:]]waiting=\([0-9][0-9]*\).*/\1/p' "$STATE/objective.last" 2>/dev/null | head -1)
_target=$(sed -n 's/^TARGET_PRS[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$SCRIPTS/objective.py" 2>/dev/null | head -1)
# ⛔ THE GATE IS DERIVED FROM THE SAME CACHE, SO IT INHERITS THE SAME AGE (2026-10-10, #7871).
# `waiting` is read from the file, never recomputed -- and the file can be hours old. Measured
# 2026-10-10T12:19 the cache was 13,059s (3.63h) old and said `waiting=11`; one recompute said 9.
# TARGET_PRS=10, so the stale term ASSERTED A FREEZE live truth says had lifted -- the mirror of the
# owner's reproduction, where a stale `waiting=4` DENIED a freeze that was real at 14. Both directions,
# one mechanism. INTAKE-FROZEN decides whether EVERY lane may open a PR, so an age-free freeze is a
# gate asserting a queue that may no longer exist. NOT omitted; no second threshold -- the same
# `cache_age=` the line above carries, rendered where the reader needs it.
_frozen_age=""
if [ -n "$_age" ]; then
  _frozen_age=" cache_age=${_age_h}"
  [ "$_age" -gt 900 ] && _frozen_age=" cache_age=${_age_h} STALE(>900s)"
fi
if [ -n "$_waiting" ] && [ -n "$_target" ] && [ "$_waiting" -ge "$_target" ] 2>/dev/null; then
  doact="${doact}INTAKE-FROZEN(waiting=${_waiting}>=${_target}${_frozen_age})->do NOT open a new PR; land or fix an EXISTING one | "
fi
prov=""
[ "${rich:-0}" = "1" ] || prov="[PROVISIONAL -- triage pending, classes may be MISSING not absent] "
# ── THE RESOURCE VERDICT GATES THE LANE VERDICT (one action per line) ────────────────────
# `RES: ... | DO: RECLAIM` beside `DO: IDLE->2 need dispatch` is TWO OPPOSITE IMPERATIVES with
# no way to reconcile them -- worse than a missing line, because it costs a dispatch cycle and
# teaches the reader to ignore BOTH tokens. Where two subsystems disagree, the MORE RESTRICTIVE
# one wins and says why. (`hold` is included: it also means "add nothing".)
_ract=$(printf '%s' "$res" | sed -n 's/.*| DO: \([A-Za-z-]*\).*/\1/p')
# ⛔ UNCONDITIONAL AND STRUCTURAL. This was a `case` match on the literal phrase `need dispatch`,
# so when an emitter switched to `IDLE->hand the next unheld item` the gate stopped matching and
# FOUR lanes were offered for dispatch while `DO: RECLAIM` said add nothing. EVERY clause is now
# piped through the gate, which decides for itself whether the clause asks for a lane. Fail-open
# (keep the clause) if the gate itself cannot run: losing the whole DO line is worse.
_g=$(printf '%s' "$doact" | /usr/bin/python3 "$HOME/.pi/agent/scripts/objective.py" --gate-clause "$res" 2>/dev/null)
[ -n "$_g" ] && doact="$_g"
# ── THE FLEET ADVANCE STANDING ORDER (#1993: the complementary half of #1991) ───────────────────
# #1991 put the owner's FLEET ADVANCE order on the TICK. That file is not the only sender of a beat
# and it is not the dominant one: THIS is. The derivation is from the two senders' own constants,
# both clocked off the same log line — this file is due at `PULSE_MIN` (5 min, above), and it is
# driven by `cadence-timer.sh` on a fixed `INTERVAL` of 450 s (7.5 min); the tick runs once per loop
# pass (TARGET 540 s + up to 120 s sleep, i.e. >= 9 min) and then rate-limits ITSELF out whenever the
# last beat is under `MIN_GAP_MIN` (4 min, `orchestrator-heartbeat.sh`) old. So the floor lands a beat
# in every 7.5-min window and the tick's pass boundary usually falls inside the floor's 4-min
# suppression window: the message a lane usually receives is this one, and until this clause it
# carried ROLE/MODEL/NEXT/PERIODIC and no order to advance anything (#1993; NOT a count of beats by
# sender — the log that count lives in was not on the box that made this change, and a derivation
# from shipped constants does not go stale the way a 24 h count does).
# ⛔ STATIC TEXT, NOT A READ. The floor's one invariant is that a beat leaves on time on a broken box
# (its header's own words: "a low-information heartbeat on time beats a rich one that never arrives"),
# so this may not add a `gh` call, a subshell, a network read, or anything that can block — and a read
# of the order from another file is a NEW way to fail (a partial farm yields an EMPTY order and the
# clause vanishes silently, which is exactly the failure #1991 spent eight review rounds on).
# ⛔ VERBATIM FROM #1991'S SHORT WORDING, AND PINNED AGAINST DRIFT. A second wording of a standing
# order is the defect: two files would then tell the fleet two different things and nothing would be
# red. The text below is the tick's `FLEETADV_SHORT` sentence for sentence, and
# `tests/heartbeat-floor-advance/run.sh` asserts that equality against the SHIPPED tick, so an edit to
# either file that is not made to both fails CI instead of drifting.
# ⛔ NOT AT THE TAIL, AND NOT INSIDE `${doact}`. (a) Placement: #1187 MEASURED a 1,962-byte payload
# arriving as its FIRST SENTENCE, so the most important clause may not be the last thing in a payload
# this long — the tick can end with the order because its body is ~1.6 k, while this one is ~1.7 k
# before the objective/goal/resource segments are filled in. It rides directly behind the state header
# and before `DO:` (whose `${prov}` marker stays adjacent to the classes it qualifies). (b) The gate
# above rewrites `${doact}` on a `DO: RECLAIM` resource verdict; a standing order is not a dispatch
# OFFER and must not be neutralised by it — and `[RES RECLAIM] …: adding lanes makes it worse`
# prefixed onto the order would invert it.
# ⛔ FORMATION RULES, ALL LOAD-BEARING: `MSG` is a DOUBLE-QUOTED assignment, so a backticked span in
# this literal is command-substituted at assignment time and silently disappears, `$` expands, and a
# raw `"` ends the string. No backtick, no `$`, no double quote, no newline (ONE MESSAGE, ONE LINE —
# `cmux send` submits every newline as its own turn).
FLEETADV_FLOOR="⛔ FLEET ADVANCE — an ORDER, not a report. CHECK THE cmux LANES AND ALL FOUR BOXES (local + the three cloud VMs) and push each toward AUTOPILOT — dispatching, creating PRs, fixing them, merging them UNATTENDED. USE THE CAPACITY, DO NOT REPORT IT: dispatch locally if the local machine has room, on a cloud VM if it is idle. DRIVE THE P0/P1 PRs: name the specific PRs that should land this cycle, take each one to the rail via scripts/admin-merge.sh, and advance agent-infra (cell-2 owns it) toward automating dispatch, PR creation, fixing and merging. A beat that reports state and dispatches nothing is a WASTED BEAT."
MSG="[HEARTBEAT ${hms}] fleet ${fleet}. ${obj} ${res} ${FLEETADV_FLOOR} ${prov}DO: ${doact} GOAL: ${goal} · GRAPH: the objectives + their order live in the TORTOISE GRAPH (read before deriving, write findings back) · ROLE: orchestrate — give each lane a LIST OF ISSUES, verify the ARTIFACT, and CHECK EVERY LANE IS MOVING; a lane that is stuck is yours to unstick (never implement, never decide for the owner) · MODEL: 6 lanes, each owning ISSUES END-TO-END (implement -> fresh-context review -> rail -> merge -> next issue); a PR is a STEP INSIDE AN ISSUE, never a queue item; A FINISHED ITEM IS THE TRIGGER TO START THE NEXT -- never stop between items, and budget/context is never a stopping reason (context auto-compacts); NO separate landing lanes and do NOT create new lanes -- retire as they finish · LANES: IN BOUNDS = ~/Documents/GitHub/tortoise AND agent-infra (BOTH fine to dispatch) · OUT OF BOUNDS = DMeer lanes (DMeer, DMeer - linkedin outreach, DMeer - marketing), a DIFFERENT repo/product — check the lane's cwd/name before every dispatch, never dispatch from a bare UUID list · NEXT: waiting>10 -> the PR queue gets the attention; otherwise merge and spend spare capacity on P0, then P1, then P2 product issues · PERIODIC: re-read the whole open issue list and ask whether the most customer-impactful ones are the ones prioritised; if the reclassification pass has an UNFINISHED progress file under state/, RESUME it from that file instead of restarting it · classify lanes by the decision tree (CPU-delta > child > tool-age > words; spinner is WEAK) · PR state from artifacts, never a queue row"

# DRY MODE (2026-10-05): print the message and send NOTHING. Added so this file can be verified
# against live state without typing into the orchestrator pane. Off by default and read from the
# environment only, so no production path changes; PULSE_MIN=0 forces the due check open.
if [ "${NUDGE_DRY:-}" = "1" ]; then
  printf '%s\n' "$MSG"
  exit 0
fi
# ⛔ `delivered=yes` USED TO BE WRITTEN UNCONDITIONALLY — THAT WAS #1187's FALSE PASS AT THIS SITE.
# The old tail was a bare `cmux send "$MSG\n"`, `rc=$?`, and then this line:
#     printf '… NUDGE at=%s delivered=yes …'
# with NO reference to `$rc` and NO verification of any kind, so a send that exited non-zero, and a
# send that returned OK while the pane received only a PREFIX, both wrote the same `delivered=yes`
# receipt. The comment that used to sit above the send — "THE SEND IS THE TEST: `cmux send` already
# tells us whether it worked" — is the premise #1187 FALSIFIED: the 1,962-byte message arrived as its
# first sentence and the 5,464-byte one arrived complete, both with `OK`. The log is what the next
# reader — the operator, and this file's own due-read — takes as the receipt, so a receipt that
# certifies nothing is exactly the defect class this file's own delivery promise cannot afford.
#
# The verdict now comes from `scripts/lib/cmux_payload.py` (#1187, #1881) — the same checker the lane
# dispatcher (`orch-send.sh`) uses — so the floor and the dispatcher hold ONE definition of "delivered",
# not two hand-rolled ones.
#
# ⛔ BUT THIS FILE IS NOT THE LOG'S ONLY PRODUCER, AND THE OTHER ONE IS NOT HONEST YET (measured, #3795
# final review). `scripts/orchestrator-heartbeat.sh` writes `NUDGE at=… delivered=yes` into THE SAME LOG
# (`:53`, same `$STATE/orchestrator-heartbeat.log`) from its OWN predicate: a grep of the WHOLE
# transcript for the message's OPENING token (`:1435` `grep -q "HEARTBEAT ${TS}" "$of"`, where
# `:67` sets `TS` and the message OPENS with `[HEARTBEAT ${TS}]`), with NO pre-send baseline. A heartbeat
# truncated to its first sentence therefore still matches and still writes `delivered=yes` — the exact
# prefix-passes defect #1187 measured. That is OUT OF SCOPE here (a separate caller, a separate change)
# and is recorded on #1187 rather than silently implied to be fixed; do not read this file's receipt as
# proof that every `delivered=yes` in the log was earned this way.
#   VERIFIED      → delivered=yes          (tail appended to the pane's transcript after this send)
#   PANE_ONLY     → delivered=NOT-SUBMITTED (on the surface, submission unproven)
#   SUBMIT_FAILED → delivered=NOT-SUBMITTED (the terminating Enter failed)
#   UNVERIFIED    → delivered=UNVERIFIED    (prefix, unreadable pane, or a refused send)
# Only the first is a success signal; the other three are LOUD, never silent.
#
# ⛔ THE FLOOR STILL SENDS WHEN THE CHECKER CANNOT RUN. `orch-send.sh` refuses to dispatch at all in
# that case (exit 7), because a duplicate LANE ORDER is dangerous. This file is the cadence FLOOR: its
# entire purpose is that a heartbeat leaves even on a broken box, and `delivered=UNVERIFIED` already
# refuses to certify a send whose delivery it could not check. So: send, then say honestly that it
# could not be checked. Never: send, then claim it landed.
_verify="$SCRIPTS/lib/cmux_payload.py"
# ⛔ ONE PLACE DECIDES WHETHER THE CHECKER CAN BE USED — AND IT PROBES CAPABILITY, NOT JUST PRESENCE
# (#3795 review cycle 3, P1). `cadence-nudge.sh` is farmed from `fleet_srcs` and `lib/cmux_payload.py`
# from `lib_srcs` (pi-bootstrap/setup.sh) — fleet FIRST — so a box whose farm pass stopped between the
# two holds a NEW floor beside a STALE checker. Such a checker exits 2 on `verify --surface` BEFORE it
# sends anything, and the floor's one invariant ("a heartbeat leaves even on a broken box") is lost
# while the receipt still reads `delivered=UNVERIFIED` — the value this file documents as "prefix,
# unreadable pane, or a refused send", never "nothing was sent". MEASURED on the PR's own fixture with
# a stale stub: no send reached cmux, and two honest-looking log lines were written. So a checker that
# does not advertise the argv we are about to pass takes the raw-send path, exactly like a missing one.
#
# ⛔ AND IT MUST NOT "just retry without --surface" (#3795 review cycle 3): a checker that has ALREADY
# sent and then crashed would be called a second time, double-sending the payload (rejected Approach 5).
_checker_broken=""
if [ ! -f "$_verify" ]; then
  _checker_broken="not on this box: $_verify"
elif [ ! -x /usr/bin/python3 ]; then
  _checker_broken="no interpreter: /usr/bin/python3"
else
  # ⛔ NOT A PIPE INTO `grep -q` (#3795 review cycle 3): under `set -o pipefail` the producer takes
  # SIGPIPE when grep exits early, the pipeline reports 141, and the capability test reads as ABSENT
  # on a good checker — the same class of false signal this file exists to catch.
  #
  # ⛔ AND THE FAILURE IS SPLIT BY WHAT WAS MEASURED (#3795 review cycle 4, P2). Discarding the exit
  # status made EVERY capability failure read as "predates --surface" — a claim about a version that
  # was never established. A farm pass that stopped mid-write leaves a copy that raises on import,
  # whose help exits non-zero with EMPTY stdout: that is a broken copy, not an old one, and the
  # receipt now says which it saw. stderr is merged into the same read so the cause travels with it.
  _help=$(/usr/bin/python3 "$_verify" verify --help 2>&1)
  _hrc=$?
  # ⛔ THE STATUS IS CONSULTED FIRST, THE FLAG ONLY SECOND (#3795 review cycle 10, P2). This read used
  # to `case "$_help" in *--surface*) ;;` BEFORE looking at `$_hrc`, so a help invocation that FAILED
  # but whose merged output happened to mention the flag passed the gate -- "the read failed" read as
  # "the checker is usable", the exact polarity this file corrects twice elsewhere (`getattr(proc,
  # "returncode", 1)` in `_resolve_session_id_qualified`, "an id out of a FAILED read is not this
  # surface's session"). It is REACHABLE in the state this gate exists for: a farm pass that stopped
  # mid-write leaves a copy whose `argparse` block is truncated, and Python reports the unclosed
  # bracket AT THE LINE HOLDING IT — a line that contains the `--surface` flag. MEASURED on the
  # fixture: `send=False` and NO `NUDGE at=` at all, i.e. the floor lost its one
  # invariant (a heartbeat leaves even on a broken box) on a box whose checker is unusable.
  if [ "$_hrc" -ne 0 ]; then
    _checker_broken="verify --help failed (rc=$_hrc): $(printf '%s' "$_help" | tr '\n' ' ' | tail -c 160)"
  else
    case "$_help" in
      *--surface*) ;;
      *) _checker_broken="stale farmed copy ($_verify) predates --surface, so it would refuse the argv before sending" ;;
    esac
  fi
fi
# ⛔ THE ENV DOOR IS VALIDATED, NOT TRUSTED (#3795 review P1). The probe above runs `verify --help`,
# which exits BEFORE argparse validates the `--timeout` VALUE -- so `CADENCE_NUDGE_VERIFY_TIMEOUT=90s`
# (the obvious human spelling of 90) passed the probe and then made the real call die in argparse,
# before it could send. Validate the shape here, so the argv the probe covered is the argv that runs.
# ⛔ THE VALUE IS SANITISED BEFORE IT CAN REACH A RECEIPT, NOT MERELY FLATTENED (#3795 review cycle 5,
# P1). It is interpolated into `_checker_broken` -> `_cause` -> `_vdiag` -> BOTH receipt lines, so an
# env value containing a newline split the receipt and let its second physical line be a byte-valid
# FORGED one: `CADENCE_NUDGE_VERIFY_TIMEOUT=$'90\nNUDGE at=9999999999 delivered=yes … verdict=VERIFIED'`
# wrote a delivery receipt with no send at all (measured), and that same line then made the floor
# compute a NEGATIVE gap and skip for ever.
#   Flattening alone is NOT enough (measured): the injected text still lands INLINE in `diag=[…]`, and
#   the due read is an UNANCHORED `.*NUDGE at=\([0-9][0-9]*\) delivered=` — so a `NUDGE at=… delivered=`
#   fragment anywhere on the line is read as a receipt. The echoed value is therefore reduced to the
#   characters a timeout can legally contain, so no receipt-shaped token survives it at all.
_vtimeout_raw="${CADENCE_NUDGE_VERIFY_TIMEOUT:-90}"
_vtimeout=$(printf '%s' "$_vtimeout_raw" | tr -d '\r\n')
_vts_echo=$(printf '%s' "$_vtimeout" | tr -cd '0-9.' | cut -c1-20)
case "$_vtimeout" in
  ''|.|*[!0-9.]*|*.*.*) _checker_broken="CADENCE_NUDGE_VERIFY_TIMEOUT is not a positive number (digits and one dot only): got '${_vts_echo}'" ;;
esac
# ⛔ AND IT IS BOUNDED, NOT ONLY SHAPE-CHECKED (#3795 review cycle 2, P2). `verify --timeout` is a
# DEADLINE, not a per-call bound (`cmux_payload.py` sets `deadline = monotonic() + timeout_s` and polls
# it), so a large value holds this run -- and the lock -- well past the 450 s tick interval that the
# whole 413 s budget is measured against. `999999999` passed a shape-only check and wedged the floor.
# The ceiling is the verification budget's own scale, so it cannot outlive the interval by more than a
# little: the tail is `timeout + poll_s + one 45 s read` and everything BEFORE it is ~275 s, so 120 s
# gives 275 + 168 = 443 s. A value of `inf` (400 digits) is refused by the length guard before `-gt`
# ever sees it.# ⛔ THE CEILING IS 120, NOT 300 (#3795 review cycle 4, P2). The first version capped at 300 and
# justified it with "300 s + one 45 s read still lands inside 450 s" — which is the TAIL ONLY. The
# budget table at the receipt counts ~275 s of work BEFORE the tail, so an accepted 300 s put the
# critical section at ~620 s: 1.4x the interval the cap exists to protect, with the next tick
# correctly skipping and the beat drifting to ~15 min with nothing on the receipt naming the cause.
# 120 is the largest round value whose whole window still fits (443 s), and even that leaves the
# pre-send work this file cannot bound (`objective.py` has no timeout) as the residual — see the
# budget note at the receipt, which is the only place the two terms are added together.
if [ -z "$_checker_broken" ]; then
  _vts_int="${_vtimeout%%.*}"
  [ -n "$_vts_int" ] || _vts_int=0
  if [ "${#_vts_int}" -gt 3 ] || [ "$_vts_int" -gt 120 ]; then
    _checker_broken="CADENCE_NUDGE_VERIFY_TIMEOUT must be <= 120 s (the pre-tail work is ~275 s of a 450 s interval), got '${_vts_echo}'"
  fi
fi
if [ -z "$_checker_broken" ]; then
  _verr=$(mktemp "${TMPDIR:-/tmp}/cadence-nudge-verify.XXXXXX") || _verr=/dev/null
  verdict=$(/usr/bin/python3 "$_verify" verify \
              --workspace "$ORCH_WS" --surface "$ORCH_SURFACE" \
              --text="$MSG" --timeout "$_vtimeout" \
              2>"$_verr")
  # ⛔ THE VERDICT IS FLATTENED BEFORE IT IS MAPPED OR PRINTED (#3795 review cycle 2, P2). The
  # `case` below was already fail-closed on a multi-line verdict — an unrecognised shape falls to `*`
  # — but the RAW value was interpolated into both receipts, so `VERIFIED\nOK` split one receipt into
  # two log lines and made the failure line read "NOT CERTIFIED … verdict=VERIFIED" / "OK — the nudge
  # was NOT proven delivered": a self-contradicting receipt, in the one change whose subject is a
  # receipt that must not overstate itself. Every other field on the line is already one-line-guarded
  # (queue via `tr` at the `objective.last` read, the checker's stderr, the failed send's stderr); this
  # is the last unguarded one.
  verdict=$(printf '%s' "${verdict:-}" | tr '\n' ' ')
  # ⛔ "NO VERDICT RECEIVED" IS NOT AN ATTEMPT (#3795 review P1). Folding a silent checker into
  # `UNVERIFIED` and then stamping `NUDGE at=` made the receipt claim an attempt that may have produced
  # NO cmux call at all. That matters far beyond this file: `NUDGE at=` is also the TICK's rate-limit
  # clock (`orchestrator-heartbeat.sh:475` reads any `NUDGE at=`, `:1053` then exits before its own
  # send), so an unearned stamp suppressed BOTH beats while the log showed a perfectly regular cadence
  # -- the false-PASS shape this whole change exists to remove, in the field the other clock reads.
  # MEASURED, and it is why the receipt is withheld: with the pre-validation tail, an invalid
  # `CADENCE_NUDGE_VERIFY_TIMEOUT` passed the probe and died inside argparse -- 0 cmux invocations, a
  # `NUDGE at=` line claiming an attempt, and the next tick declining to retry because its own
  # unearned stamp said "attempted 0m ago".
  #
  # ⛔ THE FLOOR CANNOT KNOW THE CHECKER *MADE NO ATTEMPT* -- only that no verdict arrived (#3795 review
  # cycle 2, P1). The verdict comes off a PIPE, so the checker's `print` is block-buffered: a checker
  # that printed and then died before its stdout flushed (SIGTERM does not flush) loses the word having
  # already completed its send. So this state is "no verdict was RECEIVED", not "nothing was sent", and
  # the log line below says exactly that.
  #
  # `UNVERIFIED` keeps its documented meaning (the mapping table above the receipt: a prefix, an
  # unreadable pane, or a refused send -- all AFTER a send attempt). This third state gets its own name
  # and writes NO receipt (see below), which is the only lever both clocks share.
  #
  # Residual, stated because it is a real ambiguity: a checker killed between its `cmux send` and the
  # FLUSH of its buffered stdout is indistinguishable from a pre-send failure, and because this path
  # writes NO receipt, the due read never advances -- so it re-sends on the NEXT tick, and on EVERY
  # tick while the condition persists, not once (#3795 review cycle 3, P2; measured: three runs, three
  # sends, one receipt). The duplicate is therefore bounded by how long the no-verdict state lasts.
  # That is the direction this file already chooses -- "a false UNVERIFIED costs a pane check; a false
  # delivered=yes is how a lane sits idle believing it was woken" -- and a duplicate heartbeat is
  # explicitly not the dangerous duplicate a duplicate lane ORDER is. The alternative (stamp a receipt)
  # is the P1 this branch exists to fix: `NUDGE at=` is read by BOTH clocks, so one unearned stamp
  # silences the tick as well.
  _no_verdict=0
  if [ -z "$verdict" ]; then
    verdict="NO-VERDICT"
    _no_verdict=1
  else
    case "$verdict" in
      VERIFIED) delivered="yes" ;;
      PANE_ONLY|SUBMIT_FAILED) delivered="NOT-SUBMITTED" ;;
      *) delivered="UNVERIFIED" ;;
    esac
    # ⛔ A `SUBMIT_FAILED` PAYLOAD IS STILL SITTING IN THE COMPOSER, SO SUBMIT IT -- DO NOT LEAVE IT FOR
    # THE NEXT TICK TO DUPLICATE (#3795 review cycle 7, P2). The checker types the payload and then
    # presses a SEPARATE Enter; when that Enter fails nothing is submitted, but the text is already in
    # the input box. The receipt below still records the ATTEMPT (so the due read advances and this
    # tick is not re-fired), and the old code therefore typed the WHOLE heartbeat again on the next
    # due tick -- MEASURED on the real floor plus the real checker against a composer-modelling pane:
    # one submitted message of 4261 bytes containing `[HEARTBEAT ` twice. That is precisely the action
    # the adopted checker forbids: `cmux_payload.py`'s `send_verified` docstring says the remedy is to
    # submit in that pane, NEVER to re-send, and the bare `'\n'` here is this file's own "submit what
    # is already typed" shape (the raw-send arm below has used it since before #1187).
    #   A field is added to `diag=[…]` recording the bare-Enter retry and its OUTCOME AS A
    # MEASUREMENT -- `re-submit-attempted=yes rc=<n>` -- so an operator can tell that the retry was
    # made, and what the send it made returned. It is NOT a claim that the Enter landed: that
    # inference is exactly what the block below retires. `delivered=` is deliberately NOT upgraded,
    # because nothing proves the retried Enter landed; the verdict stays `NOT-SUBMITTED` and the next
    # tick still retries.
    # ⛔ AND THE FIELD IS NAMED FOR THE MEASUREMENT, NOT FOR A VERDICT (#3795 review cycle 11, P2).
    # It was `re-submitted=`, derived from this `cmux send`'s EXIT STATUS ALONE — the exact inference
    # this file retires ~200 lines above (`:846-858`: `cmux send` exited 0 over a 1,962-byte message
    # that arrived as its FIRST SENTENCE, and the same `OK` covered an 8-byte `/reload` that vanished).
    # The retried Enter is that SAME call, made seconds later against the SAME pane, so its status is
    # no more evidence of submission than the first one's was -- which is precisely why the checker
    # returned `SUBMIT_FAILED` rather than `VERIFIED` for it. `re-submit-attempted=` states only what
    # was observed (the bare-`\n` send ran, and what its status was), so a reader triaging
    # `NOT-SUBMITTED` is not invited to stop checking a pane whose submission is still unproven.
    # ⛔ ITS RESIDUALS, STATED: (a) if this Enter ALSO fails, the text stays and the duplicate below
    # still happens once per due tick while the condition persists; (b) `PANE_ONLY` is deliberately NOT
    # re-submitted -- there the Enter WAS attempted, so the composer may already be clear, and pressing
    # Enter again would submit whatever else a human has since typed into that pane. `PANE_ONLY` keeps
    # the pre-existing duplicate exposure, bounded the same way.
    if [ "$verdict" = "SUBMIT_FAILED" ]; then
      # ⛔ THE ATTEMPT IS ALWAYS REPORTED, AND THE STATUS IS REPORTED WITH IT (#3795 review cycle 13,
      # P2). This was `re-submit-attempted=yes|no`, split on this send's exit status -- so a retry that
      # was INVOKED AND REFUSED printed `no`, i.e. "not attempted", which is a verdict on the act
      # minted from a status. That is the cycle-11 finding one field over: the call below is made on
      # EVERY `SUBMIT_FAILED` verdict, so the attempt is a fact this file witnessed, and the only thing
      # the status can honestly say is what the send returned. A reader triaging `NOT-SUBMITTED` can
      # then see `rc=0` (refused after the fact, submission still unproven) or a non-zero rc (the
      # retry itself failed) instead of being steered away from a retry that happened.
      cmux send --workspace "$ORCH_WS" --surface "$ORCH_SURFACE" '\n' >/dev/null 2>&1
      _resubmit=" re-submit-attempted=yes rc=$?"
    fi
  fi
  # The checker's stderr is kept: a crashing or refused send must not vanish, or the operator sees
  # only a verdict with no cause (orch-send.sh makes the same call for the same reason).
  _vdiag=""
  [ -s "$_verr" ] && _vdiag=" diag=[$(tr '\n' ' ' <"$_verr" | tail -c 240)]"
  [ "$_verr" = /dev/null ] || rm -f "$_verr"
  _vdiag="${_vdiag}${_resubmit:-}"
else
  # No usable checker on this box. Send anyway (the floor's whole job) and record it as unverified.
  err=$(cmux send --workspace "$ORCH_WS" --surface "$ORCH_SURFACE" "$MSG\n" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    cmux send --workspace "$ORCH_WS" --surface "$ORCH_SURFACE" '\n' >/dev/null 2>&1
  fi
  # ⛔ A BAD ENV VALUE IS NOT AN UNAVAILABLE CHECKER (#3795 review cycle 3, P2). The
  # `CADENCE_NUDGE_VERIFY_TIMEOUT` gate sets `_checker_broken`, so this arm is reached with a PERFECTLY
  # USABLE checker on the box and a rejected config value — and it used to report
  # `verdict=NO-USABLE-CHECKER` with `diag=[payload checker unavailable: CADENCE_NUDGE_VERIFY_TIMEOUT
  # is not a positive number: ...]`: a receipt asserting an absence the box contradicted, which is the
  # exact class the token rename below was meant to close. It now names the config, not the checker.
  case "$_checker_broken" in
    CADENCE_NUDGE_VERIFY_TIMEOUT*) verdict="BAD-VERIFY-TIMEOUT" ;;
    *)
      # ⛔ `NO-USABLE-CHECKER`, NOT `NO-CHECKER` (#3795 review cycle 4, P2). This branch is also reached
      # when the file EXISTS and cannot be used (stale, or broken), so the old token asserted an absence
      # the box contradicted. `diag=[…]` still carries the measured reason.
      verdict="NO-USABLE-CHECKER" ;;
  esac
  delivered="UNVERIFIED"
  # ⛔ THE FAILED SEND'S OWN STDERR IS KEPT (#3795 review P2). This branch exists FOR a broken box, so
  # the cause it already holds — `cmux` refusing the send, or a usage error — is the most valuable
  # line it could report; naming only what is MISSING leaves the operator to guess. `err` was
  # captured and never read.
  # ⛔ THE CAUSE COMES FROM THE ONE DECISION ABOVE, NOT A SECOND COPY OF ITS PREDICATES (#3795 review
  # cycles 2 and 3, P2). `_checker_broken` is non-empty on every path into this branch, so the receipt
  # cannot degrade to `payload checker unavailable: ` with nothing named — which is what a re-derived
  # guard produced when the two copies drifted, and a cause that certifies nothing inside a receipt is
  # the same defect class as the receipt itself. The PREFIX is chosen by which state was measured, for
  # the same reason the token above is.
  case "$_checker_broken" in
    CADENCE_NUDGE_VERIFY_TIMEOUT*) _cause="CADENCE_NUDGE_VERIFY_TIMEOUT rejected: $_checker_broken" ;;
    *) _cause="payload checker unavailable: $_checker_broken" ;;
  esac
  # ⛔ ONLY A FAILED SEND'S OUTPUT IS A "CAUSE" (#3795 review P2). `err` captures the send's SUCCESS
  # banner as well as its failures, and appending it unconditionally made the field that exists to
  # carry the cause present `cmux=[OK surface:19 workspace:19]` as one -- so an operator triaging
  # `diag=` for why a beat was uncertified was shown "OK" and learned nothing, and a genuinely refused
  # send was indistinguishable in shape from a successful one.
  if [ "${rc:-1}" -ne 0 ] && [ -n "$err" ]; then
    _cause="$_cause; cmux=[$(printf '%s' "$err" | tr '\n' ' ' | tail -c 200)]"
  fi
  _vdiag=" diag=[$_cause] rc=${rc:-?}"
fi
# ⛔ THE DUE READ MUST COUNT ATTEMPTS, NOT ONLY SUCCESSES (see the `last=` read near the top). A
# verification that cannot be PROVEN — the orchestrator was mid-turn, so its transcript had not
# flushed inside the window — is a normal outcome here, and if this line only counted verified sends
# the gap would never advance and the floor would re-fire on EVERY tick: a flood, which is the other
# way out of the owner's 5-9 min band. Every attempt that reaches this point stamps `NUDGE at=`, and
# the `delivered=` field carries the verdict, so the reader gets both facts and the cadence stays
# bounded.
# ⛔ THE VALUE STAMPED IS THE TICK START (`now`, captured immediately after the lock), NOT THE SUBMIT
# INSTANT — the same number, and the same stated consequence, as the note on `now` near the top of this
# file (#3795 review cycle 7, P2). Read that note before changing the field's meaning: it names the
# measured band drift and why a submit-instant stamp is not the fix.
#
# ⛔ THE STAMP IS WRITTEN AFTER THE CHECK RETURNS, which is why the wording above says "reaches this
# point" and not "every attempt" (#3795 review P2). A nudge KILLED inside the verification window
# has sent its message and stamped nothing, so the next tick re-fires once the lock takeover expires.
#
# ⛔ AND THE WINDOW IS MEASURED, NOT ASSERTED "SAFE" (#3795 review cycles 2 and 3, P2 — each earlier
# wording understated it). Worst case, with the `--surface` fallback ONE shot, from the real code:
#   3x45 s surface-qualified reads + 1 s of retry sleeps   = 136 s
#   1x45 s workspace-only fallback read                    =  45 s
#   45 s payload send + 2 s sleep + 45 s Enter + 2 s sleep  =  94 s
#   tail sentinel: `--timeout 90` PLUS one `poll_s` (3 s) PLUS one 45 s read-screen, because the
#   deadline is tested AFTER the read and the poll is paid on the iteration that has not yet crossed
#   it (measured: 136.5 s max tail, so 138 is the bound, #3795 review cycle 5)        = 138 s
#                                                        TOTAL = 413 s
# The governing boundary is the 450 s `cadence-timer.sh` interval. An age bound alone is NOT the
# protection it looks like -- this window exceeds any short one -- which is why the takeover at the top
# of this file checks IDENTITY as well as age: a holder is reclaimed only by the 20-min ceiling (never
# by age alone), a pid that is provably not this script at the short grace, and an unidentifiable lock
# not until the ceiling. An age-only takeover here produced two heartbeats 5 s apart; a pid-only one
# killed the floor outright on a recycled pid.
#
# ⛔ AND 413 s IS THE VERIFICATION WINDOW ONLY (#3795 review cycle 4, P2). The lock is taken at the TOP
# of this file and the pre-send work runs under it too: `goal-state.py` is bounded by its 20 s + 3 s
# watchdog, and the `objective.py` reads have no timeout in this file. So the real tick budget is
# 413 s + that work, inside 450 s — not "413 s with 37 s to spare". The margin is thin enough that a
# future retry must not be added against it without re-measuring.
# ⛔ A NO-VERDICT RUN WRITES NO RECEIPT (#3795 review P1). `NUDGE at=` is the claim that this pass
# attempted a beat, and it is read by the tick's rate limiter as well as by this file's due read, so
# stamping it for a pass that may never have reached cmux suppresses the next beat too. Note the
# wording: no verdict was RECEIVED; this file cannot know the checker sent nothing (see the residual
# above), and a receipt whose subject is overstatement must not assert what it did not witness.
# ⛔ AND THERE IS NO `delivered=` FIELD HERE AT ALL, deliberately (#3795 review cycle 2, P2). The due
# read now matches `delivered=.*`, so writing `delivered=NO-VERDICT` would re-arm the exact P1 this
# branch fixes the moment someone "improved" this line into a receipt. The absence of the field is the
# contract; the state lives in `verdict=`.
if [ "${_no_verdict:-0}" = "1" ]; then
  printf '%s CADENCE-NUDGE NOT CERTIFIED verdict=%s%s — no verdict was received from the checker (it printed none, or died before its stdout flushed), so delivery is UNPROVEN; the next tick retries (#1187).\n' \
    "$(date '+%m-%d %H:%M:%S')" "$verdict" "$_vdiag" >> "$LOG"
  exit 0
fi
printf '%s NUDGE at=%s delivered=%s (cadence-floor) gap=%sm queue=[%s] alerts=[] ask=[] verdict=%s%s\n' \
  "$(date '+%m-%d %H:%M:%S')" "$now" "$delivered" "$gap_min" "$q" "$verdict" "$_vdiag" >> "$LOG"
# A failed verdict gets its own line TOO, so a reader scanning for `CADENCE-NUDGE` sees the failure
# without parsing the receipt above, and so the remedy is stated rather than implied. (It is NOT
# backward compatible with the pre-#1187 `CADENCE-NUDGE rc=<n>` line, which this change removed: on the
# no-usable-checker path the exit status is appended AFTER the closing bracket — `diag=[…] rc=<n>`, not
# inside it (`_vdiag=" diag=[$_cause] rc=${rc:-?}"` above) — and on the checker path there is no `rc=`
# FIELD at all, because the exit status of a checker that ran is not a delivery verdict (its stderr may
# of course mention one).
if [ "$delivered" != "yes" ]; then
  printf '%s CADENCE-NUDGE NOT CERTIFIED verdict=%s%s — the nudge was NOT proven delivered; check the orchestrator pane before assuming the beat arrived (#1187).\n' \
    "$(date '+%m-%d %H:%M:%S')" "$verdict" "$_vdiag" >> "$LOG"
fi
exit 0
