---
title: "#559 — verification-gate rename-source shape detection (T1 of #490) — Implementation Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-06
aboutSubjects: organisation-design-team, verification-gate
aboutObjects: agent-infra, issue-559, issue-490, issue-472
---

# Plan — issue #559: verification-gate rename-source shape detection (T1 of #490 — hook integration)

> **Scope signature:** posted on #559 (`<!-- issue-scoping: v5.1 double diamond + verify -->`).
> **Base:** worktree `.worktrees/559` @ a6fda01 (= origin/main, PR #560 merged = #490 T2). Measured baseline: **241 unit / 66 e2e green**.
> **Scope gates:** problem-verify (2 fresh verifiers, clean — no P0/P1; 2×P2 + 1×P4 incorporated); solution-verify (2 fresh verifiers, clean — no P0/P1; P2s/P3s/P4s incorporated); second-model coherence gate (deepseek-v4-pro, clean — 1×P2 incorporated); Phase-7 parallel review (codebase/docs + devil's advocate — P2s incorporated below, cycle-2 re-review to NO ISSUES FOUND).

## 1. Problem statement (corrected from issue body)

The content-shape VGATE exemption is fed by **lossy name-only diff renderers** with two live fail-open holes sharing one root cause:

1. **Rename/copy rows collapse to the NEW path** (`git mv src/app.ts docs/code.md` → name-only lists `docs/code.md` only) — a deliberate code→docs rename rides the docs exemption unverified in every scope arm (staged / sweep-WT / branch / push-range). Empirically confirmed: `--name-status -z` emits `R100\0src/app.ts\0docs/code.md\0`; name-only collapses.
2. **git C-quoting of control/quote/backslash bytes** (any `core.quotepath` setting C-quotes `"`/`\`/control chars; non-ASCII octal-quoted under default quotepath) yields quoted literal path strings that (a) fail `isShapeExemptFile` (extname sees `.md"`) and (b) make `hashFile` throw → the verify loop's `catch { continue }` silently drops the file → false "✅ verified" allow. LIVE-proven: unverified `src/q"name.ts` commits silently today.

**Fix:** switch all four scope producers to `--name-status -z` (raw NUL contract — no quoting/decoding, R/C rows carry old+new) and route the resolved scope through a pure fail-closed gate that (a) measures rename/copy **OLD paths** against the exemption and (b) blocks unconditionally on any NUL-stream anomaly **before** empty-allow / exemption / verify / #7591.

**Tree-observability qualifier (no total-closure claim):** R rows fire only while the rename source exists in a **compared tree** (index/HEAD/range base). In-session/in-range `add→mv` (source never in a compared tree) emits a plain A row — code content docs-shaped at every observable tree is structurally indistinguishable from a docs create. Accepted residual, stated precisely.

**Accepted residuals (documented, not silently absorbed):**
- Copying code into a fresh `.md` (plain A row) — inherent to the Z-NARROW extension-keyed design.
- In-session/in-range add→mv → A-only (tree-observability limit above).
- `diff.renames=false` → D+A split (old path in `files` → gates today — no regression).
- Producer **exec-failure** (git diff subprocess throws/timeouts/EMAXBUFFER) keeps today's status-quo semantics: staged → `{files:[], clean:true}` (commit arm — a broken index fails the commit itself); worktree → logged staged fallback; branch → `{files:[], clean:true}` → empty-allow (pre-existing #472-era catch→[] fail-open precedent; availability rationale: repos whose local `origin/main` ref is absent — non-main default branches, fresh clones — and transient 5s timeouts must not hard-block; pinned as documented residual). **Push-range exec-failure is NOT in this class:** `resolvePushRangeScope` exec-failure → null → staged fallback (fail-closed direction — never an audited allow); the staged fallback's empty-allow on a clean index is the pre-existing #487 tier-C class named below, not a range-execution allow (cycle-2 P4 taxonomy completeness). ⛔ Channel separation by construction: exec-failure and parse-anomaly never share a channel — only parse-anomaly is newly fail-closed. Named here so constraint "NEVER error→allow" is reconciled (it applies to parse anomalies).
- Filenames with **invalid-UTF-8 bytes** (Linux-only; uncreatable on APFS): execSync `encoding:"utf-8"` decodes lossily → U+FFFD → ENOENT → drop → allow — narrowed residual of the C-quote class (valid-UTF-8 names are fully closed). Documented; `encoding:"buffer"`/latin1 noted as future escape hatch.
- Control-char names (newline/tab) parse raw post-fix and block, but cannot round-trip the whitespace-split `verify files:` prompt list → re-block loop (fail-closed friction; #490 plan §8 risk (f)).
- **Out of scope:** single-call compound empty-allow (in-batch state mutation in one tool_call → empty pre-execution scope → allow) — generic pre-execution trust boundary, live-proven, NOT fixable by any rename mechanism; **#540** is its home (OPEN, same class) — referenced, not re-filed. Resolver-null (tier-C first push, tag push, unresolvable refspec) keeps the staged scope — a rename committed on the pushed range is invisible to that scope → empty-allow (pre-existing #487 tier-C acceptance; same generic empty-scope class). #7591 auto-bypass policy itself.

## 2. Solution — Approach A (chosen over B exceptions / C orchestrator)

### 2.1 Pure parser (new, exported)
```ts
export interface DiffScope { files: string[]; renameOldPaths: string[]; clean: boolean }
export function parseDiffNameStatus(out: string): DiffScope
```
NUL-terminated tokens, **no record separator**. Trailing NUL = last token's terminator (split drops the single trailing empty element) — NOT an anomaly. Row grammar (byte-exact, probe-verified): single-path row `A|M|D|T|U|X|B\0<path>\0` (2 NUL fields); rename/copy row `R<score>|C<score>\0<old>\0<new>\0` (3 NUL fields, score = 3-digit zero-padded). `files` = new-path projection (== name-only set on ordinary paths); `renameOldPaths` = R/C old paths. **No quoting/decoding anywhere** — paths raw. `clean=false` only on a NUL-stream anomaly: interior consecutive NUL, final token lacking terminator NUL, R/C token with no score, truncated R/C row (<3 fields), empty path token, unknown status letter. `""` → clean/no rows (empty-allow route). **Multi-row desync is position-validated**: each status slot must match the status alphabet AND its expected field count — a path that happens to look like a status letter in a subsequent row is consumed as a path (its row's status already validated), so synthetic desync input (valid row followed by status-looking path) pins `clean` on genuinely malformed streams only. Producers pass the execSync buffer **untrimmed** (a trailing-space filename is legal; `.trim()` corrupts it → ENOENT → drop — the exact hole class being fixed; the resolver's legacy `.trim()`/`.split("\n")` loop is deleted wholesale, never adapted).

### 2.2 Producers (module-private; replace computeStagedDiff/computeWorktreeDiff/computeBranchDiff ~L1661-1711)
- `runStagedScope(cwd)` = `git diff --cached --name-status -z`; catch → `{files:[], renameOldPaths:[], clean:true}` (today's catch→[] status quo; commit arm — broken index fails the commit itself). Explicitly stated for every producer (review P2).
- `runWorktreeScope(cwd)` = `git diff HEAD --name-status -z`; unborn-HEAD → staged scope; other failure → logged staged fallback (today's L1681-1698 semantics).
- `runBranchScope(cwd)` = `git diff origin/main...HEAD --name-status -z`; catch → clean-empty (documented residual §1; the fail-open precedent computeBranchDiff catch→[] — preserved, pinned as residual, do NOT silently "fix" to parse-block).
- All producers: `execSync(..., { maxBuffer: 64 * 1024 * 1024 })` — EMAXBUFFER (byte-doubled `-z` output on large diffs) routes to the documented exec-failure residual, never a silent mid-stream truncation (review P3).
- `scopeFiles` L78 → `new Set(runStagedScope(projectRoot).files)` — PASS-merge filter, files projection only.
- Mixed-sweep union: `combineScopes(staged, worktree)` — **pure, exported, unit-pinned** (review P3): files dedup union, renameOldPaths union, `clean = clean_staged && clean_worktree`. One staged exec per call (captured in a local, never two).

### 2.3 Push range
- `buildPushRangeDiffCommand(tier, baseRef, src, nameStatusZ = false)`: default preserves the 3 existing exact-argv pins byte-identically. **GOOD>EASY review P2-1 adopted:** add a 4th pin group pinning the `-z` argv forms (tier A space + tier B 3-dot + 3-arg ≡ 4-arg-false equivalence) — a typo'd `-z` argv (`--name-only -z` = valid git, path-only NUL tokens) would parse-block every push; the 3 existing pins cannot catch it.
- `resolvePushRangeFiles` → **`resolvePushRangeScope(command, cwd): DiffScope | null`** (exported, e2e-only — resolveMergeScope/resolvePushRangeFiles precedent): per-refspec `-z` parse, union files + renameOldPaths, `clean` = AND over refspecs. Every existing null condition stays null (→ staged). **`push_range_empty` audit fires only when `clean && files empty`** (a `!clean` empty range emits NO audit — parse-block event is the sole signal; single-audit invariant, review P3). Old exported name dropped (grep-verified zero consumers after hook rewiring).

### 2.4 Pure gate + routing (both exported)
```ts
export type ScopeGateDecision =
  | { kind: "empty-allow" } | { kind: "parse-block"; block: { block: true; reason: string }; event: "gate_block_parse_failure" }
  | { kind: "exempt-allow" } | { kind: "verify" };
export function applyScopeGate(changedFiles, renameOldPaths, clean, bare, isExempt): ScopeGateDecision
```
Precedence IS the function body: (1) `!clean` → **parse-block** — unconditional, terminal, checked FIRST, static reason, never depends on files/bare/exempt (a drift that swallows rows must block, never ride empty/exempt/#7591); (2) `clean && files.length===0` → **empty-allow** (empty-before-exemption ordering preserved — `[].every()` vacuity can never fire); (3) `clean && files.length>0 && bare && files.every(isExempt) && renameOldPaths.every(isExempt)` → **exempt-allow** (non-exempt R/C old path forces gate ON; docs→docs stays exempt); (4) else **verify**.

```ts
export function routeScopeGate(gate: ScopeGateDecision, ctx): undefined | { block: true; reason: string } | { skip: "empty" | "exempt"; files: string[] }
```
Pure consumption helper (review P2/M3 — the hook's ~12-line routing switch is otherwise e2e-unreachable review-only glue): parse-block → carries the event name + block shape + explicitly NO `lastBlockedFiles`/`blockAttempts` writes; empty-allow → `undefined`; exempt-allow → skip metadata (files for the pendingRehash arming); verify → passthrough. Unit-pins all four routes.

### 2.5 Hook wiring (~L2179-2265; surgical inside the #561 zone L1980-2400)
- *(a) Arms block L2179-2218:* assign `let scope: DiffScope`. Pure-sweep → `runWorktreeScope(cwd)`; mixed → `combineScopes(runStagedScope(cwd), runWorktreeScope(cwd))`; gh-pr → merge-scope skip **verbatim** (L2186-2201, scenario 19 pairing — PRESERVE), else `runBranchScope(cwd)`; push → `resolvePushRangeScope(command, cwd) ?? runStagedScope(cwd)`. **Anchor sites identified by semantic content** (empty-allow return + `isBareCommitShape(command) && changedFiles.every(isShapeExemptFile)` guard), not bare line numbers — the line numbers are pre-#561 snapshots (second-model P2).
- *(b) ONE routing site replaces L2220 empty-allow + L2245 guard:* `const gate = applyScopeGate(scope.files, scope.renameOldPaths, scope.clean, isBareCommitShape(command), isShapeExemptFile); const routed = routeScopeGate(gate, …)` — parse-block → `appendJsonl({event: "gate_block_parse_failure", ...})` (shape mirrors logGateSkip L793) + console.log + `return gate.block` (⛔ load-bearing ordering: structurally BEFORE the #7591 blockAttempts region L2292-2321; no counter feed, no lastBlockedFiles — only `ELDATO_SKIP_VGATE` escapes; static non-dispatch reason naming the NUL-grammar anomaly, re-run instruction, no verifier-dispatch template since no verifier can clear it); empty-allow → `return undefined`; exempt-allow → existing branch body verbatim (logGateSkip `content_shape_exempt`, deep-review P2 comment, `isGitCommit` → pendingRehash arming with `scope.files` = new paths, return); verify → fall through with `changedFiles = scope.files`.
- *(c) renameOldPaths NEVER reach verify/hash/naming/lastBlockedFiles* — consumed only by the gate. Everything below L2270-2380 unchanged; the verify loop's `catch { continue }` legitimately remains for real deletions only.
- **#561 coordination (second-model P2 adopted):** whichever of #559/#561 lands second rebases and re-derives the anchored sites + 01-preflight paragraph against the merged head. Never revert #561 work. Merge via `gh pr merge --merge`.

### 2.6 Trust-boundary comment replacement (L2254-2259)
```
// Trust boundary (rewritten for #559): the exemption measures rename/copy
// SOURCE paths alongside destinations — an R/C row whose OLD path is not
// shape-exempt forces the gate ON even when the new path is docs-shaped
// (`git mv src/app.ts docs/code.md` no longer rides the docs exemption).
// Detection is tree-observable, not total: R rows fire only while the
// source exists in a COMPARED tree (index/HEAD/range base); C rows fire
// only when the copied content duplicates the PRE-IMAGE of a file
// modified/deleted in the same diff (no -C is passed; diff.renames=copies
// can still surface C) — a copy of an UNTOUCHED source emits a plain A row.
// Accepted residuals, no total-closure claim: (1) copying code into a fresh
// `.md` (plain A — indistinguishable from a docs create); (2) code content
// whose path is docs-shaped at EVERY observable tree — an in-session/in-range
// add→mv cancels to a plain A row because the source never exists in a
// compared tree (tree-observability limit); (3) valid-UTF-8 path bytes only —
// invalid-UTF-8 names (Linux-only) still decode-loss ENOENT→skip (narrowed
// residual of the C-quote class); (4) producer exec-failure keeps status-quo
// semantics (documented in the plan §1 residual list).
```

## 3. Implementation steps — RED-GREEN

**Honest RED semantics:** the machinery is ABSENT on base → new unit pins are red-by-absence (import/compile failure). **Stub-export first** (parseDiffNameStatus → `{files:[], renameOldPaths:[], clean:false}`; applyScopeGate → `verify`; routeScopeGate → verify passthrough; combineScopes → first arg) so pins go individually red while the suite stays loadable (review P3 — a top-level named import of missing exports is a link-time failure that would stop the whole file). Behavioral reds = e2e legs **64/66/68** (live fail-open today). Legs **65/67** are fixed-verdict GUARDs (see leg audit).

| Leg | Arm | Verdict mutation | Pre-fix | Post-fix |
|---|---|---|---|---|
| 64 | staged (bare commit) | RED | exempt-allow (silent code→docs) | BLOCK naming docs/code.md |
| 65 | staged (BARE commit — docs→docs) | GUARD | exempt-allow + audit | exempt-allow + audit (unchanged) |
| 66 | push-range (tier A) | RED | exempt-allow on range set | BLOCK naming new path |
| 67 | sweep `-am` (code→docs + dirty code) | GUARD | BLOCK (sweeps never bare → never exempt) | BLOCK (unchanged); no parse-block audit |
| 68a | staged (C-quote name) | RED | silent "✅ verified" allow | BLOCK naming raw path |
| 68b | gh-branch (gh pr create) | RED | exempt-allow on branch set | BLOCK naming new path |

Phases (sequential commits, ONE PR `Fixes #559`):
1. **Phase 0:** baseline 241/66 green; grep-verify absence; stub-exports in place.
2. **Phase 1 (RED first):** unit pins G1-G3 + e2e legs 64-68 written against stubs; confirm RED (unit pins individually red on stubs; e2e 64/66/68a/68b red; 65/67 + existing 66 green).
3. **Phase 2:** real `DiffScope` + `parseDiffNameStatus` → G1 green.
4. **Phase 3:** producers + `scopeFiles` `.files` + `combineScopes` → scopeFiles/combine pins green; e2e still red (hook unwired).
5. **Phase 4:** argv `-z` 4th pin group + `resolvePushRangeScope` (rename; audit gated on clean) → G3 green; e2e 50-59 stay green.
6. **Phase 5:** `applyScopeGate` + `routeScopeGate` → G2 green.
7. **Phase 6:** hook wiring §2.5 → e2e 64-68 green; full unit + e2e 1-63 green.
8. **Phase 7:** docs + honesty + this plan filed; drift test green.
9. **Phase 8:** full suites + gates.

## 4. Testing strategy

### 4.1 Unit pins (~34-40 new; 241 existing green)
- **G1 parseDiffNameStatus (~20):** `""` clean/no rows; A/M/D 2-NUL rows; multi-row trailing-NUL → full set clean; R100/C075 3-NUL split (files=[new], renameOldPaths=[old]); score variants; U/X/B/T rows (U reachable — conflicted-merge staged diff; X/B unreachable-but-legal); R projection parity (ordinary paths, qualified); trailing-space path survives (no trim); **multi-row desync** (valid row + status-looking path token → clean); interior consecutive NUL → clean:false; final token no terminator → clean:false; bare R no score → clean:false; truncated R (status + 1 path) → clean:false; empty path token → clean:false; unknown status Q → clean:false.
- **G2 applyScopeGate + routeScopeGate (~14):** empty-allow on `([],[],true)` (bare=false too — empty-before-bare); **parse-block on `([],[],false)`** (vacuous-allow pin); exempt files+clean+bare → exempt-allow; non-exempt file → verify; **`(["docs/new.md"],["src/app.ts"],true)` → verify — the rename hole**; docs old path → exempt-allow; `!clean` + exempt files → parse-block (precedence); `!clean` + "verified" file → parse-block; non-bare + exempt → verify (D2 form guard); parse-block shape deep-equal (event + static reason); statelessness (same input 3× → parse-block, pure analogue of attempts-1-3 no-vacuous-bypass); routeScopeGate 4 routes (parse-block → block shape + NO lastBlockedFiles/blockAttempts keys in ctx; empty → undefined; exempt → skip metadata; verify → passthrough).
- **G3 argv (~4-6):** 3 existing pins byte-green under default; + tier A `-z` exact argv; tier B `-z` exact argv; 3-arg ≡ 4-arg-false equivalence.
- **G4 regressions:** scopeFiles pins, isBareCommitShape/commitSweepClass, parsePushRefSpecs/resolvePushTier, drift test, combineScopes (files dedup, renameOldPaths ∪, clean AND).

### 4.2 E2E legs 64-68 (append after 63; 66 existing + 5 legs = 71 entries; 68 = one entry with 68a/68b halves)
Leg audit (each leg states pre/post verdict + discriminator + bare/sweep class — devil's-advocate M1). Every R-row leg sets `git config diff.renames true` per-repo (M2 isolation — a host `diff.renames=false` collapses R rows to D+A and would silently turn RED legs green; the discriminator-before-verdict asserts catch it loudly as fixture bugs). Each leg fires `session_start` before its first verdict fire and seeds D1 immediately before exempt/allow fires (scenario 56/60 pattern; leg 68's two repo halves are isolated from each other with their own session_start).
- **64 (staged code→docs rename; BARE; RED):** init/base; seed-commit `src/app.ts`; `git config diff.renames true` (**gitconfig isolation — M2**); `git mv src/app.ts docs/code.md`. Discriminators (raw `git()` helpers, un-gated setup): name-status contains R row; name-only lists only `docs/code.md`; fixture-parity `parseDiffNameStatus(...-z).files` == name-only set. D1 sentinel seed. `fire "git commit -m rename"` → **block** naming `docs/code.md`; no added `content_shape_exempt` audit; sentinel untouched. Ceremony half: VGATE PASS on `docs/code.md` → retry → allowed (scenario 62 pattern). **R-row discriminator asserted BEFORE the verdict assert** (fixture self-check — a config-collapsed D+A fixture fails loudly as fixture bug, not gate regression).
- **65 (docs→docs rename; BARE; GUARD):** `git config diff.renames true`; seed `docs/a.md`; `git mv docs/a.md docs/b.md`; R-row assert; `git commit -m rename` (BARE — a sweep would block regardless) → allowed + `content_shape_exempt` + D1 byte-identical.
- **66 (range rename; push arm; RED):** `git config diff.renames true`; init; base commit; `update-ref refs/remotes/origin/main <baseSha>`; commit `src/app.ts`; `update-ref refs/remotes/origin/main <srcSha>` (source now in the compared base tree — in-range create+mv cancels to A-only and the leg would silently pass); `git mv` + **rename commit via raw `git()` helper (un-gated setup — firing it through the hook would block at the staged arm first; M3/leg-construction note)**; discriminator: `git diff refs/remotes/origin/main HEAD --name-status -z` contains R row; `fire "git push origin main"` → block naming `docs/code.md`. docs→docs half with same base placement → push allowed + audit.
- **67 (sweep `-am` code→docs rename + dirty code; GUARD):** staged-only `git mv` (source in HEAD → R fires automatically; no update-ref — that's leg 66's requirement); dirty tracked code file; `fire "git commit -am sweep"` → **block naming the docs path AND the code file** (fixed verdict — sweeps never bare); **assert NO `gate_block_parse_failure` audit** (a broken `-z` grammar would parse-block every sweep — legs 61/62 + this assert form the net).
- **68 (two halves; one entry; both RED):**
  - **68a C-quote raw round-trip:** stage `src/quote"name.ts` — **double-quote char is C-quoted under ANY `core.quotepath`** (quotepath governs only ≥0x80 bytes; verified). Do NOT use a non-ASCII-only name (renders raw under quotepath=false → hashFile works → pre-fix gate blocks → leg green pre-fix = useless red). No quotepath config needed. `fire "git commit"` → pre-fix silent allow (red) / post-fix block; assert `res.reason.includes('src/quote"name.ts')` — RAW byte in the JS literal, never the C-quoted spelling.
  - **68b gh-branch rename:** branch scope merge-base = `origin/main...HEAD` → sandbox origin remote (scenario 19/20/40 mechanics); `git config diff.renames true`; base; `update-ref origin/main <baseSha>`; `checkout -b feat`; commit `src/app.ts`; `update-ref origin/main <srcSha>` (to the SOURCE sha — explicitly NOT scenario-39's pre-branch baseSha placement); `git mv` + rename commit via raw helper; discriminator `git diff origin/main...HEAD --name-status -z` contains R row; `fire "gh pr create --title x --body y"` → block naming `docs/code.md`.
  Audit-count hygiene on every blocked leg (deltas for `content_shape_exempt` + `gate_block_parse_failure`), scenario 56/60 patterns.

### 4.3 Fixture-mechanics + leg-audit review passes (added for proportionality — devil's-advocate M4)
The issue stays complexity:standard (labels unchanged) but the review plan adds: (a) a **leg-audit pass** — every leg 64-68 stated with pre/post verdict, discriminator, bare/sweep class (the table above is that audit); (b) a **fixture-mechanics review pass** at code-review time (the #490 P1 factory: update-ref placement, R-row realism, similarity thresholds). Both ride the existing fresh-context review gates.

## 5. Verification plan
- Unit: `NODE_ENV=test npx tsx index.test.ts` (~275-280 pass / 0 fail).
- E2E: `NODE_ENV=test npx tsx index.e2e.test.ts` (71 entries / 0 fail).
- **RED evidence (run at base `a6fda01`, 2026-09-06):** unit — `SyntaxError: The requested module './index.js' does not provide an export named 'applyScopeGate'` (red-by-absence, machinery absent on base; suite loadable via stub-export phase). E2E — **68 passed / 3 failed**; failures exactly the RED legs: 64 (staged code→docs exempt-allow), 66 (range rename exempt-allow), 68a (C-quote silent allow); GUARD legs 65/67 green pre-fix as designed. Post-fix both suites fully green: **273 unit / 71 e2e**.
- Drift: VGATE-SHAPE-RULE unit drift test green (fence table untouched — prose-only edits).
- Falsification: the fix is falsified if (a) `-z` is lossy for a real valid-UTF-8 path class; (b) an observable-source rename still exempt-rides post-fix (legs 64/66/68b); (c) the tree-observability residual is misdocumented (in-session add→mv is A-only — never claim total closure); (d) legs 64/68a still allow post-fix.
- Gates: fresh-context code-review to verbatim NO ISSUES FOUND (parallel reviewers + fix loop + fixture-mechanics pass + second-model gate via `$SECOND_MODEL` default deepseek/deepseek-v4-pro) → pipeline-compliance `Fixes #559` → record-review.sh at the exact merged head → `gh pr merge --merge`.

## 6. Acceptance criteria
1. G1-G4 green; 241 existing unit + all 66 existing e2e green (41/47/54-59/60-63 the guard net).
2. Code→docs rename with non-exempt source BLOCKS in every arm: staged (64), range (66), branch (68b); sweep (67) is a fixed-verdict GUARD (blocked pre+post by D2).
3. docs→docs (65, BARE) + docs-source range (66 half-b) stay exempt with `content_shape_exempt` + D1 byte-identical.
4. 68a blocks naming the REAL raw path — no silent `catch { continue }` allow.
5. Parse-block unconditional, terminal, first (G2 pins attempts-1-3 statelessness), never feeds `blockAttempts`/`lastBlockedFiles`; routeScopeGate pins the four routes.
6. `push_range_empty` single-audit (gated on clean); pendingRehash arming preserved (exempt + verified arms, new-path keyed); merge-scope skip pairing untouched (scenario 19 green); combineScopes pure-pinned.
7. Docs corrected (01-preflight L344-347 → §1 boundary; exemption sentence; in-code stale comments index.ts L1230-31 + index.test.ts L1747; issue-body corrections posted); drift test green.
8. No #561 work reverted; diff bounded to the listed sites; #559/#561 merge order documented.
9. Fresh-context review NO ISSUES FOUND; `Fixes #559`; record at exact head; merge.

## 7. Docs changes
- `skills/commit-workflow/workflow/01-preflight.md`: L344-347 "(open #490)" drift → §1 boundary wording (cwd-neutral globals NOW intercepted post-T2; `-C`/`--git-dir`/`--work-tree` recognized but un-gated by design — foreign-checkout rationale, fixer-loop ceremony; env-redirects remain intercepted, status quo). Exemption paragraph (~L359-365) gains the rename-source sentence + qualifiers. **VGATE-SHAPE-RULE fence L367-374 untouched.**
- In-code: index.ts L1230-31 + index.test.ts L1747 stale "#490-open" comments → closed/excluded line; trust-boundary comment §2.6.

## 8. Issue-body honesty corrections (#559; posted as a scoping comment + PR body note)
1. "reuse the machinery" FALSE — all T1 symbols grep-verified ABSENT on main; WIP (code-only, regex contradicts the verified alphabet, written against a base that never existed) = intent only.
2. "the verify chain must thread renameOldPaths" WRONG direction — renameOldPaths feed ONLY the gate/exemption decision; the verify chain stays new-path-projection (old paths don't exist on disk; hashing them throws — the exact bug class being removed).
3. Hook has FOUR scope branches (pure-sweep → WT; mixed → combineScopes union; gh-pr → branch after verbatim merge-skip; push → resolvePushRangeScope ?? staged).
4. Parse-block is unconditional + terminal on `!clean`, decided before empty/exempt/verify and structurally before #7591 — not a fall-through chain step.
5. C-quote silent-allow hole NAMED (same root; leg 68a pins it).
6. Stale counts: body's "239/0", "e2e 61/66", "66/66" describe the discarded state; base = 241/66.
7. "PR #xxx" placeholder → #560.
8. No-total-closure qualifier (tree-observability; in-session add→mv = plain A residual).
9. Residuals named: exec-failure channels (status quo, reconciled with NEVER-error→allow = parse anomalies only), invalid-UTF-8 decode-loss class, control-char re-block loop, tier-C committed-rename band (#540/tier-C generic empty-scope class).

## 9. Review cycle log
- **Problem-verify** (2 fresh): cycle 1 → P2 copy-C claim (corrected trust-boundary wording: no -C passed; C fires on pre-image duplication under copies config), P2 error→allow reconciliation (named residuals §1), P4 diverge-artifact preservation. No P0/P1; gate passed.
- **Solution-verify** (2 fresh): cycle 1 → no P0/P1; P2 argv-default seam (G3 4th pin group adopted §2.3), P2 tier-C band (residual §1), P3 trim-deletion explicit, P3 static parse-block message (routeScopeGate §2.4), P3 combineScopes helper, P3 constraint reconciliation (§1), P4s (UTF-8 qualifier §2.6, stale-comment locations, count). Gate passed.
- **Second-model coherence** (deepseek-v4-pro): no P0/P1; P2 #561 landing-order/coordination (§2.5) — semantic-content anchors adopted.
- **Phase-7 review** (codebase/docs + devil's advocate): no P0/P1; adopted — leg 65/67 relabel RED/GUARD with bare/sweep explicitness + leg-audit table (§3), gitconfig isolation `diff.renames true` + R-row-before-verdict self-check (§4.2), routeScopeGate pure helper for the e2e-unreachable hook glue (§2.4), complexity stays standard + fixture-mechanics/leg-audit review passes added (§4.3), branch exec-failure documented residual + pin (gh pr create no-origin-main path named), maxBuffer 64MB + EMAXBUFFER→residual channel (§2.2), invalid-UTF-8 decode-loss residual (§1/§2.6), G1 desync pin (§4.1), 68-construction via raw helper (§4.2), control-char re-block residual (§1), e2e count 71.
- **Cycle-2 re-review** (fresh codebase/docs + devil's advocate): reviewer 1 returned verbatim NO ISSUES FOUND; reviewer 2 zero P0/P1/P2 (3 P3/P4 polish items adopted). Phase 7 exited.

## 10. Fidelity & commit order
Diff bounded to extensions/verification-gate/{index.ts,index.test.ts,index.e2e.test.ts}, skills/commit-workflow/workflow/01-preflight.md, and this plan doc. Sequential commits in ONE PR per §3 phases. No model overrides on review dispatch (deepseek; second-model gate only via `$SECOND_MODEL` default deepseek/deepseek-v4-pro).
