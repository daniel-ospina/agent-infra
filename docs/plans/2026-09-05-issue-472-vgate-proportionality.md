---
title: "Plan: #472 — verification-gate proportionality (content-shape VGATE exemption + delete-push short-circuit)"
type: engineering
domain: operations
doc_status: draft
subjects.team: epistemic-team
created: 2026-09-05
aboutSubjects: epistemic-team
aboutObjects: agent-infra, issue-472, verification-gate, commit-workflow
---

<!-- research-path: none — root cause pinned in extensions/verification-gate/index.ts (zero tier awareness verified; GIT_COMMIT_PATTERN :324 folds push into commit pattern; non-PR branch computes whole-index staged diff) + live repros #470/#472 + docs/scoping/2026-09-05-issue-472-vgate-proportionality.md -->

# fix(verification-gate): proportionality — content-shape VGATE exemption (docs/CSS/static) + delete-push short-circuit

**Goal:** Honor the proportionality contract 01-preflight.md documents but the extension never ships: (a) ops whose relevant file set is entirely docs/CSS/static (no build-output paths) skip VGATE — tier-independent, content shape decides, matching 02-commit-pr.md Step 1.5's Micro content class; (b) delete-shaped pushes (`git push origin --delete X` etc.) ship no local content and must not trigger a whole-index staged-diff check over other sessions' parked WIP (the #470 cleanup block).

**Team:** epistemic-team
**Issue:** #472 (complexity:standard, Level: project)
**Status:** verified (plan-review ×4 clean)

**Architecture:** Two independent mechanisms inside the existing tool_call handler of `extensions/verification-gate/index.ts`, both additive early-return skips mirroring the file's own #204 merge-scope idiom (pure predicate + hook + `gate_skip` audit + `return undefined`). Mechanism (a) — content-shape exemption: ops whose entire relevant file set is docs/CSS/static (`.md|.css|.scss|.html`, no `public/|dist/|build/` path segment) skip VGATE **allow-only** (no verifiedSet/bridge writes — registry stays verifier-authoritative). Mechanism (b) — delete-push classification: whole-command purity check (∃ deletion marker + remote; per-segment gate-verb classes only) short-circuits before diff computation. The unverified loop, #7591 auto-bypass, #825/#264 sub-agent block semantics, and the tool_result handler stay byte-identical. Doc correction of `01-preflight.md` as one consistent unit + a drift test pinning the doc fence to the extension constants.

### Pattern Research

> **Findings date:** 2026-09-05

> Gate skipped: plan touches zero third-party deps — pure extension-internal logic (node:path + existing helpers only) + one skill doc. All behavior grounded in in-repo precedent: #204 merge-scope skip idiom (index.ts:1101-1107), review-enforcer micro warn-only marker (review-enforcer/index.ts:57,785-799), 02-commit-pr.md Step 1.5 content class (line 71). External research not demonstrated (org-infra internal change; issue says Research: none).

### Integration Surface Map

| Surface | Boundary | Test Layer | Failure Mode |
|---------|----------|-----------|--------------|
| tool_call git-op check (commit/push staged diff) | changedFiles vs shape predicate | unit (pure) + e2e (mounted, temp repo) | docs-only commit blocked (defect a) |
| tool_call git-op check (push delete) | isDeletionPush purity | unit (pure) + e2e (parked WIP repro) | delete-push blocked over unrelated WIP (defect b) |
| verifiedSet / bridge | allow-only skip → no NEW entries from the skipped op (a delete-push after an ALLOWED commit still runs the pendingRehash block which re-hashes + writes the bridge for the PRIOR commit — content-neutral, no new blessings; a bare (a)-exempt docs COMMIT arms pendingRehash for the next op — arming writes nothing and the consume only refreshes entries already in verifiedSet, so no NEW keys are ever created by the exempt path) | e2e audit assertions | registry contaminated by shape exemption (#190) |
| 01-preflight.md contract | VGATE-SHAPE-RULE fence ↔ SHAPE_EXEMPT_EXTENSIONS | drift test (existsSync-guarded) | doc↔extension drift recurs (defect-a class) |
| sub-agent block semantics (#825/#264) | hooks must not reorder | e2e 35-37 unchanged + new child docs commit | regression to hard-won child no-bypass |

**Bug pattern flags:** vacuous-truth on bare `git push` (require ∃ marker); quote-mask vs strip (content-preserving strip for refspec tokens); redirect tokens as refspecs (drop); scaffolding segments flipping purity (per-segment gate-verb classes only).

### Verification Plan

Unit (`npx tsx index.test.ts` from extension dir): existing 173 + new sections → all green (196 total at final state — test-review gate added exact-segment boundary pins + a 05-cleanup fixture drift guard). E2E (`npx tsx index.e2e.test.ts`): existing 39 + scenarios 38-47 (incl. 39b; scenario 47 = mechanism-(a) push half, added by the test-review gate) → all green (50 total). No integration/DB surfaces. No typecheck (no tsconfig in agent-infra; suites are the compile gate). CI: ci-main.yml extension-tests job runs unit via the failure accumulator pattern; e2e suite is the primary regression surface per issue Verification Checklist.

**Tech Stack:** TypeScript, pi extension API (`@earendil-works/pi-coding-agent` 0.84.x), node:path.

---

## Design Decisions

**D1 — Content-shape exemption is ALLOW-ONLY (no self-bless).** Pure-docs ops skip VGATE by shape; the registry is never written on the skip path. Consequence: a mixed docs+code op verifies EVERYTHING fresh exactly as today (one [VGATE] dispatch covers the blocked set — no regression vs baseline). Rationale: registry stays verifier-authoritative-only (#190/#38), zero bridge contamination, no pendingRehash staleness interaction, no perverse incentive (staging docs to dodge code verification fails — the code commit itself still blocks). Rejected: self-blessing into verifiedSet (solution-verify cycle-1 P2: cross-session bridge contamination + dual-semantics registry).

**D2 — Commit-form guard.** The shape exemption requires EVERY `git commit` invocation in the op to be bare (no `-a`/`--all`/pathspec); non-commit gated ops (push / `gh pr create`/merge) qualify on file shape alone — the guard is vacuously satisfied when no commit invocation exists (e2e scenarios 39/39b/47). `git commit -a` with staged docs + dirty code must NOT be newly permissive — keeps the pre-existing `-a` invisible-dirty-code hole unwidened (filed as follow-up #5). Push-form shape exemption relies on falsification item (3) — index is empty post-commit; HEAD content was gated at commit time.

**D3 — Build-output denylist applies to ALL FOUR extensions, any path depth.** Generated output is not static content regardless of extension (`dist/README.md`, `build/*.css` are build products just like `public/index.html`). Uniform rule = narrower exemption (more files stay gated) = fail-closed; simpler to state in the doc fence and drift-test.

**D4 — Delete-push classifier requires an explicit ∃-deletion-marker + remote.** Bare `git push` / `git push origin` are NOT pure (vacuous truth guard) — they fall back to today's whole-index gating. Forms included: `--delete X` (either position), `-d`, `:refspec`. `--prune`/`--mirror` excluded (state-mirroring, not per-arg deletion) → gated. Any other flag, second remote, content refspec, chained content push, `git commit`, or `gh pr create|merge` anywhere → not pure → gated.

**D5 — Per-segment verb-class purity.** Purity flips FALSE only on segments whose first verb is in the gate's own classes (`git commit|push`, `gh pr create|merge`). Scaffolding segments (assignments, `gh pr view`, `git branch -D`, comments, `if/fi`, `$(…)`) are ignored — they can only ADD segments that don't flip purity, never flip a content push pure. Pins the literal 05-cleanup merged-branch cleanup fenced block (05-cleanup.md:36-54) as a TRUE fixture.

**D6 — Quote handling: mask for separator scanning, strip for tokenization.** Separator scan masks quoted regions (prose `"git push origin main"` never splits); tokenization strips quotes so `git push origin "main"` (quoted content refspec) classifies as content → gated, while `--delete "$BRANCH"` (quoted delete target) classifies pure. Redirect tokens (`2>/dev/null`, `2>&1`, `>file`) are DROPPED anywhere in the push segment (never terminators — terminating would false-open `git push origin >log main`).

**D7 — Doc correction = ONE consistent unit in 01-preflight.md.** All VGATE/review-enforcer contract statements corrected together: micro-table VGATE row removed → pointer to shape rule; Review-enforcer row → warn-only reality; "Pi Extension Gates (mandatory — not tier-gated)" section retitled + corrected; micro auto-detect clause reconciled; mechanism-separation sentence; VGATE-SHAPE-RULE machine-readable fence; Test-Review backstop tier annotation. Drift test in index.test.ts reads the fence (existsSync-guarded for deployed copies).

---

## Tasks

### Task 1: RED — pure-predicate unit tests + stub exports

**Intent:** Pin the new behavior contracts before implementation (TDD red): the shape predicate, the deletion classifier (incl. vacuous-truth and ceremony-literal cases), and the doc↔extension drift test.
**Acceptance:** index.ts exports stub `SHAPE_EXEMPT_EXTENSIONS = []`, `BUILD_OUTPUT_SEGMENTS = []`, `isShapeExemptFile = () => false`, `isDeletionPush = () => false`, `isBareCommitShape = () => true`; index.test.ts imports them; the new test sections FAIL (only the new tests fail; existing 173 pass).
**Files:**
- Modify: `extensions/verification-gate/index.ts` (stub exports only)
- Modify: `extensions/verification-gate/index.test.ts`
- Test: `extensions/verification-gate/index.test.ts`

**Step 1:** Add stub exports to `extensions/verification-gate/index.ts` in a new section after `isGitCommit` (:339): `export const SHAPE_EXEMPT_EXTENSIONS: readonly string[] = []; export const BUILD_OUTPUT_SEGMENTS: readonly string[] = []; export function isShapeExemptFile(_p: string): boolean { return false; } export function isDeletionPush(_c: string): boolean { return false; } export function isBareCommitShape(_c: string): boolean { return true; }` (isBareCommitShape is a pure helper like the others — RED-pinned in Task 1 so the commit-form guard (D2) is tested before GREEN).

**Step 2:** Extend the import list in `extensions/verification-gate/index.test.ts` (:10) with the FIVE new names (`SHAPE_EXEMPT_EXTENSIONS`, `BUILD_OUTPUT_SEGMENTS`, `isShapeExemptFile`, `isDeletionPush`, `isBareCommitShape`).

**Step 3:** Append new sections to `extensions/verification-gate/index.test.ts` before the final tally (~:1294):

Section `isShapeExemptFile — content-shape exemption (#472 mechanism a)`:
- `docs/README.md` → true; `README.md` → true; `MEMORY.md` → true; `docs/research/x.md` → true; `website/index.html` → true; `docs/guides/index.html` → true; `theme.css` → true; `theme.scss` → true.
- `public/index.html` → false (build template); `dist/bundle.css` → false; `build/out.css` → false; `website/public/index.html` → false (nested segment); `public/README.md` → false (denylist covers all four exts, D3); `assets/build/x.md` → false.
- `src/app.ts` → false; `Dockerfile` → false (no ext); `LICENSE` → false; `package.json` → false; `supabase/migrations/x.sql` → false; `` (empty) → false.
- Case-variant pins (macOS default FS is case-insensitive — lowercase before comparing): `Public/index.html` → false; `DIST/bundle.css` → false; `docs/README.md` → true; `README.MD` → true.

Section `isDeletionPush — delete-shaped push classification (#472 mechanism b)`:
- TRUE: `git push origin --delete feat/x`; `git push --delete origin feat/x`; `git push origin :feat/x`; `git push origin :refs/heads/feat/x`; `git push -d origin feat/x`; `git push origin --delete a b c`; incident literal `git push origin --delete "$BRANCH" 2>/dev/null \\\n  || echo "remote branch $BRANCH already deleted"`; `cd /repo && git push origin --delete feat/x`; `git push origin :feat/x 2>/dev/null || true`.
- FALSE (vacuous-truth + content): `git push`; `git push origin`; `git push origin main`; `git push -u origin x`; `git push --force-with-lease origin main`; `git push origin main --delete foo` (mixed); `git push origin --delete a && git push origin main` (chain); `git push origin --delete a & git push origin main` (single-& background — the content push after & must NOT be absorbed); `git commit -m x && git push origin --delete foo`; `git push --tags`; `git push --all`; `git push --mirror origin`; `git push origin --delete` (no target after remote — actually false: no deletion marker value... see note); `git push origin "main"` (quoted content refspec, D6); `gh -R daniel-ospina/agent-infra pr merge 5 && git push origin --delete foo` (gh merge with global flag — must not short-circuit to allow, #204 pre-emption guard).
- Prefix-verb pins (classifier flip surface >= interception surface): `sudo git push origin main` → false (content); `env GIT_DIR=. git push origin main` → false; `nohup git push origin main` → false; `sudo git push origin --delete feat/x` → true (prefix stripped, pure deletion).
- Wrapper containment pins (fail-closed — substring scan): `sh -c 'git push origin main'` → false (wrapper push, cannot prove pure); `sh -c 'git commit -am x' && git push origin --delete foo` → false (wrapper commit inside); `! git commit -am x && git push origin --delete foo` → false; `! gh pr merge 5 && git push origin --delete foo` → false (wrapper merge — #204 pre-emption guard); `! git push origin --delete foo` → false (negation not provably a deletion — fail-closed); `GIT_SSH_COMMAND="ssh -o BatchMode=yes" git push origin --delete foo` → false (quoted env value not provably pure — fail-closed; documented known over-gate, do NOT "fix" without reopening the analysis).
- Non-interception pins: `git branch -D feat/x` → isDeletionPush false AND isGitOp false; `git worktree remove feat/x` → both false; `gh pr view 5` → isDeletionPush false.
- 04-merge-deploy.md Step B literal (second ceremony fixture, TRUE — copied VERBATIM from 04-merge-deploy.md:91): `git push origin --delete "$PR_BRANCH" 2>&1 || echo "⚠️ remote delete failed — delete manually: gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/$PR_BRANCH"` — exercises `2>&1` redirect drop, emoji + `gh api` prose in the echo (quote-masked scaffolding; `gh api` is NOT `gh pr create|merge` so it never flips purity), `$PR_BRANCH` quote-strip.

Section `isBareCommitShape — commit-form guard (#472 D2, FORALL semantics, fail-closed whitelist)`:
- BARE → true: `git commit -m x`; `git commit -m x -s` (signoff boolean); `git commit -S -m x` (sign boolean); `git commit --message x` (long value flag); `git commit -F msg.txt`; `cd /repo && git commit -m x` (cd-prefix stripped); `git push origin main` (non-commit — guard vacuously satisfied).
- NON-BARE → false: `git commit -am "x"` (sweep); `git commit -am"x"` (attached sweep — the cycle-3 P1 repro); `git commit -amx`; `git commit --all -m x`; `git commit -m x path/to/file` (pathspec); `git commit --amend -m x`; `git commit -o code.ts -m x` (only-mode); `git commit -m x --only` ; `git commit -mx` (attached-value spelling — rejected fail-closed); `git commit -a` .
- **∀-discriminating pins:** `git commit -am x && git commit -m y` → false (ANY non-bare commit poisons the whole command); `git commit -m x && git commit --amend -m y` → false; `git commit -m x && git commit -m y` → true (all bare).
- Wrapper containment pins (fail-closed — substring scan): `sh -c 'git commit -am x'` → false; `! git commit -am x` → false; `sudo -u me git commit -am x` → false; `bash -c 'git commit -m x'` → false (wrapper form not provably bare → VGATE runs).
- Fenced-block literal (TRUE fixture): the full 05-cleanup.md:36-54 fenced block verbatim (opening fence :36, code :37-53: assignments, `[ -n "$BRANCH" ] || BRANCH=$(gh pr view …)`, delete push with `2>/dev/null` + backslash continuation, `|| echo …`, if/fi with `git worktree list` + `git branch -D "$BRANCH"`; closing fence :54).
- Note on `git push origin --delete` (no target): git errors at runtime but the classifier must not allow — treat as false (no deletion target accumulated). Pin it false.

**Step 4:** Run: `npx tsx index.test.ts` — expect ~173 pass + the new TRUE-case assertions FAIL (against the false-returning stubs, FALSE-case pins pass vacuously; `isBareCommitShape = () => true` makes its FALSE-case pins fail). Confirm no pre-existing test fails and only the new sections' failures appear.
**Test granularity (normative):** one `test()` per assertion BULLET in the new sections (each bullet = one test with 1-3 `ok`/`equal` asserts), table-driven where convenient. No exact total is mandated — acceptance is "existing 173 intact + every new section's assertions present and green". Do NOT chase a specific pass count.

### Task 2: GREEN — implement both mechanisms

**Intent:** Implement the two predicates + the two additive hooks so all new unit tests pass.
**Acceptance:** index.test.ts fully green (existing 173 intact, 0 failed — every new section's assertions present and passing; exact total not mandated, see Task 1 Step 4 granularity note); index.ts exports the real `SHAPE_EXEMPT_EXTENSIONS = [".md",".css",".scss",".html"]`, `BUILD_OUTPUT_SEGMENTS = ["public","dist","build"]`, working `isShapeExemptFile`, `isDeletionPush`, `isBareCommitShape`; both hooks in place; no reordering of existing logic.
**Files:**
- Modify: `extensions/verification-gate/index.ts`
- Test: `extensions/verification-gate/index.test.ts`

**Step 1:** Add `extname` to the node:path import (:4 — the `import { relative, resolve, isAbsolute, join, dirname, basename } from "node:path"` line).

**Step 2:** Replace stubs with the real predicates (new module-level section after `isGitCommit` ~:339), per D3-D6:

```ts
// ── Content-shape exemption (#472 mechanism a) ───────
// Single source for the doc contract (01-preflight.md VGATE-SHAPE-RULE fence —
// index.test.ts drift test keeps the two in sync). Docs/CSS/static classes are
// exempt; ANY file under a build-output segment (public/ dist/ build/, any
// depth) is a GENERATED artifact and stays gated. Fail-closed: the class list
// is CLOSED — every other extension (and extension-less files: Dockerfile,
// LICENSE) keeps the gate ON. Case-insensitive match (path lowercased first —
// macOS default FS is case-insensitive); the doc fence tokens are lowercase
// (02-commit-pr.md Step 1.5), so lowercasing never diverges from them.
// Exact-segment match: `build-guide/` is NOT
// `build/` and stays exempt.
export const SHAPE_EXEMPT_EXTENSIONS: readonly string[] = [".md", ".css", ".scss", ".html"];
export const BUILD_OUTPUT_SEGMENTS: readonly string[] = ["public", "dist", "build"];

export function isShapeExemptFile(repoRelativePath: string): boolean {
  const lower = repoRelativePath.toLowerCase(); // macOS default FS is case-insensitive; repo path case is not normalized by git
  if (!SHAPE_EXEMPT_EXTENSIONS.includes(extname(lower))) return false;
  for (const segment of lower.split("/")) {
    if (BUILD_OUTPUT_SEGMENTS.includes(segment)) return false;
  }
  return true;
}
```

**Step 3:** Add the command-segmentation + deletion-classifier helpers (module level, after the merge helpers ~:500), per D4-D6:

```ts
// ── Delete-shaped push classification (#472 mechanism b) ──
// A remote-ref deletion (`git push origin --delete X` / `git push --delete
// origin X` / `git push origin :X`) ships NO local file content — a staged-diff
// check over a zero-byte deletion inspects the ENTIRE index and blocks on other
// sessions' parked WIP (the #470 cleanup incident). WHOLE-COMMAND purity:
// fires only when EVERY gated op in the command is a delete-shaped push; any
// content refspec, git commit, or gh pr create|merge anywhere falls back to
// today's gating (fail-closed).
//
// Deliberately narrower than a full bash lexer: the regex layer holding #5571
// heredoc / #204 prose edge cases is untouched; only this predicate parses, and
// only push-shaped segments it can prove pure.

// Quote-aware top-level split on real separators (&& || ; | \n AND single &
// — bash background operator: `a & git push origin main` backgrounds the first
// op and runs the content push; a single & can never appear inside a
// legitimate unquoted token, so flushing on it is safe and closes the
// fail-open where the content push after & was absorbed as a delete target).
// EXCEPTIONS (redirect syntax, NOT backgrounding): `&>` (ch followed by >) and
// `>&` (ch preceded by >, as in 2>&1) are redirects — no flush there; the
// redirect token is dropped later. Separators inside quotes are prose and never
// split. Backslash-newline continuations are joined BEFORE splitting so the
// 05-cleanup literal `…2>/dev/null \` + newline + `|| echo …` yields one push
// segment + one non-gated echo segment.
function splitCommandSegments(command: string): string[] {
  const joined = command.replace(/\\\n/g, " ");
  const segments: string[] = [];
  let cur = "";
  let quote: string | null = null;
  const flush = () => { if (cur.trim()) { segments.push(cur); cur = ""; } };
  for (let i = 0; i < joined.length; i++) {
    const ch = joined[i];
    if (quote !== null) {
      cur += ch;
      if (ch === "\\" && i + 1 < joined.length) { cur += joined[++i]; continue; }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; cur += ch; continue; }
    if (ch === "\n") { flush(); continue; }
    if ((ch === "&" || ch === "|") && joined[i + 1] === ch) { flush(); i++; continue; } // && ||
    if (ch === "&" && joined[i + 1] === ">") { cur += ch; continue; } // &> redirect
    if (ch === "&" && i > 0 && joined[i - 1] === ">") { cur += ch; continue; } // >& redirect (2>&1)
    if (ch === ";" || ch === "|" || ch === "&") { flush(); continue; } // ; | single-& background
    cur += ch;
  }
  flush();
  return segments;
}

// Strip cd/&& prefixes, inline env assignments, and command-prefix verbs
// (sudo/env/nohup/time/command) from a segment head — so a prefix-verb form the
// extension's interception patterns would still match (`sudo git push origin
// main`, `nohup git commit`) classifies identically to the bare form instead of
// being mis-treated as scaffolding (classifier flip surface >= interception
// surface). Loop until stable (cd chains + env + prefix verbs may combine).
function stripSegmentHead(segment: string): string {
  let s = segment.trim();
  for (let i = 0; i < 5; i++) {
    const next = s
      .replace(/^(?:cd\s+(?:['"][^'"]+['"]|[^\s;&|]+)\s*&&\s*)+/i, "")
      .replace(/^(?:(?:env|sudo|nohup|time|command)\s+)+/, "")
      .replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)+/, "");
    if (next === s) break;
    s = next;
  }
  return s;
}

// Quote-aware tokenizer for a push segment's argument text: keeps quoted
// values ("$BRANCH") as ONE token; strips the quote characters (D6).
function tokenizePushArgs(text: string): string[] {
  const tokens: string[] = [];
  let cur = "";
  let quote: string | null = null;
  const flush = () => { if (cur.length > 0) { tokens.push(cur); cur = ""; } };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quote !== null) {
      if (ch === "\\" && i + 1 < text.length) { cur += text[++i]; continue; }
      if (ch === quote) { quote = null; flush(); continue; }
      cur += ch;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; continue; }
    if (/\s/.test(ch)) { flush(); continue; }
    cur += ch;
  }
  flush();
  return tokens;
}

// Shell redirection token (2>/dev/null, 2>&1, >file, >>file). DROPPED
// anywhere in a push segment — a redirect is never a boundary and never a
// refspec (terminating on one would false-open `git push origin >log main`).
function isRedirectToken(token: string): boolean {
  return /^(?:\d+)?(?:>>?|<<?|&>|>&)/.test(token);
}

// True when segment is `git push` whose args are a remote PLUS deletion forms
// ONLY. Requires an explicit ∃-deletion marker (D4) — bare `git push origin`
// (no marker) is NOT pure (vacuous-truth guard). Any other flag (-f/-u/-u/
// --tags/--all/--force-with-lease), a second remote, a bare content refspec,
// or an unknown shape → false (fail-closed).
function isPureDeletionPushSegment(segment: string): boolean {
  const stripped = stripSegmentHead(segment);
  if (!/^git\s+push(?=\s|$)/.test(stripped)) return false;
  const rest = stripped.replace(/^git\s+push\s*/, "");
  const tokens = tokenizePushArgs(rest);
  let sawRemote = false;
  let sawDeletionMarker = false;
  let sawDeleteFlag = false;   // --delete/-d seen (either position)
  for (const token of tokens) {
    if (isRedirectToken(token)) continue;
    if (token === "--delete" || token === "-d") { sawDeleteFlag = true; continue; }
    if (token.startsWith("-")) return false; // any other flag → fail-closed
    if (token.startsWith(":")) { sawDeletionMarker = true; continue; } // :refspec
    if (!sawRemote) { sawRemote = true; continue; } // first non-flag = remote
    // Subsequent bare tokens are delete targets ONLY if a --delete flag was
    // seen; otherwise they are content refspecs → not pure.
    if (sawDeleteFlag) { sawDeletionMarker = true; continue; }
    return false;
  }
  return sawRemote && sawDeletionMarker;
}

// Whole-command purity (D5): true iff the command has ≥1 push op AND every
// gated op (git commit|push per GIT_COMMIT_PATTERN; gh pr create|merge per
// GH_PR_PATTERN — INCLUDING the global -R/--repo spelling `gh -R o/r pr merge`
// which GH_PR_PATTERN accepts; missing it would let mechanism (b) short-circuit
// a command that also carries a merge, pre-empting the #204 merge-scope
// decision) is a delete-shaped push. Scaffolding segments (assignments,
// gh pr view, git branch -D, comments, if/fi, $(…)) never flip purity.
export function isDeletionPush(command: string): boolean {
  let sawPush = false;
  for (const segment of splitCommandSegments(command)) {
    const stripped = stripSegmentHead(segment);
    // CONTAINMENT BACKSTOP (fail-closed, symmetric with the interception
    // surface): the gate's GIT_COMMIT_PATTERN / GH_PR_PATTERN are SUBSTRING
    // scans — they fire on `sh -c 'git commit …'`, `! git commit …`,
    // `sudo -u u git commit …`, wrapper-prefixed forms etc. Head-anchored
    // checks alone would treat such wrapper segments as scaffolding and let
    // mechanism (b) short-circuit a command that really contains a
    // commit/merge. Fail-closed containment: a segment containing ANY gated
    // verb that is not a clean head-anchored pure-deletion push → not pure.
    //   1. gh pr create|merge anywhere (bare, -R/--repo, or wrapper) → false
    //   2. git commit anywhere (bare or wrapper) → false
    //   3. head-anchored `git push` → isPureDeletionPushSegment decides
    //   4. git push in a WRAPPER form (sh -c 'git push origin main') → cannot
    //      prove purity → false (fail-closed: today's gating runs)
    //   5. no gated verb → scaffolding, ignored (D5)
    const ghOp = /\bgh(?:\s+(?:--repo|-R)(?:=|\s+)[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?\s+pr\s+(?:create|merge)\b/;
    if (ghOp.test(stripped)) return false;
    if (/\bgit\s+commit\b/.test(stripped)) return false;
    if (/^git\s+push(?=\s|$)/.test(stripped)) {
      sawPush = true;
      if (!isPureDeletionPushSegment(segment)) return false;
      continue;
    }
    if (/\bgit\s+push\b/.test(stripped)) return false; // wrapper push — not provably pure
    // else: scaffolding — ignored (D5)
  }
  return sawPush;
}
```

**Step 4:** Add the shared audit helper `logGateSkip` (module scope, near the state ~:124 or redactCommand ~:514):

```ts
// #472: shared gate_skip audit — field shape identical to the #204 merge-scope
// skip (:1105) so all skip surfaces stay audit-synced (#60).
function logGateSkip(reason: string, command: string, cwd: string, extra: Record<string, unknown> = {}): void {
  appendJsonl({
    event: "gate_skip",
    extension: "verification-gate",
    reason,
    session_cwd: process.cwd(),
    target_cwd: cwd,
    command: redactCommand(command),
    ...extra,
  });
}
```

**Step 5:** Mechanism (b) hook — insert immediately BEFORE the `// Compute diff` comment line (after the pendingRehash block ends — anchor on the unique quoted text `// Compute diff`, not line numbers, which shift after Step 3's module-level insert):

```ts
    // #472 mechanism (b): delete-shaped pushes ship NO local file content — a
    // remote-ref deletion must not trigger a whole-index staged-diff check
    // (the #470 cleanup block over another session's parked WIP). Short-circuit
    // BEFORE any diff computation — no verifiedSet/bridge writes (the #204
    // merge-scope skip's pre-diff property). Purity-gated (isDeletionPush):
    // any content refspec / git commit / gh pr op in the command falls back to
    // today's gating (fail-closed). No NEW verifiedSet/bridge entries originate
    // from this skip — note the pendingRehash block above (:1068-1090) may
    // legitimately write the bridge for a PRIOR allowed commit before this hook
    // runs; that is base behavior, not a delete-push write.
    if (isDeletionPush(command)) {
      console.log("[verification-gate] ⏭️ Skipping VGATE — delete-shaped push: no local content ships");
      logGateSkip("delete_push_no_content", command, cwd);
      return undefined;
    }
```

**Step 6:** Mechanism (a) hook — insert AFTER the empty-set allow block (`if (changedFiles.length === 0)`) and BEFORE the line `const worktreeRoot = normalizeWorktreeRoot(cwd);` (anchor on the unique quoted text, not line numbers, which shift after Step 3):

```ts
    // #472 mechanism (a): content-shape exemption — docs/CSS/static-only sets
    // (no build-output paths) skip VGATE (01-preflight.md "Verification Gate";
    // mirrors 02-commit-pr.md Step 1.5's Micro content class). TIER-INDEPENDENT:
    // content shape decides, never the complexity label. ALLOW-ONLY: no
    // verifiedSet/bridge writes — the registry stays verifier-authoritative
    // (#190/#38); a later MIXED op verifies everything fresh (docs included,
    // one [VGATE] dispatch). Commit-form guard (isBareCommitShape): only a
    // bare `git commit` qualifies — `-a`/`--all`/`--amend`/pathspec forms are
    // never exempt (D2). Exempt files are not registered, so a post-exempt
    // lint-staged rewrite cannot stale-hash a future block.
    if (changedFiles.length > 0 && isBareCommitShape(command) && changedFiles.every((file) => isShapeExemptFile(file))) {
      console.log(`[verification-gate] ⏭️ Skipping VGATE — ${changedFiles.length} docs/static file(s): content-shape exemption (tier-independent)`);
      logGateSkip("content_shape_exempt", command, cwd, { files: changedFiles.length });
      return undefined;
    }
```

where `isBareCommitShape(command)` is a small pure helper with **FORALL semantics (normative): returns false if ANY `git commit` invocation in the command is non-bare; returns true only when every commit invocation is bare (or there are no commit invocations)** — a multi-commit command like `git commit -am x && git commit -m y` MUST return false (the `-am` sweep must never be newly permissive, D2/follow-up #5). Unit pins live in Task 1 Step 3 (RED phase) — Task 2 GREEN only confirms them against the real predicate; do NOT re-register duplicate tests here. Implementation (tokenized scan, mirroring stripSegmentHead + tokenizePushArgs + substring containment): for each segment CONTAINING `git commit` (head-anchored or wrapper-prefixed — substring scan symmetric with GIT_COMMIT_ONLY_PATTERN), tokenize the args against an EXACT-TOKEN WHITELIST — allow value flags `-m/-F/-C/-c` (each consumes the next token) and their long forms `--message/--file/--reedit-message/--reuse-message`, and benign boolean flags `-s/-S/-q/-v/-e/-n/--signoff/--no-verify/--no-edit/--edit/--quiet/--verbose`; REJECT every other single-dash token (all bundles: `-a`, `-am`, `-am"x"`, `-mx`, `-o`, `-i` — the guard deliberately does not model git's bundle grammar), every unknown long flag (`--all`/`--amend`/`--only`/`--include`), every bare positional token (a pathspec), and anything after `--`. Attached-value long spellings (`--message="x"`) and `#` trailing comments are over-gated (false) by design — fail-closed. Non-commit invocations are ignored (vacuously satisfied). Code sketch:

```ts
// D2 commit-form guard: a docs/CSS/static exemption may only apply to a BARE
// `git commit` (explicit `git add` + `git commit` ceremony, per 02-commit-pr.md
// Step 1). `-a`/`--all`/`--amend` sweep working-tree changes the gate cannot
// see in the index; pathspec forms commit a chosen subset. FORALL semantics: if
// ANY commit invocation is non-bare, the whole command is non-bare (a chained
// `git commit -am x && git commit -m y` must never be exempt).
// ── D2 commit-form guard (FORALL semantics + fail-closed whitelist) ──
// A docs/CSS/static exemption may apply only to a BARE `git commit` (explicit
// `git add` + `git commit`, per 02-commit-pr.md Step 1). FORALL: if ANY commit
// invocation in the command is non-bare, the whole command is non-bare.
//
// FAIL-CLOSED MODEL: instead of modeling every git flag (bundles, -a/-o/-i
// sweeps, -S/-s semantics, attached values), the guard ALLOWS only a small
// whitelist of benign exact tokens and REJECTS everything else (→ VGATE runs →
// safe direction). Rejected forms include -a/-am/-am"x"/--all (sweep), -o/-i/
// --only/--include (pathspec selection), --amend, and any unknown flag —
// over-gating a rare benign spelling (e.g. --no-verify) is acceptable; the
// guard's job is to never be newly permissive, not to be complete.
const BARE_COMMIT_VALUE_FLAGS = new Set(["-m", "-F", "-C", "-c"]);
// Long value flags: consume the NEXT token as their value.
const BARE_COMMIT_VALUE_LONG = new Set(["--message", "--file", "--reedit-message", "--reuse-message"]);
// Boolean flags that do NOT change the committed file set (safe to allow).
const BARE_COMMIT_BOOLEAN = new Set(["-s", "-S", "-q", "-v", "-e", "-n", "--signoff", "--no-verify", "--no-edit", "--edit", "--quiet", "--verbose"]);

export function isBareCommitShape(command: string): boolean {
  for (const segment of splitCommandSegments(command)) {
    const stripped = stripSegmentHead(segment);
    // CONTAINMENT (fail-closed): a wrapper-prefixed commit (`sh -c 'git commit
    // -am x'`, `! git commit …`, `sudo -u u git commit …`) is a real commit
    // whose sweep the gate cannot see. Treat any segment CONTAINING `git
    // commit` as a commit segment (substring, mirroring GIT_COMMIT_ONLY_PATTERN)
    // so the -a sweep can never ride a docs-only staged set to an exemption.
    if (!/^git\s+commit(?=\s|$)/.test(stripped) && !/\bgit\s+commit\b/.test(stripped)) continue;
    const rest = stripped.replace(/^git\s+commit\s*/, "");
    const tokens = tokenizePushArgs(rest);
    let afterDashDash = false;
    for (let i = 0; i < tokens.length; i++) {
      const tok = tokens[i];
      if (afterDashDash) return false;               // pathspec after -- → non-bare
      if (tok === "--") { afterDashDash = true; continue; }
      if (tok.startsWith("--")) {
        if (BARE_COMMIT_VALUE_LONG.has(tok)) { i++; continue; } // consume value
        if (BARE_COMMIT_BOOLEAN.has(tok)) continue;
        return false; // --all/--amend/--only/--include/unknown long → non-bare (fail-closed)
      }
      if (tok.startsWith("-")) {
        if (BARE_COMMIT_VALUE_FLAGS.has(tok)) { i++; continue; } // -m x: consume value
        if (BARE_COMMIT_BOOLEAN.has(tok)) continue;
        // Any OTHER single-dash token (-a, -am, -am"x", -mx, -o, -sS, …) is
        // REJECTED: it may be a sweep (-a/-am), a pathspec mode (-o/-i), or an
        // attached-value spelling (-mx). We deliberately do not model git
        // bundles — reject is fail-closed (VGATE runs; the commit still
        // proceeds after the normal [VGATE] ceremony).
        return false;
      }
      return false; // bare positional token = pathspec → non-bare
    }
  }
  return true; // no commit segment, or every commit bare → guard satisfied
}
```

Reachable-push note (corrected from falsification item 3): a push AFTER a docs-only commit has an EMPTY index → the empty-set allow fires FIRST and the (a) hook never sees it. The push case the hook actually reaches is a staged-but-uncommitted all-docs set (`git add docs/ && git push origin main`) — safe to allow (push ships HEAD, gated commit-by-commit; staged docs don't ship; no widening vs today's always-allowed empty-index push) and IS audited. These cases are ALREADY pinned in Task 1 Step 3 (the guard section incl. `git push origin main` → true and `cd /repo && git commit -m x` → true) — verify against the real predicate in GREEN, do NOT re-register tests here.

**Step 7:** Run unit suite: `npx tsx index.test.ts` — expect all green (existing 173 + new sections), 0 failed.

### Task 3: e2e scenarios 38-46

**Intent:** End-to-end pin of both mechanisms against the mounted-plugin harness (the issue's Verification Checklist surface: "micro-tier + cleanup-op cases covered; regression green").
**Acceptance:** index.e2e.test.ts ends with "Final: 50 passed, 0 failed" (39 + 11 new: 38, 39, 39b, 40-47 — scenario 47 added by the test-review gate to cover the mechanism-(a) push half, per M8).
**Files:**
- Modify: `extensions/verification-gate/index.e2e.test.ts`
- Test: `extensions/verification-gate/index.e2e.test.ts`

**Step 1:** Append a new section `#472 — proportionality` before `} // main` (~:1340):

- **scenario 38: docs-only commit unblocked.** Fresh repo (setup pattern); write `README.md` + `styles/theme.css`; `git add` both; `fire("session_start")`; `fire("tool_call", {command: "git commit -m docs"})` → `equal(res, undefined)`; `readAuditLines()` tail contains a `gate_skip` with `reason: "content_shape_exempt"`; assert NO `gate_bypass` entries added.
- **scenario 39: docs-only gh pr create unblocked (branch-diff path).** Repo with `git remote add origin` + `git update-ref refs/remotes/origin/main <baseSha>` (scenario 19-20 pattern); commit docs on a branch; `fire` `gh pr create --title t` → `undefined` + audit `content_shape_exempt`.
- **scenario 39b: docs-only gh pr merge unblocked (same-repo sandbox).** Mirror scenario 39's setup with the merge verb; in the sandbox the gh head check fails → `same_repo_head_unknown` (verify: true — only cross_repo/head_mismatch skip) → `computeBranchDiff` runs → all-docs diff → (a) hook exempts → `undefined` + audit `content_shape_exempt`. Pins the ordering property that (a) fires only AFTER the #204 merge-scope early return (a future move of the (a) hook before the GH_PR_PATTERN branch would exempt cross-repo merges without the scope check).
- **scenario 40: mixed set never exempt.** Stage `README.md` + `src/app.ts`; commit → `block === true`; reason names BOTH files.
- **scenario 41: code commit after docs commit still blocks.** Commit docs-only (allowed, exempt); stage `src/app.ts` only; commit → `block === true`; reason names the .ts; then plain-text/JSON PASS merge via tool_result (existing harness pattern) → commit allowed. (Proves the exemption cannot be used to dodge code verification.) Then (guard-isolation leg — staged docs ONLY + dirty UNSTAGED code file): fire `git commit -am "x"` → `block === true` (guard rejected the sweep → VGATE ran) and assert the code file is still uncommitted (working tree still dirty — the sweep did NOT ride the exemption); fire `git commit -am"x"` (attached spelling) → `block === true`; fire `git commit -m x` (bare, code still unstaged) → `undefined` (exemption applies — only staged docs commit) and assert the code file is still NOT committed (commit-form guard — `-a` and bundles never exempt, D2).
- **scenario 42: build-template boundary.** Stage `public/index.html` + docs → commit → block, reason names `public/index.html`. Reset; stage `website/index.html` + docs → commit → `undefined`.
- **scenario 43: #470 repro — deletion push over parked WIP.** Fresh repo; stage unverified `wip.ts` (no commit); fire the 05-cleanup literal (multiline `git push origin --delete "$BRANCH" 2>/dev/null \` newline `|| echo …`) → `undefined`; audit `delete_push_no_content`; then `git commit -m wip` → still `block === true` (deletion push blessed nothing).
- **scenario 44: content push stays gated.** Parked WIP + `git push origin main` → block; parked WIP + `git push origin --delete a && git push origin main` → block; parked WIP + `git push origin --delete a & git push origin main` → block (single-& background — content push after & is a real separate command); `gh -R daniel-ospina/agent-infra pr merge 5` with parked WIP → merge-scope path runs (NOT short-circuited by mechanism b) — assert behavior matches scenario 19/20's same-repo sandbox (block on drift files or skip per head resolution).
- **scenario 45: non-interception pins.** `git branch -D feat/x` → `undefined` AND no new audit entry; `git worktree remove feat/x` → `undefined` AND no new audit entry.
- **scenario 46: flag-before-remote + sub-agent docs commit.** (a) parked WIP + `git push --delete origin feat/x` → `undefined` + audit. (b) sub-agent mode (PI_MODE=print + TASK_HEARTBEAT=1): stage docs only, commit → `undefined` + audit `content_shape_exempt` (child docs commit allowed — content-shape is deterministic, no bypass channel; #825 children still blocked on code).

**Step 2:** Run: `npx tsx index.e2e.test.ts` — expect `=== Final: 50 passed, 0 failed ===` (scenario 47 added by the test-review gate: all-docs staged push exempt).

### Task 4: 01-preflight.md one-unit correction

**Intent:** Fix the doc drift (Indicator 3) — the entire gate-contract block corrected as one consistent unit.
**Acceptance:** No self-contradiction remains in `skills/commit-workflow/workflow/01-preflight.md`; VGATE-SHAPE-RULE fence present; Review-enforcer row states warn-only reality.
**Files:**
- Modify: `skills/commit-workflow/workflow/01-preflight.md`

**Step 1:** Micro Tier table (:246-257): KEEP the `Verification-gate (VGATE)` row but REPLACE its Micro-behavior cell content with a pointer (single action): "**shape-gated, not tier-gated** — docs/CSS/static-only sets skip regardless of tier; code sets never skip (see Pi Extension Gates → Verification Gate below)." Do NOT remove the row — Steps 3/8 cross-references assume a surviving table entry.
**Step 2:** Review-enforcer row (:252) → actual behavior: "**WARN-ONLY** at micro — 0 reviewer dispatches warn but do not block (extension reads /tmp/agent-issue-complexity = micro); Standard+/unset block."
**Step 3:** Micro Tier section intro + auto-detect clause (:246-248): add the mechanism-separation sentence (VGATE skip is extension-side/shape-based/any tier; review-enforcer micro warn-only is marker-based; a docs-only commit on an UNLABELED issue is VGATE shape-exempt but still review-enforcer-blocked at 0 dispatches).
**Step 4:** "## Pi Extension Gates (mandatory — not tier-gated)" (:286) → retitle "## Pi Extension Gates (extension-enforced — per-gate scoping)" + intro correction: review-enforcer is tier-gated (micro warn-only via marker; standard+/unset block); VGATE is content-shape gated (docs/CSS/static-only sets exempt, code never); neither is bypassed for code-bearing sets.
**Step 5:** Verification Gate subsection (~:308): add the content-shape exemption block + the machine-read fence:

```markdown
**Content-shape exemption (docs/CSS/static-only — extension-side, tier-independent):**
when the op's relevant file set (staged diff for commit/push; branch diff for
`gh pr create`/merge) is ENTIRELY docs/CSS/static AND no file sits under a
build-output directory, VGATE skips the op (audited `gate_skip:
content_shape_exempt`). Code-bearing or mixed sets are NEVER exempt; a bare
`git commit` only (no `-a`/`--all`/pathspec — those forms stay fully gated).

<!-- VGATE-SHAPE-RULE: machine-read by extensions/verification-gate/index.test.ts drift test — keep in sync with SHAPE_EXEMPT_EXTENSIONS + BUILD_OUTPUT_SEGMENTS in extensions/verification-gate/index.ts -->
| Exempt extension | Build-output path segments (any depth — NOT exempt) |
|---|---|
| `.md` | `public/` `dist/` `build/` |
| `.css` | `public/` `dist/` `build/` |
| `.scss` | `public/` `dist/` `build/` |
| `.html` | `public/` `dist/` `build/` |
<!-- /VGATE-SHAPE-RULE -->
(Drift test normalizes the trailing `/` before comparing to `BUILD_OUTPUT_SEGMENTS`.)

Delete-shaped pushes (`git push origin --delete <branch>`, `git push --delete
origin <branch>`, `git push origin :<branch>`) ship no local file content and
skip VGATE before any diff computation (audited `gate_skip:
delete_push_no_content`). Content pushes keep the staged check. `git branch -D`
/ `git worktree remove` are not VGATE-intercepted.
```

**Step 6:** Review Enforcer Gate subsection (~:288): add "Micro tier: warn-only (marker /tmp/agent-issue-complexity = micro); Standard+/unset block."
**Step 7:** Test-Review Hash Backstop section: annotate the micro skip line as tier-gated via issue-body `complexity:micro` grep (third, separate micro channel).
**Step 8:** REWRITE the :257 rationale paragraph (currently "A single reviewer sub-agent catches stupid agent mistakes without the 3+ minute per-file VGATE overhead. For a 2-line fix, a 10-second \"CLEAN\" review is proportional.") to state the actual contract: "Micro-tier CODE commits keep full VGATE (shape-gated — the extension skips only docs/CSS/static sets, never code); the reviewer dispatch (review-enforcer, warn-only at micro) plus VGATE-on-code is the net." This removes the residual self-contradiction where the rationale promised no per-file VGATE for micro code while Task-4-Step-1 keeps VGATE shape-gated (code never skips).
**Step 9:** Reconcile the "Low-risk tier — skips typecheck/build for doc-only changes" (:39) and "Low (docs, config, CSS, strings)" stack vocabulary (:58/:69): these are PRE-FLIGHT SCRIPT gates (typecheck/build skip), distinct from VGATE's content-shape gate. Add one mechanism-separation sentence there so readers don't conflate pre-flight risk-tier with the extension's shape rule.
**Step 10:** Leave 02-commit-pr.md / 03-code-review.md untouched (follow-up #2); leave :132 AGENTS.md tracked-status note (follow-up #2).

### Task 5: drift test

**Intent:** Machine-pin doc↔extension agreement (Indicator 3 / defect-(a) class) — the fence in 01-preflight.md must equal the exported constants.
**Acceptance:** index.test.ts gains a drift-test section that passes when the fence matches the exports and skips (with a note) when the doc is unreachable (deployed extension copy).
**Files:**
- Modify: `extensions/verification-gate/index.test.ts`

**Step 1:** Add a section `doc drift test — 01-preflight VGATE-SHAPE-RULE fence ↔ exports`:
- Resolve the doc cwd-INDEPENDENTLY via `new URL("../../skills/commit-workflow/workflow/01-preflight.md", import.meta.url)` from the test file (precedent: the #285 drift guard at index.test.ts tail). Fall back to relative candidates only if the URL resolution fails. If no file exists → print "skip (deployed copy — doc not reachable)" and pass.
- Extract rows between `<!-- VGATE-SHAPE-RULE` and `<!-- /VGATE-SHAPE-RULE`; SKIP the header row and the `|---|` separator row inside the window.
- Parse each data row: col 1 = extension token (`.md` etc.); col 2 = code-span segment tokens. NORMALIZE: strip surrounding backticks from every token in both columns (the fence is machine-read but backtick-wrapped for prose readability), then strip a trailing `/` from segment tokens (`public/` → `public`) before comparison.
- Collect extension tokens and segment tokens into SETS (dedupe across the 4 data rows — the fence repeats `public/` `dist/` `build/` in every row; a naive flat list would yield 12 segment tokens and fail). Assert sorted extension set == sorted `SHAPE_EXEMPT_EXTENSIONS`; assert sorted normalized segment set == sorted `BUILD_OUTPUT_SEGMENTS`.

**Step 2:** Run unit suite — expect all green including the drift tests.

### Task 6: full verification + self-review fixups

**Intent:** Prove both suites green at the final state and self-review the diff for the code-review gate.
**Acceptance:** Both suites green; `git status` shows exactly the 4 expected files + the plan/scope docs; no debug artifacts.
**Files:**
- Test: both suites

**Step 1:** Run from `extensions/verification-gate/`: `npx tsx index.test.ts` → all green, 0 failed (196 total at final state); `npx tsx index.e2e.test.ts` → `=== Final: 50 passed, 0 failed ===`.
**Step 2:** `git -C <repo-root> status` — expected: `extensions/verification-gate/index.ts`, `index.test.ts`, `index.e2e.test.ts`, `skills/commit-workflow/workflow/01-preflight.md`, `docs/scoping/2026-09-05-issue-472-vgate-proportionality.md`, `docs/plans/2026-09-05-issue-472-vgate-proportionality.md` (this file). Nothing else.
**Step 3:** Self-review: re-read the two hooks in context; verify no existing test's expectations changed (all prior scenarios byte-identical semantics); verify no `console.log` debug leftovers.
**Step 4:** Hand to commit-workflow: preflight (01), VGATE verification dispatch, commit, PR "Fixes #472", code-review gate.

## Failure Modes

- Bare `git push` vacuous-truth → blocked by D4 ∃-marker + unit pin → gate stays on (fail-closed).
- `2>/dev/null` mis-parse → dropped by D6 redirect rule + ceremony-literal unit pins → correct classification.
- Chained `--delete a && git push origin main` → per-segment purity → content push flips false → gated.
- Quoted prose `--comment "see git push origin --delete x"` → quote-masked separator scan → never a segment → no false purity.
- Docs-only exemption over-read (e.g. `public/*.md`) → D3 all-four denylist + boundary e2e (scenario 42).
- Lint-staged rewrite of an exempt doc post-commit → no registry entry exists → no stale-hash false block (ALLOW-ONLY eliminates the interaction).
- Sub-agent inheriting a bypass → impossible (content-shape is a pure function of the op's file set; no env/marker/state channel).

## Follow-up issues to file (during Task 6)

1. `fix(review-enforcer): decide micro-tier dispatch policy — hard-require 1 dispatch vs current warn-only (residual net behind the VGATE docs skip)`
2. `chore(commit-workflow): de-drift 02-commit-pr.md Step 1.5 + 03-code-review.md micro references; fix 01-preflight.md:132 AGENTS.md tracked-status note (AGENTS.md IS tracked)`
3. `feat(verification-gate): scope push-time check to the pushed commit range, not the whole index (content pushes still whole-index — out of scope for #472)`
4. `docs(commit-workflow): revisit pipeline-compliance issue-link requirement for docs-only commits (Context note [a] — may be deliberate policy)`
5. `fix(verification-gate): git commit -a / --all sweeps invisible dirty code past the gate (relevant set should be HEAD-vs-working-tree for -a forms)`

## Execution-Mode Decision

Using subagent-driven execution for 6 tasks — 6 ≤ 8 (subagent-driven threshold). Tasks 1+2 both edit index.ts + index.test.ts (must run sequentially in one worktree); tasks 3-6 each own a distinct file and could parallelize, but the shared-extension-dir test suite + commit gate make a single sequential chain simpler and safer (this session dispatches implementer sub-agents per task per executing-plans/subagent-driven-development, with fresh [VGATE]/reviewer dispatches at commit time per the gate contract).
