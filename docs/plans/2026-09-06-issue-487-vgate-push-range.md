---
title: "#487 — verification-gate content-push scope (pushed commit range, not the whole index) — Implementation Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-06
aboutSubjects: organisation-design-team, verification-gate
aboutObjects: agent-infra, issue-487, issue-472
---

<!-- research-path: docs/plans/2026-09-06-issue-487-vgate-push-range.md -->

# Issue #487 Implementation Plan — VGATE content-push file set = pushed commit range

> **For Pi:** execute task-by-task; unit + e2e suites must be green before commit.

**Goal:** Content pushes (`git push` with NO `git commit` invocation in the whole command) compute a whole-index staged diff today (index.ts:1615) — another session's parked WIP in the index blocks an unrelated push of already-committed, already-verified HEAD. Post-fix, the push-time file set is the **pushed range**, not the entire index.

**Team:** organisation-design-team
**Issue:** #487 (complexity:standard). **Parent:** #472 follow-up #3 (mechanism-(b) delete-push scope; this is the content-push half).
**Plan-review cycle log:** see `<!-- plan-review:` signature at the bottom (appended after the gate passes).

**Architecture (chosen: A1 "PushScope" pure layer + A2's bounded routing edit — see §Decision):** a pure classifier `parsePushRefSpecs(command)` decides whether the command is an eligible content push and, if so, which refspecs it pushes (merge-scope twin of `evaluateMergeScope`/`commitSweepClass` — I/O separated so the shape/tier tables are unit-testable in a subprocess-free suite); a pure tier resolver `resolvePushTier(trackingExists, baseMainExists)` returns **A | B | C** (4-combo table; the second probe MEANS "the tier-B base ref resolves" — the resolver feeds it after applying the base preference below, so the pure table stays a 2×2); a pure command builder `buildPushRangeDiffCommand(tier, baseRef, src)` emits the exact `git diff` argv (baseRef is fully resolved by the orchestrator — tier A `refs/remotes/<remote>/<dst>`, tier B the chosen first-push base); one I/O orchestrator `resolvePushRangeFiles(command, cwd): string[] | null` probes the repo (tracking refs, tier-B base candidates, src resolution, branch config) and returns the pushed-range file set — **null (→ status-quo staged scope) on every fallback, NEVER `[]` on error**. The hook's routing edit is confined to the trailing `else` of the selector: `changedFiles = resolvePushRangeFiles(command, cwd) ?? computeStagedDiff(cwd);`.

- **Tier A** (tracking ref exists): 2-dot `git diff --name-only refs/remotes/<remote>/<dst> <src>` — the net tree change the remote will gain/lose (2-dot, not 3-dot: on a diverged/force push the remote branch also LOSES remote-side-only files; 3-dot would under-scope them, though those rows are content-free D entries that the disk-hash loop skips anyway — D-row semantics pinned in Task 1, scenario 55 leg (c)).
- **Tier B** (first push: no tracking ref, but the tier-B BASE resolves): 3-dot `git diff --name-only <baseMain>...<src>` where the resolver chooses `<baseMain>` = `refs/remotes/<remote>/main` when the pushed remote ≠ origin AND that ref exists, else `refs/remotes/origin/main` — the second alternative exactly matches the existing `computeBranchDiff` base choice (the DWIM `git diff origin/main...HEAD` at index.ts:1115), so tier B is precedent-aligned for the origin case and the non-origin preference is a one-probe generalization the resolver feeds to the pure table as a single boolean (`baseMainExists`).
- **Tier C** (no usable base): status-quo staged scope — **never `error → []`** (the `computeBranchDiff` catch→[] at ~L1123 is the cautionary fail-open precedent). Tier C is fail-closed: staged scope can only OVER-block relative to range scope (committed content was gate-verified at its own commit time; index-only files are never pushed).
- **Whole-command rule:** any push segment/refspec that cannot map (tag refspec, `--all`/`--tags`/`--mirror`, unknown flag, URL remote, malformed refspec, wrapper push, mixed delete+content) OR any `git commit` invocation anywhere (findGitCommit substring backstop — **wrapper-inclusive**, the P0 guard) OR any gh pr op → the WHOLE command resolves null → staged scope.
- **Untouched:** commit-time whole-index behavior (T2); the #472 mechanism-(b) delete-push short-circuit (returns earlier); the gh-pr branch-diff path (`gh pr create`/merge — computeBranchDiff); the disk-hash verification loop; #7574 pendingRehash stays commit-gated (`isGitCommit`); #7591 auto-bypass counters.
- **Audit:** an empty RESOLVED range (tier A/B ran, union `[]` — an up-to-date push ships nothing) is audited `logGateSkip("push_range_empty", …)` inside the orchestrator, BEFORE the shared silent empty-allow at L1618. Tier-C/status-quo empties stay silent (today's behavior).
- **#490 boundary (boundedness, second-model corrected):** #490 is the INTERCEPTION gap — `GIT_COMMIT_PATTERN`/`isGitOp` (L332-343) don't match global-option spellings (`git -C repo commit …`) — plus rename-source name-status plumbing; `findGitCommit` (L849) ALREADY parses global options (comment L835-836). This plan adds parse/tier/builder helpers + one else-branch line and REUSES `findGitCommit` presence-only — no body edits to `computeStagedDiff`/`computeBranchDiff`/`isBareCommitShape`/`isDeletionPush`; the routing edit is additive within the existing else (L1614-1616) — no hoisted selector, no structural rewrite of the 3-branch chain. ⛔ P0-guard coupling note: the plan's no-commit containment DEPENDS on `findGitCommit` remaining a substring scan. If a future change ever head-anchors it, the wrapper-commit containment (`sh -c 'git commit …'`, `! git commit …`) breaks and those commands would flip staged → range scope (false-allow). That future change is NOT #490; the P0 guard must be preserved independently — recorded here as a coupling constraint for whoever touches `findGitCommit` next.

**Confirmed problem vs T1 hypothesis:** the issue's T1 wording ("HEAD vs origin/<branch> or the refspec's range") is confirmed as the fix direction, but re-derived: the gate intercepts the WHOLE tool_call; the correct discriminator is **no commit invocation anywhere in the command** (wrapper-inclusive). A command that also contains `git commit` ships the index in the same op → staged scope stays correct for it. A pure content push ships committed content only → range scope. That is the routing predicate.

### Pattern Research

> **Findings date:** 2026-09-06
> **Gate skipped: plan touches zero third-party deps** — pure Node stdlib + in-repo helpers. Git semantics (2-dot vs 3-dot diff, `refs/remotes/...` spelling without a configured remote, `update-ref` fixture creation) are verified empirically by the existing e2e harness (scenarios 19/20/39/39b/44-leg4 `remote add origin` + `git update-ref refs/remotes/origin/main <sha>` and diff against that ref) AND by fresh-context solution-verify (both reviewers empirically confirmed in scratch repos that rev-parse/2-dot/3-dot resolve `update-ref`'d full refs with NO configured remote — scenarios 50-55 are the first remotes-less + update-ref fixtures, empirically supported).

### Integration Surface Map

| # | Surface | Boundary | Test layer | Failure modes (≥2) | Covering tests |
|---|---------|----------|------------|--------------------|----------------|
| 1 | `parsePushRefSpecs` classifier (pure) | command → {eligible, refspecs, bare} / reason | unit | false-eligible on commit-bearing or gh-bearing commands (P0 guard: wrapper commit containment); false-eligible on tag/`--all`/`--mirror`/delete-mixed/wrapper-push/URL-remote shapes; false-ineligible on `-u`, `--force-with-lease`, prefix-verb, multi-refspec, `HEAD` src, bare forms | Task 3 pin table (isDeletionPush-section mirror) |
| 2 | `resolvePushTier` (pure) | trackingExists/baseMainExists → A/B/C (second arg = "tier-B base ref resolves", preference already applied by the resolver) | unit | 4-combo mis-tiering (T+T→A, T+F→A, F+T→B, F+F→C); undefined on any input | Task 3 4-combo table + never-undefined fuzz (evaluateMergeScope L1113 mirror) |
| 3 | `buildPushRangeDiffCommand` (pure) | tier + resolved baseRef + src → argv string | unit | wrong base spelling (must be the FULL resolved ref — `refs/remotes/<remote>/<dst>` tier A, `refs/remotes/origin/main` OR `refs/remotes/<remote>/main` tier B — never DWIM); missing 3-dot `...` on tier B; src un-escaped | Task 3 exact-string pins (incl. a non-origin tier-B pin) |
| 4 | `resolvePushRangeFiles` (I/O) | probes + per-refspec diff, union, dedupe | e2e (real repos) | error→[] (must be null→staged); unresolvable src; tag-vs-branch src ambiguity; src=HEAD resolution; dst=HEAD; bare-push config read (remote/merge/src); any single refspec tier C → whole-command C | scenario 53 (tier C guard); scenarios 50-52/54/55; dst=HEAD → residual sentence; mixed-tier multi-refspec cascade → accepted residual (fail-closed; mirrors the resolveMergeScope no-unit-import choice) |
| 5 | Hook routing (else at L1614) | `changedFiles = resolvePushRangeFiles(command, cwd) ?? computeStagedDiff(cwd)` | e2e + unit net | commit/wrapper-commit commands must stay staged (has_commit → null); sweep/mixed routes to earlier branches untouched; gh-pr chains untouched; pure-delete commands never reach here (isDeletionPush returns first) | Task 4; unchanged scenarios 25/44/47 + unit has_commit pins |
| 6 | Exemption interplay | range-scope docs-only set still shape-exempt (isBareCommitShape vacuous on push) | e2e | range vs staged file-set source must not change exemption semantics | scenario 56 (docs-ONLY committed range → content_shape_exempt audit on the RANGE set; MIXED committed range blocks) + scenario 47 stays tier-C-tied (base-less, staged set) |
| 6b | Merge-side scoping asymmetry (plan-review P1) | a push block names COMMITTED range files; a verifier PASS with EMPTY/foreign block context diff-scopes via scopeFiles' `computeStagedDiff` fallback (L78) → committed files never in the staged diff → zero-merge | residual + in-session flow | in-session block→dispatch→retry works (lastBlockedFiles carries the range files into the merge via the blockedSet path — scenario 51 PASS leg pins it); proactive/empty-context PASS for a range file zero-merges → push re-blocks (interactive: #7591 auto-bypass at 3; sub-agent: permanent, return to parent) | scenario 51 PASS leg + accepted-residual sentence |
| 7 | Audit | empty resolved range → `push_range_empty` BEFORE shared silent empty-allow (L1618) | e2e | silent allow on an up-to-date push hides the range decision | scenario 54 |
| 8 | Doc contract | 01-preflight.md "Verification Gate" scope prose | manual/grep (same class as the existing delete-push prose — no machine fence) | doc says "staged check" for content pushes while code uses range scope (or vice versa) | Task 5 + one-time grep for the removed phrase; VGATE-SHAPE-RULE fence (L366-373) untouched (machine-pinned at index.test.ts L2137-2219 — the #472 drift guard); NO new machine pin added for the reworded prose — documented honesty, future drift guard if the phrase regresses |
| 9 | #490 overlap | findGitCommit / name-status / routing region | — | both issues touch index.ts; must stay additive, no shared helper rewrite | boundedness notes Tasks 2-4 |

### Verification Plan

- **Unit** (`index.test.ts`, subprocess-free — no `execSync` import today; verify before adding any): classifier TRUE/FALSE + reason pins, tier 4-combo table, builder exact-string pins, module-load smoke updated. Stub-first (Task 2) so the suite never ESM-crashes on missing exports (the #489 "no clean-red precedent" pattern).
- **E2E** (`index.e2e.test.ts`): scenarios 50–56 appended after scenario 49 (all in dedicated temp repos, `fire("tool_call")` never executes a real push — intercept returns before git runs; the e2e `git()` helper only runs real git for plumbing/allowed-commit execution, never for pushes to the fake remotes). Existing scenarios 25/44-legs1-3/47 get comment-only tier-C-tied annotations; 43/46 untouched (delete-push short-circuit).
- **Drift**: VGATE-SHAPE-RULE fence drift test green (fence pins untouched); no machine-read fence covers the delete/push prose being reworded.
- **Docs**: 01-preflight.md two prose sites (scope clause + "Content pushes keep the staged check") — verified no HTML-comment fence overlap at either site.
- Domain: code (extension) — no UI/UX, data/ontology, or config surfaces.

### Tech Stack

TypeScript extension (`@earendil-works/pi-coding-agent` 0.84.3 types), `node:test` + tsx, git CLI.

### Acceptance Criteria → Issue #487 T1/T2/T3

| #487 test | Criterion | Proven by |
|---|---|---|
| T1 | Non-delete `git push` computes the pushed range instead of `git diff --cached` | Task 3/4 unit pins (tier+builder) + scenario 50 (allow), 51 (block names RANGE file, never the WIP), 52 (tier B first push), 54 (empty-range audit) |
| T2 | Commit-time whole-index behavior unchanged | Unit net + e2e net (scenarios 1–49, incl. 48/49 sweep legs); has_commit pins prove commit-bearing commands never reach range scope; isDeletionPush skip / gh-pr branch path / pendingRehash commit-gating untouched by construction |
| T3 | Parked WIP + content push of committed-verified HEAD → unblocked; parked WIP + commit → still blocked | scenario 50 (push allow + follow-up WIP commit still blocks, mirroring scenario 43's blesses-nothing assert); existing commit-side pins unchanged |

---

## Task 1: e2e scenarios 50–56 (RED pins first) + tier-C-tied annotations

**Intent:** Lock the T1/T3 behavior at the hook level BEFORE implementation; the range-scope scenarios red against today's code (staged scope), scenarios 53/55(b) are the fail-closed regression guards (green pre/post).
**Acceptance:** `cd extensions/verification-gate && npm ci && npx tsx index.test.ts && npx tsx index.e2e.test.ts` (root-relative alternative matching ci-main.yml: `npx tsx extensions/verification-gate/index.e2e.test.ts`) → scenarios 50, 51, 52, 54, 55(a)/(c), 56 FAIL (pre-fix staged scope blocks/allows the wrong way); scenarios 53 and 55(b) PASS; scenarios 1–49 green except none (annotations are comment-only).
**Files touched:** `extensions/verification-gate/index.e2e.test.ts` only.

Fixture pattern (all new scenarios, mirrored on scenario 19/20/39/44-leg4 which `remote add origin` then `update-ref` `refs/remotes/origin/main`; solution-verify empirically confirmed `git rev-parse --verify refs/remotes/origin/main` and 2-dot/3-dot `git diff <ref> <ref>` work WITHOUT a configured remote — the fixtures below are remotes-less by design):

```ts
const repo = join(TEST_ROOT, "repo-487-<n>");
mkdirSync(repo, { recursive: true });
git(repo, "init -b main"); git(repo, "config user.email e2e@test"); git(repo, "config user.name e2e");
// REAL BASE-PRESENT fixture: update-ref origin/main at an ANCESTOR of HEAD so
// the pushed range is NON-EMPTY (update-ref needs NO `remote add`).
writeFileSync(join(repo, "base<n>.ts"), "b\n");
git(repo, "add base<n>.ts"); git(repo, "commit -m base");
const baseSha = git(repo, "rev-parse HEAD");
git(repo, `update-ref refs/remotes/origin/main ${baseSha}`);
```

**Scenario 50 (#487 T3 allow pin — RED pre-fix):** base commit; WRITE + STAGE `content50.ts` (`writeFileSync` + `git(repo, "add content50.ts")` — staging is REQUIRED before the PASS fire: the tool_result JSON-merge with empty block context diff-scopes against the staged set via `scopeFiles` (index.ts:78), so an unstaged file zero-merges and the scenario would red post-fix too); PASS-verify `content50.ts` via `fire("tool_result")`; commit-allow via `fire("tool_call")` + real `git(repo, "commit -m …")` (HEAD now ahead of the base; e2e temp repos have NO pre-commit hooks and `git()` is raw execSync → disk == committed == verified hash — no #7574 reliance); park WIP (`wip50.ts` staged, unverified — never committed); `session_start` (clears verifiedSet + blockAttempts + pendingRehash; in the E2E harness the session_start bridge recovery is rooted at the runner cwd, NOT this repo — the push fire's OWN top-of-op mid-session `recoverBridgeForRoot(cwd)` (L1520s, runs before the diff/verify) re-registers content50 from the PASS merge's `writeBridge` (hash match-or-drop; disk unchanged since the PASS)); fire `git push origin main` → post-fix tier A range `[content50.ts]` (verified, disk-matches) → **`equal(res, undefined)`** (pre-fix: staged `[wip50.ts]` unverified → block — the RED). Then: fire `git commit -m wip` → **still blocks at attempt 1, naming `wip50.ts`** (the push allowed nothing — blesses-nothing mirror of scenario 43). Assert no `delete_push_no_content` skip was recorded for the push fire.

**Scenario 51 (range names the pushed file, never the WIP — RED pre-fix):** base commit; RAW commit adding `content51.ts` (via `git(repo, "commit -m …")` — scenario 44-leg4 precedent: committed-but-never-verified state); `update-ref refs/remotes/origin/main ${baseSha}` (ancestor); park WIP `wip51.ts`; `session_start`; fire `git push origin main` → post-fix tier A range `[content51.ts]` unverified → **block whose reason includes `content51.ts` and NOT `wip51.ts`** (pre-fix: staged names `wip51.ts`, never `content51.ts` — the not-includes + includes asserts both RED). **PASS leg (plan-review P1 — the verify→unblock round-trip on a PUSH-BLOCKED COMMITTED range file):** after the block assert, dispatch `fire("tool_result")` with prompt `[VGATE] verify files: content51.ts … Project root: ${repo}` + JSON verified_files (disk hash of content51.ts), then RETRY `git push origin main` → **`equal(res, undefined)`** (the merge's block context — lastBlockedFiles = [content51.ts] set by the block — keeps the committed range file via scopeFiles' blockedSet path even though it never appears in `git diff --cached`; wip51.ts stays unverified and the retry allow names nothing else). This is the ONLY pin that the merge side accepts committed, never-staged range files — the entire file class the new push-block introduces.

**Scenario 52 (tier B first push — RED pre-fix):** base commit + origin/main at base; `git(repo, "checkout -b feat")`; WRITE + STAGE + PASS-verify `content52.ts` (staging-before-PASS rule as scenario 50); commit-allow + real commit of `content52.ts` on feat; park WIP `wip52.ts`; `session_start`; fire `git push -u origin feat` → NO `refs/remotes/origin/feat` (tracking absent) but origin/main present → tier B 3-dot range `[content52.ts]` verified → **allow** (pre-fix: staged WIP → block — the RED; a tier-C regression would also block → allow proves tier B engaged, not just "not tier A").

**Scenario 53 (tier C fail-closed guard — green pre/post):** fresh repo, NO `update-ref`, NO remote, no tracking refs; committed content + parked WIP; fire `git push origin main` → **block naming `wip53.ts`** (status-quo staged scope). Regression guard: an `error→[]` bug in the resolver would flip this to allow → reds the `block === true` assert. Comment: tier-C-tied by design (no usable base).

**Scenario 54 (empty resolved range audit — RED pre-fix):** base commit; `update-ref refs/remotes/origin/main` AT HEAD (up-to-date push — nothing ships); park WIP; `session_start`; fire `git push origin main` → post-fix tier A resolves (tracking exists, src==dst==HEAD), union `[]` (verified empirically: `git diff --name-only refs/remotes/origin/main main` with tracking == HEAD is empty, exit 0) → **allow** + fresh audit contains `{ event: "gate_skip", reason: "push_range_empty" }` (pre-fix: staged WIP → block — the RED). The resolver's audit runs INSIDE `resolvePushRangeFiles` (it returns `[]` — and `[] ?? staged` keeps `[]`, nullish-coalescing never replaces an empty array) BEFORE the caller's shared silent empty-allow at L1618 fires. Pins the audit-before-shared-silent-empty-allow requirement.

**Scenario 56 (docs-only COMMITTED range → content-shape exemption on the RANGE set):** repo with base commit; commit a code file ahead of base (raw commit — never verified) AND commit `README56.md` docs; `update-ref refs/remotes/origin/main` at the ANCESTOR base; NO staged files; `session_start`; fire `git push origin main` → tier A range = [code file, README56.md] → MIXED set must **block naming BOTH unverified range files — the code file AND the unverified README56.md (mirror scenario 40's both-named includes-asserts: the exemption at L1638 is whole-set only, no per-file exemption inside the block path, so the raw-committed docs file is NOT exempt)**; never exempt on a mixed range. Second fixture (docs-ONLY committed range): commit ONLY a docs file ahead of base, `update-ref` base at ancestor, no staged files, fire `git push origin main` → range all-docs → **allow + fresh audit `{ event: "gate_skip", reason: "content_shape_exempt" }`** — pins the exemption firing on a RANGE-scoped docs set (isBareCommitShape vacuous on pure pushes), closing surface-map row 6's coverage gap (scenario 47 pins only the STAGED-set exemption).

**Scenario 55 (bare-push upstream ceremony + force-push 2-dot legs):** base commit; `update-ref refs/remotes/origin/main` at an ANCESTOR of HEAD; set upstream config `git(repo, "config branch.main.remote origin")` + `git(repo, "config branch.main.merge refs/heads/main")`; WRITE+STAGE+PASS-verify `content55.ts`; commit-allow + real commit; park WIP `wip55.ts`; `session_start`. Leg (a): fire `git push --force-with-lease` (bare push — the 04-merge-deploy.md ceremony L208/L247, upstream set) → tier A range `[content55.ts]` verified → **allow** (RED pre-fix: staged WIP blocks). This is the ONLY pin on the bare-push config-probe I/O path (`branch.<cur>.remote`/`.merge` reads, src = current branch via `symbolic-ref --short HEAD`). Leg (b) negative: `git(repo, "config --unset branch.main.merge")` + fire `git push --force-with-lease` → no upstream merge config → resolver null → tier C staged → **block naming `wip55.ts`** (fail-closed fallback pinned). Leg (c) 2-dot D-row (MANDATORY — plan-review P2; the ONLY pin of deleted-row semantics on the RANGE path, guarding the disk-hash loop's ENOENT skip at L1672-1674 against ever becoming a forever-block on force-push remote-side deletions): after leg (a) (main HEAD contains the content55.ts commit, verified in-memory; wip55.ts STAGED), branch a SIBLING off the ORIGINAL base B with a PATHSpec-limited commit (wip55.ts must NOT be swept into the sibling tree — mirror scenario 44-leg-4's `git(repo, "commit -m sibling55 -- remote55.ts")` precedent, index.e2e.test.ts:1774; a plain `add`+`commit` would sweep the staged wip into the sibling and empty the main index → the scenario would go green pre-fix and the leg would lose its RED): `git(repo, "switch -c remote55 <baseSha>")` … WRITE + `git(repo, "add remote55.ts")` + pathspec commit `remote55.ts` on that branch; `git(repo, "update-ref refs/remotes/origin/main <siblingSha>")` — origin/main now points at a DIVERGED sibling tree (base B is the merge base); `git(repo, "switch main")` (wip55.ts is still staged in the main index — NOT in the sibling tree); fire `git push --force origin main` → **2-dot** diff (refs/remotes/origin/main vs HEAD trees — the space form, NOT `...`) lists `content55.ts` (A-row — content55 commit is in HEAD but not in the sibling tree; verified in-memory from leg (a)) AND `remote55.ts` (D-row — remote-side-only → path absent on disk → hashFile ENOENT → skipped, the existing deleted-file semantics; the D-row comes from the REF tree, never from a local `git rm` — no local delete commit is needed or possible) → **`equal(res, undefined)` and the block reason (if any) contains NEITHER `remote55.ts` NOR `wip55.ts`** (wip is staged but in neither tree — 2-dot never sees it; not-includes is the forever-block guard).

**Comment-only annotations (no assertion changes):**
- Scenario 25 push fire (L892): note the repo is base-less (no `remote add`, no tracking refs) → tier C → status-quo staged scope; green because the staged `fileM.txt` is bridge-registered at session_start. Comment must not claim "push-scope check" semantics that tier C does not exercise.
- Scenario 44 legs 1–3 (L1754): tier-C-tied (no `refs/remotes/*` until leg 4's `update-ref`); legs 2–3 additionally exercise the whole-command mixed-delete rule (`--delete` segment + content segment → classifier returns `mixed_delete` → tier C → staged block stays).
- Scenario 47 (L1921): tier-C-tied — base-less repo keeps the STAGED docs set (the pin's subject); a base-present variant would resolve an empty range (nothing committed) and weaken the exemption pin, so the repo must STAY base-less.

---

## Task 2: Type surface + throwing stubs + red unit section

**Intent:** TDD red without an ESM link crash (the #489 lesson: file-level static named imports hard-crash at link time if the export is missing — mirror its stub-in-same-task pattern). Also the module-load smoke (index.test.ts L529-536 region) must stay green.
**Acceptance:** `npx tsx index.test.ts` → new sections FAIL with the stub throw; the other ~200 tests still green; no module-load crash.
**Files touched:** `extensions/verification-gate/index.ts` (types + throwing stubs + export statements), `extensions/verification-gate/index.test.ts` (import line + pin sections).

Exact new surface (exported from index.ts, additive — no collision with #490's future names):

```ts
export interface PushRefSpec { src: string; dst: string; colon: boolean; }            // src/dst are PLAIN ref names (no colon); colon = refspec had an explicit `:` (split) vs bare same-name form — the resolver's dst=HEAD guard keys off it
export type PushParseResult =
  | { eligible: true; refspecs: PushRefSpec[]; bare: boolean; remote: string | null }
  | { eligible: false; reason: "has_commit" | "has_gh" | "no_push" | "mixed_delete" | "unmappable" | "wrapper" };

export function parsePushRefSpecs(command: string): PushParseResult;             // PURE — splitCommandSegments/stripSegmentHead/tokenizePushArgs/findGitCommit only
export function resolvePushTier(trackingExists: boolean, baseMainExists: boolean): "A" | "B" | "C";  // PURE 4-combo — second arg = "tier-B base ref resolves" (preference applied by the I/O resolver BEFORE the call)
export function buildPushRangeDiffCommand(tier: "A" | "B", baseRef: string, src: string): string; // PURE argv builder — baseRef is the FULLY RESOLVED base ref (never DWIM)
```

Stub bodies `throw new Error("stub")` in Task 2; real bodies in Task 3.

Unit sections (index.test.ts — mirror the isDeletionPush section layout at L1377+, and the evaluateMergeScope 4-combo table at L1037+):
- Section "parsePushRefSpecs — content-push refspec classification (#487)".
- Section "resolvePushTier — tier decision table (#487)".
- Section "buildPushRangeDiffCommand — diff argv spellings (#487)".
Plus update the module-load smoke import list + a smoke `ok(parsePushRefSpecs("git push origin main").eligible === true)` after Task 3.

---

## Task 3: Implement the pure layer — classifier, tier, builder (unit pins green)

**Intent:** Shape + tier + argv contracts locked as pure functions (the `evaluateMergeScope` I/O-separation pattern). No subprocess anywhere in this task.
**Acceptance:** the three new unit sections green; no other unit test changes; `parsePushRefSpecs` has zero execSync reach (code-review checkable).
**Files touched:** `extensions/verification-gate/index.ts` only.

**`parsePushRefSpecs(command)` semantics (whole-command, wrapper-inclusive):**
1. Iterate `splitCommandSegments(command)`; per segment `stripped = stripSegmentHead(segment)`.
2. **P0 guard (commit containment backstop):** `if (findGitCommit(stripped) !== null) return { eligible:false, reason:"has_commit" }` — findGitCommit is a SUBSTRING scan (wrapper-inclusive: `sh -c 'git commit …'`, `! git commit …`, `git -C … commit …` all register), symmetric with the interception surface. A commit anywhere means the command ships the index → staged scope stays correct.
3. **gh op guard:** the `gh pr create|merge` regex (incl. `-R/--repo` global) anywhere → `has_gh` (belt-and-braces — routing already excludes gh commands; keeps the classifier self-contained for unit pins).
4. **Push segment classification** (only head-anchored `/^git\s+push(?=\s|$)/` after strip): tokens = `tokenizePushArgs(rest)`, drop `isRedirectToken`s.
   - Deletion tokens (`--delete`/`-d`, or a refspec starting with `:`) → `mixed_delete`. Pure-delete-only commands never reach here (isDeletionPush short-circuits at L1567) — any delete token in the resolver path implies content+delete mixing → whole-command C (fail-closed, scenario 44 legs 2–3 semantics preserved).
   - Allowed flags (bare-token equality only): `-u`, `--set-upstream`, `-f`, `--force`, `--force-with-lease`. `--force-with-lease=<…>` (startsWith, attached value) and ANY other `-`-token (`--all`, `--tags`, `--mirror`, `--prune`, `--porcelain`…) → `unmappable`.
   - Positionals: first = remote — must match `/^[A-Za-z0-9_.-]+$/` (a URL — contains `/`, `@`, `:` — → `unmappable`). Remaining positionals = refspecs.
   - No positionals → bare candidate (`bare: true`, remote null). Remote + no refspecs → bare with remote fixed.
   - Refspec syntax: no colon → `{src: ref, dst: ref, colon: false}`; exactly one colon → split into src/dst with `colon: true`; >1 colon → `unmappable`. Each side must match `/^[A-Za-z0-9_][A-Za-z0-9_./-]*$/` (quotes already stripped by the tokenizer — a quoted token with an inner space fails the regex → `unmappable`). A `refs/tags/` prefix on EITHER side → `unmappable` (tag push — mandated whole-command C). `HEAD`/`refs/heads/…`/plain branch accepted syntactically (REF SEMANTICS — whether src is a tag/branch/unresolvable — is the resolver's probe job, Task 4; the classifier is syntax-only and honest about it).
   - `\bgit\s+push\b` matched at offset > 0 (wrapper/prose push: `sh -c 'git push …'`, `! git push …`) → `wrapper` (cannot prove shape — fail-closed, symmetric with isDeletionPush's wrapper rule).
5. Non-push segments that are NOT commits/gh-ops are scaffolding (pull/rebase/checkout/branch -D/echo/assignments) and are skipped — symmetric with isDeletionPush D5.
6. Zero classified push segments (prose-only over-interception, `git commit`-only handled above) → `no_push`.
7. Eligible when ≥1 head-anchored content push segment exists, all segments mapped, no has_commit/has_gh. Refspecs accumulate across ALL content segments (multi-push commands union — `git push origin a && git push origin b`).

**`resolvePushTier(trackingExists, baseMainExists)`:** `(T,·)→"A"`, `(F,T)→"B"`, `(F,F)→"C"` — the 4-combo table + a never-undefined input fuzz (evaluateMergeScope L1113-style loop over the 2×2 × nulls). The second argument is fed by the resolver AFTER the tier-B base preference (Task 4 step 3) — the pure table is a 2×2 boolean regardless of WHICH ref won the preference, so no non-origin duplication lives in the pure layer.

**`buildPushRangeDiffCommand(tier, baseRef, src)`** — EXACT strings (unit-pinned; baseRef arrives fully resolved by the orchestrator):
- `"A"` → `` `git diff --name-only ${baseRef} ${src}` `` (2-dot; baseRef = `refs/remotes/${remote}/${dst}` — full tracking-ref spelling, no DWIM — unit pin: `refs/remotes/origin/main feat/487` for remote=origin/dst=main/src=feat/487).
- `"B"` → `` `git diff --name-only ${baseRef}...${src}` `` (3-dot — one argv word, `...` needs no quoting; refs are regex-whitelisted so shell metachars are impossible). Unit pins: `refs/remotes/origin/main...feat/487` (origin) AND `refs/remotes/upstream/main...feat/487` (NON-ORIGIN base — the plan-review P1 wiring: the builder must emit whatever ref the resolver chose; two pins prove the parameter flows, not a hardcoded origin/main).

---

## Task 4: `resolvePushRangeFiles` orchestration + the routing edit (all suites green)

**Intent:** Wire the pure layer to the repo with fail-closed I/O, and route the hook's else-branch through it. T2 safety: commit-bearing commands resolve null fast (classifier, zero subprocess) → staged scope unchanged.
**Acceptance:** `npx tsx index.test.ts` and `npx tsx index.e2e.test.ts` fully green (scenarios 1–49 + 50–56 net); no changes to isDeletionPush/computeBranchDiff/computeStagedDiff bodies or the disk-hash loop.
**Files touched:** `extensions/verification-gate/index.ts` only.

**`resolvePushRangeFiles(command: string, cwd: string): string[] | null`** (exported like `resolveMergeScope`; NOT unit-imported — e2e-only, mirroring resolveMergeScope):
1. `parsed = parsePushRefSpecs(command)`; `!parsed.eligible` → `null` (no subprocess — bare commits hit this in O(scan)).
2. **Bare push (refspecs empty):** `current = execSync("git symbolic-ref --short HEAD")` (detached/failure → null). Remote = `parsed.remote ?? git config branch.<current>.remote` (execSync `git config --get`); merge = `git config --get branch.<current>.merge` → must be `refs/heads/<dst>` (else null). **src = the current branch** (`current` — NOT dst: upstream-config layouts (cur=feat, merge=refs/heads/main) diff the feat tree against refs/remotes/origin/main; the repo's own ceremonies have cur==dst after `-u`, but dst-as-src would silently diff the wrong tree in the general case). Missing remote/merge config → null (git itself would error at runtime; tier C staged is harmless status quo — document the `push.default=current`-without-upstream residual). Covers the real ceremony `git push --force-with-lease` (04-merge-deploy.md L208/L247 — upstream was set by the earlier `git push -u origin <branch>` in 02-commit-pr.md:35).
3. **Per refspec semantic probes** (whole command null on any probe failure — tier C, never []):
   - **src = `HEAD` special-case (solution-verify P2) — NO-COLON refspecs ONLY:** for a positional `HEAD` (no colon), probe `git rev-parse --verify HEAD` and derive dst from `git symbolic-ref --short HEAD` (real git pushes `HEAD` to the current branch's same-name remote branch, never to a branch literally named HEAD). This closes the internal inconsistency where the classifier accepts `HEAD` syntactically (surface-map row 1) but the resolver's `refs/heads/HEAD` probe always failed → tier C friction on a real spelling. ⛔ COLON src=HEAD refspecs (`HEAD:main`, `HEAD:HEAD`) do NOT enter this branch — they fall to the generic src probes below → `refs/heads/HEAD` unresolvable → null → tier C (accepted residual — the L262 mechanism is the spec).
   - Otherwise src resolves: `git rev-parse --verify --quiet refs/heads/<src>` (strip a `refs/heads/` prefix first); on failure probe `refs/tags/<src>` — if the TAG exists → tag push → null; if neither → unresolvable src → null. If BOTH branch and tag resolve (git ambiguity) → null.
   - **dst normalization (plan-review P2/P3 — dst=HEAD guard applies to COLON forms with NON-HEAD src):** strip a `refs/heads/` prefix. For COLON refspecs (src:dst — the classifier carries a `colon` bit on `PushRefSpec`), `dst === "HEAD"` after stripping → treat as unresolvable → null (tier C, fail-closed — a real clone's `refs/remotes/origin/HEAD` is the DEFAULT-branch symbolic ref, and a push targeting a branch literally named HEAD would otherwise silently tier-A against the wrong base). `HEAD:HEAD` (colon) never reaches this guard — it nulls at the generic src probe per the src=HEAD bullet above (colon src=HEAD → refs/heads/HEAD unresolvable); the guard's only live inputs are colon forms with non-HEAD src (`main:HEAD`, `refs/heads/main:HEAD`) plus, defensively, any exotic pair that survives. The NO-colon `HEAD` spelling is handled exclusively by the src=HEAD derivation above. Never probe `refs/remotes/origin/HEAD` for ANY refspec (HEAD as src OR dst — the guard is symmetric).
   - `trackingExists` = rev-parse `refs/remotes/<remote>/<dst>` (dst normalized — refs/heads/ prefix stripped, dst=HEAD already nulled above); tier-B BASE candidate: when remote ≠ origin AND `refs/remotes/<remote>/main` rev-parses → `baseMain = refs/remotes/<remote>/main`, else `baseMain = refs/remotes/origin/main` (may fail to resolve). `baseMainExists` = baseMain rev-parses (probe once per command, cache; the non-origin preference only when remote ≠ origin — origin remotes keep the house origin/main choice). `resolvePushTier(trackingExists, baseMainExists)` per refspec; ANY `"C"` → whole command null.
   - **Record the resolved base per refspec:** tier A baseRef = `refs/remotes/<remote>/<dst>`; tier B baseRef = the chosen `baseMain`. Step 4 diffs use `buildPushRangeDiffCommand(tier, baseRef, src)` — the builder NEVER re-derives the base (plan-review P1: the resolver's preference is dead code unless the chosen ref flows through the argv).
4. **Per-refspec diff:** `execSync(buildPushRangeDiffCommand(tier, baseRef, src), { cwd, encoding:"utf-8", timeout:5000 })` in try/catch — ANY throw → `console.error` + null (the computeBranchDiff catch→[] fail-open precedent at index.ts L1121-1123 inverted). Parse non-empty lines.
5. Union across refspecs, `Set`-dedupe, order-preserving.
6. Union empty → `logGateSkip("push_range_empty", command, cwd, { tier })` and return `[]` (allow — an up-to-date push ships nothing; the audit happens HERE, before the shared silent empty-allow at L1618 sees it).
7. Return the file list. The caller's existing disk-hash loop + content-shape exemption + #7591 counters consume it unchanged (deleted rows in a 2-dot range → ENOENT → hashFile catch → skip — the existing deleted-file semantics; disk-vs-blob 2-dot artifacts remain a documented follow-up, same class as #538).

**Routing edit** — the ONLY hook change. Replace the else at index.ts L1614–1616:

```ts
    } else {
      changedFiles = computeStagedDiff(cwd);
    }
```

with:

```ts
    } else {
      // #487: a content push with NO commit invocation in the command ships the
      // PUSHED RANGE (2-dot vs refs/remotes/<remote>/<dst>, or 3-dot vs
      // refs/remotes/origin/main on first push), not the whole index — another
      // session's parked WIP must not block an unrelated push of already-verified
      // committed HEAD. resolvePushRangeFiles returns null (→ status-quo staged
      // scope below) on EVERY fallback — commit-bearing commands (findGitCommit
      // backstop, wrapper-inclusive), gh ops, tags/--all/--tags/--mirror, mixed
      // delete+content, wrapper pushes, no usable base (tier C), any git failure —
      // NEVER [] on error (the computeBranchDiff catch→[] at index.ts L1121-1123
      // fail-open precedent). An empty RESOLVED range is audited push_range_empty inside.
      changedFiles = resolvePushRangeFiles(command, cwd) ?? computeStagedDiff(cwd);
    }
```

Placement invariants (verify at implementation): the edit sits AFTER the #472 mechanism-(b) delete-push short-circuit (L1567-1571) and AFTER the sweep/gh branches — a pure-delete command never reaches it, a gh-pr chain never reaches it; the shared `changedFiles.length === 0` allow (L1618), the content-shape exemption (L1638), the disk-hash loop, and the verified-allow/pendingRehash arms (isGitCommit-gated — pushes never arm) are all DOWNSTREAM and unchanged.

**In-code doc comments to sync (same task):** the mechanism-(b) comment block above the delete-push skip (still accurate — add one line pointing at the range scope for the content half); the routing-region exemption comment at index.ts L1623-1628 (describes ONLY the commit-form guard — add one clause: the content-push file set is range-scoped with a tier-C staged fallback, so the shape exemption reads the range/diff-derived set the same way it reads the staged set today). Delete the "L362-ish" phrasing target — that section is the `isShapeExemptFile` exports block (L355-380) and contains no "staged diff for commit/push" comment; the only occurrence of that phrase in the repo is 01-preflight.md (Task 5 Site 1's prose).

---

## Task 5: Docs + audit-reason documentation + full suite + handoff

**Intent:** The skill doc contract (01-preflight.md) must state the range scope so agents understand what a push block names, and the plan/audit vocabulary is filed.
**Acceptance:** docs prose updated (verified no machine-read fence touched); full CI command green; verification-before-completion proof recorded.
**Files touched:** `skills/commit-workflow/workflow/01-preflight.md`, this plan doc.

**Site 1 (Verification Gate — content-shape exemption clause, ~L358-360):** current text `"when the op's relevant file set (staged diff for commit/push; branch diff for \`gh pr create\`/merge)"` → `"(staged diff for commit; pushed-range diff for content push — see below; branch diff for \`gh pr create\`/merge)"`. ⛔ The `<!-- VGATE-SHAPE-RULE -->` HTML-comment fence sits ~10 lines BELOW (L366-373 — opener 366, closer 373) — edit text only, never the fence bytes (the drift test pins fence content).

**Site 2 (Delete-shaped pushes paragraph, ~L376-379):** current: `"Content pushes keep the staged check."` (verify exact prose at implementation; grep shows it at 01-preflight.md:379) → replace with the #487 paragraph:
- Content pushes verify the PUSHED RANGE — the files the push actually ships — not the whole index: `git diff refs/remotes/<remote>/<branch> <src>` when the remote-tracking ref exists (2-dot), or 3-dot against the remote's main on a first push (`refs/remotes/<remote>/main` when that ref exists, else the `refs/remotes/origin/main` fallback). A parked-WIP index from another session must not block an unrelated push of already-verified committed HEAD.
- When no usable base exists (no tracking ref and no origin/main) the push keeps the staged check (fail-closed status quo); a whole command containing a `git commit`, a tag/`--all`/`--tags`/`--mirror`, or an unmappable refspec also keeps the staged check.
- An up-to-date push (empty resolved range) is allowed and audited `gate_skip: push_range_empty`.
- Doc the tier-C residual: first push from a fresh `git init` (no fetched origin/main) with parked WIP still blocks (fail-closed friction, same class as #539).

**Audit vocabulary:** `push_range_empty` joins the gate_skip reasons documented in the extension's audit events (in-code comment at `logGateSkip` L553). No registry/audit-logger schema change.

**Verification:** `cd extensions/verification-gate && npm ci && npx tsx index.test.ts && npx tsx index.e2e.test.ts` (root-relative alternative matching ci-main.yml: `npx tsx extensions/verification-gate/index.test.ts` + `npx tsx extensions/verification-gate/index.e2e.test.ts`) green; drift tests green; grep the doc for the removed phrase to confirm no stale "Content pushes keep the staged check" remains anywhere in skills/.

---

## §Decision — approach selection & rejected tradeoffs

**Chosen: A1 "PushScope" (pure classifier + tier + builder, merge-scope twin) + A2's bounded routing edit** (`?? computeStagedDiff` one-liner). Rationale against the mandate's criteria:

- **Correctness / fail-closed coverage of the repo's actual ceremony spellings** (02-commit-pr.md:35 `git push -u origin <branch>`; 01-preflight.md L215 pre-PR `git -c commit.gpgsign=false pull --rebase origin main` — ungated STANDALONE (pull is not a gated verb); 04-merge-deploy.md L208/L247 `git push --force-with-lease`): explicit-refspec pushes (ceremony 1) and config-upstream bare pushes (ceremony 3) BOTH resolve; unmappable shapes (tags, --all/--tags/--mirror, wrapper push, mixed delete+content, URL remotes) and the P0 commit backstop all fall to tier C staged — every fallback is the fail-closed status quo, never `[]`. ⛔ Caveat (consistent with the accepted-residual note): a pull CO-EXISTING with a push in one tool_call trips the classifier's `-c`-value false positive (`commit.gpgsign=false` matches findGitCommit) → has_commit → tier C staged — fail-closed; do NOT "fix" this by head-anchoring findGitCommit or special-casing pull (that would break the P0 wrapper-commit containment).
- **Testability:** the tier cascade and refspec shape are pure and unit-pinned in a subprocess-free suite (index.test.ts has NO execSync today — verified; the house pattern is `evaluateMergeScope`'s pure-decision + e2e-orchestration split). A2 alone would bury the A/B/C table in execSync cascades → only e2e-verifiable via fixture-heavy repos per combo; A3's planner adds a new architectural shape (snapshot + windows) the file has no precedent for.
- **Boundedness vs #490:** one additive else-branch edit + new helpers; `findGitCommit` REUSED presence-only (a #490 head-anchored rewrite cannot flip it); no change to the sweep/gh/delete branch ORDER; the gh-pr branch path, computeStagedDiff/computeBranchDiff bodies, and pendingRehash commit-gating are untouched. A3's hoisted pre-resolution override slot would restructure the guarded 3-branch chain #490 must land next to — the worst overlap of the three.
- **P0 guard pinned wrapper-safe:** the no-commit requirement is enforced by `findGitCommit`'s substring containment (wrapper-inclusive — `sh -c 'git commit …'`/`! git commit …`/`git -C … commit …` all register), the same backstop the file already trusts in isDeletionPush/isBareCommitShape/commitSweepClass; unit-pinned with wrapper fixtures.

**Rejected — A2 "Imperative cascade" (minimal family extension):** smallest diff, but the tier cascade would be an unexported execSync tower — the A/B/C 4-combo table and the refspec-shape table become e2e-only (fixture-heavy, slower to iterate, and the suite's own convention — evaluateMergeScope — exists precisely to avoid I/O-buried decisions). Its "breadth mostly by NOT mapping" leaves ceremony spellings that DON'T match the blessed shapes at tier C forever, with no unit table to grow coverage against. *It WOULD have been better* if #490 had already refactored the routing region (diff-minimization matters most then), or if a second consumer needed only a yes/no push predicate with zero ambition for range correctness.

**Rejected — A3 "Range-override" (command-window snapshot planner):** best subprocess economy (one batched for-each-ref/config/symbolic-ref snapshot per command window) and an explicit union row. But the repo's ceremonies push exactly ONE refspec per command — the batched planner amortizes nothing real, and its hoisted pre-resolution override slot is the largest structural edit to the routing region, directly adjacent to #490's future landing zone. mergeCommandWindow reuse is redundant here: `splitCommandSegments` already gives per-push-segment isolation. *It WOULD have been better* if multi-refspec pushes were a real ceremony profile, if `git diff --name-only` cost on this repo were a measured latency problem (N+1 probes), or if a future issue wanted a holistic per-command git-state planner (then the snapshot abstraction pays for itself).

**Accepted residuals (documented, follow-up-shaped):** tier C friction on first-push-from-fresh-init over parked WIP (fail-closed; mandate-mandated); 2-dot D-rows whose path exists on disk as untracked content (rare false block, disk-vs-blob class — separate follow-up); **2-dot M/A-rows with dirty WORKING TREE** (a range file committed+verified whose disk copy has since been edited-uncommitted → the disk-hash loop mismatch-blocks a push that ships the clean committed blob — same disk-vs-blob class, fail-closed, named here so the follow-up issue has the full family); `push.default=current` bare push without upstream config (tier C); wrapper push `sh -c 'git push …'` (tier C — cannot prove shape, same class as #539); **`HEAD` as src in a COLON refspec (`git push origin HEAD:main`)** → resolver probes refs/heads/HEAD then refs/tags/HEAD → unresolvable → tier C (fail-closed friction; the no-colon HEAD form IS resolved via current-branch derivation — Task 4 step 3); **`HEAD` as DST in a colon refspec (`git push origin main:HEAD`)** → dst-normalization guard nulls the colon+dst=HEAD pair (NON-HEAD src forms — `HEAD:HEAD` never reaches it, nulling at the src probe per the src=HEAD bullet) BEFORE any refs/remotes/origin/HEAD probe (Task 4 step 3 — symmetric with the src guard: the clone's default-branch symbolic ref must never become a tier-A base for a branch literally named HEAD; bare remotes ACCEPT `HEAD:HEAD` (creates a remote branch named HEAD), so the guard is the only protection for `main:HEAD` — fail-closed, no unit pin: resolver-level rule, documented not tested); **mixed-tier multi-refspec push** (`git push origin main feat` where origin/main is absent → tier C for the plain refspec but refs/remotes/origin/feat exists → tier A): ANY tier-C refspec nulls the WHOLE command → status-quo staged scope (fail-closed over-scope; no e2e pin — mirrors the resolveMergeScope no-unit-import choice, recorded here so surface-map row 4 does not overclaim); **any non-whitelisted push flag** (attached `--force-with-lease=<val>`, `-q/--quiet`, `--porcelain`, `--prune`, …) → whole-command tier C (fail-closed; symmetric with isPureDeletionPushSegment's any-other-flag rule — add spellings to the whitelist only when e2e shows agents use them); **findGitCommit `-c`-value false positive** (`git -c commit.gpgsign=false pull --rebase origin main && git push …` → the `-c` VALUE contains `commit.` → has_commit → staged: fail-closed, no regression — today that spelling is staged-gated too; NOT tracked to #490 — it is a findGitCommit-internal false positive, separate from #490's interception gap, recorded here so a future findGitCommit change preserves the P0 guard's substring containment); **heredoc-body over-match** (a `cat <<EOF` body line `git push origin main` splits into a head-anchored segment → classified as a real push — shared pre-existing blind spot with isDeletionPush/commitSweepClass, allow-side only, one sentence documented in Task 3 semantics); **stale remote-tracking ref** (origin/<dst> behind the live remote → tier A 2-dot over-scopes → false block on files already on the remote — fail-closed, self-healing via 01-preflight's mandated pull --rebase pre-push); **merge-side empty-context asymmetry** (surface-map row 6b: a PASS for a push-blocked COMMITTED range file merges ONLY via the in-session block context (lastBlockedFiles) or a bridge write — never via scopeFiles' staged-diff empty-context fallback (L78); proactive/foreign-context passes zero-merge → re-block (interactive: #7591 loop bound; sub-agent: final block, return to parent — the #825 contract); optional follow-up: make the empty-context fallback range-aware); **sub-agent semantics: handled by construction** (range scope is mode-independent — the routing edit precedes the isTaskSubAgent() message split; #7591/#825 block machinery untouched; scenario 25 stays green as tier-C-tied — no sub-agent tier-A/B push scenario pinned, accepted); mixed delete+content chains keep the parked-WIP block on the delete segment (whole-command rule, scenario 44 legs 2-3 pin).

<!-- plan-review: gate PASSED 2026-09-06 (cycle log below) -->

## Plan-review cycle log

| Cycle | Reviewers (fresh task dispatch) | Result | Fix round applied |
|---|---|---|---|
| 1 | Structural/Efficiency + Integration (2) | NO P0; 3 P1 + P2s (scenario 51 PASS leg; scenario 55 in acceptances; scenario 56 added; surface row 6b + merge-side asymmetry residual; Task 4 acceptance range; tier-B non-origin base; dirty-M-row residual; §Decision pull caveat; scenario 50 session_start attribution) | Yes |
| 2 | Structural/Efficiency + Integration (2) | NO P0; 1 P1 (tier-B base preference unexpressible — builder ignored `remote`; resolver probe semantic; no pin) + P2s (scenario 55 leg c contradictory fixture; scenario 56 under-specified both-named; HEAD-as-dst origin/HEAD probe; phantom L362 comment cite; row 8 overclaim) | Yes |
| 3 | Single fresh reviewer | NO P0; 1 P1 (leg-c plain commit sweeps staged wip → green-green) + 5 P2 (3-dot glyph vs 2-dot builder; HEAD:HEAD conflation needs `colon` bit; stale cites ENOENT L1672-74 / else L1614-16 / fence L366-73 / drift L2137-2217; Task 5 Site 2 hardcoded origin/main; dangling §Testing pointer) | Yes |
| 4 | Single fresh reviewer | NO P0; 1 P1 (colon src=HEAD spec split: src=HEAD special case made NO-COLON-only; dst=HEAD guard scoped to colon non-HEAD-src; residual reworded) + 2 P2 (drift span L2137-2219; computeBranchDiff cites 1115 / L1121-1123) | Yes |
| 5 | Single fresh reviewer (convergence) | **NO ISSUES FOUND** (2 sub-P2 cosmetic notes, non-blocking) | — |

Exit conditions met: last reviewer response "NO ISSUES FOUND" verbatim; cycle 1 issues → 4 re-review cycles; cycle log posted (this table).

<!-- plan-review: PASS 2026-09-06 — 5 cycles, fresh reviewers each cycle, convergence on cycle 5 ("NO ISSUES FOUND"). Complexity: standard-tier parallel review. Gate: plan is APPROVED for execution (Tasks 1-5). -->
