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

mkdir -p "$T/home" "$T/o/logs" "$T/repo" "$T/bin" "$T/tmux/panes" "$T/tmux/clients" "$T/ps" "$T/tmp"
# ⛔ $T/repo MUST BE A REAL CHECKOUT (agent-infra#2573). The cache sweep enumerates worktree roots with
# `git worktree list`, and an EMPTY-enumeration read is cannot-verify (rc=3) by design — so on a plain
# directory every hygiene arm here would assert against a pass that abstained instead of deciding.
git init -q "$T/repo" 2>/dev/null || true

# ⛔ THE HYGIENE ROLE'S NEW SINKS ARE STUBBED IN THIS FIXTURE (agent-infra#2573). The doctor now reaps
# stale `cloud-cell-*` dirs under $TMPDIR and prunes IDLE docker images/volumes, and a suite that left
# those seams pointed at the HOST would delete a fixture of the operator's and run a real
# `docker image prune -af` on every green run. Both decisions are driven, on real fixtures, by
# `cloud-cell-doctor.hygiene.test.sh`; here they point at throwaway paths so no arm can reach the box.
export HYGIENE_TMP_DIR="$T/tmp"
# ⛔ …AND THE CWD CENSUS IS A SINK TOO (review round 7, P2). `live-ownership.sh` reads the RUNNER's real
# process table, so a fixture that left `LO_CWD_PROBE` pointing at the host would make the hygiene pass
# cannot-verify (rc=3) on any runner whose process table it cannot read — a false red about the platform
# that says nothing about the code. The sibling hardening fixture pins it for the same reason; this one
# previously pinned only the temp root and docker, so it was the one seam left on the host.
cat > "$T/bin/cwdprobe" <<'SH'
#!/bin/bash
emit() { [ -n "$1" ] || return 0; printf '/proc/4242/cwd -> %s\n' "$1"; printf 'p4242\nn%s\n' "$1"; }
emit "$FAKE_CWD"
exit 0
SH
chmod +x "$T/bin/cwdprobe"
export LO_CWD_PROBE="$T/bin/cwdprobe" FAKE_CWD="$T/nowhere-unheld"
cat > "$T/bin/docker-stub" <<'SH'
#!/bin/bash
# `info` MUST succeed, or the sweep correctly reports "no daemon" and the arms around it stop being
# about what they claim. The two prunes are no-ops: nothing here may touch a real daemon.
case "${1:-}" in
  info)    printf 'Server Version: stub\n'; exit 0 ;;
  version) printf '29.1.3\n'; exit 0 ;;   # the volume verb is version-gated; a stub must answer it
esac
exit 0
SH
chmod +x "$T/bin/docker-stub"
export DOCTOR_DOCKER_BIN="$T/bin/docker-stub"

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
  # `etime=` — the lock-owner AGE read `service_controller_present` now performs (review P2, #2402).
  # Default is 100 days, i.e. "this process began long before any lock" — the pre-fix reading, so an
  # arm that wants a RECYCLED pid must say so explicitly with `$S/etime.<pid>`.
  if [ "$fmt" = "etime=" ]; then
    if [ -f "$S/etime.$pid" ]; then cat "$S/etime.$pid"; else printf '100-00:00:00\n'; fi
    exit 0
  fi
  if [ -f "$S/args.$pid" ]; then cat "$S/args.$pid"; else printf '1 (init)\n'; fi
  exit 0
fi
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

# lane-reap (#2163): a DOUBLE, so this suite asserts the DELEGATION (and the census in the pass
# line) without letting a second reaper loose on the fixture's process table. lane-reap.sh has its
# own hermetic suite; this file's contract is "the doctor schedules it with the right posture".
cat > "$T/bin/lane-reap" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_LANE_REAP:?}"
printf '%s\n' "$*" >> "$S/calls"
case "${1:-}" in
  # ⛔ The two answers carry DIFFERENT tokens (#2163 review, P2). When both printed
  # `lanes=1/2 zombie=0`, deleting the `count` call would still leave the census assertion green —
  # a check that could not go red. `count` is the only producer of `lanes=`; `reap` says `trees=`.
  # DOCTOR_TEST_REAP_CENSUS=unreadable models the abstention the DOCTOR must escalate on: the reaper
  # could not take the read, so it prints `?` and exits 3. DOCTOR_TEST_REAP_CENSUS=garble models the
  # OTHER classifier arm (`*)` in cloud-cell-doctor.sh:936): output that does not parse as a census at
  # all — what an unexecutable tool or the `bounded 60` SIGKILL actually produce. Both arms were
  # untested before #2163 review cycle 6/7 (cycle 7 found the catch-all still unpinned).
  count) case "${DOCTOR_TEST_REAP_CENSUS:-}" in
           unreadable) printf 'lanes=?/? zombie=?\n'; exit 3 ;;
           garble)     printf 'cannot read the lane census\n'; exit 0 ;;
         esac
         printf 'lanes=3/7 zombie=2\n' ;;
  # DOCTOR_TEST_REAP_ABSTAIN models a pass that could not JUDGE every tree: the reaper's own
  # `abstained=` counter is the only token that distinguishes it from an idle one.
  # DOCTOR_TEST_REAP_INERT models the CELL shape: a pass that judged NO tree while refusing every
  # lane it found by POLICY (`trees=0/0 … refused=1 inert=1 abstained=0`). That line is the one the
  # doctor recorded as a healthy reaper, every pass, for ever.
  # DOCTOR_TEST_REAP_TREES models the OTHER shape the reaper calls clean — a pass that DID judge
  # trees and refused a human-owned lane beside them (`trees=0/1 … inert=1`, exit 0). `inert=` is a
  # POLICY count, so the doctor must escalate the INERT PASS (nothing judged), never the field alone.
  # DOCTOR_TEST_REAP_REFUSAL adds the per-tree refusal LINE, which `tail -1` used to discard.
  reap)  [ -n "${DOCTOR_TEST_REAP_REFUSAL:-}" ] && printf '  REFUSE root=99 log=/x/L-a.log — %s\n' "$DOCTOR_TEST_REAP_REFUSAL"
         printf 'lane-reap: trees=%s zombie=0 candidates=0 reaped=0 refused=1 inert=%s unidentifiable=%s abstained=%s mode=%s\n' \
           "${DOCTOR_TEST_REAP_TREES:-1/2}" "${DOCTOR_TEST_REAP_INERT:-0}" "${DOCTOR_TEST_REAP_UNIDENT:-0}" "${DOCTOR_TEST_REAP_ABSTAIN:-0}" "$([ "${2:-}" = "--apply" ] && echo apply || echo dry-run)" ;;
esac
exit 0
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
export DOCTOR_LANE_REAP_BIN="$T/bin/lane-reap" DOCTOR_TEST_LANE_REAP="$T/lane-reap"
export REAP_MIN_S=60 REAP_SAMPLE_S=2 DOCTOR_INTERVAL=1 MERGE_INTERVAL=1 HYGIENE_INTERVAL=1
export MERGE_RETRY_S=3600 CONTROLLER_STALE_S=60
# ⛔ HERMETIC BY DEFAULT: the hygiene role's registry sub-step resolves the SHIPPED `registry-sync.sh`
# beside this suite, and exec'ing the real verb from every hygiene case would make two real round
# trips to github.com per pass — and, worse, pull the fleet's LIVE records into each fixture's
# `$CELL_HOME` (the same defect `ATOMIC_LAND_REGISTRY_SYNC` exists to prevent in tests/atomic-land).
# The cases that DO exercise the registry set it back to a fixture script and a fixture store.
export DOCTOR_REGISTRY_SYNC=off
# Same reason, one variable over: `AGENT_INFRA_PATH` is set for real in the operator's (and CI's)
# environment, so a case that does not name `HARNESS_REPO` would silently resolve the CHECKOUT'S OWN
# agent-infra remote as the store and do a real union against github (measured: a 300 s real fetch
# from the case that deliberately leaves every candidate unset).
# `HARNESS_PIN_DIR` is in every cell controller's env (harness-refresh.sh), and it is the THIRD
# store candidate — leaving it ambient let the "non-agent-infra origin is refused" case fall through to
# a real checkout and do a real union (measured by a reviewer). Neutralised for the same reason.
export AGENT_INFRA_PATH= HARNESS_PIN_DIR=
mkdir -p "$T/gh" "$T/rail" "$T/sup" "$T/wt" "$T/uv" "$T/lane-reap"

doc() { # <role> [extra env assignments via env]
  OUT="$(bash "$DOCTOR" "$@" 2>&1)"; RC=$?
}
reset_tmux() { rm -f "$T/tmux/sessions" "$T/tmux/killed" "$T/tmux/new-session"; touch "$T/tmux/sessions"; }
reset_ps()   { rm -f "$T/ps/calls" "$T/ps/mode" "$T/ps/args."* "$T/ps/lstart."* "$T/ps/etime."*; }
reset_state(){ rm -rf "$T/o/state"; mkdir -p "$T/o/state/roles" "$T/lane-reap"; rm -f "$T/lane-reap/calls"; }
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
# #2163: the same pass must SCHEDULE the process reaper, and its census must be in the pass line.
grep -qx 'reap --apply' "$T/lane-reap/calls" 2>/dev/null && ok "reap: delegated the process pass ARMED (reap --apply)" || bad "reap: the process pass was not delegated armed — $(cat "$T/lane-reap/calls" 2>/dev/null)"
grep -qx 'count' "$T/lane-reap/calls" 2>/dev/null && ok "reap: read the evidence census (count)" || bad "reap: the census was not read"
result_has "lanes=3/7 zombie=2" && ok "reap: the pass line carries the CENSUS (lanes=<live>/<total> zombie=<n>)" || bad "reap: the census is missing from the pass line — $OUT"
result_has "trees=1/2" && ok "reap: the process pass's own line is in the pass line too" || bad "reap: the process pass result is missing — $OUT"

# ── 1a2) an ABSTAINING process pass is unverifiable, not a quiet pass ──────────────────────────
# ⛔ `reaped=0 refused=0` over trees the reaper could not judge is not "nothing to do" (#2163
# review, P2). Only the literal `CANNOT-VERIFY` token used to escalate, so the reaper's own
# `abstained=` counter — the one field that says a safety read failed — never reached the pass rc.
say_case "a process pass that ABSTAINED is unverifiable (rc=3), not an idle pass"
reset_tmux; reset_ps; reset_state
mk_lane lane-42 4242
DOCTOR_TEST_REAP_ABSTAIN=2 doc reap
grep -qx 'reap --apply' "$T/lane-reap/calls" 2>/dev/null && ok "reap-abstain: the pass was still delegated" || bad "reap-abstain: the process pass was not delegated — $(cat "$T/lane-reap/calls" 2>/dev/null)"
[ "$RC" -eq 3 ] && ok "reap-abstain: rc=3 (a safety read failed)" || bad "reap-abstain: rc=$RC — an abstaining pass read as clean — $OUT"
result_has "abstained=2" && ok "reap-abstain: the abstention count is in the pass line" || bad "reap-abstain: the abstention count is missing — $OUT"

# ── 1a2b) an UNREADABLE census is unverifiable, not a clean pass ────────────────────────────────
# ⛔ THE DOCTOR'S OWN ARM (#2163 review, cycle 6). `DOCTOR_TEST_REAP_ABSTAIN`/`INERT`/`TREES` drive the
# REAP PASS line's fields; nothing drove the `count` read, so the ONE `pass_rc=3` the census classifier
# owns (`cloud-cell-doctor.sh:940`, the `?-numerator` arm — the catch-all above it REWRITES only) left
# this suite green and an unreadable census
# rendered as `lanes=?/? zombie=?` at rc=0 — the exact false PASS the arm's own comment names.
say_case "an UNREADABLE lane census is cannot-verify (rc=3), never a clean pass"
reset_tmux; reset_ps; reset_state
mk_lane lane-42 4242
DOCTOR_TEST_REAP_CENSUS=unreadable doc reap
[ "$RC" -eq 3 ] && ok "census-abstain: rc=3 (the census could not be read)" || bad "census-abstain: rc=$RC — an unreadable census read as a clean pass — $OUT"
result_has "lanes=?/?" && ok "census-abstain: the pass line says ?/? rather than a fabricated 0" || bad "census-abstain: the census is not reported as unknown — $OUT"
result_has "unverifiable=1 failed=" && ok "census-abstain: ONE failed read is counted ONCE" || bad "census-abstain: the abstention count is wrong (one failed read must read unverifiable=1) — $OUT"
grep -qx 'count' "$T/lane-reap/calls" 2>/dev/null && ok "census-abstain: the census was actually READ (the leg is not vacuous)" || bad "census-abstain: no count call — this arm cannot have fired"

# …and the OTHER classifier arm: output that is not a census AT ALL (an unexecutable tool, the
# `bounded 60` SIGKILL) must take the `*)` catch-all to the same rc=3 — #2163 review cycle 7 found
# that arm still unpinned. ⛔ WHAT IS LOAD-BEARING (each number MEASURED, not inferred):
#   • at the PRE-FIX head (71edb272) removing the catch-all's own `pass_rc=3` alone left it 185/0;
#   • at THIS head that assignment no longer exists, so the single remaining one (`:940`) is the
#     load-bearing escalation — reverting it turns the suite 185 PASS / 2 FAIL (both census legs red);
#   • `unverifiable=1` for ONE failed read is pinned because the two arms counting it separately made
#     a single garbled read read as `unverifiable=2` (cycle 8, fixed in the doctor) — restoring that
#     increment turns the suite 186 PASS / 1 FAIL.
say_case "a GARBLED census read is cannot-verify (rc=3), not a clean pass"
reset_tmux; reset_ps; reset_state
mk_lane lane-42 4242
DOCTOR_TEST_REAP_CENSUS=garble doc reap
[ "$RC" -eq 3 ] && ok "census-garble: rc=3 (the read did not parse)" || bad "census-garble: rc=$RC — a garbled read read as a clean pass — $OUT"
result_has "lanes=?/?" && ok "census-garble: the pass line says ?/? rather than a fabricated 0" || bad "census-garble: the census is not reported as unknown — $OUT"
result_has "unverifiable=1 failed=" && ok "census-garble: ONE garbled read is counted ONCE (not twice, #2163 cycle 8)" || bad "census-garble: a single garbled read was over-counted — $OUT"
grep -qx 'count' "$T/lane-reap/calls" 2>/dev/null && ok "census-garble: the census was actually READ (the leg is not vacuous)" || bad "census-garble: no count call — this arm cannot have fired"

# ── 1a3) a process pass that judged NOTHING is unverifiable, not a health record ──────────────
# ⛔ THE CELL SHAPE (#2163 review r3, P2). On a cell every lane is `ancestry-unknown`, so the armed
# pass judged ZERO trees while refusing all of them: `trees=0/0 … refused=1 abstained=0 mode=apply`,
# rc 0 — and `state_write reap 0` recorded a HEALTHY reaper every pass, from an instrument that is
# inert there by design. `abstained=` cannot see it (nothing failed to read; a policy decided), so
# the reaper counts it in `inert=` and this role records that shape as its OWN verdict.
say_case "a process pass that judged NOTHING (inert) is a POLICY verdict (rc=4), never a clean pass"
reset_tmux; reset_ps; reset_state
mk_lane lane-42 4242
DOCTOR_TEST_REAP_TREES=0/0 DOCTOR_TEST_REAP_INERT=2 doc reap
[ "$RC" -eq 4 ] && ok "reap-inert: rc=4 (a POLICY verdict, not cannot-verify)" || bad "reap-inert: rc=$RC — an inert pass read as clean or as a failed read — $OUT"
result_has "inert=2" && ok "reap-inert: the inert count is in the pass line" || bad "reap-inert: the inert count is missing — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")" = "4" ] \
  && ok "reap-inert: state records rc=4 (never a healthy 0, never a failed 3)" \
  || bad "reap-inert: state last_rc is $(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")"

# ── 1a4) an inert count on a pass that DID judge trees is CLEAN, not a failed pass ────────────
# ⛔ ONE INERT LANE IS NOT A FAILED PASS (#2163 review r4, P2). `inert=` is a POLICY count, not a
# failure: `lane-reap.sh` returns 4 only when `total == 0 && inert > 0` and returns 0 when it judged
# lanes while refusing a human-owned one beside them (its own `INERT-MIXED` leg pins that). The
# doctor's `*inert=[!0]*` arm escalated ANY non-zero `inert=`, so on a box with one human-owned or
# `ancestry-unknown` lane it wrote `reap FAILED` every pass over a pass the reaper calls clean
# — the mirror of the r3 bug, one field too wide.
say_case "a policy refusal beside a JUDGED lane is not a failed pass (rc=0)"
reset_tmux; reset_ps; reset_state
mk_lane lane-42 4242
DOCTOR_TEST_REAP_TREES=0/1 DOCTOR_TEST_REAP_INERT=1 doc reap
[ "$RC" -eq 0 ] && ok "reap-inert-mixed: rc=0 (a judged lane keeps the pass clean)" || bad "reap-inert-mixed: rc=$RC — a clean pass was recorded as FAILED — $OUT"
result_has "inert=1" && ok "reap-inert-mixed: the refusal is still REPORTED in the pass line" || bad "reap-inert-mixed: the inert count is missing — $OUT"
result_has "trees=0/1" && ok "reap-inert-mixed: …beside the tree that WAS judged" || bad "reap-inert-mixed: the judged-tree count is missing — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")" = "0" ] \
  && ok "reap-inert-mixed: state records the HEALTHY pass" \
  || bad "reap-inert-mixed: state last_rc is $(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state") — a clean pass recorded as failed"
# ── 1a4b) a policy-inert reap is INERT, not FAILED — the health verb stays GREEN ───────────────
# ⛔ THE PERMANENT RED (#2163 review r8, P1). On a Linux CELL every armed pass is policy-inert
# (`ancestry-unknown`, §11.4), so recording it as `FAILED` made `cloud-cell-supervisor.sh status` exit
# 1 for ever on a healthy cell, and `[ "$rrc" -eq 0 ] && rrc=1` collapsed a genuine restart failure
# into the same number. The verdict is NAMED (never a silent green) and it does not fail the verb.
say_case "a policy-inert reap is reported INERT (rc=4) and does not red the health verb"
reset_tmux; reset_ps; reset_state
mk_lane lane-42 4242
DOCTOR_TEST_REAP_TREES=0/0 DOCTOR_TEST_REAP_INERT=2 doc reap
[ "$RC" -eq 4 ] && ok "reap-inert: the reap pass is rc=4" || bad "reap-inert: rc=$RC — $OUT"
: > "$T/o/state/roles/.desired"
"$REAL_SLEEP" 30 & SP_PID=$!
loop_up "$SP_PID"
NOW0="$(date +%s)"
for r in doctor merge hygiene; do
  printf 'role=%s\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=0\nlast_result=ok\n' "$r" "$NOW0" > "$T/o/state/roles/$r.state"
done
doc status
[ "$RC" -eq 0 ] && ok "status: a cell whose only non-zero role is a policy-inert reap is GREEN" \
  || bad "status: rc=$RC — a working policy reddened the cell — $OUT"
result_has "INERT" && ok "status: …and the row NAMES the verdict (never a silent green)" \
  || bad "status: the policy verdict is not named — $OUT"
# …and the staleness bound still applies: a reaper that STOPPED passing is not hidden by rc=4.
printf 'role=reap\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=4\nlast_result=inert-pass\n' "$(( NOW0 - 100000 ))" > "$T/o/state/roles/reap.state"
doc status
[ "$RC" -ne 0 ] && result_has "STALE" \
  && ok "status: a policy-inert reaper that stopped passing reads STALE, not healthy" \
  || bad "status: rc=$RC — an ancient rc=4 pass read as current — $OUT"
kill "$SP_PID" 2>/dev/null || true; SP_PID=""
rm -f "$T/o/state/roles/.desired"

# ── 1a4c) a policy verdict never OVERWRITES a stored cannot-verify (rehearsal) ──────────────────
# ⛔ rc=4 IS A POLICY VERDICT, NOT A SEVERITY (#2163 review r8, P1). "Keep whichever rc is larger"
# ranked a rehearsal's 4 above a stored 3 — and above a stored 1 — so a dry run recorded INERT over a
# failure that was still true. Only a FAILING rc may supersede; a clean 0 never clears a failure.
say_case "a policy-inert rehearsal does not overwrite a stored cannot-verify"
reset_tmux; reset_ps; reset_state
mk_lane lane-42 4242
printf 'role=reap\nlast_pass_at=x\nlast_pass_epoch=%s\npasses=1\nlast_rc=3\nlast_result=cannot-verify: session list unreadable\n' "$(date +%s)" > "$T/o/state/roles/reap.state"
DOCTOR_TEST_REAP_TREES=0/0 DOCTOR_TEST_REAP_INERT=2 doc reap --dry-run
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")" = "3" ] \
  && ok "rehearsal: the stored cannot-verify SURVIVES a policy-inert rehearsal" \
  || bad "rehearsal: the rehearsal overwrote rc=3 with $(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")"

# ── 1a5) an UNUSABLE PIPE IDENTITY is escalated, but its cause names IDENTITY ─────────────────
# ⛔ A READABLE BOX IS NOT A BLIND ONE (#2163 review r5, P3). `unidentifiable=` counts trees the
# reaper could not judge because its platform prints no per-pipe name for an anonymous pipe — every
# READ succeeded. It used to arrive as `abstained=`, whose only cause line said "the descriptors
# could not be read", so `reap FAILED rc=3` sent the operator after an lsof/permissions fault that
# never happened. It must still ESCALATE (it is an abstention), and the cause must name identity.
say_case "an unidentifiable pipe identity escalates with an IDENTITY cause, not a blind read"
reset_tmux; reset_ps; reset_state
mk_lane lane-42 4242
: > "$T/o/logs/doctor.log"
DOCTOR_TEST_REAP_UNIDENT=1 \
  DOCTOR_TEST_REAP_REFUSAL="pipe-identity-unusable (the descriptors WERE read; this platform prints no per-pipe name, so a tee beside the tree cannot be shown to be its own writer)" \
  doc reap
[ "$RC" -eq 3 ] && ok "reap-unident: rc=3 (an abstention never reads as a clean pass)" || bad "reap-unident: rc=$RC — an identity abstention read as clean — $OUT"
result_has "unidentifiable=1" && ok "reap-unident: the identity counter is in the pass line" || bad "reap-unident: the identity counter is missing — $OUT"
grep -q 'proc-first:.*pipe-identity-unusable' "$T/o/logs/doctor.log" 2>/dev/null \
  && ok "reap-unident: [reap] names IDENTITY as the cause" \
  || bad "reap-unident: the cause never reached [reap] — $(grep '\[reap\]' "$T/o/logs/doctor.log" 2>/dev/null | tail -2)"
if grep -q 'descriptors could not be read' "$T/o/logs/doctor.log" 2>/dev/null; then
  bad "reap-unident: a cause line claims a BLIND READ on a box where every read succeeded"
else
  ok "reap-unident: …and no cause line claims a blind read"
fi
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")" = "3" ] \
  && ok "reap-unident: state records the FAILED pass" \
  || bad "reap-unident: state last_rc is $(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state") — a failed pass recorded as healthy"

# ⛔ AND THE REASON REACHES THE LOG (#2163 review r3, P2). `tail -1` kept the summary and threw away
# every per-tree reason, so `[reap]` could not say WHY nothing was judged — and a refusal was
# indistinguishable from an idle box.
say_case "the first per-tree refusal reaches the doctor's reap log"
reset_tmux; reset_ps; reset_state
mk_lane lane-42 4242
: > "$T/o/logs/doctor.log"
DOCTOR_TEST_REAP_REFUSAL="ancestry-unknown (no positive fleet evidence in the chain)" doc reap
result_has "ancestry-unknown" && ok "reap-reason: the refusal line is in the pass line" || bad "reap-reason: the refusal line is missing — $OUT"
grep -q 'proc-first:.*ancestry-unknown' "$T/o/logs/doctor.log" 2>/dev/null \
  && ok "reap-reason: [reap] logs the FIRST refusal, not only the summary" \
  || bad "reap-reason: the refusal never reached [reap] — $(grep '\[reap\]' "$T/o/logs/doctor.log" 2>/dev/null | tail -2)"

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

# ⛔ THE SERVICE MANAGER OWNS A CONTROLLER IT HAS STOPPED (review P1, #2402). A deliberate
# `systemctl stop` leaves `.desired` in place, so this pass still reaches the ABSENT→restart arm; the
# supervisor answers rc 4 instead of re-arming the unit. Folding that into the FAILED arm would redden the
# pass over the operator's own decision (and log "restart FAILED" every 120 s on a cell that is correctly
# stopped), while folding it into the success arm would claim a restart that never happened.
reset_tmux; reset_ps; reset_state; rm -f "$T/sup/calls"
: > "$T/o/state/roles/.desired"; rm -f "$T/o/.orch.lock" "$T/o/heartbeat"
printf '4\n' > "$T/sup/rc"
doc doctor; RC4="$RC"
rm -f "$T/sup/rc"
grep -q 'start' "$T/sup/calls" 2>/dev/null && ok 'doctor: the restart was attempted through the supervisor' \
  || bad "doctor: never called the supervisor — the rc=4 arm cannot be reached: $OUT"
case "$OUT" in
  *'controller restart not launched'*) ok 'doctor: rc=4 is recorded as NOT LAUNCHED (service-managed), not as a failure' ;;
  *) bad "doctor: rc=4 was not reported as a service-managed non-restart: $OUT" ;;
esac
case "$OUT" in
  *'restart FAILED'*) bad 'doctor: reported a FAILED restart for a unit the manager deliberately stopped' ;;
  *) ok 'doctor: a deliberate unit stop is not counted against the pass' ;;
esac
[ "$RC4" -eq 0 ] \
  && ok 'doctor: the pass stays clean when the manager owns a stopped controller (rrc unchanged)' \
  || bad "doctor: a service-managed non-restart reddened the pass (rc=$RC4) — the operator's stop would read as a doctor failure"

# ⛔ A UNIT THAT CONVERGED TO `failed` IS NOT A CLEAN PASS (review P1 round 11, #2402). The supervisor used to
# answer the SAME rc 4 for a deliberate `systemctl stop` and for a start limit that converged to `failed`, and
# this pass recorded both as clean — so a STARTED cell whose unit had given up (no dispatcher, `.desired`
# present) exited 0 and read healthy, which is the false green #2402 removes, one layer in. rc 5 now carries
# that state and must redden the pass. RED on revert: fold rc 5 into the rc-4 arm and RC5 drops back to 0.
reset_tmux; reset_ps; reset_state; rm -f "$T/sup/calls"
: > "$T/o/state/roles/.desired"; rm -f "$T/o/.orch.lock" "$T/o/heartbeat"
printf '5\n' > "$T/sup/rc"
doc doctor; RC5="$RC"
rm -f "$T/sup/rc"
case "$OUT" in
  *'CONVERGED TO FAILED'*) ok 'doctor: rc=5 is reported as a unit that converged to FAILED (no dispatcher), not as a clean non-restart' ;;
  *) bad "doctor: rc=5 was not reported as the failed-unit state: $OUT" ;;
esac
[ "$RC5" -ne 0 ] \
  && ok 'doctor: a started cell whose dispatcher is gone because the unit FAILED is NOT a clean pass (rc is non-zero)' \
  || bad 'doctor: recorded a CLEAN pass over a started cell with NO dispatcher (the unit FAILED) — exactly the false green this change removes'
case "$OUT" in
  *'restart FAILED'*) bad 'doctor: borrowed the generic restart-FAILED wording for a unit that never accepted a start' ;;
  *) ok 'doctor: the failed-unit outcome has its own wording (an operator can tell it from a transient)' ;;
esac

# ⛔ THE rc-5 ARM CARRIES ITS OWN SLOT, AND THE SLOT IS DISCRIMINATED (#2163 review r8, P1). The arm
# used `[ "$rrc" -eq 0 ] && rrc=1` — it only ever RAISED a zero — so a nested reap that recorded
# cannot-verify (3) swallowed a unit that had CONVERGED TO FAILED and the pass said "cannot verify"
# over a cell with NO dispatcher. `[ "$RC5" -ne 0 ]` above cannot see that: it passes for 1 AND 3, so
# a revert to the old shape keeps the suite green. This leg pins the SLOT: rc=5 + an abstaining reap
# must be rc=1, not 3. RED on revert: fold rc 5 back into `[ "$rrc" -eq 0 ] && rrc=1` and RC5A becomes 3.
say_case "a FAILED unit OUTRANKS a nested reap's cannot-verify (rc=5 + abstain -> rc=1, not 3)"
reset_tmux; reset_ps; reset_state; rm -f "$T/sup/calls"
: > "$T/o/state/roles/.desired"; rm -f "$T/o/.orch.lock" "$T/o/heartbeat"
printf '5\n' > "$T/sup/rc"
mk_lane lane-42 4242
DOCTOR_TEST_REAP_ABSTAIN=2 doc doctor; RC5A="$RC"
rm -f "$T/sup/rc"
# ⛔ PIN THE PRECONDITION, or the leg cannot tell "the slot held" from "there was nothing to hold":
# if the abstain plumbing ever stops reaching the doctor's nested reap, `rrc` is 0 and BOTH the old and
# the new shape yield 1 — the pin would decay silently. The stored reap row is the measurable datum
# (the doctor truncates the nested result to 160 chars, so `abstained=` is NOT readable from $OUT).
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")" = "3" ] \
  && ok 'doctor: precondition — the nested reap recorded cannot-verify (3)' \
  || bad "doctor: the nested reap did NOT record cannot-verify (last_rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/reap.state")) — this leg proves nothing about dominance"
[ "$RC5A" -eq 1 ] \
  && ok 'doctor: a FAILED unit records rc=1 even when the nested reap is cannot-verify (3)' \
  || bad "doctor: the nested reap's cannot-verify swallowed the FAILED unit (rc=$RC5A, want 1) — the exact defect this arm's own comment names"
# ⛔ THE *RECORDED PASS LINE* IS THE ARTIFACT, not the log echo: `result=` carries `unit FAILED — no
# dispatcher`, while `CONVERGED TO FAILED` is log-only wording. Asserting the log token alone cannot
# see a dropped `result` — the row is what a later reader/sweep reads.
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/doctor.state")" in
  *'unit FAILED'*) ok 'doctor: …and the RECORDED pass line still names the unit FAILED (not just the log)' ;;
  *) bad "doctor: the FAILED unit is missing from the recorded pass line — $(sed -n 's/^last_result=//p' "$T/o/state/roles/doctor.state")" ;;
esac
case "$OUT" in
  *'CONVERGED TO FAILED'*) ok 'doctor: …and the operator-facing log names it CONVERGED TO FAILED' ;;
  *) bad "doctor: the FAILED unit vanished from the log — $OUT" ;;
esac

# ⛔ A LIVE LOOP RECORD IS NOT A LIVE CONTROLLER (review P0, #2402). The pre-fix
# `service_controller_present` fell back to `loop_alive`, which reads the DOCTOR's own loop.pid — a
# tautology in `loop` mode (the only mode a cell runs), so a cell whose controller had DIED read
# `controller RUNNING (no heartbeat recorded yet)`, the ABSENT→restart arm below was unreachable, and the
# doctor never restarted it. This arm fakes exactly that state: a live, identity-matched loop record and
# NO controller (no session, no lock owner, no heartbeat). The restart MUST still be launched.
reset_tmux; reset_ps; reset_state
rm -f "$T/sup/calls"; : > "$T/o/state/roles/.desired"; rm -f "$T/o/.orch.lock" "$T/o/heartbeat"
loop_up "$$"
doc doctor
grep -q 'start' "$T/sup/calls" 2>/dev/null && ok "doctor: the doctor's own loop record does not witness a controller — a missing one is still restarted" \
  || bad "doctor: reported a controller RUNNING from its OWN loop pid and did NOT restart it — $OUT"
rm -f "$T/o/state/roles/loop.pid" "$T/o/state/roles/loop.ident"

# ⛔ THE LOCK OWNER IS THE AUTHORITY, AND ITS **AGE** IS PART OF THE CLAIM (review P2, #2402).
# `lock_controller_pid` carries the shape AND the age for a written reason: `$O/.orch.lock` is data on
# disk that outlives a `kill -9`, so the OS can RECYCLE that pid onto a peer repo's controller — and on
# this box a peer repo's controller has the SAME basename from the SAME shared harness path, so the
# shape alone matches. These two arms drive the age half through the ps stub: the pid here is the
# test shell's own (so `kill -0` succeeds and the shape matches), and only `etime` differs.
say_case "doctor: the lock owner's AGE decides — a recycled pid is not this cell's controller"
reset_tmux; reset_ps; reset_state
rm -f "$T/sup/calls" "$T/o/heartbeat"; : > "$T/o/state/roles/.desired"
printf '%s\n' "$$" > "$T/o/.orch.lock"
printf 'bash /x/harness/orch-loop.sh\n' > "$T/ps/args.$$"
# (a) it began 30s ago and the lock was written just now → it IS the lock's owner → no restart.
printf '00:00:30\n' > "$T/ps/etime.$$"
doc doctor
[ -s "$T/sup/calls" ] && bad "doctor: restarted over a lock owner that provably began BEFORE the lock — $OUT" \
  || ok "doctor: a live lock owner that began before the lock is the controller (no restart)"
result_has "RUNNING" && ok "doctor: reports the service-managed controller as RUNNING" \
  || bad "doctor: did not report the service-managed controller — $OUT"
# (b) SAME pid, SAME argv, a lock written in 2020 and a process that began 10s ago → the pid was
#     RECYCLED onto a peer repo's controller. Reporting RUNNING here is the "witness that cannot say no"
#     (the arm above this one), and it makes the ABSENT→restart arm unreachable on a dead controller.
#     Without the age rule this arm FAILS: the shape matches, so the pre-fix read returned 0.
touch -t 202001010000 "$T/o/.orch.lock"
printf '00:00:10\n' > "$T/ps/etime.$$"
rm -f "$T/sup/calls"
doc doctor
grep -q 'start' "$T/sup/calls" 2>/dev/null && ok "doctor: a RECYCLED pid (began after the lock was written) does not witness a controller — it is restarted" \
  || bad "doctor: a recycled pid that began AFTER the lock was written was accepted as this cell's controller and the dead one was NOT restarted — $OUT"
# (c) an UNREADABLE age (the ps seam cannot answer) is not ownership either: same safe direction. The
#     stub answers `etime=` with an EMPTY body, which is what a ps that cannot compute the age returns.
#     The argv stub is re-created FIRST: `reset_ps` clears it too, and without it this arm passes on the
#     shape mismatch instead — which is already covered, so it would prove nothing about the age.
reset_ps
printf 'bash /x/harness/orch-loop.sh\n' > "$T/ps/args.$$"
: > "$T/ps/etime.$$"
rm -f "$T/sup/calls"
touch "$T/o/.orch.lock"
doc doctor
grep -q 'start' "$T/sup/calls" 2>/dev/null && ok "doctor: an UNREADABLE lock-owner age is NOT treated as ownership — it is restarted, not reported RUNNING" \
  || bad "doctor: an unreadable age was read as ownership and a dead controller was left alone — $OUT"
rm -f "$T/o/.orch.lock" "$T/ps/args.$$" "$T/ps/etime.$$"

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
export DOCTOR_TEST_UV="$T/uv"
export DOCTOR_LANE_REAP_BIN="$T/bin/lane-reap" DOCTOR_TEST_LANE_REAP="$T/lane-reap" DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt"
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

# ── 12b) THE CROSS-BOX REVIEW-RECORD REGISTRY (agent-infra#2577) ────────────────────────────────────
# The measured defect: `~/.pi/agent/reviews/` is PER BOX, so a verdict minted on a peer box is
# invisible here and the merge role skips its PR as `NO-RECORD` (live: store held 3201 records, this
# box 366, merge logged `candidates=11 attempted=1 landed=0 skipped=11`). Nothing ran the converging
# verb (`registry-sync.sh union`) on a schedule, so the box could not leave that state on its own.
#
# The fixture is TWO REAL git repos joined by a real `origin` remote — a bare "store" and a hub — so
# the assertions are about the shipped verb's behaviour (refs, records, bytes), never a stub's. The
# "peer box" is a clone that mints one record and publishes `refs/reviews/<key>`; the record is at the
# hub's head, which is what the merge role's `attestation_clean` compares against.
say_case "hygiene: a record that exists only on a PEER box becomes visible to the merge role in ONE pass"
reset_state; reset_tmux; : > "$T/tmux/sessions"; rm -f "$T/sup/calls"
R="$T/reg"; rm -rf "$R"; mkdir -p "$R" "$T/home/.pi/agent/reviews"
# The fixture git calls are pinned (`-c user.*`) so a runner with no global identity — and one with
# `commit.gpgsign` on — cannot turn a fixture step into a red that blames the doctor.
GITQ=(git -c user.email=fixture@example.invalid -c user.name=fixture -c commit.gpgsign=false)
git init --bare -q "$R/agent-infra.git"   # named for the origin-identity check in registry_store
git init -q "$R/hub"
printf 'x\n' > "$R/hub/f"
git -C "$R/hub" add f
"${GITQ[@]}" -C "$R/hub" commit -qm init
"${GITQ[@]}" -C "$R/hub" push -q "$R/agent-infra.git" HEAD:refs/heads/main
git -C "$R/hub" remote add origin "$R/agent-infra.git"
RHEAD="$(git -C "$R/hub" rev-parse HEAD)"
# The peer box: one clean record for PR 7 at RHEAD, published on the shared store's ref namespace.
git clone -q "$R/agent-infra.git" "$R/peer" 2>/dev/null
printf '{"pr":7,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-23T20:00:00Z"}\n' "$RHEAD" > "$R/peer/record.json"
PBLOB="$(git -C "$R/peer" hash-object -w "$R/peer/record.json")"
PTREE="$(printf '100644 blob %s\trecord.json\n' "$PBLOB" | git -C "$R/peer" mktree)"
PCOMMIT="$(git -C "$R/peer" -c user.email=fixture@example.invalid -c user.name=fixture commit-tree "$PTREE" -m record)"
git -C "$R/peer" push -q origin "$PCOMMIT:refs/reviews/daniel-ospina-agent-infra-7" 2>/dev/null
[ -n "$(git ls-remote "$R/agent-infra.git" 'refs/reviews/*' 2>/dev/null)" ] \
  && ok "registry fixture: the PEER published a review record the store holds" \
  || bad "registry fixture: the peer's record did not reach the store"
REC="$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-7.json"
printf '[]\n' > "$T/gh/prs.json"
printf '[{"number":7,"head":{"sha":"%s"},"draft":false}]\n' "$RHEAD" > "$T/gh/prs.json"
# BEFORE: the merge role cannot see the verdict — this is the defect, stated as an assertion.
OUT="$(DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" DOCTOR_REGISTRY_SYNC=off \
        bash "$DOCTOR" merge --dry-run 2>&1)"; RC=$?
[ ! -e "$REC" ] && ! result_has "WOULD call the rail on #7" \
  && ok "registry: BEFORE any pass the merge role does NOT see the peer's verdict (the measured blindness)" \
  || bad "registry: the merge role already saw #7 before the sync — the fixture proves nothing ($OUT)"
# ONE pass of the role that now carries the sync. `DOCTOR_REGISTRY_SYNC` is UNSET so the SHIPPED
# resolution order runs, and `$HARNESS_REPO` names the agent-infra checkout to provision from.
OUT="$( ( unset DOCTOR_REGISTRY_SYNC; DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         HARNESS_REPO="$R/hub" DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$DOCTOR" hygiene ) 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "registry: ONE hygiene pass completes (rc=0)" || bad "registry: hygiene rc=$RC — $OUT"
result_has "registry synced" && ok "registry: the pass records that the registry was synced" \
  || bad "registry: the pass did not record a sync — $OUT"
[ -f "$REC" ] && cmp -s "$REC" "$R/peer/record.json" \
  && ok "registry: the peer's record is now IN this box's registry, byte-identical ($REC)" \
  || bad "registry: the peer's record is still missing or altered here ($(cat "$REC" 2>/dev/null))"
# ⛔ FROM A WORKTREE. The verb performs git ref operations, and the hub checkout is what an agent
# session is refused for (#2520) — so the store must be a provisioned worktree, and the log must name
# it. Asserting the PATH (not merely "it worked") is what keeps the scheduled path the reproducible one.
case "$OUT" in
  *".worktrees/registry-sync"*) ok "registry: the sync ran from a provisioned WORKTREE, and the log names it" ;;
  *) bad "registry: the sync did not run from a worktree — $OUT" ;;
esac
git -C "$R/hub/.worktrees/registry-sync" rev-parse --git-dir >/dev/null 2>&1 \
  && ok "registry: the store worktree exists as a real git worktree of the hub" \
  || bad "registry: no worktree was provisioned at \$hub/.worktrees/registry-sync"

# AFTER: the merge role now OFFERS the PR to the rail — the whole point of the sync.
OUT="$(DOCTOR_ADMIN_MERGE="$T/bin/rail.sh" DOCTOR_TEST_RAIL="$T/rail" DOCTOR_REGISTRY_SYNC=off \
        bash "$DOCTOR" merge --dry-run 2>&1)"
result_has "WOULD call the rail on #7" \
  && ok "registry: after ONE pass the merge role SEES the peer's clean verdict for #7" \
  || bad "registry: the merge role still cannot see the synced record — $OUT"
# A rehearsal must not write: `--dry-run` is the verb an operator runs FIRST.
rm -f "$REC"
OUT="$( ( unset DOCTOR_REGISTRY_SYNC; DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         HARNESS_REPO="$R/hub" DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$DOCTOR" hygiene --dry-run ) 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && [ ! -e "$REC" ] && result_has "would sync the review registry" \
  && ok "registry: --dry-run does NOT write to the registry (a rehearsal performs no action)" \
  || bad "registry: --dry-run synced (rc=$RC, record present=$([ -e "$REC" ] && echo yes || echo no)) — $OUT"

say_case "hygiene: a FAILED registry sync is logged, NAMES the box, and leaves the pass SUCCESSFUL"
reset_state
cat > "$T/bin/sync-fail.sh" <<'SH'
#!/bin/bash
# Stand-in for a box that is offline / rate-limited: the verb cannot read the store.
printf "registry-sync.sh: cannot READ the 'origin' registry from '%s' — it is UNKNOWN, not empty. Not syncing.\n" "$2" >&2
exit 7
SH
chmod +x "$T/bin/sync-fail.sh"
rm -f "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-7.json"
OUT="$(DOCTOR_REGISTRY_SYNC="$T/bin/sync-fail.sh" DOCTOR_REGISTRY_STORE="$R/hub" \
        DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
        DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
        MIN_FREE_MB=0 bash "$DOCTOR" hygiene 2>&1)"; RC=$?
# ⛔ THE HARD REQUIREMENT: a failed sync must never fail the pass nor block a merge decision.
[ "$RC" -eq 0 ] && ok "registry: a FAILED sync leaves the pass SUCCESSFUL (rc=0)" \
  || bad "registry: a failed sync failed the pass (rc=$RC) — $OUT"
result_has "SYNC FAILED" && case "$OUT" in
  *"SYNC FAILED on $(hostname 2>/dev/null || uname -n)"*) ok "registry: the failure is logged against the box that could not sync" ;;
  *) bad "registry: the failure log does not name this box — $OUT" ;;
esac || bad "registry: a failed sync was not logged at all — $OUT"
case "$OUT" in
  *"cannot READ the 'origin' registry"*) ok "registry: the log carries the verb's OWN complaint (WHICH side failed)" ;;
  *) bad "registry: the log discards the verb's complaint — $OUT" ;;
esac
# Visible in `status` (the row prints `last_result`), WITHOUT being a failing rc.
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = "0" ] \
  && grep -qF 'registry SYNC FAILED' "$T/o/state/roles/hygiene.state" \
  && ok "registry: the failure is recorded on the role (status shows it) while last_rc stays 0" \
  || bad "registry: the failure is invisible to status — $(cat "$T/o/state/roles/hygiene.state" 2>/dev/null)"
[ ! -e "$T/home/.pi/agent/reviews/daniel-ospina-agent-infra-7.json" ] \
  && ok "registry: a failed sync wrote nothing into the registry" \
  || bad "registry: a failed sync touched the registry"
# ⛔ rc=0 IS NOT EVIDENCE OF CONVERGENCE — the verb's own `union:` line is. A seam that exits 0 silently
# (a truncated capture on a full disk, or an older copy of the verb) used to be recorded as
# `converged`: a blind box reading synced, which is the false-PASS direction that matters most here.
printf '#!/bin/bash\nexit 0\n' > "$T/bin/sync-silent.sh"; chmod +x "$T/bin/sync-silent.sh"
OUT="$(DOCTOR_REGISTRY_SYNC="$T/bin/sync-silent.sh" DOCTOR_REGISTRY_STORE="$R/hub" \
        DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
        DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
        MIN_FREE_MB=0 bash "$DOCTOR" hygiene 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry UNPROVEN" \
  && ok "registry: rc=0 with NO 'union:' summary is recorded UNPROVEN, not converged" \
  || bad "registry: a silent exit 0 was recorded as converged (rc=$RC) — $OUT"
case "$OUT" in
  *"converged with the fleet"*) bad "registry: a silent exit 0 claimed convergence — $OUT" ;;
  *) ok "registry: no convergence claim without the verb's own evidence line" ;;
esac

# ⛔ AND IT IS BOUNDED. `timeout(1)` is absent on the cells, so this exercises the shell-watchdog
# fallback: an offline store must cost the bound once, not hang the one loop that supervises the cell.
cat > "$T/bin/sync-hang.sh" <<'SH'
#!/bin/bash
"$DOCTOR_TEST_REAL_SLEEP" 30
exit 0
SH
chmod +x "$T/bin/sync-hang.sh"
T0="$(date +%s)"
# ⛔ `DOCTOR_TIMEOUT_BIN` names a tool that cannot exist, which forces `bounded`'s SHELL-WATCHDOG
# fallback — the branch a cell without `timeout(1)` actually runs. Without this override every Linux
# runner takes the `timeout -k` branch and the deployed path is never executed (the suite's own
# `/nonexistent/…` idiom, used for the tmux read too).
OUT="$(DOCTOR_TEST_REAL_SLEEP="$REAL_SLEEP" DOCTOR_REGISTRY_SYNC="$T/bin/sync-hang.sh" \
        DOCTOR_REGISTRY_STORE="$R/hub" DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
        DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
        DOCTOR_TIMEOUT_BIN=/nonexistent/registry-timeout \
        DOCTOR_REGISTRY_STEP_TIMEOUT=2 MIN_FREE_MB=0 bash "$DOCTOR" hygiene 2>&1)"; RC=$?
ELAPSED=$(( $(date +%s) - T0 ))
[ "$RC" -eq 0 ] && [ "$ELAPSED" -lt 25 ] \
  && ok "registry: a HANGING sync is cut at its bound (${ELAPSED}s) and the pass still succeeds" \
  || bad "registry: a hanging sync was not bounded (rc=$RC after ${ELAPSED}s) — $OUT"
result_has "SYNC FAILED" && ok "registry: a bounded-out sync is reported as a failure, not a silent no-op" \
  || bad "registry: the timed-out sync produced no failure line — $OUT"

# ⛔ THE COPY NEEDS ITS SIBLINGS. Since #2573 the hygiene pass also sweeps worktree-root caches,
# and that step FAILS CLOSED (`CANNOT-VERIFY`, rc=3) unless `live-ownership.sh` sits beside the
# script it runs from — correct in production, and a real deployment ships the whole directory.
# Without it these legs assert the registry store against a pass that died at step 4.
# ── 12c) the STORE is the checkout ROOT, and only an agent-infra checkout is a store at all ───────
# Both are review findings that the first cut of this change shipped, and both are silent: the worktree
# lands inside the tracked source tree, or records are pushed to the WRONG repository. The fixture asks
# the question the deployed layout actually asks — a harness copy at `<checkout>/scripts/…`, with no
# `HARNESS_REPO`/`AGENT_INFRA_PATH` set, so `$SELF_DIR/../..` is the only candidate left.
say_case "hygiene: the store is the checkout ROOT (not the scripts/ dir), and a non-agent-infra origin is REFUSED"
reset_state
mkdir -p "$R/hub/scripts/orchestrator-harness"
cp "$DOCTOR" "$R/hub/scripts/orchestrator-harness/cloud-cell-doctor.sh"
cp "$HERE/live-ownership.sh" "$R/hub/scripts/orchestrator-harness/live-ownership.sh"
cp "$HERE/../registry-sync.sh" "$R/hub/scripts/registry-sync.sh"
rm -f "$REC"; rm -rf "$R/hub/scripts/.worktrees"
OUT="$( ( unset DOCTOR_REGISTRY_SYNC DOCTOR_REGISTRY_STORE HARNESS_REPO HARNESS_PIN_DIR AGENT_INFRA_PATH; \
         DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$R/hub/scripts/orchestrator-harness/cloud-cell-doctor.sh" hygiene ) 2>&1)"; RC=$?
case "$OUT" in
  *"via $R/hub/.worktrees/registry-sync"*) ok "registry: the store resolves to the checkout ROOT's worktree" ;;
  *) bad "registry: the store did not resolve to <checkout>/.worktrees/registry-sync — $OUT" ;;
esac
[ ! -e "$R/hub/scripts/.worktrees" ] \
  && ok "registry: no worktree is provisioned inside the tracked scripts/ dir" \
  || bad "registry: a worktree was created inside the source tree — $(ls -d "$R/hub/scripts/.worktrees"/* 2>/dev/null)"
[ -f "$REC" ] && ok "registry: the shipped-layout pass still converged (the record is here)" \
  || bad "registry: the shipped-layout pass did not sync — $OUT"
# ⛔ The cross-repo guard: a repo whose `origin` is NOT agent-infra must never be used as the store —
# `registry-sync.sh` would faithfully push `refs/reviews/*` to whatever remote it is given.
# The doctor is a COPY outside any git repo, so the last candidate (`$SELF_DIR/../..`) cannot fall
# through to this very worktree's own agent-infra origin and reveal nothing about the guard.
git init -q "$R/notagentinfra" && git -C "$R/notagentinfra" remote add origin "$R/tortoise.git"
mkdir -p "$T/nc" && cp "$DOCTOR" "$T/nc/cloud-cell-doctor.sh"
cp "$HERE/live-ownership.sh" "$T/nc/live-ownership.sh"
OUT="$(DOCTOR_REGISTRY_SYNC="$HERE/../registry-sync.sh" HARNESS_REPO="$R/notagentinfra" \
        DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
        DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
        MIN_FREE_MB=0 bash "$T/nc/cloud-cell-doctor.sh" hygiene 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry SKIPPED (no worktree to sync from)" \
  && ok "registry: a checkout whose origin is NOT agent-infra is REFUSED as the store (rc stays 0)" \
  || bad "registry: a non-agent-infra checkout was used as the store (rc=$RC) — $OUT"
[ ! -e "$R/notagentinfra/.worktrees" ] \
  && ok "registry: nothing was provisioned in the refused checkout" \
  || bad "registry: a worktree was provisioned in a refused checkout"
# ⛔ The OVERRIDE is a pointer, not an exemption: naming a non-agent-infra checkout explicitly must be
# refused too (measured before this: the override pushed a record into a tortoise remote's
# `refs/reviews/*` — a silent cross-repo write, and rule 2 means nothing can delete it).
OUT="$(DOCTOR_REGISTRY_SYNC="$HERE/../registry-sync.sh" DOCTOR_REGISTRY_STORE="$R/notagentinfra" \
        DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
        DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
        MIN_FREE_MB=0 bash "$T/nc/cloud-cell-doctor.sh" hygiene 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry SKIPPED (no worktree to sync from)" \
  && ok "registry: a DOCTOR_REGISTRY_STORE whose origin is not agent-infra is REFUSED" \
  || bad "registry: the store override bypassed the origin identity check (rc=$RC) — $OUT"
result_has "refusing to push review records to it" \
  && ok "registry: the refusal says what it prevented (a cross-repo push)" \
  || bad "registry: the refusal does not name the hazard — $OUT"

say_case "hygiene: a PLAIN directory where the store worktree belongs is refused (the hub is never the store)"
# ⛔ `git -C <dir>` walks UPWARD, so `is_work_tree(<hub>/.worktrees/registry-sync)` is TRUE for an
# ordinary leftover directory — it reports the HUB. Accepting one therefore runs the verb against the
# hub checkout (the one thing "never the hub" forbids) while the convergence line names that path as
# "the worktree", silently and self-perpetuatingly (provisioning never re-runs). Reachable without
# hand-editing: a provisioning killed at its bound, or an out-of-band delete, leaves exactly this.
reset_state
git -C "$R/hub" worktree remove --force "$R/hub/.worktrees/registry-sync" >/dev/null 2>&1 || true
git -C "$R/hub" worktree prune >/dev/null 2>&1 || true
rm -rf "$R/hub/.worktrees/registry-sync"
mkdir -p "$R/hub/.worktrees/registry-sync"          # plain, UNREGISTERED
rm -f "$REC"
OUT="$( ( unset DOCTOR_REGISTRY_SYNC DOCTOR_REGISTRY_STORE HARNESS_PIN_DIR AGENT_INFRA_PATH; \
         HARNESS_REPO="$R/hub" \
         DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$DOCTOR" hygiene ) 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry SKIPPED (no worktree to sync from)" \
  && ok "registry: a plain dir where the worktree belongs is REFUSED" \
  || bad "registry: a plain directory was accepted as the store worktree (rc=$RC) — $OUT"
result_has "is not the root of a git worktree" \
  && ok "registry: the refusal is LOGGED (that branch is reachable)" \
  || bad "registry: the refusal is silent — $OUT"
[ ! -e "$REC" ] && ok "registry: nothing was synced through the hub path" \
  || bad "registry: the pass used the hub as its store — $REC exists"
# ⛔ AND THE REHEARSAL must say the same thing (the occupancy check needs no side effects). Leaving it
# out let a box that skips EVERY hourly pass print `would sync`, and `state_write_rehearsal` keeps the
# worse rc but REPLACES `last_result` — so the operator's first verb erased the recorded skip.
OUT="$( ( unset DOCTOR_REGISTRY_SYNC DOCTOR_REGISTRY_STORE HARNESS_PIN_DIR AGENT_INFRA_PATH; \
         HARNESS_REPO="$R/hub" \
         DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$DOCTOR" hygiene --dry-run ) 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry SKIPPED (no worktree to sync from)" \
  && ok "registry: --dry-run reports an OCCUPIED store path as the skip too" \
  || bad "registry: --dry-run claimed a sync on a box whose store path is unusable (rc=$RC) — $OUT"
case "$OUT" in
  *"WOULD run: registry-sync.sh"*) bad "registry: --dry-run still printed a positive WOULD — $OUT" ;;
  *) ok "registry: no false WOULD when the store path is unusable" ;;
esac
rm -rf "$R/hub/.worktrees/registry-sync"

say_case "hygiene: a REUSED store worktree of a DIFFERENT repository is refused (never a cross-repo push)"
# ⛔ "is the root of SOME worktree" is not identity. A worktree carries the CONFIG of the repo that
# registered it, so a leftover worktree of another repository at the store path makes the verb push this
# box's `refs/reviews/*` to THAT repo's remote — permanently (rule 2 has no delete path) — while the
# pass reports `converged with the fleet` and the fleet store receives nothing.
reset_state
git init --bare -q "$R/tortoise.git"
git init -q "$R/foreign"
printf 'y\n' > "$R/foreign/g"
git -C "$R/foreign" add g
"${GITQ[@]}" -C "$R/foreign" commit -qm init
git -C "$R/foreign" remote add origin "$R/tortoise.git"
git -C "$R/hub" worktree remove --force "$R/hub/.worktrees/registry-sync" >/dev/null 2>&1 || true
git -C "$R/hub" worktree prune >/dev/null 2>&1 || true
rm -rf "$R/hub/.worktrees/registry-sync"
git -C "$R/foreign" worktree add --detach --no-checkout "$R/hub/.worktrees/registry-sync" >/dev/null 2>&1 \
  || bad "registry fixture: could not register the FOREIGN worktree at the store path"
rm -f "$REC"
OUT="$( ( unset DOCTOR_REGISTRY_SYNC DOCTOR_REGISTRY_STORE HARNESS_PIN_DIR AGENT_INFRA_PATH; \
         HARNESS_REPO="$R/hub" \
         DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$DOCTOR" hygiene ) 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry SKIPPED (no worktree to sync from)" \
  && ok "registry: a worktree registered by ANOTHER repository is REFUSED as the store" \
  || bad "registry: a foreign worktree was used as the store (rc=$RC) — $OUT"
result_has "a worktree of a DIFFERENT repository" \
  && ok "registry: the refusal names the hazard (a push to that repository's remote)" \
  || bad "registry: the refusal is silent — $OUT"
[ -z "$(git ls-remote "$R/tortoise.git" 'refs/reviews/*' 2>/dev/null)" ] \
  && ok "registry: nothing was pushed to the foreign remote" \
  || bad "registry: a review record reached the foreign repository — $(git ls-remote "$R/tortoise.git" 'refs/reviews/*' 2>/dev/null)"
[ ! -e "$REC" ] && ok "registry: nothing was pulled from the foreign remote either" \
  || bad "registry: a record was materialised from the foreign remote — $REC"
git -C "$R/foreign" worktree remove --force "$R/hub/.worktrees/registry-sync" >/dev/null 2>&1 || true
rm -rf "$R/hub/.worktrees/registry-sync"

say_case "hygiene: a STALE worktree registration (dir gone) is re-created, not a permanent deadlock"
# ⛔ The worktree is a THROWAWAY, so `rm -rf`-ing it — what any disk cleanup does — leaves the
# registration behind, and a plain `worktree add` then refuses FOR EVER with rc=128 ("missing but
# already registered"). Measured: every hourly pass logged `could not provision … rc=128` and skipped,
# so the sub-step was dead on that box while `--dry-run` still said `would sync`. The fix re-creates
# OUR OWN registration with `-f` (not `worktree prune`, which would also drop other, possibly merely
# unmounted, registrations that are not this role's to remove).
reset_state
git -C "$R/foreign" worktree remove --force "$R/hub/.worktrees/registry-sync" >/dev/null 2>&1 || true
git -C "$R/hub" worktree prune >/dev/null 2>&1 || true
rm -rf "$R/hub/.worktrees/registry-sync"
git -C "$R/hub" worktree add --detach --no-checkout "$R/hub/.worktrees/registry-sync" >/dev/null 2>&1 \
  || bad "registry fixture: could not register the throwaway worktree"
rm -rf "$R/hub/.worktrees/registry-sync"          # the registration survives; the directory does not
rm -f "$REC"
OUT="$( ( unset DOCTOR_REGISTRY_SYNC DOCTOR_REGISTRY_STORE HARNESS_PIN_DIR AGENT_INFRA_PATH; \
         HARNESS_REPO="$R/hub" \
         DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$DOCTOR" hygiene ) 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry synced" \
  && ok "registry: a stale registration is RE-CREATED and the pass converges (not a permanent skip)" \
  || bad "registry: a stale registration deadlocked the sub-step (rc=$RC) — $OUT"
result_has "REGISTERED as a worktree but its directory is gone" \
  && ok "registry: the repair is LOGGED (the state is visible, not silent)" \
  || bad "registry: the repair is silent — $OUT"
case "$OUT" in
  *"rc=128"*) bad "registry: the pass still hit the 'missing but already registered' refusal — $OUT" ;;
  *) ok "registry: no rc=128 provisioning refusal" ;;
esac
[ -f "$REC" ] && ok "registry: the record was synced through the re-created worktree" \
  || bad "registry: nothing was synced after the repair — $OUT"

say_case "hygiene: no registry-sync.sh anywhere is a SKIP (not cannot-verify, unlike every other step)"
reset_state
# ⛔ A COPY, in a directory with no `registry-sync.sh` beside or above it: the shipped resolution order
# looks beside the supervisor, one level up from this file, in `$HARNESS_REPO`/`$HARNESS_PIN_DIR` and
# in the two cell script dirs — so "not found" can only be asserted from a location none of them
# reaches. (Pointing the seam at a nonexistent path is NOT the same test: the search would simply fall
# through to the SHIPPED script and sync, which is exactly what a first attempt at this case did.)
mkdir -p "$T/copy"; cp "$DOCTOR" "$T/copy/cloud-cell-doctor.sh"
cp "$HERE/live-ownership.sh" "$T/copy/live-ownership.sh"
OUT="$( ( unset DOCTOR_REGISTRY_SYNC HARNESS_REPO HARNESS_PIN_DIR AGENT_INFRA_PATH; \
         DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$T/copy/cloud-cell-doctor.sh" hygiene ) 2>&1)"; RC=$?
# ⛔ The asymmetry with the reaper above is deliberate and is the whole non-fatal ruling: a doctor
# with no registry verb is BLIND, not broken, and a permanently red hygiene row would hide the disk
# failures this role actually exists to catch.
[ "$RC" -eq 0 ] && ok "registry: a missing sync script does NOT fail the pass (rc=0, unlike the reaper's rc=3)" \
  || bad "registry: a missing sync script failed the pass (rc=$RC) — $OUT"
result_has "registry SKIPPED (registry-sync.sh not found)" && ok "registry: the skip is RECORDED (a silent clean pass would be the silent-no-op class)" \
  || bad "registry: the skip is not recorded — $OUT"
result_has "LOCAL-ONLY" && ok "registry: the log says what the skip MEANS (this box's registry stays local-only)" \
  || bad "registry: the skip's consequence is not stated — $OUT"
# ⛔ AND THE REHEARSAL MUST NOT PRETEND. `hygiene --dry-run` is the verb an operator runs FIRST; on a
# box with no sync script it used to print `WOULD run: registry-sync.sh union`, i.e. a positive claim
# about an action this box cannot take — the misinformation direction the role's rehearsal doctrine
# exists to prevent. It now reports the same SKIP the live pass records.
OUT="$( ( unset DOCTOR_REGISTRY_SYNC HARNESS_REPO HARNESS_PIN_DIR AGENT_INFRA_PATH; \
         DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$T/copy/cloud-cell-doctor.sh" hygiene --dry-run ) 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry SKIPPED (registry-sync.sh not found)" \
  && ok "registry: --dry-run reports the SKIP, not a WOULD it cannot perform" \
  || bad "registry: --dry-run claimed an action this box cannot take (rc=$RC) — $OUT"
case "$OUT" in
  *"WOULD run: registry-sync.sh"*) bad "registry: --dry-run still prints a positive WOULD on a box that cannot sync — $OUT" ;;
  *) ok "registry: no false WOULD line on a box that cannot sync" ;;
esac
# ⛔ And the SCRIPT is only half the answer: a box with the verb but NO usable store is equally blind,
# and it is the documented farmed shape (a copy under `$CELL_HOME/.pi/agent/scripts` with no checkout
# above it). The rehearsal must say the same thing the live pass says — otherwise, because
# `state_write_rehearsal` replaces `last_result`, the operator's first verb ERASES the recorded skip
# from the role row and a blind box reads clean.
OUT="$( ( unset DOCTOR_REGISTRY_STORE HARNESS_REPO HARNESS_PIN_DIR AGENT_INFRA_PATH; \
         DOCTOR_REGISTRY_SYNC="$HERE/../registry-sync.sh" \
         DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
         DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
         MIN_FREE_MB=0 bash "$T/nc/cloud-cell-doctor.sh" hygiene --dry-run ) 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry SKIPPED (no worktree to sync from)" \
  && ok "registry: --dry-run also reports a MISSING STORE as a skip (the farmed shape)" \
  || bad "registry: --dry-run claimed a sync on a box with no store (rc=$RC) — $OUT"
# The hermetic switch the rest of this suite depends on states itself, rather than degrading silently.
OUT="$(DOCTOR_REGISTRY_SYNC=off DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" \
        DOCTOR_WORKTREE_REAPER="$T/bin/wt-reaper.sh" DOCTOR_TEST_WT="$T/wt" \
        MIN_FREE_MB=0 bash "$DOCTOR" hygiene 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && result_has "registry skipped (by request)" \
  && ok "registry: the DOCTOR_REGISTRY_SYNC=off seam reports itself (the suite's hermetic switch)" \
  || bad "registry: the off seam is silent (rc=$RC) — $OUT"

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

say_case "doctor: a nested reap cannot-verify does not swallow a FAILED restart"
reset_state; : > "$T/o/state/roles/.desired"; reset_tmux
rm -f "$T/sup/calls"; printf '1\n' > "$T/sup/rc"
( DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup" DOCTOR_TEST_REAP_ABSTAIN=1 bash "$DOCTOR" doctor >/dev/null 2>&1 ); DRC=$?
rm -f "$T/sup/rc"
# ⛔ `[ "$rrc" -eq 0 ] && rrc=1` only ever RAISED A ZERO (#2163 review r8, P1): with the nested reap
# at rc=3 a controller that was DOWN and could not be restarted recorded 3 as well, so "controller is
# down" was no longer expressible in the rc at all. The supervision FAILURE is dominant.
[ "$DRC" -eq 1 ] && ok "doctor: restart FAILED + reap rc=3 -> rc=1 (controller-is-down stays expressible)" \
  || bad "doctor: rc=$DRC (want 1) — the restart failure collapsed into the reap's rc"
rm -f "$T/o/state/roles/.desired"

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
[ "$(grep -cF 'WORST_PASS_S=$(( MERGE_BUDGET_S + RAIL_TIMEOUT + HYGIENE_TIMEOUT + REGISTRY_STEP_TIMEOUT + REGISTRY_STEP_TIMEOUT ))' "$DOCTOR")" -ge 1 ] \
  && ok "status: the default doctor bound is DERIVED from the worst PASS (merge budget + one overrun + the hygiene pass's own bounded registry sub-step, #2577), not one call" \
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

say_case "final pass 3: an ABSENT mode is a LIVE pass — the loop's first tick and every role's DIRECT entry (#2135/#2424)"
# ⛔ THE BUG THESE CASES EXIST FOR. `run_loop` USED TO dispatch `run_role_pass doctor|merge|hygiene`
# with NO mode argument; `run_role_pass` forwards `"$@"`, so each role's `local dry="$1"` read an
# UNBOUND `$1` under `set -u` and the loop DIED on its first tick — every tick, on every cell
# (`cloud-cell-doctor.sh: line 1385: $1: unbound variable`). Doctor is first, so it crashed; reap,
# merge and hygiene carried the identical latent crash. The suite above never saw it because its loop
# fixture has no `.desired` and quenches BEFORE the first dispatch, and because every CLI verb binds
# `$1` (to "") — so only the absent-mode call shape the scheduler used was fatal.
# ⛔ THE LOOP IS NO LONGER THE DISCRIMINATOR, AND THIS SUITE MUST NOT PRETEND IT IS. #2424 shipped
# TWICE: this branch defaults the mode in each role (`local dry="${1:-}"`), while #2555 landed
# separately and made the loop bind it explicitly (`run_role_pass doctor ""`). Both fixes are in the
# merged tree, so Arm A below can no longer drive an unbound `$1` on its own — Arms B and D, which
# call the roles DIRECTLY with no argument, are what pin the absent shape now; Arm C pins it in the
# SOURCE (it classifies `local` reads, it never calls a role). Arm A still earns its place: it pins
# that every derived role records a LIVE pass on the loop's real tick.
#
# ⛔ THE ROLE SET IS DERIVED FROM THE DISPATCHER, NEVER SPELLED HERE. A hardcoded list covers the four
# roles that exist today and silently ignores the fifth: a new role added to `run_role_pass` with a
# bare `"$1"` (or with a non-empty default such as `"${1:---dry-run}"`) would crash — or, worse,
# rehearse while the fleet believes the work was attempted — with this suite still green.
ROLES="$(awk '/^run_role_pass\(\) \{/,/^\}/' "$DOCTOR" \
         | sed -nE 's/^[[:space:]]*([A-Za-z][A-Za-z0-9_-]*)\)[[:space:]]*run_([A-Za-z0-9_]+).*/\1 \2/p')"
ROLE_N="$(printf '%s\n' "$ROLES" | grep -c . || true)"
if [ "${ROLE_N:-0}" -ge 4 ]; then
  ok "roles: derived $ROLE_N dispatched role(s) from run_role_pass: $(printf '%s' "$ROLES" | awk '{printf "%s ", $1}')"
else
  bad "roles: found ${ROLE_N:-0} role arm(s) in run_role_pass — the derivation is broken, so every arm below is vacuous"
fi
# The derived name must BE the function the dispatcher calls, or the arms below would exercise a
# function that is not wired to the role at all.
while read -r _r _f; do
  [ -n "${_r:-}" ] || continue
  # ⛔ ANY BASH-LEGAL HEADER FORM, NOT JUST `run_x() {` AT COLUMN 0 (review P2, reproduced): a
  # whitespace-identical reformat (`run_reap()` + next-line brace, `run_reap () {`, `run_reap(){`, an
  # indented header) failed this arm while every behavioural arm passed. func_for already accepts all
  # of them, so this check uses the same shape instead of a second, stricter spelling.
  if grep -qE "^[[:space:]]*(function[[:space:]]+)?run_${_f}[[:space:]]*\([[:space:]]*\)([[:space:]]*(\{.*|\(.*|(if|while|until|for|select|case|\[\[|\(\().*|\\\\[[:space:]]*|#.*)?)$" "$DOCTOR"; then
    ok "roles: '${_r}' dispatches run_${_f}, which the script defines"
  else
    bad "roles: '${_r}' dispatches run_${_f}, which the script does NOT define — the derivation is wrong"
  fi
done <<<"$ROLES"

# Arm A — the loop on a STARTED cell: no abort, and EVERY derived role records a pass.
# ⛔ It owns its fixture. Measured false red without this: a `rail/sleep` left by an earlier case
# (case 5 sets one to 2s) truncates the tick inside the 6s bound and this arm then reports the two
# #2424 strings — "role 'merge' recorded NO pass" — for a doctor that is completely correct.
reset_state; reset_tmux; reset_ps; rm -f "$T/writing"
rm -f "$T"/gh/* "$T"/rail/* "$T"/sup/* "$T"/uv/* "$T"/wt/* 2>/dev/null || true
: > "$T/o/state/roles/.desired"          # a STARTED cell: this loop must DISPATCH, not quench
: > "$T/tmux/sessions"
OUT="$(LOOP_TICK=10 DOCTOR_INTERVAL=0 MERGE_INTERVAL=0 HYGIENE_INTERVAL=0 \
       timeout 6 bash "$DOCTOR" loop 2>&1)"; RC=$?
case "$OUT" in
  *"unbound variable"*) bad "loop: DIED on its first tick (the #2424 abort) — $OUT" ;;
  *)                    ok "loop: the first tick dispatches with no unbound-variable abort" ;;
esac
result_has "loop started" && ok "loop: it recorded the tick ('loop started')" \
  || bad "loop: no 'loop started' line — $OUT"
# "The loop survived" is NOT the acceptance: a loop that schedules nothing has fixed nothing.
while read -r _r _f; do
  [ -n "${_r:-}" ] || continue
  st="$T/o/state/roles/${_r}.state"
  if [ ! -f "$st" ]; then bad "loop: role '${_r}' recorded NO pass (its state file is missing)"; continue; fi
  p="$(sed -n 's/^passes=//p' "$st")"
  { [ -n "$p" ] && [ "$p" -ge 1 ]; } && ok "loop: role '${_r}' recorded a pass (passes=$p)" \
    || bad "loop: role '${_r}' recorded passes='${p}' — it never completed a pass"
  # What this READS is exactly what it says: the record is not MARKED as a rehearsal. It is not the
  # only guard — a rehearsal that exits on cannot-verify writes an UNMARKED record, so "empty means
  # live" is pinned by the VALUE rule in arm C and proven behaviourally in arm D, not by this string.
  case "$(sed -n 's/^last_result=//p' "$st")" in
    *"a rehearsal"*) bad "loop: role '${_r}' recorded a REHEARSAL with no flag — empty must mean LIVE" ;;
    *)               ok "loop: role '${_r}' did not record a rehearsal (the record is not marked as one)" ;;
  esac
done <<<"$ROLES"

# Arm B — every role entry point called with NO ARGUMENT AT ALL, sourced from the script's own
# define-only prelude so `set -u` is the FILE's, not the suite's. Arm A can only reach the roles the
# tick dispatches, and every CLI verb binds `$1`, so the absent shape has to be driven directly —
# this arm does it for every derived role, and Arm D does it for one (`bash -u -c … run_reap`).
PRELUDE="$T/doctor-funcs.sh"
CASELINE="$(grep -n '^case "${1:-status}" in$' "$DOCTOR" | head -1 | cut -d: -f1)"
if [ -n "$CASELINE" ] && [ "$CASELINE" -gt 100 ]; then
  head -n "$((CASELINE - 1))" "$DOCTOR" > "$PRELUDE"
  ok "bare-entry: the define-only prelude was extracted ($((CASELINE - 1)) lines of the doctor, everything before the CLI dispatch at $CASELINE)"
else
  bad "bare-entry: could not find the CLI dispatch line — this arm cannot run (head=-n '${CASELINE}')"
fi
# ⛔ NON-VACUITY: an empty or truncated prelude would make every call below "command not found" (rc
# 127) and read as a pass. Prove each function exists before trusting any result.
while read -r _r _f; do
  [ -n "${_r:-}" ] || continue
  if [ -s "$PRELUDE" ] && bash -c "source '$PRELUDE'; declare -F run_${_f} >/dev/null" 2>/dev/null; then
    ok "bare-entry: run_${_f} is defined by the extracted prelude"
  else
    bad "bare-entry: run_${_f} is NOT defined by the prelude — the arm below would be vacuous"
  fi
done <<<"$ROLES"
while read -r _r _f; do
  [ -n "${_r:-}" ] || continue
  reset_state; reset_tmux; reset_ps; rm -f "$T/writing"
  # No `.desired`: the doctor arm then takes its "cell is not started" path instead of starting a
  # controller. The abort being pinned happens on the FIRST line of each role, before any of that.
  OUT="$(bash -u -c "source '$PRELUDE'; run_${_f}" 2>&1)"; RC=$?
  case "$OUT" in
    *"unbound variable"*) bad "bare-entry: run_${_f} with NO argument DIED on an unbound variable — $OUT" ;;
    *) ok "bare-entry: run_${_f} with NO argument returns (rc=$RC) instead of dying on \${1}" ;;
  esac
done <<<"$ROLES"

# Arm C — the CLASS, not the four lines. Every `local` assignment that READS a positional must be
# classified, and the classification is by VALUE:
#   * `"${N:-}"`      → DEFAULTED to the empty string: absent means the caller's empty value;
#   * `"${N:-<any>}"` → REJECTED: a default here would invent a mode (a rehearsal would arm itself);
#   * bare `$N`       → permitted only when the (ENCLOSING FUNCTION, bound name) pair is one of the
#                       REQUIRED reads the audit block documents (an empty role/pid/head is never a
#                       safe value).
# ⛔ THE KEY IS `function:name`, NEVER THE NAME ALONE (review P1). A name-keyed allowlist grandfathers
# the next `local s="$1"` ANYWHERE in the file: `s`, `rc`, `d` and `role` are the commonest locals
# here and are already reused across helpers, so a brand-new function reusing one of those names
# passed the walk with a ✅ and no decision was ever made — the exact false PASS this case exists to
# prevent. The suite pins the negative direction (`function:s` under a function not on the list).
# ⛔ THE CLASSIFIER IS A FUNCTION so the scanner itself can be tested: a shape-whitelist that cannot
# see `local dry="${1}"` (or `local x="$1/$2"`) reports "clean" over the exact crash, which is the
# fail-open shape this case exists to prevent. Both were measured blind in an earlier revision.
# ⛔ THE VERDICT COMES FROM THE READ, NOT FROM WHAT SURROUNDS IT (review P2). The bucket used to be
# decided by whether the value was EXACTLY the positional, so `local dry="$1 "` and `local x="$1$2"`
# were filed `derived` — ungraded ✅ notes — even though both are bare reads that die on an absent
# argument. `derived` is now an ANNOTATION printed under the verdict (the value embeds the positional
# in a path or a concatenation), never a bucket that suppresses grading.
# ⛔ THE COMMENT STRIP IS QUOTE-AWARE, AND QUOTE TRACKING MUST MODEL `$( )` (review P1, twice).
# Stripping at the first whitespace-plus-`#` truncated a value that CONTAINS that sequence
# (`local what="reap #$1 lane"`): the read vanished from the SCAN and from the COUNT in one stroke, so
# no record and no `unparsed` — PASS identical to baseline over a binding that dies under `set -u`.
# A simple quote TOGGLE then failed the same way one level down: in
# `local ok="$(printf %s " #pad")" n="$1"` the inner quote closes the toggle, but bash re-quotes
# INSIDE `$( )`, so the strip fired and the line produced no record at all. This is therefore a state
# machine with a DEPTH STACK: entering `$( )` saves the quoting state and starts unquoted, and the
# matching `)` restores it. A `#` is a comment only at depth 0, unquoted, preceded by whitespace.
# The program is written once to a file because it needs both quote characters, which cannot be nested
# inside the shell's own quoting without becoming unreadable.
STRIP_AWK="$T/strip-comment.awk"
cat > "$STRIP_AWK" <<'AWK'
{
  out = ""; q = ""; depth = 0; n = length($0); i = 1
  while (i <= n) {
    c = substr($0, i, 1)
    if (q == "'") { out = out c; if (c == "'") q = ""; i++; continue }
    if (c == "\\" && q != "'") { out = out c substr($0, i + 1, 1); i += 2; continue }
    if (q == "\"") {
      if (c == "\"") { q = ""; out = out c; i++; continue }
      if (c == "$" && substr($0, i + 1, 1) == "(") { stk[depth] = q; depth++; q = ""; out = out "$("; i += 2; continue }
      out = out c; i++; continue
    }
    if (q == "`") { out = out c; if (c == "`") q = ""; i++; continue }
    if (c == "\"") { q = "\""; out = out c; i++; continue }
    if (c == "'") { q = "'"; out = out c; i++; continue }
    if (c == "`") { q = "`"; out = out c; i++; continue }
    if (c == "$" && substr($0, i + 1, 1) == "(") { stk[depth] = q; depth++; out = out "$("; i += 2; continue }
    if (c == ")" && depth > 0) { depth--; q = stk[depth]; out = out c; i++; continue }
    if (c == "#" && i > 1 && substr($0, i - 1, 1) ~ /[ \t]/ && depth == 0) break
    out = out c; i++
  }
  print out
}
AWK
strip_comment() { printf '%s\n' "$1" | awk -f "$STRIP_AWK"; }
# ⛔ ONE PATTERN, ONE VARIABLE (this class has now cost three rounds). The guard, the per-value
# scan and the fail-closed counter each carried their own copy of the read pattern, and every round
# found them out of step: `${#1}`/`${!1}` were in none of them, then `${01}` was in none of them.
# `POSRE` is the single definition; a read shape added here is added everywhere by construction.
# ⛔ AND THE BARE FORM DOES NOT ACCEPT LEADING ZEROS, while the braced form does. Bash reads `${01}`,
# `${010}`, `${#01}`, `${!01}` and `${0123}` as positional reads (they die with `01: unbound
# variable`), but unbraced `$01` is `$0` followed by `1`, not a read of arg 1 — so `0*` belongs only
# inside `\${…}`. Reproduced (review P1): a `${01}` binding left the suite at PASS=235 with no record
# and no `unparsed`. The `.` guard used to be a `case` with four hand-written arms; with five shapes
# that is five places to forget, so it is a grep against this one pattern.
POSRE='\$\{[#!]?0*[1-9][0-9]*[^}]*\}|\$[1-9][0-9]*'
audit_line() { # <text> -> "<verdict> <name> <read>" per positional read, then a `derived` note
  local body="$1" assign var val rd seen=0 alln=0
  # ⛔ ONE STRING FOR BOTH THE SCAN AND THE COUNT (review P1). The count used to strip a trailing
  # `# …` comment while the assignment scan read the RAW line, so a comment that looks like an
  # assignment contributed a phantom "seen" read: `seen == alln`, no `unparsed` was emitted, and the
  # fail-closed counter went silent on exactly the shape it exists for. Stripping ONCE, here, before
  # either use, makes the two compare the same string.
  body="$(strip_comment "$body")"
  while read -r assign; do
    [ -n "$assign" ] || continue
    var="${assign%%=*}"; val="${assign#*=}"
    grep -qE "$POSRE" <<<"$val" || continue
    while read -r rd; do
      [ -n "$rd" ] || continue
      seen=$((seen + 1))
      # ⛔ THE DEFAULTED FORM IS ANCHORED, NOT A CONTAINS-MATCH (review P1, reproduced). The arm used
      # to be the glob `${` + digit + `*` + `:-}`, which grades ANY expansion whose TEXT happens to
      # contain `:-}` as safe-to-be-empty: `${1#*:-}` (strip a prefix), `${1%:-}`, `${1/foo/:-}` and
      # the folded `${1:-${2#*:-}}` all became `defaulted` — and every one of them dies with
      # `1: unbound variable` when the argument is absent. It is now exactly `${<digits>:-}` or
      # `${<digits>-}`, which are the two spellings that mean "absent → empty" (`:-` also replaces an
      # empty value, `-` does not; neither can die on an absent argument). A non-empty default stays
      # `invented` (loud), and everything else is `bare`.
      # ⛔ `${N+x}` / `${N:+x}` ARE DELIBERATELY NOT MODELLED: they cannot die on an absent argument
      # either, but they IGNORE the caller's value (they yield `x` when it is SET), so a role written
      # that way would look defaulted while discarding the mode — graded `bare`/`unparsed` so it needs
      # a human decision instead of being waved through (review P3, declared).
      if grep -qE '^\$\{[0-9]+(:-|-)\}$' <<<"$rd"; then
        printf 'defaulted %s %s\n' "$var" "$rd"
      elif grep -qE '[$][{][0-9]+:-.+' <<<"$rd"; then
        printf 'invented %s %s\n' "$var" "$rd"
      else
        printf 'bare %s %s\n' "$var" "$rd"
      fi
      # The ANNOTATION, printed UNDER the verdict so it can never suppress it (`head -1` still
      # reads the verdict). A value that embeds the positional in a path/concatenation inherits its
      # function's contract — which is exactly why it must be graded, not excused.
      case "$val" in
        "$rd"|"\"$rd\"") ;;
        *) printf 'derived %s %s\n' "$var" "$rd" ;;
      esac
    done < <(grep -oE "$POSRE" <<<"$val")
  done < <(grep -oE '([A-Za-z_][A-Za-z0-9_]*="[^"]*"|[A-Za-z_][A-Za-z0-9_]*=\$[^ ]*)' <<<"$body")
  # ⛔ A POSITIONAL READ THE ASSIGNMENT SCAN CANNOT ATTRIBUTE IS A HARD FAIL, NOT A SILENCE
  # (review P2). The assignment pattern cannot see through a nested quote: for
  # `local n="$(printf %s "$1")"` the outer `="[^"]*"` stops at the inner quote, so the read was
  # never graded — although it dies on an absent argument exactly like `local x="$1"`, and it IS
  # inside this audit's declared scope ("every `local` binding of a positional"). The line's reads are
  # therefore COUNTED and compared with the ones the parse produced; the difference is reported as
  # `unparsed` (fail-closed) rather than dropped. Trailing ` # …` comments are stripped first so a
  # comment that mentions `$1` cannot invent an unparsed read (`="#ff"` is unaffected: the strip
  # needs WHITESPACE before the `#`).
  # ⛔ `[#!]?` IS REQUIRED: `${#1}` (length) and `${!1}` (indirect) are REAL positional reads that die
  # under `set -u` exactly as `$1` does, and with a bare `[1-9]` after `${` BOTH halves of this audit
  # were blind to them — the assignment scan did not see the read, so it was never graded, AND the
  # `alln` counter below did not count it, so the fail-closed `unparsed` net could not fire either.
  # Reproduced (review P1): `local n="${#1}"` in a new function left the suite at FAIL=0 and the
  # counters untouched. `POSRE` above is the one definition all three use.
  alln="$(grep -oE "$POSRE" <<<"$body" | wc -l)"
  while [ "$seen" -lt "$alln" ]; do
    seen=$((seen + 1))
    printf 'unparsed ? ?\n'
  done
}
# The scanner's own contract on the shapes that matter, INCLUDING the ones earlier revisions missed.
# ⛔ A BARE READ STAYS BARE THOUGH THE VALUE EMBEDS IT. `local d="$ROLES_DIR/.$1.lock"`,
# `local dry="$1 "` and `local x="$1$2"` were filed `derived` (ungraded ✅) before the review, and
# all of them die on an absent argument exactly like `local x="$1"`.
# ⛔ NOTHING INSIDE THE HEREDOC MAY BE A COMMENT: that block is DATA, and a `#` line is read as a
# record whose `want` is the prose — the failure mode is three ❌ in the self-test, not a silent pass.
while IFS='|' read -r want text; do
  [ -n "${want:-}" ] || continue
  got="$(audit_line "$text" | cut -d' ' -f1 | head -1)"
  [ "$got" = "$want" ] && ok "audit[self-test]: '$text' is classified '$want'" \
    || bad "audit[self-test]: '$text' classified '${got:-<nothing>}' (want '$want') — the scanner is blind to a shape that crashes the scheduler"
done <<'EOF'
defaulted|local dry="${1:-}" s log
defaulted|local dry="${4:-}" s log
defaulted|local dry="${1-}" s log
bare|local dry="${1+x}" s log
defaulted|local dry="${12:-}" s log
invented|local dry="${1:---dry-run}" s log
invented|local dry="${1:-0}" s log
invented|local dry="${4:---dry-run}" s log
bare|local dry="${1}" s log
bare|local dry="$1" s log
bare|local x=$1
bare|local d="$ROLES_DIR/.$1.lock"
bare|local tmp="$1/.own.tmp.$$"
bare|local dry="$1 "
bare|local x="$1$2"
bare|local n="${#1}"
bare|local n="${!1}"
bare|local what="reap #$1 lane"
bare|local ok="$(printf %s " #pad")" n="$1"
bare|local n="${01}"
bare|local n="${#01}"
bare|local n="${!010}"
bare|local s="${1#*:-}"
bare|local s="${1%:-}"
bare|local s="${1/foo/:-}"
invented|local s="${1:-${2#*:-}}"
bare|local d="$1" tmp="$1/.own.tmp.$$"
EOF
# …and the FAIL-CLOSED shape: a positional the assignment parse cannot attribute must be REPORTED,
# not skipped. `local n="$(printf %s "$1")"` is the measured case.
_unp="$(audit_line 'local n="$(printf %s "$1")"' | tr '\n' '|')"
case "$_unp" in
  *unparsed*) ok "audit[self-test]: a positional inside a nested substitution is reported UNPARSED (fail-closed), not silently skipped" ;;
  *)          bad "audit[self-test]: a nested-substitution read produced '${_unp:-<nothing>}' — an unattributable read is being skipped, which is the silence this arm exists to prevent" ;;
esac
# …then the real file. The allowlist is (FUNCTION, NAME) pairs — see the P1 note above.
REQUIRED_READS=" state_write:role state_write:rc state_write_rehearsal:role state_write_rehearsal:own \
 lock_claim:d lock_claim:tmp reclaim_lock:d role_lock:role role_unlock:d bounded:s run_bounded:s \
 pid_ident:pid human_above:pid attestation_clean:pr attestation_clean:head \
 controller_heartbeat_verdict:who role_row:role role_row:bound run_role_pass:role "
# ⛔ EVERY ENTRY MUST NAME ITS FUNCTION. A bare `role`/`s`/`d` entry would restore the name-keyed
# grandfathering this list was re-keyed to remove, and it would do it silently. The pattern is
# `*:*` (HAS a colon) — the first version tested `*:*:*`, i.e. TWO colons, which no real entry has,
# so the assertion passed on any input at all: a vacuous check inside the gate against vacuous checks.
BADENTRY=0; _n=0
for _e in $REQUIRED_READS; do
  _n=$((_n + 1))
  case "$_e" in *:*) ;; *) BADENTRY=1 ;; esac
done
[ "$BADENTRY" -eq 0 ] && [ "$_n" -ge 15 ] \
  && ok "audit: every REQUIRED_READS entry is a function:name pair ($_n entries)" \
  || bad "audit: REQUIRED_READS has $_n entries and BADENTRY=$BADENTRY — an entry without a function:name key, or a collapsed list, grandfathers the next bare read"
# The enclosing function of a line, so a bare read is judged where it actually lives.
func_for() { # <file> <line-number> -> the NEAREST PRECEDING header's name (empty before the first)
  local file="$1" want="$2" ln best=0
  # ⛔ HEADER FORMS ACCEPTED, AND ALL MAY BE INDENTED: `name() {`, `name () {` (space before the
  # parens), `name()` with the brace on the NEXT line, `function name() {`, and the keyword form
  # `function name {`. Matching only
  # `name() {` at column 0 attributed a next-line-brace function, or a NESTED helper (this file has
  # `note()` in run_reap and `claim_take()` in run_merge), to the PRECEDING/OUTER function — where
  # that function's allowlisted name covered the read and it passed with no decision (review P1/P2,
  # both reproduced).
  # ⛔ NO `$` AFTER THE BRACE ARM: a trailing comment (`state_write_rehearsal() { # <role> …`) is
  # normal in this file, and anchoring there silently dropped 22 of the 48 headers — which made a
  # line resolve to the PRECEDING function, i.e. exactly the misattribution this fixes.
  # ⛔ AND A TRAILING COMMENT BEFORE A NEXT-LINE BRACE (review P1, reproduced): `ZzFutureHelper()  #
  # note` + `{` on the following line is bash-legal, and an EOL-anchored next-line arm missed it, so
  # the read resolved to the PRECEDING function and PASS went 230→231 with the mutant's read ✅ under
  # `run_bounded`. Both arms therefore accept an optional trailing comment — and the comment arm is
  # `#.*`, not `#[^"]*`: a comment containing a quote (`# it says "hi"`) is still a comment, and with
  # the narrower class that header was invisible too (review P1). The parens are `\([[:space:]]*\)`
  # because `name( ) {` is bash-legal as well.
  # ⛔ AND A LINE-CONTINUED HEADER (review P1, reproduced): `ZzContHeader() \` and `{` on the next
  # line is bash-legal, and missing it attributed the read to the PRECEDING function, where an
  # allowlisted pair for the same NAME graded it REQUIRED (PASS 235→236). Hence the `\\[[:space:]]*$`
  # arm, which accepts a trailing backslash as well as a trailing comment.
  # ⛔ AND THE BODY MAY OPEN ON THE HEADER LINE WITH ANY COMPOUND OPENER (review P1, reproduced):
  # `ZzNew() (` , `ZzNew() if true; then`, `while`, `until`, `for`, `select`, `case`, `[[`, `((` are all
  # bash-legal one-line headers, and missing them attributed the body's read to the PRECEDING function,
  # where an allowlisted pair for the same name graded it REQUIRED (PASS 239→240). The `name()` form
  # always has EMPTY parens, so an awk `function secs(t, n, …)` is still not a header.
  # ⛔ A ZERO-PARAMETER AWK FUNCTION IS INDISTINGUISHABLE FROM A BASH HEADER (declared limitation,
  # review P2): `function ww() { … }` inside a single-quoted awk program is byte-identical to a bash
  # function header, and awk really does accept the empty parens. Such a line IS treated as a header,
  # so a `local` that follows it in the SAME bash function is graded under `ww` and fails LOUDLY
  # (`ww:pid` is not on REQUIRED_READS). That is the fail-closed direction on purpose: the opposite
  # choice — not treating `function name()` as a header — is a silent misattribution of every bash
  # function written in the keyword form, which is the fail-open class this whole audit exists for.
  # A parameterised awk function (`function secs(t, …)`) is excluded, because a bash `name()` header
  # always has EMPTY parens.
  # ⛔ IT IS "NEAREST PRECEDING", NOT "INNERMOST ENCLOSING" (review P2): there is no brace tracking,
  # so a line that comes AFTER a nested helper has closed still resolves to that helper. Today's two
  # nested helpers both sit after their function's only positional binding, so nothing is
  # misattributed; a future one that does not would be reported under the helper's name, which is
  # LOUD (that pair is not on REQUIRED_READS) rather than silently allowed.
  # ⛔ THE NAME CHARSET IS NOT `[a-z_]` (review P1, reproduced). Bash accepts `ZzFutureHelper ()`,
  # `zz-future-helper()`, `ZzFutureHelper(){` and a dotted/colon name; with a lowercase-only class
  # those headers were INVISIBLE, so the mutant's `local s="$1"` resolved to the preceding function —
  # whose allowlisted pair covered it — and the suite stayed green. The class below is therefore
  # every non-dash non-paren token character, and the extraction `s/[[:space:]]*(...//` strips an
  # optional `()`/`{` suffix.
  # ⛔ AND IT IS CHECKED BOTH WAYS (fail-closed): a line that LOOKS like a definition by the BROAD
  # pattern but does not yield a name by the NARROW one is a header this resolver cannot attribute,
  # so it is reported rather than skipped — the same doctrine as `unparsed` for reads.
  # ⛔ AND THE NAME ITSELF MAY BE CONTINUED: `ZzContName \` + `() {` is bash-legal, and it is NOT the
  # `local`-continuation residual (that one is about a binding, this is a HEADER). Missing it resolved
  # the body's read to the preceding allowlisted function (review P1, reproduced: PASS +1, read ✅ under
  # `bounded`). It needs the NEXT line to open with `()`, which a plain grep cannot see, so the header
  # list is built once and SORTED — two greps concatenated would break the ascending walk below.
  for ln in $( { grep -nE '^[[:space:]]*(function[[:space:]]+)?[^[:space:](){;]+[[:space:]]*\([[:space:]]*\)([[:space:]]*(\{.*|\(.*|(if|while|until|for|select|case|\[\[|\(\().*|\\[[:space:]]*|#.*)?)$|^[[:space:]]*function[[:space:]]+[^[:space:](){;]+([[:space:]]*(\{.*|\([[:space:]]*\).*|(if|while|until|for|select|case|\[\[|\(\().*|\\[[:space:]]*|#.*)?)$' "$file" | cut -d: -f1
                 awk 'NR > 1 && prev ~ /^[[:space:]]*(function[[:space:]]+)?[^[:space:](){;]+[[:space:]]*\\[[:space:]]*$/ && $0 ~ /^[[:space:]]*\([[:space:]]*\)/ { print NR - 1 } { prev = $0 }' "$file"; } | sort -n -u); do
    [ "$ln" -le "$want" ] || break
    best="$ln"
  done
  [ "${best:-0}" -gt 0 ] || return 0
  sed -n "${best}p" "$file" | sed -nE 's/^[[:space:]]*(function[[:space:]]+)?([^[:space:](){;]+).*/\2/p'
}
# ⛔ THE RESOLVER IS TESTED ON THE SPELLINGS THEMSELVES, NOT ON A HEURISTIC. A broad
# "looks definition-shaped" counter was tried first and it FALSE-RED on line 616 — `function secs(t,
# n,a,i,…)`, an AWK function inside a single-quoted awk program, which the shell never defines. A
# count that cannot tell bash from awk is a gate that refuses correct code, so the fail-closed duty is
# carried here instead: every bash-legal header form must resolve to its own name, verified by driving
# func_for over a fixture built for exactly that. Each of these was INVISIBLE before the charset was
# widened (`[a-z_]` only) and silently attributed the read to the PRECEDING function — whose
# allowlisted pair then covered it (review P1, reproduced: `ZzFutureHelper() { local s="$1"; }` after
# `bounded()` left the suite at FAIL=0 and both `bounded:s` lines ✅).
{
  printf 'outer_fn() {\n  :\n}\n'
  printf 'ZzFutureHelper() {\n  local s="$1"\n}\n'
  printf 'ZzSpacedHelper () {\n  local s="$1"\n}\n'
  printf 'ZzTightHelper(){\n  local s="$1"\n}\n'
  printf 'function ZzKeyword {\n  local s="$1"\n}\n'
  printf 'zz-dashed-name() {\n  local s="$1"\n}\n'
  printf 'ZzNextLine()\n{\n  local s="$1"\n}\n'
  printf 'ZzCommentBrace()  # a note\n{\n  local s="$1"\n}\n'
  printf 'ZzSpacedParen( ) {\n  local s="$1"\n}\n'
  printf 'ZzQuotedComment()  # it says "hi"\n{\n  local s="$1"\n}\n'
  printf 'ZzContHeader() \\\n{\n  local s="$1"\n}\n'
  printf 'ZzSubshell() (\n  local s="$1"\n)\n'
  printf 'ZzIfBody() if true; then\n  local s="$1"\nfi\n'
  printf 'ZzCaseBody() case x in\n  local s="$1"\n  ;;\nesac\n'
} > "$T/hdr.sh"
for _want in ZzFutureHelper ZzSpacedHelper ZzTightHelper ZzKeyword zz-dashed-name ZzNextLine ZzCommentBrace ZzSpacedParen ZzQuotedComment ZzContHeader ZzSubshell ZzIfBody ZzCaseBody; do
  _got="$(func_for "$T/hdr.sh" "$(grep -nE "^[[:space:]]*(function[[:space:]]+)?${_want//-/\\-}" "$T/hdr.sh" | cut -d: -f1 | head -1)")"
  [ "$_got" = "$_want" ] && ok "func_for: header '$_want' resolves to itself (not to the preceding 'outer_fn')" \
    || bad "func_for: header '$_want' resolved to '${_got:-<nothing>}' — a read under it would be graded against the wrong function's allowlist"
done
unset _want _got

# Walk one file and PRINT one record per positional read: "<verdict> <line> <function> <name> <read>".
# ⛔ A FUNCTION, so the walk can be run over a SYNTHETIC file the suite controls (the non-vacuity arm
# further down). While it was inline, the only thing tested was that it ran over the shipped file —
# which is precisely the shape that lets a name-keyed allowlist stay green.
audit_scan() { # <file>
  local file="$1" line ln body fn
  while IFS= read -r line; do
    ln="${line%%:*}"; body="${line#*:}"
    fn="$(func_for "$file" "$ln")"
    while read -r verdict var rd; do
      [ -n "${verdict:-}" ] || continue
      printf '%s %s %s %s %s\n' "$verdict" "$ln" "${fn:-?}" "$var" "$rd"
    done < <(audit_line "$body")
  done < <(grep -nE '^[[:space:]]*local[[:space:]]' "$file")
}
# Grade one file's reads against REQUIRED_READS. Counts land in AUDIT_*; the RETURN is the number of
# ungraded/fatal pairs, so a caller can assert on it without re-deriving the decision.
audit_grade() { # <file> <emit 1|0>
  local file="$1" emit="$2" verdict ln fn var rd bad_n=0 graded=0
  AUDIT_DEF=0; AUDIT_BARE=0; AUDIT_DER=0; AUDIT_REQ=0; AUDIT_MATCHED=""
  while read -r verdict ln fn var rd; do
    graded=$((graded + 1))
    case "$verdict" in
      defaulted) AUDIT_DEF=$((AUDIT_DEF + 1))
                 [ "$emit" = 1 ] && ok "audit: $fn:$var (line $ln) DEFAULTED to empty — absent means the caller's empty value" ;;
      invented)  bad_n=$((bad_n + 1))
                 [ "$emit" = 1 ] && bad "audit: $fn:$var (line $ln) defaults $rd to a NON-EMPTY value — absent must not invent a mode (a rehearsal would arm itself)" ;;
      unparsed)  bad_n=$((bad_n + 1))
                 [ "$emit" = 1 ] && bad "audit: $fn (line $ln) has a positional read the assignment scan CANNOT ATTRIBUTE — the read sits outside the quoted value it is looked for in (a split value like \"\$D\"/\"\$1.x\", a literal in single quotes, or an arithmetic). Rewrite it as one \"…\$N…\" token so it can be judged; an unattributed read is ungraded" ;;
      derived)   AUDIT_DER=$((AUDIT_DER + 1))
                 [ "$emit" = 1 ] && ok "audit: $fn:$var (line $ln) EMBEDS $rd in a larger value — a note; it is graded above, not excused" ;;
      *)         AUDIT_BARE=$((AUDIT_BARE + 1))
                 case "$REQUIRED_READS" in
                   *" $fn:$var "*) AUDIT_REQ=$((AUDIT_REQ + 1))
                       AUDIT_MATCHED="$AUDIT_MATCHED $fn:$var"
                       [ "$emit" = 1 ] && ok "audit: $fn:$var (line $ln) REQUIRED — reads $rd bare; a caller bug is the right outcome" ;;
                   *) bad_n=$((bad_n + 1))
                       [ "$emit" = 1 ] && bad "audit: $fn:$var (line $ln) reads $rd BARE and is not on the REQUIRED list — decide it, do not imitate its neighbour" ;;
                 esac ;;
    esac
  done < <(audit_scan "$file")
  # ⛔ NO VERDICT WITHOUT AN OBSERVATION (agent-infra#2096/#2121 — and the tree-wide
  # `scripts/check-false-pass-shapes.sh` gate is the authority, not this comment). A loop over a
  # substitution can iterate ZERO times, so a function that only counts failures reports PASS over
  # an empty read — here that would be a file with no `local` bindings at all, i.e. a scan that
  # observed nothing. `graded` is the observation count and a zero-observation grade REFUSES.
  [ "$graded" -gt 0 ] || return 1
  return "$bad_n"
}
# ⛔ THE NON-VACUITY ARM FOR THE (function, name) KEY. A synthetic file with one allowlisted read and
# one NEW helper that reuses TWO names that ARE on the list under other functions (`s` from
# `bounded:s`, `who` from `controller_heartbeat_verdict:who`). Under the FUNCTION key both are
# ungraded→bad (2); under the old NAME key both would pass (0). So this arm fails the moment somebody
# re-keys the list by name, which is the P1 regression it exists to catch.
cat > "$T/audit-mutant.sh" <<'SH'
state_write() {
  local role="$1" rc="$2"
}
future_helper() {
  local s="$1" who="$2"
}
SH
MT_BAD=0
# `emit 0` keeps the mutant's own failures out of the summary counters: every ok()/bad() call site in
# audit_grade is guarded by `[ "$emit" = 1 ] &&`, so with emit=0 neither is ever invoked.
audit_grade "$T/audit-mutant.sh" 0; MT_BAD=$?
[ "$MT_BAD" -eq 2 ] && ok "audit[self-test]: a NEW helper reusing allowlisted NAMES is graded BAD twice (the key is function:name)" \
  || bad "audit[self-test]: the mutant graded $MT_BAD bad pair(s), want 2 — the allowlist is name-keyed again (or the walk lost the function)"
# …and the allowlisted pair on the SAME mutant is graded OK, so the arm above is not vacuous either.
_allow="$(audit_scan "$T/audit-mutant.sh" | awk '$1 == "bare" && $3 == "state_write" && $4 == "role"')"
case "$_allow" in
  *"state_write role"*) ok "audit[self-test]: the same mutant's allowlisted state_write:role IS seen (the walk found both functions)" ;;
  *) bad "audit[self-test]: the mutant's state_write:role was not seen (got '${_allow:-<nothing>}') — the two-bad arm could be passing for the wrong reason" ;;
esac
AUDIT_DEF=0; AUDIT_BARE=0; AUDIT_DER=0; AUDIT_REQ=0
BADSUM=0
audit_grade "$DOCTOR" 1; BADSUM=$?
[ "$BADSUM" -eq 0 ] && ok "audit: every bare read in the shipped file is a declared function:name pair" \
  || bad "audit: $BADSUM bare/invented read(s) in the shipped file are undeclared — see the ❌ lines above"
[ "$((AUDIT_DEF + AUDIT_BARE))" -ge 15 ] && [ "$AUDIT_DEF" -ge 4 ] \
  && ok "audit: classified $((AUDIT_DEF + AUDIT_BARE)) positional reads ($AUDIT_DEF defaulted-to-empty, $AUDIT_REQ required) plus $AUDIT_DER embedding note(s)" \
  || bad "audit: classified only $((AUDIT_DEF + AUDIT_BARE)) reads ($AUDIT_DEF defaulted) — the scan is broken, so this arm proves nothing"
# ⛔ EVERY LISTED PAIR MUST BE MATCHED — twice over, because each check misses what the other
# catches. The COUNT catches a listed pair matched TWICE while another is matched ZERO times;
# the MEMBERSHIP check catches a listed pair the walk never saw at all. `AUDIT_REQ` alone was a
# count, so on a copy of the doctor carrying `bounded`'s `$1` weakened to `${1:-}` PLUS a nested
# `local s="$1"` (whose read the broken resolver attributed to `bounded`) the count still read
# 19 == 19 and the suite stayed green (review P2, reproduced).
_DISTINCT_MATCHED="$(printf '%s\n' $AUDIT_MATCHED | sort -u | wc -l)"
_DISTINCT_LISTED="$(printf '%s\n' $REQUIRED_READS | sort -u | wc -l)"
[ "$_DISTINCT_MATCHED" -eq "$_DISTINCT_LISTED" ] \
  && ok "audit: $_DISTINCT_MATCHED distinct pair(s) matched, one for each of the $_DISTINCT_LISTED listed" \
  || bad "audit: $_DISTINCT_MATCHED distinct pair(s) matched for $_DISTINCT_LISTED listed — a listed read is missing and another is standing in for it twice"
UNMATCHED=0
for _pair in $REQUIRED_READS; do
  case " $AUDIT_MATCHED " in
    *" $_pair "*) ;;
    *) UNMATCHED=$((UNMATCHED + 1))
       bad "audit: REQUIRED_READS lists $_pair but the walk never matched it — that read is no longer bare, so its coverage was silently lost" ;;
  esac
done
[ "$UNMATCHED" -eq 0 ] && ok "audit: every listed pair was matched by name (no pair is covered only through a same-named neighbour)" \
  || bad "audit: $UNMATCHED listed pair(s) were never matched"
# …and each dispatched role's mode read must BE the empty-defaulted one (the derived list again).
while read -r _r _f; do
  [ -n "${_r:-}" ] || continue
  # ⛔ NO PIPE INTO `grep -q` (#841): under the suite's `pipefail` a quiet grep exits at its first
  # match, awk takes SIGPIPE, and the pipeline status makes this `if` take the ELSE branch — the
  # measured flake was one role failing while the other three passed on the SAME file.
  # ⛔ THE RANGE START IS A HEADER FORM TOO (review P2, reproduced): `awk "/^run_${_f}\\(\\) \\{/"` only
  # matched `run_x() {` at column 0, so a role whose header is reformatted (next-line brace, `( )`,
  # indented) yielded an EMPTY range and the arm then reported "does NOT read its mode as ${1:-}" over
  # a file that reads it correctly. The start pattern now accepts the forms func_for accepts.
  if grep -qE 'local dry="\$\{1(:-|-)\}"' < <(awk "/^[[:space:]]*(function[[:space:]]+)?run_${_f}[[:space:]]*\\([[:space:]]*\\)([[:space:]]*\\{.*|[[:space:]]*$)/,/^\\}/" "$DOCTOR"); then
    ok "audit: run_${_f}'s mode read is DEFAULTED TO EMPTY (it survives the absent/empty mode the scheduler passes)"
  else
    bad "audit: run_${_f} does NOT read its mode as \"\${1:-}\" — a bare dispatch would kill or rehearse the scheduler"
  fi
done <<<"$ROLES"

# Arm D — THE DIRECTION THAT MATTERS, behaviourally: with no flag a destructive verb ACTS, with
# `--dry-run` it does not. Arm C pins the source value; this pins what the value DOES, so "empty
# means live" cannot be satisfied by a comment.
reset_state; reset_tmux; reset_ps; rm -f "$T/writing"
mk_lane lane-42 4242
doc reap --dry-run
killed lane-42 && bad "rehearsal: 'reap --dry-run' KILLED the lane (a rehearsal took the destructive path)" \
  || ok "rehearsal: 'reap --dry-run' killed nothing (the opt-in rehearsal still rehearses)"
reset_state; reset_tmux; reset_ps; rm -f "$T/writing"
mk_lane lane-42 4242
OUT="$(bash -u -c "source '${PRELUDE:-/dev/null}'; run_reap" 2>&1)"; RC=$?
killed lane-42 && ok "live: run_reap with NO argument REAPED the lane (empty mode = a live pass, rc=$RC)" \
  || bad "live: run_reap with NO argument did NOT reap — an absent mode took the rehearsal path, rc=$RC — $OUT"

# Arm E — the SAME rule the reap arm above proves, for the OTHER thing a live loop now really does:
# a real-sized queue read must not GRIND. `run_merge` used to ask "is the answer empty?" with
# `[ -z "${prs//[[:space:]]/}" ]`, which is SUPERLINEAR: it is quadratic in the payload, so a real
# queue answer already costs many seconds of PURE CPU inside that one builtin —
# no syscalls, merge lock held, so MERGE_BUDGET_S could not bound it and the whole sequential loop
# (doctor, reap, hygiene) stalled behind it on the first tick. cleanup-stale-branches.sh:694
# documents the identical hole and its fix: a `case` glob, same set, O(n).
# ⛔ TWO DIFFERENT NUMBERS, MEASURED SEPARATELY, AND NEITHER IS DERIVED FROM THE OTHER (review P2).
# On this box, bash 5.2.21, the old empty-check inside one builtin: 322 KiB (330,246 B) → 14.5 s and
# 843 KiB (the 862,802 B fixture below) → 99.8 s (2.6x bytes, 6.9x time — quadratic); the `case` glob
# → 9 ms and 26 ms on the same two payloads. The fixture is deliberately larger than a real queue
# answer so the PRE-FIX code cannot finish it inside the 30 s bound — the bound is what DISCRIMINATES,
# so the fixture has to sit comfortably on the wrong side of it. (An earlier revision of this comment
# quoted "349 KB → 84 s" as if it were this box's measurement; it is not reproducible here — 330 KB
# costs 14.5 s — so it is gone rather than reconciled.)
reset_state; reset_tmux; reset_ps; rm -f "$T/writing"
python3 - "$T/gh/prs.json" <<'PYJSON'
import json, sys
# 1200 entries, pretty-printed: the whitespace-heavy shape a real answer has. Drafts, so every one is
# skipped cheaply and the ONLY cost measured is the empty-check itself.
# A real PR carries a title and a body; the SIZE is what this arm needs, and the iteration count is
# what keeps the FIXED path fast, so the size comes from the text, not from more candidates.
body = ("this pull request touches the harness and explains, at length, why the change is safe; " * 6)
rows = [{"number": 1000 + i, "head": {"sha": "%040d" % i}, "draft": True,
         "title": "fix(harness): a title of ordinary length", "body": body} for i in range(1200)]
open(sys.argv[1], "w").write(json.dumps(rows, indent=2))
PYJSON
PAYLOAD_BYTES="$(wc -c < "$T/gh/prs.json")"
[ "${PAYLOAD_BYTES:-0}" -gt 300000 ] && ok "merge: the fixture is a real-sized payload (${PAYLOAD_BYTES} bytes)" \
  || bad "merge: the fixture is only ${PAYLOAD_BYTES:-0} bytes — too small to discriminate"
START_S="$(date +%s)"
OUT="$(timeout 30 bash "$DOCTOR" merge --dry-run 2>&1)"; RC=$?
ELAPSED_S=$(( $(date +%s) - START_S ))
[ "$RC" -ne 124 ] && ok "merge: a ${PAYLOAD_BYTES}-byte queue read COMPLETES (rc=$RC in ${ELAPSED_S}s, not killed at 30s)" \
  || bad "merge: the pass was KILLED at 30s on a real-sized payload (rc=$RC) — the empty-check is superlinear again"
# …and it must still reach a verdict, not merely survive: the record says what it did with the queue.
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state" 2>/dev/null)" in
  '') bad "merge: no verdict recorded after the big-payload pass" ;;
  *)  ok "merge: it recorded a verdict on the big payload — $(sed -n 's/^last_result=//p' "$T/o/state/roles/merge.state" | cut -c1-80)" ;;
esac
rm -f "$T/gh/prs.json"

# ── summary ─────────────────────────────────────────────────────────────────────────────────────
echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then echo "  ❌ $FAIL check(s) failed"; exit 1; fi
echo "  ✅ all checks passed"
