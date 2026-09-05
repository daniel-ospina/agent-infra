---
title: "Scope: #472 — verification-gate proportionality (micro-tier VGATE skip + cleanup-op over-scope)"
type: engineering
domain: operations
doc_status: draft
subjects.team: epistemic-team
created: 2026-09-05
aboutSubjects: epistemic-team
aboutObjects: agent-infra, issue-472, verification-gate, commit-workflow, review-enforcer
---

# Scope: #472 — verification-gate proportionality gaps

> Level: project | Complexity: standard | Team: epistemic-team | Issue: #472
> Epic: standalone | Research: none — evidence in Context (verified internally)

## Confirmed Problem (Phase 2 — problem-converge)

Two INDEPENDENT defects, sharing only the extension file:

**Defect (a) — 3-way contract drift on micro-tier proportionality.**
`skills/commit-workflow/workflow/01-preflight.md` Micro Tier table says
"Verification-gate (VGATE) → SKIPPED" for micro, but
`extensions/verification-gate/index.ts` has ZERO tier awareness (verified: grep
0 hits; `git log -S micro|complexity|AGENT_ISSUE_COMPLEXITY` on the file is
empty since extraction 1e038c4, 2026-07-30). The doc row was REAFFIRMED in
949f53f (2026-08-25, docs/CSS/static-only → micro auto-detection) while the
enforcement never shipped the behavior. A docs-only micro commit (PR #470,
issue #471, complexity:micro, MEMORY.md + docs/research/*.md, +44 lines) got
VGATE-blocked demanding a per-file `[VGATE]` JSON-PASS despite 5+ reviewer
dispatches. Separately, the SAME table's Review-enforcer row ("KEPT — 1 task
dispatch required") contradicts review-enforcer's actual warn-only micro
behavior (`extensions/review-enforcer/index.ts:785-799`) — the table is drift
on BOTH rows.

**Defect (b) — push-path mis-scope over unrelated staged files.**
`isGitOp` (`extensions/verification-gate/index.ts:335`) folds `git push` into
the commit pattern (`GIT_COMMIT_PATTERN :324`); the non-PR branch computes
`computeStagedDiff` = the ENTIRE index (`:634-641`, `:1094-1101`). A
`git push origin --delete <branch>` (a zero-byte remote-ref deletion) therefore
triggers a whole-index staged check. 05-cleanup.md Step 3.8 runs exactly this
command in the SHARED main checkout on EVERY merged PR — colliding with any
other session's parked staged WIP (the #470 incident: staged
`main-worktree-guard/classify-git.mjs` + `test.mjs` from parked #437 WIP
blocked the cleanup; unblocking required [VGATE]-verifying ANOTHER session's
uncommitted files — the documented #190 drift-contamination vector,
`index.ts:375-376`).

## Direction Decision (controller, Phase 2/5 converge — resolves issue's open question)

**Z-NARROW: implement a content-shape exemption in the extension + correct the
01-preflight gate-contract doc as one consistent unit.** NOT X-wide (full
micro-tier exemption keyed to complexity marker/env) and NOT Y (doc-only
correction).

Evidence for Z-NARROW over Y (doc-only):
1. The issue's binding Indicator 1 first disjunct requires "a docs-only commit
   passing unblocked" — Y cannot satisfy it without rewriting the indicator.
2. 949f53f (2026-08-25) consciously reaffirmed docs/CSS/static → micro with
   human review; the skip is intended for that content class.
3. VGATE's always-on lineage (#7470/#285/#825) governs BYPASS AUTHORIZATION
   (who may disable / sub-agents / children), not scope policy. The extension
   already contains intended-scope skips (#204 merge cross-repo/head-mismatch
   skip-before-diff + audit). Z-NARROW extends that pattern.
4. Safety: VGATE stays on EVERY code-bearing set (any .ts/.mjs/.js/.py/.sql/
   .pg, incl. 1-file <20-line code-micro commits) and every mixed set — the
   content-hash backstop for code is untouched.

Rejected alternatives:
- X-WIDE (marker/env-keyed full micro skip): env vars provably never reach the
  Node extension process (review-enforcer/index.ts:636-641 warning); the
  /tmp/agent-issue-complexity marker has no TTL/repo binding and would poison
  e2e isolation + create a self-servable bypass. Indicator 1's second disjunct
  ("AGENT_ISSUE_COMPLEXITY=micro path") is a trap — the env channel is dead.
- Y (doc-only correction): fails the binding indicator; keeps the 1-2 min
  per-file hash ceremony on docs forever for a class with no demonstrated
  catch-value; does not fix defect (b).

## Confirmed Solution Approach (Phase 5 — solution-converge) — TWO INDEPENDENT MECHANISMS

### Mechanism 1 — content-shape exemption (defect a) — ALLOW-ONLY (controller resolution, solution-verify cycle 1)

In `extensions/verification-gate/index.ts`, when the op's relevant file set
(staged diff for commit/push; branch diff for gh pr create/merge) is ENTIRELY
docs/CSS/static — extensions `*.md|*.css|*.scss|*.html`, build-output path
segments (`public/`, `dist/`, `build/` — any depth) applied to ALL FOUR
extensions (mirroring 02-commit-pr.md Step 1.5's "NOT build templates like
public/index.html"; generated output is not static content regardless of
extension) — skip VGATE for that op. **ALLOW-ONLY: NO self-bless, NO
verifiedSet/bridge writes, NO pendingRehash flag.** The exemption is a SCOPE
rule (VGATE does not apply to pure-docs ops), not a verification rule — the
registry stays verifier-authoritative-only (#190/#38 invariant preserved).
Consequences: a pure-docs op (commit/push/pr-create/merge) is exempt by shape
at any tier; a MIXED docs+code op verifies EVERYTHING fresh exactly as today
(docs included — one [VGATE] dispatch covers the blocked set; no regression
vs baseline). Commit-form guard: exemption applies only to a bare `git commit`
(no `-a`/`--all`/pathspec) — `git commit -a` with staged docs + dirty code
must NOT be newly permissive (keeps the pre-existing `-a` empty-index hole
unwidened). Tier-independent. Audit: `appendJsonl` gate_skip with reason +
redacted file summary (#60 parity).

### Mechanism 2 — op-type deletion classification (defect b, INDEPENDENT of shape)

Delete-shaped pushes compute an EMPTY relevant file set — a remote-ref
deletion ships no local content — and short-circuit allow with audit, BEFORE
any diff computation, no verifiedSet/bridge writes. Forms: `git push origin
--delete X`, `git push --delete origin X`, `git push origin :X` (refspec
deletion), `-d` short form. PURITY REQUIREMENT (controller resolution,
solution-verify cycle 1): classification requires an explicit ∃-deletion
marker (≥1 `--delete`/`-d` token or `:refspec`) AND a remote — a bare `git
push`/`git push origin` is NOT pure (vacuous-truth guard, fail-closed). Purity
flips ONLY on the gate's own verb classes per segment (`git commit|push` verbs
and `gh pr create|merge`); scaffolding segments (assignments, `gh pr view`,
`git branch -D`, comments, `if/fi`, `$(…)`) are ignored — pinning the literal
05-cleanup merged-branch block. Any content refspec, second remote, other flag
(-f/-u/--tags/--all/--force-with-lease), chained content push, or commit/gh-pr
op anywhere → NOT pure → today's gating. Content pushes (`git push origin
main`) stay gated exactly as today (staged-diff scope). `git branch -D` /
`git worktree remove` NEVER matched isGitOp → pinned by regression test as
non-intercepted; do NOT widen isGitOp to them. Quote handling: mask only for
separator scanning; tokenize from original text with quote-strip so a quoted
content refspec (`git push origin "main"`) never classifies pure. Redirect
tokens (`2>/dev/null`, `2>&1`, `>file`) DROPPED anywhere in the push segment
(never terminators — terminating would false-open `git push origin >log
main`).

### Doc correction — ONE consistent contract unit in 01-preflight.md

- Micro-table VGATE row → content-shape rule wording (extracted to its own
  context or retitled so tier-independence is structural, not lexical).
- Micro-table Review-enforcer row → actual behavior (warn-only when marker
  =micro; blocks at standard+/unset).
- "Pi Extension Gates (mandatory — not tier-gated)" section → corrected
  (VGATE is now shape-gated; review-enforcer is tier-gated).
- Micro-table header auto-detect clause reconciled.
- Mechanism-separation sentence: VGATE skip = extension-side/shape-based/any
  tier; review-enforcer micro warn-only = marker-based (label at preflight →
  /tmp/agent-issue-complexity). A docs-only commit on an UNLABELED issue is
  shape-exempt for VGATE but still enforcer-blocked at 0 dispatches.
- Predicate single-sourced: doc row states the mechanical predicate verbatim +
  cross-references 02-commit-pr.md Step 1.5; extension mirrors; boundary tests
  pin the examples.

## Out-of-scope (filed as follow-up issues, NOT absorbed)

1. Review-enforcer micro policy (hard-require 1 dispatch vs warn-only) — the
   residual net behind the docs skip.
2. 02-commit-pr.md Step 1.5 + 03-code-review.md micro-line drift sites +
   AGENTS.md tracked-status stale note (01-preflight.md:132 says untracked but
   AGENTS.md IS tracked).
3. Content-push range-rescope candidate (verify pushed commit range vs index) —
   NOT required by Indicator 2.
4. Pipeline-compliance issue-link requirement for docs-only commits (Context
   note [a]; may be deliberate policy).

## Boundary & Stakeholders

- In scope: verification-gate index.ts + index.test.ts + index.e2e.test.ts +
  01-preflight.md. Follow-up issues opened during implementation.
- Stakeholders: review-enforcer (same op regex, marker writer/cleaner),
  commit-workflow consumers (01-preflight, 02 Step 1.5, 05-cleanup Step 3.8),
  task sub-agents (TASK_HEARTBEAT/PI_MODE=print — content-shape is
  deterministic so child behavior is uniform; no new bypass channel), audit
  consumers (#60 gate_skip parity).
- Safety properties preserved: any staged file in a COMMIT is VGATE-verified
  (code never exempt); delete ops ship no content; mixed docs+code sets keep
  full VGATE; no new env/marker trust channel; fail-closed on hash mismatch.

## Assumptions Register

| Assumption | Status | Evidence |
|---|---|---|
| Marker channel is the only live tier channel | validated | review-enforcer :57,636-641,789; env dead |
| `git branch -D`/`git worktree remove` never matched isGitOp | validated | regex :324-339 |
| Delete-shaped push ships no file content | validated | git ref-deletion semantics |
| Exempted files self-blessed with disk hash stay fail-closed | validated | hashAndMergeFiles :752-774 records current disk hash |
| 949f53f reaffirmation = owner intent for docs class | validated | commit 949f53f 2026-08-25 |
| VGATE always-on lineage = bypass-authz, not scope policy | validated | #7470/#285/#825 semantics |

## Falsification Check

Direction flips to X-wide/Y if: (1) a pre-extraction or agent-infra design doc
ratifies "VGATE SKIPPED at micro" as a deliberate all-gates proportionality
rollout with a planned env channel — none exists (issue "Research Needed" +
full git archaeology); (2) owner ratifies always-on (Y) at the human gate —
the O/I/T would need rewriting; (3) a flow is found where push-time staged
check was the ONLY protection for shipped content (index is empty post-commit;
none found).

## Complexity

| Domain | Rating |
|--------|--------|
| Org Infra | standard |
| Architecture | low |
| UX | low (no user-facing surface) |
| Ontology | low (no schema/data) |

## Verification Gates

### problem-verify: 3 cycles, converged (0 P0, 0 P1 remaining)
- Cycle 1: verifier A 0P0/1P1/4P2/3P3/2P4; verifier B 0P0/2P1/2P2/2P3/1P4.
- Controller fixes: .html build-template carve-out (mirror Step 1.5); doc
  correction = whole gate-contract unit; review-enforcer net → follow-up issue
  + honest rationale; audit gate_skip on all skip surfaces; tier-independent
  shape wording.
- Cycle 2: verifier A 1P1 (whole 01 gate-contract unit incl. Review-enforcer
  row + Pi-Gates section); verifier B 2P1 (same-file enforcer row; defect (b)
  needs explicit op-type empty-set mechanism).
- Cycle 3: both verifiers confirmed the two-mechanism design is internally
  sound (self-blessing fail-closed verified, no code-bypass path); P1s were
  process-state (fixes not yet materialized in worktree — this doc + the
  implementation are the materialization).

### solution-verify: 2 cycles, converged (0 P0, 0 P1 remaining)
- Cycle 1: verifier A 0P0/0P1/2P2/…; verifier B 0P0/2P1 (∃-marker vacuous-truth
guard on bare push; per-segment verb-class purity for the 05-cleanup fenced
block)/4P2/….
- Controller fixes: (P1) explicit ∃-deletion-marker + remote conjunct, bare
`git push` never pure; (P1) per-segment verb-anchored purity — only gate verb
classes flip, scaffolding ignored, both ceremony literals pinned verbatim;
(P2) mechanism (a) simplified to ALLOW-ONLY (no self-bless, no registry/bridge
writes, no pendingRehash — registry stays verifier-authoritative); commit-form
guard (`-a`/`--all`/pathspec never exempt); all-four build-output denylist;
quote-strip not mask; redirect tokens dropped.
- Cycle 2: design re-verified — both P1s closed at the DESIGN level (∃-marker
conjunct sound; per-segment verb purity handles the literal 05-cleanup block;
ALLOW-ONLY has no regression/perverse incentive; -a guard acceptable +
follow-up filed). Verifier's residual P1 was process-state only (code not yet
materialized — implementation is the subsequent pipeline stage). Solution
diamond converged: 0 P0/P1 in design.

## Review Cycle Log

- problem-diverge: 2 agents (framings A1/A2/A3 + devil's advocate challenge)
- problem-converge: 2 agents → Z-NARROW direction (both rejected Y on
  O/I-T + reaffirmation evidence; one split on X-wide safety)
- problem-verify: 3 cycles (above)

<!-- issue-scoping: v5.1 double diamond + verify -->
