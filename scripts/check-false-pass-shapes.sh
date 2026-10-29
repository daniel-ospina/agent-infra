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
#                             `done <<<`, `for x in $(cmd)`) — OR over a variable CAPTURED from
#                             one, `out="$(cmd)"` then `for x in $out`, which is the same feeder
#                             one assignment earlier and is the spelling an independent scan of
#                             the same three shapes found its instances in — and returns a flag
#                             defaulted to SUCCESS, with no iteration count and no guard on the
#                             feeder's captured output. The loop can iterate ZERO times and the
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
# ⛔ THE SAME GAP, MEASURED — and the reason the capture-then-iterate *spelling* was widened but
# the *verdict half* was not. The rule needs the PASS to be lexically visible, which today means a
# flag defaulted to success and returned (`local bad=0 … return "$bad"`). The two shapes it
# therefore cannot see are a loop at SCRIPT TOP LEVEL (no verdict to key on) and a function whose
# success verdict is a LITERAL `return 0`. An independent implementation of these same three
# shapes found exactly three instances, all of them that form:
#   scripts/daily-backup.sh:282 · scripts/orchestrator-harness/fix-one.sh:139 ·
#   scripts/orchestrator-harness/test-crossbox.sh:91
# Widening the verdict half to a literal `return 0` was MEASURED against this scan set and reds
# SEVEN further functions (check-pipeline-compliance.sh:503, cleanup-stale-branches.sh:903,1021,
# pi-cache-reap.sh:656, reap-lane-venvs.sh:482, restore-smoke.sh:64, worktree-hygiene-sweep.sh:234)
# — including restore-smoke.sh:64, whose `newest_backup_dir()` is FAIL-CLOSED, returning 1 when the
# feeder is empty. Deciding which of those seven are real needs a per-function reading, and that is a
# review, not a text match; the trade this header already refuses is a linter that reds correct code
# (it is deleted from CI within a week, taking the class with it). So the three named instances were
# FIXED — the read's status is observed and an unreadable list is UNKNOWN rather than empty — instead
# of baselined, and the residual is STATED here rather than implied by a green run.
# AMONG the shapes it cannot see, and not the only ones: a for-list SPLIT ACROSS LINES (`for x in \` then
# `$out; do`) — the matcher is line-oriented, so the word list must be on one line, as it is for the
# `for x in $(cmd)` arm — and a feeder filled by `read -r out < <(cmd)`, which is a read, not a capture.
# Nor is an EXPLICITLY EMPTIED feeder: `out="$(cmd)"` then `out=""` then `for x in $out` is dropped by
# the reassignment arm, because that emptiness is stated in the code rather than unobserved — the shape
# is a feeder that emitted nothing the author did not account for. (`read -r out <<< …` and `unset out`
# count as stated too, unless they sit in a subshell; `printf -v out` and `mapfile`/`readarray` are NOT
# tracked and so are not seen.)
# ⛔ AND A QUOTED EXPANSION IS NOT A BLIND SPOT IN GENERAL (#2121 review rounds 4-5): `for x in "$out"`
# over a SCALAR iterates once even when empty, which is why it is not the shape — but `for x in
# "${arr[@]}"` over an EMPTY ARRAY iterates ZERO times, so the quoted array form IS detected and both
# `arr=($(cmd))` and `arr=( $(cmd) )` are registered as ARRAY captures. The earlier note here claimed
# quoting was safe full stop, which was false for arrays. The distinction is the variable's own kind: a
# name registered by a scalar capture (`out="$(cmd)"`) iterates ONCE under `"${out[@]}"`, so it is not
# the shape either — only a name the ARRAY arm captured is (`is_arrcap`).
# ⛔ AND THE BRACE COUNT IS A HEURISTIC, NOT A PARSER — declared because it bounds what a finding can
# mean: a file whose brace depth does not return to zero by EOF has its trailing part attributed to the
# block that swallowed it, so findings there are approximate. That is why the walk keeps a STACK of
# quoting contexts (`$(` and a backtick push a FRESH one, because bash parses them independently) instead
# of two global booleans: with two booleans an ordinary line — a `sed -n` capture whose program carries an
# s///, a single-quoted span and escaped double quotes, assigned inside a double-quoted substitution —
# desynchronised the carry, which left the block open for the REST OF THE FILE (`bash -n`-clean, and the
# run printed PASS over it). Measured at the commit before that fix: 12 of 167 files in the scan set
# drifted this way. Measured after it: 0. A file that still cannot be delimited is therefore a FAILURE —
# `partial scan(s)` for a brace count that never returns, `unterminated-heredoc` for a body that never
# ends, `unterminated-quote` for a quote carry still open at EOF (review round 4: an open carry is proof
# of desync on a `bash -n`-clean file, and it used to be the ONE shape that produced neither a finding
# nor a partial note — `0 finding(s) · 0 partial scan(s) · PASS` over a real `empty-as-pass`) — never a
# green run with a stderr note, and a shape found in a drifted tail is REPORTED with the drift named
# rather than gated away by an iteration count that the drift itself made untrustworthy.
# ⛔ AND ITS COST IS LINEAR IN THE LINE LENGTH, which is a correctness property here, not a nicety: a gate
# that HANGS cannot report anything, so it is worse than one that reds. Every "identifier followed by an
# operator" arm used to be an UNANCHORED regex (`/[A-Za-z_][A-Za-z0-9_]*\+\+/` and friends), and awk
# restarts such a pattern at every position, each attempt consuming the whole remaining identifier run
# before failing — so ONE long code line cost O(length^2). Measured before the fix: 1 KB 0.1 s, 20 KB
# 12 s, 100 KB never returned (>120 s), while a COMMENT of the same length was instant. The identifiers
# are collected once per line (scan_words) and the arms read that list.
# STILL NOT SEEN, and named so the omission is reviewable rather than inferred: a WHOLE FUNCTION WRITTEN
# ON ONE LINE (`f() { local bad=0; out="$(cmd)"; for x in $out; …; return "$bad"; }`) — its body reaches
# the line rules, but the verdict is recorded only from a line that IS a `return`, so `empty-as-pass`
# cannot fire there; a SLICE of an array
# (`for x in "${arr[@]:1}"` — an empty array sliced from 1 also iterates zero times), a capture written
# in a `case` arm (`a) names="$(cmd)" ;;`) or after `|`-into-a-subshell, `printf -v`, `mapfile`/
# `readarray`, and a for-list whose word is an element (`for x in "$arr"). (Deriving from the capture —
# `out="$out extra"`, `out="${out%…}"`, `out+=" …"`, or copying it to another name — keeps it a capture
# and IS still the shape: capture-ness is followed through variable references, so a copy a hop or three
# away is followed too, and a literal that merely EMBEDS a captured name is not mistaken for one.)
#   * a guarded copy followed by a count of the copy — `mkdir -p DIR && cp -R SRC/. DIR/ || die`
#     then a verdict printing a count of what just landed — is THIS RUN's output, not the third
#     shape, but the text cannot tell it from a pre-run listing; and a cleanup loop whose empty
#     input is a legitimate PASS is not the second shape either. Both ARE reported, and the right
#     response is ONE `# verified:` marker with the reason, not a rewrite. Named here so the first
#     encounter is a marker rather than a mystery.
#   * what quoting model it uses, and what that model still cannot see (#2121 review round 3; round 4
#     adds the CONSEQUENCE of each remaining gap, because a blind spot without one is read as a pass):
#     the walk knows a POSIX `'…'` (no escapes), an ANSI-C `$'…'` (backslash escapes; the escaped quote
#     does NOT terminate it), a `"…"`, a `$( … )`/backtick (a FRESH quoting context), a `$(( … ))` and a
#     bare `(( … ))` arithmetic command, a `[[ … ]]` test, EVERY heredoc opener on a line (`<<A <<B`
#     reads the body of A and then the body of B), a `<<<` herestring (consumed whole, operand
#     included), and the body of a `${…}` that carries a `$(`. It still cannot see:
#       – an ANSI-C ESCAPE SEQUENCE that PRODUCES a quote character (`$'\x27…'`) — the manufactured
#         character is plain text to this scan. CONSEQUENCE: the carry desynchronises there; if it is
#         still open at end of file the run FAILS LOUDLY (`unterminated-quote`), but if a later real
#         quote closes it again the tail is mis-attributed with NO note — a SILENT PASS over that
#         region. That is the one remaining silent direction in the quoting model, stated so a green
#         run is not read as proof about such a file.
#       – a `${…}` expansion that spans PHYSICAL lines: its remaining nesting is carried in `PDEPTH`
#         and its braces are refused until it closes, but the body is only WALKED when it holds a
#         `$(` (otherwise the rest of the line is skipped, since nothing there can open a heredoc).
#         CONSEQUENCE: a `<<` inside a multi-line expansion that carries NO `$(` is not seen, so a
#         heredoc there is walked as code and a quote in its body can desynchronise the carry — a
#         `partial scan` or `unterminated-quote`, both LOUD, never a silent pass.
#       – a bare `(( … ))`/`[[ … ]]` that spans PHYSICAL lines, which is treated as ending at the
#         newline. CONSEQUENCE: a `<<` on the continuation line is read as an opener, so the run reds
#         with `unterminated-heredoc` — LOUD, and a false red on a `bash -n`-clean file.
#   * the feeder guard is matched on ANY captured variable in the function, so a guard on a
#     DIFFERENT substitution (`other="$(b)"; [ -n "$other" ] || return 1`) still suppresses the
#     finding for an unguarded feeder. Tying the guard to the loop's own feeder needs flow
#     analysis this text scan does not do.
#   * a `case` INSIDE a `$( … )` — its arm labels (`a)`, `*)`) are indistinguishable, lexically, from the
#     `)` that closes the substitution, so the context pops at the FIRST arm label and the rest of the
#     substitution is walked as shell. CONSEQUENCE: LOUD — a quote left open there makes the scan
#     partial (or trips `unterminated-quote`), and a partial scan FAILS; the run never passes quietly
#     over it. The arm-label walk itself is not modelled. No live instance in the scanned set.
#   * a FUNCTION is delimited by COUNTING braces on each line, outside quotes, trailing comments and
#     `${…}` expansions. A brace that is only ever opened on one line and closed many lines later as
#     DATA — inside a multi-line quoted string, or a heredoc whose delimiter is unquoted — is counted
#     where it appears, so the depth (and with it where the function ends) can drift in that region.
#     No live instance in the scanned set. CONSEQUENCE: this is the SILENT direction — a depth that
#     happens to return to zero has no partial note to give it away, so the tail is attributed to the
#     wrong scope and a shape there can be dropped while the run prints PASS. The quote half of the
#     same drift is now LOUD (`unterminated-quote`), and nothing else here is: the mitigation for the
#     brace half is the suite's fixtures plus a per-function reading of any depth anomaly, not a green
#     run.
# The near-miss set is the contract in the other direction: every spelling of a correct guard that
# this repo actually writes must read as a guard, because a linter that reds correct code is deleted
# from CI within a week — taking the class with it. The suite pins one fixture per spelling
# (`"$x"`, `"${x}"`, `${x}`, `-gt`, `(( … ))`, `[ "$x" = 0 ]`).
# A GREEN RUN MEANS "the three recognised idioms are absent from the SCANNED SET (see
# --list-targets) or baselined" — never "no false-PASS risk exists in this repo". The set is
# `scripts/*.sh` and `scripts/orchestrator-harness/*.sh`; other subtrees are not covered. How much
# of the set each glob contributes is pinned by the suite (`--list-targets` must still carry at
# least one target from each glob), because a renamed subtree would otherwise shrink coverage
# silently: the count is the only other signal and nothing compares it.
#
# THE BASELINE IS A SET OF CLAIMS, KEYED BY (file, rule, COUNT) — never by line number
# ----------------------------------------------------------------------------------
# Today's tree contains known instances that belong to their own open issues (listed in
# scripts/false-pass-baseline.tsv with the tracking issue). They are grandfathered BY COUNT:
#   * a NEW instance in a file that already has a baselined one raises that file's count and
#     FAILS — with ONE stated exception (measured in review round 1): the key is a COUNT, so
#     FIXING one baselined instance and ADDING a different one in the same file leaves the count
#     unchanged and is reported as `baselined`. The netting case is accepted rather than hidden,
#     because a per-instance anchor would have to be a line number (the false-block class the next
#     bullet rules out); re-record with `--update-baseline` in the same change that fixes one;
#   * the key is not a line number, so an unrelated edit above a finding does not red a peer
#     lane's CI (a false block on other people's PRs is how a guard gets deleted);
#   * a count that OVER-RECORDS reality (more recorded than present, but not zero) FAILS: `5` recorded
#     where one instance remains reports the first NEW instance as `baselined`, which is the regression
#     the baseline exists to catch. Only `seen == 0` is a note (the finding was fixed, and failing on
#     "you fixed it" is perverse);
#   * a baseline entry with NO matching finding is reported as `note: … STALE` (the finding
#     was fixed, or the code changed). It does NOT fail — failing on "you fixed it" is
#     perverse — and the stale count is printed in every run's summary, so an entry cannot rot
#     silently;
#   * an entry with no justification is a FINDING: the baseline is a set of claims, and a
#     claim without a reason is exactly the class this check exists to catch.
#
# THREE RULES CAN NEVER BE GRANDFATHERED (`NON_BASELINEABLE` below), and a baseline entry naming one
# is itself a failure. `unterminated-heredoc` means THE SCAN OF THAT FILE DID NOT HAPPEN — its tail
# was skipped, so what it holds is UNKNOWN. `unterminated-quote` is the same fact from the other end:
# the walk's quote carry was still open at end of file, so every line after the quote that was never
# recognised was read as quoted — no brace counted, no function flushed — and the tail's findings
# describe a scope that does not exist. Baselining either would turn one undelimitable file into a
# permanently blind file under a green check, and the run would still advertise the file as
# `scanned` — the invariant "no PASS over a scan that did not happen" defeated by one row.
# `marker-without-justification` is an unreadable exemption: it is not a shape to accept, it is a
# claim nobody can review. `--update-baseline` therefore never writes those three (they stay
# findings), and the join refuses an entry naming them.
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
#                                           [--list-nonbaselineable] [--list-targets] [--help]
#
#   --baseline <file>   the baseline to read (default: <root>/scripts/false-pass-baseline.tsv)
#   --root <dir>        the tree to scan (default: this script's repo). The suite uses it to
#                       drive the check against FIXTURE trees, so the rules have one home.
#   --update-baseline   REWRITE the baseline from this run's findings, preserving each entry's
#                       justification. A human reviews that diff; it is the only supported way
#                       to add a group, and it prints what it wrote.
#   --list-rules        print the rule ids, one per line (the doc/tests read THIS, not a copy)
#   --list-nonbaselineable  print the rule ids that can NEVER be grandfathered by the baseline
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
RULES=("discarded-status" "empty-as-pass" "pre-existing-as-evidence" "marker-without-justification" "unterminated-heredoc" "unterminated-quote")
# ⛔ THE SPLIT LIVES BESIDE THE LIST, not in a second copy of it (#2121 review round 5, P2). These
# two are NOT shapes a lane may accept: one is a scan that did not finish (UNKNOWN), the other is an
# exemption nobody can read. Grandfathering either certifies an absence nobody observed, which is
# the whole class this check exists to catch — so they are always FINDINGs, and --update-baseline
# never writes a row for them.
NON_BASELINEABLE=("unterminated-heredoc" "unterminated-quote" "marker-without-justification")

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
    --list-nonbaselineable) printf '%s\n' "${NON_BASELINEABLE[@]}"; exit 0 ;;
    --list-targets)
      for p in "${SCAN_GLOBS[@]}"; do
        for f in "$ROOT"/$p; do
          [ -f "$f" ] || continue
          printf '%s\n' "${f#"$ROOT"/}"
        done
      done
      exit 0 ;;
    --help|-h) usage ;;
    *) echo "usage: $(basename "$0") [--baseline <file>] [--update-baseline] [--list-rules] [--list-nonbaselineable] [--list-targets] [--help]" >&2; exit 2 ;;
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
#   depth — brace depth INSIDE that function (see brace_delta): the body ends where it returns to 0,
#           never at a `}` at some indent (a nested brace group is not the end of the function)
#   end_fn — this line closed the body; the line rules still run on what PRECEDES the closing brace
#   fn_loop / fn_loop_line — the first substitution-fed loop in that function
#   fn_counter             — an iteration count or a guard on a CAPTURED feeder output
#   fn_flagret             — the function returns a flag VARIABLE
#   captured[]             — vars assigned from a command substitution in this function
#   cnt[] / numtest[]      — the vars ASSIGNED as iteration counts, and the vars COMPARED
#                            numerically (their INTERSECTION is the counter proof; see counter_proof)
# scan_file <file> — the scanner, kept INLINE (not in a variable): an interpreter whose
# program is an expansion (`awk "$PROG" file`) is refused by the worktree discard guard
# (#1228 class) because its effect cannot be read statically. An inline literal can.
scan_file() {
  awk '
function heredoc_at(line, p,   i, n, ch, name, after) {
  # A heredoc whose delimiter is QUOTED suppresses expansion, so its body is DATA (a fixture, a
  # template, a test case) rather than statements bash runs. Returned WITHOUT the quotes.
  # `sq` (set in BEGIN via sprintf) is the single-quote character, written that way because this
  # whole program lives inside a shell single-quoted string.
  #
  # ⛔ THE OPENER POSITION IS DECIDED BY THE WALK, NOT BY A SUBSTRING SEARCH (#2121 review round 3,
  # P1). This function used to find the FIRST `<<` on the line with `index()`, with no idea whether
  # it sat in a comment, a quoted string, an arithmetic expansion or a `[[ … ]]` test — so
  #   note="write it with cat <<EOF"
  # opened a PHANTOM heredoc that swallowed everything up to the next bare `EOF`, including a real
  # function header; the body of that function was then scanned at top level, where `empty-as-pass` is
  # structurally unreportable, and the run printed PASS with no note. And `x=$(( 1 << n ))` — a
  # bit-shift — became an unterminated heredoc whose delimiter was `n`, a loud false red on a
  # `bash -n`-clean file. `brace_delta` already models comments, quotes and the `$( )`/backtick
  # context stack, so IT records the position of the first `<<` that is genuinely at command
  # position (HD_POS) and this half only extracts the delimiter token from there.
  #
  # ⛔ A COMMENT IS NOT CODE. A trailing comment that mentions an opener (`cmd # cat <<EOF`) opens
  # nothing either; the walk breaks at the comment before it can see the `<<`. The whole-line
  # comment form is skipped a level up (`is_comment`).
  i = p + 2; n = length(line)
  if (i <= n && substr(line, i, 1) == "-") i++
  while (i <= n && (substr(line, i, 1) == " " || substr(line, i, 1) == "\t")) i++
  if (i > n) return ""
  # ⛔ AN UNQUOTED DELIMITER IS STILL A HEREDOC (#2121 review, P0/P1). This returned "" for every
  # unquoted opener, which meant its body was never recognised as a body at all: the lines were walked
  # as CODE, so a single quote, a double quote or a backtick inside prose or a template moved the quote
  # carry and, with it, the brace depth — measured on scripts/orchestrator-harness/reviewer-preflight.sh:111, whose `cat <<BRIEF`
  # markdown body (with apostrophes and escaped backticks) left its function open to EOF, attributing
  # the rest of the file to a phantom scope. `HEREDOC_Q` records the quoting so the caller can tell
  # DATA (quoted: skipped entirely) from a generated-script template (unquoted: the line rules still
  # run, but the body is expanded like a double-quoted string, so the carry must NOT move).
  ch = substr(line, i, 1)
  if (ch == "\"" || ch == "\\" || ch == sq) { HEREDOC_Q = 1; i++ }
  else HEREDOC_Q = 0
  # ⛔ A DIGIT IS A BIT-SHIFT, NOT A DELIMITER (#2121 review). Now that an UNQUOTED opener is tracked,
  # `$(( (RANDOM << 15) % 900000 ))` parsed `<< 15` as an opener whose delimiter was `15` and swallowed
  # the rest of the file (measured: scripts/orchestrator-harness/test-claims.sh:225 became an
  # unterminated-heredoc finding). No live heredoc in this tree uses a numeric delimiter.
  if (substr(line, i, 1) ~ /[0-9]/) return ""
  name = ""
  while (i <= n) {
    ch = substr(line, i, 1)
    if (ch ~ /[A-Za-z0-9_]/) { name = name ch; i++ } else break
  }
  if (name == "") return ""
  # The CLOSING quote belongs to the delimiter token, not to a following redirect — without this
  # the after-test below rejects every quoted opener (the opener ends WITH its quote).
  # ⛔ ONLY A QUOTED DELIMITER HAS A CLOSING QUOTE (#2121 review round 3, P1). This consumed a quote
  # after an UNQUOTED delimiter too, so `note="… <<EOF"` — which the walk now rejects — and
  # `cat <<EOF"` were read as openers whose delimiter ended at the quote.
  if (HEREDOC_Q && i <= n) {
    ch = substr(line, i, 1)
    if (ch == "\"" || ch == "\\" || ch == sq) i++
  }
  while (i <= n && (substr(line, i, 1) == " " || substr(line, i, 1) == "\t")) i++
  after = (i > n) ? "" : substr(line, i, 1)
  # ⛔ A TRAILING COMMENT AFTER THE OPENER DOES NOT CANCEL IT (#2121 review round 4, P3). The `after`
  # test rejected anything but a redirect/separator, so `cat <<BRIEF   # sticky note` was NOT recorded:
  # its body was then walked as CODE, and a single apostrophe in prose opened the quote carry — turning
  # a CORRECT file into a loud partial FAIL that named the wrong opener line. `#` is end-of-line here, on
  # the SAME word-boundary rule strip_comment uses (so `<<A#B`, where `#` is part of the delimiter
  # word, is still rejected rather than silently read as delimiter `A`).
  if (after == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;]/)) return name
  # ⛔ A SECOND OPENER ON THE SAME LINE IS A REDIRECT, NOT A REJECTION (#2121 review round 4, P0).
  # `cat <<A <<B` was rejected outright, so NEITHER body was recorded and both were walked as code.
  # `<` is as much an operand boundary as `>` is.
  if (after != "" && after != ">" && after != "<" && after != "|" && after != ";" && after != ")" && after != "&") return ""
  return name
}
function heredoc_push(dm, dash, q, ln) {
  # ⛔ ONE LINE MAY OPEN MORE THAN ONE HEREDOC, AND THEIR BODIES ARRIVE IN ORDER (#2121 review
  # round 4, P0). `cat <<A <<B` reads the body of A first and the body of B second, so a single `heredoc` slot
  # made the second body unrecorded: it was walked as CODE, its prose moved the quote carry and the
  # scan of the file desynchronised. The openers are therefore QUEUED in the order the walk met them,
  # and the terminator of one promotes the next to the active slot.
  if (heredoc == "" && HQN == 0) {
    heredoc = dm; heredoc_dash = dash; heredoc_quoted = q; heredoc_line = ln
    return
  }
  HQN++; HQ_D[HQN] = dm; HQ_DASH[HQN] = dash; HQ_Q[HQN] = q; HQ_LINE[HQN] = ln
}
function heredoc_pop(   k) {
  # The active heredoc terminated: the next queued one (if any) takes its place. Its body starts on
  # the FOLLOWING line, which is exactly what the `next` in the caller does.
  if (HQN > 0) {
    heredoc = HQ_D[1]; heredoc_dash = HQ_DASH[1]; heredoc_quoted = HQ_Q[1]; heredoc_line = HQ_LINE[1]
    for (k = 2; k <= HQN; k++) {
      HQ_D[k - 1] = HQ_D[k]; HQ_DASH[k - 1] = HQ_DASH[k]
      HQ_Q[k - 1] = HQ_Q[k]; HQ_LINE[k - 1] = HQ_LINE[k]
    }
    delete HQ_D[HQN]; delete HQ_DASH[HQN]; delete HQ_Q[HQN]; delete HQ_LINE[HQN]
    HQN--
  } else { heredoc = ""; heredoc_dash = 0; heredoc_quoted = 0 }
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
function inside_quotes(line, pos,   i, c, n, dq, sqm) {
  # Is character `pos` inside a double- or single-quoted region of `line`? Used for the `# verified:`
  # marker: a PRINTED string that mentions the marker must not manufacture an exemption
  # (review round 2).
  # ⛔ ANSI-C QUOTING IS A SECOND SINGLE-QUOTE MODE (#2121 review round 3, P0). `sqm` is the MODE:
  # 1 = POSIX single-quoted (no escapes at all — a backslash is a literal character), 2 = ANSI-C
  # dollar-quoted (a backslash escapes the next character, so an ESCAPED quote inside one does NOT
  # end it). Treating the two as one made this reader see an ANSI-C literal as CLOSED at its escaped
  # quote and reopened at the real closing one, so a verified marker written after it on the same
  # line read as OUTSIDE quotes — manufacturing an exemption. That is the same blindness as
  # brace_delta, which is the P0 this round fixes there.
  dq = 0; sqm = 0; n = length(line)
  for (i = 1; i < pos && i <= n; i++) {
    c = substr(line, i, 1)
    if (sqm == 1) { if (c == sq) sqm = 0; continue }
    if (sqm == 2) { if (c == "\\") { i++; continue } if (c == sq) sqm = 0; continue }
    if (c == "\\") { i++; continue }
    if (c == "\"" && sqm == 0) { dq = !dq; continue }
    if (c == sq && dq == 0) { sqm = ((i > 1 && substr(line, i - 1, 1) == "$") ? 2 : 1) }
  }
  return (dq || sqm != 0)
}
function is_cmd_subst(line) {
  # `$(cmd)` masks a command status through a declaration builtin; `$((arith))` does NOT — there
  # is no command whose status could be lost, and flagging it reds correct code (measured in
  # review round 1: `local n=$(( a * 100 / b ))` was reported as a masked command substitution).
  if (!match(line, /="?\$\(/)) return 0
  return substr(line, RSTART + RLENGTH, 1) != "("
}
function decl_masks_status(line,   nseg, si, s, seg, p, rest) {
  # ⛔ A DECLARATION IS A STATEMENT, WHEREVER THE STATEMENT STARTS (#2121 review, P3). This arm was
  # anchored to `^[ \t]*`, so the three prefixes the CAPTURE arms were widened for stayed invisible
  # here: `if …; then local z=$(cmd); fi`, `true && local w=$(cmd)` and a `case` arm
  # `a) local q=$(cmd) ;;` all reported clean while the identical declaration at the start of a line
  # was a finding. The line is split with the SAME splitter the capture arms use, so the two halves of
  # the rule cannot disagree about what a statement is.
  #
  # ⛔ AND THE SUBSTITUTION MAY BE ANY ASSIGNMENT WORD, NOT THE FIRST ONE (#2121 review, P1). The
  # original anchor required the FIRST declared name to be followed immediately by `="?$(` — so
  # `local -r cfg=$(cmd)`, `local a="$1" b="$(cmd)"` and `declare -A m=([k]=$(cmd))` all reported
  # clean, and the tree carries all three spellings. The declaration builtin, then ANY `=`-bound
  # substitution in the word list, is the rule; `$((arith))` is still kept out.
  nseg = split_stmts(line)
  for (si = 1; si <= nseg; si++) {
    s = SEG[si]
    sub(/^[ \t]*(then|do|else|elif)[ \t]+/, "", s)
    # a `case … in` prefix: drop everything through the first arm label
    if (match(s, /^[ \t]*case[ \t]/) && match(s, /[ \t]in[ \t]/)) {
      rest = substr(s, RSTART + RLENGTH)
      p = index(rest, ")")
      if (p > 0) s = substr(rest, p + 1)
    }
    # a bare arm label (`a)`, `*)`, `x|y)`) at the start of the statement
    sub(/^[ \t]*[A-Za-z0-9_*?.$|\[\]-]+\)[ \t]*/, "", s)
    if (!match(s, /^[ \t]*(local|declare|typeset|export|readonly)[ \t]/)) continue
    # ⛔ THE DECLARATION ENDS AT THE FIRST `;` (#2121 review, P2). `local c; c="$(cmd)"` is the
    # DOCUMENTED CORRECT FIX (the declaration is split, so the assignment keeps its status) — without
    # this bound the widened rule flagged 39 instances of the fix itself. The declaration word list is
    # what can mask a status; a later statement on the same line cannot.
    if (index(s, ";") > 0) s = substr(s, 1, index(s, ";") - 1)
    if (!match(s, /="?\$\(/)) continue
    # `$((arith))` is not a command substitution: there is no command whose status could be lost.
    if (substr(s, RSTART + RLENGTH, 1) == "(") continue
    p = RSTART - 1
    if (p < 1) continue
    # the `=` must terminate an assignment word: an identifier char, or the `]` of an array subscript
    if (substr(s, p, 1) ~ /[A-Za-z0-9_\]]/) return 1
  }
  return 0
}
function cap_var(tok,   v) {
  # The NAME out of a test token, whatever quoting/brace spelling it was written with:
  # `[ -z "$out" ]`, `[ -z "${out}" ]`, `[[ -z ${out} ]]` all yield `out`.
  v = tok
  sub(/^[ \t]*\[[ \t]+-[nz][ \t]+/, "", v)
  sub(/^"/, "", v); sub(/^\$/, "", v); sub(/^\{/, "", v)
  sub(/[^A-Za-z0-9_].*/, "", v)
  return v
}
function guard_on_captured(line,   v) {
  # `[ -n "$x" ]` / `[ -z "$x" ]` where $x was CAPTURED from a substitution is the emptiness
  # guard the empty-as-pass shape lacks. A test on any OTHER variable is not: `[ -n "$arg" ] ||
  # continue` skips one ITEM, it never notices that the feeder produced nothing (#1743).
  # ⛔ EVERY SPELLING OF THE SAME TEST IS THE SAME GUARD (#2121 review round 4, P1). The arm only
  # accepted a quoted bare name, so `[ -z "${out}" ]` — 32 occurrences of `-z "${` in scripts/*.sh
  # — and the unquoted `[[ -z ${out} ]]` were reported as the shape; a linter that reds the correct
  # guard in the spelling this fleet actually uses is deleted from CI, taking the class with it.
  if (match(line, /\[[ \t]+-[nz][ \t]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
    v = cap_var(substr(line, RSTART, RLENGTH))
    if (v != "" && is_cap(v)) return 1
  }
  return 0
}
function guarded_assignment(line,   i, n, j) {
  # ⛔ THE SUBSTITUTION MUST BE THE RHS OF AN ASSIGNMENT ON THIS LINE (#2121 review round 5, P1).
  # The arm required only the two substrings `$(` and `|| return`, with no requirement that the
  # substitution was ASSIGNED to anything or was the feeder of that loop — so an ordinary PRECONDITION that
  # merely USES one (`[ -d "$(dirname "$0")" ] || return 1`, `[ -n "$(command -v x)" ] || exit 1`,
  # both written constantly in this repo) set fn_counter and laundered a completely unrelated,
  # UNGUARDED feeder loop for the rest of the function while the run printed PASS. The documented
  # correct fix is ASSIGN-and-check (`out="$(cmd)" || return 1`), so the rule is now what its own
  # comment already stated: an `=`-bound substitution, not any use of one.
  # The `=` must END an assignment word (an identifier char or the `]` of a subscript) — otherwise a
  # COMPARISON against a substitution (`[ "$x" = "$(cmd)" ] || return 1`) would arm the arm while
  # observing nothing about the feeder.
  # ⛔ ONE LINEAR PASS OVER THE `=` CHARACTERS (#2121 review round 3, P1) — this was an unanchored
  # `[A-Za-z0-9_\]]=[ \t]*"?\$\(` regex, which mawk restarts at every position, so a long line made it
  # quadratic (see scan_words for the measurement). Same rule, no re-scanning.
  n = length(line)
  for (i = 2; i <= n; i++) {
    if (substr(line, i, 1) != "=") continue
    if (substr(line, i - 1, 1) !~ /[A-Za-z0-9_\]]/) continue
    j = skip_blanks(line, i + 1)
    if (substr(line, j, 1) == "\"") j++
    # `$((arith))` has no status to lose (same reasoning as is_cmd_subst): `n=$((a/b)) || return 1`
    # is not a guard on a failed READ.
    if (substr(line, j, 2) == "$(" && substr(line, j + 2, 1) != "(") return 1
  }
  return 0
}
function skip_param(line, i,   n, j, c, d, qm) {
  # Skip a `${…}` parameter expansion: those braces belong to the EXPANSION, not to the block
  # structure (`${#arr[@]}`, `"${1:-}"`, `${x%%.*}`), and counting them made the brace depth — and
  # with it where a function ends — depend on how a variable was spelled.
  # ⛔ A NESTED `${` IS COUNTED WHATEVER THE QUOTE STATE (#2121 review, P0). The arm was gated on
  # `!dq`, so the nested expansion inside `${A[@]+"${A[@]}"}` — a spelling this repo writes — was not
  # counted, the INNER `}` drove `d` to 0, and the recovery returned early: the rest of the line then
  # carried an unmatched `"` and, with it, a brace depth that never came back. `d` is a count of
  # `${`s, so a nested one increments it regardless of what quoting surrounds it.
  #
  # ⛔ A QUOTED `}` IS NOT THE END OF THE EXPANSION (#2121 review round 4, P1). This walk knew neither
  # quotes nor brace EXPANSIONS, so it returned at the first `}` character wherever it sat:
  #   g=${Y:-$(echo "}")}            → ended INSIDE the quoted string, leaving `")}` to be walked as
  #                                     block braces (the function closed early — with the new `${…}`
  #                                     walk that made a real `empty-as-pass` a SILENT PASS)
  #   f=${X:-{a,b}}                  → ended at the `}` of the brace EXPANSION, so the real closer was
  #                                     counted as a BLOCK brace and the function ended a line early
  #                                     (pre-existing, measured on the previous head: silent PASS)
  # Both are the same defect: the end of the expansion is not "the first `}`", it is the `}` that closes
  # the nesting. Quotes are skipped (POSIX, ANSI-C and double-quoted, escapes included), a nested `${`
  # counts, and so does a bare `{` — bash requires the braces of an alternate-value WORD to balance.
  n = length(line); j = i + 2; d = 1; qm = 0
  while (j <= n) {
    c = substr(line, j, 1)
    if (qm == 1) { if (c == sq) qm = 0; j++; continue }
    if (qm == 2) { if (c == "\\") { j += 2; continue } if (c == sq) qm = 0; j++; continue }
    if (qm == 3) { if (c == "\\") { j += 2; continue } if (c == "\"") qm = 0; j++; continue }
    if (c == "\\") { j += 2; continue }
    if (c == "\"") { qm = 3; j++; continue }
    if (c == sq) { qm = ((j > 1 && substr(line, j - 1, 1) == "$") ? 2 : 1); j++; continue }
    if (c == "$" && substr(line, j + 1, 1) == "{") { d++; j += 2; continue }
    if (c == "{") { d++; j++; continue }
    if (c == "}") { d--; if (d == 0) return j + 1 }
    j++
  }
  # ⛔ UNCLOSED IS NOT "ENDED AT THE LINE BOUNDARY" (#2121 review round 4). Returning n+1 was
  # indistinguishable from an expansion whose closing brace is the LAST character of the line, and the
  # caller read that as "carries on to the next line" — so a fully closed `${Y:-$(echo "}")}` left the
  # carry armed and the function brace on the next line went uncounted (a real shape turned into a
  # partial scan). -1 states the fact, and PARAM_D hands the caller the nesting still open, which is
  # what a multi-line expansion must carry so its closers are not counted as BLOCK braces.
  PARAM_D = d
  return -1
}
function push_ctx(k) {
  # ⛔ A QUOTING CONTEXT IS A STACK, NOT TWO BOOLEANS (#2121 review, P0). Bash parses `$( … )` and a
  # ``` ` … ` ``` substitution as a FRESH quoting context: a single quote inside them opens a
  # single-quoted string even when the substitution sits inside a double-quoted string. Two global
  # booleans cannot say that, so an ordinary line — a `sed -n` capture whose PROGRAM carries an s///,
  # a single-quoted span and escaped double quotes, assigned inside a double-quoted substitution —
  # left the carry permanently OPEN (the inner `"` closed `dq` early, the pairs shifted, and the
  # trailing quote reopened it). Every later line was then read as quoted: no brace was counted, `fn`
  # never flushed, and the first `[ -n "$captured" ]` in that phantom scope set `fn_counter` for the
  # WHOLE remainder — so later zero-iteration-loop-with-success-flag shapes were silently dropped and
  # the run still printed PASS. Measured: 12-line fixture reported nothing, the same file without the
  # nested quotes reported `empty-as-pass`.
  QN++
  QK[QN] = k; QD[QN] = 0; QS[QN] = 0; QP[QN] = 0; QA[QN] = 0; QH[QN] = 0; QR[QN] = 0; QL[QN] = 0
}
function pop_ctx() {
  if (QN > 1) { QK[QN] = ""; QD[QN] = 0; QS[QN] = 0; QP[QN] = 0; QA[QN] = 0; QH[QN] = 0; QR[QN] = 0; QL[QN] = 0; QN-- }
}
function brace_delta(line,   i, n, c, d, qk, has_sh) {
  # Net brace depth change of one scanned line, OUTSIDE quotes, comments and `${…}` expansions.
  # Sets BR_END to the position of the LAST closing brace seen, which is where a function body
  # that ends on this line ends (the caller truncates there and still scans what precedes it).
  # Sets BR_HIDDEN when a `{` was NOT counted because a quote of the CURRENT context was open at it
  # (the caller reads that to keep the body of a drifted header attributed instead of leaking it).
  # ⛔ QUOTE STATE CARRIES ACROSS LINES, per CONTEXT (review rounds 6 and 12; stack in round 13).
  # Resetting it per line made every `{`/`}` inside a MULTI-LINE quoted region count as a brace —
  # typically an awk/sed program written across lines, which is common in this tree — so the counter
  # drifted and a function looked permanently open. The carry lives in QD[]/QS[] per context;
  # entering `$(`/`` ` `` pushes a FRESH context (bash parses those independently) and its `)`/`` ` ``
  # pops it, so an inner quote can never desynchronise the outer one.
  # Braces are only counted in the OUTERMOST context: a `{ … }` inside a substitution belongs to that
  # subshell, so it is balanced where it appears and counting it buys nothing but drift.
  d = 0; n = length(line); i = 1
  BR_END = 0; BR_OPEN = 0; BR_HIDDEN = 0; HD_N = 0
  # ⛔ `(( … ))` AND `[[ … ]]` ARE ENDED AT THE LINE BOUNDARY (#2121 review round 3, P1). Their state
  # is per CONTEXT but NOT carried across lines: neither can contain a brace, so ending them here costs
  # nothing on real code, while carrying a `((` whose `))` never arrives (it can sit inside a quoted
  # region, or simply be unbalanced) would stop the brace count for the REST OF THE FILE — the silent
  # drift this file exists to catch. A genuinely multi-line arithmetic command is therefore treated as
  # ending at the newline, which is declared in the header. (A multi-line `$(( … ))` is unaffected: it
  # is an arithmetic CONTEXT, tracked by QA[] and the context stack, not by these counters.)
  for (qk = 1; qk <= QN; qk++) { QH[qk] = 0; QR[qk] = 0 }
  # ⛔ THE OPENER SEARCH IS THE ONLY REASON TO TRACK ARITHMETIC AND `[[ … ]]` HERE, SO IT RUNS ONLY ON A
  # LINE THAT COULD HOLD AN OPENER (#2121 review round 3, P1). The block below consumes `(( … ))` and
  # `[[ … ]]` characters so a `<<` inside them is never recorded; with no `<<` on the line there is
  # nothing to record, and letting those parens fall through to the `$( )`-context paren counter is
  # exactly what the scanner did before — balanced either way. One `index()` per line instead of a
  # per-character test on every line of every file: measured 4.6 s of a 23 s scan-set run.
  has_sh = (index(line, "<<") > 0)
  while (i <= n) {
    c = substr(line, i, 1)
    # ⛔ ANSI-C QUOTING IS A SECOND SINGLE-QUOTE MODE, AND ITS ESCAPES COUNT (#2121 review round 3,
    # P0). ANSI-C quoting PROCESSES backslash escapes, so its terminator is the first UNESCAPED quote
    # character; a POSIX single-quoted string has no escapes at all, so its terminator is the first
    # quote character, full stop. Applying the POSIX rule to an ANSI-C literal made a top-level
    # ANSI-C literal carrying an ESCAPED quote leave the carry OPEN (the escaped quote "closed" it,
    # the real closing quote re-opened it), so every later line was read as quoted: no brace counted,
    # no function flushed, an `empty-as-pass` shape after it reported NOTHING, and the run printed PASS
    # with no partial note and exit 0. Both states live in QS[]: 1 = POSIX, 2 = ANSI-C.
    if (QS[QN] == 2) { if (c == "\\") { i += 2; continue } if (c == sq) QS[QN] = 0; i++; continue }
    if (QS[QN] == 1) { if (c == sq) QS[QN] = 0; i++; continue }
    if (c == "\\") { i += 2; continue }
    if (c == "\"" && QS[QN] == 0) { QD[QN] = !QD[QN]; if (QD[QN] && QL[QN] == 0) QL[QN] = FNR; i++; continue }
    if (c == sq && QD[QN] == 0) { QS[QN] = ((i > 1 && substr(line, i - 1, 1) == "$") ? 2 : 1); QL[QN] = FNR; i++; continue }
    # a TRAILING comment: `#` at a word boundary starts prose, and prose is not braces. A `#` inside
    # a `$( … )` that itself sits inside a double-quoted string IS a comment, which is why this tests
    # the quote state of the CURRENT context and not the outermost one.
    # ⛔ `PDEPTH == 0 || QN > 1` — the break is suppressed only for the expansion word itself (#2121
    # review round 4, P2). Inside a `$( … )` nested in a walked `${…}`, QN > 1 and bash DOES treat `#`
    # as a comment; suppressing it there read the prose as code and a body apostrophe opened a quote
    # carry the shell never opened (loud false red on a correct file).
    if (QD[QN] == 0 && c == "#" && (PDEPTH == 0 || QN > 1) && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;]/)) break
    # ⛔ `$((` IS AN ARITHMETIC EXPANSION, NOT A COMMAND SUBSTITUTION, AND IT IS MARKED AS SUCH
    # (#2121 review round 3, P1). Both push a fresh quoting context, but a `<<` inside arithmetic is a
    # BIT-SHIFT and inside a command substitution it is a REAL heredoc — so the opener test needs to
    # tell them apart. QA[] marks the arithmetic form.
    if (c == "$" && substr(line, i + 1, 1) == "(") {
      push_ctx("sub")
      if (substr(line, i + 2, 1) == "(") QA[QN] = 1
      i += 2; continue
    }
    if (c == "`") { if (QK[QN] == "bt") pop_ctx(); else push_ctx("bt"); i++; continue }
    # ⛔ A `)` INSIDE A QUOTED REGION OF THE SUBSTITUTION IS LITERAL, AND A NESTED SUB-SHELL HAS ITS
    # OWN PARENS (#2121 review). The pop fired on any `)` while a substitution was open, so a
    # multi-line `x=$("$PY" -c "` … python source …`"")` — whose source is a double-quoted string
    # FULL of `(`/`)` — closed the substitution at the first python paren, and the rest of the source
    # was then walked as shell: the carry desynced again, one context further out. Bash pops on the
    # `)` that CLOSES the substitution, i.e. one outside any quote and outside any paren opened inside it.
    # ⛔ ARITHMETIC AND A `[[ … ]]` TEST ARE NOT COMMAND POSITIONS (#2121 review round 3, P1).
    # A `<<` there is a BIT-SHIFT, never a heredoc opener: `x=$(( 1 << n ))` opened a heredoc whose
    # delimiter was `n`, which then never terminated — `unterminated-heredoc` plus a partial FAIL on
    # a `bash -n`-clean file. Both are tracked PER CONTEXT (they are global in bash, but a context is
    # where the carrying has to live), and inside a `$(( … ))` context the opener is refused outright
    # (QA[]). Neither can contain a brace, so their state never affects the brace count.
    if (has_sh && QD[QN] == 0 && QS[QN] == 0) {
      if (QH[QN] > 0) {
        if (c == ")" && substr(line, i + 1, 1) == ")") { QH[QN]--; i += 2; continue }
        if (c == ")" && QH[QN] > 1) { QH[QN]--; i++; continue }
        if (c == "(") { QH[QN]++; i++; continue }
        i++; continue
      }
      if (QR[QN]) {
        if (c == "]" && substr(line, i + 1, 1) == "]") { QR[QN] = 0; i += 2; continue }
        i++; continue
      }
      # ⛔ `((` IS AN ARITHMETIC COMMAND ONLY OUTSIDE `$((` (#2121 review round 3, P1). Inside a
      # `$(( … ))` context the second paren belongs to the expansion, which the `$( )`-context paren
      # counter below must see (it is what pops the context at `))`); consuming it here left the
      # substitution context open for the rest of the file.
      if (QA[QN] == 0 && c == "(" && substr(line, i + 1, 1) == "(") { QH[QN] = 1; i += 2; continue }
      if (c == "[" && substr(line, i + 1, 1) == "[") { QR[QN] = 1; i += 2; continue }
      # ⛔ THE HEREDOC OPENER IS RECORDED HERE, by the walk that already knows what is code (#2121
      # review round 3, P1). The CURRENT context must be code — not inside a quote of this context,
      # not inside a `$(( … ))`, a `(( … ))` or a `[[ … ]]` — which is exactly where `<<` is a heredoc.
      # It is recorded in a `$( … )` context too, because `x="$(cat <<EOF … EOF)"` is a real heredoc
      # inside a command substitution; `${…}` is walked when it carries a `$(` (see below), and its
      # braces are declared in the header as not modelled as block braces.
      # ⛔ `<<<` IS A HERESTRING AND IS CONSUMED WHOLE (#2121 review round 4). The third-byte test kept
      # it from being recorded AT THE FIRST `<` — but the walk then advanced ONE character and re-tested
      # at the SECOND, where `<< "operand"` looks like a perfectly ordinary quoted opener: measured,
      # `read -r e <<< "herestring"` was read as a heredoc whose delimiter was `herestring`, which never
      # terminated — a loud `unterminated-heredoc` FAIL on a `bash -n`-clean file. The token is skipped
      # as a unit, so there is no second position to misread.
      if (QA[QN] == 0 && c == "<" && substr(line, i + 1, 1) == "<") {
        if (substr(line, i + 2, 1) == "<") { i += 3; continue }
        HD_N++; HD_POSA[HD_N] = i; i += 2; continue
      }
    }
    if (c == "(" && QK[QN] == "sub" && QD[QN] == 0) { QP[QN]++; i++; continue }
    if (c == ")" && QK[QN] == "sub" && QD[QN] == 0) {
      if (QP[QN] > 0) QP[QN]--
      else pop_ctx()
      i++; continue
    }
    if (QN == 1 && QD[1] == 0 && QS[1] == 0) {
      # ⛔ PDEPTH == 0 GATES THE JUMP ARM ONLY (#2121 review round 4, P0). A NESTED `${…}` inside an
      # expansion already being walked must reach the PDEPTH++ arm BELOW, not re-enter here: re-arming
      # them reset the nesting, so the outer `}` was counted as a BLOCK brace and closed the enclosing
      # function early — `${A:-${B:-$(echo hi)}}` in a body made `empty-as-pass` structurally
      # unreportable while depth returned to 0, i.e. a SILENT PASS with no partial note.
      if (PDEPTH == 0 && c == "$" && substr(line, i + 1, 1) == "{") {
        # ⛔ A `${…}` EXPANSION IS SKIPPED BECAUSE ITS BRACES ARE NOT BLOCK BRACES — BUT ITS BODY IS
        # STILL CODE WHEN IT CARRIES A COMMAND SUBSTITUTION (#2121 review round 4, P0). Jumping the
        # whole expansion hid the opener in
        #     note=${NOTE:-$(cat <<EOF … EOF)}
        # so the heredoc was never recorded, its BODY was walked as code, a body apostrophe opened the
        # quote carry and the file ended desynchronised — exit 0, 0 findings, PASS over a real
        # `empty-as-pass`. When the expansion contains a `$(`, it is now WALKED (the quote/`$(`/
        # opener arms above all run) with every brace inside it refused: PDEPTH counts the nesting that
        # is still open inside the expansion, so the braces that made skip_param necessary stay
        # uncounted — on this line and on any later one the expansion runs into.
        j = skip_param(line, i)
        if (j < 0) {
          # ⛔ THE WALK PATH CARRIES THE OUTER DEPTH, NOT PARAM_D (#2121 review round 5, P1). PARAM_D
          # already counts every `${`/`{` in the rest of the line; re-walking that same region adds
          # them a second time, so the carry ended at 2*PARAM_D - 1 and the surplus `}` ate the
          # enclosing block closer — a LOUD partial FAIL on a correct file.
          if (index(substr(line, i + 2), "$(") > 0) { PDEPTH = 1; i += 2; continue }
          PDEPTH = PARAM_D
          i = n + 1; continue
        }
        if (index(substr(line, i + 2, j - i - 2), "$(") > 0) {
          PDEPTH = 1
          i += 2; continue
        }
        i = j; continue
      }
      # inside an expansion the walk is reading: its braces are not BLOCK braces, so `${x:-{a,b}}`,
      # `${x:-$(echo "}")}` and a nested `${A[@]+"${A[@]}"}` all stay balanced. Quotes and `$( … )` are
      # handled by the arms ABOVE this one, which is how the opener inside such an expansion is seen.
      if (PDEPTH > 0) {
        if (c == "$" && substr(line, i + 1, 1) == "{") { PDEPTH++; i += 2; continue }
        if (c == "{") { PDEPTH++; i++; continue }
        if (c == "}") { PDEPTH--; i++; continue }
        i++; continue
      }
      if (c == "{") { d++; BR_OPEN++; i++; continue }
      if (c == "}") { d--; BR_END = i; i++; continue }
    } else if (c == "{") BR_HIDDEN = 1
    i++
  }
  return d
}
function split_stmts(line,   i, n, ch, prev, dq, sqm, par, start, cnt) {
  # \u26d4 QUOTE- AND PAREN-AWARE STATEMENT SPLITTING (#2121 review round 5, P1). A plain
  # `split(line, segs, /;|&&|\|\|/)` cuts a `;` inside a QUOTED STRING, manufacturing a phantom
  # statement: a printf whose QUOTED TEXT contained a semicolon became a segment that looked like a
  # reassignment of
  # `out`, which DEREGISTERED a live capture and turned a real shape GREEN (measured both ways: the
  # same line without the `;`, or with a different name after it, still reported). It also could not
  # tell a subshell from the current shell, so `( unset X; run )` looked like a write to X. Splitting
  # only on separators that are OUTSIDE quotes and OUTSIDE parentheses fixes both, and it keeps a
  # `$( \u2026 ; \u2026 )` substitution in one piece.
  #
  # \u26d4 SEGMENTS ARE SLICES, NOT A CHARACTER-BY-CHARACTER ACCUMULATION (#2121 review round 3, P1).
  # This appended to `cur` one character at a time, and awk copies a string on every assignment, so a
  # single long CODE line cost O(length^2): a 100 KB line made the scan take minutes and a 100 KB line
  # in one function never returned at all (measured: 1 KB 0.1 s, 20 KB 15 s, 100 KB > 60 s). That is a
  # gate that HANGS rather than answering — and generated scripts do carry long lines. Each
  # segment is now a substring of the line, so the cost is linear.
  # ⛔ ONE SEGMENT WHEN THERE IS NOTHING TO SPLIT (#2121 review round 3, P1): a line with no `;`, `&`
  # or `|` is one statement, and the walk below is the single most-run loop in the scanner. The
  # callers pass comment-free code (see strip_comment), so the whole line IS the segment.
  if (index(line, ";") == 0 && index(line, "&") == 0 && index(line, "|") == 0) {
    NSEG = 1; SEG[1] = line
    return NSEG
  }
  NSEG = 0; dq = 0; sqm = 0; par = 0; n = length(line); start = 1; i = 1
  while (i <= n) {
    ch = substr(line, i, 1); prev = (i > 1 ? substr(line, i - 1, 1) : "")
    # \u26d4 ESCAPES CONSUME THE NEXT CHARACTER, AND A COMMENT IS NOT CODE (review round 6, P2).
    # `prev != backslash` is parity-free: an EVEN run of backslashes before a closing quote (a literal
    # trailing backslash) left the double-quote state OPEN, so nothing after it split and a later
    # capture on the line was never registered — mirrors the walk in brace_delta(), which had it right.
    # And the per-segment comment strip cannot see a `;` INSIDE a trailing comment, so the split made a
    # phantom statement out of prose (prose shaped like a capture registered one that never happened —
    # red on correct code; prose shaped like a write deregistered a live capture — a real shape lost).
    # A trailing comment now ENDS the code, so the last segment holds no prose at all.
    if (dq) { if (ch == "\\") { i += 2; continue } if (ch == "\"") dq = 0; i++; continue }
    if (sqm == 1) { if (ch == sq) sqm = 0; i++; continue }
    if (sqm == 2) { if (ch == "\\") { i += 2; continue } if (ch == sq) sqm = 0; i++; continue }
    if (ch == "\\") { i += 2; continue }
    if (ch == "#" && (i == 1 || prev ~ /[ \t;]/)) { n = i - 1; break }
    if (ch == "\"") { dq = 1; i++; continue }
    if (ch == sq) { sqm = ((i > 1 && substr(line, i - 1, 1) == "$") ? 2 : 1); i++; continue }
    if (ch == "(") { par++; i++; continue }
    if (ch == ")") { if (par > 0) par--; i++; continue }
    if (par == 0 && (ch == ";" || (ch == "&" && substr(line, i + 1, 1) == "&") || (ch == "|" && substr(line, i + 1, 1) == "|"))) {
      NSEG++; SEG[NSEG] = (i > start) ? substr(line, start, i - start) : ""
      if (ch != ";") i++
      i++; start = i; continue
    }
    i++
  }
  NSEG++; SEG[NSEG] = (n >= start) ? substr(line, start, n - start + 1) : ""
  return NSEG
}
function strip_comment(line,   i, n, c, dq, sqm) {
  # THE CODE PART OF A LINE: everything before the first unquoted `#` at a word boundary. It is the same
  # rule brace_delta and split_stmts already walk with, in one home so the rules cannot disagree with
  # them about what a comment is.
  # ⛔ A COMMENT IS NOT CODE, INCLUDING ITS WORDS (#2121 review round 3, P2). The line-level arms read
  # the RAW line, trailing comment and all, so the widened verdict vocabulary turned COMMENT PROSE into
  # a verdict: `n=$(ls -1 "$dst"/*.sh | wc -l)   # counts what install.sh already deployed…` was
  # reported as pre-existing-as-evidence because the comment contained `deployed`. The line is a correct
  # capture with no verdict on it, so that was a false positive on code the header of this file calls
  # not code. Stripping is also the safe direction for the suppressors: a comment mentioning `-newer`
  # can no longer hide a real verdict.
  dq = 0; sqm = 0; n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (sqm == 1) { if (c == sq) sqm = 0; continue }
    if (sqm == 2) { if (c == "\\") { i++; continue } if (c == sq) sqm = 0; continue }
    if (c == "\\") { i++; continue }
    if (c == "\"" && sqm == 0) { dq = !dq; continue }
    if (c == sq && dq == 0) { sqm = ((i > 1 && substr(line, i - 1, 1) == "$") ? 2 : 1); continue }
    if (dq == 0 && c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;]/)) return substr(line, 1, i - 1)
  }
  return line
}
function is_cap(v) {
  # ⛔ CAPTURE-NESS IS NOT FUNCTION-LOCAL (#2121 review, P2). The set was reset by flush_fn, so a
  # feeder captured OUTSIDE the enclosing function — `LIST="$(cmd)"` at file scope, then
  # `f() { for x in $LIST; … }` — was not a capture at all and the shape reported nothing. A file-scope
  # capture is the same feeder one level out, so a name is a feeder if it is captured in EITHER scope.
  return ((v in captured) || (v in fcaptured))
}
function is_arrcap(v) {
  # ⛔ ONLY A NAME THE ARRAY ARM CAPTURED IS AN ARRAY (#2121 review, P3). `"${n[@]}"` was accepted for
  # ANY captured name, so `out="$(cmd)"` (a SCALAR) followed by `for x in "${out[@]}"` was reported —
  # but a quoted `[@]` over a scalar iterates ONCE even when the value is empty, so that code is
  # correct and this was a false positive. `arr=( $(cmd) )` is the spelling that can iterate ZERO times.
  return ((v in arrcap) || (v in farrcap))
}
function drop_cap(v, only_fn) {
  # ⛔ A DECLARATION BUILTIN WRITES ONLY THE FUNCTION SCOPE (#2121 review round 3, P3). This said "a
  # write that does not come from a substitution clears the capture in BOTH scopes", which is true
  # only for an UNQUALIFIED write — and it is called for `local`/`declare`/`typeset` too. So
  #   LIST="$(cmd)"                  # file scope: a real feeder
  #   f() { local LIST="alpha beta"; … }
  #   g() { for x in $LIST; … return "$bad"; }
  # reported NOTHING: the unrelated function-local shadow deleted the file-scope capture, and a
  # real zero-iteration shape became invisible. `only_fn` (set by the caller when the statement is a
  # FUNCTION-SCOPE declaration) leaves the file-scope entry alone. At FILE scope a `declare`/`typeset`
  # IS the global write (bash gives `local` no meaning there), so the caller passes 0.
  delete captured[v]; delete arrcap[v]
  if (!only_fn) { delete fcaptured[v]; delete farrcap[v] }
}
function is_verdict_line(line) {
  # ⛔ THE VERDICT VOCABULARY IS THE ONE THE FLEET ACTUALLY PRINTS (#2121 review, P2). The arm knew a
  # handful of words, so `say "seeded $O with $(ls "$O"/*.sh | wc -l …)"` and its siblings
  # (`staged`, `restored`, `converged`, `up to date`) — a count of a directory printed as the evidence
  # for the verdict — were never flagged. One home, read by both the same-line and the captured-count
  # arms, so the two cannot disagree.
  return (line ~ /(COMPLETE|complete|Completed|completed|installed|Installed|verified|VERIFIED|✅|✔|✓|PASS|passed|succeeded|success|healthy|OK|ok:|seeded|Seeded|staged|Staged|restored|Restored|converged|Converged|up to date|up-to-date|in sync|synced|deployed|Deployed|migrated|populated)/)
}
function has_recency(line) {
  # `status --porcelain` (not `git status`) is the recency alternative for a dirty-count verdict: a
  # working-tree listing IS a read of THIS run, so it is not the shape.
  return (line ~ /(-newer|-mmin|-cmin|-newermt|-anewer|diff |cmp | -nt | -ot |status --porcelain)/)
}
function expands_listcnt(line,   v) {
  # A count captured on an EARLIER line and printed in the verdict of this line is the same evidence.
  for (v in listcnt) if (match(line, "\\$\\{?" v "([^A-Za-z0-9_]|$)")) return 1
  for (v in flistcnt) if (match(line, "\\$\\{?" v "([^A-Za-z0-9_]|$)")) return 1
  return 0
}
function track_capture(sgl, cap, arr, lc, in_fn,   v, rhs, ref, t, rv, decl) {
  # ONE home for the capture / reassignment arms (#2121 review, P2): the statement loop runs it for the
  # enclosing FUNCTION and, at top level, for the FILE (see the file-scope pass in the main rule), so
  # a feeder captured one level out is still a feeder. `cap`/`arr`/`lc` are the CURRENT scope maps, and
  # `in_fn` says whether the CURRENT scope is a function body (see drop_cap for why that decides
  # whether a declaration builtin may clear the file-scope entry).
  if (match(sgl, /^[ \t]*(local[ \t]+|declare[ \t]+|typeset[ \t]+)?(-[A-Za-z]+[ \t]+)*[A-Za-z_][A-Za-z0-9_]*="?\(?[ \t]*\$\(/)) {
    v = substr(sgl, RSTART, RLENGTH); sub(/=.*/, "", v); sub(/^.*[ \t]/, "", v)
    # `$((` is arithmetic, not a capture; `arr=( $(cmd) )` and `arr=($(cmd))` ARE array captures.
    if (substr(sgl, RSTART + RLENGTH, 1) != "(" && v ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
      cap[v] = 1
      if (substr(sgl, RSTART, RLENGTH) ~ /=\(/) arr[v] = 1
      else delete arr[v]
      # ⛔ A COUNT CAPTURED HERE IS EVIDENCE SOMEWHERE ELSE (#2121 review, P2). `n=$(ls -1 "$DST" |
      # wc -l)` followed by `echo "✅ deployment COMPLETE: $n files"` puts the count on one line and the
      # verdict on the next, and the arm only ever looked at a single line. Register the variable, and
      # a later verdict line that EXPANDS it is the shape.
      if (index(sgl, "wc -l") > 0 && has_listing_cmd(sgl)) lc[v] = 1
    }
  } else if (match(sgl, /^[ \t]*(local[ \t]+|declare[ \t]+|typeset[ \t]+)?(-[A-Za-z]+[ \t]+)*[A-Za-z_][A-Za-z0-9_]*=/)) {
    v = substr(sgl, RSTART, RLENGTH); sub(/=.*/, "", v); sub(/^.*[ \t]/, "", v)
    rhs = substr(sgl, RSTART + RLENGTH)
    gsub(/\\\$/, "", rhs)              # an ESCAPED dollar is literal text, not an expansion
    gsub(sq "[^" sq "]*" sq, "", rhs)  # neither is a single-quoted span
    ref = 0; t = rhs
    while (match(t, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
      rv = substr(t, RSTART + 1, RLENGTH - 1); sub(/^\{/, "", rv)
      if (is_cap(rv)) { ref = 1; break }
      t = substr(t, RSTART + RLENGTH)
    }
    if (v ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
      if (ref) cap[v] = 1
      else {
        # ⛔ A FUNCTION-SCOPE DECLARATION SHADOWS, IT DOES NOT OVERWRITE (#2121 review round 3, P3).
        decl = (sgl ~ /^[ \t]*(local[ \t]+|declare[ \t]+|typeset[ \t]+)/)
        drop_cap(v, (in_fn && decl) ? 1 : 0)
      }
    }
  }
}
function forlist_captured(line,   t, u, v) {
  # ⛔ `for x in $var` IS THE SAME FEEDER AS `for x in $(cmd)`, one assignment earlier (#2121). The
  # loop arm only matched a LITERAL substitution in the for-list, so the capture-then-iterate
  # spelling — `out="$(cmd)"` … `for x in $out`, which is how most of this repo writes it — never
  # set fn_loop, and an unguarded zero-iteration loop in a success-default function read as CLEAN.
  # The variable must have been CAPTURED from a substitution in THIS function (captured[], reset by
  # flush_fn), and it must be the WHOLE word: a path PREFIX (`for f in "$HERE"/*.sh`) is a glob whose
  # iterations come from the filesystem, not from the capture, and a QUOTED expansion (`for f in
  # "$out"`) does not word-split so an empty value still iterates ONCE — neither is this shape, and
  # both spellings occur constantly here.
  if (!match(line, /(^|[ \t;])for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+/)) return 0
  t = substr(line, RSTART + RLENGTH)
  sub(/[ \t]*;.*$/, "", t)   # the word list ends at `; do` (or a `;`-separated statement)
  t0 = t
  while (match(t, /(^|[ \t])\$\{?[A-Za-z_][A-Za-z0-9_]*\}?([ \t]|$)/)) {
    v = substr(t, RSTART, RLENGTH); gsub(/[^A-Za-z0-9_]/, "", v)
    if (is_cap(v)) return 1
    t = substr(t, RSTART + RLENGTH)
  }
  # AND THE ARRAY FORM IS THE ONE CASE WHERE QUOTING DOES NOT SAVE (#2121 review round 4, P2).
  # `for x in "$out"` over a SCALAR iterates once even when it is empty, which is why that quoted
  # spelling is not this shape — but `for x in "${arr[@]}"` over an EMPTY ARRAY iterates ZERO times,
  # so the quoted array IS the shape, and the note above justified the exclusion with the scalar case
  # alone. Re-scan the word list for `"${name[@]}"` / `"${name[*]}"`, quoted or not.
  # ⛔ AND ONLY A NAME THE ARRAY ARM CAPTURED IS AN ARRAY (#2121 review, P3). Accepting ANY captured
  # name here made `out="$(cmd)"` (a SCALAR) followed by `for x in "${out[@]}"` a finding — but a
  # quoted `[@]` over a scalar iterates ONCE even when the value is empty, so that code is CORRECT
  # and the report was a false positive, the trade this header refuses.
  u = t0
  while (match(u, /"?\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}"?/)) {
    v = substr(u, RSTART, RLENGTH); gsub(/[^A-Za-z0-9_]/, "", v)
    if (is_cap(v) && is_arrcap(v)) return 1
    u = substr(u, RSTART + RLENGTH)
  }
  return 0
}

function counter_proof(   v) {
  # ⛔ A COUNTER IS ONLY A COUNTER WHERE IT IS COMPARED (#2121 review, P1). The old rule accepted
  # any `=$((`, `++`, `+= 1` or `wc -l` ANYWHERE in the function as proof that the loop iterated —
  # and the check suite B6 fixture shows `$((` is often plain arithmetic (`local n=$(( $1 * 100 / $2 ))`),
  # so a zero-iteration loop in the same function read as guarded and the gate reported PASS. The
  # proof must be tied to a VARIABLE: assigned as a count AND compared numerically. Both sets are
  # collected per variable and the intersection is the proof, so arithmetic on another name cannot
  # launder the shape.
  for (v in cnt) if (v in numtest) return 1
  return 0
}
function scan_words(line,   i, n, c, start, j) {
  # ⛔ ONE LINEAR WALK OVER THE LINE (#2121 review round 3, P1). The arms below read "an identifier
  # followed by an operator", and each of them used to be an UNANCHORED regex such as
  # /[A-Za-z_][A-Za-z0-9_]*\+\+/. mawk restarts such a pattern at every position, and each attempt
  # consumes the whole remaining run of identifier characters before failing, so ONE long CODE line
  # cost O(length^2): measured 1 KB 0.1 s, 20 KB 12 s, 100 KB never returned (>120 s), and a comment
  # line of the same length was instant (comments skip the rules). A gate that HANGS is worse than one
  # that reds: nothing downstream can even report it, and the fleet does generate long lines. The
  # identifiers are collected ONCE per line and the arms read this list, which is linear.
  WN = 0; n = length(line); i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (c in ALPHA) {
      start = i; j = i + 1
      while (j <= n && (substr(line, j, 1) in NUMCH)) j++
      WN++; WSTART[WN] = start; WNAME[WN] = substr(line, start, j - start); WPOS[WN] = j
      i = j; continue
    }
    i++
  }
  return WN
}
function skip_blanks(line, i,   n) {
  # The `[ \t]*` of the patterns these arms replace, as a loop: bounded by the line, linear.
  n = length(line)
  while (i <= n && (substr(line, i, 1) == " " || substr(line, i, 1) == "\t")) i++
  return i
}
function note_counter(line,   k, p, q, n, v, rhs, has_wc) {
  # `v=$(( v + 1 ))` is a count; `pct=$(( 100 * 2 / 7 ))` is arithmetic that happens to use the same
  # operators (the B6 fixture). The RHS must READ the variable it assigns — that is what makes it an
  # increment rather than a computation, and it is the only lexical difference between the two.
  # Every arm below reads the WORD LIST (scan_words) instead of re-scanning the line: same rules, one
  # pass, linear in the line length.
  n = length(line)
  has_wc = (index(line, "wc -l") > 0)
  for (k = 1; k <= WN; k++) {
    v = WNAME[k]; p = WPOS[k]
    # `++v` (the token BEFORE the name)
    if (WSTART[k] > 2 && substr(line, WSTART[k] - 2, 2) == "++") cnt[v] = 1
    # `v++`
    if (substr(line, p, 2) == "++") cnt[v] = 1
    # `v+= 1`
    if (substr(line, p, 2) == "+=") {
      q = skip_blanks(line, p + 2)
      if (substr(line, q, 1) == "1" && (q + 1 > n || substr(line, q + 1, 1) ~ /[ \t;]/)) cnt[v] = 1
    }
    if (substr(line, p, 1) != "=") continue
    q = p + 1
    if (substr(line, q, 1) == "\"") q++
    # `v=$(( … ))`: a count only when the RHS READS v
    if (substr(line, p, 4) == "=$((") {
      rhs = substr(line, p)
      # ⛔ A BOUNDED REFERENCE, NOT A SUBSTRING (#2121 review round 3). `index(rhs, v) > 0` matched the
      # name INSIDE another identifier — `total=$(( 3 * count ))` read as an increment of `total`, and
      # `n=$(( 0 * n_seen ))` as one of `n` — so a variable that is merely arithmetic became a "counter",
      # and a counter SUPPRESSES the finding. That direction is the worse one: the substring test here
      # does not red correct code, it turns a real false-PASS shape GREEN. The identifier-boundary test
      # is what makes it a read of THIS variable.
      if (index(rhs, v) > 0 && match(rhs, "(^|[^A-Za-z0-9_])" v "([^A-Za-z0-9_]|$)")) cnt[v] = 1
      continue
    }
    # `v=$( … )` where the substitution counts a listing: the count is captured here and printed later
    if (has_wc && substr(line, q, 2) == "$(" && substr(line, q + 2, 1) != "(") cnt[v] = 1
  }
}
function note_numtest(line,   t, v, k, p, q, n, op, rest, has_arith) {
  # `[ "$n" -gt 0 ]`, `[ "${n}" -ne 0 ]`, `[ "$n" = 0 ]` — the SHELL-TEST spellings.
  # ⛔ `= 0` AND `(( … ))` ARE NUMERIC TESTS TOO (#2121 review round 4, P1). The arm matched only
  # `"$name" -flag <digits>`, so `[ "$n" = 0 ]` (61 occurrences of `[ "$x" = 0 ]` in scripts/*.sh)
  # and `(( n > 0 ))` — the two most common ways this repo guards a zero count — were reported as
  # an UNGUARDED loop.
  # ⛔ BOTH SPELLINGS READ THE WORD LIST (#2121 review round 3, P1). The ARITHMETIC arm was an
  # unanchored `[A-Za-z_][A-Za-z0-9_]*[ \t]*(>|<|…)` regex — quadratic on a long identifier run (see
  # scan_words), and reachable from any long line containing `((` or `[[`.
  n = length(line)
  # ⛔ ONE SCAN PER LINE, NOT ONE PER WORD (#2121 review round 3, P1): `index(line, "((")` inside the
  # per-word loop is O(words x line) — the same shape this round exists to remove.
  has_arith = (index(line, "((") > 0 || index(line, "[[") > 0)
  for (k = 1; k <= WN; k++) {
    v = WNAME[k]; p = WPOS[k]
    # ── the SHELL-TEST spelling: the name must be a PARAMETER EXPANSION ($v, "$v", ${v}, "${v}")
    q = (WSTART[k] > 1 && substr(line, WSTART[k] - 1, 1) == "{") ? WSTART[k] - 1 : WSTART[k]
    if (q > 1 && substr(line, q - 1, 1) == "$") {
      q = p
      if (substr(line, q, 1) == "}") q++
      if (substr(line, q, 1) == "\"") q++
      q = skip_blanks(line, q)
      if (match(substr(line, q, 8), /^(-[a-z]+|[<>]=?|!?==?)/)) {
        rest = substr(line, q + RLENGTH)
        if (match(rest, /^[ \t]+-?[0-9]+/)) numtest[v] = 1
      }
    }
    # ── the ARITHMETIC spelling carries no `$`, and a bare name compared to a number is only a test
    # INSIDE `(( … ))` or `[[ … ]]` — anywhere else a `>` is a redirect, and reading `cmd > 0` as a
    # numeric test would suppress a real finding.
    if (has_arith) {
      q = skip_blanks(line, p)
      if (match(substr(line, q, 8), /^([<>]=?|==|!=|-g[te]|-l[te]|-eq|-ne)/)) {
        rest = substr(line, q + RLENGTH)
        if (match(rest, /^[ \t]*-?[0-9]+/)) numtest[v] = 1
      }
    }
  }
}
function flush_fn() {
  # ⛔ THE `# verified:` MARKER EXEMPTS THIS FINDING TOO (#2121 review). It is a FUNCTION-scope
  # finding that is reported at `fn_loop_line`, so `exempt` — which is computed per LINE — was
  # consulted by the line rules only, and the documented remedy (exempt one line with a `# verified:`
  # marker, the text the FAIL message prints) silently changed nothing for empty-as-pass. Measured on
  # a fixture: a marker on the loop line, and one on the line above it, both still produced 1 finding
  # and exit 1, while the same marker suppressed a discarded-status finding on its own line. The marker is
  # recorded where the loop is RECOGNISED, so it is read in the same pass (the two-definitions rule).
  # ⛔ IN A DRIFTED SCOPE THE COUNTER GATE DOES NOT APPLY (#2121 review, P0/P1): the drift merged
  # several functions into one scope, so whether a count belongs to THIS loop is exactly what was lost,
  # and applying that gate is what silently dropped the shape. See the END block.
  gate_ok = (PARTIAL_SCOPE ? 1 : (fn_counter == "" && !counter_proof()))
  if (fn != "" && fn_loop != "" && fn_flagret != "" && gate_ok && (fn_flagret in flaginit)) {
    if (PARTIAL_SCOPE)
      printf "%s\t%d\t%s\t%s\n", FILENAME, fn_loop_line, "empty-as-pass", \
        "the loop over a substitution can iterate ZERO times and the enclosing scope still returns a flag INITIALISED TO SUCCESS — and the scope did not close by end of file, so its extent (and any iteration count in it) is UNKNOWN; reported rather than dropped"
    else
      printf "%s\t%d\t%s\t%s\n", FILENAME, fn_loop_line, "empty-as-pass", \
        "the loop over a substitution can iterate ZERO times and " fn "() still returns a flag INITIALISED TO SUCCESS, so a feeder that emitted nothing is a PASS here"
  }
  fn = ""; fn_line = 0; fn_loop = ""; fn_loop_line = 0; fn_counter = ""; fn_flagret = ""; PARTIAL_SCOPE = 0
  NESTED_N = 0; TOPPEND = 0
  split("", captured); split("", flaginit); split("", cnt); split("", numtest)
  split("", arrcap); split("", listcnt); split("", declared)
  depth = 0; end_fn = 0
}
BEGIN { prev_marker = 0; prev_marker_bad = 0; prev_marker_line = -1
        fn = ""; fn_line = 0; fn_loop = ""; fn_loop_line = 0; fn_counter = ""; fn_flagret = ""
        NESTED_N = 0
        depth = 0; end_fn = 0; BR_END = 0
        heredoc = ""; heredoc_dash = 0; heredoc_line = 0; heredoc_quoted = 0; sq = sprintf("%c", 39)
        HQN = 0; HD_N = 0; PDEPTH = 0; PARAM_D = 0
        QN = 1; QK[1] = "top"; QD[1] = 0; QS[1] = 0; QP[1] = 0; QA[1] = 0; QH[1] = 0; QR[1] = 0; QL[1] = 0; BR_HIDDEN = 0; in_hbody = 0
        split("", fcaptured); split("", farrcap); split("", flistcnt)
        split("", arrcap); split("", listcnt); split("", declared); PARTIAL_SCOPE = 0
        # ⛔ CHARACTER CLASSES AS TABLES, NOT REGEXES (#2121 review round 3, P1). The per-character
        # walk below runs on every code line, and `c ~ /[A-Za-z_]/` compiles nothing but still enters
        # the regex engine once per character. A lookup is O(1).
        ALPHA["_"] = 1
        for (ci = 65; ci <= 90; ci++) ALPHA[sprintf("%c", ci)] = 1
        for (ci = 97; ci <= 122; ci++) ALPHA[sprintf("%c", ci)] = 1
        for (ci in ALPHA) NUMCH[ci] = 1
        for (ci = 48; ci <= 57; ci++) NUMCH[sprintf("%c", ci)] = 1 }
FNR == 1 { QN = 1; QK[1] = "top"; QD[1] = 0; QS[1] = 0; QP[1] = 0; QA[1] = 0; QH[1] = 0; QR[1] = 0; QL[1] = 0
           # the heredoc queue and the walked-`${…}` carry belong to the FILE as well: a previous
           # unterminated state must not leak into this one (each file is a fresh scan).
           heredoc = ""; heredoc_dash = 0; heredoc_quoted = 0; HQN = 0; PDEPTH = 0; PARAM_D = 0
           # the FILE-scope maps belong to the file, not to the function (see is_cap)
           split("", fcaptured); split("", farrcap); split("", flistcnt)
           split("", arrcap); split("", listcnt); split("", declared) }
{
  # ⛔ A QUOTED HEREDOC IS DATA, NOT CODE. A heredoc whose delimiter is quoted (EOS in single
  # quotes, double quotes, or backslash-escaped) suppresses expansion, so
  # its body is a FIXTURE, a template or a test case — never statements bash runs unless a caller
  # feeds it to an interpreter. Scanning it flags the very fixture a suite needs to prove this
  # guard detects anything (the shapes must exist somewhere), and a linter that reds its own test
  # is deleted from CI within a week. An UNQUOTED heredoc IS still scanned: its body is generated
  # bash. This is the same reasoning as "a comment is not code" and it is stated rather than
  # implied, because it is the one place a shape can hide from this check.
  RAW = $0
  # ⛔ A CRLF LINE ENDING IS NOT PART OF THE LINE (#2121 review round 4, P1). On a CRLF checkout the
  # `\r` survived into every comparison: `local bad=0\r` failed the `=0` arm (which requires
  # `[ \t;]`/EOL next), `return "$bad"\r` failed the verdict arm (which requires `[ \t]*$`), and
  # `EOF\r` never matched the heredoc terminator — so an `empty-as-pass` in a CRLF file was reported
  # NOWHERE and the run printed PASS. The carriage return is stripped ONCE, here, before any arm or
  # terminator compares it.
  sub(/\r$/, "", RAW)
  $0 = RAW
  if (heredoc != "") {
    # `<<-` strips leading TABS from the terminator, so the comparison must too — otherwise a
    # tab-indented terminator never matches and the heredoc swallows the rest of the file.
    t = $0
    if (heredoc_dash) sub(/^[ \t]+/, "", t)
    # ⛔ THE NEXT QUEUED HEREDOC TAKES OVER HERE (#2121 review round 4, P0): `cat <<A <<B` reads the
    # body of A and then the body of B, and both must be recognised as DATA.
    if (t == heredoc) { heredoc_pop(); next }
    # A QUOTED body is DATA (a fixture, a template, a test case) — skipped entirely.
    if (heredoc_quoted) next
    # AN UNQUOTED body is generated bash: the LINE rules still run on it (a shape may genuinely live
    # there), but bash expands it like a double-quoted string and never re-parses quoting or braces,
    # so the carry and the brace depth stay where the opener left them.
    in_hbody = 1
  } else in_hbody = 0
  # ⛔ A HEREDOC BODY LINE IS DATA, SO IT CANNOT OPEN A HEREDOC (#2121 review round 3, P1). The
  # opener search used to run on EVERY line, including the body of an already-open heredoc — where a
  # `<<` is text the compiled script prints, not a redirect. Two failures followed: a body line
  # `printf` whose ARGUMENT carries a `<<` produced `unterminated-heredoc` on a
  # `bash -n`-clean file (loud false red), and a body line could OVERWRITE the real delimiter, so the
  # `HD_POSA` holds every position at which brace_delta met a `<<` at command position — never in a
  # comment, a quote, a `$( … )`, a `${…}`, an arithmetic expansion or a `[[ … ]]` test. It is
  # therefore only consulted while no heredoc is open, and the opener is recorded from the walk itself
  # (brace_delta) — see heredoc_at.
  HD_N = 0
  # ⛔ A COMMENT IS NOT CODE, and that is decided HERE — BEFORE the brace bookkeeping — so a comment
  # that merely QUOTES a brace (`# }`) can neither close a function nor open a block.
  # ⛔ BUT A `#` INSIDE AN OPEN QUOTE IS NOT A COMMENT (#2121 review round 4). The whole line used to be
  # skipped whenever it STARTED with `#`, so a quote that closed on such a line was never seen: the
  # carry stayed open to EOF and the file was reported as `unterminated-quote` — a false red on a
  # `bash -n`-clean multi-line string whose last line happens to begin with a hash. The line is a
  # comment only when the CURRENT context has no quote open at its start (inside a `$( … )` a `#` line
  # IS a comment, which is why this reads the context rather than the outermost carry).
  is_comment = ($0 ~ /^[ \t]*#/ && QS[QN] == 0 && QD[QN] == 0)
  if (!is_comment && !in_hbody) {
  opened = 0
  # ⛔ MEASURE THE LINE BEFORE ITS HEADER IS TAKEN OFF IT (#2121 review round 8, P0). This call moved
  # above both header branches: `function name() {` strips the header AND the opening brace, so
  # measuring afterwards saw a brace-less remainder and then subtracted the consumed brace a second
  # time — `delta = -1` on the header line, which ENDED the function there, so every line of its body
  # was scanned at top level and `empty-as-pass` became unreportable for that whole function. Twenty
  # top-level `function x() {` helpers exist in the scan set, so this printed PASS over shapes the
  # previous commit caught.
  LINE_DELTA = brace_delta($0)   # ONE call per line: it advances the quote carry (review round 7)
  # ⛔ THE PHANTOM IS RESOLVED BEFORE ANY OTHER HEADER IS CONSIDERED (#2121 review round 11, P2). The
  # nested branch ran first, so a header-shaped line following a phantom header was consumed as a nested
  # helper of a function that does not exist: the real function verdict was then gated off by NESTED_N
  # and its shape was dropped. A header-shaped line now closes the phantom instead.
  if (TOPPEND) {
    # ⛔ A HEADER-SHAPED LINE CLOSES THE PHANTOM EVEN WHEN IT CARRIES A BRACE (#2121 review round 11,
    # P2). Checking BR_OPEN first let `phantom()` + `real() {` adopt real brace as the phantom own, so
    # the real function was then read as a NESTED helper of a function that does not exist — its
    # flaginit/return arms gated off and its shape dropped silently. Order matters here.
    if ($0 ~ /^[ \t]*([A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)|function[ \t]+[A-Za-z_])/) { TOPPEND = 0; fn = ""; fn_line = 0 }
    else if (BR_OPEN > 0) TOPPEND = 0
    else if ($0 !~ /^[ \t]*(#|$)/) { TOPPEND = 0; fn = ""; fn_line = 0 }
  }
  # ⛔ FUNCTION BOUNDARIES ARE TRACKED HERE, AFTER the heredoc skip: a fixture body may legitimately
  # contain a function header and a closing brace, and tracking those would attribute fixture lines
  # to a function (and cut a real function short at the closing brace of the fixture).
  # `function name()` is recognised too, because the awk helpers in this scan set spell their
  # headers that way.
  if ($0 ~ /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_]*/ && fn == "") {
    flush_fn(); fn = $0; fn_line = FNR; sub(/^[ \t]*function[ \t]+/, "", fn); sub(/[ \t(].*/, "", fn)
    # ⛔ THE ONE-LINE BODY APPLIES TO THIS SPELLING TOO (#2121 review, P2). The round-3 fix taught
    # the `name()` branch to fall through past the opening brace, but this branch kept `next`, so
    # `function f() { local x=$(cmd); }` was never seen by the line rules while the identical body in
    # the `name()` spelling was. Same treatment: drop the header, keep the body.
    # ⛔ `opened` MUST MEAN "THE COUNTED OPENING BRACE WAS CONSUMED" (#2121 review round 9, P1). Raw
    # text is wrong here for the same reason it was wrong for the nested branch: a header followed by a
    # comment carrying the only brace (`collect() # builds a { map`) set opened=1 for a brace the walk
    # ignored, so the new arithmetic gave delta = -1 and the function ENDED on its header line — silent,
    # because depth returned to 0 and no partial note is printed. BR_OPEN > 0 implies the raw first
    # brace is the counted one (the walk stops at a comment and skips ${…}).
    if (BR_OPEN > 0 && index($0, "{") > 0) { $0 = substr($0, index($0, "{") + 1); opened = 1 }
    # ⛔ A CARRY IS NOT AN ABSENT BRACE, AND A BRACE-LESS HEADER MUST NOT LEAK (#2121 review
    # round 11, P1). Two separate holes lived in this one `else { next }`: when the walk quote carry
    # is open the brace on the line was NOT counted but it IS there, so `fn` must stay set and the
    # body stays attributed (46 live headers, every one with a brace on its line — detaching them
    # made a function-scope finding structurally unreportable, a NEW silent false PASS); and a header
    # with no brace at all left `fn` set with no recovery, so it became a phantom that swallowed the
    # next function. This spelling had neither guard while its `name()` twin had the first.
    # ⛔ A HIDDEN BRACE MUST STILL BE COUNTED, AND A BRACE-LESS HEADER MUST STILL BE PENDING (#2121
    # review round 12, P0/P1). `BR_HIDDEN` alone was wrong twice: keeping `fn` without counting the
    # brace left `depth` at 0 for a function whose closing brace fell INSIDE the quoted region, so it
    # stayed open to EOF and 761 lines of this scan set were attributed to a phantom with no note
    # printed; and a brace-less header under a carry never reached TOPPEND at all. Counting the hidden
    # brace lets the closer close the body, and the `index(...) > 0` test sends a genuinely brace-less
    # header to the pending recovery where the comment already said it belonged.
    else if (BR_HIDDEN) { depth = 1; next }
    else { TOPPEND = 1; next }
  }
  # ⛔ ANY FUNCTION HEADER MET INSIDE AN OPEN BODY IS A NESTED HELPER, NOT A NEW FUNCTION (#2121
  # review round 5, P1). The round-4 fix guarded only the INDENTED spelling, so a helper written at
  # column 0 still called flush_fn() and threw the enclosing state away — the two spellings must
  # behave the same. The helper body is covered by the BRACE COUNTER like any other brace group, and
  # its depth is recorded so a `return` INSIDE the helper cannot be read as the OUTER verdict (the
  # round-5 P2 that follows from merging the bodies).
  # A nested header whose `{` sits on the NEXT line (ordinary bash style) must be caught too: the
  # header-shaped line cannot see its brace, so it is held as PENDING and the region is pushed only
  # if the very next line opens the block (review round 6, P1). Without this, the helper body was read
  # as the OUTER function and its `return "$rc"` became the outer verdict.
  if (PEND) {
    # A blank line or a comment between a header and its brace does not cancel the pending region —
    # only a real statement that is not the opening brace does (review round 7, P1).
    if (BR_OPEN > 0) { NESTED[NESTED_N] = PEND_DEPTH; NESTED_N++; PEND = 0 }
    else if ($0 !~ /^[ \t]*(#|$)/) PEND = 0
  }
  if (fn != "" && $0 ~ /^[ \t]*([A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)|function[ \t]+[A-Za-z_])/) {
    # ⛔ DECIDE ON THE BRACES THE COUNTER ACTUALLY SEES, not on raw text (review round 7, P1).
    # `index($0, "{")` matched a brace inside a trailing comment or a `${…}` that brace_delta ignores,
    # so the region was pushed and popped on the same line and the helper body was scanned as the
    # OUTER function — a false positive on a `return 0` function and, with the helper after the
    # verdict, a FALSE NEGATIVE over a real shape. A header whose counted braces are zero is PENDING.
    if (BR_OPEN > 0) { NESTED[NESTED_N] = depth; NESTED_N++ }
    else { PEND = 1; PEND_DEPTH = depth }
  }
  # ⛔ ONE ALTERNATION, INDENTATION-AGNOSTIC (#2121 review round 10, P2). The indented alternative
  # required the `{` on the SAME line, so an indented header with the brace on the next line was never
  # recognised as a function at all: its body was scanned at TOP level, empty-as-pass was unreportable
  # there, and NOTHING was printed — no finding, not even a partial note. The `function` spelling was
  # already indentation-agnostic, so the two spellings disagreed. PEND (below) supplies the recovery
  # when the counted brace does not arrive on the header line.
  if (fn == "" && $0 ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/) {
    flush_fn(); fn = $0; fn_line = FNR; sub(/^[ \t]*/, "", fn); sub(/[ \t]*\(\).*/, "", fn)
    # ⛔ A ONE-LINE BODY IS NOT SKIPPED: `f() { local x=$(cmd); … }` is a whole function on one line,
    # and `next` here made both line rules blind to it (review round 3). Drop the header and fall
    # through to the line rules on whatever follows the opening brace.
    # ⛔ `opened` MUST MEAN "THE COUNTED OPENING BRACE WAS CONSUMED" (#2121 review round 9, P1). Raw
    # text is wrong here for the same reason it was wrong for the nested branch: a header followed by a
    # comment carrying the only brace (`collect() # builds a { map`) set opened=1 for a brace the walk
    # ignored, so the new arithmetic gave delta = -1 and the function ENDED on its header line — silent,
    # because depth returned to 0 and no partial note is printed. BR_OPEN > 0 implies the raw first
    # brace is the counted one (the walk stops at a comment and skips ${…}).
    if (BR_OPEN > 0 && index($0, "{") > 0) { $0 = substr($0, index($0, "{") + 1); opened = 1 }
    else if (BR_HIDDEN) { next }   # a carry hid the brace: the body stays attributed (round 11)
    else { TOPPEND = 1; next }
  }
  # ⛔ AND A TOP-LEVEL HEADER WHOSE COUNTED BRACE NEVER ARRIVES MUST NOT BECOME A PHANTOM FUNCTION
  # (#2121 review round 10, P1). Taking `next` with `fn` already set left the header open with no
  # recovery when the walk never counts a brace for it (a drifted quote carry is the live case): every
  # line after it was attributed to that function until some later `{` happened to open a block, so a
  # real shape in the tail went unreported while the only signal named the WRONG line. The discipline
  # is the one the nested branch already uses: hold the header, keep it across blank and comment lines,
  # and if the next real statement does not supply the counted brace, close the header with
  # flush_fn() and continue at top level.
  # ⛔ A BRACE GROUP INSIDE A FUNCTION IS NOT THE END OF THE FUNCTION (#2121 review round 4, P1). The
  # rule used to end the function at a `}` at ANY indent, so a nested `{ … }` threw away the
  # flag/loop/counter state of the function and every line AFTER the group was scanned as top level —
  # one brace group was enough to hide a real empty-as-pass instance while the run printed PASS.
  # (Narrowing to column 0 instead would leave `slack()` in heartbeat-loop.sh open over the rest
  # of the file — review round 1.) Braces are COUNTED instead, and the function ends only where the
  # depth returns to zero.
  if (fn != "") {
    # LINE_DELTA was computed on the RAW line; when a header branch consumed the opening brace it
    # already counted it (and set `opened`), so subtract that one to keep the brace counted exactly once.
    delta = LINE_DELTA - (opened ? 1 : 0)
    newdepth = depth + (opened ? 1 : 0) + delta
    if (delta < 0 && newdepth <= 0) {
      # The body ends on THIS line: keep what PRECEDES the closing brace for the line rules, so a
      # one-line body is still scanned (G6) and a `} > file` closer is never read as code.
      if (opened) {
        # BR_END is a RAW-line offset and $0 has been cut down to the body, so it cannot be reused:
        # the last `}` of the remainder is the closer of this one-line body.
        t2 = $0; p = 0
        while (match(t2, /}/)) { p += RSTART; t2 = substr(t2, RSTART + 1) }
        if (p > 0) $0 = substr($0, 1, p - 1)
      } else if (BR_END > 0) $0 = substr($0, 1, BR_END - 1)
      end_fn = 1; newdepth = 0
    }
    depth = (newdepth < 0 ? 0 : newdepth)
    while (NESTED_N > 0 && depth <= NESTED[NESTED_N - 1]) NESTED_N--
  }
  }   # end of the non-comment function/brace bookkeeping
  # ⛔ THE OPENER IS TAKEN FROM THE WALK, AFTER IT, ON THE RAW LINE (#2121 review round 3, P1).
  # `HD_POSA` is where brace_delta met a `<<` at command position — never in a comment, a quote, a
  # `$( … )`, a `${…}`, an arithmetic expansion or a `[[ … ]]` test. The delimiter token is read from
  # `RAW`, the line as it arrived, because the bookkeeping above TRUNCATES `$0` at a header brace or at
  # the closing brace of a one-line body, which would shift the position.
  # ⛔ EVERY OPENER ON THE LINE, IN ORDER (#2121 review round 4, P0). Only the FIRST was recorded, so
  # `cat <<A <<B` left the body of B unrecorded and it was walked as code. Each opener is queued; the
  # terminator of one promotes the next (see heredoc_push/heredoc_pop).
  # ⛔ THE OPENER LINE IS RECORDED, not inferred from FNR in the END block (#2121 review round 5,
  # P2): FNR there is the LAST line of the file, so the row a human was asked to justify pointed at the
  # bottom of the file instead of the heredoc that blinded the scan.
  if (!is_comment && !in_hbody && HD_N > 0) {
    for (hk = 1; hk <= HD_N; hk++) {
      delim = heredoc_at(RAW, HD_POSA[hk])
      if (delim == "") continue
      heredoc_push(delim, (substr(RAW, HD_POSA[hk] + 2, 1) == "-"), HEREDOC_Q, FNR)
    }
  }
  # ⛔ A COMMENT IS NOT CODE, for the RULES and the bookkeeping too. Bookkeeping over comment text
  # let a comment containing `wc -l` silently DISABLE empty-as-pass for a whole function, while a
  # comment quoting a loop reported the comment line itself as the finding (round 2). A comment
  # can still carry the MARKER — that is where an exemption lives — so markers are read below.
  line = $0
  # ⛔ THE RULES READ THE CODE PART ONLY (#2121 review round 3, P2) — see strip_comment. The MARKER is
  # read from `line`, because that is exactly where an exemption lives (in a comment). The walk is
  # skipped when the line carries no `#` at all, which is most code (one index() instead of a pass).
  code = (index(line, "#") > 0) ? strip_comment(line) : line
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
    if (decl_masks_status(code))
      printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, "discarded-status", \
        "the declaration builtin masks the exit status of the command substitution, so a FAILED read and an EMPTY one are indistinguishable"

    # ⛔ A LISTING COMMAND AT A COMMAND POSITION, never the substring `ls` in labels/signals or
    # `find` in the word findings (round 2).
    lpos = index(code, "wc -l")
    if (lpos > 0 && has_listing_cmd(substr(code, 1, lpos - 1))) {
      if (is_verdict_line(code) && !has_recency(code))
        printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, "pre-existing-as-evidence", \
          "a count of state that existed BEFORE this run is printed as the evidence for the verdict, so it does not prove this run did anything"
    } else if (expands_listcnt(code) && is_verdict_line(code) && !has_recency(code)) {
      # ⛔ THE COUNT AND THE VERDICT MAY BE ON DIFFERENT LINES (#2121 review, P2). `n=$(ls -1 "$DST" |
      # wc -l)` then `echo "✅ deployment COMPLETE: $n files"` is the same evidence one line earlier,
      # and the arm — which only ever looked at a single line — reported nothing. `track_capture`
      # registers a variable that was CAPTURED from a listing piped into `wc -l`, and a later verdict
      # line that EXPANDS it is the shape (see expands_listcnt).
      printf "%s\t%d\t%s\t%s\n", FILENAME, FNR, "pre-existing-as-evidence", \
        "a count of state that existed BEFORE this run, captured on an earlier line, is printed as the evidence for the verdict, so it does not prove this run did anything"
    }
  }

  # Function-scope bookkeeping runs whether or not this LINE is exempt (an exemption covers one
  # construct, not the function it lives in) — but NEVER on a comment line (see above).
  if (fn != "" && !is_comment) {
    # ⛔ ONE WALK PER LINE, SHARED BY EVERY ARM THAT NEEDS "a name followed by an operator"
    # (#2121 review round 3, P1). Filled BEFORE the statement loop, because the counter, numeric-test
    # and flag arms below all read it.
    scan_words(code)
    # ⛔ A STATEMENT AFTER `;`/`&&`/`then` IS STILL A STATEMENT (#2121 review round 4, P2). The arms
    # below were anchored to the START of the line, so `local r; r="$(cmd)"` — the spelling MEMORY.md
    # recommends for this very hazard, and one of the commonest in this tree — was never registered as
    # a capture, leaving the empty-as-pass half blind for that function (as were `[ -n "$x" ] && …`
    # and `if …; then …; fi`). The line is split into statements, in ORDER, and every arm (capture,
    # reassignment, writer, loop) runs on each one — order matters: a `read`/`unset` must end a
    # capture that precedes it and must NOT end one that follows it (review round 5, P1).
    nseg = split_stmts(code)
    for (si = 1; si <= NSEG; si++) {
    sgl = SEG[si]
    sub(/^[ \t]*(then|do|else|elif)[ \t]+/, "", sgl)
    sub(/[ \t]+#.*/, "", sgl)          # a trailing comment is not code, here either
    # A SUBSHELL CANNOT WRITE THIS SHELL: `( unset X; run )` stays one segment (the splitter keeps
    # parentheses together), and a segment that OPENS a subshell is skipped for the writer arms.
    subshell = (sgl ~ /^[ \t]*\(/)
    # ⛔ ONE HOME FOR THE CAPTURE / REASSIGNMENT ARMS (#2121 review, P2): `track_capture` runs here
    # for the enclosing FUNCTION and, at top level, for the FILE (the file-scope pass below), so a
    # feeder captured one level out is still a feeder. Its comments carry the reasoning for both arms.
    track_capture(sgl, captured, arrcap, listcnt, 1)
    # ⛔ A WRITE THAT DOES NOT COME FROM A SUBSTITUTION CLEARS THE CAPTURE (#2121 review round 4).
    # `read -r out <<< "alpha beta"` and `unset out` overwrite the variable with something the author
    # stated, exactly like an explicit `out=""`, so a loop over it cannot be the shape. These are
    # segment arms, in order, and a segment that is a SUBSHELL cannot write this shell (round 5).
    # `printf -v` and mapfile/readarray are NOT handled and are declared in the header instead.
    if (!subshell && match(sgl, /(^|[ \t;&|])read[ \t]+(-[A-Za-z]+[ \t]+)*[A-Za-z_][A-Za-z0-9_]*([ \t]|$)/)) {
      rv = substr(sgl, RSTART, RLENGTH); sub(/^.*read[ \t]+/, "", rv); sub(/^-[A-Za-z]+[ \t]+/, "", rv)
      sub(/[ \t].*$/, "", rv); drop_cap(rv, 0)
    }
    if (!subshell && match(sgl, /(^|[ \t;&|])unset[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      rv = substr(sgl, RSTART, RLENGTH); sub(/^.*unset[ \t]+/, "", rv)
      drop_cap(rv, 0)
    }
    # ⛔ `name=0` FOR A BARE-DECLARED FLAG IS THE SUCCESS DEFAULT (#2121 review, P2): `local bad` then
    # `bad=0` is the split declaration the header recommends, and the declaration arm recorded nothing
    # for it (see the flaginit arm).
    if (match(sgl, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=0[ \t]*;?[ \t]*$/)) {
      w = substr(sgl, RSTART, RLENGTH); sub(/=.*/, "", w); sub(/^[ \t]*/, "", w)
      if (w in declared) flaginit[w] = 1
    }
    # The loop arm runs HERE, per statement, so that a writer later on the line cannot erase a loop
    # that precedes it (review round 5, P1).
    if (fn_loop == "" && !exempt && (sgl ~ /done[ \t]*<[ \t]*<\(/ || sgl ~ /done[ \t]*<<</ || sgl ~ /for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+\$\(/ || forlist_captured(sgl))) {
      # ⛔ THE MARKER EXEMPTS THE LOOP IT IS ON, NOT THE WHOLE FUNCTION (#2121 review round 4, P1).
      # `fn_loop_exempt` recorded the FIRST loop found and gated the report on it, so a `# verified:`
      # marker on a benign display loop disarmed the finding for a DIFFERENT, unguarded loop later in
      # the same function — the documented remedy became the bypass, contradicting this file rule that
      # an exemption covers one construct, not the function it lives in. An exempt loop now simply does
      # not become the recorded loop; a later unmarked one still does, and a function whose only loop
      # is marked records none and is not reported.
      fn_loop = 1; fn_loop_line = FNR
    }
    }
    # A COUNTER, not an ordinary status test: `=$((`, `++`, `+= 1` and `wc -l` can only be an
    # iteration count. A bare `-eq 0`/`-gt 0` is usually a STATUS test, and counting it as proof of
    # iteration let the canonical shape hide behind `[ "$rc" -eq 0 ]` (review round 1).
    # The spelling that ASSIGNS then checks `|| return 1` on the same line IS the correct fix and
    # status is observed on the same line (review round 2). Only return/exit/die/fail count —
    # `|| continue` is a per-ITEM skip and says nothing about an empty feeder.
    # ⛔ THE `|| return` ARM MUST BE THE CORRECT SHAPE, NOT ANY LINE IN THE FUNCTION (#2121 review,
    # P1). It used to fire for ANY `|| return`/`exit`/`die`/`fail` in the function — so an ordinary
    # precondition (`[ -d "$DIR" ] || return 1`) suppressed the finding for a completely different,
    # unguarded feeder. The documented correct fix is ASSIGN-and-check on the SAME line
    # (`out="$(cmd)" || return 1`), so the arm requires an ASSIGNED substitution on that line
    # (`guarded_assignment`) — a precondition that merely USES one does not count (round 5).
    if (guard_on_captured(code) || (guarded_assignment(code) && code ~ /\|\|[ \t]*(return|exit|die|fail)([ \t;]|$)/))
      fn_counter = 1
    # The counted-loop half is per VARIABLE (see counter_proof): record what this line assigns and
    # what it compares, and let the intersection decide at flush time.
    note_counter(code)
    note_numtest(code)
    # The POLARITY of the returned flag, recorded from its DECLARATION so the finding can claim
    # "success-default": `local bad=0` is a flag that passes unless a check clears it. A
    # fail-closed function (`local ok=1` ... `ok=0` ... `return "$ok"`) has the OPPOSITE contract,
    # so an assignment anywhere is NOT evidence — only the declaration default is (review round 1).
    if (NESTED_N == 0 && code ~ /^[ \t]*(local|declare|typeset)[ \t]/) {
      # ⛔ THE `name=0` SCAN READS THE WORD LIST TOO (#2121 review round 3, P1): the regex it replaces
      # was another unanchored `name=` pattern, quadratic on a long line (see scan_words).
      for (wk = 1; wk <= WN; wk++) {
        wp = WPOS[wk]
        if (substr(code, wp, 2) == "=0" && (wp + 2 > length(code) || substr(code, wp + 2, 1) ~ /[ \t;]/)) flaginit[WNAME[wk]] = 1
      }
      # ⛔ A BARE DECLARATION IS A DECLARATION, AND `name=0` ON THE NEXT LINE IS ITS DEFAULT
      # (#2121 review, P2). `local bad` + `bad=0` is the very spelling the header and MEMORY.md
      # recommend for the discarded-status hazard, and it never reached flaginit — so a function that
      # uses the FIX for one shape was invisible to the other. The declaration is remembered, and the
      # statement loop below turns a later bare `name=0` in the same function into the success-default.
      t = code
      sub(/^[ \t]*(local|declare|typeset)[ \t]+/, "", t)
      sub(/;.*/, "", t)
      nw = split(t, wl, /[ \t]+/)
      for (wi = 1; wi <= nw; wi++) {
        w = wl[wi]
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*$/) declared[w] = 1
      }
    }
    # A `return` inside a nested helper belongs to the HELPER: reading it as the enclosing function
    # verdict reported `empty-as-pass` on a function whose own verdict is a literal `return 0`
    # (review round 5, P2). The declaration-default arm is gated the same way, for the same reason.
    # ⛔ THE BRACED RETURN IS THE SAME RETURN, AND SOMETIMES IT IS THE FIX (#2121 review, P2). The
    # anchor required `$NAME` immediately, so `return "${bad}"` — the spelling that survives `set -u`
    # empty-variable handling and that a lane writing the split declaration reaches for — never recorded
    # a verdict, and a real empty-as-pass shape reported nothing.
    if (NESTED_N == 0 && code ~ /^[ \t]*return[ \t]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[ \t]*;?[ \t]*$/) {
      v = code; sub(/^[ \t]*return[ \t]+"?\$\{?/, "", v); sub(/[}"].*/, "", v); sub(/[ \t;].*/, "", v)
      fn_flagret = v
    }
  }

  # ⛔ A FEEDER CAPTURED AT FILE SCOPE IS A FEEDER TOO (#2121 review, P2). The capture arms only ran
  # inside a function (`if (fn != "")`), so a top-level `LIST="$(cmd)"` was never registered at all and
  # a function looping `for x in $LIST` over it reported nothing — the same zero-iteration shape, one
  # scope out. The same home (`track_capture`) fills the FILE maps here, so a feeder that arrives from
  # outside the function is visible; `is_cap` reads both scopes.
  if (fn == "" && !is_comment && !in_hbody) {
    split_stmts(code)
    for (si = 1; si <= NSEG; si++) {
      sgl = SEG[si]
      sub(/^[ \t]*(then|do|else|elif)[ \t]+/, "", sgl)
      sub(/[ \t]+#.*/, "", sgl)
      if (sgl ~ /^[ \t]*\(/) continue        # a subshell cannot write this shell
      track_capture(sgl, fcaptured, farrcap, flistcnt, 0)
      if (match(sgl, /(^|[ \t;&|])read[ \t]+(-[A-Za-z]+[ \t]+)*[A-Za-z_][A-Za-z0-9_]*([ \t]|$)/)) {
        rv = substr(sgl, RSTART, RLENGTH); sub(/^.*read[ \t]+/, "", rv); sub(/^-[A-Za-z]+[ \t]+/, "", rv)
        sub(/[ \t].*$/, "", rv); drop_cap(rv, 0)
      }
      if (match(sgl, /(^|[ \t;&|])unset[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
        rv = substr(sgl, RSTART, RLENGTH); sub(/^.*unset[ \t]+/, "", rv)
        drop_cap(rv, 0)
      }
    }
  }

  # A function that ENDED on this line is flushed only AFTER the line rules have run on the
  # part of it that is still body (see the brace-depth block above).
  if (end_fn) flush_fn()
  prev_marker = has_marker; prev_marker_bad = marker_bad; prev_marker_line = FNR
}
END {
      # ⛔ AN OPEN QUOTE CARRY AT END OF FILE IS PROOF THAT THE WALK DESYNCHRONISED (#2121 review
      # round 4, P0). On a `bash -n`-clean file, ending inside a quote means some quote character was
      # never recognised: every line after it is read as quoted, no brace is counted, no function is
      # flushed, `TOPPEND` clears `fn` — and the run printed exit 0 with `0 finding(s)`, `0 partial
      # scan(s)` and PASS over a real `empty-as-pass`. Measured on `${NOTE:-$(cat <<EOF … EOF)}`: the
      # opener sat inside the expansion skip_param jumped, so an apostrophe in the body opened the carry
      # and nothing closed it. A file that still cannot be delimited is UNKNOWN, which the contract at
      # the top of this file calls a FAILURE — hence a FINDING, and a rule that can never be baselined.
      qopen = 0; qline = 0
      for (qk = 1; qk <= QN; qk++) if (QS[qk] != 0 || QD[qk] != 0) {
        qopen = 1
        if (QL[qk] > 0 && (qline == 0 || QL[qk] < qline)) qline = QL[qk]
      }
      if (qopen)
        printf "%s\t%d\t%s\t%s\n", FILENAME, (qline > 0 ? qline : FNR), "unterminated-quote", \
          "a quote (or an open `$( … )` context) was still open at end of file, so the walk DESYNCHRONISED: every line after it was read as quoted, no brace was counted and no function was flushed — findings and partial-scan notes in the tail describe a scope that does not exist, and the scan of this file is PARTIAL and cannot be reported as clean"
      # ⛔ A BRACE COUNT THAT NEVER RETURNS TO ZERO IS UNKNOWN, AND UNKNOWN IS NOT CLEAN (#2121 review,
      # P1). A `{` that never closes leaves every later line attributed to the block that swallowed it, and
      # — now that headers inside a body are nested regions — can suppress every later verdict through the
      # NESTED_N gates. The note goes to stderr for the reader, AND the run FAILS: a `partial scan(s)` count
      # of zero is part of what a green run means. The limits of the heuristic are declared in the header.
      # ⛔ A DRIFTED SCOPE MUST NOT SWALLOW ITS OWN SHAPES (#2121 review, P0/P1). A quote-carry desync
      # leaves the last block open, so every line after it is attributed to that one phantom scope. The
      # function gates then read as one verdict over a dozen functions, and the FIRST `[ -n "$captured" ]`
      # in the remainder set fn_counter for all of them — measured: a real empty-as-pass shape in the
      # tail reported NOTHING while the run printed PASS. So for THIS scope the counter gate is dropped
      # (the attribution of the count is exactly what the drift destroyed) and the finding is reported
      # with the drift named. The flag/verdict gates stay: they are the only evidence the shape exists.
      if (depth > 0 || fn != "") {
        PARTIAL_SCOPE = 1
        printf "note: %s: a block opened at line %d did not close by end of file — the scan of this file is PARTIAL (the trailing part is attributed to that block), reported as a note because the brace count is a heuristic and not a parser\n", FILENAME, (fn_line > 0 ? fn_line : FNR) > "/dev/stderr"
      }
      flush_fn()
      # ⛔ AN UNTERMINATED HEREDOC IS A LOUD FAILURE, never a silent blind spot: everything after its
      # opener was read as its body, so whatever the scan would have found there is UNKNOWN — and
      # unknown is not clean. The message NAMES WHICH KIND (#2121 review round 3, P1): it used to say
      # "a quoted heredoc" for every case, but an UNQUOTED one is tracked too, and its body is not
      # skipped — its brace/quote bookkeeping is, which is just as blinding and is a different fact.
      if (heredoc != "")
        printf "%s\t%d\t%s\t%s\n", FILENAME, heredoc_line, "unterminated-heredoc", \
          (heredoc_quoted ? "a QUOTED heredoc opened and was never closed, so every line after it was SKIPPED as data — the scan of this file is PARTIAL and cannot be reported as clean" : "an UNQUOTED heredoc opened and was never closed, so every line after it was read as its body and its braces and quotes were not walked — the scan of this file is PARTIAL and cannot be reported as clean")
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
  # ⛔ AN ABSENT BASELINE AND AN UNREADABLE ONE ARE NOT THE SAME FACT (#2121). Absent means "nothing
  # is grandfathered", so every finding fails — the safe direction, and no error. But a baseline that
  # EXISTS and cannot be READ is a missing OBSERVATION: the counts it declares are unknown, and
  # treating it as empty would report `0 baselined · 0 stale` — the same output as a tree with no
  # debt — which is this whole file's defect wearing the baseline's clothes. It FAILS instead, and it
  # fails by construction rather than only when a finding happens to remain un-grandfathered.
  if [ ! -e "$BASELINE" ] && [ ! -L "$BASELINE" ]; then return 0; fi
  # A REGULAR FILE, or a character device (`--baseline /dev/null` is how a caller says "declare
  # nothing" — refusing it would be a false block). A DIRECTORY, a FIFO, a DANGLING SYMLINK, or a path
  # this user cannot read is NOT a baseline, and it FAILS rather than being silently read as "you
  # exempt nothing". The `-L` half of the absent test above is load-bearing: `-e` FOLLOWS symlinks, so
  # a dangling `--baseline` took the absent path and printed `0 baselined` over a baseline that was
  # configged and never read (measured; E9 pins it).
  if { [ ! -f "$BASELINE" ] && [ ! -c "$BASELINE" ]; } || [ ! -r "$BASELINE" ]; then
    echo "FAIL: the baseline '$BASELINE' EXISTS but is not a readable file — the counts it declares are UNKNOWN, so this run cannot certify which findings are grandfathered" >&2
    return 1
  fi
  if ! cat "$BASELINE" >> "$BASE_SAFE"; then
    echo "FAIL: the baseline '$BASELINE' could not be READ — an unread baseline is not an empty one, and a run that cannot read its own exemptions cannot report a clean tree" >&2
    return 1
  fi
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
: > "$TMPDIR_RUN/scan-notes"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  scanned=$((scanned + 1))
  # ⛔ A SCANNER THAT CANNOT RUN MUST NOT REPORT PASS. This is the no-op-gate shape the check
  # itself exists to catch (#2096): an awk that rejects its own program exits non-zero, and if
  # that status were swallowed every file would read as "no findings" while this gate certified
  # the absence it cannot see. The status is therefore read, and the reason is kept.
  # The scanner writes `note:` lines on stderr for a file whose brace count did not return to zero
  # (a PARTIAL scan — see the header). Those must reach the reader, so stderr is kept and shown in the
  # summary rather than discarded into a log that is only read when a scan FAILS.
  scan_file "$f" >> "$FINDINGS" 2>> "$TMPDIR_RUN/scan-notes" || {
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
  base_for_join || exit 1
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
    # ⛔ AND THE NON-BASELINEABLE RULES ARE NEVER WRITTEN (#2121 review round 5, P2). The sanctioned
    # remedy for a red run is `--update-baseline`, so a generator that writes EVERY rule turns one
    # truncated file (`unterminated-heredoc`) into a permanently blind file under a green check. They
    # stay findings; the one home for the list is $NON_BASELINEABLE, passed through here.
    awk -F'\t' -v nonbase="${NON_BASELINEABLE[*]}" '
      BEGIN { nbn = split(nonbase, nbt, " "); for (nbi = 1; nbi <= nbn; nbi++) nonb[nbt[nbi]] = 1 }
      NR == FNR { if ($0 ~ /^#/ || NF < 3) next; note[$1 SUBSEP $2] = ($4 == "" ? "" : $4); next }
      { if ($3 in nonb) next; c[$1 SUBSEP $3]++ }
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
# grandfathered, so every finding fails, which is the safe direction. An UNREADABLE one is a
# different fact and is refused (see base_for_join): "I could not read which findings you exempt"
# is not "you exempt none".
base_for_join || exit 1
awk -F'\t' -v nonbase="${NON_BASELINEABLE[*]}" '
  BEGIN { nbn = split(nonbase, nbt, " "); for (nbi = 1; nbi <= nbn; nbi++) nonb[nbt[nbi]] = 1 }
  NR == FNR {
    if ($0 ~ /^#/ || NF < 3) next
    if ($3 !~ /^[0-9]+$/) { print "MALFORMED\t" $1 "\t" $2 "\t" $3; next }
    # ⛔ A PARTIAL SCAN AND AN UNREADABLE EXEMPTION CANNOT BE GRANDFATHERED (#2121 review round 5,
    # P2). `unterminated-heredoc` says the tail of this file was NEVER SCANNED — the absence it
    # would certify is an absence nobody observed, so a baseline row over it defeats the invariant
    # this whole file exists to enforce. Such an entry is a FINDING in its own right, reported as
    # UNGRANDFATHERABLE and never counted as a pass.
    if ($2 in nonb) { print "UNGRANDFATHERABLE\t" $1 "\t" $2 "\t" $4; next }
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
      # ⛔ AN OVER-RECORDED COUNT ABSORBS A NEW INSTANCE (#2121 review, P3). `seen < base` used to be a
      # STALE note and nothing else, so a baseline that recorded 5 for a file where ONE instance remained
      # reported the first new instance as `baselined` and exited 0 — the count netting swallowed exactly
      # the regression the baseline exists to catch. A count that does not match reality is a claim nobody
      # can verify, so it FAILS. `seen == 0` stays a note: the finding was fixed, and failing on "you
      # fixed it" is perverse.
      if (seen[k] + 0 == 0)
        printf "STALE\t%s\t%s\t%d\t%d\n", a[1], a[2], base[k], seen[k] + 0
      else if (seen[k] + 0 < base[k])
        printf "OVERRECORDED\t%s\t%s\t%d\t%d\n", a[1], a[2], base[k], seen[k] + 0
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

findings=0; baselined=0; stale=0; unjustified=0; malformed=0; ungrandfathered=0; overrecorded=0
while IFS=$'\t' read -r kind a b c d; do
  case "$kind" in
    BASELINED) baselined=$((baselined + 1)); echo "baselined: $a:$b: $c: $d" ;;
    FINDING)   findings=$((findings + 1));   echo "$a:$b: $c: $d" ;;
    STALE)     stale=$((stale + 1));         echo "note: baseline entry is STALE: $a ($b) expected $c, found $d — the finding was fixed or the code moved; re-record with --update-baseline" ;;
    OVERRECORDED) overrecorded=$((overrecorded + 1)); echo "FAIL: baseline entry OVER-RECORDS: $a ($b) declares $c but $d remain — an over-recorded count reports a NEW instance as baselined and passes; re-record with --update-baseline" ;;
    UNJUSTIFIED) unjustified=$((unjustified + 1)); echo "FAIL: baseline entry without a justification: $a ($b) — name the tracking issue in the 4th column" ;;
    MALFORMED) malformed=$((malformed + 1)); echo "FAIL: malformed baseline entry: $a ($b) has count '$c' — regenerate with --update-baseline" ;;
    UNGRANDFATHERABLE) ungrandfathered=$((ungrandfathered + 1)); echo "FAIL: baseline entry names a rule that can NEVER be grandfathered: $a ($b)${c:+ — recorded reason: $c} — a partial scan is UNKNOWN, not clean, so the row is a finding and never a pass; remove it (--update-baseline never writes one)" ;;
  esac
done < "$DECIDED"

# PARTIAL-SCAN NOTES reach the reader here, before the summary: a stderr note that nothing prints is
# the same silence it was written to break.
# ⛔ THE COUNT BELONGS IN THE VERDICT LINE, NOT ONLY ON STDERR (review round 7, P2). A partial scan
# printed a stdout summary byte-identical to a fully scanned tree, and the stderr list was truncated at
# 20 with no marker — so 25 partial files read as "25 scanned, 0 findings, PASS". The count is part of
# the machine-read summary, and truncation says how many were withheld.
# ⛔ A PARTIAL SCAN IS NOT A PASS (#2121 review, P1). Drift in the brace count puts the tail of a file
# in a phantom scope — and per the P0 above, that was measured silently suppressing `empty-as-pass` for
# the rest of the file while this run printed PASS with a stderr note nobody gates on. 12 of 167 files
# drifted at this commit. So a partial scan FAILS with the file list, and a green run means every target
# was scanned END TO END.
partials=0
if [ -s "$TMPDIR_RUN/scan-notes" ]; then
  # The count is read ONCE, by one reader, with its status checked: `sort -u … | grep -c . || true` reports
  # `0 partial scan(s)` when the pipeline itself fails — the count-reads-zero shape, inside the counter.
  if ! partials="$(sort -u "$TMPDIR_RUN/scan-notes" | awk 'NF { n++ } END { print n + 0 }')"; then
    echo "FAIL: the partial-scan notes could not be READ — an unreadable count of unscanned regions is not zero of them" >&2
    exit 1
  fi
  sort -u "$TMPDIR_RUN/scan-notes" | head -20 | sed 's/^/partial: /' >&2
  if [ "${partials:-0}" -gt 20 ]; then
    echo "partial: … and $((partials - 20)) more partial scan(s) withheld from this list (all counted in the summary)" >&2
  fi
fi
echo "── false-PASS shapes: $scanned file(s) scanned · $findings finding(s) · $baselined baselined · $stale stale baseline entr(y|ies) · $overrecorded over-recorded baseline entr(y|ies) · $unjustified unjustified · $malformed malformed · $ungrandfathered un-grandfather-able · $partials partial scan(s) ──"
if [ "$partials" -gt 0 ]; then
  # ⛔ THE FILE LIST IS THE FINDING (#2121 review, P1): a count without the files leaves the reader to
  # re-run the check to learn which scan did not finish.
  echo "FAIL: $partials of $scanned file(s) were only PARTIALLY scanned (see the 'partial:' list above) — the tail of each is attributed to a block that never closed, so this run cannot certify that those files are free of the shapes (#2096)."
  exit 1
fi
if [ "$findings" -gt 0 ] || [ "$unjustified" -gt 0 ] || [ "$malformed" -gt 0 ] || [ "$ungrandfathered" -gt 0 ] || [ "$overrecorded" -gt 0 ]; then
  echo "FAIL: no verdict without an observation (#2096). Fix the shape, or exempt one line with '# verified: <why it is not the shape>'."
  exit 1
fi
echo "PASS: no finding in the SCANNED SET ($scanned file(s); see --list-targets) — the three shapes are absent there, or baselined against an open tracking issue."
exit 0
