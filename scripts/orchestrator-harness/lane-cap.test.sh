#!/usr/bin/env bash
# lane-cap.test.sh — the wall-clock cap: derived from the job, and what it must LEAVE BEHIND
# (agent-infra#2045).
#
# WHAT WENT WRONG, because every check below is one of its fingers. Measured 2026-10-18 on eight
# background lanes: three produced nothing, and one was working the whole time — 269,237 chars of
# transcript, a log of 1,887 bytes with ZERO model output, 7 modified files uncommitted in the
# worktree, branch still at origin/main, no `.rc`, no report file, and a notifier that reported
# `worker finished: commits=0 PR=none` — byte-identical to a lane that had legitimately had nothing to
# do. The work was recovered only because a human noticed dirty files.
#
# HOW THESE CHECKS ARE WRITTEN. The subject is the SHIPPED `spawn-gate.sh` and the SHIPPED
# `nonblocking-dispatch.sh`: every arm sources/drives the real `run_agent`, the real cap watcher and
# the real classifier, then asserts on what they DID (which files exist, what the record says, what
# exit code came back, whether the worker is really dead). A check that re-implements the cap passes
# on the broken tree too, which is the vacuity this suite exists to avoid.
#
# ⛔ `rc=$?` IS CAPTURED ON THE LINE IMMEDIATELY AFTER EVERY TESTED COMMAND, never `ck "… $?"`
# (§7.4's defect: `$?` inside a `ck` argument is expanded AFTER any `$(…)` in that argument runs).
#
# ⛔ THE STUB `pi` IS AN **EXPORTED FUNCTION** AS WELL AS A FILE STUB. The launcher does
# `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, which puts a SYSTEM `pi` AHEAD of $TMP/bin — so
# a file stub alone is shadowed and the arm would invoke the REAL agent (measured and fixed for #1828
# in spawn-gate.test.sh). A shell function is resolved before any PATH lookup and cannot be shadowed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/spawn-gate.sh"
NB="$HERE/nonblocking-dispatch.sh"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
O="$TMP/O"; mkdir -p "$O/state" "$O/logs" "$TMP/bin"
export PI_LOG="$TMP/pi.log"
export PI_PIDFILE="$TMP/worker.pid"
: > "$PI_LOG"; rm -f "$PI_PIDFILE"
# ── the stub worker ────────────────────────────────────────────────────────────────────────────────
# `sleep 600` and no report file: it is a lane in the middle of real work when its cap fires, which is
# exactly the measured shape. Its mode is selected by $PI_MODE so one function covers every arm.
pi() {
  echo "PI_RAN mode=${PI_MODE:-}" >> "$PI_LOG"
  # ⛔ THE WORKER'S OWN PID IS RECORDED so "the hard kill really landed" can be asserted on the real
  # object. And every mode `exec`s its sleeper: a shell that spawns `sleep 600` and is then KILLed
  # leaves the sleep ORPHANED and burning the box (the disclosed leak spawn-gate.test.sh names) —
  # exec keeps one process, so what the test checks is what the cap actually killed.
  # `BASHPID` is bash 4+, and this suite must run on the shipped macOS bash 3.2 — where reading it
  # under `set -u` ABORTS the stub (measured: rc=127, nothing written, the arm silently vacuous). `$PPID`
  # read from a child sh IS this subshell's pid, on every bash.
  echo "${BASHPID:-$(sh -c 'echo $PPID')}" > "$PI_PIDFILE"
  case "${PI_MODE:-}" in
    work-ignore-term)
      # Writes tracked AND untracked work, then makes the hard kill necessary: it ignores TERM.
      echo "work in progress $(date +%s)" >> wip.txt
      echo "untracked payload" > UNTRACKED.txt
      trap '' TERM; exec sleep 600 ;;
    work-honour-term)
      echo "committed-nothing work $(date +%s)" >> wip.txt
      echo "untracked payload" > UNTRACKED.txt
      exec sleep 600 ;;
    hung-ignore-term)
      # Not a single byte written and not a single line logged: the definition of a hang, and the
      # state the cap EXISTS to kill. It must not be extended by anything.
      trap '' TERM; exec sleep 600 ;;
    idle)
      exit 0 ;;
    *) exit 0 ;;
  esac
}
export -f pi
printf '#!/bin/sh\nprintf "PI_RAN mode=%%s\\n" "${PI_MODE:-}" >> "$PI_LOG"\nexit 0\n' > "$TMP/bin/pi"
chmod +x "$TMP/bin/pi"
# Pinned BY NAME: the whole rig rests on the function surviving into the callers' environment, so a
# future edit that drops `export -f pi` names its own cause instead of arriving as a confusing red.
env | grep -q '^BASH_FUNC_pi'; rc=$?
ck "the rig's pi stub is EXPORTED into the callers' environment (a function beats the callers' PATH prepend)" $rc

echo "==> lane-cap self-test ($HERE)"

# ── a scratch repo with origin/main, so the snapshot has a real base ─────────────────────────────
mkrepo() { # mkrepo <dir>
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q .
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf 'base\n' > "$d/tracked.txt"; printf 'wip base\n' > "$d/wip.txt"
  git -C "$d" add -A && git -C "$d" commit -qm base
  git -C "$d" update-ref refs/remotes/origin/main HEAD
}
REPO="$TMP/repo"; mkrepo "$REPO"
PROMPT_PLAIN="$TMP/prompt-plain.txt"; printf 'do the work\n' > "$PROMPT_PLAIN"

# drive <cap-arg> <prompt> <log> [<extra-env…>]  → "<rc> <capped> <cap> <source> <snapshot>"
# Runs the SHIPPED run_agent in the scratch repo. `$1` is passed straight through, so "" exercises the
# "the job declares its own cap" path.
drive() {
  local cap="$1" prompt="$2" log="$3"; shift 3
  ( cd "$REPO" && env PATH="$TMP/bin:$PATH" O="$O" DISK_MIN_FREE_MB=1 MAX_LOAD=999999999 \
      AGENT_CAP_GRACE="${AGENT_CAP_GRACE:-2}" AGENT_CAP_SNAPSHOT_MAX=10 "$@" \
      bash -c '
        . "$1" || exit 99
        cd "$2" || exit 98
        run_agent "$3" "$4" "$5" "lane-cap test"
        printf "%s %s %s %s %s\n" "$?" "$AGENT_CAPPED" "${AGENT_CAP_SECONDS:-?}" "${AGENT_CAP_SOURCE:-?}" "${AGENT_CAP_SNAPSHOT:--}"
      ' _ "$GATE" "$REPO" "$cap" "$log" "$prompt" 2>/dev/null | tail -1 )
}

# ── 1) THE CAP IS DERIVED FROM THE JOB, not a single global default ───────────────────────────────
# A verification-heavy prompt (this repo's selftest.sh is 411 assertions, install-launchd-durability
# 269) spends a 35-minute default before it reaches its commit. The declaration travels WITH the job.
capdecl() { # capdecl <cap-arg> <prompt-text> → "<cap> <source>" from the log line run_agent writes
  local caparg="$1" text="$2" p="$TMP/p-cap.txt" l="$TMP/l-cap.log"
  printf '%s\n' "$text" > "$p"; : > "$l"
  PI_MODE=idle drive "$caparg" "$p" "$l" >/dev/null 2>&1
  sed -n 's/.*wall_limit=\([0-9]*\)s .*cap_source=\([a-z]*\).*/\1 \2/p' "$l" | tail -1
}
got="$(capdecl "" "do the work
ESTIMATE: 5400")"; rc=$?
ck "a prompt that DECLARES \`ESTIMATE: 5400\` sets the cap to 5400s, source=prompt (got '${got:-<none>}')" $([ "$got" = "5400 prompt" ] && echo 0 || echo 1)
got="$(capdecl "" "CAP: 90m")"
ck "the declaration accepts units — \`CAP: 90m\` is 5400s (got '${got:-<none>}')" $([ "$got" = "5400 prompt" ] && echo 0 || echo 1)
got="$(capdecl "" "  estimate = 1h")"
ck "the declaration is case-insensitive, accepts \`=\`, and is indented — \`  estimate = 1h\` is 3600s (got '${got:-<none>}')" $([ "$got" = "3600 prompt" ] && echo 0 || echo 1)
got="$(capdecl "" "do the work")"
ck "a prompt that declares NOTHING falls back to the default and SAYS SO — source=default, not a silent global (got '${got:-<none>}')" $([ "$got" = "${AGENT_CAP_DEFAULT:-3000} default" ] && echo 0 || echo 1)
got="$(capdecl 7 "ESTIMATE: 5400")"
ck "an explicit timeout from the dispatcher WINS over the prompt's declaration (got '${got:-<none>}')" $([ "$got" = "7 explicit" ] && echo 0 || echo 1)
got="$(capdecl "" "the estimate: is that 5400 is a lot of time, and I mean it")"
ck "PROSE that merely contains the words is NOT a declaration (got '${got:-<none>}')" $([ "$got" = "${AGENT_CAP_DEFAULT:-3000} default" ] && echo 0 || echo 1)

# ── 2) KILLED AT THE CAP: the work survives the process (the measured case) ───────────────────────
# The stub writes one modified TRACKED file and one UNTRACKED file and never commits — the measured
# worktree state (7 modified files, branch at origin/main). It ignores TERM, so the bounded grace
# expires and the KILL has to land.
git -C "$REPO" checkout -q -- .; git -C "$REPO" clean -qfd
LOG2="$TMP/l1.log"; : > "$LOG2"
t0="$(date +%s)"
res="$(PI_MODE=work-ignore-term AGENT_CAP_GRACE=2 drive 4 "$PROMPT_PLAIN" "$LOG2")"; rc=$?
t1="$(date +%s)"; elapsed=$(( t1 - t0 ))
set -- $res
rcv="${1:-}"; capped="${2:-}"; snap="${5:-}"
ck "a worker that ignores TERM is still KILLED at the cap: rc=$rcv (128+9), capped=$capped" \
   $([ "$capped" = "1" ] && { [ "$rcv" = "137" ] || [ "$rcv" = "143" ]; } && echo 0 || echo 1)
{ [ "$rcv" = "137" ] || [ "$rcv" = "143" ]; }; rc=$?
ck "the exit status of the capped run is RECORDED and non-zero (property 3: got rc=$rcv)" $rc
{ [ "$elapsed" -ge 4 ] && [ "$elapsed" -le $(( 4 + 2 + 10 + 15 )) ]; }; rc=$?
ck "the cap fired near its bound and the grace/snapshot are BOUNDED — ${elapsed}s for cap=4 grace=2 snapmax=10" $rc
[ -n "${snap:-}" ] && [ "$snap" != "-" ] && [ -d "$snap" ]; rc=$?
ck "the worktree was SNAPSHOTTED at the cap (dir: ${snap:-<none>})" $rc
{ [ -s "$snap/wip.diff" ] && grep -q 'work in progress' "$snap/wip.diff"; }; rc=$?
ck "the snapshot carries the UNCOMMITTED work — wip.diff names what the stub wrote (a $(wc -c < "$snap/wip.diff" 2>/dev/null | tr -d ' ')-byte diff)" $rc
{ [ -s "$snap/untracked.tgz" ] && grep -qx 'UNTRACKED.txt' <<<"$(tar tzf "$snap/untracked.tgz" 2>/dev/null)"; }; rc=$?
ck "…and the UNTRACKED file, which a patch cannot carry — untracked.tgz lists UNTRACKED.txt" $rc
# ⛔ THE INCIDENT MADE NO COMMIT AT ALL, so `git format-patch` alone would have preserved 0 bytes
# while seven modified files sat on disk. This asserts the gap that made the tarball + `git diff`
# necessary instead of leaving the design to be re-litigated:
[ -f "$snap/commits.patch" ] && [ ! -s "$snap/commits.patch" ]; rc=$?
ck "the incident's shape is reproduced: the work was UNCOMMITTED, so format-patch alone is EMPTY (0 bytes) — the diff/tarball is what preserves it" $rc
grep -q 'total_bytes=0' "$snap/MANIFEST"; rc=$?
ck "…and the MANIFEST records the byte count instead of asserting a preserve it did not make (total_bytes must be > 0 here)" $([ "$rc" -ne 0 ] && echo 0 || echo 1)
REC="$O/state/cap-agent-.tsv"
[ -s "$REC" ]; rc=$?
ck "the cap is RECORDED durably at \$O/state/cap-agent-.tsv (property 3)" $rc
{ [ "$(grep -c 'at-cap' "$REC" 2>/dev/null)" -ge 1 ] && [ "$(grep -c 'settled' "$REC" 2>/dev/null)" -ge 1 ]; }; rc=$?
ck "the record carries BOTH rows — \`at-cap\` (snapshot verified) and \`settled\` (the exit status), append-only" $rc
awk -F'\t' -v want="$rcv" '$2=="settled" && $10==want {found=1} END{exit !found}' "$REC"; rc=$?
ck "…and the settled row carries the SAME exit status the caller received (rc=$rcv)" $rc
awk -F'\t' -v want="$snap" '$2=="at-cap" && $8==want {found=1} END{exit !found}' "$REC"; rc=$?
ck "…and the at-cap row names the snapshot directory, so the record is not a dead end" $rc
{ [ -s "$O/state/caps.tsv" ] && grep -q 'at-cap' "$O/state/caps.tsv"; }; rc=$?
ck "…and the fleet-wide append-only series \$O/state/caps.tsv received the same row" $rc
grep -q 'CAPPED' "$LOG2" && grep -q 'snapshot=' "$LOG2"; rc=$?
ck "the lane LOG says so too, in words an operator can read without knowing the record exists" $rc
# The kill must have really landed, not merely returned a status: ask the worker's OWN pid.
WPID="$(cat "$PI_PIDFILE" 2>/dev/null || true)"
{ [ -n "$WPID" ] && ! kill -0 "$WPID" 2>/dev/null; }; rc=$?
ck "the stub worker (pid ${WPID:-<unrecorded>}) is really GONE — the hard kill landed on the process, not only on the status" $rc

# ── 3) a TERM-respecting worker is checkpointed the same way, and says which signal ended it ──────
git -C "$REPO" checkout -q -- .; git -C "$REPO" clean -qfd; : > "$PI_LOG"
res="$(PI_MODE=work-honour-term AGENT_CAP_GRACE=3 drive 4 "$PROMPT_PLAIN" "$TMP/l2.log")"
set -- $res; rcv="${1:-}"; snap="${5:-}"; rec_last="$(tail -1 "$O/state/cap-agent-.tsv" 2>/dev/null)"
{ [ "$rcv" = "143" ] && grep -q 'exited' <<<"$rec_last"; }; rc=$?
ck "a TERM-respecting worker exits 143 and the record distinguishes \`exited\` from \`killed\` (rc=$rcv)" $rc
{ [ -s "$snap/wip.diff" ] && grep -q 'committed-nothing work' "$snap/wip.diff"; }; rc=$?
ck "…and its work is in the snapshot (the snapshot happens AFTER the bounded grace, not before it)" $rc

# ── 4) THE CAP'S ORIGINAL PURPOSE IS NOT RESURRECTED: a genuine hang is still killed, unextended ──
# The fix for a lost lane must never turn into "a hung worker is never killed". The stub writes
# nothing and logs nothing; nothing may extend it, and the record must say bytes=0 rather than
# pretend a preserve happened.
git -C "$REPO" checkout -q -- .; git -C "$REPO" clean -qfd
t0="$(date +%s)"
res="$(PI_MODE=hung-ignore-term AGENT_CAP_GRACE=1 drive 3 "$PROMPT_PLAIN" "$TMP/l3.log")"
t1="$(date +%s)"; h_elapsed=$(( t1 - t0 ))
set -- $res; rcv="${1:-}"; snap="${5:-}"
{ [ "$rcv" = "137" ] && [ "$h_elapsed" -le $(( 3 + 1 + 10 + 15 )) ]; }; rc=$?
ck "a HUNG worker (no output, no files, ignores TERM) is still killed at its cap: rc=$rcv in ${h_elapsed}s for cap=3 — nothing extended it" $rc
grep -q 'bytes=0' "$O/state/cap-agent-.tsv"; rc=$?
ck "…and its record says bytes=0 — an empty snapshot is REPORTED, never dressed up as a preserve" $rc
[ ! -s "$snap/wip.diff" ] && [ ! -s "$snap/untracked.tgz" ]; rc=$?
ck "…and the snapshot artifacts really are empty (nothing was invented)" $rc

# ── 5) THE VERDICT: a lane that produced nothing is FAILED, not "finished" ───────────────────────
# ⛔ THE DISTINGUISHABLE STATES ARE THE DELIVERABLE. `commits=0` was reported identically for "had
# nothing to do" and "was killed with seven files of uncommitted work", so a supervisor never
# re-dispatched the lost lane. These arms drive the SHIPPED classifier with fabricated INPUTS (rc,
# pid, stamp, record) — never with a fabricated verdict.
V="$TMP/vstate"; mkdir -p "$V/bg" "$V/state"
mkwr() { # mkwr <dir> <commits> <dirty 0|1>
  local d="$1"
  mkrepo "$d"
  [ "${2:-0}" -gt 0 ] && { printf 'c\n' > "$d/c.txt"; git -C "$d" add -A; git -C "$d" commit -qm c; }
  [ "${3:-0}" -gt 0 ] && printf 'dirty\n' >> "$d/tracked.txt"
}
stamp() { # stamp <dir> <name> <prompt> <started_epoch> [<cap>]
  printf 'name=%s\nworktree=%s\nbranch=main\nprompt=%s\nstarted=%s\nstarted_epoch=%s\ncap=%ss\ncap_source=explicit\n' \
    "$2" "$1" "$3" "2026-10-18 00:00:00" "$4" "${5:-3000}" > "$V/bg/$2.started"
}
verdict() { O="$V" bash "$NB" --verdict "$1" 2>/dev/null; }
verdict_rc() { O="$V" bash "$NB" --verdict "$1" >/dev/null 2>&1; echo $?; }
statusline() { O="$V" bash "$NB" --status "$1" 2>/dev/null; }
REP="$TMP/reports"; mkdir -p "$REP"
PROMPT_REP="$TMP/prompt-report.txt"; printf 'do it\nReport to %s/REPORT-demo.md when done.\n' "$REP" > "$PROMPT_REP"
now="$(date +%s)"

# 5a killed-at-cap — from the REAL record written by the run in §2/§3 (plus the epoch filter).
mkwr "$V/wt-cap" 0 0
printf 'x\n' > "$V/bg/capnote"; : > "$V/bg/capped.rc"
stamp "$V/wt-cap" capped "$PROMPT_PLAIN" "$(( now - 10 ))"
printf '%s\tat-cap\tbg\tcapped\t4\texplicit\t6\t/tmp/backup\tsnapshot=/tmp/backup bytes=500\t-\n' "$now" >> "$V/state/cap-bg-capped.tsv"
got="$(verdict capped)"; rc=$?
{ [ "$got" = "killed-at-cap" ] && [ "$(verdict_rc capped)" = "1" ]; }; rc=$?
ck "VERDICT killed-at-cap: recorded cap + recorded status is FAILED (got '$got', exit $(verdict_rc capped))" $rc
grep -q '/tmp/backup' <<<"$(statusline capped)"; rc=$?
ck "…and --status names the snapshot, so the operator can recover the work from the line" $rc

# 5b the epoch filter: the SAME record, but from a PREVIOUS run of the same name, must not classify
# a fresh healthy run as killed. (The record and caps.tsv are append-only across runs.)
mkwr "$V/wt-stale" 0 0; : > "$V/bg/stale.rc"
stamp "$V/wt-stale" stale "$PROMPT_PLAIN" "$(( now + 500 ))"
printf '%s\tat-cap\tbg\tstale\t4\texplicit\t6\t/tmp/old\tsnapshot=/tmp/old bytes=5\t-\n' "$(( now - 500 ))" >> "$V/state/cap-bg-stale.tsv"
got="$(verdict stale)"; rc=$?
ck "a cap record from an EARLIER run of the same name is not inherited — a fresh run reads '$got', not killed-at-cap" $([ "$got" != "killed-at-cap" ] && echo 0 || echo 1)

# 5c lost — no exit status, pid gone.
mkwr "$V/wt-lost" 0 0
printf '999999' > "$V/bg/lost.pid"; stamp "$V/wt-lost" lost "$PROMPT_PLAIN" "$now"
got="$(verdict lost)"; rc=$?
{ [ "$got" = "lost" ] && [ "$(verdict_rc lost)" = "1" ]; }; rc=$?
ck "VERDICT lost: no exit status and a dead pid is FAILED (got '$got')" $rc

# 5d failed rc=7.
mkwr "$V/wt-failed" 0 0; printf '7' > "$V/bg/failed.rc"; stamp "$V/wt-failed" failed "$PROMPT_PLAIN" "$now"
got="$(verdict failed)"; rc=$?
{ [ "$got" = "failed" ] && [ "$(verdict_rc failed)" = "1" ]; }; rc=$?
ck "VERDICT failed: rc=7 is FAILED (got '$got')" $rc

# 5e no-report — the prompt names a report path and it is ABSENT. This is the state the incident's
# lanes were in, and the one the old notifier could not express.
mkwr "$V/wt-norep" 0 0; printf '0' > "$V/bg/norep.rc"; stamp "$V/wt-norep" norep "$PROMPT_REP" "$now"
rm -f "$REP"/REPORT-demo.md
got="$(verdict norep)"; rc=$?
{ [ "$got" = "no-report" ] && [ "$(verdict_rc norep)" = "1" ] && grep -q 'REPORT-demo.md' <<<"$(statusline norep)"; }; rc=$?
ck "VERDICT no-report: rc=0, clean tree, but the prompt's report file is ABSENT — FAILED, and the line names the missing file (got '$got')" $rc

# 5f committed-nothing — it worked and never committed (the measured worktree, without a cap record).
mkwr "$V/wt-cn" 0 1; printf '0' > "$V/bg/cn.rc"; stamp "$V/wt-cn" cn "$PROMPT_PLAIN" "$now"
got="$(verdict cn)"; rc=$?
{ [ "$got" = "committed-nothing" ] && [ "$(verdict_rc cn)" = "1" ]; }; rc=$?
ck "VERDICT committed-nothing: rc=0 with a DIRTY worktree is FAILED — commits=0 is not a verdict (got '$got')" $rc

# 5g clean-no-work — the LEGITIMATE "nothing to do", which must still pass: a verdict ladder that
# fails everything is as useless as one that passes everything.
mkwr "$V/wt-clean" 0 0; printf '0' > "$V/bg/clean.rc"; stamp "$V/wt-clean" clean "$PROMPT_PLAIN" "$now"
got="$(verdict clean)"; rc=$?
{ [ "$got" = "clean-no-work" ] && [ "$(verdict_rc clean)" = "0" ]; }; rc=$?
ck "VERDICT clean-no-work: rc=0, nothing committed, clean tree, no report required — PASSES (got '$got')" $rc

# 5h a PLACEHOLDER report path is resolved against its DIRECTORY, and only a report written DURING
# this run counts. Without the directory arm, every fleet prompt (which writes `REPORT-<name>.md`)
# would be reported no-report; without the mtime filter, a report left by an EARLIER run of the same
# name would satisfy this one — which is how "no-report" quietly becomes "reported".
mkdir -p "$TMP/repdir"
PROMPT_PH="$TMP/prompt-placeholder.txt"; printf 'Report to %s/REPORT-<name>.md\n' "$TMP/repdir" > "$PROMPT_PH"
printf 'done\n' > "$TMP/repdir/REPORT-anything.md"
mkwr "$V/wt-ph" 0 0; printf '0' > "$V/bg/ph.rc"; stamp "$V/wt-ph" ph "$PROMPT_PH" "$(( $(date +%s) - 5 ))"
got="$(verdict ph)"; rc=$?
ck "a placeholder report path resolved against its directory: a report written during this run satisfies it (got '$got', not no-report)" $([ "$got" != "no-report" ] && echo 0 || echo 1)
# …and the staleness half: the very same file, old enough to predate this run, must NOT satisfy it.
touch -t 202001010000 "$TMP/repdir/REPORT-anything.md"
got="$(verdict ph)"; rc=$?
ck "…but a report that PREDATES the run does not — a stale file must not silence no-report (got '$got')" $([ "$got" = "no-report" ] && echo 0 || echo 1)

# 5i done — one commit, no dirty files.
mkwr "$V/wt-done" 1 0; printf '0' > "$V/bg/done.rc"; stamp "$V/wt-done" done "$PROMPT_PLAIN" "$now"
got="$(verdict done)"; rc=$?
{ [ "$got" = "done" ] && [ "$(verdict_rc done)" = "0" ]; }; rc=$?
ck "VERDICT done: rc=0 with a commit PASSES (got '$got')" $rc

# 5j running — no status yet, live pid.
mkwr "$V/wt-run" 0 0; stamp "$V/wt-run" run "$PROMPT_PLAIN" "$now"
sleep 30 & RPID=$!; printf '%s' "$RPID" > "$V/bg/run.pid"
got="$(verdict run)"; rc=$?
{ [ "$got" = "running" ] && [ "$(verdict_rc run)" = "0" ]; }; rc=$?
kill "$RPID" 2>/dev/null
ck "VERDICT running: a live pid with no status yet PASSES and is not called lost (got '$got')" $rc

# 5k unverifiable — rc=0 but the worktree is gone: never guess a pass from an unreadable tree.
mk_state_stub="$V/bg/unv.started"
printf 'name=unv\nworktree=%s\nbranch=main\nprompt=%s\nstarted=x\nstarted_epoch=%s\ncap=3000s\n' \
  "$TMP/does-not-exist" "$PROMPT_PLAIN" "$now" > "$mk_state_stub"
printf '0' > "$V/bg/unv.rc"
got="$(verdict unv)"; rc=$?
{ [ "$got" = "unverifiable" ] && [ "$(verdict_rc unv)" = "1" ]; }; rc=$?
ck "VERDICT unverifiable: rc=0 with an unreadable worktree is FAILED, never a pass (got '$got')" $rc

# ── 6) END TO END THROUGH THE LAUNCHER: the stub dies at its cap and the exit path says FAILED ────
# Nothing here is simulated except the model: `nonblocking-dispatch.sh` launches the worker through the
# real `run_agent`, the real cap watcher writes the record, and the real `--verdict` classifies it.
git -C "$REPO" checkout -q -- .; git -C "$REPO" clean -qfd; : > "$PI_LOG"
OUT="$( PI_MODE=work-ignore-term AGENT_CAP_GRACE=2 O="$O" MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 \
        bash "$NB" e2e "$REPO" "$PROMPT_PLAIN" 4 2>&1 )"; rc=$?
ck "the launcher accepts the lane and reports the cap it will apply (rc=$rc): $(grep -o 'cap=[0-9]*s (source=[a-z]*)' <<<"$OUT" | head -1)" \
   $({ [ "$rc" -eq 0 ] && grep -q 'cap=4s (source=explicit)' <<<"$OUT"; } && echo 0 || echo 1)
# Wait for the cap to fire and the record to settle. Bounded: the cap is 4s and the grace 2s.
i=0; while [ "$i" -lt 60 ]; do
  [ "$(O="$O" bash "$NB" --verdict e2e 2>/dev/null)" = "killed-at-cap" ] && break
  sleep 1; i=$((i+1))
done
got="$(O="$O" bash "$NB" --verdict e2e 2>/dev/null)"; rc=$?
ck "END TO END: a stub killed at a 4-second cap is reported 'killed-at-cap', not 'finished' (got '$got' after ${i}s)" \
   $([ "$got" = "killed-at-cap" ] && echo 0 || echo 1)
O="$O" bash "$NB" --verdict e2e >/dev/null 2>&1; vrc=$?
ck "…and the verdict's EXIT CODE is non-zero, so a supervisor's \`if\` cannot read it as success (exit $vrc)" \
   $([ "$vrc" -ne 0 ] && echo 0 || echo 1)
[ -s "$O/bg/e2e.rc" ]; rc=$?
ck "…the exit status IS recorded through the launcher's own path (\$O/bg/e2e.rc = $(cat "$O/bg/e2e.rc" 2>/dev/null || echo '<absent>'))" $rc
grep -q 'snapshot=' <<<"$(O="$O" bash "$NB" --status e2e 2>/dev/null)"; rc=$?
ck "…and --status names the snapshot, so the work is recoverable from the report line alone" $rc
E2E_SNAP="$(awk -F'\t' '$2=="at-cap"{print $8}' "$O/state/cap-bg-e2e.tsv" 2>/dev/null | tail -1)"
{ [ -n "$E2E_SNAP" ] && [ -s "$E2E_SNAP/wip.diff" ] && grep -q 'work in progress' "$E2E_SNAP/wip.diff"; }; rc=$?
ck "…and the preserved work is really on disk: ${E2E_SNAP:-<none>}/wip.diff names what the stub wrote" $rc
grep -q 'cap-bg-e2e.tsv' "$O/logs/lane-e2e.log" 2>/dev/null || grep -q 'CAPPED' "$O/bg/e2e.log" 2>/dev/null; rc=$?
ck "…and the worker's own log explains the cap in words (cap / grace / snapshot)" $rc

# ── 7) THE OLD SHAPE CANNOT COME BACK ────────────────────────────────────────────────────────────
# The regression is a watchdog that kills and records nothing. Pin its exact shape as ABSENT, and pin
# that the recording path is present — a check that only asserts the new function exists would pass on
# a tree that also kept the old silent one.
grep -q 'sleep "\$t"; kill -TERM "\$pid"' "$GATE"; rc=$?
ck "spawn-gate.sh no longer contains the silent watchdog (sleep T; TERM; sleep 15; KILL)" $([ "$rc" -ne 0 ] && echo 0 || echo 1)
{ grep -q 'agent_wait_with_cap' "$GATE" && grep -q 'agent_cap_record' "$GATE" && grep -q 'agent_cap_snapshot' "$GATE"; }; rc=$?
ck "…and the recording path (wait-with-cap / snapshot / record) is what replaced it" $rc
grep -q 'kill -KILL "\$pid"' "$GATE"; rc=$?
ck "…and the HARD KILL is still there — the fix must not resurrect 'a hung worker is never killed'" $rc

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
