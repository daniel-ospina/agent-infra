#!/usr/bin/env bash
# ci_runner_cell1_bringup.sh — bring THIS cell's agent-infra runners up, honestly labelled, and
# PROVE they serve jobs instead of merely existing.
#
# WHY THIS EXISTS — three measured failures, all on cell-1, 2026-10-24T03:45-04:10Z:
#
#  1. A DEAD LISTENER IS INVISIBLE, AND THE OBVIOUS PROBE LIES ABOUT IT.
#     `pgrep -fc "[R]unner.Listener"` is the natural health probe and it is wrong: it counts the
#     SELF-HEALER's own `bash -lc` argv (which contains the literal string) alongside the real
#     processes. Measured: it read 8 "listeners" for 4 real ones — and the two registrations that
#     actually needed starting were not in that count at all (they had no process). Both of them
#     had died at 2026-10-23T15:22:51Z on `No space left on device` writing their own `_diag`
#     log and never came back. A dead listener is the normal state of this box, not an exception,
#     so this script does not count processes: it reads the ARTIFACT — GitHub's runner list
#     (`status` + `busy`) and the new listener's own `_diag` line `Listening for Jobs`.
#
#  2. AN "ONLINE" RUNNER THAT MATCHES NO JOB IS COUNTED AS CAPACITY (#2589).
#     agent-infra's jobs ask for `ubuntu-latest`; a registration whose label set lacks it can
#     never be scheduled, so the pool tooling counts a slot no job can reach — measured on this
#     repo as `online` runners with `busy=false` forever. The label set is PRINTED before it is
#     applied and re-read from the API after.
#     ⛔ Do NOT "repair" these labels with `tortoise`'s `tools/install-ci-runner-x64.sh --repair-labels`: its
#     PUT body is `{self-hosted-x64,ubuntu-latest}`, and the labels endpoint REPLACES the custom
#     set, so it would silently drop this pool's own `agent-infra` marker. This script PUTs the
#     union and names it in the output.
#
#  3. A RUNNER WITH A DIFFERENT `awk` THAN HOSTED MANUFACTURES A FALSE RED.
#     Measured 2026-10-24T03:53:34Z (job 120770477498): `tests/materialize-agents/run.sh` died
#     `awk rc 100` on this box — mawk 1.3.4 panics `REcompile() - panic: values still on machine
#     stack` on the MD026 regex `^#{1,6}([ \t]|$)` — while the same step passes on GitHub-hosted
#     (gawk). A false red blocks a landing exactly like a queue does, and it blames the diff.
#     So the preflight refuses to start a listener whose `awk` is not GNU awk, and names the fix.
#
# MEMORY / DISK — the start is gated on the box's OWN readings, and prints them (#2387: the same
#   doctrine as ci_runner_pool.sh's floor, "manage capacity well has to be a predicate the machine
#   evaluates, not a wish in a brief"). Restarting an existing registration mints no new slot, so
#   ci_runner_pool.sh's ADD floor does not apply — but a listener that starts into 200 MB free dies
#   on its first job and takes a lane's FalkorDB with it, which is the OOM wave #2387 records.
#   Density is a measurement, never a target: this script starts only the registrations that
#   already exist, and never registers a new one. `scripts/ci_runner_pool.sh status` remains the
#   box's slot/ceiling view (measured 2026-10-24: slots=6, ceiling=3 on this 8-core box — the
#   ceiling belongs to an owner decision about THIS box, not to this script).
#
# USAGE
#   scripts/ci_runner_cell1_bringup.sh                 # label + start + verify every existing install
#   scripts/ci_runner_cell1_bringup.sh --dry-run       # print the plan, the readings, change nothing
#   scripts/ci_runner_cell1_bringup.sh --status        # artifact-only report (no start, no label write)
#   --count N        (default 2) how many installs 1..N to consider
#   --skip-awk-check (escape hatch, prints a warning; a mawk panic is a false red, not a test bug)
#
# EXIT: 0 ok · 1 usage · 2 could-not-measure / could-not-act (nothing started) ·
#       3 REFUSED — a guard verdict or an install that is not configured. Nothing changed.
set -uo pipefail

REPO="${CI_RUNNER_REPO:-daniel-ospina/agent-infra}"
ROOT="${CI_RUNNER_ROOT:-/tmp/actions-runner}"
NAME_PREFIX="${CI_RUNNER_PREFIX:-ai-runner-cell1-x64}"
# The custom label set a job on this repo can actually match. Host-derived labels
# (`self-hosted`,`Linux`,`X64`) are added by GitHub at registration and cannot be set --- or
# removed --- through this endpoint, so they are deliberately not repeated here.
LABELS="${CI_RUNNER_LABELS:-self-hosted-x64,agent-infra,ubuntu-latest}"
MEM_MIN_MB="${CI_RUNNER_MEM_MIN_MB:-3584}"    # ci_runner_pool.sh's floor, reused rather than re-derived
DISK_MIN_GB="${CI_RUNNER_DISK_MIN_GB:-4}"     # a job's checkout+venv peaked at ~0.5-2G here; below 4G
                                              # the next ENOSPC is a matter of which job lands first
SETTLE_S="${CI_RUNNER_SETTLE_S:-20}"
COUNT=2; DRY=0; MODE=run; AWK_CHECK=1

while [ $# -gt 0 ]; do
  case "$1" in
    --count) COUNT="${2:-}"; shift 2 2>/dev/null || shift ;;
    --count=*) COUNT="${1#*=}"; shift ;;
    --dry-run) DRY=1; shift ;;
    --status) MODE=status; shift ;;
    --skip-awk-check) AWK_CHECK=0; shift ;;
    -h|--help) awk '/^# USAGE/{p=1} /^set -uo pipefail$/{p=0} p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $0 [--count N] [--dry-run] [--status] [--skip-awk-check]" >&2; exit 1 ;;
  esac
done
case "$COUNT" in ''|*[!0-9]*) echo "usage: --count must be a positive integer (got '$COUNT')" >&2; exit 1 ;; esac
[ "$COUNT" -ge 1 ] || { echo "usage: --count must be >= 1 (got $COUNT)" >&2; exit 1; }

say() { printf '%s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { say "cannot-act why=missing-tool tool=$1"; exit 2; }; }

dir_for() { printf '%s/%s-%s' "$ROOT" "$NAME_PREFIX" "$1"; }
# Liveness is the process table matched on BOTH the instance dir and GitHub's fixed binary name.
# A pid file would be a stale flag (#8175's class); a bare `pgrep -f Runner.Listener` is the
# inflation this script's header is about.
listen_pid() { pgrep -f "^$1/bin/Runner.Listener run" 2>/dev/null | head -1; }

disk_free_gb() { df -Pk "$ROOT" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}'; }
mem_avail_mb() { awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null; }

# ── status: the artifact view only ────────────────────────────────────────────
# Read-only in every mode: this is the report a caller branches on, and it never starts anything.
remote_rows() { gh api "repos/$REPO/actions/runners?per_page=100" \
  --jq '.runners[] | "\(.id)\t\(.name)\t\(.status)\tbusy=\(.busy)\t\([.labels[].name]|join(","))"'; }

if [ "$MODE" = status ]; then
  need gh
  remote_rows || { say "cannot-measure why=runner-list-unreadable repo=$REPO"; exit 2; }
  for i in $(seq 1 "$COUNT"); do
    d="$(dir_for "$i")"
    [ -f "$d/.runner" ] || { say "dir=$d state=NOT-CONFIGURED"; continue; }
    pid="$(listen_pid "$d")"
    say "dir=$d listener=$([ -n "$pid" ] && echo "live pid=$pid" || echo DEAD)"
  done
  exit 0
fi

# ── preflight: the readings this script will act on, printed BEFORE it acts ────
need gh
need nohup
mem_mb="$(mem_avail_mb)"; disk_gb="$(disk_free_gb)"
case "${mem_mb:-}" in ''|*[!0-9]*) say "cannot-measure why=mem-unreadable (orchestrator-harness/capacity.sh is the owner of that read; this script refuses rather than guess)"; exit 2 ;; esac
case "${disk_gb:-}" in ''|*[!0-9]*) say "cannot-measure why=disk-unreadable root=$ROOT"; exit 2 ;; esac
# `CI_RUNNER_AWK_VERSION` is a SEAM (same shape as install-ci-runner-x64.sh's `CI_RUNNER_ARCH`): the
# guarded box is not always the box reading this code, and a test cannot uninstall gawk to exercise
# the refusal. It changes no behaviour on a real host.
awk_pin="${CI_RUNNER_AWK_VERSION:-$(awk --version 2>&1 | head -1)}"
say "readings: MemAvailable=${mem_mb}MB (floor ${MEM_MIN_MB}MB) disk_free=${disk_gb}G (floor ${DISK_MIN_GB}G) awk='${awk_pin}'"
say "labels: ${LABELS}  (host-derived self-hosted,Linux,X64 are added by GitHub, not settable here)"

if [ "$mem_mb" -lt "$MEM_MIN_MB" ]; then
  say "REFUSED why=mem-below-floor MemAvailable=${mem_mb}MB floor=${MEM_MIN_MB}MB — nothing started (#2387)"
  exit 3
fi
if [ "$disk_gb" -lt "$DISK_MIN_GB" ]; then
  say "REFUSED why=disk-below-floor free=${disk_gb}G floor=${DISK_MIN_GB}G — nothing started; this is the exact state that killed these two listeners at 15:22:51Z (ENOSPC)"
  exit 3
fi
if [ "$AWK_CHECK" = 1 ]; then
  case "$awk_pin" in
    *"GNU Awk"*) : ;;
    *) say "REFUSED why=awk-not-gawk awk='${awk_pin}' — hosted CI runs GNU awk, and mawk 1.3.4 panics on the interval-expression regexes in tests/materialize-agents (job 120770477498, 'awk rc 100'). Fix: sudo apt-get install -y gawk, then re-run; --skip-awk-check overrides."
       exit 3 ;;
  esac
fi

queued_before="$(gh api "repos/$REPO/actions/runs?status=queued&per_page=1" --jq '.total_count' 2>/dev/null)"
say "queued_before=${queued_before:-UNREADABLE}"

rc=0
for i in $(seq 1 "$COUNT"); do
  d="$(dir_for "$i")"; name="$NAME_PREFIX-$i"
  if [ ! -f "$d/.runner" ]; then
    say "REFUSED name=$name why=not-configured dir=$d (no .runner) — register it, this script only starts what exists"
    rc=3; continue
  fi
  id="$(gh api "repos/$REPO/actions/runners?per_page=100" --jq ".runners[]|select(.name==\"$name\")|.id" 2>/dev/null | head -1)"
  case "${id:-}" in ''|*[!0-9]*) say "cannot-act name=$name why=no-registration (GitHub does not list it; a local .runner alone serves nothing)"; rc=2; continue ;; esac

  body="$(printf '{"labels":["%s"]}' "$(printf '%s' "$LABELS" | sed 's/,/","/g')")"
  if [ "$DRY" = 1 ]; then
    say "dry-run: would PUT $body to runner $id ($name), then start $d/run.sh detached"
    continue
  fi

  # Labels first: a listener that starts on a label set no job matches is the "online and never
  # busy" failure this script exists to prevent (#2589).
  if got="$(printf '%s' "$body" | gh api -X PUT "repos/$REPO/actions/runners/$id/labels" --input - --jq '[.labels[].name]|join(",")' 2>&1)"; then
    say "labelled name=$name id=$id labels=$got"
  else
    say "cannot-act name=$name why=label-write-failed detail=$got"; rc=2; continue
  fi

  pid="$(listen_pid "$d")"
  if [ -n "$pid" ]; then
    say "already-live name=$name pid=$pid — not restarting (a second listener on one install double-claims jobs)"
    continue
  fi

  # Detached, no tmux ON PURPOSE: a tmux server death once took eight lanes with it.
  ( cd "$d" && setsid nohup ./run.sh >> runner.log 2>&1 < /dev/null & )
  started=0
  for _ in $(seq 1 "$SETTLE_S"); do
    sleep 1
    f="$(ls -t "$d"/_diag/Runner_*.log 2>/dev/null | head -1)"
    # "Listening for Jobs" is the artifact; the Conflict retry loop (#2502) never prints it.
    if [ -n "$f" ] && grep -q "Listening for Jobs" "$f" 2>/dev/null; then started=1; break; fi
  done
  if [ "$started" = 1 ]; then
    say "started name=$name pid=$(listen_pid "$d") _diag=Listening-for-Jobs"
  else
    say "cannot-act name=$name why=no-listening-line-in-_diag (last lines below)"
    tail -3 "$d/runner.log" 2>/dev/null | sed 's/^/    /' >&2
    rc=2
  fi
done

[ "$DRY" = 1 ] && { say "dry-run: nothing changed"; exit "$rc"; }
# ⛔ A PER-RUNNER REFUSAL IS NOT A CAPACITY VERDICT, and the verify block below must not relabel it.
# Measured in this script's own test: a missing `.runner` refused 3, the verify stage then found
# online=0 and exited 2 — so a caller read "could not act" for a box that had plainly said "do not
# start this". The refusal is the more specific answer and it wins.
if [ "$rc" -ne 0 ]; then
  say "exit=$rc — a runner above was refused/failed, so no capacity verdict is claimed"
  exit "$rc"
fi

# ── verify BY ARTIFACT: online is necessary, busy is the proof ────────────────
# A runner that is `online` and never `busy` is exactly what this lane exists to fix, so the
# script prints both and exits non-zero when no runner it started has taken a job.
say "── verifying (online is necessary; busy within ${SETTLE_S}s of a queued run is the proof)"
online=0; busy=0
for _ in $(seq 1 6); do
  rows="$(remote_rows 2>/dev/null)" || { say "cannot-measure why=runner-list-unreadable"; exit 2; }
  online="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$NAME_PREFIX" '$2 ~ ("^" p "-") && $3=="online"' | wc -l | tr -d ' ')"
  busy="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$NAME_PREFIX" '$2 ~ ("^" p "-") && $0 ~ /busy=true/' | wc -l | tr -d ' ')"
  say "  $(date -u +%T) online=$online busy=$busy"
  [ "$busy" -ge 1 ] && break
  sleep 5
done
printf '%s\n' "$rows" | awk -F'\t' -v p="$NAME_PREFIX" '$2 ~ ("^" p "-") {printf "  %s\t%s\t%s\t%s\n",$2,$3,$4,$5}' >&2
queued_after="$(gh api "repos/$REPO/actions/runs?status=queued&per_page=1" --jq '.total_count' 2>/dev/null)"
say "queued_before=${queued_before:-UNREADABLE} queued_after=${queued_after:-UNREADABLE}"
if [ "$online" -ge 1 ] && [ "$busy" -ge 1 ]; then
  say "OK online=$online busy=$busy"
  exit "$rc"
fi
say "NOT-OK online=$online busy=$busy — online without busy is the #2589 failure this script exists to prevent"
exit 2
