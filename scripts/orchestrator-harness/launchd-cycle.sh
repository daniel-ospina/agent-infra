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
#   • The only launchctl verbs INVOKED are `bootout`, `enable`, `bootstrap`, `load` (legacy fallback),
#     `print` and `print-disabled` (both read-only). No `unload`, no `disable`, and no `-w` flag is ever
#     INVOKED — the test suite asserts that about the CODE (it strips full-line comments, because the
#     comments above name the trap on purpose; a grep over the whole file would find those words and
#     prove nothing about behaviour).

# lc_domain — the launchd domain this user's agents live in. `gui/<uid>` is what `launchctl list` and
# the rendered plist's LaunchAgents location both mean; a session started from an SSH shell still owns
# the same job, which is why the domain is derived and never hardcoded.
lc_domain() { printf 'gui/%s\n' "$(id -u)"; }

lc_err() { printf '%s\n' "$*" >&2; }

# lc_real_home — the account's real home directory. TRI-STATE, and the distinction is load-bearing:
#   0 + the path      the real home, read successfully
#   1                 `dscl` EXISTS but the read failed / did not parse — the #446 check cannot run
#   2                 no `dscl` on this box (a Linux CI runner, where there is also no gui domain)
# ⛔ 1 must never be read as "no check needed": collapsing the two turned a failing DirectoryService
# read into a silently disabled temp-HOME guard (found in review), which is the measured #446 shape —
# a job registered against a throwaway `pi-setup-test.*/home` path in the REAL domain.
# Captured first and parsed in the shell, so no pipe is left to receive a SIGPIPE (#841) and a home
# path containing spaces survives.
lc_real_home() {
  local out
  command -v dscl >/dev/null 2>&1 || return 2
  out="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null)" || return 1
  # ⛔ THE VALUE MUST BE NON-EMPTY (review finding): `"NFSHomeDirectory: "` with nothing after it
  # matched the prefix and returned 0 with an EMPTY home, and `cd ""` then makes the caller's "real
  # home" the CURRENT DIRECTORY — the same trap as an empty $HOME, one layer down. A record without a
  # home is a failed read, not a home of "".
  case "$out" in
    "NFSHomeDirectory: "?*) printf '%s\n' "${out#NFSHomeDirectory: }"; return 0 ;;
  esac
  return 1
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

# lc_probe <label> — `launchctl print` for this job, with its OUTCOME CLASSIFIED rather than flattened.
# Prints the block and returns:
#   0  the job is LOADED (the block is on stdout)
#   1  launchd DEFINITIVELY says there is no such service (its own not-found text)
#   2  the read FAILED in a way that says nothing about whether the job exists — EIO, a timeout, a
#      broken domain, or a diagnostic we do not recognise (the block/diagnostic is on stdout)
# ⛔ 2 IS NOT 1, AND CONFLATING THEM IS THE DEFECT THIS FUNCTION REMOVES. `launchctl print` failing is
# not evidence the job is gone: `--uninstall` then issued NO bootout, the read-back saw an empty read,
# and the installer printed ✅ and deleted the plist over a live controller — while the ownership guard
# was skipped for the same reason, so even `enable` no longer required proof that the job was ours.
lc_probe() {
  local d out rc
  d="$(lc_domain)"
  out="$(launchctl print "$d/$1" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then printf '%s\n' "$out"; return 0; fi
  case "$out" in
    # ⛔ ONLY launchd's own SERVICE-level "no such service" answer counts as ABSENT — and the word
    # SERVICE is load-bearing (review finding). launchd prints the SAME PREFIX for a DOMAIN-level
    # rejection: `launchctl print gui/999/x` → `Bad request.` + `Could not find domain for user gui:
    # 999`, measured on this box. That message says NOTHING about the service, so matching the bare
    # `Could not find` read a broken domain as "definitively absent", `lc_bootout` then issued NO
    # removal, the read-back saw an empty read, and `--uninstall` printed ✅ and deleted the plist over
    # a job launchd still held — reachable as `sudo bash install.sh --uninstall` (id -u 0 → gui/0).
    # `Bad request` alone and `No such process` belong to `bootout`'s race tolerance, not here.
    *"Could not find service"*|*"not find service"*|*"service not found"*)
      return 1 ;;
  esac
  printf '%s\n' "$out"
  return 2
}

# lc_loaded_path <label> — the plist PATH launchd has the job loaded from, or empty when it is not
# loaded (or when the read failed — callers that must tell those apart use `lc_probe`). This is the ONE
# datum that tells us whether a loaded job is OURS.
lc_loaded_path() {
  local out
  out="$(lc_probe "$1")" || return 0
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
  local label="$1" plist="${2:-}" real rc=0 home_real loaded mine theirs block prc=0
  if [ "${ELDATO_ALLOW_TEST_HOME:-}" != "1" ]; then
    # ⛔ AN EMPTY `HOME` IS NOT THE REAL HOME, AND `cd ""` SUCCEEDS (review finding): bash's `cd ""`
    # leaves $PWD unchanged and returns 0, so `home_real` became the CURRENT DIRECTORY — an operator
    # standing in their own home PASSED the "this is the real home" comparison while $HOME was empty,
    # and the run then acted in the real user domain (the plist resolves outside the account and the
    # removal falls back to the label-keyed service-target form). Tested FIRST, before the account is
    # even consulted: an empty HOME cannot be a real home on any platform, and on a box with no `dscl`
    # the account read is skipped entirely — which is how this value slipped past the guard.
    if [ -z "${HOME:-}" ]; then
      lc_err "❌ refusing to change launchd state for $label: HOME is empty, so this run cannot be shown to be the real account. Next: run it from your own account, or for a test set ELDATO_ALLOW_TEST_HOME=1 with a launchctl stub on PATH (#446)"
      return 1
    fi
    real="$(lc_real_home)" || rc=$?
    if [ "$rc" -eq 1 ]; then
      # NOT the same as "no dscl on this box": the check exists to stop a sandboxed run from acting in
      # the REAL domain, and an unreadable account record means we cannot show that this is the real
      # account. Fail closed, and name the failed read so the operator can tell it from a HOME mismatch.
      lc_err "❌ refusing to change launchd state for $label: this account's real home could not be read ('dscl . -read /Users/$(id -un) NFSHomeDirectory' failed), so the temp-HOME guard (#446) cannot decide whether this run would act in the REAL user domain. Next: check `dscl . -read ~ NFSHomeDirectory`, or for a test set ELDATO_ALLOW_TEST_HOME=1 with a launchctl stub on PATH"
      return 1
    fi
    if [ "$rc" -eq 0 ]; then
      # ⛔ AN EMPTY ACCOUNT HOME IS NOT A HOME, and `cd ""` SUCCEEDS (review finding): it leaves $PWD
      # unchanged, so `real` became the current directory and `home_real` matched it — a sandboxed run
      # from `cd "$SANDBOX"` PASSED the guard. `lc_real_home` now refuses a blank value; this is the
      # belt for the same brace, so neither layer alone can turn "no datum" into "same path".
      if [ -z "$real" ]; then
        lc_err "❌ refusing to change launchd state for $label: this account's real home read back EMPTY, so the temp-HOME guard (#446) cannot decide whether this run would act in the REAL user domain. Next: dscl . -read ~ NFSHomeDirectory, or for a test set ELDATO_ALLOW_TEST_HOME=1 with a launchctl stub on PATH"
        return 1
      fi
      # Canonicalise the SPELLING before comparing: `HOME=/Users/me/` and a symlink to the real home are
      # the real account, and refusing them told the operator to "run it from your own account" while
      # they already were (a false block with a false reason — found in review).
      # ⛔ `|| …=""` on each: this file is SOURCED into install.sh's `set -euo pipefail`, so an
      # unguarded failing substitution aborts the CALLER mid-function — the refusal line below is then
      # never printed and the operator sees an exit code with no output at all.
      home_real="$(cd "${HOME:-}" 2>/dev/null && pwd -P)" || home_real=""
      real="$(cd "$real" 2>/dev/null && pwd -P)" || real=""
      if [ -z "$home_real" ] || [ "$home_real" != "$real" ]; then
        lc_err "❌ refusing to change launchd state for $label: HOME=$HOME is not the real home ($real), so this run would act in the REAL user domain. Next: run it from your own account, or for a test set ELDATO_ALLOW_TEST_HOME=1 with a launchctl stub on PATH (#446)"
        return 1
      fi
    fi
  fi
  block="$(lc_probe "$label")" || prc=$?
  if [ "$prc" -eq 2 ]; then
    lc_err "❌ refusing to touch $label: launchd's state for that label could not be read (${block:-no output}), and 'not loaded' is not the same as 'unreadable' — acting on the guess would remove a job we cannot show is ours. Next: launchctl print $(lc_domain)/$label | head -20"
    return 1
  fi
  loaded=""
  [ "$prc" -eq 0 ] && loaded="$(awk '/^[[:space:]]*path = /{ sub(/^[[:space:]]*path = /, ""); print; exit }' <<<"$block")"
  # ⛔ LOADED BUT UNPARSABLE IS NOT "NO CLAIM TO CHECK" (review finding): a job registered by
  # `launchctl submit`, or any print whose `path` line is absent, left `loaded` empty, so this guard was
  # SKIPPED and the caller issued a LABEL-keyed bootout — the exact failure the guard exists to close.
  if [ "$prc" -eq 0 ] && [ -n "$plist" ] && [ -z "$loaded" ]; then
    lc_err "❌ refusing to touch $label: the job is LOADED but launchd reported no plist path for it, so it cannot be shown to be ours. Next: launchctl print $(lc_domain)/$label | head -20, and remove the foreign job by hand if it really is yours"
    return 1
  fi
  if [ -n "$loaded" ] && [ -n "$plist" ]; then
    # ⛔ IDENTITY BEFORE SPELLING (review finding): a stow/chezmoi-style `~/Library/LaunchAgents/….plist`
    # that is a SYMLINK to the dotfiles copy is the same file, and `lc_canon` resolves only the DIRECTORY,
    # so the guard refused a perfectly ordinary layout with "loaded from …, not …". `-ef` compares the
    # file itself; the canonical comparison stays as the fallback (it also handles a plist that is gone).
    if [ -e "$plist" ] && [ "$loaded" -ef "$plist" ]; then
      return 0
    fi
    mine="$(lc_canon "$plist")"
    theirs="$(lc_canon "$loaded")"
    # ⛔ An EMPTY canonicalisation means "cannot resolve this path" (its directory is gone, or it is
    # spelled in a way `cd` cannot follow), NOT "the same place". Two unresolvable paths are only the
    # same path when they are the same STRING — otherwise refuse: an unprovable ownership claim is not
    # ownership, and the message names the path launchd actually reported either way.
    if [ -z "$theirs" ] || [ -z "$mine" ] || [ "$theirs" != "$mine" ]; then
      [ "$loaded" = "$plist" ] && return 0
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
  local label="$1" plist="${2:-}" d diag block rc=0
  d="$(lc_domain)"
  lc_guard_mutate "$label" "$plist" || return 1
  # NOT LOADED = nothing to remove, and that is a SUCCESS (a first install, a second `--uninstall`, a
  # plist rendered but never bootstrapped). `lc_probe` distinguishes that from an UNREADABLE domain,
  # which is NOT a success: treating a failed read as "nothing to remove" returned 0 here, so the
  # caller's read-back also saw nothing and `--uninstall` deleted the plist and printed ✅ over a job
  # launchd still held (found in review).
  block="$(lc_probe "$label")" || rc=$?
  if [ "$rc" -eq 2 ]; then
    lc_err "❌ refusing to treat $label as 'not loaded': launchd's state for that label could not be read (${block:-no output}). Next: launchctl print $d/$label | head -20"
    return 1
  fi
  [ "$rc" -eq 0 ] || return 0
  # ⛔ THE PLIST MAY BE GONE WHILE THE JOB IS STILL LOADED (a hand-deleted file, or an `--uninstall` that
  # removed it before a later one retries). The guard above has just PROVED the loaded job came from this
  # plist, so the service-target form is safe HERE and is the only handle left — without it this branch
  # returned success over a job launchd still holds.
  if [ -n "$plist" ] && [ -e "$plist" ]; then
    if diag="$(launchctl bootout "$d" "$plist" 2>&1)"; then return 0; fi
  else
    if diag="$(launchctl bootout "$d/$label" 2>&1)"; then return 0; fi
  fi
  case "$diag" in
    # ⛔ NARROW, FOR THE SAME REASON AS `lc_probe` (review finding): the bare `Could not find` prefix also
    # appears in the DOMAIN-level `Could not find domain for user gui: N`, so it converted a removal that
    # never happened into a success. `No such process` is the one genuine already-gone race.
    *"Could not find service"*|*"No such process"*|*"not find service"*) return 0 ;;
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
  out="$(lc_probe "$1")" || return 0
  # ⛔ HERE-STRING, NO PIPE (#841): a `… | head -n 1` here would let head exit early and the writer
  # take SIGPIPE, and under the caller's `pipefail` the pipeline's status — and therefore lc_pid's —
  # becomes 141 on a perfectly good read. awk exits on its own after the first match; nothing is left
  # to signal.
  awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }' <<<"$out"
}

# lc_hb_age <O> — seconds since the controller last wrote $O/heartbeat, or EMPTY when there is no
# readable heartbeat. Empty is "unknown", never "fresh": a reader that treats a missing heartbeat as
# healthy would report a dead controller as fine. A heartbeat in the FUTURE is the same class — a clock
# correction, a file written under another clock, a corrupt value — and `[ -N -le M ]` is true for every
# negative N, so it would otherwise bless a dead controller forever. Skew up to 60s is tolerated.
lc_hb_age() {
  local f="$1/heartbeat" v now
  [ -f "$f" ] || return 0
  v="$(tr -dc '0-9' < "$f" 2>/dev/null)" || return 0
  [ -n "$v" ] || return 0
  now="$(date +%s)"
  [ "$v" -le "$(( now + 60 ))" ] || return 0
  printf '%s\n' "$(( now - v ))"
}

# lc_hb_value <O> — the raw heartbeat value as a bare integer (0 when unknown), for "did it ADVANCE".
# ⛔ A VALUE FROM THE FUTURE IS "UNKNOWN", NOT "A BIG NUMBER". This value is the START-PROOF BASELINE,
# and the proof is `cur > before`: a future-dated file (clock correction, foreign clock, corruption)
# makes that target unreachable, so a healthy start is reported as "running but NOT cycling" — with the
# wrong remedy, and once per `--restart` retry, because each retry re-boots the controller out first
# (found in review). Same 60s skew tolerance as lc_hb_age, and the same reasoning: an untrustworthy
# reading must degrade to "unknown", never to a target nothing can exceed.
lc_hb_value() {
  local v now
  # ⛔ THE SAME `-f` GUARD `lc_hb_age` HAS, AND FOR A HARDER REASON (review finding): without it a
  # NON-REGULAR `$O/heartbeat` BLOCKS ON OPEN, and this read happens BEFORE the start — so
  # `install.sh --start`, the documented remedy while the controller is down, hung until it was killed:
  # the operator's last lever, with no output at all. Measured with a FIFO at that path.
  [ -f "$1/heartbeat" ] || { printf '0\n'; return 0; }
  v="$(tr -dc '0-9' < "$1/heartbeat" 2>/dev/null)" || v=""
  [ -n "$v" ] || { printf '0\n'; return 0; }
  now="$(date +%s)"
  [ "$v" -le "$(( now + 60 ))" ] || v=0
  printf '%s\n' "$v"
}

# lc_min_runtime <label> — launchd's respawn throttle for this job, in seconds (`man launchd.plist`,
# ThrottleInterval: "by default, jobs will not be spawned more than once every 10 seconds"; `launchctl
# print` reports it as `minimum runtime = N`). Printed value defaults to 10 when unreadable.
# ⛔ This matters for the crash-loop check: an observation window SHORTER than the throttle cannot see a
# relaunch at all, so a 5s window declared a crash loop healthy (found in review, with the throttle
# measured at 10 on this box).
lc_min_runtime() {
  local out n
  out="$(launchctl print "$(lc_domain)/$1" 2>/dev/null)" || { printf '10\n'; return 0; }
  n="$(awk '/^[[:space:]]*minimum runtime = [0-9]+$/ { print $4; exit }' <<<"$out")"
  case "$n" in ''|*[!0-9]*) n=10 ;; esac
  printf '%s\n' "$n"
}

# lc_disable_state <label> — the persistent Disabled override ACTUALLY in effect, from `launchctl
# print-disabled <domain>` (`man launchctl`): "enabled", "disabled", or "unknown" when it cannot be
# read. Used instead of asserting the state we hoped for: `enable` is allowed to fail, and the one
# message an operator reads during an outage must be a measurement.
lc_disable_state() {
  local out entry
  out="$(launchctl print-disabled "$(lc_domain)" 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  # ⛔ "THE VERB FAILED", "NO OVERRIDE IS RECORDED" AND "AN ENTRY WE CANNOT CLASSIFY" ARE THREE
  # DIFFERENT STATES (review finding): folding them into one `unknown` made the HEALTHY box — a
  # `print-disabled` that answers and simply has no line for this label — report itself as an
  # unreadable answer, at the moment an operator is already diagnosing launchd.
  entry="$(grep -F "\"$1\"" <<<"$out" 2>/dev/null || true)"
  case "$entry" in
    *'=> disabled'*) printf 'disabled\n' ;;
    *'=> enabled'*)  printf 'enabled\n' ;;
    '')              printf 'unset\n' ;;     # the read ANSWERED: no override for this label (healthy)
    *)               printf 'unknown\n' ;;   # an entry we cannot classify
  esac
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

  # ⛔ THE ENABLE IS VERIFIED, NOT ASSUMED (review finding: the README claimed this read-back and the code
  # only used it in a failure diagnostic). A DEFINITE `disabled` here means the override did not clear, so
  # the load would either fail or — worse — succeed into a state the next boot loses. Anything we cannot
  # read is a WARNING and the bootstrap decides: an unknown must not become a false block either.
  case "$(lc_disable_state "$label")" in
    disabled) lc_err "❌ refusing to load $label: the persistent Disabled override still reads 'disabled' after 'launchctl enable', so loading it would not survive a reboot. Next: launchctl enable $(lc_domain)/$label; launchctl print-disabled $(lc_domain) | grep $label"; return 1 ;;
    unknown)  printf '%s\n' "⚠️  could not read whether $label is disabled (launchctl print-disabled gave no usable answer) — continuing; the bootstrap below is the proof" >&2 ;;
  esac   # `enabled` and `unset` (no override recorded — the healthy state) both proceed silently
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
  lc_err "❌ could not load $label — 'launchctl bootstrap' failed (${diag:-no output}) and the legacy fallback failed too (${diag2:-no output}). This run wrote no persistent disable (it only called 'enable'; Disabled override now reads: $(lc_disable_state "$label")). Next: launchctl print $(lc_domain)/$label | head -20; plutil -lint '$plist'"
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
  local label="$1" O="$2" before="${3:-0}" timeout="${4:-30}" replaced="${5:-}" d cur pid i=0 prc blk
  d="$(lc_domain)"
  # ⛔ A NON-NUMERIC TIMEOUT IS NOT A SHORT TIMEOUT. `[ "$i" -lt "abc" ]` ERRORS, the loop body never
  # runs, and every start fails after ZERO observations ("has NO pid abcs after the start") — the same
  # defect lc_assert_stable had with `sleep abc`, in the parameter that gates an operator's recovery
  # command (found in review). Normalised here so all three callers inherit it.
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  [ "$timeout" -ge 1 ] || timeout=30
  while [ "$i" -lt "$timeout" ]; do
    pid="$(lc_pid "$label")"
    cur="$(lc_hb_value "$O")"
    if [ -n "$pid" ] && [ "$cur" -gt "$before" ] && { [ -z "$replaced" ] || [ "$pid" != "$replaced" ]; }; then
      # …and it must STAY up: a KeepAlive job that dies seconds after a start relaunches with a new pid
      # and a fresh heartbeat, and every relaunch writes one (heartbeat is the first act of a cycle).
      lc_assert_stable "$label" "${LC_SETTLE:-}" || return 1
      printf '  ✓ %s running (pid %s) and the heartbeat advanced\n' "$label" "$pid"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  pid="$(lc_pid "$label")"
  if [ -z "$pid" ]; then
    # ⛔ A READ THAT FAILED IS NOT "NO pid" (review finding): `lc_pid` folds UNKNOWN into empty, so an
    # unreadable domain was reported as "the label is not running" — a measurement about a domain that
    # was never read. The exit is non-zero either way; the DIAGNOSIS is what changes.
    prc=0; blk=""; blk="$(lc_probe "$label")" || prc=$?
    if [ "$prc" -eq 2 ]; then
      lc_err "❌ refusing to decide on $label: launchd's state could not be read after the start (${blk:-no output}), so 'not running' is unproven. Next: launchctl print $d/$label | head -20; tail -40 $O/logs/launchd.err"
    elif [ "$prc" -eq 0 ]; then
      lc_err "❌ $label is LOADED but launchd reports NO pid ${timeout}s after the start — it is not running. Next: launchctl print $d/$label | head -20; tail -40 $O/logs/launchd.err"
    else
      lc_err "❌ $label is NOT loaded ${timeout}s after the start — the label is not running. Next: launchctl print $d/$label | head -20; tail -40 $O/logs/launchd.err"
    fi
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
  out="$(lc_probe "$1")" || return 0
  awk '/^[[:space:]]*runs = /{ sub(/^[[:space:]]*runs = /, ""); print; exit }' <<<"$out"
}

# lc_assert_stable <label> [settle] — the job must not be RELAUNCHED during a quiet window.
# Read-only (two `runs` reads plus one sleep), so it is safe on a live box: a healthy controller's `runs`
# does not move while it works; a crash loop moves it on every respawn.
#
# ⛔ THE WINDOW MUST EXCEED launchd's RESPAWN THROTTLE or the check cannot observe a relaunch at all:
# `man launchd.plist` ThrottleInterval — "by default, jobs will not be spawned more than once every 10
# seconds" — and `launchctl print` reports it as `minimum runtime = N`. The default is therefore
# `minimum runtime + 3`; a 5s window was reviewed as systematically blind on the start path. LC_SETTLE
# may LOWER it for a test, but only with a numeric value that is at least 1s — anything else falls back
# to the safe default (`sleep abc` would otherwise be a zero-width window that always passes).
lc_assert_stable() {
  local label="$1" settle="${2:-}" floor r0 r1 prc _b
  floor=$(( $(lc_min_runtime "$label") + 3 ))
  case "$settle" in ''|*[!0-9]*) settle="$floor" ;; esac
  [ "$settle" -ge 1 ] || settle="$floor"
  r0="$(lc_runs "$label")"
  if [ -z "$r0" ]; then
    # ⛔ AN ABSENT COUNTER IS NOT "NOT LOADED" (review finding): a LOADED block with no `runs` line was
    # reported as not loaded — a measurement about a line that was never read.
    prc=0; _b=""; _b="$(lc_probe "$label")" || prc=$?
    if [ "$prc" -eq 0 ]; then
      lc_err "❌ refusing to certify $label: the job is LOADED but launchd reported no 'runs' counter (${_b:-no output}), so a relaunch cannot be observed. Next: launchctl print $(lc_domain)/$label | head -20"
    elif [ "$prc" -eq 1 ]; then
      lc_err "❌ $label is NOT loaded, so it cannot be cycling. Next: launchctl print $(lc_domain)/$label | head -20"
    else
      lc_err "❌ refusing to certify $label: launchd's state for that label could not be read (${_b:-no output}), so 'not cycling' is unproven. Next: launchctl print $(lc_domain)/$label | head -20"
    fi
    return 1
  fi
  sleep "$settle"
  r1="$(lc_runs "$label")"
  # ⛔ THE SECOND READ IS THE MEASUREMENT, SO AN EMPTY ONE IS UNKNOWN — NOT "STABLE" (review finding).
  # `lc_runs` returns empty both when the job is gone and when `launchctl print` failed (EIO, exactly
  # what this box does), so `[ -n "$r1" ] && …` fell through to `return 0` and CERTIFIED a crash loop
  # whenever launchd was flaky — the one signal that separates cycling from crash-looping, failing open
  # precisely when a relaunch is most likely. Classify it instead of folding it into "no pid".
  if [ -z "$r1" ]; then
    prc=0; _b=""; _b="$(lc_probe "$label")" || prc=$?
    if [ "$prc" -eq 1 ]; then
      lc_err "❌ refusing to certify $label: the job left the domain during the ${settle}s window (its 'runs' counter vanished), so this start is NOT proven. Next: launchctl print $(lc_domain)/$label | head -20; tail -40 ${O:-~/orchestrator}/logs/launchd.err 2>/dev/null"
    else
      lc_err "❌ refusing to certify $label: launchd's 'runs' counter could not be read a second time (${_b:-no output}), so 'not relaunching' is UNPROVEN. Next: launchctl print $(lc_domain)/$label | head -20"
    fi
    return 1
  fi
  if [ "$r0" != "$r1" ]; then
    lc_err "❌ $label is being RELAUNCHED (launchd runs $r0 → $r1 in ${settle}s) — it starts and dies, so a live pid and a fresh heartbeat prove nothing. Next: tail -40 ${O:-~/orchestrator}/logs/launchd.err 2>/dev/null; tail -40 ${O:-~/orchestrator}/logs/orch-loop.log"
    return 1
  fi
  return 0
}

# lc_foreign_controller <O> — the pid of a controller that is alive but was NOT started by launchd
# (one state README §9 names and explicitly warns NOT to record as a fact — read `launchctl print` and
# `$O/.orch.lock` at the moment you care, because the box moves between launchd-owned and
# session-owned during a single day). Prints the pid, or nothing. Exists so a start can REFUSE instead
# of manufacturing a restart storm: launchd's copy exits immediately on the lock, and `KeepAlive=true`
# then relaunches it for as long as the
# foreign controller lives. `kill -0` is the only liveness test used — the lock's mere presence proves
# nothing, because orch-loop.sh's EXIT trap is the only thing that removes it.
lc_foreign_controller() {
  local lock
  # ⛔ THE SAME `-f` GUARD `lc_hb_value` NEEDS, ON THE SIBLING READ, ON THE BRANCH THAT RUNS WHEN THE JOB
  # IS ABSENT (review finding): with a non-regular `$O/.orch.lock` (a FIFO, a wedged network mount) the
  # `tr` BLOCKS ON OPEN, so `--start`/`--restart` — the documented recovery — hung with no output.
  [ -f "$1/.orch.lock" ] || return 0
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
      lc_err "❌ refusing to start $label: a controller started OUTSIDE launchd already holds $O/.orch.lock (pid $lock), so launchd's copy would exit at once and KeepAlive would relaunch it forever. Next: stop it (pkill -f \"[b]ash $O/orch-loop.sh\", then verify with pgrep -fl '[o]rch-loop' and only then rm -f $O/.orch.lock), then re-run"
      return 1
    fi
  fi
  before="$(lc_hb_value "$O")"
  printf '==> restarting %s (enable → bootout → bootstrap)\n' "$label"
  via="$(lc_start "$label" "$plist")" || return 1
  LC_OUTCOME="restarted"
  printf '  ✓ loaded via %s\n' "$via"
  lc_assert_running "$label" "$O" "$before" "$timeout" "$pid"
}

# lc_ensure <label> <plist> <O> <loaded_is_current 0|1> [timeout] [hb_stale]
# The SAFE-ON-A-LIVE-BOX entry point behind `install.sh --start`. It sets the global LC_OUTCOME to what it
# ACTUALLY did — `left-untouched`, `reloaded` or `started` — so the caller's closing banner can say that
# instead of assuming a start happened (review finding: the banner claimed "this run started it and
# PROVED it" on the branch that deliberately starts nothing).
#   • the job is loaded from ANOTHER path                         → refuse before deciding anything (the
#     "left untouched" branch below would otherwise report OUR controller healthy from a foreign job);
#   • loaded job is CURRENT and the heartbeat is fresh              → LEFT COMPLETELY UNTOUCHED
#     (this is the validation run the brief protects: re-rendering the plist must never restart a
#     healthy production controller);
#   • loaded job is current, loaded, but the heartbeat is stale     → NON-ZERO, and it says so: a
#     loaded-but-not-cycling controller is wedged, and un-wedging it is `--restart`, not a silent
#     restart decided here;
#   • the loaded job is STALE                                        → reload (the running job is on the
#     old settings; applying them is the ONLY reason to touch a live job);
#   • not loaded                                                     → start.
# ⛔ "loaded_is_current" is NOT "the plist file did not change" — see install.sh's PLIST_CHANGED, which
# also has to consider that a plain install OVERWRITES the file without reloading the job (review
# finding: comparing the render to the FILE made the next --start skip the reload it existed to do).
# hb_stale is the "loaded but wedged" bound, passed in by the caller so it can track that cell's CYC
# (a fixed 900s fails a healthy CYC=900 cell and points the operator at a needless restart).
lc_ensure() {
  local label="$1" plist="$2" O="$3" changed="${4:-1}" timeout="${5:-30}" stale="${6:-780}"
  local pid age lock via before prc block
  LC_OUTCOME="started"
  # ⛔ NORMALISED LIKE `START_TIMEOUT` AND `LC_SETTLE` (review finding): `[ abc -le … ]` makes bash print
  # an integer-expression error and the test FAIL, so `LC_HB_STALE=abc` refused a perfectly healthy
  # controller with a stale-heartbeat claim that was not true, pointing at a bootout+bootstrap. Anything
  # non-numeric (or below 1) falls back to the cell's own bound.
  case "$stale" in ''|*[!0-9]*) stale=$(( ${CYC:-240} * 2 + 300 )) ;; esac
  [ "$stale" -ge 1 ] || stale=$(( ${CYC:-240} * 2 + 300 ))
  lc_guard_mutate "$label" "$plist" || return 1
  prc=0; block=""; block="$(lc_probe "$label")" || prc=$?
  if [ "$prc" -eq 2 ]; then
    lc_err "❌ refusing to decide on $label: launchd's state for that label could not be read (${block:-no output}), so 'already running' and 'not loaded' are both unproven. Next: launchctl print $(lc_domain)/$label | head -20"
    return 1
  fi
  pid=""
  [ "$prc" -eq 0 ] && pid="$(awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }' <<<"$block")"
  if [ "$changed" = "0" ] && [ -n "$pid" ]; then
    age="$(lc_hb_age "$O")"
    # ⛔ AN ABSENT HEARTBEAT IS NOT A MEASUREMENT (review finding): `lc_hb_age` returns EMPTY when the
    # read produced no usable INSTANT, and `${age:-unreadable}s old` then asserted "running but NOT
    # cycling" from a value that was never read — and pointed at `--restart`, a mutating remedy, on a
    # controller that may be perfectly healthy. Refuse, and name the datum that is actually at fault:
    # "missing" and "present but not a usable instant" (future-dated beyond the skew tolerance, or a
    # value bash will not compare) send the operator to different places.
    if [ -z "$age" ]; then
      if [ -f "$O/heartbeat" ]; then
        lc_err "❌ refusing to decide on $label: $O/heartbeat is PRESENT but is not a usable instant (empty, unreadable, non-numeric, or future-dated beyond the 60s skew), so 'not cycling' is UNPROVEN. Next: cat -v $O/heartbeat; date +%s; tail -40 $O/logs/orch-loop.log"
      else
        lc_err "❌ refusing to decide on $label: $O/heartbeat is missing or not a regular file (so there is no readable instant at that path), so 'not cycling' is UNPROVEN. Next: ls -l $O/heartbeat; tail -40 $O/logs/orch-loop.log"
      fi
      return 1
    fi
    if [ "$age" -le "$stale" ]; then
      # ⛔ A FRESH HEARTBEAT IS NOT PROOF OF HEALTH. `orch-loop.sh` writes it as the first act of a
      # cycle and the plist is KeepAlive, so a controller that dies seconds after every start keeps the
      # age fresh forever and this branch would bless it as "already running". The relaunch counter is
      # what separates them, and it is a read-only check — the live box is still left untouched.
      lc_assert_stable "$label" "${LC_SETTLE:-}" || return 1
      LC_OUTCOME="left-untouched"
      printf '  ✓ %s already running (pid %s, heartbeat %ss old, not relaunching) and the loaded job is CURRENT — left untouched\n' "$label" "$pid" "$age"
      return 0
    fi
    lc_err "❌ $label is loaded (pid $pid) but $O/heartbeat is ${age}s old (limit ${stale}s) — running but not cycling. Next: install.sh --restart"
    return 1
  fi
  if [ -z "$pid" ]; then
    lock="$(lc_foreign_controller "$O")"
    if [ -n "$lock" ]; then
      lc_err "❌ refusing to start $label: a controller started OUTSIDE launchd already holds $O/.orch.lock (pid $lock), so launchd's copy would exit at once and KeepAlive would relaunch it forever. Next: stop it (pkill -f \"[b]ash $O/orch-loop.sh\", then verify with pgrep -fl '[o]rch-loop' and only then rm -f $O/.orch.lock), then re-run"
      return 1
    fi
  fi
  # Captured BEFORE the start: `orch-loop.sh` writes the heartbeat as the FIRST act of its first
  # cycle, so a baseline read after the start would already contain the bump this assertion is
  # waiting for (see lc_assert_running).
  before="$(lc_hb_value "$O")"
  if [ -n "$pid" ]; then
    LC_OUTCOME="reloaded"
    printf '==> reloading %s — the loaded job is NOT on the rendered plist (enable → bootout → bootstrap)\n' "$label"
  else
    printf '==> starting %s (enable → bootout → bootstrap)\n' "$label"
  fi
  via="$(lc_start "$label" "$plist")" || return 1
  printf '  ✓ loaded via %s\n' "$via"
  lc_assert_running "$label" "$O" "$before" "$timeout" "$pid"
}
