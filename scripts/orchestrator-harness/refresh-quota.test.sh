#!/usr/bin/env bash
# refresh-quota.test.sh — the regression contract for the CORE-QUOTA BURN of the refresh pass.
#
# THE DEFECT (measured 2026-10-18 on the live Mac). Consecutive `[refresh]` lines in
# `~/orchestrator/logs/orch-loop.log` report the REST core budget after each pass:
#
#     REST core remaining=4459 -> 3659 -> 3054 -> 2389 -> 1784 -> 1124 -> 327 -> 0
#
# ~670 core calls per pass against a 5000/hour account budget, so the box exhausted the whole bucket
# in ~7 passes. Every later pass judged 6 candidates against a rate-limited API, all 6 came back
# INCOMPLETE/DEGRADED, `judged 6 / usable 0` aborted (CORRECTLY — #1736) and the fleet dispatched
# nothing for the rest of the hour. The refusal was right; the BURN was the defect.
#
# WHERE IT WENT (counting shim, one real pass, per surface — 6 candidates):
#     fleet-board rebuild, per candidate (`issue list --limit 2000` + `pr list --limit 400`) .. 130
#     priority-tier + reaper listings (`rest_list` pages) .................................... 39
#     pre-flight `issue landed` timeline (`gh api --paginate --slurp`) ....................... 16
#     everything else (issue view, open PRs, closed-PR sample, identity, issue-claim reads) ... ~40
# The board rebuild was 47% of the pass, and it was 6x the SAME board because the pass-scoped cache
# the refresh thought it had enabled was never enabled: it exported `COLLISION_PREFLIGHT_CACHE`, and
# the tool's seam is `COLLISION_PREFLIGHT_BOARD_CACHE`. (The old name is not merely ignored — it is
# the name tortoise's own tests plant a FORGED board under, to prove the gate refuses a caller-named
# cache directory.)
#
# WHAT THESE CHECKS DRIVE. The SHIPPED `refresh-candidates.sh` — never a re-implementation — against a
# sandbox whose `gh` is a stub and whose pre-flight is a stub, so no network, no credentials, no real
# budget is touched. The stub `gh` CHARGES the modeled core cost of every call (a listing page = 1;
# `rate_limit` = 0, it is exempt from the budget) and the pre-flight stub charges the MEASURED board
# rebuild — 20 core calls — unless the pass-scoped cache is enabled, in which case the first
# invocation pays it and the rest hit the cache (1 call). That is the regression: on the pre-fix
# script `COLLISION_PREFLIGHT_BOARD_CACHE` is never `1`, so all six invocations pay 20 and the pass
# spends 125 modeled calls, reddening the ceiling below.
#
# Run:  bash scripts/orchestrator-harness/refresh-quota.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-candidates.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
# shell_valid <path> — a stub this suite GENERATES must be NON-EMPTY and must PARSE, and if it is not
# the suite must say so BY NAME, instead of leaving an opaque `line 1: syntax error` from an unnamed
# temp file that tells a reader nothing about which assertion never ran.
# ⛔ WHAT IT DOES NOT CATCH: `mk_gh`'s body is built with an INTERPOLATING heredoc (a backslash before
# every dollar, so nothing expands), and
# the measured failure of that construction is a stub that still PARSES while serving empty bodies —
# `bash -n` returns 0 and the suite reddens on the assertions. `bash -n` proves a program parses and
# nothing more; the interpolation class is defended by keeping those escapes right, not by this guard.
# Keep the GUARD identical to the one in `refresh-spend.test.sh` — the two suites drive the same
# shipped pass, so what counts as a runnable stub must not diverge. The ABORT line and the summary
# shape below are deliberately each file's OWN (`❌`/`  N passed, M failed` here, `FAIL`/`refresh-spend:`
# there): an abort must be formatted like the run it interrupted, not like its sibling's.
shell_valid() { # <path>
  local err
  if [ ! -s "$1" ]; then
    bad "generated stub is EMPTY: $1"
  elif ! err="$(bash -n "$1" 2>&1)"; then
    # `bash -n` prefixes EVERY line with the path it was given; drop the FIRST prefix so the header names
    # the file (later lines keep their own prefix — that is bash's context line, and it is useful).
    bad "generated stub is not valid shell: $1: ${err#*: }"
  else
    return 0
  fi
  # Say the suite STOPPED, in this file's own summary shape: a bare `0 passed, 1 failed` is
  # indistinguishable from an ordinary one-assertion red and hides that the rest never ran.
  echo "ABORT: refresh-quota stops here — every assertion after this point never ran (a generated stub could not run)"
  printf '  %d passed, %d failed (ABORTED, not a complete run)\n' "$PASS" "$FAIL"
  exit 1
}
T="$(mktemp -d "${TMPDIR:-/tmp}/refresh-quota.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> refresh-candidates core-quota contract ($HERE)"

[ -f "$REFRESH" ] || { echo "  ❌ missing $REFRESH"; exit 1; }

# THE CEILING, derived from the measurement rather than rounded to taste. One pass, 6 candidates:
#   listings (5 REST pages in this fixture) + ONE board rebuild (measured 24-30 core calls, charged
#   here as 20) + 5 cached candidates (1 each) = ~30. The pre-fix pass pays the rebuild SIX times
#   (~125 here, 130 measured live). 40 is the ceiling: it leaves room for the fixture's variance and
#   still reds ANY regression that rebuilds the board more than once per pass.
CORE_CEILING=40
BOARD_COST=20        # modeled per-rebuild cost, from the measured 130/6 = 21.7 calls per rebuild
CACHED_COST=1        # a cache hit costs no board read

# mk_case <name> — sandbox: a REAL git repo (with a real local origin) whose scout worktree ALREADY
# EXISTS as a plain dir (the shipped script then never runs `git worktree add`), a sandbox HOME, and $O.
# ⛔ THE REPO MUST BE PROVISIONABLE (agent-infra#1935 review, P1). `resolve_repo` verifies an EXPLICIT
# $REPO too: it reads `git -C $REPO config --get remote.origin.url` and REFUSES (exit 3, before the
# pool is even read) a checkout that cannot prove which repo it is — "cannot prove" is never "proved",
# because pre-flighting one repo's issues against another repo's tree is #1901. A `mkdir -p` fixture
# therefore reds EVERY arm of this suite at the run path. The origin is a bare dir INSIDE the sandbox:
# real git semantics (rev-parse, config) and no network. `rf` also clears $OR (see there), so the
# local-path origin takes the documented OR_DECLARED=0 tolerance instead of needing a URL to match.
D=""
mk_case() {
  D="$T/$1"; mkdir -p "$D/home" "$D/bin" "$D/o" "$D/repo/.worktrees/dispatch-scout/tools"
  git init -q --bare "$D/origin.git"
  git init -q "$D/repo"
  git -C "$D/repo" remote add origin "$D/origin.git"
  printf '%s' "${2:-100}" > "$D/core"          # the scripted REST core budget
  # ⛔ THE FIXTURE PROVISIONS THE CROSS-BOX CLAIM REGISTRY, because the shipped pass now REQUIRES it
  # (agent-infra#2466 / #2534). A missing `$O/claims.sh` is `INCOMPLETE — never CLEAN`, so every
  # candidate is unjudged and the pass ABORTS rc=1 — which reddens exactly the assertions below that
  # check a pass DID work (`budget`, `starved`, `no-probe`): measured on #2534's head, 6 failures, all
  # in those three cases. The stub answers "no claim" and issues no `gh` call, so CORE_CEILING still
  # measures the board rebuild, which is what this shard is about. NOT the shipped `$HERE/claims.sh`: this fixture's repo
  # is a plain directory with no origin, so the real `claim_issue_preflight` would have no refs to read
  # and would answer INCOMPLETE — the same abort from the other side. (The sibling `refresh-scout.test.sh`
  # runs the SHIPPED registry because its fixture builds a real bare origin; #2534 uses this same
  # one-line stub in the one case there that needs a reader answering CLEAN.) The missing-registry
  # polarity itself is pinned by `refresh-scout.test.sh` case (c), not here.
  printf 'claim_issue_preflight() { return 0; }\n' > "$D/o/claims.sh"
}

# mk_gh <case-dir> <rows> [rate-body] — the `gh` stub. Answers the REST listings the shipped script
# asks for, wrapped in the header block `gh api -i` really produces (the helper reads `Link` and the
# status line), and CHARGES the scripted budget for every page it serves. `rate-body` overrides the
# `api rate_limit` payload (case 5 serves one WITHOUT the core field: an answer that is not a
# measurement).
# mk_gh <case-dir> <rows> [rate-body] [open-rows] — the `gh` stub. Answers the REST listings the
# shipped script asks for, wrapped in the header block `gh api -i` really produces (the helper reads
# `Link` and the status line), and CHARGES the scripted budget for every page it serves. `rate-body`
# overrides the `api rate_limit` payload (case 5 serves one WITHOUT the core field: an answer that is
# not a measurement). ⛔ `open-rows` is the UNLABELLED `state=open&limit=500` window the reaper reads
# into `.open_iss` — a different question from the label-filtered tier listings, so it gets its own
# seam: with it defaulted, a fixture that seeds a `dispatched.txt` entry could never show it being
# PRUNED (the reaper would see an empty open set and keep every entry), and the prune assertions in
# case 4 would pass by vacuity rather than by the reaper running.
mk_gh() {
  local d="$1" rows="$2" rate_body="${3:-}" open_rows="${4:-[]}"
  cat > "$d/bin/gh.body" <<SH
#!/bin/bash
charge() {  # <cost> — spend from the scripted budget (never below 0)
  local c="\$(cat "$d/core")"; c=\$(( c - \$1 )); [ "\$c" -lt 0 ] && c=0; printf '%s' "\$c" > "$d/core"
}
case "\$*" in
  "auth token") exit 0 ;;
  "api rate_limit")
    if [ -n "$rate_body" ]; then printf '%s\n' "$rate_body"
    else printf '{"resources":{"core":{"remaining":%s},"graphql":{"remaining":4990}}}\n' "\$(cat "$d/core")"; fi ;;
  *"/pulls?"*) charge 1; printf '[]\n' ;;
  *"labels=P0-blocker"*) charge 1; printf '%s\n' '$rows' ;;
  *"/issues?"*) charge 1; printf '%s\n' '$open_rows' ;;
  *) printf '[]\n' ;;
esac
SH
  chmod +x "$d/bin/gh.body"
  shell_valid "$d/bin/gh.body"
  # The `-i` framing: headers + body, so `rest_list` can parse the status and the Link header.
  cat > "$d/bin/gh" <<'SH'
#!/bin/bash
d="$(cd "$(dirname "$0")" && pwd)"
if [ "$1" = api ] && [ "$2" = -i ]; then
  shift 2
  printf '%s\n' "$*" >> "$d/gh.argv"
  out="$("$d/gh.body" api "$@" 2>"$d/.gh.err")"; rc=$?
  [ -s "$d/.gh.err" ] && cat "$d/.gh.err" >&2
  rm -f "$d/.gh.err"
  [ "$rc" -eq 0 ] || exit "$rc"
  printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n%s\n' "$out"
  exit 0
fi
exec "$d/gh.body" "$@"
SH
  chmod +x "$d/bin/gh"
  shell_valid "$d/bin/gh"
}

# mk_gh_sat <case-dir> — a `gh` stub whose TIER listings answer a FULL page (100 rows) with a
# `link: … rel="next"` header, so `rest_list` ends the window FULL with more still advertised and sets
# `REST_WINDOW_FILLED=1` — the exact condition the `.pool-sat` writer records.
# ⛔ EVERY ROW CARRIES AN ASSIGNEE, so the shared `POOL_JQ` drops all of them: the POOL stays empty (the
# reorder is not what §7 grades) while the WINDOW is genuinely truncated. The URL decides whether the
# Link header is sent — only `labels=` listings are tiers; `/issues?` keeps its no-Link shape so the
# reaper's `.open_iss` read is not turned into a spurious "0 rows but a next page" refusal.
# ⛔ The bodies are DELIBERATELY quoted heredocs (`<<'SH'`) and derive `d` from `$0`, so nothing is
# interpolated: this file's own header warns that an interpolating heredoc can serve empty bodies while
# still parsing. §7 grades a WRITER, so a stub bug must redden an assertion, never silently write nothing.
mk_gh_sat() {
  local d="$1"
  cat > "$d/bin/gh.body" <<'SH'
#!/bin/bash
# ⛔ THE CASE DIR IS THE PARENT OF bin/ (the wrapper in bin/ sets ITS `d` to bin/). Deriving it as
# `dirname "$0"` here pointed `core` at bin/core: the budget then read 0 and the pass refused
# "remaining=0 cannot buy one candidate", which reddened the positive case for a fixture reason.
d="$(cd "$(dirname "$0")/.." && pwd)"
charge() { local c; c="$(cat "$d/core")"; c=$(( c - $1 )); [ "$c" -lt 0 ] && c=0; printf '%s' "$c" > "$d/core"; }
rows_page() {  # 100 ASSIGNED rows: POOL_JQ drops every one, so only the WINDOW is exercised
  local i out="["
  for i in $(seq 1 100); do
    [ "$i" -gt 1 ] && out="$out,"
    out="$out{\"number\":$((500+i)),\"title\":\"assigned $i\",\"assignees\":[{\"login\":\"someone\"}]}"
  done
  printf '%s]' "$out"
}
case "$*" in
  "auth token") exit 0 ;;
  "api rate_limit") printf '{"resources":{"core":{"remaining":%s},"graphql":{"remaining":4990}}}\n' "$(cat "$d/core")" ;;
  *"labels=P0-blocker"*|*"labels=P1-severe"*|*"labels=P2-moderate"*) charge 1; rows_page ;;
  *"/pulls?"*) charge 1; printf '[]\n' ;;
  *"/issues?"*) charge 1; printf '[]\n' ;;
  *) printf '[]\n' ;;
esac
SH
  chmod +x "$d/bin/gh.body"
  shell_valid "$d/bin/gh.body"
  cat > "$d/bin/gh" <<'SH'
#!/bin/bash
d="$(cd "$(dirname "$0")" && pwd)"
if [ "$1" = api ] && [ "$2" = -i ]; then
  shift 2
  printf '%s\n' "$*" >> "$d/gh.argv"
  out="$("$d/gh.body" api "$@" 2>"$d/.gh.err")"; rc=$?
  [ -s "$d/.gh.err" ] && cat "$d/.gh.err" >&2
  rm -f "$d/.gh.err"
  [ "$rc" -eq 0 ] || exit "$rc"
  # The `-i` framing, with a `Link` header on TIER listings ONLY (a tier is the query that carries
  # `labels=`). Emitted by separate printf calls so the escapes are the FORMAT's, not -v's.
  printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n'
  case "$*" in *labels=*) printf 'link: <https://api.github.com/x?page=2>; rel="next"\r\n' ;; esac
  printf '\r\n%s\n' "$out"
  exit 0
fi
exec "$d/gh.body" "$@"
SH
  chmod +x "$d/bin/gh"
  shell_valid "$d/bin/gh"
}

# mk_tool <path> — the pre-flight stand-in. Charges the MODELED board rebuild unless the pass-scoped
# cache is enabled (then only the first invocation pays), records the cache seam it was handed, and
# answers CLEAN so a queued candidate is observable.
mk_tool() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'PY'
import os, sys
d = os.environ["QUOTA_CASE"]
core_p, n_p = os.path.join(d, "core"), os.path.join(d, "preflight-count")
n = int(open(n_p).read()) if os.path.exists(n_p) else 0
open(n_p, "w").write(str(n + 1))
with open(os.path.join(d, "preflight-env.log"), "a") as fh:
    fh.write("%s|%s\n" % (os.environ.get("COLLISION_PREFLIGHT_BOARD_CACHE", "<unset>"),
                          os.environ.get("COLLISION_PREFLIGHT_BOARD_CACHE_TTL", "<unset>")))
    fh.write("legacy|%s\n" % os.environ.get("COLLISION_PREFLIGHT_CACHE", "<unset>"))
cache_on = os.environ.get("COLLISION_PREFLIGHT_BOARD_CACHE") == "1"
cost = 20 if (not cache_on or n == 0) else 1
c = max(0, int(open(core_p).read()) - cost)
open(core_p, "w").write(str(c))
print("VERDICT: CLEAN")
PY
  chmod +x "$1"
}

# rf <dir> <refresh|check> [KEY=VAL ...] — runs the SHIPPED script hermetically; $OUT/$RC.
# The quota seams are CLEARED every run so a case's own values are the only ones in play and an
# operator's exports cannot leak into the sandbox (the same rule the scout suite states for its own
# ambient knobs). ⛔ $OR IS CLEARED TOO (#1935 review, P1): `OR_DECLARED` is 1 whenever the caller's
# environment names a queue target, and a DECLARED target makes the fixture's local-path origin a
# REFUSAL (it cannot prove a declared pair) — so on any box that exports $OR this suite would red for
# a reason that has nothing to do with the quota contract. Cleared, the fixture runs in the documented
# OR_DECLARED=0 state and the origin tolerance is the branch under test.
OUT=""; RC=0
rf() {
  local dir="$1" mode="$2"; shift 2
  local args=(6); [ "$mode" = check ] && args=(--check)
  OUT="$(env -u TORTOISE_REPO -u TORTOISE -u SCOUT_UV -u GH_HOST -u CELL_HOME -u SCOUT_PY \
          -u SCOUT_UV_EXTRAS -u GH_CONFIG_DIR -u OR \
          -u COLLISION_PREFLIGHT_BOARD_CACHE -u COLLISION_PREFLIGHT_BOARD_CACHE_TTL \
          -u COLLISION_PREFLIGHT_CACHE -u COLLISION_PREFLIGHT_CORE_RESERVE \
          -u COLLISION_PREFLIGHT_CORE_PER_CANDIDATE -u COLLISION_PREFLIGHT_CORE_PACING \
          HOME="$dir/home" PATH="$dir/bin:$PATH" REPO="$dir/repo" O="$dir/o" \
          QUOTA_CASE="$dir" "$@" \
          bash "$REFRESH" "${args[@]}" 2>&1)"
  RC=$?
}
# rows <n> — n unassigned, non-epic P0-blocker rows (the pool the pass judges).
rows() {
  local i out="["
  for i in $(seq 1 "$1"); do
    [ "$i" -gt 1 ] && out="$out,"
    out="$out{\"number\":$((40+i)),\"title\":\"candidate $i\",\"assignees\":[]}"
  done
  printf '%s]' "$out"
}

# ── 1) THE BUDGET: a 6-candidate pass must not exceed CORE_CEILING ─────────────────────────────
# This is the burn's own regression. It reds on any change that starts paying the board rebuild per
# candidate again — including "unsetting" the cache seam, which is exactly the pre-fix state.
mk_case budget 1000
mk_gh "$D" "$(rows 6)"
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh
spent=$(( 1000 - $(cat "$D/core") ))
judged="$(printf '%s\n' "$OUT" | grep -oE 'checked [0-9]+' | head -1)"
[ "$RC" -eq 0 ] && ok "budget: a full pass succeeds (rc=0) — $judged" \
                || bad "budget: rc=$RC (want 0) — output: $OUT"
[ "$spent" -le "$CORE_CEILING" ] \
  && ok "budget: the pass spent $spent core calls (ceiling $CORE_CEILING) — one board rebuild, not one per candidate" \
  || bad "budget: the pass spent $spent core calls, OVER the $CORE_CEILING ceiling — the board is being rebuilt per candidate (pre-fix: 125)"
[ "$spent" -gt 0 ] && ok "budget: the spend is MEASURED, not zero (the fixture really charges: $spent)" \
                   || bad "budget: the stub charged nothing — the check above would pass on any script"
# The board rebuild happens ONCE: 6 pre-flight invocations, exactly one at the full modeled cost.
[ "$(cat "$D/preflight-count" 2>/dev/null)" = "6" ] \
  && ok "budget: all 6 candidates were judged (one pre-flight run each)" \
  || bad "budget: the pre-flight ran $(cat "$D/preflight-count" 2>/dev/null) times (want 6)"

# ── 2) THE SEAM: the pass-scoped board cache is the TOOL'S name, and the legacy one is gone ─────
# The defect was two names that differ by one word. A suite that only measured the spend could pass
# on a future tool whose cache is enabled some other way; this pins the CONTRACT the harness hands
# the tool. `COLLISION_PREFLIGHT_CACHE` must NOT be exported: it is the caller-named cache directory
# tortoise's own tests plant a forged board under, and exporting it into every daemon process named an
# untrusted path on the whole fleet.
seam="$(head -1 "$D/preflight-env.log" 2>/dev/null)"
[ "$seam" = "1|300" ] && ok "seam: the pre-flight is handed COLLISION_PREFLIGHT_BOARD_CACHE=1 / TTL=300" \
                     || bad "seam: the pre-flight got '$seam' (want '1|300') — the pass-scoped board cache is NOT enabled"
grep -qx 'legacy|<unset>' "$D/preflight-env.log" 2>/dev/null \
  && ok "seam: COLLISION_PREFLIGHT_CACHE (the tool's caller-named-cache attack seam) is NOT exported" \
  || bad "seam: COLLISION_PREFLIGHT_CACHE is exported — that is the name the tool refuses, and a caller-named board directory is a caller-named BOARD"
# Turning the cache off must be LOUD in the spend, not silent: if an operator sets 0 the pass is
# allowed to cost more, but the fixture then proves the seam is doing the work the ceiling credits.
mk_case cache-off 1000
mk_gh "$D" "$(rows 6)"
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh COLLISION_PREFLIGHT_BOARD_CACHE=0
spent_off=$(( 1000 - $(cat "$D/core") ))
[ "$spent_off" -gt "$CORE_CEILING" ] \
  && ok "seam: with the cache explicitly OFF the pass spends $spent_off (> $CORE_CEILING) — the ceiling above measures the cache, not the fixture" \
  || bad "seam: cache OFF still spent only $spent_off — the ceiling would pass without the cache"

# ── 3) A STARVED PASS JUDGES FEWER CANDIDATES — AND STILL PRODUCES USABLE VERDICTS ──────────────
# The live failure shape: 6 candidates judged, 0 usable, ABORT, nothing dispatched for the rest of the
# hour. A pass that can only afford SOME of its window must judge those completely (a CLEAN is queued,
# a COLLISION is acted on) and STOP, naming the budget — never spend the last of the bucket and report
# `judged NOTHING`.
# Budget 80, reserve 40, and the PER-CANDIDATE estimate PINNED at 30. The stub pre-flight spends
# ~2 core calls per candidate and the listings cost ~5, so with the SHIPPED default (6, re-derived
# from measurement by #1984 — the pass now also reads the fleet's slow-changing answers once per
# pass) nothing this fixture can afford would ever starve: 80 - 5 - 6*2 stays above 40 + 6. That is
# the default's VALUE, not this case's subject. This case is about the STARVATION MECHANISM — a pass
# that cannot afford its whole window must stop and say so — so the seam is pinned to the estimate
# the arithmetic was designed around (30) and the budget is sized for THAT: gate 80 >= 40 + 30,
# listings leave ~75, each judged candidate leaves ~2 less, and the pass stops at ~70 = 40 + 30
# having judged 2-3 of 6. Non-vacuity: unpinning it reddens `judged N (want 1..5)` here, which is how
# this comment was verified after the merge.
mk_case starved 80
mk_gh "$D" "$(rows 6)"
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh COLLISION_PREFLIGHT_CORE_RESERVE=40 COLLISION_PREFLIGHT_CORE_PER_CANDIDATE=30
n_judged="$(printf '%s\n' "$OUT" | sed -nE 's/.*checked ([0-9]+); backlog now.*/\1/p' | head -1)"
n_usable="$(printf '%s\n' "$OUT" | grep -cE '^\[refresh\] \+#[0-9]+ CLEAN -> backlog')"
n_cand="$(wc -l < "$D/o/candidates.txt" 2>/dev/null | tr -d ' ')"
remaining="$(cat "$D/core")"
[ "$RC" -eq 0 ] && ok "starved: the pass SUCCEEDS (rc=0) instead of aborting the whole pass" \
                || bad "starved: rc=$RC (want 0) — output: $OUT"
case "${n_judged:-x}" in
  ''|*[!0-9]*) bad "starved: could not read a 'checked N' line — output: $OUT" ;;
  *) [ "$n_judged" -ge 1 ] && [ "$n_judged" -lt 6 ] \
       && ok "starved: judged $n_judged of the 6 slot(s) — FEWER candidates, same completeness" \
       || bad "starved: judged $n_judged (want 1..5) — the budget floor was not applied" ;;
esac
[ "${n_usable:-0}" -ge 1 ] && ok "starved: $n_usable usable verdict(s) produced — this pass queues work" \
                           || bad "starved: 0 usable verdicts — the #1736 abort shape is back (output: $OUT)"
[ "${n_cand:-0}" -ge 1 ] && ok "starved: candidates.txt has $n_cand line(s) — the backlog is NOT empty" \
                         || bad "starved: candidates.txt is EMPTY over a non-empty pool"
case "$OUT" in
  *"budget starved:"*) ok "starved: the stop is NAMED (a starved pass never reads as a quiet queue)" ;;
  *) bad "starved: no 'budget starved:' line — output: $OUT" ;;
esac
[ "$remaining" -ge 40 ] && ok "starved: stopped with $remaining remaining (reserve 40 intact)" \
                        || bad "starved: spent through the reserve ($remaining left, want >= 40)"

# ── 4) NO AFFORDABLE CANDIDATE: a NAMED refusal, never a false empty backlog — AND THE REAPER STILL
#      RUNS (review finding #8) ────────────────────────────────────────────────────────────────
# `judged 0` is deliberately outside the `usable -eq 0` assertion (that one requires `judged > 0`), so
# without an explicit arm a budget-starved pass would print `checked 0; backlog now 0` at rc 0 — the
# #1736 false report arriving through the budget door.
# ⛔ BUT THE REFUSAL IS DELIBERATELY **NOT** THE FIRST THING THE PASS DOES (review finding #8, P1). It
# used to sit at the top, above the `dispatched.txt` reaper, and “zero calls spent” was its stated
# virtue — which is exactly backwards: the reaper is the ONLY thing that un-blacklists a dispatched
# issue that is still OPEN, has NO PR, and has no live lane (the file's own note above the reaper says
# so), and a starved box therefore stopped pruning precisely when it was too poor to do anything else.
# The re-dispatched-when-free class stayed blacklisted until the bucket recovered on its own.
# So this case now asserts the OPPOSITE of the old assertion, and it asserts the CONSEQUENCE rather
# than the call count: `#41` is seeded into `dispatched.txt` + `checked.txt`, gh reports it as still
# open with no PR branch, and the starved pass must have PRUNED it. The spend is bounded, not zero —
# the reaper's two listings are the price, and the expensive half (the priority-tier listings, ~40) is
# pinned by "no `.pool`" below.
mk_case unaffordable 20
mk_gh "$D" "$(rows 6)" "" "$(rows 6)"   # .open_iss = issues 41..46, .pr_brs = no branches
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
# A `tmux` stub, so "no live lane" is a fact of the fixture rather than of the host: the reaper asks
# `tmux ls` for `lane-<issue>` sessions, and an ambient session on a real box would keep the entry.
printf '#!/bin/bash\nexit 0\n' > "$D/bin/tmux"; chmod +x "$D/bin/tmux"
printf '41\n' > "$D/o/dispatched.txt"
printf '41\n' > "$D/o/checked.txt"
rf "$D" refresh COLLISION_PREFLIGHT_CORE_RESERVE=40
spent_dry=$(( 20 - $(cat "$D/core") ))
[ "$RC" -eq 1 ] && ok "unaffordable: refuses TRANSIENTLY (rc=1, retried next cycle) rather than exiting 0" \
                || bad "unaffordable: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"ABORT: REST core budget"*) ok "unaffordable: the refusal NAMES the budget as the cause" ;;
  *) bad "unaffordable: the refusal does not name the budget — output: $OUT" ;;
esac
case "$OUT" in
  *"backlog now"*) bad "unaffordable: printed a backlog count for a pass that judged nothing — the #1736 false report" ;;
  *) ok "unaffordable: no 'backlog now' line — an unjudged pool is never reported as an empty one" ;;
esac
# ⛔ FINDING #8's PROPERTY, asserted on the ARTIFACT rather than on the log: a starved pass still prunes
# a blacklisted issue that is open, has no PR and no live lane. Non-vacuity is the SEED (the entry is
# there before the pass and the fixture proves the reaper can see it: gh lists #41 as open).
case "$(tr '\n' ' ' < "$D/o/dispatched.txt" 2>/dev/null)" in
  *41*) bad "unaffordable: #41 is STILL in dispatched.txt — a starved pass did not prune the blacklist (the reaper now runs below the budget gate, so it must have)" ;;
  *) ok "unaffordable: the starved pass STILL PRUNED #41 from dispatched.txt (open, no PR, no lane) — the reaper is not skipped when the box is broke" ;;
esac
case "$(tr '\n' ' ' < "$D/o/checked.txt" 2>/dev/null)" in
  *41*) bad "unaffordable: #41 is still in checked.txt — the prune did not clear the blacklist entry it un-blacklisted" ;;
  *) ok "unaffordable: the prune cleared #41 from checked.txt as well (un-blacklisted, not half-cleared)" ;;
esac
[ ! -e "$D/o/.pool" ] && ok "unaffordable: the priority-tier listings did NOT run (no .pool) — the refusal still precedes the ~40-call half" \
                       || bad "unaffordable: .pool exists — the priority listings ran for a pass that then refused"
# The reaper's two listings are the ONLY permitted spend. Bounded, and proven non-zero by the prune
# above (a reaper that never listed cannot have un-blacklisted anything).
[ "$spent_dry" -le 4 ] && ok "unaffordable: refused after $spent_dry core call(s) — the reaper's two listings only, not the ~40 the pool listing costs" \
                       || bad "unaffordable: spent $spent_dry core calls before refusing — more than the reaper's two listings, so something else ran"

# ── 5) AN UNREADABLE BUDGET DOES NOT STARVE (a metric outage is not a dispatch outage) ──────────
# If the probe cannot answer, the pass must proceed on the pre-flight's own fail-closed rules — never
# treat "unknown" as 0. Driven by a gh that answers the listings but not `rate_limit`.
# ⛔ NOT a FAILING `rate_limit`: the gh precondition (`gh_probe_env`) validates the credential with that
# same call and refuses TRANSIENT when it does not answer — so a failing probe would test THAT gate,
# not this one. The realistic shape of an unreadable budget is a body that answers HTTP 200 without
# the field (a partial `rate_limit` payload), which is what this fixture serves.
mk_case no-probe
mk_gh "$D" "$(rows 6)" '{}'
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh COLLISION_PREFLIGHT_CORE_RESERVE=4900
[ "$RC" -eq 0 ] && ok "no-probe: an UNREADABLE budget does not refuse the pass (rc=0)" \
                || bad "no-probe: rc=$RC (want 0) — an unanswerable metric must not stop dispatch — output: $OUT"
case "$OUT" in
  *"could not be read"*) ok "no-probe: the unreadable budget is REPORTED, not silently assumed" ;;
  *) bad "no-probe: the unreadable budget is not reported — output: $OUT" ;;
esac

# ── 6) EVERY TIER WINDOW IS ASKED OLDEST-FIRST (agent-infra#2019, review cycle 1 P1) ───────────#
# ⛔ WHY THIS ARM EXISTS. The provider's default order is created-DESCENDING, so an unqualified
# `--limit N` keeps the NEWEST N. The pool ranks AGE-SECOND (oldest-first inside a tier) and, since
# #2019, the queue's ORDER is derived from `.pool` — so an unsorted window made the oldest queued
# members of an over-capacity tier read as "unranked" and pinned them to the TAIL on every pass,
# forever, while the pass still claimed `severity-first`. The tier IS over capacity in production
# (open `P2-moderate` 450 against the 200 bound, 2026-11-05), so this is the live shape, not a
# hypothetical. Asking oldest-first makes truncation lose the NEWEST members — the end the ranking
# does not need, and the one that makes the unranked TAIL the ordering `age-second` actually asks for.
# This pins the QUESTION the helper puts to the provider — a stub cannot emulate the provider's order,
# so pinning the returned rows would prove nothing. The complementary half — that pool-unranked rows
# land at the TAIL in queue order — is pinned in `rank-queue.test.sh`.
# ⛔ THIS ARM'S COMMENT PROSE TRIPPED A GUARD ONCE. A reviewer measured this file REFUSED before its
# first assertion with an unpaired parenthesis in the comment above, and 28/0 with it removed; on this
# box the refusal then outlived the removal and is keyed to this file's PATH rather than its bytes — the
# same bytes under another name run 28/0 (agent-infra#3528). Recorded here so the next lane does not
# read the refusal as this suite failing.
mk_case order-dir 1000   # the reserve is 300: a 100-call budget refuses before the pool is built
mk_gh "$D" "$(rows 6)"
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh
for _tier in P0-blocker P1-severe P2-moderate; do
  _url="$(grep -F "labels=$_tier" "$D/bin/gh.argv" 2>/dev/null | head -1)"
  if [ -z "$_url" ]; then
    bad "tier-order: no listing was made for $_tier at all (the assertion below would pass by vacuity)"
    continue
  fi
  case "$_url" in
    *"sort=created"*)  ok "tier-order: $_tier is asked with sort=created" ;;
    *) bad "tier-order: $_tier listing has no sort=created — the window keeps the NEWEST rows, the opposite end from the pool's oldest-first rank: $_url" ;;
  esac
  case "$_url" in
    *"direction=asc"*) ok "tier-order: $_tier is asked direction=asc (the window keeps the OLDEST, so truncation loses the newest)" ;;
    *) bad "tier-order: $_tier listing has no direction=asc — a truncated tier would lose its OLDEST members: $_url" ;;
  esac
done

# ── 7) A CLIPPED TIER WINDOW IS RECORDED BY THE WRITER, NOT ONLY READ BACK (review cycle 36, P2) ──
# ⛔ WHY THIS ARM EXISTS — MEASURED, NOT IMAGINED. The `.pool-sat` READER and its SANITISER are pinned in
# `rank-queue.test.sh` §14b/§14c, but those cases HAND-WRITE the fixture (`printf 'P1-severe\n' >
# …/.pool-sat`), so they grade the consumer. Deleting the three `>> "$O/.pool-sat"` lines from the SHIPPED
# tier block left `rank-queue` at 106/0 and this suite at 28/0 — i.e. the ONLY disclosure this change has
# for the cross-tier truncation residual (a clipped `P1` landing behind every ranked `P2`) could go inert
# without a single red, while the order line went on printing a clean `severity-first`. A signal whose
# producer is untested is a signal that can vanish quietly; that is this repo's "an enforcer whose red path
# has never been executed" class.
# This arm drives the shipped tier block: a FULL page with `rel="next"` is exactly `REST_WINDOW_FILLED=1`.
mk_case sat-writer 1000
mk_gh_sat "$D"
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh
# ⛔ ONE ASSERTION PER TIER, NOT ONE FOR THE SET (review cycle 37, P2 — MEASURED). Matching only
# `*P0-blocker*` left the OTHER TWO writer lines deletable-green: removing just the `P1-severe` line from
# the shipped script gave this suite 31 passed, 0 failed, and `rank-queue` stayed 106/0 (its §14b/§14c
# hand-write the fixture). `P2-moderate` is the tier this suite itself documents as over capacity in
# production (450 open against a 200 window), so an ungraded P2 line is the one that matters most.
# #3481's standard is one named mutant per new assertion; a single wildcard match cannot satisfy it.
SAT="$(tr '\n' ' ' < "$D/o/.pool-sat" 2>/dev/null || true)"
for _satt in P0-blocker P1-severe P2-moderate; do
  case "$SAT" in
    *"$_satt"*) ok "truncation-writer: $_satt is RECORDED in .pool-sat for a FULL window with a next page still advertised" ;;
    *) bad "truncation-writer: .pool-sat does NOT name $_satt (got '${SAT:-<absent>}') — that tier's writer line can be deleted green, so the windows=TRUNCATED() disclosure loses that tier silently" ;;
  esac
done
# ⛔ NON-VACUITY, PER WRITER LINE: delete ONE tier's writer from a copy of the SHIPPED script and the
# assertion for THAT tier must be the one that reddens. A single "delete all three" mutation cannot
# satisfy this — it deletes whatever remains, so a pre-deleted line just shrinks the deletion set and the
# mutant's record still comes out empty, which the old arm read as "the writer is what produces it".
for _satt in P0-blocker P1-severe P2-moderate; do
  mk_case "sat-writer-mut-$_satt" 1000
  mk_gh_sat "$D"
  mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
  MUT_SAT="$T/mut-sat-$_satt/refresh-candidates.sh"; mkdir -p "$T/mut-sat-$_satt"
  sed "s|\[ \"\${REST_WINDOW_FILLED:-0}\" = \"1\" \] && echo \"$_satt\" >> \"\\\$O/\\.pool-sat\"||" \
    "$REFRESH" > "$MUT_SAT"
  if cmp -s "$REFRESH" "$MUT_SAT" 2>/dev/null; then
    bad "truncation-writer: the $_satt writer-deletion mutation did not apply — the sed anchor drifted, so the non-vacuity check for that tier would pass by vacuity"
    continue
  fi
  REFRESH_SAVED="$REFRESH"
  REFRESH="$MUT_SAT"; rf "$D" refresh; REFRESH="$REFRESH_SAVED"
  MUT_SAT_REC="$(tr '\n' ' ' < "$D/o/.pool-sat" 2>/dev/null || true)"
  # ⛔ ABSENCE IS NOT EVIDENCE — AND THIS ARM HAD THE EXACT HOLE IT FIXES FOUR LINES BELOW (review cycle 38,
  # P2 — MEASURED). Asserting only "the mutated tier is absent" passed on a mutant that produced NOTHING:
  # replacing the `sed` above with `printf '#!/bin/bash\nexit 7\n' > "$MUT_SAT"` — a script that mutates
  # nothing and writes no `.pool-sat` — still gave 35 passed, 0 failed, with all three arms reporting
  # "deleting ONLY the X writer line removes X". A mutant that never ran is indistinguishable from a writer
  # that really was the producer, which is the one thing these arms exist to tell apart. So the mutant's pass
  # must COMPLETE and its record must still name the two tiers it did NOT mutate: the survivors are the
  # witness that a record was produced at all, and the third is the tier whose line was deleted.
  _satsurv=1
  [ "$RC" -eq 0 ] || { _satsurv=0; bad "truncation-writer: the $_satt mutant's pass did not complete (rc=$RC) — 'removes $_satt' would then hold on a pass that wrote nothing: $OUT"; }
  for _sat_other in P0-blocker P1-severe P2-moderate; do
    [ "$_sat_other" = "$_satt" ] && continue
    case "$MUT_SAT_REC" in
      *"$_sat_other"*) ;;
      *) _satsurv=0; bad "truncation-writer: deleting ONLY the $_satt writer line also dropped $_sat_other (got '${MUT_SAT_REC:-<absent>}') — the mutant produced nothing, so 'removes $_satt' would grade an empty file rather than the writer" ;;
    esac
  done
  case "$MUT_SAT_REC" in
    *"$_satt"*) bad "truncation-writer: with the $_satt writer DELETED the record still names it ('$MUT_SAT_REC') — the fixture, not that writer line, is producing it" ;;
    *) if [ "$_satsurv" -eq 1 ]; then ok "truncation-writer: deleting ONLY the $_satt writer line removes $_satt from .pool-sat while the other two tiers SURVIVE (each of the three writers is graded, not just the set)"; fi ;;
  esac
done
# And the NEGATIVE: an ordinary short listing (no full window, no next page) records NOTHING, so the
# clause cannot appear on the routine path where no tier was clipped.
# ⛔ AND THE ABSENCE IS GATED ON THE PASS HAVING ACTUALLY LISTED (review cycle 37, P2 — MEASURED). Asserting
# only "`.pool-sat` is absent" passed on a REFUSED pass: with the case budget dropped to 20 the pass refused
# at the core-reserve gate (`remaining=0 cannot buy one candidate`), made ZERO `labels=` listings, and the
# arm still reported "the clause is not emitted for a tier that fit" — absence of evidence read as evidence.
# §6 above already sets this precedent (`tier-order: no listing was made for $_tier at all (the assertion
# below would pass by vacuity)`); this arm had no equivalent.
mk_case sat-writer-none 1000
mk_gh "$D" "$(rows 2)"
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh
NEG_OK=1
[ "$RC" -eq 0 ] || { NEG_OK=0; bad "truncation-writer: the unsaturated case's pass did not complete (rc=$RC) — the absence assertion below would pass without a pass: $OUT"; }
if ! grep -q 'labels=' "$D/bin/gh.argv" 2>/dev/null; then
  NEG_OK=0; bad "truncation-writer: the unsaturated case made NO tier listing at all — 'no .pool-sat' would pass by vacuity rather than because the window fit"
fi
if [ "$NEG_OK" -eq 1 ]; then
  [ ! -s "$D/o/.pool-sat" ] && ok "truncation-writer: an UNSATURATED listing (tier listings made, pass complete) writes no .pool-sat (the clause is not emitted for a tier that fit)" \
                            || bad "truncation-writer: .pool-sat exists for an unsaturated listing ('$(tr '\n' ' ' < "$D/o/.pool-sat" 2>/dev/null)') — the signal would fire on every pass and stop meaning anything"
fi


# ⛔ AND THE RECORD IS PER-PASS, NOT ACCUMULATED (review P3, cycle 60). `.pool-sat` is only ever APPENDED to;
# the ONE thing that makes it describe THIS pass is the `rm -f … "$O/.pool-sat"` in the entry reset. Every
# case above runs in a FRESH `$D`, so none of them could see that term: dropping it left this suite, rank-queue,
# pool-filter and product-floor all green — and the next pass then discloses a clip from a read that reported
# none ("a tier window ended FULL with a next page still advertised" over a listing that fit), i.e. an alarm
# that cries wolf on every pass after any clip. Driven as the failure needs: TWO passes in ONE `$O`.
mk_case sat-writer-stale 1000
mk_gh_sat "$D"
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh
# ⛔ A FAILED REDIRECTION IS REPORTED BY THE SHELL, NOT BY `tr` (review P3, cycle 61): `cmd < missing 2>/dev/null`
# still prints `bash: <missing>: No such file or directory` on stderr — the shell reports the redirect before
# the command's own stderr is redirected. The read is braced, exactly as the shipped reader does it.
stale_first="$( { tr '\n' ' ' < "$D/o/.pool-sat"; } 2>/dev/null || true)"
mk_gh "$D" "$(rows 2)"        # THIS pass: a short listing, no full window, no next page
rf "$D" refresh
stale_second="$( { tr '\n' ' ' < "$D/o/.pool-sat"; } 2>/dev/null || true)"
if [ -z "$stale_first" ]; then
  bad "truncation-stale: the FIRST pass recorded nothing ('$stale_first') — the second-pass assertion below would pass by vacuity"
elif [ "$RC" -ne 0 ]; then
  bad "truncation-stale: the second pass did not succeed (rc=$RC) — output: $OUT"
elif [ -s "$D/o/.pool-sat" ]; then
  bad "truncation-stale: the SECOND pass (an unsaturated listing) still carries the first pass's clip ('$stale_second') — the record is not per-pass, so the order line would disclose a truncation this read never saw"
else
  ok "truncation-stale: a second pass over a SATURATED first pass records NO clip (the .pool-sat reset makes the record per-pass)"
fi
# ⛔ NON-VACUITY: delete `"$O/.pool-sat"` from the entry reset and the assertion above must go RED.
MUT_STALE="$T/mut-stale/refresh-candidates.sh"; mkdir -p "$T/mut-stale"
sed 's/^rm -f "\$O\/\.pool-err" "\$O\/\.pool-read" "\$O\/\.pool-sat"$/rm -f "$O\/.pool-err" "$O\/.pool-read"/' \
  "$REFRESH" > "$MUT_STALE"
# ⛔ THE GATE MEASURES THE TERM IT IS ABOUT (review P3, cycle 63). `cmp -s` cannot distinguish "the anchor
# drifted" from "the reset no longer carries `.pool-sat` at all" — and the second IS the regression this half
# exists to catch, so blaming the anchor sent the maintainer to the fixture instead of to the deleted term.
# Ask for the term first (the `_arm14_mut` precedent: a POSITIVE measurement, then the byte comparison).
# ⛔ FOUR STATES, FOUR TRUE SENTENCES — MEASURED, NOT GUESSED (review P3, cycles 63-64). Everything that named a
# cause here was wrong at least once: counting the term ANYWHERE read 4 shipped / 3 with the reset term deleted
# (`.pool-sat` also appears in the three WRITER lines), and anchoring on the first `^rm -f ... .pool-err` line
# handed back one of the OTHER reset lines — measured: with the entry reset DELETED the message quoted the
# partial-read reset (`rm -f "$O/.pool-err" "$O/.pool-read"`) as "its line", so the "not found" branch could
# never fire. Two counts settle it: HOW MANY unindented reset lines exist, and HOW MANY of them carry the term.
#   shipped          2 / 1  -> the term is present, the byte comparison below is meaningful
#   term removed     2 / 0  -> THE REGRESSION this half exists to catch
#   line deleted     1 / 0  -> the same regression class (the record is no longer reset per pass)
#   anchor drifted   0 / 0  -> the fixture's own anchor, and the only state that blames it
_stale_all="$(grep -cE '^rm -f "\$O/\.pool-err" "\$O/\.pool-read"' "$REFRESH" 2>/dev/null)"
_stale_sat="$(grep -cE '^rm -f "\$O/\.pool-err" "\$O/\.pool-read" "\$O/\.pool-sat"$' "$REFRESH" 2>/dev/null)"
if [ "${_stale_all:-0}" = "0" ]; then
  bad "truncation-stale: NO unindented 'rm -f \"\$O/.pool-err\" \"\$O/.pool-read\"' line exists — the fixture's anchor drifted (the script's reset lines changed shape), so this non-vacuity half grades nothing"
elif [ "${_stale_sat:-0}" = "0" ]; then
  bad "truncation-stale: none of the ${_stale_all} unindented reset line(s) carries .pool-sat (the shipped script has 2, one of them the entry reset) — the reset LOST its term, or the entry reset line is gone; either way the record is no longer per-pass, which IS the regression this half exists to catch"
elif cmp -s "$REFRESH" "$MUT_STALE" 2>/dev/null; then
  bad "truncation-stale: the reset-deletion mutation did not apply — the sed anchor drifted (the term IS present, so this half's own anchor is what to check), so this non-vacuity half grades nothing"
else
  D2="$T/sat-writer-stale-mut"; mkdir -p "$D2/home" "$D2/bin" "$D2/o" "$D2/repo/.worktrees/dispatch-scout/tools"
  git init -q --bare "$D2/origin.git"; git init -q "$D2/repo"; git -C "$D2/repo" remote add origin "$D2/origin.git"
  printf '1000' > "$D2/core"
  printf 'claim_issue_preflight() { return 0; }\n' > "$D2/o/claims.sh"
  mk_gh_sat "$D2"
  mk_tool "$D2/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
  REFRESH_SAVED2="$REFRESH"; REFRESH="$MUT_STALE"; rf "$D2" refresh; REFRESH="$REFRESH_SAVED2"
  mk_gh "$D2" "$(rows 2)"
  REFRESH_SAVED2="$REFRESH"; REFRESH="$MUT_STALE"; rf "$D2" refresh; REFRESH="$REFRESH_SAVED2"
  if [ -s "$D2/o/.pool-sat" ]; then
    ok "truncation-stale: with the .pool-sat reset DELETED the second pass still carries the clip ('$(tr '\n' ' ' < "$D2/o/.pool-sat" 2>/dev/null)') — the check above grades the RESET, not a fixture artifact"
  else
    bad "truncation-stale: with the .pool-sat reset deleted the clip did NOT persist — the check above is not grading the reset"
  fi
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
