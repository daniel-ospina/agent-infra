#!/usr/bin/env bash
# commit-msg-check.test.sh — unit tests for the #668 commit-msg mangle hook.
#
# The hook (.husky/commit-msg) is run DIRECTLY here — `.husky/commit-msg <file>`
# — because husky is not installed in every checkout (#672: core.hooksPath
# unset, .husky/_/ absent). That is exactly why the hook guards its husky.sh
# source and its commitlint call instead of assuming husky bootstrapped it.
#
# Run: bash scripts/commit-msg-check.test.sh
# Registered in .github/workflows/ci-main.yml (extension-tests job).
#
# Coverage:
#   clean        → a multi-line Conventional Commit message: exit 0, NO output
#   unbalanced   → a planted odd-backtick message is flagged (warn, exit 0)
#   gap          → a planted substitution-shaped double space is flagged
#   legit code   → balanced inline-code backticks + `$`/`{{` pass silently
#   sentence     → two spaces after sentence punctuation are NOT flagged
#   false-pos    → an aligned block is flagged but still exits 0 (the evidence
#                  for the warn-only decision; strict mode is opt-in)
#   strict       → COMMIT_MSG_MANGLE_STRICT=1 turns a hit into exit 1
#   parity       → .husky/commit-msg is byte-identical to templates/.husky
#                  (bin/agent-infra.js doctor compares the two)

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/.husky/commit-msg"
TEMPLATE_HOOK="$ROOT/templates/.husky/commit-msg"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi
}
assert_empty() {
    if [ -z "$1" ]; then ok "$2"; else bad "$2 (expected no output, got: $1)"; fi
}
assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/commit-msg-check.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── Fixtures ───────────────────────────────────────────────────────────────
# A well-formed multi-line Conventional Commit whose body is full of the exact
# characters the shell would eat: backticked spans, `$VAR`, `$(…)`, `{{ }}`.
cat > "$T/clean.md" <<'MSG'
fix(ci): correct the guard for key matching

The guard now normalizes `key :` before matching via `keyRe()`.
Template literals such as `${{ inputs.env }}` and `$VAR` pass through
untouched because the message never reaches the shell.

Refs: `$(git rev-parse --short HEAD)` is quoted, not executed.
MSG

# Planted defect (a): an unmatched backtick — a `…` span was eaten.
cat > "$T/unbalanced.md" <<'MSG'
fix(ci): handle `key : matching in the guard

The guard tolerates a `key :` prefix and anchors the match.
MSG

# Planted defect (b): the substitution-shaped hole from #668 —
# "…which tolerates  — and anchors…" (the backticked span vanished).
cat > "$T/gap.md" <<'MSG'
fix(ci): correct the key guard

The guard now normalizes before key matching via keyRe() which tolerates  — and anchors the match.
MSG

# Legitimate sibling of (a): balanced inline code, `$` and `{{` untouched.
cat > "$T/legit-code.md" <<'MSG'
docs(agents): explain the `-F` rule

`git commit -m "$(cat <<'EOF')"` is banned: `$()` and `{{ }}` and `${VAR}`
are interpolated by the shell, and `keyRe()` matching eats `key :`.
MSG

# Two spaces after sentence punctuation is a legitimate (if dated) style.
cat > "$T/sentence.md" <<'MSG'
docs: fix the note.  And a second sentence follows the period.
MSG

# Accepted FALSE POSITIVE: aligned text uses runs of spaces legitimately.
# The hook flags it, but warn-only means the commit still succeeds.
cat > "$T/aligned.md" <<'MSG'
docs: document the config keys

Aligned values follow:

    name    value
    host    localhost
MSG

# ── Runner ─────────────────────────────────────────────────────────────────
HOOK_OUT=""
HOOK_RC=0
run() { # <file> [strict]
    local file="$1" strict="${2:-0}"
    local out rc
    out="$(cd "$ROOT" && COMMIT_MSG_MANGLE_STRICT="$strict" sh "$HOOK" "$file" 2>&1)"
    rc=$?
    HOOK_OUT="$out"
    HOOK_RC="$rc"
}

echo "commit-msg-check.test.sh — #668 mangle heuristic"

# 1. Clean message: exit 0, no output.
run "$T/clean.md"
assert_eq "$HOOK_RC" "0" "clean multi-line message: exit 0"
assert_empty "$HOOK_OUT" "clean multi-line message: no output"

# 2. Planted unbalanced backticks: flagged, warn-only.
run "$T/unbalanced.md"
assert_contains "$HOOK_OUT" "unbalanced backticks" "unbalanced backticks flagged"
assert_contains "$HOOK_OUT" "git commit -F" "flag names the -F remedy"
# #729: the remedy must not drift back to a `.git/` path — main-worktree-guard
# freezes `.git/…` writes as hub git-metadata for every unhatched session.
# NOTE the needle: a bare `COMMIT_MSG_` also matches the hook's own
# `COMMIT_MSG_MANGLE_STRICT` warn-only line, so it would fail unconditionally.
assert_contains "$HOOK_OUT" "absolute-git-dir" "flag names the --absolute-git-dir derivation"
assert_not_contains "$HOOK_OUT" "COMMIT_MSG_<" "flag no longer recommends a .git/COMMIT_MSG_ path"
assert_eq "$HOOK_RC" "0" "unbalanced backticks: warn-only (exit 0)"

# 3. Planted doubled-space substitution gap: flagged, warn-only.
run "$T/gap.md"
assert_contains "$HOOK_OUT" "doubled space" "substitution-shaped gap flagged"
assert_eq "$HOOK_RC" "0" "substitution-shaped gap: warn-only (exit 0)"

# 4. Legitimate balanced inline code + $ / {{ → silent.
run "$T/legit-code.md"
assert_eq "$HOOK_RC" "0" "balanced inline code: exit 0"
assert_empty "$HOOK_OUT" "balanced inline code + \$/{{: no output"

# 5. Sentence-ending punctuation + two spaces is excluded by design.
run "$T/sentence.md"
assert_eq "$HOOK_RC" "0" "two spaces after a period: exit 0"
assert_empty "$HOOK_OUT" "two spaces after a period: not flagged"

# 6. Documented false positive → still warn-only (evidence for the decision).
run "$T/aligned.md"
assert_contains "$HOOK_OUT" "doubled space" "aligned block is flagged (false positive)"
assert_eq "$HOOK_RC" "0" "flagging a legit aligned block does NOT block the commit"

# 7. Strict mode is the opt-in hard gate.
run "$T/unbalanced.md" "1"
assert_eq "$HOOK_RC" "1" "COMMIT_MSG_MANGLE_STRICT=1: unbalanced backticks exit 1"

# 8. Strict mode still lets a clean message through.
run "$T/clean.md" "1"
assert_eq "$HOOK_RC" "0" "COMMIT_MSG_MANGLE_STRICT=1: clean message exit 0"

# 9. Hook/template parity — the doctor (bin/agent-infra.js) compares the two.
if [ -f "$TEMPLATE_HOOK" ] && cmp -s "$HOOK" "$TEMPLATE_HOOK"; then
    ok ".husky/commit-msg == templates/.husky/commit-msg"
else
    bad ".husky/commit-msg differs from templates/.husky/commit-msg"
fi
if [ -x "$HOOK" ]; then ok "hook is executable"; else bad "hook is not executable"; fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
if [ "$FAIL" -eq 0 ]; then
    echo "✅ commit-msg-check: $PASS passed, 0 failed"
    exit 0
fi
echo "❌ commit-msg-check: $PASS passed, $FAIL failed"
exit 1
