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
  # Not (yet) a directory: canonicalise the deepest existing parent, then re-attach the tail.
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
  base="${base##*/}"
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
# and that is not laziness. Six shipped readers parse it with `tr -dc '0-9'` and two compare it to a
# pid with `[ "$(cat …)" = "$pid" ]` (deploy-mac-orchestrator.sh, install-controller-service.sh,
# orchestrator-bringup.sh, cloud-cell-supervisor.sh, install.sh, selftest.sh). A richer format would
# make `tr -dc '0-9'` concatenate every digit in the record into a pid that never existed, on the
# stop path of six tools. So the format is untouched and the IDENTITY lives in the two things the
# file already has: its pid, and its mtime.

# orc_lock_write <lockf> — 0 when THIS process created the record (noclobber is the atomicity).
orc_lock_write() { ( set -o noclobber; printf '%s\n' "$$" > "$1" ) 2>/dev/null; }

# orc_lock_pid <lockf> — the digits in the record, or "". The SAME read every sibling tool uses,
# so this file cannot disagree with them about who holds the lock.
orc_lock_pid() { tr -dc '0-9' < "$1" 2>/dev/null; }

# orc_mtime <file> — epoch seconds of the record's last write. `date -r` is BSD and GNU both.
orc_mtime() { date -r "$1" +%s 2>/dev/null; }

# orc_lock_reclaim <lockf> <the stale pid this caller judged> — replace a record whose holder is
# PROVEN not to be the live owner.
#
# ⛔ NOT A BARE `rm -f` (and the old `acq()` shape was exactly that): between "read the pid" and
# "remove the record" a second starter can take the lock, and an unconditional `rm` then deletes a
# LIVE holder's record — the singleton defeated by the very code that grants it. So the record is
# MOVED aside atomically and re-read: if it no longer names the pid this caller judged stale, it
# belongs to somebody who won the race and is put back untouched.
orc_lock_reclaim() {
  local lockf="${1:-}" expected="${2-}" tmp got=""
  [ -n "$lockf" ] || return 1
  tmp="$lockf.reclaim.$$"
  mv -f "$lockf" "$tmp" 2>/dev/null || return 1
  got="$(orc_lock_pid "$tmp")"
  if [ "$got" != "$expected" ]; then
    # Somebody took the lock while we were judging it. Restore theirs and report the refusal.
    mv -f "$tmp" "$lockf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 1
  fi
  rm -f "$tmp" 2>/dev/null
  orc_lock_write "$lockf"
}

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
  local pe="${2-}" ps
  if command -v pid_began_after >/dev/null 2>&1; then pid_began_after "$1" "$pe"; return $?; fi
  case "$pe" in ''|*[!0-9]*) return 2 ;; esac
  ps="$(_orc_proc_start_epoch "${1:-}")" || return 2
  [ "$ps" -gt "$((pe + ${ORC_LOCK_START_SLACK_SECONDS:-5}))" ]
}

# orc_singleton_acquire <lockf> — 0 ACQUIRED, 1 HELD by a live controller, 2 UNJUDGED.
# Sets ORC_SINGLETON_WHY to a human sentence naming the evidence, for the refusal line.
orc_singleton_acquire() {
  local lockf="${1:-}" holder="" lt="" rc=0
  ORC_SINGLETON_WHY=""
  if [ -z "$lockf" ]; then ORC_SINGLETON_WHY="no lock path was supplied"; return 2; fi
  if orc_lock_write "$lockf"; then ORC_SINGLETON_WHY="acquired"; return 0; fi
  holder="$(orc_lock_pid "$lockf")"
  # An EMPTY record is not a holder. Every shipped reader already treats it as STOPPED
  # (`install-controller-service.sh:1330`, `cloud-cell-supervisor.sh:733`), so reclaiming it steals
  # nothing — there is no pid to displace.
  if [ -z "$holder" ]; then
    if orc_lock_reclaim "$lockf" ""; then ORC_SINGLETON_WHY="reclaimed an EMPTY record"; return 0; fi
    ORC_SINGLETON_WHY="the record at $lockf is EMPTY and could not be replaced (is the state dir writable?)"
    return 2
  fi
  # Dead pid: the SIGKILL / OOM / reboot path the reclaim exists for.
  if ! kill -0 "$holder" 2>/dev/null; then
    if orc_lock_reclaim "$lockf" "$holder"; then ORC_SINGLETON_WHY="reclaimed a DEAD holder (pid $holder is gone)"; return 0; fi
    ORC_SINGLETON_WHY="dead holder pid $holder in $lockf could not be replaced"
    return 2
  fi
  # Alive. ⛔ A LIVE PID IS NOT OWNERSHIP — a recycled pid is alive too, and on this fleet the
  # recycled target is a PEER repo's controller running the same shared harness path, so shape alone
  # matches perfectly (#1178, #2402). A controller writes its record AFTER it starts, so a process
  # that BEGAN after the record was written cannot be its owner.
  lt="$(orc_mtime "$lockf")"
  orc_began_after "$holder" "${lt:-}"; rc=$?
  case "$rc" in
    0)
      if orc_lock_reclaim "$lockf" "$holder"; then
        ORC_SINGLETON_WHY="reclaimed a RECYCLED pid ($holder began after the record was written, so it is not this state dir's controller)"
        return 0
      fi
      ORC_SINGLETON_WHY="recycled pid $holder in $lockf could not be replaced"
      return 2 ;;
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

# orc_max_load_src <input as the caller found it> <origin hint> — WHICH input decided MAX_LOAD.
# `plist(<origin>)` when the launchd render says so (`ORC_CONTROLLER_ORIGIN`), `env` when some other
# environment set it, `derived:cores` when the loop computed it. The point is not the label: it is
# that a `[cap]` line printed `load=158/100` while the plist said 250, and NOTHING in the line said
# the number in force had been derived by the copy rather than set by the unit.
orc_max_load_src() {
  if [ -n "${1:-}" ]; then
    if [ -n "${2:-}" ]; then printf 'plist(%s)\n' "$2"; else printf 'env\n'; fi
    return 0
  fi
  printf 'derived:cores\n'
}
