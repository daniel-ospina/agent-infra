#!/usr/bin/env bash
# pool-filter.test.sh — the pool-eligibility definition, driven through REAL jq (#10951)
#
# ⛔ IT TESTS THE SHIPPED BYTES, NOT A COPY OF THEM. The definition is the single `POOL_JQ=`
# assignment in `refresh-candidates.sh`; this suite EXTRACTS that line and feeds it to `jq`, so a
# case exercises oniguruma — the regex engine that actually decides — rather than bash's `[[ =~ ]]`,
# which disagrees with it on non-capturing groups and on `\s`. It is the same extraction trick
# `selftest.sh` already uses for this script's other pinned lines, and it is why the definition
# can be a new in-file line instead of a new file: a new sibling file would have to be declared in
# every farm/install list, and a cell that was re-farmed without it would abort every pass.
#
# `POOL_DEF_SRC=<path>` points the extraction at ANOTHER copy of the script — used to re-run the
# pre-fix baseline (see the PR body) without reverting the change.
#
# THE CASES ARE THE LIVE QUEUE'S OWN TITLES. Every container spelling below was read off an open
# P0/P1/P2 issue on 2026-11-05 (219 rows), not invented; every work title likewise. The mutation
# cases (`epidemic: …`, `map the query surface …`, `lane reaper: …`, `analysis-paralysis …`) are
# the over-block half of that same measurement: titles the OLD bare-prefix regex silently dropped.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC="${POOL_DEF_SRC:-$HERE/refresh-candidates.sh}"

[ -f "$RC" ] || { echo "FATAL: no script to extract the definition from: $RC"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is not installed — this suite cannot drive the filter"; exit 1; }

ok=0; bad=0

ndef="$(grep -c '^POOL_JQ=' "$RC" 2>/dev/null || true)"
if [ "${ndef:-0}" -ne 1 ]; then
  echo "FAIL [definition] expected exactly 1 '^POOL_JQ=' line in $RC, found ${ndef:-0} — the pool rule must exist exactly once"
  echo "pool-filter: 0 passed, 1 failed"
  exit 1
fi
SEL="$(grep -m1 '^POOL_JQ=' "$RC" | sed -e "s/^POOL_JQ='//" -e "s/'\$//")"
if [ -z "$SEL" ]; then echo "FAIL [definition] the POOL_JQ line extracted EMPTY"; exit 1; fi
# The definition must COMPILE — a syntax error would turn every tier query into a listing failure
# that the `.pool-err` arms would report as a GitHub outage.
if ! printf '[]' | jq -r ".[]|$SEL|.number" >/dev/null 2>&1; then
  echo "FAIL [definition] the extracted POOL_JQ does not compile:"
  printf '[]' | jq -r ".[]|$SEL|.number" 2>&1 | head -3 | sed 's/^/    /'
  echo "pool-filter: 0 passed, 1 failed"
  exit 1
fi

survives() { printf '[%s]' "$1" | jq -r ".[]|$SEL|1" 2>&1; }

check_excluded() { # <label> <issue json>
  local out; out="$(survives "$2")"
  if [ -z "$out" ]; then ok=$((ok+1))
  else bad=$((bad+1)); echo "FAIL [container excluded] $1 — the filter let it through ($out)"; fi
}

check_included() { # <label> <issue json>
  local out; out="$(survives "$2")"
  if [ "$out" = "1" ]; then ok=$((ok+1))
  else bad=$((bad+1)); echo "FAIL [work included] $1 — the filter DROPPED it (out='$out')"; fi
}

iss() { # <number> <title> [labels-csv]
  local n="$1" t="$2" l="${3:-}"
  local labels='[]'
  # GitHub's payload shape: labels are OBJECTS with a `.name`, never bare strings — a fixture that
  # gets this wrong proves nothing about the filter that reads the real response.
  if [ -n "$l" ]; then labels="$(printf '%s' "$l" | tr ',' '\n' | jq -R '{name:.}' | jq -sc .)"; fi
  printf '{"number":%s,"title":%s,"labels":%s,"assignees":[]}' \
    "$n" "$(printf '%s' "$t" | jq -Rs .)" "$labels"
}

# ── 1. CONTAINER SPELLINGS THE REPOSITORY ACTUALLY USES — each must be EXCLUDED ───────────────
check_excluded 'epic(...)'          "$(iss 7949 'epic(extractor-v4): CAPSTONE — end-to-end proof the v4 selection workstream actually works')"
check_excluded 'epic:'              "$(iss 7879 'epic: the Postgres record — the four ontology layers as an authoritative relational store')"
check_excluded 'Epic: (case)'       "$(iss 1402 'Epic: Agent-reasoning eval battery — prove the graph improves reasoning')"
check_excluded 'epic-scope:'        "$(iss 2513 'epic-scope: multi-session retrieval evidence-surface — the dominant QA loss')"
check_excluded 'lane <id>:'         "$(iss 5095 'lane L3: extractor — the pipeline body')"
check_excluded 'OWNER DECISION (...)' "$(iss 3858 'OWNER DECISION (OD-6): what do we promise about how long a restore takes?')"
check_excluded 'decision(...)'      "$(iss 4824 'decision(fleet): the fleet dogfoods HOSTED memory on a paid tier (Pro)')"
check_excluded 'design(...)'        "$(iss 5491 'design(ratelimit): the shared per-IP bucket primitive has no aggregate dimension')"
check_excluded 'design(...) 2'      "$(iss 5333 'design(extractor): the destructive/relocation half of G5')"
check_excluded 'coord:'             "$(iss 4917 'coord: memory quality + cost — measurements, the 3-workstream plan, and the work order')"
check_excluded 'measure(...)'       "$(iss 9097 'measure(ask): seal and publish the epic Q3 exit measurement')"
check_excluded 'measure(...) 2'     "$(iss 10464 'measure(tiering): the #5009 premise is unmeasured — are our queries answered badly')"
check_excluded 'analysis:'          "$(iss 9001 'analysis: where the recall loss actually is')"
check_excluded 'investigation:'     "$(iss 9002 'investigation: why the container reaper double-fired')"
check_excluded 'requirement(...)'   "$(iss 4622 'requirement(objective-4): the done-state has never been measured against the deployed product')"
check_excluded 'tracking:'          "$(iss 2820 'tracking: memory-substrate problem map — write-path integrity')"
check_excluded 'residual(...)'      "$(iss 7524 'residual(extractor): the boundary NER/POS/syntax residuals have no live tracker')"
check_excluded 'map(...)'           "$(iss 5313 'map(pricing): every place tied to the pricing model — the blast radius')"
check_excluded 'arch(...)'          "$(iss 4333 'arch(storage): own the storage architecture — node volume + the true per-node cost')"
check_excluded 'leading whitespace' "$(iss 9003 '   epic: indented by a human, still a container')"

# ── 2. THE DECLARED ARM — a standing constraint is excluded by DECLARATION, not by prose ──────
# #10175 verbatim: its title is `ops(capture): …`, which no title rule can tell from work. The
# label is what makes it excludable without an agent reading the words "HELD deliberately".
check_excluded 'standing-constraint label (#10175)' \
  "$(iss 10175 'ops(capture): the hosted capture cap is HELD deliberately — never override it; the switchover is a new graph on Pro, set as default and measured' 'P1-severe,standing-constraint')"
check_excluded 'epic label' \
  "$(iss 9004 'Implement the canonical MCP and SDK surface (98->26 tools)' 'epic')"
check_excluded 'label is case-insensitive' \
  "$(iss 9005 'Retire the legacy door' 'Standing-Constraint')"

# ── 3. WORK TITLES — each must be INCLUDED (a filter that hides work is the worse defect) ────
check_included 'feat(...)'    "$(iss 9101 'feat(4282): retire the five run_onboarding MCP tools (81 -> 76 live)')"
check_included 'fix(...)'     "$(iss 10951 'fix(10951): the container-title filter misses no spelling')"
check_included 'bug(...)'     "$(iss 9102 'bug(queue): the container-title filter misses the spellings the repo uses')"
check_included 'test(...)'    "$(iss 9567 'test(record): capstone — prove the record works end to end')"
check_included 'chore(...)'   "$(iss 9103 'chore(deps): bump uv to 0.6.0')"
check_included 'refactor(...)' "$(iss 9104 'refactor(4282): collapse the five onboarding doors')"
check_included 'docs(...)'    "$(iss 9105 'docs(10000): the source vector embeds the NARRATIVE')"
check_included 'perf(...)'    "$(iss 9106 'perf(ask): the dense leg re-embeds every turn')"
check_included 'defect(...)'  "$(iss 4051 'defect(quota): the commit lane only org-limit gate was the session cap')"
check_included 'ops(...) unlabelled' "$(iss 9107 'ops(capture): arm the record in the hosted deployment')"
check_included 'hosted:'      "$(iss 9108 'hosted: the 429 retry loop never backs off')"
check_included 'rail:'        "$(iss 9331 'rail: a failure signature that embeds a measurement can never match main')"
check_included 'P0 storage:'  "$(iss 10000 'P0 storage: raw turns + session narrative are still written twice')"
check_included 'no kind at all' "$(iss 8488 'Add context-enriched embeddings + BM25 lexical retrieval')"
check_included 'no kind (benchmark)' "$(iss 8486 'Run the LongMemEval-S end-to-end QA benchmark')"
check_included 'MCP read surface:' "$(iss 8861 'MCP read surface: tortoise_health does not exist')"
# ⛔ `owner-decision` is a label on REAL WORK (#5212 is a `fix(`, #4051 a `defect(`) — the comment
# at the definition says why it is not in the label arm, and this pins that it stays included.
check_included 'owner-decision label on a fix' \
  "$(iss 5212 'fix(mcp): tortoise_create_source cannot record the absent-raw state' 'owner-decision,P2-moderate')"

# ── 4. OVER-BLOCK MUTATIONS — the OLD bare-prefix rule dropped these; they are WORK ───────────
check_included 'epidemic:'            "$(iss 9111 'epidemic: the gate spreads across surfaces')"
check_included 'map the ... (no marker)' "$(iss 9112 'map the query surface to the 26 canonical tools')"
check_included 'lane reaper: (no id)' "$(iss 9113 'lane reaper: the sweep never advances past a stale entry')"
check_included 'analysis-paralysis'   "$(iss 9114 'analysis-paralysis fix: cap the review cycles')"

# ── 5. UNKNOWN SPELLINGS STAY PICKABLE (the documented failure direction) ────────────────────
check_included 'unknown kind' "$(iss 9115 'thingamajig(scope): a kind nobody has enumerated yet')"

# ── 6. SHARED ARMS — the unassigned guard still holds, and a null title does not crash ───────
badassign="$(printf '[%s]' "$(iss 9116 'fix(x): an assigned issue is not dispatchable')" | jq -c '.[0].assignees=[{"login":"someone"}]' | jq -r ".[]|$SEL|1" 2>&1)"
if [ -z "$badassign" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "FAIL [assigned] an ASSIGNED issue survived the pool filter"; fi

nullish="$(printf '[%s]' '{"number":9117,"title":null,"labels":null}' | jq -r ".[]|$SEL|1" 2>&1)"
if [ "$nullish" = "1" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "FAIL [robustness] a null title/labels entry did not survive cleanly (out='$nullish')"; fi

# ── 7. THE DRIFT PIN — one definition, four call sites, zero private copies ──────────────────
# This is exactly the defect shape #10951 records: four inline copies that had already drifted
# (P1/P2 excluded two of the six spellings P0 excluded), so a call site that regrows its own
# container regex is a second definition of "work unit".
inline="$(grep -c 'test("^(epic' "$RC" 2>/dev/null || true)"
if [ "${inline:-0}" -eq 0 ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "FAIL [drift] $RC still carries $inline inline container regex(es) — one definition, or the copies drift again"; fi

sites="$(grep -c 'jq "\.\[\]|\$POOL_JQ|' "$RC" 2>/dev/null || true)"
if [ "${sites:-0}" -ge 4 ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "FAIL [drift] only ${sites:-0} call site(s) use \$POOL_JQ — expected at least 4 (P0, P1, P2, emergency floor)"; fi

echo "pool-filter: $ok passed, $bad failed"
[ "$bad" -eq 0 ] || exit 1
