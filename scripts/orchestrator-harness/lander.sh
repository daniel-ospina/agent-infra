#!/usr/bin/env bash
# lander.sh — the fleet's DRAIN LOOP, versioned in the harness.
#
# ── WHY THIS FILE EXISTS ────────────────────────────────────────────────────────────────────────
# The fleet produces mergeable PRs continuously and drains them with a 27-line script that lived on
# ONE cloud cell (`~/lander-v3.sh` on pi-lane-1), carrying a HARDCODED list of PR numbers. It was
# never in the repo, so it dies with that cell and takes the drain with it: nothing else merges an
# already-green PR. `orch-loop.sh`'s GREEN arm is a controller-coupled dispatch (spawn one
# `merge-one.sh` per PR), not a drain: it cannot be pointed at a repo, cannot be run by hand, and
# cannot report "why did nothing land".
#
# ── WHAT THE PRECEDENT GOT RIGHT, AND WHAT IT DID NOT ───────────────────────────────────────────
# Kept from `~/lander-v3.sh` (read on pi-lane-1, 2026-10-21): a PER-PR BOUND on the rail call
# (`perl -e 'alarm'`), an rc captured IMMEDIATELY after the act (never after another `$(date)`/
# `$(gh)`), sequential single-lander discipline (no two merges racing the same base), and
# re-reading the PR state after each attempt so a landed PR is not re-handed to the rail.
# NOT copied: the hardcoded PR numbers (it lands the same 7 forever), `admin-merge.sh` as the merge
# verb (an ADMIN merge, which this repo forbids — see below), and the absence of any readiness
# discrimination: it asked only `state,mergeable`, so a PR with a FAILING CHECK was handed to the
# rail, and a PR merely waiting on CI was indistinguishable from a broken one.
#
# ── THE MEASURED BLOCKER IS CI LATENCY, NOT REVIEW (2026-10-22) ─────────────────────────────────
# PRs sat with `mergeable: MERGEABLE`, `reviewDecision: null`, 0 unresolved review threads,
# `fail=[]`, and `statusCheckRollup.state = PENDING` while 127 workflow runs were QUEUED against 5
# in progress. So the ONE distinction this component must make is:
#
#   PENDING  → WAIT. Not an action, not a failure, not a "blocked" report. It becomes READY on its
#              own; touching it (or calling it red) is how earlier lanes burned cycles re-dispatching
#              healthy PRs.
#   FAILED   → SKIP, and NAME the failing checks. That is a real defect for a fixer, never a merge.
#
# Conflating the two is the defect this file exists to close, so `lander.classify` keeps them in
# separate counters and the report has separate words for them.
#
# ── READINESS (the selection rule, and its source of truth) ─────────────────────────────────────
# A PR is READY iff: not a draft ∧ `mergeable=MERGEABLE` ∧ `mergeStateStatus ∈ {CLEAN,HAS_HOOKS}`
# ∧ every check green (zero failures, zero pending). Anything else is reported with its reason.
#
# ⛔ `gh pr list` CANNOT ANSWER THIS — MEASURED on daniel-ospina/agent-infra 2026-10-21: 55 of 57
# open PRs came back `mergeable: UNKNOWN`, `mergeStateStatus: ""` from the LIST endpoint, while the
# SAME PRs read individually answered `MERGEABLE BEHIND`. GitHub computes mergeability lazily, and
# only the single-PR read triggers it. A lander that trusted the list would see "UNKNOWN" for
# everything and merge nothing (or, worse with a fail-open polarity, merge everything). So: LIST for
# the candidate set only, ONE `gh pr view` per candidate for the decision.
#
# ── THE MERGE VERB: THE REPO'S AUTHORITY, NEVER AN ADMIN MERGE ─────────────────────────────────
# ⛔ `admin-merge.sh` (what the cell lander uses) and `--admin` bypass branch protection, and
# `PIPELINE_COMPLIANCE_SKIP` does the same by another name. None of them are reachable from here:
# this file never sets them and never passes `--admin`. The merge is the one `gh pr merge` the
# harness already trusts, head-PINNED with `--match-head-commit` (the same hazard `merge-one.sh`
# documents: `gh pr merge` is not pinned to a sha, so a push that races the call would land a tree
# nobody classified). Where the ref moves, the merge FAILS and the PR is re-read next run — the
# safe direction.
#
# Reused rather than reimplemented: `repo-authority.sh` — the ONE home for "what does this repo
# require, and what is its merge authority", sourced by BOTH `orch-loop.sh` and `merge-one.sh` so
# the three cannot disagree. A `rail`-authority repo is NOT merged here directly: its rail owns the
# merge (that is #1764, and a raw `gh pr merge` on such a repo lands a PR on its required checks
# with no head-bound evidence). The lander leaves those to `merge-one.sh` and says so.
#
# ── THE NUMBER NOTHING SURFACED: CI QUEUE DEPTH ────────────────────────────────────────────────
# Printed once per run, before any PR is acted on, from REST `/actions/runs` totals. It is the
# reason a "ready" PR is not landing, and it is invisible in every other fleet report.
#
# USAGE
#   lander.sh --repo owner/name [--dry-run] [--max N] [--no-stale-rerun]
#   lander.sh --repo-path <git checkout> ...     # --repo derived from its origin remote
#   O=~orchestrator lander.sh ...                # where logs/state live (default $HOME/orchestrator)
#
# EXIT  0 = the run completed (merges may or may not have happened; per-PR verdicts are printed)
#       1 = at least one merge/enqueue command failed (a real error, named)
#       2 = the open-PR board could not be read — NOTHING was merged (fail-closed)
#       3 = the repo's merge contract could not be established (unreadable branch protection, an
#           authority that is neither gate nor rail, or repo-authority.sh missing) — NOTHING merged
set -uo pipefail

OR=""; DRY=0; MAX=200
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      OR="${2:-}"; shift 2 ;;
    --repo=*)    OR="${1#--repo=}"; shift ;;
    --repo-path) RP="${2:-}"; shift 2 ;;
    --repo-path=*) RP="${1#--repo-path=}"; shift ;;
    --max)       MAX="${2:-}"; shift 2 ;;
    --max=*)     MAX="${1#--max=}"; shift ;;
    --dry-run)   DRY=1; shift ;;
    --no-stale-rerun) STALE_RERUN_OFF=1; shift ;;
    -h|--help)   sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[lander] unknown argument: $1" >&2; exit 64 ;;
  esac
done
case "$MAX" in ''|*[!0-9]*|0) echo "[lander] --max must be a positive integer, got '$MAX'" >&2; exit 64 ;; esac

O="${O:-$HOME/orchestrator}"; mkdir -p "$O/logs" "$O/state" 2>/dev/null || true
LOG="$O/logs/lander.log"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
# ⛔ THE gh SHIM MUST STAY FIRST, for the reason merge-one.sh documents at the same block (#1988):
# the two lines above prepend the tool dirs, so a REAL gh outranks the seeded REST adapter
# (`$O/gh-rest`) / cell serialiser (`$O/gh-limit`) and the layer is INERT — it reports protection
# and provides none. Adapter LAST so `$O/gh-rest` (which calls the same helper) wins where it exists.
if [ -d "$O/gh-limit" ]; then PATH="$O/gh-limit:$PATH"; fi
if [ -d "$O/gh-rest" ]; then PATH="$O/gh-rest:$PATH"; fi
export PATH

# --repo-path is a convenience: the same repo a lane works in, named by its origin remote.
if [ -z "$OR" ] && [ -n "${RP:-}" ]; then
  OR="$(git -C "$RP" remote get-url origin 2>/dev/null | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\).*#\1#p' | sed 's/\.git$//')"
fi
case "$OR" in
  */*) : ;;
  *) echo "[lander] need --repo owner/name (or --repo-path with a github origin remote)" >&2; exit 64 ;;
esac

log_line()  { printf '[lander] %s\n' "$*"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }
note() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }

# ── ONE JSON reader for the whole file ─────────────────────────────────────────────────────────
# python3 (not jq) for the same reason merge-one.sh uses it: the gh shims already depend on it, and
# these payloads carry whole check lists whose names contain anything.
# modes: list | view | checks
#   list   -> one "<number>" per line (the candidate set only — everything else is read per PR)
#   view   -> "<MERGEABLE|CONFLICTING|UNKNOWN>\t<STATE>\t<draft 0|1>\t<head>"
#   checks -> "<green>\t<pending>\t<failed>\t<failed-names-space-joined>"
#             rc 3 = the payload was NOT a JSON array (an incomplete read, never "no checks")
py() { # py <mode>
  python3 -c '
import sys, json
# ⛔ A UNIT SEPARATOR, NOT A TAB. The shell builtin `read` treats TAB as IFS WHITESPACE, so a run of separators
# collapses and an EMPTY field is swallowed: "1\t0\t0\t\tworkflow-drift (cancelled)" read into five
# names put the cancelled-check text in `names` and left `odd` empty (caught by lander.test.sh case
# 7b), and an empty mergeStateStatus shifted every field of the `view` payload the same way.
US = "\x1f"
mode = sys.argv[1]
raw = sys.stdin.read()
try:
    d = json.loads(raw) if raw.strip() else None
except Exception:
    d = None
def s(v): return str(v if v is not None else "")
if mode == "list":
    if not isinstance(d, list): raise SystemExit(3)
    for o in d:
        # ONE FIELD: the list only yields the CANDIDATE SET. A per-row multi-field line here was read
        # back with a whitespace `awk`, which does not split on the unit separator — it handed the
        # loop a PR "number" made of every field concatenated (caught by lander.test.sh).
        print(s(o.get("number")))
elif mode == "view":
    if not isinstance(d, dict): raise SystemExit(3)
    print(US.join([s(d.get("mergeable")) or "UNKNOWN", s(d.get("mergeStateStatus")),
                     "1" if d.get("isDraft") else "0", s(d.get("headRefOid"))]))
elif mode == "checks":
    if not isinstance(d, list): raise SystemExit(3)
    # ⛔ ALLOW-LIST POLARITY, the merge rail s own rule: green is a SHORT list, and every value this
    # file has not been taught is neither green nor pending — it is a FAILURE to be named. A denylist
    # would let an unrecognised conclusion (or a null) fall through as "fine".
    green_ok = {"success", "neutral", "skipped"}
    pending  = {"pending", "queued", "in_progress", "waiting", "requested", "expected"}
    # ⛔ NON-RED IS NOT GREEN, AND NOT A FAILURE EITHER (the fleet s own polarity, measured against
    # live data 2026-10-21): a CANCELLED or STALE check is non-red — the merge rail does not refuse
    # on it — but its verification never COMPLETED, so it can never authorise a merge here. It gets
    # its own bucket and its own words: calling it "failed" would report a red tree that does not
    # exist (and send a fixer after nothing), while calling it green would merge unverified work.
    nonred   = {"cancelled", "stale"}
    g = p = f = 0; names = []; odd = []
    # ⛔ A RE-RUN ADDS A CHECK-RUN; IT NEVER CLEARS ONE, so the same (workflow, job) legitimately
    # appears twice on one head — a superseded `failure` beside a newer `success`. Counting every row
    # made a re-run worthless: the PR kept reading "1 FAILED check(s)" (measured by the reviewer with
    # a two-row fixture, and and by this lane own live re-runs, whose two attempts are co-resident on
    # the head). Take the NEWEST by `startedAt` per (workflow, name) and DROP the superseded ones.
    # ⛔ The dedupe is only applied when EVERY row in a group carries `startedAt`: an undateable row
    # cannot be ordered, and guessing would let a red fall through a gap. Fail-closed = count it.
    groups = {}
    for c in d:
        groups.setdefault(((c.get("workflow") or ""), (c.get("name") or "")), []).append(c)
    deduped = []
    for _k, items in groups.items():
        if len(items) > 1 and all(x.get("startedAt") for x in items):
            newest = max(items, key=lambda x: x["startedAt"])
            # ⛔ SAME SECOND IS NOT A RULING. `startedAt` has one-second resolution, and `max()` returns
            # the FIRST maximal element — so a red and a green attempt started in the same second
            # resolved by list order (measured: [success,failure] merged, [failure,success] did not).
            # On a tie, PREFER THE NON-GREEN ROW: the safe direction is "still red".
            tied = [x for x in items if x["startedAt"] == newest["startedAt"]]
            if len(tied) > 1:
                bad = [x for x in tied if (x.get("state") or "").strip().lower() not in green_ok | pending]
                deduped.append(bad[0] if bad else newest)
            else:
                deduped.append(newest)
        else:
            deduped.extend(items)
    for c in deduped:
        st = (c.get("state") or "").strip().lower()
        if st in green_ok: g += 1
        elif st in pending: p += 1
        elif st in nonred:
            odd.append((c.get("name") or "<unnamed>") + " (" + st + ")")
        else:
            f += 1
            names.append((c.get("name") or "<unnamed>") + ((" (" + st + ")") if st else " (unknown)"))
    print(US.join([str(g), str(p), str(f), " ".join(names), " ".join(odd)]))
' "$1" 2>/dev/null
}

# ── the numbers this component exists to surface ──────────────────────────────────────────────
# REST, not GraphQL: a per-PR count is a `total_count` field, and GraphQL is the rate-limited
# bucket. A failed read is NAMED as unreadable — it never prints 0, because "0 queued" is an
# all-clear and an unread all-clear is the fail-open this fleet keeps paying for.
QUEUED=""; INPROG=""
lander_queue_depth() {
  QUEUED="$(gh api "repos/$OR/actions/runs?status=queued&per_page=1" --jq .total_count 2>/dev/null)"
  INPROG="$(gh api "repos/$OR/actions/runs?status=in_progress&per_page=1" --jq .total_count 2>/dev/null)"
  case "${QUEUED:-}" in ''|*[!0-9]*) QUEUED="unreadable" ;; esac
  case "${INPROG:-}" in ''|*[!0-9]*) INPROG="unreadable" ;; esac
  if [ "$QUEUED" = unreadable ] || [ "$INPROG" = unreadable ]; then
    log_line "CI queue depth: UNAVAILABLE (queued=$QUEUED in-progress=$INPROG — the runs read failed; a PR waiting on CI cannot be distinguished from a stalled one this run)"
  else
    log_line "CI queue depth: $QUEUED queued, $INPROG in progress ($(( QUEUED + INPROG )) workflow runs) — REST /repos/$OR/actions/runs"
  fi
}

# ── the repo's merge contract, ONCE per run (the same module merge-one.sh sources) ───────────
# ⛔ NOT REIMPLEMENTED. `repo-authority.sh` is the ONE home for "what does this repo require, and
# which verb may merge it", sourced by BOTH orch-loop.sh and merge-one.sh. Reading it here is what
# makes "never bypass" true rather than aspirational: on a repo whose authority is its own RAIL, a
# raw `gh pr merge` lands the PR on the required checks alone, with no head-bound review evidence
# (#1764) — the exact bypass this component is forbidden to perform. And the refusal below is
# merge-one.sh's OWN refusal condition, copied rather than invented, so a PR that merge-one would
# refuse is never landed here by a looser reading of the same branch protection.
AUTH=""; REQ=""
lander_authority() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  if [ -f "$O/repo-authority.sh" ]; then . "$O/repo-authority.sh"
  elif [ -f "$here/repo-authority.sh" ]; then . "$here/repo-authority.sh"
  else AUTH="unknown"; log_line "merge authority: UNKNOWN — repo-authority.sh was not found (looked in $O and ${here:-<unresolved>}), so nothing merges this run"; return 0
  fi
  if ! command -v resolve_required_checks >/dev/null 2>&1 || ! command -v merge_authority >/dev/null 2>&1; then
    AUTH="unknown"; log_line "merge authority: UNKNOWN — repo-authority.sh is stale/partial (no resolve_required_checks/merge_authority); nothing merges this run"; return 0
  fi
  REQ_OVERRIDE="${REQ_OVERRIDE:-${LANDER_REQ:-}}"
  resolve_required_checks "$OR"
  AUTH="$(merge_authority "$REQ")"
  local why=""
  [ -z "${REQ:-}" ] && why="the required-check set is EMPTY"
  case "$AUTH" in gate|rail) : ;; *) why="${why:+$why; }the merge authority is '${AUTH:-<unset>}' (neither gate nor rail)" ;; esac
  if [ "${REQ_SOURCE:-}" = "fallback" ] && [ -z "$REQ_OVERRIDE" ]; then
    why="${why:+$why; }branch protection was UNREADABLE (REQ_SOURCE=fallback) and no REQ/LANDER_REQ override was supplied"
  fi
  if [ -n "$why" ]; then
    AUTH="unknown"
    log_line "merge authority: UNKNOWN — $why. Nothing merges this run (the same fail-closed refusal merge-one.sh makes, agent-infra#1764): an unreadable contract is not a licence to merge."
    return 0
  fi
  log_line "merge authority: $AUTH (required checks: [${REQ}] source=${REQ_SOURCE:-read}${REQ_OVERRIDE:+ — OPERATOR OVERRIDE})"
}

# ── merge queue presence, once per run ───────────────────────────────────────────────────────
# Detected from REST branch rules (a `merge_queue` rule type), NOT GraphQL. A rules read that fails
# is reported as unknown and falls back to squash: squash is a valid merge on a repo with no queue,
# and on a repo WITH a queue GitHub itself refuses a direct merge, which is loud rather than wrong
# (a wrong answer here would be merging past the queue; refusing is the safe direction).
HAS_QUEUE=0
lander_detect_queue() {
  local n
  n="$(gh api "repos/$OR/rules/branches/main" --jq '[.[]|select(.type=="merge_queue")]|length' 2>/dev/null)"
  case "${n:-}" in
    ''|*[!0-9]*) log_line "merge queue: UNKNOWN (the branch-rules read failed or answered something that is not a count) — merging with squash, which GitHub refuses if a queue is required"; HAS_QUEUE=0 ;;
    0) log_line "merge queue: none on main — merging with squash" ;;
    *) log_line "merge queue: PRESENT ($n rule) — handing ready PRs to the queue with --auto"; HAS_QUEUE=1 ;;
  esac
}

# ── STALE-BY-BASE RE-RUN: a RE-MEASUREMENT, NEVER A FIX ──────────────────────────────────────
# THE MEASURED TAX. GitHub does NOT re-run a PR's checks when the base branch moves: a
# `pull_request` run is bound to the tree it was dispatched for, and a base push creates `push`
# runs on MAIN, not new PR runs (documented: "Events that trigger workflows" — `pull_request`'s
# activity types contain no base-updated event, and `GITHUB_SHA` on a `pull_request` run is "the
# last merge commit of the pull request merge branch" AT DISPATCH). So when a base-side repair
# lands, every PR that failed for the OLD base keeps that failure, and the fleet re-discovers it
# PR by PR, forever. Measured 2026-10-23 on daniel-ospina/agent-infra: 50 open PRs red on
# `sigpipe-grep` for 5 undeclared `printf | grep -q` pipes that #2412 had DELETED from main
# (12:06:35Z, dd0b00716203) — and 48 of those were computed before the base tip
# (2026-10-23T12:51:03Z, 8b7322d2). That is not 50 defects.
#
# ⛔ WHAT A RE-RUN CAN AND CANNOT DO — MEASURED, and it is not what the first draft assumed.
# A re-run re-executes the ORIGINAL EVENT (`GITHUB_SHA`/`GITHUB_REF` are unchanged: the REST docs
# say so, and #2172 measured it — its run 39880090973 attempt 2 re-ran the SAME merge commit and
# `sigpipe-grep` came back FAILURE again). So a re-run CANNOT pick up a base-side repair: the job
# still checks out the merge commit it was dispatched for. What a re-run therefore buys is a
# CLASSIFICATION, not a cure — and that classification is the thing the fleet does not have today:
#   SUCCESS     the red did not reproduce on the same tree. It was a flake, or an input that lives
#               outside the tree changed (a marker posted later, an upstream service, a cache).
#   STILL-RED   the red belongs to the tree. A base-side repair does NOT reach it by re-running —
#               the branch has to be updated onto the new base (which MOVES THE HEAD and therefore
#               stales its review attestation, so it is a deliberate act for that PR's owner, never
#               something this bounded drain-loop step may do on its own).
# Recording which of the two a red is, at fleet scale, IS the deliverable. Nothing is cleared by
# assumption; a `still-red` stays red, in the report and in the state file.
#
# WHAT THIS STEP IS FOR. It RE-MEASURES a check that may have measured a tree that no longer
# exists. It is not a fix, not a suppression, and not an auto-pass:
#   * it only ever selects a check that is RED *and* started BEFORE the current base tip's
#     committer date — a red whose `started_at` is at or after the tip describes the tree we have;
#   * the outcome is RECORDED as `success` or `still-red`. `still-red` is a SUCCESS of this step:
#     it means the failure was not the base's, and it stays visible as work for a fixer. Nothing
#     here edits a check, deletes one, skips one, or touches branch protection / the required set.
#
# ⛔ WHY `rerun-failed-jobs` AND NOT `check-runs/{id}/rerequest`. `rerequest` is documented for
# check runs created by a GitHub App that consumes the `rerequested` webhook; a GitHub ACTIONS
# check run is not one (403 "does not belong to the authenticated GitHub App" / 422 "not
# rerequestable"). Every check this step selects is an Actions job, so `rerequest` is not merely
# second-best — it is a call that can answer 201 and re-run NOTHING. `actions/runs/{id}/
# rerun-failed-jobs` is the documented verb: same run id, `run_attempt += 1`, a new check run per
# failed job, and the passing jobs are left alone.
#
# ⛔ A RE-RUN ADDS A CHECK-RUN, IT DOES NOT REPLACE ONE. So the OUTCOME is read as the NEWEST
# attempt by `databaseId` within the group (app, workflow, job name) — never from a rollup state,
# never by taking the first match. A reader that ignores this reports the PR red minutes after it
# went green, which is the same class of defect as the one this step exists to undo.
#
# ⛔ THIS IS NOT THE `pipeline-compliance` MECHANISM, AND THE TWO MUST NOT BE MERGED (#2467).
# `pipeline-compliance` re-reads a head-bound marker that is POSTED AFTER its run concluded, so its
# run cannot re-evaluate itself; the remedy there is the RECORDER triggering a re-run, owned by
# another lane. Its staleness is 'the run finished before its input existed'. Ours is 'the run
# measured a base that has since changed'. A single "re-run everything red" sweep would hide both
# defects behind one command — and would also re-run reds that are genuinely the branch's own.
#
# ⛔ AND IT IS NOT `ci-failure-set.sh` / `ci_exemption.py` EITHER. Those decide CONTENT identity
# ("is this failure ALSO red on main?") by comparing failed ids against main's baseline. This step
# decides TIME ("was this measurement taken against a base that has since changed?") and never
# exempts anything: after a re-run the check is simply re-judged on its merits by every existing
# gate.
#
# BUDGET. A re-run POST costs 5 REST points (documented: POST/PATCH/PUT/DELETE = 5, GET = 1) from
# the ONE 5000/hr bucket four boxes share. So N = min(CAP, floor((core_remaining - RESERVE)/5)) and
# the number is PRINTED — a step that spends a shared budget must say what it spent, and 0 is a
# legitimate answer (it means the fleet is out of budget, not that the tree is green).
STALE_RERUN="${STALE_RERUN:-1}"                       # 0 = step disabled
STALE_RERUN_CAP="${STALE_RERUN_CAP:-8}"               # hard ceiling on re-runs PER RUN
STALE_RERUN_RESERVE="${STALE_RERUN_RESERVE:-500}"     # REST points kept for the rail/lander itself
STALE_RERUN_WINDOW="${STALE_RERUN_WINDOW:-10800}"     # 3 h: never re-run the same RUN twice inside it
# ⛔ `pipeline-compliance` IS EXCLUDED BY DEFAULT, AND NOT BECAUSE IT IS ADVISORY (it is not — it is
# the repo's ONLY REQUIRED CHECK). Its red is a DIFFERENT defect with a DIFFERENT owner (#2467): its
# run concluded BEFORE the head-bound attestation marker was posted, so it cannot re-evaluate itself
# and a re-run re-reads a marker that was already there. Ours is "the run measured a base that has
# since changed". Folding them into one sweep would hide both behind one command — so the exclusion
# is PRINTED, with its count, and the check stays red and visible for its own owner.
STALE_RERUN_EXCLUDE="${STALE_RERUN_EXCLUDE:-pipeline-compliance}"
STALE_RERUN_STATE=""

# The plan reader. ONE python, fed three files, emitting ONE plan the bash below executes. Policy
# (what is stale, what is already in the window, what the last re-run concluded) lives HERE; the
# transport (the POST, the state append, the log line) lives in bash, like the rest of this file.
lander_stale_plan() { # <rollup.json> <board.txt> <base_iso> <state> <cap> <window> <now> <exclude>
  python3 - "$@" <<'PY'
import json, os, sys
from datetime import datetime, timezone

rollup_p, board_p, base_iso, state_p, cap, window, now, exclude = sys.argv[1:9]
cap, window, now = int(cap), int(window), int(now)
exclude = {e.strip() for e in exclude.split(",") if e.strip()}
GREEN = {"success", "neutral", "skipped"}
NONRED = {"cancelled", "stale"}          # non-red, but verification never completed

def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

try:
    base_dt = ts(base_iso)
except Exception:
    print("FATAL\tbase tip committer date is unreadable — NOTHING is selected (a step with no "
          "clock cannot decide what is stale, and guessing everything would re-run the fleet)")
    raise SystemExit(0)

# The board the LANDER read is the only set this step may act on. A PR the lander did not see is
# not this step's business — that is what keeps ONE walker instead of a second opinion (#1872).
board = {l.strip() for l in open(board_p) if l.strip()}
try:
    doc = json.load(open(rollup_p))
except Exception as e:
    print(f"FATAL\tthe check surface could not be parsed ({e}) — nothing selected")
    raise SystemExit(0)
if doc.get("errors"):
    print("FATAL\tthe check-surface read returned GraphQL errors — nothing selected: "
          + json.dumps(doc["errors"])[:200])
    raise SystemExit(0)
try:
    _prs = doc["data"]["repository"]["pullRequests"]
    nodes = _prs["nodes"]
except Exception:
    print("FATAL\tthe check-surface read has no pull request nodes — nothing selected")
    raise SystemExit(0)
if (_prs.get("pageInfo") or {}).get("hasNextPage"):
    print("FATAL\tthe PR list was TRUNCATED (pageInfo.hasNextPage) — nothing selected: with more than "
          "100 open PRs this read is a SAMPLE, and acting on a sample is how the fleet ends up with a "
          "second, disagreeing opinion about the board")
    raise SystemExit(0)
_trunc = []
for _p in nodes:
    for _cs in (((_p.get("commits") or {}).get("nodes") or [])[:1]):
        _ctx = ((((_cs.get("commit") or {}).get("statusCheckRollup") or {}).get("contexts")) or {})
        if (_ctx.get("pageInfo") or {}).get("hasNextPage"):
            _trunc.append(str(_p.get("number")))
if _trunc:
    print("FATAL\tthe check surface is TRUNCATED for PR(s) " + ",".join(_trunc[:10]) +
          " (pageInfo.hasNextPage on contexts) — nothing selected: the NEWEST attempt may be outside "
          "the first 100, and an older GREEN attempt inside it would make a stale red invisible")
    raise SystemExit(0)

# ── prior state: unresolved re-runs (R) and resolved outcomes (O) ────────────────────────────
unresolved, resolved, deferred = [], [], []
if os.path.exists(state_p):
    for line in open(state_p, errors="replace"):
        f = line.rstrip("\n").split("\t")
        if not f or not f[0]:
            continue
        try:
            epoch = int(f[1])
        except Exception:
            continue
        if now - epoch > 7 * 86400:      # prune: a week is plenty of memory for this question
            continue
        if f[0] == "R":
            unresolved.append(f)
        elif f[0] == "D":
            # A refused re-run (`403 This workflow is already running`). It is NOT an outcome —
            # nothing ran — but it must spend the window, or the next pass pays another 5 points
            # to learn the same thing while the run is still executing.
            deferred.append(f)
        else:
            resolved.append(f)

# ── the newest attempt per (app, workflow, job name), by databaseId ──────────────────────────
newest = {}          # pr -> {(app,wf,name): dict}
for pr in nodes:
    num = str(pr.get("number"))
    cs = (pr.get("commits") or {}).get("nodes") or []
    ctx = (((cs[0].get("commit") or {}).get("statusCheckRollup") or {}).get("contexts") or {}).get("nodes") \
        if cs else []
    g = {}
    for c in ctx or []:
        if c.get("__typename") != "CheckRun":
            continue
        suite = c.get("checkSuite") or {}
        app = (suite.get("app") or {}).get("slug") or "?"
        wr = suite.get("workflowRun") or {}
        wf = (wr.get("workflow") or {}).get("name") or "?"
        k = (app, wf, c.get("name"))
        if k not in g or (c.get("databaseId") or 0) > (g[k]["c"].get("databaseId") or 0):
            g[k] = {"c": c, "run": wr.get("databaseId")}
    newest[num] = g

# ── outcomes for re-runs an EARLIER run of this step asked for ────────────────────────────────
# A re-run is asynchronous, so the honest verdict for one can only be read on a LATER pass. This
# is where `still-red` is produced — never assumed green, never dropped.
keep = list(deferred)
for f in unresolved:
    # R fields: R epoch pr run name cid started [app] [wf]   (app/wf are optional: older rows lack them)
    _, epoch, pr, run, name, cid, started = (f + [""] * 9)[:7]
    app, wf = ((f + [""] * 9)[7] or "", (f + [""] * 9)[8] or "")
    g = newest.get(pr) or {}
    # ⛔ THE FULL GROUP KEY, NOT THE FIRST NAME MATCH. Two workflows can publish the same job name;
    # a name-only match reported SUCCESS from the wrong one (measured by the reviewer: a red `CI/test`
    # masked by a green `Stress/test`). Fall back to name-only ONLY for a legacy row with no app/wf.
    if app or wf:
        hit = g.get((app, wf, name))
    else:
        hit = next((v for k, v in g.items() if k[2] == name), None)
    if hit is None:
        keep.append(f); continue            # nothing readable for that name yet: still unknown
    new = hit["c"]
    if str(new.get("databaseId")) == cid:
        keep.append(f); continue            # the re-run has produced no new attempt yet
    status = (new.get("status") or "").lower()
    concl = (new.get("conclusion") or "").lower()
    if status and status != "completed":
        keep.append(f); continue            # in flight: ask again next pass
    outcome = "success" if concl in GREEN else "still-red"
    print(f"OUTCOME\t{pr}\t{run}\t{name}\t{new.get('databaseId')}\t{outcome}\t{cid}\t{started}")
    resolved.append(["O", str(now), pr, run, name, str(new.get("databaseId")), outcome])

# ── selection: RED, dated, started BEFORE the base tip, not already in the window ─────────────
cands, undated, nonactions = [], [], 0
excluded = 0
# ⛔ THE WINDOW IS THE BOUND, NOT THE PRUNE. `window` used to be parsed and never referenced, so the
# real suppression was the 7-day prune — and a `403 workflow is already running` deferral (which
# clears in minutes) blocked that run's re-measurement for a week while the report claimed the
# ${STALE_RERUN_WINDOW}s window. Only records INSIDE the window suppress; unresolved R records older
# than the window are still resolved for their outcome (that is a read, not a re-run).
seen_runs = {(f[2], f[3]) for f in unresolved + deferred if now - int(f[1]) <= window}
for pr in nodes:
    num = str(pr.get("number"))
    if num not in board:
        continue
    for (app, wf, name), hit in (newest.get(num) or {}).items():
        c = hit["c"]
        status = (c.get("status") or "").lower()
        concl = (c.get("conclusion") or "").lower()
        if status and status != "completed":
            continue
        if concl in GREEN or concl in NONRED:
            continue                        # allow-list polarity: everything else is RED
        if name in exclude:
            excluded += 1; continue         # a DIFFERENT defect with a DIFFERENT owner — named below
        if not hit.get("run"):
            nonactions += 1                 # a non-Actions check has no run to re-run
            continue
        sa = c.get("startedAt")
        if not sa:
            undated.append((num, name)); continue
        if not (ts(sa) < base_dt):
            continue                        # ⛔ AT OR AFTER the base tip: this tree is current
        if (num, str(hit["run"])) in seen_runs:
            print(f"SKIPWIN\t{num}\t{hit['run']}\t{name}")
            continue
        cands.append((sa, num, str(hit["run"]), name, str(c.get("databaseId")), sa, app, wf))

# ⛔ THE EXCLUSION IS PER CHECK, BUT THE MUTATION IS PER RUN. `rerun-failed-jobs` re-runs EVERY
# failed job in the run, so a run that also carries an excluded check must not be selected at all —
# otherwise the excluded check is re-run by the same POST, which is exactly the folding-together this
# step's header forbids. Today `pipeline-compliance` lives in its own workflow so it cannot share a
# run with a `ci.yml` job; that is the LAYOUT, not an invariant, so it is enforced here too.
excluded_runs = set()
for pr in nodes:
    num = str(pr.get("number"))
    if num not in board:
        continue
    for (app, wf, name), hit in (newest.get(num) or {}).items():
        if name in exclude and hit.get("run"):
            excluded_runs.add(str(hit["run"]))
excluded_run_checks = len(excluded_runs)
cands = [c for c in cands if c[2] not in excluded_runs]

cands.sort()                                # oldest staleness first, so a bounded pass drains fairly
chosen, over, runs = [], 0, set()
for sa, num, run, name, cid, started, app, wf in cands:
    if run not in runs:
        if len(runs) >= cap:
            over += 1; continue
        runs.add(run)
    chosen.append((sa, num, run, name, cid, started, app, wf))

for sa, num, run, name, cid, started, app, wf in chosen:
    print(f"RERUN\t{num}\t{run}\t{name}\t{cid}\t{started}\t{app}\t{wf}")
stale_prs = {c[1] for c in cands}
cand_runs = len({c[2] for c in cands})
print(f"INFO\t{base_iso}\t{len(cands)}\t{len(stale_prs)}\t{cand_runs}\t{len(chosen)}\t{len(runs)}\t{over}\t"
      f"{len(undated)}\t{nonactions}\t{len(keep)}\t{excluded}\t{excluded_run_checks}")
for num, name in undated[:10]:
    print(f"UNDATED\t{num}\t{name}")

# Rewrite the state: unresolved re-runs kept, resolved ones folded into the O log (bounded).
try:
    with open(state_p + ".new", "w") as fh:
        for f in keep:
            fh.write("\t".join(f) + "\n")
        for f in resolved[-200:]:
            fh.write("\t".join(f) + "\n")
    os.replace(state_p + ".new", state_p)
except Exception as e:
    print(f"STATEERR\t{state_p}: {e}")
PY
}

lander_stale_rerun() { # <board-numbers-file>  (one PR number per line, from the board THIS run read)
  STALE_RERUN_STATE="$O/state/stale-rerun-$(printf '%s' "$OR" | tr '/' '-').tsv"
  mkdir -p "$O/state" 2>/dev/null || true
  # ⛔ THE BOARD IS A FILE ARGUMENT, NOT STDIN, for two measured reasons:
  #   1. every `gh` call below inherits the process's stdin, and `gh` can consume it — a `cat`
  #      placed after those reads got an EMPTY board and this step selected nothing while
  #      reporting a clean run (83 PRs read, stale-by-base=0 against a population of 160);
  #   2. a manual `lander.sh` run has a TTY on stdin, so even the FIRST `cat` would block forever
  #      waiting for an EOF that never comes (measured: the step hung and the run had to be killed).
  # An explicit file is bounded in both directions, and its absence is a named refusal.
  local tmp boardf="${1:-}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/lander-stale.XXXXXX")" || {
    log_line "stale-rerun: no scratch directory (mktemp failed under ${TMPDIR:-/tmp}) — 0 re-runs this run"
    return 0
  }
  if [ -z "$boardf" ] || [ ! -r "$boardf" ]; then
    log_line "stale-rerun: no readable board file was passed — 0 re-runs this run (nothing may be acted on that this run did not see)"
    rm -rf "$tmp"; return 0
  fi
  if [ "$STALE_RERUN" != 1 ]; then
    log_line "stale-rerun: DISABLED (STALE_RERUN=$STALE_RERUN) — no re-runs this run"; rm -rf "$tmp"; return 0
  fi
  # THE BUDGET, before anything is spent. `/rate_limit` is documented as NOT counting against the
  # limit, so reading it costs nothing — and 5 points per POST is the documented cost of a mutation.
  # ⛔ THE KNOBS ARE VALIDATED BEFORE THEY ARE USED, because each one bounds a MUTATION. This
  # block used to sit AFTER `n` was derived, so a typo'd `STALE_RERUN_CAP=10O` made the `-gt`
  # comparison error out and left `n` at the budget-derived value — the guard was inert for the one
  # case it exists for (measured: n=880 survived `[ 880 -gt 10O ]`). Out-of-range values are CLAMPED
  # to the documented bounds, never honoured and never silently ignored.
  # ⛔ LENGTH IS CHECKED BEFORE THE COMPARISON: bash arithmetic ERRORS on an overflowed integer, and
  # without `set -e` the `&&` merely short-circuits, so `STALE_RERUN_CAP=9999…` (a plausible fat-finger)
  # left the cap astronomic and N came straight from the bucket — 900 POSTs against the ONE shared
  # 5000/hr pool. A 4+-digit cap is not a value this step has any use for, so it is clamped, not run.
  case "${STALE_RERUN_CAP:-}" in ''|*[!0-9]*) STALE_RERUN_CAP=8 ;; esac
  [ "${#STALE_RERUN_CAP}" -gt 2 ] && STALE_RERUN_CAP=50
  [ "$STALE_RERUN_CAP" -gt 50 ] && STALE_RERUN_CAP=50
  # ⛔ THE RESERVE NEEDS THE SAME LENGTH GUARD AS THE CAP: bash arithmetic wraps an overflowed integer,
  # so `STALE_RERUN_RESERVE=18446744073709552116` with rem=1000 computed `n=180` — a POSITIVE n from a
  # reserve that should have produced 0 (measured). The cap still bounded the spend, but the documented
  # `min(cap, (remaining-reserve)/5)` was violated and it spent against a bucket with no headroom.
  case "${STALE_RERUN_RESERVE:-}" in ''|*[!0-9]*) STALE_RERUN_RESERVE=500 ;; esac
  [ "${#STALE_RERUN_RESERVE}" -gt 6 ] && STALE_RERUN_RESERVE=500
  case "${STALE_RERUN_WINDOW:-}" in ''|*[!0-9]*) STALE_RERUN_WINDOW=10800 ;; esac
  [ "${#STALE_RERUN_WINDOW}" -gt 7 ] && STALE_RERUN_WINDOW=10800
  # ⛔ EVERY CALL THIS STEP MAKES IS BOUNDED (`GH_LIMIT_NO_WAIT=1`). The gh layer backs off for up to
  # MAX_WAIT=300s on a shared-bucket refusal; inside a drain loop that is not patience, it is a STALL
  # of the whole run (measured: the step blocked and the lander had to be killed at 150s). A limited
  # call now returns AT ONCE with the named rate-limit error, which this step reports as a refusal —
  # and a refusal is recorded as a deferral, never read as green.
  local rem n now kind a b c d e f
  # ⛔ NOT `--jq`: this call may be served by the seeded REST adapter, and a projection that fails
  # inside the adapter yields an EMPTY string that is indistinguishable from "no budget". Parse the
  # body here, where a failure to parse is a named failure and not a silent zero.
  rem="$(GH_LIMIT_NO_WAIT=1 gh api rate_limit 2>/dev/null | python3 -c 'import json,sys
for f in (sys.stdin,):
    try: d=json.load(f)
    except Exception: print(""); raise SystemExit
r=((d.get("resources") or {}).get("core") or {}).get("remaining")
print(r if isinstance(r,int) else "")' 2>/dev/null)"
  case "${rem:-}" in
    ''|*[!0-9]*)
      log_line "stale-rerun: REST budget UNREADABLE (raw='${rem:-<empty>}') — 0 re-runs this run (an unbounded mutation on a shared 5000/hr bucket is not a measurement, it is a race)"
      rm -rf "$tmp"; return 0 ;;
  esac
  n=$(( (rem - STALE_RERUN_RESERVE) / 5 ))
  [ "$n" -gt "$STALE_RERUN_CAP" ] && n="$STALE_RERUN_CAP"
  [ "$n" -lt 0 ] && n=0
  now="$(date -u +%s)"

  # THE BASE TIP, over GRAPHQL (the REST bucket is the scarce one: `commits/<sha>` and
  # `pulls/<n>` reads that the rest of this file makes are the same 5000/hr pool). The committer
  # date is the clock this step measures against — one point, no REST.
  GH_LIMIT_NO_WAIT=1 gh api graphql -f query='
query($owner:String!,$name:String!){ repository(owner:$owner,name:$name){
  defaultBranchRef{ target{ ... on Commit { committedDate } } } } }' \
    -f owner="${OR%%/*}" -f name="${OR##*/}" >"$tmp/base.json" 2>/dev/null
  local base_iso
  base_iso="$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(""); raise SystemExit
print((((d.get("data") or {}).get("repository") or {}).get("defaultBranchRef") or {}).get("target",{}).get("committedDate") or "")' "$tmp/base.json" 2>/dev/null)"
  if [ -z "$base_iso" ]; then
    log_line "stale-rerun: the base tip could not be read over GraphQL — 0 re-runs this run (nothing to measure staleness against)"
    rm -rf "$tmp"; return 0
  fi

  # THE CHECK SURFACE, ONE GraphQL read for the whole board. `contexts` is the commit's check runs; the
  # per-PR `checkSuites` read is the COMPLETE surface but costs a node budget per PR that this box
  # cannot spend 100 times.
  # ⛔ `pageInfo{hasNextPage}` IS REQUESTED AND ENFORCED, because the earlier claim that a truncated
  # read "can only make this step OVER-select" was FALSE in one direction: if the newest attempt falls
  # outside the first 100 contexts and an older GREEN attempt is inside it, a stale red is neither
  # selected nor counted (`stale-by-base=0`). The planner refuses a truncated surface instead.
  GH_LIMIT_NO_WAIT=1 gh api graphql -f query='query($owner:String!,$name:String!){
  repository(owner:$owner,name:$name){
    pullRequests(first:100, states:OPEN, orderBy:{field:UPDATED_AT, direction:DESC}){
      pageInfo{ hasNextPage }
      nodes{ number
        commits(last:1){ nodes{ commit{
          statusCheckRollup{ contexts(first:100){
            pageInfo{ hasNextPage }
            nodes{ __typename
              ... on CheckRun { databaseId name status conclusion startedAt
                checkSuite{ app{slug} workflowRun{ databaseId workflow{ name } } } }
              ... on StatusContext { context state } } } } } } } } } } }' \
    -f owner="${OR%%/*}" -f name="${OR##*/}" >"$tmp/rollup.json" 2>/dev/null

  lander_stale_plan "$tmp/rollup.json" "$boardf" "$base_iso" "$STALE_RERUN_STATE" \
    "$n" "$STALE_RERUN_WINDOW" "$now" "$STALE_RERUN_EXCLUDE" >"$tmp/plan.txt" 2>"$tmp/plan.err"
  tr '\t' '\037' <"$tmp/plan.txt" >"$tmp/plan.us"
  # ⛔ ABSENCE OF AN `INFO` LINE IS THE FAILURE SIGNAL, not an empty file. A planner that dies after
  # its first print leaves a NON-EMPTY plan, every counter at its 0 default and a summary that reads
  # `stale-by-base=0` — a silent zero, which hard rule 4 forbids (measured by the reviewer: one
  # unparseable `startedAt` produced `stale-by-base=0 … outcomes read=1`).
  if ! grep -q "^INFO$(printf '\037')" "$tmp/plan.us" 2>/dev/null; then
    # ⛔ THE REASON IS ON STDOUT (`plan.txt`), NOT `plan.err`: every planner refusal is a FATAL line.
    # Reading plan.err here reported "printed nothing explanatory" for EVERY refusal and made the
    # FATAL dispatch arm below dead code, so an operator saw a truncated-surface guard fire and was
    # told nothing (measured by the reviewer against three different refused reads).
    local why
    why="$(grep -m1 "^FATAL$(printf '\037')" "$tmp/plan.us" 2>/dev/null | cut -d"$(printf '\037')" -f2-)"
    [ -n "$why" ] || why="$(tr '\n' ' ' <"$tmp/plan.err" 2>/dev/null | cut -c1-300)"
    [ -n "$why" ] || why="the planner printed nothing explanatory"
    log_line "stale-rerun: the plan did not complete (no INFO line) — 0 re-runs this run: $why"
    rm -rf "$tmp"; return 0
  fi
  local stale_runs=0 stale_prs=0 over=0 undated=0 nonact=0 cands=0 want=0 chose_runs=0 re_ran=0 outcomes=0 successes=0 stillred=0 excluded=0 excluded_runs=0
  # INFO's field order: base, candidate checks, candidate PRs, candidate runs, chosen checks,
  # chosen runs, over-budget checks, undated, non-actions, unresolved re-runs, excluded-by-name,
  # excluded-by-run
  local info; info="$(awk -F"$US" '$1=="INFO"{print; exit}' "$tmp/plan.us")"
  if [ -n "$info" ]; then
    IFS="$US" read -r _ base_iso cands stale_prs stale_runs want chose_runs over undated nonact _ excluded excluded_runs <<<"$info"
  fi
  while IFS="$US" read -r kind a b c d e f; do
    case "$kind" in
      FATAL) log_line "stale-rerun: $a"; rm -rf "$tmp"; return 0 ;;
      STATEERR) log_line "stale-rerun: THE STATE FILE COULD NOT BE WRITTEN ($a) — the outcome of every re-run this run is UNRECORDED, so it will be re-reported (and, for an unresolved re-run, re-measured) next pass. This is a degraded run, not a clean one" ;;
      UNDATED) log_line "stale-rerun: #$a $b is RED but carries no started_at — NOT selected (a check that cannot be dated cannot be called stale; it stays red and visible)" ;;
      SKIPWIN) log_line "stale-rerun: #$a $c skipped — run $b was already re-run inside the ${STALE_RERUN_WINDOW}s window (the state file is what stops a re-run loop)" ;;
    esac
  done <"$tmp/plan.us"

  # ACT: one POST per RUN (a run can carry several stale checks — sigpipe-grep and bash-suites live
  # in the same `CI` run), never per check.
  # ⛔ THE PLAN EMITS ONE LINE PER CHECK, SO THE RUN IS DEDUPED HERE. Measured live before this
  # guard existed: run 39854279334 carried two stale checks and got TWO POSTs, the second refused by
  # a secondary limit — doubling the spend and tripping the limit for every later run in the pass.
  # The CAP is counted in runs; the POSTS must be too, or the two disagree.
  local okruns=" " badruns=" "
  while IFS="$US" read -r kind a b c d e f g h; do
    [ "$kind" = "RERUN" ] || continue
    # A second check on a run this pass ALREADY posted for is still RECORDED (its own outcome has to
    # be read on a later pass) but is never a second POST. If the first POST was refused, the sibling
    # inherits the deferral instead of pretending it was re-run.
    case "$okruns" in
      *" $b "*)
        if printf 'R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$a" "$b" "$c" "$d" "$e" "$f" "$g" >> "$STALE_RERUN_STATE"; then
          log_line "stale-rerun: #$a $c is re-run by the SAME run $b already POSTed in this pass (check $d) — recorded so its outcome is read, not POSTed twice"
        else
          log_line "stale-rerun: #$a $c shares run $b (already POSTed) but the STATE FILE COULD NOT BE WRITTEN — its outcome will not be read"
        fi
        continue ;;
    esac
    case "$badruns" in *" $b "*) printf 'D\t%s\t%s\t%s\t%s\t-\t-\t%s\t%s\n' "$now" "$a" "$b" "$c" "$f" "$g" >> "$STALE_RERUN_STATE" 2>/dev/null || log_line "stale-rerun: #$a $c shares run $b whose POST was refused, but the deferral could NOT be recorded ($STALE_RERUN_STATE) — it will be re-POSTed next pass"; continue ;; esac
    if [ "$DRY" = 1 ]; then
      log_line "stale-rerun: #$a $c WOULD RE-RUN (check id $d started $e — before the base tip $base_iso; run $b)"
      continue
    fi
    if GH_LIMIT_NO_WAIT=1 gh api -X POST "repos/$OR/actions/runs/$b/rerun-failed-jobs" >/dev/null 2>"$tmp/post.err"; then
      re_ran=$((re_ran+1)); okruns="$okruns$b "
      if printf 'R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$a" "$b" "$c" "$d" "$e" "$f" "$g" >> "$STALE_RERUN_STATE"; then
        log_line "stale-rerun: #$a $c RE-RUN (run $b, check $d started $e < base tip $base_iso) — the result is read next pass, as success or still-red"
      else
        log_line "stale-rerun: #$a $c was RE-RUN (run $b) but the STATE FILE COULD NOT BE WRITTEN ($STALE_RERUN_STATE) — its outcome will not be read, and the same run may be re-run again next pass"
      fi
    else
      # ⛔ A REFUSAL IS RECORDED, NOT RETRIED. Measured live: `403 This workflow is already
      # running` for a run whose other jobs are still executing — the failed check-run is real and
      # old, but the RUN cannot be re-run yet. Recording it as a deferral (D) spends the window so
      # the next pass does not pay another POST to learn the same thing; it is never resolved into
      # an outcome, because nothing ran.
      badruns="$badruns$b "
      if printf 'D\t%s\t%s\t%s\t%s\t-\t-\t%s\t%s\n' "$now" "$a" "$b" "$c" "$f" "$g" >> "$STALE_RERUN_STATE" 2>/dev/null; then
        log_line "stale-rerun: #$a $c re-run REFUSED by the API (run $b): $(tr '\n' ' ' <"$tmp/post.err" | cut -c1-200) — recorded as deferred; not retried inside the ${STALE_RERUN_WINDOW}s window, and NOT treated as green"
      else
        log_line "stale-rerun: #$a $c re-run REFUSED by the API (run $b): $(tr '\n' ' ' <"$tmp/post.err" | cut -c1-200) — and the deferral could NOT be recorded ($STALE_RERUN_STATE), so the same run may be POSTed again next pass. NOT treated as green"
      fi
    fi
  done <"$tmp/plan.us"

  # REPORT the outcomes of earlier re-runs. `still-red` is a RESULT, not a failure of this step: it
  # says the red belongs to the branch and must stay visible.
  # OUTCOME fields: kind pr run name new_check_id outcome old_check_id started_at
  while IFS="$US" read -r kind a b c d e f _; do
    [ "$kind" = "OUTCOME" ] || continue
    outcomes=$((outcomes+1))
    case "$e" in
      success) successes=$((successes+1)); log_line "stale-rerun: #$a $c is now SUCCESS (check $d, replacing $f) — the red did not reproduce on the SAME tree: a flake, or an input outside the tree" ;;
      *)       stillred=$((stillred+1)); log_line "stale-rerun: #$a $c is STILL-RED (check $d, replacing $f) — the red belongs to this tree and a re-run cannot clear it (a base-side repair needs the branch UPDATED onto the new base, which moves the head; that is the owner's act, not this loop's). It stays red and visible; nothing here suppresses it" ;;
    esac
  done <"$tmp/plan.us"

  log_line "stale-rerun: stale-by-base=$cands check(s) across $stale_prs PR(s) in $stale_runs run(s); budget N=$n run(s) (REST core ${rem} left, minus ${STALE_RERUN_RESERVE} reserve, 5 points per re-run POST); selected=$want check(s) in $chose_runs run(s), re-ran=$re_ran run(s), over-budget=$over check(s) left for the next run; undated=$undated non-actions=$nonact; outcomes read=$outcomes (success=$successes still-red=$stillred); excluded-by-name=$excluded check(s), run(s)-dropped=$excluded_runs (NOT base-staleness: ${STALE_RERUN_EXCLUDE} is #2467's class, owned by the recorder rerun; a RUN carrying one is dropped entirely, because the POST re-runs every failed job in it)"
  note "stale-rerun: base_tip=$base_iso cands=$cands prs=$stale_prs runs=$stale_runs N=$n want=$want ran=$re_ran over=$over outcomes=$outcomes success=$successes still_red=$stillred excl_run=$excluded_runs"
  if [ "${STALE_RERUN_DEBUG:-0}" = 1 ]; then log_line "stale-rerun: DEBUG kept $tmp (plan, rollup, base)"; else rm -rf "$tmp"; fi
  return 0
}

# ── per-PR merge ─────────────────────────────────────────────────────────────────────────────
# Sets MERGE_RESULT (merged|enqueued|failed) and MERGE_SHA. The verb is `gh pr merge` ONLY, pinned
# to the head this run classified; `--admin` and PIPELINE_COMPLIANCE_SKIP are unrepresentable here.
lander_merge() { # <pr> <head>
  local pr="$1" head="$2" out
  MERGE_SHA=""
  if [ "$DRY" = 1 ]; then MERGE_RESULT=dry-run; return 0; fi
  if [ "$HAS_QUEUE" = 1 ]; then
    if out="$(gh pr merge "$pr" --repo "$OR" --squash --auto 2>&1)"; then
      MERGE_RESULT=enqueued
      note "#$pr enqueued on the merge queue (head=$head): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      return 0
    fi
    MERGE_RESULT=failed
    note "#$pr ENQUEUE FAILED (head=$head): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    return 0
  fi
  if out="$(gh pr merge "$pr" --repo "$OR" --squash --match-head-commit "$head" 2>&1)"; then
    MERGE_RESULT=merged
    # The sha, from REST (the shim prints it too, but its wording is not a contract). A read that
    # fails leaves the sha EMPTY and SAID SO rather than promoting the head sha, which is not the
    # commit that landed on a squash merge.
    MERGE_SHA="$(gh api "repos/$OR/pulls/$pr" --jq .merge_commit_sha 2>/dev/null)"
    case "${MERGE_SHA:-}" in ''|null|*[!0-9a-fA-F]*) MERGE_SHA="" ;; esac
    note "#$pr merged (head=$head merge_commit=${MERGE_SHA:-<unreadable>}): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
    return 0
  fi
  MERGE_RESULT=failed
  note "#$pr MERGE FAILED (head=$head): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  return 0
}

# ── one PR: read, classify, act, report ──────────────────────────────────────────────────────
# Counters are globals (ok/wait/skip/err) so the summary can be written for the inventory row.
lander_one() { # <pr>
  local pr="$1" view vrc mergeable mstate draft head ckraw chk crc green pend fail names odd
  view="$(gh pr view "$pr" --repo "$OR" --json mergeable,mergeStateStatus,isDraft,headRefOid 2>/dev/null | py view)"; vrc=$?
  if [ "$vrc" -ne 0 ] || [ -z "$view" ]; then
    log_line "#$pr skipped: could not read the PR (fail-closed — nothing merged for it)"; SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:read-failed"; return 0
  fi
  IFS="$US" read -r mergeable mstate draft head <<<"$view"

  # 1) a DRAFT is not a candidate at any state: it is the author's own "not ready" mark.
  if [ "${draft:-0}" = "1" ]; then
    log_line "#$pr skipped: draft (isDraft=true — the author has not asked for it to land)"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:draft"; return 0
  fi
  # 2) a CONFLICT can never merge; it is work for a fixer, not a wait.
  if [ "$mergeable" = "CONFLICTING" ] || [ "$mstate" = "DIRTY" ]; then
    log_line "#$pr skipped: mergeable=$mergeable mergeStateStatus=${mstate:-<empty>} — conflicts with $OR's base branch; a fixer owns this, waiting will not clear it"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:conflict"; return 0
  fi
  # 3) GitHub still computing mergeability is NOT a defect and NOT a green light.
  if [ "$mergeable" != "MERGEABLE" ]; then
    log_line "#$pr waiting: mergeable=${mergeable:-UNKNOWN} — GitHub has not finished computing mergeability (re-read next run; this is not a failure)"
    WAITING=$((WAITING+1)); return 0
  fi

  # 4) the checks. THE distinction of this component lives in these four counters.
  # ⛔ `gh pr checks`'s OWN EXIT CODE IS NOT AN ANSWER, AND `set -o pipefail` MAKES IT LOOK LIKE ONE.
  # Real gh exits 1 when a check FAILED and 8 when checks are pending (documented behaviour), while
  # the REST shim exits 0 — so a `gh … | py …` pipeline under pipefail reads a PR whose checks merely
  # FAILED as an UNREADABLE surface, and this component would report "waiting" for a red PR forever.
  # The payload is captured FIRST and judged ONLY by whether it is a JSON array: rc is discarded here
  # deliberately, and that is why the capture and the classification are two statements.
  ckraw="$(gh pr checks "$pr" --repo "$OR" --json name,state,startedAt,workflow 2>/dev/null)"
  chk="$(printf '%s' "$ckraw" | py checks)"; crc=$?
  if [ "$crc" -ne 0 ] || [ -z "$chk" ]; then
    # An incomplete read is neither green nor red. Reading it as "no checks" is the defect that let
    # earlier lanes call a rate-limited read a passing PR.
    log_line "#$pr waiting: the check surface could not be read (incomplete read — retry, never read as green)"
    WAITING=$((WAITING+1)); return 0
  fi
  IFS="$US" read -r green pend fail names odd <<<"$chk"
  if [ "${fail:-0}" -gt 0 ]; then
    log_line "#$pr skipped: $fail FAILED check(s): ${names# } — never merged with a failing check (green=$green pending=$pend)"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:failed-checks"; return 0
  fi
  # ⛔ BEFORE the pending arm: a check that did not complete can never resolve into a merge, so a PR
  # carrying one is SKIPPED (named, non-red) rather than reported as a CI wait it will never leave.
  if [ -n "${odd:-}" ]; then
    log_line "#$pr skipped: ${odd} did not complete (cancelled/stale) — NOT a red tree and NOT a defect, but verification never finished, so this is never merged (green=$green pending=$pend failed=$fail); re-run the checks or wait for the next push"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:checks-incomplete"; return 0
  fi
  if [ "${pend:-0}" -gt 0 ]; then
    # ⛔ THE MEASURED CASE. Green so far, CI still running: WAIT, say "waiting-on-CI", and never
    # call it skipped/blocked/failed. Action here is what made lanes re-dispatch healthy PRs.
    log_line "#$pr waiting-on-CI: $pend pending, $green green, 0 failed — CI latency, not a defect; nothing to do but wait"
    WAITING=$((WAITING+1)); return 0
  fi

  # 5) merge state. READY is the allow-list {CLEAN,HAS_HOOKS}; everything else is NAMED and left
  # alone, because a value this file has not been taught must never be read as "clean enough".
  case "$mstate" in
    CLEAN|HAS_HOOKS) : ;;
    BLOCKED)
      log_line "#$pr skipped: mergeStateStatus=BLOCKED with $green green and 0 failed — GitHub says a protection rule or a required review blocks it (mergeable=MERGEABLE, reviewDecision is not exposed over REST); NOT merged, and not a CI wait: something must change outside CI"
      SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:blocked"; return 0 ;;
    BEHIND)
      log_line "#$pr skipped: mergeStateStatus=BEHIND — behind $OR's base and the branch requires an up-to-date head; a lane/fixer must update it (checks: $green green, 0 failed)"
      SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:behind"; return 0 ;;
    ""|UNKNOWN)
      log_line "#$pr waiting: mergeStateStatus empty/UNKNOWN — mergeability not yet computed by GitHub (retry; not a failure)"
      WAITING=$((WAITING+1)); return 0 ;;
    *)
      log_line "#$pr skipped: mergeStateStatus=${mstate} (unrecognised state — allow-list is CLEAN/HAS_HOOKS, so this is NOT treated as ready; checks: $green green, 0 failed)"
      SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:state-$mstate"; return 0 ;;
  esac

  # 6) READY — but "ready" is about the PR; the MERGE VERB is about the repo. A rail repo's merge
  # authority is its own rail, so this component does not merge it and says who does.
  if [ "$AUTH" = "unknown" ]; then
    log_line "#$pr waiting: ready (green=$green, mergeStateStatus=$mstate) but the merge contract is UNKNOWN this run — nothing merges until it is readable"
    WAITING=$((WAITING+1)); return 0
  fi
  if [ "$AUTH" = "rail" ]; then
    log_line "#$pr skipped: READY, but this repo's merge authority is its own RAIL — merge-one.sh owns this merge; a raw squash here would land it on the required checks alone with no head-bound evidence (#1764)"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:rail-authority"; return 0
  fi
  lander_merge "$pr" "$head"
  case "$MERGE_RESULT" in
    merged)
      if [ -n "$MERGE_SHA" ]; then log_line "#$pr MERGED sha=$MERGE_SHA (head=$head, $green green, mergeStateStatus=$mstate)"
      else log_line "#$pr MERGED (head=$head, $green green) — merge commit sha unreadable"; fi
      MERGED=$((MERGED+1)) ;;
    enqueued) log_line "#$pr ENQUEUED on the merge queue (head=$head, $green green) — the queue lands it"; ENQUEUED=$((ENQUEUED+1)) ;;
    dry-run) log_line "#$pr WOULD MERGE (dry-run; head=$head, $green green, mergeStateStatus=$mstate)"; WOULD=$((WOULD+1)) ;;
    *) log_line "#$pr ERROR: the merge command failed (head=$head) — see $LOG"; ERRORS=$((ERRORS+1)) ;;
  esac
}

# ── the run ──────────────────────────────────────────────────────────────────────────────────
US=$'\x1f'   # unit separator: NOT an IFS whitespace char, so empty fields survive `read`
MERGED=0; ENQUEUED=0; WAITING=0; SKIPPED=0; ERRORS=0; WOULD=0; SKIP_REASONS=""
log_line "run start: repo=$OR dry_run=$DRY max=$MAX path=$(command -v gh 2>/dev/null)"
# ONCE PER RUN, BEFORE ANY ACT: the number that explains a slow drain even when nothing is ready.
lander_queue_depth
lander_authority
lander_detect_queue

BOARD="$(gh pr list --repo "$OR" --state open --json number,isDraft,headRefOid --limit "$MAX" 2>/dev/null)"
LIST="$(printf '%s' "$BOARD" | py list)"; LRC=$?
if [ "$LRC" -ne 0 ]; then
  # ⛔ FAIL-CLOSED. An unreadable board must never look like "no open PRs" (which reads as "nothing
  # to do" and is how a broken token silently stops the drain).
  log_line "FATAL: the open-PR board could not be read (gh pr list returned no parseable JSON) — NOTHING merged this run"
  note "run aborted: unreadable board (raw bytes: $(printf '%s' "$BOARD" | head -c 200))"
  exit 2
fi

N="$(printf '%s\n' "$LIST" | awk 'NF' | wc -l | tr -d ' ')"
log_line "open PRs: ${N:-0} (limit $MAX)"
# ⛔ BEFORE the board loop, and only on a board that was READ: a PR the lander did not see is not
# this step's business. Re-measuring a stale red is what makes the loop below able to see a PR as
# ready at all when the only thing red about it is a base that has since been repaired.
if [ "${STALE_RERUN_OFF:-0}" = 1 ]; then
  log_line "stale-rerun: DISABLED by --no-stale-rerun — no re-runs this run"
else
  # The board is written to a file and PASSED, never piped into the step: see the two measured
  # reasons at the top of lander_stale_rerun (a consumed stdin, and a TTY that never EOFs).
  BOARDNUMS="$O/state/boardnums-$(printf '%s' "$OR" | tr '/' '-').$$"
  printf '%s\n' "$LIST" | awk 'NF{print $1}' >"$BOARDNUMS" 2>/dev/null || BOARDNUMS=""
  lander_stale_rerun "$BOARDNUMS"
  [ -n "$BOARDNUMS" ] && rm -f "$BOARDNUMS"
fi
# ⛔ A HERESTRING, NOT A PIPE. `… | while read` runs the loop in a SUBSHELL, so every counter below
# stays 0 in the parent and the summary reads "merged=0" on a run that merged — the exact "a counter
# that is 0 forever" defect this repo has already paid for once. (Measured while writing this file:
# the first draft piped, and the summary printed zeros over a merged PR.)
while IFS= read -r pr; do
  [ -n "$pr" ] && lander_one "$pr"
done <<<"$(printf '%s\n' "$LIST" | awk 'NF{print $1}')"

log_line "summary: merged=$MERGED enqueued=$ENQUEUED would_merge=$WOULD waiting=$WAITING skipped=$SKIPPED errors=$ERRORS"
[ -n "${SKIP_REASONS# }" ] && log_line "skipped reasons:${SKIP_REASONS}"
# The durable record the fleet inventory reads (`fleet_row_lander_drain`). ONE line, fixed field
# order, written on every path that reaches the summary — a row that cannot read it must be able to
# say "no run recorded" rather than guess health from an absent file.
printf '%s %s %s %s %s %s %s %s\n' "$(date +%s)" "${QUEUED:-unreadable}" "${INPROG:-unreadable}" \
  "$MERGED" "$ENQUEUED" "$WAITING" "$SKIPPED" "$ERRORS" > "$O/state/lander-last" 2>/dev/null || true
# A refusal to merge because the CONTRACT is unreadable is not "nothing to do": rc 3 makes it visible
# to a launchd/cron last-exit instead of looking like a quiet, healthy run (merge-one.sh uses 5 for
# the same refusal; the numbers differ per script and neither is a success).
[ "$AUTH" = "unknown" ] && exit 3
[ "$ERRORS" -gt 0 ] && exit 1
exit 0
