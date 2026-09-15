---
title: "Issue #727 — re-point the openrouter flash hop leg to the V4.1 generation (register + clamp deepseek/deepseek-v4.1-flash)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-14
aboutSubjects: provider-failover, custom-provider-openrouter, check-cost-config
aboutObjects: agent-infra, pi, issue-727
---

# Issue #727 — plan

Complexity: **standard** (task) · Epic: standalone · Branch: `fix/727-openrouter-v41-leg` · PR: #1032

## Problem

The `deepseek-v4-flash` alias-family chain routes deepseek-official credit exhaustion onto an
OpenRouter hop leg. That leg was `deepseek/deepseek-v4-flash`, which upstream OpenRouter names
**"DeepSeek V4 Flash 0423"** ($0.0882/$0.1764 per M) — an *older generation* than the primary
(deepseek-official V4.1 Flash). A failover therefore silently changed the model generation,
contradicting the family contract ("one logical model served by multiple legs with identical
behavior on different balances"). Two secondary defects: the slug that *would* match the primary
(`deepseek/deepseek-v4.1-flash`) was unregistered, so a hop-leg dispatch could not resolve it at
all (an extension `models[]` array REPLACES the provider catalog — s7), and it had no
`modelOverrides` clamp key, so a 1M-context catalog row would bypass the #341 300K clamp.

## Options considered

**1. Which slug should the hop leg serve?**
- (a) Keep 0423 — leaves the family contract violated (rejected).
- (b) Re-point to `deepseek/deepseek-v4.1-flash` — same generation as the primary; ~1.70x input /
  3.40x output on the *emergency* leg only.
- (c) Keep both as ordered legs — the pre-#727 *halt-after-hop* behaviour is lost and a second-leg
  exhaustion silently serves the older build (the same class of defect this issue removes).
**Decision: (b)** — user decision 2026-09-14 ("I want 4.1, with reasoning configurable"). Cost delta
accepted and recorded in `docs/providers.md` (#727 indicator c).

**2. Thinking levels on the leg.** Upstream accepts `none`/`low`/`medium`/`high`/`xhigh`/`max`
(probed live, all 200). The deepseek primary can express `off`/`high`/`max`.
**Decision: mirror the primary** (`off`/`high`/`max`; `minimal`/`low`/`medium` unmapped) — a hop
must not change the session's thinking level. The probed capability is recorded so enabling more
levels later is a one-line change.

**3. What happens to stale pre-#727 state referring to the 0423 slug?**
- (a) Drop it from the table → `nextLegAfter` computes `startIdx -1` and the walk re-returns
  `legs[0]`, the **draining root** (#715's regression).
- (b) Keep it as an ordinary leg → a *fresh* continuation after the V4.1 leg drains is served the
  0423 build: the pre-#727 chain (which halted there) would be extended, re-introducing a silent
  generation downgrade one hop later.
- (c) Keep it in the table but **resolution-only**.
**Decision: (c)** — the entry exists so stale state matches its own position (no `startIdx -1`
re-return of the draining root), while `RESOLUTION_ONLY_LEGS` stops a fresh advance from being
served it. The guard is applied on **both** serve paths: the advance walk skips it, and resolution's
latched-active fast path refuses a `fam.activeLeg` that IS this leg — a pre-#727 latch record froze
exactly that slug, and serving it directly would re-dispatch the 0423 build for up to the latch TTL
(the walk then re-resolves the family's *first available* leg — the V4.1 openrouter leg while
`qwen-tp` stays config-blocked — retrying from the family root when the first walk halts, so a dispatch
of the *hop leg itself* is served rather than halted).
The chain **halts** after the V4.1 leg — exactly where it halted before the V4.1 leg existed. No
generation downgrade is reachable by an automatic hop; the 0423 build survives only for an explicit
must-stay dispatch of that exact leg (`PI_FAILOVER_NO_HOP=1`) or the kill switch
(`PROVIDER_FAILOVER_DISABLE=1`), both of which return the requested leg verbatim, latch or not.

## Wiring

| Surface | File | Change | Verification |
|---|---|---|---|
| Provider registration | `extensions/custom-provider-openrouter/index.ts` | register `deepseek/deepseek-v4.1-flash` (reasoning true, `off`/`high`/`max`, text+image, 300K) | `pi --list-models` shows it, reasoning = yes |
| Clamp authority | `pi-bootstrap/pi-config/models.json` | `providers.openrouter.modelOverrides["deepseek/deepseek-v4.1-flash"].contextWindow = 300000` | `scripts/check-cost-config.sh` PASS |
| Chain table | `extensions/shared/provider-failover.ts` | openrouter leg → V4.1 slug; 0423 kept last as resolution-only, guarded on BOTH serve paths (advance walk + latched-active) + a root-retry when the frozen leg is retired | `provider-failover.test.ts` 82/0 |
| Family identity | `extensions/shared/provider-failover.ts` `familyOf` | `deepseek/deepseek-v4.1-flash` (slash form) → flash family | new pin + `default-coverage.test.ts` 5/0 |
| Latch/session behavior | `extensions/provider-exhaustion.ts`, `extensions/provider-exhaustion.test.ts` | hop target = V4.1 slug; comment sync | `provider-exhaustion.test.ts` 36/0 |
| Consumer suite | `extensions/builtin-tools/builtin-tools.test.ts` | `OPENROUTER_FLASH` = V4.1 slug | 237/0 all green |
| Fixture mirror | `tests/fixtures/cost-config/*/models.json` (8 trees) | mirror the new clamp key | `tests/cost-config/run.sh` exit 0 (scratch-verified + negative control) |
| Docs | `docs/providers.md` | chain + cost delta + resolution-only rationale | review |

## Verification

- `pi --list-models` against the branch's extension + models.json: `openrouter deepseek/deepseek-v4.1-flash` — 300K ctx, **reasoning = yes**.
- Live OpenRouter probes: the slug accepts every reasoning effort pi can send, and image input (8x8 red PNG → "Red"). Rates read from the live catalog because the shipped `models-store.json` has no row for this slug.
- `scripts/check-cost-config.sh` → exit 0 (live-store 1M catalog row is the usual WARN class).
- CI-wired TS suites green: `provider-failover.test.ts`, `provider-exhaustion.test.ts`, `default-coverage.test.ts`, `builtin-tools.test.ts`.
- `tests/cost-config/run.sh` (cannot run in-session: the #1484 script gate keys on the hub-rooted session cwd) reproduced in a scratch copy: exit 0, with a negative control (key removed from `clean/models.json` only → sections 13/14 fail) proving the new parity path is live.

## Rollback

Revert the PR. No durable state migration: the legacy slug stays registered and in-table, so
pre-#727 latch files / markers / sessions keep resolving throughout — a record whose `activeLeg` is
the 0423 slug resolves to the family's first available leg rather than dispatching it. The clamp key is
additive.

### Accepted residuals

- A fresh family record whose `activeLeg` is **null** ("the primary is serving") takes neither the
  latched-active fast path nor the root-retry (scoped to a RESOLUTION-ONLY frozen leg), so an explicit
  ask for the terminal usable leg halts where a root ask on the same state resolves that leg. Same
  shape as the long-standing hop-ask residual on a latch with no per-family state, unchanged from
  pre-#727; halting never dispatches a wrong model and the ask is explicit. Documented in the
  `resolveWithChain` docstring.

## Learnings

- An extension `models[]` array REPLACES a provider's catalog, so a hop leg that is not registered
  fails to *resolve* — not just to price correctly (s7).
- `nextLegAfter` matches the current leg by **table position**: removing a leg that stale state may
  still name is not a harmless deletion (startIdx −1 → re-returns `legs[0]`, the draining root).
- Adding a `modelOverrides` key to the shipped `models.json` requires mirroring it into **all eight**
  `tests/fixtures/cost-config/*/models.json` trees (clean + minified + six backdoor trees); the
  parity pin is a canonical-JSON deep equality and the bounded-delta invariant catches a partial edit.
