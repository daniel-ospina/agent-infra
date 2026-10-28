#!/usr/bin/env bash
# pr-sickness.sh — THE PR SICKNESS QUEUE: the half of autonomy that RETURNS TO A RED PR.
#
# ⛔ WHY THIS FILE EXISTS. Dispatch was ISSUE-driven: `refresh-candidates.sh` fills a backlog of
# issues, `orch-loop.sh` [select]s one, and a lane runs. The PR side had no selector at all — it had
# two REACTORS: the acting-case fixer arms (which fire only for a red check that is in the repo's
# REQUIRED set) and the red-fixer role (which fires only when the MERGE RAIL refused). Neither ever
# asks the question "which open PR is red right now?". So a PR that went red on a check nobody's
# required-set named, or on a PR no rail had reached yet, was never visited again. MEASURED
# 2026-10-22: seven lanes finished real work and landed nothing, and 25 tortoise PRs sat `blocked`,
# most of them red on ONE systemic assertion that had already been fixed on main. Every repair that
# actually happened that week happened because a human or an orchestrator LOOKED. This file is the
# looking.
#
# ── THE CONTRADICTION TEST (asked FIRST, per AGENTS.md) ──────────────────────────────────────────
# The owner's recorded dispatch rule (2026-10-18, and it is code: `live-ownership.sh`'s PR-first
# order + orch-loop.sh's merge-priority gate) is that UN-OWNED PRs come first and new ISSUE work is
# picked only when no un-owned PR remains. That is a decision about PRIORITY, and this file does not
# reverse it — it makes the PR side of it actually reachable, which is the direction that decision
# already points. What it does NOT do is widen dispatch: this queue has its OWN READ BUDGET
# (`PS_MAX_PRS` per pass, round-robin cursor), it runs only when the box has a spawn slot, and it
# adds no lane ceiling of its own — the `fix-<PR>` workers it spawns are the SAME `fix-` sessions the
# existing fixer arms spawn, so every existing census/reaper/cap counts them unchanged.
#
# ── NOT GATED ON THE CI QUEUE, AND THAT IS THE POINT (#2927) ────────────────────────────────
# Everything this file dispatches acts on a PR THAT ALREADY EXISTS: its head is red, conflicted or
# under review. ⛔ A REPAIR PUSH IS NOT FREE — it DOES start a fresh CI run (`ci-queue.sh`'s header
# records "its pass is already spent" as NOT TRUE, and that is why the exclusion does not rest on it).
# The CI queue still says nothing about whether these dispatches may proceed: a spent QUEUE SLOT is
# not a reason to withhold repair from a PR that already has a head to repair. ⛔ AND THE REASON IS
# NOT "a queue slot costs nothing" — that is the COST CLAIM `ci-queue.sh`'s header records as
# refutable. `ci-queue.sh` states the basis as a DECISION PLUS A MEASUREMENT, and what the measurement
# showed is that the NUMBER was the wrong quantity, not that repair is cheap: 2026-10-27 on cell 4,
# `queued=33 running=2 runners=~2 => ceiling=4` derived its ceiling off demand-as-supply — a reading
# of THIS BOX's own load presented as the world's capacity — and deferred 41 consecutive PR-repair
# dispatches (all of them this file's own `skip #<n>: backpressure(q=…,r=…)`) while 11 lane slots and
# an 8-runner self-hosted fleet sat idle.
# The queue it was reading belonged to GitHub-HOSTED concurrency and to the ISSUE→PR path.
# So this file sources no CI-queue module and reads no queue depth. Its real bounds, all of which stay:
#   * LANE SLOTS — the caller's `--max-spawn` allowance (orch-loop.sh passes the remaining fix-lane
#     headroom) and the `fix-<PR>` session census; a deferred item keeps its place in the ledger.
#   * The LOAD / headroom gate (`fix-one.sh`'s `fixgate-<PR>-<HEAD>`), which is about THIS BOX's
#     capacity to run an agent rather than about GitHub's.
# The queue gate itself is unchanged and still applied where it belongs — to work that ADDS a new CI
# run (`dispatch-merge.sh`'s issue→PR batches and `orch-loop.sh`'s ISSUE path) and to the merge rail's
# own CI-spending steps. See `ci-queue.sh`'s header for the class rule; do NOT reintroduce the gate
# here on a tuning pretext — that re-opens #2927.
#
# ── POLARITY, ON THE NEWEST ATTEMPT PER (app, name) ─────────────────────────────────────────────
# One surface read per PR, from the CHECK-RUNS API (`commits/<sha>/check-runs?filter=all`), which —
# unlike `gh pr checks` — carries `app.slug`, the attempt `id` and the job id. Grouping is by
# (app, name) with the NEWEST attempt (highest id) winning, because GitHub keeps every attempt and a
# re-run ADDS a row: one commit can carry the same job both `failure` and `success`, and a per-name
# "last row seen" read silently picks whichever the API happened to order last. Verdict by POLARITY
# (the same allow-list `admin-merge.sh` / the loop's classifier / `fix-one.sh` use):
#   RED   = any completed group whose conclusion is not in {success,neutral,skipped,cancelled,stale}
#   WAIT  = no red, at least one group in flight (queued, in_progress, waiting, requested, pending)
#   GREEN = at least one group, and every group non-red
# A MISSING CHECK IS NOT GREEN, and an EMPTY/FAILED API RESPONSE IS NOT "nothing red" — it is
# `NOREAD (<reason>)`, which dispatches nothing and names the failure. That is the one direction that
# must never fail open, and it is why `ps_polarity` is a single function: the mutation that deletes it
# must break the WAIT case and the NOREAD case together (proved in pr-sickness.test.sh (f)).
#
# ── BOUNDED, AND NON-DUPLICATIVE ────────────────────────────────────────────────────────────────
#   * ONE live fixer per PR: the existing claim mechanism (`claim_pr_preflight`, cross-box) PLUS the
#     existing `fix-<PR>` / `merge-<PR>` session names (wt_alive). "Claim unreadable" is rc=2 and is
#     treated as HELD — an abstention is not permission (agent-infra#1850's polarity).
#   * A HEAD-KEYED attempt budget (`PS_MAX_TRIES`, default 2) is not a lane cap: it bounds how many
#     times ONE TREE may be handed to a fixer, exactly like the existing rail-refusal role's
#     `MAX_RED_FIX_TRIES`. Without it a fixer that cannot fix is re-spawned forever — an auto-repair
#     loop is worse than the stall it replaced.
#   * A parked head (`state/parked-<PR>` == this head) is a human's decision and is not re-dispatched.
#
# ── THE BRIEF COMES FROM THE FAILURE, NOT FROM A TEMPLATE ──────────────────────────────────────
# The work item carries `state/sickbrief-<PR>.md`, generated from the failing group itself: the
# app/name, the run id, the job id, the conclusion, and the failing JOB's own log excerpt. A fixer
# that has to rediscover why it was dispatched is a fixer that spends its budget on forensics.
#
# Exit codes of `ps_select`: 0 = the pass completed (whatever it decided), 2 = the pass could not be
# made (its own read budget/queue unknown), never a silent 0 for a pass that did nothing.
set -u

# ── seams (every one is overridden by the suite; none is an operator knob except PS_*) ──────────
ps_gh() {  # <args...> -> JSON on stdout, non-zero when the read failed
  local ghbin="${PS_GH:-gh}"
  command -v "$ghbin" >/dev/null 2>&1 || return 127
  "$ghbin" api "$@" 2>/dev/null
}
ps_is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
ps_now() { date +%s; }
ps_state_dir() { printf '%s' "${PS_STATE_DIR:-${O:-$HOME/orchestrator}/state}"; }
ps_repo() { printf '%s' "${1:-${PS_OR:-${OR:-}}}"; }
# liveness + spawn are the SAME primitives the controller uses; a missing one is a refusal, never a
# silent "nothing is held" (that would duplicate work on a live PR).
ps_alive() {  # <session> -> 0 alive
  if declare -f wt_alive >/dev/null 2>&1; then wt_alive "${1:-}"; return $?; fi
  declare -f ps_alive_stub >/dev/null 2>&1 && { ps_alive_stub "${1:-}"; return $?; }
  return 1
}
ps_claim_preflight() {  # <repo> <pr> -> 0 CLEAN, 1 COLLISION, 2 INCOMPLETE (never CLEAN)
  if declare -f claim_pr_preflight >/dev/null 2>&1; then claim_pr_preflight "${1:-}" "${2:-}"; return $?; fi
  declare -f ps_claim_stub >/dev/null 2>&1 && { ps_claim_stub "${1:-}" "${2:-}"; return $?; }
  # No claim registry at all: the local `mergeclaim` lock is the only thing left, and the CALLER
  # checks it. An absent registry is not evidence of freedom, so this reports INCOMPLETE.
  printf 'no claim registry loaded (claims.sh absent) — INCOMPLETE, never CLEAN'
  return 2
}
ps_spawn() {  # <name> <cwd> <command> -> 0 spawned
  if declare -f wt_spawn >/dev/null 2>&1; then wt_spawn "${1:-}" "${2:-}" "${3:-}"; return $?; fi
  declare -f ps_spawn_stub >/dev/null 2>&1 && { ps_spawn_stub "${1:-}" "${2:-}" "${3:-}"; return $?; }
  return 1
}

# ── the read budget is a READ budget, not a lane cap ───────────────────────────────────────────
PS_MAX_PRS="${PS_MAX_PRS:-10}"        # PRs inspected per pass (round-robin; every PR is reached)
ps_limit() { local v="${1:-}"; ps_is_num "$v" && [ "$v" -ge 1 ] && [ "$v" -le 500 ] && printf '%s' "$v" || printf '10'; }
PS_MAX_TRIES="${PS_MAX_TRIES:-2}"     # HEAD-keyed fixer attempts per PR (a cap on a TREE, not a lane)
ps_maxtries() { local v="${1:-}"; ps_is_num "$v" && [ "$v" -ge 0 ] && [ "$v" -le 50 ] && printf '%s' "$v" || printf '2'; }

# ── THE ROUTER SEAM (#2866) ───────────────────────────────────────────────────────────────────
# `scripts/orchestrator-harness/pr-state.sh` is the ONE consumer seam for the PR state table. It is
# sourced when present; when it is not, the seam prints `unavailable` and ps_router_row says so in
# the pass output — never silently.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/pr-state.sh" 2>/dev/null || true
ps_router_row() {  # <repo> <pr> → "ACTION<TAB>run<TAB>reason"; NEVER empty (rc 2 = it did not run)
  if declare -f prstate_row >/dev/null 2>&1; then
    # The router reads GitHub through the SAME gh this module does, so a suite that stubs PS_GH
    # keeps the router on the stub instead of reaching the network.
    PR_STATE_GH="${PR_STATE_GH:-${PS_GH:-gh}}" prstate_row "${1:-}" "${2:-}"
    return $?
  fi
  printf 'unavailable\t-\tpr-state.sh was not found beside pr-sickness.sh — the router did not run'
  return 2
}

# ── 1. ENUMERATE ───────────────────────────────────────────────────────────────────────────────
# ps_open_prs <owner/repo> -> TSV "number<TAB>sha<TAB>branch<TAB>draft(0|1)"; rc 2 = UNREADABLE.
# ⛔ `--paginate` emits one JSON object PER PAGE, so the parse must consume a STREAM of arrays, not
# one array — a single `.[]` over a two-page answer silently reports half the repo's PRs, which
# reads exactly like "those PRs are not sick".
ps_open_prs() {
  local repo out rc
  repo="$(ps_repo "${1:-}")"
  [ -n "$repo" ] || { printf 'no repo named (owner/repo) — cannot enumerate open PRs'; return 2; }
  out="$(ps_gh --paginate "repos/$repo/pulls?state=open&per_page=100" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'the open-PR listing is UNREADABLE (gh api repos/%s/pulls exited %d, %d bytes) — an empty answer is a FAILED CALL, not "no open PRs"' \
      "$repo" "$rc" "${#out}"
    return 2
  fi
  _rows_out="$(printf '%s' "$out" | REPO="$repo" python3 -c '
import sys, json, os
REPO = os.environ.get("REPO") or ""
# one object per page: concatenate the streams first, then walk each array
dec = json.JSONDecoder(); s = sys.stdin.read(); i = 0
rows = []
while i < len(s):
    while i < len(s) and s[i] in " \n\r\t": i += 1
    if i >= len(s): break
    obj, i = dec.raw_decode(s, i)
    if isinstance(obj, list): rows.extend(obj)
    elif isinstance(obj, dict):
        if isinstance(obj.get("items"), list): rows.extend(obj["items"])
        else: rows.append(obj)
ok = 0
for p in rows:
    # ⛔ A MALFORMED ROW IS NOT SKIPPED SILENTLY (review P2). One bad object used to kill the whole
    # parse while the function still returned 0, so the pass read "no open PRs" and the RECONCILER
    # then treated every open PR as merged/closed — dropping the deferral ledger and DELETING each
    # per-head attempt cap, the guard against an auto-repair loop. A row this parser cannot vouch for
    # is a parse failure, not an empty repo.
    if not isinstance(p, dict) or not isinstance(p.get("head"), dict):
        print("__PARSE_ERR__", "a pull request object is not the documented shape"); raise SystemExit
    try: n = int(p.get("number") or 0)
    except Exception:
        print("__PARSE_ERR__", "a pull request number is not an integer"); raise SystemExit
    if n <= 0:
        print("__PARSE_ERR__", "a pull request number is not positive"); raise SystemExit
    head = p.get("head") or {}
    sha = str(head.get("sha") or "")
    br = str(head.get("ref") or "")
    if not sha or not br:
        print("__PARSE_ERR__", "a pull request carries no head sha/ref"); raise SystemExit
    # ⛔ A FORK HEAD REF DOES NOT EXIST IN THIS REPO, so a fixer can never materialise a worktree
    # for it — fix-one.sh aborts at materialisation AFTER the attempt was booked, which reads as
    # "still red after N fixes — needs a human" for a PR this queue could never fix. Flagged here so
    # the selector skips it WITH A REASON instead of paying for the discovery.
    # AN ABSENT repo KEY IS NOT EVIDENCE OF A FORK; a PRESENT but null one is a DELETED fork, whose
    # head ref is gone from this repo too, so both differ from a head that lives in this repo.
    hr = head.get("repo")
    if "repo" in head and hr is None: fork = 1
    elif isinstance(hr, dict) and str(hr.get("full_name") or "") not in ("", REPO): fork = 1
    else: fork = 0
    print("%d\t%s\t%s\t%d\t%d" % (n, sha, br.replace("\t","").replace("\n",""), 1 if p.get("draft") else 0, fork))
    ok += 1
print("__END__", ok)
' 2>/dev/null)"
  # the sentinel decides the RETURN CODE, not just a printed line — an empty answer and a failed
  # parse are both FAILED CALLS, never "this repo has no open PRs"
  _end="$(printf '%s\n' "$_rows_out" | grep -c '^__END__' 2>/dev/null)"
  _err="$(printf '%s\n' "$_rows_out" | sed -n 's/^__PARSE_ERR__[[:space:]]*//p' | head -1)"
  if [ -n "${_err:-}" ] || [ "${_end:-0}" != "1" ]; then
    printf 'the open-PR listing could NOT be parsed (%s) — a parse failure is a FAILED CALL, not "this repo has no open PRs"' \
      "${_err:-no completion sentinel; the parser died}"
    return 2
  fi
  printf '%s\n' "$_rows_out" | grep -v '^__END__'
  return 0
}

# ── 2. THE SURFACE, AND THE ONE POLARITY FUNCTION ──────────────────────────────────────────────
# ps_surface <owner/repo> <sha> -> TSV rows on stdout, rc 2 when the call FAILED OR the surface is
# EMPTY. Sets PS_SURFACE_ERR (one sentence, the reason) on rc 2.
#   app<TAB>name<TAB>status<TAB>conclusion<TAB>attempt-id<TAB>run-id<TAB>job-id
ps_surface() {
  local repo sha out rc tmp
  repo="$(ps_repo "${1:-}")"; sha="${2:-}"
  PS_SURFACE_ERR=""
  case "$sha" in
    ''|*[!0-9a-fA-F]*) PS_SURFACE_ERR="no head sha for this PR (a check surface is bound to a sha)"; return 2 ;;
  esac
  # ⛔ A LOCAL TEMP, NOT A GLOBAL. `ps_surface` is called DIRECTLY (the suite's classifier probes, and
  # any future caller that wants the rows rather than the verdict), and a global that only
  # `ps_verdict` initialised aborted that caller under `set -u` — the "works only on the one path it
  # was written for" shape.
  tmp="$(mktemp "${TMPDIR:-/tmp}/ps-surface.XXXXXX" 2>/dev/null)" || { PS_SURFACE_ERR="no temporary file could be created for the surface read"; return 2; }
  out="$(ps_gh --paginate "repos/$repo/commits/$sha/check-runs?per_page=100&filter=all" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    PS_SURFACE_ERR="check-runs API UNREADABLE for $sha (gh api exited $rc, ${#out} bytes) — an empty response is a FAILED CALL, never a green verdict"
    rm -f "$tmp" 2>/dev/null
    return 2
  fi
  printf '%s' "$out" | python3 -c '
import sys, json, re
dec = json.JSONDecoder(); s = sys.stdin.read(); i = 0
runs = []
while i < len(s):
    while i < len(s) and s[i] in " \n\r\t": i += 1
    if i >= len(s): break
    obj, i = dec.raw_decode(s, i)
    if isinstance(obj, dict) and isinstance(obj.get("check_runs"), list): runs.extend(obj["check_runs"])
    elif isinstance(obj, list): runs.extend(obj)
bad = 0
for c in runs:
    if not isinstance(c, dict): bad += 1; continue
    app = c.get("app")
    if isinstance(app, dict): app = app.get("slug") or ""
    app = str(app or "").replace("\t"," ").replace("\n"," ")
    name = str(c.get("name") or "").replace("\t"," ").replace("\n"," ")
    url = str(c.get("details_url") or c.get("html_url") or "")
    m = re.search(r"/runs/(\d+)(?:/job/(\d+))?", url)
    rid = m.group(1) if m else ""
    jid = (m.group(2) or "") if m else ""
    print("%s\t%s\t%s\t%s\t%s\t%s\t%s" % (app, name,
          str(c.get("status") or "").lower(), str(c.get("conclusion") or "").lower(),
          c.get("id") or 0, rid, jid))
if not runs: print("__EMPTY__")
' 2>/dev/null > "$tmp"
  if [ ! -s "$tmp" ]; then
    PS_SURFACE_ERR="the check-runs answer for $sha carried no parseable run (unreadable JSON) — never a green verdict"
    rm -f "$tmp" 2>/dev/null
    return 2
  fi
  if grep -qx '__EMPTY__' "$tmp"; then
    PS_SURFACE_ERR="the check surface for $sha is EMPTY (no check runs at all) — a missing check is not a green check"
    rm -f "$tmp" 2>/dev/null
    return 2
  fi
  grep -vx '__EMPTY__' "$tmp"
  rc=$?
  rm -f "$tmp" 2>/dev/null
  return "$rc"
}

# ps_polarity <- rows on stdin. PRINTS EXACTLY ONE token line (TSV):
#   RED<TAB><app/name><TAB><run-id><TAB><job-id><TAB><conclusion><TAB><all-red-groups>
#   WAIT<TAB><n-in-flight><TAB><n-groups>
#   GREEN<TAB><n-groups>
#   NOREAD<TAB><reason>
# ⛔ THE SINGLE SOURCE OF THE VERDICT. Deleting it must break WAIT and NOREAD together — pinned by
# pr-sickness.test.sh (f); do not add a second copy of this decision anywhere in this file.
ps_polarity() {
  awk -F'\t' -v OFS='\t' '
    BEGIN {
      n = split("success neutral skipped cancelled stale", a, " "); for (i=1;i<=n;i++) NONRED[a[i]]=1
      n = split("queued in_progress waiting requested pending", a, " "); for (i=1;i<=n;i++) INFL[a[i]]=1
      ng = 0; nred = 0; nwait = 0; first = ""
    }
    NF >= 5 {
      app=$1; name=$2; st=tolower($3); cc=tolower($4); id=$5+0
      k = app SUBSEP name
      if (!(k in seen) || id >= best[k]) {
        seen[k]=1; best[k]=id; S[k]=st; C[k]=cc; R[k]=$6; J[k]=$7; G[k]=(app==""? name : app "/" name)
        if (!(k in listed)) { listed[k]=1; order[++ng]=k }
      }
    }
    END {
      if (ng == 0) { print "NOREAD", "empty surface (no check groups) — a missing check is not green"; exit }
      for (i=1;i<=ng;i++) {
        k=order[i]
        if (S[k] in INFL) { nwait++; continue }
        if (C[k] in NONRED) continue
        # ANY OTHER CONCLUSION IS RED — including an empty one and one GitHub has not documented yet
        nred++
        if (first == "") { first=G[k]; frun=R[k]; fjob=J[k]; fcc=(C[k]==""? "<none>":C[k]) }
        reds = reds (reds==""?"":",") G[k]
      }
      if (nred > 0) { print "RED", first, frun, fjob, fcc, reds; exit }
      if (nwait > 0) { print "WAIT", nwait, ng; exit }
      print "GREEN", ng
    }
  '
}

# ps_verdict <owner/repo> <sha> -> the token (stdout). rc 0 = a verdict was reached (RED/WAIT/GREEN),
# rc 2 = NOREAD (and the token names WHY). Never returns a verdict it did not measure.
ps_verdict() {
  local tok tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/ps-rows.XXXXXX" 2>/dev/null)" || { printf 'NOREAD\tno temporary file for the surface rows\n'; return 2; }
  if ! ps_surface "${1:-}" "${2:-}" > "$tmp" 2>/dev/null; then
    printf 'NOREAD\t%s\n' "${PS_SURFACE_ERR:-the check surface could not be read (no reason recorded)}"
    rm -f "$tmp" 2>/dev/null
    return 2
  fi
  tok="$(ps_polarity < "$tmp" 2>/dev/null | head -1)"
  rm -f "$tmp" 2>/dev/null
  if [ -z "$tok" ]; then
    # A polarity that produced nothing is NOT an all-clear — the exact fail-open this guard removes.
    printf 'NOREAD\tps_polarity produced no verdict (the classifier is missing or failed) — never a green verdict\n'
    return 2
  fi
  printf '%s\n' "$tok"
  case "$tok" in RED*|WAIT*|GREEN*) return 0 ;; *) return 2 ;; esac
}

# ── 3. THE BRIEF, FROM THE FAILURE ITSELF ──────────────────────────────────────────────────────
# ps_job_log <owner/repo> <run> <job> -> the failing job's log excerpt on stdout (bounded).
# ⛔ THE JOB ENDPOINT FIRST, `gh run view` SECOND. `gh run view --log-failed` REFUSES while ANY job of
# the run is still in progress ("logs will be available when it is complete"), and a RED check whose
# workflow is still finishing its other legs is the NORMAL case — measured live on tortoise #9628,
# where the failure was in a completed job and the run as a whole was not. `actions/jobs/<id>/logs`
# answers for a COMPLETED job regardless. It needs `--allow-escape-sequences` (gh refuses the raw
# ANSI stream otherwise) — and a run's tail is post-job cleanup, not the failure, so the excerpt is
# the ERROR lines first and the plain tail only when no error marker matches.
ps_job_log() {
  local repo="$1" rid="${2:-}" jid="${3:-}" ghbin="${PS_GH:-gh}" out=""
  command -v "$ghbin" >/dev/null 2>&1 || return 1
  if [ -n "$jid" ]; then
    out="$("$ghbin" api --allow-escape-sequences "repos/$repo/actions/jobs/$jid/logs" 2>/dev/null \
      | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]*Z //')"
    if [ -n "$out" ]; then
      local err
      err="$(printf '%s\n' "$out" | grep -Ei '##\[error\]|AssertionError|^FAILED|fatal:|error:|Traceback|failed' | tail -60)"
      [ -n "$err" ] && { printf '%s' "$err"; return 0; }
      printf '%s' "$(printf '%s\n' "$out" | tail -60)"; return 0
    fi
    out="$("$ghbin" run view --repo "$repo" --job "$jid" --log-failed 2>/dev/null | tail -60)"
    [ -n "$out" ] || out="$("$ghbin" run view --repo "$repo" --job "$jid" --log 2>/dev/null | tail -60)"
  fi
  if [ -z "$out" ] && [ -n "$rid" ]; then
    out="$("$ghbin" run view "$rid" --repo "$repo" --log-failed 2>/dev/null | tail -60)"
  fi
  printf '%s' "$out"
}
# ps_brief <or> <pr> <sha> <group> <run> <job> <conclusion> <reds> -> prints the brief's path
ps_brief() {
  local repo="$1" pr="$2" sha="$3" group="$4" rid="$5" jid="$6" cc="$7" reds="$8" f log
  f="$(ps_state_dir)/sickbrief-$pr.md"
  mkdir -p "$(ps_state_dir)" 2>/dev/null || true
  log="$(ps_job_log "$repo" "$rid" "$jid" 2>/dev/null)"
  {
    printf '# CI failure brief — PR #%s at %s\n\n' "$pr" "$sha"
    printf 'head12: %s\n' "${sha:0:12}"
    printf 'Generated from the FAILURE (not from a template): %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'repo: %s\n' "$repo"
    printf 'failing group: %s\n' "$group"
    printf 'conclusion: %s\n' "$cc"
    printf 'run: %s\n' "${rid:-<none>}"
    printf 'job: %s\n' "${jid:-<none>}"
    [ -n "$reds" ] && printf 'all red groups: %s\n' "$reds"
    [ -n "$rid" ] && printf 'run url: https://github.com/%s/actions/runs/%s\n' "$repo" "$rid"
    printf '\n## Why this lane was dispatched\n'
    printf 'The check surface for this head was judged RED by polarity on the newest attempt per\n'
    printf '(app, name). This is the failing job'"'"'s own log, last 60 lines:\n\n```\n'
    if [ -n "$log" ]; then printf '%s\n' "$log"; else printf '<the failing job log could not be fetched — reproduce with: gh run view %s --repo %s --log-failed>\n' "${rid:-<run>}" "$repo"; fi
    printf '```\n'
  } > "$f" 2>/dev/null || return 1
  printf '%s' "$f"
}

# ── 4. WHO HOLDS IT (an abstention is NOT permission) ──────────────────────────────────────────
# ps_held <or> <pr> <sha> -> prints the holder; rc 0 HELD, 1 FREE, 2 UNKNOWN (treated as HELD).
ps_held() {
  local repo="$1" pr="$2" sha="$3" lock p why rc
  # ⛔ NO LIVENESS PRIMITIVE IS _UNKNOWN_, NOT FREE. `ps_alive` returning "no" because nothing defines
  # it would make every PR look unheld and duplicate whatever is actually running — an abstention is
  # not permission. The controller always defines `wt_alive`; the standalone CLI may not.
  if ! declare -f wt_alive >/dev/null 2>&1 && ! declare -f ps_alive_stub >/dev/null 2>&1; then
    printf 'no liveness primitive is loaded (neither wt_alive nor a stub) — cannot tell whether a lane holds PR #%s, so it is treated as held' "$pr"
    return 2
  fi
  lock="$(ps_state_dir)/mergeclaim-$pr.lock"
  if [ -f "$lock" ]; then
    p="$(cat "$lock" 2>/dev/null || echo 0)"
    if ps_is_num "${p:-0}" && [ "${p:-0}" -gt 0 ] && kill -0 "$p" 2>/dev/null; then
      printf 'mergeclaim pid=%s' "$p"; return 0
    fi
  fi
  if ps_alive "fix-$pr"; then printf 'live session fix-%s' "$pr"; return 0; fi
  if ps_alive "merge-$pr"; then printf 'live session merge-%s' "$pr"; return 0; fi
  # ⛔ TWO KEYS, TWO QUESTIONS, AND BOTH ARE ASKED. A fixer/reviewer holds the PER-HEAD key
  # (`<PR>-<sha12>`); only the landing path holds the coarse `pr-<N>` key. Reading the coarse one
  # alone made this guard inert for exactly the peer we must not duplicate (measured: two boxes each
  # spawn `fix-<PR>` for one head, and only fix-one.sh's CAS stops the second AFTER the budget was
  # booked). Any non-CLEAN answer from either key holds; INCOMPLETE (rc 2) is not free.
  local hrc
  if [ -n "${sha:-}" ] && declare -f claim_head_preflight >/dev/null 2>&1; then
    why="$(claim_head_preflight "$repo" "$pr" "$sha" 2>/dev/null)"; hrc=$?
    case "$hrc" in
      0) : ;;
      1) printf '%s' "${why:-a live per-head claim}"; return 0 ;;
      *) printf '%s' "${why:-the per-head claim registry could not be read}"; return 2 ;;
    esac
  fi
  why="$(ps_claim_preflight "$repo" "$pr" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) return 1 ;;                                  # CLEAN: nobody holds it
    1) printf '%s' "${why:-a live cross-box claim}"; return 0 ;;
    *) printf '%s' "${why:-the claim registry could not be read}"; return 2 ;;  # INCOMPLETE ≠ FREE
  esac
}

# ── 5. NOT A CI-QUEUE GATE (see the header: repair spends CI, but a spent slot is no veto) ──────
# This numbered step used to hold `ps_queue_verdict` — ~90 lines that read the repo's CI queue and
# derived `ceiling = ceil(runners*horizon/job_p90)` — plus `ps_load_ci_queue`, which sourced
# `ci-queue.sh` for it, plus a fallback arm that re-derived the same arithmetic when the module was
# absent. Every dispatch this file makes acts on an EXISTING PR — so that number was a reading of
# THIS BOX's own load, not of the capacity to repair, and it withheld repair anyway: 41 consecutive
# skips in one measured window (#2927), while the runners it was priced against sat idle.
# ⛔ IF A FUTURE CHANGE WANTS A QUEUE-DEPTH GATE HERE, the queue is not the thing that changed. Argue
# it against #2927 in the open, not by re-adding a predicate to this file line by line.

# ── 6. THE DEFERRAL QUEUE (a deferred item is NOT dropped) ────────────────────────────────────
# One row per (repo, PR, head, check). `ps_select` drains this FIRST, so an item deferred by
# back-pressure comes back on the next pass even if the PR has left the enumerated window.
ps_defer_file() { printf '%s/prsick-deferred.tsv' "$(ps_state_dir)"; }
ps_defer_append() { # <repo> <pr> <sha> <check> [branch]
  local f tmp; f="$(ps_defer_file)"; mkdir -p "$(ps_state_dir)" 2>/dev/null || true
  # ⛔ ONE ROW PER (repo, pr, head). A deep queue re-defers the same PR every pass; appending
  # unconditionally grew the ledger by one row per pass per PR, and the drain then decided the same
  # PR several times in ONE pass (a second spawn, and a head parked "needs a human" after a single
  # pass). Re-appending REPLACES the row.
  if [ -f "$f" ] && grep -qF "$(printf '%s\t%s\t%s' "${1:-}" "${2:-}" "${3:-}")" "$f" 2>/dev/null; then
    tmp="$f.new"
    awk -F'\t' -v r="${1:-}" -v p="${2:-}" -v s="${3:-}" '!($1==r && $2==p && $3==s)' "$f" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" >> "$f" 2>/dev/null || true
}
ps_defer_list() { cat "$(ps_defer_file)" 2>/dev/null; }
ps_defer_drop() { # <repo> <pr> <sha>
  local f tmp; f="$(ps_defer_file)"; tmp="$f.new"
  [ -f "$f" ] || return 0
  awk -F'\t' -v r="${1:-}" -v p="${2:-}" -v s="${3:-}" '!($1==r && $2==p && $3==s)' "$f" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# ── 7. ONE PR'S DECISION, AND THE DISPATCH ────────────────────────────────────────────────────
# psick_refund_head <state-dir> <pr> <head> -> refund the head-keyed attempt when a marker says NO
# AGENT RAN. Prints one line per refund. Exposed (not inlined) for THREE callers: ps_decide below, the
# red-fixer role in orch-loop.sh — which consumes `fixgate-<PR>-*` for its OWN counter and deleted the
# marker before this role could see it (so the refund was inert for exactly the PRs both roles target)
# — and a future role that books a head-keyed attempt. ONE marker must refund EVERY role that booked.
psick_refund_head() {
  local dir="${1:-}" pr="${2:-}" head="${3:-}" bcnt budget f any=0
  [ -n "$dir" ] && [ -n "$pr" ] && [ -n "$head" ] || return 0
  budget="$dir/psick-$pr-$(printf '%s' "$head" | cut -c1-12)"
  for f in "$dir/fixgate-$pr-$head" "$dir/fixbail-$pr-$head"; do
    [ -f "$f" ] || continue
    if [ ! -f "$budget" ]; then
      # ⛔ NOTHING BOOKED BY THIS ROLE ⇒ NOTHING TO REFUND, AND NOTHING TO DELETE. A `fixgate`/`fixbail`
      # marker is evidence for whichever arm BOOKED the attempt; this role may only consume it when it
      # has a counter of its own at that head.
      continue
    fi
    bcnt="$(cat "$budget" 2>/dev/null || echo 0)"; ps_is_num "${bcnt:-}" || bcnt=0
    [ "$bcnt" -gt 0 ] || continue
    any=1
    printf '%s\n' "$((bcnt - 1))" > "$budget" 2>/dev/null || true
    printf '[prsick] #%s %s at head=%s was not an attempt — budget refunded %s -> %s\n' \
      "$pr" "$(basename "$f")" "$(printf '%s' "$head" | cut -c1-12)" "$bcnt" "$((bcnt - 1))"
    # ⛔ ONLY `fixgate` IS DELETED HERE. `fixbail` is ARM-UNTAGGED: a reviewer-findings fixer's bail is
    # that arm's own evidence, and `refund_bailed_fixer` (restore=1) is the only consumer that refunds
    # `fixcount` AND restores `needsfix-<PR>-<head>`. Consuming it from this role silently loses the
    # reviewer's findings and buys a second full-context review — the class orch-loop.sh's own comment
    # forbids. Read it as evidence; leave it for its owner.
    [ "$(basename "$f")" = "fixgate-$pr-$head" ] && rm -f "$f" 2>/dev/null || true
  done
  [ "$any" = "1" ] && return 0
  return 1
}

# ps_decide <or> <pr> <sha> <branch> [fork] -> prints ONE decision line; rc 0 = dispatched.
# The three shapes (the operator's grep) — `backpressure(q=…,r=…)` used to be a fourth and was
# removed with the queue gate itself (#2927):
#   RED #<pr> <check> -> dispatch <tag>
#   skip #<pr>: in flight
#   skip #<pr>: held by <lane>
# plus named refusals for the budget / park / draft / fork / unsafe-ref / no-verdict cases — never
# silence.
ps_decide() {
  local repo="$1" pr="$2" sha="$3" br="$4" fork="${5:-0}" tok rc group rid jid cc reds holder hrc budget bf bcnt tag brief cmd gatef
  # ── THE REF MUST NOT BE ABLE TO REACH A SHELL, AND THE FIXER MUST BE ABLE TO CHECK IT OUT ────
  # The argv file already keeps API data out of the spawn line; this is the OTHER half the sweep
  # enforces (`safe_ref`): a fork's head ref does not exist in this repo, and a ref with a shell-ish
  # or git-illegal shape makes fix-one.sh abort at worktree materialisation — AFTER the attempt was
  # booked, which reads as "needs a human" for a PR we can never fix.
  if [ "$fork" = "1" ]; then
    printf 'skip #%s: fork PR (its head branch is not in this repo — a fixer cannot materialise it)\n' "$pr"
    return 1
  fi
  case "${br:-}" in
    ''|[-.]*|*..*|*[!A-Za-z0-9._/-]*) printf 'skip #%s: unsafe or empty branch name (%s) — not acted on\n' "$pr" "${br:-<empty>}"; return 1 ;;
  esac
  # …and git's own grammar when a checkout is reachable, because the pattern above is only a filter.
  if [ -n "${PS_REPO_PATH:-}" ] && [ -d "${PS_REPO_PATH:-}/.git" ] \
     && command -v git >/dev/null 2>&1 \
     && ! git -C "$PS_REPO_PATH" check-ref-format --branch "$br" >/dev/null 2>&1; then
    printf 'skip #%s: branch name %s is not a valid ref in this repo — not acted on\n' "$pr" "$br"
    return 1
  fi
  tok="$(ps_verdict "$repo" "$sha")"; rc=$?
  case "$tok" in
    NOREAD*)
      # (d) — a failed call is NAMED, dispatches nothing, and is never a green verdict.
      printf 'skip #%s: %s\n' "$pr" "$(printf '%s' "$tok" | cut -f2)"
      return 1 ;;
    WAIT*)
      # (c) — in flight is not red.
      printf 'skip #%s: in flight\n' "$pr"
      return 1 ;;
    GREEN*)
      printf 'skip #%s: green\n' "$pr"
      return 1 ;;
    RED*) ;;
    *) printf 'skip #%s: no verdict (%s) — never treated as green\n' "$pr" "$(printf '%s' "${tok:-<empty>}" | cut -c1-80)"
       return 1 ;;
  esac
  group="$(printf '%s' "$tok" | cut -f2)"; rid="$(printf '%s' "$tok" | cut -f3)"
  jid="$(printf '%s' "$tok" | cut -f4)"; cc="$(printf '%s' "$tok" | cut -f5)"; reds="$(printf '%s' "$tok" | cut -f6)"

  # ── the four gates that are NOT about the surface ──────────────────────────────────────────
  holder="$(ps_held "$repo" "$pr" "$sha")"; hrc=$?
  if [ "$hrc" -eq 0 ] || [ "$hrc" -eq 2 ]; then
    printf 'skip #%s: held by %s\n' "$pr" "${holder:-an unreadable claim}"
    return 1
  fi
  bf="$(ps_state_dir)/parked-$pr"
  if [ -s "$bf" ] && [ "$(cat "$bf" 2>/dev/null)" = "$sha" ]; then
    printf 'skip #%s: parked at this head — needs a human\n' "$pr"
    return 1
  fi
  budget="$(ps_state_dir)/psick-$pr-$(printf '%s' "$sha" | cut -c1-12)"
  # ⛔ NO AGENT RAN IS NOT AN ATTEMPT, and there are TWO markers that mean it:
  #   fixgate-<PR>-<HEAD>  a load/disk gate refused the agent (fix-one.sh)
  #   fixbail-<PR>-<HEAD>  the cross-box CAS refused (another box owned the head; fix-one.sh exits 0)
  # This role booked a head-keyed attempt for both, so it refunds both. See psick_refund_head.
  psick_refund_head "$(ps_state_dir)" "$pr" "$sha"
  bcnt="$(cat "$budget" 2>/dev/null || echo 0)"; ps_is_num "${bcnt:-}" || bcnt=0
  if [ "$bcnt" -ge "$(ps_maxtries "$PS_MAX_TRIES")" ]; then
    printf 'skip #%s: budget exhausted (%s/%s fixer attempts at head=%s) — needs a human\n' \
      "$pr" "$bcnt" "$(ps_maxtries "$PS_MAX_TRIES")" "${sha:0:12}"
    return 1
  fi

  # ── THE ROUTER'S ROW: IS A FIXER WHAT THIS HEAD NEEDS? (#2866) ──────────────────────────────
  # Two reds are NOT fixer work, and this module cannot tell them apart alone:
  #   WAIT:inherited-red  the same (app, workflow, job) is red at MAIN's head. A fixer sent here
  #                       spends a lane trying to fix a tree it does not own; measured 2026-10-22,
  #                       25 tortoise PRs sat blocked on ONE systemic assertion main already had.
  #   RERUN-FLAKE         the same group PASSED on an earlier attempt at this SAME head. A fixer
  #                       here edits code that is fine, pushes a new head, strands the head-bound
  #                       review attestation and buys a full CI pass — for a flake.
  # `unavailable` is printed and the module's own gates decide: a router that did not run is not a
  # reason to stop repairing reds.
  local prow prc paction prun preason
  prow="$(ps_router_row "$repo" "$pr")"; prc=$?
  paction="$(printf '%s' "${prow:-}" | cut -f1)"
  prun="$(printf '%s' "${prow:-}" | cut -f2)"
  preason="$(printf '%s' "${prow:-}" | cut -f3-)"
  case "$paction" in
    WAIT:inherited-red)
      printf 'skip #%s: %s (router: %s)\n' "$pr" "${preason:-inherited red}" "$paction"
      return 1 ;;
    RERUN-FLAKE)
      printf 'skip #%s: flake, not a fix — %s\n' "$pr" "${preason:-a job passed at this same head}"
      printf '         re-trigger: gh run rerun %s --failed (same sha; no new head, no attestation stranded)\n' "${prun:-<run>}"
      return 1 ;;
    unavailable)
      printf '[prsick] router UNAVAILABLE for #%s (%s) — this module'"'"'s own gates decide\n' "$pr" "${preason:-no reason recorded}"
      [ "$prc" -eq 2 ] || true ;;
    "") printf '[prsick] router returned no action for #%s — this module'"'"'s own gates decide\n' "$pr" ;;
  esac

  # ── EMIT THE WORK ITEM, THEN DISPATCH ─────────────────────────────────────────────────────
  brief="$(ps_brief "$repo" "$pr" "$sha" "$group" "$rid" "$jid" "$cc" "$reds")" || {
    printf 'skip #%s: brief could not be written (state/ unwritable) — nothing spawned\n' "$pr"
    return 1
  }
  tag="fix-$pr"
  if [ "${PS_DRY_RUN:-0}" = "1" ]; then
    printf 'RED #%s %s -> would-dispatch %s (dry-run: work item + brief written, no spawn)\n' "$pr" "$group" "$tag"
    return 0
  fi
  # The argv file is the SAME 4-line contract every other fixer call site uses (no PR-derived value
  # ever reaches `sh -c`).
  printf '%s\n' "${PS_REPO_PATH:-${REPO:-}}" "$repo" "$pr" "$br" > "$(ps_state_dir)/argv-$pr" 2>/dev/null || {
    printf 'skip #%s: argv record could not be written (state/ unwritable) — nothing spawned\n' "$pr"; return 1; }
  cmd="bash '${O:-$HOME/orchestrator}/fix-one.sh' --argv '$(ps_state_dir)/argv-$pr'"
  if ! ps_spawn "$tag" "${PS_SPAWN_CWD:-${PS_REPO_PATH:-${REPO:-$PWD}}}" "$cmd"; then
    printf 'skip #%s: spawn FAILED for %s (attempt not consumed)\n' "$pr" "$tag"
    return 1
  fi
  # ⛔ BOOK THE ATTEMPT ONLY AFTER THE SPAWN (the fix-one.sh contract: a killed spawn must not burn
  # an attempt, and the fixer refunds it when a load/disk gate refused the agent).
  printf '%s\n' "$((bcnt + 1))" > "$budget" 2>/dev/null || true
  ps_defer_drop "$repo" "$pr" "$sha"
  # tell the loop's ledger the LATER fact (one row per PR per cycle; dispreplace is its own writer)
  if declare -f dispreplace >/dev/null 2>&1; then
    dispreplace "$pr" "$sha" "SICK:$group" act "sickness fixer spawned from the failure itself ($group)"
  fi
  # Prune THIS PR's superseded per-head counters (a new head is new work; the old tree's counter can
  # never be reached again). Listed and matched EXACTLY rather than globbed, so the module stays
  # statically readable by the checkout guard.
  _ps_dir="$(ps_state_dir)"
  for _ps_f in $(ls -1 "$_ps_dir" 2>/dev/null | grep -x "psick-$pr-[0-9a-f][0-9a-f]*" 2>/dev/null); do
    [ "psick-$pr-$(printf '%s' "$sha" | cut -c1-12)" = "$_ps_f" ] && continue
    rm -f "$_ps_dir/$_ps_f" 2>/dev/null || true
  done
  printf 'RED #%s %s -> dispatch %s\n' "$pr" "$group" "$tag"
  return 0
}

# ── 8. THE PASS ───────────────────────────────────────────────────────────────────────────────
# ps_select [--repo OR] [--limit N] [--dry-run] [--max-spawn N] [--verbose]
# Prints one line per decision. Never spawns two fixers for one PR, and never for a held one.
# `--max-spawn` is the caller's MEASURED capacity (orch-loop.sh passes the remaining fix-lane
# headroom), so this queue adds no lane ceiling of its own: when the allowance is spent the REMAINING
# red PRs are DEFERRED to disk (they come back on the next pass), never dropped and never spawned past
# the box's capacity.
#
# ⛔ THE ORDER IS ENUMERATE-THEN-DRAIN, AND THAT IS A CORRECTNESS PROPERTY, NOT A PREFERENCE. A
# deferral row is a memory of a decision, not evidence that the PR is still work: draining it FIRST
# and trusting it (a) dispatched fixers for MERGED PRs on a dead head — a paid lane against a branch
# that no longer exists — and (b) let a ledger of rows for green/held PRs consume the whole read
# budget every pass, so the cursor never advanced and a red PR behind the ledger was never inspected
# at all. So the OPEN LISTING is the authority: a row whose PR is gone is dropped (and its budget
# pruned), a row whose head moved is dropped (a new head is new work), and a row that survives is
# decided only after being REMOVED (re-appended by the decision itself if it is still deferred).
ps_select() {
  local repo="" limit="" dry="${PS_DRY_RUN:-0}" verb=0 rows rc seen=0 dispatched=0 maxspawn=""
  DISPATCHED_PRS=""; SEEN_PRS=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --limit) limit="${2:-}"; shift 2 ;;
      --max-spawn) maxspawn="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --verbose) verb=1; shift ;;
      *) shift ;;
    esac
  done
  repo="$(ps_repo "$repo")"
  limit="$(ps_limit "${limit:-$PS_MAX_PRS}")"
  PS_DRY_RUN="$dry"
  mkdir -p "$(ps_state_dir)" 2>/dev/null || true
  # `` (absent) = no caller-imposed allowance: dispatch as the gates decide. `` is NOT 0 — a 0 here
  # would silently disable the whole queue on a caller that forgot the flag.
  if [ -n "$maxspawn" ] && ! ps_is_num "$maxspawn"; then maxspawn=""; fi

  # ── NO QUEUE GATE ON THIS PASS (#2927) ──────────────────────────────────────────────
  # This pass dispatches PR-REPAIR work only (fixers for EXISTING heads). That work DOES spend CI (a
  # repair push starts a fresh run) and is still not queue-gated — see the header: a queue slot is
  # not the bound on repair. So it reads no queue depth. The former arm here read the queue once per
  # pass, printed `[prsick] DEFERRED (backpressure)`, and — worse than the skip lines — GATED THE
  # LEDGER DRAIN on `qrc -eq 0`, so a deep queue also froze the items already waiting in
  # `prsick-deferred.tsv`.
  # The `--max-spawn` allowance below is the real bound: it is the box's remaining fix-lane headroom.

  # ── 1. ENUMERATE (the open listing is the authority for what MAY be dispatched) ────────────
  rows="$(ps_open_prs "$repo")"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[prsick] ENUMERATION FAILED — %s\n' "$rows"
    return 2
  fi
  local total _ledger_n
  total="$(printf '%s\n' "$rows" | grep -c . 2>/dev/null)"
  ps_is_num "${total:-}" || total=0
  _ledger_n="$(ps_defer_list 2>/dev/null | grep -c . 2>/dev/null)"
  ps_is_num "${_ledger_n:-}" || _ledger_n=0
  # ⛔ AN EMPTY LISTING DOES NOT PRUNE. The same endpoint family returns a complete empty body while
  # the repo has dozens of open PRs (measured on the RUNS endpoint: 70,70,0,70,70,70); treating one as
  # authoritative makes the reconciler declare every deferred PR "merged or closed" and DELETE each
  # per-head attempt cap — the auto-repair-loop guard. A repo with genuinely nothing open and a stale
  # ledger can wait one cycle for a listing that agrees with itself; nothing is lost by waiting, and a
  # false prune cannot be undone.
  if [ "$total" -eq 0 ] && [ "$_ledger_n" -gt 0 ]; then
    printf '[prsick] the open listing came back EMPTY while %s deferral row(s) exist — rows and attempt caps KEPT (an empty answer from this endpoint is not evidence that the PRs merged); nothing dispatched this pass\n' "$_ledger_n"
    return 0
  fi

  # ── 2. RECONCILE THE DEFERRAL LEDGER AGAINST IT, THEN DRAIN WHAT SURVIVES ─────────────────
  local drepo dpr dsha dchk dbr live keptf
  keptf="$(ps_state_dir)/prsick-kept.$$"
  : > "$keptf" 2>/dev/null || keptf=/dev/null
  [ -f "$(ps_defer_file)" ] || : > "$(ps_defer_file)" 2>/dev/null || true
  while IFS="$(printf '\t')" read -r drepo dpr dsha dchk dbr; do
    [ -n "${dpr:-}" ] || continue
    [ "$drepo" = "$repo" ] || continue
    ps_is_num "$dpr" || continue
    live="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$dpr" '$1==p{print $2; exit}')"
    if [ -z "${live:-}" ]; then
      printf '[prsick] #%s left the open set (merged or closed) — its deferral row is dropped and nothing is dispatched for it\n' "$dpr"
      rm -f "$(ps_state_dir)/psick-$dpr-$(printf '%s' "$dsha" | cut -c1-12)" 2>/dev/null || true
      ps_defer_drop "$repo" "$dpr" "$dsha"
      continue
    fi
    if [ "${live:-}" != "${dsha:-}" ]; then
      printf '[prsick] #%s head moved %s -> %s — its old deferral row is dropped (a new head is new work)\n' \
        "$dpr" "${dsha:0:12}" "${live:0:12}"
      rm -f "$(ps_state_dir)/psick-$dpr-$(printf '%s' "$dsha" | cut -c1-12)" 2>/dev/null || true
      ps_defer_drop "$repo" "$dpr" "$dsha"
      continue
    fi
    # ⛔ FIXTURE TEST SHIM: keptf is a TAB-delimited row, appended with printf (not a field-join).
    printf '%s\t%s\t%s\t%s\t%s\n' "$drepo" "$dpr" "$dsha" "$dchk" "$dbr" >> "$keptf" 2>/dev/null || true
  done < "$(ps_defer_file)"

  while IFS="$(printf '\t')" read -r drepo dpr dsha dchk dbr; do
    [ -n "${dpr:-}" ] || continue
    # ⛔ THE SAME ONE-DECISION-PER-PR INVARIANT THE ENUMERATION HAS. The drain had no guard, so a
    # ledger holding two rows for one PR (before dedupe, or a re-appended row) decided it twice in
    # ONE pass: two `fix-<PR>` spawns for one head, and the attempt budget consumed twice. The
    # liveness read is NOT a substitute — wt_alive answers "not alive" for a worker that already
    # exited (a cross-box bail or a gate refusal), so the second row would spawn.
    case " ${SEEN_PRS:-} ${DISPATCHED_PRS:-} " in *" $dpr "*) continue ;; esac
    if [ "$seen" -ge "$limit" ]; then break; fi
    # REMOVE FIRST, then decide: `ps_decide` re-appends the row when its own gate defers, so the
    # ledger survives exactly as long as the DEFERRAL does. Draining the row instead let green /
    # in-flight / held rows live forever and eat the whole budget (measured: a 10-row ledger
    # starved the enumeration on a 25-PR repo, cursor frozen).
    ps_defer_drop "$repo" "$dpr" "$dsha"
    SEEN_PRS="${SEEN_PRS} $dpr"
    seen=$((seen+1))
    if [ -n "$maxspawn" ] && [ "$dispatched" -ge "$maxspawn" ]; then
      ps_defer_append "$repo" "$dpr" "$dsha" "$dchk" "$dbr"
      printf 'skip #%s: no spawn slot this pass (dispatched=%s allowance=%s) — deferred\n' "$dpr" "$dispatched" "$maxspawn"
      continue
    fi
    if ps_decide "$repo" "$dpr" "$dsha" "$dbr"; then
      dispatched=$((dispatched+1)); DISPATCHED_PRS="${DISPATCHED_PRS} $dpr"
    fi
  done < "$keptf"
  [ "$keptf" = "/dev/null" ] || rm -f "$keptf" 2>/dev/null || true

  # ── 3. THEN THE ENUMERATION, ROUND-ROBIN ──────────────────────────────────────────────────
  local pr sha br draft fork cursor start idx
  cursor="$(ps_state_dir)/prsick-cursor"
  start="$(cat "$cursor" 2>/dev/null || echo 0)"; ps_is_num "${start:-}" || start=0
  if [ "$total" -gt 0 ]; then start=$(( start % total )); else start=0; fi
  idx=0
  while IFS="$(printf '\t')" read -r pr sha br draft fork; do
    [ -n "${pr:-}" ] || continue
    ps_is_num "$pr" || continue
    case " ${DISPATCHED_PRS:-} ${SEEN_PRS:-} " in *" $pr "*) continue ;; esac   # one decision per PR per PASS
    # round-robin: skip until the cursor, then stop at the read budget
    if [ "$total" -gt 0 ] && [ "$idx" -lt "$start" ]; then idx=$((idx+1)); continue; fi
    if [ "$seen" -ge "$limit" ]; then break; fi
    idx=$((idx+1)); seen=$((seen+1)); SEEN_PRS="${SEEN_PRS} $pr"
    [ "${draft:-0}" = "1" ] && { [ "$verb" = "1" ] && printf 'skip #%s: draft (not sick PR work)\n' "$pr"; continue; }
    if [ "${fork:-0}" = "1" ]; then
      printf 'skip #%s: fork PR (its head branch is not in this repo — a fixer cannot materialise it)\n' "$pr"
      continue
    fi
    if [ -n "$maxspawn" ] && [ "$dispatched" -ge "$maxspawn" ]; then
      ps_defer_append "$repo" "$pr" "$sha" "?" "$br"
      printf 'skip #%s: no spawn slot this pass (dispatched=%s allowance=%s) — deferred\n' "$pr" "$dispatched" "$maxspawn"
      continue
    fi
    if ps_decide "$repo" "$pr" "$sha" "$br" "$fork"; then
      dispatched=$((dispatched+1)); DISPATCHED_PRS="${DISPATCHED_PRS} $pr"
    fi
  done <<EOF
$rows
EOF
  # ⛔ THE CURSOR ADVANCES BY WHAT WAS INSPECTED, NOT BY WHERE THE LOOP BROKE. Writing `idx` froze it
  # whenever the budget ran out before the cursor was reached, so the PRs past it were never visited.
  if [ "$total" -gt 0 ]; then printf '%s\n' "$(( (start + seen) % total ))" > "$cursor" 2>/dev/null || true; fi
  [ "$verb" = "1" ] && printf '[prsick] pass done: inspected=%s dispatched=%s deferred=%s\n' \
    "$seen" "$dispatched" "$(ps_defer_list | wc -l | tr -d ' ')"
  return 0
}

# ── standalone report (read-only; never spawns) ──────────────────────────────────────────────
ps_cli() {
  local verb="${1:-report}"; shift 2>/dev/null || true
  PS_STATE_DIR="${PS_STATE_DIR:-${TMPDIR:-/tmp}/ps-cli-$$}"
  case "$verb" in
    report) PS_DRY_RUN=1 ps_select --verbose "$@" ;;
    *) printf 'usage: pr-sickness.sh report|pass [--repo owner/name] [--limit N] [--dry-run]\n' >&2; return 64 ;;
  esac
}
if [ "${BASH_SOURCE:-}" = "$0" ] || { [ -z "${BASH_SOURCE+x}" ] && [ -n "${0:-}" ]; }; then
  ps_cli "$@"
  exit $?
fi
