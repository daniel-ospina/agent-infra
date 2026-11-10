#!/usr/bin/env bash
# controller-state.sh — WHERE a controller keeps its state, and WHETHER it may run at all.
#
# Sourced by orch-loop.sh (and by its suites). Never executed, and it deliberately does not call
# `set`: a sourced library must not mutate its caller's shell options (same rule as
# scripts/lib/pid-identity.sh).
#
# WHY THIS FILE EXISTS (agent-infra#2095, measured 2026-10-19)
# ----------------------------------------------------------
# A proof copy of orch-loop.sh ran LIVE for 5 h 15 m beside the launchd controller:
#
#   14121  05:15:21  bash /tmp/orc-proof/orch-loop.sh          <- parent: /tmp/live-cycle.sh
#   22947  10:54:23  /bin/bash /Users/…/orchestrator/orch-loop.sh
#   [cap] load=158/100 lanes=0/25 …
#   [dispatch] skipped (load=158>=max_load=100) lanes=0 workers=3
#
# Both resolved `O="${O:-$HOME/orchestrator}"`, so they shared ONE state dir and ONE log, and the
# copy applied its own derived MAX_LOAD=100 against the plist's 250 — for five hours, on a box whose
# live behaviour was therefore governed by a leftover test process. Two defects, one line of code:
#
#   1. the STATE DIR an instance uses was inferred from a convention (a literal path) instead of
#      being decided from the instance's own identity — so a copy silently adopted production state;
#   2. the single-instance lock answered "already running" with a silent `exit 0`, so the SECOND
#      controller looked like a healthy no-op, and its holder test was a bare `kill -0`, which a
#      recycled pid satisfies.
#
# Both are category A (Product Over Process): a false PASS (a quiet exit 0 on a held lock), and a
# bypass (a second controller defeats the singleton by existing).
#
# ⛔ WHAT THIS FILE DELIBERATELY DOES NOT DO
# -----------------------------------------
# It does not replace the machine-wide (machine, repo) registry (`scripts/lib/orchestrator-registry.sh`,
# #1761). That registry answers "does this BOX already run a controller for this repo"; this file is
# the defence-in-depth layer INSIDE one state dir — the layer a hand-started proof copy bypasses by
# never being registered at all. And it does not fork the process-identity rule: `pid-identity.sh`
# (#1178) owns "does this pid still hold this record", and this file consumes it, with a pinned
# mirror only for the farmed copies that ship without a sibling `lib/` (see `_orc_began_after`).

# ── the two paths this module can name ─────────────────────────────────────────────────────────────
# `$HOME/orchestrator` is the PRODUCTION convention: a launchd plist and a cell supervisor both set
# `O` to it. It is not removed as a convention — every deployed install keeps using it untouched.
ORC_PROD_STATE="${ORC_PROD_STATE:-$HOME/orchestrator}"
# Where an isolated instance's state lives. `$TMPDIR` (never a literal /tmp) so a macOS per-user
# temp dir is honoured; the per-copy slug makes two proof runs independent of each other.
ORC_ISOLATED_ROOT="${ORC_ISOLATED_ROOT:-${TMPDIR:-/tmp}}"

# orc_canon <path> — a canonical absolute path, WITHOUT requiring it to exist (so a state dir that
# the controller is about to create still compares correctly, and no `realpath` dependency is added
# to a bash-3.2 target). stdout only; called in a subshell on purpose.
orc_canon() {
  local p="${1:-}" d
  [ -n "$p" ] || return 1
  d="$(cd "$p" 2>/dev/null && pwd -P)" && { printf '%s\n' "$d"; return 0; }
  # Not (yet) a directory: it is only made ABSOLUTE, not resolved — there is no parent walk here.
  # ⛔ Say what the code does: an absolute path is printed verbatim (so two spellings of a path that
  # does not exist yet compare UNEQUAL and the caller takes the isolated branch, i.e. it fails closed);
  # a relative one is anchored on the caller's cwd. A tail-reattach after the deepest existing parent
  # was never implemented, and a comment claiming it sent a reader looking for code that is not here.
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *)  printf '%s/%s\n' "$(pwd -P 2>/dev/null || pwd)" "$p" ;;
  esac
}

# orc_state_slug <copy dir> — a stable, filesystem-safe suffix for one copy's isolated state dir.
# `cksum` is POSIX and present everywhere the harness runs (no `md5`/`shasum` platform split), and
# the readable prefix keeps a box's /tmp legible to the human who has to clean it up.
orc_state_slug() {
  local c="${1:-unknown}" base sum
  base="$(printf '%s' "$c" | tr -c 'A-Za-z0-9._-' '_' | sed 's/__*$//' | cut -c1-40)"
  # (No basename strip here on purpose: the `tr` above already turned every `/` — and every other
  # non-[A-Za-z0-9._-] byte — into `_`, so a `base="${base##*/}"` would be a no-op the reader would
  # have to prove. The slug is readable PREFIX + checksum, not a path, and never contains a slash.)
  sum="$(printf '%s' "$c" | cksum 2>/dev/null | cut -d' ' -f1)"
  [ -n "$sum" ] || sum="0"
  printf '%s-%s\n' "${base:-copy}" "$sum"
}

# ── 1. WHICH STATE DIR ────────────────────────────────────────────────────────────────────────────
# orc_state_pick <copy dir> [<O as the caller found it, BEFORE its own default>]
#
# Sets two GLOBALS and never echoes them, so the caller can print them later without re-deriving
# (a `$( )` here would put the answer in a subshell where `[cap]` could not read it):
#   ORC_STATE_RESOLVED  the directory this instance uses
#   ORC_STATE_SRC       where that choice CAME FROM, printed on `[state]` and `[cap]`
#
# THE ORDER IS THE WHOLE CONTRACT, and it is chosen so that NO existing install changes behaviour:
#   1. ORC_STATE_DIR   — the explicit, modern knob. Always wins.
#   2. an explicit `O` — what a launchd plist, a cell supervisor and keys.env already set. Always
#                        wins, so every deployed box keeps its exact current state dir.
#   3. the copy that LIVES in production (`$HOME/orchestrator/orch-loop.sh` started by hand) — it IS
#                        the deployed controller, so production is its own state dir.
#   4. anything else   — a proof run, a test, a scratch copy, a second checkout: an ISOLATED dir
#                        under $TMPDIR. ⛔ It may not write production state, and that is the rule
#                        the 5 h 15 m incident needed: the copy above took `default:production` and
#                        nothing in either controller's log said so.
orc_state_pick() {
  local copy="${1:-}" env_o="${2-}" cc cp
  ORC_STATE_RESOLVED=""
  ORC_STATE_SRC=""
  if [ -n "${ORC_STATE_DIR:-}" ]; then
    ORC_STATE_RESOLVED="$ORC_STATE_DIR"
    ORC_STATE_SRC="env:ORC_STATE_DIR"
    return 0
  fi
  if [ -n "$env_o" ]; then
    ORC_STATE_RESOLVED="$env_o"
    ORC_STATE_SRC="env:O"
    return 0
  fi
  cc="$(orc_canon "$copy" 2>/dev/null)" || cc=""
  cp="$(orc_canon "$ORC_PROD_STATE" 2>/dev/null)" || cp=""
  if [ -n "$cc" ] && [ "$cc" = "$cp" ]; then
    ORC_STATE_RESOLVED="$ORC_PROD_STATE"
    ORC_STATE_SRC="default:production"
    return 0
  fi
  ORC_STATE_RESOLVED="$ORC_ISOLATED_ROOT/orc-state-$(orc_state_slug "${cc:-${copy:-unknown}}")"
  ORC_STATE_SRC="derived:isolated(${cc:-${copy:-unknown}})"
  return 0
}

# ── 2. THE SINGLETON ─────────────────────────────────────────────────────────────────────────────
# The record file stays exactly what it has always been — a bare pid on one line in `$O/.orch.lock` —
# and that is not laziness. ⛔ THE ROSTER IS NOT AN ENUMERATION, and a previous attempt to write one
# here is how this comment came to say "six": a list goes stale the moment a reader is added, and the
# reader written against it updates the list instead of the code. What holds is the SHAPE: shipped
# readers parse the record with `tr -dc '0-9'` — at least eleven call sites across nine files
# (deploy-mac-orchestrator.sh, install-controller-service.sh, orchestrator-bringup.sh,
# cloud-cell-supervisor.sh, lib/fleet-inventory.sh, cloud-cell-doctor.sh, harness-refresh.sh,
# launchd-cycle.sh, watchdog-loop.sh; find them all with `git grep -nE "tr -dc ['\"]?0-9" scripts/`,
# which is the only count that cannot go stale) — and two read the WHOLE record instead: install.sh
# (`cat`, a non-digit sanitise, then `kill -0`) and selftest.sh (`[ "$(cat …)" = "$pid" ]`, on a
# fixture it created itself). A richer format would make `tr -dc '0-9'` concatenate every digit in the
# record into a pid that never existed, on the stop path of every one of those tools. So the format is
# untouched and the IDENTITY lives in the two things the
# file already has: its pid, and its mtime.

# _orc_record_path_ok <path> — 0 when opening this path as the lock record CANNOT BLOCK: absent, or a
# regular file. ⛔ A NOCLOBBER `>` IS NOT `O_EXCL` FOR A NON-REGULAR FILE, AND IT BLOCKS (measured,
# fresh-context review of #3846 cycle 3): with a FIFO at `.orch.lock`, `( set -o noclobber; … > fifo )`
# opened it O_WRONLY and hung for the whole 5 s probe — the controller neither started nor refused, which
# under launchd KeepAlive is an endless silent restart and a `harness-up` read that hangs with it. A
# device node or a socket at that path is not a record either. A SYMLINK to a regular file is fine
# (`-f` follows it, exactly as the six shipped readers do), and a dangling symlink is "absent" here —
# creating through it is what every other tool does.
_orc_record_path_ok() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  [ -e "$p" ] || return 0
  [ -f "$p" ]
}

# orc_lock_write <lockf> — 0 when THIS process created the record (noclobber is the atomicity).
# The path guard comes FIRST: a caller must not be able to hang on a non-regular object at the record
# path, and returning 1 sends it to the EMPTY-record reclaim, which MOVES that object aside and then
# creates a real record (measured: the FIFO is displaced and the acquire returns rc 0).
orc_lock_write() {
  _orc_record_path_ok "${1:-}" || return 1
  ( set -o noclobber; printf '%s\n' "$$" > "$1" ) 2>/dev/null
}

# orc_lock_pid <lockf> — the digits in the record, or "". The SAME read every sibling tool uses,
# so this file cannot disagree with them about who holds the lock.
# ⛔ NEVER READ A RECORD THAT IS NOT A REGULAR FILE (fresh-context review of #3846, cycle 3, MEASURED).
# `< "$fifo"` BLOCKS until a writer opens it, and the record path is in a state dir that other tools
# and operators also write to: a FIFO there hung `orc_singleton_acquire` for the FULL 5 s probe cap and
# was still blocked when it was SIGKILLed (record left as `type=p`), so the controller neither started
# nor refused — under launchd KeepAlive that is an endless silent restart, and `harness-up`'s read of
# the same path hangs with it. `[ -f ]` is the test: a bare pid file is a REGULAR file, a FIFO/device/
# directory/socket there is not a record at all, and a symlink to a regular file is still read (the six
# shipped readers follow it too). Anything else yields "" — the same answer as an empty record, which
# every reader already treats as STOPPED — so the caller takes the EMPTY-record reclaim path and
# displaces the odd object instead of blocking on it.
# ⛔ `2>/dev/null` BEFORE the redirect, not after: redirections apply left to right, so a FAILED
# `<` reports to a stderr that is already silenced here — but with the order reversed the shell itself
# printed `…/.orch.lock: No such file or directory` onto the controller's stderr for a record that was
# legitimately absent mid-reclaim (measured; it read as a fault in the module).
orc_lock_pid() {
  [ -f "${1:-}" ] || return 0
  tr -dc '0-9' 2>/dev/null < "$1"
}

# orc_mtime <file> — epoch seconds of the record's last write. `date -r` is BSD and GNU both.
orc_mtime() { date -r "$1" +%s 2>/dev/null; }

# orc_lock_fill <displaced record> <lockf> — put a record back into a FREE path, ATOMICALLY.
# rc 0 restored · rc 1 the path was already taken (a newer holder owns it) · rc 2 could not be restored
# ⛔ ONE OPERATION, NOT A CHECK THEN A WRITE (fresh review of #3846, P2 — the check-then-act was real).
# The shipped restore was `[ -e "$lockf" ] || mv -f "$tmp" "$lockf"`: two operations, and the second is
# `rename(2)`, which REPLACES its target unconditionally. A third starter that noclobber-created its
# record BETWEEN the test and the move was therefore still overwritten by the older pid — precisely the
# interleaving that line's comment claimed to close. Measured on this box: `mv -f` onto an existing
# path left the SECOND writer's pid there (it replaced); `ln` onto an existing path refused with
# `File exists` and left the target untouched.
# `ln` is the atomic create-if-absent, and it is the SAME class of guarantee `orc_lock_write` gets
# from `noclobber` — the primitive this module already relies on everywhere else.
# ⛔ `ln` RATHER THAN A NOCLOBBER WRITE OF THE CAPTURED PID, because a hard link keeps the INODE and so
# the displaced record's own mtime — and that mtime is the evidence the identity fence reads
# (`orc_began_after`: "did this process begin after the record was written"). A fresh mtime would make
# a reclaimable stale record permanent. Both names are in the same directory by construction
# (`$lockf.reclaim.$$`), so there is no cross-device case for `ln` to fail on.
# ⛔ BUT "ln FAILED" IS NOT "THE PATH IS TAKEN", AND COLLAPSING THE TWO DESTROYS THE ONLY COPY (same
# review round, measured). `ln` also fails with the destination FREE: EPERM under
# `fs.protected_hardlinks=1` when the record is owned by another user (a sudo/service-installed
# controller), ENOSPC on an inode-exhausted state dir, or a filesystem with no hard links — while
# `mv`/`rename` in that same directory still succeeds (measured: EPERM and ENOSPC both gave `mv` rc 0
# and `ln` rc 1). Reporting that as "taken" made the caller delete the record it had just moved aside
# — the only copy of another instance's record — after which the state dir reads FREE and the next
# starter ACQUIRES over a third instance that still believes it holds it (#1715). So: a failure with
# an OCCUPIED target is rc 1 (the occupant wins, our copy is surplus); a failure with a FREE target is
# restored with the other atomic create this module already uses (noclobber, which needs no link
# permission), and only a target that is STILL FREE and unwritable is rc 2.
# ⛔ CONTENT DECIDES, EXISTENCE DOES NOT (fresh-context review of #3846, cycle 2, measured). An `O_EXCL`
# create can SUCCEED and the WRITE then fail — ENOSPC, EFBIG, `ulimit -f` — leaving a **0-byte record
# we created ourselves** (measured with `ulimit -f 0`: `create rc=153, file exists: YES size=0`).
# `[ -e "$lockf" ]` cannot tell that apart from a third starter's record, and answering "taken" for it
# made the caller delete the displaced record AND leave a record that every reader treats as STOPPED —
# so the next starter reclaimed it and ACQUIRED over a still-live displaced holder (#1715). The read is
# therefore `orc_lock_pid`, and only a NON-EMPTY record that is not the pid we were restoring counts as
# an occupant. An empty or absent path is "nothing to trust": rc 2, and the caller KEEPS the only copy.
orc_lock_fill() {
  local tmp="${1:-}" lockf="${2:-}" pid="" at=""
  [ -n "$tmp" ] && [ -n "$lockf" ] || return 2
  if ln "$tmp" "$lockf" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 0
  fi
  at="$(orc_lock_pid "$lockf")"
  [ -n "$at" ] && return 1                     # a REAL holder owns the path; our copy is surplus
  pid="$(orc_lock_pid "$tmp")"
  [ -n "$pid" ] || return 2                    # nothing to restore — the caller must not delete the temp
  # ⛔ THE FALLBACK WRITE GETS THE SAME PATH GUARD AS `orc_lock_write`: a plain `>` onto a FIFO blocks
  # (measured), and this branch is precisely the one where the path is NOT a record we could read.
  _orc_record_path_ok "$lockf" || return 2
  # The path is not held (absent, or a record with no pid in it) and could not be linked into. Restore
  # it the other atomic way: a noclobber create can only succeed if the path is still free, so a third
  # starter that got there first still wins. The mtime cost noted above is the right trade HERE: the
  # alternative is an empty state dir, and a record that reads "written now" is HELD (refuse) rather
  # than FREE (co-run).
  ( set -o noclobber; printf '%s\n' "$pid" > "$lockf" ) 2>/dev/null
  at="$(orc_lock_pid "$lockf")"
  if [ "$at" = "$pid" ]; then
    rm -f "$tmp" 2>/dev/null
    return 0
  fi
  [ -n "$at" ] && return 1                     # a third starter won the fallback too
  return 2                                      # empty/absent: nothing to trust; the copy is KEPT
}

# orc_lock_reclaim <lockf> <the stale pid this caller judged> — replace a record whose holder is
# PROVEN not to be the live owner.
#
# ⛔ NOT A BARE `rm -f` (and the old `acq()` shape was exactly that): between "read the pid" and
# "remove the record" a second starter can take the lock, and an unconditional `rm` then deletes a
# LIVE holder's record — the singleton defeated by the very code that grants it. So the record is
# MOVED aside atomically and re-read: if it no longer names the pid this caller judged stale, it
# belongs to somebody who won the race and is put back untouched.
#
# ⛔ THREE OUTCOMES, AND 2 IS NOT 1. `orc_lock_reclaim` used to answer only 0/1, so its ONE failure
# arm had to carry two unrelated states — "another starter took the record" and "the state dir is not
# writable" — and the caller minted both into rc 2 UNJUDGED. That is a FALSE STATEMENT about the first
# one: rc 2 makes `orch-loop.sh` print "the record … could not be judged (contents: '<winner pid>')"
# and makes `harness-up`'s REFUSED-UNJUDGED row hand the operator `rm -f .orch.lock` as the remedy,
# about a FRESH, perfectly readable record naming the LIVE winner (fresh review of #3846, P2).
# So: 0 = we hold it · 1 = ANOTHER pid holds it, named in ORC_RECLAIM_HOLDER · 2 = cannot tell.
orc_lock_reclaim() {
  local lockf="${1:-}" expected="${2-}" tmp got="" winner="" frc=0
  ORC_RECLAIM_HOLDER=""
  ORC_RECLAIM_TEMP=""
  [ -n "$lockf" ] || return 2
  tmp="$lockf.reclaim.$$"
  mv -f "$lockf" "$tmp" 2>/dev/null || return 2
  got="$(orc_lock_pid "$tmp")"
  if [ "$got" != "$expected" ]; then
    # Somebody took the lock while we were judging it: this record is THEIRS, not the stale one this
    # caller judged. Put it back into a FREE path — the fill is atomic, so a THIRD starter that
    # created its own record first keeps it — and report who holds the state dir now.
    # ⛔ THE TEMP IS DELETED ONLY WHEN THE PATH IS DEMONSTRABLY TAKEN. `|| rm -f "$tmp"` deleted the
    # only copy for EVERY failure, including the non-EEXIST ones where the path is FREE — see
    # `orc_lock_fill`'s header for the measured EPERM/ENOSPC cases. A failed restore keeps the record.
    orc_lock_fill "$tmp" "$lockf"; frc=$?
    case "$frc" in
      0) : ;;                                   # restored; the fill consumed the temp
      1) rm -f "$tmp" 2>/dev/null ;;            # the path is TAKEN: its occupant is the holder
      *) ORC_RECLAIM_TEMP="$tmp" ;;             # not restored: keep the only copy, and say where it is
    esac
    winner="$(orc_lock_pid "$lockf")"
    if [ -n "$winner" ] && [ "$winner" != "$expected" ]; then
      ORC_RECLAIM_HOLDER="$winner"
      return 1
    fi
    return 2
  fi
  rm -f "$tmp" 2>/dev/null
  if orc_lock_write "$lockf"; then return 0; fi
  # ⛔ THIS ARM IS NOT "UNJUDGED" (fresh review of #3846, P2; same root as the restore above).
  # `orc_lock_write` is a noclobber create, so after our own stale record was moved aside the ONLY way
  # it fails is that a THIRD starter created the record first — and that starter ACQUIRED, atomically.
  # Reporting 2 asserted that a fresh, readable record naming the LIVE winner "could not be judged",
  # and both operator rows that read 2 then invited `rm -f` of that winner's record. Positive evidence
  # of a new holder is HELD: name it and refuse.
  winner="$(orc_lock_pid "$lockf")"
  if [ -n "$winner" ]; then
    ORC_RECLAIM_HOLDER="$winner"
    return 1
  fi
  return 2
}

# ── the slack seam, VALIDATED BEFORE IT REACHES ARITHMETIC (agent-infra#2095 review, P1) ─────────
# ⛔ AN UNVALIDATED READ OF THIS SEAM FAILS OPEN, AND HERE THE OPEN DIRECTION IS THE DESTRUCTIVE ONE.
# It is the ONLY input to the reclaim decision that comes from the environment, and the arithmetic it
# feeds runs inside a `set -u` shell. `origin/main` carried this guard INLINE in its own lock block
# (`orch-loop.sh:2335-2351`); this module inherited the VARIABLE and lost the GUARD, so the guard is
# restored here, one place, rather than folded into the arithmetic line.
#
# MEASURED on the pre-fix head, driving `orc_singleton_acquire` with a LIVE process and a record whose
# mtime is LATER than that process's start (the normal HELD case):
#
#   unset      -> rc 1 HELD by live controller pid N           (correct)
#   -100       -> rc 0 'reclaimed a RECYCLED pid (… began after …)'  ⛔ THE LIVE OWNER'S RECORD IS
#                 DISPLACED: two controllers on one state dir (#1715), and an UNOWNED lock afterwards.
#                 On main the same value is non-digit -> 5 -> HELD.
#   60/100000  -> rc 1 HELD                                    (correct: fail-closed)
#   1.5        -> 'syntax error: invalid arithmetic operator', then `ORC_SINGLETON_RC: unbound
#                 variable` -> the loop dies with NO `[singleton]` line and NO 74/75
#   08         -> 'value too great for base' — ⛔ ALL-DIGITS AND STILL FATAL: bash reads a leading
#                 zero as OCTAL, so a digits-only guard is NOT enough (the textual strip below is)
#   abc        -> 'abc: unbound variable'                     -> the same cryptic death
#
# ⛔ AND THE ARITHMETIC FAULT ABORTS THE AND-OR LIST. `orc_singleton_acquire "$LOCKF"; RC=$?` never
# assigns, so the caller dies on `case "$ORC_SINGLETON_RC"` under `set -u` — neither the loud refusal
# nor `exit 75` is reached, which is the #1985 cryptic-stop class this file exists to end. Validating
# here is what stops that fault happening at all.
# ⛔ `scripts/lib/pid-identity.sh:188` carries the SAME unvalidated seam for `PID_START_SLACK_SECONDS`,
# reachable through the `pid_began_after` arm below. That gap is PRE-EXISTING on main and is NAMED
# here rather than silently copied — this fix restores the guard for THIS module's seam only.
_orc_lock_slack() { # <candidate> -> a bounded, decimal, all-digit slack on stdout
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) s=5 ;; esac
  # Leading zeros stripped TEXTUALLY, never normalised through `$(( ))`: `08` is all-digits and an
  # OCTAL ERROR in arithmetic. This NORMALISES (`08` -> 8, `007` -> 7); it does not reject, and main
  # documented the same behaviour for the same values.
  while [ "${#s}" -gt 1 ] && [ "${s#0}" != "$s" ]; do s="${s#0}"; done
  # A slack wider than the fence itself is not a setting, it is a DEFEAT of the fence. The LENGTH test
  # comes FIRST so an absurd value is capped instead of reaching `[ -le ]` as an 'integer expression
  # expected' error. Same bound as `fleet-inventory.sh`'s copy of this fence.
  { [ "${#s}" -le 2 ] && [ "$s" -le 60 ]; } || s=5
  printf '%s\n' "$s"
}
# Established once at load, so the variable always MEANS a decided value to any later reader (the same
# doctrine `orc_state_pick` applies to `O`: a decision, not a default).
ORC_LOCK_START_SLACK_SECONDS="$(_orc_lock_slack "${ORC_LOCK_START_SLACK_SECONDS:-5}")"

# orc_began_after <pid> <epoch> — 0 the process BEGAN after that epoch (so it cannot own a record
# written earlier: a recycled pid), 1 provably before (it may own it), 2 CANNOT TELL.
#
# ⛔ THE THIRD OUTCOME IS THE POINT. Folding "cannot tell" into either arm is a defect this fleet has
# already measured twice (#1856/#2402): reading it as 1 makes an unreadable age the strongest
# evidence of ownership (and the singleton would then refuse every start on a box whose `ps -o etime`
# is broken), reading it as 0 makes it evidence of a recycled pid (and the singleton would steal a
# live controller's lock). Callers fail CLOSED on 2.
#
# ⛔ ONE RULE, TWO HOMES, PINNED. `scripts/lib/pid-identity.sh` owns this (#1178) and is used
# whenever it can be found. A FLAT DEPLOY has no `lib/` sibling (`$O` IS the harness dir, so
# `$O/../lib` is `$HOME/lib`, which no deploy writes), so the body below is a VERBATIM MIRROR — the
# same arrangement `install-controller-service.sh:1275` documents for the same reason, and
# `controller-state.test.sh` §5 extracts both bodies and REDDENS if they drift.
_orc_proc_start_epoch() {
  local p="${1:-}" e d h m s r
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  e="$("${PS_BIN:-/bin/ps}" -o etime= -p "$p" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ -n "$e" ] || return 1
  d=0
  case "$e" in *-*) d="${e%%-*}"; r="${e#*-}" ;; *) r="$e" ;; esac
  case "$d" in ''|*[!0-9]*) return 1 ;; esac
  case "$r" in
    *:*:*) h="${r%%:*}"; r="${r#*:}"; m="${r%%:*}"; s="${r##*:}" ;;
    *:*)   h=0;                 m="${r%%:*}"; s="${r##*:}" ;;
    *) return 1 ;;
  esac
  case "$h$m$s" in ''|*[!0-9]*) return 1 ;; esac
  # 10#, never a bare arithmetic expansion: etime ZERO-PADS its fields and bash reads 08 as OCTAL, so
  # an 08/09 in any field made this fail — and a failed age must never read as "began before".
  h=$((10#${h:-0})); m=$((10#${m:-0})); s=$((10#${s:-0})); d=$((10#${d:-0}))
  printf '%s\n' "$(( $(date +%s) - (d * 86400 + h * 3600 + m * 60 + s) ))"
}
orc_began_after() {
  local pe="${2-}" ps slack
  if command -v pid_began_after >/dev/null 2>&1; then pid_began_after "$1" "$pe"; return $?; fi
  case "$pe" in ''|*[!0-9]*) return 2 ;; esac
  ps="$(_orc_proc_start_epoch "${1:-}")" || return 2
  # ⛔ RE-VALIDATED AT THE POINT OF USE, not only at load. A caller that assigns the seam AFTER
  # sourcing this module would otherwise reach the arithmetic with it again — and that is exactly the
  # path a reviewer takes to check this fix, so leaving it open would re-open the finding. One rule,
  # `_orc_lock_slack`, applied at both ends.
  slack="$(_orc_lock_slack "${ORC_LOCK_START_SLACK_SECONDS:-5}")"
  [ "$ps" -gt "$((pe + slack))" ]
}

# _orc_reclaim <lockf> <expected> <acquired sentence> <what was judged> — map `orc_lock_reclaim`'s
# three outcomes onto the singleton's: 0 ACQUIRED · 1 HELD by whoever won the race · 2 UNJUDGED.
# ⛔ ONE MAPPING, THREE CALLERS, ON PURPOSE. The pre-fix code repeated "if orc_lock_reclaim ⇒ acquired
# else ⇒ 2 UNJUDGED" in all three arms, so all three inherited the same false UNJUDGED for a race that
# another starter had already won (fresh review of #3846, P2). A fourth copy in this file is how the
# arms would drift apart again.
_orc_reclaim() {
  local lockf="${1:-}" expected="${2-}" ok="${3:-reclaimed the record}" judged="${4:-the record}" rc=0
  orc_lock_reclaim "$lockf" "$expected"; rc=$?
  case "$rc" in
    0) ORC_SINGLETON_WHY="$ok"; return 0 ;;
    1) # ⛔ NOT "could not be replaced": another instance created this record while we were judging
       # it, and its create was atomic (noclobber), so IT holds the state dir and it is ALIVE enough
       # to have just written. rc 2 here sent the operator to `rm -f` a live winner's record.
       ORC_SINGLETON_WHY="HELD by pid ${ORC_RECLAIM_HOLDER:-?} — it CREATED $lockf while this instance was judging $judged, and that create was atomic, so it owns this state dir and this instance does not"
       return 1 ;;
    *) if [ -n "${ORC_RECLAIM_TEMP:-}" ]; then
         ORC_SINGLETON_WHY="the record at $lockf could not be judged while judging $judged, and it could NOT be put back (is the state dir writable?). Nothing was deleted: the displaced record is KEPT at $ORC_RECLAIM_TEMP, so no state was lost — move it back to $lockf once the state dir is writable again"
       else
         ORC_SINGLETON_WHY="the record at $lockf could not be judged and could not be replaced while judging $judged (is the state dir writable?); nothing was removed"
       fi
       return 2 ;;
  esac
}

# orc_singleton_acquire <lockf> — 0 ACQUIRED, 1 HELD by a live controller, 2 UNJUDGED.
# Sets ORC_SINGLETON_WHY to a human sentence naming the evidence, for the refusal line.
orc_singleton_acquire() {
  local lockf="${1:-}" holder="" lt="" rc=0
  ORC_SINGLETON_WHY=""
  # ⛔ THE OUT-PARAMETERS ARE CLEARED HERE, NOT ONLY INSIDE `orc_lock_reclaim` (fresh-context review of
  # #3846, cycle 3, measured). `orc_lock_reclaim` resets them per RECLAIM, but a second acquire that
  # returns 2 without reaching a reclaim (an unreadable age, say) then reported the PREVIOUS call's
  # temp path — and `orch-loop.sh:2472` branches on `ORC_RECLAIM_TEMP`, so it would print "KEPT at
  # <stale path>" and tell the operator to `mv` a stale temp over a live holder's record. Latent today
  # (the one shipped caller acquires once per process), but this file is a library and the same two
  # lines `ORC_SINGLETON_WHY` already gets cost nothing.
  ORC_RECLAIM_HOLDER=""
  ORC_RECLAIM_TEMP=""
  if [ -z "$lockf" ]; then ORC_SINGLETON_WHY="no lock path was supplied"; return 2; fi
  if orc_lock_write "$lockf"; then ORC_SINGLETON_WHY="acquired"; return 0; fi
  holder="$(orc_lock_pid "$lockf")"
  # An EMPTY record is not a holder. Every shipped reader already treats it as STOPPED
  # (`install-controller-service.sh:1330`, `cloud-cell-supervisor.sh:733`), so reclaiming it steals
  # nothing — there is no pid to displace.
  if [ -z "$holder" ]; then
    _orc_reclaim "$lockf" "" "reclaimed an EMPTY record" "an EMPTY record"; return $?
  fi
  # Dead pid: the SIGKILL / OOM / reboot path the reclaim exists for.
  if ! kill -0 "$holder" 2>/dev/null; then
    _orc_reclaim "$lockf" "$holder" "reclaimed a DEAD holder (pid $holder is gone)" "dead holder pid $holder"; return $?
  fi
  # Alive. ⛔ A LIVE PID IS NOT OWNERSHIP — a recycled pid is alive too, and on this fleet the
  # recycled target is a PEER repo's controller running the same shared harness path, so shape alone
  # matches perfectly (#1178, #2402). A controller writes its record AFTER it starts, so a process
  # that BEGAN after the record was written cannot be its owner.
  lt="$(orc_mtime "$lockf")"
  orc_began_after "$holder" "${lt:-}"; rc=$?
  case "$rc" in
    0)
      _orc_reclaim "$lockf" "$holder" \
        "reclaimed a RECYCLED pid ($holder began after the record was written, so it is not this state dir's controller)" \
        "a RECYCLED pid $holder"
      return $? ;;
    1)
      ORC_SINGLETON_WHY="HELD by live controller pid $holder (it began before the record was written, so it IS this state dir's controller)"
      return 1 ;;
    *)
      ORC_SINGLETON_WHY="HELD by pid $holder, whose AGE CANNOT BE READ — so it cannot be shown to be a recycled pid, and this instance refuses rather than displace a controller it cannot identify"
      return 2 ;;
  esac
}

# orc_singleton_release <lockf> — remove the record ONLY when it is this process's.
#
# The shipped trap was `rm -f "$LOCKF"` unconditionally. That is safe only while nothing else can
# have written the record between our acquire and our exit — and after a reclaim race (or an
# operator's manual `rm -f` followed by a fresh start) it is not: an exiting instance would delete
# the NEW holder's record and the next start would then co-run with it. Ownership is checked, not
# assumed.
orc_singleton_release() {
  local lockf="${1:-}" p=""
  [ -n "$lockf" ] || return 0
  p="$(orc_lock_pid "$lockf")"
  [ "$p" = "$$" ] || return 0
  rm -f "$lockf" 2>/dev/null
}

# ── 3. PROVENANCE TOKENS ─────────────────────────────────────────────────────────────────────────
# `ctl=` on the `[cap]` line. Without it, a `[cap]` line cannot answer WHICH controller wrote it —
# which is precisely what made the 5 h 15 m incident take a `ps` archaeology session to find: two
# controllers were writing the same log, and the line that carried the effective ceiling carried no
# identity at all. The copy's own directory is in the token on purpose: that IS the discriminator
# between the plist and a proof run.
orc_instance_id() {
  local state="${1:-$ORC_PROD_STATE}" where="${2:-${_HERE_RS:-unknown}}"
  printf 'pid=%s@%s#%s\n' "$$" "${where##*/}" "$(printf '%s' "$state" | cksum 2>/dev/null | cut -d' ' -f1)"
}

# orc_max_load_src is deliberately NOT a function here: see the `MAX_LOAD_SRC` block in
# `orch-loop.sh`. selftest.sh's lane-derivation driver extracts the `^_NCPU=` … `^MAX_REVIEW=` range
# and runs it in a bare shell, so a `$(orc_max_load_src …)` there would print `command not found` into
# a driver that is asserting on MAX_LANES. The ranking rule (env → derived) lives with the one caller
# that uses it, and `controller-state.test.sh` §6 drives the SHIPPED lines rather than a copy.
