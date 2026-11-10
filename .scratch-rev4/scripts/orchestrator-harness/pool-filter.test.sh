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
#     members of the OLD rule, kept because the old rule carried them — the measured tortoise queue
#     had no live row using them, but `analysis(` IS live in agent-infra (#1425, `P2-moderate`), so
#     the kind stays and their fixtures below are SYNTHETIC.
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
# ⛔ THE FULL WORD IS A MEMBER TOO, AND IT WAS MISSING (acceptance cycle, P1). The arm carried `arch`,
# and an alternation member is only excluded when the token is followed by `(` or `:`, so
# `architecture:` and `architecture(...)` were PICKED. Measured on the live agent-infra queue —
# #1295 `architecture: the fleet is not a lifecycle owner — abandoned cmux lanes have no ownership
# signal`, open, unassigned, `P2-moderate`, whose own body says it "is an architecture decision, not a
# bug fix". agent-infra is a GRADED population here (the harness derives `OR` from the checkout's own
# origin), so a container there is dispatched exactly like one in tortoise.
# ⛔ THE PLURAL CLASS (`epics:`, `decisions:`) IS PICKED ON PURPOSE: no live row uses it, and adding an
# unmeasured member is the runtime guess this definition refuses to make.
check_excluded 'architecture: spelled out'   "$(iss 1295 'architecture: the fleet is not a lifecycle owner — abandoned cmux lanes have no ownership signal')"
check_excluded 'architecture(...) spelled out' \
  "$(iss 900006 'architecture(storage): own the storage architecture')"

check_excluded 'leading whitespace' "$(iss 900002 '   epic: indented by a human, still a container')"
# Legacy members of the OLD rule — kept, so dropping one is a reviewed change. (No live row in the
# measured tortoise queue used them; agent-infra#1425 DOES use `analysis(`, which is why the kind
# must stay.)
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
check_included 'fix(...)'     "$(iss 900018 'fix(queue): a fix row is work, whatever its number')"
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
# bare prefix is what dropped `analysis-paralysis fix:` and `lane reaper:` — hiding work is the worse
# direction. ⛔ `epidemic:` is NOT one of them (review cycle 4, P2, measured: `^epic` cannot match
# `epidemic`); it is pinned above as a FORWARD-GUARD, and citing it as a casualty would overstate the
# case for this deliberate widening. Pinned so the trade-off reads as a decision, not an omission.
check_included 'epic of ... (bare epic, no separator)' \
  "$(iss 900029 'epic of the v4 selection workstream')"
check_included 'epic — ... (bare epic, no separator)' \
  "$(iss 900031 'epic — end-to-end proof the workstream works')"
# ⛔ THE SAME TRADE-OFF APPLIES TO `analysis` AND `investigation`, AND IT WAS UNPINNED (review, P3).
# §1 pins the SEPARATOR forms (`analysis: …`, `investigation: …`) as excluded, and the definition
# comment says these two kinds are "carried"; under the structural requirement the BARE spelling has
# no separator and is therefore PICKABLE. That is the correct direction — excluding a bare prefix is
# what dropped `analysis-paralysis fix:` — but it is a real behaviour CHANGE for these two kinds, so
# it is pinned as an inclusion here rather than left to be read as parity with the old rule.
check_included 'analysis (bare, no separator)' \
  "$(iss 900032 'analysis of the recall loss across the two stores')"
check_included 'investigation (bare, no separator)' \
  "$(iss 900033 'investigation into the container reaper double-fire')"

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

# ── 8. THE COMPOSED CALL-SITE STATEMENTS ────────────────────────────────────────────────────
# ⛔ EVERYTHING BELOW READS THE CONTINUATION-JOINED SOURCE, AND PINS WHAT FOLLOWS THE ARGUMENT TOO.
# A pin that greps ONE LINE cannot see an arm moved onto a continuation, and one that strips a
# redirect greedily cannot see a post-filter. Both measured (review cycle 5, P1) — each left this
# suite at `66 passed, 0 failed` AND product-floor at `214/0`:
#     --jq '.[]|'"$pool_jq"'|.number'\        ← the pinned line, byte-for-byte unchanged
#     '|select(. > 9000)' \                   ← bash concatenates this into the SAME word
#     … --jq '.[]|'"$pool_jq"'|.number' 2>>"$O/.pool-err" | grep -v 'mcp'
# and the WRAPPED program dropped live P0 #4282 from the emergency class, so the floor could no longer
# stand itself down. So the joined source is read, the argument is compared as a PREFIX, and the text
# after it must be EXACTLY the statement's own tail: an arm in front, behind, or after the redirect
# all red, and so does any edit to the redirect itself.
JOINED="$(awk '{
  while ($0 ~ /\\[[:space:]]*$/) {
    sub(/\\[[:space:]]*$/, "", $0)
    if ((getline nxt) <= 0) break
    if (nxt ~ /^[[:space:]]/) { sub(/^[[:space:]]+/, "", nxt); $0 = $0 " " nxt }
    else { $0 = $0 nxt }
  }
  print
}' "$RC")"
# Comments are inert; they are also where this file explains itself, so they are excluded from every
# census below rather than edited to dodge it.
NONCOMMENT="$(printf '%s\n' "$JOINED" | grep -vE '^[[:space:]]*#')"

# pin_site <label> <identifying fixed-string> <expected jq argument> <expected tail> <expected output>
pin_site() {
  local label="$1" fixed="$2" want="$3" want_tail="$4" want_out="$5" line rest tail out
  # ⛔ NONCOMMENT, not JOINED (review cycle 6, P2): a COMMENT quoting the shipped statement matched
  # first and discharged the pin, so the real site could regrow a private rule with every check green.
  line="$(printf '%s\n' "$NONCOMMENT" | grep -m1 -F -- "$fixed")"
  if [ -z "$line" ]; then bad=$((bad+1)); echo "FAIL [call site] $label - could not locate its statement in the shipped script"; return; fi
  rest="${line#*--jq }"
  case "$rest" in
    "$want"*) tail="${rest#"$want"}" ;;
    *) bad=$((bad+1)); echo "FAIL [call site] $label - its jq argument is not the shared splice and NOTHING else: '${rest:0:140}'"; return ;;
  esac
  tail="$(printf '%s' "$tail" | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')"
  if [ "$tail" = "$want_tail" ]; then ok=$((ok+1))
  else bad=$((bad+1)); echo "FAIL [call site] $label - something was added around the jq argument (tail is '$tail', expected '$want_tail')"; fi
  # …and the PINNED program must still RUN and emit the right shape (quoting, not just bytes).
  out="$(printf '[%s,%s]' "$(iss 900050 'epic(x): a container')" "$(iss 900051 'fix(y): work')" \
    | POOL_JQ="$SEL" pool_jq="$SEL" eval "jq -r $want" 2>&1)"
  if [ "$out" = "$want_out" ]; then ok=$((ok+1))
  else bad=$((bad+1)); echo "FAIL [call site] $label emitted '$out' - expected '$want_out'"; fi
}
SPLICE_POOL="'\"\$POOL_JQ\"'"
SPLICE_LOCAL="'\"\$pool_jq\"'"
# ⛔ THE ARGUMENT IS PINNED BY EQUALITY, NOT BY BEHAVIOUR ON A FIXTURE (review cycle 4, P2 — measured).
# Driving a site on a TWO-ROW fixture cannot see a private arm that does not match the fixture's one
# work row: `|select((.title//"")|test("mcp";"i")|not)` PREPENDED at the P2 site left this suite at
# `64 passed, 0 failed` while dropping 11 LIVE P2 rows, and the same arm at the floor dropped live P0
# #4282. An APPENDED arm only red the behavioural pin because it crashed jq on a string, which is not
# the property anyone wants. Equality reds on any prepended arm, any appended arm and any re-spelt
# splice, whatever the fixture says — the same shape §9(b) uses for the definition itself.
A0="'.[]|${SPLICE_POOL}|\"0 \\(.number)\"'"
A1="'.[]|${SPLICE_POOL}|\"1 \\(.number)\"'"
A2="'.[]|${SPLICE_POOL}|\"2 \\(.number)\"'"
AF="'.[]|${SPLICE_LOCAL}|.number'"
pin_site 'P0 tier' '|"0 \(.number)"' "$A0" '2>>"$O/.pool-err"; then echo "P0-blocker" >> "$O/.pool-read"' '0 900051'
pin_site 'P1 tier' '|"1 \(.number)"' "$A1" '2>>"$O/.pool-err"; then echo "P1-severe" >> "$O/.pool-read"' '1 900051'
pin_site 'P2 tier' '|"2 \(.number)"' "$A2" '2>>"$O/.pool-err"; then echo "P2-moderate" >> "$O/.pool-read"' '2 900051'
pin_site 'emergency floor' '"$pool_jq"' "$AF" '> "$o/.emergency-issues" 2>/dev/null; then' '900051'

# ── 9. THE DRIFT PINS — one definition, one binding, four call sites, no private copies ─────
# (a) THE SPLICE CENSUS. `grep -c POOL_JQ` is satisfied by comments and by three of four sites, so it
# cannot fail on a dropped call site — pinned by review cycle 2 (P1) after a mutation that removed one
# site's filter still passed. This counts the exact splice text instead, comments excluded.
sites="$(printf '%s\n' "$NONCOMMENT" | grep -cF -- "'\"\$POOL_JQ\"'" 2>/dev/null || true)"
local_sites="$(printf '%s\n' "$NONCOMMENT" | grep -cF -- "'\"\$pool_jq\"'" 2>/dev/null || true)"
if [ "${sites:-0}" -eq 3 ] && [ "${local_sites:-0}" -eq 1 ]; then ok=$((ok+1))
else bad=$((bad+1)); echo "FAIL [drift] call sites splicing the definition: ${sites:-0} file-global + ${local_sites:-0} local - expected 3 + 1 (P0, P1, P2 and the emergency floor)"; fi

# (a2) THE FOURTH SITE'S BINDING IS EVALUATED, NOT COUNTED (review cycle 4, P2). (a) pins the SPLICE
# text, so the emergency floor's `local pool_jq=…` was evaluated by NOTHING: replacing it with a
# NARROWER literal program left this suite at 60/0 and product-floor at 214/0 (measured), i.e. the
# fourth copy could regrow the exact drift this PR removed (T3) with every check green. So resolve the
# shipped expression the way bash does — with POOL_JQ set — and require the RESULT to be the shared
# definition itself.
floor_bind="$(printf '%s\n' "$NONCOMMENT" | sed -n 's/^[[:space:]]*local pool_jq=//p')"
floor_eff=""
if [ -n "$floor_bind" ] && [ "$(printf '%s\n' "$floor_bind" | grep -c .)" -eq 1 ]; then
  # ⛔ THE WHOLE STATEMENT IS EVALUATED, IN A FUNCTION, THE WAY BASH RUNS IT (review cycle 6, P1).
  # `eval "pool_jq_eff=$floor_bind"` executed only the FIRST assignment on the line and silently
  # dropped the rest: appending `; pool_jq+='|select(.number>9000)'` on the SAME line left this suite
  # at `70 passed, 0 failed` with `floor_eff` IDENTICAL to the definition, while the real runtime value
  # ended in the private arm and removed live P0 #4282 from the emergency class. Feeding the statement
  # to a function also reproduces `local`, which the plain eval did not.
  floor_eff="$(printf 'f() { local pool_jq=%s\n printf %%s "$pool_jq"\n}\nf\n' "$floor_bind" \
    | POOL_JQ="$SEL" bash 2>/dev/null)"
fi
if [ "$floor_eff" = "$SEL" ]; then ok=$((ok+1))
else bad=$((bad+1)); echo "FAIL [drift] the emergency floor's \`local pool_jq=\` does not resolve to the shared definition (got '${floor_eff:0:60}') - it must read \${POOL_JQ:?...} and never carry its own program"; fi

# (a3) THE SYMBOL CENSUS — `pool_jq` IS MENTIONED ON EXACTLY TWO NON-COMMENT LINES (cycles 3-5).
# Enumerating assignment SPELLINGS is a losing game, and it was measured losing: `pool_jq=`,
# `pool_jq+=`, `printf -v pool_jq`, `read -r pool_jq`, `declare`, `export` and `eval "pool_jq=…"` are
# independent verbs, and each of the last four left this suite at `66 passed, 0 failed` while giving
# the floor its own program (bash locals are function-scoped, so all of them assign THROUGH the pinned
# binding and leave it pristine). So the invariant is stated on the SYMBOL: the only two lines that may
# mention `pool_jq` are the binding (a2) and the one splice §8 pins. A third mention is a private
# program by construction, whatever spelling produced it.
pq_lines="$(printf '%s\n' "$NONCOMMENT" | grep -c 'pool_jq' 2>/dev/null || true)"
if [ "${pq_lines:-0}" -eq 2 ]; then ok=$((ok+1))
else bad=$((bad+1)); echo "FAIL [drift] \`pool_jq\` is mentioned on ${pq_lines:-0} non-comment line(s) - expected exactly 2 (the binding and the floor's splice); any third mention is a private pool program"; fi

# (b2) THE DEFINITION SYMBOL CENSUS — `POOL_JQ` IS MENTIONED ON EXACTLY FIVE NON-COMMENT LINES
# (review cycle 5, P2). §9(b) pins the TEXT of the column-0 assignment, so an INDENTED second
# statement — `  POOL_JQ="${POOL_JQ}|select((.title//"")|test("mcp";"i")|not)"` — appended to the
# program while ndef stayed 1, SEL stayed pristine, and §9(b) compared the pristine line to itself:
# measured `66 passed, 0 failed` at both suites with all FOUR sites then running the narrowed program.
# The census counts the definition, the three tier splices and the floor's binding — a second
# assignment, an `+=`, or any new mention reds wherever it sits and however it is spelled.
pj_lines="$(printf '%s\n' "$NONCOMMENT" | grep -c 'POOL_JQ' 2>/dev/null || true)"
if [ "${pj_lines:-0}" -eq 5 ]; then ok=$((ok+1))
else bad=$((bad+1)); echo "FAIL [drift] \`POOL_JQ\` is mentioned on ${pj_lines:-0} non-comment line(s) - expected exactly 5 (the definition, the three tier splices, and the floor's binding); a second definition re-arms every call site at once"; fi

# (c) NO PRIVATE PREDICATE QUERY (review cycle 5, P2). The Review Scope Contract's R3 claims "zero
# inline container regexes — pinned"; it was not. A FIFTH candidate query carrying the pre-fix rule adds
# no splice, so every count above is untouched: measured, adding
#     --label P3-minor --jq '.[]|select((.assignees|length)==0)|select(.title|test("^(epic|OWNER DECISION)";"i")|not)|.number'
# left this suite at `66 passed, 0 failed`. A private pool rule IS a jq `select(`/`test(`, so a `--jq`
# argument that carries one and does not splice the shared definition is exactly the drift this file
# removes — including at a site nobody has written yet.
# ⛔ SCOPED TO TITLE/LABEL FILTERING (review cycle 6, P3). Unscoped, this red a legitimate change to an
# UNRELATED listing (`--jq '.[].number'` → `--jq '.[]|select(.number>0)|.number'` at :2534) and accused
# it of a private pool rule. A container rule necessarily reads `.title` or `.labels`, so those are the
# queries this census owns; a query that filters on neither is not in the pool path.
priv="$(printf '%s\n' "$NONCOMMENT" | grep -E -- '--jq.*(select\(|test\()' | grep -cE -- '\.title|\.labels' 2>/dev/null || true)"
if [ "${priv:-0}" -eq 0 ]; then ok=$((ok+1))
else bad=$((bad+1)); echo "FAIL [drift] ${priv:-0} \`--jq\` program(s) carry a select(/test( WITHOUT splicing the shared definition - a private pool rule is the drift this file removes"; fi

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
POOL_PROG_WANT='select((.assignees|length)==0)|select((((.labels//[])|map(.name|ascii_downcase)) as $L|[$L[]|. as $n|select(["standing-constraint"]|index($n))]|length)==0)|select((.title//"")|test("^\\s*(?:((?:epic|decision|design|coord|measure|analysis|investigation|requirement|tracking|residual|map|arch|architecture|owner decision)|decision\\s+needed)(?:-scope)?\\s*[(:]|lane\\s+[A-Za-z]{0,2}[0-9][A-Za-z0-9._-]*\\s*:)";"i")|not)'
if [ "$SEL" = "$POOL_PROG_WANT" ]; then ok=$((ok+1))
else bad=$((bad+1)); echo "FAIL [membership] the pool program changed — update POOL_PROG_WANT in this suite (and say why in the PR) rather than widening, narrowing or re-arming the rule silently"; echo "    got:  $SEL"; echo "    want: $POOL_PROG_WANT"; fi

echo "pool-filter: $ok passed, $bad failed"
[ "$bad" -eq 0 ] || exit 1
