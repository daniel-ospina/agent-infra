---
title: "Research: #755 verification-gate merge scope — axis research, integration surface, provenance"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-11
aboutSubjects: verification-gate, commit-workflow, organisation-design-team
aboutObjects: agent-infra, issue-755, issue-737, issue-770, issue-775, issue-790, issue-791
---

# Research Brief

## Raw Notes

### Axis Research

- **2026-09-11T16:31:08** [pitfalls] ### Axis Research (Phase 1.5 — #755, Architecture=HIGH / Ontology=MEDIUM / UX=low / deps=none)

**Architecture axis — canonical.** Three-dot from the merge base is the canonical answer to "what did this branch author": `git diff A...B` ≡ `git diff $(git merge-base A B) B`; git documents `--merge-base` as the explicit spelling to avoid `..`/`...` confusion. Sources: git-scm.com/docs/revisions, git-scm.com/docs/git-diff, peter.eisentraut.org/blog/2022/09/13/git-diff-and-git-log-and-dots ("three dots for diff, two for log"). GitHub's PR "Files changed" is a three-dot diff anchored on the merge base (docs.github.com → pull-requests/reference/branches). Documented exceptions: `diff` and `log` dots differ; the merge base must be computable (shallow/missing refs); three-dot EXCLUDES remote-side-only files — which is why #487 deliberately chose 2-dot for the push path (D-rows of a force push must appear).

**Architecture axis — competitor/precedent.** GitHub merged-base semantics: once the base branch is merged into the topic branch, the two-dot and three-dot diffs become identical. THAT FACT DOES NOT RESCUE tier A: tier A's base is `refs/remotes/<remote>/<dst>` (the pushed *branch's* tracking ref), not the base branch, so a local `git merge origin/main` or a rebase always makes the pre-integration branch ref differ from HEAD by the full absorbed upstream delta. Push-side inflation is therefore **structural, not stale-ref-only**. Source: docs.github.com pull-requests/reference/branches; step-security/paths-filter.

**Architecture axis — pitfalls (MANDATORY for the high axis).**
1. *Skip ≠ pass is a live, exploited conflation class.* On GitHub a path-filter-skipped workflow leaves a required check Pending/unmarked while a conditionally-skipped JOB reports Success — a documented required-check/branch-protection bypass surface. Sources: github.com/orgs/community/discussions/54877, .../44490. ⇒ "identical to trusted base ⇒ satisfied" MUST be a distinctly-named NON-PASS event; recording it in `verifiedSet` or as a pass makes it indistinguishable from verification.
2. *`-X ours` / `-X theirs` / `merge=ours` is the sharpest bypass.* A conflicting path auto-resolved to a parent's content becomes byte-identical to that parent, so a content-identity rule marks a WRONG resolution as "already the base's". Post-resolution the index is stage-0, so content alone cannot distinguish "untouched base file" from "conflict resolved back to base". **The issue's original proposed criterion ("differs from both parents") does NOT catch this** — an ours-resolution does not differ from a parent. Sources: docs.gitlab.com/user/project/repository/files/git_attributes/ (custom drivers "only invoked for non-trivial conflicts"); Pro Git Customizing-Git-Git-Attributes. **RESOLVED by the ratified rule's condition (2) — not by the issue's original proposed fix #2, which the double diamond rejected and which no longer exists as a live criterion:** `B:P == mergeBase(T,B):P` asks whether the *branch side* is untouched at `P`, which an ours/theirs/`merge=ours` auto-resolution **fails** (the branch side was touched, or the merge would not have conflicted) — so the path stays gated. Residual: a change originating on the **base side only**, auto-resolved without any branch-side edit, is not a resolution act and may legitimately be subtracted.
3. *Type/mode changes and gitlinks.* `--name-status` emits `T` for typechange; submodules are recorded as SHA-1 blobs with no line content; R/C rows carry two paths. Subtract only `M`/`A` rows; never `D`, `T`, gitlink, or `R`/`C`; do not run rename detection on the subtract path. Sources: git-scm.com/docs/git-diff, git-scm.com/docs/gitattributes.
4. *Filters / renormalization make "content" ambiguous.* `merge.renormalize` and `.gitattributes` EOL/smudge/clean mean the same blob can check out to different bytes. ⇒ compare **blob-vs-blob via git object identity** (index blob SHA vs base blob SHA), never working-tree bytes vs a base blob. Sources: git-scm.com/docs/merge-config, git-scm.com/docs/gitattributes.
5. *`MERGE_HEAD` is an insufficient trigger.* `git merge --squash` writes no `MERGE_HEAD` and no second parent; octopus merges have N parents with no single "the base"; `git rebase` never sets it. A `MERGE_HEAD`-keyed fix (the issue's original *proposed* fix, since superseded by the ratified rule) cannot fire for squash/rebase/octopus. External support for the named-trusted-base framing. Source: git-scm.com/docs/git-merge.
6. *`git patch-id`/`git cherry`/`git range-diff` are NOT sound equivalence oracles for a trust decision.* patch-id "reasonably stable", ignores line numbers, "not meant to be cryptographic"; rebase already uses it to SKIP commits. Reject this family. Sources: git-scm.com/docs/git-patch-id, stackoverflow.com/a/45848295.
7. *"No merge base" is a real, common state.* Shallow clones (`--depth=1`), grafted history, missing refs, or unrelated histories → `fatal: no merge base` / empty output. **Correction (problem-verify cycle 2, both verifiers): detached HEAD is NOT one of these states** — `git merge-base <base> HEAD` resolves fine against a detached HEAD; it was wrongly listed here in cycle 1 and has been removed from the fail-closed trigger in the ratified definition (with a pin distinguishing "no merge base" from "detached HEAD"). github.blog "Get up to speed with partial clone and shallow clone" notes shallow history makes `git merge-base` unavailable. Canonical CI response is a deepen-fetch loop or the compare API. ⇒ "no merge base" must mean **absent evidence → full scope**, never an empty diff. Sources: github.blog, stackoverflow.com/questions/64957915, .../27059840.

**Architecture axis — codebase-first precedents.** `runBranchScope` (index.ts:2434-2437) ALREADY uses the canonical three-dot form (`git diff origin/main...HEAD --name-status -z`) — but its exec-failure path is catch→clean-empty **fail-open**, the cautionary precedent #487 inverted. `runStagedScope` (:2370) has no base concept at all. `resolvePushRangeScope` tier A (:2071-2077, :2191-2213) is 2-dot vs the pushed branch's tracking ref. `GIT_READ_ONLY_VERBS` (:1735-1744) already allowlists every verb a base-identity probe needs (`merge-base`, `rev-parse`, `cat-file`, `ls-tree`, `diff-index`, `hash-object`, `cherry`) — no new verb class required. `DiffScope`/`renameOldPaths` plumbing exists (:2272-2281). Zero `MERGE_HEAD` hits in the extension, confirming the issue body's grep claim.

**Ontology axis — canonical.** Mature attestation models keep a mechanical property as its OWN named claim, never folded into "verified": SLSA's Verification Summary Attestation records PASSED/FAILED against policy and explicitly distinguishes "reproducible" from "verified reproducible"; in-toto uses a fixed Statement envelope with named predicate types so new evidence kinds get a new type rather than mutating an existing one. Sources: slsa.dev/spec/v0.1/verification_summary, slsa.dev/blog/2023/05/in-toto-and-slsa, github.com/in-toto/attestation.

**Ontology axis — adversarial.** GitHub Checks separates `skipped`/`neutral` from `success`, and the documented failure mode is exactly the conflation (sources above). Emitting anything pass-shaped for base-identical content fails three ways: (a) the audit can no longer answer "verified vs mechanically discounted"; (b) the bridge/registry gains cross-session entries for content never verified — the #190 drift-contamination class #472 D1 exists to prevent; (c) the discount becomes non-idempotent, because the two producers re-derive the inflation from different baselines (index vs HEAD) and can disagree.

**Ontology axis — codebase-first (CORRECTION to the scoping premise).** `gate_skip` is **NOT** a member of the closed `GateEventName` union (extensions/shared/audit-log.ts:29-37 = `gate_bypass | review_dispatch | merge_gate_block | merge_gate_pass | review_record_collision | gate_block | bridge_clear`). `gate_skip` is a free-form event written by `logGateSkip` (index.ts:817-828). Precedent for a fixed verdict set is the TYPED union `MergeScopeDecision.reason` (:831: `cross_repo|head_mismatch|same_repo_head_match|same_repo_head_unknown`), forwarded at :3147. `gate_skip` is deliberately distinct from `gate_bypass` (index.e2e.test.ts:1524-1526 asserts a shape exemption emits `gate_skip`, not `gate_bypass`). Docs for skip reasons are prose-only (skills/commit-workflow/workflow/01-preflight.md:389,430,438); the only machine fence is `VGATE-SHAPE-RULE` (the shape-exempt table), untouched by adding a reason. ⇒ Add a **new typed `gate_skip.reason`** (e.g. `base_identical_satisfied`) with the evidence in `extra`; do NOT modify `GateEventName`; do not emit `gate_bypass`; do not write `verifiedSet`/bridge.

**Deduplicated (not counted toward the ≤8 cap).** (i) 2-dot-vs-3-dot for the push path — settled in docs/plans/2026-09-06-issue-487-vgate-push-range.md §Architecture + accepted-residual list (stale remote-tracking → tier A over-scope; fail-closed, self-healing via 01-preflight's mandated pull --rebase). (ii) May the discount self-bless into the registry? — settled: docs/plans/2026-09-05-issue-472-vgate-proportionality.md §Design Decisions D1 (ALLOW-ONLY; self-blessing into verifiedSet REJECTED). (iii) Fail-closed null-not-empty discipline — settled by #487 (`resolvePushRangeScope` null→staged; `computeBranchDiff` catch→[] named the cautionary fail-open). (iv) `merge-base` is an allowlisted read-only verb (index.ts:1739). (v) Library-deps axis = brief-coverage citation: #472 and #487 plan docs both record "Gate skipped: plan touches zero third-party deps" for this same extension.

**Integration Docs (draft).** ZERO third-party dependencies, no new package, no version bump: every existing producer shells out to the `git` CLI via `execSync` (`execDiffStatusZ` :2333, `refExists` :2091, `runStagedScope` :2370, `runBranchScope` :2434), and both sibling design records independently recorded a zero-dep gate. Git features relied on, all with no meaningful version floor: `git diff --cached --name-status -z`; `git diff <base> <src>` / `<base>...<src>`; `git merge-base <base> HEAD`; `git rev-parse --verify --quiet <ref>`; `git rev-parse <base>:<path>` / `git ls-tree <base> -- <path>` / `git cat-file -e` (blob identity — the preferred comparison); `--name-status` row classification + `-z`. Audit surface: `appendJsonl` accepts a free-form record — no `GateEventName` change needed. Doc surface: prose only; the `VGATE-SHAPE-RULE` fence is untouched.

**#2982 reuse judgement.** `git show 157d54c` — ⚠️ **NOT landed**: `git merge-base --is-ancestor 157d54c origin/main` → false; it lives on branch `fix/2982-diff-keyed-review-evidence` (PR #767). Treat it as a design record, not a convention to build on. Reusable = the DISCIPLINE, not the code: (1) hash **bytes from a file**, never a command substitution (`$(…)` strips trailing newlines and changes the digest); (2) the hash sits inside the signed/recorded text so an actor with body-edit rights cannot forge it; (3) the carry-forward arm fires only on a byte-identical artifact and refuses (exit 3) otherwise, with an explicit degraded mode rather than a silent pass. Not reusable: its bytes come from the GitHub REST API on purpose (a local `git diff` would not byte-match the API rendering), it is keyed on a whole-PR diff (we need per-path), and it is not landed precedent.

**Trigger assessment.** Architecture HIGH → FIRED (canonical, competitor-precedent, pitfalls ×3 — mandatory; canonical-only would be P1). Ontology MEDIUM → FIRED (canonical SLSA/in-toto, adversarial share of the pitfalls bucket); the codebase scan corrected the scoping premise. UX low → justified-skip (no user-facing UI; only the `console.log` block message + doc prose). Library-deps none → justified-skip (brief-coverage citation in Deduplicated). Query count: 8 external post-dedup vs the ≤8 Standard cap.

**Open questions the plan must resolve.** (1) Which base is authoritative — merge parents or the named trusted ref? The named ref is wrong when the integration source ≠ `origin/main` (local main ahead of remote, sibling branch, `FETCH_HEAD`); pick one explicitly and name the fail-closed behaviour when they disagree. (2) **RESOLVED — see pitfall 2's addendum:** the `-X ours`/`-X theirs`/`merge=ours` blind spot is closed by the ratified condition (2) (`B:P == mergeBase(T,B):P` — the branch side must be untouched), *not* by the issue's original proposed fix #2 (rejected; no longer a live criterion); narrow the subtraction to the base's own delta (paths the branch side never touched) OR explicitly accept and document the residual, and do NOT claim the issue's original proposed fix #2 covers it. (3) State explicitly that the push-side inflation is structural (tier A compares against the pushed branch's tracking ref), or the push-side justification will look unproven. (4) The two producers compare different sides (index blob vs HEAD blob) against the same base — specify the side per producer and require blob-vs-blob, never working-tree bytes. (5) Base-ref resolution when the default branch is not `main` or the remote is not `origin` — follow #487's generalization (`refs/remotes/<remote>/main` with origin fallback) and fail closed when neither resolves (`refs/remotes/origin/HEAD` is unused today). (6) **Degraded instrument:** the hosted-Tortoise epistemic-memory checkpoint returned `tortoise_unavailable` / `status: degraded` (HTTP 404) — prior in-repo claims on this defect went UNCHECKED (diagnosed and filed as #775).
- **2026-09-11T16:41:01** [canonical] Provenance bucket map for the Phase 1.5 block above (which was appended under a single [pitfalls] tag, corrected here): CANONICAL = git-scm.com/docs/revisions + /git-diff + /git-merge (three-dot ≡ merge-base, --merge-base spelling, squash writes no MERGE_HEAD), peter.eisentraut.org/blog/2022/09/13/git-diff-and-git-log-and-dots, slsa.dev/spec/v0.1/verification_summary + slsa.dev/blog/2023/05/in-toto-and-slsa (a mechanical property is its own named claim; "reproducible" vs "verified reproducible"), github.com/in-toto/attestation. COMPETITOR-PRECEDENT = docs.github.com pull-requests/reference/branches (PR "Files changed" is a three-dot merge-base diff; once the base is merged into the topic branch the two-dot and three-dot diffs become identical), github.com/step-security/paths-filter, docs.gitlab.com user/project/repository/files/git_attributes + Pro Git Customizing-Git-Git-Attributes (custom merge drivers, merge=ours). PITFALLS = the 7-entry adversarial block (skip-vs-pass required-check bypass: github.com/orgs/community/discussions/54877 and /44490; patch-id non-cryptographic: git-scm.com/docs/git-patch-id + stackoverflow.com/a/45848295; shallow clones break merge-base: github.blog partial-clone-and-shallow-clone + stackoverflow.com/questions/64957915 and /27059840). ADVERSE/ONTOLOGY = same SLSA/in-toto + the GitHub Checks skipped-vs-success split.
- **2026-09-11T16:41:03** [adversarial] Phase-1 disconfirmation note (auditability): the problem-diverge adversarial pass was performed CODEBASE-FIRST and EMPIRICALLY rather than via recorded web queries — it reconstructed the real merge commits (0be9c2a3d = 39 staged / 34 base-identical / 5 authored; af22840af = 48 / 42 / 6; ddb039e = 14 / 14 / 0), proved the |allBlocked| <= |changedFiles| invariant in the code, and forensically traced the incident session in ~/.pi/agent/audit/audit.jsonl (the 16:55:57Z `cat > /tmp/vgate_files.txt` heredoc; commit attempts at 16:46:15Z / 16:53:07Z / 16:56:47Z). This is stronger evidence than query volume but does not satisfy the skill's recorded-adversarial-query requirement — recorded here so the gap is explicit.

---

## Mechanism as shipped (#755)

**Behaviour change, always on.** Every `git commit` and `git push` scope is now
*subtracted*: a changed path is dropped from the set the verifier must cover when
its **recorded entry** (index blob for the commit leg, `HEAD` blob for the push
leg) is byte-identical to the same path's blob in the **named trusted base**
(`refs/remotes/<remote>/<branch.<cur>.merge short name, else main>`, falling back
to `refs/remotes/origin/main`). This closes the merge-in-progress flood: a merge
that pulls 39 upstream files into a 5-file change previously demanded
verification coverage for all 39.

**It only ever narrows the verifier's workload, never expands it**, and it never
records anything as verified. The subtraction writes `DiffScope.subtractions`
(an audit trail) and leaves `verifiedSet` untouched by construction — no
pass-shaped verdict is emitted for discounted content, so the audit can still
distinguish *verified* from *mechanically discounted*.

**Fail-closed by design.** Every guard is tri-state: a probe that cannot be
resolved (non-zero/`128`, shallow clone, unresolvable base, more than one merge
base) yields *no subtraction*, i.e. the pre-#755 over-gate. The failure mode is
extra verification work, never an unverified merge.

### Operating the kill switch

```sh
ELDATO_VGATE_NO_SUBTRACT=1   # disable subtraction; restore the pre-#755 over-gate
```

Read once per tool call. When set, every producer receives `null` at each
subtraction point and a `gate_skip` line with `reason: "subtract_disabled_by_env"`
is emitted, so an audit can never show subtraction and the opt-out together.

Note the **asymmetry** with `ELDATO_SKIP_VGATE`: that one *removes a gate* and is
human-only. `ELDATO_VGATE_NO_SUBTRACT` moves in the **over-gate** direction (it
makes the gate stricter), so a task sub-agent is permitted to set it. Setting it
can only cost time, never coverage.

### Non-goals (deliberately not covered)

- **Tier-C push fallback** (`resolvePushRangeScope` returns `null` → staged
  scope) keeps pre-#755 semantics: no subtraction.
- **Rebase / cherry-pick push-leg de-flooding** is **#737**'s deliverable; #737
  stays open and parked so this change does not silently absorb it.
- **`git merge` itself remains un-gated** — tracked as **#770**. This change
  covers the *commit* and *push* that consume a merge, not the merge command.
- The `scopeFiles` stash-recovery arm was **dropped**, not repaired: its fallback
  fires only when `lastBlockedFiles.length === 0`, an unsatisfiable lifecycle.
  Follow-up: **#791**.

### Where the rule lives (single statement)

`extensions/verification-gate/subtract-scope.ts` is the only place the rule is
stated. `index.ts` supplies producers and a git adapter; a plan or PR that
restates the guards in prose is a defect source, not documentation. The
machine-checked conformance properties live in
`extensions/verification-gate/test-subtract-scope.mjs` (zero-dep, `node`), and
the SDK-free behavioural suite in `subtract-scope.test.ts` (45 tests) which runs
in the `verify` job that performs **no** `npm ci` — the SDK-freeness is itself a
pinned property.
