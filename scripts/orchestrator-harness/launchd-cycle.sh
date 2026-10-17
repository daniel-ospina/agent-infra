#!/usr/bin/env bash
# launchd-cycle.sh — the ONE implementation of "stop / enable / (re)start / PROVE it started" for this
# repo's launchd job. Sourced by scripts/orchestrator-harness/install.sh; driven directly by
# scripts/install-launchd-durability.test.sh with a stub `launchctl` first on PATH.
#
# ⛔ THE RULE THIS FILE ENCODES: NEVER WRITE A PERSISTENT DISABLE, AND NEVER REPORT A START YOU DID NOT
#    VERIFY.
#
# The old flow was `launchctl unload -w` followed by `launchctl load -w` (install.sh --uninstall, its
# printed start/stop guidance, and the README §4/§6/§9 commands an agent copies). `-w` is not a
# convenience flag — `man launchctl` says it "Overrides the Disabled key and sets it to true … the state
# of the Disabled key is stored elsewhere on-disk in a location that may not be directly manipulated by
# any process other than launchd", and `enable | disable`: "Once a service is disabled, it cannot be
# loaded in the specified domain until it is once again enabled. This state persists across boots."
#
# So the pair was a DISABLE whose re-enable depended on a `bootstrap` that is allowed to fail — and on
# 2026-10-17 it failed (`Bootstrap failed: 5: Input/output error`, in launchd's log as "Setting service
# com.eldato.orchestrator-loop to disabled … removing service"). com.eldato.orchestrator-loop was left
# removed AND disabled, the installer exited 0, and the Mac dispatched nothing for 48 minutes, then 19
# more — invisible, because the only signal was an absent heartbeat (agent-infra#1975).
#
# `bootout` writes NO override at all, so the worst case of a failed cycle is "not loaded" (the very
# next start repairs it) instead of "disabled" (persistent, silent, and only fixable by name).
#
# ⛔ AND A START MUST PROVE ITSELF. An installer that exits 0 with no controller running is the false
# PASS class in AGENTS.md, which is exactly what "an operator believes the fleet is supervised" costs.
# lc_ensure/lc_restart therefore assert BOTH that the label is loaded WITH A PID and that the
# heartbeat file advanced.
#
# Conventions in this file:
#   • FUNCTIONS PRINT VALUES ON STDOUT and diagnosis on stderr, so a caller can do
#     `via="$(lc_start …)"` without swallowing the message a human needs.
#   • NO `set -e` here: this file is SOURCED, and a sourced file must not change its caller's shell
#     options. Every function states its own exit status and leaves no stray non-zero return behind.
#   • The only launchctl verbs used are `bootout`, `enable`, `bootstrap`, `load` (legacy fallback) and
#     `print` (read-only). There is no `unload`, no `disable`, and no `-w` anywhere in this file — the
#     test suite asserts that, because it is the whole point.

# lc_domain — the launchd domain this user's agents live in. `gui/<uid>` is what `launchctl list` and
# the rendered plist's LaunchAgents location both mean; a session started from an SSH shell still owns
# the same job, which is why the domain is derived and never hardcoded.
lc_domain() { printf 'gui/%s\n' "$(id -u)"; }

lc_err() { printf '%s\n' "$*" >&2; }

# lc_bootout <label> <plist>
# Remove the job definition. NO `-w` and no `unload`, so launchd's persistent Disabled override is
# never touched — this is the difference between "not loaded" (recoverable) and "disabled" (silent and
# sticky).
#
# ⛔ PATH-KEYED, NEVER LABEL-KEYED (#1975). `launchctl bootout gui/<uid>/<label>` resolves the label in
# the REAL user domain and IGNORES $HOME — so an installer run against a sandbox HOME (the self-test's
# sandbox, a lane validating the harness) would boot out the PRODUCTION controller. That is the same
# failure this whole file exists to prevent, arriving through a different door; the service-target form
# is therefore not used here at all, and the plist path is the only handle. Consequence, stated: a job
# whose plist has already been deleted cannot be removed by this function — it returns 0 and the job is
# left loaded, which the caller's own read of `launchctl print` (and `pkill` per README §6) can see.
lc_bootout() {
  local plist="${2:-}" d
  d="$(lc_domain)"
  if [ -n "$plist" ] && [ -e "$plist" ]; then
    launchctl bootout "$d" "$plist" 2>/dev/null && return 0
  fi
  return 0
}

# lc_enable <label>
# CLEAR a persistent disable before loading. This is why a box that a previous `-w` disabled can be
# recovered by an ordinary start, and it is the one verb here that removes a disable. Tolerated on
# failure: a job with no override at all is the healthy state, and `enable` is allowed to report
# nonzero for a service the domain does not know yet.
lc_enable() { launchctl enable "$(lc_domain)/$1" 2>/dev/null || true; }

# lc_pid <label> — the job's pid, or EMPTY when it is not loaded or is loaded but not running.
# `launchctl print` is the modern, non-mutating read; the `pid = N` line sits at the top level of the
# service block (nested process blocks carry `state = active`, not `pid`), so the first match is the
# job's own pid. `launchctl list <label>` would answer the same question on older systems but prints
# nothing structural on current ones; the test suite pins this parse against a captured real block.
lc_pid() {
  local out
  out="$(launchctl print "$(lc_domain)/$1" 2>/dev/null)" || return 0
  # ⛔ HERE-STRING, NO PIPE (#841): a `… | head -n 1` here would let head exit early and the writer
  # take SIGPIPE, and under the caller's `pipefail` the pipeline's status — and therefore lc_pid's —
  # becomes 141 on a perfectly good read. awk exits on its own after the first match; nothing is left
  # to signal.
  awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }' <<<"$out"
}

# lc_hb_age <O> — seconds since the controller last wrote $O/heartbeat, or EMPTY when there is no
# readable heartbeat. Empty is "unknown", never "fresh": a reader that treats a missing heartbeat as
# healthy would report a dead controller as fine.
lc_hb_age() {
  local f="$1/heartbeat" v
  [ -f "$f" ] || return 0
  v="$(tr -dc '0-9' < "$f" 2>/dev/null)" || return 0
  [ -n "$v" ] || return 0
  printf '%s\n' "$(( $(date +%s) - v ))"
}

# lc_hb_value <O> — the raw heartbeat value as a bare integer (0 when unknown), for "did it ADVANCE".
lc_hb_value() {
  local v
  v="$(tr -dc '0-9' < "$1/heartbeat" 2>/dev/null)" || v=""
  printf '%s\n' "${v:-0}"
}

# lc_start <label> <plist> — enable, bootout, bootstrap; fall back to legacy `load`.
# Prints the path that actually loaded the job ("bootstrap" or "load"), or "none" on total failure.
# The fallback matters: on 2026-10-17 `bootstrap` failed with EIO and legacy `load` is what brought the
# controller back. WHICH path ran is printed because an operator debugging the next EIO needs to know
# the job is up on the legacy path — and `load` is used PLAIN, never `load -w`, which would write the
# disable straight back.
lc_start() {
  local label="$1" plist="$2" diag diag2
  lc_enable "$label"
  # A job that is still loaded cannot be bootstrapped again ("service already loaded"), so the bootout
  # belongs to the START, not to a separate restart step.
  lc_bootout "$label" "$plist"
  if diag="$(launchctl bootstrap "$(lc_domain)" "$plist" 2>&1)"; then
    printf 'bootstrap\n'
    return 0
  fi
  if diag2="$(launchctl load "$plist" 2>&1)"; then
    lc_err "  ⚠️  launchctl bootstrap failed (${diag:-no output}) — the job came up via the legacy 'load' path"
    printf 'load\n'
    return 0
  fi
  lc_err "❌ could not load $label — 'launchctl bootstrap' failed (${diag:-no output}) and the legacy fallback failed too (${diag2:-no output}). The job is left ENABLED and NOT running, so nothing here wrote a persistent disable. Next: launchctl print $(lc_domain)/$label | head -20; plutil -lint $plist"
  printf 'none\n'
  return 1
}

# lc_assert_running <label> <O> <heartbeat_baseline> [timeout] — POLL until the label has a pid AND
# $O/heartbeat advanced PAST <heartbeat_baseline>.
#
# ⛔ THE BASELINE IS A PARAMETER, AND THAT IS THE WHOLE POINT. Reading "the current heartbeat" inside
# this function reads the value the START IT JUST DID already wrote (orch-loop.sh's heartbeat() is the
# first thing in its cycle), so the wait would sit for a SECOND advance that is minutes away — the
# assertion would fail on a perfectly healthy start, and the temptation would be to widen the timeout
# until it stopped. The caller captures the value BEFORE it starts anything and passes it in.
# One actionable line on failure, non-zero return. The timeout covers both conditions, because a job
# that exits at once (a second instance losing the lock race) can be relaunched by launchd a second
# later — a single instantaneous read would call that a failure while it was still settling.
lc_assert_running() {
  local label="$1" O="$2" before="${3:-0}" timeout="${4:-30}" d cur pid i=0
  d="$(lc_domain)"
  while [ "$i" -lt "$timeout" ]; do
    pid="$(lc_pid "$label")"
    cur="$(lc_hb_value "$O")"
    if [ -n "$pid" ] && [ "$cur" -gt "$before" ]; then
      printf '  ✓ %s running (pid %s) and the heartbeat advanced\n' "$label" "$pid"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  pid="$(lc_pid "$label")"
  if [ -z "$pid" ]; then
    lc_err "❌ $label has NO pid ${timeout}s after the start — the label is not running. Next: launchctl print $d/$label | head -20; tail -40 $O/logs/launchd.err"
  else
    lc_err "❌ $label has pid $pid but $O/heartbeat did not advance within ${timeout}s — running but NOT cycling. Next: tail -40 $O/logs/orch-loop.log; cat $O/.orch.lock"
  fi
  return 1
}

# lc_foreign_controller <O> — the pid of a controller that is alive but was NOT started by launchd
# (this box's documented state: README §9 describes `nohup … orch-loop.sh` from a session). Prints the
# pid, or nothing. Exists so a start can REFUSE instead of manufacturing a restart storm: launchd's
# copy exits immediately on the lock, and `KeepAlive=true` then relaunches it for as long as the
# foreign controller lives. `kill -0` is the only liveness test used — the lock's mere presence proves
# nothing, because orch-loop.sh's EXIT trap is the only thing that removes it.
lc_foreign_controller() {
  local lock
  lock="$(tr -dc '0-9' < "$1/.orch.lock" 2>/dev/null)" || return 0
  [ -n "$lock" ] || return 0
  kill -0 "$lock" 2>/dev/null || return 0
  printf '%s\n' "$lock"
}

# lc_restart <label> <plist> <O> [timeout] — unconditional (re)start + assertion. This is `--restart`:
# an explicit operator act, so it does not consult the plist diff.
lc_restart() {
  local label="$1" plist="$2" O="$3" timeout="${4:-30}" via pid lock before
  pid="$(lc_pid "$label")"
  if [ -z "$pid" ]; then
    lock="$(lc_foreign_controller "$O")"
    if [ -n "$lock" ]; then
      lc_err "❌ refusing to start $label: a controller started OUTSIDE launchd already holds $O/.orch.lock (pid $lock), so launchd's copy would exit at once and KeepAlive would relaunch it forever. Next: stop it (pkill -f orch-loop.sh; rm -f $O/.orch.lock), then re-run"
      return 1
    fi
  fi
  before="$(lc_hb_value "$O")"
  printf '==> restarting %s (enable → bootout → bootstrap)\n' "$label"
  via="$(lc_start "$label" "$plist")" || return 1
  printf '  ✓ loaded via %s\n' "$via"
  lc_assert_running "$label" "$O" "$before" "$timeout"
}

# lc_ensure <label> <plist> <O> <plist_changed 0|1> [timeout]
# The SAFE-ON-A-LIVE-BOX entry point behind `install.sh --start`:
#   • plist unchanged AND the job is loaded with a fresh heartbeat  → LEFT COMPLETELY UNTOUCHED
#     (this is the validation run the brief protects: re-rendering the plist must never restart a
#     healthy production controller);
#   • plist unchanged, loaded, but the heartbeat is stale            → NON-ZERO, and it says so: a
#     loaded-but-not-cycling controller is wedged, and un-wedging it is `--restart`, not a silent
#     restart decided here;
#   • plist changed                                                  → reload (the running job is on
#     the old settings; applying them is the ONLY reason to touch a live job);
#   • not loaded                                                     → start.
lc_ensure() {
  local label="$1" plist="$2" O="$3" changed="${4:-1}" timeout="${5:-30}" pid age lock via before
  pid="$(lc_pid "$label")"
  if [ "$changed" = "0" ] && [ -n "$pid" ]; then
    age="$(lc_hb_age "$O")"
    if [ -n "$age" ] && [ "$age" -le "${LC_HB_STALE:-900}" ]; then
      printf '  ✓ %s already running (pid %s, heartbeat %ss old) and the plist is UNCHANGED — left untouched\n' "$label" "$pid" "$age"
      return 0
    fi
    lc_err "❌ $label is loaded (pid $pid) but $O/heartbeat is ${age:-unreadable}s old — running but not cycling. Next: install.sh --restart"
    return 1
  fi
  if [ -z "$pid" ]; then
    lock="$(lc_foreign_controller "$O")"
    if [ -n "$lock" ]; then
      lc_err "❌ refusing to start $label: a controller started OUTSIDE launchd already holds $O/.orch.lock (pid $lock), so launchd's copy would exit at once and KeepAlive would relaunch it forever. Next: stop it (pkill -f orch-loop.sh; rm -f $O/.orch.lock), then re-run"
      return 1
    fi
  fi
  # Captured BEFORE the start: `orch-loop.sh` writes the heartbeat as the FIRST act of its first
  # cycle, so a baseline read after the start would already contain the bump this assertion is
  # waiting for (see lc_assert_running).
  before="$(lc_hb_value "$O")"
  if [ -n "$pid" ]; then
    printf '==> reloading %s — the rendered plist DIFFERS from the loaded one (enable → bootout → bootstrap)\n' "$label"
  else
    printf '==> starting %s (enable → bootout → bootstrap)\n' "$label"
  fi
  via="$(lc_start "$label" "$plist")" || return 1
  printf '  ✓ loaded via %s\n' "$via"
  lc_assert_running "$label" "$O" "$before" "$timeout"
}
