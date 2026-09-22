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
# exit 2 on usage | resolves the MAIN checkout from inside a worktree |
# #1313 staleness: PASS on main+clean+up-to-date | FAIL on behind | FAIL on
# diverged (ahead-only and true divergence) | FAIL (closed) on no upstream |
# detached HEAD reports off_main without crashing | the --gh-report leg carries
# the SAME staleness guidance (both parse sites of the token string).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/hub-state-check.sh"

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

assert_not_contains() { # <haystack> <needle> <label>
  if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpectedly present: $2)"; else ok "$3"; fi
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

# #1313: each fixture gets an upstream, so the clean case is genuinely
# up-to-date AND the freshness fact is testable. The remote is named `upstream`
# (not `origin`) deliberately — case 8 below adds a fresh `origin` to exercise
# the repo-slug parse, and a bare name clash there would silently break it.
# Local bare paths: no network, fully hermetic.
for r in "$HUB" "$OTHER"; do
  bare="$FIX/$(basename "$r")-origin.git"
  git init -q --bare -b main "$bare"
  git -C "$r" remote add upstream "$bare"
  git -C "$r" push -qu upstream main
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
assert_contains "$out" "salvage <new-branch> $HUB" "dirty-on-main FAIL prints the #435 salvage step"
assert_contains "$out" "hub-worktree.sh salvage" "dirty-on-main FAIL prints salvage"
assert_not_contains "$out" "UNRECOGNISED disorder class" "plain dirty hub does not print an unrecognised-class line"
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
assert_contains "$out" "git push origin feat/incident" "off-main FAIL prints the WIP-preservation push"
assert_contains "$out" "git checkout main && git pull --ff-only" "off-main FAIL prints the return-to-main steps"
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

# #431 regression: FAIL without any FAIL_LINES (not-a-directory / not-a-git-repo
# / launchd-TCC git-EPERM) used to crash the report leg with an unbound-variable
# error on macOS bash 3.2 set -u. Must exit 1 cleanly with a loud warning and
# NO gh traffic (there is no repo-level line to report).
: > "$GH_STUB_LOG"
out="$(bash "$CHECK" --repo "$FIX/does-not-exist" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" "1" "no-line FAIL exits 1 (was unbound-variable crash)"
assert_contains "$out" "no repo-level FAIL_LINES" "no-line FAIL warns loudly"
if [ -s "$GH_STUB_LOG" ]; then bad "no-line FAIL: zero gh traffic"; else ok "no-line FAIL: zero gh traffic"; fi

# Same guard, second trigger: an existing dir that is NOT a git repo (git
# rev-parse --git-common-dir fails — the historical launchd-TCC EPERM shape).
mkdir -p "$FIX/not-a-git-repo"
: > "$GH_STUB_LOG"
out="$(bash "$CHECK" --repo "$FIX/not-a-git-repo" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" "1" "not-a-git-repo FAIL exits 1 (no crash)"
assert_contains "$out" "no repo-level FAIL_LINES" "not-a-git-repo path warns too"
if [ -s "$GH_STUB_LOG" ]; then bad "not-a-git-repo: zero gh traffic"; else ok "not-a-git-repo: zero gh traffic"; fi

rm -f "$GH_EXISTING"
git -C "$HUB" checkout -q main 2>/dev/null || true
rm -f "$HUB/untracked.txt"

# ── 9. Staleness (#1313): the tip vs its upstream ─────────────────────────
# A dedicated hub + bare remote so the earlier cases' state is untouched. The
# detector NEVER fetches (the session's freshness machinery owns that), so the
# fixture fetches into the stale hub itself. Remote named `upstream`; a fresh
# `origin` is added for the gh-report leg's slug parse.
SHUB="$FIX/stale-hub"
SREMOTE="$FIX/stale-origin.git"
git init -q --bare -b main "$SREMOTE"
git init -q -b main "$SHUB"
git -C "$SHUB" config user.email t@t
git -C "$SHUB" config user.name t
echo base > "$SHUB/base.txt"
git -C "$SHUB" add .
git -C "$SHUB" commit -qm init
git -C "$SHUB" remote add upstream "$SREMOTE"
git -C "$SHUB" push -qu upstream main
git -C "$SHUB" remote add origin "https://github.com/daniel-ospina/tortoise.git"

# 9a. clean + on main + UP-TO-DATE → PASS. Exercise the full matrix start here:
# a stale assertion must not be the only PASS case (a detector that reds a
# healthy hub is its own failure).
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "clean+on-main+up-to-date → exit 0"
assert_contains "$out" "PASS  $SHUB" "up-to-date hub prints PASS"
assert_contains "$out" "upstream=upstream/main" "PASS line names the verified upstream"

# Advance the remote, then fetch it INTO the hub (upstream/main moves; HEAD stays).
SCLONE="$FIX/stale-clone"
git clone -q "$SREMOTE" "$SCLONE"
git -C "$SCLONE" config user.email t@t
git -C "$SCLONE" config user.name t
echo upstream > "$SCLONE/upstream.txt"
git -C "$SCLONE" add .
git -C "$SCLONE" commit -qm upstream
git -C "$SCLONE" push -q origin main
git -C "$SHUB" fetch -q upstream main

# 9b. clean + on main + BEHIND → FAIL (exactly the pre-#1313 false PASS)
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "clean+on-main+behind → exit 1 (was PASS before #1313)"
assert_contains "$out" "FAIL  $SHUB" "behind prints FAIL"
assert_contains "$out" "HUB_DISORDER=behind" "behind → HUB_DISORDER=behind"
assert_contains "$out" "ahead=0 behind=1" "behind line names the counts"
assert_contains "$out" "git merge --ff-only upstream/main" "behind FAIL prints the fast-forward recovery (the resolved ref, not @{u})"

# 9b2. dirty + BEHIND → the --gh-report leg must reconstruct BOTH classes. This
# is the composed-token case: a suffix parse of `*dirty` misses the staleness
# token appended AFTER `dirty`, so the filed issue body would claim "clean" and
# drop the salvage step (#1324 review P1).
touch "$SHUB/wip.txt"
: > "$GH_STUB_LOG"
rm -f "$GH_EXISTING"
out="$(bash "$CHECK" --repo "$SHUB" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "dirty+behind+gh-report exits 1"
assert_contains "$out" "HUB_DISORDER=dirty+behind" "dirty+behind composes both tokens"
assert_contains "$(cat "$GH_STUB_LOG")" "hub-state FAIL: $SHUB (dirty+behind)" "issue title carries dirty+behind"
assert_contains "$(cat "$GH_STUB_LOG")" "dirty ON MAIN" "issue body keeps the dirty-on-main salvage guidance"
assert_contains "$(cat "$GH_STUB_LOG")" "also BEHIND" "issue body keeps the behind note"
rm -f "$SHUB/wip.txt"

# 9c. fast-forward the hub → PASS again (no false positive once healthy).
git -C "$SHUB" merge -q --ff-only upstream/main
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 0 "hub fast-forwarded to upstream → exit 0"
assert_contains "$out" "PASS  $SHUB" "up-to-date hub prints PASS again"

# 9d. local-only commit carrying content → not fast-forwardable → diverged
# (ahead-only sub-case; `diverged` is the local-only-commit class, and the
# emitted guide must offer a route for the CONTENT-CARRYING shape too — `refresh`
# alone refuses it).
echo local > "$SHUB/local.txt"
git -C "$SHUB" add .
git -C "$SHUB" commit -qm local-only
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "clean+on-main+ahead-only → exit 1"
assert_contains "$out" "HUB_DISORDER=diverged" "ahead-only → HUB_DISORDER=diverged (local-only commits)"
assert_contains "$out" "ahead=1 behind=0" "diverged line names the counts"

# 9e. remote advances too → true divergence → diverged, with the refresh recovery.
echo upstream2 > "$SCLONE/upstream2.txt"
git -C "$SCLONE" add .
git -C "$SCLONE" commit -qm upstream2
git -C "$SCLONE" push -q origin main
git -C "$SHUB" fetch -q upstream main
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "clean+on-main+diverged → exit 1"
assert_contains "$out" "HUB_DISORDER=diverged" "true divergence → HUB_DISORDER=diverged"
assert_contains "$out" "ahead=1 behind=1" "diverged line names both counts"
assert_contains "$out" "hub-worktree.sh refresh" "diverged FAIL names the #1309 refresh recovery"
assert_contains "$out" "refresh --discard-contentless" "diverged FAIL names the contentless flag"
assert_contains "$out" "CARRY content" "diverged FAIL names the content-carrying route"
assert_contains "$out" "git push upstream main:<new-branch>" "content-carrying route preserves the commits (on the RESOLVED remote)"
assert_contains "$out" "git reset --hard upstream/main" "content-carrying route realigns to the resolved upstream"
assert_contains "$out" "#1325" "non-origin diverged guide marks refresh's origin assumption (#1325)"
assert_contains "$out" "git log --name-only --diff-merges=combined upstream/main..HEAD" "diverged inspection mirrors refresh's combined content test"
assert_not_contains "$out" "log --stat" "diverged inspection does not use --stat (hides merge content)"

# 9f. The --gh-report leg parses the staleness token SEPARATELY (#1313: two
# parse sites). The filed issue body must carry the SAME diverged guidance — a
# token handled in only one place mis-fires here, silently.
: > "$GH_STUB_LOG"
rm -f "$GH_EXISTING"
out="$(bash "$CHECK" --repo "$SHUB" --gh-report 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "diverged+gh-report exits 1"
assert_contains "$out" "opened hub-state issue" "diverged+gh-report opens an issue"
assert_contains "$(cat "$GH_STUB_LOG")" "hub-state FAIL: $SHUB (diverged)" "issue title carries the diverged token"
assert_contains "$(cat "$GH_STUB_LOG")" "hub-worktree.sh refresh --discard-contentless --repo $SHUB" "issue body carries the diverged recovery guidance"
assert_contains "$(cat "$GH_STUB_LOG")" "#1325" "issue body marks refresh's origin assumption (#1325)"

# 9i. a MISTRACKED hub: branch.main's configured upstream names ANOTHER branch.
# The comparison must be against the SAME-NAMED tracking ref (origin/main), not
# `@{u}` — otherwise a hub arbitrarily behind mainline reports PASS, the exact
# false PASS #1313 closes (#1324 review P1; reproduced on a deployed hub).
MHUB="$FIX/mistracked-hub"
MREMOTE="$FIX/mistracked-origin.git"
git init -q --bare -b main "$MREMOTE"
git init -q -b main "$MHUB"
git -C "$MHUB" config user.email t@t
git -C "$MHUB" config user.name t
echo base > "$MHUB/base.txt"
git -C "$MHUB" add .
git -C "$MHUB" commit -qm init
git -C "$MHUB" remote add origin "$MREMOTE"
git -C "$MHUB" push -qu origin main
git -C "$MHUB" push -q origin main:feat/other
git -C "$MHUB" fetch -q origin
git -C "$MHUB" branch --set-upstream-to=origin/feat/other main >/dev/null 2>&1
# advance origin/main by one commit → the hub is genuinely behind mainline while
# `@{u}` (origin/feat/other) still points at the hub's own HEAD.
MSEED="$FIX/mistracked-seed"
git clone -q "$MREMOTE" "$MSEED"
git -C "$MSEED" config user.email t@t
git -C "$MSEED" config user.name t
echo next > "$MSEED/next.txt"
git -C "$MSEED" add .
git -C "$MSEED" commit -qm next
git -C "$MSEED" push -q origin main
git -C "$MHUB" fetch -q origin
out="$(bash "$CHECK" --repo "$MHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "mistracked-upstream hub → exit 1 (compares against the same-named ref)"
assert_contains "$out" "HUB_DISORDER=behind" "mistracked-upstream hub reports behind mainline"
assert_contains "$out" "upstream=origin/main" "the reference of record is origin/main, not @{u}"

# 9j. `@{u}` naming a LOCAL branch (`wip/main`) shares the branch's basename, so
# a basename guard would TRUST it and compare the hub against itself — PASS while
# arbitrarily behind mainline (#1324 review P1, residual shape). Config is
# `branch.main.remote=.` here, so the fix falls back to origin/main.
LHUB="$FIX/local-track-hub"
LREMOTE="$FIX/local-track-origin.git"
git init -q --bare -b main "$LREMOTE"
git init -q -b main "$LHUB"
git -C "$LHUB" config user.email t@t
git -C "$LHUB" config user.name t
echo base > "$LHUB/base.txt"
git -C "$LHUB" add .
git -C "$LHUB" commit -qm init
git -C "$LHUB" remote add origin "$LREMOTE"
git -C "$LHUB" push -qu origin main
git -C "$LHUB" branch wip/main
git -C "$LHUB" branch --set-upstream-to=wip/main main >/dev/null 2>&1
LSEED="$FIX/local-track-seed"
git clone -q "$LREMOTE" "$LSEED"
git -C "$LSEED" config user.email t@t
git -C "$LSEED" config user.name t
echo next > "$LSEED/next.txt"
git -C "$LSEED" add .
git -C "$LSEED" commit -qm next
git -C "$LSEED" push -q origin main
git -C "$LHUB" fetch -q origin
out="$(bash "$CHECK" --repo "$LHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "local-branch upstream hub → exit 1 (never compared against itself)"
assert_contains "$out" "HUB_DISORDER=behind" "local-branch upstream hub reports behind mainline"
assert_contains "$out" "upstream=origin/main" "local-branch upstream falls back to origin/main"

# 9k. a remote whose NAME contains '/' (`fork/origin`), MISTRACKED: splitting
# `@{u}` on the first '/' would derive `fork`, find no `fork/main`/`origin/main`,
# and wrongly report `no_upstream` — a false FAIL on a hub whose same-named
# tracking ref is present. The remote is read from
# `branch.<branch>.remote` instead, so `fork/origin/main` resolves.
KHUB="$FIX/slash-remote-hub"
KREMOTE="$FIX/slash-remote-origin.git"
git init -q --bare -b main "$KREMOTE"
git init -q -b main "$KHUB"
git -C "$KHUB" config user.email t@t
git -C "$KHUB" config user.name t
echo base > "$KHUB/base.txt"
git -C "$KHUB" add .
git -C "$KHUB" commit -qm init
git -C "$KHUB" remote add fork/origin "$KREMOTE"
git -C "$KHUB" push -qu fork/origin main
git -C "$KHUB" push -q fork/origin main:feat/other
git -C "$KHUB" fetch -q fork/origin
git -C "$KHUB" branch --set-upstream-to=fork/origin/feat/other main >/dev/null 2>&1
KSEED="$FIX/slash-remote-seed"
git clone -q "$KREMOTE" "$KSEED"
git -C "$KSEED" config user.email t@t
git -C "$KSEED" config user.name t
echo next > "$KSEED/next.txt"
git -C "$KSEED" add .
git -C "$KSEED" commit -qm next
git -C "$KSEED" push -q origin main
git -C "$KHUB" fetch -q fork/origin
out="$(bash "$CHECK" --repo "$KHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "slash-named-remote mistracked hub → exit 1 (not no_upstream)"
assert_contains "$out" "HUB_DISORDER=behind" "slash-named remote reports behind, not no_upstream"
assert_contains "$out" "upstream=fork/origin/main" "slash-named remote resolves its own same-named ref"

# 9g. no upstream configured → FAIL CLOSED. An unverifiable hub must never read
# as PASS (that is the failure direction #1313 exists to close).
NOUP="$FIX/no-upstream-hub"
git init -q -b main "$NOUP"
git -C "$NOUP" config user.email t@t
git -C "$NOUP" config user.name t
echo x > "$NOUP/x.txt"
git -C "$NOUP" add .
git -C "$NOUP" commit -qm init
out="$(bash "$CHECK" --repo "$NOUP" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "clean+on-main+no upstream → exit 1 (fail closed)"
assert_contains "$out" "HUB_DISORDER=no_upstream" "no upstream → HUB_DISORDER=no_upstream"
assert_contains "$out" "UNVERIFIABLE" "no-upstream FAIL says freshness is unverifiable"
assert_contains "$out" "git -C $NOUP remote -v" "no-upstream guidance names the remote instead of presuming origin"

# 9h. detached HEAD must not crash: reported as off_main (no upstream to compare).
git -C "$SHUB" checkout -q --detach HEAD
out="$(bash "$CHECK" --repo "$SHUB" 2>&1)" && rc=0 || rc=$?
assert_eq "$rc" 1 "detached HEAD → exit 1 (no crash)"
assert_contains "$out" "HUB_DISORDER=off_main" "detached HEAD → HUB_DISORDER=off_main"
assert_contains "$out" "The hub is detached." "detached HEAD prints the detached recovery guidance"
git -C "$SHUB" checkout -q main

echo ""
echo "hub-state-check.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
