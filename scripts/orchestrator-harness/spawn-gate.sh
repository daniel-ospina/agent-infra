#!/usr/bin/env bash
# spawn-gate.sh — the harness's load gate, and the ONE `pi` invocation of the ported callers.
#
# SOURCED (never executed) by the two worker launch paths this port routes through it: `lane.sh`
# and `fix-one.sh` (`adopt-fix.sh` reaches it by calling fix-one.sh).
#
# ⛔ WHAT THIS FILE DOES NOT YET COVER — the header must not imply otherwise, because a comment
# claiming a guard that does not exist reads exactly like one that does. On the current tree:
#   * `merge-one.sh` still carries its OWN copy of `run_agent()` with NO gate. That is the
#     `chain-<N>` first-review path for every own-lane PR — and the one path the controller
#     deliberately stands down for, because the chain holds the claim — plus fix-one.sh's
#     re-review. It is held by concurrent lanes (PR #1769 / #1730), so it is BLOCKED, not declined.
#   * `orch-loop.sh` does NOT source this file: it defines its own `is_num`/`is_limit`/`can_spawn`
#     and gates its four DECISION sites with them. Folding those into this file is a separate
#     change with its own review.
#   * `install.sh` renders MAX_LOAD into the plist; it does not source this file.
#   ⇒ in THIS DIRECTORY the shipped `pi -p` invokers are exactly {merge-one.sh, spawn-gate.sh}, and
#     while `scripts/` as a whole also contains {cloud-cell-bringup.sh, retired/refix.sh,
#     retired/watch-one.sh}. spawn-gate.test.sh asserts BOTH sets as EQUALITIES — a fourth launch
#     path added tomorrow fails that suite loudly instead of drifting in ungated — because a
#     directory-scoped census silently says nothing about the tree outside it. (cloud-cell-bringup.sh
#     is a 120 s provider reachability probe, not a lane dispatch, and is NOT load-gated: a named,
#     asserted residual.)
#
# Why this file exists (agent-infra#1720): the gate used to be a one-liner inside orch-loop.sh plus
# a copy-pasted `run_agent()` in three workers, and only the controller's decision sites consulted
# it — the `pi` calls themselves carried no gate at all. So `chain-<N>` (the primary first-review
# path for every own-lane PR, and the one path the controller deliberately stands down for because
# the chain holds the claim), `fix-one.sh` and `adopt-fix.sh` launched their agent onto whatever
# load existed when they got there: a lane dispatched on a quiet box opened its PR up to 90 minutes
# later and its reviewer landed on the spike the gate was written to prevent. README §4 states that
# gap precisely, and names all three paths; it is the document of record for the residual.
#
# ⛔ THIS PORT IS A MERGE, NOT A COPY. The tortoise original of this file (#8521) carries only the
# gate; the agent-infra copies of `run_agent` had meanwhile gained the #1709 wall-clock telemetry
# (the `elapsed=` field and the durable `walltime.tsv` time series). Adopting the tortoise file
# verbatim would have DELETED that measurement from three shipped scripts, so run_agent() here is
# the canonical one plus the gate. A port that silently regresses the receiving tree is not a port.
set -u

# `is_num` is shared by every numeric coercion below AND by orch-loop.sh (which sources this file
# before its own threshold coercions). It lives here because the ceiling is derived at SOURCE time,
# below, and a guard that runs after the arithmetic it protects is not a guard (#1702).
#
# ⛔ LEADING ZEROS ARE REJECTED, not merely non-digits: `$(( ))` parses base 0, so `08`/`09` are not
# octal and `MAX_LOAD=08` reaches `[ "$L" -ge "08" ]`, which ERRORS — and an errored test in the
# gate chain is FALSE, i.e. it ALLOWS the spawn the gate exists to refuse. This is the same
# predicate merge-one.sh/fix-one.sh apply to REVIEW_TIMEOUT/FIX_TIMEOUT; keeping one shape means a
# caller's later redefinition cannot loosen this file's coercion.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

# ── the ceiling ──────────────────────────────────────────────────────────────────
# Resolved HERE rather than in the caller so a worker started by hand — or by a tmux server whose
# environment predates the plist — still has a live ceiling: the launchd plist supplies MAX_LOAD to
# the daemon, but nothing guarantees it reached the tmux server that starts the workers. The value is
# derived the same way install.sh derives it for the plist (install.sh does not source this file; it
# renders the expression), so the ceiling the gate applies and the ceiling the daemon advertises are
# intended to agree — spawn-gate.test.sh pins the ARITHMETIC this file applies, not install.sh.
#
# The core count is derived PORTABLY. `sysctl -n hw.ncpu` is macOS-only: on a Linux cell sysctl may
# be absent entirely (Debian's procps does not ship it any more) and `hw.ncpu` is a macOS key
# regardless, so the old `|| echo 4` silently pinned _NCPU=4 and MAX_LOAD=40 for EVERY cell (#1702).
_NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
# `is_limit` = is_num AND at most 9 digits. It must NOT reject 0: install.sh validates plist limits
# through it, where 0 is legal, and `MAX_LOAD=0` deliberately means "spawn nothing" (`[ 0 -lt 0 ]`
# is false).
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
# ⛔ `_NCPU` IS GUARDED BY `is_limit`, NOT `is_num`, AND THE REASON IS A WRAP — not a bad comparison
# (P1, review round 2026-10-15). A 19-digit-but-below-2^63 probe does NOT error anywhere: it reaches
# `$(( 10#$_NCPU * 10 ))`, WRAPS, and yields a small, plausible ceiling that every later guard then
# ACCEPTS. Measured before this fix: a probe of 1844674407470955161 gave MAX_LOAD=999999994 on a
# 10-core box — the gate is INERT and every worker launches onto a saturated machine, silently. The
# other wrap direction is the permanent stop: 2^63 wraps to 0, `is_limit 0` is true, and
# `[ "$l" -lt 0 ]` is always false, so the gate CLOSES and the box dispatches nothing, for ever.
# orch-loop.sh:83 and install.sh:45 guard the SAME derivative with `is_limit` for exactly this, and
# README §7.1 records the wrap as already corrected on canonical — so `is_num` here would REGRESS a
# canonical hardening.
# ⛔ THE COMPARISON ITSELF DOES NOT FAIL OPEN — the opposite. `can_spawn` returns `[ -lt ]`'s status
# and every caller tests `if ! can_spawn …`, so an ERRORED comparison is non-zero, `!` makes the
# branch TRUE, and the spawn is REFUSED. Measured: `can_spawn 5` with `MAX_LOAD=abc` returns 2 and
# the caller refuses. So the coercion below defends against the WRAP, the 0-valued probe and the
# 19-digit ceiling — NOT against an open gate, which this shape cannot produce. A reader who takes
# the older rationale ("`[` on a non-number is FALSE and FALSE allows dispatch") at face value will
# mis-reason about which tamper this defends; it is wrong for this one-comparison polarity.
is_limit "${_NCPU:-}"   || _NCPU=4
# A 0-VALUED PROBE IS A FAILED PROBE, NOT "NO CORES": `10 * 0` is 0, `is_limit 0` is true, and
# `[ "$l" -lt 0 ]` is always false — so a 0 probe passes every guard and CLOSES the gate for ever.
# orch-loop.sh:85 and install.sh:47 carry the identical line.
[ "${_NCPU:-0}" -ge 1 ] || _NCPU=4
# `10#` forces base 10 so a value with a leading zero is not re-read as octal.
MAX_LOAD="${MAX_LOAD:-$(( 10#$_NCPU * 10 ))}"
# ⛔ THE FALLBACK MUST BE A TRUE DEFAULT, NOT A RE-DERIVATION. A magnitude guard that falls back to
# `_NCPU * 10` is a NO-OP in the case it exists for: an out-of-range value that came FROM the core
# probe re-derives to the same garbage. The first guard repairs a 10-digit MAX_LOAD derived from a
# 9-digit `_NCPU`; only the literal 40 is genuinely out of range, so it is the final fallback.
is_limit "${MAX_LOAD:-}" || MAX_LOAD=$(( 10#$_NCPU * 10 ))
is_limit "${MAX_LOAD:-}" || MAX_LOAD=40

# 1-min load average, integer. Empty when the probe fails (see can_spawn).
# THE FIELD DIFFERS: /proc field 1 IS the 1-min load, while macOS `sysctl vm.loadavg` prints
# `{ 1.70 1.90 2.00 }`, so field 2 is. One shared awk would therefore read the wrong field on one of
# the two platforms — the bug this function's test pins. The argument is a TEST SEAM (the call site
# passes nothing), the same idiom as orch-loop.sh's mp_reason().
load1() { # [<loadavg-file>]
  local p="${1:-/proc/loadavg}"
  if [ -r "$p" ]; then
    awk '{printf "%d\n", $1}' "$p" 2>/dev/null
  else
    sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}'
  fi
}

# can_spawn <load> — the ONE load gate.
#
# The reading is an ARGUMENT, never a global: merge-one.sh and fix-one.sh already use `L` for their
# LOG PATH, so a gate that read a global `$L` would compare "/Users/…/logs/merge-42" against
# MAX_LOAD — a class of mistake the old shape invited and this one cannot express.
#
# Two callers, two readings, one predicate:
#   * orch-loop.sh's four decision sites pass the reading they cached for the cycle, so the `[cap]`
#     log line and the gate always report the same load;
#   * run_agent() below takes a FRESH reading immediately before it starts the agent — that is the
#     point, since a chain-<N> worker may have waited 90 minutes for its PR first.
#
# An empty reading is treated as 0 = allowed. That is the shipped, documented fail-open: if the
# load probe itself fails, the box must not stop merging entirely. It is NOT a licence to call this
# with no argument — spawn-gate.test.sh pins that the ported callers pass their reading rather than
# a global, and pins that the empty/no-argument case is ALLOWED (the fail-open is a decision, so it
# is asserted rather than left to be rediscovered).
can_spawn() { [ "${1:-0}" -lt "$MAX_LOAD" ]; }

# ── the ONE agent invocation ─────────────────────────────────────────────────────
# run_agent <seconds> <logfile> <promptfile> [label]
#
# Wall-clock limited: `pi -p` has no internal limit, so one hung model call holds a concurrency slot
# forever, and the caps count SESSIONS, so a single hang silently halves throughput. macOS ships no
# `timeout`/`gtimeout`, so this is done in bash: run the agent in the background with a watchdog
# subshell that kills it after N seconds. The stale-worker reaper in orch-loop.sh is the second line
# of defence.
#
# Gated: above MAX_LOAD it does not start the agent at all and returns AGENT_LOAD_REFUSED. That code
# is the caller's signal that NO AGENT RAN — distinct from "the agent ran and failed", because
# merge-one.sh records a `needsfix-<PR>-<head>` marker for the latter. Recording one for a load
# refusal would authorise a fixer for a review that never happened, burn a MAX_FIX_TRIES attempt and
# eventually park the PR (the same failure class as agent-infra#1716).
AGENT_LOAD_REFUSED=75
# Authoritative "an agent ran" flag, set by run_agent() itself. `rc == AGENT_LOAD_REFUSED` alone is
# ambiguous: `pi` shares the 0–255 exit-status namespace, so a pi that exited 75 for its own reason
# would be read as a load refusal — and a caller that acts on that (fix-one.sh skips its merge-chain
# re-run, merge-one.sh skips recording a verdict) would silently do the wrong thing. The flag is set
# only after the gate passed and pi was actually launched, so it cannot be produced by a refusal.
AGENT_STARTED=0
run_agent() { # run_agent <seconds> <logfile> <promptfile> [label]
  local t="$1" log="$2" prompt="$3" label="${4:-agent}" pid w rc l start elapsed
  AGENT_STARTED=0
  l="$(load1)"
  if ! can_spawn "$l"; then
    echo "[load-gate] REFUSED $label: load=$l >= max_load=$MAX_LOAD — no agent started; the controller re-dispatches when load falls, and nothing was consumed" >> "$log"
    return "$AGENT_LOAD_REFUSED"
  fi
  AGENT_STARTED=1
  start="$(date +%s)"
  pi -p --provider deepseek --model deepseek-v4-flash --no-session "$(cat "$prompt")" >> "$log" 2>&1 &
  pid=$!
  ( sleep "$t"; kill -TERM "$pid" 2>/dev/null; sleep 15; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null
  # agent-infra#1709 item 3: wall_limit is the CAP, not the cost. elapsed is the measured
  # reviewer/fixer/lane wall-time — the load-bearing number for fleet capacity (it was unmeasured).
  elapsed=$(( $(date +%s) - start ))
  echo "[timeout] agent pid=$pid wall_limit=${t}s elapsed=${elapsed}s rc=$rc" >> "$log"
  # DURABLE time series (agent-infra#1709 item 3). The per-run log above is TRUNCATED whenever
  # the same PR is re-run (`> "$L.log"`), so a single log line erases its own history: measured,
  # three real reviewer samples (885s/963s/1142s) disappeared within minutes. #1709 needs a DAY
  # of data, which is only possible append-only. Tab-separated, one row per agent invocation.
  # ⛔ A REFUSED SPAWN WRITES NO ROW: no agent ran, so a row here would fabricate a zero-duration
  # sample and corrupt exactly the series #1709 exists to read.
  mkdir -p "$O/state"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "$t" "$elapsed" "$rc" >> "$O/state/walltime.tsv"
  return "$rc"
}
