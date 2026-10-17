#!/usr/bin/env bash
# launchd-cycle.sh — the ONE implementation of "stop / enable / (re)start / PROVE it started" for the
# ORCHESTRATOR job (label com.eldato.orchestrator-loop). Sourced by
# scripts/orchestrator-harness/install.sh; driven directly by
# scripts/orchestrator-harness/install-launchd-durability.test.sh with a stub `launchctl` first on PATH.
#
# ⛔ NOT the only launchd seam in this repo, deliberately: `scripts/install-launchd.sh` runs the SAME
# enable→bootout→bootstrap sequence for the template family under `templates/launchd/`. It is a separate
# implementation because the two have OPPOSITE bootstrap-failure policies — that one treats a failed
# bootstrap as terminal and removes the plist (`rm -f "$installed"  # nothing half-installed`), while
# this one falls back to the legacy `load` path, which is what actually recovered THIS controller on
# 2026-10-17. Neither seam serves the other's jobs; if you change one verb sequence, read the other.
#
# ⛔ THE RULE THIS FILE ENCODES: NEVER WRITE A PERSISTENT DISABLE, NEVER TOUCH A JOB THAT IS NOT OURS,
#    AND NEVER REPORT A START YOU DID NOT VERIFY.
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

# lc_real_home — the account's real home directory, or EMPTY when it cannot be determined (no `dscl`:
# a Linux CI runner, where there is also no gui domain to protect). Captured first and parsed in the
# shell, so no pipe is left to receive a SIGPIPE (#841) and a home path containing spaces survives.
lc_real_home() {
  local out
  out="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null)" || return 0
  case "$out" in
    "NFSHomeDirectory: "*) printf '%s\n' "${out#NFSHomeDirectory: }" ;;
  esac
}

# lc_canon <path> — canonical absolute path (symlinks resolved in the DIRECTORY), or empty when the
# directory does not exist. macOS reports `/private/tmp/...` for a plist bootstrapped as `/tmp/...`, so
# a byte comparison of the two spellings would call the same job "someone else's".
lc_canon() {
  local d b
  [ -n "${1:-}" ] || return 0
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 0
  b="$(basename "$1")"
  [ -n "$d" ] && printf '%s/%s\n' "${d%/}" "$b"
}

# lc_loaded_path <label> — the plist PATH launchd has the job loaded from, or empty when it is not
# loaded. This is the ONE datum that tells us whether a loaded job is OURS.
lc_loaded_path() {
  local out
  out="$(launchctl print "$(lc_domain)/$1" 2>/dev/null)" || return 0
  awk '/^[[:space:]]*path = /{ sub(/^[[:space:]]*path = /, ""); print; exit }' <<<"$out"
}

# lc_guard_mutate <label> <plist> — the two preconditions EVERY mutating verb must pass first.
#
# ⛔ (1) TEMP-HOME (#446). A run whose $HOME is not the real home registers (and removes) jobs in the
# REAL gui domain: the observed failure was com.eldato.provider-latency-tripwire registered against a
# deleted `pi-setup-test.*/home` path, runs=0, dead through the #413 window. This is the repo's recorded
# decision and it is implemented the same way in scripts/install-launchd.sh:380-403; tests opt in with
# ELDATO_ALLOW_TEST_HOME=1 plus a `launchctl` stub on PATH.
#
# ⛔ (2) IS THE LOADED JOB OURS? `launchctl bootout <domain> <path>` does NOT match on the path — the
# path only selects which plist to read the LABEL from, and launchd then removes the service BY LABEL
# (measured 2026-10-17 on this box: `bootout gui/501 /tmp/b/copy-with-same-label.plist` removed a job
# bootstrapped from /tmp/a/…, rc=0). Since the rendered plist always carries the production label, a
# sandboxed `--uninstall`/`--start` WOULD remove the live controller — the very failure this file
# exists to prevent, arriving through the door it thought it had shut. So the loaded job's own `path`
# must equal the plist we are about to act on, or we touch nothing. `enable` has no path form at all
# (`enable | disable service-target`), which is why that check has to come before it, not with it.
lc_guard_mutate() {
  local label="$1" plist="${2:-}" real loaded mine
  if [ "${ELDATO_ALLOW_TEST_HOME:-}" != "1" ]; then
    real="$(lc_real_home)"
    if [ -n "$real" ] && [ "$HOME" != "$real" ]; then
      lc_err "❌ refusing to change launchd state for $label: HOME=$HOME is not the real home ($real), so this run would act in the REAL user domain. Next: run it from your own account, or for a test set ELDATO_ALLOW_TEST_HOME=1 with a launchctl stub on PATH (#446)"
      return 1
    fi
  fi
  loaded="$(lc_loaded_path "$label")"
  if [ -n "$loaded" ] && [ -n "$plist" ]; then
    mine="$(lc_canon "$plist")"
    if [ "$(lc_canon "$loaded")" != "$mine" ]; then
      lc_err "❌ refusing to touch $label: a job with that label is loaded from $loaded, not $plist — launchd resolves a removal by LABEL, so acting here would remove that job. Next: launchctl print $(lc_domain)/$label | head -20, and remove the foreign job by hand if it really is yours"
      return 1
    fi
  fi
  return 0
}

# lc_bootout <label> <plist>
# Remove the job definition. NO `-w` and no `unload`, so launchd's persistent Disabled override is
# never touched — this is the difference between "not loaded" (recoverable) and "disabled" (silent and
# sticky).
#
# ⛔ GUARDED, AND ITS STATUS MEANS SOMETHING. `lc_guard_mutate` runs first (a temp-HOME run and a
# label owned by another path both refuse), and a removal that actually FAILS returns non-zero with
# launchd's own diagnostic instead of being swallowed — the old `… 2>/dev/null && return 0` plus an
# unconditional `return 0` let `--uninstall` print "✅ Removed" over a job that was still loaded.
# "Not loaded" stays a success: it is the common case on a fresh box and on a second `--uninstall`.
lc_bootout() {
  local label="$1" plist="${2:-}" d diag
  d="$(lc_domain)"
  lc_guard_mutate "$label" "$plist" || return 1
  [ -n "$plist" ] && [ -e "$plist" ] || return 0
  # NOT LOADED = nothing to remove, and that is a SUCCESS (a first install, a second `--uninstall`, a
  # plist rendered but never bootstrapped). Checked by READING the domain rather than by interpreting
  # launchctl's error text: `bootout` on an unknown service exits non-zero with no output at all.
  [ -n "$(lc_loaded_path "$label")" ] || [ -n "$(lc_pid "$label")" ] || return 0
  if diag="$(launchctl bootout "$d" "$plist" 2>&1)"; then return 0; fi
  case "$diag" in
    *"Could not find"*|*"No such process"*|*"not find service"*|*"Bad request"*) return 0 ;;
  esac
  lc_err "❌ launchctl bootout failed for $label (${diag:-no output}). Next: launchctl print $d/$label | head -20"
  return 1
}

# lc_enable <label>
# CLEAR a persistent disable before loading. This is why a box that a previous `-w` disabled can be
# recovered by an ordinary start, and it is the one verb here that removes a disable. Tolerated on
# failure: a job with no override at all is the healthy state, and `enable` is allowed to report
# nonzero for a service the domain does not know yet.
# ⛔ `enable` HAS no path form (`man launchctl`: `enable | disable service-target`), so it always acts on
# the label in the REAL domain. That is why this function must never be called before
# `lc_guard_mutate` — the guard is what keeps a sandboxed run from clearing a deliberate operator
# disable on the production job, and lc_start is the only caller that keeps that order.
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
  lc_guard_mutate "$label" "$plist" || return 1
  lc_enable "$label"
  # A job that is still loaded cannot be bootstrapped again ("service already loaded"), so the bootout
  # belongs to the START, not to a separate restart step — and a removal that FAILS is fatal here:
  # carrying on would bootstrap over a job we could not clear, then fall through to `load`, and the
  # restart would report a success that never happened (the stale-limits trap README §9 exists to close).
  lc_bootout "$label" "$plist" || return 1
  if diag="$(launchctl bootstrap "$(lc_domain)" "$plist" 2>&1)"; then
    printf 'bootstrap\n'
    return 0
  fi
  if diag2="$(launchctl load "$plist" 2>&1)"; then
    lc_err "  ⚠️  launchctl bootstrap failed (${diag:-no output}) — the job came up via the legacy 'load' path"
    printf 'load\n'
    return 0
  fi
  lc_err "❌ could not load $label — 'launchctl bootstrap' failed (${diag:-no output}) and the legacy fallback failed too (${diag2:-no output}). The job is left ENABLED and NOT running, so nothing here wrote a persistent disable. Next: launchctl print $(lc_domain)/$label | head -20; plutil -lint '$plist'"
  printf 'none\n'
  return 1
}

# lc_assert_running <label> <O> <heartbeat_baseline> [timeout] [replaced_pid] — POLL until the label
# has a pid AND $O/heartbeat advanced PAST <heartbeat_baseline>, then prove the pid is STABLE.
# replaced_pid (when a job was already loaded) is the pid the caller saw BEFORE the start: it must be
# GONE, because a start whose old process survives did not take effect — the old controller keeps the
# old plist limits while the same pid and a fresh heartbeat make it look successful. (Checked inside the
# poll window, not before it: a booted-out process takes a moment to die and its last heartbeat is
# already on disk.)
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
  local label="$1" O="$2" before="${3:-0}" timeout="${4:-30}" replaced="${5:-}" d cur pid i=0
  d="$(lc_domain)"
  while [ "$i" -lt "$timeout" ]; do
    pid="$(lc_pid "$label")"
    cur="$(lc_hb_value "$O")"
    if [ -n "$pid" ] && [ "$cur" -gt "$before" ] && { [ -z "$replaced" ] || [ "$pid" != "$replaced" ]; }; then
      # …and it must STAY up: a KeepAlive job that dies seconds after a start relaunches with a new pid
      # and a fresh heartbeat, and every relaunch writes one (heartbeat is the first act of a cycle).
      lc_assert_stable "$label" "${LC_SETTLE:-5}" || return 1
      printf '  ✓ %s running (pid %s) and the heartbeat advanced\n' "$label" "$pid"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  pid="$(lc_pid "$label")"
  if [ -z "$pid" ]; then
    lc_err "❌ $label has NO pid ${timeout}s after the start — the label is not running. Next: launchctl print $d/$label | head -20; tail -40 $O/logs/launchd.err"
  elif [ -n "$replaced" ] && [ "$pid" = "$replaced" ]; then
    lc_err "❌ $label still has pid $pid ${timeout}s after the start — the job was NOT replaced, so the loaded plist may still be the OLD one. Next: launchctl print $d/$label | head -20, then boot it out by plist path and start again"
  else
    lc_err "❌ $label has pid $pid but $O/heartbeat did not advance within ${timeout}s — running but NOT cycling. Next: tail -40 $O/logs/orch-loop.log; cat $O/.orch.lock"
  fi
  return 1
}

# lc_runs <label> — the job's cumulative RELAUNCH counter from `launchctl print`, or empty when the job
# is not loaded. This is the one signal that separates "cycling" from "crash-looping": `orch-loop.sh`
# writes the heartbeat as the FIRST act of a cycle and the plist is KeepAlive, so a controller that dies
# seconds after every start looks identical to a healthy one on pid+heartbeat alone — but every relaunch
# bumps `runs`, and a healthy job's counter only moves when launchd restarts it.
lc_runs() {
  local out
  out="$(launchctl print "$(lc_domain)/$1" 2>/dev/null)" || return 0
  awk '/^[[:space:]]*runs = /{ sub(/^[[:space:]]*runs = /, ""); print; exit }' <<<"$out"
}

# lc_assert_stable <label> [settle] — the job must not be RELAUNCHED during a quiet window.
# Cheap (one sleep) and read-only, so it is safe on a live box: a healthy controller's `runs` does not
# move while it works; a crash loop moves it every few seconds.
lc_assert_stable() {
  local label="$1" settle="${2:-5}" r0 r1
  r0="$(lc_runs "$label")"
  if [ -z "$r0" ]; then
    lc_err "❌ $label has no 'runs' counter — not loaded, so it cannot be cycling. Next: launchctl print $(lc_domain)/$label | head -20"
    return 1
  fi
  sleep "$settle"
  r1="$(lc_runs "$label")"
  if [ -n "$r1" ] && [ "$r0" != "$r1" ]; then
    lc_err "❌ $label is being RELAUNCHED (launchd runs $r0 → $r1 in ${settle}s) — it starts and dies, so a live pid and a fresh heartbeat prove nothing. Next: tail -40 $O/logs/launchd.err 2>/dev/null; tail -40 $O/logs/orch-loop.log"
    return 1
  fi
  return 0
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
  lc_assert_running "$label" "$O" "$before" "$timeout" "$pid"
}

# lc_ensure <label> <plist> <O> <plist_changed 0|1> [timeout] [hb_stale]
# The SAFE-ON-A-LIVE-BOX entry point behind `install.sh --start`:
#   • the job is loaded from ANOTHER path                         → refuse before deciding anything (the
#     "left untouched" branch below would otherwise report OUR controller healthy from a foreign job);
#   • plist unchanged AND the job is loaded with a fresh heartbeat  → LEFT COMPLETELY UNTOUCHED
#     (this is the validation run the brief protects: re-rendering the plist must never restart a
#     healthy production controller);
#   • plist unchanged, loaded, but the heartbeat is stale            → NON-ZERO, and it says so: a
#     loaded-but-not-cycling controller is wedged, and un-wedging it is `--restart`, not a silent
#     restart decided here;
#   • plist changed                                                  → reload (the running job is on
#     the old settings; applying them is the ONLY reason to touch a live job);
#   • not loaded                                                     → start.
# hb_stale is the "loaded but wedged" bound, passed in by the caller so it can track that cell's CYC
# (a fixed 900s fails a healthy CYC=900 cell and points the operator at a needless restart).
lc_ensure() {
  local label="$1" plist="$2" O="$3" changed="${4:-1}" timeout="${5:-30}" stale="${6:-780}"
  local pid age lock via before
  lc_guard_mutate "$label" "$plist" || return 1
  pid="$(lc_pid "$label")"
  if [ "$changed" = "0" ] && [ -n "$pid" ]; then
    age="$(lc_hb_age "$O")"
    if [ -n "$age" ] && [ "$age" -le "$stale" ]; then
      # ⛔ A FRESH HEARTBEAT IS NOT PROOF OF HEALTH. `orch-loop.sh` writes it as the first act of a
      # cycle and the plist is KeepAlive, so a controller that dies seconds after every start keeps the
      # age fresh forever and this branch would bless it as "already running". The relaunch counter is
      # what separates them, and it is a read-only check — the live box is still left untouched.
      lc_assert_stable "$label" "${LC_SETTLE:-5}" || return 1
      printf '  ✓ %s already running (pid %s, heartbeat %ss old, not relaunching) and the plist is UNCHANGED — left untouched\n' "$label" "$pid" "$age"
      return 0
    fi
    lc_err "❌ $label is loaded (pid $pid) but $O/heartbeat is ${age:-unreadable}s old (limit ${stale}s) — running but not cycling. Next: install.sh --restart"
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
  lc_assert_running "$label" "$O" "$before" "$timeout" "$pid"
}
