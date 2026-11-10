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
[ "$rc" -eq 1 ] && grep -q 'unterminated-heredoc' <<<"$out" \
  && grep -q 'scripts/one.sh:2: unterminated-heredoc' <<<"$out"
ck $? "A5 an unterminated quoted heredoc is a LOUD finding at the OPENER's line, never a silent partial scan"

# ⛔ THE FEEDER SPELLING THE INDEPENDENT SCAN FOUND ITS INSTANCES IN (#2121). `out="$(cmd)"` then
# `for x in $out` is the same zero-iteration feeder as `for x in $(cmd)`, one assignment earlier, and
# the loop arm only matched the LITERAL substitution form — so this spelling read as CLEAN inside a
# success-default function. An independent implementation of these same three shapes found exactly
# three live instances of it in this repo's shell set; they were fixed, and this fixture is what stops
# the spelling going blind again.
D="$(fixture a6)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
verify_targets() {
  local bad=0 arg targets
  targets="$(list_targets)"
  for arg in $targets; do
    [ -e "$arg" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "A6 empty-as-pass: a loop over a CAPTURED substitution ('for x in \$targets') is the same feeder as 'for x in \$(cmd)'"

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
# ⛔ THE FINDING MUST BE ON THE LOOP'S LINE (line 7), not on the comment above it: a bare count of
# the rule id is satisfied by a finding moved onto the comment line, so it could not see the
# comment-blindness fix regress (#2121 review round 5, observation).
[ "$rc" -eq 1 ] && [ "$(grep -c 'empty-as-pass' <<<"$out")" = "1" ] \
  && grep -q 'scripts/ten.sh:7: empty-as-pass' <<<"$out"
ck $? "B10 a comment mentioning a counter neither disables the rule nor is itself reported (the finding is the LOOP's line)"

# ⛔ ROUND 4, P1 (fail-open): a `}` at ANY indent used to be read as the END of a function, so a
# nested `{ … }` brace group threw away the function's flag/loop state and every line after it was
# scanned as TOP LEVEL while the run printed PASS. Measured: this fixture passed clean and the same
# body WITHOUT the two brace lines was reported — so A2 passed only because its fixture has no
# brace group. 249 line-start closing braces in the scanned set (`admin-merge.sh:1013`, `:4974`),
# and the rule is load-bearing the other way too (`slack()` in heartbeat-loop.sh closes indented).
D="$(fixture b11)"
cat > "$D/scripts/eleven.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg
  if [ -n "${1:-}" ]; then
    {
      printf 'section: %s\n' "$1"
    }
  fi
  while IFS= read -r arg; do
    [ -e "$arg" ] || bad=1
  done < <(list_targets)
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B11 a nested BRACE GROUP inside the function does not end it (the shape is still found)"

# The other direction of the same fix: counting braces must not end the function EARLY either — a
# real counter, written AFTER a brace group, still proves the loop iterated.
D="$(fixture b12)"
cat > "$D/scripts/twelve.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 n=0 arg
  {
    printf 'checking\n'
  }
  while IFS= read -r arg; do
    n=$((n + 1))
    [ -e "$arg" ] || bad=1
  done < <(list_targets)
  [ "$n" -gt 0 ] || return 1
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B12 a counter written AFTER a brace group still guards the loop (the function stays open)"

# ⛔ ROUND 4, P1 (false-block): the emptiness guard and the zero-count test are each ONE spelling
# away from what this repo actually writes. `-z "${` occurs 32x in scripts/*.sh and `[ "$x" = 0 ]`
# 61x, so the narrow arms red CORRECT guards in both lanes — and the header then tells the lane the
# right response is a `# verified:` marker on that rule, which is the exemption that would hide the
# next genuine instance of it. One fixture per spelling.
D="$(fixture b13)"
cat > "$D/scripts/thirteen.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg out
  out="$(list_targets)"
  [ -z "${out}" ] && return 1
  while IFS= read -r arg; do
    [ -e "$arg" ] || bad=1
  done <<< "$out"
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B13 the BRACED quoted emptiness guard ([ -z \"\${out}\" ]) is not the shape"

D="$(fixture b14)"
cat > "$D/scripts/fourteen.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg out
  out="$(list_targets)"
  [[ -z ${out} ]] && return 1
  while IFS= read -r arg; do
    [ -e "$arg" ] || bad=1
  done <<< "$out"
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B14 the UNQUOTED braced guard ([[ -z \${out} ]]) is not the shape"

D="$(fixture b15)"
cat > "$D/scripts/fifteen.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 n=0 arg
  while IFS= read -r arg; do
    n=$((n + 1))
    [ -e "$arg" ] || bad=1
  done < <(list_targets)
  (( n > 0 )) || return 1
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B15 an ARITHMETIC zero-count test ((( n > 0 )) || return 1) is not the shape"

D="$(fixture b16)"
cat > "$D/scripts/sixteen.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 n=0 arg
  while IFS= read -r arg; do
    n=$((n + 1))
    [ -e "$arg" ] || bad=1
  done < <(list_targets)
  [ "$n" = 0 ] && return 1
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B16 a STRING-EQUALITY zero-count test ([ \"\$n\" = 0 ]) is not the shape"

# ⛔ THE CAPTURE-THEN-ITERATE SPELLING HAS ITS OWN NEAR-MISSES (#2121), and they are the three forms
# this repo writes constantly: a GLOB PREFIX, a QUOTED expansion, and a guard on the captured value.
# Widening the loop arm without pinning these would red hundreds of correct lines (measured on the
# real tree: `for f in "$HERE"/*.sh` alone appears in a dozen scripts), which is how a linter gets
# deleted from CI.
D="$(fixture b17)"
cat > "$D/scripts/seventeen.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 here f
  here="$(cd "$(dirname "$0")" && pwd)"
  for f in "$here"/*.sh; do
    [ -e "$f" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B17 a loop over a PATH PREFIX of a captured var ('for f in \"\$here\"/*.sh') is a glob, not the feeder"

D="$(fixture b18)"
cat > "$D/scripts/eighteen.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 line out
  out="$(read_file)"
  for line in "$out"; do
    [ -e "$line" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B18 a QUOTED expansion ('for line in \"\$out\"') does not word-split, so it iterates once — not the shape"

D="$(fixture b19)"
cat > "$D/scripts/nineteen.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg targets
  targets="$(list_targets)"
  [ -n "$targets" ] || return 1
  for arg in $targets; do
    [ -e "$arg" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B19 the emptiness guard on the CAPTURED var ([ -n \"\$targets\" ] || return 1) suppresses the capture-then-iterate form"

D="$(fixture b20)"
cat > "$D/scripts/twenty.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg items
  items="$1"
  for arg in $items; do
    [ -e "$arg" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B20 a loop over a var that was NOT captured from a substitution ('items=\"\$1\"') is not the shape"

# ⛔ A NAME REASSIGNED AWAY FROM A SUBSTITUTION IS NO LONGER A CAPTURE (#2121 review). Registering it
# for the rest of the function reds a loop that deterministically iterates: `list="$(auto_detect)"`
# then `list="alpha beta"` then `for f in $list`. That is the "reds correct code" trade the header
# refuses, and it was latent only because the usual override idiom is guarded.
D="$(fixture b21)"
cat > "$D/scripts/twentyone.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 f
  local list
  list="$(auto_detect)"
  list="alpha beta"
  for f in $list; do
    [ -e "$f" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B21 a capture REASSIGNED to a literal before the loop is not the shape (the loop cannot iterate zero times)"

# ⛔ AND "AWAY FROM THE CAPTURE" IS NOT "ANY REASSIGNMENT" (#2121 review round 2): `out="$out extra"`,
# `out="${out%…}"` and `out+=" …"` still DERIVE from the substitution, so they are still the shape. An
# arm that deregistered on any `name=` re-armed the false negative it exists to prevent.
D="$(fixture b22)"
cat > "$D/scripts/twentytwo.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 x
  local out
  out="$(list_graphs)"
  out="$out extra"
  for x in $out; do
    [ -e "$x" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B22 a reassignment that DERIVES from the capture (\"\$out extra\") is STILL the shape"

# The other side of that narrowing, declared rather than implied: an EXPLICITLY emptied feeder is not the
# shape, because the emptiness is stated in the code rather than unobserved.
D="$(fixture b23)"
cat > "$D/scripts/twentythree.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 x
  local out
  out="$(list_graphs)"
  out=""
  for x in $out; do
    [ -e "$x" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B23 an EXPLICITLY emptied feeder ('out=\"\"') is not the shape (a declared blind spot, not a silent one)"
# ⛔ AND \"MENTIONS THE NAME\" IS NOT \"REFERENCES A CAPTURE\" (#2121 review round 3). A substring test
# read `tmp="$WORK/run.tmp"` and `DIFF_HASH="$LEGACY_DIFF_HASH"` as derived-from-the-capture, so a loop
# over a literal was red on correct code — the trade this check refuses. Both are pinned here, and the
# mirror-image false NEGATIVE (a copy to a second name, which does iterate the capture) with them.
D="$(fixture b24)"
cat > "$D/scripts/twentyfour.sh" <<'EOS'
#!/bin/bash
sweep() {
  local bad=0 x
  local tmp
  tmp="$(mktemp -d)"
  tmp="$WORK/run.tmp"
  for x in $tmp; do
    [ -e "$x" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B24 a literal that merely EMBEDS the name ('\$WORK/run.tmp') is not the shape"

D="$(fixture b25)"
cat > "$D/scripts/twentyfive.sh" <<'EOS'
#!/bin/bash
differs() {
  local bad=0 x
  local DIFF_HASH
  DIFF_HASH="$(git hash-object -t blob /dev/null)"
  DIFF_HASH="$LEGACY_DIFF_HASH"
  for x in $DIFF_HASH; do
    [ -e "$x" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B25 a different variable whose NAME CONTAINS ours is not a reference to the capture"

D="$(fixture b26)"
cat > "$D/scripts/twentysix.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 x
  local out items
  out="$(list_graphs)"
  items="$out"
  for x in $items; do
    [ -e "$x" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B26 a copy of the capture into a second name is STILL the shape (capture-ness is followed)"

D="$(fixture b27)"
cat > "$D/scripts/twentyseven.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 x o
  local out
  out="$(list_graphs)"
  o="$out"
  out="$o"
  for x in $out; do
    [ -e "$x" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B27 a captured value round-tripped through another name is STILL the shape"
# ⛔ THE SAME SUBSTRING BUG IN THE ARM THAT SUPPRESSES (review round 3). A counter is accepted as proof
# the loop ran, so mis-reading an ordinary computation as a counter turns a REAL shape GREEN — the
# check laundering exactly what it exists to catch, which is worse than the false positive above. The
# arithmetic reads `count`, not `n`, so `n` is not an increment; before this fixture the check printed
# `PASS: no finding` on this function (measured against the pre-fix copy) and now reports it.
D="$(fixture b28)"
cat > "$D/scripts/twentyeight.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 x n count=2
  local out
  out="$(list_graphs)"
  n=$(( 3 * count ))
  for x in $out; do
    [ -e "$x" ] || bad=1
  done
  [ "$n" -gt 0 ] || return 1
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B28 arithmetic whose RHS names a DIFFERENT variable does not count as a counter (it cannot suppress the finding)"
# ⛔ ROUND-4 FINDINGS, each one a PASS over a real shape or a red on correct code (review round 4).
# (1) An INDENTED local helper used to flush the enclosing function state, so the shape was lost either
# BEFORE the helper (verdict discarded) or AFTER it (capture discarded).
D="$(fixture b29)"
cat > "$D/scripts/twentynine.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  note() { printf '%s\n' "$*"; }
  out="$(cmd)"
  for x in $out; do note "$x"; check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B29 a local helper defined BEFORE the shape does not hide it (nested headers do not reset the function)"

D="$(fixture b30)"
cat > "$D/scripts/thirty.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  for x in $out; do check "$x" || bad=1; done
  note() { printf '%s\n' "$*"; }
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B30 a local helper defined AFTER the shape does not discard its verdict"

# (2) A `# verified:` marker on a BENIGN loop used to exempt the whole function, disarming the finding
# for a different, unguarded loop later in it — and a marker on the real loop did nothing when an
# earlier loop existed.
D="$(fixture b31)"
cat > "$D/scripts/thirtyone.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  ls_out="$(ls)"
  # verified: printing a directory listing is a display, not a verdict
  for f in $ls_out; do printf '%s\n' "$f"; done
  names="$(get_names)"
  for n in $names; do check "$n" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B31 a marker on one loop does not exempt a DIFFERENT unguarded loop in the same function"

D="$(fixture b32)"
cat > "$D/scripts/thirtytwo.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  # verified: the caller checks the exit status of cmd itself
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B32 a marker on the ONLY loop still exempts it (the documented remedy keeps working)"

# (3) A capture written after another statement was never registered — including `local r; r="$(cmd)"`,
# the spelling MEMORY.md recommends for the declaration-builtin hazard.
D="$(fixture b33)"
cat > "$D/scripts/thirtythree.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0 r
  local out; out="$(cmd)"
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B33 a capture in a LATER statement ('local out; out=\"\$(cmd)\"') is still a capture"

# (4) The array feeder: `arr=($(cmd))` + `for x in "${arr[@]}"` iterates ZERO times on an empty array —
# the one case where quoting does not protect the loop.
D="$(fixture b34)"
cat > "$D/scripts/thirtyfour.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  local -a arr=($(cmd))
  for x in "${arr[@]}"; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B34 an ARRAY capture iterated as \"\${arr[@]}\" is the shape (empty array iterates zero times)"

# (5) Neither direction of the quote-blind / stale-writer bug may come back: a single-quoted literal
# that MENTIONS a captured name is not a reference to it, and a `read` that overwrites the capture ends
# it.
D="$(fixture b35)"
cat > "$D/scripts/thirtyfive.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  tpl='echo $out'
  for t in $tpl; do check "$t" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B35 a single-quoted literal that mentions the name is not a reference to the capture"

D="$(fixture b36)"
cat > "$D/scripts/thirtysix.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  read -r out <<< "alpha beta"
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B36 a 'read' that overwrites the capture with a stated literal is not the shape"
# ⛔ ROUND-5: five regressions the per-statement split and the writer arms introduced. Each one was
# measured PASS over a real shape (or a red on correct code) before this block existed.
D="$(fixture b37)"
cat > "$D/scripts/thirtyseven.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  printf 'usage: -o; out=FILE\n'
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B37 a SEMICOLON INSIDE A QUOTED STRING is not a statement boundary (it used to deregister the capture)"

D="$(fixture b38)"
cat > "$D/scripts/thirtyeight.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  for x in $out; do check "$x" || bad=1; done
  unset out
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B38 an 'unset' AFTER the loop does not erase the loop that precedes it"

D="$(fixture b39)"
cat > "$D/scripts/thirtynine.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  X="$(cmd)"
  ( unset X; run )
  for x in $X; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B39 a SUBSHELL 'unset' cannot clear the capture it does not own"

D="$(fixture b40)"
cat > "$D/scripts/forty.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  # callers may unset out afterwards
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B40 a TRAILING COMMENT mentioning 'unset out' is prose, not a write"

D="$(fixture b41)"
cat > "$D/scripts/fortyone.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0 n
  n=$(( $(wc -l < /tmp/f) + 1 ))
  for x in $n; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B41 an ARITHMETIC assignment ('\$(( \$(cmd) + 1 ))') is not a feeder (a number cannot iterate zero times)"

D="$(fixture b42)"
cat > "$D/scripts/fortytwo.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
note() { printf '%s\n' "$*"; }
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B42 a helper at COLUMN 0 inside a function is nested too (both header spellings behave alike)"

D="$(fixture b43)"
cat > "$D/scripts/fortythree.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  for x in $out; do printf '%s\n' "$x"; done
  log() {
    local rc=0
    check_something || rc=1
    return "$rc"
  }
  return 0
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B43 a helper's own 'return \"\$rc\"' is not the enclosing function's verdict"
# ⛔ ROUND-6 findings. B44 is the P1 the round-5 fix left open: with the helper `{` on the NEXT line
# (ordinary bash style) the nested region was never registered, so the helper body was scanned as the
# outer function and its `return "$rc"` became the outer verdict — a red on code whose verdict is a
# literal `return 0`. B45 is the mirror: prose or a quoted string that contains a statement separator
# must not manufacture (or erase) a capture.
D="$(fixture b44)"
cat > "$D/scripts/fortyfour.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  for x in $out; do printf '%s\n' "$x"; done
  log()
  {
    local rc=0
    check_something || rc=1
    return "$rc"
  }
  return 0
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B44 a helper whose brace is on the NEXT line is still a nested region"

D="$(fixture b45)"
cat > "$D/scripts/fortyfive.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$1"
  note "x" # historically; out="$(cmd)" was set here
  for y in $out; do :; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B45 a semicolon inside a COMMENT does not manufacture a capture"

D="$(fixture b46)"
cat > "$D/scripts/fortysix.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  echo "path\\"; out="$(cmd)"
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B46 an EVEN run of backslashes before a closing quote does not swallow the rest of the line"

D="$(fixture b47)"
cat > "$D/scripts/fortyseven.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  local -a arr=( $(git ls-files) )
  for x in "${arr[@]}"; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B47 the SPACE-PADDED array capture 'arr=( \$(cmd) )' registers (the header claims it does)"
# ⛔ ROUND-7: the nested-region push was decided on RAW text (`index($0, "{")`) while the depth was
# decided by brace_delta(), so a brace that only appears in a trailing comment or a `${…}` pushed a
# region and popped it on the same line — the helper body was then scanned as the OUTER function. Both
# directions were measured: a false positive on a function whose verdict is a literal `return 0`, and a
# false NEGATIVE over a real shape when the helper sits after the verdict.
D="$(fixture b48)"
cat > "$D/scripts/fortyeight.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  for x in $out; do printf '%s\n' "$x"; done
  log()  # writes into ${LOG_FILE}
  {
    local rc=0
    check_something || rc=1
    return "$rc"
  }
  return 0
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B48 a helper header with a COMMENT brace is still a nested region (no false 'success-default' verdict)"

D="$(fixture b49)"
cat > "$D/scripts/fortynine.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  for x in $out; do printf '%s\n' "$x"; done
  log()

  {
    local rc=0
    check_something || rc=1
    return "$rc"
  }
  return 0
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "B49 a BLANK LINE between a helper header and its brace does not cancel the nested region"

D="$(fixture b50)"
cat > "$D/scripts/fifty.sh" <<'EOS'
#!/bin/bash
f() {
  local bad=0
  out="$(cmd)"
  for x in $out; do printf '%s\n' "$x"; done
  return "$bad"
  log()
  {
    local ok=1
    return "$ok"
  }
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B50 a helper AFTER the verdict cannot launder it (the shape is still reported)"
# ⛔ ROUND-8, P0: `function name() {` headers were measured AFTER the header branch had already
# stripped the opening brace off the line, so the consumed brace was subtracted twice — `delta = -1`
# ended the function ON ITS HEADER LINE and every line of its body was scanned at top level, where
# neither flaginit[] nor fn_loop can be recorded. `empty-as-pass` was unreportable for the whole
# function. Every `function` fixture in this suite was a ONE-LINER, which this bug does not affect.
D="$(fixture b51)"
cat > "$D/scripts/fiftyone.sh" <<'EOS'
#!/bin/bash
function collect() {
  local bad=0
  out="$(cmd)"
  for x in $out; do echo "$x"; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B51 a MULTI-LINE body of a 'function name() {' header is analysed (the header line does not end it)"
# ⛔ ROUND-9, P1: the TOP-LEVEL header branches still decided `opened` from RAW text, so a header whose
# only raw brace sat in a trailing comment (`collect() # builds a { map`) consumed a brace the walk had
# not counted, the depth arithmetic went negative, and the function ENDED on its header line — silently,
# since depth returned to zero and therefore no `partial:` note is printed either.
D="$(fixture b52)"
cat > "$D/scripts/fiftytwo.sh" <<'EOS'
#!/bin/bash
collect() # builds a { map
{
  local bad=0
  out="$(cmd)"
  for x in $out; do echo "$x"; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B52 a header whose only raw brace is in a COMMENT does not end the function on its header line"

D="$(fixture b53)"
cat > "$D/scripts/fiftythree.sh" <<'EOS'
#!/bin/bash
function collect() # builds ${MAP}
{
  local bad=0
  out="$(cmd)"
  for x in $out; do echo "$x"; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B53 the same in the 'function name()' spelling (with an INTERPOLATED comment)"
# ⛔ ROUND-10: an INDENTED header whose brace is on the next line was never recognised as a function
# (the indented alternative required `{` on the same line), so its body was scanned at top level and
# nothing at all was printed. And a top-level header whose counted brace never arrives must not become
# a phantom function that swallows the rest of the file.
D="$(fixture b54)"
cat > "$D/scripts/fiftyfour.sh" <<'EOS'
#!/bin/bash
  ind()
  {
    local bad=0
    out="$(cmd)"
    for x in $out; do echo "$x"; done
    return "$bad"
  }
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B54 an INDENTED header with its brace on the NEXT line is a function (indentation is not the discriminator)"

D="$(fixture b55)"
cat > "$D/scripts/fiftyfive.sh" <<'EOS'
#!/bin/bash
phantom() # note: this header never gets a brace the walk counts
readonly MARK=1

real() {
  local bad=0
  out="$(cmd)"
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B55 a header whose counted brace never arrives is closed, not a phantom swallowing the next function"
# ⛔ ROUND-11: three holes in the phantom-header recovery and in the carry handling. (i) A quote carry
# that HID the brace set the header pending, detaching a body whose brace is right there — 46 live
# headers in the scan set, and a function-scope finding is structurally unreportable once detached.
# (ii) The `function` spelling had no recovery at all. (iii) A header-shaped line following a phantom
# was consumed as a NESTED helper of a function that does not exist, dropping the real verdict.
D="$(fixture b56)"
cat > "$D/scripts/fiftysix.sh" <<'EOS'
#!/bin/bash
note="a drifted quote opens here and closes after the function
name_excluded() {
  local bad=0
  out="$(cmd)"
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
"
echo "the drift closes here"
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B56 a quote CARRY that hid the brace does not detach the function body"

D="$(fixture b57)"
cat > "$D/scripts/fiftyseven.sh" <<'EOS'
#!/bin/bash
function phantom # drifted
readonly MARK=1
real() {
  local bad=0
  out="$(cmd)"
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B57 the 'function' spelling gets the same phantom recovery as the 'name()' spelling"

D="$(fixture b58)"
cat > "$D/scripts/fiftyeight.sh" <<'EOS'
#!/bin/bash
phantom()

real() {
  local bad=0
  out="$(cmd)"
  for x in $out; do check "$x" || bad=1; done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "B58 a header-shaped line right after a phantom is a FUNCTION, not a nested helper of the phantom"

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

# ⛔ A FUNCTION-SCOPE FINDING MUST HONOUR THE MARKER TOO (#2121 review). `empty-as-pass` is reported
# at the LOOP line, and `exempt` is computed per line, so the marker was consulted by the line rules
# only: the FAIL message told a lane to "exempt one line with '# verified:'" and the marker changed
# nothing for exactly the rule whose widening makes that remedy necessary. Both placements are pinned,
# plus the bare-marker case (which must NOT exempt — an unreadable exemption is not an exemption).
D="$(fixture c4)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg
  for arg in $(list_targets); do   # verified: an empty target list is a legitimate PASS here (the caller refuses an empty set)
    [ -e "$arg" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "C4 a marker on the LOOP line exempts a function-scope empty-as-pass finding"

D="$(fixture c5)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg
  # verified: an empty target list is a legitimate PASS here (the caller refuses an empty set)
  for arg in $(list_targets); do
    [ -e "$arg" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "C5 a marker on the line ABOVE the loop exempts the same finding"

D="$(fixture c6)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg
  for arg in $(list_targets); do   # verified:
    [ -e "$arg" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -q 'marker-without-justification' <<<"$out"
ck $? "C6 a BARE marker does not exempt the function-scope finding, and is itself reported"

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

# ⛔ THE SPLIT HAS ONE HOME, and the suite reads it rather than hardcoding the ids: every rule that
# can never be grandfathered must also be a published rule id (a rule the join refuses that
# --list-rules does not name is unusable to a consumer).
out="$(bash "$CHECK" --list-rules 2>&1)"
# THREE SHAPES plus three kinds that FAIL the run and must therefore be enumerable: the ids are
# reported by the scanner, so a consumer that classifies findings by rule id cannot represent a kind
# this list omits. Of the six, the last three can never be grandfathered (E3b).
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "6" ] && grep -q '^discarded-status$' <<<"$out" \
  && grep -q '^empty-as-pass$' <<<"$out" && grep -q '^pre-existing-as-evidence$' <<<"$out" \
  && grep -q '^marker-without-justification$' <<<"$out" && grep -q '^unterminated-heredoc$' <<<"$out" \
  && grep -q '^unterminated-quote$' <<<"$out"
ck $? "E3 --list-rules publishes every rule id the scanner can emit (the doc reads THIS)"

# ⛔ THE SPLIT IS READ FROM THE TOOL, not hardcoded here: a rule the join refuses that no published
# list names is unusable, and a list that drifts from the join is the two-definitions defect.
nb="$(bash "$CHECK" --list-nonbaselineable 2>&1)"
[ "$(printf '%s\n' "$nb" | grep -c .)" = "3" ] && grep -q '^unterminated-heredoc$' <<<"$nb" \
  && grep -q '^unterminated-quote$' <<<"$nb" \
  && grep -q '^marker-without-justification$' <<<"$nb" \
  && [ -z "$(printf '%s\n' "$nb" | grep -v -e '^unterminated-heredoc$' -e '^unterminated-quote$' -e '^marker-without-justification$')" ] \
  && grep -q 'unterminated-heredoc' <<<"$out"
ck $? "E3b --list-nonbaselineable names exactly the rules the baseline may never grandfather, and each is a published rule"

# ⛔ F8 (review round 1): a hardcoded help window printed the IMPLEMENTATION as help. The header is
# now found by content, so this pins that `--help` prints the contract and none of the code.
out="$(bash "$CHECK" --help 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'CONTRACT' <<<"$out" && ! grep -q 'set -uo pipefail' <<<"$out"
ck $? "E4 --help prints the header block (not the code) and exits 2 as a usage error"

# ⛔ ROUND 4: THE TWO FAIL-CLOSED ARMS HAD NO FIXTURE, and they are the two whose failure mode is
# SILENCE: a reader that cannot run leaves $FINDINGS/$DECIDED empty, every counter stays 0, and the
# run prints PASS — the exact shape this whole check exists to catch, inside the check. A PATH shim
# makes ONE `awk` leg fail, so dropping the `|| { … exit 1 }` reds this suite instead of certifying
# absence. The shims are told apart by the programs, not by position: the scan program is the only
# one that mentions `unterminated-heredoc`, the decision program the only one that emits `BASELINED`.
REAL_AWK="$(command -v awk)"
[ -n "$REAL_AWK" ] || { echo "FAIL: cannot locate awk to build the failure shims" >&2; exit 1; }
shim_for() {
  local dir="$TMP/shim-$1" marker="$2"
  mkdir -p "$dir"
  {
    printf '#!/bin/bash\n'
    printf 'for a in "$@"; do\n'
    printf '  case "$a" in *%s*) echo "shim: rejecting this awk program" >&2; exit 1 ;; esac\n' "$marker"
    printf 'done\n'
    printf 'exec %q "$@"\n' "$REAL_AWK"
  } > "$dir/awk"
  chmod +x "$dir/awk"
  printf '%s' "$dir"
}

SHIM_SCAN="$(shim_for scan 'unterminated-heredoc')"
D="$(fixture e5)"
printf '#!/bin/bash\necho clean\n' > "$D/scripts/one.sh"
out="$(PATH="$SHIM_SCAN:$PATH" bash "$CHECK" --root "$D" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'could not be scanned' <<<"$out"
ck $? "E5 a SCAN leg that cannot run is an ERROR, never a PASS (empty findings would certify absence)"

SHIM_DECIDE="$(shim_for decide 'BASELINED')"
D="$(fixture e6)"
printf '#!/bin/bash\necho clean\n' > "$D/scripts/one.sh"
out="$(PATH="$SHIM_DECIDE:$PATH" bash "$CHECK" --root "$D" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'baseline/findings join could not run' <<<"$out"
ck $? "E6 a DECISION leg that cannot run is an ERROR, never a PASS (empty join reads as 0 findings)"

# ⛔ AN UNREADABLE BASELINE IS A MISSING OBSERVATION, NOT AN EMPTY ONE (#2121). A path that EXISTS
# but is not a readable file made the join treat every finding as un-grandfathered — which happens to
# fail while findings remain, and would report `0 baselined · 0 stale` (indistinguishable from a tree
# with no debt) once they do not. That is the fail-open-on-outcomes shape this file exists to catch,
# so it FAILS BY CONSTRUCTION, on a tree with no findings at all.
D="$(fixture e7)"
printf '#!/bin/bash\necho clean\n' > "$D/scripts/one.sh"
mkdir -p "$D/base-is-a-dir"
out="$(run_check "$D" --baseline "$D/base-is-a-dir")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'EXISTS but is not a readable file' <<<"$out" \
  && ! grep -q '^PASS' <<<"$out"
ck $? "E7 an UNREADABLE baseline FAILS on a clean tree (an unread baseline is not an empty one)"

# The other half: ABSENT is a different fact from UNREADABLE, and it must not read as "nothing to
# declare" either — with a finding present and no baseline at all, the run FAILS on the finding.
D="$(fixture e8)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
render() {
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
out="$(run_check "$D" --baseline "$D/absent.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'discarded-status' <<<"$out" && ! grep -q '^PASS' <<<"$out"
ck $? "E8 an ABSENT baseline grandfathers nothing (the finding still FAILS)"

# ⛔ A DANGLING SYMLINK IS A CONFIGURED BASELINE, NOT AN ABSENT ONE (`-e` FOLLOWS symlinks, #2121
# review). It took the absent path and printed `0 baselined` over a baseline that was set and never
# read — the "missing observation reported as nothing to declare" shape, in the branch that exists to
# refuse it. A `--baseline` pointing into a pruned worktree or a shared dir types exactly like this.
D="$(fixture e9)"
printf '#!/bin/bash\necho clean\n' > "$D/scripts/one.sh"
ln -s "$D/does-not-exist.tsv" "$D/dangling.tsv"
out="$(run_check "$D" --baseline "$D/dangling.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'EXISTS but is not a readable file' <<<"$out" && ! grep -q '^PASS' <<<"$out"
ck $? "E9 a DANGLING-SYMLINK baseline FAILS (configured-but-unread is not 'nothing to declare')"

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

# ⛔ A PARTIAL SCAN CANNOT BE GRANDFATHERED (#2121 review round 5, P2). `unterminated-heredoc` says
# the tail of this file was never scanned, so baselining it turns one truncated file into a
# permanently blind file under a green check — `findings=0`, `baselined: …`, `PASS` — while the run
# still advertises the file as scanned. The run must FAIL on the entry itself.
D="$(fixture d10)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
cat <<'INNER' > /tmp/x
body line
EOS
printf 'scripts/one.sh\tunterminated-heredoc\t1\t#9 — we accept that this file is scanned to line 3\n' > "$D/base.tsv"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'can NEVER be grandfathered' <<<"$out" && grep -q 'unterminated-heredoc' <<<"$out"
ck $? "D10 a baseline entry for unterminated-heredoc FAILS (unknown is not clean, however justified)"

# ... and the SANCTIONED remedy must not manufacture one: `--update-baseline` writes findings of
# every rule, so an unfiltered generator converts the truncated file into a permanent exemption.
D="$(fixture d11)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
cat <<'INNER' > /tmp/x
body line
EOS
: > "$D/base.tsv"
bash "$CHECK" --root "$D" --baseline "$D/base.tsv" --update-baseline >/dev/null 2>&1
n="$(grep -c 'unterminated-heredoc' "$D/base.tsv" 2>/dev/null || true)"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$n" = "0" ] && [ "$rc" -eq 1 ]
ck $? "D11 --update-baseline never writes a non-grandfather-able rule, so the finding stays red"

# The second non-grandfather-able rule, same mechanism: an unreadable exemption is not a claim a
# human can review, so "accept it in the baseline" cannot be the remedy.
D="$(fixture d12)"
cat > "$D/scripts/one.sh" <<'EOS'
#!/bin/bash
# verified:
echo ok
EOS
printf 'scripts/one.sh\tmarker-without-justification\t1\t#9 — accepted, nobody read it\n' > "$D/base.tsv"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'can NEVER be grandfathered' <<<"$out"
ck $? "D12 a baseline entry for marker-without-justification FAILS (an unreadable exemption is not reviewable)"

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
ck $? "G1 a DECLARATION FLAG between the builtin and the name (local -r cfg=\$(cmd)) is still the shape"

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
ck $? "G2 an ASSOCIATIVE assignment (declare -A m=([k]=\$(cmd))) is still the shape"

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
ck $? "G4 the SPLIT declaration (local c; c=\$(cmd)) is NOT flagged"

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
ck $? "G6 a ONE-LINE body under the 'function name' spelling reaches the LINE rules (an empty-as-pass verdict cannot be recorded on a one-line body — declared in the header)"

# Every declared glob must still contribute targets: a renamed/moved subtree silently shrinks the
# scan set, and the only other signal is a count nobody compares.
targets="$(bash "$CHECK" --list-targets 2>/dev/null)"
n="$(printf '%s\n' "$targets" | grep -c .)"
[ "$n" -ge 100 ] && grep -q '^scripts/orchestrator-harness/' <<<"$targets" && grep -q '^scripts/[a-z]' <<<"$targets"
ck $? "G7 both SCAN_GLOBS still contribute targets, and the scan set has not silently shrunk ($n files)"

# ⛔ ROUND 5, P1 (fail-open): the `|| return` arm only required the two SUBSTRINGS `$(` and `|| return`,
# with no requirement that the substitution was ASSIGNED to anything — so an ordinary precondition that
# merely USES one laundered a completely unrelated, unguarded feeder loop for the rest of the function
# while the run printed PASS. `[ -d "$(dirname "$0")" ]`, `[ -f "$(dirname …)/x" ]` and
# `[ -n "$(command -v x)" ]` are idioms this repo writes constantly. G5 pins the no-substitution
# spelling; this pins the spelling that still failed open.
D="$(fixture g8)"
cat > "$D/scripts/g8.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 arg
  [ -d "$(dirname "$0")" ] || return 1
  [ -n "$(command -v awk)" ] || exit 1
  while IFS= read -r arg; do
    [ -e "$arg" ] || bad=1
  done < <(list_targets)
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" \
  && grep -q 'scripts/g8.sh:8: empty-as-pass' <<<"$out"
ck $? "G8 a precondition that USES a substitution ([ -d \"\$(dirname \"\$0\")\" ] || return 1) does not launder the loop"

# ── H. the adversarial review's ten findings ────────────────────────────────
# Each case below was a MEASURED false PASS or a measured false positive at the commit before it,
# reproduced before the fix and pinned here after it. They are grouped by the review finding they
# answer so a later reader can check the list against the record rather than trusting it.
hdr "H. the adversarial review: a desynced scan, a partial PASS, and six silent spellings"

# ⛔ H1 (review, P0) — A QUOTE-CARRY DESYNC SILENTLY DISABLED `empty-as-pass` FOR THE REST OF A FILE,
# and the run still printed PASS. `x="$(sed -n 's/.*"head_sha":"\([^"]*\)".*/\1/p' "$f")"` is an
# ordinary line; with two booleans the `'` inside the still-open `"` never opened a single-quote
# context, the inner `"` closed `dq` early, the pairs shifted and the carry never closed. `depth` froze,
# `fn` never flushed, and the first `[ -n "$captured" ]` in that phantom scope set `fn_counter` for
# EVERYTHING after it — so `real_shape` below reported nothing. Measured before the fix: 0 findings and
# `PASS`, with only a stderr `partial:` note. The stack of quoting contexts (`$(`/backtick push a fresh
# one) fixes the drift; the partial-scan FAIL (H3) is the second line of defence.
D="$(fixture h1)"
cat > "$D/scripts/h1.sh" <<'EOS'
#!/bin/bash
head_of() {
  x="$(sed -n 's/.*"head_sha":"\([^"]*\)".*/\1/p' "$f")"
  echo "$x"
}
precheck() {
  out="$(list_things)"
  [ -n "$out" ] || echo "empty"
  echo "$out"
}
real_shape() {
  local bad=0 t lister
  lister="$(list_targets)"
  for t in $lister; do
    [ -e "$t" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" \
  && grep -q 'real_shape' <<<"$out" \
  && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "H1 a nested-quote sed line does not desync the carry: the shape AFTER it is still reported, and the scan is not partial"

# ⛔ H2 (review, P0) — THE SECOND DRIFT SOURCE WAS AN UNQUOTED HEREDOC. `cat <<BRIEF` returns "" from
# the opener search (which then recognised only QUOTED delimiters), so its body was walked as CODE: an
# apostrophe in prose opened a single-quote carry, the enclosing function never closed, and the tail
# was attributed to a phantom scope where the first captured-variable test laundered the loop.
D="$(fixture h2)"
cat > "$D/scripts/h2.sh" <<'EOS'
#!/bin/bash
brief() {
  cat <<BRIEF
Run the reviewer first: it's required, and the rail reads `~/.pi/agent/reviews/`.
BRIEF
}
precheck() {
  out="$(list_things)"
  [ -n "$out" ] || echo "empty"
}
verify() {
  local bad=0 x
  x="$(list_targets)"
  for t in $x; do
    [ -e "$t" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "H2 an UNQUOTED heredoc body is not walked for quotes/braces: its prose cannot blind the rest of the file"

# ⛔ H3 (review, P1) — A PARTIAL SCAN ENDED IN PASS. A brace count that never returns to zero leaves the
# tail of a file attributed to a block that swallowed it, and the run printed
# `PASS: … the three shapes are absent there` with a stderr note only. 12 of 167 files were partial at
# this commit. A partial scan is UNKNOWN, so it must FAIL and name the count.
D="$(fixture h3)"
cat > "$D/scripts/h3.sh" <<'EOS'
#!/bin/bash
broken() {
  echo hi
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'PARTIALLY scanned' <<<"$out" && ! grep -q '^PASS' <<<"$out"
ck $? "H3 a PARTIAL scan FAILS (never PASS) and names how many of the scanned files did not finish"

# ⛔ H4 (review, P2) — THE COUNT AND THE VERDICT ON DIFFERENT LINES. `n=$(ls -1 "$DST" | wc -l)` then
# `echo "✅ deployment COMPLETE: $n files"` puts the evidence one line above the verdict, and the arm
# only ever read a single line — so the third shape reported nothing.
D="$(fixture h4)"
cat > "$D/scripts/h4.sh" <<'EOS'
#!/bin/bash
deploy() {
  n=$(ls -1 "$DST" | wc -l)
  echo "✅ deployment COMPLETE: $n files"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'pre-existing-as-evidence' <<<"$out" && grep -q 'h4.sh:4:' <<<"$out"
ck $? "H4 pre-existing-as-evidence: a count CAPTURED on one line and printed as the verdict on the next"

# ⛔ H5 (review, P2) — THE VERDICT VOCABULARY WAS TOO NARROW. `seeded`, `staged`, `restored`,
# `converged` and `up to date` are what this fleet's deploy steps print, and none of them was in the
# list, so three live instances reported clean.
D="$(fixture h5)"
cat > "$D/scripts/h5.sh" <<'EOS'
#!/bin/bash
seed() {
  log_line "seeded $O with $(ls "$O"/*.sh | wc -l | tr -d ' ') scripts"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'pre-existing-as-evidence' <<<"$out"
ck $? "H5 pre-existing-as-evidence: the verdict vocabulary includes the words the deploy steps actually print (seeded/staged/restored/converged/up to date)"

# ⛔ H6 (review, P2) — THE SPLIT DECLARATION AND THE BRACED RETURN HID THE SHAPE. `local bad` + `bad=0`
# is the very spelling the header and MEMORY.md recommend, and it never reached `flaginit`; and
# `return "${bad}"` failed the `"?\$[A-Za-z_]` anchor. Together they made a real zero-iteration loop
# report clean.
D="$(fixture h6)"
cat > "$D/scripts/h6.sh" <<'EOS'
#!/bin/bash
verify_a() {
  local bad
  bad=0
  out="$(list_targets)"
  for t in $out; do
    [ -e "$t" ] || bad=1
  done
  return "${bad}"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "H6 empty-as-pass: a BARE-declared flag defaulted on the next line, returned as \"\${bad}\""

# ⛔ H7 (review, P2) — A FEEDER CAPTURED OUTSIDE THE FUNCTION IS A FEEDER. `LIST="$(cmd)"` at file scope
# then `f() { for x in $LIST; … }` is the same zero-iteration shape one scope out, and the captured set
# was reset by flush_fn, so nothing was registered for it at all.
D="$(fixture h7)"
cat > "$D/scripts/h7.sh" <<'EOS'
#!/bin/bash
LIST="$(list_targets)"
f() {
  local bad=0 x
  for x in $LIST; do
    [ -e "$x" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "H7 empty-as-pass: a feeder captured at FILE scope and iterated inside a function"

# ⛔ H8 (review, P3) — A QUOTED `[@]` OVER A SCALAR IS NOT THE SHAPE. `out="$(cmd)"` then
# `for x in "${out[@]}"` iterates ONCE even when the value is empty, so the code is correct; accepting
# ANY captured name for the array arm made it a finding. The ARRAY spelling must still be reported.
D="$(fixture h8)"
cat > "$D/scripts/h8.sh" <<'EOS'
#!/bin/bash
show() {
  local bad=0 x
  out="$(hostname)"
  for x in "${out[@]}"; do
    [ -n "$x" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "H8 no false positive: \"\${scalar[@]}\" iterates once even when empty, so it is NOT the shape"

D="$(fixture h8b)"
cat > "$D/scripts/h8b.sh" <<'EOS'
#!/bin/bash
show() {
  local bad=0 x
  arr=($(list_targets))
  for x in "${arr[@]}"; do
    [ -n "$x" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "H8b ... while \"\${arr[@]}\" over an ARRAY CAPTURE is still the shape (an empty array iterates zero times)"

# ⛔ H9 (review, P3) — A DECLARATION IS A STATEMENT, WHEREVER IT STARTS. `decl_masks_status` was
# anchored to `^[ \t]*`, so the three prefixes the CAPTURE arms were widened for stayed invisible:
# `if …; then local z=$(cmd); fi`, `true && local w=$(cmd)` and a `case` arm `a) local q=$(cmd) ;;`.
D="$(fixture h9)"
cat > "$D/scripts/h9.sh" <<'EOS'
#!/bin/bash
a() {
  if [ -n "$1" ]; then local z=$(read_a); fi
  true && local w=$(read_b)
  case "$1" in x) local q=$(read_c) ;; esac
  echo "$z$w$q"
}
EOS
n="$(run_check "$D" | grep -c 'discarded-status')"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && [ "$n" -eq 3 ]
ck $? "H9 discarded-status: the declaration is found after 'then', after '&&' and inside a case arm (3 of 3)"

# ⛔ H10 (review, P3) — AN OVER-RECORDED BASELINE COUNT ABSORBS A NEW INSTANCE. With `5` recorded and
# one instance present, the first instance of a NEW one was reported `baselined` and the run exited 0
# with only a STALE note. A count that does not match reality is a claim nobody can verify, so it FAILS;
# `seen == 0` stays a note (failing on "you fixed it" is perverse).
D="$(fixture h10)"
cat > "$D/scripts/h10.sh" <<'EOS'
#!/bin/bash
render() {
  local cfg=$(read_config)
  echo "$cfg"
}
render2() {
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
printf 'scripts/h10.sh\tdiscarded-status\t5\t#1743 — over-recorded on purpose\n' > "$D/base.tsv"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'OVER-RECORDS' <<<"$out" && ! grep -q '^PASS' <<<"$out"
ck $? "H10 a baseline count that OVER-RECORDS reality FAILS (it is what lets a new instance pass as baselined)"

# ⛔ H11 (review, P3) — THE CHECKER'S OWN COUNT-READS-ZERO. `partials=$(sort -u … | grep -c . || true)`
# reports `0 partial scan(s)` when `sort` fails, which is the shape this whole file exists to catch,
# inside the counter for it. The count is now one reader with its status checked.
SHIM_SORT="$TMP/shim-sort"
mkdir -p "$SHIM_SORT"
printf '#!/bin/bash\necho "shim: sort refused" >&2\nexit 1\n' > "$SHIM_SORT/sort"
chmod +x "$SHIM_SORT/sort"
D="$(fixture h11)"
cat > "$D/scripts/h11.sh" <<'EOS'
#!/bin/bash
broken() {
  echo hi
EOS
out="$(PATH="$SHIM_SORT:$PATH" bash "$CHECK" --root "$D" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'partial-scan notes could not be READ' <<<"$out" && ! grep -q '^PASS' <<<"$out"
ck $? "H11 an UNREADABLE partial-scan count is an ERROR, never '0 partial scan(s)'"

# ⛔ H12 (review, P3) — AN EXISTING --root WHOSE scripts/ MATCHES NOTHING. The scan-set-empty arm was
# unreachable in the suite: E2 only covered a root that does not exist (a usage error). A root that
# exists and has no target is the scan-of-nothing shape and must FAIL, not PASS.
D="$(fixture h12)"
rm -f "$D"/scripts/*.sh 2>/dev/null || true
mkdir -p "$D/other"; printf 'not a shell file\n' > "$D/other/a.txt"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'matched NO files' <<<"$out" && ! grep -q '^PASS' <<<"$out"
ck $? "H12 an EXISTING root whose scan set matches no file FAILS (a scan of nothing is not a PASS)"

# ⛔ H13 (review round 3, P0) — ANSI-C QUOTING IS NOT POSIX QUOTING. `$'…'` PROCESSES backslash
# escapes, so its terminator is the first UNESCAPED quote; reading it with the POSIX rule made
# `WHY=$'it\'s the fallback'` leave the quote carry OPEN (the escaped quote "closed" it, the real
# closing quote re-opened it). Every later line was then read as quoted: no brace counted, no
# function flushed, and the textbook shape below reported NOTHING while the run printed PASS with no
# partial note and exit 0 — a SILENT false PASS introduced by the round-2 carry fix.
D="$(fixture h13)"
cat > "$D/scripts/h13.sh" <<'EOS'
#!/bin/bash
WHY=$'it\'s the fallback'
also=$'plain ascii, no escapes'
posix='it is a posix string with a backslash \ inside'
verify() {
  local bad=0 x
  x="$(list_targets)"
  for t in $x; do
    [ -e "$t" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "H13 P0 an ANSI-C \$'…' literal with an ESCAPED quote does not desync the carry: the shape after it is reported"

# ⛔ H14 (review round 3, P0b) — A BRACE INSIDE AN ANSI-C LITERAL IS DATA. With the carry already
# desynced by a `$'\''`-style literal, the `}` inside a later `$'…'` body was COUNTED, ending the
# enclosing function on that line (silently — depth returned to 0, so no partial note exists), and
# every line after it was scanned at top level, where `empty-as-pass` is structurally unreportable.
# The same file WITHOUT the desync line reports, which is the proof the line is what dropped it.
D="$(fixture h14)"
cat > "$D/scripts/h14.sh" <<'EOS'
#!/bin/bash
SUFFIX=$'\''
render() {
  tpl=$'a\n}\n'
  local bad=0 x
  x="$(list_targets)"
  for t in $x; do
    [ -e "$t" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "H14 P0 a '}' inside an ANSI-C literal body cannot flush the enclosing function (the shape after it is still reported)"

D="$(fixture h14b)"
cat > "$D/scripts/h14b.sh" <<'EOS'
#!/bin/bash
render() {
  tpl=$'a\n}\n'
  local bad=0 x
  x="$(list_targets)"
  for t in $x; do
    [ -e "$t" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "H14b ... and the SAME body without the desync line reports too (the desync, not the literal, is what dropped it before)"

# ⛔ H15 (review round 3, P1) — A `<<` INSIDE A QUOTED STRING IS NOT AN OPENER. `note="write it with
# cat <<EOF"` opened a PHANTOM heredoc that swallowed everything up to the next bare `EOF` — including
# a real function header — so that function's body was scanned at TOP level, where `empty-as-pass` is
# unreportable, and the run printed PASS with no note. The opener is now taken from the walk, which
# knows what is code.
D="$(fixture h15)"
cat > "$D/scripts/h15.sh" <<'EOS'
#!/bin/bash
note="write it with cat <<EOF"
verify() {
  local bad=0 x
  x="$(list_targets)"
  for t in $x; do
    [ -e "$t" ] || bad=1
  done
  return "$bad"
}
cat <<EOF
hello
EOF
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "H15 P1 a '<<' inside a quoted string opens nothing: the shape the phantom heredoc used to swallow is reported"

# ⛔ H16 (review round 3, P1) — A `<<` THAT IS NOT AT COMMAND POSITION IS NOT AN OPENER, in the other
# direction: `x=$(( 1 << n ))` is a BIT-SHIFT and a `<<` in the body of an already-open heredoc is
# DATA, and both were read as openers. Each produced `unterminated-heredoc` plus a partial FAIL on a
# `bash -n`-clean file — a linter that reds correct code is deleted from CI, taking the class with it.
D="$(fixture h16)"
cat > "$D/scripts/h16.sh" <<'EOS'
#!/bin/bash
shift_by() {
  local n=2
  x=$(( 1 << n ))
  echo "$x"
}
gen() {
  cat <<BODY
printf 'a << b'
BODY
}
EOS
bash -n "$D/scripts/h16.sh" || fail "H16 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'unterminated-heredoc' <<<"$out" && grep -q '^PASS' <<<"$out"
ck $? "H16 P1 a BIT-SHIFT in \$(( … )) and a '<<' in a heredoc BODY are not openers (no false red on a bash -n-clean file)"

# ⛔ H17 (review round 3, P1c) — THE PARTIAL-SCAN MESSAGE MUST NAME WHICH KIND. It said "a quoted
# heredoc" for every case, but an UNQUOTED one is tracked too and its body is NOT skipped (its brace
# and quote bookkeeping is), which is a different fact for whoever has to fix it.
D="$(fixture h17)"
cat > "$D/scripts/h17.sh" <<'EOS'
#!/bin/bash
gen() {
  cat <<BODY
never terminated
BODY_typo
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'an UNQUOTED heredoc opened and was never closed' <<<"$out" \
  && ! grep -q 'a QUOTED heredoc opened' <<<"$out"
ck $? "H17 P1 an unterminated UNQUOTED heredoc is named as such (never as a quoted one), and still FAILS"

# ⛔ H18 (review round 3, P2) — A COMMENT IS NOT CODE, INCLUDING ITS WORDS. The line-level arms read
# the RAW line, so the widened verdict vocabulary made COMMENT PROSE a verdict: a correct capture whose
# trailing comment said "…what install.sh already deployed" was reported as pre-existing-as-evidence.
D="$(fixture h18)"
cat > "$D/scripts/h18.sh" <<'EOS'
#!/bin/bash
count_it() {
  n=$(ls -1 "$DST"/*.sh | wc -l)   # counts what install.sh already deployed
  echo "$n"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'pre-existing-as-evidence' <<<"$out"
ck $? "H18 P2 a trailing COMMENT mentioning a verdict word is not a verdict"

# ⛔ H19 (review round 3, P3) — A `local` SHADOWS, IT DOES NOT OVERWRITE. `drop_cap` said "an unqualified
# write clears BOTH scopes" and was called for `local`/`declare`/`typeset` too, so an unrelated
# function-local shadow deleted the FILE-scope capture and a real zero-iteration shape went silent.
D="$(fixture h19)"
cat > "$D/scripts/h19.sh" <<'EOS'
#!/bin/bash
LIST="$(list_targets)"
shadow() {
  local LIST="alpha beta"
  echo "$LIST"
}
verify() {
  local bad=0 x
  for t in $LIST; do
    [ -e "$t" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out"
ck $? "H19 P3 a function-scope 'local' shadow leaves the file-scope capture intact (the shape is still reported)"

D="$(fixture h19b)"
cat > "$D/scripts/h19b.sh" <<'EOS'
#!/bin/bash
LIST="$(list_targets)"
reset() {
  LIST="alpha beta"
}
verify() {
  local bad=0 x
  for t in $LIST; do
    [ -e "$t" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'empty-as-pass' <<<"$out"
ck $? "H19b ... while an UNQUALIFIED write in a function still clears both scopes (no new false positive)"

# ⛔ H20 (review round 3, P3) — THE MACHINE-READ SUMMARY MUST NOT READ GREEN WHEN THE RUN FAILS. An
# over-recorded baseline FAILS (H10), but the summary line omitted that counter entirely, so the one
# line a lane greps read `0 finding(s) · 2 baselined · 0 stale …` on a FAILING run.
D="$(fixture h20)"
cat > "$D/scripts/h20.sh" <<'EOS'
#!/bin/bash
render() {
  local cfg=$(read_config)
  echo "$cfg"
}
render2() {
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
printf 'scripts/h20.sh\tdiscarded-status\t5\t#1743 — over-recorded on purpose\n' > "$D/base.tsv"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q '1 over-recorded baseline entr(y|ies)' <<<"$out" && ! grep -q '^PASS' <<<"$out"
ck $? "H20 P3 the summary line carries the over-recorded count (a failing run cannot print a green-looking summary)"

# ⛔ H21 (review round 3, P0) — `inside_quotes()` HAD THE SAME BLINDNESS, in both directions: it
# skipped the character after a backslash even inside a POSIX single-quoted string, where a backslash
# is a literal. So a REAL `# verified:` marker after such a string was read as inside quotes and
# silently did nothing — the documented remedy became a no-op — while a marker mentioned inside an
# ANSI-C literal must still NOT manufacture an exemption.
D="$(fixture h21)"
cat > "$D/scripts/h21.sh" <<'EOS'
#!/bin/bash
hint() {
  log_line 'note: \' # verified: the split declaration below is the documented fix, not a masked status
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'discarded-status' <<<"$out"
ck $? "H21 a real '# verified:' marker after a POSIX string ending in a backslash is honoured (the remedy is not a no-op)"

D="$(fixture h21b)"
cat > "$D/scripts/h21b.sh" <<'EOS'
#!/bin/bash
hint() {
  log_line $'a marker: # verified: it is fine'
  local cfg=$(read_config)
  echo "$cfg"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'discarded-status' <<<"$out"
ck $? "H21b ... while a marker MENTIONED inside an ANSI-C literal still grants nothing"

# ⛔ H22 (review round 3, P1) — A HEREDOC INSIDE A COMMAND SUBSTITUTION IS STILL A HEREDOC.
# `x="$(cat <<EOF … EOF)"` opens a REAL heredoc (the body is DATA, and its apostrophes and braces must
# not move the carry). Refusing every opener that is not at the outermost context would have made this
# body code — the same silent drift H2 pinned, one context deeper — so the opener test reads the
# CURRENT context instead: code, not quoted, not arithmetic.
D="$(fixture h22)"
cat > "$D/scripts/h22.sh" <<'EOS'
#!/bin/bash
wrap() {
  x="$(cat <<EOF
it's a body with an apostrophe and a } brace
EOF
)"
  echo "$x"
  local bad=0 t
  t="$(list_targets)"
  for e in $t; do
    [ -e "$e" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "H22 P1 a heredoc inside \"\$( … )\" is tracked: its body is data, and the shape after it is reported"

# ⛔ H23 (review round 3, P1) — AN ARITHMETIC COMMAND INSIDE A SUBSTITUTION IS STILL ARITHMETIC.
# `$( (( 1 << n )) )` is a bit-shift; reading it as an opener produced an unterminated phantom heredoc
# whose delimiter was `n`, plus a partial FAIL, on a `bash -n`-clean file. `$((` and a bare `((` are
# different contexts (one is an expansion the walk must POP, the other a command) and both refuse the
# opener — which is why the check cannot simply refuse everything inside `$(`.
D="$(fixture h23)"
cat > "$D/scripts/h23.sh" <<'EOS'
#!/bin/bash
shift_by() {
  local n=2
  y=$( (( 1 << n )) )
  z=$(( (RANDOM << 15) % 900000 ))
  echo "$y$z"
  if [[ -n "$y" ]]; then
    echo ok
  fi
}
EOS
bash -n "$D/scripts/h23.sh" || fail "H23 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'unterminated-heredoc' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "H23 P1 an arithmetic COMMAND inside a command substitution, and a [[ … ]] test, are not heredoc openers"

# ⛔ H24 (review round 3, P1) — A LONG LINE MUST NOT CHANGE WHAT IS SEEN. The scanner is a text matcher
# whose arms used to be unanchored "identifier + operator" regexes and a per-character segment
# accumulator, both O(length^2): a 100 KB code line did not return at all (measured >120 s) while a
# comment of the same length was instant. A gate that hangs cannot report anything, so this fixture
# pins the CORRECTNESS half of that fix on a long line — escaped quotes, a brace and a substitution all
# on one very long statement, followed by the textbook shape, which must still be found.
D="$(fixture h24)"
{
  printf '#!/bin/bash\n'
  printf 'long_line() {\n  x="'
  i=0
  while [ "$i" -lt 300 ]; do printf 'part %s: \\"quoted\\" {braces} $(sub) ; ' "$i"; i=$((i + 1)); done
  printf '"\n  echo "${#x}"\n}\n'
  printf 'verify() {\n  local bad=0 t\n  t="$(list_targets)"\n  for e in $t; do\n    [ -e "$e" ] || bad=1\n  done\n  return "$bad"\n}\n'
} > "$D/scripts/h24.sh"
bash -n "$D/scripts/h24.sh" || fail "H24 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "H24 P1 a very long quoted line does not change what is scanned (a brace and a substitution on it are still data, and the shape after it is reported)"

# ── I. the round-4 review: an open carry is a failure, and heredoc data is never code ───────
hdr "I. the round-4 review: an open quote carry at EOF is a failure, and heredoc data is never code"

# ⛔ I1 (review round 4, P0) — AN OPENER INSIDE `${…}` IS STILL AN OPENER. skip_param JUMPS the whole
# expansion, so `note=${NOTE:-$(cat <<EOF … EOF)}` was never recorded: the heredoc body was walked as
# CODE, the apostrophe in it opened the quote carry, and the open carry made every later header hit
# TOPPEND — which clears `fn`, so the `empty-as-pass` in the tail was structurally unreportable. This
# head printed exit 0, `0 finding(s)`, `0 partial scan(s)`, PASS over a REAL shape. A `${…}` that
# contains a `$(` is now walked (its braces are still not block braces), so the body is data again.
D="$(fixture i1)"
cat > "$D/scripts/i1.sh" <<'EOS'
#!/bin/bash
note=${NOTE:-$(cat <<EOF
it's the default
EOF
)}
verify() {
  local bad=0 t
  t="$(list_targets)"
  for e in $t; do
    [ -e "$e" ] || bad=1
  done
  return "$bad"
}
EOS
bash -n "$D/scripts/i1.sh" || fail "I1 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out" \
  && ! grep -q 'unterminated-quote' <<<"$out"
ck $? "I1 P0 a heredoc opener inside \"\${…:-\$( … )}\" is tracked: its body is data, and the shape after it is reported"

# ⛔ I2 (review round 4, P0) — EVERY OPENER ON A LINE, IN ORDER. `cat <<A <<B` reads the body of A and
# then the body of B; only the first opener was recorded AND the `after` test rejected the line
# outright (the second `<` was not an accepted operand boundary), so NEITHER body was recognised and
# both were walked as code. The bodies are DATA, and the shape after them is still found.
D="$(fixture i2)"
cat > "$D/scripts/i2.sh" <<'EOS'
#!/bin/bash
verify() {
  local bad=0 t
  cat <<A <<B
A body
A
it's just data
B
  t="$(list_targets)"
  for e in $t; do
    [ -e "$e" ] || bad=1
  done
  return "$bad"
}
EOS
bash -n "$D/scripts/i2.sh" || fail "I2 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out" \
  && ! grep -q 'unterminated-quote' <<<"$out"
ck $? "I2 P0 two openers on one line are BOTH tracked: each body is data, and the shape after them is reported"

# ⛔ I3 (review round 4, P0) — AN OPEN QUOTE CARRY AT END OF FILE IS PROOF THAT THE WALK DESYNCHRONISED,
# and it is now a LOUD, non-baselineable finding. The round-3 head read this file as a silent PASS
# (measured: exit 0, `0 finding(s)`, `0 partial scan(s)`) because `depth` was back to 0 and `fn` was
# empty, so neither the partial net nor any scope-based net could fire — while the file's own contract
# says a file that cannot be delimited is a FAILURE. The finding names the line where the quote opened,
# not the last line of the file.
D="$(fixture i3)"
cat > "$D/scripts/i3.sh" <<'EOS'
#!/bin/bash
x='a quote the walk cannot pair
verify() {
  local bad=0 t
  t="$(list_targets)"
  for e in $t; do
    [ -e "$e" ] || bad=1
  done
  return "$bad"
}
EOS
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'scripts/i3.sh:2: unterminated-quote' <<<"$out"
ck $? "I3 P0 an open quote carry at EOF is a LOUD finding at the line that opened it, never a silent PASS"

# ... and it can never be grandfathered (the same reasoning as D10: an absence nobody observed is not
# a claim the baseline may record), nor manufactured by the sanctioned generator.
D="$(fixture i4)"
cp "$TMP/i3/scripts/i3.sh" "$D/scripts/i3.sh"
printf 'scripts/i3.sh\tunterminated-quote\t1\t#9 — we accept that this file cannot be delimited\n' > "$D/base.tsv"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'can NEVER be grandfathered' <<<"$out" && grep -q 'unterminated-quote' <<<"$out"
ck $? "I4 a baseline entry for unterminated-quote FAILS (a desynced scan is not clean, however justified)"

D="$(fixture i5)"
cp "$TMP/i3/scripts/i3.sh" "$D/scripts/i3.sh"
: > "$D/base.tsv"
bash "$CHECK" --root "$D" --baseline "$D/base.tsv" --update-baseline >/dev/null 2>&1
n="$(grep -c 'unterminated-quote' "$D/base.tsv" 2>/dev/null || true)"
out="$(run_check "$D" --baseline "$D/base.tsv")"; rc=$?
[ "$n" = "0" ] && [ "$rc" -eq 1 ]
ck $? "I5 --update-baseline never writes unterminated-quote, so a desynced scan stays red"

# ⛔ I6 (review round 4, P1) — A CRLF LINE ENDING IS NOT PART OF THE LINE. On a CRLF file the `\r`
# survived into every comparison, so `local bad=0\r` failed the `=0` arm, `return "$bad"\r` failed the
# verdict arm and `EOF\r` never matched the terminator: `empty-as-pass` was reported NOWHERE in the
# whole file and the run printed PASS. The fixture is written with CRLF endings on purpose (a Windows
# checkout); `bash -n` cannot validate one, so the read is pinned through the scanner instead.
D="$(fixture i6)"
printf '#!/bin/bash\r\nverify() {\r\n  local bad=0 t\r\n  t="$(list_targets)"\r\n  for e in $t; do\r\n    [ -e "$e" ] || bad=1\r\n  done\r\n  return "$bad"\r\n}\r\n' > "$D/scripts/i6.sh"
grep -q $'\r' "$D/scripts/i6.sh" || fail "I6 fixture lost its CRLF endings (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "I6 P1 a CRLF file is read as lines: the verdict and the terminator are still recognised"

# ⛔ I7 (review round 4, P3) — A TRAILING COMMENT AFTER THE OPENER DOES NOT CANCEL IT. The `after` test
# refused the line, so `cat <<BRIEF   # sticky note` was not recorded, its markdown body was walked as
# code, and an apostrophe in prose turned a CORRECT file into a loud partial FAIL naming the opener.
D="$(fixture i7)"
cat > "$D/scripts/i7.sh" <<'EOS'
#!/bin/bash
show_brief() {
  cat <<BRIEF   # sticky note: the opener carries a trailing comment
It's a brief whose prose has an apostrophe.
BRIEF
  echo done
}
show_brief
EOS
bash -n "$D/scripts/i7.sh" || fail "I7 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && grep -qE '0 finding\(s\)' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out" && grep -q '^PASS' <<<"$out"
ck $? "I7 P3 an opener followed by a trailing comment is still an opener: a correct file is not reded"

# ⛔ I8 (review round 4) — A HERESTRING IS CONSUMED WHOLE, INCLUDING ITS OPERAND. The round-3 exclusion
# kept `<<<` from being recorded at the FIRST `<`, but the walk advanced one character and re-tested at
# the SECOND, where `<< "operand"` is an ordinary quoted opener: measured on the round-3 head,
# `read -r e <<< "herestring"` was read as a heredoc whose delimiter was `herestring`, which never
# terminated — a loud `unterminated-heredoc` FAIL on a `bash -n`-clean file. A false block is how a
# guard gets deleted, so the token is skipped as a unit.
D="$(fixture i8)"
cat > "$D/scripts/i8.sh" <<'EOS'
#!/bin/bash
read -r e <<< "herestring"
read -r f <<<"joined"
printf '%s%s\n' "$e" "$f"
EOS
bash -n "$D/scripts/i8.sh" || fail "I8 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'unterminated-heredoc' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "I8 a HERESTRING (spaced or joined operand) opens no heredoc: a correct file is not reded"

# ⛔ I9 (review round 4) — A `#` INSIDE AN OPEN QUOTE IS NOT A COMMENT. The whole line used to be skipped
# whenever it STARTED with `#`, so a multi-line string whose closing quote sat on such a line kept the
# carry open to EOF: the new `unterminated-quote` finding then reded a CORRECT file. The line is a
# comment only when the current context has no quote open at its start.
D="$(fixture i9)"
cat > "$D/scripts/i9.sh" <<'EOS'
#!/bin/bash
banner="first line
# a banner line whose closing quote is on this very line"
printf '%s\n' "$banner"
EOS
bash -n "$D/scripts/i9.sh" || fail "I9 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'unterminated-quote' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "I9 a quote that closes on a '# ' line closes the carry: a multi-line string is not reded"

# ⛔ I10 (review round 4, P1) — THE END OF A `${…}` IS THE MATCHING `}`, NOT THE FIRST ONE. skip_param
# knew neither quotes nor brace EXPANSIONS, so `f=${X:-{a,b}}` ended at the `}` of `{a,b}` and the real
# closer was then counted as a BLOCK brace: the function ended a line early and a real `empty-as-pass`
# after it was reported NOWHERE (measured on the round-3 head: silent PASS). Pre-existing, and silent —
# the worst combination in this file.
D="$(fixture i10)"
cat > "$D/scripts/i10.sh" <<'EOS'
#!/bin/bash
three() {
  local bad=0 t
  f=${X:-{a,b}}
  t="$(list_targets)"
  for e in $t; do
    [ -e "$e" ] || bad=1
  done
  return "$bad"
}
EOS
bash -n "$D/scripts/i10.sh" || fail "I10 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "I10 P1 a brace EXPANSION inside a \"\${…}\" does not end the expansion early: the shape after it is reported"

# ⛔ I11 (review round 4, P1) — A QUOTED `}` IS NOT THE END OF THE EXPANSION EITHER, and this one was a
# REGRESSION of the new `${…}` walk: `g=${Y:-$(echo "}")}` ended the span inside the quoted string, the
# leftover `")}` was walked as braces, the function closed early and a real shape went silent. The span
# end must come from a quote-aware scan.
D="$(fixture i11)"
cat > "$D/scripts/i11.sh" <<'EOS'
#!/bin/bash
three() {
  local bad=0 t
  g=${Y:-$(echo "}")}
  t="$(list_targets)"
  for e in $t; do
    [ -e "$e" ] || bad=1
  done
  return "$bad"
}
EOS
bash -n "$D/scripts/i11.sh" || fail "I11 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "I11 P1 a QUOTED \"}\" inside a \"\${…}\" does not end the expansion: the shape after it is reported"

# ⛔ I12 (review round 4) — AN EXPANSION THAT SPANS PHYSICAL LINES CARRIES ITS NESTING. The braces of
# `${B:-{` … `}}` live on two lines; a per-line scan that forgot the leftover nesting counted those
# closers as BLOCK braces and ended the function early, so the shape after it was silent (measured on
# the round-3 head as well as mid-change). The nesting is now carried in PDEPTH.
D="$(fixture i12)"
cat > "$D/scripts/i12.sh" <<'EOS'
#!/bin/bash
three() {
  local bad=0 t
  y=${B:-{
    a b
  }}
  t="$(list_targets)"
  for e in $t; do
    [ -e "$e" ] || bad=1
  done
  return "$bad"
}
EOS
bash -n "$D/scripts/i12.sh" || fail "I12 fixture is not bash -n clean (the fixture is wrong, not the check)"
out="$(run_check "$D")"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'empty-as-pass' <<<"$out" && grep -qE '0 partial scan\(s\)' <<<"$out"
ck $? "I12 a \"\${…}\" that spans physical lines keeps its nesting: its closers are not block braces"

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
