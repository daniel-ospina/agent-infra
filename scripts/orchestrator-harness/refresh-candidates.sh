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
OR="${OR:-daniel-ospina/tortoise}"
REPO="${REPO:-/Users/danielospina/Documents/GitHub/tortoise}"
SC="$REPO/.worktrees/dispatch-scout"
O="${O:-$HOME/orchestrator}"
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

MODE=refresh
LIMIT=24
case "${1:-}" in
  --check) MODE=check ;;
  '')      ;;
  *[!0-9]*) echo "[refresh] FATAL: unknown argument '$1' (usage: refresh-candidates.sh [LIMIT] | --check)" >&2; exit 2 ;;
  *)       LIMIT="$1" ;;
esac

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

# ── --check: the read-only provisioning verdict ───────────────────────────────────────────────
cmd_check() {
  local scout tool_dir
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
  # The venv is needed only for a UV PYTHON PROJECT: the tool itself is stdlib-only, so a repo with
  # no pyproject.toml (agent-infra) is served by a bare python3. That is NOT a failure.
  scout="$tool_dir"
  if [ -x "$scout/.venv/bin/python" ]; then
    echo "[refresh] check: interpreter=$scout/.venv/bin/python"
  elif [ -f "$scout/pyproject.toml" ]; then
    command -v "$UV" >/dev/null 2>&1 \
      || { echo "[refresh] check: FAIL $scout/pyproject.toml is present but 'uv' is not runnable (SCOUT_UV='${SCOUT_UV:-unset}', resolved command='$UV') — the scout venv cannot be provisioned"; return "$EXIT_TRANSIENT"; }
    echo "[refresh] check: interpreter=$scout/.venv/bin/python (to be provisioned with $UV sync)"
  elif command -v python3 >/dev/null 2>&1; then
    echo "[refresh] check: no pyproject.toml in $scout — the scout venv step is NOT APPLICABLE; interpreter=python3"
  else
    echo "[refresh] check: FAIL no pyproject.toml and no python3 on PATH — nothing can run the pre-flight tool"
    return "$EXIT_NOT_PROVISIONABLE"
  fi
  echo "[refresh] CHECK OK: this repo can be provisioned for dispatch"
  return 0
}

if [ "$MODE" = check ]; then cmd_check; exit $?; fi
mkdir -p "$O"

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
  echo "[refresh]   fix: set TORTOISE_REPO=<a tortoise checkout> or vendor tools/collision_preflight.py into the repo"
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
    PY="$(command -v python3 || true)"
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
git fetch origin --quiet 2>/dev/null || true

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
if ! gh issue list --repo "$OR" --state open --limit 500 --json number --jq '.[].number' > "$O/.open_iss" 2>/dev/null; then
  rm -f "$O/.open_iss"
  echo "[refresh] WARN: open-issue listing FAILED — reaping pass will be skipped (an unreadable listing is not an empty one)"
fi
if ! gh pr list --repo "$OR" --state all --limit 500 --json headRefName --jq '.[].headRefName' > "$O/.pr_brs" 2>/dev/null; then
  rm -f "$O/.pr_brs"
  echo "[refresh] WARN: PR listing FAILED — reaping pass will be skipped (an unreadable listing is not an empty one)"
fi
python3 - "$O" <<'PY'
import os, re, subprocess, sys
O = sys.argv[1]
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
PY
for f in "$O/.open_iss" "$O/.pr_brs"; do rm -f "$f"; done

touch "$O/checked.txt" "$O/candidates.txt"

# pool = open unassigned P0-blocker ∪ P1-severe ∪ P2-moderate, minus epics/owner-decisions
#
# ⛔ SEVERITY FIRST, AGE SECOND. Each tier emits "<tier> <number>" and the sort keys on the tier
# before the number. A bare `sort -n` over the numbers ALONE ordered by ISSUE NUMBER — i.e. oldest
# first — discarding the tier the three queries had just computed. Measured 2026-10-13: 238
# pool-eligible P2-moderate sat ahead of 20 pool-eligible P0-blocker, so the P0s were unreachable
# and every worker the harness ran was a P2 (#8465). The tier is a RANK, not a label.
# Dedupe on the NUMBER, keeping the lowest tier: the sort already put an issue's best tier first, so
# `!seen[$2]++` drops the later, weaker duplicate rather than letting one issue occupy two slots.
{
  gh issue list --repo "$OR" --state open --limit 300 --label P0-blocker --json number,assignees,title \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|lane|OWNER DECISION|decision|analysis|investigation)";"i")|not)|"0 \(.number)"' 2>/dev/null
  gh issue list --repo "$OR" --state open --limit 200 --label P1-severe --json number,assignees,title \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|OWNER DECISION)";"i")|not)|"1 \(.number)"' 2>/dev/null
  gh issue list --repo "$OR" --state open --limit 200 --label P2-moderate --json number,assignees,title \
    --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|OWNER DECISION)";"i")|not)|"2 \(.number)"' 2>/dev/null
} | sort -k1,1n -k2,2n | awk '!seen[$2]++ {print $2}' > "$O/.pool"

n=0
while read -r N; do
  [ -z "${N:-}" ] && continue
  grep -qx "$N" "$O/checked.txt" 2>/dev/null && continue
  grep -qx "$N" "$O/dispatched.txt" 2>/dev/null && continue
  n=$((n+1)); [ "$n" -gt "$LIMIT" ] && break
  # ⛔ A pre-flight that ERRORED is not a verdict — and a COLLISION is not terminal. `echo "$N" >>
  # checked.txt` used to run BEFORE the verdict was read, so a pre-flight that produced no VERDICT
  # line (API failure, missing venv, timeout) blacklisted the issue forever, invisibly: checked.txt
  # suppresses it, and the reaper above only walks dispatched.txt, so nothing ever removed the entry.
  # A COLLISION was permanent the same way, though a collision is transient by nature (the colliding
  # work lands). checked.txt is therefore written ONLY on the verdict that terminates the issue —
  # CLEAN, which is queued. Everything else is left unchecked, so the next pass re-attempts it.
  # (agent-infra#1716)
  PRE="$("$PY" "$PREFLIGHT" "$N" --repo . 2>&1)"
  V="$(printf '%s\n' "$PRE" | grep -E '^VERDICT' | head -1 | sed -E 's/.*VERDICT: (CLEAN|COLLISION).*/\1/')"
  case "$V" in
    CLEAN)
      echo "$N" >> "$O/checked.txt"
      echo "$N" >> "$O/candidates.txt"
      echo "[refresh] +#$N CLEAN -> backlog" ;;
    COLLISION)
      echo "[refresh] =#$N collision — a peer owns it, retried next pass" ;;
    *)
      echo "[refresh] ?#$N no verdict from the pre-flight — left unchecked for the next pass" ;;
  esac
done < "$O/.pool"
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
awk '!seen[$0]++' "$O/candidates.txt" > "$O/.cand" && mv "$O/.cand" "$O/candidates.txt"
echo "[refresh] checked $n; backlog now $(wc -l < "$O/candidates.txt" | tr -d ' ') issues"
