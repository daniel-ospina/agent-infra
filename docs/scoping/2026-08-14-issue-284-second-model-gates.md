---
title: "Scope: #284 — second-model review gates: make configurable (pricing decision: DeepSeek V4 Pro default)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-14
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-284, issue-scoping, code-review, plan-review, subagent-driven-development
---

# Scope: #284 — second-model review gates: make configurable (pricing decision: DeepSeek V4 Pro default)

## Confirmed problem

The pipeline's "second-model" review passes **hardcode `model="qwen3.8-max"`** in 4 skills:
1. `skills/issue-scoping/SKILL.md` §5.6 (coherence check) — dispatch + `[QWEN-GATE]` tags + "Qwen Coherence Check" header
2. `skills/code-review/SKILL.md` §6.6 (final gate) — dispatch + `[QWEN-GATE]` tags + "Qwen Final Gate" header
3. `skills/plan-review/SKILL.md` (final gate) — dispatch + `[QWEN-GATE]` tags + "Qwen Final Gate" header
4. `skills/subagent-driven-development/SKILL.md` (final code reviewer) — dispatch + "Qwen gate" header

Plus `skills/commit-workflow/workflow/04-merge-deploy.md` references "Qwen final gate clean when applicable" (5th file, concept-level).

Qwen was **cut off temporarily after an overcharge incident** (root cause identified: verbosity-driven token bloat — TrueFoundry measured Qwen3.8-Max using ~19× more tokens than peers on hard tasks → 2.8–4× cost per solved task despite a 5× cheaper sticker). The skills were never updated, so every pipeline run silently substitutes the default model — defeating the "stronger second reviewer" design intent. **These are second-model review gates, not Qwen gates** — a future model pick must not require re-editing skill text.

**Mechanism note (corrected):** qwen-tp IS configured in models.json (qwen3.8-max, `$QWEN_TOKEN_PLAN_API_KEY` set) — the overcharge cut-off is billing-side, not registration-side; the silent substitution happens when the token-plan credits are dead or the dispatch fails. The fix is unaffected. (`deepseek-v4-pro` exists under deepseek + qwen-tp (+ qwen-token-plan in models-store.json) — the bare id is ambiguous; provider-qualified spelling is the robust convention regardless.)

## Design decision (research-backed, 2026-08-14)

**Second-model pick:** `deepseek/deepseek-v4-pro` (pricing-validated — see issue #284 body for the full Kimi K3 / Qwen3.8-Max / DeepSeek V4 Pro 0813 comparison). Rationale: best bug-finding in the set (SWE-bench); best cost per review pass; DeepSeek Aug-16 price rise is fleet-wide either way (off-peak scheduling note). Qwen3.8-Max re-enable only after verbosity control (reasoning_effort/output caps); kimi-k3 opt-in only.

**⚠️ Provider-qualified spelling REQUIRED:** use `deepseek/deepseek-v4-pro`, NOT the bare `deepseek-v4-pro` — the bare id is **ambiguous** (exists under deepseek, qwen-tp, qwen-token-plan, qwen-token-plan-individual in the merged store; a live runtime error was observed for the sibling id `deepseek-v4-flash`: "ambiguous across providers… Use --provider or provider/model"). The task tool splits on the first slash; pi natively accepts provider/model.

## Solution (chosen: env-var slot, no new infra)

In each of the 4 skills, replace the hardcoded `qwen3.8-max` dispatch + `[QWEN-GATE]` branding with a **second-model gate convention**:

- **Model slot:** dispatch the gate with `model` = `$SECOND_MODEL` (env), **default `deepseek/deepseek-v4-pro`** when unset (provider-qualified — unambiguous).
- **Stand-in annotation (fail-explicit, never silent):** whenever the gate dispatches with anything OTHER than the configured second model — `$SECOND_MODEL` set-but-unresolvable, or unset with the default unresolvable — dispatch the tool default (`deepseek-v4-flash` when `model` omitted) and annotate the result `[SECOND-MODEL-GATE] stand-in ($SECOND_MODEL=… set-but-unresolvable | unset+default-unresolvable)`.
- **Tag/branding migration (COMPLETE list):** `[QWEN-GATE]` → `[SECOND-MODEL-GATE]`; headers "Qwen Final Gate"/"Qwen Coherence Check"/"Qwen gate" → second-model equivalents; gate-block prose ("dispatch ONE Qwen3.8-Max reviewer as a final quality gate…", "…cross-diamond coherence…", "Qwen is a stronger reasoner…", "# Final review — Qwen gate", "re-run Qwen once"); the lowercase failure/status strings ("Qwen final gate could not converge." code-review:974/plan-review:448, "Qwen coherence check could not converge." issue-scoping:808, "🔍 Qwen final gate: clean" plan-review:454); transitional prose ("Qwen just applies stronger reasoning" → "the second model just applies stronger reasoning"); and commit-workflow `04-merge-deploy.md:9` "Qwen final gate clean when applicable" → "second-model final gate". **Practical rule: replace the gate's BRANDING per skill, PRESERVING each gate's prompt template + tier-scope lines verbatim** (the plan doc's preserve rule overrides any "entire block" phrasing here). Sweep rule: any remaining "Qwen"/"Qwen3.8-Max" in a gate section is branding → "second model"; only the pricing note retains `qwen3.8-max` (exactly one per skill). No extension depends on `[QWEN-GATE]` (verified) — safe rename.
- **Pricing-decision note** in each skill: one paragraph citing #284 (why `deepseek/deepseek-v4-pro`; qwen re-enable condition; kimi-k3 opt-in). **Wording constraint:** the note must contain the lowercase id `qwen3.8-max` exactly once and MUST NOT contain the dispatch form `model="qwen3.8-max"` (or any `model="` + id sequence) — otherwise AC1 trips.

**Rejected:**
- Swap the hardcoded name only — symptom fix; next swap = another skill edit.
- Shared resolution module/skill — overkill; resolution already lives in the task tool; env resolution is inline-trivial.
- models.json alias (`second-model`) — counterproductive: adds a 6th ambiguity entry for the same ids.

## AGENTS.md carve-out (REQUIRED — resolves the hard-rule conflict)

`AGENTS.md` "Model override prohibition" ("Do NOT pass any non-DeepSeek model to the task tool… Only DeepSeek is configured") directly contradicts the new convention (kimi-k3 opt-in, qwen re-enable) and its justification is now stale (zai/qwen-tp/moonshot configured). Add a **second-model-gate exception** under the prohibition (slot at AGENTS.md:167 "REPO-SPECIFIC: Add tool-specific exceptions here"): second-model gates (per #284) may dispatch `$SECOND_MODEL` (default `deepseek/deepseek-v4-pro`; non-DeepSeek only via explicit env override); everything else stays prohibited. **Same edit must also amend the stale sentence** "Only DeepSeek is configured" → "Only DeepSeek is configured for general use; see the second-model-gate exception below". Repo-root AGENTS.md is untracked/generated — the carve-out lands in BOTH the canonical source `templates/AGENTS.base.md` (tracked; live copy is byte-identical) AND the live `AGENTS.md` copy.

## Scope boundaries

- IN: the 4 skills (canonical `skills/` + live `~/.pi/agent/skills/` copies, verified identical) + commit-workflow `04-merge-deploy.md` tag reference + AGENTS.md carve-out (canonical source + live) + optional `docs/providers.md` one-liner documenting `$SECOND_MODEL`. Issue labels (micro→standard, scoping).
- OUT: qwen billing/credits re-enable (external, blocked on overcharge root cause); fleet-wide DeepSeek Aug-16 price rise (separate tracking); models.json changes (none needed). **Known intentional remaining `qwen3.8-max` references** (do NOT re-file on grep-audit): `extensions/custom-provider-qwen/` + `pi-bootstrap/pi-config/extensions/custom-provider-qwen/` (provider registration — still loaded at runtime), `pi-bootstrap/pi-config/models.json` + `models-store.json`, `docs/providers.md` (incl. the `TASK_FALLBACK_MODEL` env-fallback mechanism — must not break; current default is `deepseek-v4-pro`), historical plan docs (`docs/plans/2026-08-10-qwen-reliability-plan.md`).
- Complexity: micro → standard (skills/ touched, per issue-scoping Phase 0.5).

## Implementation constraints (skill-lint / sequence-enforcer safe)

- Frontmatter untouched (skill-lint validates frontmatter only; no qwen in any frontmatter).
- No "sequential or parallel" phrase introduced (skill-lint body grep).
- `steps:` frontmatter entries in code-review/plan-review stay in sync with any body-header renames.
- Live copies synced from canonical (skill-sync).

## Acceptance criteria

1. `grep -rn 'model="qwen3.8-max"' skills/` → **zero dispatch references**. Per-skill mention count: `grep -c 'qwen3.8-max' <skill>` == 1 (only the pricing note; the note must NOT contain the `model="` + id sequence).
2. `grep -rin 'qwen.*\(gate\|coherence\)' skills/` → **zero** (case-insensitive — catches ALL gate-branding variants incl. lowercase "Qwen final gate could not converge", "🔍 Qwen final gate: clean", and the commit-workflow ref; the pricing note's "Qwen3.8-Max" model mention is safe — no gate/coherence suffix).
3. Each of the 4 skills documents: `$SECOND_MODEL` slot + default `deepseek/deepseek-v4-pro` + stand-in annotation rule + pricing note (citing #284).
4. AGENTS.md carve-out present in canonical source + live copy.
5. Skill lint passes (`scripts/check-skill-lint.mjs`, baseline 120 files 0 issues).
6. Live copies synced from canonical (skill-sync).
7. No provider/models.json change (verified: deepseek + qwen-tp + moonshot all configured).
