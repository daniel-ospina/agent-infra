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

# mk_case <name> — sandbox: repo + a scout worktree that ALREADY EXISTS as a plain dir (the shipped
# script then never runs `git worktree add`, so no repo/remote is needed), a sandbox HOME, and $O.
D=""
mk_case() {
  D="$T/$1"; mkdir -p "$D/home" "$D/bin" "$D/o" "$D/repo/.worktrees/dispatch-scout/tools"
  printf '%s' "${2:-100}" > "$D/core"          # the scripted REST core budget
}

# mk_gh <case-dir> <rows> [rate-body] — the `gh` stub. Answers the REST listings the shipped script
# asks for, wrapped in the header block `gh api -i` really produces (the helper reads `Link` and the
# status line), and CHARGES the scripted budget for every page it serves. `rate-body` overrides the
# `api rate_limit` payload (case 5 serves one WITHOUT the core field: an answer that is not a
# measurement).
mk_gh() {
  local d="$1" rows="$2" rate_body="${3:-}"
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
  *"/issues?"*) charge 1; printf '[]\n' ;;
  *) printf '[]\n' ;;
esac
SH
  chmod +x "$d/bin/gh.body"
  # The `-i` framing: headers + body, so `rest_list` can parse the status and the Link header.
  cat > "$d/bin/gh" <<'SH'
#!/bin/bash
d="$(cd "$(dirname "$0")" && pwd)"
if [ "$1" = api ] && [ "$2" = -i ]; then
  shift 2
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
# ambient knobs).
OUT=""; RC=0
rf() {
  local dir="$1" mode="$2"; shift 2
  local args=(6); [ "$mode" = check ] && args=(--check)
  OUT="$(env -u TORTOISE_REPO -u TORTOISE -u SCOUT_UV -u GH_HOST -u CELL_HOME -u SCOUT_PY \
          -u SCOUT_UV_EXTRAS -u GH_CONFIG_DIR \
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
# Budget 90, reserve 40: the ~5 listing pages leave ~85, the first candidate's cold rebuild (~20) is
# affordable and the second is not (85 - 20 = 65 < 40 + 30).
mk_case starved 90
mk_gh "$D" "$(rows 6)"
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh COLLISION_PREFLIGHT_CORE_RESERVE=40
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

# ── 4) NO AFFORDABLE CANDIDATE: a NAMED refusal, never a false empty backlog ────────────────────
# `judged 0` is deliberately outside the `usable -eq 0` assertion (that one requires `judged > 0`), so
# without an explicit arm a budget-starved pass would print `checked 0; backlog now 0` at rc 0 — the
# #1736 false report arriving through the budget door. And it must refuse BEFORE the listings: those
# cost ~40 calls the next pass needs.
mk_case unaffordable 20
mk_gh "$D" "$(rows 6)"
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
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
[ "$spent_dry" -eq 0 ] && ok "unaffordable: refused BEFORE the listings (0 core calls spent)" \
                       || bad "unaffordable: spent $spent_dry core calls before refusing — the listings ran for nothing"

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

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
