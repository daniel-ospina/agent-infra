#!/usr/bin/env bash
# install-launchd-durability.test.sh — the installer must never be able to take the production
# controller down (agent-infra#1975).
#
# Run: bash scripts/orchestrator-harness/install-launchd-durability.test.sh
# Exits 0 when ALL assertions pass, non-zero on any failure. HERMETIC: a throwaway HOME, a throwaway
# `$O`, and a `launchctl` stub first on PATH — it never touches real launchd, the real
# ~/Library/LaunchAgents, or the live controller.
#
# WHAT IT PINS, and the measured failure behind each:
#
#   A. no persistent-disable verb in CODE
#        `launchctl unload -w` sets the job's on-disk Disabled override to true (man launchctl) and
#        `enable|disable` state "persists across boots". The old flow was unload -w then load -w: a
#        DISABLE whose re-enable needed a bootstrap allowed to fail. On 2026-10-17 it failed (EIO) and
#        left com.eldato.orchestrator-loop removed AND disabled while the installer exited 0.
#   B. lc_pid parses a REAL `launchctl print` block
#        fixture captured from this box, so the pid read is pinned to launchd's actual output rather
#        than to an invented shape.
#   C. lc_start: enable → bootout → bootstrap, and reports WHICH path ran
#        the `load` fallback is what recovered the box; an operator debugging the next EIO must be
#        told the job came up on the legacy path, not left to guess.
#   D. lc_ensure leaves a healthy controller ALONE
#        a validation run that re-renders identical bytes with a MATCHING loaded-render record
#        (`$O/state/launchd-loaded.sha256`) must make zero mutating launchctl calls — an ABSENT record is
#        UNKNOWN and reloads once, which §F asserts separately.
#   E. THE CORE: no forbidden end state, ever
#        for every start scenario the triple (running?, disabled?, exit code) is checked, and the
#        cell "not running AND (disabled OR exit 0)" fails the suite. This is the regression the issue
#        is about: something died, nothing said so, and the exit code claimed success.
#   F. end-to-end install.sh (runs everywhere; `plutil` is stubbed off macOS so the incident's own path
#      — `--uninstall` and its read-back — is gated in CI, not only on a developer's mac):
#        plain install = zero mutating calls; --start proves itself; a failed --start exits non-zero
#        with one actionable line; --uninstall bootouts AND verifies the job is gone; an unknown flag
#        is refused.
#   G. the job is OURS or it is not touched: `launchctl bootout <domain> <path>` resolves the removal by
#        the LABEL it reads out of that plist (measured 2026-10-17: removing via a copy at a different
#        path killed the job bootstrapped from the first), so a plist carrying the production label is
#        not a sandbox. The loaded job's own `path =` must equal the plist, or the mutation is refused.
#   H. a live pid and a fresh heartbeat are not proof of health: `orch-loop.sh` writes the heartbeat
#        FIRST in a cycle and the plist is KeepAlive, so a controller that dies seconds after every
#        start looks healthy forever. `runs` is the counter that separates cycling from crash-looping.
#   I. TEMP HOME (#446): a run whose $HOME is not the real home refuses to mutate launchd at all
#        (tests opt in with ELDATO_ALLOW_TEST_HOME=1, exactly as scripts/install-launchd.sh does).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$SCRIPT_DIR"
INSTALL="$HARNESS/install.sh"
LIB="$HARNESS/launchd-cycle.sh"
README="$HARNESS/README.md"
SELF="$HARNESS/selftest.sh"
PLATFORM="$(uname)"
LABEL="com.eldato.orchestrator-loop"

PASS=0; FAIL=0; SKIP=0
ok()    { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skipd() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

assert_eq() { # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi
}
# ⛔ HERE-STRINGS, NOT `printf … | grep -q` (#841): under `pipefail` the quiet grep exits on its first
# match, the writer takes SIGPIPE, and the PIPELINE's status becomes 141 — `$?` then records a SIGPIPE
# instead of the match. Checked by `scripts/check-no-sigpipe-grep.sh`, which gates CI on the shape.
assert_contains() { # <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() {
  if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/install-durability.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

# ⛔ THE STUB. It records every invocation, maintains a tiny state dir, and RECORDS A VIOLATION for
# any invocation carrying the persistent-disable flag or the unload/disable verbs — so "the script
# never writes a persistent disable" is asserted against observed behaviour, not against a grep of
# the source alone.
mkdir -p "$T/bin"
cat > "$T/bin/launchctl" <<'SHIM'
#!/usr/bin/env bash
log="${FAKE_LOG:?}"; st="${FAKE_STATE:?}"
printf '%s\n' "$*" >> "$log"
case " $* " in *" -w "*) printf 'VIOLATION persistent-disable-flag %s\n' "$*" >> "$log" ;; esac
case "${1:-}" in unload|disable) printf 'VIOLATION persistent-disable-verb %s\n' "$*" >> "$log" ;; esac

bump_hb() { # a live controller refreshes $O/heartbeat at the top of every cycle
  local f="${FAKE_O:?}/heartbeat" prev v
  [ -n "${FAKE_NO_HB:-}" ] && return 0
  # A REAL epoch, like orch-loop.sh's `date +%s > $O/heartbeat` — the freshness read compares it
  # against the wall clock, so a counter would make every seeded state look centuries stale. It is
  # forced STRICTLY past the previous value so that two launches inside the same second still read as
  # "it advanced" (a real controller's cycle is minutes, but a test must not depend on the clock).
  prev="$(cat "$f" 2>/dev/null || echo 0)"
  v="$(date +%s)"
  # FAKE_HB_EPOCH=1 writes the REAL clock even when that is not an increase — the one shape the
  # strictly-increasing rule below cannot express, and the shape that exposes a poisoned baseline
  # (a heartbeat seeded in the FUTURE, then a healthy controller writing `now`).
  if [ -z "${FAKE_HB_EPOCH:-}" ]; then [ "$v" -le "$prev" ] && v=$(( prev + 1 )); fi
  printf '%s\n' "$v" > "$f"
}
start_ok() { # $1 = ignored; the pid is DERIVED from the launch count, because launchd gives every start
  # a NEW pid — a stub that reuses one pid cannot distinguish "the job was replaced" from "nothing
  # happened", and that distinction is exactly what lc_assert_running's replaced-pid check tests.
  local runs pid
  runs=$(( $(cat "$st/runs" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$runs" > "$st/runs"
  # The pid a start WOULD get: a fresh one each launch. FAKE_STALE_PID keeps the PREVIOUS one, i.e. the
  # old process survived the bootstrap — a bootout deletes the print block, hence the separate lastpid.
  if [ -n "${FAKE_STALE_PID:-}" ] && [ -f "$st/lastpid" ]; then
    pid="$(cat "$st/lastpid")"
  else
    pid=$(( 4200 + runs ))
  fi
  printf '%s\n' "$pid" > "$st/lastpid"
  # `minimum runtime = N` is launchd's own report of ThrottleInterval (default 10s) — measured on this box
  # against com.eldato.orchestrator-loop and two other labels. lc_assert_stable derives its window from it.
  printf 'gui/0/%s = {\n\tactive count = 1\n\tpath = %s\n\tstate = running\n\n\tminimum runtime = %s\n\truns = %s\n\tpid = %s\n}\n' \
    "${FAKE_LABEL:-com.eldato.orchestrator-loop}" "${FAKE_PLIST:-$FAKE_O/x.plist}" "${FAKE_MIN_RUNTIME:-10}" "$runs" "$pid" > "$st/print"
  : > "$st/loaded"
  bump_hb
}
case "${1:-}" in
  print)
    # ⛔ A READ THAT FAILS IS NOT "NO SUCH SERVICE". FAKE_PRINT_FAIL models the EIO family: launchd
    # cannot tell us anything, so "loaded" and "not loaded" are both unproven and the caller must
    # refuse. FAKE_PRINT_FAIL_UNLOADED models the same read breaking AFTER a successful removal — the
    # state that let `--uninstall` print ✅ and delete the plist over a job it could not read back.
    if [ -n "${FAKE_PRINT_FAIL:-}" ]; then printf 'Print failed: 5: Input/output error\n' >&2; exit 1; fi
    # FAKE_PRINT_BADONLY: a diagnostic that is NOT launchd's not-found answer and NOT a parseable block.
    # `Bad request` alone is a DOMAIN-level rejection — treating it as "absent" is how the tri-state
    # would shrink back into the flattening it replaced.
    if [ -n "${FAKE_PRINT_BADONLY:-}" ]; then printf 'Bad request.\n' >&2; exit 1; fi
    # FAKE_PRINT_DOMAIN: launchd's DOMAIN-level rejection, verbatim as this box prints it for
    # `print gui/999/x`. It says NOTHING about the service, so it must read as UNKNOWN, never as absent.
    if [ -n "${FAKE_PRINT_DOMAIN:-}" ]; then printf 'Bad request.\nCould not find domain for user gui: 999\n' >&2; exit 1; fi
    # FAKE_SERVICE_GONE_ON=N: at call N the SERVICE is genuinely gone (launchd's own service-level
    # not-found text) — the vanish-mid-window shape, which is ABSENT and must not be read as "stable".
    if [ -n "${FAKE_SERVICE_GONE_ON:-}" ]; then
      n=$(( $(cat "$st/printcalls" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$n" > "$st/printcalls"
      if [ "$n" -ge "${FAKE_SERVICE_GONE_ON}" ]; then
        printf 'Bad request.\nCould not find service "%s" in domain for user gui: 0\n' "${FAKE_LABEL:-com.eldato.orchestrator-loop}" >&2
        exit 1
      fi
    fi
    # FAKE_PRINT_NO_PATH: LOADED, but the block carries no `path =` line (a job registered by
    # `launchctl submit`). The ownership guard must refuse rather than skip its one precondition.
    if [ -n "${FAKE_PRINT_NO_PATH:-}" ]; then
      printf 'gui/0/%s = {\n\tactive count = 1\n\tstate = running\n\n\truns = 1\n\tpid = 9911\n}\n' "${FAKE_LABEL:-com.eldato.orchestrator-loop}"
      exit 0
    fi
    # FAKE_PRINT_SILENT_ON=N: call N exits non-zero and prints NOTHING — launchd killed or re-exec'ing.
    # `lc_probe` returns UNKNOWN with EMPTY output, which is the shape that made an `unread="$block"`
    # flag falsy and let `--uninstall` delete the plist over a live job.
    if [ -n "${FAKE_PRINT_SILENT_ON:-}" ]; then
      n=$(( $(cat "$st/printcalls" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$n" > "$st/printcalls"
      if [ "$n" -eq "${FAKE_PRINT_SILENT_ON}" ]; then exit 1; fi
    fi
    # FAKE_PRINT_NO_RUNS: LOADED with a pid but no `runs` line — an ABSENT datum on a loaded job, which
    # must not be reported as "not loaded".
    if [ -n "${FAKE_PRINT_NO_RUNS:-}" ]; then
      printf 'gui/0/%s = {\n\tactive count = 1\n\tpath = %s\n\tstate = running\n\n\tpid = 4242\n}\n' \
        "${FAKE_LABEL:-com.eldato.orchestrator-loop}" "${FAKE_PLIST:-$FAKE_O/x.plist}"
      exit 0
    fi
    if [ -n "${FAKE_PRINT_FAIL_UNLOADED:-}" ] && [ ! -f "$st/loaded" ]; then printf 'Print failed: 5: Input/output error\n' >&2; exit 1; fi
    # FAKE_PRINT_FAIL_ON=N: exactly the Nth `print` call in this run fails and every other one succeeds.
    # This is the shape the whole-run knob cannot express: the SECOND read of `lc_assert_stable` (or a
    # read that flips mid-window) failing while the first succeeded — the read that must not be folded
    # into "not relaunching".
    if [ -n "${FAKE_PRINT_FAIL_ON:-}" ]; then
      n=$(( $(cat "$st/printcalls" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$n" > "$st/printcalls"
      if [ "$n" -eq "${FAKE_PRINT_FAIL_ON}" ]; then printf 'Print failed: 5: Input/output error\n' >&2; exit 1; fi
    fi
    # FAKE_DOMAIN_GONE_ON=N: at call N launchd answers with its DOMAIN-level rejection instead of the
    # block — the job (or the domain) vanishing mid-window. `Could not find domain for user gui: N` is
    # what real launchd prints for `print gui/999/x` (measured), and it says NOTHING about the service.
    if [ -n "${FAKE_DOMAIN_GONE_ON:-}" ]; then
      n=$(( $(cat "$st/printcalls" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$n" > "$st/printcalls"
      if [ "$n" -ge "${FAKE_DOMAIN_GONE_ON}" ]; then
        printf 'Bad request.\nCould not find domain for user gui: 999\n' >&2; exit 1
      fi
    fi
    if [ -n "${FAKE_BOOTOUT_LAG:-}" ] && [ -f "$st/lag" ]; then
      n="$(cat "$st/lag")"
      if [ "$n" -ge 1 ]; then
        printf '%s\n' $(( n + 1 )) > "$st/lag"
        if [ "$n" -eq 1 ]; then cat "$st/print"; exit 0; fi   # one last sight of the (already removed) job
        rm -f "$st/print" "$st/loaded" "$st/lag"
        printf 'Bad request.\nCould not find service "%s" in domain for user gui: 0\n' \
          "${FAKE_LABEL:-com.eldato.orchestrator-loop}" >&2
        exit 1
      fi
    fi
    if [ -n "${FAKE_PRINT_FILE:-}" ]; then cat "$FAKE_PRINT_FILE"; exit 0; fi
    # FAKE_CRASHLOOP: a job that starts and dies — launchd bumps `runs` between two reads while the pid
    # and the heartbeat stay plausible (that is exactly why pid+heartbeat cannot detect it).
    if [ -n "${FAKE_CRASHLOOP:-}" ] && [ -f "$st/print" ]; then
      runs=$(( $(cat "$st/runs" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$runs" > "$st/runs"
      awk -v r="$runs" '/^[[:space:]]*runs = /{ printf "\truns = %s\n", r; next } { print }' \
        "$st/print" > "$st/print.new" && mv "$st/print.new" "$st/print"
    fi
    if [ -f "$st/print" ]; then cat "$st/print"; exit 0; fi
    printf 'Bad request.\nCould not find service in domain for user gui: 0\n' >&2; exit 1 ;;
  enable)   : > "$st/enabled"; exit 0 ;;
  print-disabled)
    # FAKE_PD models the four answers this verb really gives: an override for our label, none at all
    # (the healthy box), a silent/empty answer, and a failed read. Without an arm for it the verb fell
    # through to `exit 0` with no output, so `lc_disable_state` could only ever answer `unknown` inside
    # the suite — and the enable read-back was UNPINNED (review finding: deleting it kept the suite green).
    case "${FAKE_PD:-enabled}" in
      disabled) printf '\t\t"%s" => disabled\n' "${FAKE_LABEL:-com.eldato.orchestrator-loop}" ;;
      enabled)  printf '\t\t"%s" => enabled\n' "${FAKE_LABEL:-com.eldato.orchestrator-loop}" ;;
      unset)    printf '\t\t"com.example.other" => disabled\n' ;;
      fail)     printf 'Print failed: 5: Input/output error\n' >&2; exit 1 ;;
      silent)   exit 0 ;;
      *)        printf '\t\t"%s" => %s\n' "${FAKE_LABEL:-com.eldato.orchestrator-loop}" "$FAKE_PD" ;;
    esac ;;
  bootout)
    [ -n "${FAKE_BOOTOUT_FAIL:-}" ] && { printf 'Bootout failed: 5: Input/output error\n' >&2; exit 1; }
    # Real launchd on an unknown service: exit 3 with this exact line (`man launchctl` territory). Modelled
    # because lc_bootout's tolerance allow-list exists for the harmless "gone between the read and the
    # verb" race, and an unreachable branch is an untested one.
    [ -n "${FAKE_BOOTOUT_RACE:-}" ] && { printf 'Boot-out failed: 3: No such process\n' >&2; exit 3; }
    # FAKE_BOOTOUT_LIE: reports success while the job stays loaded — the exact case a status check cannot
    # catch, and the one that needs the caller to READ the domain back.
    [ -n "${FAKE_BOOTOUT_LIE:-}" ] && exit 0
    # FAKE_BOOTOUT_LAG: the removal SUCCEEDED, but launchd keeps printing the job for exactly one more
    # read (the settle lag). The caller must wait it out and end with a verified removal — a verdict taken
    # from the FIRST observation instead of the last refused the operator's own handoff command.
    if [ -n "${FAKE_BOOTOUT_LAG:-}" ]; then
      printf '%s\n' 1 > "$st/lag"
      exit 0
    fi
    # FAKE_BOOTOUT_LIE_NOPID: the lying bootout AND the job it lied about has no pid right now — which is
    # what a KeepAlive job looks like inside its respawn throttle, and exactly the state in which a
    # verdict taken from a PID (instead of from the probe) prints "Removed" over a live job.
    if [ -n "${FAKE_BOOTOUT_LIE_NOPID:-}" ]; then
      printf 'gui/0/%s = {\n\tactive count = 1\n\tpath = %s\n\tstate = running\n\n\tminimum runtime = 10\n\truns = 1\n}\n' \
        "${FAKE_LABEL:-com.eldato.orchestrator-loop}" "${FAKE_PLIST:-$FAKE_O/x.plist}" > "$st/print"
      exit 0
    fi
    if [ -f "$st/loaded" ]; then rm -f "$st/loaded" "$st/print"; exit 0; fi
    exit 3 ;;  bootstrap)
    [ -n "${FAKE_BOOTSTRAP_FAIL:-}" ] && { printf 'Bootstrap failed: 5: Input/output error\n' >&2; exit 1; }
    # Real launchd REFUSES a bootstrap over an already-loaded service (EIO — the incident's own line); modelled
    # so the "bootout before bootstrap" ordering is proven load-bearing rather than convenient.
    [ -n "${FAKE_BOOTSTRAP_ALREADY_LOADED:-}" ] && [ -f "$st/loaded" ] && { printf 'Bootstrap failed: 5: Input/output error\n' >&2; exit 1; }
    start_ok 4242; exit 0 ;;
  load)
    [ -n "${FAKE_LOAD_FAIL:-}" ] && { printf 'Load failed: 5: Input/output error\n' >&2; exit 1; }
    start_ok 5353; exit 0 ;;
  kickstart) exit 0 ;;
esac
exit 0
SHIM
chmod +x "$T/bin/launchctl"
PATH="$T/bin:$PATH"; export PATH

fresh() { # reset the stub's world; $1 = heartbeat seed (optional)
  rm -rf "$T/state" "$T/o"; mkdir -p "$T/state" "$T/o/logs"
  printf '%s\n' "${1:-100}" > "$T/o/heartbeat"
  : > "$T/o/x.plist"   # lc_bootout needs a plist path that exists to issue a removal
  export FAKE_LOG="$T/launchctl.log" FAKE_STATE="$T/state" FAKE_O="$T/o"
  : > "$FAKE_LOG"
  unset FAKE_BOOTSTRAP_FAIL FAKE_LOAD_FAIL FAKE_NO_HB FAKE_PRINT_FILE FAKE_BOOTOUT_FAIL \
    FAKE_BOOTOUT_LIE FAKE_BOOTOUT_LIE_NOPID FAKE_CRASHLOOP FAKE_PLIST FAKE_THROTTLE \
    FAKE_MIN_RUNTIME FAKE_STALE_PID FAKE_BOOTOUT_RACE FAKE_BOOTSTRAP_ALREADY_LOADED \
    FAKE_PRINT_FAIL FAKE_PRINT_FAIL_UNLOADED FAKE_HB_EPOCH FAKE_PRINT_BADONLY FAKE_PRINT_NO_PATH FAKE_PRINT_FAIL_ON FAKE_DOMAIN_GONE_ON FAKE_PRINT_DOMAIN FAKE_SERVICE_GONE_ON FAKE_PRINT_SILENT_ON FAKE_PRINT_NO_RUNS FAKE_BOOTOUT_LIE_NOPID FAKE_BOOTOUT_LAG FAKE_PD 2>/dev/null || true
}
calls() { cat "$FAKE_LOG" 2>/dev/null || true; }
verbs() { awk '$1 != "print" && $1 != "print-disabled" {printf "%s ", $1}' "$FAKE_LOG" 2>/dev/null; }
is_loaded() { [ -f "$T/state/loaded" ]; }
violations() { grep '^VIOLATION' "$FAKE_LOG" 2>/dev/null || true; }
# ⛔ SERVICE-TARGET REMOVALS. `bootout gui/<uid>/<label>` resolves the label in the REAL user domain and
# IGNORES $HOME, so a sandboxed installer run using it would remove the PRODUCTION controller. The stub
# logs argv, so the FORM is observable: verb + one target = service-target form; verb + domain + path =
# the form we ship. Two shapes are NOT the same property — a stub cannot model launchd's path→service
# resolution, so this only pins the shape; section G pins the property that actually matters.
service_target_bootouts() { awk '$1=="bootout" && NF<3 {print}' "$FAKE_LOG" 2>/dev/null || true; }

# ── the forbidden end state (E) — ONE helper, used by every scenario below ────────────────────────
# "Something died, nothing said so, and the exit code claimed success" is the exact shape of
# agent-infra#1975. So the state is read as a TRIPLE, and the one cell that must never occur is:
#   not running  AND  (persistent disable written OR exit code 0)
assert_end_state() { # <rc> <label-for-the-assertion>
  local rc="$1" name="$2" running=no viol
  is_loaded && running=yes
  viol="$(violations)"
  if [ "$running" = "no" ] && { [ -n "$viol" ] || [ "$rc" = "0" ]; }; then
    bad "$name — FORBIDDEN END STATE: not running with (disabled='${viol:-none}' rc=$rc)"
    return 1
  fi
  ok "$name — end state legal (running=$running, disable-writes=${viol:+YES}${viol:-none}, rc=$rc)"
  return 0
}

echo "==> install/launchd durability ($HARNESS)"

# ── A. no persistent-disable verb in CODE ────────────────────────────────────────────────────────
# Comments are excluded deliberately: a comment cannot run, and the whole point of several comments in
# these files is to NAME the trap for the next reader. README has no comments, so its code blocks are
# scanned as commands — those are what an agent copies and pastes.
echo "-- A. no persistent-disable invocation in code"
code_of() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null || true; }
A_BAD=""
for f in "$HARNESS"/*.sh "$HARNESS"/*.template; do
  case "$f" in *.test.sh) continue ;; esac
  hit="$(code_of "$f" | grep -nE 'launchctl[^|]*[[:space:]]-w|launchctl[[:space:]]+(unload|disable)[[:space:]]|(unload|load)[[:space:]]+-w[[:space:]]' || true)"
  [ -n "$hit" ] && A_BAD="$A_BAD
$(basename "$f"): $hit"
done
if [ -z "$A_BAD" ]; then ok "no shipped CODE line writes a persistent disable (launchctl … -w / unload / disable)"
else bad "a shipped code line writes a persistent disable:$A_BAD"; fi

# README: every COPYABLE launchctl command must be safe. ⛔ A LINE THAT "STARTS WITH launchctl" IS NOT
# WHAT AN AGENT COPIES (review finding): `sudo launchctl unload -w …`, a `$ launchctl unload -w …` line
# inside a fenced block, and `… && launchctl unload -w …` are all copyable and were all MISSED by the
# `^`-anchored detectors — appending the most likely thing an operator pastes left both green. Prose that
# merely names the verbs must NOT be flagged, so the scan is limited to FENCED blocks and strips a shell
# prompt first.
readme_unsafe() {   # $1 = file → "<line>: <text>" for unsafe copyable commands, empty when clean
  awk '
    /^[[:space:]]*(```|~~~)/ { inb = !inb; next }
    inb {
      l = $0
      # A COMMENT IS NOT A COMMAND — tested BEFORE the prompt strip, because `#   ` is itself in the
      # prompt class and stripping it turned a warned-against verb in a comment into "a command".
      if (l ~ /^[[:space:]]*#/) next
      sub(/^[[:space:]]*[$>][[:space:]]+/, "", l)
      if (l ~ /(^|[^[:alnum:]_-])launchctl[[:space:]]+(unload|disable)([[:space:]]|$)/ ||
          l ~ /launchctl[[:space:]]+(load|unload)[^#]*-w/) printf "%d: %s\n", NR, $0
    }' "$1" 2>/dev/null
}
R_BAD="$(readme_unsafe "$README")"
if [ -z "$R_BAD" ]; then ok "README ships no copyable 'launchctl unload'/'launchctl disable'/'… -w' command"
else bad "README still ships a copyable persistent-disable command: $R_BAD"; fi
# …and the DETECTOR ITSELF is pinned: a loosening (or a re-anchoring) must go red here, not silently
# un-guard the README. Fixture = a copy of the README plus the exact line an operator would paste.
R_FIX="$T/readme-fixture.md"; { cat "$README"; printf '\n```\nsudo launchctl unload -w ~/Library/LaunchAgents/%s.plist\n```\n' "$LABEL"; } > "$R_FIX"
if [ -n "$(readme_unsafe "$R_FIX")" ]; then ok "the README detector FIRES on 'sudo launchctl unload -w …' (fixture)"
else bad "the README detector misses a pasted 'sudo launchctl unload -w …' — the pin does not protect what it claims"; fi
# ⛔ …AND ON THE SHAPE WITHOUT `-w`, which is what the `-w` arm cannot catch (`unload` alone still
# de-registers, and `disable` is the verb the incident wrote): a `^`-anchored detector missed this.
R_FIX2="$T/readme-fixture2.md"; { cat "$README"; printf '\n```\nsudo launchctl unload ~/Library/LaunchAgents/%s.plist\nlaunchctl disable gui/501/%s\n```\n' "$LABEL" "$LABEL"; } > "$R_FIX2"
if [ "$(readme_unsafe "$R_FIX2" | wc -l | tr -d ' ')" -ge 2 ]; then ok "…and on 'sudo launchctl unload …' plus 'launchctl disable …' (fixture, no -w)"
else bad "the README detector misses an unflagged 'launchctl unload'/'launchctl disable' — prose-vs-command discrimination is not what an anchored match implements"; fi
if [ -z "$(readme_unsafe "$README")" ]; then ok "…and stays quiet on the shipped README (no false block)"; fi

# The ONE implementation, and the installer must refuse without it (fail closed, never a silent
# degrade to the legacy verbs).
LIB_CODE="$(code_of "$LIB")"
INSTALL_CODE="$(code_of "$INSTALL")"
# ⛔ NO SOURCE GREPS FOR THE VERBS. `grep "launchctl bootout"` is satisfied by our own error message
# ("launchctl bootout failed for …"), so it can pass while the call is renamed/moved to a variable —
# measured: rewriting the call as `_v=bootout; launchctl "$_v" …` kept the suite green. The verbs are
# asserted BEHAVIOURALLY instead, from the stub's argv log (sections C and F), which cannot be spoofed
# by a string in a diagnostic.
assert_contains "$INSTALL_CODE" 'launchd-cycle.sh' "install.sh has the helper's path"
# ⛔ HERMETICITY IS A PROPERTY OF EVERY SHIPPED SUITE, NOT JUST THIS ONE (review finding, T5):
# `selftest.sh` §6d ran `PATH="$FB:/usr/bin:/bin" bash "$INST"`, DROPPING this suite's launchctl stub, so
# the render path read the REAL domain (`launchctl print gui/<uid>/com.eldato.orchestrator-loop`) — the
# exact shape whose mutating sibling removed the live controller on 2026-10-17. Every installer
# invocation that also sets a PATH must carry the stub.
ST_BAD="$(grep -nE 'PATH="[^"]*".*bash "\$INST"|bash "\$INST".*PATH="[^"]*"' "$SELF" 2>/dev/null | grep -v 'GSTUB' || true)"
if [ -z "$ST_BAD" ]; then ok "every installer invocation in selftest.sh that sets its own PATH keeps the launchctl stub (no real-domain read)"
else bad "selftest.sh invokes install.sh on a PATH without the launchctl stub (real launchd reads): $ST_BAD"; fi
if grep -q 'LC_LIB' <<<"$INSTALL_CODE" && grep -q 'die "missing \$LC_LIB' <<<"$INSTALL_CODE"; then
  ok "install.sh FAILS CLOSED when launchd-cycle.sh is missing"
else bad "install.sh would silently proceed without launchd-cycle.sh"; fi
if grep -qE '^[[:space:]]*\. "\$LC_LIB"' <<<"$INSTALL_CODE"; then ok "install.sh sources launchd-cycle.sh"
else bad "install.sh does not source launchd-cycle.sh"; fi

# ── B. lc_pid against a REAL launchctl print block ───────────────────────────────────────────────
echo "-- B. pid read against a captured real 'launchctl print' block"
# Captured from `launchctl print gui/501/com.eldato.orchestrator-loop` on 2026-10-17, trimmed to the
# shape that matters: the job-level `pid = N` line, and the nested `state = active` lines that must
# NOT be read as a pid.
cat > "$T/real-print.txt" <<'REAL'
gui/501/com.eldato.orchestrator-loop = {
	active count = 1
	path = /Users/someone/Library/LaunchAgents/com.eldato.orchestrator-loop.plist
	type = LaunchAgent
	state = running

	program = /bin/bash
	arguments = {
		/bin/bash
		/Users/someone/orchestrator/orch-loop.sh
	}

	pid = 83626

	immediate reason = speculative
	forks = 0
	execs = 0

	resource coalition = {
		state = active
		roles = {
			coalition = {
				state = active
			}
		}
	}

	environment = {
		PATH => /usr/bin:/bin
	}
}
REAL
fresh
# ⛔ EXPORTED, not bare: a bare `FAKE_X=1` on its own line is a shell variable, so the stub (a child
# process) never sees it — the knobs silently do nothing and the test asserts nothing.
export FAKE_PRINT_FILE="$T/real-print.txt"
got="$(
  # shellcheck source=launchd-cycle.sh
  . "$LIB"; lc_pid "$LABEL"
)"
assert_eq "$got" "83626" "lc_pid returns the job's own pid from a real block (not a nested state)"
unset FAKE_PRINT_FILE
got="$( . "$LIB"; lc_pid "$LABEL" )"
assert_eq "$got" "" "lc_pid returns EMPTY for a job that is not loaded (empty, never a guess)"

echo "-- B3. a heartbeat in the FUTURE is UNKNOWN, not infinitely fresh"
# `[ -N -le M ]` is true for every negative N, so `now - value` with value > now would pass the staleness
# gate forever (a clock correction, a file written under another clock, a corrupt value).
fresh
printf '%s\n' "$(( $(date +%s) + 86400 ))" > "$T/o/heartbeat"
assert_eq "$( . "$LIB"; lc_hb_age "$T/o" )" "" "a future heartbeat reads as EMPTY (unknown)"
printf '%s\n' "$(( $(date +%s) - 5 ))" > "$T/o/heartbeat"
if [ -n "$( . "$LIB"; lc_hb_age "$T/o" )" ]; then ok "non-vacuity: a past heartbeat still reads as an age"
else bad "lc_hb_age reports nothing for a normal heartbeat"; fi

# ── C. lc_start: order, reporting, and the load fallback ─────────────────────────────────────────
echo "-- C. lc_start"
fresh
via="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" )"; rc=$?
assert_eq "$via" "bootstrap" "a healthy bootstrap reports via=bootstrap"
assert_eq "$rc" "0" "a healthy bootstrap returns 0"
order="$(verbs)"
case "$order" in
  "enable bootstrap "*) ok "invocation order is enable → bootstrap on a box with nothing loaded ($order)" ;;
  *) bad "invocation order is wrong: $order" ;;
esac
# …and a start over an ALREADY-LOADED job must boot the old one out first (a job that is still loaded
# cannot be bootstrapped again, and the pids must differ or the start did not take effect).
: > "$FAKE_LOG"
via2="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" )"; rc=$?
assert_eq "$rc" "0" "a start over a loaded job returns 0"
case "$(verbs)" in
  "enable bootout bootstrap "*) ok "invocation order is enable → bootout → bootstrap when a job is loaded ($(verbs))" ;;
  *) bad "a start over a loaded job has the wrong order: $(verbs)" ;;
esac
assert_eq "$(violations)" "" "no persistent-disable verb was used"
assert_eq "$(service_target_bootouts)" "" "the removal is passed a service TARGET plus plist PATH, not a bare service-target (shape only — see G)"

fresh
export FAKE_BOOTSTRAP_FAIL=1
out="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" 2>"$T/err.txt" )"; rc=$?
assert_eq "$out" "load" "a FAILED bootstrap falls back to the legacy load path (reported as via=load)"
assert_eq "$rc" "0" "the fallback path returns 0"
assert_contains "$(cat "$T/err.txt")" "legacy 'load' path" "the fallback SAYS which path ran"
assert_contains "$(calls)" "load" "the legacy load verb was actually invoked"

fresh
export FAKE_BOOTSTRAP_FAIL=1 FAKE_LOAD_FAIL=1
out="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" 2>"$T/err.txt" )"; rc=$?
assert_eq "$out" "none" "both paths failing reports via=none"
if [ "$rc" -ne 0 ]; then ok "both paths failing returns NON-ZERO"; else bad "both paths failing returned 0"; fi
assert_contains "$(cat "$T/err.txt")" "could not load $LABEL" "the failure names the label"
assert_contains "$(cat "$T/err.txt")" "Disabled override now reads" "the failure READS the disable state instead of asserting it"
assert_eq "$(violations)" "" "neither failure path wrote a persistent disable"
if [ -f "$T/state/enabled" ]; then ok "the job was ENABLED before the failed bootstrap"
else bad "the job was never enabled"; fi

# ── D. lc_ensure: safe on a live box ─────────────────────────────────────────────────────────────
echo "-- D. lc_ensure leaves a healthy controller alone"
# ⛔ `kickstart` is NOT read-only — it starts (or with `-k`, restarts) the job. Excluding it would make
# every "ZERO mutating launchctl calls" assertion below pass while a future `launchctl kickstart`
# restarted the live controller (review finding). Only `print` and `print-disabled` are reads (`verbs()`
# counts `kickstart` as a call for the same reason).
mutating_calls() { grep -vE '^(print|print-disabled)( |$)' "$FAKE_LOG" 2>/dev/null || true; }

fresh "$(( $(date +%s) - 5 ))"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
before="$(mutating_calls)"
out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 3 2>&1 )"; rc=$?
assert_eq "$rc" "0" "unchanged plist + healthy controller returns 0"
assert_contains "$out" "left untouched" "it says the controller was left untouched"
assert_eq "$(mutating_calls)" "$before" "ZERO MUTATING launchctl calls were made (the pid read is the only call)"

echo "-- D2. lc_ensure with a stale heartbeat"
fresh "$(( $(date +%s) - 5000 ))"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
printf '%s\n' "$(( $(date +%s) - 5000 ))" > "$T/o/heartbeat"
out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 3 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a loaded-but-not-cycling controller returns NON-ZERO"; else bad "a stale heartbeat returned 0"; fi
assert_contains "$out" "--restart" "it points at --restart rather than restarting silently"

echo "-- D3. lc_ensure reloads when the plist CHANGED"
fresh "$(( $(date +%s) - 5 ))"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 1 3 2>&1 )"; rc=$?
assert_eq "$rc" "0" "a changed plist reloads and returns 0"
assert_contains "$out" "loaded via" "it reports the load path"
assert_contains "$(calls)" "bootout" "it booted the old job out"

echo "-- D4. lc_restart refuses while a FOREIGN controller holds the lock"
fresh
printf '%s\n' "$$" > "$T/o/.orch.lock"     # this test's own shell: alive, holds the lock, not launchd
out="$( . "$LIB"; lc_restart "$LABEL" "$T/o/x.plist" "$T/o" 2 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a foreign lock holder makes the start REFUSE (non-zero)"; else bad "it started anyway"; fi
assert_contains "$out" "$T/o/.orch.lock" "the refusal names the lock and its pid"
assert_not_contains "$(calls)" "bootstrap" "nothing was bootstrapped over the foreign controller"
# ⛔ AND THE REMEDY IT PRINTS MUST BE THE SCOPED, QUOTED ONE (review finding): the message is a
# DOUBLE-QUOTED string, so an unescaped `pkill -f "[b]ash …"` reaches the operator as
# `pkill -f [b]ash /O/orch-loop.sh` — where `[b]ash` is a separate ERE matching EVERY bash process on the
# box (measured: 102). That is worse than the unscoped line it replaced, and nothing asserted the form.
assert_contains "$out" 'pkill -f "[b]ash'  "the printed remedy keeps the QUOTED scoped pattern"
assert_not_contains "$out" "pkill -f [b]ash" "…and never prints the bare ERE that matches every shell"
# the same message is reachable from lc_ensure (the other start path)
fresh
printf '%s\n' "$$" > "$T/o/.orch.lock"
out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 1 2 2>&1 )"; rc=$?
assert_contains "$out" 'pkill -f "[b]ash'  "the lc_ensure refusal keeps the quoted scoped pattern too"
rm -f "$T/o/.orch.lock"

echo "-- D5. the staleness bound tracks the CELL's cycle, not a constant"
# `install.sh` derives LC_HB_STALE from CYC (2*CYC+300). A fixed 900s would declare a healthy CYC=900
# cell wedged and point the operator at the disruptive --restart.
fresh "$(( $(date +%s) - 1500 ))"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
printf '%s\n' "$(( $(date +%s) - 1500 ))" > "$T/o/heartbeat"
out="$( . "$LIB"; LC_SETTLE=1 lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 3 2100 2>&1 )"; rc=$?
assert_eq "$rc" "0" "a 1500s-old heartbeat is HEALTHY when the bound is 2*CYC+300 for CYC=900 (2100) — a fixed 900s calls it wedged"
assert_contains "$out" "left untouched" "…and the controller is still left alone"
assert_contains "$(code_of "$INSTALL")" 'LC_HB_STALE:-$(( CYC * 2 + 300 ))' "install.sh derives the bound from CYC"
# The recovery command an operator pastes must survive a checkout path with a `'` in it; the naive
# `SELF="bash '$HERE/install.sh'"` produced an unparseable line (review finding).
assert_contains "$(code_of "$INSTALL")" 'SELF="bash $(shq "$HERE/install.sh")"' "the printed recovery command is single-quote-safe"
# ⛔ THE READ-BACK ASKS "IS THE LABEL STILL LOADED", NOT "DOES IT HAVE A PID": a KeepAlive job that
# has just exited sits loaded with no pid for up to its respawn throttle, so a pid-only read-back
# calls a job launchd still holds "removed" (review finding). The behavioural case above covers the
# lying-bootout path; this pins the datum itself, which no stub can model.

assert_contains "$(code_of "$INSTALL")" 'launchd-loaded.sha256' "the render launchd loaded is RECORDED, so 'unchanged' cannot mean 'the file did not change'"

# ── G. the loaded job must be OURS, or nothing is touched ────────────────────────────────────────
# MEASURED 2026-10-17 on this box: with a job bootstrapped from /tmp/a/x.plist, running
#   launchctl bootout gui/501 /tmp/b/copy-with-same-label.plist
# removed it (rc=0). The path is only the handle launchd uses to READ THE LABEL; removal is by label.
# So "a sandbox has its own HOME, therefore its own plist path, therefore it is safe" is FALSE — the
# rendered plist always carries the production label. What makes it safe is asking launchd where the
# loaded job actually came from.
echo "-- G. a job loaded from another path is never touched"
fresh
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
out="$( . "$LIB"; lc_bootout "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "our own job (loaded FROM this plist) is removable"

fresh
cat > "$T/foreign-print.txt" <<FOREIGN
gui/501/$LABEL = {
	active count = 1
	path = $T/elsewhere/before.plist
	state = running

	runs = 1
	pid = 9911
}
FOREIGN
export FAKE_PRINT_FILE="$T/foreign-print.txt"
out="$( . "$LIB"; lc_bootout "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a job loaded from ANOTHER path makes bootout REFUSE (non-zero)"; else bad "it booted out a job that was not loaded from our plist"; fi
assert_contains "$out" "$T/elsewhere/before.plist" "the refusal names the path launchd actually reported (the datum, not the wording)"
assert_not_contains "$(calls)" "bootout" "NO removal was issued (which would have resolved by label)"
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a start against a foreign label-holder is REFUSED (non-zero)"; else bad "it started over a foreign job"; fi
assert_not_contains "$(calls)" "enable" "enable (which has no path form at all) was not issued either"
assert_not_contains "$(calls)" "bootstrap" "nothing was bootstrapped"
unset FAKE_PRINT_FILE

# ── H. pid + fresh heartbeat is not health: the crash loop ───────────────────────────────────────
# `orch-loop.sh` writes the heartbeat FIRST in every cycle and the plist is KeepAlive=true, so a
# controller that dies seconds after each start produces a fresh heartbeat forever and a plausible pid.
echo "-- G3. a job that VANISHES between the read and the verb is not a failure"
# lc_bootout's allow-list ("No such process") exists for this race: the pre-check saw a loaded job, the
# verb found none. Without it a harmless race is reported as a fatal removal failure. The stub emits
# launchd's real line (`Boot-out failed: 3: No such process`, exit 3).
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
export FAKE_BOOTOUT_RACE=1
out="$( . "$LIB"; lc_bootout "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "a raced removal is tolerated (rc=0), not reported as a failure"
assert_not_contains "$out" "bootout failed" "…and it does not print a failure message"
unset FAKE_BOOTOUT_RACE

# …and a bootstrap over an already-loaded job is REFUSED by launchd: the start must boot the old one out
# FIRST. If that ordering ever regressed, every restart on a live box would report the incident's own EIO.
fresh "$(( $(date +%s) - 5 ))"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
export FAKE_BOOTSTRAP_ALREADY_LOADED=1
: > "$FAKE_LOG"
via="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" )"; rc=$?
assert_eq "$rc" "0" "a start over a loaded job still succeeds when launchd refuses a second bootstrap"
assert_eq "$via" "bootstrap" "…coming up via bootstrap (the old job was removed first)"
assert_contains "$(calls)" "bootout" "…which is why the bootout precedes it"
unset FAKE_BOOTSTRAP_ALREADY_LOADED

echo "-- G2. a LOADED job whose plist is gone is still removable"
# The guard has just proved the loaded job came from this plist, so the service-target form is safe here
# and is the only handle left. Treating "the file is missing" as "nothing to do" left a job launchd
# still holds while the installer printed success (review finding).
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
rm -f "$T/o/x.plist"
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_bootout "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "a loaded job whose plist is gone is removed (rc=0)"
assert_contains "$(calls)" "bootout gui/$(id -u)/$LABEL" "…via the service-target form, which the ownership guard has just made safe"
if is_loaded; then bad "the job is still loaded after the removal"; else ok "the job is gone afterwards (asserted)"; fi


echo "-- H. a crash-looping job is caught, not blessed"
fresh "$(( $(date +%s) - 5 ))"
export LC_SETTLE=1
# FAKE_THROTTLE=1 so a 1s window can observe a respawn at all; the SHIPPED default window is derived
# from launchd's own throttle (see D6), not from this test knob.
export FAKE_CRASHLOOP=1 FAKE_THROTTLE=1 FAKE_MIN_RUNTIME=1
out="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 3 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a relaunching job is NOT reported as 'already running' (non-zero)"; else bad "a crash-looping controller was blessed as healthy"; fi
assert_contains "$out" "RELAUNCHED" "the message names the relaunch instead of a stale heartbeat"
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 1 3 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a start that lands on a crash loop returns NON-ZERO"; else bad "a crash-looping start returned 0"; fi
assert_contains "$(calls)" "bootout" "…and it really did try (the bootout happened, the assertion is what failed)"
unset FAKE_CRASHLOOP LC_SETTLE FAKE_THROTTLE FAKE_MIN_RUNTIME

# ── I. TEMP HOME (#446) ────────────────────────────────────────────────────────────────────────
# A run whose $HOME is not the real home registers/removes jobs in the REAL user's domain. This is a
# recorded decision with a shipped implementation (scripts/install-launchd.sh:380-403) and the same
# opt-in; the `dscl` stub is what makes the guard testable off-macOS.
echo "-- I. a temp HOME refuses to mutate launchd (agent-infra#446)"
mkdir -p "$T/dsclbin"
cat > "$T/dsclbin/dscl" <<'DSHIM'
#!/usr/bin/env bash
printf 'NFSHomeDirectory: /Users/real-person\n'
DSHIM
chmod +x "$T/dsclbin/dscl"
fresh
out="$( env HOME="$T/sandbox-home" PATH="$T/dsclbin:$PATH" bash -c '. "$1"; lc_bootout "$2" "$3"' _ "$LIB" "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a sandbox HOME makes bootout REFUSE (non-zero)"; else bad "a sandbox HOME mutated launchd"; fi
assert_contains "$out" "is not the real home" "the refusal says why (HOME vs the real home)"
assert_contains "$out" "ELDATO_ALLOW_TEST_HOME" "…and names the escape hatch a TEST uses"
assert_not_contains "$(calls)" "bootout" "no launchctl call was issued at all"
: > "$FAKE_LOG"
out="$( env HOME="$T/sandbox-home" ELDATO_ALLOW_TEST_HOME=1 PATH="$T/dsclbin:$PATH" bash -c '. "$1"; lc_bootout "$2" "$3"' _ "$LIB" "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
assert_eq "$rc" "0" "ELDATO_ALLOW_TEST_HOME=1 is the documented opt-in and it works"

echo "-- I2. the guard compares the REAL home, not its SPELLING"
# A trailing slash or a symlink to the real home IS the real account; refusing it told the operator to
# "run it from your own account" while they already were (review finding: false block, false reason).
mkdir -p "$T/realhome" "$T/dsclreal"
ln -sfn "$T/realhome" "$T/realhome-link"
cat > "$T/dsclreal/dscl" <<DSHIM2
#!/usr/bin/env bash
printf 'NFSHomeDirectory: %s\n' "$T/realhome"
DSHIM2
chmod +x "$T/dsclreal/dscl"
fresh
for spelling in "$T/realhome" "$T/realhome/" "$T/realhome-link"; do
  : > "$FAKE_LOG"
  out="$( env HOME="$spelling" PATH="$T/dsclreal:$PATH" bash -c '. "$1"; lc_bootout "$2" "$3"' _ "$LIB" "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
  assert_eq "$rc" "0" "HOME=$spelling is the real account and is ALLOWED ($out)"
done


echo "-- H2. a start that does NOT replace the old process is caught"
# `launchctl bootstrap` can report success while launchd kept the old process. The old controller then
# keeps the OLD plist limits — and its pid plus a fresh heartbeat make the naive assertion pass.
fresh "$(( $(date +%s) - 5 ))"
( . "$LIB"; LC_SETTLE=1 lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
oldpid="$( . "$LIB"; lc_pid "$LABEL" )"
export FAKE_STALE_PID=1
out="$( . "$LIB"; LC_SETTLE=1 lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 1 3 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a start that leaves the old pid in place returns NON-ZERO"; else bad "a start that never replaced the process returned 0"; fi
assert_contains "$out" "NOT replaced" "the message says the job was not replaced (stale limits), not 'not cycling'"
assert_contains "$out" "pid $oldpid" "it names the surviving pid"
unset FAKE_STALE_PID

echo "-- D6. the relaunch window is derived from launchd's THROTTLE, not a constant"
# `man launchd.plist` ThrottleInterval: "jobs will not be spawned more than once every 10 seconds";
# `launchctl print` reports it as `minimum runtime = N`. An observation window shorter than N can never
# see a respawn — a 5s window was reviewed as systematically blind on the start path.
# ⛔ The DERIVATION is asserted from the source, not by timing: a wall-clock test of "a 5s window misses a
# 10s throttle, a 13s window catches it" depends on how long `sleep` actually takes on a loaded box, and
# the assertion it protects would then be flaky in the direction of passing. The behavioural half below
# stays, with a 1s throttle, so the fallback path itself is still exercised.
assert_contains "$(code_of "$LIB")" 'floor=$(( $(lc_min_runtime "$label") + 3 ))' "the window is derived from the job's own throttle (+3s margin)"
assert_contains "$(code_of "$LIB")" "minimum runtime = [0-9]" "lc_min_runtime reads launchd's own 'minimum runtime' field"
fresh "$(( $(date +%s) - 5 ))"
export FAKE_MIN_RUNTIME=1 FAKE_THROTTLE=1 FAKE_CRASHLOOP=1
export LC_SETTLE=abc      # a non-numeric value must NOT become a zero-width window
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
assert_eq "$( . "$LIB"; lc_min_runtime "$LABEL" )" "1" "lc_min_runtime reads the printed value (1 here)"
out="$( . "$LIB"; lc_assert_stable "$LABEL" "abc" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a NON-NUMERIC settle falls back to the derived window instead of a zero-width pass"; else bad "a non-numeric settle silently disabled the check"; fi
assert_contains "$out" "RELAUNCHED" "the message names the relaunch"
unset FAKE_CRASHLOOP FAKE_THROTTLE FAKE_MIN_RUNTIME LC_SETTLE

# ── E. the forbidden end state, across every driveable start scenario ───────────────────────────
echo "-- E. no forbidden end state in any start scenario"
drive() { # <name> <0|fail>
  local name="$1" expect="$2" rc
  out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 1 2 2>&1 )"; rc=$?
  assert_end_state "$rc" "$name"
  if [ "$expect" = "fail" ]; then
    if [ "$rc" -ne 0 ]; then ok "$name — a failed start REPORTS (rc=$rc)"; else bad "$name — exited 0 with no working controller"; fi
  else
    if [ "$rc" -eq 0 ]; then ok "$name — a good start returns 0"; else bad "$name — a good start returned $rc"; fi
  fi
}

fresh;                                                       drive "fresh box, healthy start" 0
fresh; export FAKE_BOOTSTRAP_FAIL=1;                         drive "bootstrap fails, load fallback" 0
fresh; export FAKE_BOOTSTRAP_FAIL=1 FAKE_LOAD_FAIL=1;        drive "bootstrap AND load fail" fail
fresh; export FAKE_NO_HB=1;                                  drive "loaded with a pid but no heartbeat" fail

# ── F. end-to-end install.sh ─────────────────────────────────────────────────────────────────────
echo "-- F. install.sh end to end"
# ⛔ NOT GATED ON macOS ANY MORE. The half that is genuinely platform-specific is `plutil -lint`, and on a
# Linux CI runner there is no plutil to run it — so the suite stubs it THERE and runs the rest, because
# the rest is the incident's own path (`--uninstall` and its read-back, `--start` and its proof, the
# flag refusal, "a plain run mutates nothing"). Leaving all of §F on the developer's mac meant a
# regression in that half shipped green through the only automated gate.
# ⛔ BUT IT DOES NEED A USABLE CHECKOUT, and that is the INSTALLER's requirement, not this suite's:
# install.sh stamps provenance from `REPO` and refuses anything that is not a git checkout. That holds in
# CI (a plain clone) and in this worktree on a mac. It does NOT hold for a read-only container mount of a
# LINKED worktree, whose `.git` is a FILE pointing outside the mount — the installer correctly refuses
# there, so this section SKIPS (loudly, naming the reason) instead of reporting ~27 failures that are all
# the same missing checkout. A skip is never a pass; the reason is printed.
if ! git -C "$(cd "$HARNESS/../.." && pwd)" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  skipd "§F install.sh end to end — SKIPPED: $(cd "$HARNESS/../.." && pwd) is not a usable git checkout here (install.sh stamps provenance from it); this half runs in CI and on a normal clone"
else
if [ "$PLATFORM" != "Darwin" ]; then
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/plutil"; chmod +x "$T/bin/plutil"
  STUBBED_PLUTIL=1
  export ELDATO_ALLOW_NON_DARWIN=1   # install.sh's real platform gate, bypassed in this suite only
else
  STUBBED_PLUTIL=""
fi
# The installer is driven from a STAGE copy so it cannot reach this checkout's neighbours, and so
# the only scripts its `bash -n` sweep sees are the ones under test.
STAGE="$T/stage"; mkdir -p "$STAGE"
cp "$INSTALL" "$LIB" "$HARNESS/launchd.plist.template" "$STAGE/" 2>/dev/null
SHOME="$T/home"; mkdir -p "$SHOME/Library/LaunchAgents" "$SHOME/.local/share/pi-node/current/bin" \
  "$SHOME/.pi/agent/scripts"
# install.sh probes the real binaries: gh (network), tmux, pi, uv.
printf '#!/bin/bash\nexit 0\n' > "$T/bin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/tmux"
printf '#!/bin/bash\nexit 0\n' > "$SHOME/.local/share/pi-node/current/bin/pi"
chmod +x "$T/bin/gh" "$T/bin/tmux" "$SHOME/.local/share/pi-node/current/bin/pi"
PLIST="$SHOME/Library/LaunchAgents/$LABEL.plist"
# The stub reports the loaded job's `path =` as the plist the installer rendered (passed per call in
# ORUN, because each scenario starts from `fresh`), so the ownership guard (G) sees OUR job. Without
# it the stub would claim `$T/o/x.plist` and every §F run would correctly refuse.
ORUN() { # <extra args…>
  # ⛔ ELDATO_ALLOW_TEST_HOME=1 is the #446 guard's documented opt-in: this HOME is a sandbox, so the
  # run WOULD otherwise (correctly) refuse to touch launchd. With it, the `launchctl` stub on PATH is
  # what stands in for the real domain — no real job is registered or removed by this suite.
  env HOME="$SHOME" O="$T/o" REPO="$(cd "$HARNESS/../.." && pwd)" OR="acme/widget" \
    ELDATO_ALLOW_TEST_HOME=1 LC_SETTLE=1 START_TIMEOUT=2 FAKE_PLIST="$PLIST" \
    PATH="$SHOME/.local/share/pi-node/current/bin:$T/bin:$PATH" \
    bash "$STAGE/install.sh" "$@"
}
mutating() { mutating_calls; }   # ONE definition (the two drifted apart once already)

fresh
out="$(ORUN 2>&1)"; rc=$?
assert_eq "$rc" "0" "plain install exits 0"
[ -f "$PLIST" ] && ok "plain install rendered the plist" || bad "plain install rendered no plist"
if [ -z "$(mutating)" ]; then ok "plain install made ZERO mutating launchctl calls (a validation run cannot disturb a live controller)"
else bad "plain install MUTATED launchd: $(mutating)"; fi
if [ -n "${STUBBED_PLUTIL:-}" ]; then
  ok "plutil was STUBBED on this platform — the XML-lint half of this section is not exercised here, the launchd half is"
fi

# --start with a healthy box: the job comes up and the start is PROVEN.
fresh "$(( $(date +%s) - 5 ))"
out="$(ORUN --start 2>&1)"; rc=$?
assert_eq "$rc" "0" "--start on a fresh box exits 0"
is_loaded && ok "--start left the job loaded" || bad "--start did not load the job"
assert_contains "$out" "heartbeat advanced" "--start VERIFIED the heartbeat advanced"

# --start where bootstrap AND load fail: MUST be non-zero, with one actionable line.
fresh
export FAKE_BOOTSTRAP_FAIL=1 FAKE_LOAD_FAIL=1
out="$(ORUN --start 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a failed --start exits NON-ZERO (the old installer exited 0 here)"; else bad "a failed --start exited 0"; fi
assert_contains "$out" "could not load $LABEL" "the failure prints one actionable line naming the label"
assert_contains "$out" "Next: launchctl print" "…and names the next command to run"
assert_eq "$(violations)" "" "the failed start wrote no persistent disable"

# --start where the job comes up but NEVER cycles: also non-zero, and the message distinguishes
# "no pid" from "pid but no heartbeat" (they have different remedies).
fresh
export FAKE_NO_HB=1
out="$(ORUN --start 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "loaded-but-not-cycling --start exits NON-ZERO"; else bad "loaded-but-not-cycling exited 0"; fi
assert_contains "$out" "running but NOT cycling" "the message distinguishes 'not cycling' from 'not running'"

# --start on a HEALTHY live job with an UNCHANGED plist: left alone.
fresh "$(( $(date +%s) - 5 ))"
out="$(ORUN --start 2>&1)"; rc=$?
assert_eq "$rc" "0" "second --start exits 0"
: > "$FAKE_LOG"
out="$(ORUN --start 2>&1)"; rc=$?
assert_eq "$rc" "0" "idempotent --start exits 0"
if [ -z "$(mutating)" ]; then ok "an unchanged, healthy box is NOT disturbed by --start"
else bad "--start disturbed a healthy unchanged controller: $(mutating)"; fi
assert_contains "$out" "left untouched" "…and says so"
  # ⛔ AND THE BANNER MUST NOT CLAIM A START (review finding): this run made zero mutating calls, so
  # "this run started it and PROVED it" is a process claim with no artifact behind it.
  assert_not_contains "$out" "started it and PROVED it" "the banner does NOT claim this run started it"
  assert_contains "$out" "VERIFIED it" "…it says the run VERIFIED a job it left alone"

  # ⛔ THE STALE-RENDER RELOAD (review finding): a plain install OVERWRITES the plist without reloading
  # the job. Comparing the render to the FILE then says "unchanged" on the next --start, which would
  # skip the reload it exists to perform and exit 0 with the old settings still live.
  fresh "$(( $(date +%s) - 5 ))"
  MAX_LANES=5 ORUN --start >/dev/null 2>&1
  out="$(MAX_LANES=7 ORUN 2>&1)"                       # plain run: writes the file, does not reload
  assert_contains "$out" "NOT on the rendered plist" "a plain run WARNS that the loaded job is stale"
  : > "$FAKE_LOG"
  out="$(MAX_LANES=7 ORUN --start 2>&1)"; rc=$?
  assert_eq "$rc" "0" "--start after a plain install exits 0"
  assert_contains "$(calls)" "bootout" "…and RELOADS the stale job (the file was unchanged, the job was not)"
  assert_contains "$out" "this run RELOADED it and PROVED it" "the banner says it RELOADED rather than started"
  assert_not_contains "$out" "printf " "no raw shell escaped into the banner text"

  # ⛔ AND AN ABSENT RECORD IS NOT "STALE". `$O/state/launchd-loaded.sha256` does not exist on any box
  # that has not run `--start` under this version, so the FIRST plain run of a healthy, byte-identical
  # install would otherwise tell the operator "it still uses the OLD settings" — and point at a
  # `--restart` of the production controller — from an absent file (review finding).
  fresh "$(( $(date +%s) - 5 ))"
  MAX_LANES=5 ORUN --start >/dev/null 2>&1
  rm -f "$T/o/state/launchd-loaded.sha256"
  out="$(MAX_LANES=5 ORUN 2>&1)"
  assert_contains "$out" "which render launchd loaded is UNKNOWN" "a MISSING record is reported as UNKNOWN"
  assert_not_contains "$out" "it still uses the OLD settings" "…and NOT as a measurement of staleness"
  assert_not_contains "$out" "--restart" "…nor does it point at a needless restart"

  # ⛔ AND AN UNREADABLE READ IS NOT "NOT RUNNING" (review finding): `lc_pid` alone is empty for both
  # "not loaded" and "the read failed", so the one run that cannot tell used to say the most.
  fresh "$(( $(date +%s) - 5 ))"
  ORUN --start >/dev/null 2>&1
  export FAKE_PRINT_FAIL=1
  out="$(ORUN 2>&1)"; rc=$?
  assert_contains "$out" "could NOT be read" "an unreadable domain is reported as UNKNOWN in the banner"
  assert_not_contains "$out" "The loop is NOT running" "…and NOT as 'the loop is NOT running'"
  # ⛔ A PLAIN RUN MUST NOT INVENT A WARNING (review finding): dropping `&& [ "$PLIST_CHANGED" = "1" ]`
  # from the warning guard survived the whole suite, and the mutant makes a validation run print "which
  # render launchd loaded is UNKNOWN (no … record yet)" while the record exists and MATCHES — sending the
  # operator to `--start`, the one path that can restart a healthy controller.
  unset FAKE_PRINT_FAIL
  fresh "$(( $(date +%s) - 5 ))"
  ORUN --start >/dev/null 2>&1
  out="$(ORUN 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok "a plain run on a current, healthy render exits 0"; else bad "a plain run on a current render failed: $out"; fi
  assert_not_contains "$out" "which render launchd loaded is UNKNOWN" "…and does NOT claim the loaded-render record is missing"
  assert_not_contains "$out" "NOT on the rendered plist" "…and does NOT warn about a stale render"

# an unknown flag must be REFUSED, not ignored: a typo'd --strt would otherwise install and exit 0.
out="$(ORUN --strt 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "an unknown flag is refused (non-zero)"; else bad "an unknown flag was silently accepted"; fi
assert_contains "$out" "unknown argument" "the refusal names the problem"

# --uninstall: bootout, PROVE the job is gone, then remove the plist.
fresh "$(( $(date +%s) - 5 ))"
ORUN --start >/dev/null 2>&1
: > "$FAKE_LOG"          # scope the assertion: only THIS command's calls count
out="$(ORUN --uninstall 2>&1)"; rc=$?
assert_eq "$rc" "0" "--uninstall exits 0 when the removal verifiably worked"
if is_loaded; then bad "--uninstall reported success but the job is STILL loaded"; else ok "--uninstall left the job NOT loaded (asserted, not assumed)"; fi
[ ! -f "$PLIST" ] && ok "--uninstall removed the plist" || bad "--uninstall left the plist"
assert_contains "$(calls)" "bootout" "--uninstall booted the job out"
assert_eq "$(violations)" "" "--uninstall wrote NO persistent disable (the next start is a plain start)"
assert_eq "$(service_target_bootouts)" "" "--uninstall removed by plist PATH, so a sandboxed HOME cannot boot out the live job"

# --uninstall where launchd REFUSES the removal (EIO — the incident's own error class): it must NOT
# print ✅, must NOT delete the plist (the only handle for a retry), and must exit non-zero.
fresh "$(( $(date +%s) - 5 ))"
ORUN --start >/dev/null 2>&1
export FAKE_BOOTOUT_FAIL=1
out="$(ORUN --uninstall 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a refused removal makes --uninstall exit NON-ZERO (it used to print ✅)"; else bad "--uninstall exited 0 over a job that is still loaded"; fi
assert_not_contains "$out" "✅ Removed" "it does not claim removal it could not verify"
assert_contains "$out" "bootout failed" "the failure carries launchd's own diagnostic"
[ -f "$PLIST" ] && ok "the plist is KEPT, so the removal can be retried/verified" || bad "--uninstall deleted its own only handle"

# …and where launchd LIES (reports success, job still loaded): the READ-BACK is what catches it.
fresh "$(( $(date +%s) - 5 ))"
ORUN --start >/dev/null 2>&1
export FAKE_BOOTOUT_LIE=1
out="$(ORUN --uninstall 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a claimed-but-failed removal still exits NON-ZERO (the read-back, not the status)"; else bad "--uninstall trusted 'launchctl bootout' exit 0 and reported success"; fi
assert_contains "$out" "STILL loaded" "the failure states the job is still loaded"
assert_not_contains "$out" "✅ Removed" "it does not print ✅ over a live job"

  # …and where the domain read BREAKS after the removal: an unreadable domain is not a removal, so the
  # plist must survive and the run must fail. This is the end-to-end half of §J (review finding).
  fresh "$(( $(date +%s) - 5 ))"
  ORUN --start >/dev/null 2>&1
  export FAKE_PRINT_FAIL_UNLOADED=1
  out="$(ORUN --uninstall 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "an UNVERIFIABLE removal exits NON-ZERO"; else bad "--uninstall exited 0 when the domain could not be read back"; fi
  assert_contains "$out" "cannot be VERIFIED" "the failure says the removal could not be VERIFIED"
  assert_contains "$out" "Input/output error" "…quoting launchd's own diagnostic"
  [ -f "$PLIST" ] && ok "the plist SURVIVES an unverifiable removal (the only handle a retry has)" \
    || bad "the plist was DELETED on an unverifiable removal"
  assert_not_contains "$out" "✅ Removed" "it does not print ✅ over a removal it could not read back"
  unset FAKE_PRINT_FAIL_UNLOADED

  # …and where launchd holds the job but reports no `path =` for it: the ownership guard must refuse AND
  # the read-back's verdict must still be "still loaded" (both come from the probe now).
  fresh "$(( $(date +%s) - 5 ))"
  ORUN --start >/dev/null 2>&1
  export FAKE_PRINT_NO_PATH=1
  out="$(ORUN --uninstall 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "a loaded-but-unattributable job makes --uninstall exit NON-ZERO"; else bad "--uninstall removed a job launchd could not attribute to our plist"; fi
  assert_contains "$out" "no plist path" "the refusal names the missing datum"
  [ -f "$PLIST" ] && ok "the plist is KEPT when the job cannot be shown to be ours" || bad "the plist was deleted for a job it could not attribute"
  assert_not_contains "$out" "✅ Removed" "it does not print ✅ here either"
  unset FAKE_PRINT_NO_PATH
fi

# ── J. an UNREADABLE launchd is NOT "not loaded" ────────────────────────────────────────────────
# `launchctl print` failing says NOTHING about whether the job exists. Flattening the two made
# `--uninstall` issue no bootout at all, the read-back see an empty read, and the installer print ✅ and
# DELETE the plist over a live KeepAlive controller — while the ownership guard was skipped for the same
# reason, so even `enable` (which has no path form) no longer required proof the job was ours.
echo "-- J. an unreadable domain refuses, and is never read as 'not loaded'"
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
( . "$LIB"; lc_probe "$LABEL" >/dev/null 2>&1 ); assert_eq "$?" "0" "lc_probe returns 0 for a LOADED job"
fresh
( . "$LIB"; lc_probe "$LABEL" >/dev/null 2>&1 ); assert_eq "$?" "1" "lc_probe returns 1 for launchd's own not-found answer (definitively absent)"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
export FAKE_PRINT_FAIL=1
( . "$LIB"; lc_probe "$LABEL" >/dev/null 2>&1 ); assert_eq "$?" "2" "lc_probe returns 2 when the read FAILED (unknown, not absent)"
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_bootout "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "an unreadable domain makes bootout REFUSE (non-zero)"; else bad "bootout reported success on an unreadable domain"; fi
assert_contains "$out" "could not be read" "the refusal says the read failed"
assert_not_contains "$(calls)" "bootout" "NO removal was issued"
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "an unreadable domain makes a start REFUSE (non-zero)"; else bad "it started on an unreadable domain"; fi
assert_not_contains "$(calls)" "enable" "enable was NOT issued over a job whose ownership could not be proven"
assert_not_contains "$(calls)" "bootstrap" "nothing was bootstrapped"
unset FAKE_PRINT_FAIL

# ⛔ A LOADED JOB WITH NO PARSABLE `path =` IS NOT "NO CLAIM TO CHECK" (review finding): an empty path is
# an absent DATUM, not a licence to skip the one precondition the guard exists for — with it skipped the
# caller issues a LABEL-keyed bootout, which is the sandbox hazard measured on 2026-10-17. And the
# `--uninstall` verdict must come from the PROBE, not from a second path read: `prc=0` already proves
# launchd still holds the label, so nothing after it may erase that.
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PRINT_NO_PATH=1
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_bootout "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a LOADED job with no plist path makes bootout REFUSE (non-zero)"; else bad "the ownership guard was skipped for a job launchd could not attribute to a plist"; fi
assert_contains "$out" "no plist path" "the refusal names the missing datum"
assert_not_contains "$(calls)" "bootout" "NO label-keyed removal was issued"
unset FAKE_PRINT_NO_PATH

# …and the same shape end to end: a loaded job whose block has no path line must make --uninstall exit
# NON-ZERO and keep the plist.
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
export FAKE_PRINT_NO_PATH=1
out="$( . "$LIB"; lc_bootout "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a loaded-but-unattributable job is never treated as removed"; else bad "an unattributable loaded job was reported removed"; fi
unset FAKE_PRINT_NO_PATH

# ⛔ `Bad request.` ALONE IS NOT launchd's not-found answer: it is a DOMAIN-level rejection, and widening
# the absent set is exactly backwards for a tri-state whose rule is "unrecognised ⇒ UNKNOWN".
fresh
export FAKE_PRINT_BADONLY=1
( . "$LIB"; lc_probe "$LABEL" >/dev/null 2>&1 ); assert_eq "$?" "2" "'Bad request' alone reads as UNKNOWN, not as absent"
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_bootout "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "an unknown domain diagnostic makes bootout REFUSE (non-zero)"; else bad "an unrecognised diagnostic was read as 'not loaded'"; fi
unset FAKE_PRINT_BADONLY

# ⛔ A DOMAIN-LEVEL REJECTION IS UNKNOWN, NOT "NO SUCH SERVICE" (review finding): launchd prints the
# SAME `Could not find` prefix for `Could not find domain for user gui: N` (measured on this box), which
# says nothing about the service. Matching the bare prefix made `lc_probe` return "definitively absent",
# so `bootout` issued NO removal and `--uninstall` printed ✅ and deleted the plist over a loaded job —
# reachable as `sudo bash install.sh --uninstall` (id -u 0 → gui/0 → exactly that text).
fresh
export FAKE_PRINT_DOMAIN=1
( . "$LIB"; lc_probe "$LABEL" >/dev/null 2>&1 ); assert_eq "$?" "2" "'Could not find domain for user gui' reads as UNKNOWN, not absent"
: > "$FAKE_LOG"
out="$( . "$LIB"; lc_bootout "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "…so a broken domain makes bootout REFUSE (non-zero)"; else bad "a domain-level rejection was converted into a successful removal"; fi
unset FAKE_PRINT_DOMAIN

# ⛔ THE SECOND 'runs' READ IS THE MEASUREMENT (review finding): `lc_runs` is empty both when the job is
# gone and when the read FAILED (EIO — this box's normal failure), so `[ -n "$r1" ] && …` fell through to
# `return 0` and CERTIFIED a crash loop exactly when launchd was flaky.
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
unset FAKE_PRINT_FAIL_ON
: > "$FAKE_STATE/printcalls"
export FAKE_PRINT_FAIL_ON=3          # 1 = lc_min_runtime, 2 = r0, 3 = the second (r1) read
out="$( . "$LIB"; LC_SETTLE=1 lc_assert_stable "$LABEL" 1 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "an UNREADABLE second 'runs' read is not certified as stable (non-zero)"; else bad "a failed second read was read as 'not relaunching'"; fi
assert_contains "$out" "could not be read a second time" "…and the message names the failed READ, not a missing pid"
unset FAKE_PRINT_FAIL_ON

# …and the sibling shape: the service genuinely VANISHES mid-window (a concurrent --uninstall from another
# pane, routine in this fleet) — also unproven, and named as disappearance rather than as a bad read.
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
: > "$FAKE_STATE/printcalls"
export FAKE_SERVICE_GONE_ON=3
out="$( . "$LIB"; LC_SETTLE=1 lc_assert_stable "$LABEL" 1 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a job that leaves the domain mid-window is not certified as stable"; else bad "a vanished job was read as 'not relaunching'"; fi
assert_contains "$out" "left the domain" "…and the message says it VANISHED, not that a read failed"
unset FAKE_SERVICE_GONE_ON

# ⛔ AN EMPTY `HOME` IS NOT THE REAL HOME — AND `cd ""` SUCCEEDS (review finding): bash leaves $PWD
# unchanged, so `home_real` became the CURRENT DIRECTORY and an operator standing in their own home
# PASSED the #446 guard while $HOME was empty. Reproduced from `cd ~` — the commonest cwd there is.
fresh
out="$( cd "$HOME" && env -u ELDATO_ALLOW_TEST_HOME HOME= PATH="$T/bin:$PATH" \
  bash -c '. "$1"; lc_bootout "$2" "$3"' _ "$LIB" "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "HOME='' is REFUSED even from the real home (rc non-zero)"; else bad "an empty HOME passed the #446 guard from cwd=home"; fi
assert_contains "$out" "HOME is empty" "…by the HOME guard, named as such (not by the ownership check)"
assert_not_contains "$(calls)" "bootout" "…and NO label-keyed removal was issued"

# ⛔ THE OPERATOR'S LAST LEVER MUST NOT HANG (review finding): `lc_hb_value` had no `-f` guard, so a
# non-regular `$O/heartbeat` BLOCKED ON OPEN — and it is read BEFORE the start, so `install.sh --start`
# (the documented remedy while the controller is down) hung with no output at all.
rm -f "$T/o/heartbeat"; mkfifo "$T/o/heartbeat" 2>/dev/null || true
if [ -p "$T/o/heartbeat" ]; then
  # ⛔ THE PROBE IS BOUNDED *AND* ITS OUTPUT NEVER GOES THROUGH A PIPE: a `$( … )` here would wait on
  # every writer of that pipe, and a mutant that blocks inside `tr < fifo` leaves an ORPHANED tr holding
  # it — the assertion would then hang instead of going red (measured: the suite blocked >200s). The
  # alarm kills the probe; the file redirect keeps the orphan off the capture path.
  perl -e 'alarm 10; exec @ARGV' bash -c '. "$1"; lc_hb_value "$2"' _ "$LIB" "$T/o" > "$T/hb.fifo.out" 2>&1
  rc=$?; out="$(cat "$T/hb.fifo.out")"
  assert_eq "$rc" "0" "lc_hb_value on a FIFO returns instead of blocking (a hang would be 142/124)"
  assert_eq "$out" "0" "…and reports the value as UNKNOWN (0)"
fi
rm -f "$T/o/heartbeat"; printf '1\n' > "$T/o/heartbeat"

# ── K. the refusal must be PRINTED under the CALLER's shell options ──────────────────────────────
# launchd-cycle.sh is SOURCED into install.sh's `set -euo pipefail`. An unguarded `x="$(cd … && pwd -P)"`
# therefore aborts the CALLER mid-function: the refusal line is never printed, `2>/dev/null` swallows
# `cd`'s own error, and an operator recovering a dead controller sees an exit code and NO output.
echo "-- K. the guard's refusal survives a \`set -e\` caller"
fresh
out="$( env -u ELDATO_ALLOW_TEST_HOME HOME="$T/no-such-home" PATH="$T/dsclbin:$PATH" \
  bash -c 'set -euo pipefail; . "$1"; lc_guard_mutate "$2" "$3"' _ "$LIB" "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a missing HOME makes the guard REFUSE under \`set -e\` (non-zero)"; else bad "the guard returned 0 with a missing HOME"; fi
assert_contains "$out" "is not the real home" "…and the refusal is actually PRINTED (not swallowed by set -e)"
assert_not_contains "$(calls)" "bootout" "no launchctl call was issued"

# ── N. an UNREADABLE account record is not "no check needed" ────────────────────────────────────
# `dscl` absent (Linux) and `dscl` FAILING are different states: the first has no gui domain to protect,
# the second means the #446 check cannot decide — and skipping the check there is how a sandboxed run
# registers a job against a throwaway $HOME in the REAL domain.
echo "-- N. an unreadable account record refuses instead of skipping the #446 guard"
mkdir -p "$T/dsclfail" "$T/dscljunk"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/dsclfail/dscl"
printf '#!/usr/bin/env bash\nprintf "something else\\n"\n' > "$T/dscljunk/dscl"
chmod +x "$T/dsclfail/dscl" "$T/dscljunk/dscl"
for bad in "$T/dsclfail" "$T/dscljunk"; do
  fresh
  out="$( env -u ELDATO_ALLOW_TEST_HOME HOME="$T/whatever" PATH="$bad:$PATH" \
    bash -c '. "$1"; lc_guard_mutate "$2" "$3"' _ "$LIB" "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "$(basename "$bad"): an unreadable home REFUSES (non-zero)"; else bad "$(basename "$bad"): the #446 guard was silently skipped"; fi
  assert_contains "$out" "could not be read" "$(basename "$bad"): the refusal names the failed read"
done

# ── N2. a PARSED-BUT-EMPTY account record is not "the real home" ─────────────────
# `cd ""` SUCCEEDS and leaves $PWD, so a blank `NFSHomeDirectory` made the guard's "real home" the CURRENT
# DIRECTORY — and a sandboxed run written the usual way (`cd "$SANDBOX"; HOME="$SANDBOX" …`) then PASSED
# the #446 guard. Same trap as an empty $HOME, one layer down.
echo "-- N2. a blank NFSHomeDirectory cannot become 'the real home'"
mkdir -p "$T/dsclempty"
printf '#!/usr/bin/env bash\nprintf "NFSHomeDirectory: \\n"\n' > "$T/dsclempty/dscl"
chmod +x "$T/dsclempty/dscl"
fresh; mkdir -p "$T/sandbox2"
out="$( cd "$T/sandbox2" && env -u ELDATO_ALLOW_TEST_HOME HOME="$T/sandbox2" PATH="$T/dsclempty:$PATH" \
  bash -c '. "$1"; lc_guard_mutate "$2" "$3"' _ "$LIB" "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a blank NFSHomeDirectory REFUSES even with cwd=\$HOME (non-zero)"; else bad "a blank NFSHomeDirectory became 'the real home' and the guard passed"; fi
assert_contains "$out" "real home" "…and the refusal is the HOME guard"
assert_contains "$out" "could not be read" "…from the ACCOUNT read (the lc_real_home layer, not only the belt that rejects an EMPTY account home)"
assert_not_contains "$(calls)" "bootout" "…and nothing was removed"

# ── L. a FUTURE-dated heartbeat must not poison the start-proof baseline ─────────────────────────
# The proof is `cur > before`. A future-dated file (clock correction, foreign clock, corruption) makes
# that target unreachable, so a HEALTHY start is reported as "running but NOT cycling" — with the wrong
# remedy, and once per `--restart` retry, because each retry boots the controller out first.
echo "-- L. a future heartbeat reads as UNKNOWN, in the age AND in the advance baseline"
fresh
printf '%s\n' "$(( $(date +%s) + 86400 ))" > "$T/o/heartbeat"
assert_eq "$( . "$LIB"; lc_hb_value "$T/o" )" "0" "lc_hb_value reads a future heartbeat as UNKNOWN (0), not as a huge target"
export FAKE_HB_EPOCH=1 LC_SETTLE=1
out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 1 3 2>&1 )"; rc=$?
assert_eq "$rc" "0" "a future-dated baseline does not make a healthy start look dead"
assert_contains "$out" "and the heartbeat advanced" "…the start is reported as verified"
unset FAKE_HB_EPOCH LC_SETTLE

# ── M. a non-numeric START_TIMEOUT must not zero the poll ────────────────────────────────────────
# `[ "$i" -lt "abc" ]` ERRORS, so the loop body never runs and every start fails after ZERO
# observations ("has NO pid abcs after the start") — the same defect lc_assert_stable had, in the
# parameter that gates the operator's recovery command.
echo "-- M. a non-numeric timeout falls back to a real window"
fresh
out="$( . "$LIB"; lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 1 abcs 2>&1 )"; rc=$?
assert_eq "$rc" "0" "a non-numeric START_TIMEOUT still starts and VERIFIES (no zero-width poll)"
assert_contains "$out" "and the heartbeat advanced" "…and the assertion really ran"
assert_not_contains "$out" "abcs" "the diagnostic does not quote the garbage value back as a duration"



# ── N3. `lc_ensure` must not score an unreadable read as "not loaded" ───────────────────────────
# This is the read the whole property starts with: if it fails, "already running and current" is
# unproven, and treating it as "not loaded" makes `--start` MUTATE a healthy controller on one transient
# EIO. The mutant `pid="$(lc_pid "$label")"` survived the suite until this case existed.
echo "-- N3. an unreadable read at lc_ensure refuses instead of starting"
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
: > "$FAKE_STATE/printcalls"
export FAKE_PRINT_FAIL_ON=2          # 1 = the guard's read, 2 = lc_ensure's own read
: > "$FAKE_LOG"
out="$( . "$LIB"; LC_SETTLE=1 lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 2 2>&1 )"; rc=$?
unset FAKE_PRINT_FAIL_ON
if [ "$rc" -ne 0 ]; then ok "an unreadable lc_ensure read exits NON-ZERO"; else bad "an unreadable read was scored as 'not loaded' and the start went ahead"; fi
assert_contains "$out" "could not be read" "…and names the failed read"
assert_not_contains "$(calls)" "bootstrap" "…and NOTHING was mutated (no bootstrap over a live job)"

# ── P. the ENABLE is verified: all four answers of `print-disabled` ─────────────────
echo "-- P. the persistent Disable override is read back, and all six fixtures behave"
# SIX fixtures, FOUR states:
#   healthy  — `enabled`, `unset` (no line for our label: the state of a box with no override at all),
#              `silent` (exit 0, empty output — also "no override"; a successful-but-empty answer is an
#              ANSWER, and scoring it UNKNOWN is the false alarm the split exists to remove);
#   refused  — `disabled`;
#   unknown  — `fail` (the verb failed), `garbage` (an entry we cannot classify).
# The three healthy ones must be SILENT: a healthy box that warns about itself is the failure mode.
for pd in enabled unset silent disabled fail garbage; do
  fresh
  export FAKE_PD="$pd"
  : > "$FAKE_LOG"
  out="$( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
  case "$pd" in
    enabled|unset|silent)
      if [ "$rc" -eq 0 ]; then ok "print-disabled='$pd' loads the job (rc=0)"; else bad "print-disabled='$pd' refused a healthy start: $out"; fi
      assert_not_contains "$out" "could not read whether" "…with no unreadable-answer warning"
      assert_contains "$(calls)" "bootstrap" "…and it really bootstrapped" ;;
    disabled)
      if [ "$rc" -ne 0 ]; then ok "print-disabled='disabled' REFUSES the load (rc non-zero)"; else bad "an override that did not clear was loaded anyway"; fi
      assert_contains "$out" "still reads 'disabled'" "…and the refusal names the override"
      assert_not_contains "$(calls)" "bootstrap" "…and NOTHING was loaded"
      assert_not_contains "$(calls)" "bootout" "…and the live job was not booted out either"
      # `print-disabled` is READ-ONLY (launchd-cycle.sh's own doctrine). It sits on lc_start's success
      # path, so a filter that does not exclude it makes a read look like a mutation to every future
      # "zero mutating calls" assertion.
      # `assert_not_contains` alone passes whether or not `lc_start` ever reads it, so name the read too.
      assert_contains "$(calls)" "print-disabled" "…and the enable really was READ BACK"
      assert_not_contains "$(mutating_calls)" "print-disabled" "…and the read-back is not scored as a mutation" ;;
    fail|garbage)
      if [ "$rc" -eq 0 ]; then ok "print-disabled='$pd' warns and CONTINUES (the bootstrap is the proof)"; else bad "an unreadable override was a false block: $out"; fi
      assert_contains "$out" "could not read whether" "…and it says the answer was unusable"
      assert_contains "$(calls)" "bootstrap" "…and the start still happened" ;;
  esac
done
unset FAKE_PD
# `kickstart` STARTS the job (and `-k` restarts it), so it must never be filtered out of a
# "zero mutating calls" assertion — the library does not call it today, and this keeps that true if it
# ever does. (Review finding: the filter excluded it, so such an assertion could not fail.)
: > "$FAKE_LOG"
printf '%s\n' "kickstart gui/501/$LABEL --kill" >> "$FAKE_LOG"
assert_contains "$(mutating_calls)" "kickstart" "kickstart IS counted as a mutation (it starts the job)"
: > "$FAKE_LOG"

# ── Q. an ABSENT heartbeat is not a duration ──────────────────────────────────────────
# `lc_hb_age` returns EMPTY when the file is missing or unparseable. Rendering that as
# "${age:-unreadable}s old" asserted "running but not cycling" from a value never read, and pointed at
# `--restart` — a mutating remedy — on a controller that may be healthy.
echo "-- Q. a missing heartbeat refuses instead of claiming 'not cycling'"
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
rm -f "$T/o/heartbeat"
: > "$FAKE_LOG"
out="$( . "$LIB"; LC_SETTLE=1 lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 2 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a MISSING heartbeat refuses (non-zero)"; else bad "an absent datum was rendered as a staleness measurement"; fi
# The substring names the DATUM, not just the phrase: `lc_guard_mutate` and `lc_probe` refuse with
# "could not be read" too, so a generic match would keep passing if the probe or the guard were what
# actually refused in this fixture (review finding).
assert_contains "$out" "heartbeat is missing, is not a regular file" "…and names the MISSING heartbeat specifically"
assert_not_contains "$out" "running but not cycling" "…and does NOT claim the controller is wedged"
assert_not_contains "$out" "unreadables old" "…and never prints a value it did not read"

# An EMPTY or DIGITS-FREE heartbeat is PRESENT and unusable — it must not be reported as missing. These
# two cases are what pin the arm's `[ -f ]` guard: `[ -s ]` would send an existing, zero-length file down
# the missing arm and tell the operator it does not exist.
for fixture in empty garbage; do
  fresh "$(( $(date +%s) - 5 ))"
  ( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
  case "$fixture" in
    empty)   : > "$T/o/heartbeat" ;;
    garbage) printf 'n/a\n' > "$T/o/heartbeat" ;;
  esac
  : > "$FAKE_LOG"
  out="$( . "$LIB"; LC_SETTLE=1 lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 2 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ]; then ok "an ${fixture} heartbeat refuses (non-zero)"; else bad "an unusable datum was accepted as a duration"; fi
  assert_contains "$out" "is PRESENT but is not a usable instant" "…(${fixture}) named as PRESENT-and-unusable"
  assert_not_contains "$out" "is missing, is not a regular file" "…(${fixture}) and NOT called missing"
  assert_not_contains "$out" "unreadables old" "…(${fixture}) and no fabricated duration"
done

# A heartbeat that is PRESENT but not a usable instant is a different operator problem (a clock step),
# and `lc_hb_age` returns empty for it too. Naming it "missing" would send the operator to `ls -l` on a
# file they can see.
fresh "$(( $(date +%s) - 5 ))"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
printf '%s\n' "$(( $(date +%s) + 86400 ))" > "$T/o/heartbeat"
: > "$FAKE_LOG"
out="$( . "$LIB"; LC_SETTLE=1 lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 2 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ok "a FUTURE-dated heartbeat refuses too (non-zero)"; else bad "a future instant was accepted as a duration"; fi
assert_contains "$out" "is PRESENT but is not a usable instant" "…and it does NOT call a present file 'missing'"
assert_not_contains "$out" "is missing, is not a regular file" "…(the missing wording stays off this arm)"
assert_not_contains "$out" "running but not cycling" "…and it does not claim the controller is wedged"

# ── O. the last empty-is-falsy traps ─────────────────────────────────────────────────────────────
echo "-- O. a SILENT unreadable read-back, a FIFO lock, hostile LC_HB_STALE, a symlinked plist"
# F1: `lc_probe` returns UNKNOWN (2) with EMPTY output whenever `launchctl print` exits non-zero and
# prints nothing. Storing that in the `unread` FLAG made it "" — and "" is falsy, so `--uninstall` fell
# through to `rm -f` + "✅ Removed" over a job launchd still held.
fresh "$(( $(date +%s) - 5 ))"
# The RENDERED plist path is what install.sh will act on, and the loaded job must be THAT file — otherwise
# the run refuses at the ownership guard and never reaches the read-back at all.
PLISTO="$T/o/home/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$(dirname "$PLISTO")"; : > "$PLISTO"
export FAKE_PLIST="$PLISTO"
( . "$LIB"; lc_start "$LABEL" "$PLISTO" >/dev/null 2>&1 )
: > "$FAKE_STATE/printcalls"
export FAKE_PRINT_SILENT_ON=3          # guard 1, bootout pre-check 2, the read-back 3
out="$( env ELDATO_ALLOW_TEST_HOME=1 HOME="$T/o/home" O="$T/o" REPO="$T/repo" OR="acme/widget" \
  PATH="$T/bin:$PATH" LC_SETTLE=1 START_TIMEOUT=2 FAKE_PLIST="$PLISTO" \
  bash "$INSTALL" --uninstall 2>&1 )"; rc=$?
unset FAKE_PRINT_SILENT_ON
if [ "$rc" -ne 0 ]; then ok "a SILENT unknown read-back makes --uninstall exit NON-ZERO"; else bad "an empty-output unknown read was scored as 'removed'"; fi
assert_contains "$out" "could not be read" "…and it names the failed read"
assert_not_contains "$out" "✅ Removed" "…and does not print ✅"
[ -f "$PLISTO" ] && ok "…and the plist is KEPT" || bad "the plist was deleted on an unverified removal"

# …and where `bootout` LIES about a job that has NO pid: the verdict must come from the PROBE, not from a
# pid test. A KeepAlive job inside its respawn throttle is loaded with no pid, so a pid-derived verdict
# prints "Removed" and deletes the plist over a live job — and a SOURCE GREP for `held=1` cannot tell the
# two apart (review finding: the mutant `[ -n "$held" ]` → `[ -n "$pid" ]` survived the whole suite).
fresh "$(( $(date +%s) - 5 ))"
PLISTN="$T/o/home2/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$(dirname "$PLISTN")"; : > "$PLISTN"
export FAKE_PLIST="$PLISTN"
( . "$LIB"; lc_start "$LABEL" "$PLISTN" >/dev/null 2>&1 )
export FAKE_BOOTOUT_LIE_NOPID=1
out="$( env ELDATO_ALLOW_TEST_HOME=1 HOME="$T/o/home2" O="$T/o" REPO="$T/repo" OR="acme/widget" \
  PATH="$T/bin:$PATH" LC_SETTLE=1 START_TIMEOUT=2 FAKE_PLIST="$PLISTN" \
  bash "$INSTALL" --uninstall 2>&1 )"; rc=$?
unset FAKE_BOOTOUT_LIE_NOPID
if [ "$rc" -ne 0 ]; then ok "a lying bootout over a loaded-NO-PID job makes --uninstall exit NON-ZERO"; else bad "a pid-derived verdict removed a job launchd still held (no pid)"; fi
assert_contains "$out" "STILL loaded" "…and it says the label is still loaded"
assert_not_contains "$out" "✅ Removed" "…and does NOT print ✅"
[ -f "$PLISTN" ] && ok "…and the plist is KEPT" || bad "the plist was deleted over a job that is still loaded"

# …and the settle window can still flip the verdict: launchd keeps printing the job for one read after a
# successful bootout (the lag the retry loop exists for), then forgets it. `held` must be the LAST
# observation, so this ends as a VERIFIED removal — a sticky flag refused the operator's own handoff.
fresh "$(( $(date +%s) - 5 ))"
PLISTL="$T/o/home3/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$(dirname "$PLISTL")"; : > "$PLISTL"
export FAKE_PLIST="$PLISTL"
( . "$LIB"; lc_start "$LABEL" "$PLISTL" >/dev/null 2>&1 )
export FAKE_BOOTOUT_LAG=1
out="$( env ELDATO_ALLOW_TEST_HOME=1 HOME="$T/o/home3" O="$T/o" REPO="$T/repo" OR="acme/widget" \
  PATH="$T/bin:$PATH" LC_SETTLE=1 START_TIMEOUT=2 FAKE_PLIST="$PLISTL" \
  bash "$INSTALL" --uninstall 2>&1 )"; rc=$?
unset FAKE_BOOTOUT_LAG
if [ "$rc" -eq 0 ]; then ok "a one-read removal LAG still ends as a verified removal (rc=0)"; else bad "a sticky verdict refused a removal that did happen: $out"; fi
assert_contains "$out" "✅ Removed" "…and prints ✅ once launchd has forgotten the label"

# F3: a non-regular $O/.orch.lock must not BLOCK the branch that runs when the job is absent — that is
# the operator's recovery path (`--start`), so a hang here has no output and no exit code at all.
fresh; rm -f "$T/o/.orch.lock"; mkfifo "$T/o/.orch.lock" 2>/dev/null || true
if [ -p "$T/o/.orch.lock" ]; then
  perl -e 'alarm 10; exec @ARGV' bash -c '. "$1"; lc_foreign_controller "$2"' _ "$LIB" "$T/o" > "$T/lock.out" 2>&1
  rc=$?; out="$(cat "$T/lock.out")"
  assert_eq "$rc" "0" "lc_foreign_controller on a FIFO lock returns instead of blocking"
  assert_eq "$out" "" "…and reports no foreign controller"
fi
rm -f "$T/o/.orch.lock"

# F5: `LC_HB_STALE` is a NUMBER, and a non-numeric one used to make `[ abc -le … ]` error — refusing a
# healthy controller with a stale-heartbeat claim that was not true, and pointing at a bootout+bootstrap.
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
out="$( . "$LIB"; LC_SETTLE=1 lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 2 abc 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then ok "LC_HB_STALE=abc falls back to the cell bound (a healthy job is left untouched)"; else bad "a non-numeric LC_HB_STALE refused a healthy controller: $out"; fi
assert_not_contains "$out" "integer expression expected" "…with no bash arithmetic error"
out="$( . "$LIB"; LC_SETTLE=1 lc_ensure "$LABEL" "$T/o/x.plist" "$T/o" 0 2 -5 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then ok "LC_HB_STALE=-5 falls back too"; else bad "a negative LC_HB_STALE refused a healthy controller"; fi

# F7: a stow/chezmoi-style SYMLINKED plist is the same FILE, so the ownership guard must accept it —
# comparing canonical DIRECTORIES alone refused an ordinary dotfiles layout and claimed the job came
# from somewhere else.
fresh
mkdir -p "$T/dotfiles"
printf 'x\n' > "$T/dotfiles/real.plist"
ln -sf "$T/dotfiles/real.plist" "$T/o/x.plist"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
export FAKE_PRINT_FILE="$T/o/print.symlink"
{ printf 'gui/0/%s = {\n\tactive count = 1\n\tpath = %s\n\tstate = running\n\n\truns = 1\n\tpid = 4242\n}\n' "$LABEL" "$T/dotfiles/real.plist"; } > "$FAKE_PRINT_FILE"
out="$( . "$LIB"; lc_guard_mutate "$LABEL" "$T/o/x.plist" 2>&1 )"; rc=$?
unset FAKE_PRINT_FILE
if [ "$rc" -eq 0 ]; then ok "a symlinked plist is accepted as the same FILE (stow/chezmoi layout)"; else bad "the ownership guard refused a symlinked plist: $out"; fi

# F4: the two messages that folded an absent datum into a measurement.
fresh
export FAKE_PRINT_NO_RUNS=1
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
out="$( . "$LIB"; LC_SETTLE=1 lc_assert_stable "$LABEL" 1 2>&1 )"; rc=$?
unset FAKE_PRINT_NO_RUNS
if [ "$rc" -ne 0 ]; then ok "a LOADED block with no 'runs' line refuses (non-zero)"; else bad "a missing 'runs' counter was certified"; fi
assert_contains "$out" "LOADED but launchd reported no 'runs' counter" "…and names the ABSENT datum instead of claiming the job is not loaded"
fresh "$(( $(date +%s) - 5 ))"
export FAKE_PLIST="$T/o/x.plist"
( . "$LIB"; lc_start "$LABEL" "$T/o/x.plist" >/dev/null 2>&1 )
export FAKE_PRINT_FAIL=1
out="$( . "$LIB"; lc_assert_running "$LABEL" "$T/o" 0 2 2>&1 )"; rc=$?
unset FAKE_PRINT_FAIL
if [ "$rc" -ne 0 ]; then ok "an unreadable domain after a start refuses (non-zero)"; else bad "an unreadable domain was scored as a start"; fi
assert_contains "$out" "could not be read" "…and the message names the failed read, not 'no pid'"
assert_not_contains "$out" "NO pid" "…it does not claim the label has no pid"
echo
if [ "$FAIL" -eq 0 ]; then
  printf '==> all %d checks passed (%d skipped)\n' "$PASS" "$SKIP"
  exit 0
fi
printf '==> %d passed, %d FAILED (%d skipped)\n' "$PASS" "$FAIL" "$SKIP"
exit 1
