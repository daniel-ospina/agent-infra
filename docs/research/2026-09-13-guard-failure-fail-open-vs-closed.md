---
title: "Research: guard failure modes — fail-open vs fail-closed for agent enforcement gates"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-13
aboutSubjects: main-worktree-guard, verification-gate, commit-workflow, organisation-design-team
aboutObjects: agent-infra, issue-917, issue-920, issue-926
---

# Research Brief

Answers the question behind epic #917 decision **D1**: when a guard's own machinery errors, fails to load, or cannot reach a decision, should the operation be blocked (fail-closed) or allowed through (fail-open)?

## Raw Notes

### Direct answer

**There is no universal recommendation.** The mainstream position is a **decision procedure whose first step is a cost asymmetry** — not a default. Five rules carry the consensus:

1. **Classify the two error directions for *this* operation.** OPA states this outright: the choice "can depend on many factors including the likelihood of OPA not making a decision and the cost of allowing or denying a request incorrectly" — and explicitly refuses to answer it universally (openpolicyagent.org/docs/operations).
2. **Security-enforcement planes default to fail-closed.** Kubernetes `failurePolicy` defaults to `Fail`; AWS ALB+WAF returns HTTP 500 and does not forward; Git/pre-commit/ESLint abort on non-zero. CWE-636 "Not Failing Securely ('Failing Open')" classifies failing open as a *weakness*; Saltzer–Schroeder's **fail-safe defaults** ("base access decisions on permission rather than exclusion") is the canonical formulation — the 1975 paper credits E. Glaser (1965).
3. **Fail-open is legitimate only when all three hold:** the action is reversible/low-impact **or** a compensating detection control will surface what got through, **and** the fail-open event is recorded as a state distinct from "passed". Gatekeeper is the canonical fail-open implementation *because* audit is its second leg.
4. **Failure-to-decide must never be indistinguishable from a decision to allow.** Kubernetes makes this first-class: an explicit `allowed: false` "is a rejection but Kubernetes does not consider it as a failure… An explicit rejection, correctly transmitted, always denies the API request, regardless of the `failurePolicy` setting." Only network errors/timeouts/non-2xx/malformed responses are failures.
5. **The escape hatch must be reachable *while the guard is broken*, authorised, audited, and — critically — verified to actually sit outside the guard's own match scope.**

### Named patterns / terms of art (the middle path)

**fail-safe defaults** (Saltzer–Schroeder) · **fail-closed / fail-secure** · **fail-open / fail-operational** · **"fail functional"** (CWE-636's pejorative for fail-open chosen to save support cost) · **default deny** · **audited override** (NIST SP 800-53 Rev.5 **AC-3(10)**) · **break-glass** (NIST NCCoE SP 1800-18) · **compensating control / compensating detection** (Gatekeeper audit) · **degraded mode / fail-soft / graceful degradation** · **detection-only / audit mode** · **emergency recovery procedure** · **silent fallback** (the anti-pattern) · **control validation / canary probe** · **skip ≠ pass** · **reversibility axis** ⚠️ *emerging, canonically uncited*.

### Evidence per sub-question

**1. Real projects on internal error** — fail-closed dominates:

| System | On guard error | Source |
|---|---|---|
| Git hooks | non-zero aborts; `pre-commit`/`commit-msg` bypassable via `--no-verify`, **`prepare-commit-msg` is not suppressed by it** | git-scm.com/docs/githooks |
| pre-commit framework | "If a hook exits nonzero, the commit will be aborted"; codes `1`=expected, `3`=**unexpected** | pre-commit.com |
| Husky | `sh -e`; documents `HUSKY=0` to disable **all** hooks — unlogged, unlimited | github.com/typicode/husky |
| ESLint | config/parse errors exit non-zero (`2`) | eslint.org CLI docs |
| GitHub required checks | **"A job that is skipped will report its status as 'Success'"**; `skip-checks: true` trailer skips checks | docs.github.com status-checks |
| K8s webhooks | `failurePolicy` ∈ {`Ignore`,`Fail`}, **default `Fail`** | kubernetes.io extensible-admission-controllers |
| Gatekeeper | ships **`Ignore` (fail-open)** | open-policy-agent gatekeeper "Failing Closed" |
| ALB + AWS WAF | default HTTP 500, request not forwarded; `fail open` opt-in; logs `waf-failed` | docs.aws.amazon.com ALB integrations |

**2. Middle path** — OPA's caller-side, cost-dependent framing is the clearest documented position; the "fail-open + compensating detector + distinguishable state" triad is Gatekeeper's actual architecture. The reversibility rule is widely repeated but **no primary source** was found.

**3. Silent-failure risk** — the *mechanism* is well-evidenced (CWE-636's "false sense of security"; GitHub's skipped-job-reports-Success; Gatekeeper's audit leg as the stated precondition for failing open). The *frequency* is **not**: only vendor surveys exist (PICUS ~1/7 simulated attacks detected; AttackIQ). No guard-error-rate data. Treat any percentage as unreliable.

**4. Overrides** — **NIST AC-3(10)** requires an *audited* override "under [organization-defined conditions] by [organization-defined **roles**]". Break-glass must be time-bounded, auto-revoked, immutable-logged, post-incident-reviewed. Real practice is far weaker: Git's `--no-verify` and Husky's `HUSKY=0` are unlogged and unlimited; pre-commit files its equivalents under **`pre-commit hazmat`** — "using these is usually a bad idea"; Kubernetes documents a **`breakglass` matchCondition** using a synthetic authorizer verb. **Rate-limiting overrides: no authoritative source — inference only.**

**5. Kubernetes / OPA in detail** — K8s: default `Fail`; `failurePolicy` covers network errors, timeouts, non-2xx/malformed responses, serialisation failures, undecodable patch types — and *not* explicit rejections. The good-practices doc **states** `Fail` is the default (noting the downtime cost) and **recommends overriding to `Ignore` for mutating webhooks**, with a validating controller enforcing final state. Gatekeeper: ships `Ignore`, justifies it with audit, and documents the **admission deadlock** circular dependency. OPA: refuses to choose; supplies `--fail`/`--fail-defined` for CI.

### Corrections made during review

1. **"K8s recommends `Fail`"** — wrong. K8s documents `Fail` as the default but **recommends `Ignore` for mutating webhooks**.
2. **NIST "approved individuals"** — actually **roles**.
3. **Saltzer–Schroeder "origin"** — credits E. Glaser (1965), not original to the 1975 paper.
4. **Kubernetes config-plane exemption** — an earlier claim that "DELETE-absent-from-operations is the reason" was wrong. Corrected: the API server's webhook `Dispatch` short-circuits on `rules.IsExemptAdmissionConfigurationResource` (named so since v1.26, when it was expanded from the earlier `IsWebhookConfigurationResource` to also cover `ValidatingAdmissionPolicy`/`Binding`), so `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` and admission policies/bindings in group `admissionregistration.k8s.io` are never sent to API-based (REST) webhooks — to prevent circular dependencies. Independently, Gatekeeper's own webhook never sees DELETE because its rules list `operations: [CREATE, UPDATE]`. The separate virtual-resource exclusion list (`TokenReviews`, `SubjectAccessReviews`, …) is a different mechanism.

### Where evidence is strong / weak / contested

- **Strong:** K8s semantics + default + decision-vs-failure distinction + the `breakglass` example; Gatekeeper's shipped default, audit justification, deadlock analysis; OPA's explicit delegation; Git hook semantics; pre-commit exit codes; GitHub `skipped = Success`; AWS WAF default; NIST AC-3(10); CWE-636; Saltzer–Schroeder.
- **Medium:** break-glass operational specifics (read via summaries of NIST NCCoE SP 1800-18, not the primary doc in full); CloudTrail `StopLogging` alarm guidance (secondary detections).
- **Weak / contested:** frequency of unnoticed guard failures (vendor data only); **AI-agent guardrail guidance is almost entirely vendor blogs** with no standards body — they restate the cost-asymmetry rule, not validate it; the reversibility rule as a *named* principle; whether fail-open may ever be a default (CWE-636 says it's a weakness; OPA says it can be right for dev; Gatekeeper ships it in production — genuinely context-dependent); rate-limiting overrides.

## Application to this repo (inference)

> **Inference, not documented best practice.** No source states this in this form.

A commit is **reversible** and is re-checked at push/PR/merge, so the local hook is a convenience gate, not the enforcement plane:

1. **Local pre-commit hook:** fail-closed on a detected *violation*, **fail-open-with-loud-alarm on the guard's own internal error** — never a silent `0`.
2. **The authoritative gate must be fail-closed and outside the actor's reach** — server-side `pre-receive`/`update` or a required CI check; `--no-verify` cannot touch those. This matches this repo's own `docs/ops/guarded-paths.md`, which explicitly calls `.husky/pre-commit` "a local hook, not the judge".
3. **Never emit a pass-shaped value for "could not run"** — use a distinct verdict (`UNKNOWN`/`UNGATED`/`FAILED-TO-RUN`) or pre-commit's `1` vs `3` split. GitHub's skipped-job-reports-Success is the anti-pattern this repo already tracks as a "live, exploited conflation class" (`docs/research/2026-09-11-issue-755-vgate-merge-scope.md`).
4. **Choose the error direction deliberately** along OPA's two axes — don't inherit it accidentally from `set -e`.
5. **Verify the escape hatch is actually outside the guard's scope** rather than assuming it.
6. **Prove the guard can fail** — inject the internal-error path in CI and assert it surfaces distinguishably. `MEMORY.md` already records this class biting us.

### Relevance to #917

This bears directly on decision **D1**, which spans #920 (verification-gate fail-open paths) and #926 (main-worktree-guard inversion). The repo's live evidence: blocking has caused total stoppage twice (#879 closed, #882 open); silent self-disablement has occurred at least five times (#853, #789, #744, #761, #708); and the built-in override has been used **7,738 times** with no correctness record (`~/.pi/agent/audit/gate-events.jsonl`, `gate_bypass` events, re-measured 2026-09-14 at `01d0684`; 7,737 when this brief was written — the file is append-only, so this figure must be re-measured, not cited).

Per rule 3 above, the 7,738 unrecorded bypasses are the sharpest gap — a bypass that is not recorded as a state distinct from "passed" is indistinguishable from a clean run.

## Review-loop disclosure (honest status)

Skill-mandated fresh-context verifier, 3 cycles. **Not a clean exit** — the 2-fix-cycle cap was reached:

- **Cycle 1:** 13/14 claims verified verbatim. 4 issues (see Corrections 1–4).
- **Cycle 2:** refuted one of the cycle-1 corrections — the K8s config-plane detail (Correction 4).
- **Cycle 3 (cap reached):** sole residual is a **version-anchor imprecision** in Correction 4 — the webhook-configuration exemption predates v1.26 by many releases; v1.26 merely renamed and extended it. The reviewer's verbatim fix was applied **without a 4th verifying cycle**, so that one sentence is reviewer-supplied but not independently re-confirmed.

This is a **capped exit, not a clean one**: the residual above remains unresolved by independent review.

## Method and provenance

- **Tools:** `web_search` with **sonar** (cheapest tier). No paid deep-research model used. Several queries hit Perplexity 429s.
- **Unavailable:** `seo-intelligence` MCP server; Tortoise memory (no `TORTOISE_API_KEY`), so no prior claims were queried and none filed.
- **Provenance note:** the research pass initially reported this brief "staged at `/tmp/guard-failure-research/`". **That claim was false** — the directory existed but was empty. The brief was reconstructed from the pass's returned content and written to this path directly. Recorded because it is itself an instance of the class this epic targets: an unverified claim of completion.
