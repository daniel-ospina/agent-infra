#!/bin/bash
# auto-rail — the actuator: any PR whose check surface is fully terminal AND has no red,
# gets a rail launched, without an agent in the loop. The rail itself remains the gate
# (it re-reads everything: lane terminal, base comparison, evaluated tree, evidence),
# so this only removes the WAITING, never a check.
#
#   * grouped by (name), newest attempt per group — a superseded failure must not outvote
#     a green re-run (the rail's §2C rule, applied here so we queue the right PRs)
#   * in-flight => not a candidate (a queued check is a WAIT, never a green)
#   * at most MAX rails per repo, and MAX_TOTAL overall; a PR that already has a rail is skipped
#   * one lock: two copies of this script would double-rail
set -u
MAX=${MAX:-2}
case "${MAX}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: MAX='${MAX}' is not a positive integer — this actuator would not know its own bound" >> /tmp/auto-rail.log; exit 3;; esac
# ⛔ ZERO IS NOT A BOUND, IT IS A STALL — and the message above always said "positive integer".
# `case` above accepts `0` (it is a digit), and `MAX=0` derives `MAX_TOTAL=0`, whose clause
# `[ total -ge 0 ]` is true for EVERY population: the actuator would defer every candidate for ever
# while logging a normal-looking `deferred (…)`. Fail-closed, but a silent total stall is exactly the
# state this guard exists to make diagnosable, so refuse it here rather than discover it in the log.
[ "$MAX" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: MAX='${MAX}' is not a POSITIVE integer — 0 would defer every candidate for ever" >> /tmp/auto-rail.log; exit 3; }
# The repos this actuator drives. `rails_for_repo` takes the FULL slug for the repo being asked about
# plus this same list for the population, and derives every short name itself — one call shape, so the
# two cannot drift apart (the bug that made `unattributed` read 1 for a rail that WAS attributed).
REPOS="daniel-ospina/tortoise daniel-ospina/agent-infra"
# The aggregate's derivation is a FUNCTION, for the same reason `rails_should_defer` is: a test must be
# able to pin the SHIPPED arithmetic instead of a copy of it. Every review round on this branch rewrote
# the MAX_TOTAL line (three of five rounds), which is exactly the line that cannot be left unpinned — a
# literal `MAX * 2` in the test would keep passing after the derivation was broken or disarmed.
max_total_for() {  # $1 = MAX; $2.. = the repos this actuator drives
  local max=$1 n=0 _r
  shift
  for _r in "$@"; do n=$(( n + 1 )); done
  printf '%s\n' "$(( max * n ))"
}
# ── ⛔ THE MERGE-SLOT ACCOUNTING IS PER REPO (2026-11-01). IT WAS GLOBAL, AND THAT STARVED A QUEUE. ──
# `rails_live` used to be ONE count across every repo this actuator drives, and it gated EVERY repo's
# candidates. So rails working on repo A consumed repo B's merge capacity. Measured on this box: a
# per-pass population of `rails_live=8..15 max=8` in which the overwhelming majority were agent-infra
# rails waiting out their FIRST-CHECKS bound, and tortoise's ONLY candidate deferred on every pass —
#
#   2026-11-01T16:48:57Z daniel-ospina/tortoise pass: candidates=1 rails_live=11 max=8
#   2026-11-01T16:48:57Z daniel-ospina/tortoise #10010 deferred (11 rails already live, max=8)
#
# — while `ps` at 17:12Z showed 6 rails on agent-infra, 1 on tortoise. A per-repo queue gated by a
# global counter is not a concurrency bound, it is one repo's backlog holding another's queue shut.
#
# MAX is the budget for ONE repo. Mergify, the closest analogue (independent queues feeding one shared
# CI resource), scopes concurrency exactly this way: `max_parallel_checks` is a GLOBAL cap and per-scope
# `capacities` cap an individual queue (docs.mergify.com/merge-queue/queue-modes). GitHub's merge-queue
# build concurrency and Trunk's are likewise per queue, not per machine. Nobody scopes a queue's limit to
# "everything else the box happens to be running".
#
# ⛔ PER-REPO MUST NOT SILENTLY MULTIPLY THE LOAD BOUND. MAX=8 was justified against this machine's CPU
# ceiling (see the launchd plist), so making it per-repo would turn an 8-rail bound into 8×N with nothing
# saying so. MAX_TOTAL is that aggregate, NAMED AND TUNABLE instead of an arithmetic accident: MAX × the
# number of repos this actuator drives, DERIVED from REPOS so that adding a third repo cannot leave the
# aggregate below the sum of the per-repo budgets. It is a ceiling on what THIS ACTUATOR LAUNCHES, never a
# bound on the box — measured 2026-11-01 the box carried 15 rails against max=8, because pr-doctor and the
# repair lanes start rails without consulting this counter at all. The real governor is measured load at
# dispatch time.
# ⛔ AND THE AGGREGATE IS A REAL CEILING, NOT A DECORATION — say so rather than claiming the class is
# dead: at `total >= max_total` an otherwise-idle repo's candidate IS still deferred by other repos'
# rails. That population is reachable (the log holds rails_live=15 and =16 today), so max_total is a
# bound on how much THIS actuator will pile into the shared REST budget, not a promise that the symptom
# can never recur at a larger population. It is printed on every pass for exactly that reason.
MAX_TOTAL=${MAX_TOTAL:-$(max_total_for "$MAX" $REPOS)}
case "${MAX_TOTAL}" in ''|*[!0-9]*)
  echo "$(date -u +%FT%TZ) REFUSED: MAX_TOTAL='${MAX_TOTAL}' is not a positive integer — an unparseable ceiling reads as FALSE and would disarm the aggregate bound" >> /tmp/auto-rail.log; exit 3;; esac
# ⛔ NO BACKTICKS INSIDE A DOUBLE-QUOTED MESSAGE: `` `[ total -ge 0 ]` `` in this string was COMMAND
# SUBSTITUTION (measured cycle 4) — bash ran `[ total -ge 0 ]`, printed `[: total: integer expression
# expected` to stderr, and deleted the entire explanatory clause from the log line, i.e. it truncated
# the message at the exact point that explains why the value is refused. The suite now matches the
# explanation FRAGMENT, not just `REFUSED: MAX_TOTAL=`, so this cannot come back silently.
[ "$MAX_TOTAL" -gt 0 ] || { echo "$(date -u +%FT%TZ) REFUSED: MAX_TOTAL='${MAX_TOTAL}' is not a POSITIVE integer — 0 makes the aggregate clause '[ total -ge 0 ]' true for every population, i.e. every candidate deferred for ever" >> /tmp/auto-rail.log; exit 3; }
INTERVAL=${INTERVAL:-180}
# ⛔ THE RAIL MUST LIVE SOMEWHERE THAT SURVIVES. Measured 2026-10-30 08:20Z, on this very actuator:
#    RAIL_SCRIPT defaulted to `/tmp/wt-regsync2/scripts/admin-merge.sh`  -> MISSING
#    PARALLEL    defaulted to `/tmp/jobs2/rail-parallel.sh`              -> MISSING
#    the redirect target `/tmp/rails/`                                   -> MISSING
# and `/tmp/auto-rail.log` contained **zero** `launching rail` lines — not "none needed": the launch path
# could not have worked if a candidate HAD appeared. It polled every 180 s, logged `candidates=0`, and was
# incapable. `candidates=0` is exactly what a healthy idle pass looks like, which is why this survived.
# A helper that lives in /tmp is a helper macOS deletes; a rail that lives in a checkout survives.
# ⛔ THE RAIL MUST BE EXECUTABLE FROM THE ENVIRONMENT THIS JOB RUNS IN — a path is not enough
# (measured 2026-10-30): with the hub path, all 9 launches of the first working pass died
# `Operation not permitted` — macOS TCC forbids a launchd agent from exec-ing a script under
# ~/Documents. `~/rail-hub` is a real git clone, fast-forwarded at the top of every pass, so it is what
# main carries at a path TCC permits — not a hand-copied mirror, which would be the stale-code trap.
RAIL_SCRIPT=${RAIL_SCRIPT:-$HOME/rail-hub/scripts/admin-merge.sh}
RAIL_HUB=$(dirname "$(dirname "$RAIL_SCRIPT")")
# ⛔ THE `gh` THIS JOB FINDS MUST BE THE SHIM **AND** EXECUTABLE HERE. `~/.pi/agent/shims/gh` is a symlink into
# ~/Documents (TCC-denied for launchd), and using the real gh directly would DROP the argv-level admin-merge
# guard (#984) from the one actor that merges automatically. The rail-hub clone carries scripts/gh-shim/gh at a
# TCC-free path and is refreshed to origin/main every pass, so this is the current guard, not a copy of it.
if [ -x "$RAIL_HUB/scripts/gh-shim/gh" ]; then
  export PATH="$RAIL_HUB/scripts/gh-shim:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/share/pi-node/node-v22.23.2-darwin-arm64/bin:/opt/homebrew/bin:/usr/local/bin"
else
  echo "$(date -u +%FT%TZ) REFUSED: no executable gh shim at $RAIL_HUB/scripts/gh-shim/gh — refusing to fall back to an unguarded gh" >> /tmp/auto-rail.log
  exit 3
fi
# ⛔ NO ACTUATOR MAY PASS SILENTLY WITH A MISSING DEPENDENCY. Fail loudly, once, at start: a launchd job
# that exits non-zero with a reason is diagnosable; one that logs a placid `candidates=0` for weeks is not.
RAIL_DIR=$HOME/.pi/agent/state/rails
# ⛔ (pr, head) ALREADY ANSWERED => DO NOT ASK AGAIN. Measured 2026-10-30: identical refusals were re-railed
# every pass, because the only thing that can change a refusal is a new head (push/rebase/conflict resolved)
# or a PR-state change — and neither happens by waiting 5 minutes.
TRIED=$HOME/.pi/agent/state/rails/tried.tsv
COOLDOWN_S=${COOLDOWN_S:-21600}
# ⛔ A COOLDOWN MUST BE KEYED TO WHAT CAN CHANGE THE ANSWER, NOT TO THE HEAD.
# Measured 2026-10-30 18:13Z: the head-keyed cooldown below skipped tortoise #9876 with the sentence
# "a refusal can only change with a new head" — which is FALSE. #9876 was refused for "no run of the
# lane actually TESTED head" while CI was still running; 20 minutes later it was GREEN and attested at
# the SAME head, and this actuator would not look at it for six hours. The same holds for a stale
# attestation being re-recorded and for main going green. So: a verdict that can only be changed by a
# NEW HEAD (CONFLICTED, DRAFT) keeps the long cooldown; every other verdict gets the short one.
COOLDOWN_TRANSIENT_S=${COOLDOWN_TRANSIENT_S:-900}
# ⛔ THE RAIL DIRECTORIES ARE PRECONDITIONS, NOT DECORATION. Every launch writes its verdict into
# `$RAIL_DIR`, and the cooldown logic READS it; a `mkdir` whose status nobody checks, and a redirect that
# cannot be opened, both leave the ledger recording "railed" for a rail that never ran — measured cycle 4
# on this file: `nohup … > <unopenable> 2>&1 &` returns 0 to the caller, the log says `launching rail`,
# and every later pass reports "this head was already railed … only a NEW HEAD can change" for six hours
# over a rail that never started. Refuse at start instead of failing silently per launch, exactly as the
# `$TRIED` and `$RAIL_SCRIPT` checks below do.
if ! mkdir -p "$RAIL_DIR" 2>/dev/null || [ ! -d "$RAIL_DIR" ] || [ ! -w "$RAIL_DIR" ]; then
  echo "$(date -u +%FT%TZ) REFUSED: cannot create a writable rail-verdict directory at $RAIL_DIR — a launch that cannot write its verdict is a failed launch this log would record as a launch" >> /tmp/auto-rail.log
  exit 3
fi
# ⛔ THE COOLDOWN LEDGER IS THE ONLY THING STOPPING AN UNLIMITED RE-RAIL LOOP, so its absence is a
# refusal, not a shrug: unreadable/unwritable, every candidate reads as "never tried" and is launched
# again every INTERVAL, each launch consuming a MAX slot. Refuse once, diagnosably, at start.
if ! touch "$TRIED" 2>/dev/null || [ ! -w "$TRIED" ]; then
  echo "$(date -u +%FT%TZ) REFUSED: cannot create the cooldown ledger at $TRIED — without it every candidate would be re-railed every pass" >> /tmp/auto-rail.log
  exit 3
fi
if [ ! -f "$RAIL_SCRIPT" ]; then
  echo "$(date -u +%FT%TZ) REFUSED: rail not found at $RAIL_SCRIPT — this actuator cannot land anything" >> /tmp/auto-rail.log
  exit 3
fi
# ⛔ PRs the consolidation pass (aiconsol2, 2026-10-24) flagged as one of a DUPLICATE PAIR whose
# survivor is not yet decided. Green checks do not make a duplicate safe to merge: the pair exists
# because two lanes implemented the same issue, and merging both lands one change twice.
# ⛔ A DENY entry is a claim about the PRESENT, and this list was a claim about 20:30Z.
# Revalidated 2026-10-24T22:10Z (measured, not assumed): of the original eleven, SIX named a
# partner that is no longer open — `#2317 CLOSED`, `#2247 CLOSED`, `#2336 MERGED` — so the
# refusal they justified no longer exists. A DENY that outlives its partner is a FALSE REFUSAL:
# it blocks a green, recorded PR for ever, and it is invisible because the only symptom is
# `candidates=0` on every pass (measured on both repos, 21:52Z and 21:57Z).
# Only pairs where BOTH sides are still OPEN stay here. Re-derive this list, never append to it:
#   for n in $DENY; do gh pr view $n --json number,state,title; done
DENY=" 2597 2608 2172 2551 "
LOG=/tmp/auto-rail.log
LOCK=/tmp/auto-rail.lock
# macOS has no `flock`; a directory is an atomic lock.
if ! mkdir "$LOCK.d" 2>/dev/null; then
  holder=$(cat "$LOCK.d/pid" 2>/dev/null || echo "?")
  if [ -n "$holder" ] && ps -p "$holder" >/dev/null 2>&1; then
    echo "$(date -u +%FT%TZ) another auto-rail (pid $holder) holds the lock — exiting" >> "$LOG"; exit 0
  fi
  echo "$(date -u +%FT%TZ) stale lock from pid $holder — taking it" >> "$LOG"; rm -rf "$LOCK.d"; mkdir "$LOCK.d" || exit 0
fi
echo $$ > "$LOCK.d/pid"; trap 'rm -rf "$LOCK.d"' EXIT INT TERM
log_line() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
# ── merge-slot accounting, PER REPO ─────────────────────────────────
# Attribution has PRECEDENCE, and it is ONE pass over the process table rather than three greps over it —
# three greps is how a rail can be counted twice by one and never by another.
#   1. an explicit `--repo <owner/name>` from the launcher decides;
#   2. else the repo named in the rail SCRIPT's own path (a clone/worktree of one repo);
#   3. else UNKNOWN.
# A rail attributable to NEITHER is UNKNOWN, and so is one whose `--repo` names a repo this actuator does
# not drive. Unknown load must never read as free load (fail-closed), so it counts against EVERY repo and
# is printed: that is the difference between "no rails here" and "rails I cannot see".
# Prints `<own> <total> <unknown>`; $1 is the repo being asked about, $2.. every repo driven.
rails_for_repo() {
  local tbl
  # ⛔ A FAILED DATA SOURCE IS NOT AN EMPTY QUEUE — the rule the candidate search below states at
  # SEARCH-FAILED, and the counter path did not have. This script has no `pipefail`, so a `ps` that
  # cannot run (rc≠0, no process table) left python reading EOF and printing a perfectly parseable
  # `0 0 0`: the guard in `rails_should_defer` never fired, BOTH bounds disarmed, and the log read
  # byte-identically to a healthy idle box. Capture the table and its STATUS first, and print NOTHING
  # on failure — empty output is exactly what makes that guard defer (fail-closed).
  tbl="$(ps -eo args= 2>/dev/null)" || { log_line "COUNTER-FAILED: ps rc=$? — cannot read the process table, deferring $1 (fail-closed)"; return 1; }
  printf '%s\n' "$tbl" | python3 -c '
import sys
me = sys.argv[1].split("/")[-1]
known = [r.split("/")[-1] for r in sys.argv[2:]]
own = total = unk = 0
for raw in sys.stdin.buffer:
    # a single non-UTF-8 byte in any argv would otherwise kill this whole read (UnicodeDecodeError),
    # the function would print nothing, and the caller would see an unreadable population.
    line = raw.decode("utf-8", "replace")
    if "admin-merge.sh " not in line or "[a]dmin-merge.sh" in line:
        continue
    total += 1
    toks = line.split()
    slug = None
    for i, t in enumerate(toks):
        if t == "--repo" and i + 1 < len(toks):
            slug = toks[i + 1].split("/")[-1]
            break
    if slug is None:
        for k in known:
            if "/%s/" % k in line:
                slug = k
                break
    if slug is None or slug not in known:
        unk += 1
    elif slug == me:
        own += 1
print(own, total, unk)
' "$@"
}
# The defer decision, in ONE place, so a test can pin the SHIPPED predicate instead of a copy of it.
rails_should_defer() {  # $1 = this repo (owner/name), $2.. = every repo driven
  local own total unk
  read -r own total unk <<< "$(rails_for_repo "$@")"
  # ⛔ AN UNPARSEABLE COUNTER IS NOT A FREE SLOT. `read` succeeds on empty output, and then `[ "" -ge n ]`
  # errors — and an errored `[` reads as FALSE, i.e. LAUNCH. So say it and defer: a population I cannot
  # read is load I cannot rule out, which is the same fail-closed rule as the unknown bucket.
  case ":${own}:${total}:${unk}:" in
    *[!0-9:]*|::*|*::|*:::*) log_line "COUNTER-FAILED: rails_for_repo produced no usable counts — deferring $1 (fail-closed)"; return 0;;
  esac
  [ $(( own + unk )) -ge "$MAX" ] || [ "$total" -ge "$MAX_TOTAL" ]
}
# ── THE CALL SITE'S SHAPE, as a function ───────────────────────────────────────────────────────
# `rails_should_defer` is only PER-REPO because its caller passes the whole population ($REPOS)
# alongside the repo being asked about. Drop that argument — or put the old global `total >= MAX`
# back at the call site — and every other repo's rails read as unknown load: the fix is fully undone
# while the predicate itself is untouched, and a suite that drives the predicate alone cannot see it.
# So the call site's shape is a function the suite DRIVES — and the loop's own invocation of it is
# pinned SEPARATELY, by a declared text assertion in the suite, because the loop cannot be executed
# without stub-driving the whole supervisor. Neither pin alone is enough: driving this wrapper cannot
# see `"$repo"` losing its `$REPOS` at the loop, and a grep at the loop cannot see this wrapper
# mangling its arguments. The suite states which is which (see its "call site" section).
candidate_deferred() {  # $1 = this repo, $2.. = every repo driven  (rc 0 = defer this candidate)
  rails_should_defer "$@"
}
# ── THE DUPLICATE-RAIL GUARD, as a function ────────────────────────────────────────────────────
# rc 0 = a rail for THIS PR is live (skip it), 1 = no rail for it, 2 = CANNOT TELL — and 2 is not 1.
# The guard used to read `ps … | grep -c`, which has no `pipefail` here: a failing `ps` left `grep -c`
# reading EOF, printing `0`, so "I cannot see the process table" became "no rail is running" and the
# actuator launched a SECOND rail for a PR that already had one — burning the shared REST budget,
# doubling the merge attempt, and inflating this repo's own count so other candidates of the repo this
# change exists to unstarve get deferred. A FUNCTION so the suite drives all three answers.
rail_already_running() {  # $1 = PR number
  local tbl live
  tbl=$(ps -eo args= 2>/dev/null) || { log_line "COUNTER-FAILED: ps rc=$? — cannot rule out an existing rail for #$1 (fail-closed)"; return 2; }
  live=$(printf '%s\n' "$tbl" | grep -cE "[a]dmin-merge[.]sh([[:space:]]+[^[:space:]]+)*[[:space:]]+$1([[:space:]]|$)")
  [ "$live" -gt 0 ]
}
# ── THE DUPLICATE-RAIL ANSWER, MAPPED TO AN ACTION ──────────────────────────────────────────────
# `rail_already_running` has three answers and the pass has two actions; collapsing the third into
# "no rail" is the fail-open. That mapping lives here, as a DRIVEN function, because a bare
# `if [ "$rc" -ne 1 ]` at the loop is one line a reviewer found could be deleted with the suite green.
rail_says_skip() {  # $1 = rc from rail_already_running  (rc 0 = skip this candidate)
  case "$1" in
    0) return 0;;   # a rail for this PR is live
    1) return 1;;   # no rail: proceed
    *) return 0;;   # CANNOT TELL -> skip (fail-closed) — never a launch
  esac
}
# Keep the TCC-free rail clone current BEFORE using it. A failed refresh is LOUD but not fatal: the
# previous HEAD then runs, which is strictly better than not merging, and the log says which happened.
if [ -d "$RAIL_HUB/.git" ]; then
  if git -C "$RAIL_HUB" fetch -q --depth 1 origin main 2>>"$LOG" \
     && git -C "$RAIL_HUB" -c advice.detachedHead=false checkout -q -B main origin/main 2>>"$LOG"; then
    log_line "rail-hub refreshed -> $(git -C "$RAIL_HUB" rev-parse --short HEAD)"
  else
    log_line "rail-hub REFRESH FAILED — running $(git -C "$RAIL_HUB" rev-parse --short HEAD) (possibly stale)"
  fi
else
  log_line "REFUSED: no rail clone at $RAIL_HUB — the rail cannot be executed from ~/Documents (TCC)"
  exit 3
fi
log_line "auto-rail started max=$MAX interval=${INTERVAL}s rail=$RAIL_SCRIPT"

while :; do
  for repo in $REPOS; do
    python3 - "$repo" "${RED_CAP:-2}" <<'PY' 2>> "$LOG" > /tmp/auto-rail-cand.$$
import json,subprocess,sys
repo=sys.argv[1]
try:
    r=subprocess.run(["gh","pr","list","--repo",repo,"--state","open","--limit","100",
        "--json","number,mergeable,isDraft,statusCheckRollup,body"],capture_output=True,text=True)
except Exception as e:
    # ⛔ THIS IS HOW THE ACTUATOR WAS DEAD FOR DAYS WITHOUT A SYMPTOM (measured 2026-10-30): `gh` exists
    # ONLY at ~/.pi/agent/shims/gh, that directory was missing from this job's PATH, so subprocess raised
    # FileNotFoundError here, the whole heredoc died, and the pass logged `candidates=0` — byte-identical
    # to a healthy idle pass. 1.5 MB of tracebacks accumulated in StandardErrorPath where nobody looks.
    print("SEARCH-FAILED %s: %s" % (type(e).__name__, e), file=sys.stderr); sys.exit(0)
o=r.stdout
try: prs=json.loads(o)
except Exception:
    # ⛔ A FAILED DATA SOURCE IS NOT AN EMPTY QUEUE (2026-10-30). This block used to `sys.exit(0)` on any
    # parse failure, so a `gh` that could not run at all (PATH, auth, rate limit) printed ZERO candidates
    # and the pass logged `candidates=0` — the exact ALIVE/REFUSING/IDLE ambiguity this script's own
    # comments call out. Say it instead.
    print("SEARCH-FAILED rc=%s stderr=%s" % (r.returncode, (r.stderr or "").strip().splitlines()[:1]), file=sys.stderr)
    sys.exit(0)
green=[]; red=[]
for p in prs:
    # ⛔ A PR WITHOUT A REVIEW RECORD CANNOT MERGE, so railing it is noise that occupies a MAX slot.
    # Measured 2026-10-24: three PRs sat at reds=0 with a record and NOBODY railed them (that is what
    # this script exists for) while many more were red only on `pipeline-compliance (c)` -- no head-bound
    # record -- and a rail on those refuses in seconds. Requiring the marker makes the candidate set
    # equal the set of PRs that can actually land, which is the whole point of an actuator.
    if "review recorded:" not in (p.get("body") or ""):
        continue
    # A DRAFT CAN NEVER MERGE: the rail refuses it in one line ("PR is a DRAFT").
    if p.get("isDraft"):
        continue
    g={}
    for c in p.get("statusCheckRollup") or []:
        k=c.get("name") or c.get("context")
        if k not in g or (c.get("databaseId") or 0) > (g[k].get("databaseId") or 0): g[k]=c
    redn=inflight=0
    for k,c in g.items():
        st,co=c.get("status"),c.get("conclusion")
        if st and st!="COMPLETED": inflight+=1; continue
        if co in ("SUCCESS","NEUTRAL","SKIPPED","CANCELLED","STALE"): continue
        redn+=1
    if not g or inflight: continue
    # ⛔ AND A RED PR IS STILL A CANDIDATE -- OTHERWISE THIS ACTUATOR CAN NEVER CLEAR THE ACTUAL QUEUE.
    # Measured 2026-10-30: the open queue was 12 PRs with red>0 and 0 with red==0, because `main` is red
    # on pre-existing broken suites, so EVERY PR inherits a red that is not its own. The rail has an
    # exemption engine for exactly that (scripts/ci_exemption.py: an id is EXEMPT only when it was
    # measured on main over several runs), and this filter never let the rail reach it -- the actuator
    # was strictly stricter than the gate it feeds, which is why 32 PRs sat. Green goes first and
    # red-handed-over rails are CAPPED (RED_CAP) so a burst cannot burn the API budget; the rail still
    # refuses anything whose red is unique to the PR.
    (green if redn==0 else red).append((redn, p["number"]))
for _r,n in sorted(green): print(n)
for _r,n in sorted(red)[:int(sys.argv[2])]: print(n)
PY
    # ⛔ A SILENT PASS IS NOT EVIDENCE OF A HEALTHY PASS (measured 2026-10-24). This actuator logged
    # NOTHING between 14:47 and 15:20 — alive, polling, and either finding zero candidates or
    # refusing silently — and those two readings are indistinguishable from the log. That is the
    # exact ALIVE / REFUSING / IDLE ambiguity the fleet keeps paying for (agent-infra #2700): a
    # capability that cannot report "I looked and found nothing" gets diagnosed as dead on the next
    # bad day. One line per repo per pass makes the answer readable.
    # The counts are PER REPO (that is the fix) and `unattributed` is printed rather than dropped: a
    # rail nobody can attribute is unknown load, and a report that omits it reads as "none".
    read -r _own _total _unk <<< "$(rails_for_repo "$repo" $REPOS)"
    log_line "$repo pass: candidates=$(wc -l < /tmp/auto-rail-cand.$$) cand_bytes=$(wc -c < /tmp/auto-rail-cand.$$ 2>/dev/null || echo MISSING) rails_on_repo=$_own rails_live=$_total unattributed=$_unk max=$MAX max_total=$MAX_TOTAL"
    while read -r pr; do
      [ -z "${pr:-}" ] && continue
      case "$DENY" in *" $pr "*) log_line "$repo #$pr DENIED — duplicate-pair member or contradictory PR pending a decision"; continue;; esac
      # ⛔ THE SAME FAIL-OPEN THIS FILE FORBIDS AT THE COUNTER, one line below it. No `pipefail` here,
      # so a `ps` that cannot run left `grep -c` reading EOF and printing `0`: "I cannot see the process
      # table" became "no rail is running for #pr", and the actuator would launch a SECOND rail for a PR
      # that already has one — burning the shared REST budget, doubling the merge attempt, and inflating
      # this repo's own count so other candidates of the repo this change exists to unstarve are deferred.
      # Unreadable is not zero: skip the candidate loudly (a pass that cannot rule a rail out must not add one).
      rail_already_running "$pr"; _rail_rc=$?
      if rail_says_skip "$_rail_rc"; then
        if [ "$_rail_rc" -eq 0 ]; then log_line "$repo #$pr skipped (rail already running)"
        else log_line "$repo #$pr skipped — cannot rule out an existing rail (fail-closed)"; fi
        continue
      fi
      # ⛔ THIS REPO'S BUDGET, NOT THE BOX'S. `rails_should_defer` adds the unattributable population to
      # this repo's own count (fail-closed) and keeps the aggregate as a second, independent clause:
      # another repo's rails can only decide this repo's candidates once the AGGREGATE is reached.
      if candidate_deferred "$repo" $REPOS; then
        read -r _own _total _unk <<< "$(rails_for_repo "$repo" $REPOS)"
        log_line "$repo #$pr deferred ($_own rails on this repo + $_unk unattributed, $_total live in total, max=$MAX max_total=$MAX_TOTAL)"; continue
      fi
      # ⛔ A FAILED HEAD READ IS NOT AN EMPTY HEAD. `gh` failing here used to write the cooldown key
      # with an EMPTY head, which no later pass's real head can ever match — so the same PR was railed
      # again every interval, each launch taking a MAX slot from the candidates this actuator exists to
      # serve. Skip the candidate instead, and say so.
      head=$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null) \
        || { log_line "$repo #$pr HEAD-READ-FAILED: gh rc=$? — skipping this candidate (a cooldown keyed to an empty head would re-rail it every pass)"; continue; }
      [ -n "$head" ] || { log_line "$repo #$pr HEAD-READ-FAILED: gh returned an empty head — skipping this candidate"; continue; }
      now=$(date +%s)
      if grep -q "^$pr[[:space:]]$head[[:space:]]" "$TRIED" 2>/dev/null; then
        ts=$(grep "^$pr[[:space:]]$head[[:space:]]" "$TRIED" | tail -1 | awk '{print $3}')
        age=$(( now - ${ts:-0} ))
        # The rail writes its verdict into rails/auto-<owner>-<repo>-<pr>.out. Read it and decide which
        # cooldown applies: only CONFLICTED / DRAFT are answers that a new head is required to change.
        _out="$HOME/.pi/agent/state/rails/auto-$(printf '%s' "$repo" | tr '/' '-')-$pr.out"
        _cool="$COOLDOWN_S"
        if [ -f "$_out" ] && ! grep -qiE 'CONFLICTED|is a DRAFT|DENIED' "$_out" 2>/dev/null; then
          _cool="$COOLDOWN_TRANSIENT_S"
        fi
        if [ "$age" -lt "$_cool" ]; then
          if [ "$_cool" = "$COOLDOWN_TRANSIENT_S" ]; then
            log_line "$repo #$pr skipped — railed $(( age / 60 ))m ago on a verdict that CAN change without a new head; retry in $(( (_cool - age) / 60 ))m"
          else
            log_line "$repo #$pr skipped — this head ($head) was already railed $(( age / 60 ))m ago on a verdict that only a NEW HEAD can change"
          fi
          continue
        fi
      fi
      # ⛔ THE LEDGER RECORDS AN ATTEMPT, NOT A SUCCESS, AND THAT IS DELIBERATE. Recording after a verified
      # start was proposed in review and rejected: `nohup … &` forks and the rail may refuse in seconds, so
      # "the process is gone" is exactly the case the cooldown exists for — moving the write after it would
      # re-rail every fast refusal every pass. What must not happen is a launch that never STARTED, and that
      # is prevented by the precondition checks at startup (rail script present, `$RAIL_DIR` writable,
      # `$TRIED` writable), not by this ordering.
      echo "$pr	$head	$now" >> "$TRIED"
      log_line "$repo #$pr GREEN+terminal -> launching rail (head $head)"
      # ⛔ agent-infra SPLITS ITS LANES BY TRIGGER (agent-infra #1257): `ci.yml` is pull_request-only and
      # `ci-main.yml` is push:[main]-only, so no single `--workflow` spans both sides and the rail's own
      # BLOCK line tells the operator to add `--any-workflow`. Without it every agent-infra launch from here
      # would burn a MAX slot and refuse — an actuator that fires and cannot land. This does NOT bypass a
      # check: `--any-workflow` widens the MAIN baseline (compare against every lane on main), it does not
      # skip the comparison.
      extra=""
      [ "$repo" = "daniel-ospina/agent-infra" ] && extra="--any-workflow"
      # ⛔ THE RAIL IS INVOKED DIRECTLY. It used to go through /tmp/jobs2/rail-parallel.sh, which no longer
      # exists; a missing wrapper is a failed launch that the log recorded as a launch. The output now goes
      # to the durable rails/ dir so the next reader can see what the rail actually decided.
      RAIL_SCRIPT="$RAIL_SCRIPT" nohup bash "$RAIL_SCRIPT" "$pr" --repo "$repo" $extra \
        > "$RAIL_DIR/auto-$(echo "$repo"|tr / -)-$pr.out" 2>&1 &
      sleep 3
    done < /tmp/auto-rail-cand.$$
    rm -f /tmp/auto-rail-cand.$$
  done
  sleep "$INTERVAL"
done
