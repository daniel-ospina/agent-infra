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
#
# Two labelled fields are not decoration: they are the two halves of the pass that the two measured
# incidents each skipped, and the rung line is what stops "research" from degrading into "I thought
# about it" — rung 3 (`web_fetch`) is always available, so the field is never unsatisfiable.
#
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

# brief_gate_missing <brief-file|-> — print ONE token per missing element, nothing when complete.
# `-` reads stdin (pane orders are passed inline, not as files). An unreadable or empty brief prints
# NO-FILE / EMPTY rather than pretending the parse failed for some subtler reason.
#
# ⛔ THE PARSE IS ONE awk PASS ON PURPOSE. It is the same shape #2148's suite drives and it needs no
# python at dispatch time — a gate that adds an interpreter to every spawn is a gate that will
# eventually be "temporarily" worked around on the box that lacks one.
brief_gate_missing() { # brief_gate_missing <brief-file|-> [role]
  local f="${1:--}" role="${2:-lane}" toks="" body=""
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
    toks="$(printf '%s\n' "$body" | awk "$BRIEF_GATE_AWK")"
    [ -z "$toks" ] || printf '%s\n' "$toks"
    if [ "$role" = "reviewer" ]; then printf '%s\n' "$body" | awk "$BRIEF_GATE_MUTATION_AWK"; fi
  else
    if [ ! -s "$f" ]; then printf 'EMPTY\n'; return 0; fi
    toks="$(awk "$BRIEF_GATE_AWK" "$f")"
    [ -z "$toks" ] || printf '%s\n' "$toks"
    if [ "$role" = "reviewer" ]; then awk "$BRIEF_GATE_MUTATION_AWK" "$f"; fi
  fi
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
    return _lab
  }
  _lab = ""; _rest = ""
  return ""
}
BEGIN { ins = 0; depth = 0; sec = 0; internal = 0; external = 0; rung = 0; ct = 0 }
{
  line = $0
  lc = tolower(line)
  nh = 0
  if (lc ~ /^#+/) { match(lc, /^#+/); nh = RLENGTH }

  # A heading at or above the research heading closes the section (subsections stay inside it).
  if (ins && nh > 0 && nh <= depth) { ins = 0 }

  if (!ins && nh > 0 && lc ~ /^#+[ \t]*research[ -]first/) {
    ins = 1; depth = nh; sec = 1
    next
  }

  _label(line)
  if (ins) {
    if (_lab == "internal" && length(_rest) > 0) internal = 1
    if (_lab == "external" && length(_rest) > 0) external = 1
    if (_lab == "rung" && length(_rest) > 0 &&
        _rest ~ /(^|[^0-9])[1-3]([^0-9]|$)/ &&
        tolower(_rest) ~ /perplexity|web_search|web[ _-]?fetch|context7/) rung = 1
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
BEGIN { buf = ""; ins = 0; depth = 0; sec = 0; none = 0; hdr = 0; row = 0; fence = 0; hl = 0; blk = 0 }
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
    # ⛔ A FENCED BLOCK IS QUOTED MATERIAL, NEVER THE CLAIM ITSELF (#3442 review, P2). The reviewer is
    # HANDED a filled worked row (`--mutation-section`) and both SKILL.md templates carry one, so
    # "paste the shape I was given" inside a fence is exactly the fabricated-but-shaped block this
    # contract exists to refuse. Fence state is tracked before any section logic, so a fenced heading
    # cannot open the section either. An UNBALANCED fence swallows the rest of the artifact, which
    # fails CLOSED (no heading/rows ⇒ refused) — the safe direction, stated so it is not a surprise.
    # (No apostrophes in this program: it is a single-quoted bash string.)
    if (line ~ /^[ \t]*```/ || line ~ /^[ \t]*~~~/) { fence = !fence; continue }
    if (fence) continue
    # ⛔ AN INDENTED CODE BLOCK IS QUOTED TOO (4+ leading whitespace, CommonMark). Same reasoning as
    # the fence: the reviewer is handed a filled row to copy, and an indented paste would otherwise
    # satisfy the contract. Written as four literal whitespace characters, not `{4,}`, because an
    # older BSD awk on 3.2-era hosts is a supported reader.
    if (line ~ /^[ \t][ \t][ \t][ \t]/) continue
    lc = tolower(line); nh = 0
    # A MARKDOWN HEADING MAY BE INDENTED BY UP TO 3 SPACES. Refusing an indented `## MUTATION
    # ATTRIBUTION` deadlocks an honest verdict until it is reflowed, which is a false block.
    if (match(lc, /^[ \t]*#+/)) {
      hh = substr(lc, RSTART, RLENGTH); gsub(/[ \t]+/, "", hh)
      sind = length(substr(lc, RSTART, RLENGTH)) - length(hh)
      if (sind <= 3) { nh = length(hh); htxt = substr(lc, RSTART + RLENGTH) }
    }
    # A heading at or above the section closes it (subsections stay inside it).
    if (ins && nh > 0 && nh <= depth) ins = 0
    if (!ins && nh > 0 && htxt ~ /^[ \t]*mutation[ -]attribution/) { ins = 1; depth = nh; sec = 1; continue }
    if (!ins) continue

    l = line
    # ⛔ A BLOCKQUOTE IS QUOTED MATERIAL TOO (#3442 review cycle 4, P2). Fences and 4-space blocks were
    # skipped; `>` was not, so pasting the worked row one character away satisfied the contract.
    if (l ~ /^[ \t]*>/) continue
    sub(/^[ \t]+/, "", l)
    sub(/^[-*+][ \t]+/, "", l)
    sub(/^(\*\*|__)/, "", l)
    # ⛔ A ROW COUNTS ONLY INSIDE THE CONTIGUOUS TABLE THE HEADER OPENED (#3442 review cycle 4, P1).
    # was section-wide, so a summary table placed BELOW a header-only attribution donated the row —
    # the same vacuity as the above-table case, mirrored. In GFM a table ends at the first line that is
    # not a table line (a blank line included), so anything after that is a DIFFERENT table and its
    # rows are not rows of this attribution table.
    if (l !~ /\|/) blk = 0
    if (tolower(l) ~ /^no new assertions:/ && length(l) > 0) {
      r = l; sub(/^[^:]*:/, "", r); gsub(/^[ \t]+/, "", r); gsub(/[ \t]+$/, "", r)
      if (length(r) > 0) none = 1
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
        t = tolower(l)
        # ⛔ THE HEADER OPENS THE ONLY TABLE THAT COUNTS (#3442 review cycles 3 and 4, P1). A table
        # ABOVE the header (a "what I ran" summary is the normal shape) and one BELOW it are both
        # different tables, and neither donates the row the attribution must carry itself: `blk` is set
        # ONLY here and cleared by the first line that is not a table line, so `row` can only be set
        # inside the contiguous table this header opened. (A separate `row = 0` reset was removed when
        # `blk` landed: with `blk` gating every row, the reset could never fire — the state it guarded
        # against is unreachable, and a dead guard is a guard no mutant can falsify.)
        # ⛔ A DATA ROW NAMING ALL THREE COLUMNS IS NOT A HEADER (#3442 review cycle 4, P2). The reset
        # used to fire on ANY pipe line naming all three words — including a DATA ROW that mentions them,
        # which is the natural row in a review of THIS change — wiping the count it had just contributed
        # and refusing an honest artifact that visibly carried two rows. No `!hdr` guard is needed to keep
        # that true: `blk` gates every row, so the only thing a re-detected header could do is move `hl`,
        # and a row rejected by `hl` cannot be one already counted. A guard that cannot change a verdict is
        # a guard no mutant can falsify, so it is not there (cycle-4 review).
        if (t ~ /mutant/ && t ~ /assertion/ && t ~ /redden/) { hdr = 1; hl = i; blk = 1 }
        allsep = 1
        for (j = 1; j <= k; j++) { if (C[j] !~ /^:?-+:?$/) allsep = 0 }
        # The header row is not a data row, and a `|---|` rule is not either. Both would otherwise
        # satisfy "has a row" on a table whose every data row was deleted. ⛔ BY POSITION, NOT BY
        # TEXT (review of #3442, P1): matching the first cell against the literal `assertion` admits
        # every DECORATED header — `| assertion (file:line) | mutant | … |` — as a data row, which is
        # the same vacuous table the index was added to refuse. Rows count only AFTER the header, and
        # only while that table is still open.
        if (!allsep && k >= 3 && i > hl && blk) row = 1
      }
    }
  }
  if (!sec) { print "MUTATION-ATTRIBUTION"; exit }
  if (none) exit
  if (!hdr) { print "MUTATION-MUTANT-COLUMN"; exit }
  if (!row) print "MUTATION-ROWS"
}
'

# brief_gate_verify <brief-file|-> [role] — 0 = allowed, REFUSED with the teaching message, or
# UNAVAILABLE. Prints NOTHING on success (a silent pass is a pass; the callers already log).
brief_gate_verify() { # brief_gate_verify <brief-file|-> [role]
  local f="${1:--}" role="${2:-lane}" miss=""
  case "$role" in
    lane|fixer|reviewer|worker) : ;;
    *)
      printf '[brief-gate] CANNOT VERIFY: unknown role "%s" (expected lane|fixer|reviewer|worker).\n' \
        "$role" >&2
      printf '[brief-gate]   a cannot-verify is NEVER a pass — refusing the dispatch.\n' >&2
      return "$BRIEF_GATE_UNAVAILABLE" ;;
  esac
  # stdin is INHERITED through the command substitution, so `-` reads the caller's pipe.
  miss="$(brief_gate_missing "$f" "$role")"
  [ -n "$miss" ] || return 0

  # ── THE REFUSAL MUST TEACH (delivery D) ───────────────────────────────────────────────────────
  # One line per item that is actually missing, in the order the author has to add them, then the
  # canonical block to paste. A refusal that only says "no research section" is a wall: the next
  # author still has to guess the shape, and guessing is how the field came to be skipped.
  local nl=$'\n' lines="" tok body=""
  while IFS= read -r tok; do
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
      MUTATION-ATTRIBUTION)
                 lines="${lines}  • a \`## MUTATION ATTRIBUTION\` section — per NEW assertion, the mutant that reverts the fix and the row it turns RED; or \`NO NEW ASSERTIONS: <why>\` when the diff adds none (#3442)${nl}" ;;
      MUTATION-MUTANT-COLUMN)
                 lines="${lines}  • …its table header must name \`assertion\`, \`mutant\` and \`reddened\` — a table of prose is not an attribution${nl}" ;;
      MUTATION-ROWS)
                 lines="${lines}  • …and it needs at least ONE data row (\`| <assertion> | <mutant> | <reddened row> | <observed> |\`), or a \`NO NEW ASSERTIONS: <why>\` line${nl}" ;;
    esac
  done <<< "$miss"

  {
    printf '[brief-gate] REFUSED — this dispatch does not carry its full contract. NOTHING WAS STARTED: no model call, no session, no claim.\n'
    printf '[brief-gate]   brief: %s   role: %s\n' "$f" "$role"
    printf '[brief-gate] missing:\n%s' "$lines"
    printf '[brief-gate] add exactly this to the brief, fill the <…> slots, and re-dispatch\n'
    printf '[brief-gate] (the canonical block, byte-identical to `brief-gate.sh --section %s`):\n' "$role"
    body="$(brief_gate_section "$role")"
    printf '%s\n' "$body" | sed 's/^/[brief-gate]   /'
    printf '[brief-gate] why: two lanes in one day acted on a false premise because their brief never forced the pass — one re-derived a root the tracker already held, one opened a duplicate PR. Both were brief defects, not lane defects (agent-infra#2258).\n'
    printf '[brief-gate] the pass is checked for PRESENCE and SHAPE only — a green run is not evidence the research was good; you still review the substance.\n'
  } >&2
  return "$BRIEF_GATE_REFUSED"
}

# brief_gate_section [role] — the canonical brief block, the ONE source of this text. Every generated
# brief splices it (`lane.sh`, `fix-one.sh`, `merge-one.sh`, `pr-doctor.py`) and every authored brief
# copies it from `templates/LANE-BRIEF.md`; `brief-gate.test.sh` asserts the two agree AND that the
# canonical block passes this validator, so the gate cannot drift into refusing its own advice.
brief_gate_section() { # brief_gate_section [role]
  local role="${1:-lane}" internal
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
RUNG: 2 — web_search model="sonar"   ⛔ REPLACE with the rung you will actually use, naming the tool:
    1 = perplexity MCP (\`mcp__seo-intelligence__perplexity_search\`) · 2 = \`web_search\` with the model
    passed explicitly (\`sonar\`) · 3 = \`web_fetch\`. If the rung you wanted does
    not load, name the rung you took AND the error you saw — a silent fallback erases the config gap.
CONTRADICTION TEST: which RECORDED DECISION covers this work — an owner ruling, a decision section in
    a plan doc, a decision comment on an issue, a Tortoise point carrying one? Quote it, and say
    \`no recorded decision reaches this work\` if none does. If a finding contradicts a recorded
    decision, it is NOT a candidate for adoption: reopen the decision and argue it in its own home;
    never adopt over it.
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

If the diff adds no assertion at all, say so instead of leaving the table out — one labelled line:

NO NEW ASSERTIONS: docs-only — the diff touches `docs/ops/*.md` and no executable assertion.

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
    printf '[gate] #2258 research-first: this brief carries a RESEARCH FIRST section (INTERNAL + EXTERNAL + RUNG/tool) and a CONTRADICTION TEST line. Do the pass BEFORE deciding anything; if the work is already done or already decided, report that with evidence instead of re-deriving it. The dispatch is REFUSED without both (brief-gate.sh, exit 80). [gate] #3442 non-vacuity: a CLEAN verdict must also carry a MUTATION ATTRIBUTION block — per new assertion, the mutant that reverts it and the row that goes RED (or `NO NEW ASSERTIONS: <why>`). A verdict without it is INCOMPLETE, not clean, and record-review.sh refuses to mint `clean` over it.'
    return 0
  fi
  printf '[gate] #2258 research-first: this brief carries a RESEARCH FIRST section (INTERNAL + EXTERNAL + RUNG/tool) and a CONTRADICTION TEST line. Do the pass BEFORE deciding anything; if the work is already done or already decided, report that with evidence instead of re-deriving it. The dispatch is REFUSED without both (brief-gate.sh, exit 80).'
}

# ── CLI: for callers, for tests, and for a human who wants the exact text ────────────────────────
#   bash brief-gate.sh --check <file|-> [role]   → 0 pass · 80 refused (message on stderr) · 78 cannot verify
#   bash brief-gate.sh --missing <file|-> [role]  → the missing tokens, one per line
#   bash brief-gate.sh --mutation-missing <file|-> → the NON-VACUITY tokens alone (the artifact verb;
#                                                   `record-review.sh` calls this on a review comment)
#   bash brief-gate.sh --section [role]          → the canonical brief block
#   bash brief-gate.sh --mutation-section        → the canonical NON-VACUITY block alone
#   bash brief-gate.sh --line [role]             → the one-line disclosure
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --check)   shift; brief_gate_verify "${1:--}" "${2:-lane}" ;;
    --missing) shift; brief_gate_missing "${1:--}" "${2:-lane}" ;;
    --mutation-missing) shift; brief_gate_mutation_missing "${1:--}" ;;
    --section) shift; brief_gate_section "${1:-lane}" ;;
    --mutation-section) brief_gate_mutation_section ;;
    --line)    shift; brief_gate_line "${1:-lane}" ;;
    *)
      printf 'usage: %s --check <brief-file|-> [lane|fixer|reviewer|worker]\n' "$0" >&2
      printf '       %s --missing <brief-file|-> [role] | --mutation-missing <file|->\n' "$0" >&2
      printf '       %s --section [role] | --mutation-section | --line [role]\n' "$0" >&2
      exit "$BRIEF_GATE_UNAVAILABLE" ;;
  esac
fi
