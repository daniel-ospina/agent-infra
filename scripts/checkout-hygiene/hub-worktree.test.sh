#!/usr/bin/env bash
# hub-worktree.test.sh — self-check for scripts/checkout-hygiene/hub-worktree.sh
# (#1484, Slice D: the one-command worktree helper — the root-cause fix that
# makes isolation the EASY path so the hub stops being the "only option").
#
# Run: bash scripts/checkout-hygiene/hub-worktree.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure. Self-contained: builds a
# throwaway bare origin + repo in a temp dir (the scan-orphans.test.sh pattern).
#
# Coverage: creates .worktrees/<branch> with the branch checked out (never
# detached) | never /tmp (refusal) | branch validation (main / bad names) |
# auto-setup symlinks (.env/.mcp.json/.venv) | works from INSIDE a worktree |
# rejects an existing worktree path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/hub-worktree.sh"

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
REAL_FIX="$(cd "$FIX" && pwd -P)" # canonical (macOS: /var → /private/var)

ORIGIN="$REAL_FIX/origin.git"
REPO="$REAL_FIX/repo"
git init -q --bare "$ORIGIN"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
touch "$REPO/a.txt"
git -C "$REPO" add .
git -C "$REPO" commit -qm init
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main
printf '.worktrees/\n' > "$REPO/.gitignore"
git -C "$REPO" add .gitignore && git -C "$REPO" commit -qm ignore
git -C "$REPO" push -q origin main
# Secrets/venv the incident lane lost in worktrees — the helper must symlink them
echo "TOKEN=x" > "$REPO/.env"
echo "{}" > "$REPO/.mcp.json"
mkdir -p "$REPO/.venv/bin"
touch "$REPO/.venv/bin/python"

# ── 1. Happy path: one command creates an isolated, never-detached worktree ─
out="$(bash "$HELPER" feat/1484-hub "$REPO" 2>&1)" && rc=$? || rc=$?
assert_eq "$rc" 0 "helper exits 0 on success"
assert_contains "$out" "Worktree ready: $REPO/.worktrees/feat/1484-hub" "prints the worktree path"
WT="$REPO/.worktrees/feat/1484-hub"
[ -d "$WT" ] && ok "worktree dir created under .worktrees/ (never /tmp)" || bad "worktree dir created under .worktrees/"
wt_branch="$(git -C "$WT" branch --show-current)"
assert_eq "$wt_branch" "feat/1484-hub" "worktree has the branch checked out (never detached)"
assert_contains "$out" "symlinked $REPO/.env" "auto-setup symlinks .env"
[ -L "$WT/.env" ] && ok ".env is a symlink to the hub's" || bad ".env symlink missing"
[ -L "$WT/.mcp.json" ] && ok ".mcp.json symlinked" || bad ".mcp.json symlink missing"
[ -L "$WT/.venv" ] && ok "shared venv symlinked (the incident's friction point)" || bad ".venv symlink missing"
hub_branch="$(git -C "$REPO" branch --show-current)"
assert_eq "$hub_branch" "main" "hub untouched, still on main"

# ── 2. Existing worktree path → refused ────────────────────────────────────
out="$(bash "$HELPER" feat/1484-hub "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "existing worktree path → exit 1"

# ── 3. Branch validation → exit 2 ──────────────────────────────────────────
for bad_branch in main master "" "/abs" "~/x" "feat/../x"; do
  out="$(bash "$HELPER" "$bad_branch" "$REPO" 2>&1)" && rc=0 || rc=$?
  assert_eq "$rc" 2 "invalid branch '$bad_branch' → exit 2"
done

# ── 4. /tmp refusal → exit 1 ───────────────────────────────────────────────
TMPREPO="/private/tmp/hubwt-test-$$"
git init -q -b main "$TMPREPO" 2>/dev/null
git -C "$TMPREPO" config user.email t@t && git -C "$TMPREPO" config user.name t
touch "$TMPREPO/a.txt" && git -C "$TMPREPO" add . && git -C "$TMPREPO" commit -qm init
out="$(bash "$HELPER" feat/x "$TMPREPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refuses a /tmp main repo → exit 1"
assert_contains "$out" "refusing a /tmp main repo" "refusal message names /tmp"
rm -rf "$TMPREPO"

# ── 5. Works from INSIDE a worktree (common-dir resolution) ────────────────
# The helper must resolve the MAIN repo even when called from an existing
# worktree — the exact scenario that broke isolation in the incident.
git -C "$REPO" worktree add -q "$REPO/.worktrees/existing" -b wt/existing origin/main
out="$(cd "$REPO/.worktrees/existing" && bash "$HELPER" feat/from-wt 2>&1)" && rc=$? || rc=$?
assert_eq "$rc" 0 "helper works when invoked from inside a worktree"
assert_contains "$out" "Worktree ready: $REPO/.worktrees/feat/from-wt" "resolves the MAIN repo via git-common-dir"
assert_eq "$(git -C "$REPO/.worktrees/feat/from-wt" branch --show-current)" "feat/from-wt" "nested-invocation worktree is not detached"

echo ""
echo "hub-worktree.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
