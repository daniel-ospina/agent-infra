#!/usr/bin/env bash
# watchdog.test.sh — the contract for watchdog.sh (and its install wiring).
#
# THE DEFECT THIS GUARDS. The controller does not merely crash; it gets REMOVED. `launchctl unload -w`
# — and a `bootout` whose following `bootstrap` then fails — both leave a PERSISTENT disabled flag,
# and launchd's KeepAlive cannot restart a service that is no longer in the domain. Measured five
# times on 2026-10-17 (`Setting service … to disabled` → `removing service` → dead controller) with
# no error anywhere the fleet looks. The watchdog is the second agent that puts it back; it proved
# itself on the live box: ~/orchestrator/logs/watchdog.log holds five recoveries from 2026-10-17
# (e.g. `21:26:40Z ABSENT from launchctl — reloading` / `21:26:48Z recovered: pid=54673`).
#
# ⛔ WHAT MAKES IT SAFE IS WHAT IT DOES *NOT* DO. A 60-second agent that acted on a hunch would
# interrupt a controller mid-cycle and strand its lanes, its lock and its claim — the failure mode
# this harness has already paid for. So the two properties pinned here are:
#   * a PRESENT-AND-RUNNING service is left ALONE (no load, no bootstrap, no enable, not even a log
#     line), however many times the watchdog runs;
#   * the action is IDEMPOTENT — running it over and over on a healthy box is a no-op, and a
#     recovery that already succeeded is not repeated.
# And, because the recovery state IS the same state a human's deliberate stop produces, a declared
# stop (`$O/.watchdog-off`) must be honoured rather than reversed: without it, README §6's handoff
# ritual would be undone within a minute under a human who had just been told the box was safe.
#
# HOW THESE CHECKS ARE WRITTEN. Every check drives the SHIPPED script under a stubbed `launchctl`
# (never a re-implementation): the stub keeps a state file, records every invocation, and can be
# flipped to "the load took" — which is what the script's post-load verification reads. HOME and $O
# are sandboxed, so the real launchd domain is never touched.
#
# Run:  bash scripts/orchestrator-harness/watchdog.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$HERE/watchdog.sh"
TPL="$HERE/watchdog.plist.template"
INST="$HERE/install.sh"

PASS=0; FAIL=0; SKIPPED=0
# ⛔ THE SANDBOX LABEL IS A **TEST** LABEL (agent-infra#1996). `install.sh`'s `label_guard` refuses a
# PRODUCTION loop label on any `$HOME` but the invoking user's real one — correctly, because launchd
# resolves a label in the user domain and IGNORES `$HOME`. Every install.sh caller below passes this
# through the guard's own supported seam (`LABEL_OVERRIDE`), exactly as `selftest.sh` and
# `install-launchd-durability.test.sh` do, and every assertion on the rendered loop plist derives its
# name from it. (`WATCHDOG_LABEL` is a SEPARATE constant in install.sh and is not affected by the
# override, so the assertions on the watchdog plist path keep naming the production label.)
LOOP_LABEL_TEST="com.eldato.orchestrator-loop-test"
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/watchdog.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> watchdog contract ($HERE)"

[ -f "$WD" ] || { echo "  ❌ missing $WD"; exit 1; }
bash -n "$WD" 2>/dev/null && ok "watchdog.sh parses" || bad "watchdog.sh does not parse"

# ── the launchctl stub ──────────────────────────────────────────────────────────────────────────
# State lives in $S/state: absent | idle | running. The READ the shipped script makes is
# `print <domain>/<label>` (the shell-free, non-mutating read whose `pid = N` line sits at the TOP LEVEL
# of the block — the shape `launchd-cycle.sh`'s lc_pid pins against a captured real block), and it
# follows the REAL contract: exit 0 with a block when the service is in the domain, exit 113 with
# launchd's service-level not-found when it is not, and a `pid = <n>` line only while it is actually
# running. ⛔ THERE IS NO `list` ARM, deliberately: the shipped read is `print` (above), and an arm no
# caller exercises is dead code whose rationale claims a caller that does not exist — the defect the
# durability suite names in its own stub. Every call is appended to $S/calls, so a check can assert on
# what the script DID rather than on what it printed.
mk_state() {
  S="$T/case-$1"; mkdir -p "$S/bin" "$S/home/Library/LaunchAgents" "$S/o/logs"
  printf '%s\n' "$2" > "$S/state"
  # on_load: the state the service reaches once `load`/`bootstrap` is called (a working load reaches
  # running; a broken one stays absent, which is the case the script must report as FAILED).
  printf '%s\n' "${3:-running}" > "$S/on_load"
  cat > "$S/bin/launchctl" <<'SH'
#!/bin/bash
# STUB_DIR is the CASE directory; the state is $STUB_DIR/state and the call log $STUB_DIR/calls.
# (Passing the state FILE here instead made `cat "$S/state"` read a directory, so every case
# collapsed to "loaded but not running" — the stub must model the cases, not merge them.)
S="${STUB_DIR:?}"
printf '%s\n' "$*" >> "$S/calls"
# what the stub SAW when it answered — the state file is the only input to its verdict
printf '%s [state=%s]\n' "$*" "$(cat "$S/state" 2>/dev/null)" >> "$S/observed"
# ── the STATE READ: `launchctl print <domain>/<label>`, in launchd's real block shape ─────────────
# ⛔ THE SHAPE IS THE POINT (review finding). The shipped script parses `pid = N` at the TOP LEVEL of the
# service block — the parse `launchd-cycle.sh`'s `lc_pid` pins against a CAPTURED REAL BLOCK — because
# `launchctl list <label>`'s layout is what two shipped files disagreed about on main, and a parse that
# finds no pid in a HEALTHY controller would `kickstart -k` it every 60 seconds.
# `print_fail` models launchd being UNREADABLE (EIO): the message is not launchd's service-level
# not-found, so it must read as UNKNOWN and nothing may be acted on.
case "$1" in
print)
  _l="${2##*/}"
  if [ -f "$S/print_fail" ]; then echo "Print failed: 5: Input/output error" >&2; exit 5; fi
  # `badonly` models a BARE `Bad request.` — launchd rejecting the REQUEST, with no `Could not find
  # domain` line. The repo pins that as UNKNOWN (not absent): it says nothing about the service, so no
  # action verb may be issued on it.
  if [ -f "$S/badonly" ]; then echo "Bad request." >&2; exit 1; fi
  # `silent` models launchd exiting NON-ZERO WITH NO OUTPUT at all (killed, or re-exec'ing). It is the
  # empty-is-falsy shape: a reader that stores the DIAGNOSTIC as its "unknown" flag sees "" and reports
  # definitively ABSENT — then issues enable/bootstrap and logs `recovered:` over a read that established
  # nothing. The verdict must come from the STATUS, not from whether there is text to quote.
  if [ -f "$S/silent" ]; then exit 5; fi
  # `gui_domain_absent` models a box with NO `gui/<uid>` DOMAIN at all (an SSH-only session, or uid 0).
  # launchd answers a read in a domain that does not exist with `Bad request.` + `Could not find domain
  # for user gui: <uid>` — a DOMAIN-level rejection that says NOTHING about the service. Reading it as a
  # failed read made the agent permanently inert on those boxes, so this fixture exists to keep that
  # branch honest: the `user/` probe must still happen.
  case "${2:-}" in gui/*) [ -f "$S/gui_domain_absent" ] && { printf 'Bad request.\nCould not find domain for user gui: 1000\n' >&2; exit 1; } ;; esac
  # A job in the `user/` domain (a `launchctl bootstrap user/…` from an SSH session) is invisible to
  # `gui/`: the real launchctl answers a gui/ read with the service-level not-found, which is why the
  # script must try both domains rather than hardcode one.
  case "${2:-}" in gui/*) [ -f "$S/userdomain" ] && { echo "Could not find service \"$_l\" in domain for port" >&2; exit 113; } ;; esac
  _p="${PLIST_FOR_STUB:-$S/home/Library/LaunchAgents/$_l.plist}"
  case "$(cat "$S/state")" in
    absent) echo "Could not find service \"$_l\" in domain for port" >&2; exit 113 ;;
    running)
      # `flap`: answer RUNNING twice, then idle — a controller that dies inside the window between two
      # reads. ONE read for verdict+pid cannot tell the difference; TWO reads produce `recovered: pid=`
      # (empty) at rc 0, a false PASS, and this case reddens.
      if [ -f "$S/flap" ]; then
        n=$(( $(cat "$S/flaps" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$n" > "$S/flaps"
        if [ "$n" -gt 2 ]; then
          printf 'gui/0/%s = {\n\tactive count = 1\n\tpath = %s\n\tstate = not running\n}\n' "$_l" "$_p"; exit 0
        fi
      fi
      printf 'gui/0/%s = {\n\tactive count = 1\n\tpath = %s\n\tstate = running\n\n\tminimum runtime = 10\n\tpid = 4242\n}\n' "$_l" "$_p"
      # A writer killed by SIGPIPE after printing (rc 141) is what a `| grep -q` reader CAUSES: it exits
      # at its first match and closes the pipe. Forced here so the script's verdict is pinned
      # deterministically instead of by a buffer race (it used to flip 2 runs in 25).
      if [ -f "$S/sigpipe" ]; then kill -s PIPE $$ ; fi
      ;;
    idle) printf 'gui/0/%s = {\n\tactive count = 1\n\tpath = %s\n\tstate = not running\n}\n' "$_l" "$_p" ;;
  esac
  exit 0 ;;
esac
# A box whose job lives in the `user/` domain (what `launchctl load -w` does from an SSH session):
# every ACTION verb aimed at `gui/…` is refused, exactly as the real launchctl refuses it — so a script
# that hardcodes `gui/` cannot recover, which is the defect this models. The state read above is
# domain-SCOPED, so each domain is tried in turn — that is what makes the recovery work on a box whose
# job lives in `user/`.
case "$*" in *" gui/"*) [ -f "$S/userdomain" ] && exit 113 ;; esac
case "$1" in
  # ⛔ MODELLED ON THE MEASURED launchctl, not on what the script hopes for (review round 1).
  # `load`/`bootstrap` on a service that is ALREADY IN THE DOMAIN does NOT restart it: measured on
  # this box, `load -w` on an idle-but-loaded job prints "Load failed: 5: Input/output error" and
  # exits 0, and `bootstrap` exits 5 — neither brings the process back. Only `kickstart` does — and
  # WITHOUT `-k`: the kill form would kill a controller that launchd respawned between the read and the
  # verb, which is the one outcome this agent forbids.
  # A stub that started the job on any verb made the loaded-but-idle case pass over a recovery that
  # did not happen, which is the classic test-that-pins-the-attempt defect.
  load|bootstrap)
    case "$(cat "$S/state")" in
      absent)
        # `bootstrap_refused` models the MEASURED EIO: `bootstrap` prints "Bootstrap failed: 5:
        # Input/output error" and exits 5 with the job still absent — which is exactly the 2026-10-17
        # case where the LEGACY `load` is what brought the controller back (launchd-cycle.sh's
        # lc_start keeps that fallback for the same reason).
        [ "$1" = "bootstrap" ] && [ -f "$S/bootstrap_refused" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
        # `load_refused` models the MEASURED silent no-op: a refused `load` prints "Load failed: 5:
        # Input/output error" and EXITS 0 with the job still absent, so a fallback gated on its rc
        # can never fire and only a re-read decides.
        [ "$1" = "load" ] && [ -f "$S/load_refused" ] && exit 0
        cp "$S/on_load" "$S/state"; printf '0\n' > "$S/flaps" 2>/dev/null ;;   # a load ADDS an absent job
      *) exit 0 ;;                                    # already loaded: no-op, rc 0 (measured)
    esac ;;
  kickstart) cp "$S/on_load" "$S/state"; printf '0\n' > "$S/flaps" 2>/dev/null ;;   # STARTS a loaded-but-stopped job
esac
exit 0
SH
  chmod +x "$S/bin/launchctl"
  # `ps` fall-through stub, so "the command line could not be read" is a modelled state, not a guess
  cat > "$S/bin/ps" <<'SH'
#!/bin/bash
[ -f "${STUB_DIR:?}/nops" ] && exit 1
exec /bin/ps "$@"
SH
  chmod +x "$S/bin/ps"
  # the loop's plist is what the watchdog looks for: absence of the FILE means "nothing installed"
  [ "${4:-plist}" = "noplist" ] || : > "$S/home/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
  CALLS="$S/calls"; : > "$CALLS"
}
# wd — run the SHIPPED watchdog hermetically. WATCHDOG_SETTLE=0 so a recovery case does not sleep.
OUT=""; RC=0
wd() {
  OUT="$(env -u WATCHDOG_LABEL -u WATCHDOG_PLIST \
          HOME="$S/home" O="$S/o" PATH="$S/bin:$PATH" \
          STUB_DIR="$S" WATCHDOG_SETTLE=0 \
          bash "$WD" 2>&1)"
  RC=$?
}
log_text() { tr '\n' ' ' < "$S/o/logs/watchdog.log" 2>/dev/null; }
calls_text() { tr '\n' ' ' < "$CALLS" 2>/dev/null; }
loads() { grep -cE '^(load|bootstrap) ' "$CALLS" 2>/dev/null || true; }
kicks()  { grep -cE '^kickstart ' "$CALLS" 2>/dev/null || true; }

# ── 1) a healthy, running controller is LEFT ALONE ──────────────────────────────────────────────
echo; echo "── a present-and-running controller is not touched ──"
mk_state running running
wd
[ "$RC" -eq 0 ] && ok "running: exits 0" || bad "running: rc=$RC (want 0) — $OUT"
[ "$(loads)" -eq 0 ] \
  && ok "running: no load/bootstrap is issued — a healthy controller is never reloaded" \
  || bad "running: the watchdog RELOADED a running controller ($(calls_text))"
grep -qE '^(enable) ' "$CALLS" 2>/dev/null \
  && bad "running: it cleared the enable flag under a healthy service ($(calls_text))" \
  || ok "running: not even \`enable\` is run — nothing about a healthy service is written"
[ -s "$S/o/logs/watchdog.log" ] \
  && bad "running: it logged $(log_text) on a healthy box — noise that hides a real recovery" \
  || ok "running: nothing is logged on a healthy box"

# ── 2) IDEMPOTENT: N runs over a healthy service are N no-ops ───────────────────────────────────
for _ in 1 2 3; do wd; done
[ "$(loads)" -eq 0 ] \
  && ok "idempotent: three further runs still issue no load — running it repeatedly cannot stack reloads" \
  || bad "idempotent: repeated runs issued $(loads) loads ($(calls_text))"
[ -s "$S/o/logs/watchdog.log" ] \
  && bad "idempotent: repeated runs wrote log lines on a healthy box — $(log_text) [observed=$(tr '\n' ';' < "$S/observed" 2>/dev/null)]" \
  || ok "idempotent: repeated runs write no log lines"

# ── 3) a REMOVED service is put back (the failure this exists for) ───────────────────────────────
echo; echo "── a REMOVED controller is reloaded, and only once ──"
mk_state absent absent running
wd
[ "$RC" -eq 0 ] && ok "absent: exits 0 after a successful recovery" || bad "absent: rc=$RC (want 0) — $OUT"
[ "$(loads)" -eq 1 ] \
  && ok "absent: exactly one load/bootstrap is issued (idempotent per run, not per line)" \
  || bad "absent: expected 1 load, got $(loads) ($(calls_text))"
grep -q 'enable' "$CALLS" 2>/dev/null \
  && ok "absent: \`enable\` clears the persistent disabled flag that unload -w/bootout left behind" \
  || bad "absent: enable was never called — a disabled service would stay disabled after the load"
case "$(log_text)" in
  *ABSENT*recovered*pid=4242*) ok "absent: the log says it was ABSENT and records the recovered pid" ;;
  *) bad "absent: the log does not tell the story — $(log_text)" ;;
esac
# ...and the recovery is not repeated on the next pass, because the service now runs.
wd
[ "$(loads)" -eq 1 ] \
  && ok "absent→running: the next pass leaves it alone (the recovery is not repeated)" \
  || bad "absent→running: the watchdog reloaded a controller it had just recovered ($(calls_text))"

# ── 3z) an UNREADABLE launchd acts on NOTHING (review finding: the highest-severity class) ──────
# ⛔ A FAILED READ IS NOT "NOT RUNNING". `launchctl` answering `Print failed: 5: Input/output error` says
# nothing about the job — measured EIO is the 2026-10-17 failure this agent exists for. The first version
# folded every non-zero status into "absent"/"not running", so a transient read failure plus a
# successful one landed in the "loaded but stopped" branch and ran `kickstart -k` on a controller that
# was in fact RUNNING: it would interrupt the cycle and strand that cycle's lanes, lock and claim — the
# one outcome this script forbids. The canonical reader is tri-state for exactly this reason
# (launchd-cycle.sh's lc_probe: 2 = the read failed), and this case pins that the third state is honoured.
echo; echo "── an unreadable launchd launches NOTHING at the controller ──"
mk_state unreadable running running
: > "$S/print_fail"
wd
[ "$RC" -ne 0 ] \
  && ok "unreadable: exits NON-ZERO — an unproven state is a failure, not a quiet pass" \
  || bad "unreadable: exited 0 while launchd's state could not be read"
[ -z "$(grep -E '^(kickstart|load|bootstrap|enable) ' "$CALLS" 2>/dev/null)" ] \
  && ok "unreadable: NO action verb is issued — a healthy controller is never kickstarted on a failed read" \
  || bad "unreadable: it acted on a state it could not read ($(calls_text))"
case "$(log_text)" in
  *"could not be read"*|*UNKNOWN*) ok "unreadable: the log names the failed read so the human can tell it from a removal" ;;
  *) bad "unreadable: the log does not name the failed read — $(log_text)" ;;
esac
rm -f "$S/print_fail"

# ── 3y) a MISSING gui/ DOMAIN is not a failed read: the user/ probe must still happen ──────────
# ⛔ REVIEW FINDING (P1). launchd answers `print gui/<uid>/<label>` with `Bad request.` + `Could not find
# domain for user gui: <uid>` when that DOMAIN does not exist (an SSH-only session, uid 0). That is a
# rejection of the DOMAIN, not of the service: folding it into "unreadable" left the agent PERMANENTLY
# INERT on exactly the boxes whose job lives in `user/` — a removed controller stayed removed, while the
# log blamed launchd. The recovery must continue into `user/` and work there.
echo; echo "── a missing gui/ domain does not blind the agent to a job in user/ ──"
mk_state nodomaingu absent running
: > "$S/gui_domain_absent"
: > "$S/userdomain"
wd
[ "$RC" -eq 0 ] && grep -q '^bootstrap user/' "$CALLS" \
  && ok "no gui/ domain: the user/ domain is still probed and the removed job is re-added there (rc 0)" \
  || bad "no gui/ domain: rc=$RC — the domain-level rejection stopped the probe ($(calls_text))"
case "$(log_text)" in
  *"unreadable"*) bad "no gui/ domain: it was logged as an unreadable READ — that is the permanent-inertness defect ($(log_text))" ;;
  *ABSENT*recovered*) ok "no gui/ domain: the log tells the ordinary absent→recovered story" ;;
  *) bad "no gui/ domain: unexpected log — $(log_text)" ;;
esac

# ── 3x) a BARE rejection is UNKNOWN, not ABSENT (it says nothing about the service) ─────────────
# ⛔ `Bad request.` on its own is launchd refusing the REQUEST. The repo already pins that verdict
# (`launchd-cycle.sh`'s `lc_probe` returns 2, and the durability suite asserts "Bad request. alone reads
# as UNKNOWN, not as absent"). Only the line that NAMES a missing domain means "this domain cannot hold
# the job" — that one may be skipped, because no service can live there. Treating the bare rejection as
# absence would issue enable/bootstrap off an error message and could log `recovered:` for a controller
# launchd never removed.
echo; echo "── a bare rejection issues nothing and is not read as ABSENT ──"
mk_state badonly running running
: > "$S/badonly"
wd
[ "$RC" -ne 0 ] && [ -z "$(grep -E '^(kickstart|load|bootstrap|enable) ' "$CALLS" 2>/dev/null)" ] \
  && ok "bare Bad request: exits NON-ZERO and issues NO action verb" \
  || bad "bare Bad request: rc=$RC — it acted on a rejection ($(calls_text))"
case "$(log_text)" in
  *recovered*) bad "bare Bad request: it logged a RECOVERY for a service launchd never removed — $(log_text)" ;;
  *"could not be read"*) ok "bare Bad request: logged as an unreadable state, not as a recovery" ;;
  *) bad "bare Bad request: unexpected log — $(log_text)" ;;
esac
rm -f "$S/badonly"

# ── 3w) a SILENT non-zero read is UNKNOWN, not ABSENT (empty output is not a verdict) ───────────
# ⛔ THE EMPTY-IS-FALSY TRAP, in the reader's own flag. `launchctl print` exiting non-zero and printing
# NOTHING left a datum-style `unknown=""`, so the "unrecognised answer" branch never fired and the pass
# reported definitively ABSENT — then enable/bootstrap, and a `recovered:` line for a controller launchd
# never removed. The verdict is the STATUS; the diagnostic is only what gets quoted at the operator.
echo; echo "── a silent failed read issues nothing and is not read as ABSENT ──"
mk_state silent running running
: > "$S/silent"
wd
[ "$RC" -ne 0 ] && [ -z "$(grep -E '^(kickstart|load|bootstrap|enable) ' "$CALLS" 2>/dev/null)" ] \
  && ok "silent failed read: exits NON-ZERO and issues NO action verb" \
  || bad "silent failed read: rc=$RC — it acted on a read that said nothing ($(calls_text))"
case "$(log_text)" in
  *ABSENT*|*recovered*) bad "silent failed read: it reported a state it never read — $(log_text)" ;;
  *"could not be read"*) ok "silent failed read: logged as unreadable, quoting launchd's silence" ;;
  *) bad "silent failed read: unexpected log — $(log_text)" ;;
esac
rm -f "$S/silent"

# ── 4) a load that does NOT take is reported, not retried in a loop ─────────────────────────────
mk_state broken absent absent
wd
[ "$RC" -ne 0 ] \
  && ok "failed recovery: exits NON-ZERO — a load that did not take is a failure, not a success" \
  || bad "failed recovery: exited 0 while the service never came up"
case "$(log_text)" in
  *"RECOVERY FAILED"*) ok "failed recovery: says RECOVERY FAILED and that a human is needed" ;;
  *) bad "failed recovery: the log does not name the failure — $(log_text)" ;;
esac
# The remedies for "absent" are a bounded SET (`load`, then `bootstrap` in each candidate domain), and
# each is attempted at most ONCE — the 60-second launchd pass is the retry mechanism, not an inner loop.
_dups="$(sort "$CALLS" | uniq -d | grep -E '^(load|bootstrap) ' || true)"
[ "$(loads)" -le 3 ] && [ -z "$_dups" ] \
  && ok "failed recovery: each remedy tried once per pass — 60-second launchd runs are the retry mechanism" \
  || bad "failed recovery: $(loads) load/bootstrap attempts, duplicates='${_dups}' — an inner retry loop"

# ── 5) a DECLARED stop is honoured (README §6's handoff must not be undone) ─────────────────────
echo; echo "── a declared stop is not reversed ──"
mk_state declared absent running
: > "$S/o/.watchdog-off"
wd
[ "$(loads)" -eq 0 ] \
  && ok "declared stop: the controller is NOT reloaded while \$O/.watchdog-off exists" \
  || bad "declared stop: it reloaded a controller a human had deliberately stopped ($(calls_text))"
case "$(log_text)" in
  *"declared stop"*) ok "declared stop: the run says why it did nothing (silence would look like a broken watchdog)" ;;
  *) bad "declared stop: no explanation in the log — $(log_text)" ;;
esac
# ⛔ ONE LINE PER LONG-LIVED CONDITION, NOT ONE PER MINUTE. A declared stop can last for weeks; at a
# 60-second interval an unthrottled line is 1,440 a day in the same file that carries the recoveries,
# which is how a real recovery gets missed. Three further passes must add nothing.
wd; wd; wd
[ "$(grep -c 'declared stop' "$S/o/logs/watchdog.log")" -eq 1 ] \
  && ok "declared stop: four passes write ONE line (noise must not bury a recovery)" \
  || bad "declared stop: $(grep -c 'declared stop' "$S/o/logs/watchdog.log") lines after four passes"
rm -f "$S/o/.watchdog-off"
wd
[ "$(loads)" -eq 1 ] \
  && ok "re-armed: removing the sentinel restores recovery on the next pass" \
  || bad "re-armed: still inert after the sentinel was removed ($(calls_text))"

# ── 6) nothing installed ⇒ nothing to do, and no launchctl calls at all ─────────────────────────
mk_state noplist absent running noplist
wd
[ "$RC" -eq 0 ] && [ "$(loads)" -eq 0 ] && [ ! -s "$CALLS" ] \
  && ok "no loop plist: exits 0 and makes no launchctl call (an uninstalled box stays quiet)" \
  || bad "no loop plist: rc=$RC, calls='$(calls_text)'"

# ── 7) present but NOT running is restarted — with the verb that can actually do it ─────────────
# ⛔ MEASURED: `load -w`/`bootstrap` are NO-OPS on a job already in the domain (load exits 0 having
# failed), so this case once asserted "a load was issued" over a recovery that never happened. It now
# asserts the OUTCOME (rc 0, a `recovered: pid=` line) plus the verb (`kickstart`), and the stub
# refuses to start an already-loaded job on load/bootstrap — so a regression fails here.
mk_state idle idle running
wd
[ "$RC" -eq 0 ] && [ "$(kicks)" -eq 1 ] && [ "$(loads)" -eq 0 ] \
  && ! grep -qE '^kickstart -k' "$CALLS" \
  && ok "loaded-but-idle: kickstarted once WITHOUT -k, and with NO load/bootstrap (both are no-ops on a loaded job; the kill form could interrupt a controller that respawned between the read and the verb)" \
  || bad "loaded-but-idle: rc=$RC kicks=$(kicks) loads=$(loads) — a load/bootstrip cannot restart a loaded job ($(calls_text))"
case "$(log_text)" in
  *"recovered: pid="[0-9]*) ok "loaded-but-idle: the log reports the RECOVERY with a PID, not merely the attempt" ;;
  *) bad "loaded-but-idle: no 'recovered: pid=<digits>' line — the attempt was logged as if it worked: $(log_text)" ;;
esac

# ── 8) a controller launchd did NOT start is still a running controller ───────────────────────
# ⛔ MEASURED DEFECT (review round 2): the controller also runs under `nohup ./orch-loop.sh` from a
# pane (README §4), which `launchctl` cannot see. The script then read ABSENT, loaded the service, the
# spawned controller exited on its own single-instance lock, the post-check failed, and every pass
# logged RECOVERY FAILED forever — a false alarm in the log whose only value is being trustworthy.
# The controller's OWN lock is the authority, and deferring on it is the fail-closed direction.
echo; echo "── a controller running OUTSIDE launchd is left alone ──"
mk_state outside absent running
# a process whose COMMAND LINE names orch-loop — identity, not merely liveness, is what the lock must prove.
# `exec -a` makes the SLEEP itself the process, so killing the pid cannot orphan a child that holds this
# script's stdout open (an orphaned `sleep 60` kept the whole suite at 63 s instead of 19 s).
printf '#!/bin/bash\nexec -a orch-loop.sh sleep 60\n' > "$S/orch-loop.sh"; chmod +x "$S/orch-loop.sh"
bash "$S/orch-loop.sh" & LPID=$!
printf '%s\n' "$LPID" > "$S/o/.orch.lock"
wd
[ "$RC" -eq 0 ] && [ "$(loads)" -eq 0 ] && [ "$(kicks)" -eq 0 ] \
  && ! grep -qE '^(enable|bootstrap) ' "$CALLS" \
  && ok "outside launchd: the live lock pid means a controller is running — no action verb is issued" \
  || bad "outside launchd: rc=$RC it WROTE to a controller that is running ($(calls_text))"
case "$(log_text)" in
  *"outside launchd"*) ok "outside launchd: the log says why it did nothing (once, not every minute)" ;;
  *) bad "outside launchd: no explanation in the log — $(log_text)" ;;
esac
wd; wd; wd
[ "$(grep -c 'outside launchd' "$S/o/logs/watchdog.log")" -eq 1 ] \
  && ok "outside launchd: four passes write ONE line — a persistent condition is not a 1,440-line-a-day poll" \
  || bad "outside launchd: $(grep -c 'outside launchd' "$S/o/logs/watchdog.log") lines after four passes (noise buries the recoveries)"
kill "$LPID" 2>/dev/null
# ...and a DEAD lock pid must not suppress recovery (the lock is only authoritative while it is alive).
mk_state stalelock absent running
printf '999999\n' > "$S/o/.orch.lock"
wd
[ "$(loads)" -eq 1 ] \
  && ok "stale lock: a dead pid does not suppress recovery — the service is reloaded" \
  || bad "stale lock: recovery was suppressed by a lock naming a dead pid (calls='$(calls_text)')"

# ── 9) the ACTION verbs follow the job into whichever domain holds it ────────────────────────────
# ⛔ `launchctl list <label>` is domain-agnostic but `enable`/`kickstart`/`bootstrap` are not: a job in
# `user/` is invisible to `gui/`. `launchctl bootstrap <domain> <plist>` lands the job in `gui/`
# from a GUI session and `user/` from an SSH one, so a hardcoded `gui/` made every recovery a no-op
# swallowed by `|| true` — the round-1 defect in a new dimension.
echo; echo "── the recovery acts on the domain that holds the job ──"
mk_state userdomain idle running
: > "$S/userdomain"
wd
[ "$RC" -eq 0 ] && grep -q '^kickstart user/' "$CALLS" && grep -q '^enable user/' "$CALLS" \
  && ok "user-domain job: both enable and kickstart reach the domain holding the job (rc 0)" \
  || bad "user-domain job: rc=$RC — the recovery never reached the domain holding the job ($(calls_text))"
case "$(log_text)" in
  *"recovered: pid="[0-9]*) ok "user-domain job: the log reports the recovery with a PID" ;;
  *) bad "user-domain job: no recovery line — $(log_text)" ;;
esac

# ── 10) a writer killed by SIGPIPE does not turn a RUNNING controller into a recovery ───────────
# ⛔ THE SHIPPED DEFECT THIS PINS. `running()` read the dict with `launchctl list | grep -q`, and the
# script runs under `set -o pipefail`: `grep -q` exits at its first match and closes the pipe, so the
# writer can die of SIGPIPE (141) after printing a perfectly good dict and pipefail then calls the
# PIPELINE failed. The verdict flipped on a buffer race — measured 2 runs in 25 as "present but not
# running — kickstarting" on a HEALTHY controller, i.e. a kickstart that interrupts it mid-cycle. It
# was found as a flaky case here; the flake was the product. The stub now forces the SIGPIPE (no race)
# so a regression to a `| grep -q` reader fails deterministically instead of one run in twelve.
echo; echo "── a SIGPIPE'd writer does not fake a dead controller ──"
mk_state sigpipe running running
: > "$S/sigpipe"
wd
[ "$RC" -eq 0 ] && [ "$(loads)" -eq 0 ] && [ "$(kicks)" -eq 0 ] \
  && ok "SIGPIPE: the dict printed a PID, so the controller IS running — no recovery is started" \
  || bad "SIGPIPE: a healthy controller was treated as dead (rc=$RC calls='$(calls_text)')"
[ -s "$S/o/logs/watchdog.log" ] \
  && bad "SIGPIPE: it logged a false 'present but not running' — $(log_text)" \
  || ok "SIGPIPE: nothing is logged for a healthy controller"

# ── 10c) a lock naming a LIVE NON-CONTROLLER pid is reported, not reloaded over ──────────────────
# ⛔ LIVENESS IS NOT IDENTITY, AND THE RELOAD CANNOT HELP. `orch-loop.sh` itself defers to ANY live pid in
# this file (`already running` → exit 0), so a service launched over such a lock would exit at once and
# every pass would log a recovery that never happened (review round 4, driven: absent → reloading →
# RECOVERY FAILED forever). Deleting the lock from here is the tempting fix and the wrong one — it is the
# controller's mutual exclusion, and a false negative in the identity match would then let TWO controllers
# sweep one PR queue (#1715). So: say the true thing, name the remedy, hand it to a human.
echo; echo "── a lock whose pid is not a controller is reported, not reloaded over ──"
mk_state pidreuse absent running
sleep 60 & RPID=$!
printf '%s\n' "$RPID" > "$S/o/.orch.lock"          # alive, but its command line is not a controller
wd
[ "$RC" -ne 0 ] && [ "$(loads)" -eq 0 ] && [ "$(kicks)" -eq 0 ] \
  && ok "pid reuse: no reload is attempted over a lock the controller would exit on, and rc is NON-ZERO" \
  || bad "pid reuse: rc=$RC loads=$(loads) — it reloaded into a lock nothing can reclaim ($(calls_text))"
case "$(log_text)" in
  *"not an orch-loop controller"*"remove it"*) 
    ok "pid reuse: the log names the stale lock AND the remedy (a silent no-op would look like a dead watchdog)" ;;
  *) bad "pid reuse: the log does not name the stale lock and its remedy — $(log_text)" ;;
esac
[ "$(grep -c 'stale lock' "$S/o/logs/watchdog.log")" -eq 1 ] \
  && ok "pid reuse: one line, not one per minute" \
  || bad "pid reuse: $(grep -c 'stale lock' "$S/o/logs/watchdog.log") lines"
kill "$RPID" 2>/dev/null

# ── 10e) an UNREADABLE lock-holder command line is reported, never assumed ───────────────────────
# AGENTS.md: if a read is unclear, report, do not act. Asserting "not a controller" from an empty `ps`
# would be a claim the script did not establish (round 4, driven: it printed exactly that over a REAL
# orch-loop controller whose argv it could not read).
echo; echo "── an unreadable lock holder is handed to a human ──"
mk_state nops absent running
printf '#!/bin/bash\nexec -a orch-loop.sh sleep 60\n' > "$S/orch-loop.sh"; chmod +x "$S/orch-loop.sh"
bash "$S/orch-loop.sh" & UPID=$!
printf '%s\n' "$UPID" > "$S/o/.orch.lock"
: > "$S/nops"
wd
[ "$RC" -ne 0 ] && [ "$(loads)" -eq 0 ] \
  && ok "unreadable lock holder: nothing is loaded over it, and rc says a human is needed" \
  || bad "unreadable lock holder: rc=$RC loads=$(loads) — it acted on a read it could not make"
case "$(log_text)" in
  *"could not be read"*) ok "unreadable lock holder: the log says the read failed (not that the holder is not a controller)" ;;
  *) bad "unreadable lock holder: the log overclaims — $(log_text)" ;;
esac
kill "$UPID" 2>/dev/null

# ── 10f) the verdict and the pid come from ONE read ─────────────────────────────────────────────
# ⛔ ROUND-3 DEFECT, PINNED. `running()` then `pid_of()` were two launchctl calls: a controller dying in
# between produced the log line `recovered: pid=` (EMPTY) at rc 0 — a false PASS in the only evidence a
# recovery happened. Reverting to two reads used to score 52/52 here; the `flap` stub now models the
# window deterministically so the regression is caught instead of shipped.
echo "── a controller that dies between reads cannot produce a false recovery ──"
mk_state flap absent running
: > "$S/flap"
wd
[ "$RC" -eq 0 ] && [ "$(loads)" -eq 1 ] \
  && ok "flap: the recovery is attempted once" \
  || bad "flap: rc=$RC loads=$(loads)"
case "$(log_text)" in
  *"recovered: pid="[0-9]*) ok "flap: the recovery is logged with a REAL pid (a bare 'pid=' would be a false PASS)" ;;
  *) bad "flap: the recovery line has no pid — $(log_text)" ;;
esac

# ── 10d) a bootstrap that FAILS falls through to the legacy `load`, decided by a RE-READ ────────
# ⛔ MEASURED (2026-10-17): `bootstrap` failed with `Bootstrap failed: 5: Input/output error` (rc 5)
# and legacy `load` is what brought the controller back — `launchd-cycle.sh`'s `lc_start` keeps that
# fallback for exactly this case. ⛔ AND THE rc IS NOT THE VERDICT: `load` on a job it refuses prints
# "Load failed: 5: Input/output error" and EXITS 0, so a `load || bootstrap` fallback never fires in
# the one case it exists for. The state must be re-read after every attempt — which is also what stops
# the plist landing in a SECOND domain when the first verb already installed it.
echo; echo "── a bootstrap that fails falls through to the legacy load, decided by the state ──"
mk_state bootstraprefused absent running
: > "$S/bootstrap_refused"
wd
[ "$RC" -eq 0 ] && grep -q '^load ' "$CALLS" \
  && ok "bootstrap EIO: the state is re-read, so the legacy \`load\` runs and the job comes back (rc 0)" \
  || bad "bootstrap EIO: rc=$RC load=$(grep -c '^load ' "$CALLS") — bootstrap's rc was trusted ($(calls_text))"
case "$(log_text)" in
  *"recovered: pid="[0-9]*) ok "bootstrap EIO: the recovery is reported with a PID" ;;
  *) bad "bootstrap EIO: no recovery line — $(log_text)" ;;
esac
[ "$(grep -c '^bootstrap ' "$CALLS")" -eq 2 ] \
  && ok "bootstrap EIO: bootstrap is attempted once per domain (gui/ then user/), never in one domain twice" \
  || bad "bootstrap EIO: $(grep -c '^bootstrap ' "$CALLS") bootstrap attempts — want exactly one per domain"
# ── 10e) only ONE domain ever receives the job (no second service on one label) ─────────────────
# ⛔ Two launchd jobs on one label means `--uninstall` stops one of them and the survivor's KeepAlive
# resurrects the loop under a human who was told the box was stopped. The re-read after each attempt is
# what prevents it, so this case asserts NO user/ verb was issued after gui/ took the job.
mk_state onedomain absent running
wd
# ⛔ ONLY ACTION VERBS COUNT. `read_state` probes `print user/…` after `print gui/…` on every pass — that
# is a READ, and it is what makes the agent work on a box whose job lives in `user/`. The property under
# test is that the plist is never INSTALLED into a second domain.
[ "$(grep -c '^bootstrap ' "$CALLS")" -eq 1 ] && ! grep -qE '^(enable|bootstrap|kickstart|load) .*user/' "$CALLS" \
  && ok "a job that comes up in gui/ is never also bootstrapped into user/ (one label = one job)" \
  || bad "the plist landed in two domains: $(calls_text)"

# ── 10g) only the controller counts, not any command that MENTIONS it ────────────────────────────
# ⛔ `tail -f ~/orchestrator/logs/orch-loop.log` is a command §4/§6 tell a human to run, and a substring
# test on `orch-loop` read it as a running controller — deferring recovery for as long as the human
# watches the log (the permanent inertness the identity check exists to remove). The match is on the
# `.sh` TOKEN, so a log tail is not a controller.
echo "── a command that mentions orch-loop is not a controller ──"
mk_state logtail absent running
: > "$S/orch-loop.log"
tail -f "$S/orch-loop.log" & TPID=$!
printf '%s\n' "$TPID" > "$S/o/.orch.lock"
wd
[ "$RC" -ne 0 ] && [ "$(loads)" -eq 0 ] \
  && ok "log tail: a live 'tail -f .../orch-loop.log' is not mistaken for the controller" \
  || bad "log tail: rc=$RC loads=$(loads) — a log read deferred recovery ($(calls_text))"
kill "$TPID" 2>/dev/null

# ── 10h) an invalid WATCHDOG_SETTLE is clamped, not silently zeroed ─────────────────────────────
# ⛔ `sleep abc` fails under `set -uo pipefail` with NO `set -e`: the wait silently becomes zero, and the
# wait is exactly what stops an asynchronously-updated domain from reading as still-absent and being
# bootstrapped into a SECOND domain (two jobs on one label; --uninstall stops one). Driven before the
# guard: four `sleep: invalid time interval` lines and BOTH bootstraps issued. This check costs 5 s
# because the correct behaviour is to actually wait.
echo "── an invalid WATCHDOG_SETTLE does not collapse the recovery waits ──"
mk_state badsettle idle running
_OUT="$(env -u WATCHDOG_LABEL -u WATCHDOG_PLIST HOME="$S/home" O="$S/o" PATH="$S/bin:$PATH" \
        STUB_DIR="$S" WATCHDOG_SETTLE=abc bash "$WD" 2>&1)"; _RC=$?
[ "$_RC" -eq 0 ] && case "$_OUT" in *"invalid time interval"*|*"invalid number"*) false ;; *) true ;; esac \
  && ok "bad WATCHDOG_SETTLE: clamped, so the waits still happen and the recovery completes" \
  || bad "bad WATCHDOG_SETTLE: rc=$_RC — the wait collapsed (${_OUT:-no output})"

# ── 10i) the SETTLE BOUND, not just the character class ─────────────────────────────────────────
# ⛔ `WATCHDOG_SETTLE=999999999999999999999` is ALL DIGITS, so the character-class guard passes it and
# `sleep` rejects it: no `set -e`, so every wait silently collapses to zero — measured identical log
# timestamps and 0 s elapsed — which re-opens the read-before-the-domain-updated race that bootstraps a
# SECOND job on one label (--uninstall stops one; the survivor's KeepAlive resurrects the loop). The
# `abc` case above cannot catch it (the class guard already clamps that), so this one drives a real
# overflow. A stub `sleep` records its argument instead of waiting, so the check costs nothing.
echo "── an out-of-range WATCHDOG_SETTLE is clamped to a wait that actually happens ──"
mk_state bigsettle absent running
mkdir -p "$S/bin2"
cat > "$S/bin2/sleep" <<'SH'
#!/bin/bash
printf '%s\n' "${1:-}" >> "${STUB_SLEEPS:?}"
exit 0
SH
chmod +x "$S/bin2/sleep"
: > "$S/sleeps"
_OUT="$(env -u WATCHDOG_LABEL -u WATCHDOG_PLIST HOME="$S/home" O="$S/o" PATH="$S/bin2:$S/bin:$PATH" \
        STUB_DIR="$S" STUB_SLEEPS="$S/sleeps" WATCHDOG_SETTLE=999999999999999999999 bash "$WD" 2>&1)"; _RC=$?
[ "$_RC" -eq 0 ] && grep -qx '5' "$S/sleeps" \
  && ok "huge WATCHDOG_SETTLE: clamped to 5 s and the waits run (a zero wait re-opens the double-bootstrap race)" \
  || bad "huge WATCHDOG_SETTLE: rc=$_RC sleeps='$(tr '\n' ' ' < "$S/sleeps")' — the bound did not clamp to a real wait"
grep -qx '999999999999999999999' "$S/sleeps" \
  && bad "huge WATCHDOG_SETTLE: the raw value reached sleep (sleep rejects it and the wait collapses silently)" \
  || ok "huge WATCHDOG_SETTLE: the raw value never reaches sleep"
case "$(log_text)" in
  *"recovered: pid="[0-9]*) ok "huge WATCHDOG_SETTLE: the clamped wait still recovers, with a real pid" ;;
  *) bad "huge WATCHDOG_SETTLE: no recovery — $(log_text)" ;;
esac

# ── 10b) the shipped artifacts carry no absolute home ────────────────────────────────────────────
# ⛔ THE DEFECT THIS PINS: a hardcoded /Users/<someone> in a shipped plist is why the cloud cells
# never dispatched — they loaded a plist naming a directory that does not exist on a cell, launchd
# started nothing, and no error reached the fleet.
echo; echo "── the shipped artifacts carry no absolute paths ──"
if grep -qE '/Users/[A-Za-z0-9._-]+' "$WD" "$TPL" 2>/dev/null; then
  bad "an absolute /Users/… path is baked into a shipped file: $(grep -nE '/Users/[A-Za-z0-9._-]+' "$WD" "$TPL" | head -2 | tr '\n' ' ')"
else
  ok "watchdog.sh and its plist template contain no hardcoded /Users/… path"
fi
grep -q '__O__' "$TPL" \
  && ok "the template is install-relative (its program path is rendered from \$O)" \
  || bad "the template does not use the install dir placeholder"
# ⛔ THESE TWO ARE DRIVEN, NOT GREPPED (review finding). They used to be literal-text matches on
# install.sh, two lines under a header that says a grep cannot see what install.sh DOES — and the
# behavioural assertions that actually prove them were inside the Darwin gate, so on the Linux CI lane
# the claims rested on a string that survives the statement being renamed or moved into a variable (the
# exact defect the durability suite names). install.sh refuses to run off macOS, so the platform gate is
# bypassed here the same way that suite does it — with a stubbed `plutil` and install's own documented
# ELDATO_ALLOW_NON_DARWIN opt-in — and the ASSERTIONS are about the box install.sh leaves behind.
echo; echo "── install.sh seeds \$O/watchdog.sh and REPLACES a hand-patched copy, driven on every platform ──"
SEED="$T/seed"; mkdir -p "$SEED/bin" "$SEED/home/Library/LaunchAgents" "$SEED/o"
# ⛔ THIS SANDBOX INSTALLS A **TEST** LABEL (agent-infra#1996). `install.sh`'s `label_guard` refuses a
# PRODUCTION loop label anywhere but the invoking user's real `$HOME` — correctly: launchd resolves a
# label in the user domain and IGNORES `$HOME`, so a plist written under a throwaway home still
# addresses the live controller. Every install.sh caller below therefore passes the guard's own
# supported seam (`LABEL_OVERRIDE`), which is what `selftest.sh` and the durability suite do. The
# WATCHDOG label is a separate constant in install.sh (`WATCHDOG_LABEL`, matching main's
# `PROD_WD_LABEL`) and is unaffected — so the assertions on its plist path still hold.
cat > "$SEED/bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_CALLS:?}"
exit 0
SH
printf '#!/bin/sh\nexit 0\n' > "$SEED/bin/plutil"          # install.sh's XML lint, stubbed
for _b in tmux gh pi uv; do printf '#!/bin/bash\nexit 0\n' > "$SEED/bin/$_b"; done
chmod +x "$SEED/bin/launchctl" "$SEED/bin/plutil" "$SEED/bin/tmux" "$SEED/bin/gh" "$SEED/bin/pi" "$SEED/bin/uv"
# ONE run: seed the box, then prove the two claims from its ARTEFACTS.
# ⛔ REPO AND OR ARE PART OF THE SANDBOX, not ambient state. install.sh REFUSES to run without a target
# checkout (`REPO is not set`, then `not a git checkout` — a slug is not a path), and it derives the repo
# surface from OR. Inheriting them made this section pass only where the caller's environment happened to
# carry a valid REPO, i.e. the non-hermetic shape every other install.sh caller in this repo avoids
# (`selftest.sh`, the durability suite). Every claim below depends on this run completing.
_seed_run() { env HOME="$SEED/home" O="$SEED/o" REPO="$(cd "$HERE/../.." && pwd)" OR="acme/widget" \
                  LABEL_OVERRIDE="$LOOP_LABEL_TEST" \
                  PATH="$SEED/bin:$PATH" STUB_CALLS="$SEED/calls" \
                  STUB_DIR="$SEED" ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
                  bash "$INST" "$@"; }
: > "$SEED/calls"
if _seed_run >"$SEED/out" 2>&1; then
  ok "install.sh exits 0 on a fresh sandbox box (the run the two claims below depend on)"
else
  bad "install.sh did not complete in the seed sandbox — $(tail -3 "$SEED/out" | tr '\n' ' ')"
fi
[ -x "$SEED/o/watchdog.sh" ] \
  && ok "install.sh SEEDS an executable \$O/watchdog.sh — launchd executes \$O/watchdog.sh, not the repo copy" \
  || bad "no executable \$O/watchdog.sh after install — the rendered plist names a path launchd cannot run"
# The replacement is behaviour, not text: hand-patch the seeded copy and require the NEXT run to SAY SO
# and to restore it. (Not "drift": install.sh copies this file unconditionally before its drift loop, so
# a drift entry for it could never fire — and the installer has none.)
printf '\n# hand-patched during an incident\n' >> "$SEED/o/watchdog.sh"
if _seed_run >"$SEED/out2" 2>&1; then
  # ⛔ THE PROPERTY IS "REPLACED AND SAID SO", NOT "REPORTED AS DRIFT" (review finding). The installer
  # copies the shipped file unconditionally BEFORE the drift loop, so by the time the list is compared
  # the two are identical and `watchdog.sh` can never appear there. The earlier version matched the bare
  # word `watchdog.sh` anywhere in stdout, which the copy's own warning satisfies — it would have stayed
  # green with the whole drift entry deleted. So assert the two facts that actually hold: the replacement
  # is WARNED about, and the seeded copy comes back byte-identical to the shipped one.
  # ⛔ MATCH THE WARNING'S OWN WORDS, NOT `$O`. install.sh interpolates the install dir into that
  # message (it is a double-quoted `warn`), so a pattern containing a literal `$O` can never match on
  # any box — the assertion would fail deterministically while the product did the right thing.
  _seed_warn="$(grep -F 'replacing a DIFFERENT' "$SEED/out2" 2>/dev/null || true)"
  case "$_seed_warn" in
    *watchdog.sh*) _wa_replaced=1 ;;
    *) _wa_replaced="" ;;
  esac
  [ -n "$_wa_replaced" ] \
    && ok "a hand-patched \$O/watchdog.sh is REPLACED by the next install, and the replacement is WARNED about" \
    || bad "install silently overwrote a hand-patched \$O/watchdog.sh — the run said: $(printf '%s' "${_seed_warn:-no replacement warning at all}")"
  cmp -s "$SEED/o/watchdog.sh" "$HERE/watchdog.sh" \
    && ok "…and the seeded copy is byte-identical to the shipped one afterwards" \
    || bad "the seeded \$O/watchdog.sh differs from the shipped copy after the install"
else
  bad "the replacement install run failed — $(tail -3 "$SEED/out2" | tr '\n' ' ')"
fi

# ── 11) install.sh's render + its --uninstall, DRIVEN (not grepped) ──────────────────────────────
# ⛔ A grep over install.sh cannot see what it DOES — and the uninstall path has an ORDER that
# matters: the watchdog exists to reload the loop plist, so removing the loop while the watchdog is
# still armed is a race it wins a minute later (the operator is told the box is stopped while an
# autonomous merge loop comes back under them). Both properties are driven here against a stubbed
# `launchctl` and a sandbox HOME, so the real launchd domain is never touched.
echo; echo "── install.sh renders the watchdog plist and its --uninstall is ordered + idempotent ──"
U="$T/install"; mkdir -p "$U/bin" "$U/home/Library/LaunchAgents" "$U/o"
# ⛔ THE STUB MUST BE STATEFUL, not `exit 0` for everything. install.sh removes a job through
# `launchd-cycle.sh`, which (a) reads ownership with `launchctl print <domain>/<label>` and refuses to
# act when the loaded job cannot be shown to come from THIS plist, and (b) READS THE DOMAIN BACK after
# `bootout` instead of trusting its exit code. A stub that answers nothing would make (a) refuse — the
# test would then pass over a removal that never happened. So `print` reports the plist path launchd
# would report, and `bootout` records the label so a later `print` answers "not loaded". ⛔ NO `list`
# ARM: nothing driven through this stub calls `launchctl list` (the state read is `print`, and the
# installer's reads are `print` too), and an unexercised arm lets a future `list`-based read pass untested
# — the defect the durability suite names in its own stub.
cat > "$U/bin/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_CALLS:?}"
S="${STUB_DIR:?}"
_plist_for() { ls "$HOME/Library/LaunchAgents/$1.plist" 2>/dev/null; }
# `persist_watchdog` models the ONE state the ordering exists to catch: the watchdog is loaded in a domain
# `lc_bootout`'s gui/ probe cannot see (`user/`, from an SSH session), so a bootout "succeeds" while the
# agent survives and reloads the loop a minute later.
_gone() { [ -f "$S/persist_watchdog" ] && [ "$1" = "com.eldato.orchestrator-watchdog" ] && return 1; grep -qx "$1" "$S/booted" 2>/dev/null; }
case "$1" in
  print)
    _l="${2##*/}"
    if _gone "$_l"; then echo "Could not find service \"$_l\" in domain for port" >&2; exit 113; fi
    _p="$(_plist_for "$_l")"
    [ -n "$_p" ] || { echo "Could not find service \"$_l\" in domain for port" >&2; exit 113; }
    printf 'path = %s\npid = 4242\n' "$_p"; exit 0 ;;
  bootout)
    _l=""; for _a in "$@"; do case "$_a" in *.plist) _l="$(basename "$_a" .plist)" ;; esac; done
    [ -n "$_l" ] && printf '%s\n' "$_l" >> "$S/booted"
    exit 0 ;;
esac
exit 0
SH
chmod +x "$U/bin/launchctl"
# install.sh's preflight REQUIRES tmux, gh (authenticated) and pi, and its daemon-PATH probe executes
# them. Stub all three (plus uv) so this check is hermetic: it must not depend on the host's tmux, and
# it must not read, or need, a real GitHub credential from the sandbox HOME.
for _b in tmux gh pi uv; do
  printf '#!/bin/bash\nexit 0\n' > "$U/bin/$_b"; chmod +x "$U/bin/$_b"
done
# A legal-but-hostile $O: `<` and `>` are legal in a macOS path and are XML-significant, so a
# template rendered without escaping yields a plist launchd refuses while still looking plausible.
# (install.sh rejects a SHELL metacharacter such as `&` outright — a guard, not a gap — so this
# mirrors selftest §6's choice rather than arguing with that check.)
INST_O="$U/o<x>y"
# ⛔ REPO/OR BELONG TO THE SANDBOX HERE TOO. install.sh refuses to run without a real checkout
# (`REPO is not set`, then `not a git checkout` — a slug is not a path) and derives the repo surface
# from OR, so an inherited-or-absent pair made this Darwin group pass only on a box whose
# environment happened to carry a valid checkout. Self-contained, like `_seed_run` above.
iu() { env HOME="$U/home" O="$INST_O" REPO="$(cd "$HERE/../.." && pwd)" OR="acme/widget" \
            LABEL_OVERRIDE="$LOOP_LABEL_TEST" \
            PATH="$U/bin:$PATH" STUB_CALLS="$U/calls" STUB_DIR="$U" bash "$INST"; }
: > "$U/calls"
# ⛔ GATE ON THE PLATFORM, NOT ON A TOOL. install.sh refuses outright off macOS ("this harness uses
# launchd + tmux; only macOS is supported"), so a `plutil`-based gate is the wrong predicate: on a
# Linux image WITH plutil it would run install.sh for real and redden the shard with install.sh's own
# macOS message; without it the skip was never COUNTED when the render silently ran install.sh on
# Linux. The uninstall half below is platform-independent and always runs.
if [ "$(uname)" = "Darwin" ]; then
  if iu >"$U/out" 2>&1; then
    WPL="$U/home/Library/LaunchAgents/com.eldato.orchestrator-watchdog.plist"
    [ -f "$WPL" ] && ok "install.sh writes the watchdog plist (a fresh box gets one)" \
                  || bad "install.sh wrote no watchdog plist — $(tail -3 "$U/out" | tr '\n' ' ')"
    if [ -f "$WPL" ]; then
      plutil -lint "$WPL" >/dev/null 2>&1 && ok "the rendered watchdog plist is valid XML" \
                                         || bad "the rendered watchdog plist is not valid XML"
      # ROUND-TRIP, not a raw grep: the path is XML-escaped in the plist, so only decoding it back
      # proves the escaping was correct rather than merely well-formed (selftest §6's discipline).
      _prog="$(plutil -extract ProgramArguments.1 raw "$WPL" 2>/dev/null || echo MISSING)"
      [ "$_prog" = "$INST_O/watchdog.sh" ] \
        && ok "the rendered plist runs \$O/watchdog.sh, with the hostile \$O decoded back exactly" \
        || bad "the rendered plist names '$_prog', not '$INST_O/watchdog.sh'"
      grep -q '__[A-Z_]*__' "$WPL" && bad "the rendered plist still carries a template placeholder" \
                                   || ok "no template placeholder survives the render"
    fi
    [ -x "$INST_O/watchdog.sh" ] && ok "watchdog.sh is seeded executable at \$O" \
                                 || bad "no executable \$O/watchdog.sh"
    # The banner is an UNQUOTED heredoc: a bare backtick inside it is command substitution and is
    # silently DELETED from the operator-facing text. Assert the words survive — including the verbs,
    # because the banner is where an operator copies them from and this repo's durability gate forbids
    # the `-w` forms outright (#1975).
    # ⛔ NO `grep … | grep -q` HERE. Under `set -o pipefail` a quiet `grep -q` closes the pipe and the
    # writer dies of SIGPIPE, so the PIPELINE reports failure while the pattern DID match — the idiom the
    # repo's own `check-no-sigpipe-grep.sh` bans (#841/#864), and the same mechanism that made a healthy
    # controller read as dead in `watchdog.sh`. Capture, then test in the shell.
    _banner="$(grep -F 'undeclared' "$U/out" 2>/dev/null || true)"
    case "$_banner" in
      *'watchdog-off'*) ok "the install banner keeps the declared-stop sentence (a bare backtick in the unquoted heredoc would have eaten it)" ;;
      *) bad "the install banner lost the declared-stop sentence — a backtick in the unquoted heredoc consumed it: $(printf '%s' "$_banner" | head -1)" ;;
    esac
    if grep -q 'launchctl bootstrap' "$U/out" && ! grep -qE 'launchctl (load|unload) -w' "$U/out"; then
      ok "the install banner hands over the bootstrap form only — never a -w verb"
    else
      bad "the install banner's load advice is wrong (a -w verb, or no bootstrap): $(grep -n 'launchctl' "$U/out" | head -2 | tr '\n' ' ')"
    fi
    # Render twice: the plist must be byte-identical, and re-installing must not disturb launchd.
    _h1="$(cksum < "$WPL" 2>/dev/null)"
    iu >/dev/null 2>&1
    [ "$_h1" = "$(cksum < "$WPL" 2>/dev/null)" ] \
      && ok "install.sh is idempotent: a second run renders a byte-identical watchdog plist" \
      || bad "a second install run changed the watchdog plist (non-deterministic render)"
  else
    bad "install.sh failed in the sandbox — $(tail -4 "$U/out" | tr '\n' ' ')"
  fi
else
  SKIPPED=$((SKIPPED+1))
  echo "  … one check SKIPPED (not a pass): install.sh renders only on macOS (uname=$(uname))"
fi

# The uninstall path, driven twice. It must remove the WATCHDOG FIRST, remove both plists, and be a
# no-op error-free the second time (an operator re-running it is not a failure).
: > "$U/home/Library/LaunchAgents/com.eldato.orchestrator-watchdog.plist"
: > "$U/home/Library/LaunchAgents/$LOOP_LABEL_TEST.plist"
: > "$U/calls"
: > "$U/booted"
# ELDATO_ALLOW_TEST_HOME is the #446 opt-in the launchd-cycle helpers require: the sandbox HOME is by
# construction not the account's real home, and the guard refuses (correctly) without it.
_iu_un() { env HOME="$U/home" O="$U/o" PATH="$U/bin:$PATH" STUB_CALLS="$U/calls" STUB_DIR="$U" \
             LABEL_OVERRIDE="$LOOP_LABEL_TEST" \
             ELDATO_ALLOW_TEST_HOME=1 bash "$INST" --uninstall; }
_iu_un >"$U/un1" 2>&1
_rc1=$?
_iu_un >"$U/un2" 2>&1
_rc2=$?
[ "$_rc1" -eq 0 ] && [ "$_rc2" -eq 0 ] \
  && ok "uninstall is idempotent: the first run and a re-run both exit 0" \
  || bad "uninstall rc=$_rc1 then $_rc2 (want 0/0) — $(tail -2 "$U/un1" "$U/un2" 2>/dev/null | tr '\n' ' ')"
[ -f "$U/home/Library/LaunchAgents/com.eldato.orchestrator-watchdog.plist" ] \
  && bad "a watchdog plist survives --uninstall — it would keep reloading forever" \
  || ok "uninstall removes the watchdog plist"
[ -f "$U/home/Library/LaunchAgents/$LOOP_LABEL_TEST.plist" ] \
  && bad "the loop plist survives --uninstall" \
  || ok "uninstall removes the loop plist"
# The stub records the EXPANDED arguments, so match the labels the paths end in — not the shell
# variable names, which never appear in what launchctl is actually handed.
# ⛔ THE VERB IS `bootout`, NOT A `-w` FORM. #1975 removed every persistent-disable invocation from
# this harness precisely because it leaves a flag that defeats the next start — so an assertion pinned
# on `unload -w` would demand the defect back. The property under test is the ORDER.
_wd_line="$(grep -n '^bootout .*orchestrator-watchdog\.plist' "$U/calls" | head -1 | cut -d: -f1)"
_lp_line="$(grep -n "^bootout .*$LOOP_LABEL_TEST\\.plist" "$U/calls" | head -1 | cut -d: -f1)"
if [ -n "$_wd_line" ] && [ -n "$_lp_line" ]; then
  [ "$_wd_line" -lt "$_lp_line" ] \
    && ok "uninstall stops the WATCHDOG before the loop (otherwise it resurrects the loop 60s later)" \
    || bad "uninstall order: loop stopped first — the watchdog would reload it a minute later"
else
  bad "uninstall did not boot out both services: $(tr '\n' ' ' < "$U/calls")"
fi
grep -qE 'launchctl (load|unload) -w|^unload -w' "$U/calls" \
  && bad "uninstall used a -w verb — that writes the persistent disable it must never write" \
  || ok "uninstall writes no persistent disable (no -w verb was issued)"
# ⛔ AND A SURVIVOR IS FATAL (review finding: this arm had no fixture). The watchdog may be loaded in a
# domain the gui/-scoped `lc_bootout` cannot see; deleting the plist and carrying on would leave it RUNNING
# and reloading the loop — the exact race the ordering exists to prevent. So: non-zero, plist kept, and the
# loop is NOT touched (removing it would be undone a minute later by the survivor).
: > "$U/home/Library/LaunchAgents/com.eldato.orchestrator-watchdog.plist"
: > "$U/home/Library/LaunchAgents/$LOOP_LABEL_TEST.plist"
: > "$U/calls"; : > "$U/booted"; : > "$U/persist_watchdog"
_iu_un >"$U/un3" 2>&1; _rc3=$?
[ "$_rc3" -ne 0 ] \
  && ok "a watchdog that SURVIVES the bootout makes --uninstall exit NON-ZERO (it cannot be shown removed)" \
  || bad "uninstall exited 0 over a watchdog it could not remove: $(tail -2 "$U/un3" | tr '\n' ' ')"
[ -f "$U/home/Library/LaunchAgents/com.eldato.orchestrator-watchdog.plist" ] \
  && ok "the survivor's plist is KEPT — it is the only handle a retry (or a human) has" \
  || bad "the plist was deleted over a watchdog that is still loaded"
grep -q "^bootout .*$LOOP_LABEL_TEST\\.plist" "$U/calls" 2>/dev/null \
  && bad "uninstall went on to remove the LOOP while the watchdog survives — the survivor reloads it" \
  || ok "the loop is NOT removed while the watchdog survives"
rm -f "$U/persist_watchdog"

# ── 12) the SECOND launchd service must not corrupt the controller verdict ──────────────────────
# ⛔ This change adds `com.eldato.orchestrator-watchdog`, so a controller verdict read with
# `awk '/orchestrator/{print $1}'` would now answer with the WATCHDOG's pid — a false UP on liveness,
# which is the one thing this report exists not to do. main fixed that read STRICTLY further than this
# branch did (an anchored `HARNESS_UNIT_RE` + the pid FIELD, so a foreign repo's job cannot answer
# either) and added a PLATFORM branch, so the stub below is only reachable on macOS: the check keeps
# its subject there, and on Linux it pins the newer property instead — that the verdict is NOT taken
# from a launchctl stub at all (the #1856/#1859 class, which a launchctl-reading Linux arm would
# reintroduce).
echo; echo "── a second launchd service does not change the controller verdict ──"
R="$T/report"; mkdir -p "$R/bin" "$R/o"
cat > "$R/bin/launchctl" <<'SH'
#!/bin/bash
# The full `launchctl list` table. Both labels are present: the loop is LOADED BUT STOPPED ("-"),
# the watchdog is running. This is the state that produced the false UP.
printf 'PID\tStatus\tLabel\n-\t0\tcom.eldato.orchestrator-loop\n4242\t0\tcom.eldato.orchestrator-watchdog\n'
SH
chmod +x "$R/bin/launchctl"
printf '1\n' > "$R/o/heartbeat"
rep() { env -u OR -u REPO HOME="$R/home" O="$R/o" PATH="$R/bin:$PATH" bash "$HERE/report.sh" 1 2>&1; }
OUT="$(rep)"
if [ "$(uname -s)" = "Darwin" ]; then
  case "$OUT" in
    *"UP (pid"*) bad "report.sh reads a SECOND service's pid as the controller's: $(printf '%s' "$OUT" | sed -n '3p')" ;;
    *"NOT RUNNING"*) ok "report.sh: controller stopped + watchdog running → NOT RUNNING (a substring label match would say UP)" ;;
    *) bad "report.sh: neither UP nor NOT RUNNING — $(printf '%s' "$OUT" | sed -n '3p')" ;;
  esac
else
  # On Linux the verdict must come from the platform branch (the cloud-cell supervisor, or an explicit
  # "cannot ask the supervisor") — NEVER from this stub. Asserted on the controller SECTION, because a
  # supervisor's own status text is arbitrary while a launchd verdict has a fixed shape.
  CB="$(printf '%s\n' "$OUT" | awk '/── controller ──/{f=1;next} f&&/^$/{exit} f')"
  case "$CB" in
    *"UP (pid"*) bad "report.sh read a launchd stub's pid as the controller on $(uname -s) — the verdict must not come from launchctl here: $(printf '%s' "$CB" | head -1)" ;;
    *4242*) bad "report.sh reported the launchd stub's pid (4242) in the controller section on $(uname -s)" ;;
    *) ok "report.sh: on $(uname -s) a launchd stub is NOT consulted — the controller verdict comes from the platform branch (supervisor status, or the explicit cannot-ask line)" ;;
  esac
fi
# ...and the same report must still recognise a RUNNING controller (the fix must not break the yes).
cat > "$R/bin/launchctl" <<'SH'
#!/bin/bash
printf 'PID\tStatus\tLabel\n4242\t0\tcom.eldato.orchestrator-loop\n-\t0\tcom.eldato.orchestrator-watchdog\n'
SH
chmod +x "$R/bin/launchctl"
OUT="$(rep)"
if [ "$(uname -s)" = "Darwin" ]; then
  case "$OUT" in
    *"UP (pid 4242"*) ok "report.sh: a running controller is still reported UP with ITS pid (the exact-label read keeps the yes)" ;;
    *) bad "report.sh: a running controller is no longer reported UP — $(printf '%s' "$OUT" | sed -n '3p')" ;;
  esac
else
  CB="$(printf '%s\n' "$OUT" | awk '/── controller ──/{f=1;next} f&&/^$/{exit} f')"
  case "$CB" in
    *"UP (pid 4242"*) bad "report.sh reported UP from a launchd stub on $(uname -s) (the stub answers a state this platform cannot read)" ;;
    *4242*) bad "report.sh reported the launchd stub's pid (4242) in the controller section on $(uname -s)" ;;
    *) ok "report.sh: the RUNNING-controller fixture is also answered by the platform branch, not the stub — no launchctl read on $(uname -s)" ;;
  esac
fi

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL${SKIPPED:+ SKIPPED=$SKIPPED}"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
