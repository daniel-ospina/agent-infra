#!/usr/bin/env bash
# ci-queue.sh — CI BACK-PRESSURE: how deep is the repo's CI queue, and may this box send it more
# work yet? Sourced by `orch-loop.sh` (one read per cycle, before dispatch), by `fix-one.sh` (the
# lane whose whole job is to PUSH a new head), and by `dispatch-merge.sh` (the batch dispatcher),
# and runnable STANDALONE (`bash ci-queue.sh status --repo owner/name`), because the same bytes must
# answer the question on whichever surface asks it. It never calls `set` — a sourced library must
# not mutate its caller's shell options.
#
# ── WHY THIS EXISTS (measured 2026-10-22 13:40 UTC, both repos) ─────────────────────────────────
#   tortoise      queued=92  in_progress=6  runners online=5 (busy=5)   ← queue 18x the runner count
#   agent-infra   queued=97  in_progress=7  (runner endpoint unreadable) ← 97 runs, 7 executing
#   job wait created->started:  tortoise P50 0.0m P90  2.5m max 11.2m
#                               agent-infra P50 5.0m P90 11.7m max 13.0m
#   single longest job:         agent-infra `bash-suites` 20.3m; tortoise `queue-health` 11.3m
# After a batch of rebases agent-infra went from 4 to 31 BLOCKED PRs at once, each needing a full CI
# pass, against 5 self-hosted runners. NOTHING FINISHES BECAUSE EVERYTHING STARTED: throughput
# (merges/hour) went DOWN while the work went up. This file is the reading that was missing: every
# existing gate in this harness — `load=`, `mem_avail=`, `swap_free=`, `capacity-placement` — measures
# THE BOX, and a box with 20 idle lane slots and a 90-deep CI queue looks perfectly healthy.
#
# ⛔ IT IS A MEASURED QUEUE READ, NOT A WORKER/LANE CAP — and that distinction is the recorded
# decision, not this file's preference. The owner ruled on 2026-10-17 "dispatch should be gated on
# capacity, not on number of lanes" (argued at `capacity.sh`'s ceiling section and at orch-loop.sh's
# MAX_LANES block), and re-stating that as a fixed lane ceiling here would reopen a settled
# decision through a side door. So the gate counts THE OTHER SIDE'S CAPACITY: how many runs are
# waiting, how many are executing, how many runners can execute them. A box that adds work when the
# queue is under the ceiling is allowed exactly as before; nothing here caps lanes.
#
# ── THE CEILING: DERIVED FROM THE RUNNERS AND THE JOB, NOT A MAGIC CONSTANT ────────────────────
# A self-hosted runner executes ONE job at a time, so a queue of Q runs in front of R runners drains
# in about (Q / R) job-durations. A push is worth making only if its own verdict will arrive within
# the horizon a lane is willing to wait for it — after that the push has bought nothing and it has
# DESTROYED the head-bound artifacts of the PR it touched (the review attestation is bound to a SHA,
# so a rebase/amend silently invalidates it: agent-infra#2148, `reviewer-preflight.sh`).
#
#     ceiling = ceil( runners * horizon_min / job_p90_min )
#
# With the measurement above — 5 runners, a 20-minute horizon (a lane's own re-review + merge chain
# has to fit inside one controller cycle's patience, and 20m is 2x the observed P90 job wait), and a
# 10-minute typical job (tortoise job duration P90 = 9.0m; agent-infra's `bash-suites` worst = 20.3m,
# which is why the horizon is not derived from the WORST job — a ceiling built on the worst job would
# never bind) — the ceiling is ceil(5 * 20 / 10) = 10 queued runs. The 2026-10-22 incident queue (92
# and 97) is 9-10x that; the pre-incident baseline (4) is comfortably under it. That is the check
# both arms must pass: a rule that defers on 4 would be a fleet-wide stop, and one that allows 92 is
# not a gate at all.
#
# ⛔ EVERY TUNING VALUE LIVES IN THIS FILE, IN THE TWO FUNCTIONS BELOW (`ciq_horizon_min`,
# `ciq_job_p90_min`) — one place to change the arithmetic, overridable by the matching env name,
# with the shipped default being the MEASURED one. Nothing about this gate is rendered into the
# launchd plist, so there is no second copy to drift (install.sh does not source this file).
#
# ── FAIL-CLOSED, AND THE ONE PLACE THAT IS DELIBERATELY NOT ─────────────────────────────────────
#   * An UNREADABLE queue is **UNKNOWN**, and UNKNOWN defers CI-spending work. The alternative — an
#     unreadable read opening the gate — is the fail-open shape this repo has removed from every
#     other instrument: a `gh` outage would then be indistinguishable from an empty queue, and the
#     fleet would stampede on exactly the cycle it could not see. Because dispatch is what is being
#     gated, UNKNOWN stopping dispatch costs a cycle; the defect it prevents costs a night.
#   * The ONE fail-open is the CACHE: a read that succeeded within `CIQ_TTL` seconds is used for free
#     (a burst of N dispatches in one cycle must not become N reads), and a read that FAILS falls
#     back to the last successful record for up to `CIQ_STALE_MAX` seconds — reported as
#     `cache(<age>s)` in every line it produces, so a stale reading is never presented as a fresh
#     one. Past that window the record is dropped and the verdict is UNKNOWN again.
#   * `runners` falls back to `max(1, in_progress)` when the runners endpoint cannot be read (it is
#     admin-scoped and returned 404 on the org, and an EMPTY list on agent-infra while 7 runs were
#     executing). `in_progress` is a MEASURED LOWER BOUND on parallelism — a runner is running, so a
#     runner exists — and using it keeps the ceiling derived from a measurement instead of a guess.
#     The record says `runners=<n>(busy)` when the endpoint answered, `runners=~<n>` when it did not.

# `is_num` — the shared shape predicate (no leading zeros, exactly like spawn-gate.sh: a value that
# reaches `$(( ))` must not be an invalid octal, and a non-number in a threshold makes `[ -gt ]`
# ERROR, which is FALSE, which OPENS a gate).
ciq_is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

# ── the two tuning values (the ONE place) ───────────────────────────────────────────────────────
ciq_horizon_min() { # how long a lane will wait for its own CI verdict before the push is pointless
  local v="${CIQ_HORIZON_MIN:-20}"
  ciq_is_num "$v" && [ "$v" -ge 1 ] && [ "$v" -le 600 ] || v=20
  printf '%s' "$v"
}
ciq_job_p90_min() { # MEASURED typical job duration, minutes (see the header's measurement block)
  local v="${CIQ_JOB_P90_MIN:-10}"
  ciq_is_num "$v" && [ "$v" -ge 1 ] && [ "$v" -le 600 ] || v=10
  printf '%s' "$v"
}

# ciq_ceiling <runners> -> the queued-run ceiling this runner count implies (see the derivation).
# Prints nothing and returns 1 on an unusable runner count, so a caller can distinguish "no ceiling
# could be derived" from "the ceiling is 0" (which would be a lane-cap in disguise and is refused:
# a 0 ceiling would defer every push forever, so the floor is 1 runner).
ciq_ceiling() {
  local r="${1:-}" h j
  ciq_is_num "$r" || return 1
  [ "$r" -ge 1 ] || r=1
  h="$(ciq_horizon_min)" || return 1
  j="$(ciq_job_p90_min)" || return 1
  [ "$j" -ge 1 ] || j=1
  printf '%s' "$(( (r * h + j - 1) / j ))"
}

# ciq_slug <owner/repo> -> a filename-safe key (one record per repo, never one box's queue for all).
ciq_slug() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_' | tr -s '_' '_'; }

# ciq_state_dir -> where the cached record lives. `$O/state` on a controller; overridable so the
# suite (and an operator) can point it at a sandbox without touching the live state directory.
ciq_state_dir() {
  local d="${CIQ_STATE_DIR:-${O:-$HOME/orchestrator}/state}"
  printf '%s' "$d"
}

# ciq_gh -> the reader. DELIBERATELY a function with an override: the suite stubs it, so the tests
# exercise the SHIPPED parsing and arithmetic against a canned feed instead of asserting on prose.
ciq_gh() { # <args...> -> JSON on stdout, non-zero when the read failed
  local ghbin="${CIQ_GH:-gh}"
  command -v "$ghbin" >/dev/null 2>&1 || return 127
  "$ghbin" api "$@" 2>/dev/null
}

# ciq_now -> epoch seconds (one seam, so the TTL is drivable in the suite).
ciq_now() { date +%s; }

# ciq_read <owner/repo> [<state-dir>] -> sets the CIQ_* record; 0 = usable reading, 2 = UNKNOWN.
# Record fields (all set on every call, so a caller never reads a previous call's leftovers):
#   CIQ_QUEUED  runs waiting for a runner
#   CIQ_RUNNING runs executing now
#   CIQ_RUNNERS runners that can execute them (measured; `~` lower bound when inferred)
#   CIQ_BUSY    runners currently busy (blank when the endpoint did not answer)
#   CIQ_CEILING the derived ceiling for CIQ_RUNNERS
#   CIQ_STATE   fresh | cache | unknown
#   CIQ_AGE     seconds the record has been standing (0 for a fresh read)
#   CIQ_REPO    the repo the read was made against (the wrong-surface guard: a number is only
#               meaningful next to the repo it came from — orch-loop.sh learned that the hard way
#               with its merge backlog)
ciq_read() {
  local repo="${1:-}" dir="${2:-}" f cached="" at="" queued="" running="" runners="" busy="" now age ttl stale_max
  CIQ_QUEUED=""; CIQ_RUNNING=""; CIQ_RUNNERS=""; CIQ_BUSY=""; CIQ_CEILING=""; CIQ_STATE=unknown; CIQ_AGE=""; CIQ_REPO="$repo"
  [ -n "$repo" ] || return 2
  dir="${dir:-$(ciq_state_dir)}"
  f="$dir/ci-queue-$(ciq_slug "$repo")"
  ttl="${CIQ_TTL:-90}";        ciq_is_num "$ttl" || ttl=90
  stale_max="${CIQ_STALE_MAX:-900}"; ciq_is_num "$stale_max" || stale_max=900
  now="$(ciq_now)"; ciq_is_num "$now" || now=0

  # A fresh record answers for free. This is the ONLY fail-open here, and it is bounded by `ttl`.
  if [ -f "$f" ]; then
    cached="$(cat "$f" 2>/dev/null || true)"
    at="$(printf '%s\n' "$cached" | sed -n 's/^at=//p' | head -1)"
    if ciq_is_num "${at:-}"; then
      age=$(( now - at )); [ "$age" -lt 0 ] && age=0
      if [ "$ttl" -ge 1 ] && [ "$age" -le "$ttl" ]; then
        CIQ_QUEUED="$(printf '%s\n' "$cached" | sed -n 's/^queued=//p' | head -1)"
        CIQ_RUNNING="$(printf '%s\n' "$cached" | sed -n 's/^running=//p' | head -1)"
        CIQ_RUNNERS="$(printf '%s\n' "$cached" | sed -n 's/^runners=//p' | head -1)"
        CIQ_BUSY="$(printf '%s\n' "$cached" | sed -n 's/^busy=//p' | head -1)"
        if ciq_is_num "${CIQ_QUEUED:-}" && ciq_is_num "${CIQ_RUNNERS:-}"; then
          CIQ_STATE=fresh; CIQ_AGE="$age"
          CIQ_CEILING="$(ciq_ceiling "${CIQ_RUNNERS#\~}")" || CIQ_CEILING=""
          return 0
        fi
      fi
    fi
  fi

  # A live read: three cheap counts. `per_page=1` because only `total_count` is wanted — the array is
  # not read at all, so a capped page can never truncate the number that matters.
  queued="$(ciq_gh "repos/$repo/actions/runs?status=queued&per_page=1" \
            | sed -n 's/.*"total_count":[ ]*\([0-9][0-9]*\).*/\1/p' | head -1)" || queued=""
  running="$(ciq_gh "repos/$repo/actions/runs?status=in_progress&per_page=1" \
            | sed -n 's/.*"total_count":[ ]*\([0-9][0-9]*\).*/\1/p' | head -1)" || running=""
  busy=""; runners=""
  if _rn="$(ciq_gh "repos/$repo/actions/runners")"; then
    # Count `"status":"online"` objects. The endpoint returns `{"total_count":N,"runners":[…]}`; a
    # repo with no runners of its own (agent-infra, measured) yields 0 and is NOT an error — it
    # simply does not answer the question, so the inference below takes over.
    runners="$(printf '%s' "$_rn" | tr ',' '\n' | grep -c '"status":"online"' 2>/dev/null || true)"
    busy="$(printf '%s' "$_rn" | tr ',' '\n' | grep -c '"busy":true' 2>/dev/null || true)"
    ciq_is_num "${runners:-}" || runners=""
    ciq_is_num "${busy:-}" || busy=""
    [ "${runners:-0}" -ge 1 ] 2>/dev/null || { runners=""; busy=""; }
  fi
  if ! ciq_is_num "${queued:-}" || ! ciq_is_num "${running:-}"; then
    queued=""; running=""
  fi
  if [ -z "${queued:-}" ]; then
    # The read failed. Fall back to the last good record inside the staleness window, and SAY so.
    if ciq_is_num "${at:-}" && [ -n "${cached:-}" ]; then
      age=$(( now - at )); [ "$age" -lt 0 ] && age=0
      if [ "$age" -le "$stale_max" ]; then
        CIQ_QUEUED="$(printf '%s\n' "$cached" | sed -n 's/^queued=//p' | head -1)"
        CIQ_RUNNING="$(printf '%s\n' "$cached" | sed -n 's/^running=//p' | head -1)"
        CIQ_RUNNERS="$(printf '%s\n' "$cached" | sed -n 's/^runners=//p' | head -1)"
        CIQ_BUSY="$(printf '%s\n' "$cached" | sed -n 's/^busy=//p' | head -1)"
        if ciq_is_num "${CIQ_QUEUED:-}" && ciq_is_num "${CIQ_RUNNERS:-}"; then
          CIQ_STATE=cache; CIQ_AGE="$age"
          CIQ_CEILING="$(ciq_ceiling "${CIQ_RUNNERS#\~}")" || CIQ_CEILING=""
          return 0
        fi
      fi
    fi
    CIQ_STATE=unknown
    return 2
  fi
  if [ -z "${runners:-}" ]; then
    # A measured lower bound: every executing run has a runner, so `running` is the parallelism that
    # demonstrably exists. Floor of 1 keeps the ceiling derivable on an idle repo (0 executing).
    runners="${running:-0}"; [ "$runners" -ge 1 ] || runners=1
    runners="~$runners"
  fi
  CIQ_QUEUED="$queued"; CIQ_RUNNING="${running:-0}"; CIQ_RUNNERS="$runners"; CIQ_BUSY="$busy"
  CIQ_STATE=fresh; CIQ_AGE=0
  CIQ_CEILING="$(ciq_ceiling "${CIQ_RUNNERS#\~}")" || CIQ_CEILING=""
  mkdir -p "$dir" 2>/dev/null || true
  { printf 'queued=%s\nrunning=%s\nrunners=%s\nbusy=%s\nat=%s\n' \
      "$CIQ_QUEUED" "$CIQ_RUNNING" "$CIQ_RUNNERS" "${CIQ_BUSY:-}" "$now"; } > "$f" 2>/dev/null || true
  return 0
}

# ciq_eval -> the DECISION, from the record already in CIQ_* (no read, no subshell, so a caller
# that captured nothing still sees the numbers that produced the token). Prints one token:
#   deep(...)   rc 0 — do NOT send more CI-spending work
#   ok(...)     rc 1 — allowed
#   unknown(…)  rc 2 — unreadable: DEFER (fail closed)
# The token is the whole decision, so a caller cannot read the numbers and reach its own conclusion
# differently from the gate that is logged (the "printed decision vs acted-on decision" class this
# harness has already fixed twice).
ciq_eval() {
  local q r n c
  if [ "${CIQ_STATE:-unknown}" = unknown ]; then
    printf 'unknown(queue unreadable: no fresh read and no record inside %ss — CI capacity is UNKNOWN, which defers CI-spending work rather than opening the gate)' "${CIQ_STALE_MAX:-900}"
    return 2
  fi
  q="$CIQ_QUEUED"; r="$CIQ_RUNNING"; n="${CIQ_RUNNERS#\~}"; c="${CIQ_CEILING:-}"
  if [ -z "${c:-}" ]; then
    printf 'unknown(no ceiling derivable from runners=%s)' "${CIQ_RUNNERS:-?}"
    return 2
  fi
  if [ "$q" -gt "$c" ]; then
    printf 'deep(queued=%s running=%s runners=%s%s ceiling=%s derived=ceil(%s*%s/%s))' \
      "$q" "$r" "${CIQ_RUNNERS}" "$( { [ "${CIQ_RUNNERS#\~}" = "$CIQ_RUNNERS" ] && [ -n "${CIQ_BUSY:-}" ]; } && printf ' busy=%s' "$CIQ_BUSY" )" \
      "$c" "$n" "$(ciq_horizon_min)" "$(ciq_job_p90_min)"
    return 0
  fi
  printf 'ok(queued=%s running=%s runners=%s ceiling=%s state=%s%s)' \
    "$q" "$r" "${CIQ_RUNNERS}" "$c" "${CIQ_STATE}" "$( [ "${CIQ_STATE}" = cache ] && printf ' age=%ss' "${CIQ_AGE}" )"
  return 1
}

# ciq_verdict <owner/repo> [<state-dir>] -> read, then evaluate IN THIS SHELL (a `$( )` here would
# end the subshell immediately and leave every caller with an empty record — the exact defect class
# `lo_select` carries a ⛔ comment about).
ciq_verdict() {
  ciq_read "${1:-}" "${2:-}" || { ciq_eval; return $?; }
  ciq_eval
}

# ciq_defer_note <what> [<state-dir>] -> THE ONE LINE a deferral must emit. Silence is what makes a
# deferral look like a bug, so this is the only way the harness is allowed to defer: it names the
# queue depth, the runner count, the ceiling it was measured against, and WHAT was deferred.
# Prints the line; returns 0 when the line was produced (deep or unknown), 1 when nothing is due.
ciq_defer_note() {
  local what="${1:-work}" v rc
  v="$(ciq_verdict "${CIQ_REPO_ARG:-${OR:-}}" "${CIQ_STATE_DIR:-}")"; rc=$?
  case "$rc" in
    0) printf '[ci-queue] DEFERRED %s — %s; ceiling=ceil(runners*%sm/%sm) so this push would queue behind the backlog and invalidate the head'"'"'s review record (a SHA-bound attestation); NOTHING IS LOST: the item keeps its place and is re-decided on the next cycle, and the deferral consumed no attempt\n' \
         "$what" "$v" "$(ciq_horizon_min)" "$(ciq_job_p90_min)"
       return 0 ;;
    2) printf '[ci-queue] DEFERRED %s — %s\n' "$what" "$v"; return 0 ;;
    *) return 1 ;;
  esac
}

# ciq_ci_allowed <owner/repo> [<state-dir>] -> 0 = send CI-spending work, 1 = defer (and the caller
# must print ciq_defer_note's line). This is the predicate the wiring calls; it never prints, so a
# caller inside a `$( )` cannot swallow the log.
ciq_ci_allowed() {
  ciq_verdict "${1:-${OR:-}}" "${2:-${CIQ_STATE_DIR:-}}" >/dev/null 2>&1
  case $? in 1) return 0 ;; *) return 1 ;; esac
}

# ── standalone: `bash ci-queue.sh status [--repo owner/name]` ───────────────────────────────────
# Prints the verdict, the record and the derivation. Exit code follows the verdict (0 deep, 1 ok,
# 2 unknown) so an operator (or a hook) can branch on it without parsing.
ciq_cli() {
  local repo="" verb="${1:-status}"
  shift 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --state-dir) CIQ_STATE_DIR="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$repo" ] || repo="${OR:-}"
  case "$verb" in
    status|check|defer)
      CIQ_REPO_ARG="$repo"
      if ciq_read "$repo"; then :; fi
      ciq_eval; rc=$?; printf '\n'
      printf 'repo=%s state=%s source=%s age=%ss\n' "${repo:-?}" "${CIQ_STATE}" "${CIQ_TYPE:-gh}" "${CIQ_AGE:-?}"
      printf 'record: queued=%s running=%s runners=%s busy=%s at=%s\n' \
        "${CIQ_QUEUED:-?}" "${CIQ_RUNNING:-?}" "${CIQ_RUNNERS:-?}" "${CIQ_BUSY:-?}" "$(ciq_state_dir)/ci-queue-$(ciq_slug "${repo:-}")"
      printf 'derivation: ceiling = ceil(runners * horizon / job_p90) = ceil(%s * %s / %s) = %s\n' \
        "${CIQ_RUNNERS:-?}" "$(ciq_horizon_min)" "$(ciq_job_p90_min)" "${CIQ_CEILING:-?}"
      if [ "$verb" = defer ] && [ "$rc" != 1 ]; then
        ciq_defer_note "CI-spending work (manual check)"
      fi
      return "$rc" ;;
    ceiling)
      ciq_ceiling "${2:-1}" || return 1
      printf '\n'; return 0 ;;
    *) printf 'usage: ci-queue.sh status|defer|ceiling [--repo owner/name] [--state-dir DIR]\n' >&2; return 64 ;;
  esac
}

# Executed (not sourced)? run the CLI. `BASH_SOURCE` is unset when the file is piped to a shell, in
# which case the CLI is the only sensible reading.
if [ "${BASH_SOURCE:-}" = "$0" ] || { [ -z "${BASH_SOURCE+x}" ] && [ -n "${0:-}" ]; }; then
  ciq_cli "$@"
  exit $?
fi
