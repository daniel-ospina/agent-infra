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
# ruling (2026-10-31, "external research should be perplexity") and a brief naming it is now
# REFUSED. Named here so the absence reads as a decision, not an omission.
BRIEF_GATE_TOOLS='perplexity, web_search, web_fetch, context7'

# brief_gate_missing <brief-file|-> — print ONE token per missing element, nothing when complete.
# `-` reads stdin (pane orders are passed inline, not as files). An unreadable or empty brief prints
# NO-FILE / EMPTY rather than pretending the parse failed for some subtler reason.
#
# ⛔ THE PARSE IS ONE awk PASS ON PURPOSE. It is the same shape #2148's suite drives and it needs no
# python at dispatch time — a gate that adds an interpreter to every spawn is a gate that will
# eventually be "temporarily" worked around on the box that lacks one.
brief_gate_missing() { # brief_gate_missing <brief-file|->
  local f="${1:--}"
  if [ "$f" != "-" ] && { [ ! -e "$f" ] || [ ! -r "$f" ]; }; then
    printf 'NO-FILE\n'
    return 0
  fi
  if [ "$f" = "-" ]; then
    awk "$BRIEF_GATE_AWK"
  else
    awk "$BRIEF_GATE_AWK" "$f"
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
  miss="$(brief_gate_missing "$f")"
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
    esac
  done <<< "$miss"

  {
    printf '[brief-gate] REFUSED — this dispatch carries NO research contract. NOTHING WAS STARTED: no model call, no session, no claim.\n'
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
}

# brief_gate_line [role] — ONE line for the lane log, so the mandate is visible in what an operator
# greps, exactly like `reviewer_preflight_line` (#2148). The long form is in the brief.
brief_gate_line() { # brief_gate_line [role]
  local role="${1:-lane}"
  printf '[gate] #2258 research-first: this brief carries a RESEARCH FIRST section (INTERNAL + EXTERNAL + RUNG/tool) and a CONTRADICTION TEST line. Do the pass BEFORE deciding anything; if the work is already done or already decided, report that with evidence instead of re-deriving it. The dispatch is REFUSED without both (brief-gate.sh, exit 80).'
}

# ── CLI: for callers, for tests, and for a human who wants the exact text ────────────────────────
#   bash brief-gate.sh --check <file|-> [role]   → 0 pass · 80 refused (message on stderr) · 78 cannot verify
#   bash brief-gate.sh --missing <file|->        → the missing tokens, one per line
#   bash brief-gate.sh --section [role]          → the canonical brief block
#   bash brief-gate.sh --line [role]             → the one-line disclosure
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --check)   shift; brief_gate_verify "${1:--}" "${2:-lane}" ;;
    --missing) shift; brief_gate_missing "${1:--}" ;;
    --section) shift; brief_gate_section "${1:-lane}" ;;
    --line)    shift; brief_gate_line "${1:-lane}" ;;
    *)
      printf 'usage: %s --check <brief-file|-> [lane|fixer|reviewer|worker]\n' "$0" >&2
      printf '       %s --missing <brief-file|-> | --section [role] | --line [role]\n' "$0" >&2
      exit "$BRIEF_GATE_UNAVAILABLE" ;;
  esac
fi
