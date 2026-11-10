#!/bin/bash
# tests/harness-single-source-premise/run.sh — #2726: every arm of
# `harness-single-source.yml` that INVOKES the checker must make its premise true (`unset O`) and
# NAME the premise (`O is still set`) BEFORE the invocation, because `check-single-source.sh`
# otherwise takes its deployed directory from the runner's ambient `O`.
#
# THE DEFECT THIS PINS (measured on `cmux`, the machine in #2726's own payload)
# ---------------------------------------------------------------------------
#   `scripts/orchestrator-harness/check-single-source.sh:155` is
#
#       [ -n "$O_DIR" ] || O_DIR="${O:-}"
#
#   so any invocation that does not pass a NON-EMPTY `--o` silently grades `$O` — THIS BOX'S
#   DEPLOYMENT — instead of the tree the step's name promises. This fleet's cell runners export `O`
#   (measured 2026-10-25 on `ai-runner-cell3-x64-1`/`-2`, #2735), so the arms graded the RUNNER, not
#   the harness, and redded a correct tree.
#
#   THREE arms were affected and only TWO were fixed first. The third was a FALSE PASS, not just a
#   false red: `--fork` sets no `O_DIR` either, and the planted-fork step asserted only `rc == 1`
#   and never WHAT diverged. Measured: a fork holding none of the 11 fork-arm files printed
#   `ok: … holds none of the 11 fork-arm files`, produced 0 fork divergences, and still exited 1 on
#   the deployment's 56 — so the step passed with the arm it exists to prove dead. An arm that
#   cannot fail is the no-op-gate class, and it is invisible: the job is GREEN.
#
# WHAT THIS SUITE ASSERTS (and why each arm can fail)
# ---------------------------------------------------
#   1. LIVE — EVERY `check-single-source.sh` invocation in this workflow is preceded (in the same
#      step's `run:` body) by `unset O` AND by the assertion that NAMES the premise. Comments are
#      stripped first: the canonical step's own comment discusses `--o "$d"`, and reading that as an
#      argument is how a premise check certifies a step that has no premise.
#      ⛔ ORDER, not presence: a `run:` block that unsets O AFTER the invocation is unguarded at the
#      point of the invocation (and its own assertion can then only fire after the damage). The
#      header above says "preceded", so the predicate compares line/column positions.
#      ⛔ NO `--o` EXEMPTION (#2726, review round). It used to be "an explicit `--o` exempts the
#      step", which is FALSE for `--o "$d"` with `d=""`: `:155` reads an empty `O_DIR` as "no
#      target" and re-enters `${O:-}`. Rather than reason about the value, every invoking arm now
#      carries the premise — `unset O` is a no-op on an arm whose `--o` is genuinely explicit.
#   2. LIVE — the planted-fork arm asserts the red NAMES the planted fork. This is the arm that
#      closes the class independently of env: rc 1 has several causes and the deployment surface
#      supplies tens of them on a real runner.
#   3. NEGATIVE CONTROLS — the predicate itself, one per body shape and per verdict: a premised step
#      is accepted; a step that does not invoke the checker is not flagged (an over-broad guard is
#      as useless as an over-narrow one); a comment mentioning the checker is not an invocation; and
#      every shape that must be SUBJECT is subject — a `|` block, a `>` folded block, a SINGLE-LINE
#      `run:`, an explicit `--o` (non-empty and empty), a late `unset O`, a late assertion, and a
#      step whose checker invocation could not be extracted at all (fail-closed: ERROR, never pass).
#   4. MUTANTS — `unset O` deleted from EACH arm the workflow actually invokes the checker in turns
#      arm 1 RED, by name; the population is DERIVED from the workflow, never hand-listed, and an
#      empty/shrunken population FAILS rather than looping zero times and reporting green.
#   5. MUTANT — the ORDER claim: moving `unset O` below the invocation must be caught as
#      LATE-PREMISE (a presence-only predicate passes that mutant — measured pre-fix).
#   6. MUTANT — the fork's path assertion deleted turns arm 2 RED.
#
# STATED LIMIT — what a text parser still cannot prove (do not read the green as more than this):
#   a `unset O` inside a shell function that is never called, or a checker invocation assembled from
#   variables, would satisfy arm 1. Comments are stripped LINE-WISE only — a `#` inside quotes is not
#   a comment (`printf '%s\n' '# drift'` is live code), so a TRAILING comment that names the checker
#   reads as an invocation and the step is asked for a premise it does not need (an over-block, and
#   the finding names the step). That is the same limit `scripts/run-bash-shards.sh`'s header records
#   ("no text parser can prove EXECUTION"); what is pinned here is the TEXT of every arm that runs, and
#   the shapes a future edit is likely to produce are all subject. Arm 4 additionally REFUSES a
#   population that shrank, so an extractor that stops seeing steps cannot read as a clean sweep.
#
# HERMETIC: reads one tracked file; mutations are applied to a copy in a temp dir by exact line
# deletion/move, and a mutation that does not apply is an ERROR rather than a quietly-passing
# mutant. No network, no git, no host state.
#
# Run: bash tests/harness-single-source-premise/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WF="$ROOT/.github/workflows/harness-single-source.yml"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); printf '   ✅ %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '   ❌ %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '   ⏭️  %s\n' "$*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hss-premise.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$WF" ]; then
  printf '❌ harness-single-source-premise: %s is missing — a suite that cannot read its subject must not report a pass\n' "$WF"
  exit 2
fi

STEP_RE='^      - name:'

# names_of <file> — the step names, in file order.
names_of() {
  awk -v re="$STEP_RE" '$0 ~ re { sub(re "[[:space:]]*", ""); printf "%s\n", $0 }' "$1"
}

# step_range <file> <name-or-substring> — prints "<start> <end>" (1-based, end exclusive), or nothing.
# SUBSTRING, not equality: the arms are referred to below by their leading words (the full names carry
# long parentheticals), and an exact-match lookup silently found nothing — which then read as "the arm
# has no `unset O`", i.e. a mutation that could not be built while looking like an unguarded step.
step_range() {
  local file="$1" name="$2" start end
  start="$(awk -v re="$STEP_RE" -v n="$name" '$0 ~ re { s=$0; sub(re "[[:space:]]*", "", s); if (index(s, n) > 0) { print NR; exit } }' "$file")"
  [ -n "$start" ] || return 0
  end="$(awk -v s="$start" -v re="$STEP_RE" 'NR > s && $0 ~ re { print NR; exit }' "$file")"
  [ -n "$end" ] || end="$(( $(wc -l <"$file") + 1 ))"
  printf '%s %s\n' "$start" "$end"
}

# extract_run <file> <name> — the step's `run:` scalar, whatever its YAML form. Prints:
#     FORM<TAB>{block|inline|empty|none}
#     BODY<TAB><line>        … one per body line, de-indented by the block's own content indent
# ⛔ GENERIC, because the pre-fix version started collecting only on `run: |` and then dropped any
# step with an empty body — so a single-line `run:` (the dominant form in this repo's workflows) was
# certified WITHOUT INSPECTION. Shapes read: `run: |` / `run: >` (and `|-`, `|+`, `>-`, `>+`,
# indentation indicators), and `run: <single line>`. `empty` and `none` are reported rather than
# silently treated as "no invocation" — audit() fails closed on them.
extract_run() {
  local file="$1" range start end
  range="$(step_range "$file" "$2")"
  [ -n "$range" ] || { printf 'FORM\tnone\n'; return 0; }
  start="${range% *}"; end="${range#* }"
  awk -v s="$start" -v e="$end" '
    NR < s || NR >= e { next }
    rel == 0 {
      if ($0 ~ /^[[:space:]]*run:/) {
        rel = 1
        match($0, /^[[:space:]]*run:/)
        keyindent = RLENGTH - 4                       # the `run:` key own indentation
        rest = substr($0, RLENGTH + 1); sub(/^[[:space:]]/, "", rest)
        if (rest ~ /^[|>][+-]?[0-9]?[[:space:]]*(#.*)?$/) form = "block"
        else if (rest ~ /^[[:space:]]*$/) form = "empty"
        else { form = "inline"; inline_body = rest }
      }
      next
    }
    form == "block" {
      if ($0 ~ /^[[:space:]]*$/) { n++; bline[n] = ""; next }
      m = match($0, /[^ ]/); ind = m - 1
      if (ind <= keyindent) exit                     # the block scalar ended
      n++; bline[n] = $0
    }
    END {
      print "FORM\t" (form == "" ? "none" : form)
      if (form == "inline") print "BODY\t" inline_body
      if (form == "block") {
        last = n
        while (last > 0 && bline[last] == "") last--
        ci = -1
        for (i = 1; i <= last; i++) {
          if (bline[i] == "") continue
          m = match(bline[i], /[^ ]/); ind = m - 1
          if (ci < 0 || ind < ci) ci = ind
        }
        if (ci < 0) ci = 0
        for (i = 1; i <= last; i++)
          print "BODY\t" (bline[i] == "" ? "" : substr(bline[i], ci + 1))
      }
    }
  ' "$file"
}

run_form() { extract_run "$1" "$2" | awk 'index($0, "FORM\t") == 1 { print substr($0, 6); exit }'; }
run_body() { extract_run "$1" "$2" | awk 'index($0, "BODY\t") == 1 { print substr($0, 6) }'; }

# strip_comments — a `#` comment is prose, never an invocation and never an argument.
strip_comments() { awk '!/^[[:space:]]*#/'; }

# step_text_sans_name <file> <name> — the step's lines except its `- name:` line. Used for the
# fail-closed test: a step that mentions the checker OUTSIDE its name but whose `run:` body cannot be
# extracted must be an ERROR, not a `continue`.
step_text_sans_name() {
  local file="$1" range start end
  range="$(step_range "$file" "$2")"
  [ -n "$range" ] || return 0
  start="${range% *}"; end="${range#* }"
  awk -v s="$start" -v e="$end" 'NR > s && NR < e' "$file"
}

# analyse_body <body-file> — ONE line: "OK", or "<KIND><TAB><why>".
# KIND is MISSING-PREMISE / LATE-PREMISE / MISSING-ASSERTION / LATE-ASSERTION / OK.
# ORDER is compared, not mere presence: the first `unset O` COMMAND and the first `O is still set`
# assertion must both come before the first `check-single-source.sh` invocation — by line, and by
# column when they share a line (a single-line `run:` can carry both).
analyse_body() {
  awk '
    {
      line = $0
      if (invline == 0) {
        p = index(line, "check-single-source.sh")
        if (p > 0) { invline = NR; invcol = p }
      }
      if (unsetline == 0 && match(line, /(^|[;&|(]|then|do)[[:space:]]*unset[[:space:]]+O/)) {
        pre = substr(line, RSTART, RLENGTH)
        sub(/[[:space:]]*unset.*$/, "", pre)
        unsetline = NR; unsetcol = RSTART + length(pre)
      }
      if (assertline == 0) {
        p = index(line, "O is still set")
        if (p > 0) { assertline = NR; assertcol = p }
      }
    }
    END {
      if (invline == 0) { print "OK"; exit }
      unset_ok  = (unsetline  > 0) && (unsetline  < invline || (unsetline  == invline && unsetcol  < invcol))
      assert_ok = (assertline > 0) && (assertline < invline || (assertline == invline && assertcol < invcol))
      if (unsetline == 0)
        print "MISSING-PREMISE\tinvokes check-single-source.sh with no `unset O` — this arm grades the runner deployment, not what its name promises"
      else if (!unset_ok)
        print "LATE-PREMISE\t`unset O` comes AFTER the first invocation (line " unsetline " vs " invline ") — the invocation has already graded the runner deployment"
      else if (assertline == 0)
        print "MISSING-ASSERTION\tunsets O but never names the premise (no \"O is still set\"), so a dropped unset reds later with a misleading count instead of failing in place"
      else if (!assert_ok)
        print "LATE-ASSERTION\tthe premise assertion comes AFTER the invocation (line " assertline " vs " invline ") — it cannot fail in place"
      else print "OK"
    }
  ' "$1"
}

# audit <file> — one finding per violating step; empty output means "as decided".
audit() {
  local file="$1" name form body txt res kind why
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    form="$(run_form "$file" "$name")"
    body="$(run_body "$file" "$name" | strip_comments)"
    if printf '%s\n' "$body" | grep -qF 'check-single-source.sh'; then
      printf '%s\n' "$body" >"$TMP/body.$$"
      res="$(analyse_body "$TMP/body.$$")"
      rm -f "$TMP/body.$$"
      kind="$(printf '%s' "$res" | cut -f1)"
      why="$(printf '%s' "$res" | cut -f2-)"
      if [ "$kind" != OK ]; then
        printf '%s\t%s\t%s\n' "$kind" "$name" "$why"
      fi
      continue
    fi
    # An EXTRACTABLE body that does not invoke the checker is not this arm's business. An
    # UNEXTRACTABLE one that still names the checker is an ERROR, never a pass (fail-closed, the
    # same direction `run-bash-shards.sh` takes for a suite with no `# shard:` marker).
    case "$form" in
      block|inline) : ;;
      *)
        txt="$(step_text_sans_name "$file" "$name" | strip_comments)"
        if printf '%s\n' "$txt" | grep -qF 'check-single-source.sh'; then
          printf 'UNEXTRACTABLE\t%s\tthe step mentions check-single-source.sh but no `run:` body could be extracted (form: %s) — an arm this suite cannot read must not be certified\n' "$name" "$form"
        fi
        ;;
    esac
  done < <(names_of "$file")
}

# audit_fork_names_itself <file> — the planted-fork arm's red must NAME the fork.
audit_fork_names_itself() {
  local file="$1" name body
  name="$(names_of "$file" | grep -F 'planted fork' | head -1)"
  if [ -z "$name" ]; then
    printf 'MISSING-STEP\tplanted fork\tthe "NON-VACUITY — a planted fork is refused" step is gone — an absent arm cannot be green\n'
    return
  fi
  body="$(run_body "$file" "$name")"
  # The ASSERTION is a grep invocation naming the fork — not merely the path appearing anywhere:
  # the FAIL message below also spells the path, so a path-only test would stay satisfied by the
  # very branch that exists because the check is dead.
  if ! printf '%s\n' "$body" | grep -F -- '/tmp/planted-fork/lane.sh' | grep -q 'grep'; then
    printf 'UNNAMED-FORK\tplanted fork\tthe planted-fork arm asserts only rc 1 and never checks that the red NAMES the fork — on a runner that exports O the deployment supplies rc 1 and this arm passes while dead\n'
  fi
}

# invoking_steps <file> — the step names whose (comment-stripped) body invokes the checker. DERIVED,
# so the mutant population cannot drift from the workflow it claims to cover.
invoking_steps() {
  local file="$1" name body
  names_of "$file" | while IFS= read -r name; do
    [ -n "$name" ] || continue
    body="$(run_body "$file" "$name" | strip_comments)"
    case "$body" in *check-single-source.sh*) printf '%s\n' "$name" ;; esac
  done
}

# delete_step_line <file> <exact-name> <ERE matching the line to delete> <out> — deletes the FIRST
# matching line inside that step. Returns 1 when nothing matched (a mutation that does not apply).
delete_step_line() {
  local file="$1" name="$2" ere="$3" out="$4" range start end target
  range="$(step_range "$file" "$name")"
  [ -n "$range" ] || return 1
  start="${range% *}"; end="${range#* }"
  target="$(awk -v s="$start" -v e="$end" -v ere="$ere" 'NR > s && NR < e && $0 ~ ere { print NR; exit }' "$file")"
  [ -n "$target" ] || return 1
  awk -v n="$target" 'NR != n' "$file" >"$out"
  cmp -s "$file" "$out" && return 1
  return 0
}

# move_step_line_after <file> <exact-name> <ERE of the line to move> <ERE of the line to follow> <out>
# — moves the FIRST match of the first ERE below the FIRST match of the second, inside that step.
# Returns 1 when either line is missing (a mutation that does not apply).
move_step_line_after() {
  local file="$1" name="$2" ere="$3" after="$4" out="$5" range start end tgt pos moved
  range="$(step_range "$file" "$name")"
  [ -n "$range" ] || return 1
  start="${range% *}"; end="${range#* }"
  tgt="$(awk -v s="$start" -v e="$end" -v ere="$ere" 'NR > s && NR < e && $0 ~ ere { print NR; exit }' "$file")"
  pos="$(awk -v s="$start" -v e="$end" -v a="$after" 'NR > s && NR < e && $0 ~ a { print NR; exit }' "$file")"
  [ -n "$tgt" ] && [ -n "$pos" ] || return 1
  moved="$(awk -v n="$tgt" 'NR == n' "$file")"
  awk -v n="$tgt" -v p="$pos" -v m="$moved" 'NR == n { next } { print } NR == p { print m }' "$file" >"$out"
  cmp -s "$file" "$out" && return 1
  return 0
}

echo "== 1. LIVE — every checker invocation makes its premise true, NAMES it, and does so FIRST =="
# The population arm 1 speaks about, stated so an empty/shrunken read cannot pass as "as decided".
if [ -n "$(names_of "$WF")" ]; then
  pass "the workflow yields $(names_of "$WF" | wc -l | tr -d ' ') step(s) to inspect"
else
  fail "no step was found in $WF — a guard that inspected nothing must not report a pass"
fi
OUT="$(audit "$WF")"
if [ -z "$OUT" ]; then
  pass "every check-single-source.sh arm in the workflow unsets O and names the premise before its invocation"
else
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fail "[$(printf '%s' "$line" | cut -f1)] $(printf '%s' "$line" | cut -f2): $(printf '%s' "$line" | cut -f3-)"
  done <<<"$OUT"
fi

echo
echo "== 2. LIVE — the planted-fork arm asserts the red NAMES the fork =="
OUT="$(audit_fork_names_itself "$WF")"
if [ -z "$OUT" ]; then
  pass "the planted-fork arm requires a divergence naming /tmp/planted-fork/lane.sh, not merely rc 1"
else
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fail "[$(printf '%s' "$line" | cut -f1)] $(printf '%s' "$line" | cut -f2): $(printf '%s' "$line" | cut -f3-)"
  done <<<"$OUT"
fi

echo
echo "== 3. THE PREDICATE ITSELF — negative controls, one per body shape and per verdict =="

expect_clean() {
  local fixture="$1" label="$2" out
  out="$(audit "$TMP/$fixture")"
  if [ -z "$out" ]; then
    pass "$label"
  else
    fail "$label — the predicate flagged a step it must NOT flag: $out"
  fi
}
expect_finding() {
  local fixture="$1" want="$2" label="$3" out
  out="$(audit "$TMP/$fixture")"
  if printf '%s\n' "$out" | cut -f1 | grep -qx "$want"; then
    pass "$label"
  else
    fail "$label — expected $want, got '${out:-<no finding>}'"
  fi
}

cat >"$TMP/premised.yml" <<'YML'
jobs:
  j:
    steps:
      - name: canonical copy is complete
        run: |
          set -euo pipefail
          unset O
          [ -z "${O:-}" ] || { echo "FAIL: O is still set — this arm grades the canonical tree"; exit 1; }
          bash scripts/orchestrator-harness/check-single-source.sh
YML
expect_clean premised.yml "a premised \`|\`-block arm is ACCEPTED — the predicate is not simply flagging everything"

cat >"$TMP/unrelated.yml" <<'YML'
jobs:
  j:
    steps:
      - name: a step that does not invoke the checker
        run: |
          set -euo pipefail
          echo "nothing to see"
YML
expect_clean unrelated.yml "a step that does not invoke the checker is NOT flagged (an over-broad guard is as useless as an over-narrow one)"

cat >"$TMP/commented-only.yml" <<'YML'
jobs:
  j:
    steps:
      - name: a step that only mentions the checker in a comment
        run: |
          set -euo pipefail
          # bash scripts/orchestrator-harness/check-single-source.sh would go here
          echo hi
YML
expect_clean commented-only.yml "a checker named ONLY in a comment is not an invocation — and not a spurious UNEXTRACTABLE"

cat >"$TMP/commented.yml" <<'YML'
jobs:
  j:
    steps:
      - name: canonical copy is complete
        run: |
          set -euo pipefail
          # the deployed-byte arms are the `--o "$d"` steps below
          bash scripts/orchestrator-harness/check-single-source.sh
YML
expect_finding commented.yml MISSING-PREMISE "a comment mentioning --o is not an argument — the premise is still required"

cat >"$TMP/lapsed.yml" <<'YML'
jobs:
  j:
    steps:
      - name: a REAL comparison passes
        run: |
          set -euo pipefail
          bash scripts/orchestrator-harness/check-single-source.sh --require-target
YML
expect_finding lapsed.yml MISSING-PREMISE "an arm with no premise is MISSING-PREMISE"

cat >"$TMP/oneline.yml" <<'YML'
jobs:
  j:
    steps:
      - name: a NEW arm that forgot its premise
        run: bash scripts/orchestrator-harness/check-single-source.sh
YML
expect_finding oneline.yml MISSING-PREMISE "a SINGLE-LINE \`run:\` is inspected, not skipped (it used to be certified without ever being read)"

cat >"$TMP/oneline-assert.yml" <<'YML'
jobs:
  j:
    steps:
      - name: a NEW single-line arm that unsets but never names the premise
        run: unset O && bash scripts/orchestrator-harness/check-single-source.sh
YML
expect_finding oneline-assert.yml MISSING-ASSERTION "a single-line body is read far enough to demand the ASSERTION too (a skipped step would report nothing)"

cat >"$TMP/folded.yml" <<'YML'
jobs:
  j:
    steps:
      - name: a folded-body arm with no premise
        run: >
          set -euo pipefail
          bash scripts/orchestrator-harness/check-single-source.sh
YML
expect_finding folded.yml MISSING-PREMISE "a \`>\` FOLDED body is extracted and inspected (only \`|\` used to be read at all)"

cat >"$TMP/oarm.yml" <<'YML'
jobs:
  j:
    steps:
      - name: a REAL comparison passes
        run: |
          set -euo pipefail
          d="$(mktemp -d)"
          bash scripts/orchestrator-harness/check-single-source.sh --require-target --o "$d"
YML
expect_finding oarm.yml MISSING-PREMISE "an explicit (non-empty) --o is NOT exempt — the premise is uniform across every invoking arm"

cat >"$TMP/emptyo.yml" <<'YML'
jobs:
  j:
    steps:
      - name: an arm with an EMPTY explicit --o
        run: |
          set -euo pipefail
          d=""
          bash scripts/orchestrator-harness/check-single-source.sh --o "$d"
YML
expect_finding emptyo.yml MISSING-PREMISE "an EMPTY explicit --o is subject, never exempt — \`:155\` re-enters \${O:-} for an empty O_DIR"

cat >"$TMP/late-unset.yml" <<'YML'
jobs:
  j:
    steps:
      - name: NON-VACUITY — checking nothing is UNKNOWN
        run: |
          set -euo pipefail
          bash scripts/orchestrator-harness/check-single-source.sh --require-target --quiet
          unset O
          [ -z "${O:-}" ] || { echo "FAIL: O is still set now"; exit 1; }
YML
expect_finding late-unset.yml LATE-PREMISE "a \`unset O\` AFTER the invocation is caught as LATE-PREMISE (presence alone is not the claim)"

cat >"$TMP/late-assert.yml" <<'YML'
jobs:
  j:
    steps:
      - name: canonical copy is complete
        run: |
          set -euo pipefail
          unset O
          bash scripts/orchestrator-harness/check-single-source.sh
          [ -z "${O:-}" ] || { echo "FAIL: O is still set"; exit 1; }
YML
expect_finding late-assert.yml LATE-ASSERTION "an assertion AFTER the invocation is caught — it cannot fail in place"

cat >"$TMP/unextractable.yml" <<'YML'
jobs:
  j:
    steps:
      - name: an arm that hands the read to a composite action
        with:
          script: bash scripts/orchestrator-harness/check-single-source.sh
YML
expect_finding unextractable.yml UNEXTRACTABLE "a step that names the checker but has NO extractable \`run:\` is an ERROR, never a pass (fail-closed)"

# Structural control: on the REAL workflow, the number of invoking arms the mutants sweep must not
# silently shrink — a mutant loop over an empty list passes by doing nothing.
ARMS_FILE="$TMP/arms.txt"
invoking_steps "$WF" >"$ARMS_FILE"
NARMS="$(wc -l <"$ARMS_FILE" | tr -d ' ')"
if [ "$NARMS" -ge 5 ]; then
  pass "the population swept below is DERIVED from the workflow: $NARMS invoking arm(s)"
else
  fail "the workflow yields only $NARMS invoking arm(s); this suite pins at least 5 — a shrunken population must not read as a clean sweep"
fi

echo
echo "== 4. MUTANTS — every invoking arm that loses its \`unset O\` turns this suite RED, by name =="
while IFS= read -r arm; do
  [ -n "$arm" ] || continue
  slug="$(printf '%s' "$arm" | tr -cs 'a-zA-Z0-9' '-' | cut -c1-40)"
  mut="$TMP/mut-$slug.yml"
  if ! delete_step_line "$WF" "$arm" '^[[:space:]]*unset O[[:space:]]*$' "$mut"; then
    fail "arm '$arm' has no \`unset O\` to delete (or the step is missing) — it is not guarded, so this mutant cannot be built"
    continue
  fi
  OUT="$(audit "$mut")"
  if printf '%s\n' "$OUT" | awk -F'\t' -v a="$arm" '$1 == "MISSING-PREMISE" && $2 == a { found = 1 } END { exit !found }'; then
    pass "deleting \`unset O\` from '$arm' is caught, and the finding NAMES that arm"
  else
    fail "deleting \`unset O\` from '$arm' was NOT caught by name (output: '${OUT:-<empty>}') — arm 1 is a no-op for this step"
  fi
done <"$ARMS_FILE"

echo
echo "== 5. MUTANT — the ORDER claim: \`unset O\` moved BELOW the invocation =="
# ⛔ The anchor must be the INVOCATION, not any line naming the checker: the canonical step's own
# comment discusses `check-single-source.sh` BEFORE `run:`, and anchoring there moves the `unset` into
# the comment block — which the extractor correctly drops, so the mutant would measure the wrong thing.
if move_step_line_after "$WF" "canonical copy is complete" '^[[:space:]]*unset O[[:space:]]*$' '^[[:space:]]*bash scripts/orchestrator-harness/check-single-source\.sh' "$TMP/mut-order.yml"; then
  OUT="$(audit "$TMP/mut-order.yml")"
  if printf '%s\n' "$OUT" | awk -F'\t' '$1 == "LATE-PREMISE" && index($2, "canonical copy is complete") > 0 { found = 1 } END { exit !found }'; then
    pass "moving \`unset O\` below the invocation is caught as LATE-PREMISE, by name"
  else
    fail "moving \`unset O\` below the invocation was NOT caught (output: '${OUT:-<empty>}') — the predicate is testing presence, not the ordering its header claims"
  fi
else
  fail "the ordering mutation did not apply — a mutation that does not apply is an ERROR, never a passing mutant"
fi

echo
echo "== 6. MUTANT — the fork's path assertion deleted =="
if delete_step_line "$WF" "NON-VACUITY — a planted fork is refused" 'grep -q .*/tmp/planted-fork/lane\.sh' "$TMP/mut-fork.yml"; then
  OUT="$(audit_fork_names_itself "$TMP/mut-fork.yml")"
  case "$OUT" in
    *UNNAMED-FORK*) pass "deleting the fork's path assertion is caught (rc 1 alone is refused as evidence)" ;;
    *) fail "deleting the fork's path assertion was NOT caught — the class is closed only by env, not by the assertion" ;;
  esac
else
  fail "the fork-assertion mutation did not apply — a mutation that does not apply is an ERROR, never a passing mutant"
fi

echo
printf 'PASS %d · FAIL %d · SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '❌ %d premise assertion(s) failed\n' "$FAIL"
  exit 1
fi
printf '✅ every arm of harness-single-source that invokes the checker makes its premise true FIRST, and the planted fork is proven by name\n'
exit 0
