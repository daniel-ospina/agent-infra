#!/usr/bin/env bash
# cell-lane-preflight.sh — can THIS box complete one model call AND return? Answer in ~10 s, with the
# reading, instead of discovering it across a 3300 s lane cap (agent-infra#2935).
#
# WHY THIS EXISTS
# ───────────────
# Measured 2026-10-28 05:00–06:00Z: six lanes on cell1 and five on cell3 each ran the full 3300 s
# lane cap and produced 0 commits, while cell4 ran the identical launcher (`lane.sh --repo …`) to 8
# commits. The only gate in front of a dispatch wave was LOAD — which an idle box passes precisely
# because it is idle. So two boxes held 6-8 LLM slots for 55 minutes each and nothing named why.
#
# Re-measured 2026-10-28 06:00–06:40Z on all three boxes, one thing at a time:
#
#   box    pi       cores  models.json  keys.env  dns/tls  direct completion  $O seed  bare `pi -p`
#   cell1  0.85.1   8      same         present   ok       200 / 636 ms       same     exits 13 s
#   cell3  1.2.0    4      same         present   ok       200 / 740 ms       same     ALIVE >150 s
#   cell4  1.2.0    8      same         present   ok       200 / 895 ms       same     ALIVE >150 s
#
# That table refuses the three hypotheses the issue named (endpoint reachability, the keys file, a
# stale `$O` seed: byte-identical on all three) and leaves the one thing that IS per-box and that no
# instrument reads: whether this box's `pi` finishes a call and RETURNS. So this gate measures that
# and nothing else, at the spawn point, before the slot is spent.
#
# ⛔ WHAT THAT TABLE IS, AND WHAT IT IS NOT (review of #2991, premise finding). It is a DATED per-box
# reading taken 2026-10-28 06:00-06:40Z; it is NOT a re-measurement, and it does not agree with the
# PR's own body table, which reports a KEYED, tool-using `pi -p` finishing and exiting on both boxes
# this table calls alive. Neither table is re-derived here, and neither is load-bearing: what this
# gate refuses on is a VERDICT SHAPE (a hang at the bound, confirmed across attempts), and the arms
# that pin it drive a stub `pi` — `cell-lane-preflight.test.sh` A2/A3/A11 — so the discrimination is
# proven against the shapes, not inferred from which box was broken on one afternoon. The per-box
# attribution above stays exactly as measured until somebody can reach the cells and re-measure it.
#
# ⛔ TWO DEFECTS WEAR THE SAME SYMPTOM, AND A LANE LOG CANNOT TELL THEM APART.
#   * REQUEST_STALL — nothing came back. The provider, the key or the endpoint.
#   * EXIT_HANG     — the answer came back and the PROCESS never returned. #2935's original root: a
#                     REF'd 60 s interval in `extensions/loop-enforcer/scheduler.ts`, fixed in #2944
#                     but measured STILL PRESENT on cell3 and cell4 (installed `unref=0`) — a keyless
#                     `pi -p` on those boxes answers at 2 s and is still alive at 150 s.
# A bound that reports only "hung" hides which of the two it saw, and the two have different owners
# (a provider/an account vs. the installed extension set). So the two readings are reported apart:
#
#   answered_ms  when the ANSWER TOKEN appeared — the request resolved by then
#   returned_ms  when the process exited
#
# ⛔ THE ANSWER TOKEN, NOT THE FIRST BYTE OF OUTPUT, AND NOT "say nothing".
#   The first cut of this measurement used `pi -p … "say nothing"` and polled for the first output
#   byte. Both halves are wrong and both were measured wrong before they were fixed: pi's extensions
#   write ~4 KB of banners inside 1-2 s (so "first byte" is a banner, not an answer), and an empty
#   answer is a LEGITIMATE answer to "say nothing" (so it cannot distinguish "answered nothing" from
#   "never answered"). The prompt therefore demands a fixed token and the probe waits for the token.
#
# ⛔ THE KEYS ARE EXTRACTED IN A SUBSHELL. `keys.env` is arbitrary code with the preflight's
#   privileges and MAY set `HOME` (`cloud-cell-bringup.sh` documents that at length) — sourcing it
#   into this process would move `$HOME/.pi/agent` out from under `pi` mid-measurement, i.e. the probe
#   would measure a different agent than the lane it is gating. Only the two variables the call needs
#   cross the boundary.
#
# READ THE RAIL, NOT THIS FILE, FOR "may I merge": this is a capability gate, not a CI verdict.
#
# USAGE
#   cell-lane-preflight.sh [--keys <file>] [--bound S] [--model M] [--provider P] [--attempts N]
#                          [--quiet]
#
#   --keys <file>   the env file the launcher sources. Default: $LANE_PREFLIGHT_KEYS, else the first
#                   readable of `${CELL_HOME}/keys.env` and `$HOME/keys.env` — the ORDER this code
#                   actually builds (an earlier USAGE claimed one path while the loop tried two).
#                   Unreadable, with no AMBIENT key either, is a REFUSAL (a lane started without a key
#                   burns its slot and reports `(no response)` at the end).
#                   The credential is `<PROVIDER>_API_KEY` — `DEEPSEEK_API_KEY`, `VENICE_API_KEY` … —
#                   the SAME variable the provider's own leg reads, so a lane is measured against the
#                   credential it will actually use (a hardcoded `DEEPSEEK_API_KEY` made a
#                   `--provider venice` lane refuseable on a box whose only key was the venice one).
#   --bound S       how long one attempt may take before it is killed and named. Default 45.
#   --attempts N    how many samples a non-final reading gets. Default 2. The count is printed. A
#                   HANG must repeat to refuse (a slow sample must not refuse a working box); a
#                   fast failure is retried and never refuses.
#   --model/--provider   mirror the launcher's pair. Default `${PI_LANE_MODEL:-deepseek-flash}` /
#                   `${PI_LANE_PROVIDER:-deepseek}` — the SAME contract as lane-exec.sh and
#                   spawn-gate.sh::run_agent, so the probe measures the model the lane will run.
#   --repo <path>   the checkout to measure for the staleness reading (#3932). Same value as
#                   `CELL_PREFLIGHT_REPO`, and it wins over it. NOT a way to switch the field off: a
#                   named path that is not a checkout is reported (`repo=none … reason=not-a-checkout`),
#                   never silently replaced by a guess.
#
# ENVIRONMENT (the staleness reading, #3932 — the THRESHOLD and the BOUND have no flag, because they
# are policy, not a reading: a caller must not be able to turn its own readiness field off. Naming the
# checkout is a different thing, and it has one):
#   CELL_PREFLIGHT_REPO        the checkout to measure. Resolution order, first that EXISTS:
#                              `--repo`, then `${CELL_PREFLIGHT_REPO}`, then `$PWD` (for a lane that is
#                              the worktree it will build on), then the paths this repo actually
#                              resolves cells with (`/tmp/cell-ai`, `/tmp/cell-t3`,
#                              `${CELL_HOME}/agent-infra`), then `$HOME/tortoise`, `$HOME/agent-infra`.
#                              Nothing found is `repo=none behind=unknown` — reported, never refused.
#   CELL_PREFLIGHT_MAX_BEHIND  refuse when the checkout is MORE than this many commits behind
#                              `origin/main`. Default 50.
#   CELL_PREFLIGHT_FETCH_BOUND the fetch gets this many seconds before it is killed and the reading
#                              becomes `behind=unknown`. Default 12.
#
# EXIT
#   0  CAPABLE   — answered AND returned within the bound
#   3  REFUSED   — a gate verdict; the line carries the reading it used
#   2  CANNOT MEASURE — keys unreadable, `pi` missing, bad usage. EVERY caller must refuse too.
#
# ⛔ THE `why=` WORD IS A CONTRACT WITH THE CALLER, NOT A LOG DETAIL. The caller decides refuse-vs-warn
# from it, so it is stated by POLARITY instead of being a list of favourites:
#   why=no-answer    ⇔ the process RETURNED without answering. A transient blip is the only thing that
#                      produces it (a deterministic defect hangs, errors, or cannot be measured at
#                      all), so it is the ONLY reason a caller may WARN on and proceed.
#   why=usage        ⇔ THIS FILE COULD NOT RUN AS ASKED — an unknown argument, a non-numeric `--bound`.
#                      Emitted by `die_usage` at exit 2 (the CANNOT MEASURE code). Without it the
#                      usage path printed NO verdict, so the caller WARNed and dispatched anyway;
#                      measured `LANE_PREFLIGHT_BOUND=45s` → `run_agent rc=0, agent launched` (review
#                      of #2991, P2). Its usual cause in production is consumer/helper VERSION SKEW
#                      (a caller passing a flag this copy predates), and the remedy says so.
#   every other refused reason ⇔ deterministic: `exit-hang` / `no-return` (still alive at the bound,
#                      with or without the answer), `call-failed` (answered, then errored),
#                      `keys-unreadable`, `pi-missing`, `misconfigured`, `stale-code` (the box answers,
#                      but its checkout is more than `CELL_PREFLIGHT_MAX_BEHIND` commits behind
#                      `origin/main` — #3932). A caller must REFUSE on these.
#   `no-return` is the one this file had to grow: a box whose provider is blackholed, whose proxy
#   drops, or whose extension set hangs BEFORE the first token never produces a token, so before it
#   existed that box could only ever emit `no-answer` — the WARN arm — and the gate was vacuous for
#   the permanent failure it was built for (measured: `why=no-answer alive_at=3s attempts=1`, caller
#   proceeded and launched an agent).
#
# The output is ONE line, always, in both directions (`ci_runner_pool.sh`'s rule: "a gate that refuses
# without the number it read is a wish with a semicolon").
set -u

PROG=cell-lane-preflight
KEYS=""
BOUND=45
MODEL="${PI_LANE_MODEL:-deepseek-flash}"
PROVIDER="${PI_LANE_PROVIDER:-deepseek}"
ATTEMPTS=2
QUIET=0
TOKEN="PF_OK_4f2c"
# Set BEFORE the parse loop: a usage refusal carries the host it happened on, and that is the one field
# an operator needs to act on it. `hostname` is a single cheap fork; `PI_VER` is deliberately left late,
# because it runs `pi` and a usage error must not depend on the binary it is about to blame.
HOST="$(hostname 2>/dev/null || echo '?')"

# emit <verdict> <rest of the line>  — one line, on stdout, in both directions.
# ⛔ DEFINED ABOVE `die_usage`, AND TOLERANT OF UNBOUND FIELDS, BECAUSE `die_usage` CALLS IT (review of
# #2991, P2, measured). The usage path fires during argument parsing — BEFORE `HOST`/`PI_VER` are set —
# so an `emit` that read them bare would abort under `set -u` and print nothing, which is the very
# defect this is fixing (an emit defined only BELOW the parse loop would also be an unbound FUNCTION
# at that point: `die_usage: emit: command not found`, and still no verdict).
emit() {
  local verdict="$1"; shift
  printf '[%s] LANE_CAPABILITY=%s host=%s model=%s/%s pi=%s %s\n' \
    "$PROG" "$verdict" "${HOST:-<unknown>}" "${PROVIDER:-}" "${MODEL:-}" "${PI_VER:-<unknown>}" "$*"
}

# ⛔ A USAGE ERROR IS A REFUSAL, NOT AN ABSENCE OF A VERDICT (follow-up to #2991, P2, measured).
# This used to exit 2 with a stderr line and NOTHING on stdout. Every caller decides refuse-vs-warn
# from the verdict line, so the line it prints here is the whole difference between a gate and an
# inert gate: `LANE_PREFLIGHT_BOUND=45s` measured `probe rc=2, stdout=<>` and then, through
# `run_agent`, `rc=0, agent launched` — a lane dispatched by a probe that never measured anything,
# against this file's own EXIT table ("2 CANNOT MEASURE — EVERY caller must refuse too"). The exit
# code stays 2 (it IS cannot-measure); what changes is that it can now be READ.
# ⛔ CODE STALENESS IS A READINESS FIELD (agent-infra#3932). This file existed to answer "can this box
# complete a model call" — and a checkout hundreds of commits behind passes that perfectly. Measured
# 2026-12-02 on all five cells: c1 496, c2 7093, c3 705, c5 542 commits behind origin/main, and
# `LANE_CAPABILITY=ok` was emitted on every one. A lane cut from that base produces a PLAUSIBLE LOG AND A
# WRONG DIFF: it re-derives something main already fixed, or reverts it. That is indistinguishable from a
# working lane until the work is read, and tortoise is the product this base feeds.
#
# The reading is `HEAD..origin/main` AFTER A BOUNDED FETCH, so the number is measured rather than
# remembered from a possibly-stale ref (the very "flag that records a past state" failure this file's
# sibling issues describe). A fetch that fails or times out yields `behind=unknown` and does NOT refuse —
# an unanswerable network read is a WARN, the same doctrine as `no-answer`.
#
# ⛔ THE FETCH'S OWN EXIT STATUS IS THE ONLY THING THAT MAKES THAT SENTENCE TRUE (this change's review).
# The first cut fetched in the background and then read `rev-list` UNCONDITIONALLY. But a failed fetch
# does not delete `origin/main` — it leaves the last one it saw — so `rev-list` answers, and the gate
# publishes a number it never measured: a checkout 500 commits behind, last fetched a month ago,
# reports `behind=8` and is declared READY. That is the same escaped-stale-ref false PASS the header
# above claims this reading avoided, one line under the claim. The rule is therefore structural: a ref
# that was NOT refreshed this run is not a measurement, and the status of the fetch (including the
# watchdog's kill, which surfaces as a non-zero wait status) decides it. `exec` keeps `$!` pointing at
# `git` itself rather than at a wrapper shell, so the bound's kill reaches the process it bounds.
MAX_BEHIND="${CELL_PREFLIGHT_MAX_BEHIND:-50}"
FETCH_BOUND="${CELL_PREFLIGHT_FETCH_BOUND:-12}"
REPO_ARG=""

# ⛔ WHICH CHECKOUT IS MEASURED IS THE CALLER'S TO NAME, NOT A GUESS (this change's review, P1-1).
# The first cut guessed `${HOME}/tortoise` and `${HOME}/agent-infra`, and on the boxes the reading was
# measured on NEITHER EXISTS: a cell runs `HOME=/tmp/cell-home` while the tortoise checkout with all its
# worktrees is `/tmp/cell-t3` (docs/ops/disk-consumers.md), and the dispatch Mac keeps both checkouts
# under `Documents/GitHub/`. Every reading was then `repo=none behind=unknown` → `ok`, so the refusal
# was UNREACHABLE exactly where it was meant to fire — and the suite stayed green because every arm
# passed `CELL_PREFLIGHT_REPO` explicitly. A readiness field that resolves nothing by default is the
# no-op-gate class this repo treats as category A.
# So the order is: what the CALLER named is AUTHORITATIVE (and a named path that is not a checkout does
# NOT fall through to a guess — looking somewhere other than where you were told is the same defect one
# step later); then the checkout the probe is RUNNING IN, `$PWD`, which for `run_agent` is the lane's own
# worktree — the base it will build on; then the paths this repo actually resolves cells with; then the
# plain `$HOME` layout.
# ⛔ A `--repo` FLAG DOES NOT LET A CALLER TURN THE FIELD OFF, which is the one thing the first cut's
# no-flag rule was protecting: naming a checkout can only make the reading MORE specific, a named
# non-checkout is reported as such, and `CELL_PREFLIGHT_REPO` already had exactly this power.
# ⛔ `${HOME:-}` THROUGHOUT: the first cut read `$HOME/...` bare under `set -u`, so a caller with no HOME
# aborted inside `$( )` and the verdict line lost its `repo=`/`behind=` fields ENTIRELY — the readiness
# field vanished instead of saying `unknown` (this change's review, P2-3).
# ⛔ IT SETS `REPO_FOUND` RATHER THAN PRINTING THE PATH: the note that says WHY nothing was measured has
# to survive the call, and a `$( )` would drop it (measured — the arm read the generic
# `reason=no-checkout` over the specific `reason=not-a-checkout path=…` it had just produced).
resolve_repo() { # -> 0 and REPO_FOUND set; 1 with REPO_NOTE naming why nothing was measured
  local cand
  REPO_FOUND=""
  for cand in "${REPO_ARG:-}" "${CELL_PREFLIGHT_REPO:-}"; do
    [ -n "$cand" ] || continue
    [ -e "$cand/.git" ] && { REPO_FOUND="$cand"; return 0; }
    REPO_NOTE="reason=not-a-checkout path=$cand"
    return 1
  done
  for cand in "$PWD" /tmp/cell-ai /tmp/cell-t3 \
              "${CELL_HOME:-}${CELL_HOME:+/agent-infra}" \
              "${HOME:-}${HOME:+/tortoise}" "${HOME:-}${HOME:+/agent-infra}"; do
    [ -n "$cand" ] || continue
    [ -e "$cand/.git" ] && { REPO_FOUND="$cand"; return 0; }
  done
  REPO_NOTE="reason=no-checkout tried=pwd,/tmp/cell-ai,/tmp/cell-t3,CELL_HOME/agent-infra,HOME/tortoise,HOME/agent-infra"
  return 1
}

code_freshness() {
  local repo="" behind="" fp n fetch_rc
  REPO_NOTE=""
  resolve_repo || REPO_FOUND=""
  repo="$REPO_FOUND"
  [ -n "$repo" ] || { printf 'repo=none behind=unknown %s' "${REPO_NOTE:-reason=no-checkout}"; return 0; }
  # Bounded fetch. `timeout` is absent on macOS and this suite runs on both, so the bound is a
  # background pid + a counted sleep, matching the watchdog form the repo already uses (#2046).
  # ⛔ THE DESTINATION IS EXPLICIT, AND THAT IS NOT REDUNDANT (this change's review: measured). A
  # command-line refspec with no `:<dst>` only refreshes `refs/remotes/origin/main` by git's
  # OPPORTUNISTIC UPDATE, which needs a configured `remote.origin.fetch` that maps `main`. Measured on a
  # checkout whose fetch refspec had been emptied: `git fetch origin main` exited **0**, left
  # `origin/main` untouched, and the count printed `behind=0` on a checkout that was 3 commits behind —
  # the exact false PASS this reading exists to remove, one line under the rule that a ref not refreshed
  # this run is not a measurement. Naming the destination makes the refresh structural instead of
  # dependent on a config the probe does not own.
  ( cd "$repo" 2>/dev/null && exec git fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main' >/dev/null 2>&1 ) &
  fp=$! n=0
  while [ "$n" -lt "$FETCH_BOUND" ] && kill -0 "$fp" 2>/dev/null; do sleep 1; n=$((n+1)); done
  kill -0 "$fp" 2>/dev/null && kill "$fp" 2>/dev/null
  # The watchdog's kill, a dead network and a missing remote ALL land here as non-zero, and all three
  # mean the same thing: whatever `origin/main` now holds was not read from the remote this run.
  wait "$fp" 2>/dev/null; fetch_rc=$?
  if [ "${fetch_rc:-1}" -ne 0 ]; then
    printf 'repo=%s behind=unknown reason=fetch-failed fetch_rc=%s' "$(basename "$repo")" "$fetch_rc"
    return 0
  fi
  behind="$( cd "$repo" 2>/dev/null && git rev-list --count HEAD..origin/main 2>/dev/null )"
  case "${behind:-}" in
    ''|*[!0-9]*) printf 'repo=%s behind=unknown reason=rev-list-unreadable' "$(basename "$repo")" ;;
    *)           printf 'repo=%s behind=%s' "$(basename "$repo")" "$behind" ;;
  esac
}

die_usage() { printf '%s: %s\n' "$PROG" "$*" >&2; emit "refused why=usage" "usage-error=$*"; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --keys) [ $# -ge 2 ] || die_usage "--keys needs a path"; KEYS="$2"; shift 2 ;;
    --bound) [ $# -ge 2 ] || die_usage "--bound needs seconds"; BOUND="$2"; shift 2 ;;
    --model) [ $# -ge 2 ] || die_usage "--model needs a value"; MODEL="$2"; shift 2 ;;
    --provider) [ $# -ge 2 ] || die_usage "--provider needs a value"; PROVIDER="$2"; shift 2 ;;
    --attempts) [ $# -ge 2 ] || die_usage "--attempts needs a number"; ATTEMPTS="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || die_usage "--repo needs a path"; REPO_ARG="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    # ⛔ UP TO `set -u`, NOT A LINE RANGE: the header grows and a range silently truncates the help
    # (this PR's own USAGE advertised a `--line` flag the parser had no case for, so `--line` exited 2
    # as an unknown argument — a doc that cannot drift is one derived from the file).
    -h|--help) awk 'NR>1 && /^set -u/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
case "$BOUND" in ''|*[!0-9]*) die_usage "--bound must be a positive integer (read '$BOUND')" ;; esac
case "$ATTEMPTS" in ''|*[!0-9]*) die_usage "--attempts must be a positive integer (read '$ATTEMPTS')" ;; esac
[ "$BOUND" -gt 0 ] || die_usage "--bound must be > 0 (read '$BOUND')"
[ "$ATTEMPTS" -gt 0 ] || die_usage "--attempts must be > 0 (read '$ATTEMPTS')"
# ⛔ AN UNVALIDATED REFUSAL BOUND IS AN INERT ENFORCER (this change's review). `[ "$behind" -gt "$MAX" ]`
# with a non-numeric MAX makes bash print `integer expression expected` and return 2 — i.e. FALSE — so
# the staleness refusal silently never fires and the gate reads `ok` for ever, which is exactly the
# failure #3932 exists to catch. Same doctrine as `--bound`/`--attempts`, and the same readable verdict.
case "$MAX_BEHIND" in ''|*[!0-9]*) die_usage "CELL_PREFLIGHT_MAX_BEHIND must be a non-negative integer (read '$MAX_BEHIND')" ;; esac
case "$FETCH_BOUND" in ''|*[!0-9]*) die_usage "CELL_PREFLIGHT_FETCH_BOUND must be a non-negative integer (read '$FETCH_BOUND')" ;; esac

HOST="${HOST:-$(hostname 2>/dev/null || echo '?')}"
PI_VER="$(pi --version 2>/dev/null | tail -1)"

# refuse <why> <reading> <exit-code> — a refusal ALWAYS carries the reading it used, and every one of
# them is a verdict an operator can grep, never a bare "hung".

# ── a lane with an EMPTY model/provider pair is a MISCONFIGURATION, and reporting it as an absence of
# evidence is a fail-open. Measured before this check existed: `pi -p --provider  --model  …` with both
# values empty, which lands in a pre-answer failure — so the probe spent its attempts and published the
# reading of a network blip for a lane that could never have run. It is deterministic, so it carries
# its own reason and every caller refuses on it.
[ -n "${MODEL:-}" ] || { emit "refused why=misconfigured" "model=<empty> provider=${PROVIDER:-<empty>}"; exit 2; }
[ -n "${PROVIDER:-}" ] || { emit "refused why=misconfigured" "provider=<empty> model=$MODEL"; exit 2; }

# Portable epoch milliseconds. GNU `date +%s%N` yields nanoseconds; BSD `date` does not implement `%N`
# and appends a literal `N`, so a naive divide produces a number that is neither seconds nor millis —
# on the MAC, which is the box that dispatches to the boxes being probed. Both arms are handled.
now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  case "$ns" in
    ''|*N) echo $(( ${ns%N} * 1000 )) ;;
    *)    echo $(( ns / 1000000 )) ;;
  esac
}

# ── the tool must exist before we can measure anything with it ───────────────────────────────────
if ! command -v pi >/dev/null 2>&1; then
  emit "refused why=pi-missing" "PATH=${PATH//:/ }"
  exit 2
fi

# ── the keys, extracted WITHOUT letting them touch this process's environment ─────────────────────
# ⛔ AN AMBIENT KEY IS A LEGITIMATE SOURCE, and the Mac is the box that proves it: the controller
# environment carries DEEPSEEK_API_KEY and has no `keys.env` at all, so a gate that required the file
# would refuse every lane on the one host that dispatches to the cells. The file is the CELL's shape,
# not the only shape.
# ⛔ THE CREDENTIAL IS THE PROVIDER'S OWN, NOT `DEEPSEEK_API_KEY` BY REFLEX. A lane may run
# `--provider venice` (docs/providers.md §8, `COLD_CLASS_PROVIDER`), whose key is `VENICE_API_KEY`.
# Measured against the deepseek variable, such a lane either refuses a box that holds the right key
# (`keys-unreadable`) or reports a deepseek verdict about a venice lane. `<PROVIDER>_API_KEY`, with
# anything outside [A-Z0-9] folded to `_`, is the same variable pi's own provider legs read.
KEY_VAR="$(printf '%s' "${PROVIDER:-}" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9\n' '_')_API_KEY"
KEY_AMBIENT=""
eval 'KEY_AMBIENT="${'"$KEY_VAR"':-}"'
KEY_SOURCE=env
if [ -z "$KEY_AMBIENT" ]; then
  KEYS="${KEYS:-${LANE_PREFLIGHT_KEYS:-}}"
  if [ -z "$KEYS" ]; then
    for cand in "${CELL_HOME:-}/keys.env" "${HOME:-}/keys.env"; do
      [ -n "${cand%/keys.env}" ] || continue
      [ -r "$cand" ] || continue
      KEYS="$cand"; break
    done
  fi
  if [ -z "$KEYS" ] || [ ! -r "$KEYS" ]; then
    emit "refused why=keys-unreadable" "path=${KEYS:-<none>} $KEY_VAR=unset"
    exit 2
  fi
  KEY_SOURCE="$KEYS"
  # The subshell is the boundary: it may set HOME, PATH or anything else, and none of it survives.
  PF_KEY="$( set -a; . "$KEYS" >/dev/null 2>&1; eval 'printf "%s" "${'"$KEY_VAR"':-}"' )"
  if [ -z "$PF_KEY" ]; then
    emit "refused why=keys-unreadable" "path=$KEYS reason=$KEY_VAR-empty"
    exit 2
  fi
  export "$KEY_VAR=$PF_KEY"
fi

# ── one bounded attempt ──────────────────────────────────────────────────────────────────────────
# The bound is OUR OWN killer: macOS ships no `timeout`, and this box may be the Mac, so a probe that
# needs coreutils cannot run on the box that dispatches to the boxes that need probing.
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/cell-lane-preflight.XXXXXX" 2>/dev/null)" || die_usage "cannot mktemp"
trap 'rm -rf "$TMPD"' EXIT

# attempt <n> -> sets A_RC A_WALL_MS A_FIRST_MS A_KILLED A_TAIL A_BYTES
attempt() {
  local n="$1" out="$TMPD/out.$1" start now i=0 first="" pid m_was=0
  : >"$out"
  start=$(now_ms)
  # ⛔ THE PROBE IS KILLED AS A PROCESS GROUP, NOT AS A PID (#2163's class, measured on THIS file).
  # `pi` spawns tool/extension children and `kill -9 "$pid"` reaps only the leader: a stub whose `pi`
  # spawned a child left it running after a refused probe, and `run_agent` re-invokes this probe every
  # controller cycle — so the box that is already sick is the one that accumulates the leak. With job
  # control ON the child is its own group leader, so `-${pid}` names the whole tree. The `set -m` is
  # turned back off at once, so no caller's job-control state is changed by a probe.
  case $- in *m*) m_was=1 ;; esac
  set -m 2>/dev/null || true
  # shellcheck disable=SC2086
  pi -p --no-session --provider "$PROVIDER" --model "$MODEL" \
     "Reply with exactly this token and nothing else: $TOKEN" \
     >"$out" 2>&1 </dev/null &
  pid=$!
  [ "$m_was" = "1" ] || set +m 2>/dev/null || true
  while [ "$i" -lt "$BOUND" ]; do
    # The ANSWER TOKEN is the signal, not the first byte: banners arrive in the first 1-2 s.
    if [ -z "$first" ] && grep -qF "$TOKEN" "$out" 2>/dev/null; then
      now=$(now_ms)
      first=$(( now - start )); [ "$first" -lt 0 ] && first=0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1; i=$(( i + 1 ))
  done
  A_KILLED=0
  if kill -0 "$pid" 2>/dev/null; then
    A_KILLED=1
    # The GROUP first; the bare pid only as a fallback if the group is not named (job control failed).
    kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null; A_RC=$?
  # The leader can be reaped while a child still holds the group, so one more pass reaches the children
  # that outlived it — the exact shape the leak was measured in.
  [ "$A_KILLED" -eq 1 ] && { kill -9 -- "-$pid" 2>/dev/null || true; }
  now=$(now_ms)
  A_WALL_MS=$(( now - start )); [ "$A_WALL_MS" -lt 0 ] && A_WALL_MS=0
  A_FIRST_MS="${first:-0}"
  A_BYTES=$(wc -c <"$out" 2>/dev/null | tr -d ' ')
  A_TAIL=$(tail -3 "$out" 2>/dev/null | tr '\n' '~' | cut -c1-240)
}

# ── the verdict ──────────────────────────────────────────────────────────────────────────────────
# ⛔ A HANG IS CONFIRMED BEFORE IT REFUSES; A FAST FAILURE NEVER DOES.
#   * a HANG — the process was still alive at the bound, whether or not the answer arrived — is a
#     property of the BOX, so it must REPEAT to refuse. A healthy-but-slow sample (answer at 29 s, exit
#     at 30.4 s against a 30 s bound) must not refuse a working box on ONE reading; a genuinely hanging
#     box hangs again. Cost when it fires: 2 x bound, two orders below the 3300 s lane cap it protects.
#   * `no-answer` — the process RETURNED and did not answer — is the transient arm. It is sampled
#     `--attempts` times and then WARNS; it never refuses, and it is the ONLY reason that does not.
# The refusal is taken from the LAST attempt only: a fast failure after a hang is not a confirmation.
attempts_used=0
last=""
n=1
while [ "$n" -le "$ATTEMPTS" ]; do
  attempt "$n"
  attempts_used=$n
  if grep -qF "$TOKEN" "$TMPD/out.$n" 2>/dev/null; then
    if [ "$A_RC" -eq 0 ] && [ "$A_KILLED" -eq 0 ]; then
      # ⛔ THE BOX CAN ANSWER; IS ITS CODE CURRENT? A stale base is the failure this gate was blind to
      # (#3932): the model call succeeds and the lane then builds on a month-old checkout.
      FRESHNESS="$(code_freshness)"
      FRESH_BEHIND="${FRESHNESS##*behind=}"
      case "$FRESH_BEHIND" in
        ''|*[!0-9]*) : ;;   # unmeasurable: reported below, never a refusal
        *)
          if [ "$FRESH_BEHIND" -gt "$MAX_BEHIND" ]; then
            # ⛔ EXIT 3, LIKE EVERY OTHER REFUSAL (this change's review). The first cut exited 1, and on
            # this file's own documented table `1` is not a verdict at all — the caller's "no verdict"
            # arm exists for exactly `rc=1` ("absent or could not start") and WARNS on it. It happened to
            # refuse here only because the verdict LINE was also present; a consumer that switches on the
            # code alone (this repo's own EXIT table is what such a consumer reads) would have treated a
            # stale box as "no probe ran" and dispatched anyway.
            emit "refused why=stale-code" "answered_ms=$A_FIRST_MS attempts=$n bound=${BOUND}s $FRESHNESS max_behind=$MAX_BEHIND"
            [ "$QUIET" = "1" ] || printf '%s\n' \
              "[$PROG] the box can complete a model call, but its checkout is more than ${MAX_BEHIND} commits behind origin/main. A lane cut from that base produces a plausible log and a WRONG diff — it re-derives what main already fixed, or reverts it (#3932). Advance the checkout (git -C <repo> pull --ff-only origin main, or the cell's deploy path) before dispatching; the reading above names the repo and the distance. Override with CELL_PREFLIGHT_MAX_BEHIND=<n> only if a stale base is genuinely intended." >&2
            exit 3
          fi
          ;;
      esac
      emit "ok" "answered_ms=$A_FIRST_MS returned_ms=$A_WALL_MS attempts=$n bound=${BOUND}s key=$KEY_SOURCE $FRESHNESS"
      exit 0
    fi
    # answered, then failed or hung
    if [ "$A_KILLED" -eq 1 ]; then last=exit-hang; else last=call-failed; fi
    # `call-failed` is deterministic from one reading (the request resolved and the call errored); a
    # second sample would spend the bound again for the same verdict.
    [ "$last" = "call-failed" ] && break
  else
    # nothing answered: a hang at the bound is the deterministic shape, an exit is the transient one
    if [ "$A_KILLED" -eq 1 ]; then last=no-return; else last=no-answer; fi
  fi
  n=$(( n + 1 ))
done

# Name the reading rather than the guess — and, for a hang, the TWO owners it does not separate.
case "$last" in
  exit-hang)
    emit "refused why=exit-hang" \
      "answered_ms=$A_FIRST_MS alive_at=${BOUND}s attempts=$attempts_used bound=${BOUND}s rc=$A_RC bytes=$A_BYTES"
    [ "$QUIET" = "1" ] || printf '%s\n' \
      "[$PROG] the request RESOLVED (answered at ${A_FIRST_MS}ms) and the process did not RETURN within ${BOUND}s, on ${attempts_used} of ${ATTEMPTS} attempt(s): this box burns a lane's whole wall-clock cap per spawn. It is the #2935 exit-hang class, not a provider problem — check the installed extension set (\`grep -c 'scheduler.unref' \$HOME/.pi/agent/extensions/loop-enforcer/scheduler.ts\`; an installed copy predating #2944 reports 0)." >&2
    exit 3 ;;
  no-return)
    emit "refused why=no-return" \
      "never_answered alive_at=${BOUND}s attempts=$attempts_used bound=${BOUND}s bytes=$A_BYTES tail=$A_TAIL"
    [ "$QUIET" = "1" ] || printf '%s\n' \
      "[$PROG] NOTHING answered AND the process did not RETURN within ${BOUND}s, on ${attempts_used} of ${ATTEMPTS} attempt(s). This reading has TWO owners and does not separate them: a request that never resolved (blackholed endpoint, a proxy that drops, a key the provider rejects without a reply) or an installed extension set that hangs BEFORE the first token. A box that FAILS FAST reports why=no-answer instead — that is the transient arm — so compare one; and check the extension set (\`grep -c 'scheduler.unref' \$HOME/.pi/agent/extensions/loop-enforcer/scheduler.ts\`)." >&2
    exit 3 ;;
  call-failed)
    emit "refused why=call-failed" \
      "answered_ms=$A_FIRST_MS returned_ms=$A_WALL_MS rc=$A_RC attempts=$attempts_used bound=${BOUND}s tail=$A_TAIL"
    exit 3 ;;
  *)
    emit "refused why=no-answer" \
      "returned_ms=$A_WALL_MS rc=${A_RC:-?} attempts=$attempts_used bound=${BOUND}s bytes=$A_BYTES tail=$A_TAIL"
    exit 3 ;;
esac
