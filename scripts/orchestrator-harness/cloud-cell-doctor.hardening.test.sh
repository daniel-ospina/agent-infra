#!/usr/bin/env bash
# cloud-cell-doctor.hardening.test.sh — the HARDENING contract for agent-infra#1989.
#
# ⛔ This is a DIFFERENT suite from `cloud-cell-doctor.test.sh`, which runs beside it: that one pins the
# role's primary behaviours (a wedged lane is reaped, the rail is gated on a clean attestation, `status`
# separates "configured" from "ran"), and inherits the #1713/#1711 regression contract. THIS file pins
# what #1989's review turned up one class at a time — every "cannot-verify" the doctor must produce
# rather than a clean-looking row, and every path where an action that did not take must not be
# recorded as one that did. Running the wrong file is a silent false green, so the paths are named
# exactly.
#
# It drives the SHIPPED `cloud-cell-doctor.sh` against stubs — the real tmux server, the real `ps`
# table and the real API are never touched — and covers:
#
#   * an UNREADABLE read is cannot-verify, never an answer: the session list (incl. a `mktemp` failure),
#     an unreachable tmux binary, the client list, the ancestry walk, the pane read, the log mtime, the
#     process table, the open-PR read, the review record;
#   * a benign non-answer is NOT cannot-verify: a fresh box with no server ever started, a lane that
#     ended between reads, a kill that takes the last session with it;
#   * an action that did not take is not a reap: a refused kill, an unverifiable kill, cpu that went
#     DOWN between the two observations;
#   * the merge rail's rc classifier is a PREDICATE (`124..127` and any `128+N`), so no unintended rc is
#     ever recorded as the rail's refusal, and a failed/stale-doctor restart is recorded as such;
#   * `status`'s row-level verdict: an unreadable `last_rc` FAILS the cell, and a role that recorded
#     cannot-verify FAILS it;
#   * a REHEARSAL IS NOT A VERDICT — `--dry-run` keeps the worse of (stored verdict, its own) and says
#     in the record that it was a rehearsal, on every role that rehearses and on the stop-mid-pass path;
#   * the invariants that keep the above from becoming a hang or a double act: the per-call read bound
#     (with and without `timeout(1)`), the whole-pass read budget, and the role lock.
#
# Run: bash scripts/orchestrator-harness/cloud-cell-doctor.hardening.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="${DOCTOR_UNDER_TEST:-$HERE/cloud-cell-doctor.sh}"   # the doctor ships in the harness dir, so
SUP="$HERE/../cloud-cell-supervisor.sh"                     # `start` seeds it into $O with the workers

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
say_case() { echo; echo "── $1 ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cell-doctor-test.XXXXXX")"
REAL_SLEEP="$(command -v sleep)"
cleanup() {
  # The loop fixture is backgrounded; never leave it (or a stub `sleep`) behind.
  [ -n "${LOOP_PID:-}" ] && kill -TERM "$LOOP_PID" 2>/dev/null || true
  for p in ${LANE_PIDS:-}; do kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$T"
}
trap cleanup EXIT

[ -f "$DOCTOR" ] && ok "shipped doctor present: $(basename "$DOCTOR")" || { bad "missing $DOCTOR"; exit 1; }
[ -f "$SUP" ]    && ok "shipped supervisor present" || { bad "missing $SUP"; exit 1; }

mkdir -p "$T/home" "$T/o/logs" "$T/repo" "$T/bin" "$T/tmux/panes" "$T/tmux/clients" "$T/ps"

# ── stubs ────────────────────────────────────────────────────────────────────────────────────────
# tmux: sessions list, pane pid per session, attached clients per session, and a kill LOG so the
# suite asserts the exact target (`=name`) the reaper used — not merely "a kill happened".
cat > "$T/bin/tmux" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_TMUX:?}"
sub="${1:-}"; shift
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do
    if [ "$1" = "$want" ]; then printf '%s' "$2"; return 0; fi
    shift
  done; }
case "$sub" in
  ls)
    # ⛔ Every read is COUNTED, so an arm can prove that a verification read was actually TAKEN. A
    # suite that only asserts the outcome cannot tell "the kill was verified" from "no verification
    # exists and every kill is counted" — which is exactly the pre-fix behaviour.
    printf x >> "$S/ls-calls"
    # `fail-ls` models a tmux whose answer cannot be taken: the server is unreachable, so the read
    # fails for a reason that proves NOTHING about which sessions exist. It is armed by kill-session
    # so an arm can still LIST the lane first (the pass must see it) and lose the read only after.
    # ⛔ NOT the `(No such file or directory)` form: on tmux 3.4 that one means the socket FILE does not
    # exist — a box where no server has ever started — which is an EMPTY namespace, not a failed read
    # (see `no-socket`). A refused CONNECTION proves nothing about which sessions exist, and that is
    # what this marker must model.
    if [ -f "$S/fail-ls" ]; then printf 'error connecting to /tmp/tmux-0/default (Permission denied)\n' >&2; exit 1; fi
    # A tmux that HANGS: the read a wedged server gives, and the one the per-call bound exists for.
    # Reached only through `bounded`, so a missing bound shows up as the whole pass hanging.
    if [ -f "$S/slow-ls" ]; then exec /bin/sleep 30; fi
    # The OTHER benign non-zero `ls` (measured on tmux 3.4): on a box where no server has EVER started,
    # the socket file does not exist and tmux says so. That is an EMPTY namespace, not a failed read —
    # the same shape as `no-server` below, from the other end of a server's life. A fresh cell is
    # exactly this box, so classifying it as cannot-verify makes every role red on a healthy new cell.
    if [ -f "$S/no-socket" ]; then printf 'error connecting to /tmp/tmux-0/default (No such file or directory)\n' >&2; exit 1; fi
    # tmux's own "no server running", which IS an empty list (every session is gone, the server exits
    # with the last one). The distinction between this and `fail-ls` is the whole contract of
    # `tmux_session_list`, and only this marker exercises the benign half.
    if [ -f "$S/no-server" ]; then printf 'no server running on /tmp/tmux-0/default\n' >&2; exit 1; fi
    # ⛔ A `stop` that arrives WHILE THIS PASS IS RUNNING, modelled at the first read the pass takes (a
    # marker is armed and the arm runs the role once). `stop`'s first action is to bump the loop's stop
    # generation, so that is exactly what this hook does — `cell_stopped_midpass` must then refuse every
    # destructive step the pass had not started yet, and the pass must still record a verdict.
    if [ -f "$S/stop-midpass" ] && [ -n "${DOCTOR_TEST_STOPGEN:-}" ]; then
      printf '9\n' > "$DOCTOR_TEST_STOPGEN" 2>/dev/null || true
    fi
    if [ "${1:-}" = "-F" ]; then cat "$S/sessions" 2>/dev/null; exit 0; fi
    while IFS= read -r n; do [ -n "$n" ] && printf '%s: 1 windows (created now)\n' "$n"; done < "$S/sessions" 2>/dev/null
    exit 0 ;;
  has-session)
    n="$(arg -t "$@")"; n="${n#=}"
    [ -n "$n" ] && grep -qx -- "$n" "$S/sessions" 2>/dev/null && exit 0; exit 1 ;;
  list-panes)
    n="$(arg -t "$@")"; n="${n#=}"
    # A read that cannot be taken while the session list is perfectly readable: the reap must not call
    # it "no pane pid" (a benign skip on a clean pass) — the session is still listed, so the question
    # the pid answers is unanswered.
    [ -f "$S/fail-panes" ] && { printf 'error connecting to server\n' >&2; exit 1; }
    # The lane ENDED between reads: it was listed at the entry read, and the verification reads now
    # find it gone. That is an ANSWER (nothing left to judge), not a failed read.
    if [ -f "$S/end-after-list" ]; then
      grep -vx -- "$n" "$S/sessions" > "$S/sessions.tmp" 2>/dev/null || true
      mv -f "$S/sessions.tmp" "$S/sessions" 2>/dev/null || true
      exit 0
    fi
    cat "$S/panes/$n" 2>/dev/null; exit 0 ;;
  list-clients)
    n="$(arg -t "$@")"; n="${n#=}"
    # A client list that cannot be taken must not answer "no human attached": that is the last gate
    # before a kill, so a failed READ there means cannot-verify, never a reap.
    [ -f "$S/fail-clients" ] && { printf 'error connecting to server\n' >&2; exit 1; }
    # The lane ENDED one read later than `end-after-list` does: the client list answers (so the pass
    # reaches the ancestry gate), and the session is gone by the time that gate needs to arbitrate.
    if [ -f "$S/end-after-clients" ]; then
      grep -vx -- "$n" "$S/sessions" > "$S/sessions.tmp" 2>/dev/null || true
      mv -f "$S/sessions.tmp" "$S/sessions" 2>/dev/null || true
    fi
    cat "$S/clients/$n" 2>/dev/null; exit 0 ;;
  kill-session)
    n="$(arg -t "$@")"
    printf '%s\n' "$n" >> "$S/killed"
    [ -f "$S/fail-ls-after-kill" ] && : > "$S/fail-ls"
    [ -f "$S/no-server-after-kill" ] && : > "$S/no-server"
    # A REFUSED kill: the double records the attempt and leaves the session in place, so an arm can
    # prove the reaper verifies its own kill instead of counting it.
    [ -f "$S/refuse-kill" ] && exit 0
    grep -vx -- "${n#=}" "$S/sessions" > "$S/sessions.tmp" 2>/dev/null || true
    mv -f "$S/sessions.tmp" "$S/sessions" 2>/dev/null || : > "$S/sessions"
    exit 0 ;;
  new-session)
    printf '%s\n' "$*" >> "$S/new-session"
    exit 0 ;;
  *) exit 0 ;;
esac
SH

# ps: a table (`-A`) and a per-pid ancestry/lstart (`-p`). Modes drive the two-observation gate:
#   wedge  identical readings both ticks
#   cpu    the subtree GAINS cpu on the second read
#   start  the lstart differs on the second read (the pid was recycled) -> TERM must not be sent
cat > "$T/bin/ps" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_PS:?}"
if [ "${1:-}" = "-A" ]; then
  n=0; [ -f "$S/calls" ] && n="$(cat "$S/calls")"
  n=$((n + 1)); printf '%s\n' "$n" > "$S/calls"
  m="$(cat "$S/mode" 2>/dev/null)"
  if [ "$m" = "cpu" ] && [ "$n" -ge 2 ]; then
    awk '{print $1, $2, "00:00:17"}' "$S/table" 2>/dev/null
  elif [ "$m" = "cpu-drop" ] && [ "$n" -ge 2 ]; then
    # A LOWER second reading: a subtree member exited, or the bounded read cut the table short.
    awk '{print $1, $2, "00:00:05"}' "$S/table" 2>/dev/null
  else
    cat "$S/table" 2>/dev/null
  fi
  exit 0
fi
if [ "${1:-}" = "-p" ]; then
  pid="$2"; fmt="${4:-}"
  # A per-pid read that cannot be taken: the ancestry walk gets an EMPTY row from a `ps` that failed,
  # which must never be read as "no human above" — that is the gate immediately before the kill.
  [ -f "$S/pfail" ] && exit 1
  # …and one that breaks ONLY the ancestry read: with `pfail` the lstart read fails too, so the
  # pre-fix script's TERM/KILL block abstains for a different reason and the signal assertion could
  # not discriminate. This marker leaves the fence readable.
  [ -f "$S/pfail-ppid" ] && [ "$fmt" != "lstart=" ] && exit 1
  if [ "$fmt" = "lstart=" ]; then
    if [ -f "$S/lstart.$pid" ]; then cat "$S/lstart.$pid"; else printf 'Mon Jan  1 00:00:00 2020'; fi
    exit 0
  fi
  if [ -f "$S/args.$pid" ]; then cat "$S/args.$pid"; else printf '1 (init)\n'; fi
  exit 0
fi
exit 0
SH

# sleep: appends to the lane log between the two observations when the suite asks for "still
# writing"; otherwise it is the real sleep (the loop fixture needs real time to pass).
cat > "$T/bin/sleep" <<SH
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = "2" ] && [ -f "$T/writing" ]; then printf 'progress\\n' >> "$T/o/logs/lane-42.log"; fi
done
exec "$REAL_SLEEP" "\$@"
SH

cat > "$T/bin/gh" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_GH:?}"
# A HANGING `gh` is the case the open-PR read's bound exists for: an unbounded read stalls the merge
# role with its lock held, stopping hygiene and the next pass too.
[ -f "$S/slow" ] && exec /bin/sleep 30
if [ "${1:-}" = "api" ]; then
  rc="$(cat "$S/rc" 2>/dev/null)"; [ -n "$rc" ] && { cat "$S/prs.json" 2>/dev/null; exit "$rc"; }
  cat "$S/prs.json" 2>/dev/null; exit 0
fi
exit 0
SH

cat > "$T/bin/stat" <<'SH'
#!/bin/bash
# A `stat` that cannot read an EXISTING file: the log-mtime read is then a FAILED read, not the
# documented "no log" exclusion. Real `stat` is used for everything else.
[ -f "${DOCTOR_TEST_STAT:?}/fail" ] && exit 1
exec "$(command -v stat.real 2>/dev/null || echo /usr/bin/stat)" "$@"
SH

cat > "$T/bin/du" <<'SH'
#!/bin/bash
printf '100\t%s\n' "${!#}"
SH

cat > "$T/bin/uv" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCTOR_TEST_UV:?}/uv-calls"
exit 0
SH

cat > "$T/bin/rail.sh" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_RAIL:?}"
printf '%s\n' "$*" >> "$S/calls"
rc="$(cat "$S/rc" 2>/dev/null)"; rc="${rc:-0}"
[ "$rc" = 0 ] || printf 'admin-merge: REFUSED (%s) — a test refusal\n' "$*"
exit "$rc"
SH

cat > "$T/bin/sup" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_SUP:?}"
printf '%s\n' "$*" >> "$S/calls"
exit "$(cat "$S/rc" 2>/dev/null || echo 0)"
SH

cat > "$T/bin/df" <<'SH'
#!/bin/bash
# `free_mb` reads column 4 of row 2. A marker makes the answer EMPTY — the state its own comment
# calls "cannot judge", which the auto-arming decision must treat as cannot-verify, never "enough".
S="${DOCTOR_TEST_DF:-/nonexistent}"
[ -f "$S/free-unknown" ] && exit 0
# Plenty free (10 GiB), so this stub does not accidentally arm the low-space path the real box is on.
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 20000000 100 10000000 1%% /\n'
SH

cat > "$T/bin/wt-reaper.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCTOR_TEST_WT:?}/calls"
exit "$(cat "${DOCTOR_TEST_WT:?}/rc" 2>/dev/null || echo 0)"
SH

chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# ── shared environment ──────────────────────────────────────────────────────────────────────────
export CELL_HOME="$T/home" O="$T/o" REPO="$T/repo" OR="daniel-ospina/agent-infra"
export SESSION="orch" DOCTOR_SESSION="cell-doctor"
export DOCTOR_TMUX_BIN="$T/bin/tmux" DOCTOR_PS_BIN="$T/bin/ps" DOCTOR_GH_BIN="$T/bin/gh"
export DOCTOR_SLEEP_BIN="$T/bin/sleep"
export DOCTOR_TEST_TMUX="$T/tmux" DOCTOR_TEST_PS="$T/ps" DOCTOR_TEST_GH="$T/gh" DOCTOR_TEST_STAT="$T/stat"
# ⛔ The `status` fixture runs the REAL roles, so these two are in force from the top: the `uv` double
# aborts with `:?` when DOCTOR_TEST_UV is unset, and with no reaper path hygiene records
# `worktrees cannot-verify (no reaper found)` (hv=3) — the shipped reaper is not reachable from
# $SELF_DIR, $REPO or $CELL_HOME in this fixture. Either way the "every role passed -> status is green"
# arm was exercising FAILING passes.
export DOCTOR_TEST_UV="$T/uv" DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt"
# The mid-pass `stop` hook in the tmux double bumps this (the file `stop` writes first), so an arm can
# make a stop arrive DURING a pass that is already running.
export DOCTOR_TEST_STOPGEN="$T/o/state/roles/.stop-generation"
export REAP_MIN_S=60 REAP_SAMPLE_S=2 DOCTOR_INTERVAL=1 MERGE_INTERVAL=1 HYGIENE_INTERVAL=1
export MERGE_RETRY_S=3600 CONTROLLER_STALE_S=60
mkdir -p "$T/gh" "$T/rail" "$T/sup" "$T/wt" "$T/uv" "$T/stat"

doc() { # <role> [extra env assignments via env]
  OUT="$(bash "$DOCTOR" "$@" 2>&1)"; RC=$?
}
reset_tmux() { rm -f "$T/tmux/sessions" "$T/tmux/killed" "$T/tmux/new-session" "$T/tmux/refuse-kill" "$T/tmux/fail-ls" "$T/tmux/fail-ls-after-kill" "$T/tmux/no-server" "$T/tmux/no-server-after-kill" "$T/tmux/no-socket" "$T/tmux/fail-clients" "$T/tmux/slow-ls" "$T/tmux/fail-panes" "$T/tmux/end-after-list" "$T/tmux/end-after-clients" "$T/tmux/stop-midpass" "$T/tmux/ls-calls"; touch "$T/tmux/sessions"; }
reset_ps()   { rm -f "$T/ps/calls" "$T/ps/mode" "$T/ps/pfail" "$T/ps/pfail-ppid" "$T/ps/args."* "$T/ps/lstart."*; rm -f "$T/stat/fail" "$T/gh/slow"; }
reset_state(){ rm -rf "$T/o/state"; mkdir -p "$T/o/state/roles"; }
# ⛔ The pane pid is a process THIS SUITE owns, never a literal. After the lstart fence the reaper
# signals the pane pid it measured, and the `ps` double returns a constant `lstart` for any pid with
# no file — so the fence always passes and a literal fixture pid (4242, 4747, 4848 …) is a request to
# SIGTERM/SIGKILL whatever the HOST happens to have there. That is silent destruction of an unrelated
# process on the runner, in the fixture of the code that exists to avoid exactly that. `sleep 300 &`
# gives a live pid the fence can genuinely verify, and `cleanup` reaps them.
LANE_PIDS=""
mk_lane() { # <name> [<ignored pid>] — the pid is kept in the signature so call sites read as before
  local pid
  "$REAL_SLEEP" 300 & pid=$!
  disown "$pid" 2>/dev/null || true   # keep bash from printing "Killed" for each one at cleanup
  LANE_PIDS="$LANE_PIDS $pid"
  printf '%s\n' "$1" >> "$T/tmux/sessions"
  printf '%s\n' "$pid" > "$T/tmux/panes/$1"
  : > "$T/o/logs/$1.log"
  touch -t 202001010000 "$T/o/logs/$1.log"
  printf '%s 1 00:00:10\n' "$pid" > "$T/ps/table"
}
killed() { grep -qx "=$1" "$T/tmux/killed" 2>/dev/null; }
result_has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

# ── 1) a WEDGED harness lane is reaped ───────────────────────────────────────────────────────────
say_case "a wedged lane is reaped (log silent, cpu unchanged, no human)"
reset_tmux; reset_ps; reset_state; rm -f "$T/writing"
mk_lane lane-42 4242
doc reap
[ "$RC" -eq 0 ] && ok "reap: rc=0" || bad "reap: rc=$RC — $OUT"
killed lane-42 && ok "reap: killed the exact session target (=lane-42)" || bad "reap: did NOT kill lane-42 — $OUT"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" in *"reaped lane-42"*) ok "reap: recorded 'reaped lane-42' in its state" ;; *) bad "reap: state does not record the reap — $(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" ;; esac
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")" = "0" ] && ok "reap: state last_rc=0" || bad "reap: state last_rc missing/wrong"

# ── 2) a lane whose CHILD IS STILL WRITING is NOT reaped ────────────────────────────────────────
# The documented false positive: the log is old at the first read, but the child writes during the
# sample window. A single-reading reaper kills this lane; the two-observation gate must not.
say_case "a lane whose child is still writing is NOT reaped"
reset_tmux; reset_ps; reset_state; : > "$T/writing"
mk_lane lane-42 4242
doc reap
killed lane-42 && bad "reap: killed a lane whose child wrote during the sample (the false positive)" \
               || ok "reap: left the writing lane alone"
result_has "still writing" && ok "reap: names the reason (child is still writing)" || bad "reap: reason not recorded — $OUT"
rm -f "$T/writing"

# ── 3) CPU advancing on the second observation is progress, not a wedge ─────────────────────────
say_case "a lane whose subtree gains CPU is NOT reaped"
reset_tmux; reset_ps; reset_state
mk_lane lane-43 4343
printf 'cpu\n' > "$T/ps/mode"
doc reap
killed lane-43 && bad "reap: killed a lane that gained CPU during the sample" || ok "reap: left the working lane alone"
result_has "still working" && ok "reap: names the reason (cpu advanced)" || bad "reap: cpu reason not recorded — $OUT"

# ── 4) an attached tmux client means a human is watching ────────────────────────────────────────
say_case "a session with an attached client is NOT reaped"
reset_tmux; reset_ps; reset_state
mk_lane lane-44 4444
printf 'client-1\n' > "$T/tmux/clients/lane-44"
doc reap
killed lane-44 && bad "reap: killed a session a human is attached to" || ok "reap: left the attached session alone"
result_has "attached" && ok "reap: names the reason (attached client)" || bad "reap: attached reason not recorded — $OUT"

# ── 5) ancestry reaching a human terminal ───────────────────────────────────────────────────────
# The pane pid's ancestor is Terminal.app. ppid 1 alone must never be read as "safe to kill".
say_case "a lane under a human terminal is NOT reaped"
reset_tmux; reset_ps; reset_state
mk_lane lane-45 4545
# The ancestry fixture is keyed on the pane pid the lane TERMINAL actually got (mk_lane spawns an
# owned process; a literal pid here would be the host's), so this arm keeps testing ancestry.
L45="$(cat "$T/tmux/panes/lane-45")"
printf '100 /Applications/Terminal.app/Contents/MacOS/Terminal\n' > "$T/ps/args.$L45"
printf '1 /sbin/launchd\n' > "$T/ps/args.100"
doc reap
killed lane-45 && bad "reap: killed a lane whose ancestry reaches a human terminal" || ok "reap: left the human's lane alone"
result_has "human terminal" && ok "reap: names the reason (human ancestry)" || bad "reap: human reason not recorded — $OUT"

# ── 6) a session outside the harness namespace is never considered ──────────────────────────────
say_case "a non-harness session is never a candidate"
reset_tmux; reset_ps; reset_state
printf 'my-own-shell\n' >> "$T/tmux/sessions"
printf '9999\n' > "$T/tmux/panes/my-own-shell"
: > "$T/o/logs/my-own-shell.log"; touch -t 202001010000 "$T/o/logs/my-own-shell.log"
doc reap
killed my-own-shell && bad "reap: considered a session outside the harness namespace" || ok "reap: ignored the non-harness session"
result_has "seen=0" && ok "reap: reports 0 harness sessions (the namespace filter ran)" || bad "reap: namespace filter not visible — $OUT"

# ── 7) no log = no progress signal = skip (never a guess) ───────────────────────────────────────
say_case "a session with no log is skipped, not reaped"
reset_tmux; reset_ps; reset_state
# ⛔ An OWNED pid even here: this lane is one gate away from the signal path (`no log` is checked
# before `pane_pid`), and a literal pid would be a request to SIGTERM/SIGKILL the host's process the
# moment the gate order changes. No log is what the arm is about — so simply do not create one.
"$REAL_SLEEP" 300 & L46=$!
disown "$L46" 2>/dev/null || true
LANE_PIDS="$LANE_PIDS $L46"
printf 'lane-46\n' >> "$T/tmux/sessions"
printf '%s\n' "$L46" > "$T/tmux/panes/lane-46"
printf '%s 1 00:00:10\n' "$L46" > "$T/ps/table"
doc reap
killed lane-46 && bad "reap: killed a session with no progress signal" || ok "reap: skipped the log-less session"
result_has "SKIP no log (no progress signal)" && ok "reap: names the reason (no log)" || bad "reap: log reason not recorded — $OUT"

# ── 7b) a process table this code cannot PARSE is cannot-verify, not "0 seconds" ─────────────
# A time column that does not match the ps shape parses to 0 via awk's `+0`, on BOTH observations.
# Two equal readings are then indistinguishable from a frozen subtree, so a failed READ would arrive
# at the killer as evidence of a wedge. The whole answer must be cannot-verify and the lane untouched.
say_case "an unparseable process table is cannot-verify, never 'no progress'"
reset_tmux; reset_ps; reset_state
mk_lane lane-47 0
# The garbage row must be the pane pid this lane ACTUALLY got, or the pre-fix code fails at
# "root not in the table" instead of at the parse, and the arm would be green for a code path it
# never reached (measured: it passed on the pre-fix script until this line was keyed on the pid).
L47="$(cat "$T/tmux/panes/lane-47")"
printf '%s 1 ??:??\n' "$L47" > "$T/ps/table"
doc reap
killed lane-47 && bad "reap: killed a lane on a process table it could not parse" \
              || ok "reap: left the lane alone when the table is unreadable"
[ "$RC" -eq 3 ] && ok "reap: a failed READ makes the pass rc=3 (cannot-verify is never a pass)" \
                || bad "reap: a failed read exited rc=$RC (want 3) — $OUT"
result_has "cannot read the process table" && ok "reap: names the reason (cannot-verify)" || bad "reap: cannot-verify reason not recorded — $OUT"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" in
  *"reaped lane-47"*) bad "reap: the state records a reap decided from an unreadable read" ;;
  *) ok "reap: the state does not record a reap on an unreadable read" ;;
esac

# ── 7c) a kill that did NOT take is reported, never counted as a reap ────────────────────
# `tmux kill-session` can refuse (a server hiccup, a permission, a session that will not die). If the
# reap is recorded anyway, the state and `status` claim a fix that did not happen and the lane stays
# wedged while reading as handled.
say_case "a refused kill is reported, not counted as a reap"
reset_tmux; reset_ps; reset_state
mk_lane lane-48 4848
LP48="$(cat "$T/tmux/panes/lane-48")"
: > "$T/tmux/refuse-kill"
doc reap
killed lane-48 && ok "reap: attempted the kill" || bad "reap: never attempted the kill — $OUT"
# The note the operator reads says "no signal sent"; with an OWNED pane pid that is now assertable.
# Without this assertion, moving the fence/TERM block above the verification would keep the arm green
# while the reaper signals a process it just declined to reap.
kill -0 "$LP48" 2>/dev/null && ok "reap: sent NO signal to the pane pid of a refused kill" \
                            || bad "reap: signalled the pane pid of a kill it did not verify"
[ "$RC" -eq 3 ] && ok "reap: an action that did not take makes the pass rc=3" \
                || bad "reap: a failed kill exited rc=$RC (want 3) — $OUT"
result_has "KILL FAILED" && ok "reap: reports the kill that did not take" || bad "reap: a refused kill is silent — $OUT"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" in
  *"reaped=0"*) ok "reap: the pass does not count a failed kill as a reap" ;;
  *) bad "reap: recorded a reap that did not happen — $(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" ;;
esac
rm -f "$T/tmux/refuse-kill"

# ── 7d) a DECREASING cpu reading is cannot-verify, not a wedge ─────────────────────────────────
# Cumulative CPU cannot shrink for a fixed process set, so a lower second reading proves the two
# readings are not comparable: a subtree member exited during the sample, or the bounded read came
# back truncated (the measured cause of slow reads on a loaded cell). Reading that fall as
# "unchanged" is the same false wedge the parse check removes, one branch over.
say_case "cpu that goes DOWN between the two readings is cannot-verify, not a wedge"
reset_tmux; reset_ps; reset_state
mk_lane lane-49 0
printf 'cpu-drop\n' > "$T/ps/mode"
doc reap
killed lane-49 && bad "reap: killed a lane whose second reading was LOWER (not comparable)" \
               || ok "reap: left the lane alone when the readings are not comparable"
result_has "not comparable" && ok "reap: names the reason (readings not comparable)" || bad "reap: reason not recorded — $OUT"
[ "$RC" -eq 3 ] && ok "reap: incomparable readings make the pass rc=3" || bad "reap: rc=$RC (want 3) — $OUT"

# ── 7e) a kill whose verification READ fails is not counted as a reap ──────────────────────────
# `tmux ls` fails both for "no server running" (which IS an empty list) and for a connection or tool
# failure (which proves nothing). Counting the second as "the session is gone" records a reap that
# did not happen — the same false PASS as counting an unverified `ps` read as no progress.
say_case "a kill that cannot be verified is reported, not counted as a reap"
reset_tmux; reset_ps; reset_state
mk_lane lane-50 0
LP50="$(cat "$T/tmux/panes/lane-50")"
: > "$T/tmux/fail-ls-after-kill"
doc reap
killed lane-50 && ok "reap: attempted the kill" || bad "reap: never attempted the kill — $OUT"
result_has "SKIP kill unverified" && ok "reap: reports the kill it could not verify" || bad "reap: an unverifiable kill is silent — $OUT"
result_has "cannot-verify" && ok "reap: says cannot-verify in the file's own vocabulary" || bad "reap: the abstention is not named — $OUT"
kill -0 "$LP50" 2>/dev/null && ok "reap: sent NO signal to the pane pid of an unverified kill" \
                            || bad "reap: signalled the pane pid of an unverified kill"
[ "$RC" -eq 3 ] && ok "reap: an unverifiable read makes the pass rc=3" || bad "reap: rc=$RC (want 3) — $OUT"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" in
  *"reaped=0"*) ok "reap: an unverifiable kill is not counted as a reap" ;;
  *) bad "reap: counted a reap it never verified — $(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" ;;
esac
rm -f "$T/tmux/fail-ls-after-kill" "$T/tmux/fail-ls"

# ── 7f) the OTHER non-zero `ls`: the server went away WITH the session, and that is a reap ──────
# `tmux ls` exits non-zero with "no server running" once the last session dies — an EMPTY list, not a
# failed read. If that leg were classified as cannot-verify, every sole-lane reap would silently
# become "kill unverified" and the reaper would never count a reap on a cell with one lane.
say_case "a kill that takes the last session with it IS counted (no server == empty list)"
reset_tmux; reset_ps; reset_state
mk_lane lane-51 0
: > "$T/tmux/no-server-after-kill"
doc reap
[ "$RC" -eq 0 ] && ok "reap: rc=0 when the session list is legitimately empty" || bad "reap: rc=$RC (want 0) — $OUT"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" in
  *"reaped=1"*) ok "reap: the kill IS counted when the server exits with the session" ;;
  *) bad "reap: a real reap was lost to the 'no server' leg — $(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" ;;
esac
# ⛔ The VERIFICATION READ must be observable, or this arm is green on both sides. Measured: on the
# pre-fix doctor every check here passed — because that doctor never verified a kill at all
# (`reaped=1`, rc=0 unconditionally), not because it classified this leg correctly. Counting the
# reads makes "the verification happened" an assertion instead of an assumption.
[ "$(wc -c < "$T/tmux/ls-calls" 2>/dev/null || echo 0)" -ge 2 ] \
  && ok "reap: the kill was VERIFIED by a second session read (the read was taken)" \
  || bad "reap: counted a reap without taking the verification read (ls reads=$(wc -c < "$T/tmux/ls-calls" 2>/dev/null || echo 0))"
rm -f "$T/tmux/no-server-after-kill" "$T/tmux/no-server"

# ── 7g) the ENTRY-level session read is itself cannot-verify ───────────────────────────────────
# `run_reap`'s first act is one session list, and its verdict decides the whole pass. Reading a
# failure there as "no harness session to judge" is the inert-reaper shape #1989 exists to remove:
# with `DOCTOR_TMUX_BIN=/nonexistent/tmux` the pre-fix doctor measured `seen=0 reaped=0 … to judge`,
# rc=0 — the reaper inert and its `status` row green. (The marker makes the same read fail with a
# list that is otherwise READABLE, so the arm cannot pass by having nothing to look at.)
say_case "an unreadable session list is cannot-verify, never 'nothing to judge'"
reset_tmux; reset_ps; reset_state
mk_lane lane-52 0
: > "$T/tmux/fail-ls"
doc reap
killed lane-52 && bad "reap: acted on a lane list it could not read" || ok "reap: no kill decided from an unreadable list"
[ "$RC" -eq 3 ] && ok "reap: an unreadable list makes the pass rc=3" || bad "reap: rc=$RC (want 3) — $OUT"
result_has "session list could not be read" && ok "reap: names what it could not read" || bad "reap: the abstention is unnamed — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")" = 3 ] \
  && ok "reap: the pass is RECORDED as rc=3 (status cannot show it green)" \
  || bad "reap: state records last_rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state") — $OUT"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" in
  *"seen=0"*) bad "reap: reports 'no lanes' for a list it could not read" ;;
  *) ok "reap: does not report the unreadable list as an empty one" ;;
esac
rm -f "$T/tmux/fail-ls"

# ── 7g-bis) the read's temp file: mktemp, and a mktemp that FAILS fails CLOSED ──────────
# The err file used to be `$TMPDIR/cell-doctor-tmux-ls.$$` — PREDICTABLE, so on a multi-user box a
# pre-created symlink at that path let the doctor truncate (and then grep) an arbitrary file it could
# write, and that same file carries the classification this read exists to get right. `bounded` two
# functions up already used mktemp for exactly this reason. With mktemp the path is unpredictable;
# and when mktemp itself cannot create the file the answer must be 3 (cannot-verify) — never a
# fall-through to an unbounded/unclassified read, which reads as "absent" and RESTARTS the controller.
#
# Driven through `doctor`, not `reap`: `run_reap` reads the session list through `harness_sessions`,
# whose `bounded` prefers `timeout(1)` when it exists and so never touches a temp file at all — an
# arm there would pass with the `$$` name restored. `session_present` (the →`tmux_session_list`
# caller at the controller check) is the path this fix actually owns, and its rc=3 branch is the one
# that decides whether the controller is restarted.
say_case "the session read's temp file: mktemp, and a mktemp failure is cannot-verify"
# The VULNERABILITY is the NAME, not the failure mode: a pre-created symlink at a PREDICTABLE path.
# So pin the mechanism that makes the name unpredictable — the read must ask mktemp for a random
# template. The old form wrote `$TMPDIR/cell-doctor-tmux-ls.<pid>` and never called mktemp, so THIS
# assertion is the one that reds if the predictable path comes back; the fail-closed arms below would
# both pass on the old code (a failed redirection happened to abort the read there too).
REAL_MKTEMP="$(command -v mktemp)"
cat > "$T/bin/mktemp" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/mktemp-calls"
exec "$REAL_MKTEMP" "\$@"
SH
chmod +x "$T/bin/mktemp"; : > "$T/mktemp-calls"
reset_tmux; reset_ps; reset_state; mkdir -p "$T/o/state/roles"; : > "$T/o/state/roles/.desired"
rm -f "$T/sup/calls" "$T/tmux/fail-ls"
OUT="$(TMPDIR="$T/no-such-tmpdir" bash "$DOCTOR" doctor 2>&1)"; RC=$?
[ -s "$T/sup/calls" ] && bad "doctor: restarted the controller from a read that could not be staged — $(cat "$T/sup/calls")" \
                      || ok "doctor: no restart decided from a read whose temp file could not be created"
[ "$RC" -eq 3 ] && ok "doctor: an unstakeable read makes the pass rc=3" || bad "doctor: rc=$RC (want 3) — $OUT"
result_has "controller cannot-verify" && ok "doctor: names the restart it refused" || bad "doctor: the refusal is unnamed — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state")" = 3 ] \
  && ok "doctor: the unstakeable read is RECORDED as rc=3 (status cannot show it green)" \
  || bad "doctor: state records last_rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state") — $OUT"
grep -q 'cell-doctor-tmux-ls\.XXXXXX' "$T/mktemp-calls" 2>/dev/null \
  && ok "doctor: the read asks mktemp for a RANDOM template (never a pid-derived path)" \
  || bad "doctor: the read used a PREDICTABLE temp path — mktemp calls seen: $(tr '\n' ' ' < "$T/mktemp-calls" 2>/dev/null)"
# And on a healthy TMPDIR the temp file is CLEANED UP — one leak per pass would litter a long-lived
# cell's TMPDIR, and every leaked file is a path an attacker could later symlink.
rm -rf "$T/tmpdir"; mkdir -p "$T/tmpdir"
reset_tmux; reset_ps; reset_state; mkdir -p "$T/o/state/roles"; : > "$T/o/state/roles/.desired"
rm -f "$T/sup/calls"; printf 'orch\n' >> "$T/tmux/sessions"   # a PRESENT controller: reads, never restarts
OUT="$(TMPDIR="$T/tmpdir" bash "$DOCTOR" doctor 2>&1)"; RC=$?
leftover=0
for _f in "$T/tmpdir"/cell-doctor-tmux-ls.*; do [ -e "$_f" ] && leftover=1; done
[ "$leftover" -eq 0 ] && ok "doctor: the session read's temp file is removed after the pass" \
                      || bad "doctor: left a temp file behind in TMPDIR — $(ls -A "$T/tmpdir" 2>/dev/null | tr '\n' ' ')"
# and the healthy pass really did take that read (the arm above must not pass by never reading)
[ "$RC" -ne 3 ] && ok "doctor: with a usable TMPDIR the pass completes (read taken, rc=$RC)" \
                || bad "doctor: the usable-TMPDIR control pass was itself cannot-verify — $OUT"
rm -f "$T/bin/mktemp" "$T/mktemp-calls"   # the shim is scoped to this arm

# ── 7h) a missing BINARY is still cannot-verify (the anchor, not the phrase, decides) ──────────
# The benign leg added for the fresh-box message matches on tmux's OWN wording at the start of the
# line. A bare `No such file or directory` would also match the SHELL's message for a tmux that does
# not exist — which proves nothing — so this arm pins the anchor.
say_case "an unreachable tmux BINARY is cannot-verify (not an empty namespace)"
reset_tmux; reset_ps; reset_state
mk_lane lane-53 0
OUT="$(DOCTOR_TMUX_BIN=/nonexistent/tmux bash "$DOCTOR" reap 2>&1)"; RC=$?
killed lane-53 && bad "reap: acted with no working tmux" || ok "reap: no kill without a working tmux"
[ "$RC" -eq 3 ] && ok "reap: a missing tmux binary is rc=3, not 'no server'" || bad "reap: rc=$RC (want 3) — $OUT"
result_has "session list could not be read" && ok "reap: names the unreadable list" || bad "reap: no cannot-verify reason — $OUT"

# ── 7i) a FRESH box: no server has EVER started, and tmux says so ──────────────────────────────
# tmux 3.4, measured: with the socket directory present and the socket file absent (a cell that has
# not started its first session yet) `tmux ls` exits 1 with `error connecting to … (No such file or
# directory)` — the same empty namespace as "no server running", from the other end of a server's
# life. Classified as cannot-verify it makes every role on a healthy new cell permanently red, and a
# cannot-verify row that never clears is a row operators learn to ignore.
# ⛔ OVER-BLOCK GUARD, not fix evidence: on the pre-fix doctor every leg below is green, because that
# doctor classified nothing at all — a failed `ls` simply looked like an empty list. The legs pin the
# NEW classification against over-correction (a fresh box must not be a permanent cannot-verify row),
# and 7g/7h pin the other direction (a refused connection, and a missing binary, stay rc=3).
say_case "a fresh box (no server ever started) is an EMPTY list, not cannot-verify"
reset_tmux; reset_ps; reset_state
: > "$T/tmux/no-socket"
doc reap
[ "$RC" -eq 0 ] && ok "reap: rc=0 on a box with no tmux server yet" || bad "reap: rc=$RC on a fresh box (want 0) — $OUT"
result_has "seen=0" && ok "reap: reports an empty namespace (seen=0, rc=0)" || bad "reap: the empty namespace is not reported — $OUT"
case "$OUT" in *"cannot-verify"*|*"CANNOT-VERIFY"*) bad "reap: a fresh box is reported as cannot-verify — $OUT" ;; *) ok "reap: a fresh box is not cannot-verify (that row would never clear)" ;; esac
: > "$T/o/state/roles/.desired"
rm -f "$T/sup/calls"; export DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup"
doc doctor
[ "$RC" -eq 0 ] && ok "doctor: is clean on a fresh box (it RESTARTS on absence, so this leg matters)" \
              || bad "doctor: rc=$RC on a fresh box — $OUT"
grep -qx 'start' "$T/sup/calls" 2>/dev/null \
  && ok "doctor: RESTARTS the controller on a fresh box (empty namespace = absent, not cannot-verify)" \
  || bad "doctor: did not restart on a fresh box — $(cat "$T/sup/calls" 2>/dev/null | tr '\n' ' ') — $OUT"
rm -f "$T/tmux/no-socket" "$T/o/state/roles/.desired"

# ── 7j) a client list that cannot be read is not "no human attached" ──────────────────────────
# The attached-client check is the LAST gate before the kill, so a failed read there is the one path
# where cannot-verify must be loudest. Measured pre-fix: with a healthy session list and an erroring
# `list-clients`, the reaper printed `lane-77 WOULD REAP (… no human)` and, without `--dry-run`,
# SIGTERMs a lane a human is watching.
say_case "an unreadable client list is cannot-verify, never 'no human attached'"
reset_tmux; reset_ps; reset_state
mk_lane lane-54 0
LP54="$(cat "$T/tmux/panes/lane-54")"
: > "$T/tmux/fail-clients"
doc reap
killed lane-54 && bad "reap: killed a lane whose attached-client read FAILED" || ok "reap: left the lane alone"
kill -0 "$LP54" 2>/dev/null && ok "reap: sent NO signal on an unreadable client list" \
                            || bad "reap: signalled a lane whose client list it could not read"
[ "$RC" -eq 3 ] && ok "reap: an unreadable client list makes the pass rc=3" || bad "reap: rc=$RC (want 3) — $OUT"
result_has "cannot read the attached clients" && ok "reap: names the read it could not take" || bad "reap: the abstention is unnamed — $OUT"
rm -f "$T/tmux/fail-clients"

# ── 7k) the ANCESTRY read is the gate immediately before the kill ───────────────────────────────
# `human_above` walked the pane pid's parents with one `ps -p` per hop and answered "no human above"
# for an EMPTY row — which is also what a failed or timed-out read returns. Measured pre-fix with an
# unreadable per-pid `ps`: the lane was killed and the pass recorded `reaped=1` rc=0.
say_case "an unreadable ancestry walk is cannot-verify, never 'no human above'"
reset_tmux; reset_ps; reset_state
mk_lane lane-55 0
LP55="$(cat "$T/tmux/panes/lane-55")"
: > "$T/ps/pfail-ppid"   # the ancestry read only — the lstart fence still reads
doc reap
killed lane-55 && bad "reap: killed a lane whose ancestry it could not read" || ok "reap: left the lane alone"
kill -0 "$LP55" 2>/dev/null && ok "reap: sent NO signal on an unreadable ancestry" \
                            || bad "reap: signalled a lane whose ancestry it could not read"
[ "$RC" -eq 3 ] && ok "reap: an unreadable ancestry makes the pass rc=3" || bad "reap: rc=$RC (want 3) — $OUT"
result_has "cannot read the process ancestry" && ok "reap: names the read it could not take" || bad "reap: the abstention is unnamed — $OUT"
rm -f "$T/ps/pfail-ppid"

# ── 7l) an unreadable PANE read is the last gate before the kill ───────────────────────────────
# The session list answers (the lane IS listed), but `list-panes` does not. Counting that as "no usable
# pane pid" made a failed read a benign skip on a clean pass; the question the pid answers is simply
# unanswered. The benign twin — a session that ENDED between the two reads — must stay a skip, or a
# lane exiting normally becomes a cannot-verify row.
say_case "an unreadable pane read is cannot-verify (and a session that ended is not)"
reset_tmux; reset_ps; reset_state
mk_lane lane-56 0
LP56="$(cat "$T/tmux/panes/lane-56")"
: > "$T/tmux/fail-panes"
doc reap
killed lane-56 && bad "reap: killed a lane whose pane pid it could not read" || ok "reap: left the lane alone"
kill -0 "$LP56" 2>/dev/null && ok "reap: sent NO signal on an unreadable pane read" \
                            || bad "reap: signalled a lane whose pane read failed"
[ "$RC" -eq 3 ] && ok "reap: an unreadable pane read makes the pass rc=3" || bad "reap: rc=$RC (want 3) — $OUT"
result_has "cannot read the pane pid" && ok "reap: names the read it could not take" || bad "reap: the abstention is unnamed — $OUT"
rm -f "$T/tmux/fail-panes"
# ⛔ The lane must be listed at the ENTRY read and gone at the one after: emptying the list first made
# the pass return at `seen=0` and never reach the branch this arm is named for (mutation-checked).
reset_tmux; reset_ps; reset_state
mk_lane lane-57 0
: > "$T/tmux/end-after-list"
doc reap
[ "$RC" -eq 0 ] && ok "reap: a session that ended between reads is NOT cannot-verify (the benign twin)" \
                || bad "reap: rc=$RC for a session that simply ended — $OUT"
result_has "no pane left" && ok "reap: names the benign reason (the session ended)" \
                          || bad "reap: the benign branch was not reached — $OUT"
result_has "cannot read the pane pid" && bad "reap: called a session that ended a failed read — $OUT" \
                                      || ok "reap: does not call the ended session a failed read"
rm -f "$T/tmux/end-after-list"

# ── 7m) the ancestry abstention's benign twin ────────────────────────────────────────────────────
# 7k proves a FAILED ancestry read abstains. The twin matters just as much: the walk gets an empty row
# when the pane's process simply EXITED, and a lane ending mid-pass must not turn the row `cannot-verify`
# (a cannot-verify row that fires on every normal lane exit is one operators learn to ignore). The
# session read is what tells them apart — it is gone, so there is nothing left to judge. Mutation-checked:
# with this branch forced false, 3 assertions red.
say_case "the ancestry abstention is not armed by a lane that simply ended"
reset_tmux; reset_ps; reset_state
mk_lane lane-58 0
LP58="$(cat "$T/tmux/panes/lane-58")"
: > "$T/tmux/end-after-clients"   # the client read answers; the session is gone at the ancestry gate
: > "$T/ps/pfail-ppid"            # …and the ancestry walk gets an empty row
doc reap
[ "$RC" -eq 0 ] && ok "reap: a lane whose process exited mid-pass is NOT cannot-verify" \
                || bad "reap: rc=$RC for a lane that simply ended — $OUT"
result_has "the pane process exited" && ok "reap: names the benign reason" \
                                     || bad "reap: the benign twin branch was not reached — $OUT"
case "$OUT" in *"cannot read the process ancestry"*) bad "reap: called a lane that ended a failed read — $OUT" ;; *) ok "reap: does not call the ended lane a failed read" ;; esac
kill -0 "$LP58" 2>/dev/null && ok "reap: sent NO signal to a lane it judged ended" \
                            || bad "reap: signalled a lane whose session read said gone"
rm -f "$T/tmux/end-after-clients" "$T/ps/pfail-ppid"

# ── 7n) a log whose mtime cannot be read is a FAILED read, not the "no log" exclusion ───────────
# The exclusion ("a lane that tees nothing cannot be judged") is for NO LOG. A log that exists but
# whose `stat` fails was counted as that same exclusion, so a box with a broken `stat` had a reaper
# that could never act and a pass that reported clean for ever.
say_case "an unreadable log mtime is cannot-verify, not the no-log exclusion"
reset_tmux; reset_ps; reset_state
mk_lane lane-59 0
: > "$T/stat/fail"
doc reap
[ "$RC" -eq 3 ] && ok "reap: an unreadable log mtime makes the pass rc=3" || bad "reap: rc=$RC (want 3) — $OUT"
result_has "cannot read the log mtime" && ok "reap: names the read it could not take" || bad "reap: the abstention is unnamed — $OUT"
result_has "no log" && bad "reap: counted an existing-but-unreadable log as 'no log' — $OUT" \
                     || ok "reap: does not report the no-log exclusion"
rm -f "$T/stat/fail"

# ── 8) MERGE: the rail is called only with a clean attestation at THIS head ─────────────────────
say_case "merge: the rail is gated on a clean attestation at the current head"
reset_tmux; reset_ps; reset_state
mkdir -p "$T/home/.pi/agent/reviews" "$T/gh"
HEAD_A="aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
HEAD_B="bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"
ATT="$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
printf '[{"number":42,"head":{"sha":"%s"},"draft":false}]\n' "$HEAD_A" > "$T/gh/prs.json"
rm -f "$T/rail/calls" "$T/rail/rc"
export DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail"

doc merge
[ -s "$T/rail/calls" ] && bad "merge: called the rail with NO attestation" || ok "merge: no attestation -> the rail was NOT called"
result_has "candidates=1" && ok "merge: counted the PR it looked at" || bad "merge: did not count candidates — $OUT"

# A stale attestation (a DIFFERENT head) is not an attestation: a rebase must invalidate it.
printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_B" > "$ATT"
doc merge
[ -s "$T/rail/calls" ] && bad "merge: called the rail on an attestation for ANOTHER head" || ok "merge: a stale attestation does not authorise the rail"
# ⛔ …and it is a BENIGN answer: "not reviewed at THIS head" is data, not a failed read. Mutation-checked:
# turning its sentinel into an error exit makes every un-attested PR a permanent cannot-verify row
# (`attempted=0` for ever) and reds the three assertions below.
[ "$RC" -eq 0 ] && ok "merge: another head's record is a clean pass, not cannot-verify" \
               || bad "merge: rc=$RC on a record for another head (want 0) — $OUT"
case "$OUT" in *"cannot-verify"*|*"CANNOT-VERIFY"*) bad "merge: called a benign 'not reviewed here' cannot-verify — $OUT" ;; *) ok "merge: does not call it cannot-verify" ;; esac
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
  *"nothing to land"*) ok "merge: records what it actually did (nothing to land)" ;;
  *) bad "merge: the record is unnamed — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
esac

# The right head, a clean verdict -> the rail is called, once.
printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_A" > "$ATT"
printf '1\n' > "$T/rail/rc"
doc merge
[ "$(awk 'END{print NR}' "$T/rail/calls" 2>/dev/null)" = "1" ] && ok "merge: called the rail exactly once for the attested head" \
  || bad "merge: rail call count is not 1 — $(cat "$T/rail/calls" 2>/dev/null)"
grep -qE '^42 ' "$T/rail/calls" 2>/dev/null && grep -q -- "--repo daniel-ospina/agent-infra" "$T/rail/calls" 2>/dev/null \
  && ok "merge: the rail argv carries the PR and the resolved repo" || bad "merge: rail argv wrong — $(cat "$T/rail/calls" 2>/dev/null)"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in *"REFUSED #42"*) ok "merge: a refusal is recorded (not swallowed)" ;; *) bad "merge: refusal not recorded — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;; esac
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/merge.state")" = "0" ] && ok "merge: the PASS rc stays 0 (the refusal is data, not a failed read)" \
  || bad "merge: pass rc wrong"

# Same head again: a refusal must not be retried blind.
doc merge
[ "$(awk 'END{print NR}' "$T/rail/calls" 2>/dev/null)" = "1" ] && ok "merge: a refused head is not retried inside the cooldown" \
  || bad "merge: retried a refused head blind"

# A push moves the head -> the new head is eligible again.
printf '[{"number":42,"head":{"sha":"%s"},"draft":false}]\n' "$HEAD_B" > "$T/gh/prs.json"
printf '{"head_sha":"%s","verdict":"clean-micro"}\n' "$HEAD_B" > "$ATT"
printf '0\n' > "$T/rail/rc"
doc merge
[ "$(awk 'END{print NR}' "$T/rail/calls" 2>/dev/null)" = "2" ] && ok "merge: a NEW head at the same PR is eligible again" \
  || bad "merge: a pushed head was permanently suppressed"

# ── 9) MERGE: an unreadable queue is CANNOT-VERIFY, never 'nothing to land' ─────────────────────
say_case "merge: an unreadable open-PR read is rc=3, not an empty queue"
reset_state
printf '5\n' > "$T/gh/rc"
doc merge
[ "$RC" -eq 3 ] && ok "merge: rc=3 when the queue cannot be read" || bad "merge: rc=$RC (want 3) — $OUT"
result_has "CANNOT-VERIFY" && ok "merge: says cannot-verify" || bad "merge: no cannot-verify reason — $OUT"
rm -f "$T/gh/rc"

# ⛔ A review record that is PRESENT but unreadable is cannot-verify, not "no attestation": it decides
# whether the rail is called, so answering 1 leaves a reviewed PR permanently unlanded while `status`
# shows merge green. Measured pre-fix with a truncated record: `candidates=1 attempted=0 landed=0
# skipped=1 — nothing to land`, rc=0.
say_case "merge: an unreadable review record is cannot-verify, not 'nothing to land'"
reset_tmux; reset_ps; reset_state
rm -f "$T/gh/rc" "$T/rail/calls"
printf '[{"number":77,"head":{"sha":"%s"},"draft":false}]\n' "$HEAD_B" > "$T/gh/prs.json"
mkdir -p "$T/home/.pi/agent/reviews"
printf '{"head_sha": "%s", "verdict": "cle\n' "$HEAD_B" > "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-77.json"
doc merge
[ -s "$T/rail/calls" ] && bad "merge: called the rail on an unreadable attestation" \
  || ok "merge: the rail was NOT called on a record it could not read"
[ "$RC" -eq 3 ] && ok "merge: an unreadable attestation makes the pass rc=3" || bad "merge: rc=$RC (want 3) — $OUT"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
  *"cannot-verify #"*) ok "merge: the RECORD names it (status cannot show this pass green)" ;;
  *) bad "merge: the record does not name the unreadable attestation — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
esac
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
  *"nothing to land"*) bad "merge: reports 'nothing to land' over a record it could not read" ;;
  *) ok "merge: does not report an empty queue" ;;
esac
printf 'null\n' > "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-77.json"
rm -f "$T/rail/calls"
doc merge
[ "$RC" -eq 3 ] && ok "merge: a record that PARSES but is not an object is cannot-verify too" \
                || bad "merge: rc=$RC on a \`null\` record (want 3) — $OUT"
[ -s "$T/rail/calls" ] && bad "merge: called the rail on a null record" || ok "merge: the rail was not called"
rm -f "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-77.json" "$T/gh/prs.json"

# ⛔ The rail killed at its own bound (124) may or may not have merged. Recording it as "REFUSED" on a
# clean pass asserted an outcome nobody knows, and `attempt_record` then suppresses that head.
say_case "merge: a rail that did not answer is cannot-verify, not a refusal"
reset_tmux; reset_ps; reset_state; rm -f "$T/rail/calls"
printf '[{"number":42,"head":{"sha":"%s"},"draft":false}]\n' "$HEAD_B" > "$T/gh/prs.json"
printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_B" > "$ATT"
printf '124\n' > "$T/rail/rc"
doc merge
[ "$RC" -eq 3 ] && ok "merge: rc=124 from the rail makes the pass rc=3" || bad "merge: rc=$RC (want 3) — $OUT"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
  *"the rail did not answer"*) ok "merge: the record names the unknown outcome" ;;
  *) bad "merge: recorded $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
esac
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
  *REFUSED*) bad "merge: recorded a bound-killed rail as a REFUSAL (an outcome it cannot know)" ;;
  *"cannot-verify #"*) ok "merge: records the bound-killed rail as cannot-verify, not a refusal" ;;
  *) bad "merge: the bound-killed rail is neither refused nor cannot-verify — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
esac
rm -f "$T/rail/rc"

# ⛔ THE CLASSIFICATION IS A PREDICATE, NOT A LIST OF WHAT SOMEBODY HAS SEEN. Every rc that is not
# named takes the `*)` arm, which records the rail's REFUSAL — DATA on a clean pass, which
# `attempt_record` then uses to suppress a head that may well have merged. So the arms below are chosen
# to pin the RANGE, not the arithmetic of one prior incident:
#   124 = timeout(1) killed the rail at its own bound (its own code, BELOW 128);
#   125 = timeout(1) itself failed, so the rail never ran at all;
#   126/127 = the rail could not be executed — "cannot execute" / "not found" (both BELOW 128);
#   129 = SIGHUP,  130 = SIGINT,  137 = SIGKILL,  139 = SIGSEGV,  143 = SIGTERM — every one of them
#         128+N, i.e. a SIGNAL DEATH. 137 is the `-k` KILL that ends a rail blocked on a foreground
#         `gh`/`git` (this doctor's own comment says the KILL is what ends it; measured:
#         `timeout -k 1 1 bash -c 'trap "" TERM; sleep 10'` returns 137); 143 is the `bounded` fallback
#         returning `wait`'s status for a child it TERMed itself; 129 is what a rail's foreground child
#         gets when its tmux session dies (measured: `timeout -k 1 5 bash -c 'kill -HUP $$; sleep 5'`).
# An enumeration of 124|126|127|137|143|125 pinned only the six rcs a previous review had thought of;
# 129/130/139 were still refusals, which is the fail-open the predicate exists to close.
say_case "merge: EVERY rc that is not the rail's own answer (124/125/126/127/129/130/137/139/143) is cannot-verify, not a refusal"
for _rrc in 124 125 126 127 129 130 137 139 143; do
  reset_tmux; reset_ps; reset_state; rm -f "$T/rail/calls"
  printf '[{"number":42,"head":{"sha":"%s"},"draft":false}]\n' "$HEAD_B" > "$T/gh/prs.json"
  printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_B" > "$ATT"
  printf '%s\n' "$_rrc" > "$T/rail/rc"
  doc merge
  [ "$RC" -eq 3 ] && ok "merge: rc=$_rrc from the rail makes the pass rc=3" \
                  || bad "merge: rc=$_rrc gave pass rc=$RC (want 3) — $OUT"
  case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
    *REFUSED*) bad "merge: rc=$_rrc was recorded as the rail's REFUSAL (an outcome it cannot know) — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
    *"cannot-verify #"*) ok "merge: rc=$_rrc is recorded as cannot-verify, not a refusal" ;;
    *) bad "merge: rc=$_rrc is neither refused nor cannot-verify — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
  esac
done
rm -f "$T/rail/rc"

# ── 10) DOCTOR: restart only a STARTED cell, and never kill a stale-but-present controller ──────
say_case "doctor: controller supervision (restart when gone; report, never kill, when stale)"
reset_tmux; reset_ps; reset_state
rm -f "$T/sup/calls"; export DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup"
mkdir -p "$T/o/state/roles"; : > "$T/o/state/roles/.desired"
doc doctor
grep -q 'start' "$T/sup/calls" 2>/dev/null && ok "doctor: a started cell with no controller session restarts it" \
  || bad "doctor: did NOT restart the missing controller — $OUT"

# Present but stale: report, do not start (a live-but-slow controller is a P0 kill decision).
printf 'orch\n' >> "$T/tmux/sessions"
printf '1111\n' > "$T/tmux/panes/orch"
printf '%s\n' "$(( $(date +%s) - 9999 ))" > "$T/o/heartbeat"
rm -f "$T/sup/calls"
doc doctor
[ -s "$T/sup/calls" ] && bad "doctor: started a second controller while one is present" \
  || ok "doctor: did not start a controller that is present"
result_has "CONTROLLER STALE" && ok "doctor: reports the stale controller" || bad "doctor: stale controller not reported — $OUT"

# Not started: nothing is supervised (and a stop must stay stopped).
: > "$T/tmux/sessions"; rm -f "$T/o/state/roles/.desired" "$T/sup/calls"
doc doctor
[ -s "$T/sup/calls" ] && bad "doctor: restarted a controller on a cell that was NOT started" \
  || ok "doctor: a stopped cell is not restarted"

# ⛔ A READ THAT FAILED IS NOT EVIDENCE OF ABSENCE, and this is the branch where that matters most:
# it RESTARTS the controller. `has-session` answers rc=1 for "no such session" and for every
# client/server error alike, so a blind read would restart a live cell's controller and report
# `controller RESTARTED` from a read that proved nothing. Measured on the pre-fix doctor, same
# fixture: `sup start` invoked, `last_rc=0`.
reset_tmux; reset_ps; reset_state; mkdir -p "$T/o/state/roles"; : > "$T/o/state/roles/.desired"
rm -f "$T/sup/calls"; : > "$T/tmux/fail-ls"
doc doctor
[ -s "$T/sup/calls" ] && bad "doctor: restarted the controller from a read that FAILED — $(cat "$T/sup/calls")" \
  || ok "doctor: an unreadable session list never restarts the controller"
[ "$RC" -eq 3 ] && ok "doctor: cannot-verify makes the pass rc=3" || bad "doctor: rc=$RC (want 3) — $OUT"
result_has "controller cannot-verify" && ok "doctor: names the restart it refused" || bad "doctor: the refusal is unnamed — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state")" = 3 ] \
  && ok "doctor: the failed read is RECORDED (a green row over it is the bug)" \
  || bad "doctor: state last_rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state") — $OUT"
rm -f "$T/tmux/fail-ls"

# ⛔ The controller's name is a NAME, not a pattern. `$SESSION` is unvalidated env, so both halves of
# a `grep -qx` on it are wrong: an ERE metacharacter makes grep exit 2 ("I could not answer"), which a
# caller reading only 0/3 takes as ABSENT and restarts; and an unescaped `.` matches a DIFFERENT live
# session, so the doctor reports RUNNING for a controller that does not exist.
say_case "the controller's name is matched LITERALLY"
reset_tmux; reset_ps; reset_state; mkdir -p "$T/o/state/roles"; : > "$T/o/state/roles/.desired"
printf 'orch[\n' >> "$T/tmux/sessions"
rm -f "$T/sup/calls" "$T/o/heartbeat"
OUT="$(SESSION='orch[' bash "$DOCTOR" doctor 2>&1)"; RC=$?
[ -s "$T/sup/calls" ] && bad "doctor: restarted from a name it could not match (grep rc=2 read as absent)" \
  || ok "doctor: a literal name carrying an ERE metacharacter is matched, not 'absent'"
[ "$RC" -eq 0 ] && result_has "controller RUNNING" \
  && ok "doctor: reports the present controller" || bad "doctor: rc=$RC — $OUT"
: > "$T/tmux/sessions"; printf 'orchX2\n' >> "$T/tmux/sessions"; rm -f "$T/sup/calls"
OUT="$(SESSION='orch.2' bash "$DOCTOR" doctor 2>&1)"; RC=$?
grep -q 'start' "$T/sup/calls" 2>/dev/null \
  && ok "doctor: 'orch.2' does not match a live 'orchX2' (a pattern is not a name)" \
  || bad "doctor: an unescaped '.' matched a different session and suppressed the restart — $OUT"
rm -f "$T/o/state/roles/.desired"

# ⛔ An ACTION the pass took that did not take is not a clean pass — the rule the reap applies to
# `kill-session`, applied to the restart. Measured pre-fix: `controller restart FAILED (supervisor
# start rc=1)` printed, while the pass recorded `last_rc=0` and `status` showed a green doctor row.
say_case "doctor: a restart that FAILED is recorded as such (not a clean pass)"
reset_tmux; reset_ps; reset_state; mkdir -p "$T/o/state/roles"; : > "$T/o/state/roles/.desired"
rm -f "$T/sup/calls"; printf '1\n' > "$T/sup/rc"
doc doctor
# ⛔ A FAILED ACTION and an UNREADABLE READ are different verdicts, and the merged implementation keeps
# that distinction: `supervisor start` RAN and refused, so the pass is a FAILURE (rc=1); a read it could
# not take is CANNOT-VERIFY (rc=3). What this arm pins is that a failed restart is NOT a clean pass
# either way — the pre-fix defect recorded rc=0 beside its own "restart FAILED" line.
[ "$RC" -ne 0 ] && ok "doctor: a failed restart is NOT a clean pass (rc=$RC)" || bad "doctor: rc=$RC on a failed restart (want non-zero) — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state")" != 0 ] \
  && ok "doctor: the failed restart is RECORDED (status cannot show it green)" \
  || bad "doctor: state last_rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state") — $OUT"
result_has "restart FAILED" && ok "doctor: names the failure" || bad "doctor: the failure is unnamed — $OUT"
rm -f "$T/sup/rc"
OUT="$(DOCTOR_SUPERVISOR=/nonexistent bash "$DOCTOR" doctor 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "doctor: no supervisor path -> cannot-verify (rc=3), never a clean pass" \
                || bad "doctor: rc=$RC with no supervisor (want 3) — $OUT"
rm -f "$T/o/state/roles/.desired"

# ── 11) STATUS: configured vs ran, and a started cell with no passes FAILS ──────────────────────
say_case "status: 'never ran' fails a started cell; a real pass clears it"
reset_state; : > "$T/o/state/roles/.desired"
doc status
[ "$RC" -ne 0 ] && ok "status: non-zero while every role NEVER RAN" || bad "status: rc=0 with no roles ever run"
result_has "NEVER RAN" && ok "status: names the roles that never ran" || bad "status: never-ran not named — $OUT"

# A loop that JUST started has not passed yet — its first doctor pass samples each lane, and
# `start && status` must not call that cell dead. The grace is bounded: an OLD loop that still has
# no pass fails, and a cell with no loop-age record (fail-closed) fails immediately.
"$REAL_SLEEP" 60 & GRACE_PID=$!
# ⛔ The shipped `loop_state` verifies the RECORDED IDENTITY as well as the pid (a recycled pid after
# a tmux restart, an OOM kill or a crash must not read as a live loop — #1178), so a fixture that
# writes only `loop.pid` is not "a live loop" to the shipped code: it is a dead one. This writes both
# halves in the shipped format: `pid|<identity>`, where the identity is `/proc` start time where the
# kernel offers one and `lstart` otherwise.
# ⛔ THE FIXTURE WRITES THE TRANSCRIPT THE REAL LOOP WRITES (P1, fresh review of #2335). The sibling
# suite got this fix; this one did not, so its "freshly started loop" arm wrote `loop.started = now`
# while `$T/o/logs/doctor.log` still carried the PREVIOUS arm's mtime — and whenever that write fell
# in an earlier second, `loop_transcript_fresh` vetoed (`m < st`) and the arm went UNKNOWN. Measured:
# 1 natural hit in 6 runs, 100% with a 2 s gap. Call it AFTER writing loop.started.
loop_transcript() { # <pid>
  mkdir -p "$T/o/logs"
  printf '%s  loop started pid=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$T/o/logs/doctor.log"
}
write_loop_alive() { # <pid>
  printf '%s\n' "$1" > "$T/o/state/roles/loop.pid"
  local ident
  ident="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}')"
  case "${ident:-}" in
    ''|*[!0-9]*) ident="$(ps -p "$1" -o lstart= 2>/dev/null)" ;;
    *) ident="proc:$ident" ;;
  esac
  printf '%s|%s\n' "$1" "$ident" > "$T/o/state/roles/loop.ident"
}

write_loop_alive "$GRACE_PID"
printf '%s\n' "$(date +%s)" > "$T/o/state/roles/loop.started"
loop_transcript "$GRACE_PID"
doc status
kill "$GRACE_PID" 2>/dev/null || true
[ "$RC" -eq 0 ] && result_has "WAITING" \
  && ok "status: a freshly started loop WAITS instead of failing its roles" \
  || bad "status: a fresh loop failed its roles (rc=$RC) — $OUT"
"$REAL_SLEEP" 60 & GRACE_PID=$!
write_loop_alive "$GRACE_PID"
printf '%s\n' "$(( $(date +%s) - 100000 ))" > "$T/o/state/roles/loop.started"
doc status
kill "$GRACE_PID" 2>/dev/null || true
[ "$RC" -ne 0 ] && result_has "NEVER RAN" \
  && ok "status: past the grace window, a role that never passed FAILS" \
  || bad "status: an old loop with no passes did not fail (rc=$RC) — $OUT"
rm -f "$T/o/state/roles/loop.started" "$T/o/state/roles/loop.pid" "$T/o/state/roles/loop.ident"

# A live loop pid + one recent pass per role = healthy.
"$REAL_SLEEP" 60 & LOOP_PID=$!
write_loop_alive "$LOOP_PID"
reset_tmux; reset_ps
printf '[]\n' > "$T/gh/prs.json"
doc reap;   bash "$DOCTOR" reap >/dev/null 2>&1
bash "$DOCTOR" merge >/dev/null 2>&1
bash "$DOCTOR" hygiene >/dev/null 2>&1
rm -f "$T/tmux/sessions"; : > "$T/tmux/sessions"; reset_ps
printf '[]\n' > "$T/gh/prs.json"
doc doctor
doc status
[ "$RC" -eq 0 ] && ok "status: rc=0 once the loop is live and every role has passed" || bad "status: rc=$RC after passes — $OUT"
result_has "RUNNING" && ok "status: reports the roles as RUNNING" || bad "status: no RUNNING row — $OUT"
case "$OUT" in *"last pass"*) ok "status: prints a LAST PASS time per role" ;; *) bad "status: no last-pass time — $OUT" ;; esac

# ⛔ The ROW-level verdict: a role whose last pass recorded cannot-verify is not a healthy cell. Printing
# `rc=3` in prose and exiting 0 is the same row in words — a monitoring probe reads the status, not the
# text — and the role rows are this change's core feature, so the rule must hold there too.
say_case "status: a role whose last pass recorded cannot-verify FAILS the cell"
"$REAL_SLEEP" 60 & VLOOP=$!
write_loop_alive "$VLOOP"
: > "$T/o/state/roles/.desired"
now="$(date +%s)"
for r in reap doctor merge hygiene; do
  rc_v=0; res_v="clean pass"
  [ "$r" = hygiene ] && { rc_v=3; res_v="caches-sweep FAILED rc=1"; }
  printf 'last_rc=%s\nlast_pass_epoch=%s\nlast_result=%s\n' "$rc_v" "$now" "$res_v" \
    > "$T/o/state/roles/$r.state"
done
doc status
[ "$RC" -ne 0 ] && ok "status: a role that could not verify fails the cell (rc=$RC)" \
                || bad "status: exited 0 with a hygiene row recording rc=3 — $OUT"
result_has "FAILED" && result_has "last pass rc=3" && ok "status: names the recorded verdict" || bad "status: the failing row is not the verdict — $OUT"
# …and an unreadable verdict is the same cannot-verify, not a pass. ⛔ The loop stays ALIVE for this
# sub-arm: killing it first made rc=1 come from the `loop: NOT RUNNING` row, so the arm passed whatever
# `role_row` did with the unreadable verdict (mutation-checked: it stayed green with the branch removed).
printf 'last_rc=\nlast_pass_epoch=%s\nlast_result=truncated\n' "$(date +%s)" > "$T/o/state/roles/hygiene.state"
doc status
[ "$RC" -ne 0 ] && ok "status: a record whose rc cannot be read is cannot-verify too" \
                || bad "status: exited 0 with an unreadable role verdict — $OUT"
result_has "FAILED" && result_has "no readable rc" && ok "status: the unreadable verdict is named (not the loop row)" \
                      || bad "status: the unreadable-verdict branch was not reached — $OUT"
# ⛔ …and a REHEARSAL does not move the verdict: `hygiene --dry-run` performs no action, so it cannot
# know the failure is fixed. Recording its rc=0 made `status` green over a cell that still cannot
# verify — for a whole role interval, on the verb an operator is told to run first.
say_case "hygiene --dry-run does not overwrite a cannot-verify verdict"
printf '3\n' > "$T/sup/rc"
doc hygiene
[ "$RC" -eq 3 ] && ok "hygiene: a FAILED sweep is rc=3 (the fixture for the dry-run arm)" || bad "hygiene: rc=$RC (want 3) — $OUT"
# ⛔ The POSITIVE half of the reachability control below: with no stop armed, a plain rehearsal DOES
# invoke the worktree reaper (as `--dry-run`), so "the reaper was never called" is a discriminator and
# not a property of the fixture. Asserted on the stub's own call log, never on a log line's wording.
rm -f "$T/wt/calls"
doc hygiene --dry-run
[ "$RC" -eq 0 ] && ok "hygiene --dry-run: rc=0 (it performed nothing, so nothing failed)" \
                || bad "hygiene --dry-run: rc=$RC — $OUT"
[ -s "$T/wt/calls" ] && ok "hygiene --dry-run: with no stop, the reaper IS invoked (the negative control below is meaningful)" \
                     || bad "hygiene --dry-run: no stop armed and the reaper was never invoked — the fixture, not the guard, is what suppresses it"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 3 ] \
  && ok "hygiene --dry-run: the previous cannot-verify verdict is KEPT (a rehearsal is not a verdict)" \
  || bad "hygiene --dry-run: overwrote the verdict with rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" in
  dry-run*) ok "hygiene --dry-run: the record says it was a rehearsal" ;;
  *) bad "hygiene --dry-run: the record does not say it was a rehearsal — $(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" ;;
esac
# ⛔ …and the OTHER direction, or the preservation is the same defect inverted: a rehearsal whose OWN
# read failed (an unreadable session list) is cannot-verify and must not be recorded over a clean
# previous verdict. Measured pre-fix: `last_rc=0`, dry-run rc=3, `status` rc=0 over a wedged box.
printf 'last_rc=0\nlast_pass_epoch=%s\nlast_result=clean pass\n' "$(date +%s)" > "$T/o/state/roles/hygiene.state"
: > "$T/tmux/fail-ls"
doc hygiene --dry-run
rm -f "$T/tmux/fail-ls"
[ "$RC" -eq 3 ] && ok "hygiene --dry-run: a rehearsal that hits cannot-verify is rc=3" || bad "hygiene --dry-run: rc=$RC with an unreadable session list (want 3) — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 3 ] \
  && ok "hygiene --dry-run: …and RECORDS it (the worse of the two verdicts wins)" \
  || bad "hygiene --dry-run: recorded rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state") over a rehearsal that could not verify"
# …and an UNKNOWN previous verdict is fail-closed, not "clean by default".
printf 'last_pass_epoch=%s\nlast_result=truncated\n' "$(date +%s)" > "$T/o/state/roles/hygiene.state"
doc hygiene --dry-run
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 3 ] \
  && ok "hygiene --dry-run: an unreadable previous verdict stays cannot-verify (fail-closed)" \
  || bad "hygiene --dry-run: recorded rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state") over an unreadable previous verdict"
# ⛔ …and the SAME defect had a second door: a stop that arrives MID-PASS writes the record and
# RETURNS before the merge above, so `hygiene --dry-run` interrupted by a stop recorded this pass's own
# rc — 0 by construction, because a rehearsal performs no action, so nothing it did can fail — over a
# stored cannot-verify. The operator's documented FIRST verb was clearing a failure it never probed.
say_case "hygiene --dry-run: a stop arriving MID-PASS cannot improve the stored verdict"
printf 'last_rc=3\nlast_pass_epoch=%s\nlast_result=caches-sweep FAILED rc=1\n' "$(date +%s)" \
  > "$T/o/state/roles/hygiene.state"
: > "$T/tmux/stop-midpass"
rm -f "$T/wt/calls"
doc hygiene --dry-run
# ⛔ Caught BEFORE the fixture is torn down, and both facts are behavioural: the stop GENERATION the
# tmux double bumped (the file `stop` writes first) is the evidence a stop arrived DURING this pass,
# and the reaper stub's own call log is the evidence the pass returned AT the branch that refuses it.
# Neither rests on the wording of a log line, so a future reword cannot red this with a misleading
# cause, and a branch that stopped being reached cannot leave the verdict arm passing vacuously.
STOPGEN_SEEN="$(cat "$T/o/state/roles/.stop-generation" 2>/dev/null)"
WT_CALLS_SEEN="$(cat "$T/wt/calls" 2>/dev/null)"
rm -f "$T/tmux/stop-midpass" "$T/o/state/roles/.stop-generation"
[ "$RC" -eq 0 ] && ok "hygiene --dry-run: a stopped rehearsal is rc=0 (it performed nothing that could fail)" \
             || bad "hygiene --dry-run: rc=$RC with a mid-pass stop (want 0) — $OUT"
[ "${STOPGEN_SEEN:-}" = 9 ] && ok "hygiene --dry-run: the stop genuinely arrived MID-PASS (the live generation moved)" \
                           || bad "hygiene --dry-run: no stop reached the pass (generation '${STOPGEN_SEEN:-<absent>}') — the arm proves nothing — $OUT"
[ -z "$WT_CALLS_SEEN" ] && ok "hygiene --dry-run: the pass returned AT the mid-pass branch — the worktree reaper was never invoked" \
                        || bad "hygiene --dry-run: the mid-pass branch was NOT reached — the reaper ran anyway: $WT_CALLS_SEEN"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 3 ] \
  && ok "hygiene --dry-run: the stored cannot-verify SURVIVES a stopped rehearsal" \
  || bad "hygiene --dry-run: a stopped rehearsal replaced rc=3 with rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state") — a rehearsal is not a verdict"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" in
  dry-run*) ok "hygiene --dry-run: the surviving row still says it was a rehearsal" ;;
  *) bad "hygiene --dry-run: the row does not say it was a rehearsal — $(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" ;;
esac
# …and the OTHER direction, so the merge is not tested on one side only: a stopped rehearsal whose OWN
# read could not be taken (an unreadable session list, i.e. cannot-verify already true) must record 3,
# never overwrite a previous CLEAN verdict with the rehearsal's own 0.
printf 'last_rc=0\nlast_pass_epoch=%s\nlast_result=clean pass\n' "$(date +%s)" \
  > "$T/o/state/roles/hygiene.state"
: > "$T/tmux/stop-midpass"; : > "$T/tmux/fail-ls"
doc hygiene --dry-run
rm -f "$T/tmux/stop-midpass" "$T/tmux/fail-ls" "$T/o/state/roles/.stop-generation"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 3 ] \
  && ok "hygiene --dry-run: …and a stopped rehearsal that itself could not verify records 3" \
  || bad "hygiene --dry-run: recorded rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state") over a stopped, unverifiable rehearsal"
rm -f "$T/sup/rc"
kill "$VLOOP" 2>/dev/null || true
rm -f "$T/o/state/roles/hygiene.state" "$T/o/state/roles/.desired" "$T/o/state/roles/loop.pid" "$T/o/state/roles/loop.ident"
kill -TERM "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""

# ⛔ ABSENT IS NOT UNREADABLE — the inverse over-correction, and the one an operator meets FIRST: on a
# FRESH cell `state/roles/hygiene.state` does not exist, and `state_get` answers the SAME empty string
# for "no record yet" as for "the record holds no readable rc". Folding both into 3 (right for the
# UNREADABLE case) recorded a failure that never happened: a clean rehearsal wrote `last_rc=3`, so
# `status` reported `hygiene FAILED last pass rc=3` over `dry-run (a rehearsal, no action taken) …
# MB->…MB`. Nothing was being preserved, because nothing existed yet.
say_case "a rehearsal on a FRESH cell (no prior record) does not invent a failure"
reset_tmux; reset_ps; reset_state; rm -f "$T/sup/rc" "$T/wt/rc"
[ ! -f "$T/o/state/roles/hygiene.state" ] && ok "fresh cell: no hygiene record exists (the fixture for this arm)" \
  || bad "fresh cell: a hygiene record already exists — the arm would prove nothing"
doc hygiene --dry-run
[ "$RC" -eq 0 ] && ok "fresh cell: hygiene --dry-run is rc=0 (a rehearsal performs nothing that can fail)" \
              || bad "fresh cell: hygiene --dry-run rc=$RC — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 0 ] \
  && ok "fresh cell: the first-ever rehearsal records rc=0 (absent is not unreadable)" \
  || bad "fresh cell: a CLEAN rehearsal recorded rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state") — a failure that never happened"
result_has "dry-run" && ok "fresh cell: the first record still says it was a rehearsal" \
                   || bad "fresh cell: the record does not say it was a rehearsal — $OUT"
# …and the consequence that mattered: `status` must not read that cell as failing a role.
: > "$T/o/state/roles/.desired"
"$REAL_SLEEP" 60 & FLOOP=$!
write_loop_alive "$FLOOP"
nowf="$(date +%s)"
for r in reap doctor merge; do
  printf 'last_rc=0\nlast_pass_epoch=%s\nlast_result=clean pass\n' "$nowf" > "$T/o/state/roles/$r.state"
done
doc status
kill "$FLOOP" 2>/dev/null || true
rm -f "$T/o/state/roles/.desired" "$T/o/state/roles/loop.pid" "$T/o/state/roles/loop.ident"
[ "$RC" -eq 0 ] && ok "fresh cell: …and status reads the cell as healthy afterwards" \
              || bad "fresh cell: status rc=$RC over a rehearsal that recorded a failure it never saw — $OUT"

# ⛔ THE SAME RULE ONE ROLE OVER. It was first written inside `run_hygiene` only, and `reap`, `merge` and
# `doctor` each ENDED on an unconditional write of their own rc — so a clean rehearsal cleared a stored
# `cannot-verify` (a refused kill, an unanswered rail, a failed controller restart) and `status` read
# that as health for a whole role interval. Measured pre-fix: `last_rc=3` -> `reap --dry-run` -> `0`.
say_case "a rehearsal keeps the stored verdict on reap, merge and doctor too"
seed_err() { printf 'last_rc=3\nlast_pass_epoch=%s\nlast_result=%s\n' "$(date +%s)" "$2" \
               > "$T/o/state/roles/$1.state"; }
# (a) reap — a real pass recorded a REFUSED kill.
reset_tmux; reset_ps; reset_state
seed_err reap "seen=1 reaped=0 skipped=1 failed=1 — lane-42 KILL FAILED (…) the action did not take"
doc reap --dry-run
[ "$RC" -eq 0 ] && ok "reap --dry-run: rc=0 (it killed nothing, so nothing it did could fail)" \
             || bad "reap --dry-run: rc=$RC — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")" = 3 ] \
  && ok "reap --dry-run: the stored KILL FAILED verdict SURVIVES the rehearsal" \
  || bad "reap --dry-run: recorded rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state") over a stored cannot-verify"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" in
  dry-run*) ok "reap --dry-run: the record says it was a rehearsal (not 'nothing was wedged')" ;;
  *) bad "reap --dry-run: the record does not say it was a rehearsal — $(sed -n 's/^last_result=//p' "$T/o/state/roles/reap.state")" ;;
esac
# (b) merge — a real pass recorded a rail that did not answer.
reset_tmux; reset_ps; reset_state
printf '[]\n' > "$T/gh/prs.json"
seed_err merge "cannot-verify #42 (the rail did not answer, rc=124); candidates=1 attempted=1 landed=0"
doc merge --dry-run
[ "$RC" -eq 0 ] && ok "merge --dry-run: rc=0 (no rail was called)" || bad "merge --dry-run: rc=$RC — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/merge.state")" = 3 ] \
  && ok "merge --dry-run: the stored 'the rail did not answer' verdict SURVIVES the rehearsal" \
  || bad "merge --dry-run: recorded rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/merge.state") over a stored cannot-verify"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
  dry-run*) ok "merge --dry-run: the record says it was a rehearsal (not 'nothing to land')" ;;
  *) bad "merge --dry-run: the record does not say it was a rehearsal — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
esac
# (c) doctor — a real pass recorded a FAILED controller restart; the rehearsal RESTARTS NOTHING.
reset_tmux; reset_ps; reset_state
: > "$T/o/state/roles/.desired"
# rc=1 deliberately: this is the role's FAILED restart, not a cannot-verify — a rehearsal keeps
# whichever stored verdict is worse, and both must survive it.
printf 'last_rc=1\nlast_pass_epoch=%s\nlast_result=%s\n' "$(date +%s)" \
  "reap: nothing to judge; controller restart FAILED rc=1" > "$T/o/state/roles/doctor.state"
doc doctor --dry-run
[ "$RC" -eq 0 ] && ok "doctor --dry-run: rc=0 (no restart was attempted)" || bad "doctor --dry-run: rc=$RC — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state")" = 1 ] \
  && ok "doctor --dry-run: the stored FAILED-restart verdict SURVIVES the rehearsal" \
  || bad "doctor --dry-run: recorded rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state") over a stored rc=1 — $OUT"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/doctor.state")" in
  dry-run*) ok "doctor --dry-run: the record says it was a rehearsal (not 'controller RESTARTED')" ;;
  *) bad "doctor --dry-run: the record does not say it was a rehearsal — $(sed -n 's/^last_result=//p' "$T/o/state/roles/doctor.state")" ;;
esac
rm -f "$T/o/state/roles/.desired"

# ── 12) HYGIENE: the package cache is pruned; worktrees are armed only under pressure ───────────
say_case "hygiene: uv cache prune runs; the worktree reaper is gated"
reset_state; rm -f "$T/uv/uv-calls" "$T/wt/calls"
doc hygiene
grep -q 'cache prune' "$T/uv/uv-calls" 2>/dev/null && ok "hygiene: ran 'uv cache prune' (not 'cache clean')" \
  || bad "hygiene: did not prune the package cache — $(cat "$T/uv/uv-calls" 2>/dev/null)"
grep -q -- '--dry-run' "$T/wt/calls" 2>/dev/null && ok "hygiene: a healthy disk leaves the worktree reaper in DRY-RUN" \
  || bad "hygiene: worktree reaper mode wrong — $(cat "$T/wt/calls" 2>/dev/null)"

# ⛔ The worktree-root sweep DELETES `.venv`/`node_modules` at every worktree root, so its live-worker
# guard is the one place where a failed read has a destructive consequence. Both halves are asserted:
# a live worker SKIPS the sweep, and an UNREADABLE session list skips it too. Measured pre-fix on the
# second: `$(harness_sessions | awk …)` made the read's status awk's, so rc=3 became `0` — "no worker
# is live" — and the pass invoked `prune --caches` and recorded `last_rc=0`.
say_case "hygiene: a destructive sweep is never armed by a read it could not take"
reset_tmux; reset_ps; reset_state; rm -f "$T/sup/calls" "$T/uv/uv-calls" "$T/wt/calls"
mk_lane lane-42 0
doc hygiene
[ -s "$T/sup/calls" ] && bad "hygiene: swept the worktree caches while a worker session was LIVE — $(cat "$T/sup/calls")" \
  || ok "hygiene: a live worker session suppresses the worktree cache sweep"
result_has "workers live" && ok "hygiene: says why the sweep was skipped" || bad "hygiene: no reason recorded — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 0 ] \
  && ok "hygiene: a live worker is a DECISION on a read that succeeded, so the pass is clean (rc=0)" \
  || bad "hygiene: rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state") on a healthy pass — $OUT"
rm -f "$T/sup/calls" "$T/uv/uv-calls" "$T/wt/calls"; : > "$T/tmux/fail-ls"
doc hygiene
[ -s "$T/sup/calls" ] && bad "hygiene: swept the worktree caches on a session list it could not READ — $(cat "$T/sup/calls")" \
  || ok "hygiene: an unreadable session list does not arm the destructive sweep"
[ "$RC" -eq 3 ] && ok "hygiene: cannot-verify makes the pass rc=3" || bad "hygiene: rc=$RC (want 3) — $OUT"
result_has "CANNOT-VERIFY" && ok "hygiene: names the read it could not take" || bad "hygiene: the abstention is unnamed — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 3 ] \
  && ok "hygiene: the pass is RECORDED as rc=3" || bad "hygiene: state last_rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state") — $OUT"
# ⛔ OVER-CORRECTION GUARD (green pre-fix): the pre-fix code never skipped the uv prune, so this pins
# the new early-return's SCOPE — it must not take the safe prune with it.
grep -q 'cache prune' "$T/uv/uv-calls" 2>/dev/null \
  && ok "hygiene: the SAFE prune still ran (unused entries only, safe beside live lanes)" \
  || bad "hygiene: a failed session read also suppressed the safe uv prune — $(cat "$T/uv/uv-calls" 2>/dev/null)"
# ⛔ …and the same scope for STEP 3. The worktree reaper needs no session list — its own contract
# preserves any worktree a live process holds — so an early return here disabled the ONE role that
# prevents a disk-full cell, on a box that was under pressure because it was wedged. Mutation-checked.
[ -s "$T/wt/calls" ] && ok "hygiene: the worktree reaper still RAN (a failed session read does not disable it)" \
  || bad "hygiene: a failed session read also suppressed the worktree reaper"
rm -f "$T/tmux/fail-ls"

# ⛔ The same rule for the role that `rm -rf`s caches: an action that FAILED, or that could not be
# attempted, must not be recorded as having happened. Measured pre-fix with a failing supervisor:
# `… worktree caches swept`, `last_rc=0` — the operator was told the disk was reclaimed.
say_case "hygiene: an action that failed or could not be attempted is not a clean pass"
reset_tmux; reset_ps; reset_state; rm -f "$T/sup/calls" "$T/uv/uv-calls" "$T/wt/calls"
printf '1\n' > "$T/sup/rc"
doc hygiene
result_has "FAILED" && ok "hygiene: names the sweep that failed" || bad "hygiene: a failed sweep is silent — $OUT"
[ "$RC" -eq 3 ] && ok "hygiene: a failed sweep makes the pass rc=3" || bad "hygiene: rc=$RC (want 3) — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 3 ] \
  && ok "hygiene: the failure is RECORDED" || bad "hygiene: state last_rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state") — $OUT"
rm -f "$T/sup/rc"
printf '3\n' > "$T/wt/rc"
doc hygiene
result_has "worktrees" && result_has "FAILED" && ok "hygiene: a reaper that aborted (exit 3) is reported, not summarised" \
  || bad "hygiene: the reaper's exit code is discarded — $OUT"
[ "$RC" -eq 3 ] && ok "hygiene: an aborted reaper makes the pass rc=3" || bad "hygiene: rc=$RC (want 3) — $OUT"
rm -f "$T/wt/rc"
OUT="$(DOCTOR_SUPERVISOR= bash "$DOCTOR" hygiene 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "supervisor not found" \
  && ok "hygiene: with no supervisor path the sweep is cannot-verify, not a silent success" \
  || bad "hygiene: rc=$RC with no supervisor — $OUT"
# The shipped reaper is NOT in the supervisor's required-worker list, so a healthy cell can lack it;
# "worktrees dry-run" was the clean-pass wording over a sweep that was never even attempted.
OUT="$(DOCTOR_WORKTREE_REAPER=/nonexistent/reaper bash "$DOCTOR" hygiene 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "worktree reaper (pi-reap-worktrees.sh) not found" \
  && ok "hygiene: a missing reaper is cannot-verify, not a clean pass" \
  || bad "hygiene: rc=$RC with no reaper (want 3) — $OUT"
# …and an unreadable `df` must not read as "the disk is fine" (which left the sweep in dry-run and the
# pass green forever on a box whose disk it cannot measure).
reset_state; rm -f "$T/uv/uv-calls" "$T/wt/calls"; mkdir -p "$T/df"; : > "$T/df/free-unknown"
OUT="$(DOCTOR_TEST_DF="$T/df" HYGIENE_WORKTREES=auto bash "$DOCTOR" hygiene 2>&1)"; RC=$?
rm -f "$T/df/free-unknown"
[ "$RC" -eq 3 ] && result_has "cannot read the free space" \
  && ok "hygiene: an unreadable free-space answer is cannot-verify (the sweep stays dry-run)" \
  || bad "hygiene: rc=$RC with an unreadable df (want 3) — $OUT"
grep -q -- '--dry-run' "$T/wt/calls" 2>/dev/null \
  && ok "hygiene: …and the reaper was NOT armed on it" \
  || bad "hygiene: the reaper mode on an unreadable df was $(cat "$T/wt/calls" 2>/dev/null | tr '\n' ' ')"

# ── 13) unknown arguments are refused (a typo must not arm the destructive verb) ───────────────
say_case "argument validation"
OUT="$(bash "$DOCTOR" reap --dryrun 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "a typo'd flag is refused (rc=2)" || bad "a typo'd flag was silently accepted (rc=$RC) — $OUT"
OUT="$(DOCTOR_INTERVAL=abc bash "$DOCTOR" status 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "a non-numeric interval is refused before any pass" || bad "a bad interval was accepted (rc=$RC) — $OUT"
OUT="$(bash "$DOCTOR" loop --dryrun 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "an argument to 'loop' is refused (a rehearsal typo is not a silent arm)" || bad "loop accepted an argument (rc=$RC) — $OUT"

say_case "the read budget: a pass that spends it does not act on what it reached"
reset_tmux; reset_ps; reset_state; rm -f "$T/writing"
mk_lane lane-47 4747
OUT="$(REAP_TIMEOUT=1 REAP_SAMPLE_S=2 bash "$DOCTOR" reap 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "CANNOT-VERIFY" && ! killed lane-47 \
  && ok "reap: budget spent mid-pass -> rc=3, cannot-verify, NO kill" \
  || bad "reap: budget exhausted but rc=$RC killed=$(killed lane-47 && echo yes || echo no) — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")" = 3 ] \
  && ok "reap: the partial pass is RECORDED as rc=3 (not a clean pass)" \
  || bad "reap: state does not record rc=3 — $(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")"

# The open-PR read is bounded too (a hung `gh` used to stall the merge role with its lock held), and a
# ZERO bound is refused at startup because `timeout 0` means NO timeout at all.
OUT="$(MERGE_READ_TIMEOUT=0 bash "$DOCTOR" merge 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && result_has "must be > 0" \
  && ok "startup: a zero MERGE_READ_TIMEOUT is refused (timeout 0 disables the bound)" \
  || bad "startup: accepted MERGE_READ_TIMEOUT=0 (rc=$RC) — $OUT"
# ⛔ The SAME `=0 disables the bound` hole sat in the two knobs the REAP's safety rests on. At
# REAP_SAMPLE_S=0 the two CPU observations are taken microseconds apart, so "CPU unchanged" is true
# of EVERY lane — including a LIVE one in a long model call (quiet log, flat CPU) — and that gate is
# what the header names as the thing separating a wedge from a long call. REAP_MIN_S=0 removes the
# age floor outright. Both were accepted, so both could kill the lane the reaper exists to spare.
for _z in REAP_SAMPLE_S REAP_MIN_S; do
  OUT="$(env "$_z=0" bash "$DOCTOR" reap 2>&1)"; RC=$?
  [ "$RC" -eq 2 ] && result_has "must be > 0" \
    && ok "startup: a zero $_z is refused (0 makes the bound it configures vacuous)" \
    || bad "startup: accepted $_z=0 (rc=$RC) — $OUT"
done
OUT="$(MERGE_READ_TIMEOUT=abc bash "$DOCTOR" merge 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "startup: a non-numeric MERGE_READ_TIMEOUT is refused" || bad "it was accepted (rc=$RC) — $OUT"
# The bound ITSELF: a hanging `gh` must end the pass as cannot-verify instead of holding the merge lock.
if command -v timeout >/dev/null 2>&1; then
  reset_tmux; reset_ps; reset_state
  printf '[]\n' > "$T/gh/prs.json"; : > "$T/gh/slow"
  M0=$(date +%s)
  OUT="$(MERGE_READ_TIMEOUT=1 bash "$DOCTOR" merge 2>&1)"; RC=$?
  M1=$(date +%s)
  rm -f "$T/gh/slow"
  [ "$RC" -eq 3 ] && ok "merge: a hung open-PR read is cannot-verify (rc=3), not a hang" \
                  || bad "merge: rc=$RC on a hung \`gh\` (want 3) — $OUT"
  [ "$((M1 - M0))" -lt 10 ] && ok "merge: the bound ended the read ($((M1 - M0))s, budget 1s)" \
                           || bad "merge: the read was not bounded ($((M1 - M0))s)"
  result_has "CANNOT-VERIFY" && ok "merge: names the read it could not take" || bad "merge: the abstention is unnamed — $OUT"
fi

say_case "the per-call read bound: a wedged tmux cannot hang the pass"
# A wedged tmux is exactly the condition the reap runs under (README §6.5.2). The bound is per CALL
# (`READ_CALL_TIMEOUT`), inside the whole-pass budget, and an unbounded read here hangs the pass with
# the role lock held — stopping `merge` and `hygiene` too, which is a worse outcome than the read.
if command -v timeout >/dev/null 2>&1; then
  reset_tmux; reset_ps; reset_state; rm -f "$T/writing"
  mk_lane lane-55 0
  : > "$T/tmux/slow-ls"
  B0=$(date +%s)
  OUT="$(READ_CALL_TIMEOUT=1 bash "$DOCTOR" reap 2>&1)"; RC=$?
  B1=$(date +%s)
  rm -f "$T/tmux/slow-ls"
  [ "$RC" -eq 3 ] && ok "reap: a hung read is cannot-verify (rc=3), not a hang" || bad "reap: rc=$RC on a hung read — $OUT"
  # ⛔ OVER-CORRECTION GUARD: green on the pre-fix script too (the bound and the `bounded` wrapping of
  # the list read already existed there). It pins the bound against removal, not the fix.
  [ $((B1 - B0)) -le 15 ] && ok "reap: returned in $((B1 - B0))s (the bound held; the read 'sleeps' 30s)" \
                         || bad "reap: took $((B1 - B0))s — the per-call bound did not hold"
  killed lane-55 && bad "reap: acted on a lane it never read" || ok "reap: no action from a read it could not complete"
else
  echo "  (skipped: no \`timeout\` in PATH — the fallback arm below pins the bound on this host)"
fi
# ⛔ …and the SAME bound WITHOUT `timeout(1)`. This is not a hypothetical: `bounded` carries a SHELL
# fallback (background + `sleep $s` watchdog + TERM/KILL) precisely because "its ABSENCE must not
# silently drop the bound", and `DOCTOR_TIMEOUT_BIN` is the documented seam that drives it. A
# conditional arm that simply SKIPPED on such a host left the bound untested exactly there — and its
# skip message said the bound "degrades to unbounded", which is the opposite of what the code does.
# ⛔ OVER-CORRECTION GUARD, like the arm above: green on the pre-fix doctor too. It pins the fallback
# against removal; it is not evidence of any fix in this PR.
reset_tmux; reset_ps; reset_state; rm -f "$T/writing"
mk_lane lane-56 0
: > "$T/tmux/slow-ls"
F0=$(date +%s)
OUT="$(DOCTOR_TIMEOUT_BIN=/nonexistent/tmux-timeout READ_CALL_TIMEOUT=1 bash "$DOCTOR" reap 2>&1)"; RC=$?
F1=$(date +%s)
rm -f "$T/tmux/slow-ls"
[ "$RC" -eq 3 ] && ok "reap: without timeout(1) a hung read is still cannot-verify (rc=3), not a hang" \
                || bad "reap: rc=$RC on a hung read with no timeout(1) — $OUT"
[ $((F1 - F0)) -le 15 ] && ok "reap: the SHELL fallback ended the read in $((F1 - F0))s (the read 'sleeps' 30s)" \
                      || bad "reap: took $((F1 - F0))s with no timeout(1) — the bound was silently dropped"
killed lane-56 && bad "reap: acted on a lane it never read (fallback path)" \
                || ok "reap: no action from a read the fallback could not complete"

say_case "the role lock: a second pass SKIPS rather than acting twice"
reset_tmux; reset_ps; reset_state; rm -f "$T/writing"
mk_lane lane-46 4646
"$REAL_SLEEP" 30 & HOLDER=$!
mkdir -p "$T/o/state/roles/.reap.lock"; printf '%s\n' "$HOLDER" > "$T/o/state/roles/.reap.lock/pid"
OUT="$(bash "$DOCTOR" reap 2>&1)"; RC=$?
kill "$HOLDER" 2>/dev/null || true
[ "$RC" -eq 0 ] && result_has "SKIP another reap pass is running" && ! killed lane-46 \
  && ok "reap: a held lock makes the second pass a no-op (no second sample, no kill)" \
  || bad "reap: the lock did not stop a second pass (rc=$RC killed=$(killed lane-46 && echo yes || echo no)) — $OUT"

# ── summary ─────────────────────────────────────────────────────────────────────────────────────
echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then echo "  ❌ $FAIL check(s) failed"; exit 1; fi
echo "  ✅ all checks passed"
