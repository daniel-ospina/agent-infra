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

# Fixture root: hub-worktree.sh REFUSES a main repo under /tmp (or /private/tmp),
# and on Linux `mktemp -d` returns /tmp/… — so a bare temp root makes THIS suite
# fail on ubuntu-latest even though it passes on macOS (where mktemp uses
# /var/folders). Prefer RUNNER_TEMP (GitHub Actions), then a non-/tmp TMPDIR,
# else a HOME-based root. (#1324 review — this suite is wired into ci-main.yml.)
FIX_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
case "$FIX_ROOT" in
  /tmp|/tmp/*|/private/tmp|/private/tmp/*) FIX_ROOT="${HOME:-$PWD}/.hubwt-fixtures" ;;
esac
mkdir -p "$FIX_ROOT"
FIX="$(mktemp -d "$FIX_ROOT/hubwt-XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
REAL_FIX="$(cd "$FIX" && pwd -P)" # canonical (macOS: /var → /private/var)

ORIGIN="$REAL_FIX/origin.git"
REPO="$REAL_FIX/repo"
git init -q --bare -b main "$ORIGIN"
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
# /tmp on BOTH platforms: macOS /tmp is a symlink to /private/tmp and `pwd -P`
# resolves there, so the helper's refusal matches either spelling. The old
# hardcoded `/private/tmp` literal does not exist on Linux (#1324 review).
TMPREPO="/tmp/hubwt-test-$$"
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

# ── 6b. #854: the salvage hub-cleanup NAMES every path it reverses ──────────
# The defect this pins: salvage reverts the shared hub's tracked dirt to HEAD
# and used to do so with NO line naming the paths — so a sub-agent running the
# sanctioned recovery could destroy a parent session's uncommitted edit (the
# observed case: a TRACKED `.mcp.json` reverted to its exact HEAD bytes, mtime
# inside the dispatch window) with nothing in its report. The reversal must be
# (a) NAMED, with the branch that preserved it, and (b) printed even though the
# hub ends CLEAN — a clean exit must not swallow it.
REPO854="$REAL_FIX/repo854"
ORIGIN854="$REAL_FIX/origin854.git"
git init -q --bare -b main "$ORIGIN854"
git init -q -b main "$REPO854"
git -C "$REPO854" config user.email t@t
git -C "$REPO854" config user.name t
printf '{\n  "mcpServers": {}\n}\n' > "$REPO854/.mcp.json"   # TRACKED (the incident file)
printf '.worktrees/\n' > "$REPO854/.gitignore"
git -C "$REPO854" add . && git -C "$REPO854" commit -qm init
git -C "$REPO854" remote add origin "$ORIGIN854"
git -C "$REPO854" push -q origin main
# An UNRELATED uncommitted tracked edit (the parent's user-approved config) +
# untracked WIP, neither of them the recovering session's.
printf '{\n  "mcpServers": { "hosted-tortoise": { "url": "https://example.invalid" } }\n}\n' > "$REPO854/.mcp.json"
echo "scratch" > "$REPO854/notes.md"
out="$(bash "$HELPER" salvage feat/salvage-854 "$REPO854" 2>&1)" && rc=$? || rc=$?
assert_eq "$rc" 0 "#854: salvage of the incident shape exits 0"
assert_contains "$out" "hub cleanup REVERSED the dirty set" "#854: the cleanup names the reversal"
assert_contains "$out" "the uncommitted change now lives ONLY on feat/salvage-854" "#854: the reversal names where the change went"
assert_contains "$out" "     .mcp.json" "#854: the reverted TRACKED path is named (the incident file)"
assert_contains "$out" "     notes.md" "#854: the removed untracked path is named"
# The reversal really happened (hub back to HEAD bytes) AND was preserved.
assert_eq "$(git -C "$REPO854" hash-object .mcp.json)" "$(git -C "$REPO854" rev-parse HEAD:.mcp.json)" "#854: hub file reverted to HEAD byte-exact"
grep -q "hosted-tortoise" "$REPO854/.worktrees/feat/salvage-854/.mcp.json" && ok "#854: the reversed change IS preserved on the salvage branch" || bad "#854: the reversed change NOT preserved on the branch"
assert_eq "$(git -C "$REPO854" status --porcelain | wc -l | tr -d ' ')" "0" "#854: hub clean after the named reversal"
# A CLEAN hub prints no reversal record (the record must describe a real
# reversal, not be emitted unconditionally).
out="$(bash "$HELPER" salvage feat/salvage-854-nothing "$REPO854" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "#854: a clean hub still refuses salvage → exit 1"
case "$out" in *"hub cleanup REVERSED"*) bad "#854: clean hub emitted a reversal record" ;; *) ok "#854: no reversal record when nothing was reversed" ;; esac

# ── 6c. #854: the untracked sweep must NOT take `.worktrees/` ──────────
# `.worktrees/` appears as an untracked DIRECTORY whenever it is not
# gitignored, so an unguarded `rm -rf` destroys every sibling session's live
# worktree, and the paths are never named. Pin the guard with a sibling
# worktree holding an uncommitted edit.
# `status.showUntrackedFiles=all` is set deliberately: it is the user config
# under which the sweep's porcelain arrives as `.worktrees/<name>/` instead of
# the collapsed `.worktrees/`, so a guard matching only the container path
# fails OPEN and deletes the sibling worktree (and, on the capture side,
# publishes it to the salvage branch as an embedded-repo gitlink). Both guards
# must match every form the path can arrive in.
REPO854B="$REAL_FIX/repo854b"
ORIGIN854B="$REAL_FIX/origin854b.git"
git init -q --bare -b main "$ORIGIN854B"
git init -q -b main "$REPO854B"
git -C "$REPO854B" config user.email t@t
git -C "$REPO854B" config user.name t
git -C "$REPO854B" config status.showUntrackedFiles all
echo a > "$REPO854B/a.txt"
git -C "$REPO854B" add . && git -C "$REPO854B" commit -qm init
git -C "$REPO854B" remote add origin "$ORIGIN854B"
git -C "$REPO854B" push -q origin main
git -C "$REPO854B" worktree add -q "$REPO854B/.worktrees/sibling" -b wt/sibling HEAD
echo "sibling-uncommitted" >> "$REPO854B/.worktrees/sibling/a.txt"
echo "hub-dirt" >> "$REPO854B/a.txt"
out="$(bash "$HELPER" salvage feat/salvage-854b "$REPO854B" 2>&1)" && rc=$? || rc=$?
assert_eq "$rc" 1 "#854: a hub whose .worktrees is not gitignored does NOT report a clean hub"
assert_contains "$out" "is the isolated-worktree container" "#854: the refusal names the .worktrees container"
if [ -e "$REPO854B/.worktrees/sibling/a.txt" ]; then ok "#854: the sibling worktree SURVIVED the sweep"; else bad "#854: the sibling worktree was DELETED"; fi
grep -q "sibling-uncommitted" "$REPO854B/.worktrees/sibling/a.txt" 2>/dev/null && ok "#854: the sibling's uncommitted edit survived" || bad "#854: the sibling's uncommitted edit was destroyed"
# The capture pass must not put the container on the salvage branch either:
# with `--untracked-files=all` the pre-existing sibling arrives as
# `.worktrees/sibling/`, and copying it makes git record an embedded-repo
# gitlink on the branch the PR is opened from.
if git -C "$ORIGIN854B" ls-tree -r --name-only feat/salvage-854b 2>/dev/null | grep -q '^\.worktrees'; then
  bad "#854: the salvage branch CAPTURED the .worktrees container (sibling worktree)"
else
  ok "#854: the salvage branch carries no .worktrees path"
fi

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

# ── 7c. #1919: salvage must NOT eat a worktree nested in the hub ────────────
# git reports a nested registered worktree as ONE untracked directory
# (`?? nested-wt/`). The old capture would `cp -Rf` the LIVE worktree into the
# salvage branch and the hub cleanup would then `rm -rf` it out of the hub —
# destroying a working tree whose uncommitted work nothing else preserved. So
# salvage skips it (and any directory CONTAINING one) and still captures the
# genuine dirt beside it.
git -C "$REPO" worktree add -q "$REPO/nested-wt" -b nested-wt-br HEAD
echo "nested-wip" > "$REPO/nested-wt/nested-only.txt"   # uncommitted work INSIDE the worktree
echo "genuine-wip" > "$REPO/genuine-untracked.txt"      # real hub dirt beside it
out="$(bash "$HELPER" salvage feat/salvage-nested "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "salvage succeeds with a nested registered worktree present"
assert_contains "$out" "registered worktree (not hub dirt): nested-wt/" "…and names the worktree it left alone"
wt_s2="$REPO/.worktrees/feat/salvage-nested"
[ -f "$REPO/nested-wt/nested-only.txt" ] && ok "the nested worktree's uncommitted file SURVIVED" || bad "NESTED WORKTREE DESTROYED by salvage"
git -C "$REPO" worktree list --porcelain | grep -q "$REPO/nested-wt" && ok "…and it is still a registered worktree" || bad "worktree record lost"
grep -q "genuine-wip" "$wt_s2/genuine-untracked.txt" 2>/dev/null && ok "the genuine untracked file WAS captured on the branch" || bad "genuine dirt not captured"
assert_contains "$(git -C "$REPO" status --porcelain)" "?? nested-wt/" "…and the hub's only remaining entry is the worktree itself"
git -C "$REPO" worktree remove --force "$REPO/nested-wt" 2>/dev/null || true
git -C "$REPO" branch -q -D nested-wt-br 2>/dev/null || true
git -C "$REPO" worktree remove --force "$wt_s2" 2>/dev/null || true
git -C "$REPO" branch -q -D feat/salvage-nested 2>/dev/null || true

# ── 7d. #1919: salvage REFUSES when the worktree list cannot be read ────────
# An UNVERIFIABLE registered set is not an EMPTY one: with no list the capture
# pass cannot tell a live worktree from scratch dirt, and the cleanup pass would
# `rm -rf` the only copy of its uncommitted work. The destructive side must fail
# CLOSED (#1919 review P2) — the two readers degrade to "exclude nothing", which
# is safe precisely because they delete nothing.
git -C "$REPO" worktree add -q "$REPO/nested-wt" -b nested-wt-br2 HEAD
echo "nested-wip-2" > "$REPO/nested-wt/nested-only.txt"
SHIM="$FIX/shim-git-noworktreelist"; mkdir -p "$SHIM"
REAL_GIT_BIN="$(command -v git)"
cat > "$SHIM/git" <<'SHIMEOF'
#!/usr/bin/env bash
# Fail ONLY `git […] worktree list`; every other invocation reaches real git.
prev=""
for a in "$@"; do
  if [ "$prev" = "worktree" ] && [ "$a" = "list" ]; then
    echo "fatal: shimmed 'git worktree list' failure" >&2
    exit 128
  fi
  prev="$a"
done
exec "$REAL_GIT_BIN" "$@"
SHIMEOF
chmod +x "$SHIM/git"
out="$(REAL_GIT_BIN="$REAL_GIT_BIN" PATH="$SHIM:$PATH" bash "$HELPER" salvage feat/salvage-nolist "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "salvage REFUSES when \`git worktree list\` cannot answer (fails CLOSED)"
assert_contains "$out" "could not list REGISTERED WORKTREES" "…and says so, by name"
[ -f "$REPO/nested-wt/nested-only.txt" ] && ok "the live worktree's uncommitted file SURVIVED" || bad "WORKTREE CONTENT DESTROYED on an unverifiable list"
assert_contains "$(git -C "$REPO" status --porcelain)" "?? nested-wt/" "…and nothing was removed from the hub"
git -C "$REPO" worktree remove --force "$REPO/nested-wt" 2>/dev/null || true
git -C "$REPO" branch -q -D nested-wt-br2 2>/dev/null || true

# ── 7e. #1919: a CONTAINER left in place must NOT be reported as clean ─────
# salvage deliberately leaves a container (`deep/` holding a worktree) alone, so
# the hub is NOT clean afterwards and the verdict must say so (#1919 review
# cycle 2 P1). Reusing the container-aware predicate for the final cleanliness
# test dropped it from the remaining set: salvage printed "back to main+CLEAN"
# and exited 0 on a hub that `git status` and M4 both called dirty — a false PASS
# of the recovery path.
mkdir -p "$REPO/deep"
git -C "$REPO" worktree add -q "$REPO/deep/inner-wt" -b deep-wt-br HEAD
echo "deep-wip" > "$REPO/deep/inner-wt/precious-deep.txt"
echo "genuine-two" > "$REPO/genuine-two.txt"
out="$(bash "$HELPER" salvage feat/salvage-deep "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "salvage does NOT certify a hub whose worktree CONTAINER remains"
assert_contains "$out" "NOT yet fully clean" "…and says the hub is not clean"
[ -f "$REPO/deep/inner-wt/precious-deep.txt" ] && ok "…and the nested worktree's file SURVIVED" || bad "DEEP WORKTREE DESTROYED by salvage"
assert_contains "$(git -C "$REPO" status --porcelain)" "?? deep/" "…and the container is still there (reported, not removed)"
wt_s3="$REPO/.worktrees/feat/salvage-deep"
grep -q "genuine-two" "$wt_s3/genuine-two.txt" 2>/dev/null && ok "the genuine dirt beside it WAS captured" || bad "genuine dirt not captured"
rm -rf "$REPO/deep"
git -C "$REPO" worktree prune >/dev/null 2>&1 || true
git -C "$REPO" branch -q -D deep-wt-br 2>/dev/null || true
git -C "$REPO" worktree remove --force "$wt_s3" 2>/dev/null || true
git -C "$REPO" branch -q -D feat/salvage-deep 2>/dev/null || true

# ── 8. refresh (#1309): clean-but-stale hub → advance the hub to its upstream ─
# The state with no SANCTIONED path: a CLEAN hub whose local main has DIVERGED
# from origin/main (a merely behind hub is already covered by the M4-sanctioned
# `git pull --ff-only`; repo-freshness covers the sibling hubs automatically).
# refresh must refuse a diverged hub by default and print the local-only SHA(s);
# `--discard-contentless` advances it only when every local-only commit is
# contentless. It must also refuse, by default and non-zero, a dirty tree, a
# content-carrying local-only commit, or a hub-local IGNORED path the upstream
# changes. Hermetic: every repo here is a throwaway under $FIX, never a real hub.
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

# 8j. MUTATION COVER for the sub-script's OWN content-loss re-check: a clean,
# on-main hub with a content-carrying local-only commit must be refused at the
# point of mutation even when the sub-script is the entry point (the outer
# caller's analysis is bypassed here).
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
git -C "$REPO" checkout -q main
echo "sub-upstream" > "$CLONE/sub-upstream.txt"
git -C "$CLONE" add sub-upstream.txt && git -C "$CLONE" commit -qm sub-upstream
git -C "$CLONE" push -q origin main
printf 'sub-content\n' > "$REPO/sub-only.txt"
git -C "$REPO" add sub-only.txt && git -C "$REPO" commit -qm sub-content
sub_head="$(git -C "$REPO" rev-parse HEAD)"
out="$(bash "$SCRIPT_DIR/hub-worktree-refresh-advance.sh" "$REPO" discard-contentless 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "sub-script refuses a content-carrying commit on the discard path"
assert_contains "$out" "carries file content" "sub-script content refusal names the reason"
assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$sub_head" "sub-script content refusal does not move HEAD"
git -C "$REPO" reset -q --hard origin/main

# 8k. a `master` hub → refresh must advance origin/master, never origin/main
# (the upstream is the hub's OWN branch, not a hardcoded origin/main).
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
git -C "$REPO" branch -q -f master origin/main
git -C "$REPO" push -q origin master
git -C "$REPO" checkout -q master
main_before="$(git -C "$REPO" rev-parse origin/main)"
git -C "$CLONE" fetch -q origin main && git -C "$CLONE" reset -q --hard origin/main
git -C "$CLONE" fetch -q origin master
git -C "$CLONE" checkout -q -B master origin/master
echo "master-only" > "$CLONE/master-only.txt"
git -C "$CLONE" add master-only.txt && git -C "$CLONE" commit -qm master-advance
git -C "$CLONE" push -q origin master
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "refresh advances a master hub → exit 0"
assert_eq "$(git -C "$REPO" rev-parse HEAD)" "$(git -C "$REPO" rev-parse origin/master)" "master hub == origin/master after refresh"
assert_eq "$(git -C "$REPO" rev-parse origin/main)" "$main_before" "master refresh did not touch origin/main"
[ -e "$REPO/master-only.txt" ] && ok "master refresh brought in origin/master content" || bad "master refresh missed origin/master content"
git -C "$REPO" checkout -q main
git -C "$REPO" branch -q -D master
git -C "$CLONE" checkout -q main

# 8l. an upstream path the hub IGNORES → refused before either move. porcelain
# cannot see ignored files, so without this check the reset would silently delete
# the hub-local file (the fast-forward aborts on it instead) — the SEC-001
# data-loss path.
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
printf 'upstream-env\n' > "$CLONE/.env"
git -C "$CLONE" add -f .env && git -C "$CLONE" commit -qm add-env
git -C "$CLONE" push -q origin main
printf 'hub-local-secret\n' > "$REPO/.env"
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses an upstream path the hub ignores → exit 1"
assert_contains "$out" "IGNORES" "ignored-collision refusal names the state"
assert_contains "$out" ".env" "ignored-collision refusal names the file"
assert_eq "$(cat "$REPO/.env")" "hub-local-secret" "the hub-local ignored file was not overwritten"
rm -f "$REPO/.env"

# 8m. the ignored-collision check does NOT false-refuse when the ignored path
# has no upstream counterpart. The hub is left genuinely BEHIND so the
# sub-script actually runs — on the "already up to date" path the check would
# never be exercised and this group would be inert.
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
echo "m-upstream" > "$CLONE/m-upstream.txt"
git -C "$CLONE" add m-upstream.txt && git -C "$CLONE" commit -qm m-upstream
git -C "$CLONE" push -q origin main
printf 'still-local\n' > "$REPO/.env.local"
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "an unrelated hub-local ignored file still refreshes → exit 0"
assert_contains "$out" "fast-forward" "the ignored-collision check ran on the advancing path"
assert_eq "$(cat "$REPO/.env.local")" "still-local" "the unrelated ignored file is untouched"
rm -f "$REPO/.env.local"

# 8n. the collision check is PATH-AWARE, not a string compare: a hub-local
# ignored DIRECTORY that collides with an upstream FILE of the same name is
# caught (a line-by-line ignored-vs-tracked `comm` misses it).
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
mkdir -p "$REPO/hubdir" && printf 'hub-kept\n' > "$REPO/hubdir/k.txt"
printf 'hubdir/\n' >> "$REPO/.gitignore"
git -C "$REPO" add .gitignore && git -C "$REPO" commit -qm ignore-hubdir
git -C "$REPO" push -q origin main
git -C "$CLONE" fetch -q origin main && git -C "$CLONE" reset -q --hard origin/main
printf 'upstream-file\n' > "$CLONE/hubdir"
git -C "$CLONE" add hubdir && git -C "$CLONE" commit -qm upstream-hubdir-file
git -C "$CLONE" push -q origin main
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses an ignored DIRECTORY vs an upstream FILE → exit 1"
assert_contains "$out" "IGNORES" "directory/file collision refusal names the state"
assert_eq "$(cat "$REPO/hubdir/k.txt")" "hub-kept" "the ignored directory contents were not overwritten"

# 8o. the MIRROR of 8n: a hub-local ignored FILE that the upstream writes UNDER
# (the changed path `hubfile/x` does not exist locally, so the check must look at
# its nearest existing non-directory ancestor — otherwise `reset --hard` deletes
# the hub-local file to create the directory).
rm -rf "$REPO/hubdir"
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
printf 'hub-file-kept\n' > "$REPO/hubfile"
printf 'hubfile\n' >> "$REPO/.gitignore"
git -C "$REPO" add .gitignore && git -C "$REPO" commit -qm ignore-hubfile
git -C "$REPO" push -q origin main
git -C "$CLONE" fetch -q origin main && git -C "$CLONE" reset -q --hard origin/main
mkdir -p "$CLONE/hubfile" && printf 'upstream-under\n' > "$CLONE/hubfile/x"
git -C "$CLONE" add -f hubfile/x && git -C "$CLONE" commit -qm upstream-under-hubfile
git -C "$CLONE" push -q origin main
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses an ignored FILE with an upstream path UNDER it → exit 1"
assert_contains "$out" "IGNORES" "file/ancestor collision refusal names the state"
assert_eq "$(cat "$REPO/hubfile")" "hub-file-kept" "the ignored hub-local file was not deleted"

# 8p. a DANGLING ignored symlink at a changed path: `-e` follows the link and
# reports absence, so the check must also test `-L` or the reset replaces it.
rm -f "$REPO/hubfile"
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
ln -s /nonexistent-hub-target "$REPO/.env.local"
git -C "$CLONE" fetch -q origin main && git -C "$CLONE" reset -q --hard origin/main
printf 'upstream-env-local\n' > "$CLONE/.env.local"
git -C "$CLONE" add -f .env.local && git -C "$CLONE" commit -qm upstream-env-local
git -C "$CLONE" push -q origin main
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses a dangling ignored symlink at a changed path → exit 1"
assert_contains "$out" "IGNORES" "dangling-symlink refusal names the state"
[ -L "$REPO/.env.local" ] && ok "the dangling ignored symlink was not replaced" || bad "the dangling ignored symlink was replaced"

# 8q. a directory the upstream REPLACES with a non-directory, where the hub
# ignores a file INSIDE it: no changed path names that file, so the subtree has
# to be scanned or the reset destroys it together with the directory.
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
mkdir -p "$REPO/col" && printf 'tracked\n' > "$REPO/col/t.txt"
printf 'keep-me\n' > "$REPO/col/keep.local"
printf 'col/keep.local\n' >> "$REPO/.gitignore"
git -C "$REPO" add .gitignore col/t.txt && git -C "$REPO" commit -qm col-dir
git -C "$REPO" push -q origin main
git -C "$CLONE" fetch -q origin main && git -C "$CLONE" reset -q --hard origin/main
rm -rf "$CLONE/col" && printf 'upstream-collapsed\n' > "$CLONE/col"
git -C "$CLONE" add -A col && git -C "$CLONE" commit -qm upstream-collapses-col
git -C "$CLONE" push -q origin main
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses a collapsed dir holding an ignored file → exit 1"
assert_contains "$out" "IGNORES" "collapsed-dir refusal names the state"
assert_contains "$out" "col/keep.local" "collapsed-dir refusal names the IGNORED entry, not the tracked directory"
assert_eq "$(cat "$REPO/col/keep.local")" "keep-me" "the ignored file inside the replaced directory survived"

# 8r. a hub-local IGNORED SYMLINK whose target is an existing directory, with an
# upstream path UNDER it: `-d` follows the link, so the ancestor has to be
# recognised through `-L` — otherwise `reset --hard` replaces the symlink with a
# real directory without a refusal.
git -C "$REPO" fetch -q origin main
git -C "$REPO" reset -q --hard origin/main
mkdir -p "$REPO/realdir" && printf 'real-kept\n' > "$REPO/realdir/keep.txt"
ln -s realdir "$REPO/hubd"
printf 'hubd\n' >> "$REPO/.gitignore"
git -C "$REPO" add .gitignore realdir/keep.txt && git -C "$REPO" commit -qm symlink-ancestor
git -C "$REPO" push -q origin main
git -C "$CLONE" fetch -q origin main && git -C "$CLONE" reset -q --hard origin/main
mkdir -p "$CLONE/hubd" && printf 'upstream-under-symlink\n' > "$CLONE/hubd/newfile"
git -C "$CLONE" add -f hubd/newfile && git -C "$CLONE" commit -qm upstream-under-symlink
git -C "$CLONE" push -q origin main
out="$(bash "$HELPER" refresh --repo "$REPO" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "refresh refuses an ignored symlink ancestor with an upstream path under it"
assert_contains "$out" "IGNORES" "symlink-ancestor refusal names the state"
[ -L "$REPO/hubd" ] && ok "the ignored symlink ancestor was not replaced" || bad "the ignored symlink ancestor was replaced"

echo ""
echo "hub-worktree.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
