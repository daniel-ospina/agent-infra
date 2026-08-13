# Issue #210 — Research

- **Status:** IMPLEMENTED
- **Branch:** feat/210-merge-base-fix
- **Date:** 2026-08-12
- **Level:** task | **Complexity:** micro | **Team:** organisation-design-team

## 1. Bug confirmed

`\bgit\s+merge\b` matches `git merge-base` because the hyphen is a non-word
char → word boundary. Verified on current code:

```js
node -e "const {classifyGitCommand}=await import('./extensions/main-worktree-guard/classify-git.mjs'); console.log(classifyGitCommand('git merge-base --is-ancestor a b'));"
// → block:merge   ❌ FALSE POSITIVE
```

Full current behavior:

```
git merge-base --is-ancestor a b → block:merge   (BUG — read-only, must be allow)
git merge origin/main            → block:merge   (correct)
git merge --ff-only              → block:merge   (correct)
git merge                        → block:merge   (correct)
git merge-base a b               → block:merge   (BUG — read-only, must be allow)
```

Incident: 2026-08-11 read-only ancestor check blocked → nested-pi detour hung 29h.

## 2. The pattern line

`extensions/main-worktree-guard/classify-git.mjs`, line 25:

```js
{ name: "merge", re: /\bgit\s+merge\b/ },
```

Classify loop (first match wins — no re-negotiation after the merge line):

```js
for (const { name, re } of DESTRUCTIVE_GIT_PATTERNS) {
  if (re.test(c)) return `block:${name}`;
}
return "allow";
```

## 3. Sibling false-positives (hyphen = word boundary)

```
git checkout-index file → allow          (checkout-branch has (?!-\w) — already safe)
git checkout-tree x    → allow           (same)
git switch-branch      → allow           (same)
git switch-tree        → allow           (same)
git restore-file       → block:restore   ⚠️ false positive (no real `git restore-*` subcommand)
git clean-index        → block:clean     ⚠️ false positive (no real `git clean-*` subcommand)
git reset-soft         → block:reset     ⚠️ false positive (no real `git reset-*` subcommand; real form is `git reset --soft`)
git pull-request       → block:pull      ⚠️ false positive (no real `git pull-*` subcommand in git itself)
git rebase-onto        → block:rebase    ⚠️ false positive (no real `git rebase-*` subcommand)
git merge-ours         → block:merge     ⚠️ false positive — SAME regex as merge → fixed by this issue's one-line change
```

Real-world exposure: the ONLY real git subcommands hit are the `merge-*` plumbing
family, which share the merge regex and are all read-only → the single merge fix
covers them (trivially in the same regex, per scope rule). The other siblings
(restore/clean/reset/pull/rebase + `-word`) only match non-existent git
subcommands → **OUT OF SCOPE**, report only.

## 4. Read-only merge-* subcommands (git 2.50.1, `git help -a` — six: merge-base, merge-file, merge-index, merge-msg, merge-one-file, merge-tree)

| subcommand | read-only? |
|---|---|
| `git merge-base` | ✅ read-only (ancestry queries: --is-ancestor, --independent, --fork-point) |
| `git merge-tree` | ✅ read-only (performs merge without touching index or working tree; --write-tree only writes objects to the object DB, like commit) |
| `git merge-file` | ✅ read-only re: branches (three-way merge of file args, result to a file path — same class as allowed `git checkout -- <path>`) |
| `git merge-index` | ✅ read-only (runs a merge program for each file needing merge) |
| `git merge-msg` | ✅ read-only re: branches (writes only the merge message file — no branch or worktree mutation) |
| `git merge-one-file` | ✅ read-only re: branches (writes only the file(s) being merged, same class as `git checkout -- <path>`) |

None move branches or clobber the working tree (the guard's threat model).
`git mergetool` is never matched: `merge\b` fails before `tool` — and the FINAL
regex keeps the `\b` (§5), so it stays allow. A draft `(?!-)`-without-`\b` form
would have wrongly blocked it (round-3 finding F1).

## 5. Fix shape (verified)

Replacement for the merge pattern — KEEP the trailing `\b` (round-3 fix F1):

```js
{ name: "merge", re: /\bgit\s+merge\b(?!-)/ },
```

Negative lookahead `(?!-)` — all `merge-*` subcommands are read-only plumbing, so
excluding the hyphen covers merge-base/merge-tree/merge-file/merge-index/merge-msg/merge-one-file
in one change. The trailing `\b` MUST stay: dropping it (draft `/\bgit\s+merge(?!-)/`)
lets any word starting "merge" match — `git mergetool` passes `(?!-)` (next char
't' is not '-') → wrongly `block:merge`. With `\b` kept, `(?!-)` only excludes
the real `merge-*` plumbing. Verified through the FULL patched classify path (no
other pattern re-blocks; checkout-branch requires `checkout|switch`):

```
git merge-base --is-ancestor a b → allow
git merge origin/main            → block:merge   (existing case, sanity)
git merge                        → block:merge
git merge --ff-only              → block:merge
git merge-tree                   → allow
git merge-file a b c             → allow
git merge-index -a               → allow
git merge-one-file a b c         → allow
git merge-msg                    → allow
git mergetool                    → allow   (F1 — draft regex wrongly blocked this)
git merge;git push               → block:merge   (compound preserved — F2)
```

40/40 regression sweep (all 29 existing classify cases + 11 new: 9 committed
additions [§6] + 2 manual probes — `git mergetool`, `git merge-msg`) — green.

Note: issue title suggests `(?:\s|$)` ("space/EOL"); it passes the plumbing-allow
cases but silently allows no-space compound forms (`git merge;git push`,
`git merge&&git push` — the `&&` form also verified `block:merge`), so it would
fail the committed compound guard (§6, F2). `(?!-)` is strictly more
conservative — same fix, no compound gap. Recommend `(?!-)`.

## 6. Test additions (extensions/main-worktree-guard/test.mjs)

Harness: `expect(name, command, expected)` → `classifyGitCommand(command)`.
Current suite: **65 passed, 0 failed** (baseline run). Add after the existing
`expect("merge", "git merge origin/main", "block:merge")`:

```js
// Issue #210 — read-only merge-* plumbing must classify as allow
expect("merge-base --is-ancestor", "git merge-base --is-ancestor a b", "allow");
expect("merge-base", "git merge-base a b", "allow");
expect("merge-tree", "git merge-tree", "allow");
expect("merge-file", "git merge-file a b c", "allow");
expect("merge-index", "git merge-index -a", "allow");
expect("merge-one-file", "git merge-one-file a b c", "allow");
// regression guard — real merges still block
expect("bare merge", "git merge", "block:merge");
expect("merge --ff-only", "git merge --ff-only", "block:merge");
// compound-form differentiator (F2) — (?!-) must block no-space compounds;
// the (?:\s|$) alternative would silently allow these
expect("merge; push compound", "git merge;git push", "block:merge");
```

→ 65 + 9 = **74 cases, target green**.

## Verification Fixes (round 3)

| Round-3 fix (one row) | Applied |
|---|---|
| full-diamond verifier findings F1–F5 | F1: merge regex → `/\bgit\s+merge\b(?!-)/` (kept `\b`; `git mergetool` → allow); F2: compound guard `git merge;git push` added to §6 test plan; F3: `git merge-msg` added to §4 read-only table; F4: 40/40 sweep reconciled — 11 new = 9 committed additions + 2 manual probes (`git mergetool`, `git merge-msg`); F5: merge-one-file label softened to "read-only re: branches" |

Verified node -e outputs (simulated patched classify path — fix not yet implemented, only the merge pattern swapped):

```
git merge-base --is-ancestor a b -> allow
git merge origin/main            -> block:merge
git merge                        -> block:merge
git merge --ff-only              -> block:merge
git merge-tree                   -> allow
git merge-file a b c             -> allow
git merge-index -a               -> allow
git merge-one-file a b c         -> allow
git merge-msg                    -> allow
git mergetool                    -> allow
git merge;git push               -> block:merge
git merge&&git push              -> block:merge
```

Rationale probe (why the `\b` matters):

```
draft /\bgit\s+merge(?!-)/  matches "git mergetool": true  (WRONG -> block:merge)
fixed /\bgit\s+merge\b(?!-)/ matches "git mergetool": false (correct -> allow)
```
