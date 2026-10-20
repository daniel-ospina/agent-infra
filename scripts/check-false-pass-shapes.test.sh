#!/bin/bash
# scripts/check-false-pass-shapes.test.sh — the suite for agent-infra#2121
#
# WHAT THIS PINS, and why each case exists
# ----------------------------------------
#   A. DETECTION — each of the three shapes is found in a fixture, one at a time. A guard that
#      reports nothing on a tree containing the shape certifies the absence it cannot see.
#   B. NEAR-MISSES — the shapes' neighbours must NOT be flagged: this suite fails as loudly on a
#      FALSE POSITIVE as on a false negative, because a linter that reds correct code is deleted
#      from CI within a week (and taking the class with it).
#   C. THE MARKER — `# verified: <reason>` exempts the construct it sits on; a marker with NO
#      reason does not exempt and is itself a finding.
#   D. THE BASELINE — a grandfathered (file, rule) group passes; a SECOND instance of the same
#      rule in the same file exceeds the count and FAILS (the regression the baseline must not
#      swallow); a stale entry is reported but does not fail; an entry with no justification fails.
#   E. NON-VACUITY — the scan actually ran: the file count is reported and > 0, and a tree the
#      scanner cannot read is an ERROR, not a PASS.
#   F. THE REAL TREE — the repo's own scan set is clean under the shipped baseline. This is the
#      case CI enforces, and it is deliberately the last one: everything above proves the guard
#      can detect, this proves today's tree has nothing it should detect.
#
# Hermetic: every fixture is built in a temp dir; the repo is only READ.
#
# Usage: bash scripts/check-false-pass-shapes.test.sh
# Exit:  0 = all assertions passed, 1 = at least one failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-false-pass-shapes.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/false-pass-shapes-test.XXXXXX")"
FAILURES=0
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ck() { if [ "$1" -eq 0 ]; then echo "  ok: $2"; else fail "$2"; fi; }
hdr() { echo "== $*"; }

[ -x "$CHECK" ] || { echo "FAIL: $CHECK is not executable (CI runs it directly in the shard list)" >&2; exit 1; }

# fixture <name> — a tree with a `scripts/` dir, which is what the scan set covers.
fixture() {
  local d="$TMP/$1"
  mkdir -p "$d/scripts"
  printf '%s' "$d"
}
# run_check <root> [extra args] — prints the check's output, returns ITS exit status.
run_check() {
  local root="$1"; shift
  bash "$CHECK" --root "$root" "$@" 2>&1
}

# ── A. detection ────────────────────────────────────────────────────────────
hdr "A. each shape is DETECTED (one at a time)"

D="$(fixture a1)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
local_var() {
  local out=$(broken_parser)
  echo "$out"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'discarded-status' <<<"$out"
ck $? "A1 discarded-status: 'local x=\$(cmd)' is flagged"

D="$(fixture a2)"
cat > "$D/scripts/two.sh" <<'EOS'
#!/bin/bash
verify_thing() {
  local bad=0 arg
  while IFS= read -r arg; do
    [ -e "$arg" ] || bad=1
  done < <(list_targets "$1")
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "A2 empty-as-pass: a zero-iteration loop still returns the success-default flag (the #1743 shape)"

D="$(fixture a3)"
cat > "$D/scripts/three.sh" <<'EOS'
#!/bin/bash
echo "✅ installed — $(( $(ls -1 "$SRC" | wc -l) )) entries"
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'pre-existing-as-evidence' <<<"$out"
ck $? "A3 pre-existing-as-evidence: a pre-run listing count printed as the verdict's evidence"

# ⛔ F1 (review round 1): a COMMENT that merely mentions a heredoc opener must not blind the file.
# The measured instance was scripts/check-no-sigpipe-grep.sh:81, whose comment quoted an opener and
# silently skipped 1,900+ lines while the run still printed PASS — the no-op gate, inside the gate.
D="$(fixture a4)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
# a comment mentioning an opener opens nothing: cat <<'INNER' ... INNER
render() {
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'discarded-status' <<<"$out"
ck $? "A4 a COMMENT mentioning a heredoc opener does not blind the rest of the file"

# ⛔ ROUND 2: an UNTERMINATED quoted heredoc skips the rest of the file. Silence there is the
# no-op gate this check exists to catch, so it is a LOUD finding — "unknown" is not "clean".
D="$(fixture a5)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
cat <<'INNER' > /tmp/x
body line
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'unterminated-heredoc' <<<"$out"
ck $? "A5 an unterminated quoted heredoc is a LOUD finding, never a silent partial scan"

# ── B. near-misses must NOT be flagged ──────────────────────────────────────
hdr "B. near-misses are NOT flagged (a false positive is a defect too)"

D="$(fixture b1)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
# a plain assignment is NOT the declaration-builtin shape: the status is discardable either
# way, but only the builtin form masks it SILENTLY, and flagging every assignment would flag
# half the repo.
v=$(some_command)
echo "$v"
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'discarded-status' <<<"$out"
ck $? "B1 a plain 'v=\$(cmd)' assignment is not flagged"

D="$(fixture b2)"
cat > "$D/scripts/two.sh" <<'EOS'
#!/bin/bash
count_things() {
  local n=0 arg
  while IFS= read -r arg; do
    n=$((n + 1))
  done < <(list_targets)
  [ "$n" -gt 0 ] || return 1
  return 0
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B2 a counted loop with a non-empty guard is not empty-as-pass"

D="$(fixture b3)"
cat > "$D/scripts/three.sh" <<'EOS'
#!/bin/bash
verify_thing() {
  local bad=0 arg out
  out="$(list_targets)"
  [ -z "$out" ] && return 1
  while IFS= read -r arg; do
    [ -e "$arg" ] || bad=1
  done <<< "$out"
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B3 a loop whose feeder output is guarded for emptiness is not empty-as-pass"

D="$(fixture b4)"
cat > "$D/scripts/four.sh" <<'EOS'
#!/bin/bash
echo "✅ installed — $(find "$DST" -newer "$MARK" | wc -l) file(s) copied by THIS run"
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'pre-existing-as-evidence' <<<"$out"
ck $? "B4 a RECENCY-FILTERED count (what this run wrote) is not pre-existing-as-evidence"

D="$(fixture b5)"
cat > "$D/scripts/five.sh" <<'EOS'
#!/bin/bash
echo "✅ manifest parity holds"
echo "   scanned $(( $(ls -1 "$SRC" | wc -l) )) entries for information only"
EOS
# The count line has no verdict word on it, so it is not evidence for a verdict.
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'pre-existing-as-evidence' <<<"$out"
ck $? "B5 a bare count on a non-verdict line is not flagged"

# ⛔ F2 (review round 1): ARITHMETIC is not a command substitution. `local n=$(( a * 100 / b ))`
# has no command whose status could be lost; flagging it reds correct code, which is the one thing
# this guard must never do.
D="$(fixture b6)"
cat > "$D/scripts/six.sh" <<'EOS'
#!/bin/bash
pct() {
  local n=$(( $1 * 100 / $2 ))
  local r=$(( TARGET - 1 ))
  echo "$n $r"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'discarded-status' <<<"$out"
ck $? "B6 arithmetic expansion '\$((...))' is NOT discarded-status"

# ⛔ F3 (review round 1): the shape is a flag INITIALISED TO SUCCESS. A fail-closed function
# (default FAIL, cleared to success) is the opposite contract and must not be reported.
D="$(fixture b7)"
cat > "$D/scripts/seven.sh" <<'EOS'
#!/bin/bash
verify_all() {
  local ok=1 arg
  while IFS= read -r arg; do
    [ -e "$arg" ] || continue
    ok=0
  done < <(list_targets)
  return "$ok"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B7 a FAIL-CLOSED flag (default 1, cleared on success) is not empty-as-pass"

# ⛔ ROUND 2: `ls` and `find` are SUBSTRINGS of `labels`, `signals` and `findings` — this fleet's
# most common nouns. An unanchored match reds correct code, so the listing command must sit at a
# COMMAND position.
D="$(fixture b8)"
cat > "$D/scripts/eight.sh" <<'EOS'
#!/bin/bash
echo "✅ $(printf '%s\n' "$labels" | wc -l) labels"
echo "✅ $(cat findings.tsv | wc -l) recorded findings"
echo "✅ $(printf '%s' "$signals" | wc -l) signals"
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'pre-existing-as-evidence' <<<"$out"
ck $? "B8 the nouns labels/signals/findings are not listing commands"

# ⛔ ROUND 2: observing the feeder status on the assignment line IS the fix the rule asks for.
D="$(fixture b9)"
cat > "$D/scripts/nine.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg out
  out="$(list_targets)" || return 1
  while IFS= read -r arg; do
    [ -e "$arg" ] || bad=1
  done <<< "$out"
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B9 'out=\$(cmd) || return 1' is a guard, not the shape"

# ⛔ ROUND 2: a COMMENT mentioning a counter must not silently disable the rule (that would be a
# false NEGATIVE created by prose), nor may a comment quoting a loop be reported (a false POSITIVE).
D="$(fixture b10)"
cat > "$D/scripts/ten.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg
  # NOTE: elsewhere the code counts with wc -l, and a loop ends with done <<< "$list"
  while IFS= read -r arg; do
    [ -e "$arg" ] || bad=1
  done < <(list_targets)
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && [ "$(grep -c 'empty-as-pass' <<<"$out")" = "1" ]
ck $? "B10 a comment mentioning a counter neither disables the rule nor is itself reported"

# ── C. the opt-out marker ───────────────────────────────────────────────────
hdr "C. the '# verified:' marker"

D="$(fixture c1)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
render() {
  local cfg=$(read_config)   # verified: read_config is a builtin wrapper whose status cannot fail (see its own test)
  echo "$cfg"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'discarded-status' <<<"$out"
ck $? "C1 a marker WITH a reason exempts the construct on its line"

D="$(fixture c2)"
cat > "$D/scripts/two.sh" <<'EOS'
#!/bin/bash
render() {
  # verified: the parser cannot fail here
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ]
ck $? "C2 a marker on the line ABOVE exempts the construct below it"

D="$(fixture c3)"
cat > "$D/scripts/three.sh" <<'EOS'
#!/bin/bash
render() {
  local cfg=$(read_config)   # verified:
  echo "$cfg"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'marker-without-justification' <<<"$out" && grep -q 'discarded-status' <<<"$out"
ck $? "C3 a marker with NO reason exempts nothing AND is itself a finding"

# ── D. the baseline ─────────────────────────────────────────────────────────
hdr "D. the baseline is a set of claims, keyed by (file, rule, count)"

D="$(fixture d1)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
render() {
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
printf '# baseline\nscripts/one.sh\tdiscarded-status\t1\t#1743 — grandfathered for this fixture\n' > "$D/base.tsv"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'baselined:' <<<"$out"
ck $? "D1 a grandfathered group PASSES and is announced on every run"

# The regression the baseline must not swallow: a SECOND instance in the same file.
cat >> "$D/scripts/one.sh" <<'EOS'
render2() {
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'scripts/one.sh:.*discarded-status' <<<"$out"
ck $? "D2 a SECOND instance of the same rule in a baselined file FAILS (count exceeded)"

D="$(fixture d3)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
echo ok
EOS
printf '# baseline\nscripts/one.sh\tdiscarded-status\t1\t#1743 — points at a finding that is gone\n' > "$D/base.tsv"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'STALE' <<<"$out"
ck $? "D3 a STALE baseline entry is reported loudly but does not fail (failing on 'you fixed it' is perverse)"

D="$(fixture d4)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
echo ok
EOS
printf 'scripts/one.sh\tdiscarded-status\t1\t\n' > "$D/base.tsv"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'without a justification' <<<"$out"
ck $? "D4 a baseline entry with NO justification is a finding (an unreadable claim is not a claim)"

D="$(fixture d5)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
render() {
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
printf 'scripts/one.sh\tdiscarded-status\tnotanumber\tnope\n' > "$D/base.tsv"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'malformed baseline entry' <<<"$out"
ck $? "D5 a malformed baseline entry FAILS (it must be generated, not hand-mangled)"

# ── E. non-vacuity ──────────────────────────────────────────────────────────
hdr "E. the scan actually ran (a guard that cannot scan must not PASS)"

D="$(fixture e1)"
printf '#!/bin/bash\necho clean\n' > "$D/scripts/one.sh"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && grep -qE '1 file\(s\) scanned' <<<"$out"
ck $? "E1 the summary reports the number of files actually scanned"

D="$(fixture e2)"
out="$(bash "$CHECK" --root "$TMP/does-not-exist" 2>&1)"; rc=$?
[ "$rc" -eq 2 ]
ck $? "E2 a nonexistent --root is a usage error, never a clean PASS"

out="$(bash "$CHECK" --list-rules 2>&1)"
# THREE SHAPES plus two kinds that FAIL the run and must therefore be enumerable and baselinable:
# `marker-without-justification` (an unreadable exemption) and `unterminated-heredoc` (a partial
# scan). A consumer that classifies findings by rule id cannot represent a kind this list omits.
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "5" ] && grep -q '^discarded-status$' <<<"$out" \
  && grep -q '^empty-as-pass$' <<<"$out" && grep -q '^pre-existing-as-evidence$' <<<"$out" \
  && grep -q '^marker-without-justification$' <<<"$out" && grep -q '^unterminated-heredoc$' <<<"$out"
ck $? "E3 --list-rules publishes every rule id the scanner can emit (the doc reads THIS)"

# ⛔ F8 (review round 1): a hardcoded help window printed the IMPLEMENTATION as help. The header is
# now found by content, so this pins that `--help` prints the contract and none of the code.
out="$(bash "$CHECK" --help 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'CONTRACT' <<<"$out" && ! grep -q 'set -uo pipefail' <<<"$out"
ck $? "E4 --help prints the header block (not the code) and exits 2 as a usage error"

# ⛔ ROUND 3: `--update-baseline` had NO coverage, and its failure modes are all silent ones: a
# regressed empty body `mv`d over the baseline retires every group; a new group written with a
# placeholder sentence would satisfy the justification check; a kept group must keep its reason.
D="$(fixture d6)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
render() {
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
printf 'scripts/one.sh\tdiscarded-status\t1\t#1743 — the reason that must SURVIVE a rewrite\n' > "$D/base.tsv"
out="$(bash "$CHECK" --root "$D" --baseline "$D/base.tsv" --update-baseline 2>&1)"; rc=$?
row="$(awk -F'\t' '$0 !~ /^#/ && NF == 4 && $3 == 1' "$D/base.tsv")"
# ⛔ NO `… | grep -q` HERE, and the remedy has TWO spellings — pick by producer (#841/#864): a
# quiet grep exits at its FIRST match, the still-writing producer takes SIGPIPE, and `pipefail`
# promotes that to the pipeline's status, so a match that IS present can read as absent. A builtin
# producer (`printf`/`echo`) inverts to a here-string; ANY other producer CAPTURES first and tests
# in the shell — which is why the awk above is captured into `row` and tested with `[ -n "$row" ]`,
# while the grep below reads a FILE. CI caught this line with the pipeline spelling.
[ "$rc" -eq 0 ] && grep -q 'the reason that must SURVIVE a rewrite' "$D/base.tsv" && [ -n "$row" ]
ck $? "D6 --update-baseline keeps an existing group's justification and its count"

# A NEW group must be written with an EMPTY 4th column, so the NEXT run reports it as a finding
# rather than mistaking a placeholder sentence for a human's justification.
D="$(fixture d7)"
cat > "$D/scripts/two.sh" <<'EOS'
#!/bin/bash
render() {
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
: > "$D/base.tsv"
out="$(bash "$CHECK" --root "$D" --baseline "$D/base.tsv" --update-baseline 2>&1)"; rc=$?
write_ok=1
[ "$rc" -eq 0 ] || write_ok=1
[ "$rc" -eq 0 ] && [ "$(awk -F'\t' '$0 !~ /^#/ {print NF}' "$D/base.tsv" | head -1)" = "4" ] \
  && [ -z "$(awk -F'\t' '$0 !~ /^#/ {print $4}' "$D/base.tsv" | head -1)" ] && write_ok=0
ck $write_ok "D7 a NEW group is written with an EMPTY justification (so the next run flags it)"

out="$(bash "$CHECK" --root "$D" --baseline "$D/base.tsv" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'without a justification' <<<"$out"
ck $? "D8 the freshly-written group FAILS until a human names its tracking issue"

# A CLEAN tree is a legal state for --update-baseline (zero findings = empty baseline), not a
# generator failure — the state a lane reaches after fixing the last baselined instance.
D="$(fixture d9)"
printf '#!/bin/bash\necho clean\n' > "$D/scripts/one.sh"
: > "$D/base.tsv"
out="$(bash "$CHECK" --root "$D" --baseline "$D/base.tsv" --update-baseline 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$(awk '$0 !~ /^#/' "$D/base.tsv")" ]
ck $? "D9 --update-baseline on a CLEAN tree writes an empty baseline and succeeds"

# ── G. the two shapes the first review found unreadable ──────────────────────
# Both are pinned here because each was a FALSE PASS (the gate said clean while the shape was
# present) — the one failure class this check exists to prevent, and the one no test could see.
hdr "G. the widened declaration rule and the counter proof (review round 1 findings)"

D="$(fixture g1)"
cat > "$D/scripts/g1.sh" <<'EOS'
#!/bin/bash
load_cfg() {
  local -r cfg=$(read_config)
  echo "$cfg"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'discarded-status' <<<"$out"
ck $? "G1 a DECLARATION FLAG between the builtin and the name (local -r cfg=$(cmd)) is still the shape"

D="$(fixture g2)"
cat > "$D/scripts/g2.sh" <<'EOS'
#!/bin/bash
load_map() {
  declare -A m=([k]=$(read_config))
  echo "${m[k]}"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'discarded-status' <<<"$out"
ck $? "G2 an ASSOCIATIVE assignment (declare -A m=([k]=$(cmd))) is still the shape"

D="$(fixture g3)"
cat > "$D/scripts/g3.sh" <<'EOS'
#!/bin/bash
hazard() {
  local input="$1" intended="$(lower "$2")" want="$3" got
  got="$(scan "$input")"
  [ "$got" = "$want" ]
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'discarded-status' <<<"$out"
ck $? "G3 the substitution in a LATER word of the declaration is the shape"

# The SPLIT declaration is the documented CORRECT fix; flagging it would make the rule
# unfixable and the fleet would disable the gate (the reason this arm exists).
D="$(fixture g4)"
cat > "$D/scripts/g4.sh" <<'EOS'
#!/bin/bash
load_cfg() {
  local c; c="$(read_config)"
  echo "$c"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'discarded-status' <<<"$out"
ck $? "G4 the SPLIT declaration (local c; c=$(cmd)) is NOT flagged"

# ⛔ A FUNCTION-FUNCTION-WIDE `|| return` OR AN UNRELATED `$((` IS NOT EVIDENCE the loop iterated.
D="$(fixture g5)"
cat > "$D/scripts/g5.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg
  [ -d "$1" ] || return 1
  local pct=$(( 100 * 2 / 7 ))
  while IFS= read -r arg; do
    [ -e "$arg" ] || bad=1
  done < <(list_targets)
  [ "$pct" -ge 0 ] && echo "$pct"
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "G5 an unrelated OR-return plus an unrelated arithmetic assignment does not launder a zero-iteration loop"

D="$(fixture g6)"
cat > "$D/scripts/g6.sh" <<'EOS'
#!/bin/bash
function oneliner() { local x=$(read_config); echo "$x"; }
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'discarded-status' <<<"$out"
ck $? "G6 a ONE-LINE body under the 'function name' spelling is scanned (same treatment as name())"

# Every declared glob must still contribute targets: a renamed/moved subtree silently shrinks the
# scan set, and the only other signal is a count nobody compares.
targets="$(bash "$CHECK" --list-targets 2>/dev/null)"
n="$(printf '%s\n' "$targets" | grep -c .)"
[ "$n" -ge 100 ] && grep -q '^scripts/orchestrator-harness/' <<<"$targets" && grep -q '^scripts/[a-z]' <<<"$targets"
ck $? "G7 both SCAN_GLOBS still contribute targets, and the scan set has not silently shrunk ($n files)"

# ── F. the real tree ────────────────────────────────────────────────────────hdr "F. the repo's own scan set is clean under the shipped baseline (this is what CI enforces)"

out="$(bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" | sed 's/^/    /' >&2
fi
[ "$rc" -eq 0 ]
ck $? "F1 bash scripts/check-false-pass-shapes.sh passes on this tree"

grep -q 'PASS:' <<<"$out"
ck $? "F2 the verdict line is printed (silence is never a pass)"

echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED: $FAILURES assertion(s)"
  exit 1
fi
echo "PASS: all false-PASS-shape assertions passed"
exit 0
