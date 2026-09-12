---
title: "#755 — Verification gate: subtract base-identical paths from a merge's scope (Implementation Plan)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-11
aboutSubjects: verification-gate, commit-workflow, organisation-design-team
aboutObjects: agent-infra, issue-755, issue-737, issue-770, issue-790, issue-791
---

# #755 — Verification gate: subtract base-identical paths from a merge's scope

**Issue:** #755 · **Complexity:** standard · **Team:** organisation-design-team
**Supersedes:** the cycle-1..12 accretion of this plan (see git history). Restatement was the defect source; this document states each mechanism **once**.

---

## 1. Problem

When a merge is in progress, `scopeFiles` scopes the verifier to every path that differs from *some* reference. That includes the **trusted base's own delta**, so a merge pulls the whole base-difference into the verifier's file list. The gate floods; the verifier is asked to attest files the branch never touched.

## 2. The rule

**Subtract path `P` from the scope iff ALL of the following hold.** Any unprovable input ⇒ do not subtract (fail closed, over-gate).

| # | Condition | Implements as |
|---|---|---|
| 0 | Exactly one merge base | `mergeBaseCount(T, B) === 1` |
| 1 | `P`'s entry on the recorded side equals its entry on `T` | `P ∉ diff --no-renames --raw -z <T> <recordedSide>` |
| 2 | `P`'s entry on **`B`** equals its entry on `merge-base(T,B)` | `P ∉ diff --no-renames --raw -z <T>...<B>` |
| 3 | `B` is **not** ancestor-or-equal of `T` | `isAncestorOrEqual(B, T) === false` |
| 4 | *(push only)* `T` is an ancestor-or-equal of some **non-first** parent of `srcRef` | `parentRefs(srcRef).slice(1).some(r => isAncestorOrEqual(T, r) === true)` |
| 5 | *(push only)* `trackingRef` is ancestor-or-equal of `B` | `isAncestorOrEqual(trackingRef, B) === true` |
| E | Eligibility: status is `A` or `M` only | `statuses.get(P) ∈ {"A","M"}` |
| F | `P` is a regular file on `T` | mode ∈ `{100644, 100755}` |

Conditions 0–F are the **only** statement of the rule. There is no other normative statement of it anywhere.

Condition 2 names **`B`** explicitly, not "the recorded side": the normative form `diff <T>...<B>` is by definition `diff merge-base(T,B) <B>`, so it tests **`B`'s** entry — which for the `branch` arm happens to equal the recorded side (`HEAD`) but for the `index`/`worktree`/`wtPath` arms does not. Condition 1 is the side-sensitive one and it is stated against the recorded side. Getting this backwards would be an under-gate; as stated, condition 2 can only over-gate.

**Two entry points, because the arms differ structurally (not by a runtime flag):**

- `subtractCommitArm(scope, statuses, ctx)` — conditions **0,1,2,3,E,F**
- `subtractPushArm(scope, statuses, ctx)` — conditions **0,1,2,3,4,5,E,F**

**Filters only.** The subtraction filters the reported file list. It never writes `verifiedSet`, never marks anything verified, never changes `clean`, never touches `renameOldPaths`.

**Subtraction is per-arm, pre-union.** `combineScopes` unions the *kept* sets. No eligibility rule exists at union level (no consumer).

## 3. The seam

An **op-level bundle** is resolved **once per gated git op**; producers receive the **bundle**, never a built context. `SubCtx` values never cross a function boundary — so a valid-but-wrong `recordedSide` has no syntactic representation.

```ts
// subtract-scope.ts — declared once, shared by SubCtx.arm() and SubAudit.arm
type ArmLabel = "staged" | "worktree" | "wtPath" | "branch" | "push";
type RecordedSide = "index" | "worktree" | "wtPath" | "ref";

// op-level, resolved ONCE per gated op
interface SubBundle {
  tOid: string;                                    // trusted base, resolved to an immutable OID
  tRef: string;
  baseEntries: Map<string, { mode: string; blob: string }>;   // 1× ls-tree -r -z <T>
  pairMemo: Map<string, {                          // key `${tOid}..${bOid}`
    mergeBaseCount: number | null;                 // null ⇒ no subtraction
    mergeBaseOid: string | null;
    branchSideChanged: Set<string> | null;         // null ⇒ differsFromBranchSide() → true (safe)
  }>;
}

// built INSIDE each producer — the producer owns `recordedSide` and `arm`
makeGitSubCtx(cwd, {
  bundle, arm: ArmLabel, recordedSide: RecordedSide,
  pathspecs?, srcRef?, trackingRef?, parents?
}): SubCtx | null
```

`ghCommitRecordScope` is a **router** (four delegating returns) with no single `arm`/`recordedSide`: it **only threads the bundle**; each delegate producer builds its own ctx.

**Injected primitives** (raw, not pre-computed booleans) — every one has a declared fail-closed sentinel:

| Primitive | Type | On failure | Effect |
|---|---|---|---|
| `differsFromBase(p)` | `boolean` | **`true`** | condition 1 fails ⇒ no subtraction |
| `differsFromBranchSide(p)` | `boolean` | **`true`** | condition 2 fails ⇒ no subtraction |
| `baseEntry(p)` | `{mode,blob}` \| `null` | `null` | ineligible ⇒ no subtraction |
| `mergeBaseCount()` | `number` \| `null` | `null` | condition 0 fails |
| `mergeBaseOid()` | `string` \| `null` | `null` | audit only |
| `isAncestorOrEqual(a,b)` | `boolean` \| `null` | `null` | (3) passes only on explicit `false`; (4)/(5) only on explicit `true` |
| `parentRefs(ref)` | `string[]` | `[]` | condition 4 unprovable |
| `isShallowRepository()` | `boolean` | **`true`** | no subtraction |
| `arm()` | `ArmLabel` | — | audit only (never branched on) |
| `recordedSide()` | `RecordedSide` | — | audit only |
| `recordedSideRef()` | `string` \| `null` | `null` | audit only |
| `recordedSideOid()` | `string` \| `null` | `null` | audit only |
| `t()` / `b()` | `{ref, oid}` | — | audit only |
| `trackingRefOid()` | `string` \| `null` | `null` | audit only |
| `srcRef()` / `trackingRef()` | `string` \| `null` | `null` | condition 4/5 |

`recordedSideOid()` derivation: `ref` ⇒ `rev-parse`; `index`/`worktree`/`wtPath` ⇒ **`null`** (no read-only OID exists — a worktree-only change reports dst SHA `0000000`, and `GIT_READ_ONLY_VERBS` has no `write-tree`). `SubAudit.r.oid` is therefore `string | null`.

**`--is-ancestor` exit codes are tri-state:** `0`⇒`true`, `1`⇒`false` (a valid negative, **not** a failure), `128`/other/throw⇒`null`. Conflating `1` with `128` inverts guard 3 and enables subtraction on a failed query.

**Refs are resolved to OIDs once**; every membership/tree/merge-base/ancestry query runs off the OIDs, so a concurrent `update-ref` cannot tear a read. **No subtract-path subprocess is ever handed a bare ref name.**

**`trackingRef` is `tracking` exactly as `index.ts:2204` already computes it** — `refs/remotes/${remote}/${dst}`. That local is **also** the tier input (`trackingExists` → `resolvePushTier` → `baseRef`), so it is **not modified**; the pin is that `:2204` stays byte-identical. `srcRef` is never used to derive it.

**Trusted base:** `resolveTrustedBase(cwd)` → `{ref, oid}`: `refs/remotes/<remote>/<branch.<cur>.merge short name, else main>`, `<remote>` from `branch.<current>.remote` else `origin`; fallback `refs/remotes/origin/main`; `null` when neither resolves ⇒ no subtraction. Used by **both** legs so they cannot disagree.

## 4. Audit

`DiffScope` gains **one** optional field: `subtractions?: SubAudit[]`. `combineScopes` concatenates it and reads **nothing else** — null-safe and **absence-preserving** (absent, never `[]`, when nothing was subtracted):

```ts
const subs = [...(a.subtractions ?? []), ...(b.subtractions ?? [])];
return subs.length > 0 ? { ...core, subtractions: subs } : { ...core };
```

`SubAudit`: `{ arm, recordedSide, t: {ref,oid}, b: {ref,oid}, r: {ref,oid: string|null} | null, mergeBaseOid: string|null, trackingRefOid: string|null, perArmSubtracted: string[] }`.

- **Emit site:** between `:3200` and `:3208`, before `applyScopeGate`. `:3199` is *inside* the push branch, so anchoring there would skip every commit arm.
- `subtractedPaths` = `union(perArmSubtracted) \ scope.files`.
- **At most one** `base_identical_satisfied` per op; it **may** co-exist with a per-path reason.
- **The invariant fails closed:** inside each producer, if `files` shrank then `subtractions` must be non-empty; otherwise **return the producer's own unchanged scope — never throw**. (A throw here is fail-closed via pi's `beforeToolCall`, which re-throws and blocks the op; "never throw" is chosen because a clean over-gate with an audit line is a better surface than a hard abort.)
- **Vocabulary:** `SUBTRACT_SKIP_REASONS = ["base_identical_satisfied", "subtract_disabled_by_env"]` exported from `subtract-scope.ts`; `index.ts` declares `GATE_SKIP_REASONS` spreading it plus the 3 existing literals and the 4 `#204` reasons — **9 distinct members, each literal written in exactly one place**.
- Emit reads `for (const a of (scope.subtractions ?? []))`; the push accumulator and both `:2252`/`:2254` returns use `?? []`.

**Kill switch `ELDATO_VGATE_NO_SUBTRACT`:** read **once per op** in the `tool_call` handler before any ctx exists. When set, `sub` is `null` at every position ⇒ today's over-gate scope restored, one audited `subtract_disabled_by_env` line, no `base_identical_satisfied`. Permitted to task sub-agents (it moves toward over-gating).

## 5. Wiring

`parseDiffNameStatusDetailed(output) → { scope, statuses }`; `parseDiffNameStatus` becomes a thin wrapper (`.scope`) so the **seven** full-object `deepEqual` pins stay green. All **five** call sites switch: `:2229` (push), `:2372`, `:2393`, `:2427`, `:2436`.

Producers take `sub?: SubBundle | null`: `runStagedScope:2370`, `runWorktreeScope:2382`, `runWtPathScope:2415`, `runBranchScope:2434`, `ghCommitRecordScope:2449` (+ its routing sites `:2451`/`:2452`/`:2455`/`:2456`/`:2458`), `resolvePushRangeScope:2118`.

**The hook builds the `SubBundle` once** (after `resolveTrustedBase`) and threads it. **No site builds a `SubCtx`.**

**Exactly one bundle-carrying position per arm, and six `null` positions:** `scopeFiles`, the scope-resolution **`??` operand**, and the four internal fallbacks `:2386`/`:2391`/`:2419`/`:2425` (each switches the recorded side to the index — forwarding a mismatched ctx would subtract branch-authored content). The scope-resolution site serves TWO commands and they need DIFFERENT bundles:

```ts
const pushAttempt = parsePushRefSpecs(command).eligible;   // pure classifier, zero subprocess
scope = resolvePushRangeScope(command, cwd, pushAttempt ? sub : null)
        ?? runStagedScope(cwd, pushAttempt ? null : sub);
```

For a **push**, `resolvePushRangeScope` handles it and the operand fires only on an unresolvable tier-C range → **no bundle**. For a **commit**, `resolvePushRangeScope` returns `null` at its eligibility check (it is not a push at all), so the operand IS the commit arm and must carry the bundle. Passing one bundle to both silently disables the entire commit leg while every other test still passes — see §7 finding 1.

**`runBranchScope` is a live arm:** `R = HEAD`, `B = HEAD`, `T` = the resolved trusted base (**not** the hardcoded `origin/main` it diffs). Pinned by a fixture with TWO remotes pointing at different commits, so which one is chosen is observable: the configured `branch.<cur>.remote` wins over the `origin/main` fallback.

**The push arm is only non-inert when `T` ≠ the destination's tracking ref.** Tier A's scope is `diff <tracking> <srcRef>`, so for `git push origin main` (where `T` resolves to the same `refs/remotes/origin/main`) condition (1) is the exact *complement* of scope membership and nothing can ever be subtracted. The arm does its work on a **feature-branch push**, where `T` = the base branch and the tracking ref is the feature's own. Pinned by e2e scenario 80.

**Push leg:** per refspec; `B = srcRef^1`; guards 4/5; tier A only; cross-name refspecs are **not** specially handled (guard 5 evaluates the destination's tracking ref, as today). `push_range_empty` at `:2251` is suppressed when `(union.subtractions?.length ?? 0) !== 0` — when the emptiness was *caused* by subtraction, the single line is `base_identical_satisfied`.

## 6. Tasks

1. **`subtract-scope.ts` + `subtract-scope.test.ts`** — the rule, the sentinel table, `SubAudit` shape, `SUBTRACT_SKIP_REASONS`. `parseDiffNameStatusDetailed` + wrapper in `index.ts`. Parser status-map pins (`A`/`M` eligible; `D`/`T`/`R`/`C`/`U`/`X`/`B` ineligible; `R`/`C` keyed by new path; `anomaly ⇒ partial map`) live in **`index.test.ts`** (the parser lives in `index.ts`, whose `:2` is a *value* SDK import — `subtract-scope.test.ts` must stay SDK-free).
2. **Git adapter** — `makeGitSubCtx`, `resolveTrustedBase`, argv-only `execFileSync`, tri-state, NUL-preserving, no `gitProbe` reuse (binary + `.trim()`). Canonical counts: `diff T <recordedSide>` ×arms, `ls-tree -r -z <T>` ×1, `diff T...B` ×pairs, `merge-base --all` ×pairs. Count pin on a PATH shim; `--is-ancestor` and `rev-parse` are O(arms), excluded. Grammar pins for `ls-tree -z` (split NUL, then first TAB) and `diff --raw -z` (`:old new oldsha newsha status NUL path NUL`) — a missed path makes both conditions hold ⇒ under-gate.
3. **Commit-leg wiring** — producers subtract **their own** scope before returning; kill switch; audit transport; no subtraction after any `combineScopes`.
4. **Push-leg wiring** — per refspec, resolved `srcRef`, union of kept, `push_range_empty` suppression, `:2252`/`:2254` rebuild.
5. **Audit surface** — the emit site, `SubAudit` payload, invariant, vocabulary constant, `GateSkipReason` union (also `decision.reason` callers at `:3147` — declare the 4 `#204` reasons and derive the type).
6. **Failure pins (test-only)** — no-throw; `makeGitSubCtx → null` ⇒ unchanged scope, no audit line; **isolating `pairMemo` pin: fail only the per-pair `diff T...B` with the per-arm diff and `ls-tree` succeeding, assert scope unchanged** (and the symmetric case) — without this an implementation caching an empty `Set` passes everything; kill-switch pin; the `tracking`-derived-from-`dst` source-string pin and the push/commit discrimination pin; per-arm handle requirements (commit arms need no `trackingRef`, so an unpushed branch still subtracts). **Two REAL-GIT pins assert their names:** a gitlink in T is skipped while its sibling regular file still reaches `baseEntries` as a regular-mode entry (the eligibility precondition, which is what the pin asserts); and an all-identical recorded side subtracts (an empty diff is a valid empty result, not a parse failure).
7. **E2E scenarios 77–80** in `index.e2e.test.ts` — 77 merge-in-progress commit leg; 78 kill switch; 79 control for 78 (same fixture, flag unset); **80 the push leg** (feature-branch geometry, since a `git push origin main` push is provably inert — see §5).
8. **CI + tripwire** (`extensions/verification-gate/test-subtract-scope.mjs`, zero-dep, plain `node`, self-excluded from its own scan): forbidden-symbol grep for `subtractFromScope`/`baseEntryMode`/`armKind` across `extensions/verification-gate/` (guards re-introduction, not a current hit); `makeGitSubCtx(` key-set uniqueness **outside the cycle log**; `GATE_SKIP_REASONS` no-duplicate; `SUBTRACT_SKIP_REASONS` ownership; the `:2204` byte-identity, the push/commit discrimination, and the emit-site-outside-the-push-branch source strings; SDK-freeness of the new module and its suite. **Lives under `extensions/verification-gate/` rather than `scripts/` so ci-main.yml's existing `extensions/*/test*.mjs` glob picks it up with no glob change**; also wired explicitly into `ci.yml`'s `verify` job (which performs no `npm ci`) and `ci-main.yml`'s extension-tests job beside the two existing gate suites.
9. **Docs** — `#737` stays open (`parked`; rebase/cherry-pick push-leg is its own deliverable); disclose that the subtraction ships always-on and is invisible at PR time; document `ELDATO_VGATE_NO_SUBTRACT` beside `ELDATO_SKIP_VGATE`.

## 7. Verification

- `cd extensions/verification-gate && npm ci --no-audit --no-fund` → `npx tsx index.test.ts` (301 pass) → `npx tsx index.e2e.test.ts` (85 pass) → `npx tsx subtract-scope.test.ts` (48 pass) → `node extensions/verification-gate/test-subtract-scope.mjs` (all checks pass).
- **Anti-vacuity.** The staged (index) arm has a positive fixture asserting non-empty `subtractions`, not just correct `files` — a `files`-only assertion cannot catch a no-op. The **push** arm's positive fixture is e2e scenario 80. The `worktree`/`wtPath`/`branch` arms are covered only through the arm-agnostic parts (the guards and `subtractForArm`); their arm-specific `rArgs` diff-argument branches are exercised by **no** test. They are *not* claimed as separately pinned — an earlier draft of this line claimed per-arm fixtures that do not exist.
- No typecheck exists (no `tsconfig.json`, no `typescript`); `tsx` erases types, so **every sentinel is enforced by a test, never by an annotation.**

**Implementation status: complete.** 434 tests green (301 + 85 + 48). Findings surfaced *during* implementation and code review that the 12-cycle plan review had not:

1. **The `??` operand serves two commands.** `resolvePushRangeScope(cmd, cwd, sub) ?? runStagedScope(cwd, null)` passes `null` to the fallback for the tier-C push case — but a bare `git commit` *also* returns `null` at the eligibility check, so the commit leg received `null` and never subtracted. This disabled the **entire** commit-side fix while every unit and e2e check still passed. Fixed by discriminating with the pure classifier: `const pushAttempt = parsePushRefSpecs(command).eligible;` then per-branch argument selection. Caught by e2e scenario 77; scenario 79 is its control. A tripwire anchor now pins it.
2. **`clean:false` short-circuited outside the rule.** The guard lived in the `index.ts` wrapper, so a caller reaching the module directly could bypass it. Moved into the module's `run()`.
3. **The tripwire was red at its own commit** — its forbidden-symbol list matched the list itself. Self-exclusion added, with the reason recorded: the cycle-9/11/12 "red at its own document" class, one level up.

Fixture bugs found and fixed while writing scenarios 77–80 (each would have produced a misleadingly-passing test): after a merge, `git diff --cached` shows only the **incoming** side; and the branch must **diverge** from `T` or guard (3) correctly blocks the subtraction.

**Code-review follow-up commit.** The review panel found four more, three of them defects the plan review had reasoned about but never traced:

4. **A gitlink in the trusted base silently disabled subtraction for the whole repo.** `parseLsTreeZ` returned `null` for the entire map on the first non-blob entry, which made `makeSubBundle` return `null` — so in any repo whose base tree contains a submodule, #755 became a silent no-op with no audit line. Guard (F) already excluded such paths per-path, and the comment stated a per-entry intent the code did not implement. Now `continue` (skip the entry), with a REAL-GIT pin that commits an actual gitlink into the trusted base tree, proves the non-blob record is present, and asserts its sibling regular file still reaches `baseEntries`.
5. **An empty diff was treated as a parse failure.** `parseRawZ` rejected a zero-byte stream, so conditions (1)/(2) returned the fail-closed `true` for *every* path whenever the recorded side was wholly identical to `T` — exactly the strongest form of the property this rule exists to detect (e.g. `git checkout <T> -- .` with HEAD still diverged). Now an empty stream is a provably-empty result; only a truncated non-empty stream is an anomaly.
6. **Guard (4) was fed a bare ref name**, contradicting this plan's own OID-pinning invariant, leaving a TOCTOU window: a concurrent `update-ref` could retarget `srcRef` between ctx build and the `rev-list` probe, so guard (4) could pass against a different commit than guards (1)–(3) were evaluated against. Now the parent list comes off the pinned OID. A test caught the follow-on: `parentRefs()` returns parents with token 0 already dropped, so guard (4) still needs `.slice(1)` to exclude the FIRST parent.
7. **The push leg had no end-to-end pin.** Task 7 named a push-leg scenario; the scenario actually written was a control, so half the fix was covered only at the unit level with a hand-built ctx. Adding scenario 80 also surfaced the geometry in §5: the push arm is provably inert for `git push origin main` and only does work on a feature-branch push.

A first attempt at hardening the status parser was built on a **false premise** — that a similarity score appears only on R/C rows. `git diff -B --name-status -z` emits `M<score>` for file rewrites, and the guard would have hard-blocked a legitimate op the moment any gate diff command gained `-B`. Corrected, with the falsified premise recorded in the code. This is the same failure mode that dominated the plan review: **asserting a mechanism without tracing it once** — here caught by a reviewer who traced it against `git-diff(1)` and reproduced it.

**And two of the first versions of the pins above were themselves vacuous**, which is the same failure mode one level down. The gitlink pin wrote the gitlink to the *index* while `makeSubBundle` reads a *committed* tree, so no non-blob record ever reached the parser; the empty-diff pin used a plain overlay `checkout`, which leaves the branch-only file in the index, so the per-arm diff was never empty. Both passed against the pre-fix code. They now assert their own fixtures (`ls-tree` really contains `160000 commit`; the per-arm diff really is zero bytes) and are proven discriminating by **sabotage**: reverting each fix in place makes exactly that pin fail, and only that pin. The general rule this session keeps re-learning: **a test that has not been observed to fail against the broken version is not evidence.**

## 8. Non-goals

Rebase/cherry-pick push-leg de-flooding (#737) · tier A/B/C semantics (unchanged) · `MERGE_HEAD` probing (misses `--squash`/octopus/rebase) · `verifiedSet`/bridge writes (#472 D1) · adding `npm ci` to a PR-triggered job.

## 9. Residuals (open, tracked — not promises)

- **#770** — one-shot merge verbs (`gh pr merge`) are un-gated, so a merge parent is a freely chosen input.
- **#791** — `scopeFiles` stash-recovery lifecycle is unsatisfiable and that path has no audit emit.
- **#772** — `main-worktree-guard`'s text scanner false-positives on quoted git verbs.
- **#771** — `#7591` counter persistence.
- **#773** — `hashFile` throw → silent skip.
- **#790** — `plan-review` can iterate a plan into a state where its length is its dominant defect source.
