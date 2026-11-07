#!/usr/bin/env bash
# brief-gate.sh — THE research contract a brief must satisfy, and the ONE place it is decided
# (agent-infra#2258).
#
# WHY THIS FILE EXISTS. "Research first" was mandated in `AGENTS.md` and in the orchestrator's prose
# and existed NOWHERE on the dispatch path, so a brief written without it dispatched a lane that
# could not know it had skipped the pass. Measured, twice in one day: a lane re-derived a root the
# tracker already held (the Postgres record migration was already decomposed across #7879 / #5086 /
# #5090 / #8607), and a lane opened a DUPLICATE PR (#2247 vs #2250 for the same three fixes). Both
# were brief defects, not lane defects. A rule that lives only in the dispatcher's memory is
# exactly as strong as the weakest dispatcher — the argument this tree already made for the load gate
# (`spawn-gate.sh`, #1884) and for the reviewer disclosure (`reviewer-preflight.sh`, #2148).
#
# #2148 IS THE PRECEDENT, and this file follows it deliberately: a section that makes the requirement
# impossible to omit from the BRIEF, plus a fail-closed check so a brief that lacks it never reaches
# an agent. The difference is where the check bites. #2148 discloses; this one REFUSES.
#
# ── THE SCHEMA ───────────────────────────────────────────────────────────────────────────────────
# A brief passes iff it carries, as plain markdown:
#
#   1. a `RESEARCH FIRST` heading (`## RESEARCH FIRST`, any case, any `#` depth), and INSIDE that
#      section (subsections allowed, the section ends at the next heading of the same or shallower
#      depth):
#        INTERNAL: <non-empty>   what this repo/tracker already holds
#        EXTERNAL: <non-empty>   what is looked up outside it
#        RUNG: <1|2|3> — <tool>  which rung of the research ladder, and the tool it names
#   2. ANYWHERE in the brief:
#        CONTRADICTION TEST: <non-empty>   whether a RECORDED DECISION covers the work
#   3. FOR THE `reviewer` ROLE AT ROUND >= 4 ONLY (agent-infra#3441), and INSIDE the research section
#      like INTERNAL/EXTERNAL/RUNG (subsections allowed; a line under an unrelated heading does not
#      count — round-3 review, P2: the validator enforced this while the schema did not say it):
#        COMPARABLES: <non-empty>   what comparable / competitor implementations do for the mechanism
#      A SEPARATE label, not a word inside EXTERNAL — see the round section below for why.
#   4. a `PREVIOUS WORK` heading (any case, any `#` depth), and INSIDE that section:
#        CLAIM: WIP: BRANCH: WORKTREE: PRIOR:   — each with a non-empty value, and WIP's value
#        BEGINNING `issue-<N>` (`pr-<N>` for a fixer's PR key). See the fourth contract below.
#
# Two labelled fields are not decoration: they are the two halves of the pass that the two measured
# incidents each skipped, and the rung line is what stops "research" from degrading into "I thought
# about it" — rung 3 (`web_fetch`) is always available, so the field is never unsatisfiable.
#
# ── THE FOURTH CONTRACT: PREVIOUS WORK (#3484) ──────────────────────────────────────────────────
# Two mechanisms make a reaped claim safe, and BOTH were voluntary: `scripts/lane-wip.py` ("did the
# lane finish, or stop mid-WIP, and WHAT is the WIP?", invoked by nothing on the dispatch path) and
# `scripts/bg-rescue-wip.sh` (archives uncommitted work to `refs/wip/<slug>` on origin). Measured
# 2026-11-05: **222 rescued `refs/wip/*` archives existed and nothing told the next actor to look at
# them**, `claims.sh`/`claim-reaper.sh` mentioned WIP ZERO times, and the same session produced three
# branches for one issue, two for another, and a dispatch on an issue whose PR already existed. A
# released claim reads as *"nothing happened here"* when it should read as *"here is what someone
# already did"*.
#
# So the brief must carry the measurement, and — the half that is not prose — the gate REFUSES a
# `WIP:` line that names NO ref while `refs/wip/*` holds one that belongs to the issue the line is
# keyed to. `silence is not freedom`, the polarity `claim-unreadable` already uses for the claim
# registry. The check is a CONTRADICTION test, not a substance test: it cannot tell whether the
# author READ the ref, and the next actor still has to read it.
#
# ⚠️ STATED RESIDUAL — THE WIP CROSS-CHECK IS BEST-EFFORT, AND DELIBERATELY SO, IN THREE WAYS.
#   (a) COVERAGE: it bites on a brief whose `WIP:` line carries a REAL ISSUE number in its KEY. Scope, and
#       nothing broader: an `issue-` key that carries no digit inside its first bracket is the canonical
#       slot `issue-<N>` (a CLOSED bracket, which the canonical block ships) and is ADMITTED — the gate
#       cannot refuse its own advice, the same licence the research contract gives its own `<…>` slots.
#       A number OUTSIDE the bracket (`issue-<x> 4242`) leaves the key unparsable and is admitted as the
#       slot too; that adds no capability an author needs (the bare slot already admits), and it is named
#       so the limit can be re-measured rather than trusted. The direction is one-way, not a biconditional:
#       anything swallowed as the slot carries no digit in its first bracket, but not every digit-free
#       value is swallowed (`issue-slot4242`, with no bracket at all, is REFUSED as unkeyed).
#       ⓘ AND A `pr-<digits>` KEY IS NEVER RESOLVED AGAINST `refs/wip/*`: those refs are ISSUE-keyed, so a
#       `pr-` key is accepted for fixer/reviewer roles and its absence claim is unchecked (measured: a
#       fixer brief with `pr-<4242> -> none` and a matching `refs/wip/issue-4242-…` on origin is admitted
#       with no token). That is the same fact this file states later — `issue-<N>` is "the only one the
#       cross-check can resolve" — and it belongs in the limit, not only in the code.
#   (b) MEASUREMENT: it needs a repository and a reachable `origin`. With neither, the gate says so on
#       stderr (the word `UNVERIFIED`, naming the issue) and ADMITS the brief, because refusing
#       every dispatch on a moment's network failure converts a memory gap into a fleet-wide outage.
#       The claim pre-flight on this same dispatch path already hard-depends on that reachability, so
#       the ordinary case is the measured one.
#   (c) NAME, NOT CONTENT: it can prove that a snapshot EXISTS for an issue, never that the snapshot
#       contains the work you need. Reading it is the next actor's job — which is why the line says so.
# The refusal is deterministic and per-issue, so (a) and (b) are boundaries of a real check rather than
# a hopeful one; and `--wip-refs` (the verb `claim-reaper.sh` and `claims.sh` consume) fails CLOSED for
# the handover record, where abstaining costs nothing.

# ── THE SECOND CONTRACT, AND WHY IT LIVES IN THIS FILE (#3442) ───────────────────────────────────
# For role `reviewer` there is a THIRD requirement, on top of the two above:
#
#   3. a `MUTATION ATTRIBUTION` heading (any case, any `#` depth) — for role `reviewer` only —
#      carrying EITHER
#        `NO NEW ASSERTIONS: <why>`   the diff adds no assertion at all, or
#        a table whose header names `assertion`, `mutant` and `reddened`, plus at least one data
#        row with >=3 non-empty cells.
#
# WHY. Review had NO contract requiring that a new assertion CAN FAIL, so a PR could be reviewed
# clean three times on the strength of a guard whose test stays GREEN with the bug restored, and
# nothing on the path noticed. Measured in ONE night across five PRs (agent-infra#3442, and the
# instances are recorded in `docs/ops/review-non-vacuity-baseline.md`):
#   #3355  a liveness leg no `Mutation` ever produced — the CI shard never exercised it
#   #3368  `assert_absent "unbound variable"` stayed GREEN because the fixture set `CELL_HOME`
#   #3368  deleting the whole record-based probe left both gates green on a PREFIX match
#   #3374  a phrase `cell-install.sh` prints UNCONDITIONALLY was grepped from the whole log
#   #3355  `ceiling == 3` could not be reddened — the value is capped regardless
# #3368's own review named the root verbatim: "No mutation leg for the new gate — which is exactly
# how findings 1 and 2 survived three recorded clean reviews." The ABSENCE of the mutation leg is
# not a missing test; it is why the vacuous assertions went undetected.
#
# WHY HERE, AND NOT IN A NEW MODULE. `brief-gate.sh` is already the ONE place a dispatch contract is
# decided, is already presence-required in `check-single-source.sh`'s EXECUTED set, and is already
# installed on every box. A new `mutation-attribution.sh` that the gate SOURCED would put every
# dispatch on that box behind a file nothing installs — the `lane-env.sh` failure (#3060) exactly.
#
# WHY THE VERDICT SIDE READS THIS SAME PARSER. `record-review.sh` refuses to mint a FRESH `clean`
# verdict over a review artifact that carries no such block (`--mutation-missing` below is its
# input). That file is the ONLY place a comment becomes a clean claim, so gating it is what turns
# "the reviewer was told" into "the verdict cannot be minted without it" — the #2258 argument, one
# layer down: a rule that lives only in the brief is exactly as strong as the weakest reviewer.
#
# ⚠️ WHAT THIS BUYS, PRECISELY — the same limit the research contract states, and it must be stated
# or a green run will be read as more than it is. The check is PRESENCE AND SHAPE, never SUBSTANCE:
# it cannot tell a mutant that really reddens the named row from one the author invented, and it
# cannot tell an EQUIVALENT mutant from a killed one (undecidable in general — `cacm.acm.org/research/
# how-do-java-mutation-tools-differ/`, and the classic adoption blocker in the mutation-testing
# literature). What it removes is the measured failure mode: a clean verdict with NO attribution at
# all, which is indistinguishable from a guard nobody ever tried to break.
# ── THE ROUND, AND WHY A GATE NEEDS ONE (#3441) ───────────────────────────────────────────────
# Rounds 1-3 converge on "is this fix correct?" — a question local reading CAN answer. Past round 3
# the loop has stopped converging, and the recurring cause is that we are re-deriving a decision the
# field has already settled, or re-inventing a guard a comparable project has already hardened. So
# from round 4 the brief must carry a `COMPARABLES:` line naming what COMPARABLE / COMPETITOR
# implementations do for the mechanism under review. The round is supplied by the caller
# (`merge-one.sh` derives it from `REV_ROUND` / `state/reviewround-<PR>`), because a brief generator
# with no round input cannot tell round 1 from round 7 — which is the plumbing half of #3441.
#
# ⛔ WHY A LABEL AND NOT A WORD-SEARCH INSIDE `EXTERNAL:` (fresh review of #3441, P1). The first draft
# matched /comparable|competitor/ against the `EXTERNAL:` line — and the CANONICAL BLOCK THIS FILE
# EMITS already says "how comparable systems solve this", so the clause was satisfied by the gate's
# OWN BOILERPLATE for every generated brief at every round. It could not fire on the one path #3441
# exists for: it refused only a hand-written brief that happened to avoid those words — a gate whose
# PASS was supplied by itself. A separate label cannot be satisfied that way: the round>=4 block emits
# it with a placeholder, an earlier round's block does not emit it at all, and the validator requires
# a non-empty value. So the refusal now means something checkable — "this brief was not built for a
# round>=4 review" — which is exactly the missing-round-plumbing defect.
#
# ⚠️ THIS IS STILL A SHAPE CHECK, NOT A CONTENT CHECK. It requires the LABEL and a non-empty value; it
# cannot tell a real survey from a token mention. That is stated here for the same reason RUNG's tool
# vocabulary is: a green run is not evidence the research was good, and the contract's own section says
# so.
#
# ── FAIL-CLOSED, ALWAYS ──────────────────────────────────────────────────────────────────────────
# A missing brief, an unreadable brief, an EMPTY brief, an unknown role, or a validator that cannot
# run all REFUSE. There is no "skip the gate" flag, no environment variable that turns it off, and
# no role that is exempt: a gate a caller can opt out of by omission is not a gate (#1884).
#
# ── WHAT THIS FILE DELIBERATELY DOES NOT DO ─────────────────────────────────────────────────────
# It does not judge the CONTENT — it cannot tell a good research plan from a token one, and pretending
# otherwise would manufacture confidence. It enforces PRESENCE and SHAPE, which is the half a machine
# can actually decide; the orchestrator reviews the substance. Stated here so no reader takes a
# green run as "the research was done".
#
# Exit codes, because callers branch on them (they are NOT interchangeable):
#   0   the brief satisfies the contract
#   80  REFUSED — the brief is deficient, and nothing was started (BRIEF_GATE_REFUSED)
#       ⛔ 80, NOT 74: 74 is AGENT_LAND_BACKLOG (and pi's own EX_IOERR), and sharing it made a
#       land-backlog refusal read as a brief refusal — opposite remedies (#2258 review).
#   78  the gate CANNOT RUN (bad usage / unknown role) — a cannot-verify is never a pass
#
# Callers (one implementation, called from each): `spawn-gate.sh::run_agent` (which covers
# `lane.sh`, `fix-one.sh` and any future caller of the helper), `merge-one.sh`'s own `run_agent`,
# `nonblocking-dispatch.sh` (in the FOREGROUND, before it backgrounds the worker),
# `orch-send.sh`, `safe-send.sh`, and `pr-doctor.py` (which splices `--section` into the brief it
# writes). `brief-gate.test.sh` asserts that set as an EQUALITY, so a dispatch path added tomorrow
# without a gate reddens a test instead of drifting in ungated.
set -u

BRIEF_GATE_REFUSED=80
BRIEF_GATE_UNAVAILABLE=78

# The closed vocabulary a `RUNG:` value must name. Rung 1 = the perplexity MCP; rung 2 = the
# `web_search` tool (model stated explicitly, `sonar`); rung 3 = `web_fetch`. A rung digit
# alone is not a decision — the tool is what makes the plan executable, so both are required.
# ⛔ `exa` is deliberately ABSENT from this vocabulary: the server was uninstalled by owner
# ruling (2026-10-31, "external research should be perplexity"). Named here so the absence
# reads as a decision, not an omission.
# ⚠️ WHAT THAT BUYS, PRECISELY (a review measured the wider claim and it was false): a brief
# whose `RUNG:` line names ONLY `exa` is REFUSED, because no allowed tool is then present.
# The gate checks PRESENCE and SHAPE, never content — a brief naming `exa` ALONGSIDE an
# allowed tool still passes (`RUNG: 3 — web_fetch / exa` → exit 0), and that is correct: it
# also lets a brief mention `exa` solely to prohibit it (`RUNG: 3 — web_fetch (exa is
# uninstalled)`) pass, which a substring ban would wrongly refuse. So the vocabulary makes
# `exa` an unusable ROUTE, not a forbidden WORD. See "WHAT THIS FILE DELIBERATELY DOES NOT
# DO" above; the prohibition itself lives in the research skill and the owner's ruling.
BRIEF_GATE_TOOLS='perplexity, web_search, web_fetch, context7'

# The review round from which a review brief must carry a `COMPARABLES:` line (#3441).
# Owner ruling, 2026-11-04: past round 3 the question changes from "does this line work" to "what does
# the field do", so the mandate starts at 4.
BRIEF_GATE_COMPARABLE_ROUND=4

# brief_gate_round_norm <value> — a round is a positive integer or it is 0 (unknown).
# ⛔ NEVER default an unreadable round to 1 in a way that would let a round-7 brief claim round 1: every
# coercion treats anything non-numeric as UNKNOWN (0), so a caller that loses the round never has it
# silently upgraded by this function.
# ⛔ BUT `0` IS BELOW THE THRESHOLD, SO THE COMPARABLE MANDATE IS SKIPPED AT UNKNOWN — state that
# plainly, because it is a RESIDUAL, not a protection (round 4 review, P2). The earlier text here
# claimed the opposite — "UNKNOWN is checked for the comparable clause as well — a caller that loses
# the round does not thereby buy the round-3 contract" — and that is FALSE: the validator is
# `(gr_round + 0) >= (gr_cmp + 0)`, so 0 >= 4 is false and no `EXTERNAL-COMPARABLES` is demanded.
# Measured: `--missing <file> reviewer` and `--missing <file> reviewer banana` both print no such
# token. The sibling arm comment by NAME ("ROUND ≥ 4 REQUIRES THE COMPARABLE CLAUSE", in
# `BRIEF_GATE_AWK` below — cited by name, never by line: round 5 review, P3, an earlier cite of
# `:~215` was already stale when it was written) and `brief-gate.test.sh` pin the REAL behaviour. A
# false sentence is bad on its own, but
# this one asserts a fail-open protection for a gate — a lane reading it would think deleting the
# residual arms is safe, which is the missing-plumbing class #3441 exists to close. Reachability is
# what bounds it: `merge-one.sh` always supplies the round for a review, so UNKNOWN is not a state any
# harness review path reaches.
# ⛔ NINE DIGITS, THE `is_limit` BOUND, because `$(( 10#… ))` on a longer value WRAPS INTO A NEGATIVE
# number (fresh review of #3441, P2: 9223372036854775808 -> -9223372036854775808). A negative round is
# neither 0 nor >= the threshold, so it would slip past the mandate — the exact fail-open arithmetic
# class this tree's `is_limit` exists for. No harness path produces one today, and ⛔ THE BOUND IS NOT A
# PROTECTION FOR THE MANDATE (round-15 review, P3 — this sentence used to claim exactly that, twelve
# lines after the block above calls the same value a RESIDUAL): it coerces a malformed round
# DETERMINISTICALLY TO UNKNOWN (0), and `0 >= 4` is false, so the round-4 mandate is SKIPPED either way.
# What the bound buys is that the skip is a named, testable state (`(round-bound)` in
# `brief-gate.test.sh` asserts `rc=0`) instead of an arbitrary wrapped integer. Claiming otherwise
# would tell a lane the opposite of what the code does — the false-sentence class this file's own
# comments were corrected for twice.
brief_gate_round_norm() { # <value> -> integer (0 = unknown)
  case "${1:-}" in
    ''|*[!0-9]*) printf '0\n' ;;
    *)
      if [ "${#1}" -le 9 ]; then printf '%s\n' "$(( 10#${1} ))"; else printf '0\n'; fi ;;
  esac
}

# brief_gate_missing <brief-file|-> [role] [round] — print ONE token per missing element, nothing
# when complete. `-` reads stdin (pane orders are passed inline, not as files). An unreadable or empty
# brief prints NO-FILE / EMPTY rather than pretending the parse failed for some subtler reason.
#
# ⛔ THE PARSE IS ONE awk PASS ON PURPOSE. It is the same shape #2148's suite drives and it needs no
# python at dispatch time — a gate that adds an interpreter to every spawn is a gate that will
# eventually be "temporarily" worked around on the box that lacks one.
brief_gate_missing() { # brief_gate_missing <brief-file|-> [role] [round]
  local f="${1:--}" role="${2:-lane}" rnd toks="" body=""
  rnd="$(brief_gate_round_norm "${3:-0}")"
  if [ "$f" != "-" ] && { [ ! -e "$f" ] || [ ! -r "$f" ]; }; then
    printf 'NO-FILE\n'
    return 0
  fi
  if [ "$f" = "-" ]; then
    # ⛔ STDIN IS READ ONCE, HERE, AND RE-FED TO EVERY PASS. Two awks reading `-` in sequence would
    # leave the second one at EOF, and a role that needs both contracts would then report the first
    # as satisfied and the second as absent on the SAME input — a refusal that depends on how many
    # times the caller happened to pipe the brief. (The trailing newline is restored because command
    # substitution strips it, and awk drops a final line that carries none.)
    body="$(cat)"
    if [ -z "$body" ]; then printf 'EMPTY\n'; return 0; fi
    toks="$(printf '%s\n' "$body" | awk -v gr_role="$role" -v gr_round="$rnd" -v gr_cmp="$BRIEF_GATE_COMPARABLE_ROUND" "$BRIEF_GATE_AWK")"
    [ -z "$toks" ] || printf '%s\n' "$toks"
    if [ "$role" = "reviewer" ]; then printf '%s\n' "$body" | awk "$BRIEF_GATE_MUTATION_AWK"; fi
  else
    if [ ! -s "$f" ]; then printf 'EMPTY\n'; return 0; fi
    toks="$(awk -v gr_role="$role" -v gr_round="$rnd" -v gr_cmp="$BRIEF_GATE_COMPARABLE_ROUND" "$BRIEF_GATE_AWK" "$f")"
    [ -z "$toks" ] || printf '%s\n' "$toks"
    if [ "$role" = "reviewer" ]; then awk "$BRIEF_GATE_MUTATION_AWK" "$f"; fi
  fi
}

# ── PREVIOUS WORK (#3484): the ONE reader of `refs/wip/*`, and the contradiction check ──────────
# `BRIEF_GATE_WIP_AWK` prints the VALUE of the `WIP:` line of the PREVIOUS WORK section (and nothing
# else), so the cross-check and the shape check can never disagree about which line is the claim.
# Two consumers read this file's ref matcher — this gate, and `--wip-refs` (called by
# `claim-reaper.sh` and `claims.sh::claim_prune` for the handover line). ⛔ ONE DEFINITION, because two
# matchers would drift and the drift would be invisible: a ref the gate matched and the reaper did not
# is a handover that silently stops being reported.
# shellcheck disable=SC2016
BRIEF_GATE_WIP_AWK='
# ⛔ QUOTED MATERIAL IS NOT A CLAIM — the rule the NON-VACUITY parser states, applied to BOTH carrier
# contracts as well (fresh-context review of #3484, P1). Without it a brief could satisfy the WHOLE
# PREVIOUS WORK block by pasting the canonical block inside a fence, and the cross-check would then read
# the QUOTED `issue-<N> -> refs/wip/<ref>` as the author’s own claim and switch itself off — a
# fail-open in the one machine check this change adds. Indentation is measured in COLUMNS (a TAB is the
# next 4-column stop), because four columns is an indented CODE BLOCK to every renderer.
# Returns the content of `s` after its leading whitespace, or a sentinel for an indented code block.
function _qskip(s,   col, ln, q, c, tw, ind) {
  col = 0; ind = 0; ln = length(s)
  for (q = 1; q <= ln; q++) {
    c = substr(s, q, 1)
    if (c == " ") { col++; ind++; continue }
    if (c == "\t") { tw = 4 - (col % 4); col += tw; ind += tw; continue }
    break
  }
  if (ind >= 4) return "\001"
  return substr(s, q)
}
# ⛔ A FENCE IS CLOSED ONLY BY ITS OWN CHARACTER, IN A RUN AT LEAST AS LONG, AND WITH NO INFO STRING —
# the three CommonMark rules the NON-VACUITY parser already had to learn twice. Sets `fence`.
function _fence(s,   fc, fl, q, rest) {
  fc = substr(s, 3, 1)
  fl = 0
  for (q = 3; substr(s, q, 1) == fc; q++) fl++
  rest = substr(s, q)
  if (!fence) { fence = 1; fencec = fc; fencelen = fl }
  else if (fc == fencec && fl >= fencelen && rest ~ /^[ \t]*$/) fence = 0
  return 1
}
function _strip(s) { sub(/^[ \t]+/, "", s); sub(/^[-*+][ \t]+/, "", s); sub(/^[0-9]+[.)][ \t]+/, "", s);
  sub(/^(\*\*|__)/, "", s); sub(/^[ \t]+/, "", s); return s }
BEGIN { ins = 0; depth = 0; val = ""; _n = 0; fence = 0; fencec = ""; fencelen = 0 }
{
  line = _qskip($0)
  if (line == "\001") next
  if (match(line, /^(```|~~~)/)) { _fence(line); next }
  if (fence) next
  lc = tolower(line); nh = 0
  if (lc ~ /^#+/) { match(lc, /^#+/); nh = RLENGTH }
  if (ins && nh > 0 && nh <= depth) ins = 0
  if (!ins && nh > 0 && lc ~ /^#+[ \t]*previous[ -]work/) { ins = 1; depth = nh; next }
  if (!ins) next
  t = _strip(line)
  # ⛔ THE SAME RECOGNIZER AS THE SHAPE PARSER, OR THE TWO DISAGREE AND THE GATE FAILS OPEN
  # (review cycle 3, P1). `_label` folds `[ \t-]+` into one space and strips it, so `WIP-:`, `WIP --:`,
  # `WIP- :` are all the `wip` LABEL to the shape check — while this reader required `^wip[ \t]*:` and
  # therefore collected NOTHING, so the cross-check abstained and the brief was ADMITTED with an
  # unchecked claim of absence (measured: `WIP-: issue-4242 -> none` → rc 0 against an existing ref).
  # ⛔ THE CLASS IS EXACTLY THE SEPARATORS `_label` FOLDS — SPACE AND HYPHEN — AND NOTHING ELSE (review of
  # #3621, cycle 3, P3: the first version also spanned `_`, which `_label` never folds, so `WIP_:` was
  # collected by this reader while the shape parser saw no `wip` label at all — the "line this reader
  # collected and that parser ignored" the sentence above calls a new disagreement, two lines below it).
  # TAB is excluded for a DIFFERENT reason, and it is worth stating precisely (review of #3621, P2 —
  # the earlier text here claimed `_label` reads `WIP<TAB>:` as `wip`, which it does NOT: the label
  # class of `_label` is `[A-Za-z][A-Za-z0-9 _-]`, so a TAB before the colon matches NO label at all, and
  # a TAB-label brief is refused by the SHAPE parser for having no `WIP:` line — measured
  # `PREVIOUS-WORK-WIP` with NO `CONTRADICTED` token, while the identical colon-label brief is ADMITTED
  # at rc 0). So the guarantee here is the LABEL CLASS, NOT a fold: `_label` folds `[ \t-]+` only AFTER
  # it has matched, so teaching that class to span `\t` (a plausible "make the two readers agree" edit)
  # would let the shape parser see `wip` while the `[ -]*` of this reader still spans no TAB — shape
  # satisfied, reader silent, absence claim ADMITTED. That is the #3484 fail-open, so the class and this
  # reader move together or not at all. (H63/H63b/H63c/H63d pin the TAB spellings.)
  if (tolower(t) ~ /^wip[ -]*:/) {
    sub(/^[^:]*:/, "", t)
    sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
    # …and the value is measured UNDRESSED, for the reason given in the `_label` comment above a
    # decorated label must not turn an honest `issue-<N> -> none` into an unkeyed value.
    gsub(/^[*_`]+/, "", t); gsub(/[*_`]+$/, "", t)
    sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
    _v[++_n] = t
  }
}
# ⛔ EVERY `WIP:` VALUE, one per line, prefixed `V<TAB>` — the earlier "last one wins" shape made the
# cross-check trivially bypassable: append a second `WIP:` line (unfenced, and the canonical block IS
# such a line) and the checker abstained on it while the shape check was satisfied by the first.
END { for (_i = 1; _i <= _n; _i++) printf "V\t%s\n", _v[_i] }
'

# brief_gate_repo [explicit] — WHICH repository `refs/wip/*` is read from. Resolution, in order:
#   1. the caller's explicit argument (a dispatch path that knows its repo should pass it);
#   2. `$CLAIM_REPO` — the claim registry's own repository resolution (claims.sh). ⛔ NOT a disable
#      switch: it SELECTS the repository measured, and an unusable value degrades to UNMEASURED, the
#      same direction as passing nothing;
#   3. `$REPO` — the controller's repo variable, present in the shells that dispatch lanes;
#   4. `git rev-parse --show-toplevel` of the cwd, which is the truth inside a worktree.
# Prints the path, or nothing when none is usable (the caller then reports UNMEASURED, never "none").
brief_gate_repo() { # brief_gate_repo [explicit]
  local r="${1:-}"
  # ⛔ AN EXPLICIT PATH IS TAKEN STRICTLY: a caller that names a repository it then cannot measure gets
  # UNMEASURED, never a silent fallback to some other tree. Falling back here would let a typo in a
  # dispatch path quietly measure a DIFFERENT repo and report "no rescued WIP" about it.
  if [ -n "$r" ]; then
    if [ -d "$r" ]; then printf '%s\n' "$r"; fi
    return 0
  fi
  r="${CLAIM_REPO:-}"
  [ -n "$r" ] || r="${REPO:-}"
  if [ -n "$r" ] && [ -d "$r" ]; then printf '%s\n' "$r"; return 0; fi
  git rev-parse --show-toplevel 2>/dev/null
  return 0
}

# brief_gate_wip_refs <issue> [repo] — every `refs/wip/*` ref that BELONGS TO issue <issue>, one
# `<ref>\t<sha12>` per line on stdout.
# Exit: 0 the remote answered (an EMPTY answer is a real answer: no ref for this issue), 2 UNMEASURED
#       (no repository, no issue, or `git ls-remote` could not answer — never a pass, never "none").
# ⛔ THE MATCH IS THE DECLARED NAMING RULE — AND IT IS LITERALLY THE ONE #3382 ALREADY PUBLISHES.
# `refs/wip/<slug>` belongs to issue N iff N is a HYPHEN-DELIMITED SEGMENT of <slug>
# (`ai-3194` -> yes; `ai-31940` -> no; `fix-3442-nonvacuity` -> yes). That is verbatim
# `mcp-servers/orchestrator/server.py`'s `match_rule` (`str(issue) in slug.split("-")`), so the typed
# saved-work tool and this gate cannot disagree about which snapshots belong to an issue. Written as a
# segment comparison rather than a substring test on purpose: a substring would over-match
# (`fix-4242a`) and the two surfaces would then answer the same question differently.
# The rule is deliberately LOOSE about the prefix, because the 222 archives that already exist are
# named from the BRANCH (`fix-3442`, `ai-3194`, `fix-3442-nonvacuity`): a strict `issue-<N>-` prefix
# match would report every one of them as unlinked and the reader would be blind to the whole
# population it exists for. `bg-rescue-wip.sh` now writes the `issue-<N>-` form for new rescues — which
# this rule also matches, so both families are covered by one rule.
# brief_gate_bounded <secs> <cmd...> — run <cmd> under the repo ONE portable time bound (#2046),
# printing its stdout and returning its status, or 124 on a timeout.
# ⛔ IT NEVER FALLS BACK TO AN UNBOUNDED NETWORK CALL (fresh-context review of #3484, P2). The first
# draft used `timeout` when present and the BARE call otherwise — on macOS, where `timeout` ships
# nowhere and this harness runs, a black-holed origin would stall every dispatch that carries a keyed
# absence claim, with no bound at all. That is the exact defect `scripts/lib/bounded.sh` exists for, so
# the bound comes from there (one place, one order: `timeout` -> `gtimeout` -> its internal watchdog).
# With NO bounded mechanism available the answer is rc 2 — UNMEASURED, never a hang and never a pass.
brief_gate_bounded() { # brief_gate_bounded <secs> <cmd...>
  local secs="${1:-20}"; shift
  if [ -z "${BRIEF_GATE_BOUNDED_TRIED:-}" ]; then
    BRIEF_GATE_BOUNDED_TRIED=1
    local c here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    # ⛔ NO `${O:-}` ROOT (review cycle 2, nit): `O` is the orchestrator STATE root (`$O/state/...`),
    # not a scripts root — a candidate that can only ever hit the wrong tree, tried first, so a state
    # dir that happened to contain `lib/bounded.sh` would shadow the repo's own copy.
    for c in "$here/lib/bounded.sh" \
             "${AGENT_INFRA_PATH:-}/scripts/lib/bounded.sh" \
             "${HOME:-}/.pi/agent/scripts/lib/bounded.sh"; do
      [ -n "$c" ] && [ -f "$c" ] || continue
      # shellcheck source=/dev/null
      . "$c" >/dev/null 2>&1 && break
    done
  fi
  declare -f tb_timeout >/dev/null 2>&1 || return 2
  tb_resolve_timeout >/dev/null 2>&1 || return 2
  local out rc
  out="$(tb_timeout "$secs" "$@" 2>/dev/null)"; rc=$?
  tb_watchdogs_reap >/dev/null 2>&1 || :
  tb_bound_cleanup >/dev/null 2>&1 || :
  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

brief_gate_wip_refs() { # brief_gate_wip_refs <issue> [repo]
  local issue="${1:-}" repo="${2:-}" out rc
  case "$issue" in ''|*[!0-9]*) printf '[brief-gate] --wip-refs needs an ISSUE NUMBER (got "%s")\n' "$issue" >&2; return 2 ;; esac
  repo="$(brief_gate_repo "$repo")"
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    printf '[brief-gate] --wip-refs: no repository to read refs/wip from (repo=%s)\n' "${repo:-<none>}" >&2
    return 2
  fi
  # ⛔ ABSOLUTISE BEFORE ANY `cd` (fresh-context review of #3484, P2). `claims.sh` supports
  # `CLAIM_REPO="."` (a caller standing at a work-tree root), and a relative path resolved AFTER the
  # caller moved to a neutral cwd points somewhere else entirely — measured: `.` became `/tmp`, the
  # listing failed, and the handover line read UNMEASURED on a box whose origin answered fine.
  repo="$(cd "$repo" 2>/dev/null && pwd)" || repo=""
  if [ -z "$repo" ]; then
    printf '[brief-gate] --wip-refs: the repository path could not be resolved\n' >&2
    return 2
  fi
  out="$(brief_gate_bounded 20 git -C "$repo" ls-remote --refs origin 'refs/wip/*')"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[brief-gate] --wip-refs: `git ls-remote origin refs/wip/*` could not answer (rc=%s) in %s — UNMEASURED (unknown is not zero)\n' "$rc" "$repo" >&2
    return 2
  fi
  printf '%s\n' "$out" | awk -v n="$issue" '
    NF >= 2 && $2 ~ /^refs\/wip\// {
      slug = $2; sub(/^refs\/wip\//, "", slug)
      k = split(slug, seg, "-")
      for (i = 1; i <= k; i++) if (seg[i] == n) { printf "%s\t%s\n", $2, substr($1, 1, 12); break }
    }'
  return 0
}

# brief_gate_previous_work <brief-file|-> [repo] [role] — print the tokens the cross-check contributes:
# `PREVIOUS-WORK-WIP` once when ANY `WIP:` value is unkeyed for this role, and
# `PREVIOUS-WORK-WIP-CONTRADICTED<TAB>refs…` once when any issue that claims absence has a matching ref.
# Nothing when the block is consistent, unmeasurable-but-usable, or when the shape tokens already speak.
#
# ⛔ THE ABSENCE CLAIM IS THE PART *AFTER* THE KEY, NOT THE WHOLE LINE — and this is the shape the
# first draft got wrong. Reading the whole value for a `refs/wip/` substring made the MOST natural
# honest line (`issue-4242 -> none (measured: git ls-remote refs/wip/* at …)`) look like a named ref,
# so the check silently skipped exactly the briefs that did the measurement properly. The value is
# `issue-<N> -> <claim>`, and the claim is what decides: it begins `refs/wip/` ⇒ a ref is named;
# anything else (`none`, `unclaimed`, `nothing`, `-`, `refs/wip/* is empty`, a half-finished sentence)
# ⇒ a claim of absence, which is then CHECKED. No word list to defeat, no measurement note that can
# switch it off, and a GLOB is not a ref.
brief_gate_previous_work() { # brief_gate_previous_work <file|-> [repo] [role]
  local f="${1:--}" repo="${2:-}" role="${3:-lane}" values val vlow tag claim rest issue ref nval inner after tail num head
  local unkeyed=0 issues="" evidence=""
  values="$(awk "$BRIEF_GATE_WIP_AWK" "$f" 2>/dev/null)"
  [ -n "$values" ] || return 0            # no WIP line at all: the SHAPE token already refuses
  # ── EVERY VALUE IS CHECKED, NOT THE LAST ONE (fresh-context review of #3484, P1) ──────────────
  # The shapes that defeated the "last one wins" reader, all measured: a pasted canonical block (a live,
  # unfenced `WIP: issue-<N> -> refs/wip/<ref>` line — i.e. THE TEXT THIS GATE HANDS THE AUTHOR), a
  # trailing `WIP: none`, a bare `WIP:` label, and a second keyed line for a different issue. Each one
  # made the checker abstain on the wrong line while the shape check stayed satisfied.
  while IFS=$'\t' read -r tag val; do
    [ "${tag:-}" = "V" ] || continue
    if [ -z "${val:-}" ]; then unkeyed=1; continue; fi
    # ⛔ THE KEY IS FOLDED TOO (review of #3621, nit). The LABEL was already case-insensitive
    # (`_label` lowercases), so `WIP: Issue-4242 -> none` was refused while `WIP:` was accepted — an
    # asymmetry no author can be expected to guess. `vlow` is what every key and claim test reads.
    vlow="$(printf '%s' "$val" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
    # ── ONE NORMALISATION, THEN ONE CLASSIFICATION, THEN ONE CLAIM READ (review of #3621, cycles 2-4)
    # Three rounds found the same shape of bug in three spellings: an arm per key form meant that every
    # form the arms did not name fell through to the unfilled-slot branch and was keyed-but-UNCHECKED
    # (`issue-<4242>`, then `issue-<#4242>`, then a bracket with no `>` at all). So the bracket forms are
    # canonicalised FIRST, into the plain `issue-<digits> -> <claim>` shape, and only then classified.
    # ⛔ AND THE NUMBER IS THE FIRST DIGIT RUN, NOT EVERY DIGIT (review of #3621, cycle 4, P1): deleting
    # all non-digits CONCATENATED them, so `issue-<#4242 (prev attempt #1234)> -> none` was measured as
    # `42421234` — a key that does not exist, which ADMITTED the very claim it should refuse.
    # ⛔ THE KEY PART IS CUT AT THE ARROW BEFORE THE BRACKET IS LOOKED FOR (review of #3621, cycle 5). The
    # bracket search must not see the `-` AND `>` of the arrow: with the whole value in hand, the canonical
    # `issue-<N> -> refs/wip/<ref>` was read as a CLOSED bracket whose content is `n` — i.e. malformed —
    # and the gate refused its own canonical block. Everything before the first arrow is the key.
    nval="$vlow"
    head="${nval%%->*}"
    head="${head%%→*}"
    case "$head" in
      issue-"<"*">"*|pr-"<"*">"*)
        # ⛔ THE TAIL IS WHAT FOLLOWS THE BRACKET CLOSE, NOT WHAT FOLLOWS THE ARROW (review of #3621,
        # cycle 8, P2). ⛔ THE MECHANISM BELOW WAS STATED BACKWARDS UNTIL CYCLE 12 AND IS NOW MEASURED:
        # the ARROWED spelling is the one that breaks, NOT the arrow-less one. `head` stops at the arrow,
        # so deriving the tail from it truncates the claim on `issue-<4242> -> refs/wip/<ref>` to a bare
        # space, leaving `claim` empty and REFUSING an honest brief with "read the ref you already
        # named" (measured: shipped rc 0 → 80 under `${head#*>}`, reddening H55d and all four H57c
        # spellings). The ARROW-LESS spelling is INERT under that same mutant — with no arrow `head` IS
        # the whole value, so H62 stays green and must NOT be cited as its proof (cycle 12 review).
        # Cutting at the bracket handles both spellings; an UNTERMINATED bracket leaves no trustworthy
        # claim text and is treated as an absence claim, which is the fail-closed direction.
        after="${nval#*-<}"
        inner="${after%%>*}"
        # `after` always contains a `>` here — the arm was entered on `head`, which already held one, and
        # `head` is a prefix of `nval` — so this needs no fallback branch (review of #3621, cycle 9: the
        # `*) tail=""` arm was unreachable, and saying so is cheaper than a reader re-deriving it).
        tail="${after#*>}"
        num="$(printf '%s' "$inner" | sed -E 's/^[^0-9]*//; s/[^0-9].*$//')"
        case "$head" in
          # ── WHAT THIS ARM DECIDES, ONCE (review of #3621, cycle 6: an earlier draft of this comment said
          # the opposite two lines apart and repeated its rationale).
          # 1. A bracket carrying a NUMBER anywhere inside it is KEYED BY THAT NUMBER — the first digit run,
          #    never the concatenation of every run (a key that does not exist measured nothing, cycle 4).
          # 2. A bracket carrying NO DIGITS is the UNFILLED SLOT (`issue-<N>` — a CLOSED bracket — is
          #    exactly what the canonical block ships, so this case must be admitted: the gate cannot
          #    refuse its own advice). The coverage limit is therefore "no digit inside the key's first
          #    bracket", not "no number anywhere in the value" — a number OUTSIDE the bracket (`issue-<x>
          #    4242`) leaves the key unparsable and the value is treated as the slot.
          # 3. The number is joined to the tail WITH A SEPARATOR, and it IS load-bearing — on ONE carrier
          #    shape, which has to be NAMED or the attribution reads as false (cycle 12 review tried the
          #    revert on `issue-<4242> -> none`, whose tail already BEGINS with the arrow's space, found it
          #    inert, and reported the citation as non-reproducing — that is simply not the carrier).
          #    The carrier is a number glued DIRECTLY after the closing bracket, i.e. H61's own
          #    `issue-<4242>4242> -> none`: there `tail` is `4242> -> none (…)`, so without the separator
          #    the key is the CONCATENATION `42424242` — a key that does not exist — and the contradicted
          #    claim is ADMITTED (measured: base 80 → separator-revert 0, reddening
          #    H61['issue-<4242>4242>'] and nothing else in the suite). The two lines are a PAIR: the
          #    revert of `tail` alone is INERT here (`${nval#*>}` ≡ `${after#*>}`, since `after` always
          #    holds the bracket close). What `tail`'s derivation decides is the ARROWED spelling — the
          #    `tail` paragraph above, H55d/H57c — not the arrow-less one.
          issue-*) if [ -n "$num" ]; then nval="issue-$num $tail"; else nval="issue-slot"; fi ;;
          *)       if [ -n "$num" ]; then nval="pr-$num $tail";    else nval="pr-slot";    fi ;;
        esac ;;
      issue-"<"*|pr-"<"*)
        # an UNTERMINATED bracket still carries a number: key it, and treat the rest as an ABSENCE claim
        # (we cannot parse a named ref out of it reliably, and refusing is the fail-closed direction).
        num="$(printf '%s' "${head#*-<}" | sed -E 's/^[^0-9]*//; s/[^0-9].*$//')"
        case "$head" in
          issue-*) if [ -n "$num" ]; then nval="issue-$num ->"; else nval="issue-slot"; fi ;;
          *)       if [ -n "$num" ]; then nval="pr-$num ->";    else nval="pr-slot";    fi ;;
        esac ;;
    esac
    issue=""
    case "$nval" in
      issue-[0-9]*) issue="${nval#issue-}"; issue="${issue%%[!0-9]*}" ;;
      # ⛔ THE SLOT SENTINEL IS MATCHED EXACTLY, NOT AS A PREFIX (review of #3621, cycle 5, P3). `issue-slot*`
      # also matched `issue-slot4242` — an author-spellable route to the unchecked arm WITH a number in it,
      # i.e. the hole this whole file exists to close, two lines after a comment promising it cannot be
      # reached. Only the bare sentinel, which no `issue-<digits>`/bracket form can normalise to, is a slot.
      issue-slot)  : ;;
      pr-slot)     case "$role" in fixer|reviewer) : ;; *) unkeyed=1 ;; esac ;;
      pr-[0-9]*)   case "$role" in fixer|reviewer) : ;; *) unkeyed=1 ;; esac ;;
      # ⛔ ANY WHITESPACE SEPARATES `keyless` FROM ITS REASON — NOT JUST A SPACE (cycle 12 review, P2;
      # carrier corrected in cycle 13, after the first version of this comment cited a predicate that no
      # longer exists at this head). WHAT THE BASE DID: on `origin/main` the ONLY key test was the SHAPE
      # parser's `_rest ~ /^keyless[ \t]+[^ \t]/` — whitespace-general — so `keyless<TAB>— why` was
      # ADMITTED (rc 0). `1519642ff` deleted that test and made THIS classifier the sole authority, and
      # the arm it introduced required a literal space, so the move NARROWED a spelling the base
      # accepted: measured on byte-identical briefs, `origin/main` rc 0 versus the cycle-11 head rc 80 —
      # UNKEYED, with a diagnostic about the key, for a brief whose key is the documented third form.
      # The predicate below is that base test, carried into the only reader there is — separator, then
      # real text after it — so `keyless` and `keylessfoo` stay REFUSED, the direction that matters.
      # ⛔ IT IS DELIBERATELY STRICTER THAN THE BASE ON ONE EXOTIC CARRIER: main's `[^ \t]` treated a lone
      # VT/FF as a "reason", this arm does not (measured `keyless  <VT>` → main 0, here 80). That is the
      # fail-CLOSED direction — whitespace is not a reason — and it is recorded here so a later reader
      # does not "restore parity" by widening it back.
      # H51c is the ADMIT row. H51d is the parity row: a separator followed by WHITESPACE ONLY must still
      # be refused — and its carrier has to be a byte the value reader's trailing trim KEEPS. That trim is
      # `[ \t]+` (the WIP awk above), so a space/tab-only value collapses to bare `keyless` and asserts
      # nothing new — which is exactly why the FIRST version of H51d was vacuous. ⛔ THAT PROVENANCE IS
      # TWO STEPS, NOT ONE (checked against this PR's own review record): the row was ADDED by the
      # cycle-12 fix round, whose finding 3 was the `keyless<TAB>` false block; it was then found VACUOUS
      # by the cycle-13 review's finding 2, which deleted it — and the cycle-14 delta review's finding 1
      # restored it with a carrier the trim keeps. An earlier wording cited "cycle 12 finding 2" for the
      # vacuity, and that finding is the SEPARATOR citation, a different finding in a different cycle.
      # CR survives the trim and really does arrive here as whitespace-only, so H51d uses CR: with it, the
      # plausible-simplification mutant `[[:space:]]*[![:space:]]*` → `[[:space:]]*` is KILLED
      # (`keyless<CR>` 80 → 0) while the bare-`keyless` row alone cannot kill it (80 → 80, measured).
      keyless*)
        rest="${nval#keyless}"
        case "$rest" in [[:space:]]*[![:space:]]*) : ;; *) unkeyed=1 ;; esac ;;
      *) unkeyed=1 ;;
    esac
    [ -n "$issue" ] || continue
    # the claim is what FOLLOWS the key, so a measurement note that mentions `refs/wip/*` is still a
    # claim of absence (an earlier draft read the whole value and switched itself off)
    rest="${nval#issue-}"
    rest="${rest#*>}"
    rest="${rest#"$issue"}"
    # ⛔ ERE, NOT GNU's `\|` (review cycle 3, P2). BSD sed — macOS, where install.sh and launchd run —
    # does not implement `\|` in a BRE, so this substitution was INERT there: the arrow stayed in
    # `claim`, the claim no longer began `refs/wip/`, and an HONEST brief that named its ref was
    # falsely REFUSED on the exact platforms the fleet runs on while Linux stayed green.
    # ⛔ THE ARROW IS OPTIONAL, AND THE `?` IS LOAD-BEARING ON THE **PLAIN** PATH (measured, review of
    # #3621 cycles 3-4 — both earlier wordings of this comment had it inverted). After the key strip the
    # PLAIN form `issue-4242 -> refs/wip/x` has already had its `->` consumed by the `#*>` step and keeps
    # a LEADING SPACE, which a required-arrow sed does not remove — `refs/wip/<ref>` then fails the
    # `case` below and an HONEST named ref is read as a CLAIM OF ABSENCE (mutant: delete the `?` and
    # H16/H35/H50/H53b all redden, measured). The bracket forms are normalised above, so they arrive here
    # in the plain shape.
    claim="$(printf '%s' "$rest" | sed -E 's/^[[:space:]]*(->|→|:)?[[:space:]]*//')"
    # ⛔ A GLOB IS NOT A REF (review of #3621, P2). `refs/wip/* is empty` begins with `refs/wip/` and
    # was therefore read as "a ref is named", so the most honest possible way to say "I looked and there
    # is nothing" switched the check OFF — measured rc 0 with a matching ref on origin, on the merged
    # baseline too. A named ref must be a CONCRETE token: the word after `refs/wip/` non-empty and free
    # of glob characters, or the value is a claim of absence.
    case "$claim" in
      refs/wip/*)
        ref="$(printf '%s' "${claim#refs/wip/}" | sed -E 's/[[:space:]].*$//')"
        case "$ref" in ''|*'*'*|*'?'*|*'['*) issues="${issues:+$issues }$issue" ;; esac ;;
      *) issues="${issues:+$issues }$issue" ;;
    esac
  done <<< "$values"
  [ "$unkeyed" -eq 0 ] || printf 'PREVIOUS-WORK-WIP\n'
  [ -n "${issues// /}" ] || return 0
  repo="$(brief_gate_repo "$repo")"
  if [ -z "$repo" ] || [ ! -d "$repo" ]; then
    printf '[brief-gate] PREVIOUS WORK: refs/wip was NOT measured (no repository resolvable from here) — admitting the brief; the claim that #%s has no rescued WIP is UNVERIFIED.\n' "$(printf '%s' "$issues" | tr ' ' ',')" >&2
    return 0
  fi
  for issue in $(printf '%s\n' $issues | sort -u); do
    refs="$(brief_gate_wip_refs "$issue" "$repo" 2>/dev/null)"; local rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '[brief-gate] PREVIOUS WORK: refs/wip could not be read for #%s — the claim that none exists is UNVERIFIED (admitted; see --wip-refs).\n' "$issue" >&2
      continue
    fi
    rest="$(printf '%s\n' "$refs" | awk 'NF >= 1 { printf "%s%s", (n++ ? "," : ""), $1 }')"
    [ -n "$rest" ] && evidence="${evidence}${evidence:+, }${rest}"
  done
  [ -n "$evidence" ] && printf 'PREVIOUS-WORK-WIP-CONTRADICTED\t%s\n' "$evidence"
  return 0
}

# brief_gate_mutation_missing <brief-or-artifact-file|-> — the NON-VACUITY contract alone (#3442),
# with NO research requirement. This is the verb `record-review.sh` calls on a review ARTIFACT: an
# artifact is not a brief, so asking it for `RESEARCH FIRST` would refuse every honest review. One
# parser, two consumers, so the shape the brief teaches and the shape the record demands cannot
# drift apart.
brief_gate_mutation_missing() { # brief_gate_mutation_missing <file|->
  local f="${1:--}"
  if [ "$f" != "-" ] && { [ ! -e "$f" ] || [ ! -r "$f" ]; }; then
    printf 'NO-FILE\n'
    return 0
  fi
  if [ "$f" = "-" ]; then
    awk "$BRIEF_GATE_MUTATION_AWK"
  else
    awk "$BRIEF_GATE_MUTATION_AWK" "$f"
  fi
}

# The awk program, kept in a variable so the CLI and the sourced path cannot drift. Globals set by
# `_label`: `_lab` (lowercased label) and `_rest` (the value after the colon).
# shellcheck disable=SC2016
BRIEF_GATE_AWK='
# ⛔ QUOTED MATERIAL IS NOT A CLAIM — the rule the NON-VACUITY parser states, applied to BOTH carrier
# contracts as well (fresh-context review of #3484, P1). Without it a brief could satisfy the WHOLE
# PREVIOUS WORK block by pasting the canonical block inside a fence, and the cross-check would then read
# the QUOTED `issue-<N> -> refs/wip/<ref>` as the author’s own claim and switch itself off — a
# fail-open in the one machine check this change adds. Indentation is measured in COLUMNS (a TAB is the
# next 4-column stop), because four columns is an indented CODE BLOCK to every renderer.
# Returns the content of `s` after its leading whitespace, or a sentinel for an indented code block.
function _qskip(s,   col, ln, q, c, tw, ind) {
  col = 0; ind = 0; ln = length(s)
  for (q = 1; q <= ln; q++) {
    c = substr(s, q, 1)
    if (c == " ") { col++; ind++; continue }
    if (c == "\t") { tw = 4 - (col % 4); col += tw; ind += tw; continue }
    break
  }
  if (ind >= 4) return "\001"
  return substr(s, q)
}
# ⛔ A FENCE IS CLOSED ONLY BY ITS OWN CHARACTER, IN A RUN AT LEAST AS LONG, AND WITH NO INFO STRING —
# the three CommonMark rules the NON-VACUITY parser already had to learn twice. Sets `fence`.
function _fence(s,   fc, fl, q, rest) {
  fc = substr(s, 3, 1)
  fl = 0
  for (q = 3; substr(s, q, 1) == fc; q++) fl++
  rest = substr(s, q)
  if (!fence) { fence = 1; fencec = fc; fencelen = fl }
  else if (fc == fencec && fl >= fencelen && rest ~ /^[ \t]*$/) fence = 0
  return 1
}
function _label(s,   t) {
  t = s
  sub(/^[ \t]+/, "", t)
  sub(/^[-*+][ \t]+/, "", t)          # "- INTERNAL: …"
  sub(/^[0-9]+[.)][ \t]+/, "", t)    # "1. INTERNAL: …"
  sub(/^(\*\*|__)/, "", t)           # "**INTERNAL:** …"
  sub(/^[ \t]+/, "", t)
  if (match(t, /^[A-Za-z][A-Za-z0-9 _-]*:/)) {
    _lab = tolower(substr(t, 1, RLENGTH - 1))
    gsub(/[ \t-]+/, " ", _lab)
    sub(/[ \t]+$/, "", _lab)
    _rest = substr(t, RLENGTH + 1)
    sub(/^[ \t]+/, "", _rest)
    sub(/[ \t]+$/, "", _rest)
    # ⛔ THE VALUE IS MEASURED UNDRESSED (#3484). A DECORATED label (`**WIP:** issue-3484 -> none`,
    # `` `CLAIM:` … ``) is normal markdown, and a value test that reads the decoration instead of the
    # value refuses an honest brief — the same one-sided-strip defect the mutation parser (§3442) had.
    # Ornament around a genuinely empty value then reads as empty, which is the direction that refuses.
    gsub(/^[*_`]+/, "", _rest)
    gsub(/[*_`]+$/, "", _rest)
    sub(/^[ \t]+/, "", _rest)
    sub(/[ \t]+$/, "", _rest)
    return _lab
  }
  _lab = ""; _rest = ""
  return ""
}
BEGIN { ins = 0; depth = 0; sec = 0; internal = 0; external = 0; rung = 0; ct = 0; cmp = 0
        pins = 0; pdepth = 0; pwsec = 0; pwcla = 0; pwwip = 0; pwbr = 0; pwwt = 0; pwpri = 0
        fence = 0; fencec = ""; fencelen = 0 }
{
  line = _qskip($0)
  if (line == "\001") next
  if (match(line, /^(```|~~~)/)) { _fence(line); next }
  if (fence) next
  lc = tolower(line)
  nh = 0
  if (lc ~ /^#+/) { match(lc, /^#+/); nh = RLENGTH }

  # A heading at or above the research heading closes the section (subsections stay inside it).
  if (ins && nh > 0 && nh <= depth) { ins = 0 }
  # …and the same rule closes the PREVIOUS WORK section (#3484), independently: the two sections
  # must not be able to lend each other their labels, or a brief could satisfy one contract with the
  # text of the other.
  if (pins && nh > 0 && nh <= pdepth) { pins = 0 }

  if (!ins && nh > 0 && lc ~ /^#+[ \t]*research[ -]first/) {
    ins = 1; depth = nh; sec = 1
    next
  }
  if (!pins && nh > 0 && lc ~ /^#+[ \t]*previous[ -]work/) {
    pins = 1; pdepth = nh; pwsec = 1
    next
  }

  _label(line)
  if (ins) {
    if (_lab == "internal" && length(_rest) > 0) internal = 1
    if (_lab == "external" && length(_rest) > 0) external = 1
    if (_lab == "rung" && length(_rest) > 0 &&
        _rest ~ /(^|[^0-9])[1-3]([^0-9]|$)/ &&
        tolower(_rest) ~ /perplexity|web_search|web[ _-]?fetch|context7/) rung = 1
    # ⛔ SCOPED LIKE ITS SIBLINGS (round 2 review, P2): a `COMPARABLES:` line under some OTHER heading
    # must not satisfy the round>=4 clause — the same rule §A pins for EXTERNAL ("scoping is
    # enforced"). The canonical round>=4 block emits the label INSIDE the research section, so the
    # gate still cannot refuse its own advice.
    if (_lab == "comparables" && length(_rest) > 0) cmp = 1
  }
  # CONTRADICTION TEST is the one label allowed ANYWHERE (it may sit outside the section, and the
  # schema says so). The COMPARABLES label is scoped to the section, above.
  # ── PREVIOUS WORK (#3484). Five labelled facts about the work that already exists for this key.
  # `WIP` is measured by SHAPE here — it must be keyed to an issue (or, for a fixer, a PR) so the
  # contradiction check below can tell WHICH issue the claim of absence is about. Requiring the key
  # is what makes `unclaimed` (the wording the issue itself uses) checkable instead of unfalsifiable: the shape
  # the issue proposed had no slot for the issue number at all.
  if (pins) {
    if (_lab == "claim" && length(_rest) > 0) pwcla = 1
    # ⛔ THREE ACCEPTED KEYS, AND `keyless` IS THE THIRD ON PURPOSE (#3484). `issue-<N>` is the normal
    # case and the only one the cross-check can resolve; `pr-<N>` is a fixer working one PR; and a
    # DIAGNOSIS lane (stall-fix, the drainer) genuinely has no key, so refusing it would force a FALSE
    # one — the choice is between an honest `keyless — <why>` and an invented issue number. An author
    # who means to evade can invent a number more easily than they can justify `keyless`, so nothing is
    # gained by withholding the honest form.
    # ⛔ PRESENCE ONLY, HERE. Whether the key is valid is decided in ONE place — `brief_gate_previous_work`,
    # which reads EVERY `WIP:` value (fresh-context review of #3484, P1: two readers that disagreed about
    # WHICH line is the claim let a trailing `WIP: none` / a pasted canonical block / a bare label satisfy
    # the shape while the cross-check abstained on the last line it saw).
    if (_lab == "wip" && length(_rest) > 0) pwwip = 1
    if (_lab == "branch" && length(_rest) > 0) pwbr = 1
    if (_lab == "worktree" && length(_rest) > 0) pwwt = 1
    if (_lab == "prior" && length(_rest) > 0) pwpri = 1
  }
  if (_lab == "contradiction test" && length(_rest) > 0) ct = 1
}
END {
  if (NR == 0) { print "EMPTY"; exit }
  if (!sec) print "RESEARCH-SECTION"
  else {
    if (!internal) print "INTERNAL"
    if (!external) print "EXTERNAL"
    if (!rung)     print "RUNG"
  }
  if (!ct) print "CONTRADICTION-TEST"
  # ⛔ ROUND ≥ 4 REQUIRES THE COMPARABLE CLAUSE, FOR THE REVIEWER ROLE ONLY (#3441). A lane brief at
  # round 0 (a caller that passed no round) keeps the round-3 contract — stated as a residual, not
  # hidden: the mandate is only reachable when the caller supplies the round, which `merge-one.sh`
  # always does for a review (it derives it from `state/reviewround-<PR>`).
  if (gr_role == "reviewer" && (gr_round + 0) >= (gr_cmp + 0) && !cmp) print "EXTERNAL-COMPARABLES"
  if (!pwsec) print "PREVIOUS-WORK-SECTION"
  else {
    if (!pwcla) print "PREVIOUS-WORK-CLAIM"
    if (!pwwip) print "PREVIOUS-WORK-WIP"
    if (!pwbr)  print "PREVIOUS-WORK-BRANCH"
    if (!pwwt)  print "PREVIOUS-WORK-WORKTREE"
    if (!pwpri) print "PREVIOUS-WORK-PRIOR"
  }
}
'

# ── THE NON-VACUITY PARSER (#3442) ────────────────────────────────────────────
# Deliberately a SEPARATE program from the one above, for two reasons that are both load-bearing:
#
#   1. IT MUST READ THE WHOLE INPUT BEFORE IT DECIDES, and the research parser must not. The same
#      program is run over a reviewer's BRIEF (real newlines) and over a review ARTIFACT as
#      `record-review.sh` reads it — a GitHub comment body arrives @tsv-ESCAPED, so its newlines are
#      the two literal characters `\` + `n` and the whole comment is ONE awk record. A line-oriented
#      scan would then never see a heading at a line start and would refuse every honest artifact.
#      So this program buffers, un-escapes `\n`, and re-scans: one code path, both carriers.
#      (The sibling file already paid for this lesson — `verify_review_evidence`'s record-marker arm
#      had to widen `^` to `(^|\\n)` for exactly this reason.)
#   2. The research schema must keep behaving EXACTLY as it does today. Wrapping two contracts in one
#      END block is how a change to one silently re-opens the other.
#
# Globals: `sec` (the heading exists), `none` (a NO NEW ASSERTIONS claim with a reason), `hdr` (a
# table header naming assertion + mutant + reddened), `hl` (the header's LINE index, so a header can
# never count as its own data row), `row` (a data row BELOW the header with >=3 non-empty cells) and
# `fence` (inside a ``` block — quoted material, never a claim).
# Tokens are printed only when the contract is unmet, one per line, so the caller can teach each.
# shellcheck disable=SC2016
BRIEF_GATE_MUTATION_AWK='
function _cells(s, arr,   n, i, x, k, tmp) {
  n = split(s, tmp, "|"); k = 0
  for (i = 1; i <= n; i++) {
    x = tmp[i]
    gsub(/^[ \t`*_]+/, "", x); gsub(/[ \t`*_]+$/, "", x)
    if (length(x) > 0) { k++; arr[k] = x }
  }
  return k
}
# ── THE DECORATION STRIP, ONE HOME (#3442 review cycle 4, P1 — FAIL-OPEN). A reviewer DECORATES a
# label (`**NO NEW ASSERTIONS:**`, `*NO NEW ASSERTIONS: docs-only*`, a bullet), so the wrappers must
# come off BOTH ends before the reason is measured. Stripping only the LEADING `**` left the CLOSING
# `**` as the "reason", so an exemption carrying NO reason at all satisfied `length(r) > 0` and minted
# a clean record with neither a table nor a justification; and the one-sided strip REFUSED an honest
# decorated line (a false block). One function, so a single mutant can revert the whole rule.
function _undress(s) {
  gsub(/^[ \t*_`]+/, "", s); gsub(/[ \t*_`]+$/, "", s)
  return s
}
# ── THE @tsv REVERSAL, IN ONE PASS (#3442 review, P1/P2). `evidence_fetch` hands this program a
# `jq @tsv` body, which escapes BACKSLASH, TAB, NEWLINE and CARRIAGE RETURN. Reversing them with
# successive gsubs is wrong in both directions: `\\n` (a literal backslash the author typed before
# an n) would become a newline, and a real `\r` left escaped keeps its two characters, so a
# `|---|\r` RULE is not an all-separator row and becomes the DATA row. One left-to-right scan gets
# every pair right, and unknown escapes pass through unchanged.
function _unescape(s,   out, i, n, c, nx) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) {
      nx = substr(s, i + 1, 1)
      if (nx == "\\") { out = out "\\"; i++; continue }
      if (nx == "n")  { out = out "\n"; i++; continue }
      if (nx == "r")  { out = out "\r"; i++; continue }
      if (nx == "t")  { out = out "\t"; i++; continue }
    }
    out = out c
  }
  return out
}
BEGIN { buf = ""; ins = 0; depth = 0; sec = 0; none = 0; hdr = 0; row = 0; fence = 0; hl = 0; indx = 0; slot = 0 }
{ buf = buf $0 "\n" }
END {
  if (length(buf) == 0) { print "EMPTY"; exit }
  # @tsv reverses here, not in the caller: a consumer that un-escaped first would be a SECOND
  # definition of the artifact format, and the two would drift.
  # ⛔ AND THE ESCAPED CARRIER IS DETECTED, NEVER ASSUMED. An HONEST artifact may carry a literal
  # backslash-n inside a cell (a mutant that edits a newline is a normal mutant). Un-escaping a REAL
  # multi-line body would turn that cell into a line break, split the row, and REFUSE a reviewer
  # whose row is right there — a false block whose message names the wrong cause. So the reversal
  # runs only when the body is ONE record, which is exactly what `jq @tsv` produces.
  nraw = split(buf, RAW, "\n")
  if (nraw == 1 || (nraw == 2 && RAW[2] == "")) buf = _unescape(buf)
  nl = split(buf, L, "\n")
  for (i = 1; i <= nl; i++) {
    # ⛔ CR BEFORE ANYTHING ELSE: a body that travelled through a CRLF carrier has a trailing \r on
    # every line, and `|---|\r` is not an all-separator row to the regex below — so the rule would
    # become the DATA row and a header-plus-rule table would be admitted (fresh-context review, P1).
    line = L[i]; sub(/\r$/, "", line)
    # ── INDENT IS MEASURED IN COLUMNS, NOT CHARACTERS (review cycle 7, P2 — FAIL-OPEN). CommonMark
    # expands a TAB to the next 4-COLUMN stop, so `" \t"` and `"  \t"` are four columns of indent —
    # an indented CODE BLOCK to every renderer — while a character test saw two or three characters and
    # let the copied exemption go LIVE. The miss set was non-monotonic (more indentation was caught,
    # less was not), which is the shape of a rule that is measuring the wrong thing. So the leading
    # whitespace is expanded ONCE here, and every indent decision below reads the expansion.
    lw = ""; col = 0; ln = length(line)
    for (q = 1; q <= ln; q++) {
      c = substr(line, q, 1)
      if (c == " ") { lw = lw " "; col++; continue }
      if (c == "\t") { for (tw = 4 - (col % 4); tw > 0; tw--) { lw = lw " "; col++ } continue }
      break
    }
    lrest = substr(line, q); icol = length(lw)
    # ⛔ AN INDENTED CODE BLOCK IS QUOTED TOO (4+ COLUMNS, CommonMark), AND IT IS TESTED BEFORE THE
    # FENCE. The reviewer is handed a filled row to copy, so an indented paste must not satisfy the
    # contract — and a fence line INDENTED BY FOUR is quoted code rather than a fence, so testing the
    # fence first let an indented fence line INSIDE an open fence close it and re-open the live region
    # (review cycle 4, P2).
    if (icol >= 4) {
      # ⛔ AN INDENTED EXEMPTION IS QUOTED — AND THE REFUSAL MUST SAY SO (review cycles 5-7, P2). The
      # canonical block shows the `NO NEW ASSERTIONS:` shape as an INDENTED code block so that pasting
      # the block cannot exempt the artifact pasted from it. The cost is that a reviewer who copies the
      # shape faithfully writes a line this program skips, and the refusal then said "your table
      # header must name assertion, mutant and reddened" — a cause to look for and NOT FIND. Remember
      # it, so the refusal can name what happened. `indx` is SECTION-scoped and fence-aware, so an
      # appendix or a quoted line cannot lend its diagnosis to the mutation section.
      if (ins && !fence && tolower(lrest) ~ /^no new assertions:/) indx = 1
      continue
    }
    # ⛔ A FENCED BLOCK IS QUOTED MATERIAL, NEVER THE CLAIM ITSELF (#3442 review, P2). The reviewer is
    # HANDED a filled worked row (`--mutation-section`) and both SKILL.md templates carry one, so
    # "paste the shape I was given" inside a fence is exactly the fabricated-but-shaped block this
    # contract exists to refuse. Fence state is tracked before any section logic, so a fenced heading
    # cannot open the section either. An UNBALANCED fence swallows the rest of the artifact, which
    # fails CLOSED (no heading/rows ⇒ refused) — the safe direction, stated so it is not a surprise.
    # (No apostrophes in this program: it is a single-quoted bash string.)
    # ⛔ AND A FENCE IS CLOSED ONLY BY ITS OWN CHARACTER, IN A RUN AT LEAST AS LONG (review cycles
    # 4-6). `fence` used to be ONE boolean toggled by EITHER character, so a `~~~` line inside a ```
    # block re-opened the live region. Then the character alone closed on a fenced command INSIDE the
    # block, and requiring only a blank tail refused a LEGAL LONGER closer. Both CommonMark rules are
    # needed: no info string on the closer, and the closer >= the opener.
    if (match(lrest, /^(```|~~~)/)) {
      fc = substr(lrest, RLENGTH - 2, 1)
      flen = 0
      for (k = RLENGTH - 2; substr(lrest, k, 1) == fc; k++) flen++
      rest = substr(lrest, k)
      if (!fence) { fence = 1; fencec = fc; fencelen = flen }
      else if (fc == fencec && flen >= fencelen && rest ~ /^[ \t]*$/) fence = 0
      continue
    }
    if (fence) continue
    nh = 0
    # A MARKDOWN HEADING MAY BE INDENTED BY UP TO THREE COLUMNS. Refusing an indented `## MUTATION
    # ATTRIBUTION` deadlocks an honest verdict until it is reflowed, which is a false block. Four or
    # more columns is a CODE BLOCK and was already skipped above, so no `sind` test is needed here.
    if (match(lrest, /^#+/)) { nh = RLENGTH; htxt = tolower(substr(lrest, RLENGTH + 1)) }
    # A heading at or above the section closes it (subsections stay inside it).
    if (ins && nh > 0 && nh <= depth) ins = 0
    if (!ins && nh > 0 && htxt ~ /^[ \t]*mutation[ -]attribution/) { ins = 1; depth = nh; sec = 1; indx = 0; slot = 0; continue }
    if (!ins) continue

    l = line
    # ⛔ BLOCKQUOTE MARKERS COME OFF FIRST (review cycle 4, P2 — FAIL-OPEN). The first "cell" of a
    # quoted table was the `>` marker, so `allsep` was false and the `|---|` RULE became the DATA row: a
    # header-plus-rule table carrying no attribution at all was ADMITTED, because the marker defeated
    # the one check that refuses a rule-as-row. A reviewer quoting their OWN table must be judged on
    # the table, so the marker is stripped rather than the line skipped.
    bq = 1
    while (bq) { bq = sub(/^[ \t]*>[ \t]?/, "", l) }
    sub(/^[ \t]+/, "", l)
    sub(/^[-*+][ \t]+/, "", l)
    # ⛔ THE EXEMPTION IS MEASURED AFTER `_undress` (review cycle 4, P1 — FAIL-OPEN): see that
    # function for the two directions a one-sided strip gets wrong. The `[^:]` split keeps a URL later
    # in the line from being read as the label.
    nn = _undress(l)
    if (tolower(nn) ~ /^no new assertions:/) {
      r = nn; sub(/^[^:]*:/, "", r); r = _undress(r)
      # ⛔ A PLACEHOLDER IS NOT A REASON (review cycles 5-6, P2). Every carrier that TELLS a reviewer
      # about this exemption spells it `NO NEW ASSERTIONS: <why>` — the generated merge-one prompt,
      # skills/code-review/SKILL.md, and the refusal text in record-review.sh — so the literal slot is
      # the text most likely pasted, and `length()` cannot tell a slot from a reason. The quoted
      # re-spellings are a paste one keystroke away, so ONE layer of quotes comes off before the slot
      # test. STATED LIMIT, unchanged in kind: a bracketed slot or a bare `TODO` still counts as a
      # reason — this is a shape test, and every shape test has a boundary. `slot` remembers WHICH
      # refusal to give, so the message can name the cause instead of the generic column token.
      rq = r; sq = sprintf("%c", 39)
      sub(/^"/, "", rq); sub(/"$/, "", rq); sub("^" sq, "", rq); sub(sq "$", "", rq)
      # ⛔ AND THE EMPTINESS TEST READS THE STRIPPED FORM (review cycle 7, P2 — FAIL-OPEN). Testing
      # `length(r)` while testing `rq` for the slot let `NO NEW ASSERTIONS: ""` through: the reason is
      # empty once its quotes come off, but the quoted pair made it non-empty. `_undress(rq)` also
      # closes the whitespace-only case (`" "`), which is the same defect in one more spelling.
      if (length(_undress(rq)) > 0 && rq !~ /^<[^<>]*>$/) none = 1
      else if (length(_undress(rq)) > 0) slot = 1
    }
    # ⛔ A TABLE NEED NOT HAVE OUTER PIPES (#3442 review cycle 3, P2). GFM renders
    # `assertion | mutant | reddened row | observed` as a table, and refusing it told the reviewer its
    # header "must name assertion, mutant and reddened" — a column it already had. So any line carrying
    # a pipe is a table candidate; `_cells` still requires >=3 non-empty cells for a row, and the
    # header still has to name all three columns. Stated limit, unchanged in kind: this is a SHAPE
    # test, so a prose line with three pipe-separated segments can satisfy a row.
    if (l ~ /\|/) {
      k = _cells(l, C)
      if (k >= 2) {
        allsep = 1
        for (j = 1; j <= k; j++) { if (C[j] !~ /^:?-+:?$/) allsep = 0 }
        # A `|---|` RULE is never a data row, and is never a header either: on a table whose every
        # data row was deleted it would otherwise satisfy "has a row". Decided BEFORE the header
        # test so the rule can never be mistaken for one.
        if (allsep) continue
        t = tolower(l)
        # ⛔ THE HEADER RESETS `row` (#3442 review cycle 3, P1). A table ABOVE the header (a "what I
        # ran" summary is the normal shape) sets `row` while `hl` is still 0, and a later header-only
        # attribution table then inherited that row — the vacuous table, admitted. Finding the header
        # starts the attribution over: from here only a row BELOW it counts.
        # ⛔ AND THE GUARD IS `!hdr` — ONE HEADER PER SECTION (review cycle 4, P2 — FALSE BLOCK).
        # Without it, ANY row whose cells happened to say "assertion", "mutant" and "reddened"
        # RE-ENTERED the header branch and reset `row`, so an honest single-row attribution that
        # spelled the column names out in its own cells was REFUSED with a message telling the
        # reviewer to write the row it had already written. A table has one header; after it, every
        # row is data.
        # Rows count only AFTER the header — BY POSITION, NOT BY TEXT (review of #3442, P1): matching
        # the first cell against the literal `assertion` admits every DECORATED header —
        # `| assertion (file:line) | mutant | … |` — as a data row, the same vacuous table the index
        # was added to refuse.
        if (!hdr && t ~ /mutant/ && t ~ /assertion/ && t ~ /redden/) { hdr = 1; hl = i; row = 0 }
        if (k >= 3 && i > hl) row = 1
      }
    }
  }
  if (!sec) { print "MUTATION-ATTRIBUTION"; exit }
  if (none) exit
  if (!hdr) {
    # The likelier cause wins the diagnosis, because the generic token sends the reviewer to look for
    # something that is not there: an INDENTED exemption is a paste-back of the canonical block, and a
    # PLACEHOLDER one is the slot the harness itself printed. A complete table still wins over both
    # hints (this arm is reached only when !hdr).
    if (indx) { print "MUTATION-EXEMPTION-INDENTED"; exit }
    if (slot) { print "MUTATION-EXEMPTION-PLACEHOLDER"; exit }
    print "MUTATION-MUTANT-COLUMN"; exit
  }
  if (!row) print "MUTATION-ROWS"
}
'

# brief_gate_missing_all <file|-> [role] [round] [repo] — every missing token for a dispatch: the SHAPE
# tokens plus the PREVIOUS WORK cross-check. `--missing` is the verb an author iterates with, so it must
# see the same body `--check` sees.
# ⛔ STDIN IS MATERIALISED ONCE HERE TOO (fresh-context review of #3484, P2). `brief_gate_missing` and
# `brief_gate_previous_work` are two readers; with `-` the first drains the pipe and the second sits at
# EOF, so `--missing -` reported "complete, rc=0" for a brief that `--check -` refuses — the diagnostic
# verb disagreeing with the gate is how an author is told their brief is fine when it is not.
brief_gate_missing_all() { # brief_gate_missing_all <file|-> [role] [round] [repo]
  local f="${1:--}" role="${2:-lane}" rnd repo="${4:-}" tmpf=""
  rnd="$(brief_gate_round_norm "${3:-0}")"
  if [ "$f" = "-" ]; then
    tmpf="$(mktemp "${TMPDIR:-/tmp}/brief-gate.XXXXXX" 2>/dev/null)" || {
      # ⛔ NOT `NO-FILE` (review cycle 2, nit): the brief is right there — the TEMP FILE could not be
      # made (a full disk, an unusable TMPDIR). `NO-FILE` sends the author to look for a brief that
      # exists; this token says what actually failed, and it refuses rather than answering "complete".
      printf '[brief-gate] CANNOT VERIFY: no temp file for the stdin brief (mktemp failed) — the brief was NOT read.\n' >&2
      printf 'GATE-UNAVAILABLE\n'; return "$BRIEF_GATE_UNAVAILABLE"; }
    cat > "$tmpf"
    f="$tmpf"
  fi
  # ⛔ BOTH ARGUMENTS: #3441's review ROUND (on the base) and #3484's ROLE (the WIP key rule is
  # role-scoped). Resolving this by keeping one side drops the other feature silently — which is what a
  # rebase resolution did to this file on the shared branch before this replay.
  brief_gate_missing "$f" "$role" "$rnd"
  brief_gate_previous_work "$f" "$repo" "$role"
  [ -n "$tmpf" ] && rm -f "$tmpf"
  return 0
}

# brief_gate_verify <brief-file|-> [role] [round] [repo] — 0 = allowed, REFUSED with the teaching message, or
# UNAVAILABLE. Prints NOTHING on success (a silent pass is a pass; the callers already log).
brief_gate_verify() { # brief_gate_verify <brief-file|-> [role] [round] [repo]
  local f="${1:--}" role="${2:-lane}" rnd miss="" repo="${4:-}" tmpf="" pw=""
  case "$role" in
    lane|fixer|reviewer|worker) : ;;
    *)
      printf '[brief-gate] CANNOT VERIFY: unknown role "%s" (expected lane|fixer|reviewer|worker).\n' \
        "$role" >&2
      printf '[brief-gate]   a cannot-verify is NEVER a pass — refusing the dispatch.\n' >&2
      return "$BRIEF_GATE_UNAVAILABLE" ;;
  esac
  # stdin is INHERITED through the command substitution, so `-` reads the caller's pipe.
  rnd="$(brief_gate_round_norm "${3:-0}")"
  # ⛔ STDIN IS MATERIALISED ONCE, HERE (#3484). TWO passes read the brief — the research/shape parse
  # and the PREVIOUS WORK cross-check — and a second `-` reader would sit at EOF, silently reporting
  # "no WIP line" for a brief that has one, i.e. the cross-check would be INERT on exactly the carrier
  # (a pane order piped inline) it most needs to cover. A temp file makes both passes read one body.
  if [ "$f" = "-" ]; then
    tmpf="$(mktemp "${TMPDIR:-/tmp}/brief-gate.XXXXXX" 2>/dev/null)" || {
      printf '[brief-gate] CANNOT VERIFY: no temp file for the stdin brief — refusing (a cannot-verify is never a pass).\n' >&2
      return "$BRIEF_GATE_UNAVAILABLE"; }
    cat > "$tmpf"
    f="$tmpf"
  fi
  miss="$(brief_gate_missing "$f" "$role" "$rnd")"
  pw="$(brief_gate_previous_work "$f" "$repo" "$role")"
  [ -n "$pw" ] && miss="${miss:+$miss$'\n'}${pw}"
  if [ -z "$miss" ]; then
    [ -n "$tmpf" ] && rm -f "$tmpf"
    return 0
  fi


  # ── THE REFUSAL MUST TEACH (delivery D) ───────────────────────────────────────────────────────
  # One line per item that is actually missing, in the order the author has to add them, then the
  # canonical block to paste. A refusal that only says "no research section" is a wall: the next
  # author still has to guess the shape, and guessing is how the field came to be skipped.
  local nl=$'\n' lines="" tok body=""
  while IFS= read -r tok; do
    # ⛔ THE CONTRADICTION TOKEN CARRIES ITS EVIDENCE (`TOKEN<TAB>ref,ref`), because a refusal that says
    # "a matching ref exists" while naming none sends the author to grep for the thing that refused
    # them. The token is split OFF before the case, and the evidence is printed on its own line.
    local pwev=""
    case "$tok" in PREVIOUS-WORK-WIP-CONTRADICTED*)
      pwev="${tok#PREVIOUS-WORK-WIP-CONTRADICTED}"; pwev="${pwev#$'\t'}"; tok=PREVIOUS-WORK-WIP-CONTRADICTED ;;
    esac
    case "$tok" in
      NO-FILE)   lines="${lines}  • the brief file does not exist or is not readable — a dispatch with no brief carries no contract${nl}" ;;
      EMPTY)     lines="${lines}  • the brief is EMPTY — there is nothing to research and nothing to do${nl}" ;;
      RESEARCH-SECTION)
                 lines="${lines}  • a \`## RESEARCH FIRST\` heading, containing INTERNAL:, EXTERNAL: and RUNG:${nl}" ;;
      INTERNAL)  lines="${lines}  • \`INTERNAL:\` — what this repo and its tracker ALREADY hold (issue + comments, prior attempts, open PRs, the doc for the seam)${nl}" ;;
      EXTERNAL)  lines="${lines}  • \`EXTERNAL:\` — what you will look up OUTSIDE it, and what you took from it${nl}" ;;
      RUNG)      lines="${lines}  • \`RUNG: <1|2|3> — <tool>\` — which rung of the research ladder, naming the tool (one of: ${BRIEF_GATE_TOOLS})${nl}" ;;
      CONTRADICTION-TEST)
                 lines="${lines}  • \`CONTRADICTION TEST:\` — which RECORDED DECISION covers this work, quoted; or that none does${nl}" ;;
      PREVIOUS-WORK-SECTION)
                 lines="${lines}  • a \`## PREVIOUS WORK\` heading, containing CLAIM:, WIP:, BRANCH:, WORKTREE: and PRIOR: (#3484)${nl}" ;;
      PREVIOUS-WORK-CLAIM)
                 lines="${lines}  • \`CLAIM:\` — the claim that owns this key right now (\`refs/claims/issue-<N> -> <holder>:<pid>, lease_until <ts>\`) or \`unclaimed\`${nl}" ;;
      PREVIOUS-WORK-WIP)
                 lines="${lines}  • \`WIP:\` — START the value with the key: \`issue-<N> -> refs/wip/<ref> @ <sha12>\`, or \`issue-<N> -> none (measured: <cmd> at <ts>)\`, or \`keyless — <why>\` for a dispatch with no issue/PR key. The key is what makes your absence claim CHECKABLE — this gate refuses it when \`refs/wip/*\` holds a matching ref${nl}" ;;
      PREVIOUS-WORK-WIP-CONTRADICTED)
                 lines="${lines}  • …and it CONTRADICTS \`refs/wip/*\`, which holds a rescued snapshot for the issue your WIP line is keyed to: ${pwev}${nl}  •   read it (fetch that ref locally and inspect the files it carries) and either CONTINUE that work or say why it is superseded — do not re-derive it${nl}" ;;
      PREVIOUS-WORK-BRANCH)
                 lines="${lines}  • \`BRANCH:\` — an existing \`fix/<N>\`/\`rescue/<N>\` for this key (head, commits ahead, reviewed?) or \`none\`${nl}" ;;
      PREVIOUS-WORK-WORKTREE)
                 lines="${lines}  • \`WORKTREE:\` — a worktree already on this key (path, and clean/<N> dirty files) or \`none\` — a dirty one may be your predecessor's finished work${nl}" ;;
      PREVIOUS-WORK-PRIOR)
                 lines="${lines}  • \`PRIOR:\` — what the previous attempt concluded and why it stopped, or \`no previous attempt\`${nl}" ;;
      MUTATION-ATTRIBUTION)
                 lines="${lines}  • a \`## MUTATION ATTRIBUTION\` section — per NEW assertion, the mutant that reverts the fix and the row it turns RED; or \`NO NEW ASSERTIONS: <why>\` when the diff adds none (#3442)${nl}" ;;
      MUTATION-EXEMPTION-INDENTED)
                 lines="${lines}  • …and a \`NO NEW ASSERTIONS:\` line INDENTED by 4+ spaces (or by a TAB, which is four columns) is a QUOTED CODE BLOCK, not a claim — write it at COLUMN 0. (The canonical block shows the shape indented precisely so that pasting the block cannot exempt you.)${nl}" ;;
      MUTATION-EXEMPTION-PLACEHOLDER)
                 lines="${lines}  • …and \`NO NEW ASSERTIONS: <why>\` with the slot still in it is not a reason — replace it with why THIS diff adds no assertion${nl}" ;;
      MUTATION-MUTANT-COLUMN)
                 lines="${lines}  • …its table header must name \`assertion\`, \`mutant\` and \`reddened\` — a table of prose is not an attribution${nl}" ;;
      MUTATION-ROWS)
                 lines="${lines}  • …and it needs at least ONE data row (\`| <assertion> | <mutant> | <reddened row> | <observed> |\`), or a \`NO NEW ASSERTIONS: <why>\` line${nl}" ;;
      EXTERNAL-COMPARABLES)
                 lines="${lines}  • this is review ROUND ${rnd} (>= ${BRIEF_GATE_COMPARABLE_ROUND}), so the brief must carry a \`COMPARABLES:\` line naming at least one COMPARABLE / COMPETITOR implementation and how it solves the mechanism under review (#3441). Past round 3 the loop stopped converging on 'is this line correct', so the question changes to 'what does the field do', and a local read cannot answer it. ⛔ The line is EMITTED by \`brief-gate.sh --section reviewer <round>\` — a brief that lacks it was generated without the round, which is the defect${nl}" ;;
    esac
  done <<< "$miss"

  {
    printf '[brief-gate] REFUSED — this dispatch does not carry its full contract (research + non-vacuity + round). NOTHING WAS STARTED: no model call, no session, no claim.\n'
    printf '[brief-gate]   brief: %s   role: %s   round: %s\n' "$f" "$role" "${rnd:-0}"
    printf '[brief-gate] missing:\n%s' "$lines"
    printf '[brief-gate] add exactly this to the brief, fill the <…> slots, and re-dispatch\n'
    printf '[brief-gate] (the canonical block, byte-identical to `brief-gate.sh --section %s %s`):\n' "$role" "${rnd:-0}"
    body="$(brief_gate_section "$role" "$rnd")"
    printf '%s\n' "$body" | sed 's/^/[brief-gate]   /'
    printf '[brief-gate] why: two lanes in one day acted on a false premise because their brief never forced the pass — one re-derived a root the tracker already held, one opened a duplicate PR. Both were brief defects, not lane defects (agent-infra#2258).\n'
    printf '[brief-gate] the pass is checked for PRESENCE and SHAPE only — a green run is not evidence the research was good; you still review the substance.\n'
  } >&2
  [ -n "$tmpf" ] && rm -f "$tmpf"
  return "$BRIEF_GATE_REFUSED"
}

# brief_gate_section [role] — the canonical brief block, the ONE source of this text. Every generated
# brief splices it (`lane.sh`, `fix-one.sh`, `merge-one.sh`, `pr-doctor.py`) and every authored brief
# copies it from `templates/LANE-BRIEF.md`; `brief-gate.test.sh` asserts the two agree AND that the
# canonical block passes this validator, so the gate cannot drift into refusing its own advice.
brief_gate_section() { # brief_gate_section [role] [round]
  local role="${1:-lane}" rnd internal round_note=""
  rnd="$(brief_gate_round_norm "${2:-0}")"
  case "$role" in
    lane|worker)
      internal='read what this repo and its tracker ALREADY hold, before you decide anything: the issue AND every comment (root-cause corrections live there), `git log --all --grep` for a prior attempt, the open PRs touching the same files, the architecture doc for the seam you are about to change. Quote file:line, issue and PR numbers. If the work is ALREADY DONE, already decided, or already decomposed into other issues, STOP and report that with evidence instead of re-deriving it.' ;;
    fixer)
      internal='read the reviewer'"'"'s findings IN FULL, the pre-fix code at each stated location, and the earlier fix attempts on this PR (its commits and earlier review comments). Quote file:line. If a finding is already fixed at the head, say so with the commit instead of fixing it twice.' ;;
    reviewer)
      internal='read the diff IN FULL at the PR head (`git show origin/<branch>:<path>`), the linked issue and its comments, the earlier review comments on this PR, and the tracker'"'"'s record of this defect. Quote file:line. If the issue is already fixed elsewhere, that is the finding — do not review a stale premise.' ;;
    *)
      printf 'brief-gate.sh: unknown role "%s" (expected lane|fixer|reviewer|worker)\n' "$role" >&2
      return "$BRIEF_GATE_UNAVAILABLE" ;;
  esac
  # ⛔ ROUND >= 4 PUTS A LABELLED `COMPARABLES:` LINE IN THE CANONICAL BLOCK ITSELF (#3441), so the
  # brief a dispatch actually splices carries the mandate instead of relying on an author to remember
  # it — AND so the label is the thing the validator checks. Round<4 emits NO such label, which is what
  # makes `--check <round-3 brief> reviewer 7` refuse: a brief built without the round is refused by
  # the round it will be used at, which is the plumbing defect #3441 names.
  if [ "$role" = "reviewer" ] && [ "$rnd" -ge "$BRIEF_GATE_COMPARABLE_ROUND" ]; then
    round_note="COMPARABLES: name at least one COMPARABLE / COMPETITOR implementation — an agent harness, a CI
    gate, an attestation or review-budget system — and say concretely how it solves the mechanism
    under review. MANDATORY at review round ${rnd} (#3441): rounds 1-3 converge on \"is this line
    correct\"; past round 3 the loop has stopped converging, and the recurring cause is re-deriving a
    decision the field already settled. If a convergent external practice contradicts a RECORDED
    DECISION, that is a REOPEN (argue it in the decision's own home), never a quiet adoption.
"
  fi
  cat <<BRIEF
## RESEARCH FIRST — before you decide anything (agent-infra#2258)

⛔ This is not a formality and it is not deep research. Do this pass BEFORE you write code, file an
issue, or open a PR, and state its outcome in your final message. It exists because two lanes in one
day acted on a false premise: one re-derived a root the tracker already held, one opened a duplicate
PR. Both were brief defects — the lane was never asked to look first.

INTERNAL: ${internal}
EXTERNAL: look OUTSIDE this repo for how comparable systems solve this — vendor docs, specs, the
    \`research\` skill (state the rung in the RUNG line below). Say what you looked up and what you
    took from it. Skipping the rung is not allowed; \`web_fetch\` on a primary source always exists.
${round_note}RUNG: 2 — web_search model="sonar"   ⛔ REPLACE with the rung you will actually use, naming the tool:
    1 = perplexity MCP (\`mcp__seo-intelligence__perplexity_search\`) · 2 = \`web_search\` with the model
    passed explicitly (\`sonar\`) · 3 = \`web_fetch\`. If the rung you wanted does
    not load, name the rung you took AND the error you saw — a silent fallback erases the config gap.
CONTRADICTION TEST: which RECORDED DECISION covers this work — an owner ruling, a decision section in
    a plan doc, a decision comment on an issue, a Tortoise point carrying one? Quote it, and say
    \`no recorded decision reaches this work\` if none does. If a finding contradicts a recorded
    decision, it is NOT a candidate for adoption: reopen the decision and argue it in its own home;
    never adopt over it.

## PREVIOUS WORK — did someone already start this? (agent-infra#3484)

A released claim reads as "nothing happened here" unless someone looks, and 222 rescued \`refs/wip/*\`
snapshots existed on this repo that nothing told the next actor about. Measure the five facts below
and paste the MEASUREMENT — this is the handover the reaper cannot write for you, because only you
know what the previous attempt concluded.

⛔ \`WIP:\` MUST START WITH THE KEY (\`issue-<N>\`, or \`pr-<N>\` for a fixer's PR key). That is what
makes the absence claim checkable instead of unfalsifiable: a \`WIP:\` value that names no
\`refs/wip/…\` ref is read as "there is none", and the dispatch is REFUSED when \`refs/wip/*\` holds
a snapshot for that issue. Silence is not freedom.

CLAIM:     refs/claims/issue-<N> -> <holder>:<pid>, lease_until <ts>   ·   or "unclaimed"
WIP:       issue-<N> -> refs/wip/<ref> @ <sha12>   ·   or   issue-<N> -> none (measured: <cmd> at <ts>)
           ·   or   keyless — <why this dispatch has no issue/PR key>
BRANCH:    fix/<N> / rescue/<N> -> <head>, <N> commits ahead, reviewed | unreviewed   ·   or "none"
WORKTREE:  <path> -> clean | <N> dirty files   ·   or "none"
PRIOR:     what the previous attempt concluded, and why it stopped   ·   or "no previous attempt"

Commands that answer it: \`git ls-remote origin 'refs/claims/*' 'refs/wip/*'\`,
\`git ls-remote --heads origin 'fix/<N>*' 'rescue/<N>*'\`, \`git worktree list\`, and
\`bash scripts/orchestrator-harness/brief-gate.sh --wip-refs <N>\` (the typed form of the WIP line).
BRIEF
  # ⛔ THE NON-VACUITY CONTRACT IS FOR THE REVIEWER ROLE ONLY (#3442), and the canonical block is a
  # WORKED EXAMPLE, not a template: its table is filled in, so a reviewer sees the shape it must
  # produce rather than a `<slot>` it can leave as written. `fixtures/mutation-attribution/` carries
  # the same shape for the two suite classes the issue measured (a bash suite and a python mutation
  # harness) so the copyable form exists where a suite's own author will look for it.
  if [ "$role" = "reviewer" ]; then brief_gate_mutation_section; fi
}

# brief_gate_mutation_section — the canonical NON-VACUITY block (#3442). ONE home: the reviewer's
# brief splices it, `record-review.sh`'s refusal points at it, and `--section reviewer` prints it, so
# the shape the gate teaches and the shape the recorder demands cannot diverge.
brief_gate_mutation_section() {
  cat <<'MUTBRIEF'

## MUTATION ATTRIBUTION — every NEW assertion names the mutant that reddens it (agent-infra#3442)

A clean verdict is a claim that the new guards CAN FAIL — and until #3442 nothing on the path asked
anyone to show it. Five PRs in one night were reviewed clean over assertions that would have stayed
GREEN with the bug restored; the mutation leg was simply ABSENT, and absence is invisible to every
other review check. Do this pass LAST, immediately before you return a clean verdict.

For EVERY assertion the diff ADDS OR CHANGES that claims to protect a behaviour, state the edit that
reverts that behaviour and the row that goes RED. Rows are one line each:

| assertion | mutant (the edit that reverts the fix) | reddened row | observed |
|---|---|---|---|
| `scripts/x.sh:120` — "the gate refuses an empty brief" | `sed 's/rc=80/rc=0/' scripts/x.sh` | `x.test.sh` §A (i) | `❌ … REFUSED with 80 (got 0)`, rc=1 |

If the diff adds no assertion at all, say so instead of leaving the table out — one labelled line.
Its shape is shown as an INDENTED code block on purpose: a LIVE `NO NEW ASSERTIONS:` line inside this
block would exempt EVERY artifact pasted from it — including one whose table was deleted — which is
the fabricate-by-paste-back this contract exists to refuse. Type the line yourself:

    NO NEW ASSERTIONS: docs-only — the diff touches `docs/ops/*.md` and no executable assertion.

⛔ Write that line at COLUMN 0. The indented form above is a QUOTED code block and the parser skips
it — which is why it is shown that way (a LIVE line in this block would exempt every verdict pasted
from it, including one whose table was deleted). A verdict refused for indenting it is told so by
name.

⛔ THREE RULES, and rule 3 is a FINDING, never a nit:
1. A mutant per NEW GUARD — not per file, not per PR. An assertion that encodes a fix gets its own row.
2. The catch must be ATTRIBUTABLE. A mutant that reddens the suite through an UNRELATED row is not a
   proof: name the row that names the behaviour (measured: #3355's first review found a mutation that
   anchored the repair-arm `continue` instead of the liveness leg it was supposed to protect).
3. An assertion whose value cannot vary under ANY mutation of the diff is dead weight that actively
   misleads the next reader into thinking the guard is covered. Make it reachable or delete it. A
   comment explaining why it cannot fail is NOT a fix.

⛔ "I read the diff and it looks right" is not this pass, and a suite that passes on the pre-fix code
is not evidence the fix is tested. A verdict with no attribution block is INCOMPLETE, not clean: the
recorder refuses to mint `clean` over it (`record-review.sh`, exit 3).
MUTBRIEF
}

# brief_gate_line [role] — ONE line for the lane log, so the mandate is visible in what an operator
# greps, exactly like `reviewer_preflight_line` (#2148). The long form is in the brief.
brief_gate_line() { # brief_gate_line [role]
  local role="${1:-lane}"
  if [ "$role" = "reviewer" ]; then
    printf '[gate] #2258 research-first: this brief carries a RESEARCH FIRST section (INTERNAL + EXTERNAL + RUNG/tool) and a CONTRADICTION TEST line. Do the pass BEFORE deciding anything; if the work is already done or already decided, report that with evidence instead of re-deriving it. The dispatch is REFUSED without both (brief-gate.sh, exit 80). [gate] #3484 previous work: a PREVIOUS WORK block (CLAIM / WIP / BRANCH / WORKTREE / PRIOR) is required too, WIP keyed `issue-<N>` — a WIP line that names no ref is REFUSED when refs/wip/* holds a snapshot for that issue. [gate] #3442 non-vacuity: a CLEAN verdict must also carry a MUTATION ATTRIBUTION block — per new assertion, the mutant that reverts it and the row that goes RED (or `NO NEW ASSERTIONS: <why>`). A verdict without it is INCOMPLETE, not clean, and record-review.sh refuses to mint `clean` over it.'
    return 0
  fi
  printf '[gate] #2258 research-first: this brief carries a RESEARCH FIRST section (INTERNAL + EXTERNAL + RUNG/tool) and a CONTRADICTION TEST line. Do the pass BEFORE deciding anything; if the work is already done or already decided, report that with evidence instead of re-deriving it. The dispatch is REFUSED without both (brief-gate.sh, exit 80). [gate] #3484 previous work: the same refusal applies without a PREVIOUS WORK block (CLAIM / WIP / BRANCH / WORKTREE / PRIOR), WIP keyed `issue-<N>`; a WIP line that names no ref is refused when refs/wip/* holds a snapshot for that issue.'
}

# ── CLI: for callers, for tests, and for a human who wants the exact text ────────────────────────
#   bash brief-gate.sh --check <file|-> [role] [round] [repo]  → 0 pass · 80 refused (message on stderr) · 78 cannot verify
#   bash brief-gate.sh --missing <file|-> [role] [round] [repo] → the missing tokens, one per line
#   bash brief-gate.sh --mutation-missing <file|-> → the NON-VACUITY tokens alone (the artifact verb;
#                                                   `record-review.sh` calls this on a review comment)
#   bash brief-gate.sh --wip-refs <issue> [repo]  → `<ref>\t<sha12>` per refs/wip ref belonging to the
#                                                   issue · 0 answered (empty IS an answer) · 2 unmeasured
#                                                   (the ONE ref matcher: claim-reaper.sh and claims.sh
#                                                   call this for the handover line, #3484)
#   bash brief-gate.sh --section [role] [round]  → the canonical brief block
#   bash brief-gate.sh --mutation-section        → the canonical NON-VACUITY block alone
#   bash brief-gate.sh --line [role]             → the one-line disclosure
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --check)   shift; brief_gate_verify "${1:--}" "${2:-lane}" "${3:-0}" "${4:-}" ;;
    --missing) shift; brief_gate_missing_all "${1:--}" "${2:-lane}" "${3:-0}" "${4:-}" ;;
    --wip-refs) shift; brief_gate_wip_refs "${1:-}" "${2:-}" ;;
    --mutation-missing) shift; brief_gate_mutation_missing "${1:--}" ;;
    --section) shift; brief_gate_section "${1:-lane}" "${2:-0}" ;;
    --mutation-section) brief_gate_mutation_section ;;
    --line)    shift; brief_gate_line "${1:-lane}" ;;
    *)
      printf 'usage: %s --check <brief-file|-> [lane|fixer|reviewer|worker] [round] [repo]\n' "$0" >&2
      printf '       %s --missing <brief-file|-> [role] [round] [repo] | --mutation-missing <file|->\n' "$0" >&2
      printf '       %s --wip-refs <issue> [repo]\n' "$0" >&2
      printf '       %s --section [role] [round] | --mutation-section | --line [role]\n' "$0" >&2
      exit "$BRIEF_GATE_UNAVAILABLE" ;;
  esac
fi
