#!/bin/bash
# watchdog.sh — put the controller's launchd service BACK if it has been REMOVED.
#
# WHY THIS EXISTS. The controller does not merely crash; it gets removed. `launchctl unload -w` —
# and a `bootout` whose following `bootstrap` then fails — both leave a PERSISTENT disabled flag,
# and launchd's `KeepAlive` cannot restart a service that is no longer in the domain. The plist is
# still on disk, nothing logs an error, and the box just stops dispatching. Measured five times on
# 2026-10-17: `Setting service … to disabled` → `removing service` → dead controller, with no error
# anywhere the fleet looks. KeepAlive covers a crash; this covers removal. Proven on the live box:
# the loop was booted out and the log recorded a recovery five seconds later.
# REAL ARTEFACT (not a remembered pid): ~/orchestrator/logs/watchdog.log holds five removals and five
# recoveries from 2026-10-17 — e.g. `21:26:40Z ABSENT from launchctl — reloading` followed by
# `21:26:48Z recovered: pid=54673`.
#
# ⛔ IT WILL ALSO RE-START WHAT A HUMAN DELIBERATELY STOPPED — that is the same state, and no launchctl
# call can tell the two apart. Any UNDECLARED stop produces exactly the ABSENT state this script
# recovers from: README §6 opens with `touch $O/.watchdog-off` (step 0) precisely because a controller
# stopped IN PLACE (its step 2, `pkill -f "[b]ash $O/orch-loop.sh"`) is this script's recovery trigger —
# so without the declaration the controller would be back within one interval, under a human who had
# just been told the machine was safe to touch. (Step 1, `install.sh --uninstall`, removes this agent
# itself, so it needs no declaration; and the `-w` forms are never the path — #1975.) A deliberate stop therefore has to be
# DECLARED, and the declaration is a FILE — it survives a reboot and needs no memory of a command:
#
#     touch "$O/.watchdog-off"     # declare the stop: the watchdog does nothing while it exists
#     rm -f "$O/.watchdog-off"     # re-arm
#
# The ARMED state is the absence of that file, so once the AGENT IS LOADED it needs no extra step, and
# forgetting to re-arm fails in the safe direction (the controller stays down, visibly). ⛔ Loading the
# agent is its own step: `install.sh` only renders and seeds it (it never loads an agent), so a fresh
# install is NOT protected until the load command it prints has been run.
#
# Deliberately dumb: read the service's state with launchctl's OWN status verb, load it if it is
# gone, log what happened, exit. No retries, no heuristics, no inspection of the queue.
#
# INSTALL. Rendered by install.sh into ~/Library/LaunchAgents/com.eldato.orchestrator-watchdog.plist
# (template: watchdog.plist.template), with this script seeded at $O/watchdog.sh. Every path below
# is HOME/$O-relative on purpose — a absolute path baked into a shipped file is why the cloud cells
# launched a controller out of a directory that did not exist on them and dispatched nothing.
set -uo pipefail

LABEL="${WATCHDOG_LABEL:-com.eldato.orchestrator-loop}"
O="${O:-$HOME/orchestrator}"
PLIST="${WATCHDOG_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LOG="$O/logs/watchdog.log"
# Seconds to wait before deciding whether the load took. launchd's own bookkeeping is asynchronous,
# so an immediate re-read reports the old state and would log a false failure on every recovery.
SETTLE="${WATCHDOG_SETTLE:-5}"
# ⛔ GUARD-BEFORE-USE, like every other limit in this harness. A typo'd override (WATCHDOG_SETTLE=abc)
# makes every `sleep` below fail SILENTLY — there is no `set -e`, so the wait collapses to zero — and the
# waits are what stop an asynchronously-updated domain from being read as "still absent" and bootstrapped
# a second time (two jobs on one label; `--uninstall` stops one, the survivor's KeepAlive resurrects the
# loop). Measured with `abc`: four `sleep: invalid time interval` on stderr, BOTH bootstraps issued.
case "$SETTLE" in ''|*[!0-9]*) SETTLE=5 ;; esac
# ...and BOUND it: an all-digit value `sleep` rejects (999999999999999999999) also collapses the wait to
# zero (driven: identical log timestamps, 0 s elapsed), and a pass can sleep up to 4×SETTLE, so anything
# over 10 s overruns the plist's 60-second StartInterval and lets a second instance into `boot_svc`.
# 0 is allowed because the test suite needs a wait-free run; the plist forwards only HOME and O, so a
# deployed box always gets the built-in 5.
[ "$SETTLE" -le 10 ] 2>/dev/null || SETTLE=5
DECLARED_OFF="$O/.watchdog-off"
# The controller's single-instance lock — written by orch-loop.sh, reclaimed only when its pid is dead.
LOCKF="$O/.orch.lock"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG" 2>/dev/null || true; }
# ⛔ ONE LINE, NOT ONE PER PASS. A declared stop or an outside-launchd controller can persist for
# weeks, and 1,440 identical lines a day would bury the recoveries that are this log's whole value
# (the suite already refuses noise on a healthy box for the same reason). So a long-lived condition
# is reported only when the log's LAST line is not already that message — a transition, not a poll.
# The key is printed as the line's head so the last-line comparison has something stable to match and
# the log reads `outside launchd — a controller is running (pid=…)` instead of the key as stray prose.
say_once() {
  local want="$1" last; shift
  last="$(tail -1 "$LOG" 2>/dev/null)"
  case "$last" in *"$want"*) return 0 ;; esac
  say "$want — $*"
}
mkdir -p "${LOG%/*}" 2>/dev/null || true

# Nothing installed → nothing to watch. `install.sh --uninstall` removes the plist, and the old loop
# plist being gone is also what makes an uninstalled box quiet.
[ -f "$PLIST" ] || exit 0

# A declared stop is not a failure. Say it once and do nothing else.
if [ -e "$DECLARED_OFF" ]; then
  say_once "declared stop" "the service is left alone while $DECLARED_OFF exists (README §6)"
  exit 0
fi

# ── state: ONE tri-state read, parsed with the repo's canonical shape ────────────────────────────
# ⛔ `launchctl print <domain>/<label>` IS THE READ, and the reason is written in this repo twice.
# `launchd-cycle.sh`'s `lc_pid` uses it because "`launchctl list <label>` … prints nothing structural on
# current" macOS, and the durability suite pins the parse against a CAPTURED REAL BLOCK. This file
# originally parsed `launchctl list <label>` instead — the two shipped files then disagreed about the
# output shape, and the disagreement is not academic: a parse that reads "no pid" from a HEALTHY
# controller `kickstart -k`s it every 60 seconds, which is the one outcome this script forbids. So the
# canonical read wins, and the pid comes from the same captured block as the verdict.
#
# ⛔ THE THIRD STATE IS THE POINT (`lc_probe`, launchd-cycle.sh): 0 = LOADED (READ_BLOCK holds the
# block), 1 = definitively ABSENT from every one of this user's domains, 2 = the read FAILED and says
# NOTHING about the job. Folding 2 into either answer is how a failed read becomes a kickstart against a
# healthy controller (a `launchctl list` that exits non-zero on an EIO read is indistinguishable from
# "absent" by exit status alone — measured EIO is the 2026-10-17 failure this agent exists for).
#
# `print` needs a DOMAIN where `list` did not, so both are tried in the order the ACTION verbs use. (No
# "remembered domain": the action verbs re-probe both, which is what keeps a stale domain from steering a
# verb — `launchd-cycle.sh` deleted a zero-caller helper of exactly that shape.)
READ_BLOCK=""; READ_RC=0
read_state() {
  local d out rc unknown="" diag=""
  READ_BLOCK=""; READ_RC=1
  for d in $DOMAINS; do
    out="$(launchctl print "$d/$LABEL" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then READ_BLOCK="$out"; READ_RC=0; return 0; fi
    case "$out" in
      # The service is not in THIS domain — try the next one.
      *"Could not find service"*|*"not find service"*|*"service not found"*) continue ;;
      # ⛔ A DOMAIN-LEVEL REJECTION IS NOT A FAILED READ OF THE SERVICE, and returning UNKNOWN here made
      # the agent PERMANENTLY INERT on exactly the boxes whose job lives in `user/`. launchd answers
      # `print gui/<uid>/<label>` with `Bad request.` + `Could not find domain for user gui: <uid>` when
      # that domain does not exist for this user (measured; a non-GUI login, uid 0, or an SSH-only
      # session) — it says NOTHING about the job. So: try the next domain, which is why DOMAINS has two.
      # ⛔ ONLY THE LINE THAT NAMES A MISSING DOMAIN IS THE "this domain cannot hold the job" answer.
      # A BARE `Bad request.` is launchd rejecting the REQUEST, and the repo pins it as UNKNOWN
      # (launchd-cycle.sh's lc_probe returns 2 for it; the durability suite asserts it). Folding a
      # bare rejection into the domain-missing arm would make an unreadable state read as ABSENT,
      # and then issue enable/bootstrap on it — a mutation decided from an error message.
      *"Could not find domain"*) continue ;;
      # ⛔ A WRITER THAT DIED AFTER PRINTING THE BLOCK IS NOT A FAILED READ — the answer arrived. This is
      # the SIGPIPE shape a `| grep -q` reader CAUSES (`grep -q` exits at the first match and closes the
      # pipe; under `pipefail` the pipeline then reports 141). Nothing here pipes, but the rule holds
      # anyway: the exit status of a writer must not outvote a complete block it printed, or a healthy
      # controller gets read as UNKNOWN and the recovery is suppressed for no reason.
      *"pid = "*|*"= {"*) READ_BLOCK="$out"; READ_RC=0; return 0 ;;
      # ⛔ A FLAG, NOT THE DATUM (the empty-is-falsy trap this repo has been bitten by): `launchctl print`
      # exiting NON-ZERO WITH NO OUTPUT stores "" in a datum-style flag, `[ -n "$unknown" ]` is then false,
      # and an unreadable state would be reported as definitively ABSENT — issuing enable/bootstrap and a
      # false `recovered:` over a read that established nothing. The diagnostic is kept separately.
      *) unknown=1; diag="$out" ;;
    esac
  done
  # Nothing in this user's domains answered usefully. An UNRECOGNISED answer is UNKNOWN (2), not
  # "absent" — the only answer that means "not here" is launchd's own service-level not-found, and it was
  # already consumed by the `continue` above.
  if [ -n "$unknown" ]; then READ_BLOCK="$diag"; READ_RC=2; return 2; fi
  READ_RC=1; return 1
}
# ⛔ NEVER READ THE BLOCK WITH A `| grep -q` PIPELINE. The script runs under `set -o pipefail`, and
# `grep -q` exits at the first match and CLOSES THE PIPE — the writer can then be killed by SIGPIPE
# (rc 141) after printing a perfectly good block, and pipefail reports the PIPELINE as failed. The
# verdict flips on a scheduler race: measured intermittently (2 runs in 25) as "present but not
# running — kickstarting" over a HEALTHY controller, followed by a kickstart that interrupts it
# mid-cycle and strands that cycle's lanes, lock and claim. Nothing here pipes; the block is captured
# whole and matched in the shell, so the writer's exit status cannot outvote its output.
# `pid = N` sits at the TOP LEVEL of the service block (nested process blocks carry `state = active`),
# so the first match is the job's own pid — the parse `lc_pid` pins against a captured real block.
running() { case "$READ_BLOCK" in *'pid = '*) return 0 ;; esac; return 1; }
pid_of() { awk '/^[[:space:]]*pid = [0-9]+$/ { print $3; exit }' <<<"$READ_BLOCK"; }

# ⛔ THE STATE READS ARE DOMAIN-AGNOSTIC; THE ACTION VERBS ARE NOT. `launchctl list <label>` finds a
# job in any of this user's domains, but `enable`/`kickstart`/`bootstrap` need <domain>/<uid>/<label>,
# and a job in `user/` is invisible to `gui/` (measured on this box: `launchctl print
# gui/501/<a user-domain service>` → "Could not find service … in domain for user gui: 501" while
# `launchctl list <same label>` succeeded). `launchctl bootstrap <domain> <plist>` lands the job in
# `gui/` from a GUI session and in `user/` from an SSH one — so each verb tries both and
# takes the first that succeeds. Hardcoding `gui/` is the round-1 defect in a new dimension: a remedy
# that cannot act on the state it was written for, silently swallowed by `|| true`.
DOMAINS="gui/$(id -u) user/$(id -u)"
enable_svc() { local d; for d in $DOMAINS; do launchctl enable "$d/$LABEL" 2>/dev/null && return 0; done; return 1; }
# ⛔ `kickstart` WITHOUT `-k`. `-k` kills the running instance first, and the state being remedied
# ("in the domain with no pid") never needs a kill — while the READ that found it is stale by
# construction (the lock checks run between the read and the verb), so a KeepAlive respawn landing in
# that window would be KILLED mid-cycle: stranded lanes, a stranded lock and a stranded claim, the one
# outcome this file forbids. Plain `kickstart` starts a stopped job and is a no-op on a running one.
kick_svc()   { local d; for d in $DOMAINS; do launchctl kickstart "$d/$LABEL" 2>/dev/null && return 0; done; return 1; }
boot_svc() {
  local d
  # ⛔ THE VERBS ARE `bootstrap` THEN PLAIN `load`, NEVER THE `-w` FORMS (#1975). `-w` writes a
  # PERSISTENT Disabled override — the exact state this script exists to repair — so the sequence here
  # is the same one `launchd-cycle.sh`'s `lc_start` uses, for the same measured reason: on 2026-10-17
  # `bootstrap` failed with EIO and the LEGACY `load` is what brought the controller back. `enable` has
  # already cleared any disable flag, so `bootstrap` re-adds the job without writing one.
  #
  # ⛔ A VERB'S EXIT STATUS IS NOT A VERDICT HERE. `load` prints "Load failed: 5: Input/output error" and
  # exits 0 (measured), and `bootstrap` reports a real failure on the same job — so a fallback gated on
  # rc alone can never fire in exactly the case it exists for. The STATE is re-read instead, because
  # that is the only thing that says whether the job came back. Re-reading also stops the fallback from
  # installing the SAME plist into a SECOND domain: after every attempt the state decides, so
  # `bootstrap user/` is never reached once `gui/` holds the job (two launchd jobs on one
  # label = an uninstall that stops only one of them, and a KeepAlive that resurrects the other).
  for d in $DOMAINS; do
    launchctl bootstrap "$d" "$PLIST" 2>/dev/null || true
    # launchd's bookkeeping is ASYNCHRONOUS — the same reason `SETTLE` exists below. Without this wait the
    # re-read can report the OLD state for a bootstrap that did install the job, and the fallback would
    # then load a SECOND domain: two launchd jobs on one label, of which `--uninstall` stops one, and the
    # survivor's `KeepAlive` resurrects the loop under a human who was told it was stopped.
    sleep "$SETTLE"
    read_state || true
    # ⛔ AN UNREADABLE RE-READ ENDS THE LADDER. A plain "is it loaded" test answers FALSE for both
    # "definitively absent" (READ_RC 1) and "could not read" (READ_RC 2), so folding them here would continue
    # into the NEXT domain after a bootstrap that may well have installed the job — on an EIO read, i.e. exactly the
    # failure family this agent exists for. That is the second-job-on-one-label state the paragraph above
    # calls impossible: `--uninstall` stops one of them and the survivor's KeepAlive resurrects the loop.
    # So an unreadable state stops the ladder and reports UNPROVEN; it never justifies another verb.
    if [ "$READ_RC" -eq 2 ]; then
      say "recovery UNPROVEN — a verb was issued and launchd could not be read back (${READ_BLOCK:-no output}); stopping rather than stacking a second job on one label"
      return 1
    fi
    [ "$READ_RC" -eq 0 ] && return 0
  done
  # LAST RESORT: the legacy path `lc_start` also keeps — PLAIN `load` (it infers the domain from the
  # plist), never `load -w`.
  launchctl load "$PLIST" 2>/dev/null || true
  sleep "$SETTLE"
  read_state || true
  [ "$READ_RC" -eq 0 ] && return 0
  return 1
}

# ⛔ A PRESENT-AND-RUNNING SERVICE IS LEFT ALONE — this is the property that makes a 60-second
# watchdog safe. It acts only when the service is NOT RUNNING (which includes "in the domain with no
# pid", handled below), never on a hunch, so it cannot interrupt a controller mid-cycle (which would
# strand its lanes, its lock and its claim).
#
# ⛔ ONE CAPTURED READ DECIDES THE WHOLE BRANCH (`ST`), then the pid is read out of the SAME block. The
# first version read "is it running" at the top and "is it loaded" again below, with the lock checks in
# between: a controller that launchd respawned in that window read "not running" and then "loaded", so
# the watchdog ran `kickstart -k` on the fresh process — the same two-reads-one-decision defect this
# file calls out for the verdict line. `read_state` is the single authority now.
read_state || true; ST="$READ_RC"
if [ "$ST" -eq 2 ]; then
  # ⛔ AN UNREADABLE LAUNCHD IS NOT "NOT RUNNING". Nothing is issued, and the log names the failed read
  # — the alternative is a kickstart against a healthy controller decided from an error message.
  say "unreadable state — launchd's state for $LABEL could not be read (${READ_BLOCK:-no output}); whether a controller is running is UNKNOWN, so this pass acted on NOTHING. ⛔ A REPEATED LINE HERE IS THE SIGNAL: launchd itself is unhealthy (or the domain is missing), and this agent cannot recover anything until it can read again"
  exit 1
fi
if [ "$ST" -eq 0 ] && running; then exit 0; fi

# ⛔ A RUNNING CONTROLLER IS LEFT ALONE EVEN WHEN LAUNCHD DID NOT START IT. The controller also runs
# under `nohup ./orch-loop.sh` from a pane (README §4), and `launchctl list` cannot see that process —
# so on a nohup box this script read ABSENT, loaded the service, the spawned controller exited on its
# own single-instance lock ("already running"), the post-check failed, and every pass for the life of
# the box logged RECOVERY FAILED and kickstarted the job. That is a false alarm in the one log whose
# only value is being trustworthy (review round 2; measured: a live `orch-loop.sh` while both labels
# were absent from both domains). The CONTROLLER'S OWN LOCK is the authority on "is a controller
# running" — `orch-loop.sh` writes `$$` into it at startup and reclaims it only when that pid is dead,
# so it answers for launchd, nohup and a hand-started pane alike. Deferring here is also the
# fail-closed direction: a stale-but-live pid makes us do NOTHING, never kill or replace anything.
if [ -f "$LOCKF" ]; then
  CPID="$(cat "$LOCKF" 2>/dev/null || echo 0)"
  if [ "${CPID:-0}" -gt 0 ] 2>/dev/null && kill -0 "$CPID" 2>/dev/null; then
    # ⛔ LIVENESS IS NOT IDENTITY. A pid recycled by an unrelated process, or a lock left behind by a
    # controller that was SIGKILLed, would defer recovery FOREVER — one "outside launchd" line and then
    # silence while the service stays removed. That is the stale-flag-never-revalidated failure, and the
    # watchdog must not inherit it. The command is captured and matched (never `| grep -q`, see above).
    # The match is on the `.sh` TOKEN, not on `orch-loop` as a substring: `tail -f logs/orch-loop.log` is
    # a command §4/§6 tell a human to run, and a substring test read it as a controller.
    _cmd="$(ps -p "$CPID" -o command= 2>/dev/null)"
    case "$_cmd" in
      "")
        # ⛔ UNVERIFIABLE IS NOT "NOT A CONTROLLER" (AGENTS.md: if a read is unclear, report, do not act).
        # Both directions are wrong and cannot be repaired from here, so hand it to a human explicitly.
        say_once "lock holder unverifiable" "pid=$CPID holds $LOCKF but its command line could not be read — inspect it; the service is being left alone"
        exit 1 ;;
      *orch-loop.sh*)
        # Residual, on purpose: a live process whose argv merely HAS the token (a human running
        # `vi orch-loop.sh`, or `bash -x orch-loop.sh`) reads as a controller here — because argv is the
        # only identity available: the lock records a bare PID (`orch-loop.sh` writes `$$`), and a lock
        # that also bound an IDENTITY (argv, or a start time) does not exist today. It is tolerable
        # because this path only DEFERS, never writes: the calls it made are reads alone (`launchctl
        # print` per domain, per `read_state`), never enable/load/kickstart/bootstrap — so the cost is a
        # missed recovery while an editor is open on the file, and the next pass re-reads it. The root
        # fix belongs to the controller's lock.
        say_once "outside launchd" "a controller is running (pid=$CPID) — not touching the service"
        exit 0 ;;
      *)
        # ⛔ THE LOCK NAMES SOMETHING THAT IS NOT THE CONTROLLER, AND RELOADING CANNOT FIX IT.
        # `orch-loop.sh` defers to ANY LIVE pid in this file (`already running` → exit 0), so a service
        # launched now would exit immediately and every pass would log a recovery that never happened.
        # Deleting the lock here is the tempting fix and the wrong one: it is the controller's mutual
        # exclusion, and a false negative in the match above would then let TWO controllers sweep one PR
        # queue (agent-infra#1715). Say the true thing and hand it over; the root fix belongs to the
        # controller's own lock rule (filed as a follow-up).
        say_once "stale lock" "$LOCKF names pid=$CPID, alive but not an orch-loop controller — a controller started now would exit on that lock; remove it (or restart the box) and the next pass recovers"
        exit 1 ;;
    esac
  fi
fi

# ⛔ TWO DIFFERENT REMEDIES, because the two states are NOT the same state (review round 1, measured
# on this box with a throwaway `com.example.wdprobe` agent):
#
#   loaded && !running — `load -w` does NOT restart a job that is already in the domain. It fails
#        ("Load failed: 5: Input/output error") and **exits 0**, so a `load || bootstrap` fallback
#        could never fire for this case, and `bootstrap` fails too ("Bootstrap failed: 5", rc=5).
#        Measured: `load -w` (second time) -> rc=0, job NOT restarted; `bootstrap gui/501 <plist>` ->
#        rc=5; `kickstart -k gui/501/<label>` -> PID back (54057), rc=0. `kickstart` is the verb that
#        starts a loaded-and-stopped job (the `-k` form measured the same PID back; it ships WITHOUT `-k`
#        so it can never kill a controller that respawned between the read and the verb), and this is the
#        state a crash-looping KeepAlive controller is throttled into — so it is real, not theoretical.
#        Before this fix the script logged RECOVERY FAILED forever while the remedy was in its own hands.
#   absent — the job left the domain (a persistent-disable verb, or a failed bootstrap). Recovery is
#        `enable` then `bootstrap` (plain `load` as the last-resort fallback) and NEVER the `-w` forms:
#        `-w` writes the persistent Disabled override, which is exactly the state this branch repairs
#        (#1975, and the durability suite refuses a shipped line that issues one).
if [ "$ST" -eq 0 ]; then
  say "present but not running (pid=none) — kickstarting"
  enable_svc || true
  kick_svc || true
else
  say "ABSENT from launchctl — reloading"
  enable_svc || true
  boot_svc || true
fi
sleep "$SETTLE"

# ⛔ ONE READ DECIDES BOTH "DID IT COME BACK" AND "WHAT PID". Two separate reads meant a controller
# that died in the window between them logged `recovered: pid=` (EMPTY) and exited 0 — a false PASS in
# the line that is the only evidence a recovery happened (review round 3, reproduced with a stub that
# answers running, then no-PID). The pid IS the verdict: none, no recovery. It is read out of the SAME
# captured block the verdict came from.
read_state || true
# ⛔ A FAILED READ AFTER THE ATTEMPT IS NOT "STILL NOT RUNNING". Third state again: if launchd cannot be
# read back, the recovery is UNPROVEN — saying "the service is still not running" would assert a fact
# this pass did not establish, in the one line the fleet uses to decide whether to act.
if [ "$READ_RC" -eq 2 ]; then
  say "RECOVERY UNPROVEN — the recovery was attempted, but launchd's state could not be read back (${READ_BLOCK:-no output}); whether the service is running is UNKNOWN"
  exit 1
fi
RPID="$(pid_of)"
if [ -n "$RPID" ]; then
  say "recovered: pid=$RPID"
else
  # ⛔ THE RETRY BELONGS TO LAUNCHD, NOT TO THIS SCRIPT. The plist's StartInterval re-runs us every
  # 60 s, so a recovery that did not take is attempted again a minute later; an inner retry loop
  # would only multiply the attempts and bury the cause (a plist that no longer parses, a missing
  # binary, a full disk). Exit NON-ZERO so the failure shows up in launchd's own LastExitStatus as
  # well as in the log.
  say "RECOVERY FAILED — the service is still not running; needs a human"
  exit 1
fi
