---
title: "Plan: #284 — second-model review gates (configurable, DeepSeek V4 Pro default)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-14
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-284, issue-scoping, code-review, plan-review, subagent-driven-development
---

# Plan: #284 — second-model review gates (configurable, DeepSeek V4 Pro default)

## Goal
The 4 pipeline skills that dispatch a "stronger second model" review gate must resolve the model from config (`$SECOND_MODEL`, default `deepseek/deepseek-v4-pro`) instead of hardcoding `qwen3.8-max` (cut off after the Qwen overcharge incident). Fail-explicit stand-in annotation; no silent substitution. Full design: `docs/scoping/2026-08-14-issue-284-second-model-gates.md`.

## Edits (canonical `skills/` — live `~/.pi/agent/skills/` is a symlink to it, auto-syncs)

### Per-skill edit rule (all 4 skills): replace the gate's BRANDING elements — header, Model:/dispatch lines, gate prose ("dispatch ONE Qwen3.8-Max reviewer as a final quality gate…", "…cross-diamond coherence…", "Qwen is a stronger reasoner…", "# Final review — Qwen gate", `[QWEN-GATE]` tags, converge-failure strings, "re-run Qwen once" table rows) — with the convention block below. **PRESERVE each skill's gate prompt template verbatim** (e.g., issue-scoping's 6-item coherence-check prompt ~L779-799) **and tier-scope lines** ("**Applies to:** Standard + Complex only. Micro tier skips…") — replace only the branding/model wiring, never the review substance. **De-brand transitional prose:** "Qwen just applies stronger reasoning" → "the second model just applies stronger reasoning" (code-review:964, plan-review:437). **Sweep rule:** any remaining "Qwen"/"Qwen3.8-Max" token in a gate section is branding → "second model"; ONLY the pricing note retains `qwen3.8-max`. Post-state: exactly 4 `qwen` lines in skills/ (one pricing note per skill).
```
**Second-model gate:** dispatch with `model` = `$SECOND_MODEL` (env; default `deepseek/deepseek-v4-pro` —
provider-qualified, unambiguous; resolve via `~/.pi/agent/models.json`). When `$SECOND_MODEL` is set but
unresolvable, or unset with the default unresolvable, dispatch the tool default (`deepseek-v4-flash`) and
annotate the result `[SECOND-MODEL-GATE] stand-in ($SECOND_MODEL=… set-but-unresolvable | unset+default-unresolvable)`.
Never silently substitute. Pricing decision (issue #284): deepseek-v4-pro (best bug-finding + cost per review pass);
qwen3.8-max re-enable only after verbosity control (reasoning_effort/output caps); kimi-k3 opt-in only.
```
(The note contains `qwen3.8-max` exactly once, never as `model="qwen3.8-max"`.)

### 1. `skills/issue-scoping/SKILL.md` (§5.6, ~L769-808)
- Header `Phase 5.6 — Qwen Coherence Check` → `Phase 5.6 — Second-Model Coherence Check`
- `**Model:** qwen3.8-max (via Token Plan or configured provider).` + `task(model="qwen3.8-max", ...)` → convention block (dispatch line: `task(model=<second-model per convention>, prompt=<coherence check prompt>)`)
- 5× `[QWEN-GATE]` → `[SECOND-MODEL-GATE]`
- `"Qwen coherence check could not converge."` → `"second-model coherence check could not converge."`
- Pricing note (from convention block)

### 2. `skills/code-review/SKILL.md` (§6.6, ~L953-976)
- Header `Step 6.6 — Qwen Final Gate` → `Step 6.6 — Second-Model Final Gate`
- `**Model:**` + `task(model="qwen3.8-max", ...)` lines → convention block
- 5× `[QWEN-GATE]` → `[SECOND-MODEL-GATE]`
- `"Qwen final gate could not converge."` → `"second-model final gate could not converge."`
- Pricing note

### 3. `skills/plan-review/SKILL.md` (~L426-454)
- Header `Phase 4.5 — Qwen Final Gate` → `Phase 4.5 — Second-Model Final Gate`
- `**Model:**` + `task(model="qwen3.8-max", ...)` → convention block
- 6× `[QWEN-GATE]` → `[SECOND-MODEL-GATE]`
- `"Qwen final gate could not converge."` + `🔍 Qwen final gate: clean` → second-model equivalents
- Pricing note

### 4. `skills/subagent-driven-development/SKILL.md` (~L167-178)
- `**Final code reviewer (after all tasks):** Dispatch with model="qwen3.8-max". This is the two-tier review pattern — Flash handles per-task reviews, Qwen3.8-Max serves as the senior gatekeeper…` + `task(prompt=final_code_reviewer_prompt, model="qwen3.8-max")` + the "omit model for per-task, pass model=… only for the final reviewer" note → convention block (3 mentions → 1 pricing note)

### 5. `skills/commit-workflow/workflow/04-merge-deploy.md` (L9)
- `Qwen final gate clean when applicable` → `second-model final gate clean when applicable`

### 6. `templates/AGENTS.base.md` + `AGENTS.md` (both, byte-identical; L165-167)
- After the model-override prohibition: add the second-model-gate exception (per scope) + amend the stale sentence `Only DeepSeek is configured` → `Only DeepSeek is configured for general use; see the second-model-gate exception below`

### 7. `docs/providers.md` (optional IN)
- One line documenting `$SECOND_MODEL` (default `deepseek/deepseek-v4-pro`; gate-only override)

## Constraints (skill-lint / sequence-enforcer safe)
- Frontmatter untouched (no `steps:` renames needed — headers are body text only)
- No `sequential or parallel` phrase
- `[QWEN-GATE]` string appears in NO extension (verified) — rename safe

## Verification (ACs from scope)
1. `grep -rn 'model="qwen3.8-max"' skills/` → 0; `grep -c 'qwen3.8-max' <each of 4 skills>` == 1
2. `grep -rin 'qwen.*\(gate\|coherence\)' skills/` → 0
3. **Catch-all:** `grep -rin 'qwen' skills/` → EXACTLY the 4 pricing-note lines (one per skill) — catches any "qwen after gate" pattern (e.g., "**Gate passes:** Qwen returns CLEAN" at code-review:976, plan-review:450)
4. `scripts/check-skill-lint.mjs` → clean (baseline 120 files 0 issues)
5. `git diff` review + skill-sync commit
6. Repo-wide: no extension breakage (`grep -rn 'QWEN-GATE' extensions/` stays 0 — no dependency)
7. Live copies synced (symlink — verify with `cmp` canonical vs live)

## Out of scope
Qwen billing re-enable; DeepSeek Aug-16 price rise; models.json changes; non-skill qwen references (extensions/custom-provider-qwen + pi-bootstrap/pi-config/extensions/custom-provider-qwen — provider registration; **extensions/builtin-tools/index.ts (15 refs: resolver split-on-slash, qwen-HA fallback, TASK_FALLBACK_MODEL docstring) + builtin-tools.test.ts (38 refs)** — extension logic, no gate branding; **`manifest.json` (extension registry, `custom-provider-qwen/` entry)**; pi-bootstrap configs; docs/providers.md existing fallback; historical plans) — intentional, documented in scope. `[QWEN-GATE]` in extensions/ = 0 (verified).
