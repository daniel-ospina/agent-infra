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
  if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi
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
printf '.worktrees/\n.env\n.env.local\n.mcp.json\n.venv\n' > "$REPO/.gitignore"
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

# ── 6. salvage (#435): dirty-hub capture → branch, hub returns to CLEAN ─────
git -C "$REPO" checkout -q main
echo "change-1" >> "$REPO/a.txt"                                        # tracked modified
echo "legit" > "$REPO/docs-new.md"                                      # untracked file
mkdir -p "$REPO/sub" && echo "deep" > "$REPO/sub/deep.md"               # untracked dir
mkdir -p "$REPO/.playwright-mcp" && echo "{}" > "$REPO/.playwright-mcp/art.json"  # junk dir
echo "bye" > "$REPO/delete-me.txt"
git -C "$REPO" add delete-me.txt && git -C "$REPO" commit -qm add-delete-me
git -C "$REPO" push -q origin main
rm "$REPO/delete-me.txt"                                                # tracked deletion (unstaged)

out="$(bash "$HELPER" salvage feat/salvage-1 "$REPO" 2>&1)" && rc=$? || rc=$?
assert_eq "$rc" 0 "salvage exits 0 on a dirty hub"
assert_contains "$out" "Salvage complete" "salvage reports completion"
hubdirty="$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')"
assert_eq "$hubdirty" "0" "hub CLEAN after salvage (junk removed too)"
assert_eq "$(git -C "$REPO" branch --show-current)" "main" "hub back on main"
wt_s="$REPO/.worktrees/feat/salvage-1"
[ -d "$wt_s" ] && ok "salvage worktree exists" || bad "salvage worktree missing"
git -C "$wt_s" log --oneline -1 | grep -q "salvage" && ok "salvage commit present" || bad "no salvage commit"
grep -q "change-1" "$wt_s/a.txt" && ok "tracked modification captured" || bad "tracked modification NOT captured"
grep -q "legit" "$wt_s/docs-new.md" && ok "untracked file captured" || bad "untracked file NOT captured"
grep -q "deep" "$wt_s/sub/deep.md" && ok "untracked dir captured" || bad "untracked dir NOT captured"
[ ! -e "$wt_s/delete-me.txt" ] && ok "tracked deletion captured" || bad "tracked deletion NOT captured"
[ ! -e "$wt_s/.playwright-mcp" ] && ok "junk dir NOT captured into branch" || bad "junk dir captured"
[ ! -e "$REPO/.playwright-mcp" ] && ok "junk dir removed from hub" || bad "junk dir left in hub"
git -C "$REPO" branch -r | grep -q "origin/feat/salvage-1" && ok "salvage branch pushed to origin" || bad "salvage branch NOT pushed"

# Clean hub → salvage refuses with guidance
out="$(bash "$HELPER" salvage feat/salvage-nope "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "salvage on a CLEAN hub → exit 1"
assert_contains "$out" "nothing to salvage" "clean-hub message"

# Off-main hub → salvage refuses with the WIP-preservation hint
git -C "$REPO" checkout -q -b strand/br
echo x >> "$REPO/a.txt"
out="$(bash "$HELPER" salvage feat/salvage-offmain "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "salvage on an OFF-MAIN hub → exit 1"
assert_contains "$out" "WIP-preservation path" "off-main guidance mentions push origin"
git -C "$REPO" checkout -q main
git -C "$REPO" branch -q -D strand/br

echo ""
echo "hub-worktree.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

# ── 7. salvage edge cases: push rejection (P1) + non-ASCII paths (P2) ──────
# 7a. Origin rejects the push → hub must NOT be cleaned; dirt stays recoverable.
git -C "$REPO" checkout -q main
echo "rej-1" >> "$REPO/a.txt"
mkdir -p "$REPO/.playwright-mcp" && echo "{}" > "$REPO/.playwright-mcp/art.json"
mkdir -p "$REPO/.git/hooks"  # pre-receive hook lives on the BARE origin
printf '#!/bin/sh\nexit 1\n' > "$ORIGIN/hooks/pre-receive"
chmod +x "$ORIGIN/hooks/pre-receive"
out="$(bash "$HELPER" salvage feat/salvage-reject "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "salvage exits 1 when the push is rejected"
assert_contains "$out" "PUSH FAILED" "push-failure message surfaced"
hubdirty="$(git -C "$REPO" status --porcelain | grep -v '^??' | wc -l | tr -d ' ')"
assert_eq "$hubdirty" "1" "hub dirt PRESERVED when push fails (tracked mod still dirty)"
[ -e "$REPO/.playwright-mcp/art.json" ] && ok "junk untouched when push fails" || bad "junk removed despite push failure"
git -C "$REPO" branch -r | grep -q "origin/feat/salvage-reject" && bad "rejected branch must NOT exist on origin" || ok "no rejected branch on origin"
git -C "$REPO" worktree list | grep -q "salvage-reject" && ok "local worktree retains the commit" || bad "local salvage worktree missing"
rm -f "$ORIGIN/hooks/pre-receive"

# 7b. Non-ASCII filename → captured verbatim, hub restored clean, no garbage.
git -C "$REPO" checkout -q main
git -C "$REPO" clean -fdq
git -C "$REPO" reset -q --hard HEAD 2>/dev/null || true
echo "cafe-head" > "$REPO/cafe-original.md"
git -C "$REPO" add cafe-original.md && git -C "$REPO" commit -qm add-cafe
git -C "$REPO" mv cafe-original.md "café-guide.md" 2>/dev/null || git -C "$REPO" mv cafe-original.md "$(printf 'caf\xc3\xa9-guide.md')"
git -C "$REPO" commit -qm mv-cafe
git -C "$REPO" push -q origin main
echo "cafe-edited" >> "$REPO/café-guide.md"
out="$(bash "$HELPER" salvage feat/salvage-utf8 "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "salvage succeeds with a non-ASCII dirty path"
grep -q "cafe-edited" "$REPO/.worktrees/feat/salvage-utf8/café-guide.md" && ok "non-ASCII modification captured" || bad "non-ASCII modification NOT captured"
hubdirty="$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')"
assert_eq "$hubdirty" "0" "hub CLEAN after non-ASCII salvage"
[ ! -e "$REPO/café-guide.md" ] || [ ! -e "$REPO/caf\303\251-guide.md" ] && ok "no octal-garbage file left behind" || bad "octal-garbage file left in hub"
git -C "$REPO" worktree remove --force "$REPO/.worktrees/feat/salvage-utf8" 2>/dev/null || true
git -C "$REPO" branch -q -D feat/salvage-utf8 2>/dev/null || true

# 7c. Tracked SYMLINK dirt (retargeted) → captured AS A LINK; the link's old
# target file must stay untouched (cycle-2 P1: cp wrote THROUGH the WT symlink).
git -C "$REPO" checkout -q main
git -C "$REPO" clean -fdq
git -C "$REPO" reset -q --hard HEAD 2>/dev/null || true
echo "victim-content" > "$REPO/victim.txt"
echo "target-content" > "$REPO/target.txt"
ln -s victim.txt "$REPO/weblink"
git -C "$REPO" add victim.txt target.txt weblink && git -C "$REPO" commit -qm add-links
git -C "$REPO" push -q origin main
rm "$REPO/weblink" && ln -s target.txt "$REPO/weblink"   # retarget dirty
out="$(bash "$HELPER" salvage feat/salvage-symlink "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "salvage succeeds with tracked symlink dirt"
grep -q "victim-content" "$REPO/.worktrees/feat/salvage-symlink/victim.txt" 2>/dev/null && ok "victim file NOT corrupted in the branch" || bad "VICTIM FILE CORRUPTED in the branch"
[ "$(readlink "$REPO/.worktrees/feat/salvage-symlink/weblink" 2>/dev/null || true)" = "target.txt" ] && ok "retargeted symlink captured verbatim" || bad "symlink retarget NOT captured"
hubdirty="$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')"
assert_eq "$hubdirty" "0" "hub CLEAN after symlink salvage"
[ -L "$REPO/weblink" ] && ok "hub weblink restored as a symlink" || bad "hub weblink not a symlink"
git -C "$REPO" worktree remove --force "$REPO/.worktrees/feat/salvage-symlink" 2>/dev/null || true
git -C "$REPO" branch -q -D feat/salvage-symlink 2>/dev/null || true

# ── 8. refresh (#1309): clean-but-stale hub → advance main to origin/main ───
# The state the guard made unreachable: a CLEAN hub whose local main is behind
# origin/main (the ordinary result of a clone nobody has pulled). refresh must
# advance it — and must refuse, by default and non-zero, to discard a dirty
# tree or a local-only commit that carries any file content. Hermetic: every
# repo here is a throwaway under $FIX, never a real hub.
git -C "$REPO" checkout -q main 2>/dev/null || true
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
git -C "$REPO" clean -fdq

# A second clone that plays the role of "someone else pushed to origin".
CLONE="$REAL_FIX/refresh-upstream"
git clone -q "$ORIGIN" "$CLONE"
git -C "$CLONE" config user.email t@t
git -C "$CLONE" config user.name t

# 8a. clean hub BEHIND origin/main → refresh advances it (fast-forward).
echo "refreshed-content" > "$CLONE/refreshed.txt"
git -C "$CLONE" add refreshed.txt && git -C "$CLONE" commit -qm refresh-upstream
git -C "$CLONE" push -q origin main
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "refresh advances a clean behind-hub → exit 0"
assert_contains "$out" "fast-forward" "refresh reports the fast-forward path"
assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$(git -C "$REPO" rev-parse origin/main)" "hub main == origin/main after refresh"
assert_eq "$(git -C "$REPO" branch --show-current)" "main" "hub still on main after refresh"
[ -e "$REPO/refreshed.txt" ] && ok "refreshed tree contains the upstream file" || bad "refreshed tree missing the upstream file"

# 8b. DIRTY hub → refused, non-zero, and the salvage remedy is named.
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
head_before="$(git -C "$REPO" rev-parse HEAD)"
echo "dirty-here" >> "$REPO/a.txt"
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses a dirty hub → exit 1"
assert_contains "$out" "working tree is DIRTY" "dirty refusal names the state"
assert_contains "$out" "salvage" "dirty refusal names the salvage remedy"
assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$head_before" "dirty refusal does not move HEAD"
git -C "$REPO" reset -q --hard origin/main
# untracked-only dirt counts as dirty too (untracked WIP is not refreshed away).
touch "$REPO/untracked-junk.tmp"
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses an untracked-only dirty hub → exit 1"
rm -f "$REPO/untracked-junk.tmp"

# 8c. local-only commit that CARRIES content → refused, file named; the
# discard flag does NOT override a content-carrying commit.
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
echo "local-only-content" > "$REPO/local-only.txt"
git -C "$REPO" add local-only.txt && git -C "$REPO" commit -qm local-only-content
head_before="$(git -C "$REPO" rev-parse HEAD)"
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses a content-carrying local-only commit → exit 1"
assert_contains "$out" "REFUSING" "content refusal is explicit"
assert_contains "$out" "local-only.txt" "content refusal names the file"
assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$head_before" "content refusal does not move HEAD"
out="$(bash "$HELPER" refresh --repo "$REPO" --discard-contentless 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "--discard-contentless does not bypass a content-carrying commit"
assert_contains "$out" "only drops CONTENTLESS" "flag refusal states the contentless scope"
git -C "$REPO" reset -q --hard origin/main

# 8d. CONTENTLESS local-only commits (an empty commit, the observed tortoise
# case) → plain refresh still refuses and prints the SHA; the explicit flag
# discards exactly those commits and advances.
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
# Divergence with no content on the local side: an empty local commit while
# origin/main advances independently.
git -C "$REPO" commit -q --allow-empty -m "empty local-only commit"
EMPTY_SHA="$(git -C "$REPO" rev-parse HEAD)"
echo "upstream-diverge" > "$CLONE/diverge.txt"
git -C "$CLONE" add diverge.txt && git -C "$CLONE" commit -qm diverge-upstream
git -C "$CLONE" push -q origin main
head_before="$(git -C "$REPO" rev-parse HEAD)"
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "plain refresh refuses a contentless divergence → exit 1"
assert_contains "$out" "not fast-forwardable" "contentless refusal names the divergence"
assert_contains "$out" "$EMPTY_SHA" "contentless refusal prints the local-only SHA"
assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$head_before" "plain refresh does not move HEAD"
out="$(bash "$HELPER" refresh --repo "$REPO" --discard-contentless 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "--discard-contentless proceeds on a contentless divergence"
assert_contains "$out" "$EMPTY_SHA" "flag path prints the discarded SHA before the move"
assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$(git -C "$REPO" rev-parse origin/main)" "hub main == origin/main after flagged refresh"
[ -e "$REPO/diverge.txt" ] && ok "flagged refresh brought in the upstream content" || bad "flagged refresh missed the upstream content"

# 8d2. the OBSERVED tortoise topology: an empty local commit, then a CLEAN
# merge of origin/main on top of it (a merge whose own delta is nil). Both
# local-only commits are contentless, so --discard-contentless drops them.
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
git -C "$REPO" commit -q --allow-empty -m "empty before merge"
git -C "$CLONE" fetch -q origin main && git -C "$CLONE" reset -q --hard origin/main
echo "merge-time" > "$CLONE/merge-time.txt"
git -C "$CLONE" add merge-time.txt && git -C "$CLONE" commit -qm merge-time-upstream
git -C "$CLONE" push -q origin main
git -C "$REPO" fetch -q origin main
git -C "$REPO" merge -q --no-ff -m "merge origin into empty commit" origin/main
MERGE_SHA="$(git -C "$REPO" rev-parse HEAD)"
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "plain refresh refuses the empty-commit + clean-merge divergence"
assert_contains "$out" "$MERGE_SHA" "merge refusal prints the merge SHA"
assert_contains "$out" "CONTENTLESS" "clean-merge divergence is classified contentless"
out="$(bash "$HELPER" refresh --repo "$REPO" --discard-contentless 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "flag discards the contentless empty+merge divergence"
assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$(git -C "$REPO" rev-parse origin/main)" "hub main == origin/main after merge-case refresh"

# 8e. already up to date → no-op success; off-main hub → refused.
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "refresh on an up-to-date hub → exit 0"
assert_contains "$out" "already at origin/main" "up-to-date refresh reports a no-op"
git -C "$REPO" checkout -q -b refresh-strand
echo stranded > "$REPO/stranded.txt" && git -C "$REPO" add stranded.txt && git -C "$REPO" commit -qm stranded
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses an off-main hub → exit 1"
assert_contains "$out" "not main/master" "off-main refusal names the branch condition"
git -C "$REPO" checkout -q main
git -C "$REPO" branch -q -D refresh-strand

# 8f. refresh accepts --repo.
assert_contains "$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" "already at origin/main" "refresh accepts --repo"

# 8g. the destructive verbs live ONLY in the nested sub-script (guard posture,
# #444): hub-worktree.sh's own content must contain no destructive git verb
# outside a comment (the guard strips comments before it gates).
outer_src="$(cat "$HELPER")"
outer_code="$(printf '%s\n' "$outer_src" | grep -Ev '^[[:space:]]*#' | sed 's/"[^"]*"//g' | grep -E '(^|[^-A-Za-z_])git\b.*[[:space:]]+(merge|reset)([[:space:]]|$)' || true)"
assert_eq "$outer_code" "" "hub-worktree.sh has no destructive git invocation outside comments"
[ -x "$SCRIPT_DIR/hub-worktree-refresh-advance.sh" ] && ok "refresh sub-script exists and is executable" || bad "refresh sub-script missing/not executable"
grep -Eq '(^|[^-A-Za-z_])git\b.*[[:space:]]+reset([[:space:]]|$)' "$SCRIPT_DIR/hub-worktree-refresh-advance.sh" && ok "destructive verbs are delegated to the sub-script" || bad "sub-script carries no destructive verb"

# 8h. the sub-script self-refuses a NON-main-checkout target (a linked worktree
# has a .git FILE, not a directory) — defense in depth if invoked directly.
out="$(bash "$SCRIPT_DIR/hub-worktree-refresh-advance.sh" "$REPO/.worktrees/feat/from-wt" ff 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh sub-script refuses a linked worktree target"
assert_contains "$out" "not a main checkout" "sub-script refusal explains the target check"

# 8i. the sub-script refuses a DIRTY hub even if called directly.
echo "sub-dirty" >> "$REPO/a.txt"
out="$(bash "$SCRIPT_DIR/hub-worktree-refresh-advance.sh" "$REPO" ff 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh sub-script refuses a dirty hub"
assert_contains "$out" "is DIRTY" "sub-script dirty refusal names the state"
git -C "$REPO" reset -q --hard origin/main

echo ""
echo "hub-worktree.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
