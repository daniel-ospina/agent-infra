#!/usr/bin/env bash
# hub-state-check.test.sh — self-check for scripts/checkout-hygiene/hub-state-check.sh
# (#1484; deployed session-gated via extensions/session-checks.ts, #432).
#
# Run: bash scripts/checkout-hygiene/hub-state-check.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Self-contained: builds
# throwaway repos in a temp dir; GH_BIN stubs the gh CLI for the dedup emitter.
#
# Coverage: PASS on main+clean | FAIL on off-main | FAIL on dirty (untracked +
# staged + unstaged) | recovery command in FAIL output | HUB_DISORDER= line |
# --repo arg | --gh-report creates one issue / comments on existing (dedup) |
# exit 2 on usage | resolves the MAIN checkout from inside a worktree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/hub-state-check.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_contains() { # <haystack> <needle> <label>
  if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}

assert_eq() { # <actual> <expected> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# ── Fixture: two temp repos (one clean hub, one to disorder) ──────────────
HUB="$FIX/hub"
OTHER="$FIX/other"
for r in "$HUB" "$OTHER"; do
  git init -q -b main "$r"
  git -C "$r" config user.email t@t
  git -C "$r" config user.name t
  touch "$r/a.txt"
  git -C "$r" add .
  git -C "$r" commit -qm init
done

# ── 1. PASS on main+clean ─────────────────────────────────────────────────
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=$? || rc=$?
assert_eq "$rc" 0 "clean hub exits 0"
assert_contains "$out" "PASS  $HUB" "clean hub prints PASS"
assert_contains "$out" "hub discipline holds" "clean summary line"

# ── 2. FAIL on untracked (dirty) ──────────────────────────────────────────
touch "$HUB/untracked.txt"
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "untracked → exit 1"
assert_contains "$out" "FAIL  $HUB" "untracked prints FAIL"
assert_contains "$out" "HUB_DISORDER=dirty" "untracked → HUB_DISORDER=dirty"
assert_contains "$out" "recovery: cd $HUB && git checkout main && git pull --ff-only" "FAIL prints recovery command"
rm "$HUB/untracked.txt"

# ── 3. FAIL on staged + unstaged ──────────────────────────────────────────
echo x >> "$HUB/a.txt"
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "unstaged modification → exit 1"
assert_contains "$out" "HUB_DISORDER=dirty" "unstaged → dirty"
git -C "$HUB" add .
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "staged modification → exit 1"
assert_contains "$out" "HUB_DISORDER=dirty" "staged → dirty"
git -C "$HUB" checkout -q .

# ── 4. FAIL on off-main ───────────────────────────────────────────────────
git -C "$HUB" checkout -qb feat/incident
out="$(bash "$CHECK" --repo "$HUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "off-main → exit 1"
assert_contains "$out" "HUB_DISORDER=off_main" "off-main → HUB_DISORDER=off_main"
git -C "$HUB" checkout -q main

# ── 5. Worktree resolution (D5): check from INSIDE a worktree ─────────────
WT="$HUB/.worktrees/wt-test"
git -C "$HUB" worktree add -q "$WT" -b wt/feat HEAD
git -C "$HUB" checkout -qb pr1467 2>/dev/null || true  # disorder the HUB (off-main)
out="$(bash "$CHECK" --repo "$WT" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "check from worktree sees the disordered hub (off-main) → exit 1"
assert_contains "$out" "HUB_DISORDER=off_main" "worktree-resolved check reports MAIN checkout state"
git -C "$HUB" worktree remove --force "$WT"
git -C "$HUB" branch -D wt/feat >/dev/null 2>&1 || true

# ── 6. Multiple repos: one PASS + one FAIL → exit 1, both lines ───────────
git -C "$HUB" checkout -q pr1467 2>/dev/null || git -C "$HUB" checkout -qb pr1467 2>/dev/null || true
out="$(bash "$CHECK" --repo "$HUB" --repo "$OTHER" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "multi-repo with one FAIL → exit 1"
assert_contains "$out" "PASS  $OTHER" "multi-repo prints PASS for the clean repo"
assert_contains "$out" "FAIL  $HUB" "multi-repo prints FAIL for the disordered repo"
git -C "$HUB" checkout -q main

# ── 7. Usage errors → exit 2 ──────────────────────────────────────────────
out="$(bash "$CHECK" --bogus 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 2 "unknown flag → exit 2 (usage)"

# ── 8. gh-report dedup emitter (stubbed gh) ────────────────────────────────
# gh is stubbed to (a) list open hub-state issues, (b) create or comment.
mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub: record invocations; simulate an open hub-state issue for the second run.
echo "$@" >> "$GH_STUB_LOG"
case "$1" in
  issue)
    if [ "$2" = "list" ]; then
      # "issue exists" flag file toggles between create-mode and comment-mode
      if [ -f "$GH_EXISTING" ]; then echo '123'; else echo '[]'; fi
    elif [ "$2" = "create" ]; then
      echo "https://github.com/stub/hub/issues/99"
    elif [ "$2" = "comment" ]; then
      echo "commented"
    fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$FIX/bin/gh"
export GH_BIN="$FIX/bin/gh"
export GH_STUB_LOG="$FIX/gh-calls.log"
export GH_EXISTING="$FIX/gh-existing"

# seed an origin remote so the slug parses
git -C "$HUB" remote add origin "https://github.com/daniel-ospina/tortoise.git" 2>/dev/null || true

git -C "$HUB" checkout -qb pr1467 2>/dev/null || true
touch "$HUB/untracked.txt"
: > "$GH_STUB_LOG"
out="$(bash "$CHECK" --repo "$HUB" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "gh-report FAIL still exits 1"
assert_contains "$out" "opened hub-state issue" "first FAIL opens a hub-state issue"
assert_contains "$(cat "$GH_STUB_LOG")" "issue create --repo daniel-ospina/tortoise" "issue create targets the parsed repo slug"

# second run: stub now reports an open issue → dedup → comment, no new issue
touch "$GH_EXISTING"
: > "$GH_STUB_LOG"
out="$(bash "$CHECK" --repo "$HUB" --gh-report 2>&1)" && rc=0 || rc=$?
assert_contains "$out" "commented on existing hub-state issue" "repeat FAIL comments on the open issue (dedup)"
if grep -q "issue create" "$GH_STUB_LOG"; then bad "dedup: no second issue create"; else ok "dedup: no second issue create"; fi
assert_contains "$(cat "$GH_STUB_LOG")" "issue comment --repo daniel-ospina/tortoise 123" "comment targets the existing issue number"
rm -f "$GH_EXISTING"
git -C "$HUB" checkout -q main 2>/dev/null || true
rm -f "$HUB/untracked.txt"

echo ""
echo "hub-state-check.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
