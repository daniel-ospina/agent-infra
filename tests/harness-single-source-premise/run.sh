#!/bin/bash
# tests/harness-single-source-premise/run.sh — #2726: every arm of
# `harness-single-source.yml` that INVOKES the checker without an explicit `--o` must first make its
# premise true (`unset O`), because `check-single-source.sh` otherwise takes its deployed directory
# from the runner's ambient `O`.
#
# THE DEFECT THIS PINS (measured on `cmux`, the machine in #2726's own payload)
# ---------------------------------------------------------------------------
#   `scripts/orchestrator-harness/check-single-source.sh:155` is
#
#       [ -n "$O_DIR" ] || O_DIR="${O:-}"
#
#   so any invocation that does not pass `--o` silently grades `$O` — THIS BOX'S DEPLOYMENT —
#   instead of the canonical tree the step's name promises. This fleet's cell runners export `O`
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
#   1. LIVE — every `check-single-source.sh` invocation in this workflow that passes no explicit
#      `--o` is preceded by `unset O` in the SAME step's `run:` body, and by the assertion that
#      NAMES the premise (so a dropped unset fails in place instead of redding later with a
#      misleading divergence count). Comments are stripped first: the canonical step's own comment
#      discusses `--o "$d"`, and reading that as an argument is how a premise check certifies a step
#      that has no premise.
#   2. LIVE — the planted-fork arm asserts the red NAMES the planted fork. This is the arm that
#      closes the class independently of env: rc 1 has several causes and the deployment surface
#      supplies tens of them on a real runner.
#   3. NEGATIVE CONTROLS — the predicate itself: an explicit-`--o` step is exempt, a step that loses
#      its `--o` becomes subject again, and a comment mentioning `--o` exempts nothing. Without
#      these, an over-broad check could "pass" arm 1 by demanding `unset O` nowhere.
#   4. MUTANTS — `unset O` deleted from EACH of the three arms turns arm 1 RED, by name.
#   5. MUTANT — the fork's path assertion deleted turns arm 2 RED.
#
# HERMETIC: reads one tracked file; mutations are applied to a copy in a temp dir by exact line
# deletion, and a mutation that does not apply is an ERROR rather than a quietly-passing mutant.
# No network, no git, no host state.
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

# run_body <file> <exact-name> — the `run: |` body of that step, with `#` comment lines REMOVED (a
# comment that discusses `--o "$d"` is not an argument and must not exempt the step).
run_body() {
  local file="$1" name="$2" range start end
  range="$(step_range "$file" "$name")"
  [ -n "$range" ] || return 0
  start="${range% *}"; end="${range#* }"
  awk -v s="$start" -v e="$end" '
    NR <= s || NR >= e { next }
    /^[[:space:]]*run:[[:space:]]*\|/ { inrun = 1; next }
    inrun {
      line = $0
      sub(/^ {10}/, "", line)          # de-indent the body so an exact-line test is usable
      stripped = line; sub(/^[[:space:]]+/, "", stripped)
      if (stripped ~ /^#/) next                              # comment: not an argument
      print line
    }
  ' "$file"
}

# audit <file> — one finding per violating step; empty output means "as decided".
audit() {
  local file="$1" name body explicit premise assertn
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    body="$(run_body "$file" "$name")"
    [ -n "$body" ] || continue
    printf '%s\n' "$body" | grep -qF 'check-single-source.sh' || continue
    # `--o` as an ARGUMENT (followed by space/quote/=), never `--require-target` and never `--fork`.
    if printf '%s\n' "$body" | grep -Eq -- '(^|[[:space:]])--o([[:space:]]|=|"|'"'"')'; then
      continue
    fi
    if printf '%s\n' "$body" | grep -Fxq 'unset O'; then premise=yes; else premise=no; fi
    if printf '%s\n' "$body" | grep -Fq 'O is still set'; then assertn=yes; else assertn=no; fi
    if [ "$premise" != yes ]; then
      printf 'MISSING-PREMISE\t%s\tinvokes check-single-source.sh with no explicit --o and never unsets O — this arm grades the runner deployment, not what its name promises\n' "$name"
    elif [ "$assertn" != yes ]; then
      printf 'MISSING-ASSERTION\t%s\tunsets O but never names the premise, so a dropped unset reds later with a misleading count instead of failing in place\n' "$name"
    fi
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

echo "== 1. LIVE — every non-\`--o\` checker invocation makes its premise true and names it =="
OUT="$(audit "$WF")"
if [ -z "$OUT" ]; then
  pass "every check-single-source.sh arm without an explicit --o unsets O first and names the premise"
else
  while IFS=$'\t' read -r kind name why; do
    [ -n "${kind:-}" ] || continue
    fail "[$kind] ${name}: ${why}"
  done <<<"$OUT"
fi

echo
echo "== 2. LIVE — the planted-fork arm asserts the red NAMES the fork =="
OUT="$(audit_fork_names_itself "$WF")"
if [ -z "$OUT" ]; then
  pass "the planted-fork arm requires a divergence naming /tmp/planted-fork/lane.sh, not merely rc 1"
else
  while IFS=$'\t' read -r kind name why; do
    [ -n "${kind:-}" ] || continue
    fail "[$kind] ${name}: ${why}"
  done <<<"$OUT"
fi

echo
echo "== 3. THE PREDICATE ITSELF — negative controls =="
cat >"$TMP/exempt.yml" <<'YML'
jobs:
  j:
    steps:
      - name: a REAL comparison passes
        run: |
          set -euo pipefail
          d="$(mktemp -d)"
          bash scripts/orchestrator-harness/check-single-source.sh --require-target --o "$d"
YML
OUT="$(audit "$TMP/exempt.yml")"
if [ -z "$OUT" ]; then
  pass "an explicit --o exempts the step (the \${O:-} fallback is never consulted)"
else
  fail "the predicate flagged an explicit---o step, so it cannot distinguish a real arm from an unguarded one: $OUT"
fi

cat >"$TMP/lapsed.yml" <<'YML'
jobs:
  j:
    steps:
      - name: a REAL comparison passes
        run: |
          set -euo pipefail
          bash scripts/orchestrator-harness/check-single-source.sh --require-target
YML
OUT="$(audit "$TMP/lapsed.yml")"
case "$OUT" in
  *MISSING-PREMISE*) pass "dropping --o re-subjects the step (the exemption is the ARGUMENT, not the step's name)" ;;
  *) fail "dropping --o left the step unreported — the exemption is reading the step's NAME, not its arguments: '${OUT:-<empty>}'" ;;
esac

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
OUT="$(audit "$TMP/commented.yml")"
case "$OUT" in
  *MISSING-PREMISE*) pass "a comment mentioning --o is not an argument — the premise is still required" ;;
  *) fail "a comment mentioning --o exempted the step, so a step that merely discusses the flag is certified unguarded: '${OUT:-<empty>}'" ;;
esac

echo
echo "== 4. MUTANTS — each arm that loses its \`unset O\` turns this suite RED, by name =="
for arm in "canonical copy is complete" "NON-VACUITY — a planted fork is refused" "NON-VACUITY — checking nothing is UNKNOWN"; do
  slug="$(printf '%s' "$arm" | tr -cs 'a-zA-Z0-9' '-' | cut -c1-40)"
  mut="$TMP/mut-$slug.yml"
  if ! delete_step_line "$WF" "$arm" '^          unset O$' "$mut"; then
    fail "arm '$arm' has no \`unset O\` to delete (or the step is missing) — it is not guarded, so this mutant cannot be built"
    continue
  fi
  OUT="$(audit "$mut")"
  case "$OUT" in
    *"$arm"*) pass "deleting \`unset O\` from '$arm' is caught, and the finding NAMES that arm" ;;
    *) fail "deleting \`unset O\` from '$arm' was NOT caught (output: '${OUT:-<empty>}') — arm 1 is a no-op for this step" ;;
  esac
done

echo
echo "== 5. MUTANT — the fork's path assertion deleted =="
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
printf '✅ every non---o arm of harness-single-source makes its premise true, and the planted fork is proven by name\n'
exit 0
