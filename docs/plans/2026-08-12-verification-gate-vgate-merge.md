<!-- research-path: none (standalone bugfix, zero third-party deps; issue body contains the forensics) -->

# Verification-Gate Mid-Session [VGATE] Merge — Implementation Plan

**Goal:** Make a mid-session `[VGATE]` sub-agent PASS reliably register into the committing session's `verifiedSet` so the next commit passes without the `BLOCK_ATTEMPT_THRESHOLD=3` auto-bypass.

**Team:** organisation-design-team
**Issue:** #190 (complexity:standard)

**Architecture:** Single-file extension change (`extensions/verification-gate/index.ts`) plus tests. Four coordinated fixes: (1) bridge persists compound keys (root provenance), (2) root-aware bridge recovery at every git-op check + session_start with stored-hash match-or-drop, (3) robust plain-text PASS merge (broadened prompt regex, `lastBlockedFiles` fallback only on zero parse, staged-diff scoping when no block context, no state consumption on zero-merge, prompt-root override for cross-worktree dispatches), (4) `hasPass` marker+boundary parity with `hasFail`.

### Pattern Research

Skipped — plan touches zero third-party deps. All behavior is internal to the extension + pi extension API (`@earendil-works/pi-coding-agent` 0.84.1, already pinned and used by the file).

### Integration Surface Map

| Surface | Boundary | Test Layer | Failure Mode |
|---------|----------|-----------|--------------|
| `tool_result` handler | pi ExtensionAPI event (task tool) | mounted-plugin harness (fake API) | event not processed → zero merge (incident) |
| bridge file `~/.pi/agent/verification/latest.json` | cross-process shared state | mounted harness + temp HOME | no root provenance → cross-worktree contamination (#37) |
| `tool_call` git-op check | staged diff vs verifiedSet | mounted harness + temp git repo | stale bridge hash → mismatch block |
| `mergeVerifiedFiles` / plain-text merge | prompt parsing + registry keys | unit (pure functions) | zero-parse prompts, subset PASS widening |
| live copy `~/.pi/agent/extensions/verification-gate` | deployment | PR description sync step + auto-sync | live copy diverges → fix not effective |

### Verification Plan

Unit (index.test.ts, extended) + mounted-plugin regression suite (index.test.ts, temp HOME + dynamic import) + e2e contract update (index.e2e.test.ts scenario 13). No integration/DB surfaces. Run: `npx tsx extensions/verification-gate/index.test.ts` and `npx tsx extensions/verification-gate/index.e2e.test.ts` (from repo root with the extension's node_modules symlink to the pi install — local setup).

---

## Design Decisions

**D1 — Bridge format: persist compound keys + STORED hashes.** `writeBridge` currently strips the worktree root and re-hashes from DISK at write time — so the bridge has no root provenance AND carries disk-snapshot hashes (not the verifier-authoritative hash). Both are wrong once the bridge becomes live. Change: persist `path` as the FULL compound key (`worktreeRoot::relPath`) and `hash` as the REGISTRY'S STORED hash (`verifiedSet.get(f) ?? hashFile(root, path)` fallback for legacy/plain entries) — the bridge becomes a byte-mirror of the registry, so recovery's match-or-drop anchors to the verifier's hash (#38 authority) and a post-PASS edit drops the entry fail-closed (verifier P1-1). Update the stale comment (line ~104), the e2e contract test (scenario 13 — bridge is a UNION of full-set writes; assert every entry round-trips `parseCompoundKey`), and state explicitly: pre-D1 legacy bridges are dropped entirely on the first post-D1 session (fail-closed; write-side legacy fallback kept only for safety).

**D2 — Root-aware bridge recovery, stored-hash match-or-drop; narrow pendingRehash.** New helper `recoverBridgeForRoot(normRoot)`:
- `readBridge()`; if null/corrupt → warn once, return. Perf guard: skip entirely when the bridge's mtime is older than this session's last recovery (no per-git-op re-hash churn).
- For each entry: `parseCompoundKey(vf.path)`; skip unless `parsed.root === normRoot` (exact realpath'd root equality — cross-worktree entries are inert).
- **Match-or-drop**: merge into `verifiedSet` ONLY if `vf.hash === hashFile(parsed.root, parsed.path)`. Because D1 now persists the STORED hash, a post-PASS edit makes the stored hash ≠ disk → entry skipped (fail-closed, mismatch → normal block). Never recompute a fresh hash at recovery.
- `blockAttempts.delete(key)` only for merged (hash-matched) entries.
- Call sites: (1) `tool_call` git-op check path, ordered rehash-block → bridge-recovery → unverified computation; (2) `session_start` (root = `normalizeWorktreeRoot(resolveGitRoot(process.cwd()))`; in tests, `process.chdir(repo)` first — session_start carries no cwd).
- **pendingRehash narrowing (verifier P1-2)**: capture the allowed commit's `changedFiles` at allow-time (`pendingRehashFiles`); the rehash loop touches ONLY those files (the only ones lint-staged could have modified), re-hashes from disk, updates the registry, and re-writes the bridge. Prevents the rehash from re-blessing unrelated verified files from disk and stops D1+D2 from cementing that blessing cross-session. #7574 intent (post-lint hash capture) preserved.
- **Framing (verifier B ISSUE 7)**: same-session recovery is usually a no-op (tool_result merged + wrote the bridge atomically); the recovery channel is defense-in-depth for (a) the incident's event-miss class where a merge landed via another path (e.g., a sub-agent's own tool_result handler writing the bridge — observed in the incident logs: "merged 1/5 files" in sub-agent stderr), (b) unclean shutdown / bypass-session merges, (c) cross-process handoff. The incident's primary fix is D3.
- **Remove `clearBridge()` from `session_shutdown` (verifier P1-1)**: print-mode sub-agents fire `session_shutdown` on exit (`pi -p` dispose path), so the sub-agent's own bridge write is deleted before the parent can recover it, AND any sub-agent exit between a parent merge and the next git-op deletes the parent's bridge. With D1's stored-hash match-or-drop, stale bridge entries are inert (fail-closed) — the bridge needs no deletion on shutdown. Keep `clearBridge` only as an explicit test/emergency helper; delete the `session_shutdown` call.
- **`recoverBridgeForRoot` robustness (verifier P2-4)**: wrap the match in try/catch — `hashFile` throws on deleted/unhashable files; treat a throw as no-match (skip entry, never merge, never `blockAttempts.delete`).
- **mtime-guard bookkeeping (verifier P2-3)**: reset `lastRecoveryMtime = 0` in `session_start` alongside the existing resets; set it at both recovery call sites.

**D3 — Robust plain-text PASS merge.**
- Broaden `fileMatch` regex: `verify files:\s*(.+?)(?=(?:\.|\n)\s*(?:Classification:|Project root:)|$)` — accepts `\n\nClassification:` (incident dispatch #1's format) and no-period formats. Applies to both the plain-text and fail-open branches.
- **Prompt files primary, `lastBlockedFiles` fallback only on zero parse**: if prompt parsing yields ≥1 file → merge those (diff-scoped per existing #5673 filter). If zero files parsed (incident (a)) AND `lastBlockedFiles` non-empty → fall back to merging `lastBlockedFiles` (hashable ones), logging loudly ("prompt parse failed — falling back to blocked diff"). A subset PASS must NOT merge un-named blocked files (no widening).
- **Empty-context scoping**: when `lastBlockedFiles` is empty, diff-scope prompt files against `computeStagedDiff(projectRoot)` at merge time (files must be in the current staged diff) — replaces the unfiltered pass-through (verifier B ISSUE 7).
- **Wrong-root guard**: extract prompt root; if `lastBlockedCwd` is set AND prompt root realpath-differs from it → the dispatch targets another worktree: rebind `projectRoot` to the prompt root, clear the stale `lastBlockedFiles` (no filter against foreign context). Prevents the stale-state wrong-root loop (verifier B ISSUE 3).
- **No state consumption on zero-merge**: `lastBlockedCwd`/`lastBlockedFiles` survive a zero-merge plain-text OR JSON PASS (retry context preserved); consume on merged>0 and on FAIL/hasFail verdicts (#5607 preserved for terminal paths).

**D4 — `hasPass` marker + boundary parity.** `/(?:^|\n)\s*(?:[-*•]|\d+\.)?\s*\*{0,3}PASS(?:\b|:|—)/i` + `✅.*PASS(?:\b|:|—)` (boundary on BOTH variants — verifier B ISSUE 5; `\*{0,3}` covers `***PASS***`). Matches `PASS`, `- PASS`, `**PASS**`, `***PASS***`, `PASS:`, `✅ PASS`; does NOT match `PASSED`/`PASSES`/`✅ PASSED`. NOTE (behavioral): a `- PASSED`-only response without FAIL markers still falls through to the pre-existing fail-open prompt-merge (#5724, deliberately permissive) — the mounted test asserts the hasPass path specifically (no "Plain-text PASS — merged" log) and documents fail-open as the actual allow path; pure-function tests pin the regex boundary.

**D5 — Test-only introspection export.** `export function getVerifiedSetKeys(): string[]` (module-internal state is otherwise unobservable; harmless named export, existing pattern).

## Tasks

### Task 1: Bridge compound-key format + e2e contract update

**Intent:** Give the bridge root provenance so recovery can be worktree-isolated (#37 property).
**Acceptance:** Bridge entries contain `root::rel` compound keys; e2e scenario 13 updated and passing.

**Files:**
- Modify: `extensions/verification-gate/index.ts` (`writeBridge` ~line 88-110, comment line ~104)
- Modify: `extensions/verification-gate/index.e2e.test.ts` (scenario 13 assertions)
- Test: `extensions/verification-gate/index.e2e.test.ts`

**Step 1:** In `writeBridge`, persist `{ path: f, hash: verifiedSet.get(f) ?? hashFile(parsed.root ?? projectRoot, parsed.path ?? f) }` — full compound key as `path`, STORED hash (verifier authority) as `hash`; legacy plain-path entries fall back to the disk hash (write-side safety only; recovery drops non-compound entries fail-closed). Update the "compound form is internal" comment.

**Step 2:** Run e2e: `npx tsx extensions/verification-gate/index.e2e.test.ts` — scenario 13 will fail; update it to assert compound-key format (`path.includes("::")` + round-trip root parse). Also add: after a PASS merge + fresh `session_start`, the commit is allowed via bridge recovery (proves recovery works).

**Step 3:** Run: `npx tsx extensions/verification-gate/index.test.ts` — all pure-function tests still pass (92).

### Task 2: Root-aware bridge recovery (D2)

**Intent:** Make the bridge a live mid-session recovery channel — redundancy for the incident's event-level miss.
**Acceptance:** Git-op check merges hash-matched, same-root bridge entries; cross-root entries inert; mismatched entries skip (fail-closed).

**Files:**
- Modify: `extensions/verification-gate/index.ts` (new `recoverBridgeForRoot`; call in `tool_call` check path after `pendingRehash`, and in `session_start`)
- Test: `extensions/verification-gate/index.test.ts` (mounted harness)

**Step 1:** Implement `recoverBridgeForRoot(normRoot: string): number` — readBridge, filter by `parseCompoundKey(path).root === normRoot`, match-or-drop via `vf.hash === hashFile(root, path)`, merge + `blockAttempts.delete` for matched, warn once on corrupt bridge.

**Step 2:** Wire into `tool_call`: after the `pendingRehash` block, before `computeStagedDiff` — `recoverBridgeForRoot(normalizeWorktreeRoot(cwd))` (with the mtime guard). Narrow `pendingRehash`: capture `pendingRehashFiles = changedFiles` at allow-time; rehash loop iterates only those. And into `session_start`: after `verifiedSet.clear()`, REPLACE the old blind recovery loop with `recoverBridgeForRoot(normalizeWorktreeRoot(resolveGitRoot(process.cwd())))`, log recovered count; reset `lastRecoveryMtime`. REMOVE `clearBridge()` from `session_shutdown` (delete the call; keep the helper for tests/emergency).

**Step 3:** Mounted tests (temp HOME + dynamic import, e2e pattern):
- T4a: bridge with same-root entry + matching hash → commit allowed.
- T7: bridge entry for a DIFFERENT root → not merged → still blocked.
- T8: bridge entry with stale hash (file edited) → not merged → still blocked (no re-hash fail-open).

### Task 3: Robust plain-text PASS merge (D3)

**Intent:** Eliminate the prompt-format fragility (incident (a)) and the zero-merge state loss; prevent wrong-root rebinding.
**Acceptance:** `\n\nClassification:` prompts merge; zero-parse falls back to `lastBlockedFiles`; subset PASS does not widen; zero-merge keeps state; cross-worktree dispatch rebinds root.

**Files:**
- Modify: `extensions/verification-gate/index.ts` (plain-text hasPass branch ~line 672-720; JSON zero-merge path ~line 783-807; fileMatch regex both branches)
- Test: `extensions/verification-gate/index.test.ts` (mounted harness + pure-function tests for the regex)

**Step 1:** Broaden `fileMatch` regex (both occurrences) + implement `scopeFiles` helper. Add pure-function tests: `\n\nClassification:` form, no-period form, dot-containing absolute paths.

**Step 2:** Implement `resolveMergeRoot(prompt)` (D3) and rework ALL merge branches:
- plain-text hasPass branch: prompt-root guard via `resolveMergeRoot`; promptFiles primary; bounded fallback (`verify files:` marker present + zero parse → `lastBlockedFiles`); empty/foreign-context scoping against `computeStagedDiff(projectRoot)`; consume `lastBlockedCwd` only when `merged > 0`.
- fail-open branch: same guard + broadened regex (no other behavior change — #5724 deliberately permissive).
- JSON branch: same guard before the `mergeVerifiedFiles` call + `scopeFiles` pre-filter on `result.verified_files`; JSON zero-merge path: same non-consume, NO fallback.

**Step 3:** Mounted tests (fire `session_start` between tests to reset module state — e2e pattern; T1 also gets `getVerifiedSetKeys` — move the D5 export INTO Task 3):
- T1: full sequence — attempt1 BLOCK (7 files) → tool_result (documented prompt + line-start PASS) → attempt2 ALLOW (no auto-bypass: attempt 2 ≠ 3); assert bridge contents (compound key + stored hash) + `getVerifiedSetKeys`; negative control: a NEW staged file still BLOCKS; then re-modify + re-stage a merged file → commit BLOCKS on attempt 1 (blockAttempts cleared by merge, not leaked).
- T2: prompt with `\n\nClassification:` (no period) merges.
- T3: `**PASS**` response merges via the hasPass path; `- PASSED` does NOT take the hasPass path (fail-open may still allow — assert the log/branch, per D4 note).
- T5: zero-parse + bounded fallback merges `lastBlockedFiles`; zero-merge (unhashable) keeps `lastBlockedCwd`; JSON-path zero-merge also keeps it.
- T6: wrong-root — block in wt-A, plain-text dispatch with `Project root: wt-B` → rebinds to B, merges B files under B root; T6-JSON: same via JSON PASS, AND an un-staged wt-B file named in the JSON PASS does NOT merge (scopeFiles).

### Task 4: hasPass parity (D4) + introspection export (D5)

**Intent:** Response-marker parity and test observability.
**Acceptance:** `**PASS**`/`- PASS` merge; `PASSED`/`PASSES` do not; `getVerifiedSetKeys()` exported.

**Files:**
- Modify: `extensions/verification-gate/index.ts` (hasPass regex line ~670; add export)
- Test: `extensions/verification-gate/index.test.ts`

**Step 1:** Replace hasPass regex with D4 pattern (boundary on both variants); add pure-function regression tests (match + non-match: `**PASS**`, `- PASS`, `✅ PASS`, `PASS:` vs `PASSED`, `PASSES`, `✅ PASSED`).

**Step 2:** (Already landed in Task 3 for T1.) Verify `getVerifiedSetKeys()` export + add a pure-function sanity test.

### Task 5: Full suite + live-copy sync + commit

**Intent:** Green suite, deployed live copy, shipped PR.
**Acceptance:** All tests pass; live copy synced; PR with sync note.

**Step 1:** Run both suites from repo root (with extension node_modules symlink): index.test.ts (restructured: `process.env.HOME` set to a temp dir BEFORE any `index.js` evaluation — ZERO static imports of `./index.js`; pure functions destructured from the awaited module instance; async-aware test runner (e2e queue pattern — a rejected async test must count as FAILED, no false green); `async main()` owns the result printer + exit; module-load regression merged into the callable-exports test) + index.e2e.test.ts (scenario 13 updated + recovery scenario with `process.chdir(repo)` before the fresh `session_start`). Add mounted tests: session_shutdown after a merge does NOT delete the bridge (subsequent session_start still recovers); bridge entry for a deleted file is skipped (no crash); JSON PASS with empty verified_files → no fallback merge.

**Step 2:** Check the sync mechanism: `scripts/sync.sh` / `scripts/sync-all.sh` / `extensions/auto-sync.ts` — the repo copy is the source; `~/.pi/agent/extensions/verification-gate` must be refreshed. Note the sync step in the PR description (live copy only refreshes at next session start / manual sync; warn-mode sessions won't auto-refresh).

**Step 3:** Remove stray `probe-file-190.ts` from the worktree. Commit workflow: VGATE dispatch → draft PR → code-review gate (bug-scan + security + extension-safety) → fix loop → ready → record-review → merge.

## Rejected Alternatives

1. **Remove `ELDATO_SKIP_VGATE=1` from builtin-tools sub-agent env** — rejected: builtin-tools is #191 (out of scope); sub-agents lack the `task` tool → enabled gate inside sub-agents deadlocks their own commits. (NOTE: the tool_result handler has NO `extensionEnabled` check, so `ELDATO_SKIP_VGATE=1` sessions still merge+write the bridge — this is the mechanism D2's recovery relies on; the scoping's earlier "sub-agents can never write the bridge" claim was corrected during scope-verify. Do NOT add the check — it would gut D2.)
2. **Merge all `lastBlockedFiles` on every PASS** — rejected: subset-PASS would mark un-named blocked files verified (fail-open widening). Fallback is zero-parse-only.
3. **Recompute hashes at bridge recovery** — rejected (verifier B): a file edited after PASS would be re-hashed to current content and sail through — mismatch detection becomes dead code.
4. **Keep the bridge format as-is and merge by relative path** — rejected: root-agnostic merge = cross-worktree contamination (#37) — P0-grade fail-open.
5. **Only loosen the prompt regex** — rejected: fixes (a) but not the event-level failure; D2's redundancy is required.

## Acceptance Criteria

1. `npx tsx extensions/verification-gate/index.test.ts` — all pass (existing 92 + new mounted/unit tests).
2. `npx tsx extensions/verification-gate/index.e2e.test.ts` — all pass (scenario 13 updated to compound-key contract + recovery scenario).
3. Live copy `~/.pi/agent/extensions/verification-gate/index.ts` byte-identical to the merged repo copy (sync step documented in PR).
4. Mid-session sequence (block → VGATE PASS → commit) passes on attempt 2 with no auto-bypass (T1).
5. Cross-worktree bridge entries and stale hashes never unblock a commit (T7/T8).
