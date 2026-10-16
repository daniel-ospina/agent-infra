---
title: "#1321 + #1322 — skill-enforcer must enforce in the deployed layout, or fail loud"
type: engineering
domain: platform
doc_status: draft
created: 2026-09-21
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: agent-infra
---

# #1321 + #1322 — skill-enforcer must enforce in the deployed layout, or fail loud

**Issues:** `daniel-ospina/agent-infra#1321` (empty manifest under the symlink farm) +
`#1322` (read-tracking prefix can never match) · **Tier:** standard · **A/B:** A
(false PASS — a gate prints `✅` while enforcing nothing; plus a gate-satisfaction bypass)
· **Domain:** adversarial (path/symlink resolution, gate satisfaction) — **review bound:
2 cycles**, acceptance = every declared threat class covered by a test + green CI
**Date:** 2026-09-21 · **Branch:** `fix/1321-1322-skill-enforcer-gates`

## Confirmed problem (Phase 2)

`extensions/skill-enforcer.ts` makes **three independent mistakes that all fail open and
all fail silently**. #1321 and #1322 diagnose two; the plan review found the third, which
is a precondition for the second one's acceptance test:

1. **`MANIFEST_PATH = resolve(__dirname, "..", …)` (#1321).** Pi loads global extensions
   from `~/.pi/agent/extensions/*.ts` — symlinks into this repo — with **jiti**, which keeps
   the **symlink path** in `__dirname`. The manifest therefore resolves to
   `~/.pi/agent/enforcement/dangerous-ops.txt` (nothing creates it), `loadManifest()`
   returns `{}`, and the extension still prints `✅ Loaded — enforcing 0 skill gates`.
2. **`SKILLS_PREFIX ?? "operations/skills/"` (#1322).** No `AGENT_SKILLS_PREFIX` is set and
   pi serves skills from `~/.pi/agent/skills/<name>/SKILL.md`, so a read through the path pi
   actually advertises never populates `readFiles`. Masked today by (1); once (1) is fixed
   without this, every `git commit`/`push`/`merge`/`gh pr create` blocks and the natural
   remedy — read the skill as instructed — cannot clear it.
3. **Duplicate manifest lines clobber (`loadManifest`'s `map[skillName] = …`).**
   `commit-workflow` appears twice (the git gate, then the `gh pr review` gate) and
   `how-to-use-tortoise` twice (a `hard` verb list, then a broad `tortoise_` **nudge**).
   Last-wins means the loaded `commit-workflow` entry is **`gh pr review|gh pr approve`
   only** — `git commit`/`push`/`merge`/`gh pr create` are **not gated at all** — and
   `how-to-use-tortoise`'s hard gate is downgraded to a nudge. So the banner could honestly
   say `enforcing 4 skill gates` while the headline gate never fires: #1321's own defect
   (a green count over an inert gate), one layer below the path bug. #1321 Indicator 2 and
   #1322 Indicator 2 are **unsatisfiable** until this is fixed. Fixing it is in scope, and
   the manifest file itself is **not** touched (the fix is duplicate semantics in code).

**Reproduced (red), both loaders** — extension symlinked into a `~/.pi/agent/extensions`-shaped
farm, manifest absent:

```
{"loader":"jiti","banner":["log: [skill-enforcer] ✅ Loaded — enforcing 0 skill gates from manifest"]}
{"loader":"tsx --preserve-symlinks","banner":["log: [skill-enforcer] ✅ Loaded — enforcing 0 skill gates from manifest"]}
```

**Root cause is one class:** the module treats its **load path** as its **real path**, treats
a **missing input as success**, and treats **repeated configuration as replaceable**. The
path is the mechanism; the silent `✅` is the defect — `AGENTS.md`'s category A, *"an inert
enforcer — a runner whose termination or enforcement condition can never fire while it
appears to protect something."*

## Rejected alternatives (Phase 5)

| # | Approach | Why not chosen |
|---|---|---|
| A | **`realpathSync(__filename)`** module dir + canonical read identity + loud + duplicate-merge manifest load | **Chosen.** Loader-independent (jiti *and* Node), no env, and it binds the manifest to the file actually next to the executing module. |
| B | `$AGENT_INFRA_PATH` fallback as the manifest source of truth (`skill-registry.ts`'s pattern) | Can designate a **different** file than the one next to the module — the exact divergence #1321 was. Rejected as the source of truth; the env var is kept only as an additional **skill-root** candidate and as a **fallback** when the module's own `../enforcement` is absent (see the copy-layout note, T9). |
| C | Deployment: `pi-bootstrap/setup.sh` creates `~/.pi/agent/enforcement -> $AGENT_INFRA_PATH/enforcement` | Fixes one asset on one machine; the next repo-relative asset re-breaks identically, and a non-bootstrapped host keeps the silent 0. **Reported in the PR body, not implemented** — the code must fail loud regardless of layout. |
| D | Make `loadManifest()` throw on a missing file | Kills the whole extension (a throw inside a jiti-loaded module fails the load) and takes read-tracking and the prerequisite gates down with it. Fail-loud must be *an error line + an unavailable gate state*, not a crash. |
| E | Match any `…/skills/<n>/SKILL.md` (unanchored basename) | Rejected — it makes every manifest gate satisfiable from any agent-writable directory (`/tmp/evil/skills/commit-workflow/SKILL.md`). See T7; the chosen design anchors to trusted roots + known shapes. |

## Architecture

**One module, four changes.**

1. **Real module location.**
   `MODULE_DIR = (() => { try { return dirname(realpathSync(__filename)); } catch { return __dirname; } })()`.
   `MANIFEST_PATH = resolve(REPO_DIR, "enforcement", "dangerous-ops.txt")` where
   `REPO_DIR = resolve(MODULE_DIR, "..")`. **Fallback (T9):** when
   `existsSync(MANIFEST_PATH)` is false and `$AGENT_INFRA_PATH` (or `$ELDATO_INFRA_PATH`) is
   set, use `<infra>/enforcement/dangerous-ops.txt`; if neither resolves, stay loud. The env
   value is a *fallback*, never a source of truth (it cannot override a manifest that exists
   next to the module).
2. **Loud manifest guard.** `loadManifest(path)` → `{ rules, ok, error?, warnings }`.
   `ok === false` when: the file is missing/unreadable; it yields zero rules; a line is
   malformed (`> 4` `#`-separated fields — a `#` inside a message used to be silently
   truncated); a rule has no pattern; a rule's pattern is not a valid regex. A broken load
   emits **unconditional `console.error`** at module load *and* at `session_start` (never
   gated by `isPrintMode()` — headless `pi -p` sub-agents are exactly the sessions that run
   `git`), replaces the `✅` banner with `❌`, and registers the failure in the **shared**
   health registry. The blocking gate still runs over the rules that *did* load.
3. **Read identity = skill name, anchored to trusted roots.** `readFiles` becomes a set of
   canonical names, so every consumer (`MANIFEST` gates, prerequisite chains, nudges,
   persistence) compares identity rather than a path fragment. `canonicalSkillName(path)`
   accepts a `…/SKILL.md` only when the resolved path sits under a **trusted base** in one of
   the **known skill-root shapes**:
   bases = `homedir()`, `process.cwd()`, `REPO_DIR`, `$AGENT_INFRA_PATH`/`$ELDATO_INFRA_PATH`,
   `$AGENT_SKILLS_PREFIX`; shapes = `skills/`, `operations/skills/`, `.agents/skills/`,
   `.pi/skills/`, `.pi/agent/skills/`. The canonical key is the **directory basename** owning
   the `SKILL.md` (so nested `reviewers/<n>/` works). `SKILLS_PREFIX` survives as the
   display/override fallback only.
4. **Manifest rules, not a last-wins map.** `MANIFEST: Record<string, ManifestRule[]>` — one
   `{ patterns, mode, message }` per non-comment line, keyed by skill. Each rule keeps its own
   mode, so `how-to-use-tortoise`'s hard verb list stays hard **and** the broad `tortoise_`
   catch-all stays a nudge; `commit-workflow` keeps both its git rules and its `gh pr review`
   rule. (Hoisting a merged mode to `hard` was rejected: it would silently promote the
   catch-all nudge to a hard block.) The banner reports both the unique-skill count (4) and
   the rule count (6) so a dropped-rule regression cannot hide behind a healthy skill count.
5. **The blocking branches must honour `mode` (T11).** Today the bash and MCP block branches
   test `entry.patterns` and return `{ block: true }` **without ever reading `entry.mode`** —
   only the nudge/`tool_result` handlers check it. Arming the manifest therefore converts
   `how-to-use-tortoise`'s broad `tortoise_` **nudge** rule into a **hard block** on every
   `mcp__tortoise__tortoise_search` / `_query` / `_health` call and on any bash text
   containing `tortoise_` (e.g. a repo-wide `rg`). That is a *new* false block introduced by
   fixing the mask, so the blocking branches skip `mode === "nudge"` rules explicitly and a
   handler-driven test pins both directions.
6. **All six `MANIFEST` consumers migrate together.** read-tracker (`Object.keys`), MCP block,
   bash block, nudge handler, `tool_result` injection, banner. Four of them iterate
   `entry.patterns`/`entry.mode`, so a missed site reads the array shape and silently does
   nothing. A source assertion pins that no `${SKILLS_PREFIX}${name}/SKILL.md` gate key
   survives outside the display helper.

### Adversarial Threat Surface

Gate/enforcement code whose correctness is "an attacker cannot make it fail open." Every class
below gets a test.

| # | Threat class | Adversarial input | Required behaviour | Test |
|---|---|---|---|---|
| T1 | Symlink load path (the issue's mechanism) | extension loaded through `…/extensions/skill-enforcer.ts` → symlink into the repo | `MANIFEST_PATH` is the **real** repo manifest; 4 skills / 6 rules; banner `enforcing 4 skill gates from manifest` | symlink-farm child |
| T2 | Manifest missing | resolved path does not exist | `console.error` (unconditional, incl. print mode), banner `❌`, **never** `✅`; `ok === false`; health entry failed | copy-farm child + unit |
| T3 | Manifest present, zero rules | blank / comments-only | same as T2, error names `0 entries` | unit + copy-farm child |
| T4 | Manifest line with no usable pattern | empty pattern, invalid regex, or a `#` inside a field (>4 fields) | line dropped, loud warning, `ok === false`; the *other* lines still enforce | unit |
| T5 | Read through each served/consumer root | `~/.pi/agent/skills/…`, `<cwd>/.pi/skills/…`, `<cwd>/skills/…`, `<cwd>/operations/skills/…`, `<repo>/skills/…`, `<repo>/operations/skills/…` | one canonical key `<n>`; `git commit` blocked → permitted | unit matrix + positive control |
| T6 | Read through `.agents/skills/` | `<repo>/.agents/skills/<n>/SKILL.md` | same canonical key as T5 | unit + positive control |
| T7 | Read from an unanchored path | `/tmp/evil/skills/<n>/SKILL.md`, `/tmp/evil/operations/skills/<n>/SKILL.md`, `/tmp/evil/.agents/skills/<n>/SKILL.md` | **does NOT** register; the gate stays blocked | unit matrix + handler control |
| T8 | Loader keeps the symlink path (precondition) | jiti / `--preserve-symlinks` | a symlinked probe reports `__dirname` = farm dir while `realpathSync(__filename)` = real file — asserted **first**, so no leg can pass vacuously | child precondition |
| T9 | Module-copy layout | extension copied (not symlinked) with no sibling `enforcement/` | env fallback resolves the in-force manifest; if neither resolves → loud, never silent 0 | unit (`MANIFEST_PATH` resolution fn) |
| T10 | Duplicate manifest lines | the *real* `enforcement/dangerous-ops.txt` (two lines per skill, two of them) | both lines' patterns survive with their own mode; `git commit` is armed | unit over the real manifest + positive control |
| T11 | A **nudge** rule must never hard-block | `mcp__tortoise__tortoise_search`, `rg -n 'tortoise_' skills/` | neither blocks; the `hard` verb list still blocks a genuine `tortoise_create_point` | handler-driven fake-`pi` test |
| T12 | Fixture hermeticity | ambient `PI_MODE=print`, `SKILL_ENFORCER_DISABLED=1`, `AGENT_INFRA_PATH` → another checkout | every child/in-process leg pins or clears those vars, so a control cannot pass vacuously | fixture-level precondition assertion in each leg |
| T13 | Persisted-read entry | a hand-written `~/.pi/agent/skill-reads.json` naming a skill | narrowed: an entry restores only if it canonicalises to a name a trusted root actually holds a `SKILL.md` for. **Residual, not closed:** a valid name (or a read by a previous session) still satisfies a gate for ≤24 h — deliberate #7416 behaviour, pre-existing, filed as a follow-up | unit (seeded + forged file) |

**Explicitly out of scope** (declared, not chased, filed from cycle 1):

- **T7 residual — a `SKILL.md` forged inside a trusted root's own shape**
  (`<cwd>/skills/<n>/SKILL.md`, `<repo>/skills/…`, `.agents/skills/…`) still registers. The
  gate proves "a plausible skill file under a real skill root was read", not provenance;
  closing it needs a content hash / signed manifest-of-skills. Requirement 3 needs the
  `<repo>/skills/` shape to register, so tightening further would break the stated
  acceptance. Filed as a follow-up.
- **T13 residual — persisted reads satisfy a gate for ≤24 h** (#7416 by design, pre-existing
  before this change: the stored key was a path string and was equally forgeable). This
  change *narrows* it (an entry must now name a skill a trusted root actually holds).
  Reversing #7416 would reopen a recorded decision, so it is filed, not absorbed.
- **Gate applicability is by pattern spelling.** `git -C <path> commit` / `git --no-pager
  commit` do not match the manifest's plain alternation, so the git gate is not
  spelling-proof. The manifest is a stated scope boundary; residual, follow-up.
- **Drift pin for the inlined `isToolCallEventType`.** It becomes a second copy (this module +
  `sequence-enforcer`); #966's precedent puts parity pins in SDK-bearing suites. Filed with
  the DRY extraction rather than absorbed here.

- `SKILL_ENFORCER_DISABLED` / `ALLOW_MAIN_EDITS` — deliberate bypass env, unchanged.
- `extensions/skill-registry.ts` (#1323, needs a decision) — untouched.
- The deployment-side symlink (alternative C) — reported in the PR body.
- **`ok === false` is loud, not fail-closed.** A missing manifest means `rules = {}`, so no
  gate can fire; the only enforcement is the error line + health state. This is #1321's
  stated objective ("fail loudly"), and failing closed would deny all `git` use on a
  broken manifest. Recorded as a residual, not fixed here.
- **A `SKILL.md` forged inside a trusted root's known shape** is still accepted. The gate
  proves "a plausible skill file was read", not provenance; closing that needs a content
  hash / manifest-of-skills design. Filed as a follow-up.
- **DRY:** the inline `isToolCallEventType` becomes a second copy (sequence-enforcer already
  inlines one). Extracting a shared zero-dep helper touches a third extension; filed as a
  follow-up rather than absorbed.

### Integration Surface Map

| Surface | Type | Test layer | Failure mode 1 | Failure mode 2 |
|---|---|---|---|---|
| Manifest resolution (`MODULE_DIR` × loader) | process/fs boundary | child process (symlink farm) | symlink path kept → 0 rules | loader starts realpathing → precondition assertion fails loudly |
| `loadManifest` (rules, duplicates, defects) | pure function over a file | unit (temp fixtures + the real manifest) | missing file returns `{}` silently | duplicate line drops a gate; malformed line silently misparsed |
| `canonicalSkillName` | pure function over strings | unit | served path not recognised → gate unsatisfiable | unanchored path recognised → gate forgeable |
| `tool_call` gate handlers | event handlers over a fake `pi` API | in-process integration | `git commit` allowed with the skill unread | a read does not clear the block |
| Persistence (`skill-reads.json`) | fs, via an injected file-path seam | unit + child | path-form legacy entry never matches | a test writes the real `~/.pi` |
| Health registry (`shared/health.ts`) | shared registry | child + unit | a failed load reports `loaded:true` | — |
| Display paths in block/nudge text | strings | unit | remedy points at a non-existent path | — |
| CI wiring | workflow YAML + content lock | suite + lock | suite never runs | pinned invocation line broken |

### Journey Test Map

**Journey: an agent that follows the skill table can still commit.**
1. `git commit -m x` → **blocked**, reason names `commit-workflow` and a path that **exists** → test `positive control: git commit is blocked before the governing skill is read`.
2. Read the skill at the path pi advertises (`~/.pi/agent/skills/commit-workflow/SKILL.md`)
   → `📖 commit-workflow read (manifest)`, `readFiles` holds the canonical name,
   `skill-reads.json` holds it → test `read via the served ~/.pi/agent/skills path registers the canonical key`.
3. The same `git commit -m x` → **permitted** → same control, second half.

**Journey: an operator whose manifest is broken finds out.** Boot a farm with no manifest →
`❌` on stderr with no `✅` anywhere, health entry failed → test `fixture: a missing/empty manifest is LOUD`.

**Tech Stack:** TypeScript with **no runtime import outside `node:*` and `./shared/*`** (the
one value import, `isToolCallEventType`, is inlined after `extensions/sequence-enforcer/index.ts:52-60`),
Node ≥ 22, `npx tsx` (CI route), jiti 2.7.0 (pi's loader; manual + optional local leg),
`node:fs` / `node:path` / `node:os`.

### Pattern Research

> **Skipped — plan touches zero third-party deps.** In-repo precedent for every mechanism:
> the inline `isToolCallEventType` (`extensions/sequence-enforcer/index.ts:52-60`), the
> zero-dep shared helper (`extensions/shared/print-mode.ts`), the shared health registry
> (`extensions/shared/health.ts`, used by `builtin-interactive`/`verification-gate`), the
> realpath fix already applied to scripts (#708), and the symlink-farm + `--preserve-symlinks`
> fixture route.

---

## Tasks

### Task 1: Manifest resolution, rule semantics, loud failure (#1321 + T4/T9/T10)

**Intent:** the manifest the enforcer reads is the one next to the real module; every line
becomes its own rule; a manifest it cannot fully use is never reported as a loaded gate.
**Acceptance:** through a symlink farm, `MANIFEST_PATH` is the real repo file, 4 skills /
6 rules, banner `enforcing 4 skill gates from manifest (6 rules)`; with the manifest
absent/empty/defective the failure is observable on stderr in **print mode** too, and no `✅`
is printed; `MANIFEST["commit-workflow"]` arms `git commit` and both modes survive for
`how-to-use-tortoise`.
**Files:** Modify `extensions/skill-enforcer.ts`, `scripts/ci/enforce-protocol-table.sh`
(comment only — it quotes the old `__dirname` resolution); Test
`extensions/skill-enforcer.test.ts`.

**Step 0 — drop the SDK value import (prerequisite; the suite cannot import the module
otherwise).** Replace `import { isToolCallEventType } from "@earendil-works/pi-coding-agent"`
with an inline copy plus `import type` for the two types, exactly as
`extensions/sequence-enforcer/index.ts:52-60` does (same drift note naming
`dist/core/extensions/types.js`). Acceptance includes *"the module imports with zero
`node_modules` present"* and a source assertion that no non-`node:*`/`./shared/*` runtime
import remains.
**Step 1 — failing tests.** `loadManifest` fixtures (missing, blank, comments-only,
duplicate line, empty pattern, invalid regex, `>4` fields); the real-manifest assertions
(4 skills, 6 rules, `commit-workflow` matches `git commit` **and** `gh pr review`,
`how-to-use-tortoise` has a hard verb rule **and** a `tortoise_` nudge rule); the banner
(healthy ≠ failed, never `✅` on failure); `resolveManifestPath(env)` incl. the env fallback
(sibling wins; a fallback resolution names the env var loudly); T11's mode-direction control.
**Step 2 — run:** FAIL (`loadManifest` has no `ok`; duplicates clobber; `MANIFEST_PATH`
resolves into the farm).
**Step 3 — implement:** `MODULE_DIR`/`REPO_DIR`, `resolveManifestPath(env)`, `loadManifest`
→ rules + `ok`/`warnings`, `manifestBanner`, unconditional `console.error` at module load and
`session_start`, shared-registry `register` (and **delete** the module-local
`__skillRegistry`/`register` that shadows it), skip `nudge` rules in the two blocking
branches, export `MANIFEST_PATH`/`MANIFEST`/`MANIFEST_LOAD`/`loadManifest`/`manifestBanner`/
`resolveManifestPath`.
**Step 4 — run:** PASS.

### Task 2: Layout-independent read identity + satisfiable positive control (#1322 + T5/T6/T7)

**Intent:** a read of the governing skill registers it whichever on-disk copy was read, and
only from a *trusted* skill root.
**Acceptance:** the T5/T6 matrix collapses to one key per skill; `/tmp/evil/**` does not
register (T7); with the real manifest loaded, `git commit` is blocked before the read and
permitted after a read through `~/.pi/agent/skills/commit-workflow/SKILL.md`; the reason text
names a path that exists; `skill-reads.json` is non-empty after the read (issue #1322
Indicator 3) and a legacy path-form entry restores to the same key; a corrupt file is
diagnosed, not silently dropped; the suite never writes the real `~/.pi`.
**Files:** Modify `extensions/skill-enforcer.ts`; Test `extensions/skill-enforcer.test.ts`.

**Step 1 — failing tests.** `canonicalSkillName` matrix — T5/T6, T7 (three unanchored shapes),
nested `reviewers/<n>`, a relative path, a trailing slash, a non-`SKILL.md`; the `git commit`
positive control through a fake `pi` API (the blocked half asserted as a **hard failure**, not
skipped, or the allow half passes vacuously); `before_agent_start` nudge fires before a read,
is suppressed after a read through a **non-prefix** path, and names an existing file; the
prerequisite pin (`writing-plans` alone → `write` blocked; `+ issue-scoping` → permitted);
persistence round-trip, legacy path-form normalisation, forged/unknown-name rejection (T13),
corrupt-file diagnostic; `session_start` order (clear → restore → report) pinned.
Read-tracking legs drive a **synthetic `read` event carrying the path string**, so the
pi-served-root leg needs no real `~/.pi`; a child that pins `HOME` covers the display path.
**Step 2 — run:** FAIL (served path → `null`).
**Step 3 — implement:** `skillRoots`/`canonicalSkillName`/`skillDisplayPath`; key `readFiles`
by name; replace every `${SKILLS_PREFIX}${name}/SKILL.md` gate key with `name`; route **all**
agent-facing path text (bash block reason, MCP block reason, nudge confirmation reason,
`before_agent_start` nudge message) through `skillDisplayPath`, defined as *first existing*
candidate in the order pi-served → repo → consumer → env prefix; add the
`_setSkillReadsFileForTest` seam covering **both** the file and its directory (so the suite
never `mkdir`s the real `~/.pi`); normalise legacy entries on restore and accept a restored
entry only when a trusted root holds a `SKILL.md` for it; add a corrupt-file diagnostic.
**Step 4 — run:** PASS.

### Task 3: Make the suite non-inert (wiring)

**Intent:** a guard whose test CI never runs is a guard nobody has checked.
**Acceptance:** the suite runs **per-PR** (`ci.yml` `verify` job) and post-merge
(`ci-main.yml` extension accumulator); `scripts/workflow-lock.json` is updated in the same
commit; `check-pi-pin-lockstep.mjs` stays green (its pinned invocation line and `with:` key
set are untouched); `check-pi-config-extensions.sh` needs no change (`*.test.ts` is excluded).
**Files:** Modify `.github/workflows/ci.yml`, `.github/workflows/ci-main.yml`,
`scripts/workflow-lock.json`; Test `extensions/skill-enforcer.test.ts`.

**Step 1:** add a `npx tsx extensions/skill-enforcer.test.ts` step to ci.yml's `verify` job
(plain single-line `run:`, YAML-subset safe, `setup-node@v4` already present) and the same
invocation to ci-main.yml's `test-command` accumulator — **without touching** the pinned
`node scripts/check-pi-pin-lockstep.mjs || …` line (item 6a). The symlink-farm fixture links
**both** `skill-enforcer.ts` **and** `shared/` into the farm, mirroring
`pi-bootstrap/pi-config/extensions/`; the missing-manifest farm gets a **copy** of the
extension plus the same `shared/` link.
**Child spawn recipe (explicit):** `npx tsx <driver>` with
`NODE_OPTIONS=--preserve-symlinks` for the symlink leg (a non-symlinked driver that *imports*
the symlinked extension — `--preserve-symlinks-main` is not needed), and a fully specified
env: `PI_MODE` cleared (banner legs) or `=print` (the print-mode loudness leg),
`SKILL_ENFORCER_DISABLED` / `AGENT_ALLOW_MAIN_EDITS` / `ELDATO_ALLOW_MAIN_EDITS` cleared,
`AGENT_INFRA_PATH` / `ELDATO_INFRA_PATH` / `AGENT_SKILLS_PREFIX` / `ELDATO_SKILLS_PREFIX`
cleared or pinned per leg, `HOME` pinned for persistence legs. Each leg asserts its own
precondition (T8 loader check; T12 bypass-env check) before its verdict.
**Step 2:** `node scripts/check-workflow-lock.mjs --update-lock` (both edited workflows).
**Step 3:** `node scripts/check-pi-pin-lockstep.mjs` → PASS.

---

## Verification plan

| Command | Expected |
|---|---|
| `npx tsx extensions/skill-enforcer.test.ts` | all assertions pass, exit 0 |
| `node scripts/check-skill-lint.test.mjs` | PASS (existing) |
| `node scripts/check-pi-pin-lockstep.mjs` | PASS (existing) |
| `npx tsx extensions/sequence-enforcer/sequence-enforcer.test.ts` | PASS (existing) |
| `npx tsx extensions/shared/print-mode.test.ts` + `print-mode-wiring.test.ts` | PASS (existing) |
| `bash scripts/ci/enforce-protocol-table.sh` | PASS (manifest ↔ skills) |
| `bash scripts/ci/tests/enforce-protocol-table.test.sh` | PASS (existing, after the comment edit) |
| `bash scripts/check-pi-config-extensions.sh` + `tests/pi-config-extensions/run.sh` | PASS |
| jiti e2e (manual, real jiti 2.7.0) | before `enforcing 0` → after `enforcing 4 … (6 rules)` |

## Wiring Check

| Touch point | Type | Covered by | Status |
|---|---|---|---|
| `~/.pi/agent/extensions` symlink farm | deployment layout | T1 symlink-farm child + jiti e2e | ✅ |
| `enforcement/dangerous-ops.txt` (rules, duplicates) | repo config | T4/T10 unit tests over the real manifest | ✅ |
| `~/.pi/agent/skills/<n>/SKILL.md` | pi-served path | T5 + positive control | ✅ |
| `<repo>/operations/skills/`, `<repo>/skills/`, `.agents/skills/`, `.pi/skills/` | consumer layouts | T5/T6 | ✅ |
| `~/.pi/agent/skill-reads.json` | persisted state | round-trip + legacy + corrupt tests via the file seam | ✅ |
| `extensions/shared/health.ts` registry | extension status | `getReport()` on a broken-manifest child | ✅ |
| `scripts/ci/enforce-protocol-table.sh` comment | gate documentation | comment updated with the resolution change | ✅ |
| CI (`ci.yml` verify, `ci-main.yml` extension-tests, lock) | gate wiring | Task 3 | ✅ |
| `extensions/skill-registry.ts` | adjacent module | **not touched** (#1323) | ⚠️ declared |

## Risks

- **Pinned workflow content.** `ci.yml`/`ci-main.yml` are byte-locked; the same-commit
  `--update-lock` is the documented, conspicuous remedy, and `check-pi-pin-lockstep.mjs`'s
  exact-invocation pin is untouched.
- **`readFiles` key format change.** Entries persisted by an older version are path-shaped;
  `restorePersistedReads` normalises them through `canonicalSkillName` (names pass through
  unchanged); unresolvable entries are skipped with a diagnostic, never silently trusted.
- **Side effect, stated not absorbed:** keying reads by identity makes the
  `writing-plans → issue-scoping` prerequisite satisfiable (it was not before, because
  `issue-scoping` was never tracked). A consequence of T5, not an extra feature.

## Plan review — cycle log (adversarial bound: 2)

Cycle 1 (2 reviewers) found 2 P0 + 5 P1; all folded in above. Cycle 2 (2 fresh reviewers)
verified the cycle-1 fixes and found 1 new P0 + 6 P1; the P0 (persisted-read bypass) and the
P1 that a `nudge` rule would hard-block once the manifest is armed are folded in above. The
bound is spent; remaining items are the declared residuals and the follow-ups below —
`[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=11 residuals=filed` is disclosed in the PR
body. Every declared class has a test; the two non-closed classes (T7 residual, T13 residual)
are declared, narrowed where cheap, and filed rather than chased.

<!-- plan-review: cycles=2, status=adversarial-capped, version=2.3.0 -->

---

## Implementation review — cycle log (adversarial bound: 2)

Scope: the **IMPLEMENTED** artifact (`extensions/skill-enforcer.ts`,
`extensions/skill-enforcer.test.ts`, the CI wiring), not the plan. Fresh-context reviewer each
cycle, no memory of the plan rounds. Acceptance = every declared class covered by a test + green
CI, not reviewer exhaustion; the bound is the declared threat surface (**2 cycles**).

### Cycle 1 — 3 findings (1 P0, 1 P1, 1 P2), all in-scope, all fixed

| # | Class | Sev | Finding | Fix |
|---|---|---|---|---|
| 1 | T7/T5 | **P0** | `skillRoots()` fed `$AGENT_SKILLS_PREFIX`/`$ELDATO_SKILLS_PREFIX` into the trusted-root set, and `normalizePath("/")` → `""`, so `candidate.startsWith(root + "/")` accepted **every absolute path**: an override of `/` made `/tmp/evil/skills/commit-workflow/SKILL.md` satisfy a real `git commit` gate. The file's own header called the prefix display-only. | An absolute prefix is refused and a degenerate normalised root is never added (`add()` guards `!n \|\| n === "/"`); the refusal is reported from `reportManifestState`. Tests: `no trusted root is ever degenerate` + `T7/P0 — an ABSOLUTE … prefix cannot widen the trusted roots` (control + `/` + `/tmp`). |
| 2 | T13 | P1 | `skillNameFromPersistedEntry` existence-checked only the **bare-name** branch; a **path-shaped** entry restored on shape alone (`canonicalSkillName` never touches the filesystem), so `…/skills/<ghost>/SKILL.md` restored **silently** — weaker than this plan's own T13 declaration, which requires a name a trusted root *actually holds* a `SKILL.md` for. | Both branches now require `skillFileFor(name)`; a ghost is refused loudly. Test: `T13 — a PATH-SHAPED entry naming a ghost under a trusted root is refused, loudly`. |
| 3 | T12 | P2 | The hermeticity snapshot was taken **before** the jiti child, so that leg lay outside the class's own "no child run may write" claim. | The assertion moved to the end of section G, after every child leg. |

Cycle 1 also raised two out-of-surface observations. One was cheap and in the same class — an
unrecognised `mode` (`HARD`, a typo, or absent) silently downgraded a `hard` rule to a nudge, i.e.
"the manifest says arm, the gate enforces less" — so it was **folded in**: `loadManifest` now treats
any mode that is not exactly `hard`/`nudge` as a defect (line dropped, warning, `ok === false`). The
real manifest spells every mode exactly, so its 4 / 6 count is unchanged. The other (a `hard` rule
whose pattern targets a builtin that is neither bash nor `mcp__*` is inert) is a **new class**, not a
declared one — filed, not chased.

### Cycle 2 — 4/4 fixes verified, 2 new findings (both P2), both fixed

All four cycle-1 fixes were **verified closed** against the reviewer's own reproductions
(`AGENT_SKILLS_PREFIX=/` → `has empty root: false \| canonical: null` + a loud refusal; ghost path
entry → diagnosed and the gate left blocked; assertion order confirmed; 12 mode spellings probed,
every non-exact one `ok=false` with the line dropped).

| # | Class | Sev | Finding | Fix |
|---|---|---|---|---|
| 1 | T4 (observability) | P2 | A **partially**-defective manifest printed `❌ NOT ENFORCING` while its surviving `hard` rules were still armed and blocking — the banner told an operator the opposite of the truth, contradicting T4's own "the OTHER lines still enforce". | `manifestBanner` now distinguishes the two states: `❌ NOT ENFORCING … no usable rule — every gate is off` only when **0** rules survive, and `⚠️ DEGRADED — … N rule(s) STILL ARMED` otherwise. Test: `a partially-defective manifest says DEGRADED / STILL ARMED — never NOT ENFORCING`. |
| 2 | T7 (observability) | P2 | A whitespace-only prefix was correctly refused, but the warning asserted the **false** reason `is absolute` — the guard conflated `isAbsolute` with `trim() === ""`. | The refusal now names the true reason (`is blank` / `is absolute` / `not a directory UNDER <base>`). |

Cycle 2 also recorded a residual it disagreed with: a **relative** prefix that *escapes* its base
(`../../../../../../../tmp` resolved the trusted root to `/tmp`, functionally identical to the refused
absolute `/tmp`). That tension is now closed in code rather than argued — a prefix must resolve to a
**proper descendant** of the base it is resolved against, so `.`, `..` and any traversal out are
refused too. The reviewer's own repro now reports `/tmp in roots: false \| canonical: null`.

### Exit and disclosure

Cycle 2 did **not** return the clean verdict — it returned 2 findings, which were fixed **after the
bound was spent**, with no third review cycle available. This merge therefore does **not** rest on a
literal `NO ISSUES FOUND`; it rests on threat-list coverage, and the bounded exit is disclosed as
such in the PR body:

`[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=13 residuals=filed`

Both cycle-2 findings were **P2 observability** (wording of a banner and of a warning), not
gate-bypass; both are fixed and both are covered by a test that would fail if reverted.

<!-- implementation-review: cycles=2, status=adversarial-capped, findings=5 fixed=5, cycle2_p2_fixed_post_bound=2 -->
