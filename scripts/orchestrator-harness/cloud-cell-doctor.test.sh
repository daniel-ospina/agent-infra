#!/usr/bin/env bash
# cloud-cell-doctor.test.sh — the regression contract for agent-infra#1989.
#
# The issue: a cloud cell ran exactly one loop (dispatch), nothing landed a green PR, nothing reaped
# a wedged lane, and `status` could not tell a dead role from an idle box. This suite drives the
# SHIPPED `cloud-cell-doctor.sh` (and the supervisor's role verbs/status) against stubs — the real
# tmux server, the real `ps` table and the real API are never touched — and asserts the behaviours
# the issue's validation names:
#
#   * a wedged harness session IS reaped (and the kill is recorded);
#   * a lane whose child is STILL WRITING is NOT reaped (the documented false positive);
#   * a lane with an attached client, or whose ancestry reaches a human terminal, is NOT reaped;
#   * a session outside the harness namespace is never even considered;
#   * the merge role calls the standard rail ONLY when a clean attestation exists for THIS head,
#     records a refusal with its reason, and does not retry that head blind;
#   * `status` distinguishes "loop configured" from "ran a pass", and FAILS a started cell whose
#     roles never ran;
#   * the doctor restarts a missing controller only when the cell is supposed to be running, and
#     never kills a stale-but-present one.
#
# Run: bash scripts/orchestrator-harness/cloud-cell-doctor.test.sh

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
    # A failing `tmux ls` is the difference between "nothing to reap" and "I could not look".
    if [ -f "$S/ls_rc" ]; then
      [ -f "$S/ls_msg" ] && cat "$S/ls_msg"
      exit "$(cat "$S/ls_rc")"
    fi
    if [ "${1:-}" = "-F" ]; then cat "$S/sessions" 2>/dev/null; exit 0; fi
    while IFS= read -r n; do [ -n "$n" ] && printf '%s: 1 windows (created now)\n' "$n"; done < "$S/sessions" 2>/dev/null
    exit 0 ;;
  has-session)
    n="$(arg -t "$@")"; n="${n#=}"
    [ -n "$n" ] && grep -qx -- "$n" "$S/sessions" 2>/dev/null && exit 0; exit 1 ;;
  list-panes)
    n="$(arg -t "$@")"; n="${n#=}"
    cat "$S/panes/$n" 2>/dev/null; exit 0 ;;
  list-clients)
    n="$(arg -t "$@")"; n="${n#=}"
    [ -f "$S/clients_rc" ] && { [ -f "$S/clients_msg" ] && cat "$S/clients_msg"; exit "$(cat "$S/clients_rc")"; }
    cat "$S/clients/$n" 2>/dev/null; exit 0 ;;
  kill-session)
    n="$(arg -t "$@")"
    printf '%s\n' "$n" >> "$S/killed"
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
  [ -f "$S/hang" ] && { "$REAL_SLEEP" 5; exit 0; }
  n=0; [ -f "$S/calls" ] && n="$(cat "$S/calls")"
  n=$((n + 1)); printf '%s\n' "$n" > "$S/calls"
  if [ -f "$S/mode" ] && [ "$(cat "$S/mode")" = "cpu" ] && [ "$n" -ge 2 ]; then
    awk '{print $1, $2, "00:00:17"}' "$S/table" 2>/dev/null
  else
    cat "$S/table" 2>/dev/null
  fi
  exit 0
fi
if [ "${1:-}" = "-p" ]; then
  pid="$2"; fmt="${4:-}"
  [ -f "$S/pfail.$pid" ] && exit 1
  [ -f "$S/phang.$pid" ] && { "$REAL_SLEEP" 5; exit 0; }
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
if [ "${1:-}" = "api" ]; then
  [ -f "$S/hang" ] && { "$REAL_SLEEP" 5; }
  rc="$(cat "$S/rc" 2>/dev/null)"; [ -n "$rc" ] && { cat "$S/prs.json" 2>/dev/null; exit "$rc"; }
  cat "$S/prs.json" 2>/dev/null; exit 0
fi
exit 0
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
# The rail's flake reproduction runs `git -C "$PWD"`; the cell doctor must invoke it FROM $REPO.
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >> "$S/calls"
[ -f "$S/sleep" ] && "$REAL_SLEEP" "$(cat "$S/sleep")"
# A TERM-DEFERRING rail: a shell waiting on a foreground child (the real hang shape) ignores TERM
# until that child returns. Only a KILL ends it.
[ -f "$S/defer" ] && "$REAL_SLEEP" 5
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

cat > "$T/bin/wt-reaper.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCTOR_TEST_WT:?}/calls"
exit 0
SH

chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# ── shared environment ──────────────────────────────────────────────────────────────────────────
export CELL_HOME="$T/home" O="$T/o" REPO="$T/repo" OR="daniel-ospina/agent-infra"
export SESSION="orch" DOCTOR_SESSION="cell-doctor"
export DOCTOR_TMUX_BIN="$T/bin/tmux" DOCTOR_PS_BIN="$T/bin/ps" DOCTOR_GH_BIN="$T/bin/gh"
export DOCTOR_SLEEP_BIN="$T/bin/sleep" REAL_SLEEP
export DOCTOR_TEST_TMUX="$T/tmux" DOCTOR_TEST_PS="$T/ps" DOCTOR_TEST_GH="$T/gh"
# The `uv` double records its calls here; without it the double fails (it is `:?`-guarded), and a
# fixture that forgot to pass it would read as "uv cache prune FAILED" — a truthy-looking false red.
export DOCTOR_TEST_UV="$T/uv"
export REAP_MIN_S=60 REAP_SAMPLE_S=2 DOCTOR_INTERVAL=1 MERGE_INTERVAL=1 HYGIENE_INTERVAL=1
export MERGE_RETRY_S=3600 CONTROLLER_STALE_S=60
mkdir -p "$T/gh" "$T/rail" "$T/sup" "$T/wt" "$T/uv"

doc() { # <role> [extra env assignments via env]
  OUT="$(bash "$DOCTOR" "$@" 2>&1)"; RC=$?
}
reset_tmux() { rm -f "$T/tmux/sessions" "$T/tmux/killed" "$T/tmux/new-session"; touch "$T/tmux/sessions"; }
reset_ps()   { rm -f "$T/ps/calls" "$T/ps/mode" "$T/ps/args."* "$T/ps/lstart."*; }
reset_state(){ rm -rf "$T/o/state"; mkdir -p "$T/o/state/roles"; }
mk_lane() { # <name> <pid> [<log mtime, `touch -t` form; default ancient>]
  printf '%s\n' "$1" >> "$T/tmux/sessions"
  printf '%s\n' "$2" > "$T/tmux/panes/$1"
  : > "$T/o/logs/$1.log"
  touch -t "${3:-202001010000}" "$T/o/logs/$1.log"
  printf '%s 1 00:00:10\n' "$2" > "$T/ps/table"
}
killed() { grep -qx "=$1" "$T/tmux/killed" 2>/dev/null; }
# The ps stub reports a fixed lstart for every pid, so this is the identity `loop_alive` must see.
# The identity the code will compute for a REAL pid: /proc starttime when the kernel offers it, else
# the ps stub's lstart (fake pids like 5050 have no /proc entry).
ident_of() {
  local id
  id="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}')"
  case "$id" in ''|*[!0-9]*) printf 'Mon Jan  1 00:00:00 2020' ;; *) printf 'proc:%s' "$id" ;; esac
}
loop_up() { # <pid>
  printf '%s\n' "$1" > "$T/o/state/roles/loop.pid"
  printf '%s|%s\n' "$1" "$(ident_of "$1")" > "$T/o/state/roles/loop.ident"
}
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

# ── 1b) a lane whose log advanced INSIDE the floor is NOT reaped ────────────────────────────────
# REAP_MIN_S is the whole reason a SCHEDULED reap pass is safe: a lane that spoke recently is between
# tool calls, not wedged. Without this the floor could be raised to 0 and every other case would still
# pass — the branch would be unguarded while the registry reports it pinned.
say_case "a lane whose log advanced inside REAP_MIN_S is NOT reaped"
reset_tmux; reset_ps; reset_state
# 5 s old, NOT 0: an age of 0 satisfies `age <= 0` as well, so a zero-age fixture would pass even
# with the floor deleted — the case has to sit BETWEEN the floor and "just now" to pin the branch.
mk_lane lane-47 4747 "$(date -d '-5 seconds' +%Y%m%d%H%M.%S)"
doc reap
killed lane-47 && bad "reap: killed a lane that logged a moment ago (the floor did not apply)" \
               || ok "reap: left the just-active lane alone"
result_has "under 60s" && ok "reap: names the floor it respected" || bad "reap: floor not named — $OUT"
# Its log is newer than every later case's fixture and the log-less case asserts the ABSENCE of one,
# so remove it rather than leave a shared name behind (the other cases re-create their own log).
rm -f "$T/o/logs/lane-47.log"

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
printf '100 /Applications/Terminal.app/Contents/MacOS/Terminal\n' > "$T/ps/args.4545"
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
printf 'lane-46\n' >> "$T/tmux/sessions"
printf '4646\n' > "$T/tmux/panes/lane-46"
printf '4646 1 00:00:10\n' > "$T/ps/table"
doc reap
killed lane-46 && bad "reap: killed a session with no progress signal" || ok "reap: skipped the log-less session"
# ⛔ "no log" and "a log whose mtime cannot be READ" are different facts and now have different
# branches: the first is the documented exclusion (a lane that tees nothing cannot be judged), the
# second is cannot-verify. The reason string therefore names the log itself, not "readable".
result_has "no log (no progress signal)" && ok "reap: names the reason (no log)" || bad "reap: log reason not recorded — $OUT"

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

# The right head, a clean verdict -> the rail is called, once.
printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_A" > "$ATT"
printf '1\n' > "$T/rail/rc"
doc merge
[ "$(awk 'END{print NR}' "$T/rail/calls" 2>/dev/null)" = "1" ] && ok "merge: called the rail exactly once for the attested head" \
  || bad "merge: rail call count is not 1 — $(cat "$T/rail/calls" 2>/dev/null)"
grep -qE 'argv=42 ' "$T/rail/calls" 2>/dev/null && grep -q -- "--repo daniel-ospina/agent-infra" "$T/rail/calls" 2>/dev/null \
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

# An UNREADABLE review store is not "no attestation": every candidate would be skipped and the pass
# would claim a clean `nothing to land` while reviewed PRs silently never land. It is rc=3, like every
# other unreadable read in this doctor.
say_case "merge: an unreadable/corrupt review store is CANNOT-VERIFY (not 'nothing to land')"
reset_state; rm -f "$T/rail/calls"
printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_A" > "$ATT"
chmod 000 "$ATT"
OUT="$(DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" bash "$DOCTOR" merge 2>&1)"; RC=$?
chmod 644 "$ATT"
[ "$RC" -eq 3 ] && [ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/merge.state")" = "3" ] \
  && ok "merge: an unreadable attestation file -> rc=3 (not a clean 'nothing to land')" \
  || bad "merge: an unreadable store produced rc=$RC — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")"
[ -s "$T/rail/calls" ] && bad "merge: called the rail while the store was unreadable" || ok "merge: the rail was NOT called on an unreadable store"
printf 'not json at all\n' > "$ATT"
OUT="$(DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" bash "$DOCTOR" merge 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "CANNOT-VERIFY" \
  && ok "merge: a CORRUPT attestation -> rc=3 (a parse failure is not a 'not clean' verdict)" \
  || bad "merge: a corrupt attestation produced rc=$RC — $OUT"
# A store that simply has no attestation for this PR is still an ordinary skip (rc=0): the distinction
# must not turn "unreviewed" into a fault.
rm -f "$ATT"
OUT="$(DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" bash "$DOCTOR" merge 2>&1)"; RC=$?
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
  *"nothing to land"*) ok "merge: NO attestation is still a clean skip (rc=0) — the new rule did not over-block" ;;
  *) bad "merge: an unreviewed PR produced rc=$RC — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
esac

# ── 9) MERGE: an unreadable queue is CANNOT-VERIFY, never 'nothing to land' ─────────────────────
say_case "merge: an unreadable open-PR read is rc=3, not an empty queue"
reset_state
printf '5\n' > "$T/gh/rc"
doc merge
[ "$RC" -eq 3 ] && ok "merge: rc=3 when the queue cannot be read" || bad "merge: rc=$RC (want 3) — $OUT"
result_has "CANNOT-VERIFY" && ok "merge: says cannot-verify" || bad "merge: no cannot-verify reason — $OUT"
rm -f "$T/gh/rc"

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
loop_up "$GRACE_PID"
printf '%s\n' "$(date +%s)" > "$T/o/state/roles/loop.started"
doc status
kill "$GRACE_PID" 2>/dev/null || true
[ "$RC" -eq 0 ] && result_has "WAITING" \
  && ok "status: a freshly started loop WAITS instead of failing its roles" \
  || bad "status: a fresh loop failed its roles (rc=$RC) — $OUT"
"$REAL_SLEEP" 60 & GRACE_PID=$!
loop_up "$GRACE_PID"
printf '%s\n' "$(( $(date +%s) - 100000 ))" > "$T/o/state/roles/loop.started"
doc status
kill "$GRACE_PID" 2>/dev/null || true
[ "$RC" -ne 0 ] && result_has "NEVER RAN" \
  && ok "status: past the grace window, a role that never passed FAILS" \
  || bad "status: an old loop with no passes did not fail (rc=$RC) — $OUT"
rm -f "$T/o/state/roles/loop.started" "$T/o/state/roles/loop.pid" "$T/o/state/roles/loop.ident"

# A live loop pid + one recent pass per role = healthy.
"$REAL_SLEEP" 60 & LOOP_PID=$!
loop_up "$LOOP_PID"
reset_tmux; reset_ps
printf '[]\n' > "$T/gh/prs.json"
doc reap;   bash "$DOCTOR" reap >/dev/null 2>&1
bash "$DOCTOR" merge >/dev/null 2>&1
DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" bash "$DOCTOR" hygiene >/dev/null 2>&1
rm -f "$T/tmux/sessions"; : > "$T/tmux/sessions"; reset_ps
printf '[]\n' > "$T/gh/prs.json"
doc doctor
doc status
[ "$RC" -eq 0 ] && ok "status: rc=0 once the loop is live and every role has passed" || bad "status: rc=$RC after passes — $OUT"
result_has "RUNNING" && ok "status: reports the roles as RUNNING" || bad "status: no RUNNING row — $OUT"
case "$OUT" in *"last pass"*) ok "status: prints a LAST PASS time per role" ;; *) bad "status: no last-pass time — $OUT" ;; esac
kill -TERM "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""

# ── 12) HYGIENE: the package cache is pruned; worktrees are armed only under pressure ───────────
say_case "hygiene: uv cache prune runs; the worktree reaper is gated"
reset_state; rm -f "$T/uv/uv-calls" "$T/wt/calls"
export DOCTOR_TEST_UV="$T/uv" DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt"
# ⛔ MIN_FREE_MB=0 pins the DISK PRESSURE this arm is about: `auto` arms the reaper when free space is
# under MIN_FREE_MB*2, so on a nearly-full runner (measured: 1 GB free, 99% used) an un-pinned "healthy
# disk" arm asserts --dry-run against a host that is under pressure and fails for the wrong reason.
OUT="$(MIN_FREE_MB=0 bash "$DOCTOR" hygiene 2>&1)"; RC=$?
grep -q 'cache prune' "$T/uv/uv-calls" 2>/dev/null && ok "hygiene: ran 'uv cache prune' (not 'cache clean')" \
  || bad "hygiene: did not prune the package cache — $(cat "$T/uv/uv-calls" 2>/dev/null)"
grep -q -- '--dry-run' "$T/wt/calls" 2>/dev/null && ok "hygiene: a healthy disk leaves the worktree reaper in DRY-RUN" \
  || bad "hygiene: worktree reaper mode wrong — $(cat "$T/wt/calls" 2>/dev/null)"
# …and the other half of the same gate: under pressure `auto` ARMS it. Pinned high, so it holds on any
# host.
rm -f "$T/wt/calls"
OUT="$(MIN_FREE_MB=99999999 bash "$DOCTOR" hygiene 2>&1)"; RC=$?
grep -q -- '--apply' "$T/wt/calls" 2>/dev/null && ok "hygiene: DISK PRESSURE (auto) arms the worktree reaper" \
  || bad "hygiene: a cell under disk pressure did not arm the reaper — $(cat "$T/wt/calls" 2>/dev/null)"

# ── 13) unknown arguments are refused (a typo must not arm the destructive verb) ───────────────
say_case "argument validation"
OUT="$(bash "$DOCTOR" reap --dryrun 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "a typo'd flag is refused (rc=2)" || bad "a typo'd flag was silently accepted (rc=$RC) — $OUT"
OUT="$(DOCTOR_INTERVAL=abc bash "$DOCTOR" status 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "a non-numeric interval is refused before any pass" || bad "a bad interval was accepted (rc=$RC) — $OUT"
OUT="$(bash "$DOCTOR" reap --dry-run --dry-run 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "a repeated --dry-run is refused (two flags used to concatenate into a non-matching value)" \
  || bad "repeated --dry-run was accepted (rc=$RC) — $OUT"
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

say_case "the role lock: a second pass SKIPS rather than acting twice"
reset_tmux; reset_ps; reset_state; rm -f "$T/writing"
mk_lane lane-46 4646
"$REAL_SLEEP" 30 & HOLDER=$!
# The ownership record is `own` (what lock_claim writes and role_lock reads), and it carries the
# IDENTITY: a bare pid in the wrong file left this arm passing through the "fresh lock dir" grace path
# instead of the live-owner exclusion it claims to exercise.
mkdir -p "$T/o/state/roles/.reap.lock"
holder_ident="$(sed 's/.*) //' "/proc/$HOLDER/stat" 2>/dev/null | awk '{print $20}')"
case "$holder_ident" in ''|*[!0-9]*) holder_ident="$(ps -p "$HOLDER" -o lstart= 2>/dev/null)" ;; *) holder_ident="proc:$holder_ident" ;; esac
printf '%s|%s\n' "$HOLDER" "$holder_ident" > "$T/o/state/roles/.reap.lock/own"
OUT="$(bash "$DOCTOR" reap 2>&1)"; RC=$?
kill "$HOLDER" 2>/dev/null || true
[ "$RC" -eq 0 ] && result_has "SKIP another reap pass is running" && ! killed lane-46 \
  && ok "reap: a held lock makes the second pass a no-op (no second sample, no kill)" \
  || bad "reap: the lock did not stop a second pass (rc=$RC killed=$(killed lane-46 && echo yes || echo no)) — $OUT"

# ── 14) REVIEW ROUND 1 FINDINGS: each one pinned so it cannot come back ─────────────────────────
say_case "an unreadable session list is not 'nothing to reap'"
reset_tmux; reset_ps; reset_state
OUT="$(DOCTOR_TMUX_BIN=/nonexistent/tmux bash "$DOCTOR" reap 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "CANNOT-VERIFY" \
  && ok "reap: tmux absent -> rc=3 cannot-verify (not a clean empty pass)" \
  || bad "reap: missing tmux gave rc=$RC — $OUT"
printf '1\n' > "$T/tmux/ls_rc"; printf 'tmux: permission denied opening /tmp/tmux-0/default\n' > "$T/tmux/ls_msg"
OUT="$(bash "$DOCTOR" reap 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "CANNOT-VERIFY" \
  && ok "reap: a FAILING tmux read -> rc=3 cannot-verify" \
  || bad "reap: a failing tmux read gave rc=$RC — $OUT"
printf '1\n' > "$T/tmux/ls_rc"; printf 'no server running on /tmp/tmux-0/default\n' > "$T/tmux/ls_msg"
OUT="$(bash "$DOCTOR" reap 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && grep -q 'no harness session to judge' "$T/o/state/roles/reap.state" 2>/dev/null \
  && ok "reap: 'no server running' IS an empty list (rc=0) — the two are distinguished" \
  || bad "reap: no-server gave rc=$RC — $OUT"
rm -f "$T/tmux/ls_rc" "$T/tmux/ls_msg"

say_case "hygiene: the reaper is found beside the supervisor, and its absence is cannot-verify"
reset_state; rm -f "$T/uv/uv-calls" "$T/wt/calls" "$T/bin/sup-calls"
export DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup"
cat > "$T/bin/pi-reap-worktrees.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCTOR_TEST_WT:?}/calls"
exit 0
SH
chmod +x "$T/bin/pi-reap-worktrees.sh"
# ⛔ Pin the free-space floor. `HYGIENE_WORKTREES=auto` escalates to `--apply` when the CELL's disk is
# under `2 * MIN_FREE_MB`, so an un-pinned arm asserted "dry-run by default" against whatever the host
# happened to have free — measured red on this box at 128 MB free, green on CI. The floor is part of
# the fixture, exactly like every other bound here.
( unset DOCTOR_WORKTREE_REAPER; MIN_FREE_MB=1 doc hygiene )
grep -q -- '--dry-run' "$T/wt/calls" 2>/dev/null \
  && ok "hygiene: the shipped-layout reaper (beside the supervisor) is FOUND and run" \
  || bad "hygiene: did not find the reaper beside the supervisor — $(cat "$T/wt/calls" 2>/dev/null)"
# …and the escalation itself, made deterministic by pinning a floor no disk can satisfy: a cell whose
# disk is under 2× the floor must SWEEP, not merely report (the stated reason `auto` exists).
: > "$T/wt/calls"
( unset DOCTOR_WORKTREE_REAPER; MIN_FREE_MB=999999999 doc hygiene ) >/dev/null 2>&1 || true
grep -q -- '--apply' "$T/wt/calls" 2>/dev/null \
  && ok "hygiene: auto escalates to --apply when free space is under 2x the floor" \
  || bad "hygiene: auto did not escalate on a full disk — $(cat "$T/wt/calls" 2>/dev/null)"
rm -f "$T/bin/pi-reap-worktrees.sh"
# Point the override at a path that cannot exist: the repo copy one level up would otherwise be
# found, and this arm is about the NOT-FOUND verdict, not about the search order.
OUT="$(DOCTOR_WORKTREE_REAPER=/nonexistent/pi-reap-worktrees.sh bash "$DOCTOR" hygiene 2>&1)"
HRC=$?
[ "$HRC" -eq 3 ] && ok "hygiene: no reaper anywhere -> rc=3 (not a clean pass)" \
  || bad "hygiene: missing reaper gave rc=$HRC (want 3) — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = "3" ] \
  && ok "hygiene: the cannot-verify is RECORDED on the role" \
  || bad "hygiene: state rc is not 3 — $(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")"

say_case "hygiene: an unreadable session list fails CLOSED (no cache sweep)"
reset_state; rm -f "$T/o/hyg.out" "$T/sup/calls"
: > "$T/tmux/sessions"
printf '1\n' > "$T/tmux/ls_rc"; printf 'tmux: permission denied opening /tmp/tmux-0/default\n' > "$T/tmux/ls_msg"
( unset DOCTOR_SUPERVISOR; bash "$DOCTOR" hygiene >/dev/null 2>&1 )
rm -f "$T/tmux/ls_rc" "$T/tmux/ls_msg"
grep -q 'prune --caches' "$T/sup/calls" 2>/dev/null \
  && bad "hygiene: swept caches while the session list was UNREADABLE (fail-open)" \
  || ok "hygiene: unreadable session list -> the cache sweep is SKIPPED (fail-closed)"

say_case "doctor: a failed or impossible restart is NOT a clean pass"
reset_state; : > "$T/o/state/roles/.desired"; reset_tmux
rm -f "$T/sup/calls"; printf '1\n' > "$T/sup/rc"
( DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" bash "$DOCTOR" doctor >/dev/null 2>&1 ); DRC=$?
[ "$DRC" -eq 1 ] && ok "doctor: a FAILED controller restart makes the pass rc=1" \
  || bad "doctor: failed restart gave rc=$DRC (want 1)"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state")" = "1" ] \
  && ok "doctor: the failure is RECORDED (status cannot print a false green)" \
  || bad "doctor: state rc is not 1 — $(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state")"
rm -f "$T/sup/rc"
( DOCTOR_SUPERVISOR=/nonexistent/sup bash "$DOCTOR" doctor >/dev/null 2>&1 ); DRC=$?
[ "$DRC" -eq 3 ] && ok "doctor: no supervisor to restart with -> rc=3 cannot-verify" \
  || bad "doctor: no-supervisor gave rc=$DRC (want 3)"

say_case "merge: the rail runs FROM the target checkout, and the pass is bounded"
reset_state; reset_tmux; rm -f "$T/rail/calls" "$T/rail/rc" "$T/rail/sleep"
HEAD_C="cccc3333cccc3333cccc3333cccc3333cccc3333"
ATT42="$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_C" > "$ATT42"
printf '[{"number":42,"head":{"sha":"%s"},"draft":false}]\n' "$HEAD_C" > "$T/gh/prs.json"
doc merge
grep -q "cwd=$T/repo " "$T/rail/calls" 2>/dev/null \
  && ok "merge: the rail's cwd is \$REPO (its git flake reproduction needs the target checkout)" \
  || bad "merge: the rail ran from $(sed -n 's/ .*//p' "$T/rail/calls" 2>/dev/null)"

# Two attested PRs, the first rail call outlasting the budget: the second must NOT be attempted.
rm -f "$T/rail/calls" "$T/rail/rc"
# Fresh PR numbers, so neither is inside the refusal cooldown recorded by the arm above.
printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_C" > "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-44.json"
printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_C" > "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-45.json"
printf '[{"number":44,"head":{"sha":"%s"},"draft":false},{"number":45,"head":{"sha":"%s"},"draft":false}]\n' "$HEAD_C" "$HEAD_C" > "$T/gh/prs.json"
printf '2\n' > "$T/rail/sleep"
OUT="$(MERGE_BUDGET_S=1 bash "$DOCTOR" merge 2>&1)"; RC=$?
rm -f "$T/rail/sleep"
[ "$RC" -eq 3 ] && result_has "CANNOT-VERIFY" && [ "$(awk 'END{print NR}' "$T/rail/calls")" = "1" ] \
  && ok "merge: budget spent -> rc=3, the remaining candidate is NOT tried" \
  || bad "merge: budget test rc=$RC calls=$(wc -l < "$T/rail/calls") — $OUT"

say_case "status: the loop's liveness is IDENTITY-fenced, not a bare pid"
reset_state; : > "$T/o/state/roles/.desired"
"$REAL_SLEEP" 30 & LID_PID=$!
loop_up "$LID_PID"
printf '999|Mon Jan  1 00:00:00 2020\n' > "$T/o/state/roles/loop.ident"   # a RECYCLED pid's record
doc status
kill "$LID_PID" 2>/dev/null || true
[ "$RC" -ne 0 ] && result_has "NOT RUNNING" \
  && ok "status: a pid whose recorded identity does not match is NOT reported as the loop" \
  || bad "status: a recycled pid read as RUNNING (rc=$RC) — $OUT"
rm -f "$T/o/state/roles/loop.ident"

say_case "status: a busy-but-healthy cell is not STALE (the bound covers the worst pass)"
reset_state; : > "$T/o/state/roles/.desired"
printf '4200 1 00:00:01\n' > "$T/ps/table"; reset_tmux; : > "$T/tmux/sessions"
"$REAL_SLEEP" 30 & SL_PID=$!
loop_up "$SL_PID"
NOW="$(date +%s)"; OLD=$(( NOW - 300 ))
# reap/hygiene passed just now (their bounds are the test's compressed intervals); doctor/merge are
# 300 s old — which the ROUND-1 default (2*DOCTOR_INTERVAL = 2 s here, 240 s on a real cell) called
# STALE while the merge pass was still legitimately inside a rail call.
for r in reap hygiene; do
  printf 'role=%s\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=0\nlast_result=ok\n' "$r" "$NOW" \
    > "$T/o/state/roles/$r.state"
done
for r in doctor merge; do
  printf 'role=%s\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=0\nlast_result=ok\n' "$r" "$OLD" \
    > "$T/o/state/roles/$r.state"
done
OUT="$(unset DOCTOR_STALE_S; bash "$DOCTOR" status 2>&1)"; RC=$?
kill "$SL_PID" 2>/dev/null || true
[ "$RC" -eq 0 ] && ! result_has "STALE" \
  && ok "status: passes 300s old are not stale under a bound that covers the longest rail call" \
  || bad "status: reported a healthy cell stale (rc=$RC) — $OUT"
[ "$(grep -cF 'WORST_PASS_S=$(( MERGE_BUDGET_S + RAIL_TIMEOUT + HYGIENE_TIMEOUT ))' "$DOCTOR")" -ge 1 ] \
  && ok "status: the default doctor bound is DERIVED from the worst PASS (merge budget + one overrun), not one call" \
  || bad "the default stale bound is not derived from the worst pass"

# And a pass that has been inside a legitimate multi-candidate merge is NOT stale: 3000 s is past the
# round-2 bound (MERGE_BUDGET_S 2400 + RAIL_TIMEOUT 900 = 3300 is the worst pass, so use 3000 < that
# with a narrowed merge budget to prove the derivation, not a hardcoded number).
"$REAL_SLEEP" 30 & SL2_PID=$!
loop_up "$SL2_PID"
for r in reap hygiene; do
  printf 'role=%s\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=0\nlast_result=ok\n' "$r" "$NOW" \
    > "$T/o/state/roles/$r.state"
done
for r in doctor merge; do
  printf 'role=%s\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=0\nlast_result=ok\n' "$r" "$(( NOW - 3000 ))" \
    > "$T/o/state/roles/$r.state"
done
OUT="$(unset DOCTOR_STALE_S; bash "$DOCTOR" status 2>&1)"; RC=$?
kill "$SL2_PID" 2>/dev/null || true
[ "$RC" -eq 0 ] && ! result_has "STALE" \
  && ok "status: a 3000 s-old pass inside a legitimate merge budget is not stale (the bound covers the PASS)" \
  || bad "status: a pass inside the merge budget read stale (rc=$RC) — $OUT"

# ── 15) REVIEW ROUND 2 FINDINGS: the SAFETY gates must fail closed on an unreadable read ──────
say_case "a safety gate whose read fails CLOSES (never 'nobody is watching' / 'no human above')"
reset_tmux; reset_ps; reset_state; rm -f "$T/writing"
mk_lane lane-48 4848
printf '1\n' > "$T/tmux/clients_rc"; printf 'tmux: client list failed\n' > "$T/tmux/clients_msg"
OUT="$(bash "$DOCTOR" reap 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "cannot read the attached clients" && ! killed lane-48 \
  && ok "reap: an unreadable attached-client read SKIPS the lane and the PASS is rc=3 (fails closed)" \
  || bad "reap: unreadable clients rc=$RC killed=$(killed lane-48 && echo yes || echo no) — $OUT"
rm -f "$T/tmux/clients_rc" "$T/tmux/clients_msg"

reset_tmux; reset_ps; reset_state
mk_lane lane-49 4949
: > "$T/ps/pfail.4949"
OUT="$(bash "$DOCTOR" reap 2>&1)"; RC=$?
rm -f "$T/ps/pfail.4949"
[ "$RC" -eq 3 ] && result_has "cannot read the process ancestry" && ! killed lane-49 \
  && ok "reap: an unreadable ancestry read SKIPS the lane and the PASS is rc=3 (fails closed)" \
  || bad "reap: unreadable ancestry rc=$RC killed=$(killed lane-49 && echo yes || echo no) — $OUT"

say_case "the per-read bound survives a host with no timeout(1)"
reset_tmux; reset_ps; reset_state; rm -f "$T/writing"
mk_lane lane-50 5050
: > "$T/ps/hang"
STARTED="$(date +%s)"
OUT="$(DOCTOR_TIMEOUT_BIN=/nonexistent/tmux-timeout READ_CALL_TIMEOUT=1 bash "$DOCTOR" reap 2>&1)"; RC=$?
ELAPSED=$(( $(date +%s) - STARTED ))
rm -f "$T/ps/hang"
[ "$ELAPSED" -lt 4 ] && ! killed lane-50 && result_has "cannot-verify" \
  && ok "reap: without timeout(1) the shell fallback still cuts a hung read (${ELAPSED}s, no kill)" \
  || bad "reap: a hung read ran ${ELAPSED}s under the fallback (killed=$(killed lane-50 && echo yes || echo no)) — $OUT"

say_case "merge: the open-PR read is INSIDE the pass budget and bounded"
reset_state; reset_tmux; rm -f "$T/gh/rc"
: > "$T/gh/hang"
STARTED="$(date +%s)"
OUT="$(MERGE_READ_TIMEOUT=1 bash "$DOCTOR" merge 2>&1)"; RC=$?
ELAPSED=$(( $(date +%s) - STARTED ))
rm -f "$T/gh/hang"
[ "$RC" -eq 3 ] && [ "$ELAPSED" -lt 4 ] && result_has "CANNOT-VERIFY" \
  && ok "merge: a hung open-PR read is cut at MERGE_READ_TIMEOUT and the pass is rc=3" \
  || bad "merge: hung read rc=$RC after ${ELAPSED}s — $OUT"

# ── 16) REVIEW ROUND 3 FINDINGS ─────────────────────────────────────────────────────────────────
say_case "a TERM-deferring subprocess is still ENDED by its bound"
reset_state; reset_tmux
rm -f "$T/rail/calls" "$T/rail/rc" "$T/rail/sleep" "$T/rail/defer"
HEAD_D="dddd4444dddd4444dddd4444dddd4444dddd4444"
printf '{"head_sha":"%s","verdict":"clean"}\n' "$HEAD_D" > "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-46.json"
printf '[{"number":46,"head":{"sha":"%s"},"draft":false}]\n' "$HEAD_D" > "$T/gh/prs.json"
: > "$T/rail/defer"
STARTED="$(date +%s)"
OUT="$(DOCTOR_RAIL_TIMEOUT=1 DOCTOR_TIMEOUT_KILL_S=1 bash "$DOCTOR" merge 2>&1)"; RC=$?
ELAPSED=$(( $(date +%s) - STARTED ))
rm -f "$T/rail/defer"
[ "$ELAPSED" -lt 6 ] \
  && ok "merge: a rail that defers TERM is KILLed at the bound (${ELAPSED}s, not the 5s hang)" \
  || bad "merge: a TERM-deferring rail ran ${ELAPSED}s — the bound did not end it"

say_case "the role lock is identity-fenced (a recycled pid cannot wedge the role)"
reset_state; reset_tmux; reset_ps; rm -f "$T/writing"
mk_lane lane-51 5151
"$REAL_SLEEP" 30 & HOLD2=$!
mkdir -p "$T/o/state/roles/.reap.lock"
# A LIVE pid, but a DIFFERENT incarnation: this is the recycled-pid case a bare `kill -0` cannot see.
printf '%s|proc:1\n' "$HOLD2" > "$T/o/state/roles/.reap.lock/own"
OUT="$(bash "$DOCTOR" reap 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ! result_has "SKIP another reap pass is running" \
  && ok "lock: a lock held by a live WRONG-incarnation pid is RECLAIMED (no permanent wedge)" \
  || bad "lock: a recycled pid wedged the role — $OUT"
kill "$HOLD2" 2>/dev/null || true
# …and the true incarnation still excludes a second pass.
rm -rf "$T/o/state/roles/.reap.lock"; reset_tmux; reset_ps; mk_lane lane-52 5252
"$REAL_SLEEP" 30 & HOLD3=$!
mkdir -p "$T/o/state/roles/.reap.lock"
printf '%s|%s\n' "$HOLD3" "$(ident_of "$HOLD3")" > "$T/o/state/roles/.reap.lock/own"
OUT="$(bash "$DOCTOR" reap 2>&1)"; RC=$?
kill "$HOLD3" 2>/dev/null || true
[ "$RC" -eq 0 ] && result_has "SKIP another reap pass is running" && ! killed lane-52 \
  && ok "lock: the SAME incarnation still excludes a second pass" \
  || bad "lock: the identity fence let a concurrent pass run — $OUT"

# ── 17) REVIEW ROUND 4 FINDINGS ─────────────────────────────────────────────────────────────────
say_case "a role whose LAST pass failed makes status fail (the pass, not just its age, is judged)"
reset_state; : > "$T/o/state/roles/.desired"; reset_tmux; reset_ps
"$REAL_SLEEP" 30 & SP_PID=$!
loop_up "$SP_PID"
NOW="$(date +%s)"
printf 'role=doctor\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=1\nlast_result=controller restart FAILED rc=1\n' "$NOW" > "$T/o/state/roles/doctor.state"
for r in reap merge hygiene; do
  printf 'role=%s\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=0\nlast_result=ok\n' "$r" "$NOW" > "$T/o/state/roles/$r.state"
done
doc status
kill "$SP_PID" 2>/dev/null || true
[ "$RC" -ne 0 ] && result_has "FAILED" \
  && ok "status: a recent pass that FAILED (rc=1) is reported and fails the verb" \
  || bad "status: a failed pass read as healthy (rc=$RC) — $OUT"

say_case "the doctor's not-started pass carries the nested reap's rc"
reset_state; reset_tmux; rm -f "$T/o/state/roles/.desired"
printf '1\n' > "$T/tmux/ls_rc"; printf 'tmux: permission denied opening /tmp/tmux-0/default\n' > "$T/tmux/ls_msg"
( DOCTOR_GRACE_S=0 bash "$DOCTOR" doctor >/dev/null 2>&1 ); DRC=$?
rm -f "$T/tmux/ls_rc" "$T/tmux/ls_msg"
[ "$DRC" -eq 3 ] && [ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state")" = "3" ] \
  && ok "doctor: not-started + unreadable reap -> the record is rc=3 (not a clean 'not started')" \
  || bad "doctor: not-started recorded rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/doctor.state") (want 3)"

say_case "hygiene: a FAILING reaper and a MISSING supervisor are cannot-verify"
reset_state; reset_tmux
cat > "$T/bin/bad-reaper.sh" <<'SH'
#!/bin/bash
exit 2
SH
chmod +x "$T/bin/bad-reaper.sh"
OUT="$(DOCTOR_WORKTREE_REAPER="$T/bin/bad-reaper.sh" DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" bash "$DOCTOR" hygiene 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "worktrees" && result_has "FAILED rc=2" \
  && ok "hygiene: a reaper that exits non-zero -> rc=3 (not 'worktrees apply')" \
  || bad "hygiene: a failing reaper produced rc=$RC — $OUT"
OUT="$(DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" DOCTOR_SUPERVISOR=/nonexistent bash "$DOCTOR" hygiene 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "supervisor not found" \
  && ok "hygiene: no supervisor -> the cache sweep is CANNOT-VERIFY (not a silent no-op)" \
  || bad "hygiene: no supervisor produced rc=$RC — $OUT"

# ── 18) REVIEW ROUND 6 FINDINGS ─────────────────────────────────────────────────────────────────
say_case "hygiene: a FAILED (or timed-out) uv cache prune is cannot-verify, not a clean pass"
reset_state; rm -f "$T/uv/uv-calls" "$T/wt/calls"
cat > "$T/bin/uv-bad" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$T/bin/uv-bad"
# PATH order decides which `uv` the role finds; the double is named `uv` in $T/bin, so shadow it for
# this arm only with a directory that carries the failing one.
mkdir -p "$T/binbad"; mv "$T/bin/uv-bad" "$T/binbad/uv"
OUT="$(PATH="$T/binbad:$T/bin:$PATH" DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
       bash "$DOCTOR" hygiene 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && [ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = "3" ] \
  && result_has "uv cache prune FAILED" \
  && ok "hygiene: uv prune rc=1 -> the PASS is rc=3 (a failed prune cannot read green)" \
  || bad "hygiene: a failed uv prune produced rc=$RC — $OUT"

say_case "a stop that arrives MID-PASS suppresses the destructive steps it would have started"
reset_state; : > "$T/o/state/roles/.desired"; reset_tmux; rm -f "$T/rail/calls"
mkdir -p "$T/home/.pi/agent/reviews"
printf '[{"number":42,"head":{"sha":"%s"},"draft":false}]\n' "cccc3333cccc3333cccc3333cccc3333cccc3333" > "$T/gh/prs.json"
printf '{"head_sha":"cccc3333cccc3333cccc3333cccc3333cccc3333","verdict":"clean"}\n' \
  > "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
# The `gh` double sleeps, so the pass is provably still running when the stop lands.
mkdir -p "$T/binslow"
cat > "$T/binslow/gh" <<'SH'
#!/bin/bash
sleep 1
printf '[{"number":42,"head":{"sha":"cccc3333cccc3333cccc3333cccc3333cccc3333"},"draft":false}]\n'
SH
chmod +x "$T/binslow/gh"
( sleep 0.4; rm -f "$T/o/state/roles/.desired" ) &
OUT="$(DOCTOR_GH_BIN="$T/binslow/gh" DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" \
       bash "$DOCTOR" merge 2>&1)"; RC=$?
wait 2>/dev/null || true
[ -s "$T/rail/calls" ] && bad "merge: railed a PR AFTER a stop arrived mid-pass" \
  || ok "merge: a stop mid-pass -> the rail was NOT called (stop wins)"
result_has "STOP arrived during this pass" && ok "merge: the pass SAYS it was stopped, it is not silent" \
  || bad "merge: the stop is not recorded in the pass result — $OUT"
: > "$T/o/state/roles/.desired"

say_case "the role lock's reclaim is atomic (one winner, never a stolen fresh lock)"
# Drive the SHIPPED `role_lock`/`reclaim_lock`/`lock_claim` with stubs for the probes around them. A
# dead-owner lock, then FOUR reclaimers at once. Two designs fail this: `rm -rf; mkdir` (B deletes A's
# fresh lock) and `mv $d tomb` (a loser whose mv fails moves the winner's FRESH lock away) — the
# second was measured at 2 winners before the meta-lock.
rm -rf "$T/locktest"; mkdir -p "$T/locktest/.reap.lock"
printf '999999|proc:1\n' > "$T/locktest/.reap.lock/own"
{
  printf '%s\n' 'pid_ident() { printf "proc:1\n"; }'
  cat <<'NUMOK'
num_ok() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
NUMOK
  # ⛔ The REAL `mtime_epoch`, never a constant: `reclaim_lock` bounds a killed reclaimer's meta-lock
  # at 60 s, so a stub that answers 1 makes EVERY meta-lock look ancient — the second racer then deletes
  # a meta-lock created milliseconds ago and claims the lock too (measured on CI: 3 "winners" of 6).
  # The stub was the defect; the shipped code's own age check is what keeps the reclaim to one winner.
  sed -n '/^mtime_epoch() {/,/^}/p' "$DOCTOR"
  sed -n '/^lock_claim() {/,/^}/p' "$DOCTOR"
  sed -n '/^reclaim_lock() {/,/^}/p' "$DOCTOR"
  sed -n '/^role_lock() {/,/^}/p' "$DOCTOR"
} > "$T/locktest/lib.sh"
: > "$T/locktest/winners"
for i in 1 2 3 4 5 6; do
  ( ROLES_DIR="$T/locktest"; . "$T/locktest/lib.sh"; role_lock reap && printf 'w%s\n' "$i" >> "$T/locktest/winners" ) &
done
wait
W="$(awk 'END{printf "%d\n", NR+0}' "$T/locktest/winners")"
[ "$W" -le 1 ] && ok "lock: at most ONE of six concurrent reclaimers holds the lock (got $W)" \
  || bad "lock: $W reclaimers held the same lock (the reclaim is not atomic)"
# …and the role is still usable afterwards: the meta-lock must not wedge it.
rm -rf "$T/locktest/.reap.lock" "$T/locktest/.reap.lock.reclaim"; mkdir -p "$T/locktest/.reap.lock"
printf '999999|proc:1\n' > "$T/locktest/.reap.lock/own"
( ROLES_DIR="$T/locktest"; . "$T/locktest/lib.sh"; role_lock reap ) \
  && ok "lock: a dead-owner lock is still RECLAIMED (no wedge from the meta-lock)" \
  || bad "lock: a dead-owner lock could not be reclaimed"
# A meta-lock left by a KILLED reclaimer must not disable the role: it is bounded, then reclaimed.
mkdir -p "$T/locktest/.reap.lock.reclaim"; printf '999999|proc:1\n' > "$T/locktest/.reap.lock/own"
touch -d '@1' "$T/locktest/.reap.lock.reclaim" 2>/dev/null || touch -t 197001010000 "$T/locktest/.reap.lock.reclaim"
( ROLES_DIR="$T/locktest"; . "$T/locktest/lib.sh"; role_lock reap ) \
  && ok "lock: an ANCIENT meta-lock (a killed reclaimer) does not wedge the role" \
  || bad "lock: a stale meta-lock disabled the role permanently"

say_case "round 8: a stop mid-pass does not erase an earlier cannot-verify; a missing checkout is not a refusal"
# hygiene: uv prune FAILS, then a stop lands before the worktree step — the pass must stay rc=3.
reset_state; : > "$T/o/state/roles/.desired"; reset_tmux; rm -f "$T/wt/calls" "$T/o/state/roles/.stop-generation"
# A SLOW failing `uv` (1 s) gives the stop a window to land mid-pass, between the prune and the reaper.
mkdir -p "$T/binslowuv"
cat > "$T/binslowuv/uv" <<'SH'
#!/bin/bash
sleep 1
exit 1
SH
chmod +x "$T/binslowuv/uv"
( sleep 0.4; printf '1\n' > "$T/o/state/roles/.stop-generation" ) & HSTOP=$!
OUT="$(DOCTOR_TEST_UV="$T/uv" DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
       PATH="$T/binslowuv:$T/bin:$PATH" bash "$DOCTOR" hygiene 2>&1)"; RC=$?
wait "$HSTOP" 2>/dev/null || true
[ "$RC" -eq 3 ] && [ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = "3" ] \
  && ok "hygiene: a stop mid-pass keeps an earlier rc=3 (it cannot turn the pass green)" \
  || bad "hygiene: a stop mid-pass erased a cannot-verify (rc=$RC) — $OUT"
[ -s "$T/wt/calls" ] && bad "hygiene: ran the worktree reaper after a stop arrived mid-pass" \
  || ok "hygiene: the worktree reaper is NOT run after a stop arrived mid-pass"
rm -f "$T/o/state/roles/.stop-generation"

# merge: a MISSING checkout is cannot-verify, NOT a rail refusal that reads as a clean pass.
reset_state; : > "$T/o/state/roles/.desired"; rm -f "$T/rail/calls"
mkdir -p "$T/home/.pi/agent/reviews"
printf '[{"number":42,"head":{"sha":"%s"},"draft":false}]\n' "dddd4444dddd4444dddd4444dddd4444dddd4444" > "$T/gh/prs.json"
printf '{"head_sha":"dddd4444dddd4444dddd4444dddd4444dddd4444","verdict":"clean"}\n' \
  > "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
OUT="$(REPO="$T/no-such-checkout" DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" \
       bash "$DOCTOR" merge 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in *"no checkout"*) true ;; *) false ;; esac \
  && ok "merge: a missing checkout is CANNOT-VERIFY (rc=3), not 'REFUSED'" \
  || bad "merge: a missing checkout produced rc=$RC — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")"
[ -s "$T/rail/calls" ] && bad "merge: the rail ran without a checkout" || true
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
  *REFUSED*) bad "merge: a missing checkout was recorded as a rail REFUSAL (it suppresses the PR for MERGE_RETRY_S)" ;;
  *) ok "merge: no refusal was recorded for a checkout that does not exist" ;;
esac

say_case "round 9: an unreadable checkout and an unreadable pane pid are cannot-verify"
reset_state; : > "$T/o/state/roles/.desired"; rm -f "$T/rail/calls"
mkdir -p "$T/home/.pi/agent/reviews"
printf '[{"number":42,"head":{"sha":"%s"},"draft":false}]\n' "eeee5555eeee5555eeee5555eeee5555eeee5555" > "$T/gh/prs.json"
printf '{"head_sha":"eeee5555eeee5555eeee5555eeee5555eeee5555","verdict":"clean"}\n' \
  > "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
mkdir -p "$T/chmod-repo"; chmod 000 "$T/chmod-repo" 2>/dev/null
if [ ! -r "$T/chmod-repo" ]; then
  OUT="$(REPO="$T/chmod-repo" DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" \
         bash "$DOCTOR" merge 2>&1)"; RC=$?
  chmod 755 "$T/chmod-repo" 2>/dev/null
  [ "$RC" -eq 3 ] && ok "merge: an UNREADABLE checkout is cannot-verify too (rc=3), not a rail refusal" \
    || bad "merge: an unreadable checkout produced rc=$RC — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")"
else
  chmod 755 "$T/chmod-repo" 2>/dev/null
  echo "  ⏭ SKIP: running as root — a 000 directory is still readable, so the unreadable arm cannot be built"
fi

# reap: `list-panes` failing while `tmux ls` works. A real session always has a pane pid, so an empty
# read is a read failure — the lane was not judged, and the pass must not report a clean skip.
reset_state; reset_tmux; reset_ps
mk_lane lane-91 9191
# `tmux ls` SUCCEEDS and the lane is aged and idle — only the PANE read is empty (an unreadable
# answer), which is the case under test.
: > "$T/tmux/panes/lane-91"
OUT="$(bash "$DOCTOR" reap 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && result_has "cannot-verify" \
  && ok "reap: an unreadable pane pid is cannot-verify (rc=3), not a clean 'no usable pane pid'" \
  || bad "reap: an unreadable pane pid produced rc=$RC — $OUT"

say_case "round 10: the merge role takes the controller's per-PR claim"
reset_state; : > "$T/o/state/roles/.desired"; reset_tmux; rm -f "$T/rail/calls" "$T/o/state/mergeclaim-42.lock"
mkdir -p "$T/home/.pi/agent/reviews" "$T/o/state"
printf '[{"number":42,"head":{"sha":"%s"},"draft":false}]\n' "ffff6666ffff6666ffff6666ffff6666ffff6666" > "$T/gh/prs.json"
printf '{"head_sha":"ffff6666ffff6666ffff6666ffff6666ffff6666","verdict":"clean"}\n' \
  > "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-42.json"
# A LIVE worker already holds the claim: the doctor must NOT rail the same head, and must NOT remove
# the other worker's claim.
"$REAL_SLEEP" 30 & HOLD=$!
sleep 0.2
printf '%s\n' "$HOLD" > "$T/o/state/mergeclaim-42.lock"
OUT="$(DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" bash "$DOCTOR" merge 2>&1)"; RC=$?
[ -s "$T/rail/calls" ] && bad "merge: railed a PR whose claim a live worker holds (double dispatch)" \
  || ok "merge: a LIVE claim on the PR means the doctor does not rail it"
[ -f "$T/o/state/mergeclaim-42.lock" ] && ok "merge: the other worker's claim is left in place" \
  || bad "merge: the doctor deleted a claim it did not own"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
  *"claimed by pid"*) ok "merge: the skip names the claim holder" ;;
  *) bad "merge: the claim skip is unexplained — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
esac
# A STALE claim (its owner is gone) is reclaimed: the doctor rails, and releases only its own claim.
kill -KILL "$HOLD" 2>/dev/null || true
OUT="$(DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" bash "$DOCTOR" merge 2>&1)"; RC=$?
[ "$(awk 'END{print NR}' "$T/rail/calls" 2>/dev/null)" = "1" ] \
  && ok "merge: a STALE claim is reclaimed and the rail is called once" \
  || bad "merge: a stale claim blocked the rail — $(cat "$T/rail/calls" 2>/dev/null)"
[ -f "$T/o/state/mergeclaim-42.lock" ] && bad "merge: the claim was left behind after the pass" \
  || ok "merge: the claim is released after the rail returns"

say_case "round 10b: an unusable parser and a rail that could not read the merge state are cannot-verify"
# (a) the attestation PARSER failing to EXECUTE (126/127): it used to fall through to "no clean
# attestation" — a clean `nothing to land` while every reviewed PR was skipped. Drive the SHIPPED
# function with a `python3` that cannot run.
rm -rf "$T/attstore"; mkdir -p "$T/attstore"
printf '{"head_sha":"1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa","verdict":"clean"}\n' \
  > "$T/attstore/daniel-ospina-agent-infra-42.json"
{ sed -n '/^attestation_clean() {/,/^}/p' "$DOCTOR"; } > "$T/attstore/lib.sh"
ARC=0
( CELL_HOME="$T/attstore-home"; OR="daniel-ospina/agent-infra"; . "$T/attstore/lib.sh"
  mkdir -p "$CELL_HOME/.pi/agent"; ln -sfn "$T/attstore" "$CELL_HOME/.pi/agent/reviews"
  python3() { return 127; }
  attestation_clean 42 "1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa" ) || ARC=$?
[ "$ARC" -eq 3 ] && ok "merge: an UNUSABLE python3 is cannot-verify (rc=3), not 'nothing to land'" \
  || bad "merge: a parser that cannot execute produced rc=$ARC (want 3)"

# (b) the rail exits 1 because it could not READ the merge state: not a refusal, no cooldown.
reset_state; : > "$T/o/state/roles/.desired"; rm -f "$T/rail/calls" "$T/o/state/mergeclaim-42.lock"
cat > "$T/bin/rail-unreadable.sh" <<'SH'
#!/bin/bash
echo "BLOCK [merge_unreadable] the post-merge state could not be read (this is NOT a claim that it did not merge)"
exit 1
SH
chmod +x "$T/bin/rail-unreadable.sh"
OUT="$(DOCTOR_ADMIN_MERGE="$T/bin/rail-unreadable.sh" DOCTOR_TEST_RAIL="$T/rail" \
       bash "$DOCTOR" merge 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" in
    *"merge_unreadable"*) ok "merge: a rail 'merge_unreadable' block is cannot-verify (rc=3), not a REFUSED" ;;
    *) bad "merge: merge_unreadable recorded as $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state")" ;;
  esac || bad "merge: a merge_unreadable block produced rc=$RC"
grep -q 'merge_unreadable' "$T/o/state/roles/merge.attempts" 2>/dev/null \
  && bad "merge: a merge_unreadable block armed the retry cooldown (the head may have merged)" \
  || ok "merge: a merge_unreadable block does NOT cool the head down"

say_case "final pass: an incomplete ps read cannot make a live lane look idle; the rail is found one level up"
# (a) `ps -A` FAILS midway: the CPU subtree read must be NA (fail closed), not a short answer that
# makes "cpu unchanged" true while descendants are still working.
reset_state; : > "$T/o/state/roles/.desired"; reset_tmux; reset_ps; rm -f "$T/writing"
mk_lane lane-77 7777
cat > "$T/ps/mode" <<'EOF'
cpu
EOF
# The stub fails the SECOND -A call (the sample), after the first (baseline) succeeded.
cat > "$T/bin/ps-fail2" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_PS:?}"
if [ "${1:-}" = "-A" ]; then
  n=0; [ -f "$S/calls" ] && n="$(cat "$S/calls")"
  n=$((n + 1)); printf '%s\n' "$n" > "$S/calls"
  [ "$n" -ge 2 ] && exit 1
  cat "$S/table" 2>/dev/null; exit 0
fi
exec "$REAL_PS" "$@"
SH
chmod +x "$T/bin/ps-fail2"
OUT="$(DOCTOR_PS_BIN="$T/bin/ps-fail2" bash "$DOCTOR" reap 2>&1)"; RC=$?
killed lane-77 && bad "reap: killed a lane whose CPU read FAILED (an incomplete table looked idle)" \
  || ok "reap: an incomplete/failed CPU read does NOT reap (fail-closed)"
result_has "cannot-verify" && ok "reap: the unreadable CPU subtree is recorded as cannot-verify" \
  || bad "reap: the failed CPU read is not recorded — $OUT"

# (b) the shipped rail sits one level ABOVE this file (`scripts/admin-merge.sh`): with no supervisor
# in the environment, `rail_path` must still find it.
rm -rf "$T/railup"; mkdir -p "$T/railup/scripts/orchestrator-harness"
printf '#!/bin/bash\nexit 0\n' > "$T/railup/scripts/admin-merge.sh"; chmod +x "$T/railup/scripts/admin-merge.sh"
cp "$DOCTOR" "$T/railup/scripts/orchestrator-harness/cloud-cell-doctor.sh"
{ sed -n '/^rail_path() {/,/^}/p' "$DOCTOR"; } > "$T/railup/lib.sh"
RP="$( ( SELF_DIR="$T/railup/scripts/orchestrator-harness"; unset DOCTOR_ADMIN_MERGE SUPERVISOR
          REPO=/nonexistent CELL_HOME=/nonexistent; . "$T/railup/lib.sh"; rail_path ) )"
[ "$(cd "$(dirname "$RP")" && pwd)/$(basename "$RP")" = "$T/railup/scripts/admin-merge.sh" ] \
  && ok "merge: the rail is found one level UP from the doctor (the shipped layout)" \
  || bad "merge: rail_path returned '${RP}' (want $T/railup/scripts/admin-merge.sh)"

say_case "final pass 2: the LOOP quenches on .desired, and an unreadable session list is cannot-verify"
# A loop that survives `stop` (the orphan case) must exit rather than keep dispatching roles: a pass
# that BEGINS after the stop snapshots the post-stop state, so the mid-pass check cannot see it.
reset_state; reset_tmux; reset_ps; rm -f "$T/o/state/roles/.desired"
: > "$T/tmux/sessions"
OUT="$(LOOP_TICK=0 DOCTOR_INTERVAL=0 MERGE_INTERVAL=0 HYGIENE_INTERVAL=0 \
       timeout 20 bash "$DOCTOR" loop 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "the loop is exiting without dispatching" \
  && ok "loop: with no .desired the loop EXITS instead of dispatching (a stop cannot be outrun)" \
  || bad "loop: an undesired cell kept looping (rc=$RC) — $OUT"
[ -f "$T/o/state/roles/merge.state" ] && bad "loop: dispatched the merge role on a stopped cell" \
  || ok "loop: no role pass ran on a stopped cell"

# …and the hygiene arm: an unreadable worker-session list is rc=3, not a clean pass.
reset_state; : > "$T/o/state/roles/.desired"; reset_tmux
printf '1\n' > "$T/tmux/ls_rc"; printf 'tmux: permission denied\n' > "$T/tmux/ls_msg"
OUT="$(DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" DOCTOR_SUPERVISOR="$T/bin/sup" \
       DOCTOR_TEST_SUP="$T/sup" bash "$DOCTOR" hygiene 2>&1)"; RC=$?
rm -f "$T/tmux/ls_rc" "$T/tmux/ls_msg"
[ "$RC" -eq 3 ] && [ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = "3" ] \
  && ok "hygiene: an unreadable session list is rc=3 (the sweep was never evaluated)" \
  || bad "hygiene: an unreadable session list produced rc=$RC (a clean pass over an unrun sweep)"

# ── 18) A DEAD LOOP IS NEVER 'WAITING' (agent-infra#2306) ────────────────────────────────────────
# The measured pi-cell-4 output, in full: `loop: NOT RUNNING` printed BESIDE four `WAITING … 274s
# ago` rows that quoted the dead loop's start time as if it were progressing. The only row that knew
# the truth did not suppress or downgrade the others, so a reader concluded "the first pass is slow"
# while nothing would ever complete — and reap/merge/hygiene never ran at all (a cell that produces
# PRs and can never land them).
say_case "status: a DEAD loop reports DEAD in every row, never WAITING (#2306)"
reset_state; reset_tmux; reset_ps; : > "$T/o/state/roles/.desired"
: > "$T/o/logs/doctor.log"
# A pid that is provably gone: start one and reap it, so `kill -0` fails for the right reason.
"$REAL_SLEEP" 0.05 & GONE_PID=$!; wait "$GONE_PID" 2>/dev/null || true
printf '%s\n' "$GONE_PID" > "$T/o/state/roles/loop.pid"
printf '%s|proc:12345\n' "$GONE_PID" > "$T/o/state/roles/loop.ident"
printf '%s\n' "$(( $(date +%s) - 274 ))" > "$T/o/state/roles/loop.started"
# …and the SIGKILL's leftovers: the in-progress marker a killed loop cannot remove.
: > "$T/o/state/roles/.doctor.running"
# ⛔ THE EXACT MEASURED SHAPE FIRST: no role record yet (so the old code took the grace branch) plus
# the marker a SIGKILL left behind. That is the combination that printed `WAITING … 274s ago` beside
# `loop: NOT RUNNING`, and it is the one a role-record-only fixture cannot reach.
doc status
case "$OUT" in *WAITING*) bad "status: printed WAITING for a role with no pass under a DEAD loop — $OUT" ;;
              *) ok "status: the measured shape (no pass + stale .running marker) is not WAITING" ;; esac
case "$OUT" in *"still running"*) bad "status: read the killed loop's .running marker as a live pass — $OUT" ;;
              *) ok "status: a killed loop's in-progress marker is not read as a live pass" ;; esac
NOW="$(date +%s)"
for r in reap doctor merge hygiene; do
  printf 'role=%s\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=0\nlast_result=ok\n' "$r" "$NOW" \
    > "$T/o/state/roles/$r.state"
done
doc status
case "$OUT" in *WAITING*) bad "status: printed WAITING under a DEAD loop (the #2306 lie) — $OUT" ;;
              *) ok "status: no row promises WAITING when the loop is gone" ;; esac
case "$OUT" in *"DEAD"*) ok "status: names the rows DEAD" ;; *) bad "status: no DEAD row — $OUT" ;; esac
result_has "pid-gone" && ok "status: names the evidence (pid-gone), not just the verdict" || bad "status: the reason is not named — $OUT"
result_has "last pass" && ok "status: still reports the last pass each role recorded" || bad "status: the last-pass record was lost — $OUT"
[ "$RC" -ne 0 ] && ok "status: a dead loop under a started cell fails the verb (rc=$RC)" || bad "status: rc=0 beside a dead loop"
# ⛔ THE SAME FIXTURE WITH A LIVE LOOP MUST NOT READ DEAD — otherwise the arm above is satisfied by
# "rows are always red" rather than by the liveness check it claims to test.
"$REAL_SLEEP" 30 & LIVE_PID=$!
loop_up "$LIVE_PID"
printf '%s\n' "$(date +%s)" > "$T/o/state/roles/loop.started"
doc status
kill "$LIVE_PID" 2>/dev/null || true
case "$OUT" in *"DEAD"*) bad "status: called a LIVE loop's roles DEAD (the control arm) — $OUT" ;;
              *) ok "status: a live loop's rows are not DEAD (non-vacuity of the arm above)" ;; esac
[ "$RC" -eq 0 ] && ok "status: the live-loop control is clean, so the dead arm is decided by liveness" \
                 || bad "status: the live-loop control failed (rc=$RC) — $OUT"

# ⛔ AN UNREADABLE READ IS NOT A DEATH WITNESS. Each shape below cannot distinguish "gone" from "could
# not tell", so it must abstain: UNKNOWN + rc 3, never WAITING (a promise) and never DEAD (a claim).
say_case "status: unverifiable loop records abstain with a named reason (#2306)"
for shape in unparseable-pid no-identity-record; do
  reset_state; : > "$T/o/state/roles/.desired"; : > "$T/o/logs/doctor.log"
  "$REAL_SLEEP" 30 & LIVE_PID=$!
  case "$shape" in
    unparseable-pid)      printf 'not-a-pid\n' > "$T/o/state/roles/loop.pid" ;;
    no-identity-record)   printf '%s\n' "$LIVE_PID" > "$T/o/state/roles/loop.pid"
                          rm -f "$T/o/state/roles/loop.ident" ;;
  esac
  printf '%s\n' "$(date +%s)" > "$T/o/state/roles/loop.started"
  doc status
  kill "$LIVE_PID" 2>/dev/null || true
  case "$OUT" in *WAITING*) bad "status[$shape]: abstained as WAITING (a promise it cannot make) — $OUT" ;;
                *) ok "status[$shape]: no WAITING row" ;; esac
  case "$OUT" in *DEAD*) bad "status[$shape]: manufactured a death witness from an unreadable read — $OUT" ;;
                *) ok "status[$shape]: does not claim DEAD from an unreadable read" ;; esac
  [ "$RC" -eq 3 ] && ok "status[$shape]: rc=3 (the abstention code, not a pass)" \
                  || bad "status[$shape]: rc=$RC (want 3) — $OUT"
  result_has "UNKNOWN" && ok "status[$shape]: named UNKNOWN" || bad "status[$shape]: no UNKNOWN row — $OUT"
done
reset_state; rm -f "$T/o/state/roles/"*; : > "$T/o/state/roles/.desired"

# ── summary ─────────────────────────────────────────────────────────────────────────────────────
echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then echo "  ❌ $FAIL check(s) failed"; exit 1; fi
echo "  ✅ all checks passed"
