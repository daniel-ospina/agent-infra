#!/usr/bin/env bash
# fleet-inventory.test.sh — the regression contract for the bundled fleet supervisor's INVENTORY.
#
# WHAT THIS SUITE IS FOR. The owner asked for one script that runs every fleet process AND checks they
# are all alive, "so we get neither broken duplication nor a component that is silently off, missing,
# or running twice" (2026-10-18). Four of those five failures were observed on one night. Each arm
# below pins one of them, and every arm is a behaviour that did not exist before this change:
#
#   §1  DUPLICATE FIRES ON TWO LIVE INSTANCES — the controller, and a pidfile loop. A lock file is not
#       proof: the measured duplicate ran with a lock present. §1c is the same read on the same box
#       with ONE instance, so §1a cannot pass by always reporting DUPLICATE.
#   §2  MISSING FIRES WHEN ONE IS ABSENT — both for the controller (no process, no live lock owner)
#       and for a pidfile loop, and the pidfile's own STALE pid is named rather than trusted.
#   §3  THE MATCHER DOES NOT MATCH ITSELF — the hardest form: the checker's OWN argv is exactly
#       `<shell> <component path>`, which is what `pgrep -f "orch-loop.sh"` counted (it matched the
#       shell that ran it). Also: a shell whose TEXT mentions the path, and a reader of its log.
#   §4  SKIPPED IS DISTINGUISHABLE FROM OK — its own state, its own reason, and a PASS for the exit
#       code (a Mac is not broken for having no cell supervisor) while never rendering as OK.
#   §5  THE EXIT CODE REFLECTS THE WORST ROW — 0 all-OK/SKIPPED, 1 any not-OK, 2 any UNKNOWN
#       (an unreadable process table is an abstention, never a pass).
#
# NON-VACUITY. Each arm is a behaviour of the SHIPPED predicates, so it is shown non-vacuous by
# pointing the suite at a neutered copy of the library — the recipe at the bottom of this header.
#
# Hermetic: a temp HOME, a temp state dir, temp component paths, and a `launchctl` STUB on PATH. No
# real launchd, no real fleet process, no network, nothing read from or written to the operator's
# own directories. Every fixture process is killed on exit and the paths live under a temp dir.
#
# Run:  bash scripts/fleet-inventory.test.sh
#       FLEET_LIB=/tmp/neutered-fleet-inventory.sh bash scripts/fleet-inventory.test.sh
#
# ⛔ NON-VACUITY RECIPE: copy scripts/lib/fleet-inventory.sh somewhere and point FLEET_LIB at it.
# Verified mutations and the arms each reddens (each was run; the added §9x arms are the ones the
# review of this change forced, one per defect it reproduced):
#   (a) drop the `q == self` clause from `_fleet_ps_awk`                    → §3 (self-match) only
#   (a2) RESTORE the ancestor exclusion (the pre-review behaviour)          → §9a only
#   (b) drop the `n -gt 1` DUPLICATE branch of `fleet_row_controller`       → §1a only (3 arms)
#   (c) make `fleet_state_severity` return 0 for every state                → §1a's "DUPLICATE row must
#       fail the table", §2's "MISSING row must fail the table", and all §5 severity arms (5 arms):
#       EXPECTED, because that one function IS the exit-code contract those arms assert
#   (d) restore `|| return 0` on the bootout (drop the read-after)          → §7b only
#   (e) drop the UNKNOWN pre-check in `fleet_ensure_components`             → §8's first two arms
#   (f) fold "unreadable plist" into "key absent"                           → §9b only
#   (g) render "code present, no job" as SKIPPED again                      → §9c (2 arms: the state
#       AND the severity arm — the second one only couples after the severity_of_row fix)
#   (h) point the cadence row back at the sibling loop's log                → §9d (2 arms)
#   (i) delete the landers' expiry bound                                    → §9e only
#   (j) classify the watchdog PAIR as DUPLICATE again                       → §9g only
#   (k) drop the kickstart after a bootstrap                                → §9h only
#   (l) drop the start-side restore of watchdog-loop.sh                     → §9i (2 arms)
#   (m) treat an unreadable process age as ownership (the pre-review fold)  → §9k only
#   (n) delete the read-before-launch in `fleet_start_component`            → §9l (2 arms)
#   (o) drop the `FLEET_PS_CACHE=""` before the start read-back             → §9m only
#   (p) move the watchdog's last-exit read back behind the pair branch      → §9n (2 arms)
#   (q) drop the cadence stale-copy note                                    → §9o only
#   (r) run the loop launcher in the FOREGROUND (no detach)                 → §9j only (and the whole
#       suite goes from ~35s to ~5min: the wall clock is the symptom the arm pins)
#   (s) nest the cell-identity test back inside "supervisor script missing" → §9p + §4 (a Linux dev
#       box / CI runner reads MISSING again: the entry point's supervisor path always EXISTS)
#   (t) do not clear a pidfile the row has PROVEN stale                        → §9q (2 arms: start
#       cannot repair the row, and the row stays FAILING afterwards)
#   (u) have the caller assume it started something                          → §9r only
#   (v) accept any non-empty FLEET_CELL_HOME as cell identity                → §9p only (a defaulted
#       path made every Linux box a "cell": the entry point defaults CELL_HOME)
#   (w) delete a pidfile naming a live copy at ANOTHER PATH (no basename proof) → §9q(b) only (start
#       manufactured a duplicate, then read OK over two live loops)
#   (x) refuse the repair entirely                                         → §9q (2 arms)
#   (aa) render a STALE lander-drain record as OK (delete the LATE verdict)    → §9u only (2 arms)
#   (y) hard-code the heartbeat loop's bound instead of reading
#       `FLEET_HEARTBEAT_LATE_S`                                           → §9t's LATE arm only
#   (z) hard-code the cadence row's bound instead of reading
#       `FLEET_CADENCE_LATE_S`                                             → §9t's LATE arm only
#   (aa) drop `+ $FLEET_JOB_SLACK_S` from the launchd freshness bound       → §9t's job-slack OK arm
#   (ab) hard-code the controller's bound instead of reading
#       `FLEET_CONTROLLER_LATE_S`                                           → §9t's controller LATE arm
#   (ac) restore the zero-tolerance fence (drop the shared 5 s slack)            → §9v (deterministic
#       on EVERY platform). §9k's owner arm and §9u's fresh-lock arm assert the same property but are
#       only probabilistic: they redden when the two clock sources disagree (the Linux-only accident
#       that produced the bug), and stayed GREEN on macOS — which is why §9v was added
#   (ae) skip the slack validation (read PID_START_SLACK_SECONDS raw)             → §9v only when
#       the env supplies a non-integer: `1.5` makes the arithmetic a syntax error, the test fails, and
#       the fence is SKIPPED (the pid is then claimed on argv alone → §9u's recycled arm reddens)
#   (ad) drop the recycled-pid fence entirely (accept any live pid in the lock) → §9u only
# A red in a section the mutation does not name means the arm is coupled to the wrong behaviour —
# e.g. (b) reddening §2 would mean §2 is asserting the controller's duplicate logic.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_LIB="${FLEET_LIB:-$HERE/lib/fleet-inventory.sh}"

PASS=0; FAIL=0
ok()  { printf '  ✅ %s\n' "$*"; PASS=$(( PASS + 1 )); }
bad() { printf '  ❌ %s\n' "$*"; FAIL=$(( FAIL + 1 )); }
say_case() { printf '\n── %s ──\n' "$*"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-inventory-test.XXXXXXXX")" || exit 1
KIDS=""                      # in-process children
KIDS_FILE="$T/child-pids"    # children spawned through a subshell (`spawn_component` prints inside $( ) )
# kill9 — disown first: a killed JOB is announced by the shell's job control ("Killed: 9") even in a
# non-interactive script, and a passing suite must not print what looks like a crash.
kill9() { local p; for p in "$@"; do disown "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done; }
cleanup() {
  [ -n "$KIDS" ] && kill9 $KIDS
  [ -f "$KIDS_FILE" ] && kill9 $(cat "$KIDS_FILE") 2>/dev/null
  pkill -9 -f "$T/" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

[ -f "$FLEET_LIB" ] || { printf 'no library at %s\n' "$FLEET_LIB" >&2; exit 1; }

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# A component is spawned as a REAL process whose argv is `<shell> <exact path>` — the shape every
# predicate matches. `sleep` is the body, so the fixture is live but does nothing.
mk_proc_script() { # <path> [sleep-seconds]
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/bash\nsleep %s\n' "${2:-300}" > "$1"
  chmod +x "$1"
}
track() { printf '%s\n' "$@" >> "$KIDS_FILE"; }
spawn_component() { # <path> -> pid on stdout
  bash "$1" >/dev/null 2>&1 &
  local p=$!
  # ⛔ THE PID IS RECORDED IN A FILE, not in a variable: this function is called inside `$( )`, so it
  # runs in a SUBSHELL and a `KIDS="$KIDS $p"` here is discarded the moment it returns (measured in
  # review — every component fixture leaked, held only by the path-scoped `pkill` in cleanup()).
  track "$p"
  printf '%s\n' "$p"
}

H="$T/home"
O="$T/O"
SCRIPTS="$H/.pi/agent/scripts"
STATE="$H/.pi/agent/state"
A="$H/Library/LaunchAgents"
BIN="$T/bin"
mkdir -p "$SCRIPTS" "$STATE" "$A" "$O" "$BIN"

# The canned `launchctl list` table, and a stub that answers `list` from it. Anything else the
# inventory might ask for (bootstrap/kickstart/bootout) is RECORDED, never performed. The verbs are
# covered HERE too (§7 stop, §8 start): an earlier version of this comment claimed they were covered
# by orchestrator-bringup.test.sh, which references no `fleet_` function at all — a coverage claim
# with no artifact behind it (reviewer C: `rg -F 'fleet_' orchestrator-bringup.test.sh` → nothing).
LC_LIST="$T/launchctl.list"
: > "$LC_LIST"
cat > "$BIN/launchctl" <<'STUB'
#!/bin/bash
# `list` answers from the canned table. `bootout` REMOVES the label from it (so the read-after in
# fleet_stop_component sees the change) unless $FLEET_LAUNCHCTL_REFUSE_BOOTOUT exists — the arm that
# pins "a bootout that failed must not read as stopped". Everything else is recorded only.
if [ "${1:-}" = "list" ]; then cat "$FLEET_LAUNCHCTL_LIST"; exit 0; fi
printf '%s\n' "$*" >> "$FLEET_LAUNCHCTL_CALLS"
if [ "${1:-}" = "bootstrap" ]; then
  # A real bootstrap LOADS the job; the stub must too, or the read-after-bootstrap guard (which exists
  # to catch a bootstrap that reported success over nothing) refuses every start in the fixture.
  label="${3##*/}"; label="${label%.plist}"          # bootstrap's 3rd arg is the PLIST PATH
  [ -s "$FLEET_LAUNCHCTL_LIST" ] || printf 'PID\tStatus\tLabel\n' > "$FLEET_LAUNCHCTL_LIST"
  grep -q "	$label\$" "$FLEET_LAUNCHCTL_LIST" 2>/dev/null \
    || printf -- '-\t0\t%s\n' "$label" >> "$FLEET_LAUNCHCTL_LIST"
fi
if [ "${1:-}" = "bootout" ]; then
  if [ -f "${FLEET_LAUNCHCTL_REFUSE_BOOTOUT:-/nonexistent}" ]; then
    echo "Bootout failed: 5: Input/output error" >&2; exit 5
  fi
  label="${2##*/}"
  awk -F'\t' -v l="$label" 'NR==1 || $3 != l' "$FLEET_LAUNCHCTL_LIST" > "$FLEET_LAUNCHCTL_LIST.tmp" \
    && mv "$FLEET_LAUNCHCTL_LIST.tmp" "$FLEET_LAUNCHCTL_LIST"
fi
exit 0
STUB
chmod +x "$BIN/launchctl"
export FLEET_LAUNCHCTL_LIST="$LC_LIST" FLEET_LAUNCHCTL_CALLS="$T/launchctl.calls"
: > "$FLEET_LAUNCHCTL_CALLS"

# ⛔ AND A `plutil` STUB — the suite is registered as a CI shard, both lanes are `ubuntu-latest`, and
# Linux has no `plutil`. Without this the launchd arms read every declaration as UNREADABLE (8 arms
# red, then `run-bash-shards.sh` exits 1 and BOTH lanes redden on every run) — a suite that is green
# only on the author's Mac is not a contract. Same shape as
# `orchestrator-harness/install-launchd-durability.test.sh`, which stubs it for the same reason.
cat > "$BIN/plutil" <<'PLUTIL'
#!/usr/bin/env python3
# plutil < -extract KEY raw -o - FILE | -p FILE | -lint FILE >
import sys, plistlib
a = sys.argv[1:]
try:
    with open(a[-1], "rb") as f:
        d = plistlib.load(f)
except Exception:
    sys.stderr.write("plutil: cannot parse %s\n" % a[-1]); sys.exit(1)
if not a or a[0] == "-lint":
    sys.exit(0)
if a[0] == "-extract":
    k = a[1]
    if k not in d:
        sys.stderr.write("%s: no value at key path %s\n" % (a[-1], k)); sys.exit(1)
    v = d[k]
    print("true" if v is True else "false" if v is False else v)
    sys.exit(0)
if a[0] == "-p":
    print("{")
    for k, v in d.items():
        print('  "%s" => %s' % (k, v))
    print("}")
    sys.exit(0)
sys.exit(1)
PLUTIL
chmod +x "$BIN/plutil"

# A plist good enough for `plutil -extract`: the inventory reads StartInterval/StandardOutPath from
# the job's OWN declaration, so an arm that cares about freshness needs a real one.
mk_plist() { # <label> <interval-or-empty> <stdout-path-or-empty>
  local l="$1" i="${2:-}" o="${3:-}"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n'
    printf '\t<key>Label</key>\n\t<string>%s</string>\n' "$l"
    printf '\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/bin/bash</string>\n\t</array>\n'
    [ -n "$i" ] && printf '\t<key>StartInterval</key>\n\t<integer>%s</integer>\n' "$i"
    [ -n "$o" ] && printf '\t<key>StandardOutPath</key>\n\t<string>%s</string>\n' "$o"
    printf '</dict>\n</plist>\n'
  } > "$A/$l.plist"
}

# run_rows — the inventory as this fixture box sees it. The seams are set for ONE source of the
# library, in a subshell, so each arm gets a fresh view and no arm can leak state into the next.
run_rows() { # [extra env assignments]
  (
    set -o pipefail
    FLEET_HOME="$H" FLEET_O="$O" FLEET_PLATFORM="mac" \
    FLEET_AGENT_SCRIPTS="$SCRIPTS" FLEET_AGENT_STATE="$STATE" \
    FLEET_LAUNCH_AGENTS_DIR="$A" FLEET_LAUNCHCTL="$BIN/launchctl" \
    FLEET_PLUTIL="$BIN/plutil" \
    FLEET_CELL_SUPERVISOR="" FLEET_CONTROLLER_LATE_S=1800 \
    PATH="$BIN:$PATH" \
    bash -c 'set -uo pipefail; . "$1"; shift; eval "$*"' _ "$FLEET_LIB" "$*" 
  )
}

# state_of <rows> <component> — the STATE column, or the literal ABSENT when no such row exists.
state_of() { # <rows> <name>
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n { print $4; found=1; exit } END { if (!found) print "ABSENT" }'
}
detail_of() { # <rows> <name>
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n { print $5; exit }'
}
# severity_of <rows> — the table's own exit code for them (0/1/2), computed by the shipped function.
severity_of() { # <rows>
  printf '%s\n' "$1" | run_rows 'fleet_render_table >/dev/null; echo "RC=$?"'
}
# severity_of_row <rows> <component> — the exit code of a table made of ONE known-OK row plus the row
# under test. `severity_of` over a whole fixture box answers a different question: seed_quiet_box
# leaves the controller MISSING, so RC=1 arrived whatever the named row said, and an arm labelled
# "…and it fails the table" could not redden for its own behaviour (measured by review).
severity_of_row() { # <rows> <name>
  local row
  row="$(printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n')"
  severity_of "$(printf 'controller\tx\ty\tOK\t\n%s\n' "$row")"
}

# Base fixtures: every component that is NOT under test is either absent-and-SKIPPED or explicitly
# OK, so an arm's red can only come from the behaviour it names.
seed_quiet_box() {
  rm -f "$O/.orch.lock" "$O/heartbeat" "$STATE/heartbeat-loop.pid" "$STATE/cadence-timer.pid" \
        "$STATE/cadence-timer.beat" "$STATE/orchestrator-heartbeat.log"
  # …and the CODE fixtures. Since a component whose script exists but whose job does not is MISSING
  # (not SKIPPED), a script left behind by an earlier section would change what a later arm expects.
  rm -f "$SCRIPTS"/*.sh "$SCRIPTS"/*.py "$O"/*.sh 2>/dev/null
  # ⛔ AND KILL THE FIXTURES. Removing a script does not change a RUNNING process's argv, so a
  # leftover controller from an earlier section still matches the predicate and manufactures a
  # DUPLICATE in the next one (measured: §9f saw two controllers, one of them §7's).
  pkill -9 -f "$T/" 2>/dev/null; sleep 0.2
  : > "$KIDS_FILE"
  printf 'PID\tStatus\tLabel\n' > "$LC_LIST"
  printf '%s\n' "$(date +%s)" > "$O/heartbeat"
}

# ── §0 the entry point actually prints the table (wiring, not just the library) ────────────────
# The inventory is worthless if `status` does not render it: the owner asked for ONE script whose
# status prints the table. This arm runs the shipped entry point, not the library.
say_case "§0 the shipped entry point renders the table and exits with its verdict"
seed_quiet_box
OUT="$(env -i HOME="$H" PATH="$BIN:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  O="$O" FLEET_LAUNCHCTL_LIST="$LC_LIST" FLEET_LAUNCHCTL_CALLS="$FLEET_LAUNCHCTL_CALLS" \
  FLEET_AGENT_SCRIPTS="$SCRIPTS" FLEET_AGENT_STATE="$STATE" FLEET_LAUNCH_AGENTS_DIR="$A" \
  FLEET_PLATFORM=mac FLEET_PLUTIL="$BIN/plutil" \
  bash "$HERE/orchestrator-bringup.sh" status 2>&1)"; RC=$?
case "$OUT" in
  *"COMPONENT"*"EXPECTED"*"ACTUAL"*"STATE"*) ok "§0 status prints COMPONENT | EXPECTED | ACTUAL | STATE" ;;
  *) bad "§0 status does not print the inventory table — $OUT" ;;
esac
# ⛔ ON THE ROW, not somewhere in the output. The previous assertion was `*cell-supervisor*SKIPPED*`
# against the WHOLE screen — a glob across lines that any row could satisfy, and one that depended on
# the runner's platform (`FLEET_PLATFORM` is now forced, or a Linux CI runner renders this row MISSING).
rowstate="$(printf '%s\n' "$OUT" | awk '$1=="cell-supervisor"{print $NF; exit}')"
[ "$rowstate" = "SKIPPED" ] && ok "§0 the cell-supervisor ROW reads SKIPPED on a mac (not just the word somewhere)" \
                            || bad "§0 the cell-supervisor row should read SKIPPED on a mac, got [$rowstate] — $OUT"
[ "$RC" = 1 ] && ok "§0 status exits non-zero (1) while a component is MISSING — the table IS the verdict" \
              || bad "§0 status exited $RC with a MISSING component (want 1)"

# ── §1 DUPLICATE ────────────────────────────────────────────────────────────────────────────────
say_case "§1 two live instances must be reported as DUPLICATE (a lock is not proof)"
seed_quiet_box
mk_proc_script "$O/orch-loop.sh"
CP1="$(spawn_component "$O/orch-loop.sh")"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" = "OK" ] && ok "§1b one live controller reads OK (so §1a cannot pass by always saying DUPLICATE)" \
                 || bad "§1b a single controller should be OK, got [$st]"

CP2="$(spawn_component "$O/orch-loop.sh")"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
d="$(detail_of "$ROWS" controller)"
[ "$st" = "DUPLICATE" ] && ok "§1a two live controllers read DUPLICATE" \
                        || bad "§1a two live controllers should be DUPLICATE, got [$st]"
case "$d" in
  *"$CP1"*"$CP2"*|*"$CP2"*"$CP1"*) ok "§1a DUPLICATE names BOTH pids ($CP1, $CP2)" ;;
  *) bad "§1a the DUPLICATE note does not name both pids — [$d]" ;;
esac
[ "$(severity_of_row "$ROWS" controller)" = "RC=1" ] && ok "§1a a DUPLICATE row makes the exit code 1" \
                                      || bad "§1a a DUPLICATE row must fail the table — got $(severity_of_row "$ROWS" controller)"
kill9 $CP1 $CP2

# A pidfile loop is the second, independent duplicate path (its pidfile guard is what the duplicate
# defeats). Two instances, one pidfile naming one of them.
say_case "§1d a pidfile loop running twice is DUPLICATE, not OK"
seed_quiet_box
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"
: > "$STATE/orchestrator-heartbeat.log"   # the loop's OWN freshness signal: it appends every pass
HP1="$(spawn_component "$SCRIPTS/heartbeat-loop.sh")"
sleep 0.3
printf '%s\n' "$HP1" > "$STATE/heartbeat-loop.pid"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "OK" ] && ok "§1d one heartbeat-loop with a matching pidfile reads OK" \
                 || bad "§1d one heartbeat-loop should read OK, got [$st]"
HP2="$(spawn_component "$SCRIPTS/heartbeat-loop.sh")"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "DUPLICATE" ] && ok "§1d two heartbeat-loops read DUPLICATE" \
                        || bad "§1d two heartbeat-loops should be DUPLICATE, got [$st]"
# The recycled-pid case: the pidfile names a live process that is NOT the loop.
kill9 $HP1 $HP2
printf '%s\n' "$$" > "$STATE/heartbeat-loop.pid"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "FAILING" ] && ok "§1e a pidfile naming a LIVE NON-LOOP pid is FAILING (recycled pid), never OK" \
                      || bad "§1e a recycled pid in the pidfile should be FAILING, got [$st]"

# ── §2 MISSING ──────────────────────────────────────────────────────────────────────────────────
say_case "§2 an absent component must be reported MISSING"
seed_quiet_box
# The loop's code must EXIST for "it is not running" to be the right verdict: with no script on the
# box the component does not exist here at all, and SKIPPED (with its reason) is the honest state —
# §9c pins that distinction. This section is about an INSTALLED component that is not running.
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" = "MISSING" ] && ok "§2 no controller process and no live lock owner reads MISSING" \
                      || bad "§2 an absent controller should be MISSING, got [$st]"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "MISSING" ] && ok "§2 an absent heartbeat-loop reads MISSING" \
                      || bad "§2 an absent heartbeat-loop should be MISSING, got [$st]"
[ "$(severity_of_row "$ROWS" controller)" = "RC=1" ] && ok "§2 a MISSING row makes the exit code 1 (not silently green)" \
                                      || bad "§2 a MISSING row must fail the table"

# A dead pid in the pidfile must be NAMED, not trusted ("it has a pidfile, so it is running").
mktemp_dead_pid() { local p=""; while [ -z "$p" ] || kill -0 "$p" 2>/dev/null; do p=$(( 60000 + RANDOM % 9000 )); done; printf '%s\n' "$p"; }
printf '%s\n' "$(mktemp_dead_pid)" > "$STATE/heartbeat-loop.pid"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"; d="$(detail_of "$ROWS" heartbeat-loop)"
[ "$st" = "MISSING" ] && ok "§2 a STALE pidfile does not make an absent loop read as present" \
                      || bad "§2 a stale pidfile should still be MISSING, got [$st]"
case "$d" in *stale*) ok "§2 the note names the stale pidfile (so the operator can see the lie)" ;;
             *) bad "§2 the stale pidfile is not named — [$d]" ;; esac

# ── §3 SELF-MATCH SAFETY ───────────────────────────────────────────────────────────────────────
say_case "§3 the process matcher must not match itself"
seed_quiet_box
rm -f "$STATE/heartbeat-loop.pid"
# The hardest case: the checker's own argv IS `<shell> <exact component path>` — the shape a
# `pgrep -f` counts ("this bug bit us repeatedly: the shell that ran it").
cat > "$T/self-check.sh" <<EOF
#!/bin/bash
set -uo pipefail
. "$FLEET_LIB"
printf 'COUNT=%s\n' "\$(fleet_pids_for "$O/orch-loop.sh" | awk 'NF' | wc -l | tr -d ' ')"
EOF
chmod +x "$T/self-check.sh"
cp "$T/self-check.sh" "$O/orch-loop.sh"   # the checker now has the component's OWN path
OUT="$(bash "$O/orch-loop.sh" 2>&1)"
case "$OUT" in
  *COUNT=0*) ok "§3 a checker whose argv is exactly <shell> <component path> counts ZERO instances" ;;
  *) bad "§3 SELF-MATCH: the checker counted itself — $OUT" ;;
esac

# A shell whose TEXT mentions the path is not an invocation (tok[2] is `-c`, not the path).
bash -c "sleep 3 # $O/orch-loop.sh is a fine script" >/dev/null 2>&1 &
MENTION=$!
KIDS="$KIDS $MENTION"
sleep 0.2
OUT="$(bash "$T/self-check.sh" 2>&1)"
case "$OUT" in
  *COUNT=0*) ok "§3 a shell whose TEXT mentions the path does not match (argv shape, not substring)" ;;
  *) bad "§3 a shell mentioning the path in its text was counted — $OUT" ;;
esac
# A reader of the component's log is not the component.
bash -c "tail -f /dev/null; : $O/orch-loop.sh" >/dev/null 2>&1 &
READER=$!
KIDS="$KIDS $READER"
sleep 0.2
OUT="$(bash "$T/self-check.sh" 2>&1)"
case "$OUT" in
  *COUNT=0*) ok "§3 a reader/log-toucher does not match" ;;
  *) bad "§3 a reader was counted as the component — $OUT" ;;
esac
# …and the matcher DOES find a real instance, so §3 cannot pass by matching nothing at all.
mk_proc_script "$O/orch-loop.sh"
REAL="$(spawn_component "$O/orch-loop.sh")"
sleep 0.3
OUT="$(bash "$T/self-check.sh" 2>&1)"
case "$OUT" in
  *COUNT=1*) ok "§3 the same matcher DOES find the one real instance (so §3 is not 'match nothing')" ;;
  *) bad "§3 the matcher missed a real instance — $OUT" ;;
esac
kill9 $REAL
cp "$T/self-check.sh" "$O/orch-loop.sh.bak" 2>/dev/null || true
rm -f "$O/orch-loop.sh"   # restore: the path is a component script again, not the checker

# ── §4 SKIPPED vs OK ──────────────────────────────────────────────────────────────────────────
say_case "§4 SKIPPED is its own state and never a silent OK"
seed_quiet_box
mk_proc_script "$O/orch-loop.sh"; CP="$(spawn_component "$O/orch-loop.sh")"; sleep 0.3
ROWS="$(run_rows 'FLEET_PLATFORM=mac; fleet_rows ""' )"
st="$(state_of "$ROWS" cell-supervisor)"
d="$(detail_of "$ROWS" cell-supervisor)"
[ "$st" = "SKIPPED" ] && ok "§4 a component that does not apply to this box reads SKIPPED" \
                      || bad "§4 the cell supervisor on a mac should be SKIPPED, got [$st]"
[ "$st" != "OK" ] && ok "§4 SKIPPED is textually distinct from OK" || bad "§4 SKIPPED rendered as OK"
case "$d" in *Mac*|*mac*) ok "§4 SKIPPED always carries a REASON (which platform, why)" ;;
             *) bad "§4 SKIPPED without a reason — [$d]" ;; esac
# A SKIPPED row alone must not fail the table: a Mac is not broken for having no cell supervisor.
ONLY_SKIPPED="$(printf 'controller\tx\ty\tOK\t\ncell-supervisor\tx\ty\tSKIPPED\tbecause\n')"
[ "$(severity_of "$ONLY_SKIPPED")" = "RC=0" ] && ok "§4 SKIPPED is a PASS for the exit code (not a false block)" \
                                             || bad "§4 SKIPPED must not fail the table"
# The same component on a CELL, without a supervisor, is MISSING — "absent" and "not applicable"
# must never render the same. A CELL is a box that carries a cell's identity (FLEET_CELL_HOME):
# `bringup` maps `uname -s = Linux` to platform=cell, so without that marker every Linux dev box and
# CI runner would get a permanently-red row for a supervisor it does not have (new arm below).
mkdir -p "$T/srvcell"; : > "$T/srvcell/keys.env"
ROWS="$(run_rows 'FLEET_PLATFORM=cell; FLEET_CELL_HOME="'"$T"'/srvcell"; FLEET_CELL_SUPERVISOR=""; fleet_rows ""')"
st="$(state_of "$ROWS" cell-supervisor)"
[ "$st" = "MISSING" ] && ok "§4 on a CELL the same component reads MISSING (absence ≠ not-applicable)" \
                      || bad "§4 on a cell with no supervisor the row should be MISSING, got [$st]"
# …but platform=cell with NO cell identity is a dev box or a CI runner, and a permanent red there is a
# false block: the kernel alone does not make a box a cell.
ROWS="$(run_rows 'FLEET_PLATFORM=cell; FLEET_CELL_HOME=""; FLEET_CELL_SUPERVISOR=""; fleet_rows ""')"
st="$(state_of "$ROWS" cell-supervisor)"
[ "$st" = "SKIPPED" ] && ok "§4 platform=cell with no cell identity is SKIPPED, not a permanent MISSING (Linux dev box / CI)" \
                      || bad "§4 a non-cell Linux box should not be red — got [$st]"
# …and an UNSET platform is an unanswered question, never a pass (SKIPPED is severity 0).
ROWS="$(run_rows 'FLEET_PLATFORM=""; fleet_rows ""')"
st="$(state_of "$ROWS" cell-supervisor)"
[ "$st" = "UNKNOWN" ] && ok "§4 an UNSET platform reads UNKNOWN, never SKIPPED (a pass)" \
                      || bad "§4 an unset platform should be UNKNOWN, got [$st]"
kill9 $CP

# ── §5 THE EXIT CODE IS THE WORST ROW ────────────────────────────────────────────────────────
say_case "§5 the table's exit code reflects the worst row"
ALL_OK="$(printf 'controller\tx\ty\tOK\t\nb\tx\ty\tSKIPPED\twhy\n')"
[ "$(severity_of "$ALL_OK")" = "RC=0" ] && ok "§5 all-OK (+SKIPPED) → 0" || bad "§5 all-OK should be 0"
WITH_BAD="$(printf 'controller\tx\ty\tOK\t\nb\tx\ty\tFAILING\tboom\nc\tx\ty\tMISSING\tgone\n')"
[ "$(severity_of "$WITH_BAD")" = "RC=1" ] && ok "§5 one FAILING/MISSING among OK rows → 1" || bad "§5 a bad row should be 1"
WITH_UNKNOWN="$(printf 'controller\tx\ty\tOK\t\nb\tx\ty\tUNKNOWN\tunreadable\n')"
[ "$(severity_of "$WITH_UNKNOWN")" = "RC=2" ] && ok "§5 an UNKNOWN (unreadable read) → 2, never 0" || bad "§5 UNKNOWN should be 2"
# Zero rows is not a healthy fleet: a declaration that failed to load must not certify.
[ "$(severity_of "")" = "RC=2" ] && ok "§5 an EMPTY table → 2 (a missing check is not a green check)" \
                                || bad "§5 an empty table must be 2, got $(severity_of "")"

# End to end: an unreadable process table must be an ABSTENTION (2), never a green table — the
# doctrine the fleet already applies to lane liveness.
seed_quiet_box
ROWS="$(run_rows 'FLEET_PS=/bin/false; fleet_rows ""' 2>/dev/null)"
st="$(state_of "$ROWS" controller)"
[ "$st" = "UNKNOWN" ] && ok "§5 an unreadable ps reads UNKNOWN for the controller" \
                      || bad "§5 an unreadable ps should be UNKNOWN, got [$st]"
[ "$(severity_of "$ROWS")" = "RC=2" ] && ok "§5 and the table exits 2 (fail-closed), not 0" \
                                      || bad "§5 an unreadable ps must exit 2, got $(severity_of "$ROWS")"

# ── §6 the ACTUAL verdicts on a clean box, and a periodic job's last-exit ────────────────────
say_case "§6 a launchd job is judged by its OWN declaration, not by 'pid exists'"
seed_quiet_box
mk_proc_script "$O/orch-loop.sh"; CP="$(spawn_component "$O/orch-loop.sh")"
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"; HP="$(spawn_component "$SCRIPTS/heartbeat-loop.sh")"
printf '%s\n' "$HP" > "$STATE/heartbeat-loop.pid"
: > "$STATE/orchestrator-heartbeat.log"
mk_plist "com.tortoise.pr-doctor" 1200 "$STATE/pr-doctor.out"
touch "$STATE/pr-doctor.out"
printf 'PID\tStatus\tLabel\n-\t2\tcom.tortoise.pr-doctor\n' > "$LC_LIST"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" pr-doctor)"
[ "$st" = "FAILING" ] && ok "§6 a job whose LAST EXIT is 2 reads FAILING (the measured exit-2-for-hours state)" \
                      || bad "§6 last exit 2 should read FAILING, got [$st]"
printf 'PID\tStatus\tLabel\n-\t0\tcom.tortoise.pr-doctor\n' > "$LC_LIST"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" pr-doctor)"
[ "$st" = "OK" ] && ok "§6 the same job with last exit 0 reads OK (so §6 is not 'always FAILING')" \
                 || bad "§6 last exit 0 should read OK, got [$st]"
# A job that is declared but NOT in the launchd domain will never run — MISSING, not OK.
printf 'PID\tStatus\tLabel\n' > "$LC_LIST"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" pr-doctor)"
[ "$st" = "MISSING" ] && ok "§6 a declared job that is not loaded reads MISSING (it will never run)" \
                      || bad "§6 an unloaded job should be MISSING, got [$st]"
# A hand-run copy beside the scheduled run is DUPLICATE — counted by DISTINCT pid, so the job's OWN
# in-flight run (launchd's pid IS the process the matcher finds) is not mistaken for a second one.
mk_proc_script "$SCRIPTS/pr-doctor.py"
SCHED="$(spawn_component "$SCRIPTS/pr-doctor.py")"
printf 'PID\tStatus\tLabel\n%s\t-\tcom.tortoise.pr-doctor\n' "$SCHED" > "$LC_LIST"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" pr-doctor)"
[ "$st" = "OK" ] && ok "§6 the job's OWN in-flight run is not double-counted (its pid IS launchd's pid)" \
                 || bad "§6 the job's own run was counted twice, got [$st]"
Manual="$(spawn_component "$SCRIPTS/pr-doctor.py")"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" pr-doctor)"
[ "$st" = "DUPLICATE" ] && ok "§6 a hand-run pr-doctor beside the scheduled one reads DUPLICATE" \
                        || bad "§6 a second pr-doctor should be DUPLICATE, got [$st]"
kill9 $CP $HP "$SCHED" "$Manual"

# A reaper whose plist declares NO output path must still be judged on the log IT writes — not on
# "last exit 0" alone (the branch that rendered four dead-schedulable reapers OK).
say_case "§6b a job with no declared output is judged on its OWN log, and never on silence"
seed_quiet_box
mk_proc_script "$O/orch-loop.sh"; CP3="$(spawn_component "$O/orch-loop.sh")"
mk_plist "com.tortoise.worktree-reaper" 60 ""            # 60s interval, no StandardOutPath
: > "$LC_LIST"; printf 'PID\tStatus\tLabel\n-\t0\tcom.tortoise.worktree-reaper\n' > "$LC_LIST"
# The component's own log, fresh → OK (so the arm is not "always LATE").
: > "$STATE/pi-reap-worktrees.log"
sleep 0.2
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" reaper.worktree-reaper)"
[ "$st" = "OK" ] && ok "§6b a fresh own-log reads OK even with no declared StandardOutPath" \
                 || bad "§6b a fresh own-log should read OK, got [$st]"
# …and STALE beyond its own bound → LATE. `touch -t` far in the past, so the bound cannot be luck.
touch -t 202001010000 "$STATE/pi-reap-worktrees.log"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" reaper.worktree-reaper)"
[ "$st" = "LATE" ] && ok "§6b a STALE own-log reads LATE (the 'job stopped being scheduled' state)" \
                   || bad "§6b a stale own-log should read LATE, got [$st]"
# A job with NO declared output AND no own-log → UNKNOWN, never OK ("not checked" is not green).
# pr-doctor is the row with no own-log seam, so a plist that declares no output leaves it unprovable.
rm -f "$STATE/pi-reap-worktrees.log"
mk_plist "com.tortoise.pr-doctor" 1200 ""
printf 'PID\tStatus\tLabel\n-\t0\tcom.tortoise.worktree-reaper\n-\t0\tcom.tortoise.pr-doctor\n' > "$LC_LIST"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" pr-doctor)"
[ "$st" = "UNKNOWN" ] && ok "§6b with no freshness signal at all the row is UNKNOWN, never OK" \
                      || bad "§6b no derivable freshness should be UNKNOWN, got [$st]"
kill9 "$CP3"

# ── §7 the VERB paths: stop must not lie, and must not touch what it does not own ────────────────
say_case "§7 stop/start: a verified stop, a failing bootout that is NOT a stop, and no false warnings"
seed_quiet_box
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"
mk_proc_script "$SCRIPTS/cadence-timer.sh"
HP="$(spawn_component "$SCRIPTS/heartbeat-loop.sh")"; printf '%s\n' "$HP" > "$STATE/heartbeat-loop.pid"
CT="$(spawn_component "$SCRIPTS/cadence-timer.sh")";  printf '%s\n' "$CT" > "$STATE/cadence-timer.pid"
: > "$STATE/orchestrator-heartbeat.log"
mk_proc_script "$O/orch-loop.sh"; CP="$(spawn_component "$O/orch-loop.sh")"
mk_plist "com.tortoise.pr-doctor" 1200 "$STATE/pr-doctor.out"; touch "$STATE/pr-doctor.out"
printf 'PID\tStatus\tLabel\n-\t0\tcom.tortoise.pr-doctor\n' > "$LC_LIST"
sleep 0.3
OUT="$(run_rows 'fleet_stop_all ""' 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "§7a stop_all on a healthy box returns 0 (no false failure)" \
              || bad "§7a stop_all returned $RC — $OUT"
case "$OUT" in
  *"could not stop"*) bad "§7a stop_all warns 'could not stop' on a healthy box — $OUT" ;;
  *) ok "§7a stop_all never prints a 'could not stop' line for a component it does not own" ;;
esac
case "$OUT" in
  *"stopped controller"*) bad "§7a stop_all claims it stopped the CONTROLLER (it is the platform verb's) — $OUT" ;;
  *) ok "§7a the controller is not claimed as stopped by this verb" ;;
esac
case "$OUT" in
  *landers*) ok "§7a the landers are explicitly left running, with a reason" ;;
  *) bad "§7a the landers row is not accounted for — $OUT" ;;
esac
if kill -0 "$HP" 2>/dev/null; then bad "§7a the heartbeat-loop fixture survived stop_all"; else ok "§7a the heartbeat-loop was actually stopped (pids, not the command's status)"; fi
if kill -0 "$CP" 2>/dev/null; then ok "§7a the controller process is untouched by stop_all"; else bad "§7a stop_all killed the controller"; fi
grep -q 'bootout' "$FLEET_LAUNCHCTL_CALLS" 2>/dev/null && ok "§7a the launchd job was removed with bootout (no persistent disable)" \
                                                  || bad "§7a no bootout was issued for the launchd job"
grep -q 'unload' "$FLEET_LAUNCHCTL_CALLS" 2>/dev/null && bad "§7a an unload was issued (a -w there writes a persistent disable)" \
                                                       || ok "§7a no unload/-w was issued by the inventory"

# A bootout that FAILS must not be reported as a stop: `|| return 0` was exactly that bug.
seed_quiet_box
mk_plist "com.tortoise.pr-doctor" 1200 "$STATE/pr-doctor.out"; touch "$STATE/pr-doctor.out"
printf 'PID\tStatus\tLabel\n-\t0\tcom.tortoise.pr-doctor\n' > "$LC_LIST"
: > "$FLEET_LAUNCHCTL_CALLS"
touch "$T/refuse-bootout"
OUT="$(FLEET_LAUNCHCTL_REFUSE_BOOTOUT="$T/refuse-bootout" run_rows 'fleet_stop_component pr-doctor; echo "RC=$?"' 2>&1)"
case "$OUT" in
  *RC=1*) ok "§7b a bootout that failed reads as NOT stopped (the domain is re-read, not the exit code)" ;;
  *) bad "§7b a failed bootout reported success — $OUT" ;;
esac
rm -f "$T/refuse-bootout"

# ── §8 start: an unreadable read is never "already OK", and a FAILING job is repairable ─────────
say_case "§8 start: cannot-determine is not success, and a FAILING periodic job gets a re-run"
seed_quiet_box
OUT="$(run_rows 'FLEET_PS=/bin/false; fleet_ensure_components ""; echo "RC=$?"' 2>&1)"
case "$OUT" in
  *"already OK"*) bad "§8 `start` reported a green fleet from an UNREADABLE process table — $OUT" ;;
  *) ok "§8 an unreadable read does not read as 'every component is already OK'" ;;
esac
case "$OUT" in
  *RC=2*) ok "§8 and the verb returns 2 (cannot determine), not 0" ;;
  *) bad "§8 an unreadable read must be rc=2 — $OUT" ;;
esac

seed_quiet_box
mk_proc_script "$O/orch-loop.sh"; CP2="$(spawn_component "$O/orch-loop.sh")"
mk_plist "com.tortoise.pr-doctor" 1200 "$STATE/pr-doctor.out"; touch "$STATE/pr-doctor.out"
printf 'PID\tStatus\tLabel\n-\t2\tcom.tortoise.pr-doctor\n' > "$LC_LIST"
: > "$FLEET_LAUNCHCTL_CALLS"
sleep 0.3
OUT="$(run_rows 'fleet_ensure_components ""' 2>&1)"
case "$OUT" in
  *"pr-doctor: started (was FAILING)"*) ok "§8 a FAILING job is repaired by start (kickstart), not skipped" ;;
  *) bad "§8 start did not repair a FAILING job — $OUT" ;;
esac
grep -q 'kickstart' "$FLEET_LAUNCHCTL_CALLS" 2>/dev/null && ok "§8 the repair was a kickstart (re-run), not a bootstrap" \
                                                           || bad "§8 no kickstart was issued"


# ── §9 the second review round: one arm per defect it found ─────────────────────────────────────
# Every arm in this section was written against a defect REPRODUCED by a fresh reviewer, and each was
# run against the pre-fix revision to confirm it reddens there (the mutation results are in the PR).

# §9a (E-1) A CHECK THAT RUNS BENEATH THE COMPONENT MUST STILL SEE IT.
# The first version excluded the checker's own pid AND EVERY ANCESTOR from the match set. That is
# over-broad: a health read that runs as a CHILD of the controller (a tick added to orch-loop.sh, a
# lane child, fix-one.sh) has the controller as an ancestor, so the controller vanished from its own
# inventory and the row read MISSING over a live, fresh controller. `q == self` is the only barrier
# that is load-bearing. Reproduced: with the check running as a child of a live orch-loop.sh the row
# printed MISSING.
say_case "§9a an inventory run BENEATH the controller still counts the controller (ancestor ≠ self)"
seed_quiet_box
cat > "$T/probe-inside.sh" <<'PROBE'
#!/bin/bash
# This runs as a CHILD of $O/orch-loop.sh, which is therefore one of its ANCESTORS.
. "$FLEET_LIB"
fleet_pids_for "$FLEET_O/orch-loop.sh" | awk 'NF' | wc -l | tr -d ' '
PROBE
printf '#!/bin/bash\nbash %s/probe-inside.sh\nsleep 2\n' "$T" > "$O/orch-loop.sh"
chmod +x "$O/orch-loop.sh"
INSIDE="$(env FLEET_LIB="$FLEET_LIB" FLEET_O="$O" FLEET_HOME="$H" bash "$O/orch-loop.sh" 2>/dev/null | tr -d '[:space:]')"
[ "$INSIDE" = "1" ] && ok "§9a a check running beneath the controller counts it (1), not 0" \
                   || bad "§9a the controller was excluded as an ANCESTOR of the checker — counted [$INSIDE] (want 1)"

# §9b (E-2) AN UNREADABLE JOB DEFINITION IS UNKNOWN, NOT A SILENTLY UNBOUNDED OK.
# `plutil` fails for BOTH "key absent" and "file unreadable"; the first version folded both into the
# empty string, which sets no freshness bound and renders a plain green OK — the fail-open the
# UNKNOWN doctrine in this library exists to forbid.
say_case "§9b a job definition that cannot be READ is UNKNOWN (absent key vs unreadable are different)"
seed_quiet_box
mk_proc_script "$SCRIPTS/pr-doctor.py"
printf 'this is not a plist <key>StartInterval</key> but it mentions the key\n' > "$A/com.tortoise.pr-doctor.plist"
printf 'PID\tStatus\tLabel\n-\t0\tcom.tortoise.pr-doctor\n' > "$LC_LIST"
sleep 0.2
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" pr-doctor)"
[ "$st" = "UNKNOWN" ] && ok "§9b an unreadable StartInterval is UNKNOWN, never OK" \
                      || bad "§9b an unreadable declaration should be UNKNOWN, got [$st] — $(detail_of "$ROWS" pr-doctor)"
rm -f "$A/com.tortoise.pr-doctor.plist"

# §9c (C-3) CODE PRESENT + NO JOB = MISSING (actionable), NOT SKIPPED (a pass).
# Reviewer C measured that `com.tortoise.pr-doctor` and `com.eldato.orchestrator-watchdog` are
# installed by NO surface in this repo: on a box set up by the repo's own installers both rows hit the
# "no plist → SKIPPED" path, and SKIPPED is severity 0 AND invisible to `start`. The component whose
# silent exit-2 motivated this whole file was therefore GREEN BY ABSENCE.
say_case "§9c a component whose CODE is here but whose JOB is not is MISSING, not a green SKIPPED"
seed_quiet_box
mk_proc_script "$SCRIPTS/pr-doctor.py"
printf 'PID\tStatus\tLabel\n' > "$LC_LIST"
sleep 0.2
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" pr-doctor)"
[ "$st" = "MISSING" ] && ok "§9c code present + no job reads MISSING (actionable)" \
                      || bad "§9c code present + no job should be MISSING, got [$st]"
[ "$(severity_of_row "$ROWS" pr-doctor)" = "RC=1" ] && ok "§9c …and it fails the table (SKIPPED would have passed)" \
                                      || bad "§9c a MISSING-by-unprovisioned row must fail the table, got $(severity_of_row "$ROWS" pr-doctor)"
# …while a component with NOTHING on the box is SKIPPED: "does not exist here" ≠ "installed and dead".
rm -f "$SCRIPTS/pr-doctor.py"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" pr-doctor)"
[ "$st" = "SKIPPED" ] && ok "§9c nothing on the box at all still reads SKIPPED (not a fake MISSING)" \
                      || bad "§9c an absent component should be SKIPPED, got [$st]"

# §9d (C-4) THE CADENCE TIMER'S FRESHNESS MUST BE ITS OWN SIGNAL.
# The row read `orchestrator-heartbeat.log`, which heartbeat-loop.sh appends to EVERY pass — so the
# timer's LATE branch could only fire if BOTH loops stopped, i.e. it could not report the one state it
# exists for. The timer now writes its own beacon per tick.
say_case "§9d a LIVE cadence timer whose own beacon is stale is LATE even while the sibling loop writes"
seed_quiet_box
mk_proc_script "$SCRIPTS/cadence-timer.sh"
CTB="$(spawn_component "$SCRIPTS/cadence-timer.sh")"; printf '%s\n' "$CTB" > "$STATE/cadence-timer.pid"
printf '%s\n' "$(date +%s)" > "$STATE/orchestrator-heartbeat.log"     # the SIBLING's file: fresh
sleep 0.2
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" cadence-timer)"
[ "$st" != "OK" ] && ok "§9d a fresh sibling log does NOT make the cadence timer OK (got $st)" \
                  || bad "§9d the cadence timer read OK off heartbeat-loop's log — the masking is back"
printf '%s\n' "$(date +%s)" > "$STATE/cadence-timer.beat"             # its OWN beacon
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" cadence-timer)"
[ "$st" = "OK" ] && ok "§9d …and its OWN fresh beacon reads OK" \
                 || bad "§9d a fresh own beacon should read OK, got [$st] — $(detail_of "$ROWS" cadence-timer)"
touch -t 202001010000 "$STATE/cadence-timer.beat"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" cadence-timer)"
[ "$st" = "LATE" ] && ok "§9d …and a stale own beacon reads LATE (alive, pacing nothing)" \
                   || bad "§9d a stale own beacon should read LATE, got [$st]"
kill9 "$CTB"; rm -f "$STATE/cadence-timer.pid"

# §9e (C-6/M3) THE LANDERS' EXPIRY BOUND — the "expired silently, green PRs waiting for a human"
# state from this file's own header — was covered by NO assertion: a mutant that deleted the bound
# left 51/51 green. Bound is a seam, so the fixture does not have to wait 90 minutes.
say_case "§9e an EXPIRED lander is LATE (the state the whole row exists for)"
seed_quiet_box
mk_proc_script "$O/merge-one.sh"; LD="$(spawn_component "$O/merge-one.sh")"
sleep 2.2                                    # etime is integer seconds: the bound is 1s
ROWS="$(run_rows 'FLEET_LANDER_BOUND_S=1; fleet_rows ""')"
st="$(state_of "$ROWS" landers)"
[ "$st" = "LATE" ] && ok "§9e a lander older than its bound reads LATE" \
                   || bad "§9e an expired lander should read LATE, got [$st]"
[ "$(severity_of_row "$ROWS" landers)" = "RC=1" ] && ok "§9e …and an expired lander fails the table" \
                                      || bad "§9e an expired lander must fail the table, got $(severity_of_row "$ROWS" landers)"
ROWS="$(run_rows 'FLEET_LANDER_BOUND_S=9000; fleet_rows ""')"
st="$(state_of "$ROWS" landers)"
[ "$st" = "OK" ] && ok "§9e …while a young lander reads OK (so the arm cannot pass by always LATE)" \
                 || bad "§9e a young lander should read OK, got [$st]"
kill9 "$LD"

# §9f (E-11) the LATE branches that had no arm: the controller's own heartbeat, and a pidfile loop's
# output. A bound with no arm is a bound a future edit can delete silently.
say_case "§9f the controller and the pidfile loops each have a LATE arm"
seed_quiet_box
mk_proc_script "$O/orch-loop.sh"; CL="$(spawn_component "$O/orch-loop.sh")"
touch -t 202001010000 "$O/heartbeat"
sleep 0.2
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" = "LATE" ] && ok "§9f a live controller with a STALE heartbeat reads LATE (alive, dispatching nothing)" \
                   || bad "§9f a stale controller heartbeat should read LATE, got [$st]"
kill9 "$CL"
seed_quiet_box
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"
HL="$(spawn_component "$SCRIPTS/heartbeat-loop.sh")"; printf '%s\n' "$HL" > "$STATE/heartbeat-loop.pid"
printf '%s\n' "$(date +%s)" > "$STATE/orchestrator-heartbeat.log"
sleep 0.2
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "OK" ] && ok "§9f a fresh heartbeat loop reads OK" || bad "§9f fresh loop should be OK, got [$st]"
touch -t 202001010000 "$STATE/orchestrator-heartbeat.log"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "LATE" ] && ok "§9f …and a live loop that stopped writing reads LATE" \
                   || bad "§9f a silent loop should read LATE, got [$st]"
kill9 "$HL"; rm -f "$STATE/heartbeat-loop.pid"

# §9g (E-3/E-4) THE WATCHDOG PAIR IS REDUNDANCY BY DESIGN — and a second copy of the SAME mechanism
# is the real duplicate. Classifying the launchd job + watchdog-loop.sh pair as DUPLICATE reddened a
# HEALTHY box (both run the same idempotent watchdog.sh and cannot disagree), so `status` exited 1
# forever on the owner's Mac. Two watchdog-loop.sh processes are genuinely wrong.
say_case "§9g the two watchdog MECHANISMS are not a duplicate; two copies of ONE mechanism are"
seed_quiet_box
mk_proc_script "$O/watchdog-loop.sh"
WL="$(spawn_component "$O/watchdog-loop.sh")"
mk_plist "com.eldato.orchestrator-watchdog" "" ""
printf 'PID\tStatus\tLabel\n-\t0\tcom.eldato.orchestrator-watchdog\n' > "$LC_LIST"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller-watchdog)"
[ "$st" = "OK" ] && ok "§9g launchd job + watchdog-loop.sh reads OK (deliberate redundancy, #1976)" \
                 || bad "§9g the deliberate watchdog pair should be OK, got [$st] — $(detail_of "$ROWS" controller-watchdog)"
d="$(detail_of "$ROWS" controller-watchdog)"
case "$d" in
  *"deliberate redundancy"*) ok "§9g …and it SAYS so, rather than passing silently" ;;
  *) bad "§9g the redundancy is not named in the row — [$d]" ;;
esac
WL2="$(spawn_component "$O/watchdog-loop.sh")"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller-watchdog)"
[ "$st" = "DUPLICATE" ] && ok "§9g two copies of watchdog-loop.sh ARE a duplicate" \
                        || bad "§9g two identical watchdogs should be DUPLICATE, got [$st]"
kill9 "$WL" "$WL2"

# §9h (E-8) a bootstrapped job must be KICKED, or "start" produces no evidence at all. A job that is
# not RunAtLoad reads "loaded, last exit 0" without ever having run under this start.
say_case "§9h start kicks a job it bootstraps, so the verdict is about a RUN"
seed_quiet_box
mk_proc_script "$SCRIPTS/pr-doctor.py"
mk_plist "com.tortoise.pr-doctor" 1200 "$STATE/pr-doctor.out"; touch "$STATE/pr-doctor.out"
printf 'PID\tStatus\tLabel\n' > "$LC_LIST"; : > "$FLEET_LAUNCHCTL_CALLS"
sleep 0.2
OUT="$(run_rows 'fleet_ensure_components ""' 2>&1)"
grep -q '^kickstart' "$FLEET_LAUNCHCTL_CALLS" 2>/dev/null \
  && ok "§9h a bootstrapped job is kickstarted (start yields a run, not an absence)" \
  || bad "§9h no kickstart followed the bootstrap — $OUT / $(cat "$FLEET_LAUNCHCTL_CALLS" 2>/dev/null)"

# §9j (C-5) `start` MUST NOT BLOCK ON A LAUNCHER THAT DOES NOT DETACH.
# The first version ran `heartbeat-loop`'s launcher in the FOREGROUND and depended on the script
# detaching itself; the farmed copy can lag the repo, so a non-detaching copy hangs `start` forever
# (measured in review: ~300s of an 335s suite was one blocked start, and a blocking `start` is
# indistinguishable from a wedged box). Detached + read back is the only shape that cannot hang.
say_case "§9j start returns promptly even when the launcher does NOT detach"
seed_quiet_box
printf '#!/bin/bash\nsleep 30\n' > "$SCRIPTS/heartbeat-loop.sh"   # this one never detaches
t0="$(date +%s)"
OUT="$(run_rows 'fleet_start_component heartbeat-loop' 2>&1)"; SRC=$?
el=$(( $(date +%s) - t0 ))
[ "$el" -lt 10 ] && ok "§9j start returned in ${el}s (a non-detaching launcher does not block it)" \
                 || bad "§9j start BLOCKED for ${el}s on a launcher that does not detach"
[ "$SRC" = 0 ] && ok "§9j …and it reports success only because the process is really there" \
               || bad "§9j start returned $SRC — $OUT"
pkill -9 -f "$SCRIPTS/heartbeat-loop.sh" 2>/dev/null

# §9i (E-3) `stop` stops BOTH watchdog mechanisms, so `start` must restore the box's own
# configuration — otherwise stop+start silently downgrades it to one watchdog.
say_case "§9i start restores watchdog-loop.sh that stop removed (no silent downgrade)"
seed_quiet_box
mk_proc_script "$O/watchdog-loop.sh"
# …and a box that has ONLY the plain loop must still be stoppable: has_stop asked the launchd
# predicate, so it answered "no stop mechanism" for a component whose process it could signal.
HSTOP="$(run_rows 'fleet_component_has_stop controller-watchdog && echo yes || echo no')"
[ "$HSTOP" = "yes" ] && ok "§9i a loop-only box HAS a stop mechanism for the watchdog" \
                     || bad "§9i has_stop said [$HSTOP] for a running watchdog-loop.sh with no plist"
mk_plist "com.eldato.orchestrator-watchdog" "" ""
printf 'PID\tStatus\tLabel\n' > "$LC_LIST"; : > "$FLEET_LAUNCHCTL_CALLS"
OUT="$(run_rows 'fleet_start_component controller-watchdog' 2>&1)"; SRC=$?
[ "$SRC" = 0 ] && ok "§9i start controller-watchdog reports success" \
              || bad "§9i start controller-watchdog failed ($SRC) — $OUT"
sleep 0.4
NLOOP="$(env FLEET_O="$O" FLEET_HOME="$H" bash -c '. "$1"; fleet_pids_for "$FLEET_O/watchdog-loop.sh"' _ "$FLEET_LIB" | awk 'NF' | wc -l | tr -d ' ')"
[ "${NLOOP:-0}" -ge 1 ] && ok "§9i watchdog-loop.sh is running again after start (restored, not invented)" \
                       || bad "§9i start did not restore watchdog-loop.sh — the box is silently downgraded"
pkill -9 -f "$O/watchdog-loop.sh" 2>/dev/null


# ── §9k-§9o the THIRD round: defects found by the cycle-2 reviewer, one arm each ──────────────────

# §9k (issue 1) AN UNDATABLE LOCK OWNER IS AN ABSTENTION — the guard cannot call it the owner.
# The recycled-pid guard failed OPEN when the pid's age could not be read: "unknown age" was treated
# as "began before the lock", i.e. as the STRONGEST evidence of ownership. With a `ps` that answers the
# table read but not `-o etime=` (a shim / busybox-shaped ps), a stale lock naming a foreign controller
# read as this state dir's own, live controller. `pid-identity.sh:pid_began_after` returns 2 for this
# reason; the row must abstain (UNKNOWN), not invent an owner.
say_case "§9k an unreadable process AGE is an abstention, never an ownership claim"
seed_quiet_box
mkdir -p "$T/harness"
mk_proc_script "$T/harness/orch-loop.sh"
HZ="$(spawn_component "$T/harness/orch-loop.sh")"
printf '%s\n' "$HZ" > "$O/.orch.lock"
cat > "$T/bin/ps-noetime" <<'PSSHIM'
#!/bin/bash
# Answers the table read; refuses an age, like a ps without `-o etime=`.
case "$*" in *etime*) exit 1 ;; esac
exec /bin/ps "$@"
PSSHIM
chmod +x "$T/bin/ps-noetime"
sleep 0.3
# Sanity: with a REAL ps this fixture IS the owner (harness-scoped pid, so the state-dir scope does not
# also claim it) — otherwise the arm below would pass for the wrong reason.
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" != "MISSING" ] && ok "§9k with a readable age the lock owner is accepted ($st)" \
                       || bad "§9k the fixture lock owner was not accepted even with a real ps — [$st]"
ROWS="$(run_rows 'FLEET_PS='"$T"'/bin/ps-noetime; fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" = "UNKNOWN" ] && ok "§9k an UNREADABLE age abstains (UNKNOWN), it does not claim the pid" \
                      || bad "§9k an undatable lock owner must abstain, got [$st] — $(detail_of "$ROWS" controller)"
kill9 "$HZ"; rm -f "$O/.orch.lock"

# §9u (#2030) THE OTHER HALF OF §9k'S FENCE: a GENUINELY RECYCLED pid is still refused.
# §9k pins the two abstention arms (readable age → owner, unreadable age → UNKNOWN); it does not pin
# the RECYCLED case at all, so adding tolerance to the fence could have quietly turned the guard off.
# A lock written long before the process now holding its pid is the whole point of the guard: the pid
# was recycled, so it contributes NOBODY and the row reads MISSING (not a false owner). The slack is
# 5 s, so an hour-old lock is still ~700 slacks past the tolerance.
say_case "§9u a lock whose pid was RECYCLED contributes nobody (the guard survives the fence slack)"
seed_quiet_box
mkdir -p "$T/harness"
mk_proc_script "$T/harness/orch-loop.sh"
HR="$(spawn_component "$T/harness/orch-loop.sh")"
printf '%s\n' "$HR" > "$O/.orch.lock"
touch -t 202001010000 "$O/.orch.lock"          # the lock predates the process by years
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" = "MISSING" ] && ok "§9u a lock naming a RECYCLED pid is not this state dir's controller" \
                      || bad "§9u a recycled lock pid must contribute nobody, got [$st] — $(detail_of "$ROWS" controller)"
# …and the SAME pid IS the owner once the lock is younger than the process: the only difference is
# the fence, so the arm above cannot pass by refusing everything.
printf '%s\n' "$HR" > "$O/.orch.lock"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" != "MISSING" ] && ok "§9u …while a FRESH lock naming the same live pid is accepted ($st)" \
                        || bad "§9u a fresh lock naming a live orch-loop.sh must be the owner, got [$st]"
kill9 "$HR"; rm -f "$O/.orch.lock"

# §9v (#2030 review) THE SLACK ITSELF, PINNED DETERMINISTICALLY — not raced against the clocks.
# §9k's owner arm and §9u's fresh-lock arm only redden when the two clock SOURCES disagree (the
# Linux-only accident that produced the bug), so reverting the fix left the suite GREEN on macOS: the
# property was not actually pinned. This arm CONTROLS the age source instead — `ps-etime0` answers the
# argv read for real and reports `00:00` elapsed, so the process always looks brand-new while the lock
# is made unambiguously older. With zero tolerance that is a deterministic refusal (MISSING); with the
# shared slack it is a deterministic acceptance, on every platform, every run.
say_case "§9v the fence slack is pinned deterministically (a brand-new-looking pid + a 2 s old lock)"
seed_quiet_box
mkdir -p "$T/harness"
mk_proc_script "$T/harness/orch-loop.sh"
HV="$(spawn_component "$T/harness/orch-loop.sh")"
printf '%s\n' "$HV" > "$O/.orch.lock"
cat > "$T/bin/ps-etime0" <<'PSSH0'
#!/bin/bash
# The argv/table read is real; the AGE read says "just started", like a ps whose start clock is a
# second behind the filesystem's. Controls the one input the fence compares.
case "$*" in *etime*) echo 00:00; exit 0 ;; esac
exec /bin/ps "$@"
PSSH0
chmod +x "$T/bin/ps-etime0"
sleep 2.2                                     # lock_age >= 2, so the 5 s slack is what saves it
ROWS="$(run_rows 'FLEET_PS='"$T"'/bin/ps-etime0; fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" != "MISSING" ] && ok "§9v a pid whose start clock reads 2 s after its own lock is still the OWNER ($st)" \
                        || bad "§9v the fence has no slack: a 2 s clock disagreement refused a healthy owner, got [$st] — $(detail_of "$ROWS" controller)"
kill9 "$HV"; rm -f "$O/.orch.lock"

# §9w (#2030 review) THE SHARED SLACK MUST STAY ONE VALUE ACROSS ITS THREE COPIES.
# `pid-identity.sh` and `cloud-cell-supervisor.sh` are pinned against each other by that suite (a
# drift arm), and this file now carries a third copy (farmed standalone, like the cell supervisor).
# Without this arm, moving the shared default leaves this fence silently at the old value — the same
# divergence #1856 found when two consumers carried +1 s and +5 s.
say_case "§9w the fence slack default is the same value in all three copies"
slack_of() { # <file> <var-name> -> the numeric value it declares (no match ⇒ empty)
  grep -oE "$2(:-|=)[0-9]+" "$1" 2>/dev/null | head -1 | sed -E 's/.*(:-|=)//'
}
lib_slack="$(slack_of "$HERE/lib/fleet-inventory.sh" PID_START_SLACK_SECONDS)"
pidid_slack="$(slack_of "$HERE/lib/pid-identity.sh" PID_START_SLACK_SECONDS)"
# The cell supervisor names it LOCK_START_SLACK_SECONDS (not PID_START_SLACK_SECONDS) — a different
# symbol for the same question, which is exactly why the pair needed a drift arm in the first place.
cell_slack="$(slack_of "$HERE/cloud-cell-supervisor.sh" LOCK_START_SLACK_SECONDS)"
[ -n "$lib_slack" ] && [ -n "$pidid_slack" ] && [ -n "$cell_slack" ] \
  && ok "§9w all three copies declare a numeric default (inventory=$lib_slack pid-identity=$pidid_slack cell-supervisor=$cell_slack)" \
  || bad "§9w a copy no longer declares its slack default (inventory=[$lib_slack] pid-identity=[$pidid_slack] cell-supervisor=[$cell_slack]) — the parity arm cannot compare"
[ "$lib_slack" = "$pidid_slack" ] && [ "$lib_slack" = "$cell_slack" ] \
  && ok "§9w the inventory fence uses the same slack as pid-identity.sh and cloud-cell-supervisor.sh ($lib_slack s)" \
  || bad "§9w fence slack DIVERGED — inventory=$lib_slack pid-identity=$pidid_slack cell-supervisor=$cell_slack (one predicate, three answers)"

# §9l (issue 2) `start` MUST NOT DUPLICATE A LOOP THAT IS ALREADY RUNNING.
# A pidfile loop reads FAILING while its process IS alive (the pidfile names a different pid). The
# first version launched anyway — 1 live copy before the verb, 2 after, plus "started" reported from
# the copy it had just made. `start` manufacturing the duplicate it exists to detect is the class this
# file was written for.
say_case "§9l start never launches a second copy of a loop that is already running"
seed_quiet_box
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"
HL1="$(spawn_component "$SCRIPTS/heartbeat-loop.sh")"
printf '%s\n' "$(mktemp_dead_pid)" > "$STATE/heartbeat-loop.pid"     # a STALE record, live process
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "FAILING" ] && ok "§9l a live loop with a wrong pidfile reads FAILING" \
                      || bad "§9l the fixture should read FAILING, got [$st]"
OUT="$(run_rows 'fleet_start_component heartbeat-loop' 2>&1)"; SRC=$?
[ "$SRC" = 0 ] && ok "§9l start returns 0 for an already-running loop (nothing to start)" \
               || bad "§9l start returned $SRC for an already-running loop — $OUT"
case "$OUT" in
  *"already running"*) ok "§9l …and it SAYS the failure is the record, not the process" ;;
  *) bad "§9l start did not name the already-running loop — $OUT" ;;
esac
NSAME="$(env FLEET_O="$O" FLEET_HOME="$H" bash -c '. "$1"; fleet_pids_for "$2"' _ "$FLEET_LIB" "$SCRIPTS/heartbeat-loop.sh" | awk 'NF' | wc -l | tr -d ' ')"
[ "${NSAME:-0}" -eq 1 ] && ok "§9l exactly ONE copy is alive afterwards (start did not duplicate)" \
                        || bad "§9l start left ${NSAME} copies — it manufactured the duplicate"
kill9 "$HL1"

# §9m (issue 3) THE READ-BACK MUST NOT TRUST A STALE PS CACHE.
# `fleet_rows` exports `FLEET_PS_CACHE`; the launchd path clears its own cache before re-reading, but
# the start path did not — so the verb reported FAILURE for a process it had just started (and left
# that process running while telling the caller it did not work).
say_case "§9m start verifies against a FRESH process read, not a cached one"
seed_quiet_box
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"
OUT="$(run_rows 'FLEET_PS_CACHE="controller deleted 1 0 never"; fleet_start_component heartbeat-loop' 2>&1)"; SRC=$?
[ "$SRC" = 0 ] && ok "§9m start succeeds despite a stale ps cache" \
               || bad "§9m the read-back used a stale cache and reported a started process as failed ($SRC) — $OUT"
sleep 0.2
NFRESH="$(env FLEET_O="$O" FLEET_HOME="$H" bash -c '. "$1"; fleet_pids_for "$2"' _ "$FLEET_LIB" "$SCRIPTS/heartbeat-loop.sh" | awk 'NF' | wc -l | tr -d ' ')"
[ "${NFRESH:-0}" -ge 1 ] && ok "§9m …and the process it started is really there" \
                         || bad "§9m start reported success but nothing is running"
pkill -9 -f "$SCRIPTS/heartbeat-loop.sh" 2>/dev/null

# §9n (issue 4) ON THE SHIPPED CONFIGURATION (both watchdogs) A FAILING JOB IS STILL REPORTED.
# The pair branch returned OK before it read the launchd job's last exit, so a watchdog whose job exits
# non-zero could never be reported — and "a job exited 2 for hours and nothing noticed" is this file's
# headline case. The plain loop is still covering, so it is not MISSING; it is FAILING, and it says which.
say_case "§9n a failing launchd watchdog is reported even while the plain loop covers"
seed_quiet_box
mk_proc_script "$O/watchdog-loop.sh"; WL="$(spawn_component "$O/watchdog-loop.sh")"
mk_plist "com.eldato.orchestrator-watchdog" "" ""
printf 'PID\tStatus\tLabel\n-\t2\tcom.eldato.orchestrator-watchdog\n' > "$LC_LIST"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" controller-watchdog)"; d="$(detail_of "$ROWS" controller-watchdog)"
[ "$st" = "FAILING" ] && ok "§9n launchd watchdog exit 2 reads FAILING, not OK" \
                      || bad "§9n a failing watchdog must be FAILING, got [$st] — $d"
case "$d" in
  *"plain loop is still covering"*) ok "§9n …and the note says the loop still covers (why it is not fatal)" ;;
  *) bad "§9n the note does not explain the coverage — [$d]" ;;
esac
kill9 "$WL"

# §9o (issue 7) A STALE INSTALLED COPY OF THE CADENCE TIMER IS NAMED, NOT SILENTLY LATE FOREVER.
# The per-tick beacon exists only in the REPO copy; `pi-bootstrap` ships FARMED copies. A healthy timer
# started from a pre-beacon copy writes `CADENCE-TIMER started pid=…` and no beacon, so "no beacon"
# is a statement about the COPY — and the row must say so, or it reads LATE forever with a reason that
# blames a perfectly healthy loop.
say_case "§9o a cadence timer installed before the beacon is reported as a STALE COPY"
seed_quiet_box
mk_proc_script "$SCRIPTS/cadence-timer.sh"; CT="$(spawn_component "$SCRIPTS/cadence-timer.sh")"
printf '%s\n' "$CT" > "$STATE/cadence-timer.pid"
printf '10-18 09:00:00 CADENCE-TIMER started pid=%s interval=450s\n' "$CT" > "$STATE/orchestrator-heartbeat.log"
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" cadence-timer)"; d="$(detail_of "$ROWS" cadence-timer)"
[ "$st" = "LATE" ] && ok "§9o a pre-beacon copy is LATE (its freshness cannot be proven)" \
                   || bad "§9o a pre-beacon cadence timer should be LATE, got [$st]"
case "$d" in
  *"predates the beacon"*) ok "§9o …and the reason names the STALE COPY and the fix, not the loop" ;;
  *) bad "§9o the LATE reason does not name the stale copy — [$d]" ;;
esac
kill9 "$CT"; rm -f "$STATE/cadence-timer.pid"



# ── §9p-§9s the FOURTH round: the cycle-3 reviewer's defects, one arm each ───────────────────────

# §9p (cycle-3 issue 1) CELL IDENTITY IS DECIDED FIRST — and the entry point's OWN seam is what marks
# a cell. The identity test used to sit inside the "supervisor script is missing" branch, but the entry
# point always sets FLEET_CELL_SUPERVISOR to the checkout's cloud-cell-supervisor.sh, which EXISTS — so
# the test was unreachable and every Linux dev box / CI runner stayed MISSING. The mirror image was a
# real cell with no supervisor reading SKIPPED ("not a cell"): a pass on the component that keeps a
# cell's controller alive.
say_case "§9p a cell is a box that carries a cell's identity — not merely a Linux kernel"
seed_quiet_box
# (a) platform=cell, supervisor script PRESENT (the entry point's real configuration), no cell identity
mk_proc_script "$T/cloud-cell-supervisor.sh"
ROWS="$(run_rows 'FLEET_PLATFORM=cell; FLEET_CELL_HOME=""; FLEET_CELL_SUPERVISOR="'"$T"'/cloud-cell-supervisor.sh"; fleet_rows ""')"
st="$(state_of "$ROWS" cell-supervisor)"
[ "$st" = "SKIPPED" ] && ok "§9p a non-cell Linux box reads SKIPPED even when the supervisor script EXISTS" \
                      || bad "§9p a Linux dev box / CI runner must not be red — got [$st]"
# (b) …and a PROVISIONED cell home marks it (a bare directory is not evidence: the entry point
# DEFAULTS CELL_HOME=/tmp/cell-home, which is how this identity test became dead code — cycle-4 review)
CELLH="$T/cellhome"; mkdir -p "$CELLH"; : > "$CELLH/keys.env"
# ⛔ CELL_HOME must be in the ENVIRONMENT: the library maps it to FLEET_CELL_HOME when it is SOURCED,
# so setting it in the eval (after the source) is too late — the same trap `run_rows` cannot express.
ROWS="$(env FLEET_HOME="$H" FLEET_O="$O" FLEET_AGENT_SCRIPTS="$SCRIPTS" FLEET_AGENT_STATE="$STATE" \
  FLEET_LAUNCH_AGENTS_DIR="$A" FLEET_LAUNCHCTL="$BIN/launchctl" FLEET_PLUTIL="$BIN/plutil" \
  FLEET_PLATFORM=cell CELL_HOME="$CELLH" FLEET_CELL_SUPERVISOR="" PATH="$BIN:$PATH" \
  bash -c 'set -uo pipefail; . "$1"; fleet_rows ""' _ "$FLEET_LIB")"
st="$(state_of "$ROWS" cell-supervisor)"
[ "$st" = "MISSING" ] && ok "§9p CELL_HOME (the entry point's own seam) marks a cell → supervisor gone is MISSING" \
                      || bad "§9p a cell with no supervisor must be MISSING, got [$st]"
# (b2) a bare directory with no cell marker is NOT identity — the defaulted path must not make a
# Linux dev box or CI runner a "cell"
BAREH="$T/barehome"; mkdir -p "$BAREH"
ROWS="$(run_rows 'FLEET_PLATFORM=cell; FLEET_CELL_HOME="'"$BAREH"'"; FLEET_CELL_SUPERVISOR="'"$T"'/cloud-cell-supervisor.sh"; fleet_rows ""')"
st="$(state_of "$ROWS" cell-supervisor)"
[ "$st" = "SKIPPED" ] && ok "§9p a bare CELL_HOME path is not cell identity (only a PROVISIONED one is)" \
                      || bad "§9p a defaulted-but-empty cell home must not count as identity — got [$st]"
# (c) a real cell whose supervisor is missing reads MISSING, not "not a cell"
ROWS="$(run_rows 'FLEET_PLATFORM=cell; FLEET_CELL_HOME="'"$T"'/srvcell"; FLEET_CELL_SUPERVISOR=/nonexistent.sh; fleet_rows ""')"
st="$(state_of "$ROWS" cell-supervisor)"; d="$(detail_of "$ROWS" cell-supervisor)"
[ "$st" = "MISSING" ] && ok "§9p a cell whose supervisor is GONE reads MISSING (never a SKIPPED pass)" \
                      || bad "§9p a cell with a missing supervisor should be MISSING, got [$st]"
case "$d" in
  *"dev box"*) bad "§9p a real cell was told it is not a cell — [$d]" ;;
  *) ok "§9p …and it is not told it is a dev box" ;;
esac

# §9q (cycle-3 issue 5) A DIAGNOSED ROW MUST BE REPAIRABLE.
# The recycled-pid FAILING row (pidfile names a live pid that is not this loop) was launched at, but the
# SHIPPED launcher refuses to run while its pidfile names a live pid — so the copy exited, the read-back
# failed, and `start` reported a failure that pointed at the launcher instead of the pidfile it had just
# diagnosed. The verb now clears the record it has already proven stale.
say_case "§9q start clears a pidfile it has PROVEN stale, so a FAILING row is repairable"
seed_quiet_box
# A launcher that carries the shipped guard: refuse to run while the pidfile names a LIVE pid.
cat > "$SCRIPTS/heartbeat-loop.sh" <<LAUNCHER
#!/bin/bash
PF="$STATE/heartbeat-loop.pid"       # absolutised: this suite must never touch the operator's \$HOME
if [ -f "\$PF" ]; then
  old="\$(tr -dc '0-9' < "\$PF")"
  if [ -n "\$old" ] && kill -0 "\$old" 2>/dev/null; then
    echo "heartbeat loop already running (pid \$old)"; exit 0
  fi
fi
printf '%s\\n' "\$\$" > "\$PF"
sleep 300
LAUNCHER
chmod +x "$SCRIPTS/heartbeat-loop.sh"
NOTLOOP="$(spawn_component "$SCRIPTS/cadence-timer.sh" 2>/dev/null || true)"
sleep 300 & NOTLOOP=$!; track "$NOTLOOP"
printf '%s\n' "$NOTLOOP" > "$STATE/heartbeat-loop.pid"      # alive, but NOT the loop
printf '%s\n' "$(date +%s)" > "$STATE/orchestrator-heartbeat.log"   # its own freshness signal
sleep 0.3
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "FAILING" ] && ok "§9q the fixture reads FAILING (a recycled pid in the pidfile)" \
                      || bad "§9q the fixture should read FAILING, got [$st]"
OUT="$(run_rows 'fleet_start_component heartbeat-loop' 2>&1)"; SRC=$?
[ "$SRC" = 0 ] && ok "§9q start REPAIRS the row (returns 0)" \
               || bad "§9q start could not repair a diagnosed row ($SRC) — $OUT"
case "$OUT" in
  *"recycled pid"*) ok "§9q …and it says it removed the stale record, naming why" ;;
  *) bad "§9q start did not explain the record it cleared — $OUT" ;;
esac
sleep 0.4
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "OK" ] && ok "§9q …and the row is OK afterwards (repair verified by the predicate)" \
                 || bad "§9q the row should be OK after the repair, got [$st] — $(detail_of "$ROWS" heartbeat-loop)"
pkill -9 -f "$SCRIPTS/heartbeat-loop.sh" 2>/dev/null

# …and the OTHER direction, which the first version of this repair got WRONG: a pidfile naming a live
# copy running from a DIFFERENT path. The exact-argv predicate cannot see that copy, so "not this path"
# is not proof of "recycled pid" — deleting the record started a second loop and then reported OK over
# two of them (a false pass, and the duplicate this file exists to catch).
say_case "§9q(b) a pidfile naming a live copy at ANOTHER PATH is respected, not deleted"
seed_quiet_box
mkdir -p "$T/other"
cat > "$T/other/heartbeat-loop.sh" <<'OTHER'
#!/bin/bash
printf '%s\n' "$$" > "$HEARTBEAT_PIDFILE"
sleep 300
OTHER
chmod +x "$T/other/heartbeat-loop.sh"
OPID="$(HEARTBEAT_PIDFILE="$STATE/heartbeat-loop.pid" bash "$T/other/heartbeat-loop.sh" >/dev/null 2>&1 & echo $!)"
timeout_kill() { kill -9 "$1" 2>/dev/null; }
track "$OPID"
sleep 0.4
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"      # the installed copy EXISTS but must not be started
printf '%s\n' "$(date +%s)" > "$STATE/orchestrator-heartbeat.log"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "FAILING" ] && ok "§9q(b) the fixture reads FAILING (the record is not the installed copy)" \
                      || bad "§9q(b) the fixture should read FAILING, got [$st]"
OUT="$(run_rows 'fleet_start_component heartbeat-loop' 2>&1)"; SRC=$?
case "$OUT" in
  *"another path"*) ok "§9q(b) start REFUSES: the live copy at another path owns the record" ;;
  *) bad "§9q(b) start did not name the other-path copy — $OUT" ;;
esac
[ "$SRC" = 0 ] && ok "§9q(b) start returns 0 (nothing was started, nothing failed)" \
               || bad "§9q(b) start returned $SRC — $OUT"
NAPPLIED="$(env FLEET_O="$O" FLEET_HOME="$H" bash -c '. "$1"; fleet_pids_for "$2"' _ "$FLEET_LIB" "$SCRIPTS/heartbeat-loop.sh" | awk 'NF' | wc -l | tr -d ' ')"
[ "${NAPPLIED:-0}" -eq 0 ] && ok "§9q(b) NO second copy was launched (no manufactured duplicate)" \
                          || bad "§9q(b) start launched the installed copy beside the other-path one"
kill -9 "$OPID" 2>/dev/null

# §9r (cycle-3 issue 4) THE CALLER MUST NOT SAY "started" FOR A NO-OP.
# The verb said "already running — left alone" and the caller then printed "started heartbeat-loop": two
# contradicting lines in one command, one of them false.
say_case "§9r start reports what it DID, so a no-op is never reported as a start"
seed_quiet_box
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"
ALIVE="$(spawn_component "$SCRIPTS/heartbeat-loop.sh")"
printf '%s\n' "$(mktemp_dead_pid)" > "$STATE/heartbeat-loop.pid"
printf 'PID\tStatus\tLabel\n' > "$LC_LIST"
sleep 0.3
OUT="$(run_rows 'fleet_ensure_components ""' 2>&1)"
case "$OUT" in
  *"started heartbeat-loop"*) bad "§9r the caller claimed a start for an already-running loop — $OUT" ;;
  *) ok "§9r the caller does not claim a start it did not perform" ;;
esac
case "$OUT" in
  *"heartbeat-loop: already running"*) ok "§9r …it reports the no-op as a no-op" ;;
  *) bad "§9r the no-op is not reported — $OUT" ;;
esac
kill9 "$ALIVE"

# §9s (cycle-3 issue 3) AN ABSTENTION PRINTS ONE CONTROLLER LINE, WITH NO MISATTRIBUTION.
# `foreign` is `live minus own`, so it is non-empty *because* own abstained — the old guard could never
# fire, and the screen printed CANNOT DETERMINE and then a confident RUNNING that called this state
# dir's OWN controller "another repo's", plus `lock: none` about a lock it could not read.
say_case "§9s an unreadable owner read abstains ONCE — no RUNNING line, no misattribution"
seed_quiet_box
mk_proc_script "$O/orch-loop.sh"; CPL="$(spawn_component "$O/orch-loop.sh")"
printf '%s\n' "$CPL" > "$O/.orch.lock"
cat > "$T/bin/ps-noetime2" <<'PSSHIM'
#!/bin/bash
# The ENTRY POINT dates a pid with `lstart` and the INVENTORY with `-o etime=`: a shim that fails only
# one of them leaves the other answering, so the screen would legitimately print RUNNING and the arm's
# premise (an abstention) would never be exercised.
case "$*" in *etime*|*lstart*) exit 1 ;; esac
exec /bin/ps "$@"
PSSHIM
chmod +x "$T/bin/ps-noetime2"
sleep 0.3
OUT="$(env -i HOME="$H" PATH="$BIN:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  O="$O" FLEET_LAUNCHCTL_LIST="$LC_LIST" FLEET_LAUNCHCTL_CALLS="$FLEET_LAUNCHCTL_CALLS" \
  FLEET_AGENT_SCRIPTS="$SCRIPTS" FLEET_AGENT_STATE="$STATE" FLEET_LAUNCH_AGENTS_DIR="$A" \
  FLEET_PLATFORM=mac FLEET_PLUTIL="$BIN/plutil" FLEET_PS="$T/bin/ps-noetime2" \
  PS_BIN="$T/bin/ps-noetime2" \
  bash "$HERE/orchestrator-bringup.sh" status 2>&1)"; SRC=$?
nrun="$(printf '%s\n' "$OUT" | grep -c '^controller: RUNNING' || true)"
[ "${nrun:-0}" -eq 0 ] && ok "§9s no controller RUNNING line is printed when the owner read abstained" \
                       || bad "§9s a RUNNING line contradicts the abstention ($nrun) — $(printf '%s\n' "$OUT" | grep -E 'controller:|lock:' | tr '\n' ' | ')"
case "$OUT" in
  *"NOT attributable to this state dir"*) bad "§9s the abstention misattributed this state dir's own controller — $OUT" ;;
  *) ok "§9s …and no pid is misattributed to another repo" ;;
esac
case "$OUT" in
  *"lock: none"*) bad "§9s 'lock: none' was asserted from a lock read that failed — $OUT" ;;
  *) ok "§9s …and no 'lock: none' is asserted about an unreadable lock" ;;
esac
case "$OUT" in
  *"fleet components"*) ok "§9s the fleet TABLE still prints (one unreadable datum does not suppress it)" ;;
  *) bad "§9s the table was suppressed by one unreadable read — $OUT" ;;
esac
[ "$SRC" = 2 ] && ok "§9s …and the exit code is 2 (cannot determine), not 1 or 0" \
               || bad "§9s an abstaining read must exit 2, got $SRC"
kill9 "$CPL"

# §9t (#2026) THE LIVENESS BOUNDS §9t OWNS ARE PINNED BY NAME, IN BOTH DIRECTIONS.
# `FLEET_HEARTBEAT_LATE_S` is the one term the stall-term registry's reverse scan can SEE (its name
# carries the HEARTBEAT token); `FLEET_CONTROLLER_LATE_S`, `FLEET_CADENCE_LATE_S` and
# `FLEET_JOB_SLACK_S` carry no family token, so they are registered as out-of-family — and a term
# registered that way must cite a test that actually names it (the registry's guardedBy-attribution
# assertion). (`FLEET_LANDER_BOUND_S` is the fifth registered term; §9e flips it.) More to the point, a bound with
# no arm is a bound a future edit can delete silently: the LATE arms above use `touch -t` far in the
# past, which trips ANY bound, so none of them distinguishes the bound's VALUE from luck. These arms
# move only the named seam, so the row can only flip because the bound moved.
say_case "§9t the heartbeat, controller, cadence and job-slack bounds each flip the row when only THAT seam moves"
seed_quiet_box
mk_proc_script "$SCRIPTS/heartbeat-loop.sh"
HL2="$(spawn_component "$SCRIPTS/heartbeat-loop.sh")"; printf '%s\n' "$HL2" > "$STATE/heartbeat-loop.pid"
printf '%s\n' "$(date +%s)" > "$STATE/orchestrator-heartbeat.log"
sleep 2.2                                     # the log is now ~2 s old, and readable as such
ROWS="$(run_rows 'FLEET_HEARTBEAT_LATE_S=1; fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "LATE" ] && ok "§9t FLEET_HEARTBEAT_LATE_S=1 makes a ~2 s old log LATE (the bound is read, not decoration)" \
                    || bad "§9t a 2 s old log under a 1 s bound should read LATE, got [$st]"
ROWS="$(run_rows 'FLEET_HEARTBEAT_LATE_S=9000; fleet_rows ""')"
st="$(state_of "$ROWS" heartbeat-loop)"
[ "$st" = "OK" ] && ok "§9t …and FLEET_HEARTBEAT_LATE_S=9000 reads the SAME log OK (so the arm cannot pass by always LATE)" \
                 || bad "§9t a 2 s old log under a 9000 s bound should read OK, got [$st]"
kill9 "$HL2"; rm -f "$STATE/heartbeat-loop.pid"
# The controller's bound is read straight off `$O/heartbeat`, so the seam is moved the same way. This
# one had NO seam arm at all before: §9f trips it with `touch -t 202001010000`, which would stay LATE
# under any bound, so a hard-coded 1800 passed every arm.
seed_quiet_box
mk_proc_script "$O/orch-loop.sh"
CL2="$(spawn_component "$O/orch-loop.sh")"; printf '%s\n' "$CL2" > "$O/.orch.lock"
printf '%s\n' "$(date +%s)" > "$O/heartbeat"
sleep 2.2
ROWS="$(run_rows 'FLEET_CONTROLLER_LATE_S=1; fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" = "LATE" ] && ok "§9t FLEET_CONTROLLER_LATE_S=1 makes a ~2 s old heartbeat LATE" \
                    || bad "§9t a 2 s old controller heartbeat under a 1 s bound should read LATE, got [$st]"
ROWS="$(run_rows 'FLEET_CONTROLLER_LATE_S=9000; fleet_rows ""')"
st="$(state_of "$ROWS" controller)"
[ "$st" = "OK" ] && ok "§9t …and FLEET_CONTROLLER_LATE_S=9000 reads the same heartbeat OK" \
                 || bad "§9t a 2 s old controller heartbeat under a 9000 s bound should read OK, got [$st]"
kill9 "$CL2"; rm -f "$O/.orch.lock"
seed_quiet_box
mk_proc_script "$SCRIPTS/cadence-timer.sh"
CT2="$(spawn_component "$SCRIPTS/cadence-timer.sh")"; printf '%s\n' "$CT2" > "$STATE/cadence-timer.pid"
printf '%s\n' "$(date +%s)" > "$STATE/cadence-timer.beat"
sleep 2.2
ROWS="$(run_rows 'FLEET_CADENCE_LATE_S=1; fleet_rows ""')"
st="$(state_of "$ROWS" cadence-timer)"
[ "$st" = "LATE" ] && ok "§9t FLEET_CADENCE_LATE_S=1 makes a ~2 s old beacon LATE" \
                    || bad "§9t a 2 s old beacon under a 1 s bound should read LATE, got [$st]"
ROWS="$(run_rows 'FLEET_CADENCE_LATE_S=9000; fleet_rows ""')"
st="$(state_of "$ROWS" cadence-timer)"
[ "$st" = "OK" ] && ok "§9t …and FLEET_CADENCE_LATE_S=9000 reads the same beacon OK" \
                 || bad "§9t a 2 s old beacon under a 9000 s bound should read OK, got [$st]"
kill9 "$CT2"; rm -f "$STATE/cadence-timer.pid"
seed_quiet_box
# A job's own freshness bound is `2 × its StartInterval + FLEET_JOB_SLACK_S`. With a 1 s interval the
# base bound is 2 s, so a ~3 s old log is LATE at slack 0 and OK at the shipped-magnitude slack — the
# slack is the ONLY thing that moved between the two readings.
mk_plist "com.tortoise.worktree-reaper" 1 ""
printf 'PID\tStatus\tLabel\n-\t0\tcom.tortoise.worktree-reaper\n' > "$LC_LIST"
: > "$STATE/pi-reap-worktrees.log"
sleep 3.2
ROWS="$(run_rows 'FLEET_JOB_SLACK_S=0; fleet_rows ""')"
st="$(state_of "$ROWS" reaper.worktree-reaper)"
[ "$st" = "LATE" ] && ok "§9t FLEET_JOB_SLACK_S=0 makes a 3 s old log LATE against a 2 s derived bound" \
                    || bad "§9t a 3 s old log under a 2 s bound should read LATE, got [$st]"
ROWS="$(run_rows 'FLEET_JOB_SLACK_S=300; fleet_rows ""')"
st="$(state_of "$ROWS" reaper.worktree-reaper)"
[ "$st" = "OK" ] && ok "§9t …and FLEET_JOB_SLACK_S=300 reads the same log OK (the slack widened the bound)" \
                 || bad "§9t a 3 s old log under a 302 s bound should read OK, got [$st]"
rm -f "$STATE/pi-reap-worktrees.log"

# §9u THE DRAIN LOOP ROW (`lander-drain`) — the component that DECIDES what lands. Its failure mode is
# silence: a loop that is off opens no PR, reds no check and logs nothing, so the row must be able to
# say (a) nothing has ever run, (b) a fresh run and what it measured, and (c) a run that went stale.
# The CI queue depth is asserted IN THE ROW because that is the number the row exists to surface.
say_case "§9u the lander-drain row reports never-run / fresh / stale, with the CI queue depth"
seed_quiet_box
LDRAIN="$O/state/lander-last"; mkdir -p "$O/state"
rm -f "$LDRAIN"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" lander-drain)"
[ "$st" = "SKIPPED" ] && ok "§9u no run recorded reads SKIPPED (a box with no drain loop is not broken)" \
                      || bad "§9u no run recorded should read SKIPPED, got [$st]"
case "$(detail_of "$ROWS" lander-drain)" in
  *"GREEN PRs THEN WAIT FOR A HUMAN"*) ok "§9u …and the advice names the consequence, not the file path" ;;
  *) bad "§9u the never-run advice does not name the consequence: $(detail_of "$ROWS" lander-drain)" ;;
esac
printf '%s 4 11 2 0 40 15 0\n' "$(date +%s)" > "$LDRAIN"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" lander-drain)"
# The drain's OUTPUT (counts + queue depth) is the row's ACTUAL column — a fresh run that merged
# nothing is information, so it belongs beside the freshness, not in an advice string.
act="$(printf '%s\n' "$ROWS" | awk -F'\t' '$1=="lander-drain"{print $3}')"
[ "$st" = "OK" ] && ok "§9u a fresh run record reads OK" || bad "§9u a fresh record should read OK, got [$st]"
case "$act" in
  *"CI queue 4 queued/11 in progress"*) ok "§9u …and the row carries the CI queue depth ($act)" ;;
  *) bad "§9u the queue depth is NOT in the row: [$act]" ;;
esac
printf '%s 4 11 2 0 40 15 0\n' "$(( $(date +%s) - 7200 ))" > "$LDRAIN"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" lander-drain)"
[ "$st" = "LATE" ] && ok "§9u a run older than the bound reads LATE (the loop is off)" \
                   || bad "§9u a stale record should read LATE, got [$st]"
[ "$(severity_of_row "$ROWS" lander-drain)" = "RC=1" ] && ok "§9u …and a stale drain fails the table" \
                                                       || bad "§9u a stale drain must fail the table"
printf 'garbage\n' > "$LDRAIN"
ROWS="$(run_rows 'fleet_rows ""')"
st="$(state_of "$ROWS" lander-drain)"
[ "$st" = "UNKNOWN" ] && ok "§9u an unreadable record reads UNKNOWN, never OK" \
                      || bad "§9u an unreadable record should read UNKNOWN, got [$st]"
rm -f "$LDRAIN"


printf '\n%s\n' "──────────────────────────────────────────────"
printf 'fleet-inventory: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
