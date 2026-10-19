---
title: "Plan: agent-infra#1341 — pi-patches 'already applied' must be a positional proof, not an existential test"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-16
aboutSubjects: organisation-design-team
aboutObjects: agent-infra-1341, pi-patches, apply-mjs, make-manifest-mjs, false-pass, positional-proof, issue-1316
---

# Plan — agent-infra#1341 → `scripts/pi-patches/` positional proof

> Status: **shipped on `feat/1341-tm` (PR #1817)**. This doc is the plan/evidence record
> the pipeline-compliance gate requires for a `complexity:standard` issue; the code and
> its evidence suites landed in the same PR.
> Refs: agent-infra#1341 (fix), agent-infra#1316 (the change set this patches),
> agent-infra#1816 (coverage gap: these suites are run by no workflow).

## Confirmed problem

`scripts/pi-patches/apply.mjs` decided "already applied" on the entry's replacement
payload being present **verbatim anywhere** in the file:

```js
const verified = next.includes(entry.replace);
```

That is an **existential** question — *"does this payload string appear somewhere?"* —
not the question the gate exists to answer (*"is the fix in force?"*). A partial revert
that **neutralises** the patched region (replaces the marker-gated expression with the
ungated variant, or otherwise breaks the gate) while leaving the payload **verbatim**
inside an inert container — a `String.raw` template literal, a `/* … */` block comment,
a `//` line comment, a dead branch — satisfies it. The entry then reports
`= <id> — already applied`, `--check` prints "all replacements present" and exits **0**
over a tree whose fix is gone, and `apply` mode reports "nothing to write (idempotent)".

This is a **false PASS** — the class the gate's own history is a record of: the
`verifyPresent` substring test it replaced was hardened for exactly this failure mode one
level up ("a comment that merely QUOTES the needles"), but the bare-payload test is the
*same* existential question with the payload instead of the needles.

The defect is **pre-existing** (found by the enforcement-safety reviewer on PR #1333,
2026-09-22); #1333 extended the same class to 9 new entries and presented
payload-verbatim as *the* proof in `scripts/pi-patches/README.md`. It matters more after
#1333 because four of the (e) entries — the exemption/throw entries — have **no
behavioural probe**: `apply.mjs` step 5 probes only `clampMaxTokensToContext` (change
(b)), so for those entries the shape check is the *only* proof.

Reproduced at HEAD on the pristine installed 0.85.1 tree: entry `e8`'s marker-gated
expression replaced with an ungated (textually different) variant, payload appended
verbatim inside a `String.raw` template literal, file still parses →
`apply.sh --check` **exit 0**. After this change the same tree is refused (exit 2) while
every healthy path is unchanged.

## Root cause

The proof had **no position**. `replace` is a bare payload string; `includes` searches
the whole file, so it cannot distinguish "the payload sits where the patched region
belongs" from "the payload sits anywhere". The manifest recorded no information about
where the payload belongs, so no caller could ask the positional question.

## Considered alternatives

| # | Approach | Verdict |
|---|---|---|
| A | Record per-entry `preContext`/`postContext` and require `preContext + replace + postContext` | **Chosen** — makes the proof positional without leaving the per-entry idempotent re-apply design |
| B | A whole-file patched hash (cryptographic pin) | **Rejected** — stronger against a deliberate actor, but it breaks the per-entry idempotent re-apply design (a partially patched tree, the normal retry state, has no single whole-file hash). Left as a stated boundary in the README, not silently dropped. |
| C | `node --check` alone as the refusal | **Rejected as the primary gate** — it does **not** catch the reported variant: a payload inside a template literal parses. Kept as a **secondary** net (step 4b) for the shapes that are also syntax errors. |
| D | Execute the patched tree to observe behaviour | **Rejected as the primary gate** — the patch runs inside pi's own request path; a general behavioural probe is not available for the four entries with no probe (and step 5 already shows how narrow the executable surface is). |

## Change

| File | Change |
|---|---|
| `scripts/pi-patches/make-manifest.mjs` | Records per-entry `preContext`/`postContext` — the text surrounding the payload in the **correctly patched** file, **clamped** so it never reaches into another entry's patched region (b1/e3 are adjacent: e3 begins one newline after b1's closing brace, and an unclamped window would refuse a valid **partially** patched tree). Refuses to emit a manifest whose entries cannot be proved positionally. Manifest `schema` 1 → 2. |
| `scripts/pi-patches/apply.mjs` | `patchedRegion(entry)`; both the "already applied" branch and step 4 shape verification require it. A manifest lacking context is refused loudly (exit 2) rather than falling back to the existential check. Step 4b adds `node --check` per patched file as a **secondary** net. Validation sits **after** the `--revert` branch so an older manifest can still be reverted. |
| `scripts/pi-patches/manifests/0.85.1/manifest.json` | Regenerated — additive (`preContext`/`postContext` per entry, `schema: 2`). |
| `scripts/pi-patches/tests/verify-summarization-clamp-exemption.mjs` (e) | New payload-verbatim fixture **per entry** (9 entries): region neutralised, pristine anchor absent, payload appended verbatim in an inert `String.raw` template literal / block comment / line comment, file asserted to still **parse**, `--check` required to refuse. |
| `scripts/pi-patches/tests/verify-summarization-budget-floor.mjs` (d) | Same fixture for the 3 (d) entries. |
| `scripts/pi-patches/README.md` | The proof description, the `apply.sh` behaviour table row, and Known gap 14 (now **CLOSED**) updated. |

## Wiring

| Touch point | Type | Covered by | Status |
|---|---|---|---|
| `apply.mjs` "already applied" branch (the false PASS) | code | this PR | ✅ |
| `apply.mjs` step 4 shape verification | code | this PR | ✅ |
| `make-manifest.mjs` context derivation + clamp | code | this PR | ✅ |
| `manifests/0.85.1/manifest.json` (`schema: 2`) | artifact | this PR | ✅ |
| (e) evidence suite fixture loop | test | `tests/verify-summarization-clamp-exemption.mjs` | ✅ |
| (d) evidence suite fixture loop | test | `tests/verify-summarization-budget-floor.mjs` | ✅ |
| `apply.sh` behaviour table + Known gap 14 | docs | `scripts/pi-patches/README.md` | ✅ |
| The suites are run by **no workflow** | CI | agent-infra#1816 (filed; not this PR) | ⚠️ tracked |
| MCP tool registry / TortoiseSDK public surface | — | untouched | ✅ (not applicable) |

## Verification

- `node scripts/pi-patches/tests/verify-summarization-clamp-exemption.mjs` → exit 0,
  277 assertions ✅ (54 new payload-verbatim assertions) on a fully patched `PI_ROOT`.
- `node scripts/pi-patches/tests/verify-summarization-budget-floor.mjs` → exit 0,
  87 assertions ✅ (18 new).
- `apply.sh --check` across tree classes: pristine **1**; fully patched **0**; partially
  patched (first entry of every file) **1** with **no** false refusal (the clamp holds);
  neutralised + payload verbatim, per entry **2** (was **0** — the false PASS);
  context-stripped manifest **2** + re-derive instruction; patched file with a broken
  delimiter **1** ("does not parse").
- `make-manifest.mjs` re-derived from the pristine tree **and** from an already-patched
  tree produce an **identical** manifest (`postContext` is stable), so the artifact is
  reproducible rather than a snapshot of one tree's state.

### Non-vacuity

Against the **pre-fix** `apply.mjs`, the payload-verbatim fixture makes **all 15 entries**
read as a false PASS (exit 0, "already applied", "the fix is in place"). Tested **per
entry**, not only the reported `e8`, so the guard is falsifiable across the whole change
set and not just at the reported index.

### Environmental dependency (stated, not assumed)

The (e)/(d) evidence suites drive the **real** caller and presume a `PI_ROOT` that already
carries changes (b)/(d): on a pristine 0.85.1 install their RED/GREEN behavioural legs
report the pre-#1263(d) floor (13107) instead of the budget (32135). This is exactly the
state the lane's own final message recorded, and it is **unchanged by this PR** — the new
fixtures run on trees the suites build themselves and are not affected by it.

## Residual

- A content-based positional proof is a detection aid against accidental
  neutralisation/partial reverts, **not** a cryptographic pin: an actor holding the
  manifest could paste the context too. A whole-file patched hash would close that and was
  considered (alternative B); it is left as a deliberate boundary because it breaks the
  per-entry idempotent re-apply design.
- The pi-patches evidence suites are run by **no workflow** (they need a pinned install),
  which is the coverage gap that let this class survive. Filed as agent-infra#1816.
