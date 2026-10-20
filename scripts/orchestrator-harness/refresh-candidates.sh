#!/bin/bash
# refresh-candidates.sh — pre-flight a pool of open P0/P1/P2 issues and append the CLEAN ones
# to ~/orchestrator/candidates.txt (the dispatch backlog). Skips anything already checked.
#
#   refresh-candidates.sh [LIMIT]     # refill the backlog (called by orch-loop.sh, BACKGROUNDED)
#   refresh-candidates.sh --check     # read-only: CAN this repo be provisioned for dispatch?
#
# ⛔ WHY `--check` EXISTS (agent-infra#1736). The scout provisioning below used to be a
# TORTOISE-shaped spec: `uv sync --extra embeddings --extra parity` (tortoise extras, and a
# `pyproject.toml` the target repo may not have) plus tortoise's `tools/collision_preflight.py`
# (which agent-infra does not carry). A cell pointed at a repo that is neither aborted every
# cycle, and orch-loop.sh runs this script in a BACKGROUNDED subshell — so the non-zero exit could
# not fail the loop and the controller reported RUNNING with `lanes: 0` forever: a cell that looks
# alive and can only merge. `--check` answers the provisioning question up front, WITH THE REASON,
# so a cell is never STARTED in that state (cloud-cell-supervisor.sh `check` calls it).
set -u
OR_FROM_ENV="${OR:-}"
OR="${OR_FROM_ENV:-daniel-ospina/tortoise}"
# ⛔ THE LANDED PRUNE MUST NOT ACT ON A REPO NOBODY NAMED (review P1, cycle 4). The listings below only
# ever READ `$OR`, and a wrong `$OR` there cost a wrong listing. The landed prune is a WRITE: it DROPS
# entries from `landed.txt` on a CLOSED answer, which RELEASES a landed suppression and makes shipped
# work dispatchable again — from a `gh issue view --repo <the literal>` answer about a DIFFERENT repo.
# `repo-slug.sh` and #2040 exist because that literal was already the measured wrong-repo defect, so
# the prune takes an EXPLICIT-or-DERIVED slug and nothing else: when neither exists it is called with an
# EMPTY repo, which its own per-entry fail-closed arm reads as "cannot read this entry" and KEEPS it.
# The listings keep their shipped default (unchanged by this PR).
PRUNE_OR="$OR_FROM_ENV"
if [ -z "$PRUNE_OR" ]; then
  _rs="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  # ⛔ A RESOLVER THAT DEFINES NOTHING IS NOT A RESOLVER (review P2, cycle 5). `orch-loop.sh` checks
  # `command -v derive_or` after sourcing the same file and refuses (exit 78) when it is absent; this
  # arm did not, so a stale or function-less `$O/repo-slug.sh` left PRUNE_OR empty — and the prune then
  # reports every entry as "could not be re-read", naming a failed READ that was never attempted while
  # a landed suppression stays in force forever. The candidates are tried in order until one actually
  # yields a slug, so a stale $O copy no longer shadows the good one beside the script.
  for _cand in "${O:-}/repo-slug.sh" "$_rs/repo-slug.sh"; do
    [ -n "$_cand" ] && [ -f "$_cand" ] || continue
    # shellcheck disable=SC1090
    . "$_cand" 2>/dev/null || continue
    command -v derive_or >/dev/null 2>&1 || { unset -f derive_or 2>/dev/null; continue; }
    PRUNE_OR="$(derive_or "${REPO:-}" "" 2>/dev/null || true)"
    [ -n "$PRUNE_OR" ] && break
  done
fi
# ── THE PRODUCT WORK FLOOR'S INTAKE SIDE (agent-infra#2054) ──────────────────────────────────
# `orch-loop.sh` fills up to PRODUCT_FLOOR of each batch from `candidates.product.txt` first. This
# script is what decides WHICH candidates are product, and it decides by REPO plus LABEL — not by title
# text, which is the mistake the 1,229-issue title-regex pass already paid for (232 unlabelled).
#   product  =  the target repo is in PRODUCT_REPOS  AND  the issue does not carry the `harness` label
#   harness  =  everything else, including every agent-infra issue
# ⛔ AND THE TWO QUEUES ARE DERIVED FROM `candidates.txt`, NEVER ACCUMULATED INTO. The merged backlog is
# the authority; a product queue that could drift (a queued-then-failed write, a dispatched issue, an
# issue re-classified) would make the floor's share a claim about a past pass. Deriving the split at the
# END of the pass makes it a function of the files as they are NOW.
PRODUCT_REPOS="${PRODUCT_REPOS:-daniel-ospina/tortoise}"
REPO="${REPO:-/Users/danielospina/Documents/GitHub/tortoise}"
SC="$REPO/.worktrees/dispatch-scout"

# ── A USABLE $HOME IS A PRECONDITION OF THE PRE-FLIGHT, NOT A PER-CANDIDATE RESULT ─────────────
# WHY THIS LIVES HERE AND NOT ONLY IN cloud-cell-bringup.sh. Bring-up already names this as friction
# #1 (`cmux vm exec` runs as user `cmux` with HOME=/home/ubuntu, which is NOT created on the image,
# so anything that writes $HOME dies) and repairs it — inside its OWN process. A repair in bring-up's
# process cannot cross a process boundary, and the controller is not always started by bring-up: the
# REFRESH is what actually runs the pre-flight, and nothing made its environment usable.
#
# MEASURED 2026-10-16 on the live cmux cells — the SAME tool, the same cwd, the same issue, with
# ONLY $HOME differing (issue #1328, daniel-ospina/agent-infra):
#   HOME=/home/ubuntu   -> VERDICT: COLLISION (exit 1) — "a peer owns it, retry next pass"
#                          ... ALSO INCOMPLETE: 3 surface(s) could not be queried
#   HOME=/tmp/cell-home -> VERDICT: LANDED (exit 4) — the authoritative answer
# gh keeps its credentials in $HOME/.config/gh, so under the image's HOME every gh surface of the
# pre-flight fails (`gh auth status` there answers "not logged in"). The danger is not that the tool
# refuses: a COLLISION is a perfectly ordinary answer to the caller, so a broken environment does not
# read as breakage — it reads as a busy queue. Measured the same day: the cell whose keys.env
# carries NO `HOME=` logged 309 collisions and ZERO clean verdicts, its `candidates.txt` stayed
# empty and orch-loop reported RUNNING with `lanes: 0`; the ONLY cell queueing candidates was the
# one whose keys.env carries an operator's HAND-WRITTEN `HOME=`/`UV_CACHE_DIR=`. That is the
# fix-that-never-ran shape.
#
# WRITABLE is the definition of usable HERE, and it is the harness's own precondition, not a choice
# made in this function: cloud-cell-supervisor.sh and cloud-cell-bringup.sh both die on a non-writable
# home, and `$O` defaults to `$HOME/orchestrator`, which this script writes. The repair is a NO-OP
# wherever $HOME is already a writable directory (every laptop, and every cell whose controller the
# supervisor started); a home that is absent, not a directory, or not writable is off-spec for this
# harness and is replaced.
CELL_HOME="${CELL_HOME:-/tmp/cell-home}"
usable_home() { [ -n "${1:-}" ] && [ -d "$1" ] && [ -w "$1" ]; }
# $1 = --create. Runs at LOAD, before anything else: the interpreter probe, uv's cache and the
# pre-flight all resolve through $HOME. TWO candidates — the caller's $HOME, then $CELL_HOME (the
# home bring-up provisions and the credentials live in) — and only an ABSOLUTE, existing, writable
# directory is eligible. Only $CELL_HOME is ever created, and the repo, the scout worktree and the
# venv are never touched (which is what `--check`'s read-only promise is about);
# cloud-cell-bringup.sh's --check path creates the same home. $O's parent is deliberately NOT a
# candidate: it is the same directory on a real cell, and on a hand-run with $O pointed elsewhere it
# would silently adopt a home that holds no credentials.
resolve_home() {
  local create="${1:-}" cand old="${HOME:-<unset>}"
  for cand in "${HOME:-}" "$CELL_HOME"; do
    [ -n "$cand" ] || continue
    case "$cand" in /*) ;; *) continue ;; esac
    if [ "$cand" = "$CELL_HOME" ] && [ "$create" = --create ] && ! usable_home "$cand"; then
      mkdir -p "$cand" 2>/dev/null || true
    fi
    usable_home "$cand" || continue
    [ "$cand" = "$old" ] && return 0
    HOME="$cand"; export HOME
    # uv's cache default is $HOME/.cache/uv, which is why an unusable HOME makes `uv sync` die on
    # its cache before it can fail on anything real. Point it at the same writable home; an
    # explicit operator value is kept.
    : "${UV_CACHE_DIR:=$cand/.cache/uv}"; export UV_CACHE_DIR
    echo "[refresh] HOME=$old is not a writable directory — using HOME=$HOME UV_CACHE_DIR=$UV_CACHE_DIR (cloud-cell-bringup.sh friction #1)"
    return 0
  done
  return 1
}
resolve_home --create \
  || echo "[refresh] WARN: neither \$HOME ('${HOME:-<unset>}') nor CELL_HOME ('$CELL_HOME') is a writable directory — the pre-flight's gh surfaces will be unreadable and its verdicts degraded"

O="${O:-$HOME/orchestrator}"

# ⛔ ONE BOARD REBUILD PER PASS, NOT ONE PER CANDIDATE (#2022). A pass runs the pre-flight once per
# candidate, and the fleet-board rebuild inside it measured 15.9 s of a 19 s run — identical every
# time. Six rebuilds per pass contend with the controller's own sweep; a contended GitHub read returns
# as an UNQUERYABLE SURFACE, which is not a verdict, so every candidate is "left unchecked", the
# backlog stays 0 and CREATE ACTIVITY STOPS with no error anywhere.
#
# ⛔ AND IT WAS NEVER ACTUALLY ON (agent-infra#2022 follow-up, 2026-10-18). The tool (tortoise#8948)
# caches its own PARTIAL board and never writes fleet_state.DEFAULT_OUT — but it gates that cache on
# `COLLISION_PREFLIGHT_BOARD_CACHE`, and this script exported `COLLISION_PREFLIGHT_CACHE` (no
# `_BOARD_`) with the directory path in it. The tool DOES NOT READ EITHER OF THOSE: the enable flag
# was therefore never set, the cache never engaged, and every candidate paid the whole board rebuild.
# MEASURED that day with a counting shim over one real pass: the board rebuild (`issue list
# --limit 2000` + `pr list --limit 400`) cost 130 of the pass's ~270 core calls — 6 rebuilds of the
# same board, 47% of everything the pass spent.
# ⛔ THE OLD NAME IS NOT A SEAM AT ALL, AND IT IS ALSO THE NAME THE TOOL's OWN TESTS USE AS AN
# ATTACK. It was a pure NO-OP here — nothing read it — and that is exactly why the burn survived:
# the export LOOKED like the cache was on. It must not be reintroduced as if it were a setting.
# Separately, tortoise's `tests/test_collision_preflight.py` plants a forged board in
# `COLLISION_PREFLIGHT_CACHE` to prove the gate REFUSES a caller-named cache directory (a
# caller-selectable directory is a caller-selectable BOARD: `_board_can_answer` /
# `_board_is_for_repo` / `state_freshness` are read out of that file, so a crafted "nobody holds it"
# would clear a live holder). So the name belongs to that refusal test — never to the harness's env.
# (Corrected 2026-10-18: an earlier revision of this comment claimed exporting it named an untrusted
# path on every daemon process. Nothing read it, so the export was inert; the defect was the SILENT
# NO-OP, not an open door.)
# The cache is ENABLED here with the tool's own seam, ON by default (the burn it removes is not an
# option), and the directory stays DERIVED inside the tool exactly as its contract requires. TTL 300 s:
# one pass, not two. The tool additionally refuses a cached board that its own fleet clock calls stale
# (`fleet_state.STATE_FRESH_S`, 900 s), that cannot answer, or that was built for another repo — so a
# hit can never turn an unmeasured board into a CLEAN, and the dispatch-time CLAIM gate remains the
# authoritative lock either way.
# Measured: 16.8 s -> 3.6 s -> 3.4 s per candidate, identical verdicts. `0` => behave as before.
export COLLISION_PREFLIGHT_BOARD_CACHE="${COLLISION_PREFLIGHT_BOARD_CACHE:-1}"
export COLLISION_PREFLIGHT_BOARD_CACHE_TTL="${COLLISION_PREFLIGHT_BOARD_CACHE_TTL:-300}"

# ── READ THE FLEET'S SLOW-CHANGING ANSWERS ONCE PER PASS, NOT ONCE PER CANDIDATE (#1984) ───────
# The board cache above removes the six REBUILDS of one fleet board. It does not remove the rest of
# the per-candidate repetition: the pre-flight also asks for the IDENTITY (`gh api user`), the OPEN
# PR list, and the RECENTLY-CLOSED-PR sample on EVERY candidate, and none of the three can change
# in the seconds between two candidates in one pass.
# MEASURED (counting shim, shipped script, agent-infra, 24 candidates, board cache ON): 72 of the
# pass's 134 core requests are those three answers, re-asked 24 times each — 54% of the pass. The
# fixed part (the two listings and the three priority tiers) is 14; the genuinely per-candidate part
# is 2 (issue state + the `issue landed` timeline).
#
# The mechanism is `gh-limit.py`'s pass memo (`GH_LIMIT_PASS_CACHE`): the whole invocation is
# memoised — argv in, exact (stdout, stderr, rc) out — so there is no gh semantics to re-create and
# nothing that can drift from what the real gh said. It is a LAYER, not a call-site change, for the
# reason `gh-limit/gh` gives about itself: a layer each call site has to remember is a layer that
# gets forgotten, and the pre-flight is a TORTOISE product this repo does not own — every future
# fleet-wide read it grows is covered by this one export.
#
# ⛔ THE DIRECTORY IS WIPED AND RE-CREATED AT THE START OF EVERY PASS, and that is what bounds the
# staleness: an entry written by an earlier pass is UNREACHABLE by a later one, by construction
# rather than by a TTL that could be missed. It is also REMOVED on the way out (both exits are
# trapped), because the entries hold issue and PR bodies and this state dir lives on a disk whose
# budget the box reaps. A pass that dies hard leaves its directory to the next pass's wipe.
GH_PASS_CACHE_DIR="${GH_PASS_CACHE_DIR:-$O/state/.gh-pass-cache}"
gh_pass_cache_start() {
  rm -rf "$GH_PASS_CACHE_DIR" 2>/dev/null || true
  if mkdir -p "$GH_PASS_CACHE_DIR" 2>/dev/null; then
    chmod 700 "$GH_PASS_CACHE_DIR" 2>/dev/null || true
    GH_LIMIT_PASS_CACHE="$GH_PASS_CACHE_DIR"; export GH_LIMIT_PASS_CACHE
  else
    # NOT fatal, and it says so: a cache that cannot be created must not stop a pass that can still
    # read GitHub. What is lost is the saving, and the next pass tries again. `unset` rather than an
    # empty string so the layer's own `bool(cfg(...))` reads it as OFF.
    unset GH_LIMIT_PASS_CACHE
    echo "[refresh] WARN: cannot create the per-pass read cache at $GH_PASS_CACHE_DIR — every fleet-wide read in this pass will be re-fetched per candidate (#1984); the pass itself is unaffected"
  fi
}
gh_pass_cache_stop() { rm -rf "$GH_PASS_CACHE_DIR" 2>/dev/null || true; }
# ⛔ APPEND, never PREPEND. These two directories are where launchd's minimal environment finds the
# harness's tools, so they must stay on PATH — but hard-prepending them silently OUTRANKED the
# caller's own PATH: a caller that put a pinned/stub `uv` first (the regression suite, or an
# operator with a fixed interpreter) got whatever `uv` sat in /usr/local/bin instead, with no way
# to opt out from outside. Appending keeps the tools discoverable without overruling the caller.
# (`SCOUT_UV` below pins the binary explicitly when PATH order is not enough.)
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

# The `uv` used to provision the scout venv. `SCOUT_UV` overrides PATH resolution outright — the
# regression suite pins its stub with it, and an operator can point it at a specific interpreter.
# Both the `--check` probe and the run resolve through this SAME variable, so a check can never
# disagree with what the refresh would actually execute.
UV="${SCOUT_UV:-uv}"

# ── exit codes: TWO failure kinds, because the caller must act on them differently ────────────
# `&` in orch-loop.sh discarded this script's status, so a bare non-zero was invisible. orch-loop
# now reads the code: TRANSIENT is retried next cycle (a network/tool hiccup — retrying is
# correct); NOT_PROVISIONABLE stops the retry loop and is surfaced loudly, because retrying cannot
# help. Keep these in sync with orch-loop.sh's `-eq 3` handler.
EXIT_TRANSIENT=1
EXIT_NOT_PROVISIONABLE=3

# ── the interpreter minimum, from the TOOL (agent-infra#1748 review) ──────────────────────────
# The collision pre-flight is stdlib-only, which is why a repo with no `pyproject.toml` needs no venv
# — but it is NOT interpreter-agnostic: tortoise's `tools/collision_preflight.py` refuses a <3.12
# interpreter at module scope (#5128), prints an explanation and exits 3 with NO `VERDICT` line.
# Nothing here used to check the version, so the bare-`python3` arm could select macOS's CLT 3.9 shim
# or Ubuntu 22.04's 3.10: `--check` said CHECK OK (it tested existence only), the refresh exited 0
# having queued nothing, and no `.refresh-blocked` marker was written — the merge-only cell #1736
# exists to remove, certified by the gate this PR added. Both paths gate the SELECTED interpreter on
# this minimum; it is the tool's own contract, named once here.
MIN_PY_MAJOR=3
MIN_PY_MINOR=12

# 0 iff $1 runs and is at least the tool's minimum. Used for the venv interpreter too: `uv sync`
# honours the project's `requires-python`, which may be lower, so "a venv exists" is not by itself
# evidence that the tool will run in it.
py_satisfies_min() {
  local bin="$1"
  [ -n "$bin" ] || return 1
  "$bin" -c "import sys; raise SystemExit(0 if sys.version_info[:2] >= ($MIN_PY_MAJOR, $MIN_PY_MINOR) else 1)" >/dev/null 2>&1
}

# Set PY to an interpreter meeting the tool's minimum, or return 1 with the reason in PY_WHY.
# `SCOUT_PY` pins it outright (mirrors `SCOUT_UV`) and is authoritative: a pinned interpreter that
# does not satisfy the minimum is a REFUSAL, never silently swapped for another. Otherwise the
# versioned names are tried before the generic `python3`, because on macOS `python3` is the CLT 3.9
# shim while a 3.12 sits in /opt/homebrew/bin — and the export above only APPENDS those dirs, so
# `command -v python3` finds the too-old one first. The two macOS dirs are tried explicitly for the
# same reason, so a 3.12 there is still found under launchd's minimal PATH.
resolve_python() {
  local cand resolved
  if [ -n "${SCOUT_PY:-}" ]; then
    if py_satisfies_min "$SCOUT_PY"; then PY="$SCOUT_PY"; return 0; fi
    PY_WHY="SCOUT_PY='$SCOUT_PY' is not a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR"
    return 1
  fi
  for cand in python3.13 python3.12 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    resolved="$(command -v "$cand" 2>/dev/null || true)"
    [ -n "$resolved" ] || continue
    if py_satisfies_min "$resolved"; then PY="$resolved"; return 0; fi
  done
  PY_WHY="no Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR found (tried python3.13, python3.12, python3, /opt/homebrew/bin/python3, /usr/local/bin/python3)"
  return 1
}

MODE=refresh
LIMIT=24
# ⛔ A PERSISTENTLY NON-ANSWERING ENTRY MUST EVENTUALLY LEAVE THE CANDIDATE SET (tortoise#8469
# review P2, ported with the landed.txt half). Without a bound, a candidate at the pool head whose
# pre-flight never answers is re-judged on EVERY pass and the cursor can never advance past it, so
# the entries behind it starve forever. `RETRY_MAX` consecutive attempts mark it checked and the log
# names the attempt.
# ⛔ AND THE BOUND APPLIES ONLY TO A VERDICT-LESS RUN — NEVER TO A PRE-FLIGHT `INCOMPLETE` (review P1,
# this round; the port had folded both into one arm). `INCOMPLETE` is not per-candidate flakiness: this
# file documents it as a BOX-WIDE state in three places — without `cmux` "EVERY verdict is INCOMPLETE"
# (:371, :385), an unauthenticated `gh` degrades every verdict (:396), and an unreadable claim registry
# returns rc 2 for every issue (:1848). Striking those candidates would, after three passes, append the
# whole walked pool head to `checked.txt` — which the CLEAN arm above states is "reclaimed only for
# numbers that reached `dispatched.txt`", i.e. PERMANENT and invisible for a candidate that was never
# dispatched. A box-wide outage would then look exactly like an empty backlog (#2040/#1731) and
# nothing would ever dispatch again. So a pre-flight `INCOMPLETE` takes NO strike: it is reported on
# every pass already (its own line, `ICR_INCOMPLETE`, the `judged NOTHING` abort, `.refresh-blocked`),
# and the fix is the box, not the queue.
# ⛔ AND AN `INCOMPLETE` MAY NEITHER SUPPLY NOR RESET THE COUNT (review P1, final round). The bound
# counts VERDICT-LESS RUNS ON THIS ENTRY since its last real verdict: `state/pretry-<N>` is
# incremented by the verdict-less arm alone and cleared by the arms that reach a verdict (CLEAN,
# COLLISION, LANDED). Round 4 spanned both kinds under one counter plus a `pretryown-<N>` marker, so
# an entry needed only ONE run of its own failure to retire — the count itself could be supplied by a
# box-wide outage. Measured sequence at the default `RETRY_MAX=3`: `INCOMPLETE` (outage), `INCOMPLETE`
# (outage), then one verdict-less run -> `checked.txt`, permanent and invisible, for a candidate that
# was never dispatched. Counting verdict-less runs alone keeps BOTH properties: a pure outage never
# retires (it never increments), and a pool head that never answers is still bounded — a verdict-less
# run each pass retires at `RETRY_MAX`, and an alternating outage/verdict-less chain retires after at
# most `2*RETRY_MAX` passes, because an `INCOMPLETE` does not clear the count either (round 3's reset
# was the starvation half of this bug).
# ⛔ A BAD VALUE CAN ONLY MAKE THE BOUND LOOSER, NEVER TIGHTER (review P2, this round). Non-numeric or
# absent -> the shipped default. A literal `0` is clamped to the DEFAULT, not to 1: `1` marks an entry
# checked on its FIRST failure, which is the first-failure blacklisting this bound must not create —
# the previous `[ "$RETRY_MAX" -ge 1 ] || RETRY_MAX=1` did exactly that while the comment promised it
# could not.
RETRY_MAX="${RETRY_MAX:-3}"
case "$RETRY_MAX" in ''|*[!0-9]*) RETRY_MAX=3 ;; esac
[ "$RETRY_MAX" -ge 1 ] || RETRY_MAX=3
case "${1:-}" in
  --check) MODE=check ;;
  '')      ;;
  *[!0-9]*) echo "[refresh] FATAL: unknown argument '$1' (usage: refresh-candidates.sh [LIMIT] | --check)" >&2; exit 2 ;;
  *)       LIMIT="$1" ;;
esac

# The per-pass read cache is installed ONLY on the run path: `--check` is read-only by contract and
# never makes a gh call at all, so it has nothing to memoise and nothing to clean up. The traps are
# installed HERE rather than earlier because `exit` before this point (no `trap` yet) has no cache
# to remove; after it, every exit path — including the ones below that `exit "$EXIT_TRANSIENT"` —
# takes the same two lines and no branch has to remember them.
if [ "$MODE" = refresh ]; then
  gh_pass_cache_start
  trap 'gh_pass_cache_stop' EXIT
  trap 'gh_pass_cache_stop; exit 129' HUP
  trap 'gh_pass_cache_stop; exit 130' INT
  trap 'gh_pass_cache_stop; exit 143' TERM
fi

# ── the collision pre-flight tool, resolved PER REPO (agent-infra#1736) ────────────────────────
# The gate is a TORTOISE product: tortoise is the only repo that ships tools/collision_preflight.py
# and it applies to ANY issue's repo through --repo. A repo that carries its own copy wins (it pins
# the version that repo reviewed against); otherwise a tortoise checkout is used; otherwise there
# is NOTHING to run, and "nothing to run" must be a loud refusal, never an empty backlog. The old
# code hardcoded `$SC/tools/collision_preflight.py`, so a cell on agent-infra (no such file) ran a
# tool that did not exist, emitted no VERDICT, and queued nothing — forever, and silently.
PREFLIGHT=""
# The configured tortoise checkout. `TORTOISE_REPO` is the harness's established name for this
# (check-port-drift.sh, install-launchd.sh, hub-state-check.sh); `TORTOISE` is accepted as an alias
# so an operator's existing keys.env keeps working (agent-infra#1748 review).
tortoise_var() { [ -n "${TORTOISE_REPO:-}" ] && printf '%s' "$TORTOISE_REPO" || printf '%s' "${TORTOISE:-}"; }
find_tortoise() {   # print a tortoise checkout carrying the tool, or return 1
  local cand common configured
  configured="$(tortoise_var)"
  if [ -n "$configured" ] && [ -f "$configured/tools/collision_preflight.py" ]; then
    (cd "$configured" && pwd -P); return 0
  fi
  common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  for cand in \
    "$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" \
    "$([ -n "$common" ] && dirname "${common%/.git}")/tortoise" \
    "${HOME:-/nonexistent}/Documents/GitHub/tortoise" \
    "${HOME:-/nonexistent}/eldato/tortoise" \
  ; do
    [ -n "$cand" ] || continue
    [ -f "$cand/tools/collision_preflight.py" ] || continue
    (cd "$cand" && pwd -P); return 0
  done
  return 1
}

resolve_preflight() {   # sets PREFLIGHT to the resolved tool path; returns 1 if none
  local repo_dir t
  # The TARGET repo's own copy — the scout worktree when it exists, else the main checkout.
  # `--check` must not create the worktree, so the main checkout is what it reads there.
  repo_dir="$REPO"; [ -d "$SC" ] && repo_dir="$SC"
  if [ -f "$repo_dir/tools/collision_preflight.py" ]; then
    PREFLIGHT="$repo_dir/tools/collision_preflight.py"; return 0
  fi
  if t="$(find_tortoise)"; then
    PREFLIGHT="$t/tools/collision_preflight.py"; return 0
  fi
  return 1
}

# ── cmux must be EXECUTABLE by the pre-flight, or EVERY verdict is unusable ────────────────────
# WHY. The pre-flight's `issue assignee/holder` surface reads lane liveness from the FLEET BOARD, and
# the board's only source for it is the live-session store: tortoise's `tools/fleet_state.py`
# `live_sessions()` shells out to `cmux sessions list --json --all`. When cmux cannot be executed that
# read returns `{}`, `build_state` writes `liveness_measured: False`, and the board carries an
# `orphans[kind=liveness-unmeasured]` row. The pre-flight refuses to read an unmeasured liveness as a
# dead owner (`_board_liveness_error`, fail-closed — #8175), so the surface is INCOMPLETE.
#
# ⛔ ONE UNMEASURABLE SURFACE IS THE WHOLE PASS. Every blocking surface must answer before the tool
# prints anything this script counts, so a holder surface it can never measure makes EVERY candidate
# unusable and the pass aborts BY DESIGN (#1736) — correctly, but forever. MEASURED 2026-10-18 on this
# box: `candidates.txt: 0`, `checked.txt: 310`, pool READ(203), and every cycle of
# `~/orchestrator/logs/orch-loop.log` carrying
#     [refresh] ?#1981 INCOMPLETE from the pre-flight (it could not query every surface)
#     [refresh] ABORT: none of the 6 candidate(s) the pre-flight ran produced a usable verdict
# under the daemon PATH `com.eldato.orchestrator-stack` really sets:
#     /Users/home/orchestrator/gh-rest:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
# cmux is not on it and CANNOT be: the binary ships inside the app bundle
# (/Applications/cmux.app/Contents/Resources/bin/cmux), which is on no default PATH. An interactive
# shell finds it only because cmux's own shim setup adds that directory to the LOGIN shell's PATH —
# and launchd inherits no shell. `install.sh` never probed cmux either (its list was tmux/gh/uv/pi/jq),
# so a FRESH INSTALL reproduced the same PATH. Both halves are fixed: install.sh now bakes the
# resolved directory into the daemon PATH, and this resolver repairs a RUNNING deployment — the
# refresh's own PATH — without one.
#
# ⛔ APPEND, NEVER PREPEND. That bundle directory also ships `open`, `ghostty`, `grok` and `muse`;
# prepending it would shadow /usr/bin/open for every child of this pass. Appending keeps cmux
# findable while changing which binary wins for nothing.
# ⛔ ALSO ASK IT TO RUN. `/Applications/cmux.app` can be present with its CLI unable to talk to the
# app; that is a different failure and the pre-flight reports it as INCOMPLETE with its own reason, so
# this resolver's contract is only the PATH half — it must not claim more than it checked.
# ⛔ THIS HOME'S BUNDLE IS TRIED BEFORE /Applications: a user-local install must win over the system
# copy, and it is what makes this resolver hermetically testable (a sandbox HOME), which is the only
# way a regression test can pin "the controller's PATH has no cmux" without the host's own cmux
# answering for it.
resolve_cmux() {
  local cand
  if command -v cmux >/dev/null 2>&1; then return 0; fi
  for cand in \
    "${CMUX_BIN_DIR:-}" \
    "${HOME:-/nonexistent}/Applications/cmux.app/Contents/Resources/bin" \
    /Applications/cmux.app/Contents/Resources/bin \
  ; do
    [ -n "$cand" ] || continue
    [ -x "$cand/cmux" ] || continue
    PATH="$PATH:$cand"; export PATH
    echo "[refresh] cmux was NOT on PATH — appended $cand: the pre-flight's holder surface reads the fleet board's live-session store through 'cmux sessions list', and without it EVERY verdict is INCOMPLETE (#8175/#1736)"
    return 0
  done
  return 1
}
# Resolved ONCE, at load, so `--check` and the run judge the SAME environment and the repair is
# written once per pass either way. Non-fatal: whether an unmeasured board is fatal is not this
# script's call (the abort guard owns "a pass judged nothing", and a cell may legitimately serve a
# SHARED board it did not build) — but it is never silent: `--check` has its own line below, and a
# RUN says so here, because the abort it causes ("judged NOTHING", #1736) names no cause and the
# pre-flight's own reason is swallowed by the summary.
CMUX_HINT=""
if ! resolve_cmux; then
  CMUX_HINT=1
  [ "$MODE" = "check" ] || echo "[refresh] WARN: 'cmux' is not resolvable (tried \$CMUX_BIN_DIR, \$HOME/Applications/cmux.app/Contents/Resources/bin, /Applications/cmux.app/Contents/Resources/bin) — the pre-flight's holder surface reads the fleet board's live-session store through 'cmux sessions list', so every verdict from this box is INCOMPLETE and nothing can be queued (#8175/#1736) — fix: run install.sh, or set CMUX_BIN_DIR=<the directory holding cmux>"
fi

# ── gh must be able to AUTHENTICATE, or the pre-flight's verdicts are degraded fiction ─────────
# WHY. The surfaces of tools/collision_preflight.py that DECIDE a verdict — issue metadata, open PRs,
# the assignee/holder surfaces — are gh-backed. The three it reads from git (local branches, remote
# branches, local worktrees) are NOT a substitute: all three are BLOCKING — a ref naming the issue
# forces a COLLISION — and the local-branch surface's terminal lookup is itself a gh call whose
# failure deliberately KEEPS the ref blocking (fail-closed). With an unauthenticated gh the tool does
# NOT refuse — it answers from whatever it can still read, which is
# how a LANDED issue came back as a COLLISION (measured 2026-10-16, #1328: `VERDICT: COLLISION ...
# ALSO INCOMPLETE: 3 surface(s) could not be queried` under HOME=/home/ubuntu, `VERDICT: LANDED`
# under HOME=/tmp/cell-home). The caller cannot tell that answer apart from a real collision, so an
# environment failure becomes "a peer owns it, retry next pass" on every candidate, forever. This
# check turns it back into ONE named provisioning failure.
# ⛔ PERMANENT (3) IS RESERVED FOR A CONDITION A RETRY CANNOT CHANGE — no `gh` on PATH, no credential
# stored for the host, or a credential the API has REJECTED with a 401. Everything else is TRANSIENT
# (1), so a network/API fault cannot latch the permanent `.refresh-blocked` marker that only a human
# can clear (#1853 review).
# `gh auth token` also recognises GH_TOKEN/GITHUB_TOKEN, so a token-in-env cell is not false-blocked.
# ⛔ ASK gh WHICH HOST IT WILL USE — DO NOT MODEL IT. The pre-flight's own calls pass a host-LESS
# repo slug (`--repo .`, whose remote host `_remote_slug` strips), so the host is gh's choice — and
# gh's rule (`GH_HOST`, else the ONE configured host, else github.com) CANNOT be reproduced from its
# JSON view. `gh auth status --json hosts` reports the KNOWN hosts, which ADD a github.com entry
# synthesised from GH_TOKEN/GITHUB_TOKEN, and it cannot show a configured github.com whose token an
# env token shadows: the two are byte-identical there. Every attempt to derive the host from that
# JSON named the WRONG host in some configuration — a two-GHES config (gh uses github.com, the JSON
# suggests the enterprise host, so the probe reported TRANSIENT for ever and never named the real
# cause) and a GHES config with GH_TOKEN set (gh uses the enterprise host, the JSON suggests
# github.com, so a bad credential LATCHED the permanent marker naming the wrong host) — both measured
# against gh 2.97.0 (#1853 review). So NO host is named here at all: `gh auth token` and `gh api`
# resolve it exactly as the pre-flight's own calls do. Neither touches any OTHER host, so an unrelated
# host's problem cannot change the answer (an UNSCOPED `gh auth status` would — it validates them all).

# 0 = the environment the pre-flight runs in can authenticate; 1 = TRANSIENT; 3 = PERMANENT.
gh_probe_env() {
  local terr err
  if ! command -v gh >/dev/null 2>&1; then
    echo "[refresh] NOT PROVISIONABLE: gh is not on PATH — the verdict-deciding surfaces of the collision pre-flight are gh-backed, so no candidate can be judged and a cell on this repo could only MERGE (#1736)"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  # ⛔ DISCRIMINATE ON THE CREDENTIAL'S PRESENCE, NEVER ON gh's PROSE. Presence and validation have to
  # be TWO questions, because no single hosted call answers both without naming a host. `gh auth
  # status` cannot tell a transport fault from a rejected credential — measured on gh 2.97.0: behind a
  # DEAD PROXY a pure network fault prints exactly the same "The token in ~/.config/gh/hosts.yml is
  # invalid." as a revoked one — so any text match on "invalid"/"expired"/"authenticat" classifies an
  # outage as a credential failure and latches the permanent marker a human must clear (#1853 review).
  # PRESENCE is `gh auth token`: an OFFLINE lookup of the stored credential (hosts.yml / the keyring),
  # so its exit status is cause-independent. ⛔ ITS STDOUT IS THE TOKEN — it is discarded below and the
  # captured stream is STDERR ONLY (`2>&1 >/dev/null`), so no token can reach the log.
  if ! terr="$(gh auth token 2>&1 >/dev/null)"; then
    echo "[refresh] NOT PROVISIONABLE: gh has no credential STORED for the host it is configured for, in the environment the pre-flight runs in (HOME=$HOME) — its issue/PR surfaces cannot be read, so the pre-flight would answer from partial evidence and read every candidate as a collision (#1736)"
    printf '%s\n' "$terr" | sed -n '1,4p' | sed 's/^/[refresh]   /'
    echo "[refresh]   fix: authenticate gh in THIS home (gh auth login --with-token <token>), or point HOME at the home that already holds the credentials; set GH_HOST to name a host other than the one gh is configured for, then re-run"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  # VALIDATION is the same call the pre-flight's gh-backed surfaces make, with no host named. A
  # credential that is STORED and DOES answer is usable, so this is also where the probe can SUCCEED.
  err="$(gh api rate_limit 2>&1)" && return 0
  # A credential IS stored, but the call did not answer. Is it REJECTED, or merely UNREACHABLE? Only
  # the API can say, and only a 401 is unambiguous. A 403 is deliberately NOT used: `/rate_limit` is
  # exempt from the PRIMARY rate limit, but a 403 still has several meanings — an SSO/SAML
  # enforcement, a missing scope, an IP-allowlist block, a suspended account, or a SECONDARY rate
  # limit — so a permanent denial and a transient throttle are indistinguishable there (and a
  # transport failure carries no HTTP status at all). The ambiguous middle is
  # returned TRANSIENT on purpose: a wrong TRANSIENT costs a loud rc=1 retry, while a wrong PERMANENT
  # stops dispatch until a human clears the marker. MEASURED on gh 2.97.0: a bogus stored token ->
  # `gh: Bad credentials (HTTP 401)`; a dead proxy -> `proxyconnect tcp: … connection refused` with no
  # status.
  # ⚠️ DECLARED RESIDUAL: a credential that GitHub rejects with a 403 is therefore retried
  # indefinitely (loudly, via `FAILED rc=1`) and never writes the permanent marker.
  if grep -q 'HTTP 401' <<<"$err"; then
    echo "[refresh] NOT PROVISIONABLE: the gh credential STORED for the host gh is configured for is REJECTED by GitHub (HTTP 401) in the environment the pre-flight runs in (HOME=$HOME) — a retry cannot fix it, and every candidate would be read as a collision (#1736)"
    printf '%s\n' "$err" | sed -n '1,4p' | sed 's/^/[refresh]   /'
    echo "[refresh]   fix: re-authenticate gh in THIS home (gh auth login --with-token <token>), then re-run"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  echo "[refresh] TRANSIENT: a gh credential is stored for the host gh is configured for but the API did not answer with a 401 in the environment the pre-flight runs in (HOME=$HOME) — treating it as an outage rather than a rejected credential, so this is retried next cycle instead of latching the permanent MERGE-ONLY marker (#1736)"
  printf '%s\n' "$err" | sed -n '1,4p' | sed 's/^/[refresh]   /'
  return "$EXIT_TRANSIENT"
}

gh_env_verdict() {
  # The probe covers the host the pre-flight's own host-LESS calls resolve. The harness's POOL
  # LISTING is a different call — it names `$OR` directly — and it is guarded where it runs: an
  # unreadable listing must not be read as an empty one (see `.pool` in cmd_run).
  gh_probe_env
}

# ── the cross-box ISSUE claim: a BLOCKING pre-flight surface (agent-infra#1850) ────────────────
# The pre-flight tool (`tools/collision_preflight.py`) enumerates its own surfaces out of immutable
# history — open PRs, branches, worktrees, the assignee — and `git worktree list`/local branches are
# PER-MACHINE BY CONSTRUCTION, so a peer's work is invisible until it first pushes. A lane's whole
# working period is exactly that window, and NOTHING assigns the issue on dispatch
# (`refresh-candidates.sh`'s pool selects `(.assignees|length)==0`), so every box reads every issue
# as free. That is the 2026-10-16 collision: two cells dispatched the same tortoise issues.
#
# The registry that closes the window is `refs/claims/*` (claims.sh) — a ref push is an atomic CAS,
# it is durable, and it is already read cross-box. So the pre-flight step consults it HERE: this
# script is what certifies an issue as dispatchable, so it is the only place the read can make the
# verdict WRONG (the tool is a tortoise product and reads no claim refs; a claim nobody reads is not
# a claim). The ref's HOME is the TARGET repo's origin — that is `$SC`, the scout worktree, which
# shares `$REPO`'s origin — because every would-be dispatcher of that issue resolves `$REPO` to it.
#
# ⛔ FAIL-CLOSED, AND ONLY HERE. `claim_issue_preflight` returns 2 (INCOMPLETE) when the registry
# cannot be READ, and an INCOMPLETE is never a CLEAN: a registry outage must not become a duplicate
# dispatch. That polarity is the OPPOSITE of claims.sh's acquisition path, which fails OPEN on an
# infra error so a network blip does not block a merge — the two are deliberate, and the cost of
# being wrong differs: refusing costs one PR's merge, certifying a free issue costs duplicated work
# on two boxes.
#
# ⚠️ STATED LIMIT: a box where the registry FILE is NOT INSTALLED does not queue nothing — it falls
# through to the pre-registry behaviour, loudly. A deployed box gets it from the deploy step that
# seeds `$O` (`scripts/deploy-crossbox.sh`, `scripts/deploy-mac-orchestrator.sh`, or the manual
# `cp scripts/orchestrator-harness/*.sh ~/orchestrator/` of README §4 — ⛔ NOT `install.sh`, which
# only REPORTS the drift and prints that `cp` command; corrected 2026-10-16 after a review found the
# old sentence sent the operator down a path that does not install it), so a deployed cell has it; a
# box without it cannot take the claim either, and refusing to queue on a missing FILE would make
# every such box merge-only — a bigger, less reversible failure than the state being removed.
# Missing is reported; unreadable is refused; PRESENT BUT STALE is refused AND surfaced as a
# provisioning failure (rc=3 below), because that one is local, permanent, and fixable in seconds.
# ⛔ THE REGISTRY PATH IS NOT READ FROM THE ENVIRONMENT (2026-10-16 review). `CLAIMS_SH` was a
# regression-test seam, but three production callers had begun to honour it, which let an ambient
# value resolve a DIFFERENT registry in each of them — a gate half-disabled by the environment, the
# exact "disable it by ambient env" shape orch-loop.sh's dispatch gate forbids. It is now a path:
# `$O/claims.sh`, everywhere, and the regression suite drives a sandbox `O` instead.
issue_claim_verdict() { # <issue> -> 0 CLEAN / 1 COLLISION / 2 INCOMPLETE / 3 NOT PROVISIONABLE
  local csh="$O/claims.sh"
  if [ ! -f "$csh" ]; then
    CLAIM_RESULT="the claim registry ($csh) is NOT INSTALLED — INCOMPLETE, never CLEAN"
    return 2
  fi
  # CLAIM_REPO = the scout worktree: a checkout of the TARGET repo, whose origin is the ref's home.
  CLAIM_REPO="${SC:-$PWD}"
  # shellcheck source=/dev/null
  . "$csh" || { CLAIM_RESULT="$csh failed to source — INCOMPLETE, never CLEAN"; return 2; }
  # ⛔ A REGISTRY THAT CANNOT ANSWER IS NOT EVIDENCE OF FREEDOM. An older `claims.sh` in $O (drift:
  # the drift check reports it, and the daemon executes the $O copy) has no `claim_issue_preflight`,
  # and calling the missing function returns 127 — which the CLEAN arm's `case` would read as neither
  # 1 nor 2, and therefore QUEUE the issue. A stale flag that records a past state must not become a
  # duplicate dispatch, so a registry that cannot answer counts as INCOMPLETE.
  # ⛔ AND THIS ONE IS ITS OWN CODE (rc=3, 2026-10-16 review), because unlike an unreadable registry
  # it is PERMANENT and LOCAL: nothing about it is transient, so a pass that keeps answering
  # INCOMPLETE queues nothing forever while the cell still reports RUNNING — the "a cell that can
  # only merge, and looks healthy" defect this script has already been fixed for twice (#1748,
  # #1736). rc=3 is the provisioning code `orch-loop.sh` turns into `$O/.refresh-blocked`, which
  # stops the retry AND names the reason in `status`. The operator's fix is one `cp`.
  if ! declare -f claim_issue_preflight >/dev/null 2>&1; then
    CLAIM_RESULT="$csh predates the issue-claim reader (no claim_issue_preflight) — NOT PROVISIONABLE, never CLEAN"
    return 3
  fi
  claim_issue_preflight "$1"
}

# ── --check: the read-only provisioning verdict ───────────────────────────────────────────────
cmd_check() {
  local scout tool_dir
  # ⛔ The gh precondition is DELIBERATELY NOT judged here. `--check` is what
  # cloud-cell-supervisor.sh's cmd_check and cloud-cell-bringup.sh's check_dispatch run, and each of
  # those already performs ONE `gh auth status` itself — the supervisor's in cmd_check, the bringup's
  # in check_gh, which bringup's own `--check` arm runs immediately before check_dispatch (both are
  # listed in its main()). orchestrator-harness's selftest pins exactly one such call under
  # `$CELL_HOME` for each of them, so a second `gh auth status` from here would redden an
  # owned suite. More importantly it is the WRONG LAYER:
  # those checks run in the
  # operator's shell with HOME=$CELL_HOME forced, while the pre-flight inherits the HOME of the
  # process that actually runs it — which is the divergence this whole change exists for, and which
  # no operator-side check can see. The run path below is the one that judges it.
  # ⚠️ DECLARED RESIDUAL (pre-existing, and outside this change's scope): those two operator-side
  # checks call `gh auth status` UNSCOPED, so a stale UNRELATED host refuses a cell whose target host
  # is fine. scripts/cloud-cell-supervisor.sh and scripts/cloud-cell-bringup.sh are owned by another
  # lane; the run-path probe below is host-scoped, so this one is not.
  [ -d "$REPO" ] || { echo "[refresh] check: FAIL repo not found at $REPO"; return "$EXIT_TRANSIENT"; }
  tool_dir="$REPO"; [ -d "$SC" ] && tool_dir="$SC"
  if ! resolve_preflight; then
    echo "[refresh] check: no tools/collision_preflight.py in $tool_dir and no tortoise checkout resolved (TORTOISE_REPO='${TORTOISE_REPO:-}', TORTOISE='${TORTOISE:-}')"
    echo "[refresh] NOT PROVISIONABLE: this repo cannot be pre-flighted for dispatch, so a cell on it would MERGE ONLY (#1736)"
    echo "[refresh]   fix: set TORTOISE_REPO=<a tortoise checkout> (e.g. in keys.env), or vendor tools/collision_preflight.py into the repo"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  echo "[refresh] check: repo=$REPO"
  echo "[refresh] check: pre-flight tool=$PREFLIGHT"
  # ⛔ jq IS A PREREQUISITE OF THE LISTING READ (#1962 review). The listings run on the REST bucket and
  # `rest_list` assembles and projects pages with jq; without it the helper REFUSES rather than answer
  # from a partial read, so every pass would report `queue=UNREADABLE` and the cell would be MERGE-ONLY
  # — the exact shape this check exists to refuse. Probed BEFORE "CHECK OK", because a verdict printed
  # after the certification is not a verdict, and `cloud-cell-bringup.sh` refuses to start a cell on
  # NOT PROVISIONABLE. install.sh probes jq on a new box for the same reason.
  # ⛔ PROBED BY EXECUTION, NOT BY PRESENCE (#1962 review, MEASURED). `command -v jq` answers "is a
  # file named jq on PATH" — a DIFFERENT question from "can it run", and the message below claims the
  # second. A jq that RESOLVES but cannot execute passes it: a shim whose tool is missing (this box
  # resolves `gh` through ~/.pi/agent/shims and install.sh probes daemons by RUNNING them for exactly
  # that 127), a wrong-architecture or corrupted binary. Measured with `jq` = `#!/bin/bash; exit 1`:
  # `--check` printed `CHECK OK` rc=0, and the helper then refused every page — the certified box that
  # reads `queue=UNREADABLE` for ever, which is the state this check exists to refuse. `py_satisfies_min`
  # above probes its interpreter the same way, for the same reason.
  jq --version >/dev/null 2>&1 \
    || { echo "[refresh] check: FAIL 'jq' does not RUN on this box (absent, or present and failing) — every listing is assembled with it"
         echo "[refresh] NOT PROVISIONABLE: the REST listings cannot be read without a WORKING jq, so a cell on this box would report queue=UNREADABLE and MERGE ONLY (#1962)"
         echo "[refresh]   fix: install jq (apt-get install -y jq), or put a working jq on PATH"
         return "$EXIT_NOT_PROVISIONABLE"; }
  echo "[refresh] check: jq=$(command -v jq)"
  # ── the CROSS-BOX CLAIM REGISTRY, judged LOCALLY (agent-infra#1850 review, 2026-10-16) ──────
  # The refresh refuses every issue when `$O/claims.sh` exists but predates the issue-claim reader,
  # and that state is permanent and local — so a cell in it queues NOTHING forever. Catching it HERE
  # is the whole point of a provisioning verdict: it needs no network, no `gh`, and no scout, and it
  # refuses to certify a cell that could only merge. A byte-identical check to the one the refresh
  # applies (`declare -f claim_issue_preflight`), so a check can never disagree with the run.
  if [ -f "$O/claims.sh" ]; then
    # ONE probe for both failure kinds — unloadable, or loaded but carrying no `claim_issue_preflight`
    # — because they share the one operator fix and the one consequence (the pre-flight refuses every
    # issue, so the cell can only merge). Behaviourally byte-identical to the refresh's own check.
    if ! ( CLAIM_REPO="$SC"; . "$O/claims.sh"; declare -f claim_issue_preflight >/dev/null 2>&1 ) 2>/dev/null; then
      echo "[refresh] check: FAIL $O/claims.sh cannot answer the issue-claim question (unloadable, or predating the issue-claim reader)"
      echo "[refresh] NOT PROVISIONABLE: the pre-flight would refuse every issue as INCOMPLETE, so a cell on this repo would MERGE ONLY"
      echo "[refresh]   fix: cp scripts/orchestrator-harness/*.sh ~/orchestrator/  (then re-run this check)"
      return "$EXIT_NOT_PROVISIONABLE"
    fi
    echo "[refresh] check: claim registry=$O/claims.sh (issue-claim reader present)"
  else
    # NOT a failure: the documented loud fallthrough (issue_claim_verdict's STATED LIMIT). The box
    # dispatches, without the cross-box gate, and says so — the same verdict the refresh reaches.
    echo "[refresh] check: claim registry=$O/claims.sh absent — the refresh will WARN per issue and dispatch without a cross-box claim"
  fi
  # ⛔ JUDGE THE INTERPRETER THE REFRESH WILL ACTUALLY USE. `--check` must not create the scout
  # worktree, but the venv it reads must be the one the run will find there. Reading
  # `$REPO/.venv/bin/python` whenever `$SC` did not exist was a FALSE PASS: the run uses
  # `$SC/.venv/bin/python`, so a repo with a main-checkout venv and a broken `uv` passed the probe,
  # then ran `uv sync`, failed, and exited the TRANSIENT 1 — no marker, nothing in `status`, retried
  # forever (#1748 review). A worktree of $REPO carries $REPO's pyproject.toml, so "no scout yet"
  # plus a repo pyproject means `uv` must be runnable. Whichever interpreter is selected — the
  # venv's or a bare python3 — is then version-gated, because the tool refuses <3.12.
  if [ -x "$SC/.venv/bin/python" ]; then
    scout="$SC/.venv/bin/python"
    if ! py_satisfies_min "$scout"; then
      echo "[refresh] check: FAIL the scout venv interpreter $scout is older than Python $MIN_PY_MAJOR.$MIN_PY_MINOR, which the pre-flight tool requires"
      echo "[refresh] NOT PROVISIONABLE: the pre-flight tool would refuse this interpreter and emit no VERDICT, so a cell on this repo would MERGE ONLY (#1736)"
      echo "[refresh]   fix: rebuild the scout venv with a newer interpreter (uv sync on a >= $MIN_PY_MAJOR.$MIN_PY_MINOR requires-python), or set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>"
      return "$EXIT_NOT_PROVISIONABLE"
    fi
    echo "[refresh] check: interpreter=$scout"
  elif [ -f "$SC/pyproject.toml" ] || { [ ! -d "$SC" ] && [ -f "$REPO/pyproject.toml" ]; }; then
    # Two ways to need a provisioned scout venv: the scout already exists and declares a uv/Python
    # project, or it does not exist yet but the repo it will be a worktree of does.
    command -v "$UV" >/dev/null 2>&1 \
      || { echo "[refresh] check: FAIL a pyproject.toml is present but 'uv' is not runnable (SCOUT_UV='${SCOUT_UV:-unset}', resolved command='$UV') — the scout venv cannot be provisioned"; return "$EXIT_TRANSIENT"; }
    echo "[refresh] check: interpreter=$SC/.venv/bin/python (to be provisioned with $UV sync)"
  elif resolve_python; then
    echo "[refresh] check: no pyproject.toml in $tool_dir — the scout venv step is NOT APPLICABLE; interpreter=$PY"
  else
    echo "[refresh] check: FAIL $PY_WHY"
    echo "[refresh] NOT PROVISIONABLE: the pre-flight tool requires Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR and no usable interpreter is available, so a cell on this repo would MERGE ONLY (#1736)"
    echo "[refresh]   fix: set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>, or put one on PATH"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  # cmux is not a gate here (see resolve_cmux: the abort guard, not this check, owns "judged
  # nothing"), but the operator needs it NAMED when it is the reason every verdict comes back
  # INCOMPLETE — the state that reads as a healthy cell with an empty pool from the outside.
  if [ -z "$CMUX_HINT" ]; then
    echo "[refresh] check: cmux=$(command -v cmux)"
  else
    echo "[refresh] check: WARN 'cmux' is NOT resolvable (tried \$CMUX_BIN_DIR, \$HOME/Applications/cmux.app/Contents/Resources/bin, /Applications/cmux.app/Contents/Resources/bin) — the pre-flight's holder surface reads the fleet board's live-session store through it, so every verdict from this box is INCOMPLETE and NOTHING can be queued (#8175)"
    echo "[refresh]   fix: run install.sh (it bakes the cmux directory into the daemon PATH), or set CMUX_BIN_DIR=<the directory holding cmux>"
  fi
  echo "[refresh] CHECK OK: this repo can be provisioned for dispatch"
  return 0
}

if [ "$MODE" = check ]; then cmd_check; exit $?; fi
# ⛔ AN UNWRITABLE STATE DIR REFUSES — it does not get absorbed. Every write below was unchecked, so a
# state dir that cannot be WRITTEN let the run finish with `checked 0; backlog now` at rc 0 having
# persisted NOTHING: no marker for orch-loop, no candidates, and the cell sits RUNNING with `lanes: 0`
# — the merge-only shape this change exists to remove (#1853 review).
mkdir -p "$O" || { echo "[refresh] ABORT: cannot create the state directory $O"; exit "$EXIT_TRANSIENT"; }
# ⛔ WRITABLE, NOT MERELY PRESENT — `mkdir -p` SUCCEEDS on an existing read-only or root-owned
# directory, where every write below fails. Those failures are invisible in exactly the way that
# matters: a STALE `.pool` left by an earlier run satisfies a test on the FILE, the loop reads that
# stale pool, and the pass reports `checked N; backlog now M` at rc 0 having persisted nothing. A probe
# write at entry makes it ONE named refusal instead (#1853 review). The probe covers a state dir that
# was ALREADY unwritable at entry; the state writes below are each checked in their own right, so a
# write failure that only BEGINS mid-run (a disk that fills afterwards) is refused at THAT write
# rather than absorbed. What remains unhandled is narrower: a line left PARTIALLY written by an
# interrupted write is not rolled back.
if ! ( : > "$O/.write-probe" ) 2>/dev/null; then
  echo "[refresh] ABORT: $O is not WRITABLE — the pass could not persist its backlog (#1736)"
  exit "$EXIT_TRANSIENT"
fi
rm -f "$O/.write-probe"
# ⛔ `state/product-class` IS INVALIDATED BY THE WRITER, NOT HERE (review cycle 6, P1; this comment used to
# describe a pass-entry invalidation that was WRONG and has been removed — do not restore it). The record
# describes `candidates.product.txt` / `candidates.harness.txt`, so only the function that writes those
# files may invalidate it, and it does: `write_product_queues` writes `PENDING` as its first action and
# every arm below overwrites it. A pass that refuses HERE, at the environment check, at the budget or at
# the pool read leaves the previous record standing — which is TRUE, because neither queue file changed
# (measured: with the entry-time write, every such pass reported a blind intake on a healthy box). What
# is left at this point of the pass is only the state DIRECTORY, which the writer needs.
mkdir -p "$O/state" 2>/dev/null || :
# The same environment precondition on the RUN path — and before the scout is provisioned, so a cell
# that cannot read GitHub refuses in a second instead of after minutes of network work.
gh_env_verdict || exit $?

# ── THE CORE BUDGET IS FINITE AND SHARED — ASK BEFORE YOU SPEND IT (#1736 follow-up) ─────────────
# MEASURED 2026-10-18 on the live Mac, from consecutive `[refresh]` lines in
# `~/orchestrator/logs/orch-loop.log`: REST core remaining 4459 -> 3659 -> 3054 -> 2389 -> 1784 ->
# 1124 -> 327 -> 0. ~670 core calls per pass against a 5000/hour account budget, so the box exhausted
# the whole bucket in ~7 passes. After that every pass judged 6 candidates against a rate-limited
# API, all 6 came back INCOMPLETE/DEGRADED, `judged 6 / usable 0` ABORTED — CORRECTLY (#1736: an
# empty backlog over candidates nobody judged is a false report) — and the fleet dispatched NOTHING
# for the rest of the hour. The refusal was right. The BURN was the defect.
# The burn is attacked at its source above (one board rebuild per pass instead of six) and in the
# pre-flight's own surfaces. What is left is the failure SHAPE: a pass that cannot tell, before it
# spends, that it is about to spend its last call. So the pass now reads the remaining core budget
# (that endpoint is exempt from the budget, so reading it is free) and judges FEWER candidates when
# the budget cannot buy another one while keeping a reserve.
#
# ⛔ THIS IS NOT A PERMISSION SLIP, AND IT NARROWS NOTHING. The pre-flight is invoked with exactly the
# same arguments and its verdict is judged by exactly the same fail-closed rules below; no surface is
# skipped, and no incompletely-queried surface can become CLEAN. Only HOW MANY candidates a pass
# attempts changes — and it changes in the safe direction: judging 2 of 6 COMPLETELY queues work,
# while judging 6 against a refused API queues nothing and is the #1736 abort. A pass that cannot
# afford even ONE candidate refuses TRANSIENTLY and NAMES the budget, because "judged nothing" must
# never be reported as "nothing to do". That refusal is placed BELOW the `dispatched.txt` reaper (see
# the "NOW THAT THE BLACKLIST IS PRUNED" block): the reaper's two listings are paid even when starved,
# because that reaper is the only thing that ever un-blacklists a dispatched issue that is still open.
#
# 300 is the reserve: below it, the sweep/merge/claim paths (which also spend this bucket) come first,
# and a pass that judges nothing still leaves the box able to MERGE.
#
# ⛔ 30 WAS THE WRONG CONSTANT, AND IT COST THE FLEET REAL WORK (#1984, cause 3). It was an estimate
# made before the per-pass read memo (#1984 cause 1) existed, and it is a ~3x OVER-estimate of even
# the un-memoised pass: a pass with LIMIT=24 judged SIX candidates where the budget could buy 24,
# because 18 of them looked unaffordable. An over-estimate here is not the safe direction it looks
# like — `CORE_RESERVE + k*CORE_EST` is subtracted from the SAME budget, so it silently converts
# "this box has 3,000 calls" into "this box may judge 6 things", and the backlog of a healthy cell
# starves while the bucket sits 60% full.
# The default is now MEASURED, not guessed. Counting shim over the shipped script, agent-infra, one
# 24-candidate pass with BOTH caches on (the board cache above and the per-pass read memo), spend per
# candidate in order:
#     [2, 2, 2, … 2, 5]  — 23 candidates at 2 core requests each (issue state + the `issue landed`
#     timeline; everything fleet-wide is read ONCE for the pass), and the FIRST candidate at 5,
#     because it is the one that pays those pass-wide reads (identity + open PRs + closed-PR sample).
# So the mean is 2.1 and the HIGH WATER is 5 — and a candidate that has to walk all eight surfaces
# (more timeline pages, a per-branch PR lookup) costs more than any candidate in that set.
# 6 is one above the measured high water, deliberately: this number is used as `CORE_RESERVE + k*EST`
# against a FINITE bucket, so setting it to the mean (2) would let a pass spend past the reserve
# exactly on the candidate that costs the most — an under-estimate is an OVER-spend, which is the
# failure this gate exists to prevent. It is also re-learned within the pass from each candidate's
# own measured spend, so a box whose pre-flight is more expensive paces itself; and because another
# consumer can only INFLATE an observation, the learning only ever makes the pass stop EARLIER.
# Both are operator seams, not policy: raising the reserve makes the box dispatch fewer candidates
# per pass; 0 disables pacing entirely (the burn protection above stays).
core_cfg_int() {   # <value> <default> — a non-numeric or negative seam is the default, never a crash
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
CORE_RESERVE="$(core_cfg_int "${COLLISION_PREFLIGHT_CORE_RESERVE:-}" 300)"
CORE_PER_CANDIDATE="$(core_cfg_int "${COLLISION_PREFLIGHT_CORE_PER_CANDIDATE:-}" 6)"
CORE_PACING="$(core_cfg_int "${COLLISION_PREFLIGHT_CORE_PACING:-}" 1)"
# Remaining core budget, or return 1 when it cannot be read. ⛔ UNREADABLE IS NOT ZERO: a probe that
# cannot answer must not starve the pass (that would turn a metric outage into a dispatch outage) and
# must not be reported as a healthy budget either. The caller says which it was.
core_remaining() {
  local r
  r="$(gh api rate_limit 2>/dev/null | jq -r '.resources.core.remaining // empty' 2>/dev/null)"
  case "$r" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$r"
}
CORE_EST="$CORE_PER_CANDIDATE"
STARVED=0
# ⛔ THE PROBE AND ITS ABORT ARE DELIBERATELY **NOT** HERE. They sit far below, immediately after the
# `dispatched.txt` reaper — the “NOW THAT THE BLACKLIST HAS BEEN PRUNED” block. Read that block
# before moving this: the gate was here, it cost zero calls here, and that turned out to be the wrong
# thing to optimise (a starved pass stopped pruning blacklisted issues that have no PR). This block is
# now only the SEAM RESOLUTION; the decision is taken where its cost is known.

# The scout is a dedicated throwaway worktree used only to run the collision pre-flight.
# Provision it on first use: an earlier version just `cd`-ed into it, so on a fresh box the
# refresh subshell exited 1 every cycle, wrote nothing, and the backlog silently never refilled.
if [ ! -d "$SC" ]; then
  echo "[refresh] provisioning scout worktree at $SC"
  cd "$REPO" || { echo "[refresh] ABORT: repo not found at $REPO"; exit "$EXIT_TRANSIENT"; }
  git fetch origin main --quiet 2>/dev/null || true
  if git rev-parse --verify -q "refs/heads/chore/dispatch-scout" >/dev/null 2>&1; then
    git worktree add "$SC" chore/dispatch-scout >/dev/null 2>&1
  else
    git worktree add "$SC" -b chore/dispatch-scout origin/main >/dev/null 2>&1
  fi
fi
cd "$SC" || { echo "[refresh] ABORT: no scout worktree at $SC — cannot pre-flight issues"; exit "$EXIT_TRANSIENT"; }

# Resolve the tool BEFORE spending time on a venv: a repo with no tool can never dispatch, whatever
# its environment, and the reason must be the one an operator sees.
if ! resolve_preflight; then
  echo "[refresh] NOT PROVISIONABLE: no tools/collision_preflight.py in $SC and no tortoise checkout resolved (TORTOISE_REPO='${TORTOISE_REPO:-}', TORTOISE='${TORTOISE:-}')"
  echo "[refresh]   this repo cannot be pre-flighted for dispatch — the cell would merge only (#1736)"
  echo "[refresh]   fix: set TORTOISE_REPO=<a tortoise checkout> (e.g. in keys.env) or vendor tools/collision_preflight.py into the repo"
  exit "$EXIT_NOT_PROVISIONABLE"
fi

# ── the scout venv: ONLY for a repo that declares a Python/uv environment ─────────────────────
# `uv sync` is a UV-PYTHON step. A repo with no pyproject.toml at all (agent-infra: package.json,
# bin/, scripts/, mcp-servers/) cannot run it — measured on the live cell: "No `pyproject.toml`
# found in current directory or any parent".
# ⛔ That is NOT a provisioning failure: there is NOTHING TO PROVISION. Reporting it as one
# (`ABORT: uv sync failed`) was the silent-loop defect (#1736). Only the genuinely
# not-applicable case is skipped; a `uv sync` that fails on a REAL pyproject is still fatal, still
# loud, and its output is printed — nothing else is swallowed.
PY="$SC/.venv/bin/python"
if [ ! -x "$PY" ]; then
  if [ ! -f "$SC/pyproject.toml" ]; then
    echo "[refresh] no pyproject.toml in $SC — not a uv/Python project; skipping the scout venv step (the pre-flight tool is stdlib-only)"
    # ⛔ Not "any python3": the tool REFUSES <3.12 with exit 3 and no VERDICT, which the loop below
    # would absorb as a per-issue "no verdict" and exit 0 — merge-only and silent (#1748 review).
    if ! resolve_python; then
      echo "[refresh] NOT PROVISIONABLE: no Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR to run the pre-flight tool — $PY_WHY"
      echo "[refresh]   the tool refuses an older interpreter (exit 3, NO VERDICT), so the backlog would"
      echo "[refresh]   stay empty and the refresh would exit 0 — a cell that looks RUNNING and MERGE ONLY (#1736)"
      echo "[refresh]   fix: set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>, or put one on PATH"
      exit "$EXIT_NOT_PROVISIONABLE"
    fi
  else
    # Read the extras from the PROJECT rather than hardcoding tortoise's: `uv sync --extra X`
    # ERRORS on an extra the pyproject does not declare, so inheriting `embeddings`/`parity` into a
    # non-tortoise Python repo would fail every cycle for a spec that does not apply to it.
    # SCOUT_UV_EXTRAS overrides the detection entirely (set it empty for a bare `uv sync`).
    EXTRAS=""
    if [ -n "${SCOUT_UV_EXTRAS+x}" ]; then
      EXTRAS="$SCOUT_UV_EXTRAS"
    else
      for e in embeddings parity; do
        awk -v want="$e" '
          /^\[/ { sec = ($0 ~ /^\[project\.optional-dependencies\]/) ; next }
          sec { line = $0; sub(/[[:space:]]*=.*/, "", line); gsub(/[[:space:]\"]/, "", line)
                if (line == want) { print "declared"; exit } }
        ' "$SC/pyproject.toml" 2>/dev/null | grep -q declared && EXTRAS="$EXTRAS --extra $e"
      done
      EXTRAS="${EXTRAS# }"
    fi
    echo "[refresh] provisioning scout venv (uv sync${EXTRAS:+ $EXTRAS})"
    # shellcheck disable=SC2086  # $EXTRAS is a deliberate, space-separated argv list
    if ! UVOUT="$(cd "$SC" && "$UV" sync $EXTRAS 2>&1)"; then
      echo "[refresh] ABORT: uv sync failed in $SC — run it by hand, then re-run the refresh"
      printf '%s\n' "$UVOUT" | tail -5 | sed 's/^/[refresh]   /'
      exit "$EXIT_TRANSIENT"
    fi
    [ -x "$PY" ] || { echo "[refresh] ABORT: uv sync reported success but $PY is missing"; exit "$EXIT_TRANSIENT"; }
  fi
fi
if [ -z "$PY" ] || ! "$PY" -c '' >/dev/null 2>&1; then
  echo "[refresh] NOT PROVISIONABLE: no usable python to run the pre-flight tool (no scout venv, no python3)"
  exit "$EXIT_NOT_PROVISIONABLE"
fi
# ⛔ The VENV interpreter is version-gated too: `uv sync` honours the project's `requires-python`,
# which may be lower than the tool needs, so an existing venv is not evidence the tool can run in it.
if ! py_satisfies_min "$PY"; then
  echo "[refresh] NOT PROVISIONABLE: the selected interpreter $PY is older than Python $MIN_PY_MAJOR.$MIN_PY_MINOR, which the pre-flight tool requires"
  echo "[refresh]   it would refuse it (exit 3, NO VERDICT) and the refresh would exit 0 having queued nothing (#1748 review)"
  echo "[refresh]   fix: set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>, or rebuild the scout venv on a newer requires-python"
  exit "$EXIT_NOT_PROVISIONABLE"
fi
git fetch origin --quiet 2>/dev/null || true

# ── THE LISTINGS RUN ON THE REST BUCKET, NOT GraphQL (agent-infra#1962 / #1959) ────────────────
# MEASURED 2026-10-17 on all three cloud cells, for hours:
#     [refresh]   GraphQL: API rate limit already exceeded for user ID 81560491.
#     [refresh] queue=UNREADABLE …            candidates.txt: 0 lines
# `gh issue list` / `gh pr list` are GraphQL, and those five calls above were the whole of this
# script's GraphQL LISTING traffic. When GitHub refused them the pass could not READ the board at all:
# every priority tier FAILED, it aborted `queue=UNREADABLE`, and the backlog stayed at 0 on every
# cell. "Transient — retried next cycle" was false, and `candidates.txt: 0` did not mean "no work" —
# it meant "the reader was starved". That is the defect this block removes.
# TWO mechanisms produce that refusal on this account, and the fix does not depend on which one:
#   1. REAL EXHAUSTION — one account (`daniel-ospina`, user 81560491) shared by the Mac and every
#      cell, one GraphQL bucket. Polling less would help.
#   2. A CACHED `RATE_LIMIT` BODY (agent-infra#1968) — GitHub answers a GraphQL rate limit with HTTP
#      200 + `errors[type:RATE_LIMIT]`, and gh caches that body as introspection for 24 h. Measured on
#      this account: every GraphQL call refused while `/rate_limit` reported ~4500/5000 remaining and
#      the cached entry's `X-Ratelimit-Reset` was hours IN THE PAST. Polling less does NOT help, and
#      "budget exhausted" is the wrong diagnosis. The tell is that past reset (or `used: 5000` inside
#      a refusal while `remaining` reads healthy).
# REST is a SEPARATE bucket (`gh api rate_limit` reports `core` and `graphql` independently), so the
# listings below are `gh api` — REST — and they cost the GraphQL budget NOTHING. That is what makes
# refusals like the two above stop mattering to the READ.
#
# ⛔ WHAT THIS DOES NOT FIX — stated because the difference decides what an operator does next. Only
# the LISTINGS moved. The per-candidate pre-flight (`tools/collision_preflight.py`) still reads
# `gh issue view` (issue state, assignee) and `gh pr list --state open`, and it is fail-closed: a
# BLOCKING surface it cannot query makes the run INCOMPLETE, which this pass refuses to queue. On
# these cells that is visible in the loop log — `?#N INCOMPLETE from the pre-flight (it could not
# query every surface) — not a verdict, left unchecked`. So on a box where GraphQL is refused and
# the `gh-rest` adapter is NOT on PATH, this change turns "the pool could not be READ" into "the pool
# was read and the pre-flight could not CERTIFY" — a named, later failure, not dispatch. Restoring
# dispatch there is the adapter's job (#1959/#1962, which is why it must be deployed on the cells) or
# the tool's own (it lives in the tortoise repo).
#
# ⛔ WHY NOT `$O/gh-rest` HERE. That adapter translates the same commands correctly, but it is a
# DAEMON-PATH concern, and a fail-closed read may not depend on something whose ABSENCE is silent:
# measured the same day on pi-cell-2, `/tmp/cell-home/orchestrator/gh-rest/` DOES NOT EXIST, and
# install.sh treats a missing adapter as a WARNING (`install.sh:380`) rather than a failure — so a
# refresh wired to it would have gone on spending GraphQL on every cell while reading as fixed. `gh api`
# is core gh, present exactly where `gh` is, which the provisioning check above requires.
#
# ⛔ FAILURE SEMANTICS ARE UNCHANGED, AND THAT IS THE POINT. These listings are load-bearing: an EMPTY
# `.open_iss`/`.pr_brs` written on a FAILED read un-blacklists issues that already HAVE a PR (#1705),
# and a silently short pool inverts the P0-before-P2 order (#8465). So a failed page or a failed
# projection returns NON-ZERO — the caller then DELETES the file rather than writing an empty one —
# and only "every page was read and the projection succeeded" is a success.
#
# ⛔ `--paginate` IS DELIBERATELY NOT USED. REST caps `per_page` at 100 and `gh api --paginate`
# follows every page to the end of the collection regardless of any limit, so a 500-limit query
# against a large repo would fetch thousands of rows — spending the shared core budget to produce
# rows nobody reads. `rest_list` reads `ceil(limit/100)` pages and stops at the limit, so each
# original limit stays a REAL total, not a first-page count.
LISTS_NOTED=""
lists_transport_note() {  # once per pass: which transport the LISTINGS use, and the bucket state
  [ -n "$LISTS_NOTED" ] && return 0
  LISTS_NOTED=1
  local probe gq co
  if probe="$(gh api rate_limit 2>/dev/null)" && [ -n "$probe" ]; then
    gq="$(printf '%s' "$probe" | jq -r '.resources.graphql.remaining // "?"' 2>/dev/null)"
    co="$(printf '%s' "$probe" | jq -r '.resources.core.remaining // "?"' 2>/dev/null)"
    echo "[refresh] listings transport=REST — GraphQL remaining=${gq:-?} AS REPORTED (a cached RATE_LIMIT body can refuse every call while this reads healthy, #1968), REST core remaining=${co:-?}: the listings below are REST; the per-candidate pre-flight still asks gh issue view / gh pr list (GraphQL) unless the gh-rest adapter is on PATH"
  else
    echo "[refresh] listings transport=REST — the rate_limit probe did not answer, so the bucket state is UNKNOWN here; the listings below still run on REST"
  fi
}

# rest_fail <kind> <page> <stderr-file> — ONE line the caller prefixes. It separates "starved" from
# "broken", and it does NOT call every 403 a rate limit.
rest_fail() {
  local kind="$1" page="$2" errf="$3" msg core status
  msg="$(tr '\n' ' ' < "$errf" 2>/dev/null | tr -s ' ' | cut -c1-240)"
  case "$msg" in
    *"rate limit"*|*"Rate limit"*|*"API rate limit"*)
      core="$(gh api rate_limit 2>/dev/null | jq -r '.resources.core.remaining // "unknown"' 2>/dev/null)"
      # ⛔ THE STATUS IS READ FROM THE PROVIDER'S OWN MESSAGE, NEVER ASSUMED. GitHub answers a rate
      # limit with 403 AND with 429 (secondary limits), so a hardcoded "HTTP 403" would mislabel the
      # one case where the provider's text is the only evidence there is — and dropping that text is
      # the same "naming the wrong cause closes the investigation" failure the 403 branch below is
      # written to avoid. `gh` prints the status in the same message ("… (HTTP 429)").
      # ⛔ FROM `$errf`, NOT FROM `$msg`: `msg` is cut to 240 chars for the one-line log, and a
      # SECONDARY-limit body carries a variable-length request-ID/timestamp tail, so the "(HTTP 429)"
      # that identifies the case can be exactly what the truncation removes (measured with a 250-byte
      # body: the log read `HTTP ?` and the message stopped mid-parenthesis).
      status="$(tr '\n' ' ' < "$errf" 2>/dev/null | sed -n 's/.*(HTTP \([0-9][0-9]*\)).*/\1/p')"
      echo "REST $kind listing FAILED — the REST bucket refused it as RATE-LIMITED (HTTP ${status:-?}, core remaining=${core:-unknown}): $msg; this is NOT an empty listing" >&2 ;;
    # ⛔ A 403 IS NOT NECESSARILY A RATE LIMIT. `gh api` answers a PERMISSION refusal with a 403 too
    # ("Resource not accessible by integration"), and naming the wrong cause closes the investigation
    # — worse than naming none. The provider's own words are carried through, and both causes named.
    *403*)
      core="$(gh api rate_limit 2>/dev/null | jq -r '.resources.core.remaining // "unknown"' 2>/dev/null)"
      echo "REST $kind listing FAILED — HTTP 403 with no rate-limit wording (core remaining=${core:-unknown}): a permission refusal OR an unnamed rate limit — $msg" >&2 ;;
    *)
      echo "REST $kind listing FAILED (page $page): ${msg:-gh api exited non-zero and said nothing}" >&2 ;;
  esac
}

# rest_list <issues|pulls> [--repo R] [--state S] [--limit N] [--label L] [--jq PROG]
#   The REST twin of the two `gh … list` forms this script uses. Prints the projected rows, one per
#   line. rc 0 ONLY when every page was read AND the projection succeeded — the one property every
#   caller below depends on. `--json` is NOT modelled on purpose: the caller's `--jq` names the
#   fields it reads, and dropping a field an adapter does not model is the wrong-answer shape
#   gh-rest's own header warns about. Messages go to stderr UNPREFIXED — the callers own the
#   `[refresh]` tag (they both re-prefix what they collect, so a helper-side tag doubles it).
rest_list() {
  local kind="${1:-}"; [ $# -gt 0 ] && shift
  local repo="$OR" state="open" limit=30 label="" prog='.' ep q page=1 pages n tmp pf status more
  if [ -z "$kind" ]; then
    echo "REST: rest_list needs a listing kind (issues|pulls)" >&2; return 1
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|--state|--limit|--label|--jq)
        # ⛔ A FLAG WITH NO VALUE IS A BROKEN CALL, NOT A DEFAULT. `shift 2` past the end does not
        # shift AT ALL in bash (measured: `set -- a; shift 2` → argc 1, rc 1), so the bare form spun
        # in this loop for ever — and this pass runs BACKGROUNDED, where a hang is invisible: the
        # controller reports RUNNING and the backlog never refreshes.
        [ $# -ge 2 ] || { echo "REST: listing flag '$1' needs a value" >&2; return 1; }
        case "$1" in
          --repo)  repo="$2" ;;
          --state) state="$2" ;;
          --limit) limit="$2" ;;
          --label) label="$2" ;;
          --jq)    prog="$2" ;;
        esac
        shift 2 ;;
      # ⛔ AN UNMODELLED FLAG IS AN ERROR, NOT A DROP: silently ignoring one turns a narrow query into
      # an unbounded one, which is how a priority tier silently becomes "every issue" (#8465).
      *) echo "REST: unsupported listing flag '$1' — refusing to answer a question this helper does not model" >&2; return 1 ;;
    esac
  done
  case "$kind" in
    issues) ep="repos/$repo/issues" ;;
    pulls)  ep="repos/$repo/pulls" ;;
    *) echo "REST: unknown listing kind '$kind'" >&2; return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || {
    echo "REST: jq is required to assemble a paginated $kind listing and is not on PATH — refusing to answer from a partial read" >&2
    return 1; }
  q="state=$state&per_page=100"
  # ⛔ THE LABEL IS URL-ENCODED. An unencoded space or `&` truncates the query and the tier then reads
  # as EMPTY — "no work" — which is the #8465 priority inversion through another door.
  [ -n "$label" ] && q="$q&labels=$(printf '%s' "$label" | jq -Rr @uri)"
  case "$limit" in
    ''|*[!0-9]*)
      echo "REST: --limit '$limit' is not a number — refusing to page an unbounded $kind listing" >&2
      return 1 ;;
  esac
  pages=$(( (limit + 99) / 100 )); [ "$pages" -ge 1 ] || pages=1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/refresh-rest.XXXXXX")" || {
    echo "REST: cannot create a temp dir for the $kind listing" >&2; return 1; }
  while [ "$page" -le "$pages" ]; do
    # ⛔ ZERO-PADDED, because the final jq is handed a GLOB and plain `p*.json` sorts `p10` BEFORE `p2`
    # — pages then concatenate out of order, and `.[0:$limit]` truncates the wrong rows once a listing
    # needs more than nine pages.
    printf -v pf '%s/p%03d' "$tmp" "$page"
    if ! gh api -i "$ep?$q&page=$page" > "$pf.raw" 2>"$pf.err"; then
      rest_fail "$kind" "$page" "$pf.err"
      rm -rf "$tmp"; return 1
    fi
    # `-i` prepends the response headers; the body is everything after the first blank line. The
    # separator is found by LENGTH rather than by matching `/^\r?$/`. The choice is PORTABILITY, not
    # a workaround: `\r` inside an ERE is a backslash before an ordinary character, which POSIX leaves
    # undefined, so a match on it would be a property of the awk build rather than of the response.
    # `length($0) <= 1` asks the question the header format actually answers — "is this line blank, or
    # a bare CR?" — and needs no escape at all. MEASURED, both forms on both awks this fleet runs, and
    # they agree: macOS awk 20200816 here and mawk 1.3.4 20240123 on pi-cell-2 (the cell's only awk)
    # each return the identical body from `A`/CR/CR/`B` input, and `/^\r?$/` matches the bare-CR line
    # on both (1 match) while `/^r?$/` matches none (0). So no build is known to fail this; the line
    # is written to not depend on the answer.
    # If a split ever did fail, the consequence is a REFUSAL, never a quiet undercount: the body comes
    # back empty, and an empty body on a 200 hits the empty-body guard below (only 204/304 may be
    # empty) and the page is refused — it cannot truncate a listing at rc 0.
    awk 'b { print } !b && length($0) <= 1 { b = 1 }' "$pf.raw" > "$pf.json"
    # ⛔ THE LINK HEADER IS THE PROVIDER'S OWN STATEMENT about whether another page exists, and it is
    # the only reliable way to separate "the collection ended exactly on a page boundary" (a
    # legitimate empty next page — 100 open issues against a 500 limit) from "the body vanished" (a
    # truncated listing that would otherwise come back rc 0). Row counts alone cannot tell them apart.
    more="$(grep -ci '^link:.*rel="next"' "$pf.raw" 2>/dev/null)"
    case "$(jq -r 'type' < "$pf.json" 2>/dev/null)" in
      array) n="$(jq 'length' < "$pf.json" 2>/dev/null)" ;;
      *)     n="" ;;   # `null` has length 0 — an array TYPE is required, not a numeric length
    esac
    # ⛔ THE STATUS LINE DECIDES WHETHER AN EMPTY BODY IS AN ANSWER. Real `gh api -i` answers an
    # empty collection with headers + `[]`; a 0-byte body on a 200 is a body that VANISHED in transit,
    # and reading it as "no rows" writes an EMPTY `.pr_brs` at rc 0 — the #1705 trigger this block
    # exists to shut (an empty branch list makes `has_pr` false for every issue). Only 204/304 carry
    # no body by definition, so only they may be read as an empty answer.
    status="$(awk 'NR==1{print $2}' "$pf.raw" 2>/dev/null)"
    if [ -z "$n" ] && [ ! -s "$pf.json" ]; then
      case "$status" in
        204|304) n=0 ;;
      esac
    fi
    case "$n" in
      ''|*[!0-9]*)
        if [ ! -s "$pf.json" ]; then
          echo "REST: the $kind listing page $page answered HTTP ${status:-?} with an EMPTY body — a 0-byte body is 'no rows' only when the status says 204; refusing to read it as an empty listing" >&2
        else
          echo "REST: the $kind listing page $page did not answer with a JSON array — refusing to read it as an empty page" >&2
        fi
        rm -rf "$tmp"; return 1 ;;
    esac
    if [ "$n" -eq 0 ] && [ "${more:-0}" -ge 1 ]; then
      echo "REST: the $kind listing page $page answered with 0 rows although the LINK header still advertises a next page — a vanished page is not the end of the collection" >&2
      rm -rf "$tmp"; return 1
    fi
    # ⛔ A SHORT PAGE THAT STILL ADVERTISES A NEXT PAGE IS NOT THE END OF THE COLLECTION EITHER. GitHub
    # returns exactly `per_page` rows on every page but the last, so `rel="next"` together with FEWER
    # rows means the page was filtered or stripped — and returning it at rc 0 is a truncated listing: a
    # short `.pr_brs` un-blacklists issues that already have a PR (#1705).
    # ⛔ THE EXEMPTION IS A FILLED WINDOW, NOT A PAGE POSITION. `page < pages` is FALSE on the last
    # page of every multi-page window, so gating on it would return 440 rows at rc 0 for `--limit 500`
    # with 100 rows on pages 1-4 and 40 on page 5, while page 5 still advertised a next page. The
    # question is not where the page sits but whether the caller's window was FILLED: `want` rows are still missing after this page, so a short page that
    # has more behind it is a truncation — while `--limit 10` against a 40-row page is not (40 >= 10:
    # the window is full, and the next page is one the caller never asked for).
    want=$(( limit - 100 * (page - 1) ))
    if [ "${more:-0}" -ge 1 ] && [ "$n" -lt 100 ] && [ "$n" -lt "$want" ]; then
      echo "REST: the $kind listing page $page returned only $n rows although the LINK header advertises a next page — a short page is not a complete listing" >&2
      rm -rf "$tmp"; return 1
    fi
    if [ "$n" -lt 100 ] || [ "$page" -ge "$pages" ]; then break; fi   # short page, or the window is reached
    page=$((page + 1))
  done
  # ⛔ /issues RETURNS PULL REQUESTS TOO. Left in, a labelled PR becomes a DISPATCH CANDIDATE: the tier
  # programs below only require "no assignee and a non-epic title", so it would be queued as
  # `0 <PR#>`, land in `dispatched.txt`, and get a lane spawned for a PR number the pass never
  # adjudicated as an issue. The REAPER is exposed to the same rows for an unrelated reason —
  # `has_pr` (below) keys on PR head-BRANCH names, not on numbers, so a PR row whose branch does not
  # embed its own number is un-blacklisted exactly like an issue. Issues and PRs share ONE number
  # space per repo, and that is precisely why these rows have to be dropped HERE: nothing downstream
  # can tell a PR row from an issue row.
  # Dropped for `kind=issues` ONLY: `.pr_brs` is kind=pulls and the #1705 `has_pr` check needs those
  # rows. Dropped here ONCE FOR THIS FILE (the gh-rest adapter drops the same rows, `gh-rest/gh:157`;
  # that twin is why BOTH surfaces must be changed together if the rule ever moves). ⛔ `--limit` IS A RAW-ROW BUDGET AND THE PROJECTED TOTAL IS SMALLER — stated with the
  # measurement, because a comment that lies about the window is worse than none: the page budget is
  # `ceil(limit/100)` RAW rows (the loop above), and PRs are dropped only here, so a 500 window
  # returns 500 minus however many pull requests were inside it. Driven against the real API:
  # tortoise `--limit 500` -> 485 rows, agent-infra -> 454, where the pre-change listing returned 500
  # (it excludes pull requests by definition).
  # ⛔ WHAT THAT COSTS, said plainly rather than softened: the endpoint's default order is created
  # DESCENDING (verified against the live API: a 500 read returned 1993 -> 961), so the window keeps
  # the NEWEST rows and an issue pushed out of it does not come back on the next pass — it moves
  # further out as the board grows. That is the opposite end from the one the pool prefers
  # (`sort -k1,1n -k2,2n` at the tier ranking is OLDEST-FIRST), so a repo with more than 500 open
  # issues would lose its oldest ones from `.open_iss` permanently.
  # Accepted for `.open_iss` because that loss only NARROWS: fewer issues are visible to the reaper,
  # so fewer un-blacklists (never more). `.pr_brs` (kind=pulls) is unfiltered, so the #1705 `has_pr`
  # check is unaffected.
  # ⛔ THE TIER WINDOWS HAVE THE SAME SHAPE AND THAT ARGUMENT DOES NOT COVER THEM. They carry
  # `labels=`, so each window is one labelled subset rather than the whole backlog — but it is still a
  # created-DESC window, so a tier with more open labelled issues than its bound puts the OLDEST ones
  # permanently outside `.pool`, and `.pool` is ranked OLDEST-FIRST. Measured 2026-10-17: open
  # `P2-moderate` is 430 on agent-infra against the 200 bound below, so that tier IS over its window.
  # The BOUNDS are unchanged from the GraphQL form (`gh issue list --label … --limit 300/200/200` had
  # the same three windows), so this change neither introduces nor widens the truncation — it is
  # stated here because the paragraph above would otherwise read as "the tiers are complete".
  # The alternative — fetching `limit` PROJECTED rows — means paging past the budget on the shared
  # core bucket this change exists to protect. The gh-rest adapter makes exactly that trade the other
  # way (`gh-rest/gh:229,238` page the whole collection, then `:157` drops PR rows and `:158` slices
  # the projection), so the two surfaces differ deliberately: the adapter bounds its OUTPUT, this
  # helper bounds its SPEND.
  jq -r -s --arg kind "$kind" --argjson limit "$limit" \
     'add // [] | (if $kind == "issues" then map(select(has("pull_request") | not)) else . end) | .[0:$limit] | '"$prog" \
     "$tmp"/p*.json
  n=$?
  # ⛔ A WINDOW THAT ENDED ON ITS LAST PAGE WITH A NEXT PAGE STILL ADVERTISED IS SATURATED, NOT
  # COMPLETE — and the distinction is LOAD-BEARING for any caller that reads ABSENCE from the answer as
  # evidence. `.open_iss` can afford the loss (it only NARROWS, see the two paragraphs above); the
  # product floor's harness-label listing CANNOT, because it classifies a candidate PRODUCT by its
  # ABSENCE from this set — so a harness row pushed out of the window would be classified product and
  # take the floor slot, which is the "never invent a class from a reading that did not answer" polarity
  # inverted. The rc stays 0 (no existing caller's contract changes); the flag is set instead, and the
  # floor's writer falls back to the conservative all-harness arm when it is set.
  REST_WINDOW_FILLED=0
  [ "${more:-0}" -ge 1 ] && REST_WINDOW_FILLED=1
  rm -rf "$tmp"
  return "$n"
}

# ── reap stale dispatch bookkeeping ────────────────────────────────────────────
# `dispatched.txt` is append-only: an issue is recorded as handled the first time it is handed
# to a lane, and nothing re-checks whether that dispatch DELIVERED. A lane that dies (reboot,
# OOM, crash) therefore blacklists its issue forever — invisibly, because the issue stays open
# with no PR. Real cases: #4114, #4095, #3554 sat for >24h. Un-blacklist an entry whose issue is
# still open, has no PR, and has no live lane, so the pre-flight below can re-queue it.
# ⛔ A FAILED listing is NOT an EMPTY one, and the reader below cannot tell them apart. `|| : >
# "$O/.pr_brs"` wrote an EMPTY file when `gh pr list` failed, and an empty `.pr_brs` makes the
# reaper's `has_pr` false for EVERY issue — so a failed listing un-blacklisted open issues that DO
# have a PR. orch-loop.sh skips only what is in dispatched.txt, so it then re-spawned a lane for an
# issue that already had one: duplicate work against the shared queue (agent-infra#1705). Write each
# list only when the listing SUCCEEDS and DELETE it when it fails, so "the read failed" (ABSENT) is
# distinguishable from "the answer is none" (PRESENT but EMPTY). The reaper refuses the whole pass
# unless both are present; a genuinely empty list is still a valid answer and still reaps.
lists_transport_note
if ! rest_list issues --repo "$OR" --state open --limit 500 --jq '.[].number' > "$O/.open_iss" 2>"$O/.list-err"; then
  rm -f "$O/.open_iss"
  echo "[refresh] WARN: open-issue listing FAILED — reaping pass will be skipped (an unreadable listing is not an empty one)"
  [ -s "$O/.list-err" ] && sed -n '1,2p' "$O/.list-err" | sed 's/^/[refresh]   /'
fi
if ! rest_list pulls --repo "$OR" --state all --limit 500 --jq '.[]|.head.ref' > "$O/.pr_brs" 2>"$O/.list-err"; then
  rm -f "$O/.pr_brs"
  echo "[refresh] WARN: PR listing FAILED — reaping pass will be skipped (an unreadable listing is not an empty one)"
  [ -s "$O/.list-err" ] && sed -n '1,2p' "$O/.list-err" | sed 's/^/[refresh]   /'
fi
rm -f "$O/.list-err"
# ⛔ The reap pass REWRITES state (`dispatched.txt`, `checked.txt`) and its status used to be
# discarded, so a failure there left a half-written blacklist or a stale suppression and the pass
# carried on reporting success. Its status is read IMMEDIATELY below — and the invocation line is
# anchored by selftest.sh, which extracts this heredoc body, so its SHAPE is load-bearing:
# `python3 - "$O" "$PRUNE_OR" <<'PY'` carries the EXPLICIT-OR-DERIVED repo slug the landed prune needs
# for `gh issue view <N> --repo <slug>` — never the listings' fallback literal (review P1, cycle 4).
python3 - "$O" "$PRUNE_OR" <<'PY'
import json, os, re, subprocess, sys
O = sys.argv[1]
# The landed prune's repo slug. ABSENT means it cannot ask the authoritative question, and the
# prune then keeps every entry (fail closed per entry) — never assumes closed.
OR = sys.argv[2] if len(sys.argv) > 2 else ""
def lines(name):
    p = os.path.join(O, name)
    return [l.strip() for l in open(p)] if os.path.exists(p) else []
# ⛔ FAIL CLOSED. An ABSENT list means the read FAILED, which is not the same as "the answer is
# none". The capture above deletes the file when `gh` fails, so absence is the failure signal — and
# without this guard `brs == []` makes `has_pr` false for EVERY issue, un-blacklisting open issues
# that DO have a PR; orch-loop.sh (which skips only what is in dispatched.txt) then re-spawns a lane
# for them. Refuse the whole pass and leave the blacklist untouched, so the next cycle retries with a
# live listing. A PRESENT but EMPTY file is a real answer ("no PRs") and is still reaped.
# (agent-infra#1705)
missing = [f for f in (".open_iss", ".pr_brs") if not os.path.exists(os.path.join(O, f))]
if missing:
    print("[reap] SKIPPED: %s not readable — an unreadable listing is not an empty one; blacklist untouched"
          % " ".join(missing))
    raise SystemExit(0)
open_iss = {l for l in lines(".open_iss") if l}
brs = [l for l in lines(".pr_brs") if l]
try:
    out = subprocess.run(["tmux", "ls", "-F", "#{session_name}"], capture_output=True, text=True).stdout
except Exception:
    out = ""
live = {m.group(1) for m in re.finditer(r"^lane-(\d+)$", out, re.M)}
keep, reaped = [], []
for n in lines("dispatched.txt"):
    if not n:
        continue
    if n in live:
        keep.append(n); continue
    has_pr = any(re.search(r"(^|[-/])%s([-/]|$)" % re.escape(n), b) for b in brs)
    if n in open_iss and not has_pr:
        reaped.append(n)
    else:
        keep.append(n)
with open(os.path.join(O, "dispatched.txt"), "w") as fh:
    fh.write("\n".join(keep) + ("\n" if keep else ""))
if reaped:
    gone = set(reaped)
    ck = os.path.join(O, "checked.txt")
    kept = [l for l in lines("checked.txt") if l and l not in gone]
    if os.path.exists(ck):
        with open(ck, "w") as fh:
            fh.write("\n".join(kept) + ("\n" if kept else ""))
    print("[reap] un-blacklisted (open, no PR, no live lane): %s" % " ".join(sorted(reaped, key=int)))

# ── landed.txt: a REPORTED decision, never a second blacklist (tortoise#8560/#8625/#8629) ─────
# `landed.txt` is the LANDED verdicts' home. An entry whose issue is now CLOSED has had its decision
# made, so drop it; otherwise the list would be the invisible permanent suppression checked.txt was,
# clearable only by hand.
#
# ⛔ AN ENTRY WHOSE ISSUE IS *OPEN* IS RELEASED, NOT KEPT. landed.txt is a DURABLE, cross-version
# store: before tortoise#8625 the only persistent producer of LANDED was the timeline title arm on an
# OPEN issue, so every pre-existing entry names an OPEN issue — exactly the issues the tool now
# reports CLEAN. Keeping one would suppress that issue on EVERY pass before its pre-flight ran, the
# "no dismissal path" harm #8625 removed merely pushed into the consumer. Post-#8625 an OPEN entry
# can only mean the issue was reopened since its close-race landing, in which case the work is NOT
# done and suppressing it is a false LANDED. Either way: release, loudly.
#
# ⛔ IT READS THE ENTRY'S OWN STATE — it does NOT infer CLOSED from ABSENCE in the capped
# `.open_iss` listing. `.open_iss` is `--limit 500` against a repo with >500 open issues, so it is
# PERMANENTLY saturated and absence from it proves nothing; an earlier `len(open_iss) < 500` guard
# was a no-op on every pass. The targeted, UNCAPPED `gh issue view <N> --json state` answers the
# actual question.
#
# ⛔ FAIL CLOSED PER ENTRY: an entry whose state cannot be read is KEPT — a failed read never drops a
# suppression that may still be owed. Named in the log, so it is never silent.
lp = os.path.join(O, "landed.txt")
landed_entries = [l for l in lines("landed.txt") if l]

def landed_issue_state(n):
    """The issue's own state, straight from gh — UNCAPPED, and None on ANY failure
    (which the caller reads as "keep the entry", never "closed")."""
    if not OR:
        return None
    try:
        r = subprocess.run(["gh", "issue", "view", n, "--repo", OR,
                            "--json", "state"], capture_output=True, text=True)
        if r.returncode != 0:
            return None
        state = json.loads(r.stdout).get("state")
    except Exception:
        return None
    if not isinstance(state, str):
        return None
    return state.strip().upper() or None

if landed_entries:
    still_landed, released, settled, unreadable = [], [], [], []
    for n in landed_entries:
        state = landed_issue_state(n)
        if state == "CLOSED":
            settled.append(n)
        elif state == "OPEN":
            released.append(n)
        else:
            still_landed.append(n)
            unreadable.append(n)
    if os.path.exists(lp):
        with open(lp, "w") as fh:
            fh.write("\n".join(still_landed) + ("\n" if still_landed else ""))
    if settled:
        print("[reap] landed list: decision made (issue CLOSED), dropped: %s"
              % " ".join(sorted(settled, key=int)))
    if released:
        print("[reap] landed list: issue is OPEN — RELEASED (a pre-#8625 entry came from the timeline "
              "title arm on an OPEN issue, which would otherwise suppress a now-authorized issue "
              "forever): %s" % " ".join(sorted(released, key=int)))
    if unreadable:
        print("[reap] landed list: %d entr(ies) could not be re-read — KEPT, not assumed closed: %s"
              % (len(unreadable), " ".join(sorted(unreadable, key=int))))
PY
reap_rc=$?
if [ "$reap_rc" -ne 0 ]; then
  echo "[refresh] ABORT: the reap pass failed — refusing to carry on over a half-rewritten blacklist (#1736)"
  exit "$EXIT_TRANSIENT"
fi
for f in "$O/.open_iss" "$O/.pr_brs"; do rm -f "$f"; done

# ── NOW THAT THE BLACKLIST IS PRUNED, CAN THIS PASS AFFORD ANYTHING AT ALL? (#1736 follow-up) ────
# ⛔ THIS GATE IS DELIBERATELY **LATE — BELOW THE REAPER — AND NOT AT THE TOP OF THE PASS.** It used
# to sit immediately after `gh_env_verdict`, where refusing genuinely cost zero calls, and “zero
# calls” was the wrong thing to optimise. MEASURED shape (agent-infra#1736 follow-up review): on a
# starved box the pass exited BEFORE the reaper above ever ran, so the one piece of housekeeping that
# UN-BLACKLISTS a dispatched issue that is still open, has NO PR and no live lane stopped happening
# exactly when the box was too poor to do anything else — and the reaper's own note states that this
# is the only thing that ever removes such an entry, so the entry stayed until the bucket recovered
# and `orch-loop.sh` (which skips only what `dispatched.txt` names) never re-dispatched it.
# So the pass now pays the reaper's two listings (each `rest_list` page is ~1 core call; the two
# captures are what the reaper's `has_pr`/`open_iss` test needs) UNCONDITIONALLY, whatever the budget
# says, and refuses AFTER them. What it still does NOT do when starved is the expensive half — the
# three priority-tier listings (~40 calls) and any pre-flight run. The refusal is therefore ~2 calls
# dear, not free, and that is the trade: the cheap call that keeps the blacklist honest, then stop.
# ⛔ `queue_state_write` CANNOT MOVE UP HERE WITHOUT INVENTING A READING. `EMPTY`/`READ(<n>)`/
# `PARTIAL(<t>)`/`UNREADABLE` are statements about the pool LISTING, which happens below this line;
# writing one from a pass that never listed would be the false report that state exists to prevent
# (and `UNREADABLE` would then be indistinguishable from a real blind read). The heartbeat keeps the
# PREVIOUS reading together WITH ITS AGE (`orch-loop.sh`'s `queue_state_token`), so a frozen value
# cannot pass as a fresh one — which is what makes leaving it stale honest rather than silent.
# ⛔ ONE candidate AND the reserve must fit, or this pass would spend its last calls to judge a
# handful and produce no usable verdict at all.
if [ "$CORE_PACING" -eq 1 ]; then
  if CORE_NOW="$(core_remaining)"; then
    if [ "$CORE_NOW" -lt $(( CORE_RESERVE + CORE_PER_CANDIDATE )) ]; then
      echo "[refresh] ABORT: REST core budget remaining=$CORE_NOW cannot buy one candidate without eating the reserve=$CORE_RESERVE (~$CORE_PER_CANDIDATE per candidate) — this pass ran NOTHING of the pool and judged NOTHING, so an empty backlog would be a false report (#1736). The dispatched.txt reaper HAS run (that is why the refusal is here and not earlier); the pool is left untouched and the next cycle retries."
      exit "$EXIT_TRANSIENT"
    fi
    echo "[refresh] budget: REST core remaining=$CORE_NOW, reserve=$CORE_RESERVE, ~$CORE_PER_CANDIDATE per candidate — up to $(( (CORE_NOW - CORE_RESERVE) / CORE_PER_CANDIDATE )) candidate(s) affordable this pass (limit $LIMIT)"
  else
    echo "[refresh] WARN: the REST core budget could not be read — pacing is OFF for this pass (it will not be starved on an unreadable metric). The pre-flight's own fail-closed rules still decide every verdict."
  fi
fi

touch "$O/checked.txt" "$O/candidates.txt" "$O/landed.txt"

# pool = open unassigned P0-blocker ∪ P1-severe ∪ P2-moderate, minus epics/owner-decisions
#
# ⛔ SEVERITY FIRST, AGE SECOND. Each tier emits "<tier> <number>" and the sort keys on the tier
# before the number. A bare `sort -n` over the numbers ALONE ordered by ISSUE NUMBER — i.e. oldest
# first — discarding the tier the three queries had just computed. Measured 2026-10-13: 238
# pool-eligible P2-moderate sat ahead of 20 pool-eligible P0-blocker, so the P0s were unreachable
# and every worker the harness ran was a P2 (#8465). The tier is a RANK, not a label.
# Dedupe on the NUMBER, keeping the lowest tier: the sort already put an issue's best tier first, so
# `!seen[$2]++` drops the later, weaker duplicate rather than letting one issue occupy two slots.
# ⛔ EACH QUERY RECORDS ITS OWN FAILURE, so a partial listing is detected too. Depending on the
# pipeline's status cannot work — the group reports only its LAST command's, and `pipefail` would not
# fix it — and a re-read of the listing is NOT the same question: this pipeline's queries carry
# `--label` and a `--jq`, so a failure confined to those succeeds on a plain re-read. Measured: a
# broken `--jq` fails the pool query while `gh issue list … --json number` still exits 0, and one
# failing tier with another returning rows leaves `.pool` NON-EMPTY — so an emptiness test never fires
# and that whole priority tier silently disappears into a "healthy" backlog, the #8465 priority
# inversion this sort exists to prevent (#1853 review). The sentinel is a real file write from the
# pipeline's subshell, so the parent sees it.
# ⛔ EACH QUERY RECORDS WHICH WAY IT WENT, not only when it failed. `.pool-read` gets the tier
# that ANSWERED (even with zero rows), `.pool-err` the tier that did not — so UNREADABLE (nothing
# answered) is a fact the parent can check rather than an inference from an empty error file, and
# PARTIAL can NAME the tiers that were read instead of only the ones that failed.
rm -f "$O/.pool-err" "$O/.pool-read"
{
  if rest_list issues --repo "$OR" --state open --limit 300 --label P0-blocker \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|lane|OWNER DECISION|decision|analysis|investigation)";"i")|not)|"0 \(.number)"' 2>>"$O/.pool-err"; then echo "P0-blocker" >> "$O/.pool-read"
  else echo "P0-blocker" >> "$O/.pool-err"; fi
  if rest_list issues --repo "$OR" --state open --limit 200 --label P1-severe \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|OWNER DECISION)";"i")|not)|"1 \(.number)"' 2>>"$O/.pool-err"; then echo "P1-severe" >> "$O/.pool-read"
  else echo "P1-severe" >> "$O/.pool-err"; fi
  if rest_list issues --repo "$OR" --state open --limit 200 --label P2-moderate \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|OWNER DECISION)";"i")|not)|"2 \(.number)"' 2>>"$O/.pool-err"; then echo "P2-moderate" >> "$O/.pool-read"
  else echo "P2-moderate" >> "$O/.pool-err"; fi
# ⛔ ONE SORTED STREAM, ONE ARTIFACT. The rank map goes FIRST into the key (`-k1,1n`) and the
# number is what is emitted, so the pool is priority-ordered, oldest-first inside a tier. (The fork's
# `.prio`/`<number>TAB<rank>` second artifact existed only for BP0's P0 override; see the NOTE below.)
} | sort -k1,1n -k2,2n | awk '!seen[$2]++ {print $2}' > "$O/.pool"
# ⛔ AN UNWRITTEN POOL IS NOT AN EMPTY ONE, and the test for it is the redirect's STATUS, not the
# FILE's existence: a `.pool` left behind by an earlier run satisfied a `[ -f ]` test while THIS run's
# redirect failed, and the stale pool was then read as the backlog of a run that persisted nothing —
# `checked N; backlog now M` at rc 0 (#1853 review). The status is read IMMEDIATELY, with no `$(...)`
# in between, and this is its OWN statement on purpose: selftest.sh extracts the line above VERBATIM
# (`grep -E '^\} \| sort '` + a sed that strips a trailing ` > "$O/.pool"`), so a suffix on that line
# turns the extracted pipeline into a syntax error and reddens the #8465 severity-ordering check —
# which would then stop covering the very ordering the pool depends on.
#
# NOTE (BP0, tortoise#8468 — reconciled onto main): the fork's `.prio` rank map existed ONLY for
# orch-loop's P0 merge-priority override, which main's unconditional drain rule (owner ruling,
# 2026-10-18) replaced. The pool stream therefore stays a SINGLE artifact again, as on main.
pool_rc=$?

# ── THE POOL'S READ STATE: EMPTY, PARTIAL or UNREADABLE (agent-infra#1931) ────────────────────
# ⛔ A LAYER THAT CANNOT SEE MUST NOT REPORT AN EMPTY QUEUE. Measured 2026-10-17: a cell whose pool
# listing failed refused correctly on 131 consecutive passes and dispatched nothing while 15 PRs sat
# open — and `backlog=0` in the controller's cycle line was indistinguishable from a fleet with
# nothing to do. So the read's outcome is now a NAMED state, in ONE vocabulary, and `EMPTY` is
# reserved for the only answer that may ever mean "no work":
#   EMPTY         every priority tier was READ, and the pool listed no dispatchable issue.
#   READ(<n>)     every priority tier was read, and n candidate(s) were listed. A non-empty pool is
#                 never labelled EMPTY; it is a third, plainly-different readable answer.
#   PARTIAL(<t>)  some tiers were read and <t> were NOT — the survivors are a SUBSET, never a
#                 complete pool, so nothing is queued from it (#1736).
#   UNREADABLE    NO tier could be read. The fleet is BLIND to the backlog, and that is not "nothing
#                 to do" — it is the state this whole change exists to make visible.
# The state is persisted WITH the epoch of the read, so the controller's heartbeat line can carry it
# (orch-loop.sh's queue_state_token prints it together with its age, so a frozen value cannot pass
# as a fresh one). It is the READ's state, not the backlog's: it stays true even when a later step of
# this pass refuses, and it never overrides the fail-closed refusals below.
QUEUE_STATE_FILE="$O/state/queue-state"
queue_state_write() {  # <STATE> — record what THIS pass learned about the pool, for the heartbeat
  mkdir -p "$O/state" 2>/dev/null
  if ! printf '%s %s\n' "$1" "$(date +%s)" > "$QUEUE_STATE_FILE" 2>/dev/null; then
    # NOT fatal on purpose: this is the REPORTING contract, not the gate. The pass still refuses or
    # queues exactly as before; what is lost is the heartbeat's copy of the state, and it says so
    # rather than leaving a previous pass's reading standing in for this one.
    echo "[refresh] WARN: cannot record the pool read state into $QUEUE_STATE_FILE — the heartbeat will not carry whether this pass could SEE the pool (agent-infra#1931)"
  fi
}
# Which of the three tiers answered. A tier that recorded NEITHER outcome did not answer, so it
# counts as FAILED: a read whose outcome cannot be proven is not a read (fail-closed).
POOL_READ=""; POOL_FAILED=""
for _tier in P0-blocker P1-severe P2-moderate; do
  if grep -qx "$_tier" "$O/.pool-read" 2>/dev/null; then POOL_READ="$POOL_READ $_tier"
  else POOL_FAILED="$POOL_FAILED $_tier"; fi
done
POOL_READ="${POOL_READ# }"; POOL_FAILED="${POOL_FAILED# }"

if [ "$pool_rc" -ne 0 ]; then
  # The listing ran but could not be CAPTURED, so this pass has no pool it can trust — blind, not empty.
  queue_state_write "UNREADABLE"
  echo "[refresh] queue=UNREADABLE — the pool listing could not be CAPTURED into $O (rc=$pool_rc), so this pass is blind to the backlog; that is not \"nothing to do\" (agent-infra#1931)"
  echo "[refresh] ABORT: cannot write the candidate pool into $O — the pool this pass would read is not the one it just listed"
  exit "$EXIT_TRANSIENT"
fi

# ⛔ AN UNREADABLE POOL IS NOT AN EMPTY ONE. TRANSIENT on purpose: the failure says nothing about
# WHICH host would come back, and a marker only a human can clear must not be latched on a guess.
# The state is written and printed BEFORE the abort, so the refusal and the heartbeat agree.
if [ -n "$POOL_FAILED" ]; then
  if [ -n "$POOL_READ" ]; then
    # The argument names the tiers that could NOT be read, comma-joined (no spaces: the token is one
    # field in a log line a human and a grep both read).
    POOL_STATE="PARTIAL($(printf '%s' "$POOL_FAILED" | tr ' ' ','))"
    queue_state_write "$POOL_STATE"
    echo "[refresh] queue=$POOL_STATE — the pool listing could not be read for $POOL_FAILED (read: $POOL_READ), so the survivors are a SUBSET, not a complete pool, and nothing is queued from it (#1736, agent-infra#1931)"
    # The refusal says which of the two shapes it is: a partial pool, or no pool at all.
    echo "[refresh] ABORT: the candidate pool listing FAILED for $POOL_FAILED — a partial pool is not a backlog (#1736)"
  else
    POOL_STATE="UNREADABLE"
    queue_state_write "$POOL_STATE"
    echo "[refresh] queue=$POOL_STATE — NO priority tier could be read ($POOL_FAILED FAILED), so the fleet is BLIND to the backlog; \"no candidates\" here is NOT \"nothing to do\" (agent-infra#1931)"
    echo "[refresh] ABORT: the candidate pool listing FAILED for $POOL_FAILED — no tier could be read, so there is NO pool to dispatch from (#1736)"
  fi
  sed -n '1,6p' "$O/.pool-err" | sed 's/^/[refresh]   /'
  rm -f "$O/.pool-err" "$O/.pool-read"
  exit "$EXIT_TRANSIENT"
fi
rm -f "$O/.pool-err" "$O/.pool-read"
# Every tier was read, so EMPTY is now an admissible answer — and the ONLY one that may say "no work".
POOL_ROWS="$(wc -l < "$O/.pool" 2>/dev/null | tr -d ' ')"
case "${POOL_ROWS:-}" in
  ''|*[!0-9]*)
    # The pool was just written at rc 0, so an unreadable row count means the file is gone or was
    # replaced under us. UNKNOWN is not empty: refuse rather than report a backlog nobody counted.
    queue_state_write "UNREADABLE"
    echo "[refresh] queue=UNREADABLE — the pool was written but its row count could NOT be read, so this pass cannot say what it listed; that is not \"nothing to do\" (agent-infra#1931)"
    echo "[refresh] ABORT: cannot count the candidate pool at $O/.pool — refusing to report a backlog this pass did not measure (#1736)"
    exit "$EXIT_TRANSIENT" ;;
esac
if [ "$POOL_ROWS" -eq 0 ]; then
  POOL_STATE="EMPTY"
  echo "[refresh] queue=$POOL_STATE — every priority tier was READ and listed no dispatchable issue: this pass can SEE the pool, and it is genuinely empty (agent-infra#1931)"
else
  POOL_STATE="READ($POOL_ROWS)"
  echo "[refresh] queue=$POOL_STATE — every priority tier was READ; $POOL_ROWS candidate(s) listed (agent-infra#1931)"
fi
queue_state_write "$POOL_STATE"

# ── DID ANYTHING THE PASS READS ACTUALLY MOVE? (agent-infra#1984, cause 2) ─────────────────────
# The pass runs whenever the backlog is short — every cycle, i.e. far more often than the fleet's
# state changes. Measured (counting shim, agent-infra): 14 core requests per pass are the listings
# themselves and, before the per-pass read memo (#1984 cause 1) and the board cache (#2022/#2050),
# another ~120 were the SAME fleet reads and the SAME verdicts re-derived for the SAME candidates.
# At a five-minute cadence that is the ~1,150 core calls/hour of pure re-reading the issue measures.
#
# The cheap part must keep running: the listings ARE the question "did anything change?". What is
# skipped here is the EXPENSIVE part — the per-candidate pre-flight — and only when its inputs are
# byte-identical to the pass that just exhausted them.
#
# ⛔ "UNCHANGED" IS NOT "UNREADABLE", AND THIS BLOCK IS WRITTEN SO THEY CANNOT BE CONFUSED. It sits
# BELOW every refusal: a pool that was PARTIAL or UNREADABLE has already exited (above), so nothing
# reaching here was inferred from a failed read. On top of that, the token stores the READ STATE it
# was written under (`READ(n)`/`EMPTY`) and a skip requires that state to match too — so a pass that
# read the pool and a pass that could not read it can never produce the same `unchanged` conclusion.
# A missing, unparsable, or foreign token is a MISS (run the pass), never a skip: the failure
# direction of this gate is "do the work", because the work is what discovers the state.
#
# ⚠️ THE RESIDUAL, STATED: a COLLISION is retried next pass because a claim is a window, and while a
# skip is in force that retry waits up to SKIP_TTL. That is the deliberate trade — 300 s is one
# fleet-board TTL and the delay is bounded and named in the skip line — and it is why the TTL is a
# SEAM: a fleet that needs faster collision retries lowers it, at the cost of re-reading more often.
#
# ⛔ AND "WE SKIPPED" IS NOT "THERE IS NO WORK". Nothing in candidates.txt or checked.txt is read
# or written by a skip, and the line below says `queue=READ(n)` first and `SKIPPED` second. #1736's
# vocabulary is preserved: READ/EMPTY describe the queue, this describes the READER's decision.
#
# The token is written TWICE: `<digest> <epoch> <state> 0` BEFORE the loop and `… 1` after it only
# when the loop exhausted the pool. So an interrupted pass (SIGKILL, a cycle timeout, a budget
# abort) leaves `0` behind and the next pass always runs — a half-run pass can never be mistaken for
# a completed one. That is the same "a stale flag that records a past state and is never revalidated"
# defect this fleet has been bitten by, closed by construction rather than by a rule.
POOL_TOKEN="$O/state/pool-token"
SKIP_TTL="${REFRESH_UNCHANGED_SKIP_TTL:-300}"
case "$SKIP_TTL" in ''|*[!0-9]*) SKIP_TTL=300 ;; esac
# SHA-256 when the box has it (`sha256sum` on the cells, `shasum` on the Mac), `cksum` otherwise.
# Any of the three answers the only question asked — "is this the same bytes as last time?" — and a
# keyed-hash collision here is not an attack surface: the inputs are this box's own files, and the
# worst case of a collision is that a pass SKIPS work it would have repeated.
pool_digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else cksum | cut -d' ' -f1; fi
}
# ⛔ landed.txt IS PART OF "WOULD THE ANSWER BE THE SAME". A pass that just RELEASED a landed entry
# (its issue is readable-OPEN) or recorded one has changed which candidates are dispatchable, so a
# digest that omitted it could skip the very pass that would act on that change.
POOL_DIGEST="$(
  { cat "$O/.pool" 2>/dev/null; printf '\036'
    cat "$O/checked.txt" 2>/dev/null; printf '\036'
    cat "$O/dispatched.txt" 2>/dev/null; printf '\036'
    cat "$O/landed.txt" 2>/dev/null; } | pool_digest 2>/dev/null
)"
case "${POOL_DIGEST:-}" in
  ''|*[!0-9a-fA-F]*) POOL_DIGEST="" ;;   # unreadable digest => never "unchanged"
esac
pool_token_write() {  # <exhausted:0|1> — see the two-phase write above
  [ -n "$POOL_DIGEST" ] || return 0
  mkdir -p "$O/state" 2>/dev/null
  printf '%s %s %s %s\n' "$POOL_DIGEST" "$(date +%s)" "$POOL_STATE" "$1" > "$POOL_TOKEN" 2>/dev/null || \
    echo "[refresh] WARN: cannot record the pass token at $POOL_TOKEN — the next pass will not know this listing was already swept (#1984)"
}
# ── THE COLLISION LEDGER'S PATH AND TTL — DEFINED HERE BECAUSE THE SKIP BELOW MUST READ IT ──────
# (agent-infra#1729's ledger; its reader and writer are below, with the rest of the loop's state.)
COLLISION_LEDGER="$O/state/collided"
COLLISION_TTL="${POOL_COLLISION_TTL:-900}"
case "$COLLISION_TTL" in ''|*[!0-9]*) COLLISION_TTL=900 ;; esac
# ⛔ A SKIP MUST NEVER STARVE A COLLISION RETRY (agent-infra#1729 × #1984). The digest above covers
# `.pool`, `checked.txt` and `dispatched.txt` — NOT the ledger — so two passes can be byte-identical
# in every file this gate reads while a ledger record EXPIRED between them, i.e. while the answer
# would NOT be the same: re-judging that candidate is exactly what the next pass is for. So the skip
# is additionally gated on the ledger holding ONLY records that are still live AND plausible — the
# same two conditions the reader below applies before it will walk past a record (a corrupt or
# absurd-future record is re-judged there, so it must disable the skip here too). Every other case
# runs the pass; the cost of being wrong in this direction is one pass, and the cost of being wrong
# in the other is #1716's contract (a collision DEFERRED, never dropped).
ledger_all_live() {
  [ -r "$COLLISION_LEDGER" ] || return 0
  local _n _e _i _max
  _n="$(date +%s 2>/dev/null || echo 0)"
  case "$_n" in ''|*[!0-9]*) return 1 ;; esac
  _max=$(( _n + COLLISION_TTL * 2 ))
  while read -r _e _i; do
    [ -n "${_i:-}" ] || continue
    case "$_e" in ''|*[!0-9]*) return 1 ;; esac   # corrupt => re-judged => no skip
    [ "$_e" -gt "$_n" ] || return 1               # EXPIRED => re-judged => no skip
    [ "$_e" -le "$_max" ] || return 1             # ABSURD future => corruption => no skip
  done < "$COLLISION_LEDGER"
  return 0
}
# The previous pass's record, parsed strictly. Four fields, all required, none guessed.
PREV_DIGEST=""; PREV_EPOCH=""; PREV_STATE=""; PREV_EXHAUSTED=""
if [ -r "$POOL_TOKEN" ]; then
  read -r PREV_DIGEST PREV_EPOCH PREV_STATE PREV_EXHAUSTED < "$POOL_TOKEN" 2>/dev/null || true
fi
case "${PREV_EPOCH:-}" in ''|*[!0-9]*) PREV_EPOCH="" ;; esac
if [ -n "$POOL_DIGEST" ] && [ "${PREV_DIGEST:-}" = "$POOL_DIGEST" ] \
   && [ "${PREV_STATE:-}" = "$POOL_STATE" ] && [ "${PREV_EXHAUSTED:-}" = "1" ] \
   && [ -n "$PREV_EPOCH" ] && ledger_all_live; then
  NOW_EPOCH="$(date +%s)"
  case "${NOW_EPOCH:-}" in ''|*[!0-9]*) NOW_EPOCH=0 ;; esac
  AGE=$(( NOW_EPOCH - PREV_EPOCH ))
  if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$SKIP_TTL" ]; then
    echo "[refresh] queue=$POOL_STATE unchanged for ${AGE}s (digest ${POOL_DIGEST%${POOL_DIGEST#????????}}, ttl ${SKIP_TTL}s) — the pool, checked.txt and dispatched.txt are byte-identical to a pass that swept every candidate and left nothing unattempted, so this pass SKIPS the per-candidate pre-flight (#1984). Nothing was queued and nothing was judged: this is not \"no work\", it is \"the answer would be the same\", and candidates.txt/checked.txt are untouched."
    exit 0
  fi
fi
# From here the pass IS going to run, so its own outcome is recorded: `0` until the loop proves it
# got to the end of the pool.
pool_token_write 0

n=0
# `usable` counts the verdicts the pre-flight produced that the caller can act on: CLEAN, COLLISION,
# and LANDED. NOT counted: an INCOMPLETE run, a DEGRADED `COLLISION ... ALSO INCOMPLETE` (the tool
# answering from partial evidence — the broken-environment fingerprint this gate exists to catch),
# and a run that emitted no VERDICT at all. See the property assertion after the loop.
usable=0
# ── TWO BUDGETS: `n` IS SLOTS FILLED, `judged` IS PRE-FLIGHT RUNS (agent-infra#1729) ─────────────
# `n` counts the SLOTS this pass filled, and a slot is filled ONLY by a verdict that MOVES THE HEAD:
# CLEAN (queued, and `checked.txt` then retires it from every later pass) or LANDED (the issue left
# the pool by itself). A COLLISION, an INCOMPLETE, a DEGRADED answer or a verdict-less run fills NO
# slot — that candidate stays exactly where it was in `$O/.pool`.
# ⛔ WHY THE DISTINCTION IS THE FIX. `n` used to be incremented for every candidate the loop TOUCHED,
# so `$LIMIT` consecutive candidates a peer held consumed the WHOLE window. MEASURED on the live
# controller, four consecutive passes (orch-loop.log, 2026-10-18):
#     queue=READ(200) … =#8486 =#8488 =#8999 =#7773 =#8083 =#8084 collision … checked 6; backlog now 0
# — the SIX lowest-numbered candidates, every one of them held by a peer, every pass, forever, while
# 194 other candidates were never examined (`candidates.txt` pinned at 0 lines). The intake was not
# blind (READ(200) is honest); it was starved by a cursor that could never advance: `$O/.pool` is
# rebuilt `tier, then number` on every pass, nothing rotated it, and a collision is deliberately left
# UNCHECKED so the same six sat at the head again. `COLLISION` counts as `usable`, so even the
# "judged NOTHING" abort below stayed quiet and the pass read as healthy while it queued nothing.
# ⛔ SO A PASS WALKS PAST A CANDIDATE IT CANNOT MOVE, bounded by `RUN_BUDGET` pre-flight RUNS — a
# hard cost bound, because each run is a network call against a rate-limit bucket four boxes share.
# A healthy pass still stops after `$LIMIT` slots and costs exactly what it did before; only a
# blocked head spends the allowance, and only to reach the candidates behind it.
judged=0
RUN_BUDGET=$(( LIMIT * 2 ))
degraded=0
# Issue-claim outcomes for THIS pass, so a run whose registry answered nothing can NAME the registry
# instead of looking like a healthy cell with an empty pool (2026-10-16 review: `lanes: 0` and an
# unreadable registry were indistinguishable from the outside, and the per-issue lines scroll away).
ICR_INCOMPLETE=0; QUEUED=0
# 1 only while the loop is still going to reach the end of the pool. Every `break` below clears it,
# because a pass that stopped early (LIMIT, budget) has NOT swept the pool and must not license the
# next pass to skip (#1984 cause 2).
POOL_SWEPT=1
# ── CLAIM-DRIVEN OUTCOMES, COUNTED (agent-infra#2094) ──────────────────────────────────────────
# Two different things a claim does to this pass, and they must never print the same line:
#   ICR_HELD      a peer's LIVE claim withheld the candidate, so it is NOT queued — a pool full of
#                 these ends the pass at `backlog now 0`, the healthiest-looking line this script can
#                 print and the one the incident produced over 192 readable candidates.
#   ICR_RECLAIMED the only claim on the candidate was ORPHANED, so it WAS queued (the registry's
#                 pre-flight returns CLEAN for a holder that cannot be a live lane, agent-infra#2094).
#                 That is the incident's repair happening, and it used to leave no trace at all.
# ⛔ NEITHER LINE CLAIMS AN ACTION THIS SCRIPT DID NOT TAKE. The refresh READS the registry; the CAS is
# won (or lost) later by orch-loop's `claim_issue_acquire`. So the wording is "queued because the only
# claim is orphaned", never "reclaimed" — a comment reporting an effect the code did not produce is the
# false-green class this file has been fixed for.
# ⛔ THE ORPHAN TOKEN ONLY APPEARS ON THE CLEAN/PRE-FLIGHT-RECLAIM PATH. Counting it in the
# COLLISION arm — which is unreachable for it, because the pre-flight returns 0 — would print a
# column that is always 0 as though it were a measurement (#1931's rule: the absence of a
# measurement is not a measurement of emptiness).
ICR_HELD=0; ICR_RECLAIMED=0

# ── THE COLLISION LEDGER: what this pass — and the last TTL of passes — knows is HELD ────────────
# Walking past a blocked head fixes ONE pass; with no record, the NEXT pass starts at the same head
# and re-buys the same six collisions — six network runs a pass on a bucket four boxes share
# (measured on the live controller: core remaining fell 3684 -> 3249 -> 2931 -> 2397 over three
# passes). So a COLLISION is recorded with the epoch at which that record expires, and a later pass
# walks past it for free.
# ⛔ WHAT MAKES IT SAFE. (1) It can only skip a PRE-FLIGHT, never a dispatch: a skipped candidate is
# left exactly where a COLLISION leaves it — unqueued, un-`checked`, still in the pool. (2) Every
# record EXPIRES (`POOL_COLLISION_TTL`, 900 s) and expired records are dropped on the next write, so
# a collision is DEFERRED, never dropped — #1716's contract that a held candidate is retried on a
# later pass holds, and the worst a stale record can cost is one TTL of delay on work a peer holds.
# (3) ONLY `COLLISION` IS RECORDED. A DEGRADED answer, an INCOMPLETE registry and a verdict-less run
# are ENVIRONMENT failures, not peer collisions: suppressing those for a TTL would hide the
# merge-only / starved-read defect this script exists to surface (#1736). They still get the in-pass
# skip-ahead, so they cannot consume the whole window either — they are re-judged next pass, loudly.
# (4) An ABSENT or UNREADABLE ledger means "nothing is known to be held": the conservative direction
# is to pre-flight a candidate again (one wasted run), never to skip one on evidence nobody read.
COLLIDED_FRESH=" "      # space-hedged, so `case … in *" $N "*)` cannot match a substring of a number
COLLIDED_NEW=""         # numbers THIS pass found held by a peer
# ── THE FUNNEL'S PER-REASON COUNTS (agent-infra#2040) ───────────────────────────────────────────
# `queue=READ(223)` beside `[dispatch] backlog empty` is a CONTRADICTION that hid a total dispatch
# stop for hours on every cloud cell: the pool was read (223 candidates), the backlog was empty, and
# nothing in the log said which step ate the 223. Each arm below therefore counts itself, and the
# pass writes ONE machine-readable line (state/refresh-funnel) that orch-loop.sh prints as the
# dispatch funnel. The counts SUM to the pool: listed = skipped_checked + skipped_dispatched +
# skipped_landed + skipped_collided + judged + not_reached, and judged = queued + collision +
# landed + unjudged. A count that cannot be reconciled is not published as a decomposition (see the
# assertion after the loop).
# ⛔ `skipped_landed` IS IN THE SUM AND MUST BE NAMED HERE TOO (review P2, cycle 9): the writer, the
# reader (`orch-loop.sh`) and ARCHITECTURE.md all learned the key in this PR; this sentence — the one a
# reconciler actually follows when the parts do not add up — did not, and would have sent them looking
# for a missing count that this file subtracts correctly.
# ⛔ EVERY WAY A ROW LEAVES THE FUNNEL WITHOUT BEING JUDGED HAS ITS OWN COUNTER (review finding
# P2-1). `not_reached` is DERIVED (listed − the skip buckets − judged), so a walk-past arm with no
# counter of its own silently lands in `not_reached` — and orch-loop.sh RENDERS that bucket as
# `N not reached (limit)`, the one reading that tells an operator to raise `LIMIT`. On a four-box
# fleet with a fresh collision ledger the ordinary case is walking past dozens of peer-held
# candidates, so the derived number was dominated by peer-held work while `limit=` sat at its real
# value beside it — the same class of false statement (`backlog empty queue=READ(223)`) this funnel
# was added to end. The collision walk-past therefore counts HERE, in its own bucket, and is
# subtracted before `not_reached` is derived. `skipped_landed` (this branch) and `skipped_collided`
# (main, #2040 follow-up) are INDEPENDENT buckets: a landed candidate was never judged, a collided
# one was deferred unjudged, and either can occur without the other — so BOTH are in the sum.
SKIP_CHECKED=0; SKIP_DISPATCHED=0; SKIP_LANDED=0; SKIP_COLLIDED=0
V_QUEUED=0; V_COLLISION=0; V_LANDED=0; V_UNJUDGED=0
skipped=0               # candidates walked past because a recent pass already found them held
_now="$(date +%s 2>/dev/null || echo 0)"
# ⛔ A RECORD MAY NOT DEFER A CANDIDATE FOR LONGER THAN A TTL. This script only ever writes
# `now + TTL`, so an expiry further out than `2 × TTL` is CORRUPTION (a truncated or hand-edited
# file), and the conservative direction is to judge the candidate again — never to let a stale flag
# suppress work for ever. The bound is derived locally, so a bad record requires no cleanup.
_max="$(( _now + COLLISION_TTL * 2 ))"
if [ -r "$COLLISION_LEDGER" ]; then
  while read -r _exp _iss; do
    [ -n "${_iss:-}" ] || continue
    case "$_exp" in ''|*[!0-9]*) continue ;; esac   # a corrupt record is not evidence of a block
    [ "$_exp" -gt "$_now" ] || continue             # EXPIRED => judged again, i.e. never dropped
    [ "$_exp" -le "$_max" ] || continue             # ABSURD future => corruption => judged again
    COLLIDED_FRESH="$COLLIDED_FRESH$_iss "
  done < "$COLLISION_LEDGER"
fi
while read -r N; do
  [ -z "${N:-}" ] && continue
  if grep -qx "$N" "$O/checked.txt" 2>/dev/null; then SKIP_CHECKED=$((SKIP_CHECKED + 1)); continue; fi
  if grep -qx "$N" "$O/dispatched.txt" 2>/dev/null; then SKIP_DISPATCHED=$((SKIP_DISPATCHED + 1)); continue; fi
  # ⛔ A LANDED ISSUE IS SUPPRESSED, NOT BLACKLISTED, AND THE SKIP SITS BEFORE THE SLOT COUNTER so a
  # recorded entry costs no LIMIT slot on later passes (tortoise#8560). Reported in the tail of every
  # pass; the reaper releases it once its issue is readable-OPEN and drops it once CLOSED.
  if grep -qx "$N" "$O/landed.txt" 2>/dev/null; then SKIP_LANDED=$((SKIP_LANDED + 1)); continue; fi
  # ⛔ STOP ON SLOTS FILLED, OR ON RUNS SPENT — never on "candidates touched". These are the TWO
  # budgets this pass has, and they bound DIFFERENT things: `$LIMIT` slots (a slot is filled only by
  # a verdict that MOVES the head), and `$RUN_BUDGET` pre-flight RUNS (a slot may take many runs to
  # fill when the head is blocked, and every run is a network call on a bucket four boxes share).
  # Neither is "candidates touched" — that equality is #1729.
  # ⛔ AND THESE TWO TESTS SIT ABOVE THE LEDGER SKIP, NOT BELOW IT (#1729 review, P1). Below it, once
  # the slots were full every remaining COLLIDED candidate still reached the skip arm and printed a
  # `>#N SKIPPED` line until the next non-collided candidate happened to break the loop — with a
  # large ledger that is an unbounded block of log noise per pass. The skip arm is a WALK-PAST; it
  # must never outrank the stop conditions.
  [ "$n" -ge "$LIMIT" ] && { POOL_SWEPT=0; break; }
  [ "$judged" -ge "$RUN_BUDGET" ] && { POOL_SWEPT=0; break; }
  # A candidate a recent pass already found HELD is walked past at NO network cost. It is NOT written
  # to `checked.txt`: when the record expires the normal path judges it again (ledger note above).
  # ⛔ DELIBERATELY ABOVE THE BUDGET PROBE BELOW: a skip costs no network at all, so a held candidate
  # must not spend the pass's `rate_limit` read merely to discover it is free to walk past. Skipping
  # can never let a pass run away — every candidate it walks past is one the loop would not have
  # judged anyway, and the walk ends at the end of the pool.
  case "$COLLIDED_FRESH" in
    *" $N "*)
      skipped=$((skipped + 1))
      # ⛔ AND THE FUNNEL COUNTS IT (review finding P2-1): `skipped` feeds the human summary below,
      # SKIP_COLLIDED feeds the decomposition. Without this the row lands in the DERIVED
      # `not_reached` bucket, which the dispatch line renders as `N not reached (limit)` — a false
      # cause for a real number, printed beside `limit=` at its true value.
      SKIP_COLLIDED=$((SKIP_COLLIDED + 1))
      echo "[refresh] >#$N SKIPPED — a pass less than ${COLLISION_TTL}s ago found a peer holding it; retried when that record expires (agent-infra#1729)"
      continue ;;
  esac
  # ── CAN THIS PASS AFFORD ANOTHER CANDIDATE? (see the budget block above `cmd_run`) ─────────────
  # ⛔ THE CHECK IS BEFORE `judged++`, so a pass that stops here has not ATTEMPTED this candidate:
  # it is left UNCHECKED for the next pass (no `checked.txt` entry), exactly like a COLLISION or a
  # DEGRADED verdict. That is the #1736 contract — a candidate nobody judged is never "no work".
  # The re-read is per candidate because the SPEND so far is the only honest estimate of the spend
  # to come; the seam makes it free (the rate_limit endpoint is exempt from the core budget).
  # ⛔ THIS IS THE SPEND BOUND, AND `$RUN_BUDGET` ABOVE IS THE RUN-COUNT BOUND — both are needed.
  # Run count alone cannot see a pre-flight whose cost per run tripled (the board rebuild, #2022);
  # spend alone cannot see a box whose bucket is healthy but whose pool head is an endless block.
  # ⛔ `${CORE_PACING:-0}`, NOT `$CORE_PACING`: selftest.sh extracts this loop body from `n=0` and
  # runs it standalone, so the seams defined ABOVE the loop are absent there. Under the bare name
  # the extraction printed `[: : integer expression expected` once per candidate (measured) and
  # skipped the block by ACCIDENT — a green suite that no longer exercises this code, which is the
  # "passes for the wrong reason" shape the extraction exists to avoid. Absent => OFF, and the
  # shipped flow always defines it (0 or 1), so this default can only be reached by an extraction.
  if [ "${CORE_PACING:-0}" -eq 1 ]; then
    if CORE_NOW="$(core_remaining)"; then
      if [ "$CORE_NOW" -lt $(( ${CORE_RESERVE:-0} + ${CORE_EST:-0} )) ]; then
        STARVED=1
        POOL_SWEPT=0
        # The report names BOTH budgets, each by what it actually counts: `judged` is pre-flight
        # RUNS and `n` is SLOTS filled. #2050 said "judged $judged of the $LIMIT slot(s)", which is
        # only true under the pre-#1729 meaning of `n`; keeping that sentence on the reconciled head
        # would print `judged 2 of the 6 slot(s)` for a pass that filled ONE slot in two runs.
        echo "[refresh] budget starved: REST core remaining=$CORE_NOW < reserve=$CORE_RESERVE + ~$CORE_EST for the next candidate — this pass spent $judged of its $RUN_BUDGET pre-flight run(s) and filled $n of its $LIMIT slot(s), so it stops HERE; the candidates not reached are left unchecked (NOT judged, so this is not an empty backlog)"
        break
      fi
      CORE_AT_CANDIDATE="$CORE_NOW"
    else
      CORE_AT_CANDIDATE=""
    fi
  fi
  # ⛔ A pre-flight that ERRORED is not a verdict — and a COLLISION is not terminal. `echo "$N" >>
  # checked.txt` used to run BEFORE the verdict was read, so a pre-flight that produced no VERDICT
  # line (API failure, missing venv, timeout) blacklisted the issue forever, invisibly: checked.txt
  # suppresses it, and the reaper above only walks dispatched.txt, so nothing ever removed the entry.
  # A COLLISION was permanent the same way, though a collision is transient by nature (the colliding
  # work lands). checked.txt is therefore written ONLY on the verdict that terminates the issue —
  # CLEAN, which is queued. Everything else is left unchecked, so the next pass re-attempts it.
  # (agent-infra#1716)
  judged=$((judged + 1))
  PRE="$("$PY" "$PREFLIGHT" "$N" --repo . 2>&1)"; PRE_RC=$?
  # ⛔ A tool that REFUSED TO RUN is a PROVISIONING failure, not a per-issue "no verdict". The
  # pre-flight's EXIT_USAGE (3) is how it reports an unusable environment — most importantly its
  # Python >= 3.12 guard (#5128), which prints an explanation and NO `VERDICT` line. Absorbing that
  # into the `*)` arm below left the backlog empty and the script exiting 0, so no `.refresh-blocked`
  # marker was written and nothing appeared in `status`: the cell stayed RUNNING with `lanes: 0` —
  # the exact merge-only defect this gate exists to catch, now certified by it (#1748 review). The
  # exit code is read IMMEDIATELY after the command, with no `$(...)` in between (the retired
  # do-merge.sh bug class). EXIT_INCOMPLETE (2) and the verdict-less open-PR / ambiguous-target
  # refusals are per-issue and transient by nature; 3 is the tool's usage/environment code.
  # A here-string, not `printf … | grep -q`: under `pipefail` the quiet grep exits at its first
  # match while the writer is still pushing bytes, the writer takes SIGPIPE (141), and pipeline
  # status becomes non-zero — so this fail-closed gate would report NOT-PROVISIONABLE on output
  # that DID carry a verdict (#841; scripts/check-no-sigpipe-grep.sh is the guard).
  if [ "$PRE_RC" -eq 3 ] && ! grep -qE '^VERDICT' <<<"$PRE"; then
    echo "[refresh] NOT PROVISIONABLE: the pre-flight tool exited 3 (usage/environment) with no VERDICT — a cell on this repo could only MERGE (#1736)"
    printf '%s\n' "$PRE" | tail -3 | sed 's/^/[refresh]   /'
    echo "[refresh]   fix: make the interpreter runnable (the tool requires Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR) or set SCOUT_PY=<a Python >= $MIN_PY_MAJOR.$MIN_PY_MINOR>"
    exit "${EXIT_NOT_PROVISIONABLE:-3}"
  fi
  V="$(printf '%s\n' "$PRE" | grep -E '^VERDICT' | head -1 | sed -E 's/.*VERDICT: (CLEAN|COLLISION|LANDED|INCOMPLETE).*/\1/')"
  # A DEGRADED answer is not a verdict — for ANY non-landed verdict. The canonical producer prints the
  # `ALSO INCOMPLETE:` marker beside a COLLISION or a LANDED answer (an INCOMPLETE verdict IS the
  # degraded reading and prints "N surface(s) could not be queried" with no marker), and
  # `resolve_preflight` prefers the repo's OWN copy, so a VENDORED producer could pair it with CLEAN and
  # reproduce the healthy-looking reading this pass exists to refuse (#1853 review). LANDED is exempt:
  # the producer's contract makes a terminal signal decisive over an incomplete one.
  degraded=0
  # ⛔ ANCHORED, because the report echoes the candidate's own `title:` line: an unanchored search for
  # this phrase would let an ISSUE TITLE set the flag and silently drop a genuine CLEAN (#1853 review).
  grep -qE '^ *ALSO INCOMPLETE: ' <<<"$PRE" && degraded=1
  case "$V" in
    CLEAN)
      # ⛔ A CLEAN that ALSO says INCOMPLETE is the DEGRADED answer, not a verdict — the tool could
      # not read every surface and would have used the conservative verdict had it been able to.
      # Measured 2026-10-16 (#1328): an issue whose true verdict was LANDED came back degraded.
      # Counting a degraded answer as usable would let a broken environment report a healthy
      # `checked N; backlog now 0` — the reading this pass exists to refuse (#1853 review).
      # A DEGRADED pre-flight short-circuits BEFORE the claim read: the verdict is not trustworthy,
      # so the issue is left unchecked and is neither queued nor certified either way.
      if [ "$degraded" -eq 1 ]; then
        V_UNJUDGED=$((V_UNJUDGED + 1))
        echo "[refresh] ?#$N CLEAN is DEGRADED (the pre-flight could not query every surface) — not counted as a verdict, left unchecked for the next pass"
      else
        # ── the cross-box ISSUE claim is a BLOCKING surface (agent-infra#1850) ───────────────────
        # The tool above reads only immutable history and per-machine git state, so it reports CLEAN
        # for an issue a PEER started ten seconds ago and has not pushed yet. Read the registry
        # before certifying: an issue claim is a claim on the WORK, and it exists before the first
        # push. The registry is resolved from `$O`, which the loop has already resolved: there is no
        # `CLAIMS_SH` seam (an ambient value could have half-disabled the gate).
        ICR=0
        # ⛔ THE REASON IS RESET PER CANDIDATE, because the CLEAN arm below reads it to decide whether to
        # print "queued because its ONLY claim is ORPHANED" and to count a reclaim. Today that read is
        # never stale — every path that can leave a reason also sources the registry, and claims.sh
        # resets `CLAIM_RESULT=""` at source time — but that reachability argument spans TWO FILES, and
        # the block's own rule is that neither line may claim an action this script did not take. The
        # reset makes the guarantee local: an empty reason can only come from THIS candidate.
        CLAIM_RESULT=''
        # ⛔ A MISSING REGISTRY IS `ICR=0` ON PURPOSE — the documented loud fallthrough (see
        # issue_claim_verdict's STATED LIMIT), and the only case in which a box without the registry
        # keeps dispatching. It is NOT a verdict: the branch below announces it every time.
        if [ -f "$O/claims.sh" ]; then
          # `cmd; rc=$?` rather than `if cmd; then …; else rc=$?; fi` — one shape, no reliance on the
          # condition's status surviving into the else branch.
          issue_claim_verdict "$N"; ICR=$?
        else
          echo "[refresh] ⚠️ #$N: no claim registry at $O/claims.sh — the cross-box issue-claim check is OFF on this box (seed it: cp scripts/orchestrator-harness/*.sh ~/orchestrator/)"
        fi
        # ⛔ THE CLEAN ARM IS NAMED, NOT THE WILDCARD (2026-10-16 review). `case 1) … 2) … *) CLEAN`
        # read EVERY other code — 127 from a missing function, and any code a foreign or future
        # registry might return — as CLEAN and queued the issue: fail-OPEN, in the one place this
        # block declares it never fails open. A verdict this reader does not recognise is not a
        # licence to dispatch; it is an INCOMPLETE. Only an explicit 0 queues.
        case "$ICR" in
          0)
            # ⛔ EVERY STATE WRITE IS CHECKED, AND THE PERMANENT ONE GOES LAST. `checked.txt` is what
            # makes an issue invisible to LATER passes — it is reclaimed only for numbers that reached
            # `dispatched.txt` — so writing it BEFORE the queue entry made a failed append to
            # `candidates.txt` an unrecoverable loss: the issue is never pre-flighted again, never
            # queued, and the pass still logged `+#N CLEAN -> backlog` and exited 0. Measured (#1853
            # review): with `candidates.txt` unwritable, the pre-flight ran ONCE, ever, and two
            # consecutive passes reported success. The recoverable write lands FIRST, so a failure
            # there leaves the issue retryable; the log line and `usable` follow BOTH writes, so
            # neither can overstate the queue. (Inlined rather than a helper: selftest.sh extracts
            # this loop body and runs it standalone, so anything it calls must live inside the
            # extraction.)
            if ! printf '%s\n' "$N" >> "$O/candidates.txt"; then
              echo "[refresh] ABORT: cannot queue #$N into $O/candidates.txt — this pass would report a backlog it did not persist (#1736)"
              exit "${EXIT_TRANSIENT:-1}"
            fi
            if ! printf '%s\n' "$N" >> "$O/checked.txt"; then
              echo "[refresh] ABORT: cannot record #$N as checked in $O/checked.txt (#1736)"
              exit "${EXIT_TRANSIENT:-1}"
            fi
            usable=$((usable + 1))
            QUEUED=$((QUEUED + 1)); V_QUEUED=$((V_QUEUED + 1))
            # ⛔ A VERDICT CLEARS THE RETRY STRIKE (review P1). `RETRY_MAX` bounds CONSECUTIVE
            # non-verdicts; the counter was only cleared in the LANDED arm, so an entry that answered
            # on most passes still accumulated strikes across them and was eventually written to
            # `checked.txt` — permanent, invisible suppression — by three UNRELATED transient
            # failures. Measured class: every arm that reaches a verdict must reset it.
            rm -f "$O/state/pretry-$N" 2>/dev/null
            n=$((n + 1))     # a SLOT is filled: this candidate has left the head for good (#1729)
            echo "[refresh] +#$N CLEAN -> backlog"
            # The pre-flight said CLEAN for a claim that EXISTS: that is an ORPHANED holder being
            # reclaimed (a fresh issue reads "no claim on #N"). Name it, or the repair is invisible.
            case "${CLAIM_RESULT:-}" in
              *rphan*) ICR_RECLAIMED=$((ICR_RECLAIMED + 1))
                       echo "[refresh] +#$N queued because its ONLY claim is ORPHANED (reclaimable — the acquire still races the CAS) — ${CLAIM_RESULT}" ;;
            esac ;;
          1) # a live claim: a peer owns it. Leave it UNCHECKED so the next pass re-attempts it —
             # a claim is a window, not a verdict (the peer's work lands).
             # ⛔ AND IT IS USABLE — it is a COLLISION, which is one of the three verdicts the caller
             # can act on. Without this the pool property-assertion below reads an ALL-claim-held pool
             # as "judged NOTHING" and aborts rc=1 every cycle, in exactly the cross-box-collision
             # state this check exists for, while the pass has already printed a verdict per candidate
             # (#1853 review). ICR=2 (INCOMPLETE) stays uncounted — that is not a verdict.
             usable=$((usable + 1)); V_COLLISION=$((V_COLLISION + 1))
             ICR_HELD=$((ICR_HELD + 1))
             # Held by a peer, so the next pass walks past it for free instead of re-buying this
             # verdict — for `POOL_COLLISION_TTL` seconds, after which it is judged again (#1729).
             # ⛔ AND IT CLEARS THE STRIKE: a COLLISION is a verdict (review P1) — see the CLEAN arm.
             rm -f "$O/state/pretry-$N" 2>/dev/null
             COLLIDED_NEW="$COLLIDED_NEW$N "
             echo "[refresh] =#$N COLLISION (cross-box issue claim) — $CLAIM_RESULT; retried next pass" ;;
          2) # unreadable registry: INCOMPLETE, never CLEAN. Also left unchecked, so the issue is
             # re-attempted rather than lost, and NOT queued, so nothing is dispatched on a guess.
             ICR_INCOMPLETE=$((ICR_INCOMPLETE + 1))
             V_UNJUDGED=$((V_UNJUDGED + 1))
             echo "[refresh] ?#$N INCOMPLETE — $CLAIM_RESULT; not queued, retried next pass" ;;
          3) # PRESENT BUT STALE: a local, PERMANENT provisioning failure. Refusing per-issue would
             # queue nothing forever while the cell still reported RUNNING (the merge-only defect this
             # script has been fixed for twice), so take it to the provisioning channel: orch-loop.sh
             # records `.refresh-blocked`, stops retrying, and `status` names the reason.
             echo "[refresh] NOT PROVISIONABLE: ${CLAIM_RESULT:-$O/claims.sh cannot answer the issue-claim question}"
             echo "[refresh]   fix: cp scripts/orchestrator-harness/*.sh ~/orchestrator/  (then re-run)"
             exit "${EXIT_NOT_PROVISIONABLE:-3}" ;;
          *) ICR_INCOMPLETE=$((ICR_INCOMPLETE + 1))
             V_UNJUDGED=$((V_UNJUDGED + 1))
             echo "[refresh] ?#$N INCOMPLETE — the registry returned an UNRECOGNISED verdict (rc=$ICR); not queued, retried next pass" ;;
        esac
      fi ;;
    COLLISION)
      # ⛔ A COLLISION that ALSO says INCOMPLETE is the DEGRADED answer, not a verdict: the tool
      # could not read every surface and defaulted to the conservative one. Measured 2026-10-16
      # (#1328): an issue whose true verdict was LANDED came back as `VERDICT: COLLISION ... ALSO
      # INCOMPLETE: 3 surface(s) could not be queried`. Counting it as usable would let a broken
      # environment report a healthy `checked N; backlog now 0` — the reading this pass exists to
      # refuse (#1853 review).
      if [ "$degraded" -eq 1 ]; then
        V_UNJUDGED=$((V_UNJUDGED + 1))
        echo "[refresh] ?#$N COLLISION is DEGRADED (the pre-flight could not query every surface) — not counted as a verdict, left unchecked for the next pass"
      else
        usable=$((usable + 1)); V_COLLISION=$((V_COLLISION + 1))
        # A COLLISION is a verdict, so it clears the consecutive-strike counter (review P1).
        rm -f "$O/state/pretry-$N" 2>/dev/null
        COLLIDED_NEW="$COLLIDED_NEW$N "   # a peer holds it: recorded so the next pass skips it (#1729)
        echo "[refresh] =#$N collision — a peer owns it, retried next pass"
      fi ;;
    LANDED)
      # Terminal and REAL: the issue was closed between the pool listing and the pre-flight, so it
      # has left the pool by itself. Since tortoise#8625 the ONLY source of a LANDED verdict is the
      # issue's OWN state being CLOSED, and this pool is built from `--state open`, so this arm is
      # reachable only through a CLOSE RACE — kept for exactly that race.
      # Counted as a usable verdict (otherwise a pass of LANDEDs reads as "judged NOTHING") and it
      # fills a SLOT, but it is NEVER written to checked.txt: checked.txt retiring an OPEN issue is
      # the permanent invisible suppression #8515 removed. landed.txt keeps it out of the backlog
      # WITHOUT hiding it — the tail of every pass names the set, the reaper settles it once the
      # issue is CLOSED and releases it if the issue is OPEN (tortoise#8560/#8629 review F3).
      usable=$((usable + 1)); V_LANDED=$((V_LANDED + 1))
      n=$((n + 1))     # a SLOT is filled: the issue has left the pool, so the head moved (#1729)
      rm -f "$O/state/pretry-$N" 2>/dev/null
      # ⛔ CHECKED, LIKE EVERY OTHER STATE WRITE (review N6). The rule three hundred lines up says
      # "EVERY STATE WRITE IS CHECKED"; this one was not. A failed append here does not lose work (the
      # issue is CLOSED, so the pool no longer lists it) but it WOULD make the pass claim a landed
      # record it never persisted — and landed.txt is the set the pass NAMES on stdout and the reaper
      # settles. Recoverable: the next pass sees the closed issue again and retries the append.
      if ! printf '%s\n' "$N" >> "$O/landed.txt"; then
        echo "[refresh] ⚠️ #$N LANDED but the landed.txt append FAILED — the decision is real (the issue is closed); the record will be retried next pass"
      fi
      echo "[refresh] =#$N LANDED — work already shipped; verify/close, NOT queued, NOT checked" ;;
    INCOMPLETE)
      # ⛔ A PRE-FLIGHT `INCOMPLETE` IS THE BOX, NOT THE CANDIDATE (review P1). It touches the
      # retirement bound in NO direction: it neither strikes nor clears `state/pretry-<N>`. Striking
      # would blacklist the whole pool behind a box-wide outage; clearing would make the bound
      # unreachable for an ALTERNATING outage/verdict-less chain (round 3's starvation half — a pool
      # head re-bought every pass forever). Both halves are why the counter belongs to the
      # verdict-less arm alone (see the RETRY_MAX note near the top). It stays unchecked (retried next
      # pass) and is REPORTED, which is what the arm did before the port folded it into the
      # verdict-less one.
      V_UNJUDGED=$((V_UNJUDGED + 1))
      echo "[refresh] ?#$N INCOMPLETE from the pre-flight (it could not query every surface) — not a verdict, left unchecked for the next pass (an INCOMPLETE is box-wide: it neither strikes nor clears the $RETRY_MAX verdict-less bound)" ;;
    *)
      V_UNJUDGED=$((V_UNJUDGED + 1))
      # ⛔ A VERDICT-LESS RUN IS NOT A VERDICT, BUT IT MAY NOT BE RETRIED FOREVER (tortoise#8469 review
      # P2). No `VERDICT:` line at all — the pre-flight crashed, timed out or answered an ambiguous
      # target — so the entry is BOUNDED: after RETRY_MAX verdict-less attempts it is marked checked so
      # the cursor can advance past a pool head that will never answer. The attempt number is logged, so
      # this is never silent. Only THIS arm writes `checked.txt`, and only THIS arm may count toward the
      # bound (review P1, final round): the counter is a count of the pre-flight failing on THIS ENTRY,
      # which is the one fact a box-wide `INCOMPLETE` cannot supply.
      mkdir -p "$O/state" 2>/dev/null
      pf="$O/state/pretry-$N"
      pa="$(cat "$pf" 2>/dev/null || echo 0)"; case "$pa" in ''|*[!0-9]*) pa=0 ;; esac
      pa=$((pa + 1))
      if [ "$pa" -ge "$RETRY_MAX" ]; then
        # ⛔ THE PERMANENT WRITE IS CHECKED, LIKE EVERY OTHER ONE (#1853's rule, review P1).
        # `checked.txt` is what makes an entry invisible to LATER passes and is reclaimed only for
        # numbers that reached `dispatched.txt` — so a FAILED append here that the pass reported as
        # "marked checked" would be the same overstatement the CLEAN arm was fixed for.
        if printf '%s\n' "$N" >> "$O/checked.txt"; then
          # ⛔ AND THE COUNTER IS CONSUMED, NOT MERELY LEFT TO AGE. `checked.txt` is reclaimable (the
          # reaper rewrites it for numbers that reached `dispatched.txt`), so a counter left behind
          # would let a later chain that is one strike short retire on the strength of a past one.
          rm -f "$pf" 2>/dev/null
          echo "[refresh] ?#$N ${V:-no verdict} — marked checked after $RETRY_MAX verdict-less attempts on this entry (a persistently non-answering entry must not starve the pool behind it)"
        else
          echo "[refresh] ABORT: cannot record #$N as checked in $O/checked.txt — the cursor would not advance and this pass would claim it did (#1736)"
          exit "${EXIT_TRANSIENT:-1}"
        fi
      else
        echo "$pa" > "$pf" 2>/dev/null || true
        echo "[refresh] ?#$N ${V:-no verdict} from the pre-flight — left unchecked for the next pass (attempt $pa/$RETRY_MAX)"
      fi ;;
  esac
  # ── LEARN THIS BOX'S REAL PER-CANDIDATE COST (the pacing estimate is MEASURED, not a guess) ─────
  # Only a LARGER observed spend raises the estimate: a pass that got cheaper must not raise it on the
  # strength of a concurrent consumer's spend (the box shares the bucket with the sweep, the merge path
  # and every lane), and erring HIGH is the safe direction — it stops the pass one candidate early
  # instead of one too late. A CONCURRENT spend can only inflate this, i.e. make pacing MORE cautious.
  if [ -n "${CORE_AT_CANDIDATE:-}" ] && CORE_AFTER="$(core_remaining)"; then
    if [ "$CORE_AFTER" -le "$CORE_AT_CANDIDATE" ]; then
      CORE_SPENT=$(( CORE_AT_CANDIDATE - CORE_AFTER ))
      # The measurement, in the log, because the constant above is only as good as what this box
      # actually spends and an operator cannot re-derive it any other way (#1984 cause 3). A
      # concurrent consumer only INFLATES this, so a large value is the safe reading.
      [ "$CORE_SPENT" -gt 0 ] && echo "[refresh] budget: #$N spent ${CORE_SPENT} core request(s) (estimate now ~$CORE_EST)"
      [ "$CORE_SPENT" -gt "$CORE_EST" ] && CORE_EST="$CORE_SPENT"
    fi
  fi
done < "$O/.pool"
# ── THE FUNNEL RECORD ─────────────────────────────────────────────────────────────────────────────
# Written HERE, before the no-usable-verdict abort below, because the abort is precisely the cycle
# that used to print `[dispatch] backlog empty queue=READ(223)` with no trace of where 223 went.
# ONE line, `key=value` pairs, atomic (write+rename) so a reader never sees a torn record and a
# half-written one cannot be mistaken for a measurement. The counts must RECONCILE — a record that
# does not add up is reported as UNRECONCILED with both sides, never silently published as truth.
# This is instrumentation: a failure to write it is logged and does NOT fail the pass (the backlog
# is the product; the funnel explains it).
FUNNEL_LISTED="${POOL_ROWS:-}"
# A plain digit test, not `is_num`: this script defines no such helper and MUST NOT grow a second
# number parser (selftest extracts it). `wc -l` output is already space-stripped at POOL_ROWS.
case "$FUNNEL_LISTED" in ''|*[!0-9]*) FUNNEL_LISTED="-" ;; esac
FUNNEL_NOTREACHED="-"
if [ "$FUNNEL_LISTED" != "-" ]; then
  FUNNEL_NOTREACHED=$(( 10#$FUNNEL_LISTED - SKIP_CHECKED - SKIP_DISPATCHED - SKIP_LANDED - SKIP_COLLIDED - judged ))
  [ "$FUNNEL_NOTREACHED" -lt 0 ] && FUNNEL_NOTREACHED=0
  if [ $(( SKIP_CHECKED + SKIP_DISPATCHED + SKIP_LANDED + SKIP_COLLIDED + judged + FUNNEL_NOTREACHED )) -ne "$(( 10#$FUNNEL_LISTED ))" ] \
     || [ $(( V_QUEUED + V_COLLISION + V_LANDED + V_UNJUDGED )) -ne "$judged" ]; then
    echo "[refresh] WARN funnel does not reconcile: listed=$FUNNEL_LISTED (skipped_checked=$SKIP_CHECKED skipped_dispatched=$SKIP_DISPATCHED skipped_landed=$SKIP_LANDED skipped_collided=$SKIP_COLLIDED judged=$judged not_reached=$FUNNEL_NOTREACHED) vs judged split (queued=$V_QUEUED collision=$V_COLLISION landed=$V_LANDED unjudged=$V_UNJUDGED)"
  fi
fi
# `reconciled=0` when the parts do NOT sum to the pool. The reader then prints UNRECONCILED instead
# of a decomposition: a record that does not add up must not be presented as one that does (the WARN
# below is in the refresh's log, which an operator reading the dispatch line never sees).
# ⛔ OPTIMISTIC DEFAULT REMOVED (review round 4, finding 7). FUNNEL_OK started at 1 and was only
# recomputed when `listed` was numeric — so a pass whose pool count was unusable (listed="-")
# published `reconciled=1` beside a decomposition nothing had checked. Unverified is not reconciled:
# the flag now starts at 0 and only a numeric pool that passes BOTH checks sets it.
# ⛔ AND BE HONEST ABOUT WHAT THE POOL CHECK CAN SEE. `not_reached` is DERIVED from the same skip
# buckets (checked, dispatched, landed, collided) and `judged`, so the pool half cannot detect a row that was
# never counted at all; what it DOES catch is OVER-counting — one row landing in two skip buckets, or
# a verdict arm that increments nothing — which is the reachable failure when someone adds a
# `continue` without a counter. The judged half is the split invariant. Neither check can see a
# pool row that vanished; the reader's wording says
# what is verified, not that the pool is provably complete.
FUNNEL_OK=0
if [ "$FUNNEL_LISTED" != "-" ]; then
  [ $(( SKIP_CHECKED + SKIP_DISPATCHED + SKIP_LANDED + SKIP_COLLIDED + judged + FUNNEL_NOTREACHED )) -eq "$(( 10#$FUNNEL_LISTED ))" ] \
    && [ $(( V_QUEUED + V_COLLISION + V_LANDED + V_UNJUDGED )) -eq "$judged" ] && FUNNEL_OK=1
fi
FUNNEL_LINE="listed=$FUNNEL_LISTED judged=$judged queued=$V_QUEUED collision=$V_COLLISION landed=$V_LANDED unjudged=$V_UNJUDGED skipped_checked=$SKIP_CHECKED skipped_dispatched=$SKIP_DISPATCHED skipped_landed=$SKIP_LANDED skipped_collided=$SKIP_COLLIDED not_reached=$FUNNEL_NOTREACHED limit=$LIMIT reconciled=$FUNNEL_OK at=$(date +%s)"
if printf '%s\n' "$FUNNEL_LINE" > "$O/state/.refresh-funnel.$$" 2>/dev/null \
   && mv "$O/state/.refresh-funnel.$$" "$O/state/refresh-funnel" 2>/dev/null; then
  echo "[refresh] funnel $FUNNEL_LINE"
else
  rm -f "$O/state/.refresh-funnel.$$" 2>/dev/null
  echo "[refresh] WARN could not record the funnel in $O/state/refresh-funnel — the dispatch line will say UNRECORDED rather than report a decomposition it does not have"
fi
# ── persist what this pass learned about HELD candidates (agent-infra#1729) ─────────────────────
# REWRITTEN, never appended: every record that is still fresh is carried over with its ORIGINAL
# expiry (re-stamping one this pass did not re-judge would make a held candidate's record permanent),
# expired records are dropped, and this pass's new collisions are added. `mv` is atomic within the
# directory, so a concurrent reader sees the old file or the new one. A failure here is LOUD but NOT
# fatal: the ledger is an optimisation, and losing it costs exactly one pass of re-buying the same
# collisions — while aborting the pass would throw away the candidates it has just queued.
if [ -n "${COLLISION_LEDGER:-}" ]; then
  _now="$(date +%s 2>/dev/null || echo 0)"
  _exp=$(( _now + ${COLLISION_TTL:-0} ))
  mkdir -p "$(dirname "$COLLISION_LEDGER")" 2>/dev/null || true
  if {
       if [ -r "$COLLISION_LEDGER" ]; then
         while read -r _e _i; do
           [ -n "${_i:-}" ] || continue
           case "$_e" in ''|*[!0-9]*) continue ;; esac
           [ "$_e" -gt "$_now" ] || continue
           printf '%s %s\n' "$_e" "$_i"
         done < "$COLLISION_LEDGER"
       fi
       for _i in ${COLLIDED_NEW:-}; do printf '%s %s\n' "$_exp" "$_i"; done
     } > "${COLLISION_LEDGER}.new" 2>/dev/null \
     && mv "${COLLISION_LEDGER}.new" "$COLLISION_LEDGER" 2>/dev/null; then :
  else
    rm -f "${COLLISION_LEDGER}.new" 2>/dev/null
    echo "[refresh] WARN: could not record the collision ledger at $COLLISION_LEDGER — the next pass will re-pre-flight the same held candidates (this pass's verdicts stand)"
  fi
fi
# ── a pass the registry answered NOTHING for is not a healthy pass (2026-10-16 review) ──────────
# The per-issue INCOMPLETE lines scroll away, and `lanes: 0` with `backlog=0` is exactly what a quiet
# box looks like, so a git-transport-only outage (gh and the merge path both still working) or a
# stale registry would leave every cell on the repo dispatching nothing while looking healthy. The
# aggregate names the registry as the cause, and it is printed BEFORE the no-usable-verdict abort
# below so that abort is not the only line that mentions it. ⚠️ There is deliberately NO SECOND
# transient exit here: the `usable -eq 0` assertion below already exits TRANSIENT when every
# candidate was INCOMPLETE, and exiting on `ICR_INCOMPLETE>0 && QUEUED==0` would also red a pass whose
# whole pool is peer-owned COLLISIONs — an empty backlog for a legitimate reason (#1853 review).
if [ "$ICR_INCOMPLETE" -gt 0 ]; then
  echo "[refresh] $ICR_INCOMPLETE of $judged pre-flighted issues INCOMPLETE — the cross-box claim registry could not answer; $QUEUED queued"
fi
# ⛔ THE OTHER WAY A POOL EMPTIES WITHOUT LOOKING LIKE A FAULT (agent-infra#2094). Printed only when
# a claim actually changed this pass's outcome, so a normal pass stays quiet. The withheld count is
# what makes `backlog now 0` readable as "claims", not as "no work"; the reclaimed count is the
# rename repair, which is a healthy event but must be visible.
if [ "$ICR_HELD" -gt 0 ]; then
  echo "[refresh] $ICR_HELD of $judged candidate(s) WITHHELD by a live cross-box claim (held-by-live) — a short backlog here is claims, not an empty pool (agent-infra#2094)"
fi
if [ "$ICR_RECLAIMED" -gt 0 ]; then
  echo "[refresh] $ICR_RECLAIMED of $judged candidate(s) queued although a claim EXISTS, because it is ORPHANED (held-by-orphan) — the holder host cannot be a live lane; the acquire still races the CAS (agent-infra#2094)"
fi
# ⛔ THE COLLISION-CONSUMES-THE-WINDOW CLASS IS COVERED (agent-infra#1729): a persistently colliding
# head used to eat the whole window while `checked N; backlog now 0` printed and the pool was never
# advanced. It is addressed by the SLOT budget + the collision ledger above, not by this assertion —
# so what remains here is the narrower reading: a pass whose every RUN was unjudgeable.
#
# ⛔ THE TWO COUNTERS ABOVE ARE A DIFFERENT QUESTION, AND NEITHER IS "WHAT THIS DOES NOT COVER"
# (agent-infra#2094, spliced into one paragraph by the merge that brought #1729 in — a reader could not
# tell which symptom was claimed covered). The withheld/reclaimed lines answer "why is the backlog
# short": a live cross-box claim (held-by-live) is withheld, and a claim that is ORPHANED is queued and
# counted, so neither shape can read as "no work". Uncovered by either is only the pass whose every RUN
# was unjudgeable, which the STARVED / `usable -eq 0` arms below refuse.
# ⛔ A PASS THAT COULD AFFORD **NOTHING** MUST NOT FALL THROUGH TO `checked 0; backlog now M` EITHER
# (agent-infra#1736 follow-up). The BUDGET REFUSAL is placed below the reaper, so the mid-loop guard
# below only fires when the budget was affordable at the gate and was consumed by the listings on the
# way down — and `judged=0` is DELIBERATELY not covered by the `usable -eq 0` assertion after this
# comment (that one requires `judged -gt 0`). Without this arm such a pass would print
# `checked 0; backlog now 0` at rc 0 — the exact "an unjudged pool reads as an empty one" false
# report #1736 exists to refuse, arriving through the budget door instead of the API's. TRANSIENT,
# because a budget resets on a clock: the next cycle can judge. It is also NAMED, so an operator sees
# `starved` and not a quiet queue.
if [ "$STARVED" -eq 1 ] && [ "$judged" -eq 0 ]; then
  echo "[refresh] ABORT: the REST core budget could not buy a single candidate this pass (reserve=$CORE_RESERVE, ~$CORE_EST per candidate) — NOTHING was judged, so an empty backlog would be a false report (#1736). Retrying next cycle."
  exit "$EXIT_TRANSIENT"
fi
# ⛔ ... and a MIXED pass: ONE usable verdict masks any number of `?no verdict` / DEGRADED candidates,
# so `checked N; backlog now M` can still be printed over candidates the pre-flight could not judge.
# An abort on any degraded candidate would be worse — it would discard a pass that DID find a CLEAN
# candidate — so this limit is declared, not closed.
# This assertion covers the ALL-candidates-unjudged empty-backlog reading only.
# ⛔ ASSERT THE PROPERTY, NOT THE PLUMBING. "checked N; backlog now 0" over a non-empty pool is the
# reading the fleet has been stuck in: it looks like a healthy empty queue, and each `?no verdict`
# line is a per-candidate MASK of one environment failure (measured 2026-10-16: two cells whose
# keys.env carried no HOME logged 98 and 113 of them, and both had an empty backlog). If the
# pre-flight produced no usable verdict for ANY candidate, this pass judged nothing and must say so
# rather than report an empty backlog as a result.
# The TRANSIENT code, deliberately: the gh precondition above already refused PERMANENTLY (rc=3,
# with the reason) when the environment could not authenticate, so no-usable-verdict from a passing
# environment is a per-cycle anomaly (a network fault, a rate limit) that the next cycle should
# retry — loudly, via orch-loop.sh's `FAILED rc=1` line, not silently.
if [ "$judged" -gt 0 ] && [ "$usable" -eq 0 ]; then
  echo "[refresh] ABORT: none of the $judged candidate(s) the pre-flight ran produced a usable verdict (CLEAN, COLLISION or LANDED) — this pass judged NOTHING, so an empty backlog would be a false report (agent-infra#1736). Retrying next cycle."
  exit "$EXIT_TRANSIENT"
fi
# Dedupe WITHOUT re-sorting. orch-loop.sh consumes this file top-down and dispatches the first
# BATCH entries, so its ORDER IS the dispatch priority. `sort -n -u` re-ordered the ENTIRE backlog
# by issue number, which is what put 238 P2s ahead of 20 P0s (#8465) — the same defect as the pool
# sort above, and it reappeared here on every cycle.
#
# This file is FIFO. The pool above is severity-ordered when it is appended, but an entry added on a
# LATER cycle joins at the BACK, behind whatever is already queued — so a P0 discovered while P2s sit
# at the head waits for them instead of displacing them. That residual is deliberate and bounded: the
# refresh only runs while the backlog is below 6 (orch-loop.sh) and BATCH is 2, so at most 5 entries
# can be ahead of it. The TIME that costs is contingent, not a ceiling: 5 entries at 2 per cycle is 3
# cycles only if the capacity gate is open each cycle — a load/lane/swap/memory gate that holds
# dispatch delays it further. The ENTRY bound is what the refresh guarantees; do not read a wall-clock
# ceiling into it. Carrying the tier through orch-loop.sh's reader would remove the residual at the
# cost of a second ordering surface; not worth it for a bounded handful of entries.
#
# `mv` is atomic within the directory (rename(2)), so a concurrent reader sees the old file or the new
# one, never a torn one; `&&` keeps a failed awk from truncating the live backlog. One deliberate
# trade: `mv` swaps the inode, so the target's mode is replaced by the temp's umask-derived one,
# whereas the old `sort -o` preserved it. The file holds only public issue numbers and its mode is
# never set deliberately, so 644 is not a property anything depends on.
# ⛔ The final rewrite is CHECKED too: `&&` only stopped the `mv`, so a failed rewrite left the OLD
# `candidates.txt` in place and the line below then reported a backlog count from a file THIS pass
# never produced — the same absorbed-write shape as the queue append above (#1853 review).
awk '!seen[$0]++' "$O/candidates.txt" > "$O/.cand" || {
  echo "[refresh] ABORT: cannot rewrite the deduped backlog into $O/.cand (#1736)"
  exit "$EXIT_TRANSIENT"
}
mv "$O/.cand" "$O/candidates.txt" || {
  echo "[refresh] ABORT: cannot replace $O/candidates.txt with the deduped backlog (#1736)"
  exit "$EXIT_TRANSIENT"
}
# ── THE TWO QUEUES (agent-infra#2054) ────────────────────────────────────────────────────────
# ONE extra LISTING per pass reads the `harness`-labelled issues — up to `ceil(limit/100)` = 5 core
# requests at `--limit 500`, budget-gated below (the bound is derived there, never glossed as "a call").
# It is read AFTER the backlog is final, so the split costs nothing in ordering and cannot disturb it.
# ⛔ A FAILED READ MUST NOT MANUFACTURE PRODUCT WORK, and it must not stop dispatch either. The polarity
# is the same one the claim pre-flight uses in the opposite direction: without the label set, EVERY
# candidate classifies as harness, so `candidates.product.txt` comes out EMPTY, the floor is unmet, and
# orch-loop.sh says so WITH the queue-state token. That is a visible, conservative failure — never a
# product candidate invented from a listing that did not answer.
# ⛔ WRITTEN BY A FUNCTION, NOT INLINE (cycle-1 review, P1). Two defects came from the inline version:
# (a) it called a helper that lives in orch-loop.sh — the refresh runs as a CHILD and never
# sources it, so the operator's split line was `command not found` under `2>/dev/null` and printed
# `[refresh] split: ` with NO COUNTS on every pass; (b) the failed-listing polarity had no assertion, so
# a mutation making a failed read MANUFACTURE a full product queue stayed green. The function below is
# the whole block, it inlines its own counting, and product-floor.test.sh drives BOTH arms against a
# stubbed `rest_list`.
# ⚠️ THE COST IS STATED, NOT GLOSSED: this is not "one REST call". `rest_list` pages, so a full window
# costs ceil(limit/100) core requests, and it is spent AFTER the pass's budget discipline — so a pass
# that just refused to spend its reserve on pre-flight would still pay for this. It is therefore GATED on
# the same reserve: when the pass has nothing left, the listing is skipped, everything classifies as
# harness, and the floor reports itself unmet (the conservative direction) with a named reason.
# ⛔ EVERY "EVERY CANDIDATE IS HARNESS" ARM GOES THROUGH THIS ONE FUNCTION (review cycle 7, P1). Four of
# them used to write the two queues with `|| :` and then print `[refresh] split: product 0 harness <n>` —
# a count read from `candidates.txt` and a `0` TYPED as a literal — so a failed write both lied about the
# counts and, worse, could LEAVE A STALE NON-EMPTY PRODUCT QUEUE while the record said the class was
# absent: the loop then took the `[ -s candidates.product.txt ]` branch and satisfied the floor from a
# file this pass had just declared it could not classify. The `-f`/numeric artefact gate that cycle 2/3
# added existed only on the success path; here it covers every arm.
# `wpq_degrade <o> <record line> <pass line>`: writes, verifies, records — and says so when the writes
# did not land, rather than reporting a split it did not perform.
wpq_degrade() { # <o> <record> <message>; echoes the operator line
  local o="$1" rec="$2" msg="$3" stale=""
  { : > "$o/candidates.product.txt"; cp "$o/candidates.txt" "$o/candidates.harness.txt"; } 2>/dev/null || :
  # The claim these arms make is about the FILES, so it is checked against the files: both must be
  # regular, and the product queue must be EMPTY. A directory (or an unreadable file) on either path
  # fails this, and a product queue that still holds rows is the dangerous case — it would satisfy the
  # floor from a class this pass just declared unreadable.
  local want got
  want="$(wc -l < "$o/candidates.txt" 2>/dev/null | tr -d ' ' || :)"
  got="$(wc -l < "$o/candidates.harness.txt" 2>/dev/null | tr -d ' ' || :)"
  # ⛔ BOTH FILES, AND THE HARNESS ONE BY CONTENT (review cycle 8, P2). It was checked with `-f` alone, so
  # a stale harness queue whose write failed kept the claim "every candidate is treated as HARNESS" true
  # on paper and false on disk. The claim is now checked against the backlog's own line count.
  if [ ! -f "$o/candidates.product.txt" ] || [ ! -f "$o/candidates.harness.txt" ] \
     || [ -s "$o/candidates.product.txt" ] || [ "${want:-x}" != "${got:-y}" ]; then
    stale=" AND the all-harness fallback could not be written either, so the queues on disk may still hold a previous pass's split (dispatch still filters through candidates.txt, but do not read that as a class)"
  fi
  # ⛔ THE RECORD WRITE IS CHECKED LIKE EVERY OTHER WRITE IN THIS FUNCTION (review cycle 8, P1). It was
  # the ONE write here with a bare `|| :`, so an unwritable `state/` left the PREVIOUS pass's `OK
  # product=0 harness=3` in place while the queues were rewritten — and the loop then reported "the split
  # RAN and found none" for a pass whose listing never answered: the exact masking this record exists to
  # remove, produced by the record itself failing silently.
  if ! printf '%s%s\n' "$rec" "$stale" > "$o/state/product-class" 2>/dev/null; then
    printf '%s%s\n AND state/product-class could NOT be written, so the record on disk is the PREVIOUS pass'"'"'s and does not describe these queues' "$msg" "$stale"
    return 0
  fi
  printf '%s%s\n' "$msg" "$stale"
}
write_product_queues() { # <O> <OR> <PRODUCT_REPOS> -> writes the two queues; echoes one line
  local o="$1" repo="$2" prepos="$3" isp=0
  mkdir -p "$o/state" 2>/dev/null || :
  # ⛔ THE RECORD DESCRIBES THESE TWO FILES, SO ONLY THE THING THAT WRITES THEM MAY INVALIDATE IT
  # (review cycle 6, P1). This invalidation used to run at PASS ENTRY, ~1,400 lines before the first
  # byte of either queue is written — so a pass that refused at the environment check, the budget or
  # the pool read replaced a record that was still a byte-true description of the queues on disk with
  # `PENDING`, and the loop then reported a BLIND INTAKE on a healthy box (measured: the pass exits at
  # `gh_env_verdict || exit`, both queue files untouched, `state/product-class` = `PENDING`). That is
  # the false positive the measured-empty arm exists to remove, one window over.
  # Placed HERE, every arm below still overwrites it (so a pass that dies mid-split cannot leave the
  # previous measurement standing — the cycle-3 defect), while a pass that never reaches this point
  # leaves the previous record alone: it is still true, because neither queue file changed.
  if ! printf 'PENDING this pass has started but has not recorded a product class yet — no split has run, so this is NOT a measurement and NOT a finding about product work (the pass aborted, or is still running)\n' > "$o/state/product-class" 2>/dev/null; then
    # An unwritable record must be VISIBLE, not silent: every arm below will also fail to write, and the
    # loop would then repeat the previous pass's record as this pass's answer.
    printf '[refresh] WARN: state/product-class is NOT writable — the product class cannot be recorded this pass, so the floor'"'"'s reason= line will carry a PREVIOUS pass'"'"'s record. This is a state-dir failure, not a finding about product work.\n'
  fi
  # ⛔ THE REASON IS A RECORD, NOT A SECOND INFERENCE (review cycle 2, P2). `orch-loop.sh` used to PRINT
  # A QUESTION beside its unmet-floor line — "is this repo in PRODUCT_REPOS, and did the refresh pass
  # list the harness label?" — for causes THIS function already knew and had just decided. On a repo
  # that is simply not a product repo (agent-infra, the default `PRODUCT_REPOS` being tortoise) it asked
  # it on EVERY pass, and a routine case printed in the same words as the real failure is how the real
  # one stops being read (the #2042/#1931 masking shape, in the line that exists to expose it). So each
  # arm records WHAT IT DECIDED in `state/product-class`, and the loop repeats that instead of guessing.
  case " $(printf '%s' "$prepos" | tr ',' ' ') " in *" $repo "*) isp=1 ;; esac
  if [ "$isp" != "1" ]; then
    wpq_degrade "$o" \
      "$(printf 'NOT-A-PRODUCT-REPO %s is not in PRODUCT_REPOS (%s), so every candidate is harness' "$repo" "${prepos:-<empty>}")" \
      "$(printf '[refresh] split: every candidate is HARNESS — %s is not in PRODUCT_REPOS (%s)' "$repo" "${prepos:-<empty>}")"
    return 0
  fi
  # The budget gate: `CORE_NOW`/`CORE_RESERVE` are the pass's own spend meters. An unreadable meter is
  # NOT a refusal (the pre-flight takes the same view: it never starves on an unread metric).
  local affordable=1 wpq_need=0 wpq_pages=0 wpq_prod="" wpq_harn="" wpq_ok=0 fell=""
  # ⛔ THE WINDOW IS NAMED ONCE (review cycle 3, P2). The listing call and the budget bound that decides
  # whether this pass can afford it used to spell `500` and `5` INDEPENDENTLY, so the two could drift and
  # the bound would certify a read the call no longer costs. Both now read this constant, and the bound
  # is computed from it (`ceil(WPQ_LISTING_LIMIT / 100)` requests, which is what `rest_list` pages at).
  # LOCAL, not top-level: product-floor.test.sh extracts THIS FUNCTION BODY alone and drives it, so a
  # top-level constant would be an unbound variable in the extracted copy (measured: 12 red).
  local WPQ_LISTING_LIMIT=500
  if [ -n "${CORE_NOW:-}" ] && [ -n "${CORE_RESERVE:-}" ]; then
    case "$CORE_NOW" in ''|*[!0-9]*) : ;; *)
      # ⛔ RESERVE THE LISTING'S OWN COST, COUNTED IN THE LISTING'S OWN UNIT (review cycle 3, P2).
      # `rest_list` pages at 100 RAW rows per request, so a `--limit 500` read costs
      # ceil(500/100) = 5 core REQUESTS. The previous form multiplied the PER-CANDIDATE estimate
      # (`CORE_PER_CANDIDATE`, "one above the measured high water" *per candidate*) by the page count:
      # `5 * 6 = 30` requests of headroom demanded for a 5-request read, while the reason printed beside
      # it said "reserve %s + 5 paged requests" — a sum that could not add up, and a 6x over-block on a
      # pass that could have afforded the read. Worse, it coupled this gate to a knob that means
      # something else: `COLLISION_PREFLIGHT_CORE_PER_CANDIDATE=0` (a documented "disables pacing"
      # setting) collapsed the bound to the bare reserve, so a pass sitting AT the reserve passed and
      # spent it — the exact under-reserve this gate exists to prevent. The window is named ONCE, below,
      # and the listing call uses the same constant, so the bound cannot drift from the read.
      wpq_pages=$(( (WPQ_LISTING_LIMIT + 99) / 100 ))
      wpq_need=$(( CORE_RESERVE + wpq_pages ))
      [ "$CORE_NOW" -ge "$wpq_need" ] || affordable=0 ;;
    esac
  fi
  if [ "$affordable" != "1" ]; then
    wpq_degrade "$o" \
      "$(printf 'BUDGET-SKIPPED the pass could not afford the harness-label listing (remaining=%s, needs=%s = reserve %s + %s paged request(s) at --limit %s), so it was not read' "${CORE_NOW:-?}" "$wpq_need" "${CORE_RESERVE:-?}" "$wpq_pages" "$WPQ_LISTING_LIMIT")" \
      "$(printf '[refresh] WARN: split SKIPPED — the pass cannot afford the harness-label listing (remaining=%s, needs %s = reserve %s + up to %s paged requests at --limit %s), so it was not read; every candidate is treated as HARNESS and the product floor is unmet. This is a budget statement, not a finding about product work.' "${CORE_NOW:-?}" "$wpq_need" "${CORE_RESERVE:-?}" "$wpq_pages" "$WPQ_LISTING_LIMIT")"
    return 0
  fi
  # ⛔ A SATURATED WINDOW IS NOT A COMPLETE ONE (review cycle 2, P2). `rest_list` sets
  # `REST_WINDOW_FILLED=1` when it stopped because the window was full while the provider still
  # advertised a next page — and this listing is read for ABSENCE, so a truncated one classifies the
  # rows it never saw as PRODUCT. That is the one direction the polarity comment above forbids, so it
  # takes the same conservative arm: everything harness, the floor reports itself unmet, and the reason
  # says which it was.
  local satur=0
  if rest_list issues --repo "$repo" --state open --limit "$WPQ_LISTING_LIMIT" --label harness --jq '.[].number' > "$o/.harness-issues" 2>/dev/null; then
    [ "${REST_WINDOW_FILLED:-0}" = "1" ] && satur=1
    if [ "$satur" = "1" ]; then
      # ⛔ THE WINDOW IS NAMED FROM THE CONSTANT, NOT TYPED (review cycle 5, P2). Both operator-facing
      # strings said `--limit 500` while the listing reads `"$WPQ_LISTING_LIMIT"`: raise the constant and
      # the reason would keep telling the operator a window the call no longer used — the same
      # "the reason prints a number that is not the one used" defect the budget message was fixed for.
      wpq_degrade "$o" \
        "$(printf 'LISTING-TRUNCATED the harness-label window (--limit %s) was filled with a next page still advertised, so a harness issue outside it would have been classified PRODUCT' "$WPQ_LISTING_LIMIT")" \
        "$(printf '[refresh] WARN: the harness-label listing was TRUNCATED by its own window (--limit %s filled, more rows advertised) — every candidate is treated as HARNESS this pass, so the product queue is EMPTY and the product floor is unmet. A truncated exclusion set cannot be read as evidence of product work.' "$WPQ_LISTING_LIMIT")"
      return 0
    fi
    # ⛔ A SPLIT THAT COULD NOT BE WRITTEN IS NOT A SPLIT (this lane's cycle-2 review, P2). Both queues
    # were written with `awk … && mv` and the counts were then read back with `wc -l` and REPORTED AS
    # MEASUREMENTS — so a full disk or a read-only state dir printed `OK product=0 harness=0` beside two
    # files that did not exist, and a `0` here is the exact number the loop reports as "the split RAN
    # and found no product work".
    # ⛔ AND "BOTH WRITES LANDED" IS AN ARTEFACT CLAIM, NOT AN EXIT CODE (review cycle 3, P3). `mv f <dir>`
    # exits 0 and moves the temp INSIDE a directory occupying the queue path, and `wc -l < <dir>` then
    # prints `0` at rc 1 — so the exit-code gate certified a harness queue that was never written and
    # printed the `0` it never measured. (The suite forced that path only on the PRODUCT side, so the
    # harness side was the untested half.) Success is now gated on the ARTEFACT: both paths are regular
    # files AND both counts are numeric. `-f` is what refuses a directory; the numeric check refuses an
    # unreadable file whose `wc` failure would otherwise be read as a zero.
    if awk -v hf="$o/.harness-issues" '
      BEGIN { while ((getline l < hf) > 0) skip[l] = 1 }
      !($0 in skip) { print }' "$o/candidates.txt" > "$o/.product.tmp" 2>/dev/null \
      && mv -f "$o/.product.tmp" "$o/candidates.product.txt" 2>/dev/null \
      && awk -v pf="$o/candidates.product.txt" '
      BEGIN { while ((getline l < pf) > 0) prod[l] = 1 }
      !($0 in prod) { print }' "$o/candidates.txt" > "$o/.harness.tmp" 2>/dev/null \
      && mv -f "$o/.harness.tmp" "$o/candidates.harness.txt" 2>/dev/null \
      && [ -f "$o/candidates.product.txt" ] && [ -f "$o/candidates.harness.txt" ]; then
      wpq_prod="$(wc -l < "$o/candidates.product.txt" 2>/dev/null | tr -d ' ' || :)"
      wpq_harn="$(wc -l < "$o/candidates.harness.txt" 2>/dev/null | tr -d ' ' || :)"
      case "${wpq_prod}${wpq_harn}" in ''|*[!0-9]*) wpq_ok=0 ;; *) wpq_ok=1 ;; esac
    fi
    if [ "$wpq_ok" = "1" ]; then
      # ⛔ AND THE RECORD IS A WRITE LIKE ANY OTHER (review cycle 8, P1): `|| :` here would leave the
      # previous pass's record describing queues this pass just rewrote — a measured-empty reported as
      # the answer for a pass that never recorded one.
      if ! printf 'OK product=%s harness=%s\n' "$wpq_prod" "$wpq_harn" > "$o/state/product-class" 2>/dev/null; then
        printf '[refresh] WARN: the split RAN (product %s harness %s) but state/product-class could NOT be written — the record on disk is the PREVIOUS pass'"'"'s and does not describe these queues, so treat the floor'"'"'s reason= line as stale until a pass can write it.\n' \
          "$wpq_prod" "$wpq_harn"
        return 0
      fi
      printf '[refresh] split: product %s harness %s — product = a PRODUCT_REPOS issue without the harness label\n' \
        "$wpq_prod" "$wpq_harn"
      return 0
    fi
    # The degrade arm: today's order, all-harness, and a reason that claims NO count it did not measure.
    # ⛔ AND THE FALLBACK IS VERIFIED TOO (same review finding): the arm's claim is that every candidate
    # is NOW harness — a statement about the FILE, not about the intent. When the same unusable queue
    # path defeats the fallback as well, the record says so instead of asserting a state the disk does
    # not hold (the queue on disk would still be the previous pass's split).
    rm -f "$o/.product.tmp" "$o/.harness.tmp" 2>/dev/null || :
    # `;` not `&&`: an unusable PRODUCT path must not skip the HARNESS write, which is the one that
    # carries the class (measured: with `&&`, a directory on the product path left BOTH queues unwritten
    # and the arm still claimed every candidate was now harness).
    { : > "$o/candidates.product.txt"; cp "$o/candidates.txt" "$o/candidates.harness.txt"; } 2>/dev/null || :
    if [ ! -f "$o/candidates.product.txt" ] || [ ! -f "$o/candidates.harness.txt" ] || [ -s "$o/candidates.product.txt" ]; then
      fell=" AND the all-harness fallback could not be written either, so the queues on disk may still hold a previous pass's split (dispatch order falls back to candidates.txt, but do not read that as a class)"
    fi
    # ⛔ THE LAST UNCHECKED RECORD WRITE (review cycle 9, P2). Its three siblings are checked; this one kept
    # `|| :`, so a failure left the `PENDING` from the top of the function and the loop then reported
    # `reason=PENDING` ("the pass aborted, or is still running") instead of `WRITE-FAILED` — a lost record,
    # not a silent one, but the same shape. The operator line below carries the warning either way.
    if ! printf 'WRITE-FAILED the split was computed but its queue files could not be written, so every candidate is treated as HARNESS and no counts were measured%s\n' "$fell" > "$o/state/product-class" 2>/dev/null; then
      printf '[refresh] WARN: state/product-class could NOT be written either, so the record on disk is this pass'"'"'s PENDING line rather than WRITE-FAILED — read the line above, not reason=PENDING, for what happened.\n'
    fi
    printf '[refresh] WARN: split FAILED to write %s/candidates.product.txt and candidates.harness.txt — every candidate is treated as HARNESS and the product floor is unmet. No count is reported because none was measured; this is a write failure, not a finding about product work.%s\n' "$o" "$fell"
    return 0
  fi
  # ⛔ A FAILED READ MUST NEVER MANUFACTURE PRODUCT WORK (and must not stop dispatch either). Without the
  # label set EVERY candidate classifies as harness, so the product queue is empty, the floor reports
  # itself unmet, and nothing was invented from a listing that did not answer.
  wpq_degrade "$o" \
    'LISTING-FAILED the harness-label listing did not answer, so nothing is classified product' \
    '[refresh] WARN: the harness-label listing FAILED — every candidate is treated as HARNESS this pass, so the product queue is EMPTY and the product floor is unmet (orch-loop.sh says so). Nothing is dispatched on a class this pass could not read.'
  return 0
}

write_product_queues "$O" "$OR" "${PRODUCT_REPOS:-}"
# The pass reached the end of the pool (or the pool was empty), so the NEXT pass may skip this work
# if nothing it reads has moved since — see the token block above the loop (#1984 cause 2).
[ "$POOL_SWEPT" -eq 1 ] && pool_token_write 1
if [ "${skipped:-0}" -gt 0 ]; then
  echo "[refresh] skipped $skipped candidate(s) a peer is holding (recorded within the last ${COLLISION_TTL:-0}s) — walked past so the pass could reach the candidates behind them; each is retried when its record expires (agent-infra#1729)"
fi
# ⛔ A PASS THAT JUDGED NOTHING BECAUSE EVERYTHING IT WALKED WAS HELD IS NOT "NO WORK", and its
# `checked 0` is not `nothing to do` — so it says which of the two it is. It makes NO claim about the
# backlog's size: the `checked N; backlog now M` line below carries that, and a NOTE that guessed it
# was measured printing "the empty backlog is that" over a backlog of 3.
if [ "${judged:-0}" -eq 0 ] && [ "${skipped:-0}" -gt 0 ]; then
  echo "[refresh] NOTE: nothing was judged this pass — every candidate the walk reached was a recorded peer collision, so this is NOT an empty pool and NOT \"nothing to do\" (queue=${POOL_STATE:-?}, agent-infra#1729)"
fi
# ⛔ THE LANDED SET IS REPORTED ON EVERY PASS, not only when a new verdict arrives. A list that is
# filtered but never printed is the same invisible suppression it replaced: the operator asking "why
# is #N never dispatched again?" must see it here. It is not an error — it is a decision waiting to
# be made (verify + close, or re-state the remaining scope). The reaper drains it as decisions land.
if [ -s "$O/landed.txt" ]; then
  echo "[refresh] landed (awaiting verify/close or a re-scope), not queued: $(tr '\n' ' ' < "$O/landed.txt")"
fi
echo "[refresh] checked $judged; backlog now $(wc -l < "$O/candidates.txt" | tr -d ' ') issues"
# ⛔ THE STARVED-PASS SUMMARY IS SEPARATE FROM THE COUNT ON PURPOSE. `checked 2` over a 203-issue pool
# would otherwise read like a healthy pass that ran out of work; the pass stopped because it ran out of
# BUDGET, and the two facts must not share one sentence (agent-infra#1736's vocabulary: READ/EMPTY are
# statements about the queue, this is a statement about the reader's allowance).
if [ "$STARVED" -eq 1 ]; then
  echo "[refresh] budget: this pass spent $judged of its $RUN_BUDGET pre-flight run(s) and filled $n of its $LIMIT slot(s), then stopped at the reserve ($CORE_RESERVE) — the candidates not reached were left UNCHECKED, not judged; the next pass re-attempts them"
fi
