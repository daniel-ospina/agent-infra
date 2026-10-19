#!/usr/bin/env bash
# ============================================================
# check-false-pass-shapes.sh — the mechanical half of the false-PASS class (agent-infra#2121)
# ============================================================
#
# THE INVARIANT (epic #2096, and the reason this file exists)
# -----------------------------------------------------------
#   **No verdict without an observation, in the same execution.**
#   A success, an empty set, or an "all fine" may be printed only on the strength of a fact
#   THIS RUN read. If the read failed, was empty for an unchecked reason, or produced
#   something unparseable, the only permitted output is UNKNOWN (and, on a destructive path,
#   a refusal).
#
# The fleet's gates are FAIL-CLOSED ON INPUTS and FAIL-OPEN ON OUTCOMES: a missing input is
# caught, a missing OBSERVATION is not. Nineteen open issues are instances of that one defect
# wearing different clothes (#1743, #1663, #1843, #2036, #2041, #2059, #1917, #1926, #1797,
# #1956, #1414, …), and review produced all nineteen — so the remedy is not more review, it is
# a check. Three of the six banned shapes are LEXICALLY detectable; those three are here. The
# semantic remainder (aggregate laundering, silent truncation, idle-equals-dead) stays a
# review responsibility and is OUT OF SCOPE, stated rather than implied.
#
# THE THREE SHAPES (each pinned by a positive AND a near-miss fixture in the suite)
# --------------------------------------------------------------------------------
#   discarded-status          a DECLARATION builtin taking a command substitution:
#                             `local x=$(cmd)`, and the declare/typeset/export/readonly forms.
#                             What `$?` holds afterwards is the BUILTIN's status, so a FAILED
#                             read and an EMPTY read are indistinguishable. (#1743's other
#                             half: `resolve_env` used `command -v python3 || true` on the
#                             same path.)
#   empty-as-pass             a function loops over a SUBSTITUTION (`done < <(cmd)`,
#                             `done <<<`, `for x in $(cmd)`) and returns a flag defaulted to
#                             SUCCESS, with no iteration count and no guard on the feeder's
#                             captured output. The loop can iterate ZERO times and the
#                             function still reports PASS. `verify_targets` in
#                             scripts/install-launchd.sh is the canonical instance (#1743): a
#                             host without python3 made the "a dead job must never be
#                             installed" guard verify NOTHING and exit 0.
#   pre-existing-as-evidence  a verdict line whose evidence is a count of state that existed
#                             BEFORE this run (an unfiltered directory/file listing piped into
#                             a line count) with no recency filter. It proves the directory is
#                             populated, not that this run did anything. (#2041: a deploy
#                             announced "convergence COMPLETE" while cp had copied nothing.)
#
# WHAT THIS GUARD DOES NOT COVER (deliberate, so no green run is over-read)
# -----------------------------------------------------------------------------------
# It is a TEXT matcher, not a flow analysis. It misses:
#   * every semantic shape (aggregate laundering, silent truncation, idle-equals-dead);
#   * a discarded status whose consequence is not lexically visible — a plain `VAL=$(cmd)`
#     assignment used as if non-empty is ubiquitous and usually harmless, so flagging it
#     would flag half the repo. Only the DECLARATION-BUILTIN form is banned here, because that
#     is the form where the masking is SILENT;
#   * a zero-iteration loop in a function that returns nothing (an implicit status from the
#     last command) — indistinguishable in the text from a deliberate "return what I just ran".
#   * a guarded copy followed by a count of the copy — `mkdir -p DIR && cp -R SRC/. DIR/ || die`
#     then a verdict printing a count of what just landed — is THIS RUN's output, not the third
#     shape, but the text cannot tell it from a pre-run listing; and a cleanup loop whose empty
#     input is a legitimate PASS is not the second shape either. Both ARE reported, and the right
#     response is ONE `# verified:` marker with the reason, not a rewrite. Named here so the first
#     encounter is a marker rather than a mystery.
# A GREEN RUN MEANS "the three recognised idioms are absent from the SCANNED SET (see
# --list-targets) or baselined" — never "no false-PASS risk exists in this repo". The set is
# `scripts/*.sh` and `scripts/orchestrator-harness/*.sh`; other subtrees are not covered.
#
# THE BASELINE IS A SET OF CLAIMS, KEYED BY (file, rule, COUNT) — never by line number
# ----------------------------------------------------------------------------------
# Today's tree contains known instances that belong to their own open issues (listed in
# scripts/false-pass-baseline.tsv with the tracking issue). They are grandfathered BY COUNT:
#   * a NEW instance in a file that already has a baselined one raises that file's count and
#     FAILS — the baseline cannot swallow a regression;
#   * the key is not a line number, so an unrelated edit above a finding does not red a peer
#     lane's CI (a false block on other people's PRs is how a guard gets deleted);
#   * a baseline entry with NO matching finding is reported as `note: … STALE` (the finding
#     was fixed, or the code changed). It does NOT fail — failing on "you fixed it" is
#     perverse — and the stale count is printed in every run's summary, so an entry cannot rot
#     silently;
#   * an entry with no justification is a FINDING: the baseline is a set of claims, and a
#     claim without a reason is exactly the class this check exists to catch.
#
# THE OPT-OUT MARKER — `# verified: <why this is NOT the shape>`
# ----------------------------------------------------------------------------------
# A genuine exception (correct-but-unusual code) is exempted with a marker on the finding's
# line or the line immediately above it. The marker is AUDITABLE: a marker with no
# justification (bare `# verified:`, or `TODO`/`?`/`x`) does NOT grant an exemption and is
# itself a finding — an unexplained exemption is an exemption nobody reviewed.
#
# CONTRACT
#   bash scripts/check-false-pass-shapes.sh [--baseline <file>] [--root <dir>]
#                                           [--update-baseline] [--list-rules]
#                                           [--list-targets] [--help]
#
#   --baseline <file>   the baseline to read (default: <root>/scripts/false-pass-baseline.tsv)
#   --root <dir>        the tree to scan (default: this script's repo). The suite uses it to
#                       drive the check against FIXTURE trees, so the rules have one home.
#   --update-baseline   REWRITE the baseline from this run's findings, preserving each entry's
#                       justification. A human reviews that diff; it is the only supported way
#                       to add a group, and it prints what it wrote.
#   --list-rules        print the rule ids, one per line (the doc/tests read THIS, not a copy)
#   --list-targets      print the files the scan covers (same reason)
#
# Output: `path:line: RULE: message` per finding, `baselined: …` per grandfathered occurrence,
# `note: …` for stale entries, one summary line, then a verdict word.
# Exit:   0 = clean, 1 = findings or a malformed baseline, 2 = usage.
# ============================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
BASELINE=""          # resolved AFTER --root is known (the default lives beside the scan set)
UPDATE_BASELINE=0

# ── the scan set (ONE declaration; --list-targets prints exactly this) ──────────
# `scripts/*.sh` is the repo's top-level gates and helpers; `scripts/orchestrator-harness/*.sh`
# is the lane/rail machinery that prints most of the fleet's verdicts. Test suites are
# INCLUDED on purpose — a false PASS inside a suite is how a broken gate ships green.
SCAN_GLOBS=("scripts/*.sh" "scripts/orchestrator-harness/*.sh")
RULES=("discarded-status" "empty-as-pass" "pre-existing-as-evidence" "marker-without-justification" "unterminated-heredoc")

# Prints the header block (lines starting with `#`, from line 2) and exits 2 for a USAGE ERROR.
# The range is COMPUTED, never a hardcoded line window: a window that outruns the header prints
# implementation as help, and one that stops early hides part of the contract (both measured in
# review round 1 against a hardcoded '2,112p').
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --baseline) [ "$#" -ge 2 ] || usage; BASELINE="$2"; shift ;;
    --baseline=*) BASELINE="${1#--baseline=}" ;;
    # --root lets the SUITE drive this check against a fixture tree (and lets a lane verify a
    # worktree without a second copy of the rules). The scan set and the default baseline are
    # both relative to it, so one flag moves the whole contract.
    --root) [ "$#" -ge 2 ] || usage; ROOT="$(cd "$2" 2>/dev/null && pwd)" || { echo "FAIL: --root '$2' is not a directory" >&2; exit 2; }; shift ;;
    --root=*) ROOT="$(cd "${1#--root=}" 2>/dev/null && pwd)" || { echo "FAIL: --root '${1#--root=}' is not a directory" >&2; exit 2; } ;;
    --update-baseline) UPDATE_BASELINE=1 ;;
    --list-rules) printf '%s\n' "${RULES[@]}"; exit 0 ;;
    --list-targets)
      for p in "${SCAN_GLOBS[@]}"; do
        for f in "$ROOT"/$p; do
          [ -f "$f" ] || continue
          printf '%s\n' "${f#"$ROOT"/}"
        done
      done
      exit 0 ;;
    --help|-h) usage ;;
    *) echo "usage: $(basename "$0") [--baseline <file>] [--update-baseline] [--list-rules] [--list-targets] [--help]" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$BASELINE" ] || BASELINE="$ROOT/scripts/false-pass-baseline.tsv"

# ── the scanner ──────────────────────────────────────────────────────────────
# One awk pass per file, emitting TAB-separated rows (`file  line  rule  message`) so the
# decision half never re-parses prose.
# ⛔ THE MARKER IS READ HERE, in the same pass that finds the shape: "is this line exempt?"
# must not be answered by a second reader that could disagree (that is the two-definitions
# defect this whole check is about).
#
# awk state, per FILE (the scanner is invoked once per file):
#   prev_marker / prev_marker_bad / prev_marker_line — a `# verified:` on the previous line
#   fn — the enclosing function ("" at top level)
#   fn_loop / fn_loop_line — the first substitution-fed loop in that function
#   fn_counter             — an iteration count or a guard on a CAPTURED feeder output
#   fn_flagret             — the function returns a flag VARIABLE
#   captured[]             — vars assigned from a command substitution in this function
# scan_file <file> — the scanner, kept INLINE (not in a variable): an interpreter whose
# program is an expansion (`awk "$PROG" file`) is refused by the worktree discard guard
# (#1228 class) because its effect cannot be read statically. An inline literal can.
scan_file() {
  awk '
function heredoc_delim(line,   p, i, n, ch, name, after) {
  # A heredoc whose delimiter is QUOTED suppresses expansion, so its body is DATA (a fixture, a
  # template, a test case) rather than statements bash runs. Returned WITHOUT the quotes.
  # `sq` (set in BEGIN via sprintf) is the single-quote character, written that way because this
  # whole program lives inside a shell single-quoted string.
  #
  # ⛔ A COMMENT IS NOT CODE. A line whose first non-blank character is `#` can MENTION a heredoc
  # opener without opening one, and treating it as one blinded the scanner for the REST OF THE
  # FILE while the run still printed PASS — measured on scripts/check-no-sigpipe-grep.sh:81, whose
  # comment quoted an opener and so skipped 1,900+ lines. That is the no-op gate this whole file
  # exists to catch, inside this whole file.
  if (match(line, /^[ \t]*#/)) return ""
  p = index(line, "<<")
  if (p == 0) return ""
  # AND NEITHER IS A QUOTED STRING: a shell line that PASSES a heredoc opener as DATA to grep
  # opener as DATA to grep. Bash opens a heredoc only when the `<<` is followed by a delimiter and
  # then by a REDIRECT/END — never by the quote that closes a string (review round 2).
  i = p + 2; n = length(line)
  if (i <= n && substr(line, i, 1) == "-") i++
  while (i <= n && (substr(line, i, 1) == " " || substr(line, i, 1) == "\t")) i++
  if (i > n) return ""
  ch = substr(line, i, 1)
  if (ch == "\"" || ch == "\\" || ch == sq) i++
  else return ""
  name = ""
  while (i <= n) {
    ch = substr(line, i, 1)
    if (ch ~ /[A-Za-z0-9_]/) { name = name ch; i++ } else break
  }
  if (name == "") return ""
  # The CLOSING quote belongs to the delimiter token, not to a following redirect — without this
  # the after-test below rejects every quoted opener (the opener ends WITH its quote).
  if (i <= n) {
    ch = substr(line, i, 1)
    if (ch == "\"" || ch == "\\" || ch == sq) i++
  }
  while (i <= n && (substr(line, i, 1) == " " || substr(line, i, 1) == "\t")) i++
  after = (i > n) ? "" : substr(line, i, 1)
  if (after != "" && after != ">" && after != "|" && after != ";" && after != ")" && after != "&") return ""
  return name
}
function has_listing_cmd(left,   t) {
  # A LISTING COMMAND, at a command position — not the substring `ls` inside `labels`/`signals`
  # and not `find` inside the word findings, which is the most common noun in this repo (round 2).
  t = left
  while (match(t, /(^|[ \t(`$])(ls|find)([ \t]|$)/)) {
    return 1
  }
  return 0
}
function inside_quotes(line, pos,   i, c, n, dq, sqn) {
  # Is character `pos` inside a double- or single-quoted region of `line`? Used for the `# verified:`
  # marker: a PRINTED string that mentions the marker must not manufacture an exemption
  # (review round 2).
  dq = 0; sqn = 0
  for (i = 1; i < pos && i <= length(line); i++) {
    c = substr(line, i, 1)
    if (c == "\\") { i++; continue }
    if (c == "\"" && sqn == 0) { dq = !dq; continue }
    if (c == sq && dq == 0) { sqn = !sqn }
  }
  return (dq || sqn)
}
function is_cmd_subst(line) {
  # `$(cmd)` masks a command status through a declaration builtin; `$((arith))` does NOT — there
  # is no command whose status could be lost, and flagging it reds correct code (measured in
  # review round 1: `local n=$(( a * 100 / b ))` was reported as a masked command substitution).
  if (!match(line, /="?\$\(/)) return 0
  return substr(line, RSTART + RLENGTH, 1) != "("
}
function guard_on_captured(line,   v) {
  # `[ -n "$x" ]` / `[ -z "$x" ]` where $x was CAPTURED from a substitution is the emptiness
  # guard the empty-as-pass shape lacks. A test on any OTHER variable is not: `[ -n "$arg" ] ||
  # continue` skips one ITEM, it never notices that the feeder produced nothing (#1743).
  if (match(line, /\[[ \t]+-[nz][ \t]+"\$[A-Za-z_][A-Za-z0-9_]*/)) {
    v = substr(line, RSTART, RLENGTH); sub(/.*\$/, "", v)
    if (v in captured) return 1
  }
  return 0
}
function flush_fn() {
  if (fn != "" && fn_loop != "" && fn_flagret != "" && fn_counter == "" && (fn_flagret in flaginit))
    printf "%s\t%d\t%s\t%s\n", FILENAME, fn_loop_line, "empty-as-pass", \
      "the loop over a substitution can iterate ZERO times and " fn "() still returns a flag INITIALISED TO SUCCESS, so a feeder that emitted nothing is a PASS here"
  fn = ""; fn_loop = ""; fn_loop_line = 0; fn_counter = ""; fn_flagret = ""
  split("", captured); split("", flaginit)
}
BEGIN { prev_marker = 0; prev_marker_bad = 0; prev_marker_line = -1
        fn = ""; fn_loop = ""; fn_loop_line = 0; fn_counter = ""; fn_flagret = ""
        heredoc = ""; heredoc_dash = 0; sq = sprintf("%c", 39) }
{
  # ⛔ A QUOTED HEREDOC IS DATA, NOT CODE. A heredoc whose delimiter is quoted (EOS in single
  # quotes, double quotes, or backslash-escaped) suppresses expansion, so
  # its body is a FIXTURE, a template or a test case — never statements bash runs unless a caller
  # feeds it to an interpreter. Scanning it flags the very fixture a suite needs to prove this
  # guard detects anything (the shapes must exist somewhere), and a linter that reds its own test
  # is deleted from CI within a week. An UNQUOTED heredoc IS still scanned: its body is generated
  # bash. This is the same reasoning as "a comment is not code" and it is stated rather than
  # implied, because it is the one place a shape can hide from this check.
  if (heredoc != "") {
    # `<<-` strips leading TABS from the terminator, so the comparison must too — otherwise a
    # tab-indented terminator never matches and the heredoc swallows the rest of the file.
    t = $0
    if (heredoc_dash) sub(/^[ \t]+/, "", t)
    if (t == heredoc) { heredoc = ""; heredoc_dash = 0 }
    next
  }
  delim = heredoc_delim($0)
  if (delim != "") { heredoc = delim; heredoc_dash = (index($0, "<<-") > 0) }
  # ⛔ FUNCTION BOUNDARIES ARE TRACKED HERE, AFTER the heredoc skip: a fixture body may legitimately
  # contain a function header and a closing brace, and tracking those would attribute fixture lines
  # to a function (and cut a real function short at the closing brace of the fixture).
  # ⛔ A CLOSING BRACE IS RECOGNISED AT ANY INDENT: `slack()` in heartbeat-loop.sh closes with an
  # indented `  }` inside a nesting block, and requiring column 0 left the function OPEN over the
  # rest of the file (review round 1). `function name()` is recognised too, because the awk
  # helpers in this scan set spell their headers that way.
  if ($0 ~ /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_]*/) { flush_fn(); fn = $0; sub(/^[ \t]*function[ \t]+/, "", fn); sub(/[ \t(].*/, "", fn); next }
  if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/ || $0 ~ /^[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{/) {
    flush_fn(); fn = $0; sub(/^[ \t]*/, "", fn); sub(/[ \t]*\(\).*/, "", fn)
    # ⛔ A ONE-LINE BODY IS NOT SKIPPED: `f() { local x=$(cmd); … }` is a whole function on one line,
    # and `next` here made both line rules blind to it (review round 3). Drop the header and fall
    # through to the line rules on whatever follows the opening brace.
    if (index($0, "{") > 0) { $0 = substr($0, index($0, "{") + 1) } else { next }
  }
  if ($0 ~ /^[ \t]*}/) { flush_fn(); next }
  # ⛔ A COMMENT IS NOT CODE, for the RULES and the bookkeeping too. Bookkeeping over comment text
  # let a comment containing `wc -l` silently DISABLE empty-as-pass for a whole function, while a
  # comment quoting a loop reported the comment line itself as the finding (round 2). A comment
  # can still carry the MARKER — that is where an exemption lives — so markers are read below.
  is_comment = ($0 ~ /^[ \t]*#/)
  line = $0
  has_marker = 0; marker_bad = 0
  # The marker must sit at a WORD BOUNDARY and OUTSIDE QUOTES: a printed string that mentions it
  # must not manufacture an exemption (round 2).
  if (match(line, /(^|[ \t])#[ \t]*verified:/) && !inside_quotes(line, RSTART + RLENGTH - 7)) {
    has_marker = 1
    reason = line; sub(/.*#[ \t]*verified:[ \t]*/, "", reason); sub(/[ \t]+$/, "", reason)
    if (reason == "" || reason ~ /^([Tt][Oo][Dd][Oo]|\?|\.\.\.|x)$/) marker_bad = 1
  }
  # A valid marker exempts its OWN line and the NEXT one (the marker sits above the code).
  # An INVALID marker exempts nothing — and is reported as its own finding.
  exempt = ((has_marker && !marker_bad) || (prev_marker && !prev_marker_bad && prev_marker_line == FNR - 1))
  if (has_marker && marker_bad)
    printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, "marker-without-justification", \
      "`# verified:` carries no reason, so it does not exempt the code below and an exemption nobody can read is an exemption nobody reviewed"

  if (!exempt && !is_comment) {
    # `="?` — an OPTIONAL opening quote: `local x="$(cmd)"` masks the status exactly as the
    # unquoted form does, and it is the spelling this fleet mostly uses. `is_cmd_subst` keeps
    # `$((arith))` out of the rule (see its comment).
    if (line ~ /^[ \t]*(local|declare|typeset|export|readonly)[ \t]+(readonly[ \t]+)?[A-Za-z_][A-Za-z0-9_]*="?\$\(/ && is_cmd_subst(line))
      printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, "discarded-status", \
        "the declaration builtin masks the exit status of the command substitution, so a FAILED read and an EMPTY one are indistinguishable"

    # ⛔ A LISTING COMMAND AT A COMMAND POSITION, never the substring `ls` in labels/signals or
    # `find` in the word findings (round 2).
    lpos = index(line, "wc -l")
    if (lpos > 0 && has_listing_cmd(substr(line, 1, lpos - 1))) {
      verdict = (line ~ /(COMPLETE|complete|installed|Installed|verified|VERIFIED|✅|✔|✓|PASS|passed|succeeded|success|healthy|OK|ok:)/)
      # `status --porcelain` (not `git status`) is the recency alternative for a dirty-count
      # verdict: a working-tree listing IS a read of THIS run, so it is not the shape.
      recency = (line ~ /(-newer|-mmin|-cmin|-newermt|-anewer|diff |cmp | -nt | -ot |status --porcelain)/)
      if (verdict && !recency)
        printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, "pre-existing-as-evidence", \
          "a count of state that existed BEFORE this run is printed as the evidence for the verdict, so it does not prove this run did anything"
    }
  }

  # Function-scope bookkeeping runs whether or not this LINE is exempt (an exemption covers one
  # construct, not the function it lives in) — but NEVER on a comment line (see above).
  if (fn != "" && !is_comment) {
    if (match(line, /^[ \t]*(local[ \t]+|declare[ \t]+|typeset[ \t]+)?[A-Za-z_][A-Za-z0-9_]*="?\$\(/)) {
      v = substr(line, RSTART, RLENGTH); sub(/^.*[ \t]/, "", v); sub(/=.*/, "", v); captured[v] = 1
    }
    if (fn_loop == "" && (line ~ /done[ \t]*<[ \t]*<\(/ || line ~ /done[ \t]*<<</ || line ~ /for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+\$\(/)) {
      fn_loop = 1; fn_loop_line = FNR
    }
    # A COUNTER, not an ordinary status test: `=$((`, `++`, `+= 1` and `wc -l` can only be an
    # iteration count. A bare `-eq 0`/`-gt 0` is usually a STATUS test, and counting it as proof of
    # iteration let the canonical shape hide behind `[ "$rc" -eq 0 ]` (review round 1).
    # The spelling that ASSIGNS then checks `|| return 1` on the same line IS the correct fix and
    # status is observed on the same line (review round 2). Only return/exit/die/fail count —
    # `|| continue` is a per-ITEM skip and says nothing about an empty feeder.
    if (line ~ /=\$\(\(/ || line ~ /\+\+/ || line ~ /\+= 1/ || line ~ /wc -l/ || guard_on_captured(line) || line ~ /\|\|[ \t]*(return|exit|die|fail)([ \t;]|$)/)
      fn_counter = 1
    # The POLARITY of the returned flag, recorded from its DECLARATION so the finding can claim
    # "success-default": `local bad=0` is a flag that passes unless a check clears it. A
    # fail-closed function (`local ok=1` ... `ok=0` ... `return "$ok"`) has the OPPOSITE contract,
    # so an assignment anywhere is NOT evidence — only the declaration default is (review round 1).
    if (line ~ /^[ \t]*(local|declare|typeset)[ \t]/) {
      t = line
      while (match(t, /[A-Za-z_][A-Za-z0-9_]*=0([ \t;]|$)/)) {
        w = substr(t, RSTART, RLENGTH); sub(/=.*/, "", w); flaginit[w] = 1
        t = substr(t, RSTART + RLENGTH)
      }
    }
    if (line ~ /^[ \t]*return[ \t]+"?\$[A-Za-z_][A-Za-z0-9_]*"?[ \t]*;?[ \t]*$/) {
      v = line; sub(/^[ \t]*return[ \t]+"?\$/, "", v); sub(/".*/, "", v); sub(/[ \t;].*/, "", v)
      fn_flagret = v
    }
  }

  prev_marker = has_marker; prev_marker_bad = marker_bad; prev_marker_line = FNR
}
END { flush_fn()
      # ⛔ AN UNTERMINATED QUOTED HEREDOC IS A LOUD FAILURE, never a silent blind spot: everything
      # after its opener was skipped, so whatever the scan would have found there is UNKNOWN — and
      # unknown is not clean.
      if (heredoc != "")
        printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, "unterminated-heredoc", \
          "a quoted heredoc opened and was never closed, so every line after it was SKIPPED — the scan of this file is PARTIAL and cannot be reported as clean"
    }
' "$1"
}

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/false-pass-shapes.XXXXXX")" || { echo "FAIL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMPDIR_RUN"' EXIT
TARGETS="$TMPDIR_RUN/targets"; FINDINGS="$TMPDIR_RUN/findings"; DECIDED="$TMPDIR_RUN/decided"
BASE_SAFE="$TMPDIR_RUN/baseline"
: > "$TARGETS"; : > "$FINDINGS"; : > "$DECIDED"

# ⛔ THE JOIN BELOW USES `NR == FNR` TO SPLIT ITS TWO FILES, AND THAT IDIOM IS WRONG WHEN THE
# FIRST FILE IS EMPTY: NR and FNR are both 1 on the second file's first line, so that line is
# consumed as if it were baseline and a real finding silently disappears. Measured here on
# the first run (an absent baseline made the join eat a finding and report 0). A synthetic
# first line makes the split total, whatever the baseline holds.
base_for_join() {
  printf '# false-pass-shapes baseline (synthetic first line: see the NR==FNR note above)\n' > "$BASE_SAFE"
  [ -f "$BASELINE" ] && cat "$BASELINE" >> "$BASE_SAFE"
  return 0
}

for p in "${SCAN_GLOBS[@]}"; do
  # ⛔ `"$ROOT"/$p` — the ROOT is QUOTED and only the glob expands. Unquoted `$ROOT/$p` word-splits
  # a checkout path containing a space into pieces that are all non-files, which collects ZERO
  # targets and used to print PASS over a scan of nothing (review round 1).
  for f in "$ROOT"/$p; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f" >> "$TARGETS"
  done
done
if [ ! -s "$TARGETS" ]; then
  echo "FAIL: the scan set matched NO files under $ROOT — a scan of nothing is not a PASS (#2096)" >&2
  exit 1
fi

scanned=0
scan_failures=0
: > "$TMPDIR_RUN/scan-errors"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  scanned=$((scanned + 1))
  # ⛔ A SCANNER THAT CANNOT RUN MUST NOT REPORT PASS. This is the no-op-gate shape the check
  # itself exists to catch (#2096): an awk that rejects its own program exits non-zero, and if
  # that status were swallowed every file would read as "no findings" while this gate certified
  # the absence it cannot see. The status is therefore read, and the reason is kept.
  scan_file "$f" >> "$FINDINGS" 2>> "$TMPDIR_RUN/scan-errors" || {
    echo "FAIL: the scanner could not run on $f (awk rejected the program) — a scan that did not happen cannot be a PASS" >&2
    scan_failures=$((scan_failures + 1))
  }
done < "$TARGETS"
if [ "$scan_failures" -gt 0 ]; then
  echo "FAIL: $scan_failures file(s) could not be scanned (see above)" >&2
  exit 1
fi

# Paths become REPO-RELATIVE here, once, by exact-string prefix removal. `index()`/`substr`
# rather than a regex substitution: a checkout path legitimately contains `.`, `+` and `[`, and
# a regex would rewrite the wrong span of a path that merely LOOKS like the root.
if [ -s "$FINDINGS" ]; then
  awk -F'\t' -v OFS='\t' -v root="$ROOT/" '
    { if (index($1, root) == 1) $1 = substr($1, length(root) + 1); print }
  ' "$FINDINGS" > "$FINDINGS.rel" && mv -f "$FINDINGS.rel" "$FINDINGS"
fi

# ── --update-baseline: rewrite from this run, preserving each entry's justification ──
if [ "$UPDATE_BASELINE" -eq 1 ]; then
  base_for_join
  tmp="$BASELINE.tmp.$$"
  {
    printf '# scripts/false-pass-baseline.tsv — grandfathered false-PASS findings (agent-infra#2121)\n'
    printf '#\n'
    printf '# WHY A BASELINE AND NOT A FIX: each group below is a KNOWN instance that belongs to its\n'
    printf '# own open issue (named per line). The check still reports it, and a NEW instance of the\n'
    printf '# same rule in the same file raises the count and FAILS — this file cannot swallow a\n'
    printf '# regression. Keyed by (path, rule, COUNT), never by line number: an unrelated edit above\n'
    printf '# a finding must not red a peer lane'\''s CI.\n'
    printf '#\n'
    printf '# FORMAT: <path>\t<rule>\t<count>\t<tracking issue + why this is still open>\n'
    printf '# Rewrite with: bash scripts/check-false-pass-shapes.sh --update-baseline\n'
    printf '# The 4th column is REQUIRED: an entry with no justification is reported as a finding.\n'
    # ⛔ A NEW GROUP IS WRITTEN WITH AN EMPTY 4th COLUMN, never with a placeholder sentence: a
    # placeholder is non-empty, so it would satisfy the justification check and become
    # indistinguishable from a real one on the next run (review round 1). Empty = the check FAILS
    # until a human names the tracking issue, which is the intended pressure.
    awk -F'\t' '
      NR == FNR { if ($0 ~ /^#/ || NF < 3) next; note[$1 SUBSEP $2] = ($4 == "" ? "" : $4); next }
      { c[$1 SUBSEP $3]++ }
      END {
        for (k in c) {
          split(k, a, SUBSEP)
          printf "%s\t%s\t%d\t%s\n", a[1], a[2], c[k], (k in note ? note[k] : "")
        }
      }' "$BASE_SAFE" "$FINDINGS" 2>>"$TMPDIR_RUN/update-errors" \
      | sort > "$tmp.body"
    # ⛔ THE GENERATOR'S STATUS IS CHECKED, not just assumed: awk failing through a pipeline into
    # `sort` writes an EMPTY body, and `mv` over the baseline would then silently retire every
    # group. `set -o pipefail` is on, and the status is read here.
    # ⛔ AN EMPTY BODY IS LEGAL (review round 2): zero findings — the state a lane reaches AFTER
    # fixing the last baselined instance — means an empty baseline, not a generator failure. Only a
    # non-zero status is a failure.
    if [ "$?" -ne 0 ]; then
      cat "$TMPDIR_RUN/update-errors" >&2 2>/dev/null || true
      echo "FAIL: --update-baseline could not generate the entries (awk failed) — the baseline was NOT rewritten" >&2
      rm -f "$tmp.body"
      exit 1
    fi
    if [ ! -s "$tmp.body" ]; then
      echo "no findings remain — the baseline records NO groups (that is the goal, not an error)" >&2
    fi
    cat "$tmp.body"
    rm -f "$tmp.body"
  } > "$tmp"
  if ! mv -f "$tmp" "$BASELINE"; then rm -f "$tmp"; echo "FAIL: could not write $BASELINE" >&2; exit 1; fi
  echo "baseline written: $BASELINE"
  echo "review the diff — every added group needs a tracking issue, and every removed group is a fix."
  exit 0
fi

# ── decide: join the baseline against the findings, in one pass ──────────────
# The join is awk, not bash arrays: the fleet runs bash 3.2 on macOS, where `declare -A` does
# not exist, and a guard that silently degrades on one platform is the class this file is about.
# ⛔ READ-ONLY: this check never creates or edits the baseline (a check that writes its own
# exemptions is the bypass shape). An ABSENT baseline is not an error — it means nothing is
# grandfathered, so every finding fails, which is the safe direction.
base_for_join
awk -F'\t' '
  NR == FNR {
    if ($0 ~ /^#/ || NF < 3) next
    if ($3 !~ /^[0-9]+$/) { print "MALFORMED\t" $1 "\t" $2 "\t" $3; next }
    nb++; bkeys[nb] = $1 SUBSEP $2
    base[bkeys[nb]] = $3 + 0
    note[bkeys[nb]] = ($4 == "" ? "" : $4)
    next
  }
  {
    k = $1 SUBSEP $3
    seen[k]++
    # ⛔ `base[k]` here would AUTO-VIVIFY the element in awk (a read creates the key), which
    # made every finding appear as an unjustified baseline entry on the first run. `k in base`
    # is the non-creating test.
    lim = (k in base) ? base[k] : 0
    if (seen[k] <= lim) printf "BASELINED\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4
    else                printf "FINDING\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4
  }
  END {
    # Iterate the RECORDED key list, never `for (k in base)` — see the auto-vivification note.
    for (i = 1; i <= nb; i++) {
      k = bkeys[i]
      split(k, a, SUBSEP)
      if (seen[k] + 0 < base[k])
        printf "STALE\t%s\t%s\t%d\t%d\n", a[1], a[2], base[k], seen[k] + 0
      if (note[k] == "")
        printf "UNJUSTIFIED\t%s\t%s\n", a[1], a[2]
    }
  }' "$BASE_SAFE" "$FINDINGS" > "$DECIDED"
  # ⛔ THE DECISION READER'S STATUS IS CHECKED TOO. If this awk fails, `$DECIDED` is empty, every
  # counter stays 0 and the run prints PASS — the exact fail-open shape the scan half already
  # guards against (review round 3). Two readers, one rule.
  if [ "$?" -ne 0 ]; then
    echo "FAIL: the baseline/findings join could not run (awk rejected the program) — a decision that did not happen cannot be a PASS" >&2
    exit 1
  fi

findings=0; baselined=0; stale=0; unjustified=0; malformed=0
while IFS=$'\t' read -r kind a b c d; do
  case "$kind" in
    BASELINED) baselined=$((baselined + 1)); echo "baselined: $a:$b: $c: $d" ;;
    FINDING)   findings=$((findings + 1));   echo "$a:$b: $c: $d" ;;
    STALE)     stale=$((stale + 1));         echo "note: baseline entry is STALE: $a ($b) expected $c, found $d — the finding was fixed or the code moved; re-record with --update-baseline" ;;
    UNJUSTIFIED) unjustified=$((unjustified + 1)); echo "FAIL: baseline entry without a justification: $a ($b) — name the tracking issue in the 4th column" ;;
    MALFORMED) malformed=$((malformed + 1)); echo "FAIL: malformed baseline entry: $a ($b) has count '$c' — regenerate with --update-baseline" ;;
  esac
done < "$DECIDED"

echo "── false-PASS shapes: $scanned file(s) scanned · $findings finding(s) · $baselined baselined · $stale stale baseline entr(y|ies) · $unjustified unjustified · $malformed malformed ──"
if [ "$findings" -gt 0 ] || [ "$unjustified" -gt 0 ] || [ "$malformed" -gt 0 ]; then
  echo "FAIL: no verdict without an observation (#2096). Fix the shape, or exempt one line with '# verified: <why it is not the shape>'."
  exit 1
fi
echo "PASS: no finding in the SCANNED SET ($scanned file(s); see --list-targets) — the three shapes are absent there, or baselined against an open tracking issue."
exit 0
