---
title: "Decision: Local Qwen 32B-class — not good enough for agentic coding"
type: decisions
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-05
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, pi, cmux, deepseek
---

# Decision: Local Qwen 32B-class — not good enough for agentic coding (2026-09-05)

**Domain:** llm-ops / engineering
**Decision:** Do NOT route pi coding-agent work through a locally-run Qwen 32B-class model. Keep agentic coding on remote DeepSeek (V4-Flash default, V4-Pro second-model gate). Local Qwen remains viable only for zero-marginal-cost review/drafting passes run as an on-demand night batch.
**Status:** Decided (user, 2026-09-05). Research concluded; no implementation planned.
**Related:** #469 (idle pi REPL session reaping — memory hygiene), #365 (session-lifecycle cost contract).

## Context (target hardware)

Apple M5, 32 GB unified memory, 10 GPU cores, macOS 26.5.1. Measured baseline: ~19 GB genuine working set with normal load (Chrome ~6.8 GB, pi fleet 37 procs ~6.7 GB, OrbStack, cmux), ~14 GB true spare (free + reclaimable cache). A 20–24 GB resident model does NOT coexist with the normal workload — it must be time-shared (load on demand, unload when idle).

## Benchmark comparison (SWE-bench Verified unless noted)

| Model | SWE-bench V | Terminal-Bench | Verdict |
|---|---|---|---|
| DeepSeek-V4-Flash (cloud, task-tool default) | ~79 | 82.7 (TB 2.1) | agent-tuned baseline |
| Qwen3.5-35B-A3B (local MoE, int4) | 69.2 | 40.5 (TB 2) | good reasoning, weak agentic/terminal |
| Qwen3-32B dense (stock) | 23–30 | — | not agent-tuned out of the box |

Gaps that killed it for coding: Terminal-Bench ~2× worse (40.5 vs 82.7) → ~2× mistakes per tool-heavy agent turn → retries negate the cost saving; SWE-bench ~10 pts lower. Int4 quantization dips below the FP8 card numbers.

## What this means operationally

- Agentic main loops / tool-chaining sub-agents: **remote DeepSeek, always.**
- Possible local offload (zero marginal cost, quality-adequate): token-hungry low-tool-churn passes — code/plan reviewers, research verifiers, drafting, synthesis. Requires the on/off choreography: Ollama `keep_alive=0` interactive, full `brew services stop` off otherwise, night-batch = preload → run queue → unload.
- Cheap tier economics: V4-Flash is already low-cost; local only pays at high batch volume (night sweeps), not per-session substitution.

## References

- HF model cards: Qwen3.5-35B-A3B (69.2 SWE-bench V / 40.5 TB2), DeepSeek-V4-Flash (~79 / 82.7)
- Ollama 0.19 MLX backend announcement (2026-03-30): M5-class acceleration, >32 GB flagged for flagship NVFP4 build
- Measured machine state: 2026-09-05 session memory audit (see chat record)
