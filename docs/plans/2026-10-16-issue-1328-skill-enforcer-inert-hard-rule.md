---
title: "#1328 — skill-enforcer: a `hard` manifest rule for a non-bash, non-MCP tool is silently inert"
type: engineering
domain: platform
doc_status: implemented
created: 2026-10-16
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: agent-infra
---

# #1328 — a `hard` manifest rule must always be evaluated

**Issue:** `daniel-ospina/agent-infra#1328` (filed from #1321/#1322, implementation review
cycle 1) · **Tier:** micro/standard · **A/B:** **A** — inert enforcer + false PASS: the
manifest declares a gate, the banner counts it as armed, and its condition can never fire.
**Adversarial domain** (gate/enforcement code: "a rule can be made to never fire") —
acceptance = every declared class covered by a test, plus a RED leg.
**Date:** 2026-10-16 · **Branch:** `feat/1328-tm`

## Confirmed problem (measured, not read)

`extensions/skill-enforcer.ts` dispatched tool calls to two handlers, and the two handlers
partitioned calls by **channel** while the two manifest **modes** were partitioned by
handler. The partitions are crossed, so two cells of the (mode × channel) matrix were
covered by neither:

| | bash | `mcp__*` | builtin / extension tool |
|---|---|---|---|
| **hard** | blocking handler | blocking handler | ❌ **inert — this issue** |
| **nudge** | ❌ inert | ❌ inert | nudge handler (#1820) |

- the blocking handler skips `rule.mode !== "hard"`;
- the nudge handler returns early for bash and `mcp__*` with the comment *"already handled by
  the blocking handler above"* — which is false for a `nudge` rule;
- for anything else the blocking handler fell through `if (!cmd) return undefined`, because
  the only bash text it ever built came from a `bash` call.

**Reproduced (RED).** A copy-farm with the manifest
`builtin-skill # web_search # hard # builtin-tool channel`, driven through the extension's
own handlers, on `HEAD`:

```
{"tool":"web_search","blocked":false,"reason":null}
```

The banner for that farm says `enforcing 3 skill gates … (3 rules)` and `loadManifest`
returns `ok: true`: the rule is accepted, counted as armed, and can never block. That is the
issue's own class and #1321's (`✅ Loaded — enforcing 0 skill gates`), one channel over.

The shipped manifest has no such rule today, so this is a latent class — but the *mirror*
cell (`nudge` × {bash, `mcp__*`}) is **already live and broken**: the shipped
`how-to-use-tortoise # tortoise_ # nudge` broad catch-all never fires (5 consecutive
`mcp__tortoise__tortoise_search` calls: no block, no reminder, no injection, no nudge log).
Measured, filed as **#1820**, and deliberately **not** fixed here — see "Residuals".

## Rejected alternatives (the issue body's two directions, re-derived)

The issue body proposed (a) add an explicit `tool:` field and refuse un-gatable `hard`
rules, or (b) fail loudly at load for a `hard` rule that cannot be a bash command or an MCP
tool name.

| # | Approach | Verdict |
|---|---|---|
| (a) | `tool:` field on the manifest format + load-time refusal | **Rejected as the primary fix.** It migrates the format under `loadManifest`, `enforce-protocol-table.sh` (+ its fixture suite) and the workflow content lock, and it can only validate the *channel spelling* — the extension cannot enumerate tool names (extensions register arbitrary tools), so it would refuse mistyped channels and nothing else. Its value largely disappears once the channels are complete. |
| (b) | fail loudly for a `hard` pattern that "cannot be a bash command or an MCP tool name" | **Rejected — unimplementable as stated.** Every regex can match some bash command, so the predicate is undecidable; a "matches a bare tool name" heuristic would false-fail a legitimate `git read-tree` gate. Its *decidable* half is adopted narrowly, for `read` (below). |
| C | **Channel-complete gate: one subject per call** | **Chosen.** ~10 lines in one file, no format migration, no manifest rewrite, and it closes the class rather than narrowing it: every `tool_call` maps to exactly one subject, so a `hard` rule is unreachable **only** if its pattern matches neither a command nor a tool name — a pattern defect, not a channel defect. |

## Architecture

1. **One subject per call.** The blocking gate computes
   `subject = isBash ? command : toolName` and evaluates **every** `hard` rule against it.
   The bash and `mcp__*` legs are behaviour-identical to before (the old `mcp__*` branch
   already tested the tool name); the builtin/extension leg is the fix.
2. **`read` is never a subject.** Reading `<skill>/SKILL.md` is the only documented remedy for
   any gate, so a manifest rule must never block the `read` tool: a pattern that merely
   contains `read` (`git read-tree`, `spread`) would otherwise make **every** gate in the
   manifest unsatisfiable at once. `loadManifest` reports such a rule **loudly** as a warning
   (not a defect — the rule stays armed for its other subjects), which is the issue's option
   (b) applied precisely where it is decidable, so the rule is never *silently* inert.
3. **`mode` is still honoured in the unified loop** — `nudge` rules never hard-block
   (#1321/T11), pinned by a regression control.

## Threat surface (adversarial domain)

| # | Class | Adversarial input | Required behaviour | Test |
|---|---|---|---|---|
| T1 | `hard` × builtin tool (the issue) | manifest rule `builtin-skill # web_search # hard` | **blocks**, and clears once `skills/builtin-skill/SKILL.md` is read | copy-farm gate driver (RED on `HEAD`: `blocked:false`) |
| T2 | `hard` × bash / `mcp__*` (controls) | `git commit`, `mcp__svc__do_thing` | still block, with the right skill named | same farm |
| T3 | `nudge` × builtin | `nudge-skill # web_search # nudge` | never blocks; rule still loaded (`1 rule`) | same farm |
| T4 | Remedy-tool collision | `git-skill # git read-tree\|read # hard` | `read` is **not** blocked; the bash leg still blocks; the collision is warned on **stderr** | same farm (RED on `HEAD`: `warnings: []`) |
| T5 | False block introduced by channel completion | all 16 fleet tool names vs the **real** manifest | none blocks; no warning | copy-farm gate driver over `enforcement/dangerous-ops.txt` |

## Residuals (declared, not chased)

- **#1820 — the `nudge` × {bash, `mcp__*`} cell is still dead.** The mechanical fix is the
  same subject model, but the nudge handler **escalates** (1st call reminds, 3rd call
  blocks), so closing it would newly block `mcp__tortoise__tortoise_search` — which
  #1321's declared T11 requires must not block. That is a decision (may a nudge escalate on
  a read-only MCP query?), not a mechanism, so it is filed with the measurement. The false
  comment has been corrected in place next to the early return.
- **A `hard` rule naming `read` remains inert, by design and loudly** (warning above). The
  alternative — arming it — is the unavertible deadlock described in (2).
- **`NUDGE_MESSAGES` carries `research` / `debug-workflow` entries that no manifest rule
  names**, so those tailored messages are unused (the generic fallback text is used
  instead). Dead config text, nothing lost; not filed (category B, no named consequence).

## Verification

| Command | Result |
|---|---|
| `npx tsx extensions/skill-enforcer.test.ts` | **49 passed, 0 failed** |
| `SE_TEST_MODULE_SRC=<HEAD module> npx tsx extensions/skill-enforcer.test.ts` | **46 passed, 3 failed** — the two new legs, with the expected RED evidence (`web_search blocked:false`; `warnings: []`) plus T1's `MODULE_DIR` assertion, which fails only because the seam feeds the module in from `/tmp` (a property of the seam, red on `main` too — it is not a regression) |
| `bash scripts/ci/enforce-protocol-table.sh` | PASS (manifest → skills, 4 checked) |
| `bash scripts/ci/tests/enforce-protocol-table.test.sh` | ALL FIXTURES PASS |
| `node scripts/check-skill-lint.test.mjs` | 160 passed, 0 failed |
| `node scripts/check-pi-pin-lockstep.mjs` | 123 passed, 0 failed |
| `node scripts/check-workflow-lock.mjs` | ✅ lock matches (3 files) |
| `bash scripts/check-pi-config-extensions.sh` | PASS (farm parity) |

No new test file: the legs were added to `extensions/skill-enforcer.test.ts`, which
`ci.yml`'s `verify` job and `ci-main.yml`'s extension accumulator already run
unconditionally. (`config/ci-surfaces.yml` / `tools/ci_selection.py` do not exist in this
repo — that registration rule is a tortoise-repo convention.)
