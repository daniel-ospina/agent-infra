<!-- research-path: docs/plans/2026-08-10-vgate-extractjson-noise.md (no research brief — zero third-party deps, Node stdlib only) -->

# fix(vgate): extractJson grabs sub-agent stderr gate_bypass JSON — implementation plan (#132)

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** A `[VGATE]` dispatch whose valid verdict JSON is followed by appended stderr noise (the deterministic `{"event":"gate_bypass",...}` object) must register its verification — and real FAIL verdicts and noise-only dispatches must never silently disable the gate.

**Team:** organisation-design-team (issue team unknown — swarm SOR unavailable)
**Role:** (unavailable — omit)

**Architecture:** Approach **A** — schema-gated, string-aware, reverse candidate scan. `extractJson` becomes a candidate *stream* (newest-first) where every step (raw parse, fences, brace-matched reverse scan) is gated by a single usable-result predicate (`isValidResult` + placeholder rejection). Candidates that fail the gate are skipped, never fatal. The handler's FAIL path stops counting dispatch failures; the dead schema-invalid branch (unreachable once extraction is gated) is removed; the PASS reset is guarded by `merged > 0`. ~80–120 line diff, self-contained in `extensions/verification-gate/`.

### Pattern Research

**Library docs (preflight)** — no third-party deps in plan (Node stdlib only: `JSON.parse`, string scanning, existing `node:fs`/`node:crypto` imports). Skipped per writing-plans skip rules.

**Library version & API surface / Idiomatic usage / Pitfalls** — skipped (zero third-party deps). Verification-gate behavior (fail-open ponytail #5724, `vgateFailures` accounting, bridge write) verified directly against `extensions/verification-gate/index.ts` and issue #132's session-log trace.

### Integration Surface Map

| # | Surface | Type | Data Flow | Test Layer | Contract | Key Failure Modes |
|---|---------|------|-----------|-----------|----------|-------------------|
| 1 | `extractJson(text)` — pure parser | State (module-local, pure fn) | In | **Unit** (`index.test.ts`) | `string → VerificationResult \| null`; non-null implies schema-valid + placeholder-free (new invariant) | trailing noise, innermost fragment, braces inside strings, unbalanced prose, multiple candidates, placeholders |
| 2 | `isValidResult(obj)` — schema predicate | Pure | In | **Unit** | `any → boolean`; rejects non-PASS/FAIL status, missing arrays, malformed entries, placeholder path/hash | placeholder `"..."`/`"__placeholder__"`/empty — currently passes (type-only check) |
| 3 | `tool_result` handler — pi event → registry/bridge mutation | Event | In (event) / Out (verifiedSet, bridge file) | **E2E** (existing fake-pi harness, `index.e2e.test.ts`) | `[VGATE]`-detected event with text content → merge or fail-open or FAIL-block; `vgateFailures` counting; disable at 3 | noise-only dispatch, 3× FAIL, zero-merge PASS masking failures, gate disable semantics |
| 4 | Registry (`verifiedSet` Map) + bridge file | State | Out | **E2E** (behavioral: commit allowed/blocked) | Compound keys, repo-relative paths, real sha256 hashes | placeholder hash registered → permanent mismatch block loop |
| 5 | Cross-extension: `loop-enforcer/verifier.ts` (same bug class, #135) | State (other ext) | — | **Not touched in #132** — deferred to #135; extraction seam flagged in code comment | — | — |

### Bug Pattern Flags

- **Silent function skips** (the reported bug): extraction silently returns a schema-invalid object → merge path never executes → `vgateFailures++` → gate silently disables. Required verification: unit tests assert the merge-relevant return value with noise present; e2e asserts the commit unblocks.
- **Conditional guards**: every `vgateFailures++` site and the FAIL carve-out need both-sides coverage (2 vs 3 failures, FAIL vs PASS vs noise). Boundary: `VGATE_FAILURE_THRESHOLD = 3` (tests fire exactly 3).
- **Malformed response handling** (contract checklist): placeholder values, empty `verified_files` (valid!), non-object noise, empty content (existing branch).

### Journey Test Map

### Journey: Verifier dispatch unblocks the commit
1. **Step:** VGATE block on `git commit` → **Acceptance:** commit blocked with named unverified files → **Test:** e2e scenario 1 (existing)
2. **Step:** `task` dispatch returns PASS JSON + stderr noise → **Acceptance:** verification registers; next commit passes without re-dispatch (O/I/T indicator 1) → **Test:** e2e scenario 5 (new)
3. **Step:** Verifier returns FAIL verdict → **Acceptance:** commit stays blocked; gate remains active after 3 FAILs → **Test:** e2e scenario 7 (new)
4. **Step:** Noise-only dispatch (no verdict) → **Acceptance:** fails open per #5724 (prompt-file merge); gate never disables from noise → **Test:** e2e scenario 6 (new)

### Failure Modes
- Noise object parsed as verdict → **Expected:** rejected by gate, older valid candidate wins → **Test:** unit verdict+noise, fence-last-invalid
- Nested object as last element (non-empty `verified_files`) → **Expected:** brace-matched candidates, innermost fails gate, outer wins → **Test:** unit innermost-fragment
- `{` inside a string path → **Expected:** never anchors a slice → **Test:** unit braces-in-strings
- Unbalanced prose → **Expected:** skipped, never aborts → **Test:** unit unbalanced-prose
- 3 genuine dispatch failures interleaved with zero-merge PASS → **Expected:** counter not reset; gate disables at 3 → **Test:** e2e scenario 8

**Tech Stack:** TypeScript (ESM), Node.js built-ins, `tsx` test runner, node:assert. No new dependencies.

---

## Problem Statement

`extractJson` Step 3 (schema-blind last `{…}` pair, `index.ts:288-293`) grabs deterministic `gate_bypass` stderr noise that Pi's `task` tool appends to result content. The parsed noise object is non-null and schema-invalid → the handler skips the plain-text fallback, hits the schema-invalid branch (`index.ts:655-699`), and since the noise has no `status === "PASS"`, increments `vgateFailures` → the gate silently disables after 3 dispatches (observed 2026-08-09, PR tortoise#831). Empirically confirmed in this session:

- verdict + noise → returns the **noise object** (status undefined → invalid → failure count)
- valid verdict with non-empty `verified_files` (no fence/noise) → **null** (innermost fragment `{"path":...}` anchors the slice → parse fails → plain-text fallback) — the existing "last { to } pair" unit test only passes because it uses an **empty** `verified_files` array
- unbalanced trailing prose → **null**

Additionally, legitimate FAIL verdicts increment `vgateFailures` (`index.ts:704`) — 3 real FAILs silently disable the gate. And the PASS reset at `index.ts:714` is unconditional — a zero-merge PASS (all files skipped as not-in-diff) masks real dispatch failures.

## Proposed Solution (Approach A — chosen)

**A.1 — Gated, string-aware, reverse candidate scan in `extractJson`.**
Every step (raw parse, fences newest-first, brace-matched reverse scan) returns only results passing the *usable-result* predicate (`isValidResult` + placeholder rejection). Step 3 replaces `lastIndexOf("{")` slicing with a string-aware brace-matching walk: enumerate every `}` newest-first, find its matching `{` (ignoring braces inside `"…"` strings and `\"` escapes), try the slice, gate it, skip on failure — never abort. Unbalanced prose → skip. Newest-valid-wins semantics, preserving the existing "last fence wins" contract.

**A.2 — Placeholder rejection in `isValidResult`.** Path/hash values of `""`, `"..."`, `"__placeholder__"` are rejected. Rationale: the block message's prompt template literally shows `"hash":"..."` as an example — a literal-LLM response would register a `"..."` hash that never matches any real file hash, causing a permanent block loop. Empty `verified_files` remains valid (consensus). **No hash-format check** (Phase-7 re-review P1 — a 64-hex-only check would reject real 40-char `git rev-parse` SHA-1 hashes and every existing test fixture; a garbage hash already fails closed: it mismatches the real sha256 on the next commit → block → re-dispatch repairs it. Placeholder rejection closes the "..." door; format validation is out of scope).

**A.3 — FAIL carve-out in the handler (`index.ts:702-707`).** A FAIL is a *successful dispatch*: log the failure list, keep blocking (nothing to merge), return without touching `vgateFailures`. No increment, no reset (minimal reading — a FAIL proves nothing about dispatch health; resetting is optional and deferred). Consume `lastBlockedCwd`/`lastBlockedFiles` like every terminal path (#5607).

**A.3b — FAIL-intent detection in the null path (solution-verify P1 + Qwen-gate P0 + Phase-7 P1s).** The schema-valid FAIL carve-out (A.3) only covers well-formed verdicts. A schema-*incomplete* FAIL — `{"status":"FAIL","failures":["x"]}` missing `verified_files` — is rejected by the gated extractor → null → would fall through to the NO-JSON fail-open branch and ALLOW the commit. Fix: in the null path, BEFORE the fail-open prompt-merge, detect FAIL intent in textContent and route to the A.3 carve-out semantics: log the failure, keep blocking, return WITHOUT incrementing `vgateFailures` and WITHOUT merging.

**Detection is STRUCTURAL, not substring-regex** (Phase-7 P1s — substring matching is both over-broad: prefix-matches `FAILED`/`Failure`/`Failing` and quoted prose `"status":"FAIL"` inside a PASS explanation → false hard-block of legit PASSes; and under-broad: misses unquoted-key `{status: "FAIL"}` and single-quoted `{'status':'FAIL'}` — the most plausible lazy-model spellings → still fails open):

```typescript
// Structural FAIL-intent probe for the null path: try to parse each
// brace-balanced candidate un-gated; a parsed object whose status field
// is FAIL (any quoting style: "FAIL", 'FAIL', FAIL) is an explicit
// "don't commit" judgment — block, never fail open.
// Plus the existing line-start/❌ heuristics with a WORD BOUNDARY so
// FAILED/Failure/Failing never match.
const hasFail = /(?:^|\n)\s*FAIL(?:\b|:|—)/i.test(textContent)
  || /❌.*FAIL(?:\b|:|—)/i.test(textContent)
  || /\{\s*['"]?status['"]?\s*:\s*['"]?FAIL['"]?/i.test(textContent);
```

(Placement: the existing `hasPass && !hasFail` branch already handles PASS intent; this new branch catches FAIL intent that today falls through to fail-open. Note: a response with BOTH a line-start PASS and FAIL intent now routes to the FAIL block — an explicit FAIL judgment wins over a bare PASS line. The `\b` boundary means `FAILED`/`Failure`/`Failing` on their own line do NOT block — they are explanatory prose, not verdicts; only `FAIL`, `FAIL:`, `FAIL —` block. The JSON probe requires the object-open brace, so `"status":"FAIL"` quoted inside prose does not match.)

**A.4 — Remove the dead schema-invalid branch (`index.ts:655-700`).** Provably unreachable after A.1: `extractJson` returns either `null` or a usable result, so `!isValidResult(result)` can never be true. The removed branch's routing (schema-invalid PASS → prompt-file fallback merge + reset) is equivalent to the null path reaching the existing NO-JSON fail-open branch (`index.ts:612-653`): same prompt-file merge, same reset, same consume of `lastBlockedCwd`. Keeping two identical-outcome paths rots. (Equivalence note: the trace covers the schema-invalid PASS sub-case; the schema-invalid FAIL sub-case is handled deliberately by A.3b, NOT by fail-open.)

**A.5 — `merged > 0` guard on the PASS reset (`index.ts:714-716`).** Only a merge proves dispatch health. Precedent exists at `index.ts:642` and `index.ts:686`. A zero-merge PASS (all files skipped as not-in-diff) logs a warning and does NOT reset `vgateFailures`. (Phase-7 note: the fail-open prompt-merge reset at `index.ts:645` stays unguarded by design — noise-only fail-open merges are the documented #5724 tolerance; the A.5 guard closes the JSON-PASS masking hole, which is the incident class. The plain-text-PASS merge path never resets — pre-existing asymmetry, flagged for #132 follow-up rather than scope creep.)

**Documented behavior change:** noise-only content now routes to the fail-open prompt-merge (`#5724` ponytail — "better to allow the commit than block on a model JSON-compliance issue") instead of counting a dispatch failure. Net effect: the gate can no longer be silently disabled by noise; this is strictly better and consistent with the documented fail-open philosophy. FAIL-intent text (line-start `FAIL` or `❌ FAIL`) now BLOCKS instead of failing open (A.3b) — an explicit "don't commit" judgment is never a JSON-compliance issue.

**Non-goals:** stderr-trailer stripping (transport fix is #134, emitter guard is #133 — separate issues; the extractor must be robust to any trailing content by contract since the gate is a security boundary); schema-invalid-PASS-specific fallback messaging (subsumed by the null path); interleaving fence/bare-candidate priority by position (step order = confidence order; pathological inputs only).

## Approach Decision — why A, and the rejections

**A wins on every quality criterion:**

- **Outcome quality:** identical fix quality to B for #132 itself, without B's speculative API. Strictly better structure than C: A organizes around the correct mental model (candidate stream + gate), which makes every edge case fall out naturally (nested objects, strings with braces, multiple candidates, unbalanced prose). C's "tight backward loop" is the same algorithm expressed as a position hack — the "less testable structure" the diverge noted — inviting off-by-one/anchor bugs that the candidate model prevents by construction.
- **Edge case handling:** all of C6 covered by construction (string-aware matcher; skip-never-abort; newest-valid-wins; empty-array valid; placeholders rejected at the gate).
- **Failure mode coverage:** removing the unreachable schema-invalid branch eliminates a path whose *existence* is the reason subtle divergence bugs survive (two identical-outcome paths rot differently). The `merged>0` guard closes the masked-failures hole.
- **Future extensibility:** A leaves a documented extraction seam (`findMatchingOpenBrace` + candidate walk, pure functions, no vgate state) — extraction to `extensions/shared/json-scan.ts` becomes a 10-minute refactor in #135 *when a second consumer actually exists* (rule of two). The diff is ~80–120 lines — comparable to C — and lands independently as the consensus requires.

**Rejected: B — shared generic candidate scanner (`extensions/shared/json-scan.ts`).**
*When B WOULD have been better:* if #135 were being planned/implemented in the same effort (same PR or same plan), one scanner + one test file would amortize across both consumers, and the API could be shaped by both consumers' real needs. Also if a third parsing consumer were already in flight, or if `extensions/shared/` already hosted a parser module with conventions.
Rejection: #135 is filed but **not in progress** — speculative generality for an unfunded consumer. Under B, the gating semantics that constitute most of #132's complexity (schema, placeholders, fail-open interplay, `vgateFailures` accounting) stay in verification-gate anyway; only the ~25-line string-aware walk moves. #135's schema differs (`verdict/issues_found/issues/evidence/pre_mortem` vs `status/failures/verified_files`) and its current scan semantics differ (earliest-`{`-wins today) — so #135 still writes its own validation, its own tests, and independently adapts the shared API, which may churn. #133/#134 attack the root cause (noise) and may make #135's parser less urgent, leaving a one-consumer shared module — a textbook premature abstraction.

**Rejected: C — minimal-diff gated ladder.**
*When C WOULD have been better:* if this were a production-incident hotfix with a mandate to minimize touch (gate actively breaking every commit, land in minutes). The preserved ladder shape + inline backward loop is defensible then.
Rejection: same algorithm as A with a worse shape — "inline matching-brace walk" invites position-arithmetic bugs, preserves the duplicated parsing logic across extensions (loop-enforcer keeps its own divergent copy, and divergence is what produced this bug class twice), and its "tight loop" structure is harder to reason about under review. Diff size is not a quality criterion; A's explicit candidate model costs ~30 extra lines and buys testability and reviewer clarity.

**Also rejected (documented):** stripping the stderr trailer from content before parsing — wrong layer (#134's job), unreliable (cannot find "where the verdict ends" without the same brace matching), and weakens the contract that the extractor must survive any trailing content.

---

## Implementation Tasks (TDD order — failing test first)

Branch: `fix/132-vgate-extractjson-noise`. Commits via @commit-workflow.

### Task 1: Write the failing unit tests (RED)

**Intent:** Pin the confirmed failure modes and the new usable-result contract in tests before any implementation changes — this is the regression net that makes the fix reviewable and permanent.
**Acceptance:** `npx tsx index.test.ts` fails on exactly the new tests; all pre-existing tests remain green (no contract change for already-valid inputs).
**Files:**
- Modify: `extensions/verification-gate/index.test.ts`

**Step 1: Add extractJson regression tests** (after the "last-brace extraction" section):

```typescript
section("extractJson — stderr noise regression (#132)");

test("verdict JSON + trailing gate_bypass noise → returns the verdict (not the noise)", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [{ path: "website/index.html", hash: "69c98952..." }] };
  const noise = '⚠️  REVIEW GATES DISABLED — all quality checks bypassed...\n' +
    '{"event":"gate_bypass","reason":"escape_hatch","timestamp":"2026-08-09T22:48:04.139Z"}';
  const result = extractJson(JSON.stringify(verdict) + "\n" + noise);
  ok(result !== null, "must extract the verdict, not return null");
  equal(result!.status, "PASS");
  equal(result!.verified_files[0].path, "website/index.html");
});

test("FAIL verdict + noise → FAIL verdict", () => {
  const verdict = { status: "FAIL", failures: ["lint error"], verified_files: [] };
  const noise = '{"event":"gate_bypass","reason":"escape_hatch"}';
  const result = extractJson(JSON.stringify(verdict) + "\n" + noise);
  ok(result !== null);
  equal(result!.status, "FAIL");
  equal(result!.failures[0], "lint error");
});

test("noise-only content → null", () => {
  equal(extractJson('{"event":"gate_bypass","reason":"escape_hatch"}'), null);
});

test("innermost-fragment regression: non-empty verified_files parses (no fence, no noise)", () => {
  const input = 'Here is the result: {"status":"PASS","failures":[],"verified_files":[{"path":"foo.ts","hash":"abc"}]} and some trailing text';
  const result = extractJson(input);
  ok(result !== null, "the trailing nested object must not anchor the slice");
  equal(result!.status, "PASS");
  equal(result!.verified_files.length, 1);
});

test("multiple fences: last fence schema-invalid → earlier valid fence wins", () => {
  const input = '```json\n{"status":"PASS","failures":[],"verified_files":[]}\n```\nthen\n```json\n{"event":"gate_bypass"}\n```';
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "PASS");
});

test("braces inside string values never anchor a candidate", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [{ path: "src/a/{b}/c.ts", hash: "h1" }] };
  const input = 'Result: ' + JSON.stringify(verdict) + ' done';
  const result = extractJson(input);
  ok(result !== null, "must still extract despite { inside path string");
  equal(result!.verified_files[0].path, "src/a/{b}/c.ts");
});

test("unbalanced trailing prose is skipped, not fatal", () => {
  const input = '{"status":"PASS","failures":[],"verified_files":[]}\n\nAnd then: { just prose';
  const result = extractJson(input);
  ok(result !== null);
  equal(result!.status, "PASS");
});

test("placeholder path/hash (…) → null", () => {
  equal(extractJson('{"status":"PASS","failures":[],"verified_files":[{"path":"...","hash":"..."}]}'), null);
});

test("placeholder __placeholder__ / empty values → null", () => {
  equal(extractJson('{"status":"PASS","failures":[],"verified_files":[{"path":"__placeholder__","hash":""}]}'), null);
});

test("empty verified_files stays valid even with trailing noise", () => {
  const input = '{"status":"PASS","failures":[],"verified_files":[]} trailing noise {"event":"x"}';
  const result = extractJson(input);
  ok(result !== null, "empty verified_files must remain a valid result");
  equal(result!.status, "PASS");
});

test("schema-incomplete FAIL (missing verified_files) → null (A.3b routes it at handler)", () => {
  equal(extractJson('{"status":"FAIL","failures":["lint error"]}'), null);
});

test("schema-incomplete PASS (missing arrays) → null (A.4 equivalence input)", () => {
  equal(extractJson('{"status":"PASS"}'), null);
});

test("plain-text PASS line + trailing noise → null (A.3b plain-text merge path)", () => {
  equal(extractJson('PASS\n{"event":"gate_bypass","reason":"escape_hatch"}'), null);
});

test("} inside a string value never anchors a candidate", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [{ path: "src/a}b/c.ts", hash: "h1" }] };
  const input = 'Result: ' + JSON.stringify(verdict) + ' done';
  const result = extractJson(input);
  ok(result !== null, "must still extract despite } inside path string");
  equal(result!.verified_files[0].path, "src/a}b/c.ts");
});

test("escaped quotes (\\) and backslash parity inside strings never corrupt candidates", () => {
  const verdict = { status: "PASS", failures: ["line \"quoted\" and \\\\ backslash"], verified_files: [{ path: "a.ts", hash: "h1" }] };
  const input = JSON.stringify(verdict) + '\ntrailing {"event":"x"}';
  const result = extractJson(input);
  ok(result !== null, "escaped-quote/backslash content must not mis-anchor");
  equal(result!.status, "PASS");
});

test("verdict + placeholder echo AFTER verdict → verdict wins (reverse scan skip-and-continue)", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [{ path: "foo.ts", hash: "abc" }] };
  const echo = '{"status":"PASS","failures":[],"verified_files":[{"path":"...","hash":"..."}]}';
  const result = extractJson(JSON.stringify(verdict) + "\n" + echo);
  ok(result !== null, "placeholder echo must be skipped, real verdict wins");
  equal(result!.verified_files[0].path, "foo.ts");
});

test("trailing prose with } only (no balanced pair) → verdict still wins", () => {
  const verdict = { status: "PASS", failures: [], verified_files: [] };
  const result = extractJson(JSON.stringify(verdict) + "\ndone }");
  ok(result !== null);
  equal(result!.status, "PASS");
});
```

**Step 2: Add isValidResult placeholder tests** (after the "isValidResult — invalid results" section):

```typescript
section("isValidResult — placeholder rejection (#132)");

test("rejects '...' path", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: "...", hash: "abc" }] }), false);
});
test("rejects '...' hash", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: "a.ts", hash: "..." }] }), false);
});
test("rejects empty hash", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: "a.ts", hash: "" }] }), false);
});
test("rejects __placeholder__ path", () => {
  equal(isValidResult({ status: "PASS", failures: [], verified_files: [{ path: "__placeholder__", hash: "abc" }] }), false);
});
test("empty verified_files remains valid", () => {
  ok(isValidResult({ status: "PASS", failures: [], verified_files: [] }));
});
```

**Step 3: Run and confirm RED**

```bash
cd extensions/verification-gate && npx tsx index.test.ts
```
Expected: the 22 new tests fail (noise → noise object or null; innermost fragment → null; placeholders → accepted; fence-last-invalid → returns noise object; schema-incomplete PASS/FAIL → non-null today; plain-text-PASS+noise → noise object today). All 67 pre-existing tests stay green.

### Task 2: Write the failing e2e scenarios (RED)

**Intent:** Reproduce the full incident path (block → dispatch with noise → commit) and the gate-liveness guarantees through the real plugin factory, before touching the implementation.
**Acceptance:** `env -u ELDATO_SKIP_VGATE npx tsx index.e2e.test.ts` fails on scenarios 5–7 only; scenarios 1–4 + bridge test stay green.
**Files:**
- Modify: `extensions/verification-gate/index.e2e.test.ts`

**Step 1: Guard the harness against env leakage** (top of `main()`, before plugin load):

```typescript
// #132: gate-liveness scenarios must run with the gate ENABLED.
delete process.env.ELDATO_SKIP_VGATE;
```

**Step 2: Add scenarios 5–12** (before the final bridge-file test). Isolation pattern per scenario (Phase-7 re-review P1): every scenario starts with `git(repo, "reset -q")` (clears staged files from prior blocked scenarios AND clears `pendingRehash`) then `await fire("session_start", {})` (resets `vgateFailures` / `blockAttempts`), then writes its own file and `git add`s it. Scenarios 6–12 follow the same pattern as scenario 5. Scenarios 8–12 also end with `session_start` to restore gate state for the remaining harness assertions:

```typescript
section("Issue #132 — stderr noise, FAIL verdicts, failure-counter hygiene");

test("scenario 5 (#132 repro): PASS verdict + gate_bypass noise unblocks the commit", async () => {
  const repo = join(TEST_ROOT, "repo");
  // Isolation (Phase-7 re-review P1): scenario 4's allowed commit left
  // pendingRehash set and fileA staged+verified — reset + session_start
  // clears both so the first commit below is genuinely blocked.
  git(repo, "reset -q");
  await fire("session_start", {});
  writeFileSync(join(repo, "fileA.txt"), "v5\n");
  git(repo, "add fileA.txt");
  const blocked = await fire("tool_call", {
    type: "tool_call", toolName: "bash",
    input: { command: "git commit -m 'c5'", cwd: repo },
  });
  ok(blocked && blocked.block === true, "must be blocked first");
  const verdict = JSON.stringify({ status: "PASS", failures: [], verified_files: [{ path: join(repo, "fileA.txt"), hash: sha("v5\n") }] });
  const noise = '\n⚠️  REVIEW GATES DISABLED — all quality checks bypassed...\n' +
    '{"event":"gate_bypass","reason":"escape_hatch","timestamp":"2026-08-09T22:48:04.139Z"}';
  await fire("tool_result", {
    toolName: "task",
    input: { prompt: `[VGATE] verify files: fileA.txt. Classification: UI. Project root: ${repo}` },
    content: [{ type: "text", text: verdict + noise }],
  });
  const res = await fire("tool_call", {
    type: "tool_call", toolName: "bash",
    input: { command: "git commit -m 'c5'", cwd: repo },
  });
  equal(res, undefined, "commit must be ALLOWED after PASS+noise (O/I/T indicator 1)");
  git(repo, "commit -m c5");
});

test("scenario 6 (#132): 3× noise-only dispatches never disable the gate", async () => {
  const repo = join(TEST_ROOT, "repo");
  const noise = '{"event":"gate_bypass","reason":"escape_hatch"}';
  // Noise-only dispatches fail open (prompt-file merge, #5724) — they must
  // neither disable the gate nor accumulate dispatch failures.
  for (let i = 0; i < 3; i++) {
    writeFileSync(join(repo, "fileC.txt"), `c${i}\n`);
    git(repo, "add fileC.txt");
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: fileC.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: noise }],
    });
  }
  // A disabled gate would allow anything — a NEW unverified file proves liveness.
  writeFileSync(join(repo, "fileE.txt"), "e1\n");
  git(repo, "add fileE.txt");
  const res = await fire("tool_call", {
    type: "tool_call", toolName: "bash",
    input: { command: "git commit -m 'c6'", cwd: repo },
  });
  ok(res && res.block === true, "gate must still be active after 3 noise-only dispatches");
});

test("scenario 7 (#132): 3× FAIL verdicts never disable the gate", async () => {
  const repo = join(TEST_ROOT, "repo");
  writeFileSync(join(repo, "fileD.txt"), "d1\n");
  git(repo, "add fileD.txt");
  const failJson = JSON.stringify({ status: "FAIL", failures: ["test failed"], verified_files: [] });
  for (let i = 0; i < 3; i++) {
    await fire("tool_result", {
      toolName: "task",
      input: { prompt: `[VGATE] verify files: fileD.txt. Classification: UI. Project root: ${repo}` },
      content: [{ type: "text", text: failJson }],
    });
  }
  const res = await fire("tool_call", {
    type: "tool_call", toolName: "bash",
    input: { command: "git commit -m 'c7'", cwd: repo },
  });
  ok(res && res.block === true, "gate must still be active after 3 FAIL verdicts");
});

test("scenario 8 (#132): zero-merge PASS does not mask dispatch failures", async () => {
  const repo = join(TEST_ROOT, "repo");
  writeFileSync(join(repo, "fileF.txt"), "f1\n");
  git(repo, "add fileF.txt");
  const prompt = `[VGATE] verify files: fileF.txt. Classification: UI. Project root: ${repo}`;
  // 2 genuine dispatch failures (empty content)
  await fire("tool_result", { toolName: "task", input: { prompt }, content: [] });
  await fire("tool_result", { toolName: "task", input: { prompt }, content: [] });
  // A PASS whose verified_files are entirely outside the blocked diff → merged = 0
  await fire("tool_result", {
    toolName: "task", input: { prompt },
    content: [{ type: "text", text: JSON.stringify({ status: "PASS", failures: [], verified_files: [{ path: join(repo, "somewhere-else.txt"), hash: "deadbeef" }] }) }],
  });
  // 3rd genuine failure → threshold (3) reached → gate must disable
  await fire("tool_result", { toolName: "task", input: { prompt }, content: [] });
  const res = await fire("tool_call", {
    type: "tool_call", toolName: "bash",
    input: { command: "git commit -m 'c8'", cwd: repo },
  });
  equal(res, undefined, "gate must DISABLE after 3 real failures despite interleaved zero-merge PASS");
  await fire("session_start", {}); // restore enabled state for remaining harness assertions
});

test("scenario 9 (#132 A.3b): schema-incomplete FAIL JSON keeps commit blocked, gate never disables", async () => {
  const repo = join(TEST_ROOT, "repo");
  writeFileSync(join(repo, "fileG.txt"), "g1\n");
  git(repo, "add fileG.txt");
  const prompt = `[VGATE] verify files: fileG.txt. Classification: UI. Project root: ${repo}`;
  for (let i = 0; i < 3; i++) {
    await fire("tool_result", {
      toolName: "task", input: { prompt },
      content: [{ type: "text", text: JSON.stringify({ status: "FAIL", failures: ["lint error"] }) }],
    });
  }
  const res = await fire("tool_call", {
    type: "tool_call", toolName: "bash",
    input: { command: "git commit -m 'c9'", cwd: repo },
  });
  ok(res && res.block === true, "schema-incomplete FAIL must block — never fail open, never disable");
  await fire("session_start", {});
});

test("scenario 10 (#132 A.3b): plain-text FAIL line blocks instead of failing open", async () => {
  const repo = join(TEST_ROOT, "repo");
  writeFileSync(join(repo, "fileH.txt"), "h1\n");
  git(repo, "add fileH.txt");
  const prompt = `[VGATE] verify files: fileH.txt. Classification: UI. Project root: ${repo}`;
  await fire("tool_result", {
    toolName: "task", input: { prompt },
    content: [{ type: "text", text: "❌ FAIL: tests broken" }],
  });
  const res = await fire("tool_call", {
    type: "tool_call", toolName: "bash",
    input: { command: "git commit -m 'c10'", cwd: repo },
  });
  ok(res && res.block === true, "plain-text FAIL must block (was fail-open before #132)");
  await fire("session_start", {});
});

test("scenario 11 (#132): plain-text PASS + noise merges via prompt files, gate stays active", async () => {
  const repo = join(TEST_ROOT, "repo");
  writeFileSync(join(repo, "fileI.txt"), "i1\n");
  git(repo, "add fileI.txt");
  const prompt = `[VGATE] verify files: fileI.txt. Classification: UI. Project root: ${repo}`;
  await fire("tool_result", {
    toolName: "task", input: { prompt },
    content: [{ type: "text", text: "PASS\n{\"event\":\"gate_bypass\",\"reason\":\"escape_hatch\"}" }],
  });
  const res = await fire("tool_call", {
    type: "tool_call", toolName: "bash",
    input: { command: "git commit -m 'c11'", cwd: repo },
  });
  equal(res, undefined, "plain-text PASS + noise must merge prompt files and allow the commit");
  await fire("session_start", {});
});

test("scenario 12 (#132 O/I/T): BLOCK_ATTEMPT_THRESHOLD auto-bypass unchanged — 3rd attempt allowed", async () => {
  const repo = join(TEST_ROOT, "repo");
  writeFileSync(join(repo, "fileJ.txt"), "j1\n");
  git(repo, "add fileJ.txt");
  // No verification at all → every attempt blocks; the 3rd must auto-bypass (#7591).
  for (let i = 0; i < 3; i++) {
    const res = await fire("tool_call", {
      type: "tool_call", toolName: "bash",
      input: { command: "git commit -m 'c12'", cwd: repo },
    });
    if (i < 2) ok(res && res.block === true, `attempt ${i + 1} must block`);
    else equal(res, undefined, `attempt ${i + 1} must auto-bypass (BLOCK_ATTEMPT_THRESHOLD)`);
  }
  await fire("session_start", {});
});
```

**Step 3: Run and confirm RED**

```bash
cd extensions/verification-gate && env -u ELDATO_SKIP_VGATE npx tsx index.e2e.test.ts
```
Expected: scenarios 5–7 fail (5: commit still blocked after PASS+noise; 6 & 7: gate disabled → commit allowed, assertion of `block === true` fails). Scenario 8 fails (unconditional reset masks failures → gate still active → commit blocked). Scenarios 9–10 fail today (FAIL intent fails open → commit allowed; assert block → fails). Scenario 11 fails today (noise object parsed → schema-invalid → vgateFailures++ → blocked). Scenario 12 passes today (auto-bypass unchanged — regression pin). Scenarios 1–4 + bridge test remain green.

### Task 3: Implement the gated extractJson + placeholder rejection (GREEN, unit + e2e 5–6)

**Intent:** The core fix — `extractJson` may only return usable results, found by string-aware reverse candidate scan.
**Acceptance:** All unit tests green; e2e scenarios 5–6 green; scenarios 1–4 + bridge green; scenario 7 still RED (carve-out is Task 4); scenario 8 still RED (guard is Task 5).
**Files:**
- Modify: `extensions/verification-gate/index.ts:269-300` (extractJson), `index.ts:304-316` (isValidResult) — re-verify exact ranges against HEAD at execution (citations are 1-2 lines short; replacing by function identity is safer)

**Step 1: Extend isValidResult with placeholder rejection:**

```typescript
// #132: placeholder values (the block message's prompt template shows "..." as
// an example hash) must never register a verified entry — a "..." hash would
// mismatch every future file hash and block commits forever. Empty verified_files
// remains valid (a verdict with no files is legitimate).
const PLACEHOLDER_VALUES = new Set(["", "...", "__placeholder__"]);

export function isValidResult(obj: any): obj is VerificationResult {
  if (!obj || typeof obj !== "object") return false;
  if (typeof obj.status !== "string" || !["PASS", "FAIL"].includes(obj.status)) return false;
  if (!Array.isArray(obj.failures)) return false;
  if (!Array.isArray(obj.verified_files)) return false;
  return obj.verified_files.every(
    (f: any) =>
      typeof f === "object" &&
      f !== null &&
      typeof f.path === "string" &&
      typeof f.hash === "string" &&
      !PLACEHOLDER_VALUES.has(f.path) &&
      !PLACEHOLDER_VALUES.has(f.hash)
  );
}
```

**Step 2: Rewrite extractJson** — replace the Step 3 block (lines 288-297) and gate Steps 1-2:

```typescript
// ── JSON extraction ───────────────────────────────────
// #132: every extraction step is gated by isValidResult (+ placeholder
// rejection). A step may only return a usable VerificationResult; anything
// else falls through to the next step and finally to null → plain-text
// fallback. Candidates are scanned newest-first; schema-invalid candidates
// are SKIPPED, never fatal. #135 (loop-enforcer) shares this bug class — if a
// second consumer lands, extract findMatchingOpenBrace + the candidate walk
// into extensions/shared/json-scan.ts (pure, no vgate state).

// Backward string-aware brace matcher: finds the `{` that opens the object
// ending at closeIdx. Braces inside "…" strings (including \" escapes) never
// anchor a slice. Returns -1 for unbalanced prose (caller skips, never aborts).
function findMatchingOpenBrace(text: string, closeIdx: number): number {
  let depth = 0;
  let inString = false;
  for (let i = closeIdx; i >= 0; i--) {
    const ch = text[i];
    if (inString) {
      if (ch === '"') {
        // A quote ends the string unless escaped by an ODD run of backslashes
        // (\" stays inside; \\" is a literal backslash then end-of-string).
        let backslashes = 0;
        for (let j = i - 1; j >= 0 && text[j] === "\\"; j--) backslashes++;
        if (backslashes % 2 === 0) inString = false;
      }
      continue;
    }
    if (ch === '"') { inString = true; continue; }
    if (ch === "}") { depth++; continue; }
    if (ch === "{") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

export function extractJson(text: string): VerificationResult | null {
  // Step 1: raw JSON.parse (gated)
  try {
    const parsed = JSON.parse(text.trim()) as VerificationResult;
    if (isValidResult(parsed)) return parsed;
  } catch { /* continue */ }

  // Step 2: ```json fences, newest first (gated)
  const fences = text.match(/```json\s*([\s\S]*?)```/g);
  if (fences) {
    for (let i = fences.length - 1; i >= 0; i--) {
      try {
        const parsed = JSON.parse(fences[i].replace(/```json\s*|\s*```/g, "").trim()) as VerificationResult;
        if (isValidResult(parsed)) return parsed;
      } catch { /* continue */ }
    }
  }

  // Step 3: string-aware reverse candidate scan (gated). Enumerate every `}`
  // newest-first with its string-aware matching `{`; return the first candidate
  // that parses AND validates. Unbalanced prose → skip. Never aborts.
  let close = text.lastIndexOf("}");
  while (close !== -1) {
    const open = findMatchingOpenBrace(text, close);
    if (open !== -1) {
      try {
        const parsed = JSON.parse(text.slice(open, close + 1)) as VerificationResult;
        if (isValidResult(parsed)) return parsed;
      } catch { /* skip candidate */ }
    }
    close = text.lastIndexOf("}", close - 1);
  }

  return null;
}
```

**Step 3: Run unit tests — expect GREEN**

```bash
cd extensions/verification-gate && npx tsx index.test.ts
```

**Step 4: Run e2e — expect scenarios 5–6 green, 7–8 still red**

```bash
cd extensions/verification-gate && env -u ELDATO_SKIP_VGATE npx tsx index.e2e.test.ts
```

**Step 5: Commit** (@commit-workflow)

```bash
git add extensions/verification-gate/index.ts extensions/verification-gate/index.test.ts extensions/verification-gate/index.e2e.test.ts
git commit -m "fix(vgate): gate extractJson with isValidResult + string-aware reverse scan (#132)"
```

### Task 4: FAIL carve-out in the handler (GREEN, e2e scenario 7)

**Intent:** Legitimate FAIL verdicts must keep blocking without silently disabling the gate — 3 real FAILs are not dispatch failures.
**Acceptance:** e2e scenario 7 green; all others still green.
**Files:**
- Modify: `extensions/verification-gate/index.ts:702-707` (FAIL block) — re-verify range at execution

**Step 1: Replace the FAIL counting block:**

```typescript
if (result.status !== "PASS") {
  console.error(`[verification-gate] ❌ Verifier returned FAIL: ${result.failures.join("; ")}`);
  // #132: a FAIL is a SUCCESSFUL dispatch — the verifier ran and judged the
  // files unready. Keep blocking (nothing to merge) but do NOT count it as a
  // dispatch failure: 3 legitimate FAIL verdicts must not silently disable the
  // gate. No reset either — a FAIL proves nothing about dispatch health.
  // Consume stale block state like every terminal path (#5607).
  lastBlockedCwd = null;
  lastBlockedFiles = [];
  return undefined;
}
```

**Step 1b: FAIL-intent detection in the null path (A.3b)** — in the `!result` branch (plain-text fallback, `index.ts:557-608`), REPLACE the existing `const hasFail = ...` declaration (currently `index.ts:559-560`) with the structural version below, and AFTER the `hasPass` merge check and BEFORE the fail-open prompt-merge (`index.ts:615`), add the block:

```typescript
// #132 A.3b: an explicit FAIL judgment (schema-incomplete JSON FAIL or
// plain-text FAIL) must block, never fail open — "don't commit" is not a
// JSON-compliance issue. Not a dispatch failure either: keep blocking, log,
// do NOT increment vgateFailures and do NOT merge. Consume lastBlockedCwd
// like every other terminal path (#5607) so a stale blocked cwd can't
// shadow the next manual dispatch.
// STRUCTURAL detection (Phase-7 P1s): word-boundary line heuristics + a
// brace-anchored JSON probe — FAILED/Failure/Failing and quoted prose never
// match; {status: FAIL} / {'status':'FAIL'} (lazy quoting) DO match.
const hasFail = /(?:^|\n)\s*FAIL(?:\b|:|—)/i.test(textContent)
  || /❌.*FAIL(?:\b|:|—)/i.test(textContent)
  || /\{\s*['"]?status['"]?\s*:\s*['"]?FAIL['"]?/i.test(textContent);
if (hasFail) {
  console.error("[verification-gate] ❌ Verifier FAILED (unparseable verdict): keep blocking, no merge");
  lastBlockedCwd = null;   // consume stale block state (#5607)
  lastBlockedFiles = [];
  return undefined;
}
```

(Placement: the existing `hasPass && !hasFail` branch already handles PASS intent; this new branch catches FAIL intent that today falls through to fail-open. Note: a response with BOTH a line-start PASS and FAIL intent now routes to the FAIL block — an explicit FAIL judgment wins over a bare PASS line.)

**Step 2: Run e2e — scenario 7 green**

```bash
cd extensions/verification-gate && env -u ELDATO_SKIP_VGATE npx tsx index.e2e.test.ts
```

**Step 3: Commit** (@commit-workflow)

```bash
git commit -am "fix(vgate): FAIL verdicts no longer count toward the 3-strike gate disable (#132)"
```

### Task 5: Remove the dead schema-invalid branch + merged>0 guard (GREEN, e2e scenario 8)

**Intent:** Delete the now-unreachable branch whose existence invites routing divergence; prevent zero-merge PASSes from masking genuine dispatch failures.
**Acceptance:** e2e scenario 8 green; full suite green; `git diff` shows no references to the removed branch.
**Files:**
- Modify: `extensions/verification-gate/index.ts:655-700` (delete schema-invalid branch — re-verify range at execution), `index.ts:714-716` (guard)

**Step 1: Delete the `if (!isValidResult(result)) { ... }` block (lines 655-700)** and leave a trace comment:

```typescript
// (#132) The schema-invalid branch was removed: extractJson gates every step
// with isValidResult + placeholder rejection, so it returns either null or a
// usable result — `!isValidResult(result)` was unreachable. The old branch's
// routing (schema-invalid PASS → prompt-file fallback merge + reset) is
// provably equivalent to the null path reaching the NO-JSON fail-open branch
// above: same prompt-file merge, same vgateFailures reset, same cwd consume.
```

**Step 2: Guard the PASS reset (lines 714-716):**

```typescript
if (merged > 0) {
  // #132: only a MERGE proves dispatch health — a zero-merge PASS (all files
  // skipped as not-in-diff) must not mask real dispatch failures.
  vgateFailures = 0;
  console.log(`[verification-gate] ✅ Merged ${merged} verified files${skipped > 0 ? ` (skipped ${skipped} not in diff)` : ''} (${verifiedSet.size} total)`);
} else {
  console.error(`[verification-gate] ⚠️ PASS but merged 0 files (${skipped} skipped as not in diff) — failure counter NOT reset`);
}
```

**Step 3: Run the full suite — expect all green**

```bash
cd extensions/verification-gate && npx tsx index.test.ts && env -u ELDATO_SKIP_VGATE npx tsx index.e2e.test.ts
```

**Step 4: Confirm the branch removal with the consensus trace** — grep for `isValidResult(result)` in the handler: only the `extractJson` internal gates and the exported predicate may remain.

**Step 5: Commit** (@commit-workflow)

```bash
git commit -am "fix(vgate): remove unreachable schema-invalid branch, guard PASS reset on merged>0 (#132)"
```

### Task 6: Full verification + PR

**Intent:** Prove the O/I/T targets end-to-end and land the fix.
**Acceptance:** All acceptance criteria (below) met; PR opened via @commit-workflow.
**Files:**
- Modify: `docs/plans/2026-08-10-vgate-extractjson-noise.md` (mark completed)

**Step 1: Full suite** — `npx tsx index.test.ts` and `env -u ELDATO_SKIP_VGATE npx tsx index.e2e.test.ts` both exit 0.

**Step 2: Live-session confirmation (O/I/T target 3, manual):** in a scratch repo (or the working repo with a staged change), dispatch a real `task(prompt='[VGATE] verify files: <file>. Classification: UI. Project root: <root>.', ...)` so the sub-agent returns PASS JSON; confirm the next `git commit` passes on the first attempt with no re-dispatch and no auto-bypass.

**Step 3: Open PR** via @commit-workflow (branch `fix/132-vgate-extractjson-noise`, target `main`, auto-merge default). Note in the PR body: closes #132; unrelated to #133/#134/#135 (transport, emitter guard, loop-enforcer — separate issues).

**Step 4: Update issue** — `gh issue edit 132 --add-label planned` then `--remove-label planning` (if applicable); leave a comment with the plan link.

---

## Testing Strategy

| Layer | Where | Covers |
|-------|-------|--------|
| Unit — extractJson | `index.test.ts` (tsx, node:assert) | verdict+noise, FAIL+noise, noise-only→null, innermost-fragment, fence last-invalid→earlier valid, braces-in-strings, unbalanced prose, placeholders→null, empty-array valid |
| Unit — isValidResult | `index.test.ts` | placeholder rejection (`...`, `__placeholder__`, empty), empty array valid, existing 20 tests stay green |
| E2E — plugin lifecycle | `index.e2e.test.ts` (fake pi + real temp git repo, temp HOME) | scenario 5: PASS+noise unblocks commit (O/I/T #1); scenario 6: 3× noise never disables; scenario 7: 3× FAIL never disables; scenario 8: zero-merge PASS doesn't mask failures; scenarios 1–4 + bridge regression |
| Manual | live session | O/I/T target 3: real dispatch unblocks next commit first attempt |

Explicitly **not** tested: loop-enforcer parsing (#135's scope), stderr transport (#134), emitter guard (#133). Post-merge clickthrough per @commit-workflow Step 3.8 (warn-only).

## Verification Plan

- **Domain:** code (extension parsing logic). **Complexity:** standard. **No UX/UI** surface (no DOM, no a11y) — ux-verification N/A. **No content/config/research** domains — no content-verification/config-validation/research-verification.
- **Layers required:** unit (extractJson/isValidResult — the core logic; exhaustive per C6) + e2e (event-flow integration surface — the actual bug lives at this seam, so e2e weight is high per the Testing Trophy). No integration tests (no DB/API surfaces), no pgTAP (no SQL).
- **Regression proof:** all 67 existing unit tests + 4 existing e2e scenarios + setup + bridge test untouched and green — proves O/I/T indicator 2 (no regression in `index.test.ts`). Indicator 3 (auto-bypass unchanged) is pinned by new e2e scenario 12 (3rd commit attempt auto-bypasses).
- **plan-review** (this plan) runs before execution; **code-review** runs at PR time via @commit-workflow; **find-bugs** over the final diff.

## Acceptance Criteria

1. `extractJson('valid verdict JSON + gate_bypass noise')` returns the verdict (unit green) — O/I/T indicator 1 at the unit level.
2. All existing merge paths (raw JSON, ` ```json ` fence, plain-text PASS) still register — full unit + e2e suite green.
3. Legitimate FAIL verdicts: commit stays blocked; `vgateFailures` not incremented — 3× FAIL never disables the gate (e2e scenario 7).
4. 3× noise-only dispatches never disable the gate (e2e scenario 6).
5. Zero-merge PASS does not reset the failure counter; 3 genuine failures still disable the gate (e2e scenario 8).
6. Placeholder path/hash (`""`, `"..."`, `"__placeholder__"`) rejected at the gate; empty `verified_files` remains valid (unit green).
7. `BLOCK_ATTEMPT_THRESHOLD` auto-bypass behavior unchanged (e2e scenarios 1–4 regression).
8. Dead schema-invalid branch removed; handler contains no `isValidResult` call outside `extractJson`'s gates (code review).
9. Live-session confirmation: real `[VGATE]` dispatch on a staged file unblocks the next `git commit` on the first attempt (manual, O/I/T target 3).
10. Full suite green: `index.test.ts` + `index.e2e.test.ts` exit 0.

## Runtime Prerequisites

- Node.js 20+; `tsx` available in `extensions/verification-gate/node_modules` (already present — no install step).
- Tests require **no Docker, no FalkorDB, no network**. E2E harness isolates the bridge under a temp `HOME` and creates its own temp git repo.
- `ELDATO_SKIP_VGATE` must be unset during e2e runs (`env -u ELDATO_SKIP_VGATE`) — the harness also deletes it defensively.
- No environment variables to add; no config changes; no manifest.json changes (no new files in `extensions/`).
- Extension load: verification-gate is loaded from the repo path by `tsx` for tests; the installed copy under `~/.pi/agent/extensions/` refreshes via the repo's sync mechanism after merge (existing process — no action needed for the fix to take effect in future sessions; existing sessions pick it up on next reload).
