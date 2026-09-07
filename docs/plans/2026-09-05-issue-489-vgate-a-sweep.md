---
title: "#489 — verification-gate auto-sweep commit scope (`git commit -a`/`--all`) — Implementation Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-05
aboutSubjects: organisation-design-team, verification-gate
aboutObjects: agent-infra, issue-489, issue-472
---

<!-- research-path: docs/plans/2026-09-05-issue-489-vgate-a-sweep.md -->

# Issue #489 Implementation Plan — VGATE sweep-form commit scope (`git commit -a`/`--all`)

> **For Pi:** execute task-by-task; unit + e2e suites must be green before commit.

**Goal:** Close the verification-gate hole where `git commit -a`/`--all` sweeps invisible dirty code past a gate that only diffs the staged index.

**Team:** organisation-design-team
**Issue:** #489 (complexity:standard). **Scope comment:** issue comment 5559094110 (`<!-- issue-scoping: v5.1 double diamond + verify -->`).
**Plan-review cycle log:** see `<!-- plan-review:` signature at the bottom (appended after the gate passes).

**Architecture:** `-a`/`--all` commit forms record tracked working-tree state, so VGATE's commit file set must come from `git diff HEAD` (exactly what the sweep commits) for those forms; bare and `--amend` commits keep `git diff --cached` (index — precise for them). Pathspec commits of tracked files (`git commit <path>` / `-o`/`--only`) record the named paths' WORKING-TREE content — the staged index under-gates that vector; this is #489 T2's explicit carve-out, tracked as follow-up #538 (not characterized as precise here). A pure classifier `commitSweepClass(command)` (git token-order option-value model) returns `"sweep" | "mixed" | "none"` per command; the hook routes `"sweep"` (pure-sweep chains) to a new `computeWorktreeDiff`, `"mixed"` (sweep + bare/other commit in one command — an index-only staged-revert file would otherwise slip past a WT-only scope) to `staged ∪ worktree`, `"none"` to today's staged scope. The #472 D2 exemption guard (isBareCommitShape) is untouched.

### Pattern Research

> **Findings date:** 2026-09-05
> **Gate skipped: plan touches zero third-party deps** — pure Node stdlib + in-repo helpers. Git CLI semantics empirically verified in sandbox repos during scoping (scope comment evidence 1–5) and re-verified by plan reviewers.

### Integration Surface Map

| # | Surface | Boundary | Test layer | Failure modes (≥2) | Covering tests |
|---|---------|----------|------------|--------------------|----------------|
| 1 | `commitSweepClass` classifier (pure) | commit token stream → sweep/mixed/none | unit section | false-negative on bundled/attached `-a` (`-am`, `-am"x"`, `-amx`, `-va`); false-negative when optional-value `-S`/`-u` precedes a bare `-a`; false-positive on `-m`-swallowed flag tokens / attached values | Task 1 pin table |
| 2 | `computeWorktreeDiff` | `git diff HEAD --name-only` subprocess | e2e (real repos) | unborn HEAD → staged fallback (exact `-a`-on-unborn set); other `git diff HEAD` failures → error log + staged fallback (accepted residual, corrupt-repo commits fail at git level anyway); deleted tracked files in the sweep (content-free skip) | scenario 48 Leg E, scenario 49 unborn + deletion legs |
| 3 | Hook routing | classifier → file set | e2e | sweep misrouted to staged/branch scope; bare/`--amend`/gh-pr/delete-push regression | scenario 48 legs A–F; unchanged scenarios 38–47 as net; scenario 41 stays GREEN UNTOUCHED (post-fix its Leg-B `-am` block names only README.md — the Leg-A armed pendingRehash re-blesses app.ts to its a2 disk state before the block check, so no mismatch section appears; 41's D2 pins hold byte-identical pre/post fix) |
| 4 | Exemption interplay | sweep + all-docs WT set | e2e | D2 must keep refusing sweep exemption; docs-only empty-index `-a` flips allow→block (fail-closed friction — pin it) | 48 Leg F; existing 41 Leg B/C |
| 5 | #7591 auto-bypass | attempt counters per file | e2e | same-file blocks across legs reaching threshold 3 → silent auto-bypass | 48 session layout (session_start at start + before Legs B/E/F/G; load-bearing boundaries: no-reset B-PASS→C-allow, and the G reset) |
| 6 | git-global-option spellings (`git -C <dir> commit`, `--no-pager`, `-c k=v`, `--git-dir=`) | interception pattern (GIT_COMMIT_PATTERN) | — | TRUE mechanism: `GIT_COMMIT_PATTERN` requires `git` immediately adjacent to `commit`, so `git -C repo commit -a` NEVER fires the hook (`isGitOp` false) — the whole global-options family is un-gated today for bare AND sweep forms (the classifier never runs). PRE-EXISTING, not a #489 regression; `findGitCommit`'s regex already tolerates the globals, so the fix is interception-pattern coverage (mirror it in GIT_COMMIT_PATTERN) — tracked by OPEN issue #490. Task 1 pins `git -C repo commit -am x`/`git --no-pager commit -am x` → sweep are PURE-PREDICATE contract pins the hook cannot reach until #490 lands (same class as the pre-existing D2 pins) | residual (#490) |
| 7 | intent-to-add (`git add -N <file>`) under `-a` | `git diff HEAD` listing of intent-to-add entries is git-version-sensitive; `-a`'s treatment also version-dependent — a divergence would route a real WT sweep to the staged scope | — | unpinned git edge (second-model gate finding, P3) — residual-shaped, same class as #538/#539; not exercised by any scenario | residual (follow-up) |

### Verification Plan

- **Unit** (`index.test.ts`): module-load smoke; classifier section with TRUE/FALSE pins (Task 1). No red-state module crash: the classifier is stubbed (throwing) in index.ts in the same task as the tests (this suite has no clean-red precedent — #472 shipped impl+tests together; the file-level static named import would otherwise hard-crash at ESM link time).
- **E2E** (`index.e2e.test.ts`): scenario 48 (legs A–F, session layout below) + scenario 49 (unborn-HEAD + deleted-tracked sweep edges). Scenario 41 UNTOUCHED.
- **Drift**: VGATE-SHAPE-RULE fence drift test green (fence pins only SHAPE_EXEMPT_EXTENSIONS/BUILD_OUTPUT_SEGMENTS — untouched).
- **Docs**: 01-preflight "Verification Gate" prose clause (sweep scope + how-to note) — fence table untouched.
- Domain: code (extension) — no UI/UX, data/ontology, or config surfaces.

### Tech Stack

TypeScript extension (`@earendil-works/pi-coding-agent` 0.84.3 types), `node:test` + tsx, git CLI.

---

## Task 1: Classifier `commitSweepClass` — stub + red unit tests

**Intent:** Lock the sweep classification contract before implementation (TDD red, suite-crash-safe).
**Acceptance:** New unit section FAILS (stub throws); the other ~200 unit tests still run green (no ESM link crash); module-load smoke updated.
**Files:**
- Modify: `extensions/verification-gate/index.ts` — stub export (throwing) + doc comment skeleton
- Modify: `extensions/verification-gate/index.test.ts` — smoke list + new section

**Step 1:** Add the stub next to `isBareCommitShape` in index.ts:

```ts
// #489: sweep-form commit classifier — stub (implemented in Task 2).
export type CommitSweepClass = "sweep" | "mixed" | "none";
export function commitSweepClass(_command: string): CommitSweepClass {
  throw new Error("#489: not implemented");
}
```

**Step 2:** index.test.ts — (a) add `commitSweepClass` to the STATIC named import at line ~10 (`import { …, commitSweepClass } from "./index.js"` — omitting this reds the smoke with `ReferenceError` instead of a clean typeof fail) AND (b) add it to the module-load callables smoke list (`ok(typeof commitSweepClass === "function")`), then (c) add a `section("commitSweepClass — auto-sweep commit classification (#489)")` after the isBareCommitShape section with:

```ts
test("SWEEP (single pure-sweep invocation) → \"sweep\"", () => {
  const pins = [
    "git commit -a",
    "git commit --all -m x",
    "git commit -am x",
    'git commit -am "x"',
    "git commit -amx",                       // -a + -m(x attached)
    "git commit -vam x",                     // -v -a -m(x)
    "git commit -qam x",
    "git -C repo commit -am x",              // sweep behind git global flags
    "git --no-pager commit -am x",
    "git commit --author \"Jane <j@d>\" -a -m x",  // scan continues past required-value longs
    "git commit --date 2024-01-01 -a -m x",
    "git commit --trailer \"A=b\" -a -m x",   // required-value long consumes its value, then -a
    "git commit -t tpl.txt -a -m x",
    "git commit -S -a -m x",                  // optional-value -S never consumes the NEXT token → -a is real
    "git commit -u -a -m x",                  // same for -u
    "git commit --amend -a",                  // via the -a arm
    "git commit -a --amend",
    "git commit -a -m x && git commit --all -m y", // every invocation sweeps → sweep
  ];
  for (const c of pins) equal(commitSweepClass(c), "sweep", `must be sweep: ${c}`);
});

test("MIXED (sweep + non-sweep commit in one command) → \"mixed\"", () => {
  const pins = [
    "git commit -m x && git commit --all -m y",   // bare then sweep
    "git commit -am x && git commit -m y",         // sweep then bare
    "git commit -m x f.txt && git commit -a -m y", // pathspec then sweep
  ];
  for (const c of pins) equal(commitSweepClass(c), "mixed", `must be mixed: ${c}`);
});

test("NONE (bare / amend-alone / pathspec / value-swallowed / vacuous) → \"none\"", () => {
  const pins = [
    "git commit -m x",
    "git commit -m x -s",
    "git commit -F msg.txt",
    "git commit -c HEAD -m x",
    "git commit -C HEAD -m x",
    "git commit -S -m x",
    "git commit -m -a",                  // message "-a"
    "git commit -m --amend",             // message "--amend"
    "git commit --message -a",           // subject "-a"
    "git commit --message --all",
    "git commit --message=--amend",      // attached value
    "git commit -ma x",                  // -m value "a" + pathspec x
    "git commit -mx",                    // -m value x
    "git commit -Sa -m x",               // -S optional keyid "a" (attached) — NOT a sweep
    "git commit -uall -m x",             // -u optional mode "all" (attached)
    "git commit -ta x",                  // -t template "a" + pathspec x
    "git commit --amend -m x",           // amend alone — index scope (#489 T1 letter; T2)
    "git commit -m x f.txt",             // pathspec
    "git commit -o code.ts -m x",        // only-mode pathspec
    "git commit -m x --only",
    "git commit -m x -- -a",             // `--` pathspec terminator → "-a" is a path, not a flag
    "git commit --all=true",             // invalid attached spelling — not the flag
    "sh -c 'git commit -am x'",          // wrapper — non-head-anchored → none (staged scope, unchanged; #539)
    "! git commit -am x",
    "git push origin main",              // vacuous — no commit invocation
    "gh pr create --body 'git commit -am x'",  // prose — never classified
  ];
  for (const c of pins) equal(commitSweepClass(c), "none", `must be none: ${c}`);
});
```

**Step 3:** Run `npx tsx extensions/verification-gate/index.test.ts` — expect: the module-load smoke stays GREEN (typeof check passes against the stub — it never calls the predicates) and the three new section tests FAIL with `#489: not implemented`; all ~200 other tests PASS (file loads fine — stub export exists). Exit code 1. This is the red.

## Task 2: Implement the classifier (real bodies)

**Intent:** Green the classifier.
**Acceptance:** Task 1's three tests pass; no other test regresses.
**Files:**
- Modify: `extensions/verification-gate/index.ts` (replace the stub; keep the `CommitSweepClass` type export)

**Step 1:** Implement `commitSweepClass(command)` replacing the stub. Structure (reuse the D2 helpers — `splitCommandSegments`, `stripSegmentHead`, `findGitCommit`, `tokenizePushArgs`):

- Iterate `splitCommandSegments(command)`; per segment `stripSegmentHead`; `findGitCommit(stripped)`.
- HEAD-ANCHORED only (`commitMatch.index === 0`): classify the invocation via a private `scanCommitInvocationForSweep(rest: string): boolean` (the token scan below). Non-head-anchored commit text (wrappers, prose, `gh pr create --body "…git commit -am…"`) is never a classified invocation — `"none"` contribution (unchanged staged scope; no prose misfire; residual #539 — including `env -i git commit -a` and `sudo -u me git commit -a`, where env/sudo's own flags defeat stripSegmentHead's prefix strip, and quoted multi-word env values).
- Command class: no sweep-scanned invocation → `"none"`; ≥1 sweep + every head-anchored commit invocation sweep → `"sweep"`; ≥1 sweep + ≥1 non-sweep head-anchored invocation → `"mixed"`. (Multiple head-anchored invocations across `&&`-chained segments.)
- `scanCommitInvocationForSweep(rest)` — token-order scan mirroring git's parser:
  - `tokenizePushArgs(rest)`; iterate with a `skipNext` flag.
  - `skipNext` set → clear, continue.
  - `tok === "--"` → pathspec terminator: return false (index scope; nothing after can be a flag).
  - `tok === "--all"` → true.
  - long flags (`startsWith("--")`): required-value longs consume the next token (`skipNext = true`): `--message --file --reedit-message --reuse-message --author --date --template --cleanup --fixup --squash --trailer --pathspec-from-file` (verified empirically: `--encoding` is NOT a git commit option — "error: unknown option `encoding'" — excluded; a wrongly-included boolean would skipNext over a real `-a` → false negative). Other longs (`--amend`, booleans, unknowns, `=value` attached forms) → continue.
  - short clusters (`startsWith("-")` and `length > 1`, not `"--"`): iterate chars from index 1: char `a` → true; required-value chars `m F C c t` → consume rest-of-cluster if any, else `skipNext = true`, then stop scanning this cluster; optional-value chars `S u` → consume rest-of-cluster chars only (attached value), never the next token, then stop scanning this cluster; boolean/unknown chars (`e i n o q s v` and others) → continue.
  - positional tokens (pathspecs) → continue scanning (git parses flags after positional args).
- Doc comment: #489 semantics, git value-model rationale, residual boundaries (#538/#539/#540), and the mixed→union rationale.

**Step 2:** Run the unit suite — expect the new section green, all others green.

## Task 3: Route by class in the hook — `computeWorktreeDiff` + diff selection

**Intent:** Sweep-scoped verification (T1); mixed chains get the union so index-only staged-revert content cannot slip past a WT-only scope.
**Acceptance:** Classification-driven diff selection; pinned scenarios unaffected.
**Files:**
- Modify: `extensions/verification-gate/index.ts` (diff functions + hook diff-selection block ~L1447)

**Step 1:** Add `computeWorktreeDiff(cwd)` beside `computeStagedDiff`:

```ts
function computeWorktreeDiff(cwd: string): string[] {
  // #489: sweep commits record the working tree — the relevant file set is
  // HEAD-vs-working-tree. Unborn HEAD: `git commit -a` records only the
  // index (verified), and `git diff HEAD` errors — staged fallback is the
  // exact -a set for that state. Any OTHER diff failure (corrupt index,
  // permission) is logged and falls back to the staged scope (status-quo
  // semantics; a genuinely broken repo fails at git commit time anyway) —
  // accepted residual, see #489 plan surface-map row 2.
  try {
    execSync("git rev-parse --verify HEAD", { encoding: "utf-8", cwd, timeout: 5000, stdio: "ignore" });
  } catch {
    return computeStagedDiff(cwd); // unborn
  }
  try {
    const out = execSync("git diff HEAD --name-only", { encoding: "utf-8", cwd, timeout: 5000 }).trim();
    return out ? out.split("\n").filter(Boolean) : [];
  } catch (e) {
    console.error("[verification-gate] ⚠️ git diff HEAD failed — falling back to staged scope:", (e as Error).message);
    return computeStagedDiff(cwd);
  }
}
```

**Step 2:** Replace the hook's diff-selection block:

```ts
    // Compute diff — #489: auto-sweep commits (`-a`/`--all`) record the
    // working tree, not just the index; their verification file set must be
    // HEAD-vs-working-tree (`git diff HEAD` — exactly what the sweep commits)
    // or the staged-docs verifier PASS lets the swept code ride unverified.
    // Classifier: "sweep" (pure-sweep command) → WT diff; "mixed" (sweep +
    // non-sweep commit in one command) → union(staged, WT) — a WT-only scope
    // would blind the gate to index-only content a BARE commit in the chain
    // records; "none" → today's staged scope. Mixed sweep+gh-pr chains keep
    // the gh branch path (unchanged; #540).
    const sweepClass = commitSweepClass(command);
    let changedFiles: string[];
    if (sweepClass !== "none" && !GH_PR_PATTERN.test(command)) {
      const worktree = computeWorktreeDiff(cwd);
      // pure-sweep → WT diff only (no wasted staged subprocess); mixed →
      // deduped union (a bare commit in the chain records index-only content)
      changedFiles = sweepClass === "sweep" ? worktree
        : Array.from(new Set([...computeStagedDiff(cwd), ...worktree]));
    } else if (GH_PR_PATTERN.test(command)) {
      // #204: PRESERVE THIS BRANCH VERBATIM — do not elide the merge-scope
      // skip: `if (!decision.verify) { console.log + logGateSkip + return undefined }`
      // (a dropped `return undefined` makes cross-repo/unknown-head gh pr merge
      // fall through to branch-diff and reds scenario 19).
      if (isMergeCommand(command)) {
        const decision = resolveMergeScope(command, cwd);
        if (!decision.verify) { /* unchanged — keep verbatim */ }
      }
      changedFiles = computeBranchDiff(cwd);
    } else {
      changedFiles = computeStagedDiff(cwd);
    }
    // ⛔ ORDERING GUARD: this diff-selection block sits AFTER the top-of-op
    // pendingRehash loop and AFTER recoverBridgeForRoot. Do not move the
    // insertion above them — scenario 41's post-fix greenness depends on the
    // Leg-A allowed commit's armed pendingRehash (re-blessing src/app.ts to
    // its a2 disk state) executing before sweep1's block check; and do not
    // insert hook ops / session_start between 41's Leg-A real commit and its
    // sweep1 fire (consuming the armed rehash turns the a1-vs-a2 stale hash
    // into a Hash-mismatch section and reds 41's `!/Hash mismatch/` assert
    // with no behavior change to this fix).
```

**Step 3:** Run BOTH suites. Expected: scenario 41 stays GREEN UNTOUCHED (its Leg-B `-am` block names README.md only — the Leg-A armed pendingRehash re-blesses app.ts to its a2 disk state at the top of the sweep1 op, so no mismatch section; all 41 asserts hold byte-identical pre/post fix). All other scenarios 1–47, 39b green. Unit suite green.

## Task 4: e2e scenario 48 (the #489 pins) + scenario 49 (edges)

**Intent:** End-to-end pinning of T3 + edge behaviors, per suite conventions (one repo per scenario, `session_start` boundaries for #7591 counters, audit reader, D1 bridge rules).
**Acceptance:** Scenarios 48 + 49 green; full e2e suite green.
**Files:**
- Modify: `extensions/verification-gate/index.e2e.test.ts` (append after scenario 47)

**Step 1 — scenario 48 (`(#489): git commit -a / --all sweeps dirty code — working-tree diff scope`):** one repo `repo-489-48`, baseline commits `README.md` ("r1\n") + `src/app.ts` ("a1\n"). Session layout: `session_start` at the start and before Legs B/E/F (suite isolation hygiene — clears verifiedSet + #7591 counters; #7591 auto-bypass is in fact unreachable here — app.ts never exceeds attempt 2 under any layout — so the resets are hygiene, not load-bearing) and before Leg G — where the reset IS load-bearing (see below). TWO load-bearing boundaries: (1) NO `session_start` between Leg B's PASS and Leg C's allow (README's registration must survive `verifiedSet.clear()` into Leg C); (2) Leg G's `session_start` — Leg F's fire-time bridge recovery re-registers app.ts `sha("a4\n")` into the in-memory verifiedSet, and recovery is ADD-ONLY (fire-time match-or-drop drops stale bridge entries but never removes an already-merged in-memory key), so without the G reset the discriminator fire classifies app.ts (disk a5) as a HASH MISMATCH, not unverified — the `!/Hash mismatch/` assert reds. (The pendingRehash-ordering guard — no `session_start` between an ALLOWED real commit and the next sweep's block check — belongs to scenario 41, whose Leg A really commits; in 48 every pre-Leg-C fire is BLOCKED, so no rehash is ever armed there.) The tool_call bridge-recovery at each op targets the SCENARIO repo root and re-merges match-or-drop; every block-expecting leg edits its file to new content first, so old hashes drop against the new content.

- **Leg A (staged docs + dirty code, `-am`, both UNVERIFIED):** stage `README.md` r2; dirty `src/app.ts` a2 (unstaged). Fire `git commit -am "x"` → `block === true`; assert the reason names BOTH `README.md` and `src/app.ts`; assert both appear after the `Unverified files` header; assert NO `Hash mismatch` section (`!/Hash mismatch/` negative — deterministic: fresh repo root, no prior PASS registration). (Pre-fix: reason names only README.md.)
- **Leg B (hole closer — red pre-fix):** `session_start`. Fire `tool_result` VGATE PASS naming ONLY `README.md` (hash `sha("r2\n")`). Fire `git commit -am "x"` → MUST `block === true` naming `src/app.ts` (the docs PASS must not unlock the swept code; pre-fix this fire is ALLOWED and the code ships). (Leg A blocked app.ts in the prior session, but the reset before Leg B keeps this block at attempt 1 in-session — under the 3-attempt threshold.)
- **Leg C (code PASS → allow → real sweep):** Fire `tool_result` VGATE PASS for `src/app.ts` (hash `sha("a2\n")`). Fire `git commit -am "x"` → `equal(undefined)` (allowed — both files verified). Execute the real `git commit -am "x"`; assert `git diff HEAD^ --name-only` lists BOTH README.md and src/app.ts (the allowed sweep committed both — correct: both verified); porcelain clean.
- **Leg D (bare docs commit stays shape-exempt — T3):** edit both (r3/a3); stage README only; fire bare `git commit -m x` → `undefined` + audit `content_shape_exempt` count increased; execute the real bare commit; raw porcelain exactly `" M src/app.ts\n"` (dirty code untouched).
- **Leg E (empty-index sweep — purest variant):** `session_start`; dirty `src/app.ts` a4, nothing staged. Fire `git commit -a -m sweep` → `block === true` naming `src/app.ts` (pre-fix: empty staged diff → allowed → code swept unverified). PASS it; fire again → `undefined`; execute the real `git commit -a -m sweep`; porcelain clean.
- **Leg F (docs-only empty-index sweep — fail-closed friction pin):** `session_start`; edit README r5 (dirty, NOT staged; no code changes). Fire `git commit -a -m docs` → `block === true` naming `README.md` (post-fix: WT scope `[README.md]` non-empty → sweep never exempt (D2) → unverified docs block; pre-fix: empty staged diff → allowed). This is an intentional allow→block flip (fail-closed) — pin it with a comment.
- **Leg G (MIXED chain — union routing e2e pin, added post-test-review P1):** `session_start`; advance HEAD with a RAW commit to never-registered content (README r7 — the Leg-D rehash blessed the old HEAD r3 hash into the durable bridge, so a disk restore to r3 would re-bless via recovery); stage README r8 then restore its DISK content to HEAD r7 (index-only — `git diff HEAD` does NOT list it while `git diff --cached` does; hash never registered); dirty `src/app.ts` a5. Fire `git commit -m "docs" && git commit -am "x"` → `block === true` naming BOTH files (union = staged ∪ WT; a WT-only misroute names only app.ts, a staged-only misroute names only README — the discriminator the classifier-level MIXED pins cannot reach). PASS both (README at its DISK hash `sha("r7\n")` — the union is name-scoped) → fire again → `undefined`; execute the real bare half then the real `-am` half; assert `git diff HEAD^ --name-only` of the `-am` commit lists both files; porcelain clean.

**Step 2 — scenario 49 (`(#489): unborn-HEAD sweep fallback + deleted-tracked sweep`):**
- Sub-case (a) unborn (fallback REGRESSION GUARD — green pre-fix too, since a staged set on unborn already blocks via the staged scope; the red pin for the empty-index sweep is scenario 48 Leg E): fresh repo `repo-489-49a`, `git init` (NO baseline commit); write + stage `README.md` + `src/app.ts`; `session_start`; fire `git commit -a -m first` → `block === true` naming BOTH staged files (the unborn fallback must return the staged set — a naive `git diff HEAD` error→`[]` implementation would under-gate to allow). PASS both → fire → allowed; execute real `git commit -a -m first` → commit created.
- Sub-case (b) deletion: in a second fresh repo `repo-489-49b` with baseline `src/app.ts` committed + registered (PASS before baseline commit per scenario-2 style, or baseline committed via a PASS-allowed flow), `git rm src/app.ts` (staged deletion) + dirty `notes.txt` staged; `session_start`; fire `git commit -a -m del` → the deletion is content-free (verify loop skips unhashable/deleted files — existing catch at the block-check loop), dirty file blocks; assert the block names the dirty file and does NOT name the deleted file; no forever-block on retry.

**Step 3:** Run the full e2e suite — all green (1–49 + 39b), 41 untouched.

## Task 5: Docs clause + full suite + handoff

**Intent:** Behavior documentation sync; green suites.
**Acceptance:** Both suites + drift test green; docs clause present.
**Files:**
- Modify: `skills/commit-workflow/workflow/01-preflight.md` (Verification Gate prose — OUTSIDE the VGATE-SHAPE-RULE fence table)

**Step 1:** In 01-preflight "Verification Gate" prose: (a) the section's opening model sentence ("blocks `git commit` unless every staged file has been verified…") gains the sweep clause — sweep-form commits additionally verify never-staged working-tree files; (b) after the "`-a`/`--all`/`--amend`/pathspec anywhere in the op re-gates the whole command" sentence in the exemption paragraph, add: auto-sweep commit forms (`-a`/`--all`) additionally scope their verification file set to the WORKING TREE (`git diff HEAD` — what the sweep actually records); bare and `--amend` commits keep the staged index (pathspec WT-path commits are #538's tracked residual — the staged index under-gates them). Update the how-to line: "`verify files:` names the files in the block — for `-a`/`--all` commits these may include dirty tracked files never staged."

**Step 2:** Run `npx tsx extensions/verification-gate/index.test.ts` and `npx tsx extensions/verification-gate/index.e2e.test.ts` from the repo root (npm ci prerequisite done) — both green; the VGATE-SHAPE-RULE drift unit test green.

**Step 3:** test-review on the changed test files (hash backstop), then hand off to commit-workflow.

🔍 second-model final gate: clean (3 P3 polish items resolved inline — session-layout rationale, wasted staged subprocess, intent-to-add edge noted in surface map)

### Plan-review cycle log
- Cycle 1: 2 fresh reviewers → 3 P1 (ESM static-import red crash → stub-first TDD; scenario-41 rewrite premise defeated by pendingRehash re-bless → 41 left UNTOUCHED with ordering guard; mixed bare+sweep chains under-gate index-only staged-revert content → tri-state classifier + union) + P2s (session layout, pin gaps incl. -S -a/-u -a false-negative guards, --encoding verify, unborn-detection) — all fixed.
- Cycle 2: 2 fresh reviewers → 0 P0/P1; 5 P2 + P3s (red-state wording, static-import edit naming, merge-scope branch preserve, Leg B counter accounting, 49(a) reframed as regression guard; -C cwd disclosure; 01-preflight opening-model sentence; union name-scoping disclosure; bridge-recovery target note correction; env -i spelling) — all fixed.
- Cycle 3: 2 fresh reviewers → 1 P2 (pathspec commits record WT content — "index precise" claim false; carve-out #538) + 1 P3 (-C residual's true mechanism = interception-pattern non-coverage → #490) — fixed inline.
- 🔍 second-model final gate (deepseek-v4-pro): clean — no P0/P1/P2; core design re-derived correct; 3 P3 polish items resolved inline.

<!-- plan-review: cycles=3, status=clean, version=2.3.0 -->
