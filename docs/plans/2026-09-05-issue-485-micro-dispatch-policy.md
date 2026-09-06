---
title: "Plan: #485 — review-enforcer micro-tier dispatch policy (hard-require ≥1 dispatch)"
type: engineering
domain: operations
doc_status: draft
subjects.team: epistemic-team
created: 2026-09-06
aboutSubjects: epistemic-team
aboutObjects: agent-infra, issue-485, review-enforcer, commit-workflow, issue-472, issue-513
---

<!-- research-path: decision audited in-repo — extensions/review-enforcer/index.ts micro branch (~:785-803) + docs/scoping evidence on issue #485 comment (2026-09-06) + git archaeology (1e038c4 extraction, c4f1647 #472, 5077695 #486) + review records ~/.pi/agent/reviews/*.json + audit log ~/.pi/agent/audit/gate-events.jsonl -->

# fix(review-enforcer): decide micro-tier dispatch policy — hard-require 1 dispatch (Option A)

**Goal:** Close the zero-dispatch net for docs-only micro commits by making the review-enforcer micro tier block at 0 dispatches (uniform ≥1-dispatch floor at every tier — the dispatch floor is content-free by org-wide design (F2); the zero-REVIEW residual is tracked in #513), sweeping every commit-workflow surface that asserts warn-only, and pinning the contract with behavioral + drift tests so it cannot re-drift (#486/#493 class).

**Team:** epistemic-team
**Issue:** #485 (complexity:standard, Level: project)
**Status:** implemented — PR #518 in code-review; plan-review clean (cycles=5, second-model gate NO P0/P1); test-review CLEAN (3 cycles, NO ISSUES FOUND cycle 3); doc_status stays `draft` until merge per 05-cleanup convention

## Decision + Rationale (the issue's T1)

**Decision: Option A — hard-require ≥1 task dispatch at micro.** The micro branch flips from warn to block-on-zero; docs that assert "micro → WARN-ONLY" are swept to the uniform contract; tests pin the behavior.

**Audit evidence:**
1. **The zero-gate net is real and newly created by #472.** For a `complexity:micro` docs/CSS/static-only commit at 0 dispatches: review-enforcer warns (micro branch), VGATE is content-shape-exempt (#472), pre-flight Low-risk skips typecheck/build, code-review is skipped at micro (03-code-review.md Step 2), and pipeline-compliance skips checks b–e at micro (scripts/check-pipeline-compliance.sh:239). Every enforced agent-quality gate clears.
2. **Unlabeled docs-only commits already block today** (fall-through block path at index.ts ~:801-802 when no marker). Option A makes labeled-micro match them — a uniform floor, not a new strictness regime.
3. **Warn-only was never deliberately decided in agent-infra.** The branch arrived with the pi-monorepo extension extraction (1e038c4, 2026-07-30). The pre-#472 docs claimed "KEPT — 1 task sub-agent dispatch required before git ops" (git show c4f1647) — doc-aspiration the code never enforced. #472 doc-conformed DOWN to the code. A is first-time code enforcement of a long-documented intent.
4. **The "docs are low-consequence" premise is false for the contract-doc subclass.** #475 and #492 changed `skills/*.md` — files encoding agent behavior for every future session. #492 (itself a docs-only micro PR) spawned follow-ups #488/#493; its drift was found by automated checks, not review. Blast radius of a wrong contract-doc edit = all sessions.
5. **Micro CODE commits are unaffected by the flip.** VGATE is never shape-exempt for code, and its mandatory `[VGATE]` verification dispatch increments the review-enforcer any-task counter before commit. Only docs-only micro at 0 dispatches is newly blocked.
6. **Empirical scan:** no open bug/regression issues reference recent micro PRs #470–#501 — but that evidence is regime-misattributed (those PRs merged under the OLD regime: VGATE ceremony + "KEPT" docs both active). The true zero-gate net was ~1 day old at scoping time; Option B's "proven safe" claim is unearned.
7. **BLOCK_MESSAGE stale path (pre-existing adjacent bug, filed separately):** BLOCK_MESSAGE ~L618 points at `operations/skills/code-review/SKILL.md`, which does not exist in agent-infra (`skills/code-review/SKILL.md` is the repo path; `operations/skills` is the consumer-repo hardlink location). Cross-repo path semantics need their own decision — not absorbed into #485.
8. **F2 honesty (any-task dispatch proxy):** the gate's floor is "≥1 task sub-agent this session" — deliberately content-free org-wide ("ponytail: binary counter… trusts the agent is well-intentioned but forgetful"). A's justification is therefore **consistency with the established org-wide floor** + closing the newly-ungated consequential-docs class — NOT "prevents zero-review merges." The residual (a docs diff merging with no agent having looked at it, wearing a satisfied-gate badge) is the same accepted residual as standard/complex and is tracked for the merge-time fix in #513.

**Rejected: Option B (keep warn-only, document the net)** — fails the orchestrator criterion (≥1 quality gate per landed change) by design; its empirical pillar is regime-misattributed; its only backstop is open issue #513 with no ETA. Sequencing note: A lands the commit-time floor now; #513 closes the merge-time attestation residual. **Would have been better if** #513's anchored-dispatch contract landed first and made commit-time enforcement redundant.

## Implementation Plan

### Task 1: Flip the micro branch + micro-specific block message

**Intent:** The review-enforcer's micro tier must block at 0 dispatches like every other tier (uniform floor), with remediation guidance that is correct for micro (the multi-agent code-review gate is skipped there, so the generic BLOCK_MESSAGE pointing at the code-review skill would misdirect).
**Acceptance:** `extensions/review-enforcer/index.ts` contains a `MICRO_BLOCK_MESSAGE` and the micro arm (`tier === "micro"`) returns `{ block: true, reason: MICRO_BLOCK_MESSAGE }`; the phrases "micro tier allows bypass", "warn only" (space-form), and the "(proportional)" gate comment are gone from index.ts; the marker read remains (message selection); the #285 task-sub-agent early return and the merge-registry path are unchanged.
**Files:**
- Modify: extensions/review-enforcer/index.ts

Steps:
1. Add `MICRO_BLOCK_MESSAGE` beside `BLOCK_MESSAGE` (~:615-621) and export it (T1 asserts hard equality). Content (docs-only-primary): state 0 dispatches block at micro; docs-only sets → dispatch a lightweight reviewer naming the docs diff ("even a trivial one-line review counts"); code sets satisfy the dispatch via VGATE's own `[VGATE]` dispatch — with a fallback clause for VGATE-disabled sessions: "if VGATE is disabled/bypassed, dispatch any lightweight task sub-agent — the gate counts any task dispatch"; the multi-agent code-review gate stays skipped per 03-code-review.md; escape-hatch line mirroring BLOCK_MESSAGE (`AGENT_SKIP_REVIEW_GATE=1` or `ELDATO_SKIP_REVIEW_GATE=1`). MUST NOT reference the code-review skill path (T1 asserts absence).
2. Flip the micro arm (~:785-799): keep the tier read; replace the warn `return undefined` with `{ block: true, reason: MICRO_BLOCK_MESSAGE }`; rewrite the "Proportional gate: micro tier → warn only" comment to state the uniform ≥1-dispatch policy + marker-read-for-message-selection.
3. Sweep "proportional/warn-only" drift language in code comments (~:699 "block git ops if no reviewers (proportional)", ~:785).
4. Export the declarative policy contract for the drift-pin test: `export const TIER_RULE = { micro: "block", standard: "block", complex: "block", unknown: "block", unlabeled: "block" } as const;` — **declarative, consumed by the T2 drift test only** (the block decision is uniform, so no production branch consults it; T1/T1b + the source-shape guard T3 carry the code↔behavior link — mirroring the VGATE precedent's symmetric doc↔export compare without artificial production indirection). The "unlabeled"/"unknown" keys map to an absent marker or a non-micro marker value (`unknown` is the literal pre-flight TIER value when the issue is unlabeled).

### Task 2: Docs sweep (01/02/03) + REVIEW-ENFORCER-TIER-RULE fence

**Intent:** Every commit-workflow surface that asserts "micro → WARN-ONLY / warn but do not block" must state the uniform block contract so agents and docs agree with the code.
**Acceptance:** final (plan-end) grep over the four NON-TEST scoped files (`extensions/review-enforcer/index.ts`, `01-preflight.md`, `02-commit-pr.md`, `03-code-review.md`) for `"warn-only\|WARN-ONLY\|warn but do not block\|warn instead of block\|micro tier allows bypass"` returns 0 hits — index.ts tokens are removed in Task 1, the doc assertions in this task. index.test.ts is intentionally EXEMPT from the grep corpus: it carries the anti-token DATA (`MICRO_WARN_ANTI_TOKENS`) plus historical comments — the T2 CI pin scans only the three docs, so the one-time acceptance grep scopes to the same non-test surface. The fence exists; the #493 env-export COMMAND lines (01-preflight L244-245: export + echo) and the VGATE-SHAPE-RULE fence (L323-330) are byte-identical — the annotation SENTENCE above them was rewritten (see Task 2 step 1 note: pre-implements #493 T2's re-label option; the export line itself is untouched per the #493 boundary). (Anchors: export+echo at L244-245, VGATE-SHAPE-RULE fence at L338-345 post-fence-insertion — content-first edits, numbers re-verified at merge per the risk register.) The same anti-tokens (plus the space-form "warn only") are pinned DURABLY in the T2 drift test (Task 3) — CASE-INSENSITIVE with a single legit-line carve-out — so a future docs-only commit re-inserting warn-only prose fails post-merge CI instead of passing the one-time grep.
**Files:**
- Modify: skills/commit-workflow/workflow/01-preflight.md
- Modify: skills/commit-workflow/workflow/02-commit-pr.md
- Modify: skills/commit-workflow/workflow/03-code-review.md

Steps:
1. **01-preflight.md** — sweep: the export-annotation parenthetical ("review-enforcer proportional blocking", now ~L241) — rewritten to the legacy/vestigial annotation ("the extension never consults this env var for gate decisions; session_start reads it only to warn that it has no effect; #493 owns dropping the export"). Note: this edit touches the #493-owned annotation SENTENCE (pre-implementing #493 T2's re-label option — #493 coordination comment updated to match); the export COMMAND + marker-write lines (L244-245) and the VGATE-SHAPE-RULE fence (L338-345 post-fence-insertion) are untouched. Also sweep: L250 mechanism-separation sentence (reshape: the marker selects the MESSAGE, not allow/block — labeled-micro docs-only commits now block like unlabeled; VGATE shape-exemption unchanged); L254 Micro table Review-enforcer row → **BLOCK at 0 dispatches — ≥1 task dispatch required at EVERY tier (micro included since #485)**; L259 rationale (micro code sets satisfy via VGATE's own dispatch; the residual case the uniform block closes is docs-only micro); L290 extension-gates intro (uniform ≥1-dispatch block; marker read selects the micro message); L293-294 Review Enforcer Gate prose + one line in the how-to-satisfy (~L298-306) documenting the micro block message.
2. **Fence** — insert after the Review Enforcer Gate bypass line (~L308), before `### Verification Gate`:
   `<!-- REVIEW-ENFORCER-TIER-RULE: machine-read by extensions/review-enforcer/index.test.ts drift test — keep in sync with extensions/review-enforcer/index.ts TIER_RULE. "unlabeled"/"unknown" = no marker or a non-micro marker value → block. -->` plus a standalone table `| Tier | 0-dispatch git-op policy |` with rows micro/standard/complex/unknown/unlabeled → `block`, closed by `<!-- /REVIEW-ENFORCER-TIER-RULE -->`. Note under it: micro code sets satisfy the dispatch via VGATE; docs-only sets dispatch a lightweight reviewer; multi-agent code-review stays skipped.
3. **02-commit-pr.md L71** — excise ONLY the review-enforcer warn-only clause ("review-enforcer warn-only at Micro via the /tmp/agent-issue-complexity marker — 0 dispatches warn but do not block."), replace with the uniform contract ("review-enforcer ≥1-dispatch applies at Micro — 0 dispatches BLOCK at every tier; the marker read selects the micro remediation message only; code sets satisfy the dispatch via VGATE; docs-only micro sets dispatch a lightweight reviewer"). Preserve the VGATE content-shape clauses verbatim; the parenthetical is balanced — restructure by closing the outer paren after the micro-class clause so the VGATE sentences stand alone.
4. **03-code-review.md L31** — replace the micro-skip block's false clause ("consistent with the review-enforcer extension being WARN-ONLY at Micro… 0 reviewer dispatches warn but do not block — extensions/review-enforcer/index.ts micro branch; Standard+/unset block") with the flip-consistent triad: (a) micro skips the MULTI-AGENT code-review GATE by design; (b) the review-enforcer ≥1-dispatch still applies — 0 dispatches block at EVERY tier (marker read selects the micro message); (c) VGATE satisfies it for code sets (or, with VGATE disabled, any lightweight task dispatch); docs-only sets dispatch a lightweight reviewer — NOT a reinstatement of the multi-agent micro review. No clean-micro/merge-record language (#513 boundary).

### Task 3: Behavioral + drift-pin + source-shape tests

**Intent:** Pin the new contract so neither the code nor the docs can silently re-drift (F3: unpinned prose re-drifted #472→#486→#493 while the VGATE-SHAPE-RULE fence held zero drift).
**Acceptance:** `NODE_ENV=test npx tsx extensions/review-enforcer/index.test.ts` → 98 passed, 0 failed (94 baseline + T1/T1b/T2/T3); `NODE_ENV=test npx tsx extensions/verification-gate/index.test.ts` → 197 passed, 0 failed (VGATE fence untouched).
**Files:**
- Modify: extensions/review-enforcer/index.test.ts

Steps:
1. Import `deepEqual` from `node:assert/strict` (currently only `ok, equal` at ~:46), and add `MICRO_BLOCK_MESSAGE` + `TIER_RULE` to the static `./index.js` named-import block (~L24-44) — the symbols only exist after Task 1 exports them, and this import edit is what makes step 7's full-stash-breaks-module-load reasoning true.
2. Reword the stale `withMarkerIsolated` comment (~:832-834): since #485 every tier blocks at 0 dispatches; the marker only selects the block message. Keep the helper (the new T1 writes the marker and needs deterministic cleanup).
3. **T1 — behavioral flip, marker=micro** (`testAsync`): `withTempHome` + `withMarkerIsolated`; write `/tmp/agent-issue-complexity` = `micro`; `PI_MODE=print`; factory + `session_start`; fire `git commit -m x` at 0 dispatches → `block === true`, `reason === MICRO_BLOCK_MESSAGE` (hard equality on the exported const), reason includes the docs-only remedy, reason does NOT include the code-review skill path; after one `tool_result {toolName:"task"}` → retry `git commit` → allowed (undefined).
4. **T1b — behavioral message boundary, non-micro marker** (`testAsync`, same harness): write marker = `standard`; fire `git commit -m x` at 0 dispatches → `block === true`, reason is the GENERIC `BLOCK_MESSAGE` (includes "No reviewers were dispatched"), does NOT include the micro docs-only remedy — pins the message-selection state machine (a regression collapsing message selection fails this).
5. **T2 — drift pin + durable prose anti-tokens** (sync `test`, structural mirror of verification-gate's drift test ~L1640-1738): `isSourceCheckout()` soft-skip for deployed copies (log the skip reason); resolve the three swept docs via `new URL("../../skills/commit-workflow/workflow/<file>.md", import.meta.url)` (01-preflight, 02-commit-pr, 03-code-review); vacuous-pass guard (`ok(false, "...would pass vacuously...")` when a doc is unreachable); parse the REVIEW-ENFORCER-TIER-RULE fence from 01-preflight (opener/closer presence, anchored separator row, exactly-2-cell data rows); `deepEqual` the SORTED `fenceRows` against the SORTED `Object.entries(TIER_RULE)` — order-insensitive symmetric doc↔export compare (a cosmetic reorder of fence rows or TIER_RULE keys must not fail CI; matches the VGATE precedent's sort-based robustness); then assert the durable prose pin across all three docs: each doc contains NONE of `["warn-only", "warn only", "warn but do not block", "warn instead of block", "micro tier allows bypass"]` — implemented CASE-INSENSITIVE (re-drift case-mutants "WARN-ONLY"/"Warn-only"/"WARN only" are in the historical vocabulary) with a substring-strip carve-out for the single legitimate on-demand-gates line (LEGIT_ON_DEMAND_LINE = "Quality gates available on-demand (WARN only, do not block)", stripped per line, exactly-once in 01-preflight / zero in 02/03, anchor-count pinned); converts the one-time acceptance grep into a CI-enforced pin that runs in ci-main's post-merge extension-tests job and can never disagree with it (same case-insensitive vocabulary, same doc corpus).
6. **T3 — source-shape guard** (sync `test`, E14 `src.includes` technique already used at ~:964-971): read `./index.ts`; assert absence of the anti-token set — implemented as a CASE-INSENSITIVE loop over `[...MICRO_WARN_ANTI_TOKENS, "allows bypass", "proportional"]` (derived from the T2 docs pin's shared vocabulary so the two backstops cannot diverge; WARN-ONLY case-mutants are covered via "warn-only"; the code-only additions close the docs-corpus gap) — a future micro CODE commit re-labeling the branch "warn-only"/"proportional" fails post-merge CI; assert presence of `reason: MICRO_BLOCK_MESSAGE`. The warn-shape regression (micro branch returning `return undefined`) is pinned by a region check: slice index.ts between the tier-read comment and the fall-through `return { block: true, reason: BLOCK_MESSAGE }` (full-file lastIndexOf anchor so a micro-collapse cannot vacuous-pass), assert the slice contains no bare `return undefined` (whole-file includes would false-positive on the legitimate non-bash/disabled/non-git early returns).
7. **Red→green demonstration:** after authoring T1/T1b, run the suite against a PARTIAL revert of the Task 1 flip — restore only the old warn path in the micro branch (`return undefined`), KEEPING the `MICRO_BLOCK_MESSAGE`/`TIER_RULE` exports (a full stash breaks module load: index.test.ts imports those symbols statically at ~L24-44, so the whole file would error at evaluation instead of showing assertion failures) → expect **T1 to FAIL** (`block === true` / hard equality on reason) **and T3's region-slice guard to FAIL** (the reverted arm reintroduces a bare `return undefined` inside the slice); **T1b stays green by design** — it pins the micro-vs-generic message boundary on the `standard` marker, whose block behavior is identical pre- and post-flip (a flip regression that ALSO collapses message selection is what makes T1b fail). Restore the flip → expect 98 green.

### Task 4: Plan doc + commit via commit-workflow

**Intent:** Land the single unit (code + tests + docs + plan doc) through the full commit ceremony so self-application of the gates is exercised (review-enforcer ≥1 dispatch + VGATE on the mixed code+docs set + pre-flight Skill Enforcement Audit + test-writing → test-review on the modified test file).
**Acceptance:** PR opened with body "Fixes #485"; code-review to convergence; merged; issue labeled implemented.
**Files:**
- Create: docs/plans/2026-09-05-issue-485-micro-dispatch-policy.md (this doc)

Steps:
1. Run commit-workflow: pre-flight (typecheck via tsx suites, enforce-protocol-table.sh), stage the 5 code/docs files + this plan doc (never `git add -A`), commit via `/tmp/commit-msg.md` + `git commit -F` (timeout ≥300s).
2. Test-Review ceremony: run test-writing → test-review with `--caller test-writing` on the modified `index.test.ts` (hash write requires that flag form — test-review SKILL.md L447). NOTE: the pre-flight Test-Review Hash Backstop's micro-skip is a BODY-substring grep (`gh issue view <N> --json body | grep -q 'complexity:micro'` → exit 0); #485's body contains the literal `complexity:micro` in prose, so the hash GATE silently exits 0 for this commit regardless of the standard label — the ceremony still runs because test-writing mandates independent review of edited test files, but do not claim the gate fired. The body-grep-vs-label channel quirk is filed as a follow-up issue (a Standard issue whose body mentions the micro tier silently skips a Standard-tier gate).
3. Open the PR (draft), run the code-review skill to convergence (second-model final gate), record the review, merge.
4. Post-merge sync: run the skill sync (`bash sync.sh` from the main checkout, or the auto-sync extension at next session start) and verify the installed mirror converges — `~/.pi/agent/skills/commit-workflow/workflow/01-preflight.md` contains the REVIEW-ENFORCER-TIER-RULE fence and none of the anti-tokens. The T2 drift test soft-skips deployed copies (isSourceCheckout), so mirror convergence is verified manually at merge time, not by CI.

## Integration Surface Map

| Surface Type | Specific Surface | Data Flow | Contract | Test Layer |
|---|---|---|---|---|
| Extension gate decision | review-enforcer micro arm vs dispatch count | Internal | 0 dispatches → block (all tiers); ≥1 → allow | Unit (T1, factory harness) |
| FS marker channel | /tmp/agent-issue-complexity read | In | marker=micro → micro message; absent/unknown → generic message; both block | Unit (T1/T1b harness, withMarkerIsolated) |
| Docs↔code contract | 01-preflight fence ↔ index.ts TIER_RULE | Bidirectional | fence rows == TIER_RULE entries | Drift test (T2, VGATE precedent) |
| Source shape | index.ts micro arm | Internal | no warn-return shape | Source-shape guard (T3, E14 precedent) |
| CI enforcement | ci-main.yml extension-tests (post-merge) | In | suite runs 98 green (T1/T1b/T2/T3 included) | Existing wiring (untouched) |
| Enforcement audit | enforce-protocol-table.sh (skills/** trigger) | In | Pass 1 green (no manifest/SKILL.md changes) | Pre-flight + CI (no new entries) |

## Verification Plan

- `NODE_ENV=test npx tsx extensions/review-enforcer/index.test.ts` → 98 passed, 0 failed (red→green demonstrated in Task 3 step 7 via partial revert: T1 + T3 region guard go red on the warn shape; T1b stays green by design).
- `NODE_ENV=test npx tsx extensions/verification-gate/index.test.ts` → 197 passed, 0 failed (VGATE-SHAPE-RULE fence untouched).
- Scoped grep sweep (Task 2 Acceptance, 4 non-test files, 5 anti-tokens; index.test.ts exempt as the token carrier) → 0 hits.
- `bash scripts/ci/enforce-protocol-table.sh` → passes (Pass 1; Passes 2/3 skip in agent-infra).
- `git diff --stat` → exactly the 6 files (index.ts, index.test.ts, 01-preflight.md, 02-commit-pr.md, 03-code-review.md, plan doc). commit-workflow/SKILL.md, AGENTS.md, enforcement/, extensions/verification-gate/*, 04-merge-deploy.md, docs/plans historical records untouched.
- Code-review (commit-workflow Step 2/3) with fresh reviewers; second-model final gate.
- Test-Review ceremony for the modified index.test.ts (test-writing → test-review `--caller test-writing`; the pre-flight hash GATE skips via body-substring grep — see Task 4 step 2 note).

### Test-Review Cycle Log (index.test.ts #485 additions)

| Cycle | Reviewers | Verdict | Issues fixed |
|---|---|---|---|
| 1 | Correctness, Coverage/Surface, Test-Quality (3 parallel, fresh) | 2×P1 + 9×P2 | withMarkerIsolated asymmetric teardown (P1 — leaked marker into real /tmp path); T1/T1b unguarded PI_MODE restore; T3 non-load-bearing tokens 2/4 + comment-prose token; T1 marker not producer-format ("Micro\n"); T1b omitted unlabeled key reason; T2 anti-token case-split (P1); T1 remediation self-referential (added positive [REVIEW]+docs-only pins); T3 no isSourceCheckout guard; T3 region first-occurrence vacuous-collapse |
| 2 | Same 3 roles (fresh) | NO P0/P1; 3×P2 (converged: vacuous ordering anchor; missing micro×≥1-dispatch cell; T2 whole-line carve-out) | Ordering anchor re-pinned to unique early-return string; T1 complement cell (micro+1 dispatch → allowed, behavioral ordering pin); T2 substring-strip carve-out + exact-once anchor count; T1b generic-message direction pins (code-review-skill path present, no micro content) |
| 3 | Same 3 roles (fresh) | **NO ISSUES FOUND** (all three, verbatim) | — |

Hash written: ~/.pi/agent/test-review/fbb28d…803.json (status CLEAN, --caller test-writing).

## Risk Register

| Risk | Mitigation |
|---|---|
| Docs-only micro sessions now block at 0 dispatches (behavior change) | Intended; MICRO_BLOCK_MESSAGE prescribes the minimal compliant act (lightweight reviewer naming the diff); escape hatch documented |
| Escape-hatch normalization (AGENT_SKIP_REVIEW_GATE) | Micro message prescribes compliance first, hatch last; #513 pairs merge-time evidence |
| Token-dispatch equilibrium (F2 content-free floor) | Accepted org-wide design (same as standard/complex); surfaced to #513 |
| #493 merge-order drift | Coordination comment posted on #493 (T1 premise obsoleted; T2 valid; land after #485). Post-code-review correction (2026-09-06): the annotation SENTENCE above the export was rewritten by #485 (pre-implements #493 T2's re-label option) — the #493 coordination comment updated to reflect that; the export COMMAND + echo lines (L244-245), SKILL.md, and the VGATE-SHAPE-RULE fence remain untouched by #485. #493 residual scope: decide dropping the vestigial export line + SKILL.md index prose |
| AGENT_SKIP_VGATE / ELDATO_SKIP_VGATE session + micro code at 0 dispatches | Post-flip this is fail-closed (blocked) but the VGATE-prescribed remedy cannot occur; MICRO_BLOCK_MESSAGE includes the fallback clause ("dispatch any lightweight task sub-agent — the gate counts any task dispatch"); escape hatch remains; #513 pairs merge-time evidence |
| Installed skill mirror lag (~/.pi/agent/skills stale until sync) | T2 drift test soft-skips deployed copies by design; Task 4 step 4 runs the sync post-merge and verifies convergence manually |
| Origin/main advanced post-draft (e.g. #500's +2-line 01-preflight edit) | Commit-workflow pre-flight BEHIND check fetches+rebases before merge, shifting absolute line anchors; edit content-first (unique-text, not line numbers) and re-verify the export/echo lines (L244-245) + VGATE-SHAPE-RULE fence (L338-345 post-fence-insertion) byte-identity against the synced base |
| Dispatch-count block path has no durable audit event (pre-existing; extended to docs-only micro by the flip) | Merge-registry + VGATE blocks audit (#60); the dispatch block logs console-only. Follow-up issue filed (#516) rather than absorbed; MICRO_BLOCK_MESSAGE directs compliant action |
| VGATE-SHAPE-RULE fence damage | Fence token names disjoint; verification-gate suite re-run (197) |
| Stale marker leak flips expectations | Post-flip a micro marker only changes the MESSAGE, not allow/block (fail-closed); withMarkerIsolated keeps tests deterministic |
| enforce-skills.yml CI on skills/** | Pass 1 unaffected (no manifest/SKILL.md changes); Passes 2/3 skip in agent-infra |
| BLOCK_MESSAGE stale path (operations/skills vs skills) | Pre-existing adjacent bug — filed separately (not absorbed; cross-repo path semantics) |

## Learnings

To be appended after execution (per memory contract — no code gotcha expected).

<!-- plan-review: cycles=5, status=clean, version=2.3.0 -->
