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
#   lander.sh --repo owner/name [--dry-run] [--max N]
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

say()  { printf '[lander] %s\n' "$*"; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }
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
    for c in d:
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
    say "CI queue depth: UNAVAILABLE (queued=$QUEUED in-progress=$INPROG — the runs read failed; a PR waiting on CI cannot be distinguished from a stalled one this run)"
  else
    say "CI queue depth: $QUEUED queued, $INPROG in progress ($(( QUEUED + INPROG )) workflow runs) — REST /repos/$OR/actions/runs"
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
  else AUTH="unknown"; say "merge authority: UNKNOWN — repo-authority.sh was not found (looked in $O and ${here:-<unresolved>}), so nothing merges this run"; return 0
  fi
  if ! command -v resolve_required_checks >/dev/null 2>&1 || ! command -v merge_authority >/dev/null 2>&1; then
    AUTH="unknown"; say "merge authority: UNKNOWN — repo-authority.sh is stale/partial (no resolve_required_checks/merge_authority); nothing merges this run"; return 0
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
    say "merge authority: UNKNOWN — $why. Nothing merges this run (the same fail-closed refusal merge-one.sh makes, agent-infra#1764): an unreadable contract is not a licence to merge."
    return 0
  fi
  say "merge authority: $AUTH (required checks: [${REQ}] source=${REQ_SOURCE:-read}${REQ_OVERRIDE:+ — OPERATOR OVERRIDE})"
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
    ''|*[!0-9]*) say "merge queue: UNKNOWN (the branch-rules read failed or answered something that is not a count) — merging with squash, which GitHub refuses if a queue is required"; HAS_QUEUE=0 ;;
    0)           say "merge queue: none on main — merging with squash" ;;
    *)           say "merge queue: PRESENT ($n rule) — handing ready PRs to the queue with --auto"; HAS_QUEUE=1 ;;
  esac
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
    say "#$pr skipped: could not read the PR (fail-closed — nothing merged for it)"; SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:read-failed"; return 0
  fi
  IFS="$US" read -r mergeable mstate draft head <<<"$view"

  # 1) a DRAFT is not a candidate at any state: it is the author's own "not ready" mark.
  if [ "${draft:-0}" = "1" ]; then
    say "#$pr skipped: draft (isDraft=true — the author has not asked for it to land)"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:draft"; return 0
  fi
  # 2) a CONFLICT can never merge; it is work for a fixer, not a wait.
  if [ "$mergeable" = "CONFLICTING" ] || [ "$mstate" = "DIRTY" ]; then
    say "#$pr skipped: mergeable=$mergeable mergeStateStatus=${mstate:-<empty>} — conflicts with $OR's base branch; a fixer owns this, waiting will not clear it"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:conflict"; return 0
  fi
  # 3) GitHub still computing mergeability is NOT a defect and NOT a green light.
  if [ "$mergeable" != "MERGEABLE" ]; then
    say "#$pr waiting: mergeable=${mergeable:-UNKNOWN} — GitHub has not finished computing mergeability (re-read next run; this is not a failure)"
    WAITING=$((WAITING+1)); return 0
  fi

  # 4) the checks. THE distinction of this component lives in these four counters.
  # ⛔ `gh pr checks`'s OWN EXIT CODE IS NOT AN ANSWER, AND `set -o pipefail` MAKES IT LOOK LIKE ONE.
  # Real gh exits 1 when a check FAILED and 8 when checks are pending (documented behaviour), while
  # the REST shim exits 0 — so a `gh … | py …` pipeline under pipefail reads a PR whose checks merely
  # FAILED as an UNREADABLE surface, and this component would report "waiting" for a red PR forever.
  # The payload is captured FIRST and judged ONLY by whether it is a JSON array: rc is discarded here
  # deliberately, and that is why the capture and the classification are two statements.
  ckraw="$(gh pr checks "$pr" --repo "$OR" --json name,state 2>/dev/null)"
  chk="$(printf '%s' "$ckraw" | py checks)"; crc=$?
  if [ "$crc" -ne 0 ] || [ -z "$chk" ]; then
    # An incomplete read is neither green nor red. Reading it as "no checks" is the defect that let
    # earlier lanes call a rate-limited read a passing PR.
    say "#$pr waiting: the check surface could not be read (incomplete read — retry, never read as green)"
    WAITING=$((WAITING+1)); return 0
  fi
  IFS="$US" read -r green pend fail names odd <<<"$chk"
  if [ "${fail:-0}" -gt 0 ]; then
    say "#$pr skipped: $fail FAILED check(s): ${names# } — never merged with a failing check (green=$green pending=$pend)"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:failed-checks"; return 0
  fi
  # ⛔ BEFORE the pending arm: a check that did not complete can never resolve into a merge, so a PR
  # carrying one is SKIPPED (named, non-red) rather than reported as a CI wait it will never leave.
  if [ -n "${odd:-}" ]; then
    say "#$pr skipped: ${odd} did not complete (cancelled/stale) — NOT a red tree and NOT a defect, but verification never finished, so this is never merged (green=$green pending=$pend failed=$fail); re-run the checks or wait for the next push"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:checks-incomplete"; return 0
  fi
  if [ "${pend:-0}" -gt 0 ]; then
    # ⛔ THE MEASURED CASE. Green so far, CI still running: WAIT, say "waiting-on-CI", and never
    # call it skipped/blocked/failed. Action here is what made lanes re-dispatch healthy PRs.
    say "#$pr waiting-on-CI: $pend pending, $green green, 0 failed — CI latency, not a defect; nothing to do but wait"
    WAITING=$((WAITING+1)); return 0
  fi

  # 5) merge state. READY is the allow-list {CLEAN,HAS_HOOKS}; everything else is NAMED and left
  # alone, because a value this file has not been taught must never be read as "clean enough".
  case "$mstate" in
    CLEAN|HAS_HOOKS) : ;;
    BLOCKED)
      say "#$pr skipped: mergeStateStatus=BLOCKED with $green green and 0 failed — GitHub says a protection rule or a required review blocks it (mergeable=MERGEABLE, reviewDecision is not exposed over REST); NOT merged, and not a CI wait: something must change outside CI"
      SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:blocked"; return 0 ;;
    BEHIND)
      say "#$pr skipped: mergeStateStatus=BEHIND — behind $OR's base and the branch requires an up-to-date head; a lane/fixer must update it (checks: $green green, 0 failed)"
      SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:behind"; return 0 ;;
    ""|UNKNOWN)
      say "#$pr waiting: mergeStateStatus empty/UNKNOWN — mergeability not yet computed by GitHub (retry; not a failure)"
      WAITING=$((WAITING+1)); return 0 ;;
    *)
      say "#$pr skipped: mergeStateStatus=${mstate} (unrecognised state — allow-list is CLEAN/HAS_HOOKS, so this is NOT treated as ready; checks: $green green, 0 failed)"
      SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:state-$mstate"; return 0 ;;
  esac

  # 6) READY — but "ready" is about the PR; the MERGE VERB is about the repo. A rail repo's merge
  # authority is its own rail, so this component does not merge it and says who does.
  if [ "$AUTH" = "unknown" ]; then
    say "#$pr waiting: ready (green=$green, mergeStateStatus=$mstate) but the merge contract is UNKNOWN this run — nothing merges until it is readable"
    WAITING=$((WAITING+1)); return 0
  fi
  if [ "$AUTH" = "rail" ]; then
    say "#$pr skipped: READY, but this repo's merge authority is its own RAIL — merge-one.sh owns this merge; a raw squash here would land it on the required checks alone with no head-bound evidence (#1764)"
    SKIPPED=$((SKIPPED+1)); SKIP_REASONS="$SKIP_REASONS #$pr:rail-authority"; return 0
  fi
  lander_merge "$pr" "$head"
  case "$MERGE_RESULT" in
    merged)
      if [ -n "$MERGE_SHA" ]; then say "#$pr MERGED sha=$MERGE_SHA (head=$head, $green green, mergeStateStatus=$mstate)"
      else say "#$pr MERGED (head=$head, $green green) — merge commit sha unreadable"; fi
      MERGED=$((MERGED+1)) ;;
    enqueued) say "#$pr ENQUEUED on the merge queue (head=$head, $green green) — the queue lands it"; ENQUEUED=$((ENQUEUED+1)) ;;
    dry-run)  say "#$pr WOULD MERGE (dry-run; head=$head, $green green, mergeStateStatus=$mstate)"; WOULD=$((WOULD+1)) ;;
    *)        say "#$pr ERROR: the merge command failed (head=$head) — see $LOG"; ERRORS=$((ERRORS+1)) ;;
  esac
}

# ── the run ──────────────────────────────────────────────────────────────────────────────────
US=$'\x1f'   # unit separator: NOT an IFS whitespace char, so empty fields survive `read`
MERGED=0; ENQUEUED=0; WAITING=0; SKIPPED=0; ERRORS=0; WOULD=0; SKIP_REASONS=""
say "run start: repo=$OR dry_run=$DRY max=$MAX path=$(command -v gh 2>/dev/null)"
# ONCE PER RUN, BEFORE ANY ACT: the number that explains a slow drain even when nothing is ready.
lander_queue_depth
lander_authority
lander_detect_queue

BOARD="$(gh pr list --repo "$OR" --state open --json number,isDraft,headRefOid --limit "$MAX" 2>/dev/null)"
LIST="$(printf '%s' "$BOARD" | py list)"; LRC=$?
if [ "$LRC" -ne 0 ]; then
  # ⛔ FAIL-CLOSED. An unreadable board must never look like "no open PRs" (which reads as "nothing
  # to do" and is how a broken token silently stops the drain).
  say "FATAL: the open-PR board could not be read (gh pr list returned no parseable JSON) — NOTHING merged this run"
  note "run aborted: unreadable board (raw bytes: $(printf '%s' "$BOARD" | head -c 200))"
  exit 2
fi

N="$(printf '%s\n' "$LIST" | awk 'NF' | wc -l | tr -d ' ')"
say "open PRs: ${N:-0} (limit $MAX)"
# ⛔ A HERESTRING, NOT A PIPE. `… | while read` runs the loop in a SUBSHELL, so every counter below
# stays 0 in the parent and the summary reads "merged=0" on a run that merged — the exact "a counter
# that is 0 forever" defect this repo has already paid for once. (Measured while writing this file:
# the first draft piped, and the summary printed zeros over a merged PR.)
while IFS= read -r pr; do
  [ -n "$pr" ] && lander_one "$pr"
done <<<"$(printf '%s\n' "$LIST" | awk 'NF{print $1}')"

say "summary: merged=$MERGED enqueued=$ENQUEUED would_merge=$WOULD waiting=$WAITING skipped=$SKIPPED errors=$ERRORS"
[ -n "${SKIP_REASONS# }" ] && say "skipped reasons:${SKIP_REASONS}"
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
