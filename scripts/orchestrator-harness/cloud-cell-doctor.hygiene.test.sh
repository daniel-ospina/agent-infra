#!/usr/bin/env bash
# cloud-cell-doctor.hygiene.test.sh — the disk-reclaim contract of the hygiene role (agent-infra#2573).
#
# WHY THIS SUITE EXISTS. The fleet ran out of disk every ~20 minutes and lanes died of ENOSPC, which
# is the worst possible failure shape: a lane that dies of ENOSPC produces NO output and is
# indistinguishable from a lane that did nothing. `cloud-cell-doctor.test.sh` and its hardening
# sibling drive the ROLE (reap / merge / status / the rehearsal rule); this suite drives the three
# RECLAIM decisions the role did not have, and the one it declined to make:
#
#   1. the `cloud-cell-<pid>.<rand>` temp dirs this family's own `mktemp -d` leaves under $TMPDIR —
#      kept for the life of the box, because a run killed by ENOSPC never reaches its trap;
#   2. docker images/volumes no container is using (cell-3 held 24.9 GB of images and 5.2 GB of
#      volumes while its lanes died of ENOSPC);
#   3. the worktree-root cache sweep, which used to disable ITSELF whenever any worker session was
#      live — i.e. it declined to reclaim precisely when the box was busiest.
#
# THE RULE EVERY ARM PINS. Reclaim only on PROOF of idleness, state the proof in the log, and REPORT
# anything unclear instead of reaping it. So each sink is driven in BOTH directions, in the same
# fixture: a stale/idle candidate is freed and the pass says so with a `df` delta, and a live/pinned
# candidate is LEFT ALONE with its reason named. A fixture that only proved the freeing direction would
# pass on a reaper that deletes everything; one that only proved the sparing direction would pass on a
# reaper that does nothing. Both are vacuous alone and neither is vacuous together.
#
# NON-VACUITY IS NOT ASSUMED: every arm that frees something has a sibling that forbids it in the same
# run (a live pid beside a dead one, a held root beside an idle one, an unpushed commit beside a
# merged-and-aged checkout), so the pass cannot be green by doing nothing OR by doing everything.
#
# The worktree half is driven through the SHIPPED reaper (`scripts/pi-reap-worktrees.sh`) against real
# git repositories: its gates ARE git semantics, and a doctor-side stub would let the delivery path
# pass while the production decision was wrong. Its own suite (`pi-reap-worktrees.test.sh`) owns the
# gate-by-gate contract; here the question is only whether the DOCTOR still reaches it, still passes
# the right mode, and never overrides a verdict.
#
# Run: bash scripts/orchestrator-harness/cloud-cell-doctor.hygiene.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="${DOCTOR_UNDER_TEST:-$HERE/cloud-cell-doctor.sh}"    # overridable: the revert arm needs it
SUP="${DOCTOR_SUPERVISOR_UNDER_TEST:-$HERE/../cloud-cell-supervisor.sh}"
REAPER="${DOCTOR_REAPER_UNDER_TEST:-$HERE/../pi-reap-worktrees.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
say_case() { echo; echo "── $1 ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cell-doctor-hygiene.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
T="$(cd "$T" && pwd -P)"   # git records RESOLVED paths; every expectation must compare resolved ones
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

for f in "$DOCTOR" "$SUP" "$REAPER"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done
bash -n "$DOCTOR" || { echo "FATAL: the doctor does not parse" >&2; exit 2; }
bash -n "$SUP"    || { echo "FATAL: the supervisor does not parse" >&2; exit 2; }

REAL_GIT="$(command -v git)" || { echo "FATAL: git is required" >&2; exit 2; }
NOW="$(python3 -c 'import datetime;print(int(datetime.datetime.fromisoformat("2026-09-15T20:00:00+00:00").timestamp()))')"
OLD_DATE="2026-07-01T12:00:00+00:00"      # 76 days before NOW: above every age floor in play
ANCIENT="202001010000"                     # `touch -t` form, for the temp dirs' idle floor

mkdir -p "$T/bin" "$T/tmp" "$T/home" "$T/o/logs" "$T/o/state/roles" "$T/sup" "$T/docker" "$T/state" \
         "$T/tmux" "$T/pids"

# ── stubs ────────────────────────────────────────────────────────────────────────────────────────
# tmux: the session census. The file is the WHOLE answer, so "no worker" and "a worker" are one line.
cat > "$T/bin/tmux" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_TMUX:?}"
case "${1:-}" in
  ls) if [ "${2:-}" = "-F" ]; then cat "$S/sessions" 2>/dev/null; exit 0; fi
      while IFS= read -r n; do [ -n "$n" ] && printf '%s: 1 windows\n' "$n"; done < "$S/sessions" 2>/dev/null
      exit 0 ;;
  *) exit 0 ;;
esac
SH
# uv: the role's package-cache prune. Recorded, so "ran" and "did not run" are distinguishable; the
# REAL uv must never be reached from a suite (it would prune the operator's machine-global cache).
cat > "$T/bin/uv" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_UV:?}"
printf '%s\n' "$*" >> "$S/uv-calls"
exit 0
SH
# docker: the one seam that can delete images. `info` succeeds unless the fixture says otherwise (a
# sweep whose daemon probe fails is a DIFFERENT arm), and every argv is recorded — including the ones
# that must NEVER appear (`system prune`).
cat > "$T/bin/docker" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_DOCKER:?}"
printf '%s\n' "$*" >> "$S/calls"
case "${1:-}" in
  info)
    if [ -f "$S/info_rc" ]; then
      # ⛔ to STDERR: the doctor's probe is `docker info 2>&1 >/dev/null`, i.e. it reads the daemon's
      # OWN complaint, so a stub that printed to stdout would look like a successful empty read.
      cat "$S/info_err" >&2 2>/dev/null
      exit "$(cat "$S/info_rc")"
    fi
    case " $* " in
      *" --format "*) printf '%s\n' "${S}/dockerroot"; exit 0 ;;
    esac
    printf 'Server Version: stub\n'; exit 0 ;;
  # The volume verb is VERSION-GATED (#2573 review round 7): `docker volume prune` prunes only
  # ANONYMOUS unused volumes from 23.0; before that it takes NAMED ones too. Every other arm therefore
  # needs a modern server, and the gate's own arms override DOCKER_SERVER_VERSION.
  version) case " $* " in *" --format "*) printf '%s\n' "${DOCKER_SERVER_VERSION-29.1.3}"; exit 0 ;; esac
           printf 'Client: stub\nServer: Docker Engine\n'; exit 0 ;;
  image)  [ -f "$S/image_rc" ] && exit "$(cat "$S/image_rc")"; printf 'Total reclaimed space: 1.2GB\n'; exit 0 ;;
  volume) [ -f "$S/volume_rc" ] && exit "$(cat "$S/volume_rc")"; printf 'Total reclaimed space: 3.4GB\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
# the supervisor: the cache sweep's EXECUTOR. It records the argv the doctor decided, which is the
# whole question this suite asks of it (the sweep itself is the supervisor's own suite's contract).
cat > "$T/bin/sup" <<'SH'
#!/bin/bash
S="${DOCTOR_TEST_SUP:?}"
printf '%s\n' "$*" >> "$S/calls"
[ -f "$S/rc" ] && exit "$(cat "$S/rc")"
exit 0
SH
# The reaper's own seams: `ps` and `lsof` report nothing that holds any fixture, so the ONLY thing
# deciding a worktree is its git state (dirty / unreachable / aged) — the gates this suite asserts.
cat > "$T/bin/ps"  <<'SH'
#!/bin/bash
printf '1 0 /sbin/launchd\n'
exit 0
SH
cat > "$T/bin/lsof" <<'SH'
#!/bin/bash
printf 'p9999\nn/usr/local\n'
exit 0
SH
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
# No GitHub remote in the fixture, so the open-PR veto is N/A; answer the benign "no open PRs" anyway.
exit 0
SH
# The CWD CENSUS seam (`live-ownership.sh`). ⛔ BOTH shapes are emitted from ONE stub: the Linux arm
# parses `ls -l /proc/<pid>/cwd` output ("… -> <path>") and the macOS arm parses `lsof -Fpn` ("p<pid>"
# then "n<path>"). A stub that only served one of them would be green here and red on the other
# platform — the exact class `live-ownership.test.sh` records having been caught by the Linux runner.
cat > "$T/bin/cwdprobe" <<'SH'
#!/bin/bash
# One cwd from FAKE_CWD, or one per line from FAKE_CWD_FILE (how the "every root is held" fixture is
# built: one census row per root).
emit() {
  [ -n "$1" ] || return 0
  printf '/proc/4242/cwd -> %s\n' "$1"
  printf 'p4242\nn%s\n' "$1"
}
if [ -n "${FAKE_CWD_FILE:-}" ] && [ -f "${FAKE_CWD_FILE}" ]; then
  while IFS= read -r line; do emit "$line"; done < "$FAKE_CWD_FILE"
else
  # ⛔ A BENIGN DEFAULT, NOT AN EMPTY PROBE: an empty probe reads as UNKNOWN (rc=2) in
  # `live-ownership.sh`, so arms that just want "the census worked and nobody is in a root" would
  # assert against a cannot-verify. One cwd outside every fixture root says exactly that.
  emit "${FAKE_CWD:-/usr/local/lib}"
fi
exit 0
SH
chmod +x "$T/bin/tmux" "$T/bin/uv" "$T/bin/docker" "$T/bin/sup" "$T/bin/ps" "$T/bin/lsof" "$T/bin/gh" \
         "$T/bin/cwdprobe"

# ── the environment the doctor runs under ───────────────────────────────────────────────────────
# EVERY seam is set explicitly: an ambient value in the caller's shell must not be able to change a
# verdict, and nothing here may reach the host's /tmp, docker daemon or uv cache.
export PATH="$T/bin:$PATH"
export CELL_HOME="$T/home" O="$T/o" REPO="$T/repo" OR="" SESSION="hygiene-test-$$"
export DOCTOR_TMUX_BIN="$T/bin/tmux" DOCTOR_TEST_TMUX="$T/tmux"
export DOCTOR_DOCKER_BIN="$T/bin/docker" DOCTOR_TEST_DOCKER="$T/docker"
export DOCTOR_SUPERVISOR="$T/bin/sup" DOCTOR_TEST_SUP="$T/sup"
export DOCTOR_WORKTREE_REAPER="$REAPER"
export DOCTOR_TEST_UV="$T/uv"
export HYGIENE_TMP_DIR="$T/tmp"
export STALE_WORKTREE_DAYS=7
# ⛔ `apply`, not the shipped default `auto`: `auto` arms the reaper only under disk pressure, so on a
# runner with free space the worktree arms would assert against a DRY-RUN and prove nothing about
# delivery. The pressure-driven arming is pinned by `cloud-cell-doctor.test.sh` (both directions).
export HYGIENE_WORKTREES=apply
export PS_BIN="$T/bin/ps" LSOF_BIN="$T/bin/lsof" GH_BIN="$T/bin/gh"
export REAP_WT_STATE_DIR="$T/state" REAP_WT_LOG="$T/state/reap.log" REAP_WT_NOW_EPOCH="$NOW"
export REAP_WT_DRY_RUN=0 REAP_WT_BUDGET_SECONDS=300
export LO_CWD_PROBE="$T/bin/cwdprobe"
unset FAKE_CWD

DOC_OUT=""; DOC_RC=0
doc() { DOC_OUT="$(bash "$DOCTOR" "$@" 2>&1)"; DOC_RC=$?; }
reset_state() { rm -rf "$T/o/state"; mkdir -p "$T/o/state/roles"; }
reset_calls() { rm -f "$T/sup/calls" "$T/docker/calls" "$T/uv/uv-calls"; }
reset_out()   { rm -rf "$T/o/logs"; mkdir -p "$T/o/logs"; }
result_has()  { case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state" 2>/dev/null)" in *"$1"*) return 0 ;; esac; return 1; }
log_has()     { grep -qF -- "$1" "$T/o/logs/doctor.log" 2>/dev/null; }
wtlog_has()   { grep -qF -- "$1" "$T/o/logs/doctor-worktrees.log" 2>/dev/null; }

# A pid that is provably GONE — never a magic number, which could be alive on the runner and make the
# "stale" fixture a live one (the arm would then pass for the wrong reason, or fail mysteriously).
dead_pid() {
  "$SLEEP_BIN" 0.2 & local p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}
SLEEP_BIN="$(command -v sleep)"

mk_tmpdir() { # <name> <age: touch -t form> -> path
  local d="$T/tmp/$1"
  mkdir -p "$d"; printf 'x\n' > "$d/f"
  touch -t "$2" "$d" "$d/f"
  printf '%s' "$d"
}

# ⛔ RELATIVE AGES BY EPOCH, NOT BY A WALL-CLOCK ROUND TRIP (review round 6, P2). `touch -t` parses an
# `[[CC]YY]MMDDhhmm` stamp in the HOST zone, and a stamp that lands inside a DST-REPEATED hour resolves
# to whichever offset libc picks — measured under Europe/Madrid: a `now − 600 s` stamp resolved 3600 s
# into the future, so the doctor computed a NEGATIVE age and the "10 minutes ago" fixture behaved as
# "in the future". `os.utime` sets the instant directly, so no zone, offset or fold can move it.
mk_tmpdir_ago() { # <name> <seconds-ago> -> path
  local d="$T/tmp/$1"
  mkdir -p "$d"; printf 'x\n' > "$d/f"
  python3 -c 'import os,sys,time
t = time.time() - float(sys.argv[1])
for p in sys.argv[2:]: os.utime(p, (t, t))' "$2" "$d" "$d/f"
  printf '%s' "$d"
}

# ── the worktree fixture: real git, real gates ──────────────────────────────────────────────────
mk_repo() {
  mkdir -p "$T/repo"
  "$REAL_GIT" init -q -b main "$T/repo"
  "$REAL_GIT" -C "$T/repo" config user.email t@t
  "$REAL_GIT" -C "$T/repo" config user.name t
  printf 'base\n' > "$T/repo/base.txt"
  "$REAL_GIT" -C "$T/repo" add base.txt
  GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$T/repo" commit -qm init
}
# A checkout nobody is holding, on a NAMED branch, clean, older than the floor: the reaper's own
# contract removes it and KEEPS the branch (the commit is never lost).
mk_wt_abandoned() {
  "$REAL_GIT" -C "$T/repo" worktree add -q "$T/repo/wt-abandoned" -b feat/abandoned
  mkdir -p "$T/repo/wt-abandoned/node_modules"
  printf 'x\n' > "$T/repo/wt-abandoned/node_modules/marker"
}
# A checkout whose HEAD commit is held by NO ref: removing the directory would ORPHAN it. This is the
# "unpushed commit" the safety rule protects, and it must be preserved by the SHIPPED gate.
mk_wt_unpushed() {
  "$REAL_GIT" -C "$T/repo" worktree add -q --detach "$T/repo/wt-unpushed"
  printf 'wip\n' > "$T/repo/wt-unpushed/wip.txt"
  "$REAL_GIT" -C "$T/repo/wt-unpushed" add wip.txt
  GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" \
    "$REAL_GIT" -C "$T/repo/wt-unpushed" commit -qm 'unpushed wip'
}
# A checkout with an UNCOMMITTED change: `clean` is what protects it.
mk_wt_dirty() {
  "$REAL_GIT" -C "$T/repo" worktree add -q "$T/repo/wt-dirty" -b feat/dirty
  printf 'uncommitted\n' >> "$T/repo/wt-dirty/base.txt"
}

mk_repo
mk_wt_abandoned; mk_wt_unpushed; mk_wt_dirty
ok "fixture: a real git repo with an abandoned, an unpushed and a dirty worktree"

# ════════════════ (a) a STALE-ONLY box: each sink is reclaimed, and the pass proves it ═════════
say_case "(a) stale temp dir + idle docker images + abandoned worktree ARE reclaimed, with a df delta"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"      # no worker session
DEAD="$(dead_pid)"
mk_tmpdir "cloud-cell-${DEAD}.AAAA" "$ANCIENT" >/dev/null
doc hygiene
if [ ! -e "$T/tmp/cloud-cell-${DEAD}.AAAA" ]; then
  ok "temp: a dir whose embedded pid is NOT alive is reaped"
else
  bad "temp: a stale cloud-cell-* dir survived the pass"
fi
log_has "reaped $T/tmp/cloud-cell-${DEAD}.AAAA (proof: the name's token ${DEAD} is not a LIVE pid" \
  && ok "temp: the log STATES the proof (the pid it tested, and that it is gone)" \
  || bad "temp: the reaped dir was removed without naming the evidence — $(grep -F 'temp:' "$T/o/logs/doctor.log" 2>/dev/null | head -3)"
grep -qx 'image prune -af'  "$T/docker/calls" 2>/dev/null \
  && ok "docker: 'image prune -af' ran (unused images only — a live container keeps its image)" \
  || bad "docker: 'image prune -af' was not invoked — $(cat "$T/docker/calls" 2>/dev/null)"
grep -qx 'volume prune -f'  "$T/docker/calls" 2>/dev/null \
  && ok "docker: 'volume prune -f' ran (volumes no container uses)" \
  || bad "docker: 'volume prune -f' was not invoked — $(cat "$T/docker/calls" 2>/dev/null)"
# ⛔ AN ALLOWLIST, NOT A BANNED STRING (review, P2). Banning the literal `system prune` passed every
# argv the stub recorded unless it contained those two words — `container prune -f` (which removes
# STOPPED CONTAINERS, a test's evidence), `builder prune` and `network prune` all sailed through the
# arm while it claimed "only the two 'in use by nothing' verbs". Every recorded argv must now be one of
# the three the role is allowed to run, so a NEW verb cannot be added without reddening this.
DOCKER_BAD="$(grep -vx -e 'info' -e 'info --format {{.DockerRootDir}}' -e 'version --format {{.Server.Version}}' -e 'image prune -af' -e 'volume prune -f' \
                       "$T/docker/calls" 2>/dev/null)"
[ -z "$DOCKER_BAD" ] \
  && ok "docker: every docker argv is in the allowlist ('info', 'image prune -af', 'volume prune -f') — no 'system/container/builder/network prune'" \
  || bad "docker: a verb outside the allowlist was invoked — $(printf '%s' "$DOCKER_BAD" | tr '\n' ' ')"
[ -e "$T/repo/wt-abandoned" ] \
  && bad "worktree: an abandoned (clean, aged, holder-free) checkout survived an ARMED pass" \
  || ok "worktree: the abandoned checkout is reclaimed (delivery reaches the shipped reaper)"
"$REAL_GIT" -C "$T/repo" rev-parse --verify refs/heads/feat/abandoned >/dev/null 2>&1 \
  && ok "worktree: its BRANCH survives the checkout's removal (removing a worktree never deletes a branch)" \
  || bad "worktree: the branch was deleted with the checkout — that is how a commit gets orphaned"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" in
  *"df "*"MB → "*"MB ("*"MB)"*) ok "the record carries a df BEFORE → AFTER delta" ;;
  *) bad "no df delta in the record — $(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" ;;
esac
log_has "df ($T/home):" && ok "the log carries the df delta against the filesystem the pass reclaims from" \
                       || bad "no 'df (...)' line in the log"
[ "$DOC_RC" -eq 0 ] && ok "(a) the pass is CLEAN (every step ran and decided)" || bad "(a) rc=$DOC_RC — $DOC_OUT"

# ════════════════ (b) a PINNED box: nothing is reclaimed, and every skip NAMES its reason ══════
say_case "(b) live temp dir + unpushed commit + dirty tree are LEFT ALONE, each with its reason"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
LIVE="$$"                                   # this suite's own pid: alive for the whole arm
mk_tmpdir "cloud-cell-${LIVE}.BBBB" "$ANCIENT" >/dev/null      # alive pid, ancient mtime
mk_tmpdir "cloud-cell-test.CCCC"    "$ANCIENT" >/dev/null      # no pid in the name
DEAD2="$(dead_pid)"
mk_tmpdir_ago "cloud-cell-${DEAD2}.DDDD" 0 >/dev/null                   # dead pid, but FRESH
printf '1\n' > "$T/docker/info_rc"
printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n' \
  > "$T/docker/info_err"
doc hygiene
rm -f "$T/docker/info_rc" "$T/docker/info_err"
[ -e "$T/tmp/cloud-cell-${LIVE}.BBBB" ] \
  && ok "temp: a dir whose embedded pid is ALIVE is never touched" \
  || bad "temp: a LIVE pid's dir was reaped"
log_has "LEFT $T/tmp/cloud-cell-${LIVE}.BBBB — pid ${LIVE} from the name is ALIVE" \
  && ok "temp: the live skip names the live pid (the reason, not just the verdict)" \
  || bad "temp: the live skip is not explained"
[ -e "$T/tmp/cloud-cell-test.CCCC" ] \
  && ok "temp: a name carrying NO pid is reported, never reaped (no liveness proof exists)" \
  || bad "temp: a dir with no pid in its name was reaped on an assumption"
log_has "LEFT $T/tmp/cloud-cell-test.CCCC — no pid in the name" \
  && ok "temp: …and the log says why that spelling is not reaped" \
  || bad "temp: the no-pid skip is not explained"
[ -e "$T/tmp/cloud-cell-${DEAD2}.DDDD" ] \
  && ok "temp: a DEAD pid with a FRESH mtime is left (a recycled pid must not be the only proof)" \
  || bad "temp: a freshly-written dir was reaped on a pid test alone — a recycled pid could delete a live fixture"
log_has "under the 3600s idle floor" && ok "temp: …and the idle floor is named in the log" \
                                     || bad "temp: the idle-floor skip is not explained"
grep -q 'prune' "$T/docker/calls" 2>/dev/null \
  && bad "docker: a prune was attempted on a box whose daemon could not be reached" \
  || ok "docker: no daemon ⇒ nothing is pruned"
result_has "docker: no daemon" && ok "docker: the skip is recorded as 'no daemon' (a true nothing-to-do)" \
                               || bad "docker: the daemon skip is not in the record — $DOC_OUT"
[ -d "$T/repo/wt-unpushed" ] \
  && ok "worktree: a checkout whose HEAD commit NO ref holds is preserved (removing it would orphan the commit)" \
  || bad "worktree: an unpushed commit's checkout was DELETED — its commit now survives nowhere"
wtlog_has "reason=detached-unreachable" && ok "worktree: the reason is logged (detached-unreachable)" \
                                        || bad "worktree: the unpushed skip is not explained — $(cat "$T/o/logs/doctor-worktrees.log" 2>/dev/null | head -5)"
[ -d "$T/repo/wt-dirty" ] \
  && ok "worktree: a checkout with an UNCOMMITTED change is preserved" \
  || bad "worktree: a dirty checkout was DELETED — uncommitted work lost"
wtlog_has "reason=dirty" && ok "worktree: the reason is logged (dirty)" \
                         || bad "worktree: the dirty skip is not explained"
[ "$DOC_RC" -eq 0 ] && ok "(b) the pass is CLEAN: every skip was a DECISION on a read that succeeded" \
                    || bad "(b) rc=$DOC_RC — a decided skip must not redden the role — $DOC_OUT"

# ════════════════ the CLAMP: a live worker must not suppress every root ════════════════════════
say_case "the clamp: a live worker excludes ITS OWN root, and every other root is still swept"
reset_state; reset_out; reset_calls
printf 'lane-99\n' > "$T/tmux/sessions"                       # a worker IS live
# A checkout built FOR THIS ARM: arm (a) armed the reaper, which (correctly) reclaimed every clean,
# aged, holder-free checkout in the fixture, so a root reused from there would be pointing the census
# at a directory that no longer exists — and the arm would prove nothing.
"$REAL_GIT" -C "$T/repo" worktree add -q "$T/repo/wt-live" -b feat/live-now
mkdir -p "$T/repo/wt-live/node_modules"; printf 'x\n' > "$T/repo/wt-live/node_modules/marker"
export FAKE_CWD="$T/repo/wt-live"
doc hygiene
unset FAKE_CWD
[ -s "$T/sup/calls" ] \
  && ok "cache sweep: it RAN with a worker live (pre-fix it self-disabled exactly when the box was busiest)" \
  || bad "cache sweep: a live worker suppressed the whole sweep — the clamp is back"
grep -q -- "--exclude-root=$T/repo/wt-live" "$T/sup/calls" 2>/dev/null \
  && ok "cache sweep: the root a LIVE process holds is EXCLUDED" \
  || bad "cache sweep: the held root was not excluded — $(cat "$T/sup/calls" 2>/dev/null)"
grep -q -- "--exclude-root=$T/repo/wt-dirty" "$T/sup/calls" 2>/dev/null \
  && bad "cache sweep: an IDLE root was excluded too (the evidence decided nothing)" \
  || ok "cache sweep: an idle root is NOT excluded (the census decided, not the worker count)"
log_has "LEFT $T/repo/wt-live — a LIVE process has a cwd inside it" \
  && ok "cache sweep: the exclusion is REPORTED with its evidence" \
  || bad "cache sweep: the held root was excluded without saying why"
result_has "workers live" && ok "cache sweep: the record says the box had workers live" \
                           || bad "cache sweep: the record does not say workers were live — $DOC_OUT"
[ "$DOC_RC" -eq 0 ] && ok "cache sweep: rc=0 (a decision on a read that succeeded)" || bad "cache sweep: rc=$DOC_RC — $DOC_OUT"

say_case "the clamp: an UNREADABLE census proves nothing about any root, so nothing is swept"
reset_state; reset_out; reset_calls
printf 'lane-99\n' > "$T/tmux/sessions"
OUT="$(LO_CWD_PROBE=/nonexistent/cwdprobe bash "$DOCTOR" hygiene 2>&1)"; RC=$?
[ -s "$T/sup/calls" ] \
  && bad "cache sweep: swept roots on a census it could not take — $(cat "$T/sup/calls")" \
  || ok "cache sweep: an unreadable live-cwd census arm no destructive sweep (fail-closed)"
[ "$RC" -eq 3 ] && ok "cache sweep: the pass is rc=3 (cannot-verify is not a pass)" || bad "cache sweep: rc=$RC (want 3) — $OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 3 ] \
  && ok "cache sweep: the cannot-verify is RECORDED" \
  || bad "cache sweep: state recorded rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")"

say_case "the clamp: every root held ⇒ the sweep is skipped, named, and NOT reddened"
reset_state; reset_out; reset_calls
printf 'lane-99\n' > "$T/tmux/sessions"
# ONE census row per root (the repo root AND every worktree), which is what a box where a lane is
# running in each checkout looks like.
{
  printf '%s\n' "$T/repo"
  "$REAL_GIT" -C "$T/repo" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}'
} > "$T/cwds"
export FAKE_CWD_FILE="$T/cwds"
doc hygiene
unset FAKE_CWD_FILE
[ -s "$T/sup/calls" ] && bad "cache sweep: swept while every root was held — $(cat "$T/sup/calls")" \
                      || ok "cache sweep: nothing is swept when no root is idle"
result_has "every root held" && ok "cache sweep: the skip is named in the record" \
                             || bad "cache sweep: the all-held skip is unnamed — $DOC_OUT"
[ "$DOC_RC" -eq 0 ] && ok "cache sweep: rc=0 — a census that READ and decided is not cannot-verify" \
                    || bad "cache sweep: rc=$DOC_RC — $DOC_OUT"

say_case "the clamp: a HARNESS_REPO worktree (a second repo the sweep prunes) is excluded too"
reset_state; reset_out; reset_calls
printf 'lane-99\n' > "$T/tmux/sessions"
mkdir -p "$T/harness"
if [ ! -d "$T/harness/.git" ]; then
  "$REAL_GIT" init -q -b main "$T/harness"
  "$REAL_GIT" -C "$T/harness" config user.email t@t
  "$REAL_GIT" -C "$T/harness" config user.name t
  printf 'h\n' > "$T/harness/h.txt"; "$REAL_GIT" -C "$T/harness" add h.txt
  GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" "$REAL_GIT" -C "$T/harness" commit -qm h
  "$REAL_GIT" -C "$T/harness" worktree add -q "$T/harness/wt-h" -b feat/harness-live
fi
mkdir -p "$T/harness/wt-h/node_modules"; printf 'x\n' > "$T/harness/wt-h/node_modules/marker"
export HARNESS_REPO="$T/harness" FAKE_CWD="$T/harness/wt-h"
doc hygiene
unset HARNESS_REPO FAKE_CWD
grep -q -- "--exclude-root=$T/harness/wt-h" "$T/sup/calls" 2>/dev/null \
  && ok "cache sweep: a held worktree of HARNESS_REPO is excluded (the doctor enumerates BOTH repos the sweep prunes)" \
  || bad "cache sweep: a live HARNESS_REPO worktree was not excluded — $(cat "$T/sup/calls" 2>/dev/null)"
grep -q -- "--exclude-root=$T/harness$" "$T/sup/calls" 2>/dev/null \
  && bad "cache sweep: the harness MAIN checkout was excluded although nothing holds it" \
  || ok "cache sweep: the idle harness main checkout is still swept (the exclusion is per-ROOT, not per-repo)"

say_case "no worker at all: the sweep runs unfiltered, exactly as before"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
doc hygiene
[ -s "$T/sup/calls" ] && ok "cache sweep: it runs when no worker session is live" || bad "cache sweep: it did not run"
grep -q -- '--exclude-root' "$T/sup/calls" 2>/dev/null \
  && bad "cache sweep: excluded a root with no worker live (an exclusion nobody needs is a surprise)" \
  || ok "cache sweep: no exclusions are passed when no worker is live (the old path is intact)"

# ════════════════ the pass-level df artefact rules ═════════════════════════════════════════════
say_case "the df delta: signed, never a du sum, and never invented when df cannot answer"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
doc hygiene
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" in
  *"→"*) ok "the record's delta is a before → after pair (the filesystem's answer, not a du sum)" ;;
  *) bad "the record has no before → after pair — $(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" ;;
esac
# ⛔ THIS ARM USED TO BE UNFAILABLE (review, P2): its negative branch called `ok` as well, so it went
# green whether the label was present, absent, or the whole line had been deleted. It now asserts the
# pairing in both directions — a `du` figure in the log MUST carry the label, and the fixture's stubbed
# `uv` is on PATH, so "no du at all" is itself a red (the prune did not run).
if grep -q 'du ' "$T/o/logs/doctor.log" 2>/dev/null; then
  grep -qF 'informational; the df delta below is the claim' "$T/o/logs/doctor.log" 2>/dev/null \
    && ok "…and every du figure the log keeps is LABELLED informational (the claim is the df delta)" \
    || bad "a du figure appears in the log WITHOUT the informational label — it reads as a savings claim"
else
  bad "no du pair at all: the uv cache prune did not run (the label question cannot be answered by an absent line)"
fi

say_case "a failed docker prune is CANNOT-VERIFY, never a clean row"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
printf '1\n' > "$T/docker/image_rc"
doc hygiene
rm -f "$T/docker/image_rc"
[ "$DOC_RC" -eq 3 ] && ok "docker: rc=1 from 'image prune' makes the PASS rc=3" || bad "docker: rc=$DOC_RC (want 3) — $DOC_OUT"
result_has "docker prune FAILED" && ok "docker: the failure is named in the record" \
                                 || bad "docker: the failure is not in the record — $DOC_OUT"
[ "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" = 3 ] \
  && ok "docker: …and RECORDED (status cannot print a false green)" \
  || bad "docker: state rc=$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")"

say_case "a rehearsal reclaims NOTHING (dry-run is the verb an operator runs FIRST)"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
DEAD3="$(dead_pid)"
mk_tmpdir "cloud-cell-${DEAD3}.EEEE" "$ANCIENT" >/dev/null
mkdir -p "$T/repo/wt-new-abandoned"; "$REAL_GIT" -C "$T/repo" worktree add -q "$T/repo/wt-new-abandoned" -b feat/new-abandoned
doc hygiene --dry-run
[ -e "$T/tmp/cloud-cell-${DEAD3}.EEEE" ] && ok "temp: a rehearsal reaps nothing" || bad "temp: --dry-run DELETED a stale dir"
[ -e "$T/repo/wt-new-abandoned" ] && ok "worktree: a rehearsal removes nothing" || bad "worktree: --dry-run removed a checkout"
grep -q 'prune' "$T/docker/calls" 2>/dev/null && bad "docker: --dry-run invoked a prune" || ok "docker: a rehearsal prunes nothing"
log_has "WOULD reap temp dir $T/tmp/cloud-cell-${DEAD3}.EEEE" && ok "temp: the rehearsal SAYS what it would do (and why)" \
                                                           || bad "temp: the rehearsal is silent about the candidate"

# ════════════════ what a fresh-context review of THIS change found ══════════════════════════════
# Each arm below reddens on the fix's own revert (stated per arm), so none of them is decoration.
say_case "temp: a NESTED write is activity — the directory's own mtime cannot prove idleness"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
DEAD4="$(dead_pid)"
NEST="$T/tmp/cloud-cell-${DEAD4}.FFFF"
mkdir -p "$NEST/sub"; printf 'x\n' > "$NEST/sub/f"
touch -t "$ANCIENT" "$NEST"          # the DIRECTORY looks ancient ...
touch "$NEST/sub"                    # ... but something was written INSIDE it since
doc hygiene
[ -e "$NEST" ] && ok "temp: a dir whose CONTENTS were touched after its own mtime is NOT reaped" \
               || bad "temp: reaped on an age it could not prove — a nested write is invisible to the directory's mtime"
log_has "$NEST — an entry INSIDE it was written after its own mtime" \
  && ok "temp: …and the keep NAMES the nested write (a silent keep is the defect the log exists to prevent)" \
  || bad "temp: the nested-write keep is unexplained — $(grep -F 'temp:' "$T/o/logs/doctor.log" 2>/dev/null | head -3)"

say_case "the temp idle floor is honoured at the value the operator set (HYGIENE_TMP_MIN_AGE_S)"
# ⛔ THE FLOOR IS THE SECOND GATE (the pid is the first): it covers pid RECYCLING, so the SAME dead-pid
# dir must be reaped under a small floor and kept under a large one — driven through the shipped knob,
# not through the fixture's own posture. This arm is the `guardedBy` pin the heartbeat/progress-edge
# registry cites for HYGIENE_TMP_MIN_AGE_S (extensions/shared/heartbeat-progress-edges.ts).
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
DEAD7="$(dead_pid)"
# ⛔ The stamp is set by EPOCH (`mk_tmpdir_ago`), not by a wall-clock round trip: round 5 fixed a UTC
# stamp that `touch -t` read as local, and round 6 found the residual — a `now − 600 s` stamp can land
# inside a DST-REPEATED hour and resolve to the other offset (measured: +3600 s, so a "10 minutes ago"
# dir read as being 3000 s in the FUTURE). Epoch arithmetic has no zone to get wrong.
mk_tmpdir_ago "cloud-cell-${DEAD7}.LLLL" 600 >/dev/null
HYGIENE_TMP_MIN_AGE_S=60 doc hygiene
[ -e "$T/tmp/cloud-cell-${DEAD7}.LLLL" ] \
  && bad "temp: a dir 10 min old survived a 60 s floor (the floor is not read from HYGIENE_TMP_MIN_AGE_S)" \
  || ok "temp: under a 60 s floor the 10-min-old dir is reclaimed (the floor is read from the environment)"
mk_tmpdir_ago "cloud-cell-${DEAD7}.NNNN" 600 >/dev/null
HYGIENE_TMP_MIN_AGE_S=3600 doc hygiene
[ -e "$T/tmp/cloud-cell-${DEAD7}.NNNN" ] \
  && ok "temp: under a 3600 s floor the SAME age is KEPT (the floor is a real gate, not decoration)" \
  || bad "temp: a dir younger than its floor was reaped — the recycling hole the floor exists to bound"
log_has "under the 3600s idle floor" && ok "temp: …and the keep names the floor it failed" \
                                    || bad "temp: the age-floor keep is unexplained"

say_case "a token that cannot be a pid is NOT 'the pid is dead' (0, a leading zero, a date stamp)"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
# `kill -0 0` SUCCEEDS (0 is the caller's own process GROUP), so a name shaped like that would read as
# "ALIVE" forever; `20260101` is above the kernel pid ceiling yet `kill` says "No such process", so the
# old code read it as DEAD and reaped on the age floor alone — a reap with no liveness proof.
mk_tmpdir "cloud-cell-0.GGGG"        "$ANCIENT" >/dev/null
mk_tmpdir "cloud-cell-01718.HHHH"    "$ANCIENT" >/dev/null
mk_tmpdir "cloud-cell-20260101.IIII" "$ANCIENT" >/dev/null
doc hygiene
for n in cloud-cell-0.GGGG cloud-cell-01718.HHHH cloud-cell-20260101.IIII; do
  [ -e "$T/tmp/$n" ] && ok "temp: '$n' survives — its token proves nothing about liveness" \
                     || bad "temp: '$n' was reaped on an age floor, with no liveness proof at all"
done
log_has "cannot be a pid" && ok "temp: …and the reason names WHY the token is not a pid" \
                          || bad "temp: the non-pid keep is unexplained — $(grep -F 'temp:' "$T/o/logs/doctor.log" 2>/dev/null | head -3)"
log_has "above the kernel pid ceiling" && ok "temp: …and an out-of-range token says so" \
                                       || bad "temp: an out-of-range pid token is unexplained"

say_case "an in-place APPEND below depth 3 is still activity (a created entry is not the only writer)"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
DEAD5="$(dead_pid)"
DEEP="$T/tmp/cloud-cell-${DEAD5}.JJJJ"
mkdir -p "$DEEP/a/b/c/d"; printf 'x\n' > "$DEEP/a/b/c/d/log"
# Every DIRECTORY looks ancient …
touch -t "$ANCIENT" "$DEEP" "$DEEP/a" "$DEEP/a/b" "$DEEP/a/b/c" "$DEEP/a/b/c/d"
touch "$DEEP/a/b/c/d/log"          # … but a file four levels down was appended to
doc hygiene
[ -e "$DEEP" ] && ok "temp: a deep in-place write still blocks the reap (no depth bound on the walk)" \
               || bad "temp: reaped a dir whose file four levels down was written — the depth bound hid it"

say_case "the census runs with NO worker session: a session is a declaration, a cwd is a fact"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
FAKE_CWD="$T/repo" doc hygiene
# The held root must be EXCLUDED — and the idle ones still swept: that is the per-root decision this
# whole fix is about. Reverting to the session gate (no census when no session is live) sweeps
# `$T/repo` with no exclusion at all and reddens the first arm below.
grep -qF -- "--exclude-root=$T/repo" "$T/sup/calls" 2>/dev/null \
  && ok "cache sweep: a live cwd with NO session still EXCLUDES its root (a session is a declaration, a cwd is a fact)" \
  || bad "cache sweep: a root a live process sits in was swept on a session-less box — $(cat "$T/sup/calls" 2>/dev/null)"
log_has "$T/repo — a LIVE process has a cwd inside it" \
  && ok "cache sweep: …and the exclusion NAMES the root and its evidence" \
  || bad "cache sweep: the exclusion is silent — $(grep -F 'caches:' "$T/o/logs/doctor.log" 2>/dev/null | head -3)"
case "$(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" in
  *"every root held"*) bad "cache sweep: claimed every root was held although the fixture left idle ones — $(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" ;;
  *"swept"*) ok "cache sweep: the idle roots are still swept (one held root does not disable the pass)" ;;
  *) bad "cache sweep: the sweep is not reported — $(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")" ;;
esac
[ "$DOC_RC" -eq 0 ] && ok "cache sweep: rc=0 — the census read and decided" || bad "cache sweep: rc=$DOC_RC — $DOC_OUT"

say_case "and with the census taken, a box where nobody holds a root passes NO exclusion at all"
reset_state; reset_out; reset_calls; printf 'lane-7\n' > "$T/tmux/sessions"
FAKE_CWD=/usr/local/lib doc hygiene
[ -s "$T/sup/calls" ] && ok "cache sweep: the sweep runs when no root is held" \
                     || bad "cache sweep: it did not run with an idle root and a live worker session — $(cat "$T/sup/calls" 2>/dev/null)"
grep -q -- '--exclude-root' "$T/sup/calls" 2>/dev/null \
  && bad "cache sweep: an exclusion was passed for a root nothing holds — $(cat "$T/sup/calls")" \
  || ok "cache sweep: no exclusion argv at all (an EMPTY array must not expand under set -u)"

say_case "an UNENUMERABLE worktree root set is cannot-verify, never a clean pass"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
mkdir -p "$T/not-a-repo"
OUT="$(REPO="$T/not-a-repo" bash "$DOCTOR" hygiene 2>&1)"; RC=$?
result_has "no worktree root enumerated" \
  && ok "cache sweep: an empty enumeration is named as the failed read it is" \
  || bad "cache sweep: an empty enumeration was not recorded — $(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state" 2>/dev/null)"
case "$(sed -n 's/^last_rc=//p' "$T/o/state/roles/hygiene.state")" in
  [123456789]*) ok "cache sweep: …and it is RECORDED as non-clean (status cannot print a false green)" ;;
  *) bad "cache sweep: an unenumerable root set recorded a CLEAN pass" ;;
esac

say_case "docker: an ABSENT daemon is 'nothing to reclaim'; a DENIED one is cannot-verify"
# ⛔ The two are not the same fact (review round 3). "Cannot connect … Is the docker daemon running?"
# means the box holds nothing for us; a daemon that exists and refuses this user means the reclaimable
# images/volumes are there and this pass cannot reach them — a green row there would hide exactly the
# incident the issue measured (24.9 GB of idle images on a cell whose loop could not prune them).
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
printf '1\n' > "$T/docker/info_rc"
printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n' > "$T/docker/info_err"
doc hygiene
result_has "docker: no daemon" && ok "docker: an ABSENT daemon reads as 'no daemon' (a true nothing-to-reclaim)" \
                              || bad "docker: the absent-daemon class was not recognised — $(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")"
[ "$DOC_RC" -eq 0 ] && ok "docker: …and that box is not reddened" || bad "docker: rc=$DOC_RC — $(printf '%s' "$DOC_OUT" | tail -2)"
printf 'permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: dial unix /var/run/docker.sock: connect: permission denied\n' > "$T/docker/info_err"
reset_state; reset_out; reset_calls
doc hygiene
rm -f "$T/docker/info_rc" "$T/docker/info_err"
result_has "docker daemon unreachable" && ok "docker: a DENIED socket is cannot-verify (the data is there, this pass cannot prune it)" \
                                      || bad "docker: a denied socket was reported as $(sed -n 's/^last_result=//p' "$T/o/state/roles/hygiene.state")"
[ "$DOC_RC" -eq 3 ] && ok "docker: …and the pass is rc=3, not a green row over 25 GB of idle images" \
                   || bad "docker: rc=$DOC_RC (want 3) — $(printf '%s' "$DOC_OUT" | tail -2)"
grep -q 'prune' "$T/docker/calls" 2>/dev/null && bad "docker: a prune was attempted with no reachable daemon" \
                                              || ok "docker: no prune is attempted when the daemon cannot answer"

say_case "docker: the VOLUME verb is version-gated — a pre-23 daemon prunes NAMED volumes too"
# ⛔ THIS IS THE DATA-LOSS-SHAPED ARM (review round 7). `docker volume prune` removes only ANONYMOUS
# unused volumes from 23.0 (that is why `-a/--all` exists); on an older daemon the same command takes
# every UNUSED volume, NAMED ones included — the durable volume `docker compose down` preserves. The
# pass runs hourly and unattended, so the verb must not be attempted where its set is unknown.
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
DOCKER_SERVER_VERSION=22.06.0-beta.0 doc hygiene
grep -qx 'image prune -af' "$T/docker/calls" 2>/dev/null \
  && ok "docker: on a pre-23 daemon the IMAGE prune still runs (unused images are safe at any version)" \
  || bad "docker: the version gate suppressed the image prune too — $(cat "$T/docker/calls" 2>/dev/null)"
grep -qx 'volume prune -f' "$T/docker/calls" 2>/dev/null \
  && bad "docker: 'volume prune -f' ran against a pre-23 daemon — it prunes NAMED unused volumes there (durable data)" \
  || ok "docker: 'volume prune -f' is NOT attempted on a pre-23 daemon (named volumes survive)"
log_has "volume prune SKIPPED (server 22.06.0-beta.0 < 23.0" \
  && ok "docker: …and the skip names the version and the reason" \
  || bad "docker: the version skip is unexplained — $(grep -F 'docker:' "$T/o/logs/doctor.log" 2>/dev/null | head -3)"
reset_state; reset_out; reset_calls
DOCKER_SERVER_VERSION=29.1.3 doc hygiene
grep -qx 'volume prune -f' "$T/docker/calls" 2>/dev/null \
  && ok "docker: on a 23+ daemon the volume verb runs (anonymous-only by the daemon's own default)" \
  || bad "docker: the volume prune was suppressed on a modern daemon — the gate is over-broad"
reset_state; reset_out; reset_calls
DOCKER_SERVER_VERSION="" doc hygiene
grep -qx 'volume prune -f' "$T/docker/calls" 2>/dev/null \
  && bad "docker: the volume verb ran with an UNREADABLE server version (blast radius unestablished)" \
  || ok "docker: an unreadable server version skips the volume verb (fail-closed)"
[ "$DOC_RC" -eq 3 ] && ok "docker: …and that is cannot-verify (rc=3), not a clean pass on a skipped verb" \
                   || bad "docker: rc=$DOC_RC (want 3) — $(printf '%s' "$DOC_OUT" | tail -2)"

say_case "temp: a walk that could not COMPLETE is not 'nothing newer inside' (fail-open)"
reset_state; reset_out; reset_calls; : > "$T/tmux/sessions"
DEAD6="$(dead_pid)"
WALK="$T/tmp/cloud-cell-${DEAD6}.KKKK"
mk_tmpdir "cloud-cell-${DEAD6}.KKKK" "$ANCIENT" >/dev/null
# A `find` that fails ONLY for the nested-write walk (everything else passes through to the real one), so
# this arm is about the exit status of that read and nothing else.
cat > "$T/bin/find" <<SH
#!/bin/bash
case " \$* " in *" -newer "*) exit 1 ;; esac
exec /usr/bin/find "\$@"
SH
chmod +x "$T/bin/find"
doc hygiene
rm -f "$T/bin/find"
[ -e "$WALK" ] && ok "temp: a FAILED nested-write walk leaves the candidate alone (an unreadable read is not a proof)" \
               || bad "temp: reaped a dir on a walk that never completed — the exit status was discarded"
log_has "nested-write walk over it could not be completed" \
  && ok "temp: …and the reason says the walk failed" || bad "temp: the failed walk is unexplained — $(grep -F 'temp:' "$T/o/logs/doctor.log" 2>/dev/null | head -2)"

# ════════════════ the exclusion set is PER PASS, not per process ════════════════════════════════
say_case "the held-root exclusions do not survive into the next pass of the same loop process"
# ⛔ WHY THIS ARM SOURCES THE DOCTOR INSTEAD OF RUNNING IT (review round 2, P1). Every other arm starts a
# fresh `bash "$DOCTOR"`, so a *global* exclusion array looks correct: the process dies with it. But
# `run_loop` calls the pass REPEATEDLY IN ONE PROCESS, and `hr` restarts at 0 each time — so a global
# array kept the high indices from a busier pass, the exclusion set grew to its historical maximum,
# and a later pass excluded roots nothing holds while recording "swept N root(s)". Only a second call
# in the SAME shell can see that. The source guard at the bottom of the doctor makes it importable.
PASS_SB="$T/passdb"
rm -rf "$PASS_SB"; mkdir -p "$PASS_SB/out/logs" "$PASS_SB/state/roles"
rm -f "$T/sup/calls"                                  # the two calls below must be THIS arm's, only
printf 'lane-9\n' > "$T/tmux/sessions"
printf '%s\n' "$T/repo" > "$T/pass-cwds-held"          # pass 1: the repo root is HELD
printf '/usr/local/lib\n' > "$T/pass-cwds-free"        # pass 2: nothing holds it
(
  export O="$PASS_SB/out" CELL_HOME="$PASS_SB/home" REPO="$T/repo" OR=""
  export SUPERVISOR="$T/bin/sup"                     # the function reads $SUPERVISOR directly
  export FAKE_CWD_FILE="$T/pass-cwds-held"
  . "$DOCTOR"                                        # functions only — no pass runs
  begin_pass                                         # the pass-level state a direct call would miss
  hygiene_cache_sweep ""
  FAKE_CWD_FILE="$T/pass-cwds-free"
  begin_pass
  hygiene_cache_sweep ""
)
PASS_CALLS="$(cat "$T/sup/calls" 2>/dev/null)"
PASS1="$(printf '%s\n' "$PASS_CALLS" | sed -n '1p')"
PASS2="$(printf '%s\n' "$PASS_CALLS" | sed -n '2p')"
case "$PASS1" in
  *"--exclude-root="*) ok "two passes in one shell: the FIRST pass excludes the root it found held" ;;
  *) bad "two passes in one shell: the held pass passed no exclusion — $(printf '%s' "$PASS1")" ;;
esac
case "$PASS2" in
  *"--exclude-root="*) bad "the SECOND pass excluded a root nothing holds — the exclusion set survived the pass ($(printf '%s' "$PASS2"))" ;;
  # ⛔ AN EMPTY CALL LINE IS NOT "NO EXCLUSION" (review round 3): if the second pass never invoked the
  # sweep at all, the old `*)` arm reported the reset as proven from a call that does not exist.
  *"prune --caches"*) ok "the SECOND pass passes NO exclusion: the set is per-PASS, reset at the top of the sweep" ;;
  *) bad "the SECOND pass never invoked the sweep, so this arm proved nothing — calls=[$(printf '%s' "$PASS_CALLS" | tr '\n' '|')]" ;;
esac

# ════════════════ summary ═══════════════════════════════════════════════════════════════════════
echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  ✅ all checks passed"; exit 0; fi
echo "  ❌ $FAIL check(s) failed"; exit 1
