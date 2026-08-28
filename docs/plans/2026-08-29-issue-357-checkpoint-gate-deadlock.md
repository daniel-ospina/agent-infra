---
title: "#357 — Checkpoint Gate Deadlock Fix — Implementation Plan"
type: engineering
domain: platform
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-29
aboutSubjects: sequence-enforcer, enforcement, pi-extensions
aboutObjects: agent-infra, issue-357
---

<!-- research-path: docs/scoping/2026-08-29-issue-357-checkpoint-gate-deadlock.md -->

# #357 — Checkpoint Gate Deadlock Fix — Implementation Plan

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Make the sequence-enforcer's checkpoint step-gate satisfiable and escapable so no pi -p worker or worktree pipeline session can deadlock on it, while keeping the gate meaningful where a token can legitimately be produced.

**Team:** organisation-design-team
**Tier:** standard (condensed plan; TDD preferred for behavioral changes)

**Architecture:** Repair the checkpoint gate in `extensions/sequence-enforcer/index.ts` end-to-end — (a) fix the token ts contract so a valid CLEAR token actually passes; (b) wire `token_phase` through the loaders so the phase check fires; (c) add mode-independent advancement so the pipeline never freezes at a checkpoint; (d) guarantee an in-session escape (loop_enforcer/read + sole-command `parallel_work_check.sh|py`); (e) make guidance reachable and name a CLEAR-able invocation; (f) make the print default argv-aware (documented #201 reversal); (g) single-audit; (h) operator force-pass; (j) park-only recovery; wire the test suite into CI (zero-dep route); and gate the DEPLOYMENT (the #265 sync.sh branch-guard silently blocks deploy from a non-main checkout).

### Pattern Research

> **Findings date:** 2026-08-29

> **Gate skipped: plan touches zero third-party dependencies** — the CI route intentionally inlines the extension's only runtime pi-package import (`isToolCallEventType` = `event.toolName === toolName`, verified against the pi dist) and keeps the repo's package.json dependency-free; all other imports are `import type` (erased) or node builtins. No library versions to verify, no API-surface questions, no pitfalls research needed. The design decisions (escape regex, advancement semantics, mode resolution) were exhaustively verified in-repo through 4+4 verifier review cycles + second-model coherence + Phase 7 review (see the scoping doc).

### Integration Surface Map

| Surface | Boundary | Test layer | Failure modes covered |
|---|---|---|---|
| `extensions/sequence-enforcer/index.ts` | pi extension API (tool_call/tool_result events, session_start/shutdown) | unit (fakePi harness in `sequence-enforcer.test.ts`) | event ordering, concurrent siblings, marker lifecycle, blocked-call no-tool_result |
| Token file `/tmp/parallel-check-token.json` (+ `PARALLEL_CHECK_TOKEN_FILE` env) | JSON contract between swarm writer and enforcer | unit (matrix: ISO/ms/s, TTL boundary 599/601s, future skew, stale, wrong-verdict, wrong-phase, corrupt, malformed event shapes) | ts parse NaN, phase dead-code, cross-session clobber, guard-vs-advance ordering |
| Force file `/tmp/parallel-check-force.json` (Task 10) | operator → enforcer (verdict CLEAR + phase + repo binding) | unit (happy/phase/repo/one-shot/TTL/session-clear + malformed JSON/truncated/missing-field + cross-session two-instance) | stale, phase-mismatch, repo-mismatch, one-shot lingering, shared-/tmp cross-session unlink (any new session's start deletes it) |
| Marker map per-toolCallId (Task 7) | in-memory enforcer state | unit (cap/evict under sustained blocked calls, late tool_result for evicted marker) | leak on worker-kill (blocked calls emit no tool_result), unbounded growth |
| Audit log `~/.pi/agent/audit/enforcement.jsonl` | enforcer → jsonl | unit (audit sink) + manual/CI | double-audit, warn_blocked vs checkpoint_skipped_warn, NEW event names (`checkpoint_skipped_warn`, `checkpoint_force_pass`, `checkpoint_block_recovery`, `checkpoint_token_fresh`) undocumented, audit-volume unbounded from block-spam |
| Skill frontmatter loader (`loadSteps` python bridge) | SKILL.md steps → Step[] | unit (`_pushSkillForTest` fixtures + bridge-path test) | `token_phase` dropped by both extraction paths |
| Mode resolution (`resolveMode`/`handleSequenceTimeout`/`print-mode.ts`) | env/argv → warn/gate/strict; park vs pop | unit (argv matrix) | bare-shell `pi -p` resolving gate; park/pop predicate split |
| CI `ci-main.yml` extension-tests | repo → CI runner | CI execution of the suite | suite not wired (the meta-root-cause: never-passable contract shipped untested) |
| Deployment (`sync.sh` → `pi-bootstrap/setup.sh` → `~/.pi/agent/extensions`) | repo main → live extension copy | manual post-merge md5 gate (criterion 15) | #265 branch-guard freeze; deployed-copy hash drift |
| 3 gated skills + issue-scoping (#4907 comments) | skill text → agent behavior | skill-lint + doc review | bare `parallel_work_check` form that (d) blocks (issue-scoping carries the same instruction — activation-class residual) |

### Verification Plan (test-routing)

- Domain: code (infra extension). Complexity: Architecture high / UX low / Ontology low.
- Layers: unit (primary — the `sequence-enforcer.test.ts` suite, fakePi harness upgraded to multi-handler) + CI execution (ci-main.yml extension-tests) + skill-lint on the 3 gated skills (writing-plans/commit-workflow/executing-plans) + the touched issue-scoping + enforcement files + 2-3 day positive-audit window (criterion 16).
- Skipped: integration (no DB/auth/external services), e2e (no UI), UX verification (no UI).

**Tech Stack:** TypeScript (tsx), node builtins, pi extension API. Zero new dependencies.

---

### Task 1: CI wiring — make the suite runnable and CI-visible (prerequisite)

**Intent:** The sequence-enforcer suite is the only gate-critical suite NOT executed in CI — the never-passable checkpoint contract shipped (08-12) with zero token-acceptance tests and 118/118 production blocks. Every subsequent task gets a CI-visible red/green signal only if this lands first.

**Acceptance:** `npx tsx extensions/sequence-enforcer/sequence-enforcer.test.ts` passes from a clean checkout with NO dependencies installed; `ci-main.yml` extension-tests runs the suite and fails the job on test failure.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (imports only)
- Modify: `.github/workflows/ci-main.yml` (extension-tests job)

**Step 1:** Replace the runtime value import `import { isToolCallEventType } from "@earendil-works/pi-coding-agent"` with a local inline predicate (verify against the pi dist: `event.toolName === toolName`; honor the same call shape used at both existing call sites). **Add a comment pinning the verified pi-dist version + the dist file/line where the predicate was confirmed (drift guard — the suite exercises only the inline copy; a future pi change silently diverges, caught only in Task 13's audit window where the dep IS available).** Keep `import type { ExtensionAPI }` as-is (already erased).

**Step 2:** Verify the suite runs with no node_modules: `npx tsx extensions/sequence-enforcer/sequence-enforcer.test.ts` → expect 28 passed, 0 failed (baseline).

**Step 3:** Add to `ci-main.yml` extension-tests job: `echo "== extensions/sequence-enforcer/sequence-enforcer.test.ts =="; npx tsx extensions/sequence-enforcer/sequence-enforcer.test.ts || failures=$((failures+1))` (match the existing 3-tsx-file pattern; keep the per-file comments accurate as the explicit-suite list grows from 3 to 4 files).

**Step 4:** Run the suite + `print-mode.test.ts` + `print-mode-wiring.test.ts` + `auto-sync.test.ts` — all green.

### Task 2: (a) — tolerant ts parse in checkpointTokenOk

**Intent:** Root cause 1 — the writer emits an ISO string, `Number(ts)` → NaN → a fresh CLEAR token is ALWAYS judged "stale". Without this, the gate can never pass even in its intended happy path.

**Acceptance:** `checkpointTokenOk` accepts ISO (Date.parse), numeric epoch-ms, and numeric epoch-seconds (< 1e12 → ×1000) within the 10-min TTL; the token-acceptance matrix test is green.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (checkpointTokenOk + new `parseTokenTs`)
- Test: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 1 (TDD):** Write the acceptance matrix test — ISO fresh → ok; numeric-ms fresh → ok; numeric-s fresh → ok; stale (>10 min) → block; **TTL boundary: ts = now−599s → ok, now−601s → block; future-ts skew: ts = now+300s → behavior pinned and documented (tolerant parse makes this live in production — currently ok until the skew passes)**; wrong-verdict → block; corrupt → block. Run → fail (NaN path).

**Step 2:** Implement `parseTokenTs(ts: unknown): number | null` and use it in `checkpointTokenOk`'s TTL check.

**Step 3:** Run → pass. Run full suite → green.

### Task 3: (b) — token_phase parsing + PARALLEL_CHECK_TOKEN_FILE + fail-closed

**Intent:** Root causes 2 — `token_phase` is dropped by both loaders so the phase check never fires (any-phase CLEAR passes any checkpoint), and the enforcer hardcodes the token path while the writer honors `PARALLEL_CHECK_TOKEN_FILE`.

**Acceptance:** A step's `token_phase` is enforced (wrong-phase token blocks); a checkpoint step WITHOUT `token_phase` is fail-closed (blocks with a clear message) AND a startup warning lists it; a token at `PARALLEL_CHECK_TOKEN_FILE` (env) is honored. **CRITICAL (P1): read the PLAIN `process.env.PARALLEL_CHECK_TOKEN_FILE` FIRST** — `_getEnv` prefixes `AGENT_`/`ELDATO_` and would read `AGENT_PARALLEL_CHECK_TOKEN_FILE`, never the writer's plain-name contract; AGENT_/ELDATO_ aliases are optional fallback only.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (Step interface, loadSteps both extraction paths, checkpointTokenOk requiredPhase, `process.env.PARALLEL_CHECK_TOKEN_FILE` direct read + session_start warning scan)
- Test: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 1 (TDD):** Tests — phase-match passes; phase-mismatch blocks; missing token_phase on a checkpoint step blocks; `PARALLEL_CHECK_TOKEN_FILE` env path honored (**the test sets the PLAIN env name — the writer's contract — to a tmp path**); **bridge-path tests: (1) a real fixture SKILL.md through `loadSteps` asserts `token_phase` survives the `_try_frontmatter` path; (2) a module-shaped declaration vendored via AGENT_TOOLS_PATH asserts the `_try_module` normalization pass restores it; (3) F2 startup-warning test: a fixture step lacking token_phase fires the warning at load; a step WITH it does not**. Run → fail.

**Step 2:** Add `token_phase: string` to `Step`; extract it in the embedded `_try_frontmatter` python string; for the `_try_module` bridge path, do the normalization INSIDE the python bridge script (yaml is already loaded there — re-read frontmatter for `gate === "checkpoint"` steps missing `token_phase`; **NEVER in TS — the zero-dep CI route forbids a TS YAML dependency**); `requiredPhase = step.token_phase`; fail-closed branch for missing token_phase; **F2 warning fires LAZILY on first activation of a skill whose checkpoint step lacks `token_phase` (NOT a session_start full-scan — the skill stack/stepCache are empty at session_start and a python-spawn per skill across `~/.pi/agent/skills` would be prohibitively slow; lazy-on-activation matches Step 1's "at load" wording and costs zero scan)**; token path from `process.env.PARALLEL_CHECK_TOKEN_FILE` with canonical `/tmp` fallback.

**Step 3:** Run → pass. Full suite → green.

### Task 4: (f) — argv-aware print default + park/pop consistency

**Intent:** Root cause 5 — bare-shell `pi -p` (argv print flag, no PI_MODE env) resolves gate despite the documented "pi -p → warn" default; the audit's gate-mode victims are consistent with this class. This is the documented #201 bare-shell carve-out reversal (decision record in the scope doc).

**Acceptance:** resolveMode argv matrix green (`-p` w/o PI_MODE → warn; PI_MODE=print → warn; interactive → gate; env/file override wins); handleSequenceTimeout park/pop uses the same predicate.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (resolveMode argv seam, handleSequenceTimeout)
- Modify: `extensions/shared/print-mode.ts` (header #201 reversal note)
- Test: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 1 (TDD):** Tests — `resolveMode({}, "/nonexistent", ["pi","-p","task"])` → warn; existing matrix unchanged. Run → fail (no argv seam).

**Step 2:** Add `argv = process.argv` param to `resolveMode`; fallback becomes `isPrintMode(env, argv) ? "warn" : "gate"`; `handleSequenceTimeout` park predicate switches to the same (with an (env, argv) seam for tests).

**Step 3:** Update `print-mode.ts` header: semantic mode decisions are now argv-aware; document the #201 carve-out reversal rationale.

**Step 4:** Run → pass. Full suite + print-mode tests → green.

### Task 5: (g) — single-audit

**Intent:** Root cause 7 — every gate-mode block is audited twice (validateToolCall + handler), inflating the audit 2x and confusing monitoring.

**Acceptance:** Exactly one audit entry per blocked call (handler-owned); a warn-mode would-block at ANY gate emits exactly ONE entry (skips the handler's unconditional `allowed` entry); the two tests asserting validateToolCall-side audit are updated.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (validateToolCall return contract `{block, reason?, wouldBlock?}` — pure; handler owns all audit writes)
- Test: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 1 (TDD):** Update the two audit-asserting tests to assert handler-side entries; add the would-block single-entry test. Run → fail.

**Step 2:** Move all four audit sites (warn_blocked, checkpoint-non-ok, strict allow-list, gate wouldBlock) to the handler; handler skips the `allowed` entry for would-block calls.

**Step 3:** Run → pass. Full suite → green.

### Task 6: (d) — escape-hatch at checkpoint

**Intent:** Root cause 3 — the checkpoint token check precedes the allow-list, so every tool (incl. loop_enforcer, violating #7470) is blocked with no escape. This adds the sole-command escape.

**Acceptance:** At a pending checkpoint in gate/strict: `read` + `loop_enforcer` allowed; `bash` allowed ONLY for the sole-command full-string match (regex mechanically verified in the scope doc, 17/17); everything else fail-closed; escape matrix test green.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (checkpoint branch of validateToolCall + `isCheckpointEscape` helper + `checkpoint_token_fresh` guard)
- Test: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 0 (prerequisite):** Upgrade the fakePi harness to multi-handler dispatch (array per event, preserving registration order) — Task 7's sub-skill-read ordering tests depend on the read-tracker handler running; the upgrade was previously in Task 12, moved here because Task 7 needs it. Run the suite → still green (last-handler behavior preserved for single-handler events).

**Step 1 (TDD):** Tests from the scope doc's matrix — `parallel_work_check.sh plan` allowed; `python3 /path/parallel_work_check.py plan` allowed (`.py` suffix); `env GH_TOKEN=x parallel_work_check.sh plan` allowed (positive allowlist); bare name / `rm -rf /` / `&&` / `&` / newline / tab / NBSP / Ogham / `$(x)` env-injection / `sudo env` / `cd &&` / `python3 -m` / `/usr/bin/python3` blocked; **U+0020-not-rejected regression (assert the reject-set does NOT match a plain space); malformed-event cases (`input: {}`, `command: undefined`, `command: 42`, `command: null` at a gate-mode checkpoint → BLOCKED with the standard handler-owned blocked entry carrying `reason: "malformed_command"` — NOT a new event name (Task 11's four-event list stays authoritative); note `command: 42` is coerced by `String()` with no exception, so the test asserts the block + reason, not crash-avoidance; `command: undefined`/null must NOT throw)**; escape-at-ok-checkpoint → blocked with the `checkpoint_token_fresh` event**; read+loop_enforcer allowed; everything else blocked. Run → fail.

**Step 2:** Implement the escape in the checkpoint branch BEFORE the gate/strict split: `isCheckpointEscape(toolName, command)` = loop_enforcer / read / bash matching the sole-command regex after the whitespace+metachar pre-check (regex per the scope doc — use `new RegExp` or escaped `/`; `[^\S\u0020]` reject-set; explicit env allowlist `GH_TOKEN|CHECKOUT_GUARD_ENFORCE|AGENT_INFRA_PATH`; safe-class values; mandatory `.sh|.py` suffix). **Defensive type-guard (P1): a non-string / missing / non-object bash `command` (malformed event: `input: {}`, `command: undefined`, `command: 42`, `command: null`) is treated as fail-closed BLOCK — never throw into the handler (a throw could fail-open the gate or take down the enforcement chain).** Add the `checkpoint_token_fresh` execution guard (checker-matching bash at an ok-checkpoint blocks with the distinct event). **EVALUATION ORDER (P1): the (d) guard runs against the step captured at call time BEFORE the (c) advancement evaluation — a checker re-run at an ok-checkpoint is blocked against the CHECKPOINT step (event references the pre-advance step), then advancement proceeds (token ok); without this pin the guard would read the NEXT step and never fire.**

**Step 3:** Run → pass (verify against the mechanically-verified 17-case matrix).

### Task 7: (c) — mode-independent advancement + marker contract

**Intent:** Root cause 6 — NO code path advances a checkpoint step in any mode; even gate+valid-token freezes stepIndex forever (subsequent gates unreachable, bridge stale, orchestrator restart loops). The lynchpin.

**Acceptance:** token-ok-driven advancement: tool_call advances iff ok (regardless of tool); tool_result advances iff `!ok@call → ok@result` transition (per-toolCallId marker `{skill, stepIndex, ok}`, same-call suppression, checkpoint-owner-first); warn auto-advances on first call with `checkpoint_skipped_warn` (only audit); blocked calls never advance; force-file consumption hook; announceGate on advance.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (tool_call + tool_result handlers, `findCheckpointGateOwner`, marker map)
- Test: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 1 (TDD):** **The advancement/marker tests use the REAL event shape `{ toolName, toolCallId, input }` (the existing fakePi harness passes bare `{ toolName: "task" }` — without toolCallId every marker keys on `undefined` and same-call suppression silently collapses; sibling calls would look identical).** Tests — valid-token-advance; producer-timing tool_result advance; fail-open guard (failing run → NO advance); back-to-back pair no-double-advance (same-call suppression); completion-order reversal (concurrent siblings); **distinct-sibling-after-advance (1C part 2: sibling A advances via valid token; sibling B's tool_call then lands → validated against the NEXT step); concurrent cross-phase escape race (two sibling checker calls with DIFFERENT phases at a pending checkpoint → exactly one advance, no permanent strand regardless of completion order; extend `checkpoint_token_fresh` semantics to block a checker-matching call whose phase ≠ current step's token_phase so a wrong-phase token never lands while a checkpoint is pending); marker cap/evict (N allowed calls with no tool_result → map stays bounded; late tool_result for an evicted marker does NOT advance)**; sub-skill-read ordering (**requires the fakePi multi-handler upgrade from Task 6 Step 0**); warn first-call advance + `checkpoint_skipped_warn`; advancing call not re-blocked by a following verifier step; **announceGate-after-advance: advance a checkpoint whose next step is ANOTHER checkpoint → the next entry's guidance is token-state-aware (fresh-ok → no checker instruction; else run-or-report) — stops the worker re-running the checker and clobbering a valid token**. Run → fail.

**Step 2:** Implement per the scope doc's pinned contract (SINGLE rule, marker `{skill, stepIndex, ok}` keyed by toolCallId, cap/evict, checkpoint-owner-first resolution, warn precedence). **Marker key-extraction handles a MISSING toolCallId fail-closed: no toolCallId on the event → no marker (the call's advancement still evaluates, but same-call suppression is unavailable for it — assert this in a test).**

**Step 3:** Run → pass. Full suite → green.

### Task 8: (j) — park-only checkpoint recovery

**Intent:** Blocked calls re-arm the 10-min timer forever ("blocked-spam workers never timed out") — a gate-mode session at an un-CLEAR-able checkpoint retries indefinitely. Park-only (never pop: pop → re-read/re-pop loop + silent enforcement loss).

**Acceptance:** ≥3 consecutive blocked calls (counter keyed `(skill.path, stepIndex)`, reset on advance) OR a wall-clock stall at a checkpoint → immediate PARK (state preserved) with `checkpoint_block_recovery` event, one-shot-per-checkpoint; verifier-gate spam unaffected.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (consecutive-block counter + wall-clock trigger in the enforcement handler / handleSequenceTimeout)
- Test: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 1 (TDD):** Tests — block-spam → park immediately, frame survives; one-shot suppression; wall-clock stall parks; **timer-driven park: make a checkpoint current, advance fake time with ZERO further events → the park timer fires (forces a timer-driven implementation, not event-driven); block-read-block-read mixed spam → park within the N-minute bound (reads reset the consecutive-block counter but never advance); audit-volume bound: 1k blocked calls → per-call entry growth is bounded (rate-limit/coalesce with a stated ceiling) OR the unbounded signature is explicitly accepted with a documented cap + disk-watch note; the block-spam run writes ZERO entries to the production log (NODE_ENV=test sink hygiene)**; verifier-gate spam unaffected. Run → fail.

**Step 2:** Implement per the scope doc (counter keyed `(skill.path, stepIndex)` reset on advance/stack-change + **wall-clock evaluated per tool_call against `stepStartedAt` with a stated threshold (e.g. 5 min) — wall-clock is the AUTHORITATIVE trigger: allowed reads reset the consecutive-block counter, and a fully idle session still parks via the timer; checkpoint-stall PARK takes precedence over the interactive-mode 10-min POP** + park-only + one-shot). **Choose and pin the audit-volume decision here: rate-limit/coalesce per-call blocked entries in the handler with a stated ceiling (e.g. ≥20 blocked entries in 60s for the same `(skill.path, stepIndex)` → coalesce to one entry) so the 1k-blocked-calls test is self-contained at Task 8; add an explicit `auditLog` NODE_ENV=test guard (no sink installed → NO production write — the probe-pollution class the scope doc cites) with its own small test.**

**Step 3:** Run → pass. Full suite → green.

### Task 9: (e) — reachable checkpoint guidance

**Intent:** Root cause 3 (second half) — gateGuidance early-returns on `allow.length === 0` so the checkpoint branch is unreachable (audit shows `hint:""`); the worker gets zero constructive guidance.

**Acceptance:** gateGuidance(checkpoint) is non-empty and covers ALL THREE checkpoint states: (1) no-ok token → path-resolvable invocation (PARALLEL_CHECK_BIN-resolved absolute path, phase from token_phase, no `<`/`>` placeholders) that is the **parent/main-checkout CLEAR-able form (omit `--repo` or point at a clean checkout — the worktree-targeted form is DEFER-guaranteed and must NOT be the primary command)** + escape tools + "end your turn and report" fallback; (2) fresh-ok token → "do NOT re-run the checker, proceed" (no invocation named — a re-run REMOVES the token); (3) fail-closed missing-token_phase → "checkpoint unpassable (missing token_phase) — contact operator" (no invocation — the empty phase would produce a no-arg command the escape rejects); warn-mode guidance is mode-aware ("auto-advancing, audit-only"); blocked entries carry `allowed` + `hint`; **criterion 14 conformance: the emitted invocation passes `isCheckpointEscape` AND is the parent/main-checkout form (no `$VAR`, no `<phase>`)**.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (gateGuidance)
- Test: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 1 (TDD):** Tests — checkpoint guidance non-empty; ALL THREE states (no-ok / fresh-ok / missing-token_phase) emit the right variant; no literal placeholders; warn-mode variant; end-your-turn fallback present; **conformance: `isCheckpointEscape("bash", <emitted invocation>)` → true and the command is the parent/main-checkout form (no `$VAR`, no `<phase>`); if `PARALLEL_CHECK_TOKEN_FILE` env is active, the emitted invocation writes where the enforcer reads (env-consistency — guidance must interpolate the env or assert it)**. Run → fail.

**Step 2:** Fix the early-return (gate whitelist) so the checkpoint branch is reachable; write the guidance per the scope doc.

**Step 3:** Run → pass. Full suite → green.

### Task 10: (h) — operator force-pass

**Intent:** The checker CANNOT CLEAR by design in worktrees (C1 DEFER, C4 STALE, no card env) — gate-mode interactive worktree sessions need a scoped operator escape distinct from the kill switch; formalizes the proven hand-token practice.

**Acceptance:** `checkpointTokenOk` honors `/tmp/parallel-check-force.json` (verdict CLEAR + phase + operator + origin + repo binding), per-checkpoint ONE-SHOT (consumed on advance), operator TTL (session-scoped), session_start cleanup, phase enforced; `checkpoint_force_pass` event emitted; human-read-only documentation.

**Files:**
- Modify: `extensions/sequence-enforcer/index.ts` (force-file read in checkpointTokenOk + session_start unlink + force-source audit in handler)
- Test: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 1 (TDD):** Tests — force pass (phase match); force wrong-phase blocks; force repo-mismatch blocks; one-shot consumption deletes the file; TTL; session cleanup; distinct event; **malformed force file (truncated JSON, `{}`, missing verdict/phase/repo/operator/ts, NaN/negative/string ts) → fail-closed block with guidance naming the malformed file; JSON.parse wrapped, all field reads type-guarded (mirror the real token's corrupt→block matrix); cross-session test matching the PINNED delete-on-start semantics (P1): (1) session B writes a force file; session A's session_start LATER runs → A's start DELETES B's lingering file (documented hazard — per-session scoping is the filed separate issue, not this fix); (2) A's one-shot advance at its own checkpoint deletes only the file A's advance consumed (phase/repo binding suppresses cross-repo consumption)**; `checkpoint_force_pass` event. Run → fail.

**Step 2:** Implement per the scope doc.

**Step 3:** Run → pass. Full suite → green.

### Task 11: (i) — documentation updates

**Intent:** The post-fix reality differs from every current doc: workers' checkpoint gates become warn no-ops; the gate in worktrees is effectively human-gated; the audit signal migrates; the skills' #4907 comments name a form (d) blocks.

**Acceptance:** enforcement SKILL.md updated (post-fix reality, force-gate preconditions, signal migration to checkpoint_skipped_warn, token schema, #201 reversal + who-changes, --mode json/rpc gate-resolving class, audit human-read-only); the 3 gated skills' #4907 comments updated to the path-resolvable invocation + escape/force-pass pointers AND `skills/issue-scoping/SKILL.md`'s #4907 block (same bare form — activation-class residual); print-mode.ts header updated (Task 4); skill-lint green.

**Files:**
- Modify: `skills/enforcement/SKILL.md`
- Modify: `skills/writing-plans/SKILL.md`, `skills/commit-workflow/SKILL.md`, `skills/executing-plans/SKILL.md` (#4907 comments)
- Modify: `skills/issue-scoping/SKILL.md` (#4907 block — bare-form residual)

**Step 1:** Update enforcement SKILL.md per the scope doc's (i) list — including the FULL new checkpoint audit-event set (`checkpoint_skipped_warn`, `checkpoint_force_pass`, `checkpoint_block_recovery`, `checkpoint_token_fresh`), the (j) conditional audit signature (per-call blocked + 1 recovery event + 1 park/10min, spam re-arm caveat), and the (h) force-file contract (schema + when to write: one file per checkpoint, consumed on advance, 60-min TTL, machine-shared /tmp path with cross-session clobber hazard — any new session's start unlinks it; write it after the checkpoint is reached; single-operator assumption).

**Step 2:** Update the 3 gated skills' checkpoint-step comments (bare `parallel_work_check <phase>` → path-resolvable + escape/force-pass pointers) AND `skills/issue-scoping/SKILL.md`'s #4907 block (it carries the identical bare-form instruction — activation-class residual: when a gated skill was read earlier in the session, a bare run blocks at a checkpoint with no escape guidance).

**Step 3:** Run `scripts/check-skill-lint.mjs` on the touched skills → green.

**Step 4:** File the separate issues listed under "Separate issues to file" via `gh issue create` (carrying the scope doc's wording + severity) — do NOT absorb them into this PR. **Ensure the list includes the scope doc's canonical "CI hygiene for review-enforcer/verification-gate suites" item (currently listed below — if Task 1's CI work absorbs it, say so explicitly instead of dropping it); the `approval.py` merge-conflict item's provenance is this session's finding (dead approval router — broken pre-existing infra discovered during scoping; AGENTS.md auto-file rule applies) — file it with that context.**

### Task 12: harness upgrade + full regression

**Intent:** The fakePi harness keeps only the last handler per event (upgraded to multi-handler in Task 6 Step 0, which Task 7 consumed); the mislabeled "checkpoint step under warn" test exercises a verifier step.

**Acceptance:** fakePi dispatches ALL registered handlers in order; the mislabeled test renamed/re-scoped to a real checkpoint step; full suite + print-mode + auto-sync green.

**Files:**
- Modify: `extensions/sequence-enforcer/sequence-enforcer.test.ts`

**Step 1:** (Done in Task 6 Step 0 — verify the upgrade is present; no re-work.)

**Step 2:** Rename/re-scope the mislabeled test; add the full-skill warn E2E.

**Step 3:** Run the full suite + sibling suites → all green.

### Task 13: deploy verification (delivery-time)

**Intent:** The #265 sync.sh branch-guard silently blocks deployment when the checkout isn't on main — the fix can merge, CI-green, and never reach the machines that deadlock (the sharpest pre-mortem from Phase 7).

**Acceptance:** After the PR merges: the machine checkout is on main; `sync.sh`/`pi-bootstrap/setup.sh` has run (extension copy); deployed md5 of BOTH `extensions/sequence-enforcer/index.ts` AND `extensions/shared/print-mode.ts` (the argv seam — runtime-imported by the deployed extension) == origin/main md5 (plus the 5 touched skill files — enforcement, writing-plans, commit-workflow, executing-plans, issue-scoping — if the sync path covers them); the positive-audit window (criterion 16) shows `checkpoint_skipped_warn` from the fleet — **with a warm-up allowance: already-running pi processes keep the OLD module until restart, so criterion 16 checks sessions started AFTER the sync (or allows a startup-lag window)**.

**Files:**
- (operation, no code)

**Step 1:** Post-merge, return the machine checkout to main + ff-only pull.

**Step 2:** Run `./sync.sh` (extension copy), then verify md5 of ALL acceptance artifacts == origin/main's md5: `~/.pi/agent/extensions/sequence-enforcer/index.ts` AND `~/.pi/agent/extensions/shared/print-mode.ts` (the argv seam) AND the 5 touched skill files (enforcement, writing-plans, commit-workflow, executing-plans, issue-scoping — where the sync path covers them). Any mismatch → loud failure (silent non-deployment is the exact class this task guards against).

**Step 3:** 2-3 days later, confirm the production audit shows `checkpoint_skipped_warn` events (positive signal — absence of `blocked` alone is not evidence). **Scope the query to sessions started AFTER the sync timestamp** — already-running pi processes keep the OLD module until restart, so pre-sync session gaps must not be read as failure OR as false evidence of success.

### Acceptance Criteria (from the scope doc, all 16)
1. Token-acceptance matrix green (ISO/ms/s fresh→ok; stale/wrong-verdict/wrong-phase/corrupt/missing-token_phase→block) [Tasks 2,3]
2. A `pi -p` worker (argv `-p`, no PI_MODE) reading writing-plans/SKILL.md resolves warn and completes all steps without blocking; audit shows `checkpoint_skipped_warn` [Tasks 4,7]
3. Gate-mode no-token: read+loop_enforcer allowed; `rm -rf /` blocked; `parallel_work_check.sh plan` allowed; bare name + all smuggles blocked [Task 6]
4. Gate-mode valid-token: first call advances; tool_result advances only on !ok→ok; failing run → NO advance [Task 7]
5. Blocked checkpoint entries carry `allowed` + `hint` naming a CLEAR-able invocation + end-your-turn fallback [Task 9]
6. resolveMode argv matrix green; park/pop same predicate; overrides win [Task 4]
7. Force-pass honored with TTL + phase + repo binding + session-clear + one-shot + distinct event [Task 10]
8. Exactly one audit entry per blocked call; would-block single entry [Task 5]
9. Mislabeled test renamed; fakePi multi-handler; full-skill warn E2E [Task 12]
10. Suite green in CI extension-tests; no regressions in print-mode/auto-sync; skill-lint green [Tasks 1,11]
11. Documented residuals stated (headless gate-override, interactive un-CLEAR-able, activation-class, sub-skill-read bypass) [Task 11]
12. ≥3 blocked calls or wall-clock stall → immediate PARK, one-shot; verifier spam unaffected [Task 8]
13. No-double-advance invariant: same-call suppression [Task 7]
14. Hint's named invocation passes the escape check AND is CLEAR-able [Tasks 6,9]
15. DEPLOY GATE: checkout on main + sync run + deployed md5 == origin/main [Task 13]
16. POSITIVE-AUDIT GATE: `checkpoint_skipped_warn` present in production audit [Task 13]

### Separate issues to file (do not absorb)
- swarm: token-production feasibility (PATH/GH_TOKEN/card env/budget/worktree-aware checkout_guard)
- audit session-id schema (also prevents probe pollution; add an enforcement.jsonl reader)
- eldato: skill_declaration.py token_phase
- swarm: writer ts canonicalization + sequence_check.py three-way tolerance
- token file per-session scoping (cross-session clobber — activated by (a))
- CI hygiene for review-enforcer/verification-gate suites (scope doc canonical item — absorb into Task 1 ONLY with explicit note)
- swarm: approval.py committed merge conflict (dead stub) — blocks the approval router (found this session; broken pre-existing infra)
