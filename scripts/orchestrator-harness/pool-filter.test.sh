#!/usr/bin/env bash
# pool-filter.test.sh — the pool-eligibility definition, driven through REAL jq (#10951)
#
# ⛔ IT TESTS THE SHIPPED BYTES, NOT A COPY OF THEM. The definition is the single `POOL_JQ=`
# assignment in `refresh-candidates.sh`; this suite EXTRACTS that line and feeds it to `jq`, so a
# case exercises oniguruma — the regex engine that actually decides — rather than bash's `[[ =~ ]]`,
# which disagrees with it on non-capturing groups and on `\s`.
#
# WHY THE DEFINITION IS AN IN-FILE LINE AND NOT ITS OWN FILE: nothing new is RESOLVED at runtime.
# `refresh-candidates.sh` is executed from a pin-materialised checkout and from copies of itself, so
# a second file that a pass had to locate would be a new way for every pool query to fail; and one
# line beside its four call sites is the only copy that cannot drift from them (drifting copies are
# the defect this fixes).
#
# `POOL_DEF_SRC=<path>` points the extraction at ANOTHER copy of the script. That is how the
# pre-fix baseline is re-run without reverting the change: take a copy of the shipped script and
# replace its `POOL_JQ=` line with the old rule —
#   POOL_JQ='select((.assignees|length)==0)|select((.title//"")|test("^(epic|lane|OWNER DECISION|decision|analysis|investigation)";"i")|not)'
# then `POOL_DEF_SRC=/tmp/that-copy.sh bash scripts/orchestrator-harness/pool-filter.test.sh`.
#
# PROVENANCE OF THE CASES, stated precisely because a fixture claiming to be evidence is worse than
# no fixture:
#   • CONTAINER spellings (section 1) and the WORK titles in section 3 that carry a real issue
#     number are QUOTED FROM LIVE ROWS — an open daniel-ospina/tortoise P0/P1/P2 issue read on
#     2026-11-05 (219 rows). `analysis:` / `investigation:` are the exception and say so: they are
#     members of the OLD rule that no live row currently uses, kept because the old rule carried
#     them.
#   • SYNTHETIC cases are numbered from 900001 so they cannot be mistaken for a real issue: the
#     over-block guards (section 4), the unknown-kind case (5), and the robustness rows (6).
#   • Section 4's `epidemic:` and `map the …` cases are FORWARD-GUARDS, not casualties of the old
#     rule (`^epic` cannot match `epidemic`) — they exist so a re-added bare prefix cannot pass.
#     `lane reaper:` and `analysis-paralysis fix:` ARE casualties: the old rule dropped both.
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
check_excluded 'requirement(...)'   "$(iss 4622 'requirement(objective-4): the done-state has never been measured against the deployed product')"
check_excluded 'tracking:'          "$(iss 2820 'tracking: memory-substrate problem map — write-path integrity')"
check_excluded 'residual(...)'      "$(iss 7524 'residual(extractor): the boundary NER/POS/syntax residuals have no live tracker')"
check_excluded 'map(...)'           "$(iss 5313 'map(pricing): every place tied to the pricing model — the blast radius')"
check_excluded 'arch(...)'          "$(iss 4333 'arch(storage): own the storage architecture — node volume + the true per-node cost')"
check_excluded 'leading whitespace' "$(iss 900002 '   epic: indented by a human, still a container')"
# Legacy members of the OLD rule that no live row uses — kept, so dropping one is a reviewed change.
check_excluded 'analysis: (legacy kind)'      "$(iss 900003 'analysis: where the recall loss actually is')"
check_excluded 'investigation: (legacy kind)'  "$(iss 900004 'investigation: why the container reaper double-fired')"

# ── 2. THE DECLARED ARM — a standing constraint is excluded by DECLARATION, not by prose ──────
# #10175 verbatim: its title is `ops(capture): …`, which no title rule can tell from work. The
# label is what makes it excludable without an agent reading the words "HELD deliberately".
check_excluded 'standing-constraint label (#10175)' \
  "$(iss 10175 'ops(capture): the hosted capture cap is HELD deliberately — never override it; the switchover is a new graph on Pro, set as default and measured' 'P1-severe,standing-constraint')"
check_excluded 'label is case-insensitive' \
  "$(iss 900005 'Retire the legacy door' 'Standing-Constraint')"
# ⛔ THE `epic` LABEL IS NOT AN EXCLUSION — and the measurement is that it changed NOTHING either way.
# All 7 epic-labelled rows in the severity queue are also epic-TITLED, so the title arm already
# excluded every one of them; the arm was a no-op. It is dropped as an UNPINNED label rather than
# because it hid a live row: tortoise#9701 carries `epic` on a `bug(tooling):` work row but no
# P0/P1/P2 label, so it was never in this population. The case below keeps that shape excluded from
# ever being an exclusion reason: a work title plus the `epic` label must stay pickable.
check_included 'epic label on a work title (not an exclusion)' \
  "$(iss 9701 'bug(tooling): epic→child wiring is prose-only — audits read epics as childless (#1402 reported as zero children while 12 existed)' 'epic')"

# ── 3. WORK TITLES — each must be INCLUDED (a filter that hides work is the worse defect) ────
check_included 'feat(...)'    "$(iss 900010 'feat(4282): retire the five run_onboarding MCP tools (81 -> 76 live)')"
check_included 'fix(...)'     "$(iss 10951 'fix(10951): the container-title filter misses no spelling')"
check_included 'bug(...)'     "$(iss 900011 'bug(queue): the container-title filter misses the spellings the repo uses')"
check_included 'test(...)'    "$(iss 9567 'test(record): capstone — prove the record works end to end')"
check_included 'chore(...)'   "$(iss 900012 'chore(deps): bump uv to 0.6.0')"
check_included 'refactor(...)' "$(iss 900013 'refactor(4282): collapse the five onboarding doors')"
check_included 'docs(...)'    "$(iss 900014 'docs(10000): the source vector embeds the NARRATIVE')"
check_included 'perf(...)'    "$(iss 900015 'perf(ask): the dense leg re-embeds every turn')"
check_included 'defect(...)'  "$(iss 4051 'defect(quota): the commit lane only org-limit gate was the session cap')"
check_included 'ops(...) unlabelled' "$(iss 900016 'ops(capture): arm the record in the hosted deployment')"
check_included 'hosted:'      "$(iss 900017 'hosted: the 429 retry loop never backs off')"
check_included 'rail:'        "$(iss 9331 'rail: a failure signature that embeds a measurement can never match main')"
check_included 'P0 storage:'  "$(iss 10000 'P0 storage: raw turns + session narrative are still written twice')"
check_included 'no kind at all' "$(iss 8488 'Add context-enriched embeddings + BM25 lexical retrieval')"
check_included 'no kind (benchmark)' "$(iss 8486 'Run the LongMemEval-S end-to-end QA benchmark')"
check_included 'MCP read surface:' "$(iss 8861 'MCP read surface: tortoise_health does not exist')"
# ⛔ `owner-decision` is a label on REAL WORK (#5212 is a `fix(`, #4051 a `defect(`) — the comment
# at the definition says why it is not in the label arm, and this pins that it stays included.
check_included 'owner-decision label on a fix' \
  "$(iss 5212 'fix(mcp): tortoise_create_source cannot record the absent-raw state' 'owner-decision,P2-moderate')"

# ── 4. OVER-BLOCK GUARDS — none of these may ever be dropped ─────────────────────────────────
# The last two ARE casualties of the OLD bare prefix (`^analysis`, `^lane`); the first two are
# forward-guards, because a re-added bare prefix (`^epic`, `^map`) would drop them.
check_included 'epidemic: (forward-guard)'   "$(iss 900020 'epidemic: the gate spreads across surfaces')"
check_included 'map the ... (forward-guard)' "$(iss 900021 'map the query surface to the 26 canonical tools')"
check_included 'lane reaper: (old-rule casualty)' "$(iss 900022 'lane reaper: the sweep never advances past a stale entry')"
check_included 'analysis-paralysis (old-rule casualty)' "$(iss 900023 'analysis-paralysis fix: cap the review cycles')"
# A decision REQUEST is a container by this file's own rule, and it was the ONE container-shaped title
# the structural form missed in the live 179 (tortoise#3447, P2-moderate, unassigned). Pinned so
# removing the arm is a conscious change.
check_excluded 'decision needed: (#3447)' "$(iss 3447 'Decision needed: reinstate or drop the deferred [checks.loop_liveness] fly.toml check')"
# …and `lane:` WITHOUT an id is not the umbrella form, so it stays work-shaped rather than guessed at.
check_included 'lane: without an id' "$(iss 900024 'lane: the sweep never advances past a stale entry')"
# ⛔ THE QUALIFIER IS BOUNDED (review cycle 3, P1). An `(?:-[A-Za-z0-9]+)*` qualifier excluded every
# `<kind>-<word>:` title, so these four — a correlation-id propagation task, a palette extraction, a
# lint bug and an unbounded LRU — were silently DROPPED at runtime with no `.pool-err` and a
# healthy-looking count. They are pinned as INCLUSIONS so re-widening the qualifier reds here.
check_included 'tracking-id: (hyphenated work, not a qualifier)' \
  "$(iss 900025 'tracking-id: propagate the correlation id through the funnel')"
check_included 'design-tokens: (hyphenated work)' \
  "$(iss 900026 'design-tokens: extract the palette into one module')"
check_included 'arch-lint: (hyphenated work)' \
  "$(iss 900027 'arch-lint: the rule misfires on fixtures')"
check_included 'map-cache: (hyphenated work)' \
  "$(iss 900028 'map-cache: the LRU is unbounded')"
# ⛔ A BARE `epic` WITH NO SEPARATOR IS DELIBERATELY PICKABLE (review cycle 3, P2). The pre-fix P0
# rule excluded these two by prefix; the structural requirement includes them, because excluding by
# bare prefix is what dropped `epidemic:` and `analysis-paralysis fix:` — hiding work is the worse
# direction. Pinned so the trade-off reads as a decision rather than as an omission.
check_included 'epic of ... (bare epic, no separator)' \
  "$(iss 900029 'epic of the v4 selection workstream')"
check_included 'epic — ... (bare epic, no separator)' \
  "$(iss 900031 'epic — end-to-end proof the workstream works')"

# ── 5. UNKNOWN SPELLINGS STAY PICKABLE (the documented failure direction) ────────────────────
check_included 'unknown kind' "$(iss 900030 'thingamajig(scope): a kind nobody has enumerated yet')"

# ── 6. SHARED ARMS — the unassigned guard still holds, and a null title does not crash ───────
badassign="$(printf '[%s]' "$(iss 900040 'fix(x): an assigned issue is not dispatchable')" | jq -c '.[0].assignees=[{"login":"someone"}]' | jq -r ".[]|$SEL|1" 2>&1)"
if [ -z "$badassign" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "FAIL [assigned] an ASSIGNED issue survived the pool filter"; fi

nullish="$(printf '[%s]' '{"number":900041,"title":null,"labels":null}' | jq -r ".[]|$SEL|1" 2>&1)"
if [ "$nullish" = "1" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "FAIL [robustness] a null title/labels entry did not survive cleanly (out='$nullish')"; fi

# ── 7. THE COMPOSED CALL-SITE PROGRAMS — the shape `selftest.sh` extracts must survive ───────
# ⛔ PINNED BY REVIEW CYCLE 1 (P1). The definition alone passing does not prove a CALL SITE works: an
# earlier cut emitted `|\"0 \(.number)`, and `selftest.sh:3856` (`match($0,/\|"[0-9] /)`) then
# extracted NOTHING — reddening the #8465 tier-rank guard and blinding it at once. Reproduce selftest's
# own extraction here, so the contract cannot break silently again.
RANKS="$(awk '{printf "%s", $0} /\\$/{next} {print ""}' "$RC" \
  | awk '/--label/{lab=""; for(i=1;i<=NF;i++) if($i=="--label") lab=$(i+1);
           if(match($0,/\|"[0-9] /)) print lab" -> "substr($0,RSTART+2,1)}' \
  | tr '\n' ' ' | sed 's/ *$//')"
if [ "$RANKS" = "P0-blocker -> 0 P1-severe -> 1 P2-moderate -> 2" ]; then ok=$((ok+1))
else bad=$((bad+1)); echo "FAIL [selftest contract] the tier->rank pairs selftest.sh extracts came out '$RANKS' — expected 'P0-blocker -> 0 P1-severe -> 1 P2-moderate -> 2'"; fi

# And EVERY call site must still behave. ⛔ BOTH shapes are driven: the three tier queries (which emit
# `"<tier> <number>"`) and the emergency floor (which emits a bare `.number` and, by review cycle 2,
# reads the program through its own `pool_jq` local because its body is extracted on its own).
drive_site() { # <label> <fixed-string that identifies the site's jq argument> <expected output>
  local label="$1" fixed="$2" want="$3" site out
  # strip the leading `--jq `, a trailing ` 2>>…` redirect, and a trailing shell line-continuation `\`
  site="$(grep -m1 -F -- "$fixed" "$RC" | sed -e "s/^.*--jq //" -e "s/[[:space:]]*2>>.*//" -e 's/[[:space:]]*\\$//')"
  if [ -z "$site" ]; then bad=$((bad+1)); echo "FAIL [composed call site] $label - could not locate the jq argument"; return; fi
  out="$(printf '[%s,%s]' "$(iss 900050 'epic(x): a container')" "$(iss 900051 'fix(y): work')" \
    | POOL_JQ="$SEL" pool_jq="$SEL" eval "jq -r $site" 2>&1)"
  if [ "$out" = "$want" ]; then ok=$((ok+1))
  else bad=$((bad+1)); echo "FAIL [composed call site] $label emitted '$out' - expected '$want'"; fi
}
# The three tier queries concatenate $POOL_JQ and append the tier prefix.
drive_site 'P0 tier' '|"0 \(.number)"' '0 900051'
# The emergency floor reads it through its own local (its body is extracted alone).
drive_site 'emergency floor' '"$pool_jq"' '900051'

# ── 8. THE DRIFT PINS — one definition, exactly four call sites, no private copies ───────────
# (a) THE SHAPE PIN, not the identifier. `grep -c POOL_JQ` is satisfied by comments and by three of
# four sites, so it cannot fail on a dropped call site — pinned by review cycle 2 (P1) after a mutation
# that removed one site's filter still passed. This counts the exact splice text instead.
sites="$(grep -cF -- "'\"\$POOL_JQ\"'" "$RC" 2>/dev/null || true)"
local_sites="$(grep -cF -- "'\"\$pool_jq\"'" "$RC" 2>/dev/null || true)"
if [ "${sites:-0}" -eq 3 ] && [ "${local_sites:-0}" -eq 1 ]; then ok=$((ok+1))
else bad=$((bad+1)); echo "FAIL [drift] call sites splicing the definition: ${sites:-0} file-global + ${local_sites:-0} local - expected 3 + 1 (P0, P1, P2 and the emergency floor)"; fi

# (b) THE WHOLE PROGRAM IS PINNED, ONCE, BY WHOLE-TEXT EQUALITY (review cycle 4, P2). The three
# per-arm pins that used to live here could each be defeated by an ARM APPENDED to the shared program:
# `grep -c '\.title'` counts LINES and the whole program is ONE line, so a second `.title` arm read as
# 1; a substring pin on the alternation survived `|plan` appended to the outer group; and an appended
# second label select (or a fourth arm on a field nothing counted — `.milestone`) read as one select.
# Measured at the prior head: appending `|select(((.title//"")|ascii_downcase|startswith("spike")|not))`
# left the suite at `62 passed, 0 failed` while `spike(events): …` was silently DROPPED. Pinning the
# whole assignment subsumes every one of those: a second arm, a re-spelled label exclusion, an arm on
# an uncounted field, a reordering, a widened member and a changed qualifier ALL red here.
#
# ⛔ SO: CHANGING THE POOL RULE REQUIRES EDITING `POOL_PROG_WANT` BELOW, and that edit is the reviewed
# test change the definition comment promises. If you are here because this check failed, the question
# is not "how do I make it green" — it is "am I deliberately changing what counts as a work unit, and
# have I said why in the PR?" `refs #8465` is what it costs when that question goes unasked.
POOL_PROG_WANT='select((.assignees|length)==0)|select((((.labels//[])|map(.name|ascii_downcase)) as $L|[$L[]|. as $n|select(["standing-constraint"]|index($n))]|length)==0)|select((.title//"")|test("^\\s*(?:((?:epic|decision|design|coord|measure|analysis|investigation|requirement|tracking|residual|map|arch|owner decision)|decision\\s+needed)(?:-scope)?\\s*[(:]|lane\\s+[A-Za-z]{0,2}[0-9][A-Za-z0-9._-]*\\s*:)";"i")|not)'
if [ "$SEL" = "$POOL_PROG_WANT" ]; then ok=$((ok+1))
else bad=$((bad+1)); echo "FAIL [membership] the pool program changed — update POOL_PROG_WANT in this suite (and say why in the PR) rather than widening, narrowing or re-arming the rule silently"; echo "    got:  $SEL"; echo "    want: $POOL_PROG_WANT"; fi

echo "pool-filter: $ok passed, $bad failed"
[ "$bad" -eq 0 ] || exit 1
