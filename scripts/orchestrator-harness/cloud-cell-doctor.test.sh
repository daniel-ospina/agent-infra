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
export DOCTOR_SLEEP_BIN="$T/bin/sleep"
export DOCTOR_TEST_TMUX="$T/tmux" DOCTOR_TEST_PS="$T/ps" DOCTOR_TEST_GH="$T/gh"
export REAP_MIN_S=60 REAP_SAMPLE_S=2 DOCTOR_INTERVAL=1 MERGE_INTERVAL=1 HYGIENE_INTERVAL=1
export MERGE_RETRY_S=3600 CONTROLLER_STALE_S=60
mkdir -p "$T/gh" "$T/rail" "$T/sup" "$T/wt" "$T/uv"

doc() { # <role> [extra env assignments via env]
  OUT="$(bash "$DOCTOR" "$@" 2>&1)"; RC=$?
}
reset_tmux() { rm -f "$T/tmux/sessions" "$T/tmux/killed" "$T/tmux/new-session"; touch "$T/tmux/sessions"; }
reset_ps()   { rm -f "$T/ps/calls" "$T/ps/mode" "$T/ps/args."* "$T/ps/lstart."*; }
reset_state(){ rm -rf "$T/o/state"; mkdir -p "$T/o/state/roles"; }
mk_lane() { # <name> <pid> [<log-age-touch>]
  printf '%s\n' "$1" >> "$T/tmux/sessions"
  printf '%s\n' "$2" > "$T/tmux/panes/$1"
  : > "$T/o/logs/$1.log"
  touch -t 202001010000 "$T/o/logs/$1.log"
  printf '%s 1 00:00:10\n' "$2" > "$T/ps/table"
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
result_has "no readable log" && ok "reap: names the reason (no log)" || bad "reap: log reason not recorded — $OUT"

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
printf '%s\n' "$GRACE_PID" > "$T/o/state/roles/loop.pid"
printf '%s\n' "$(date +%s)" > "$T/o/state/roles/loop.started"
doc status
kill "$GRACE_PID" 2>/dev/null || true
[ "$RC" -eq 0 ] && result_has "WAITING" \
  && ok "status: a freshly started loop WAITS instead of failing its roles" \
  || bad "status: a fresh loop failed its roles (rc=$RC) — $OUT"
"$REAL_SLEEP" 60 & GRACE_PID=$!
printf '%s\n' "$GRACE_PID" > "$T/o/state/roles/loop.pid"
printf '%s\n' "$(( $(date +%s) - 100000 ))" > "$T/o/state/roles/loop.started"
doc status
kill "$GRACE_PID" 2>/dev/null || true
[ "$RC" -ne 0 ] && result_has "NEVER RAN" \
  && ok "status: past the grace window, a role that never passed FAILS" \
  || bad "status: an old loop with no passes did not fail (rc=$RC) — $OUT"
rm -f "$T/o/state/roles/loop.started" "$T/o/state/roles/loop.pid"

# A live loop pid + one recent pass per role = healthy.
"$REAL_SLEEP" 60 & LOOP_PID=$!
printf '%s\n' "$LOOP_PID" > "$T/o/state/roles/loop.pid"
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
kill -TERM "$LOOP_PID" 2>/dev/null || true; LOOP_PID=""

# ── 12) HYGIENE: the package cache is pruned; worktrees are armed only under pressure ───────────
say_case "hygiene: uv cache prune runs; the worktree reaper is gated"
reset_state; rm -f "$T/uv/uv-calls" "$T/wt/calls"
export DOCTOR_TEST_UV="$T/uv" DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt"
doc hygiene
grep -q 'cache prune' "$T/uv/uv-calls" 2>/dev/null && ok "hygiene: ran 'uv cache prune' (not 'cache clean')" \
  || bad "hygiene: did not prune the package cache — $(cat "$T/uv/uv-calls" 2>/dev/null)"
grep -q -- '--dry-run' "$T/wt/calls" 2>/dev/null && ok "hygiene: a healthy disk leaves the worktree reaper in DRY-RUN" \
  || bad "hygiene: worktree reaper mode wrong — $(cat "$T/wt/calls" 2>/dev/null)"

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
