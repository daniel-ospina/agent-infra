---
title: "#1323 — the pi skill farm: build it from the layout, or stop pretending"
type: engineering
domain: platform
doc_status: draft
created: 2026-10-16
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: agent-infra
---

# #1323 — the pi skill farm: build it from the layout, or stop pretending

**Issue:** `daniel-ospina/agent-infra#1323` · **Tier:** standard · **A/B:** A
(an **inert enforcer** — the extension's only action could never fire, while it
reported itself as "falling back to cache"; plus a warning naming a path that
cannot exist for any repo) · **Domain:** filesystem/gate — the farm is a gate
input, so the adversarial surface is declared below · **Date:** 2026-10-16 ·
**Branch:** `feat/1323-tm`

## Confirmed problem

`extensions/skill-registry.ts` built its registry by shelling out to
`<project>/operations/tools/skill_registry.py` — a file that lives in **eldato**
and has **never** existed in agent-infra (`git log --all -- '*skill_registry*'`
is empty; there is no `operations/` directory here at all, and
`scripts/check-skill-links.sh` asserts that in its own guard text). Two
consequences, one class (a missing input read as "nothing to do"):

1. The `$AGENT_INFRA_PATH` fallback resolved to `<agent-infra>/operations/tools/
   skill_registry.py` — **unreachable by construction** — and every non-eldato
   session printed a warning naming it. `AGENTS.md` §"Fix Broken Infrastructure":
   a warning that can never be acted on trains readers to ignore startup output.
2. With no generator the cache stayed `{}`; `if (Object.keys(registry).length
   === 0) return;` made the handler a **silent no-op**. Measured on the fleet:
   `~/.pi/agent/skills-registry.json` = `{}` (2 bytes), the farm holds 125 real
   directories created by `pi-bootstrap/setup.sh`, and the extension contributes
   nothing on any repo except eldato. Drift between a skill and its farm copy is
   therefore invisible until `sync.sh` happens to run again.

**Reproduced (RED, old module, temp HOME, a project that HAS a skill):**

```
$ cd <tmp>/proj            # contains skills/alpha/SKILL.md
$ HOME=<tmp>/home AGENT_INFRA_PATH=<agent-infra> npx tsx probe.ts
skill-registry: skill_registry.py not found under
  <agent-infra>/operations/tools/skill_registry.py — falling back to cache
[probe] registry cache exists: false
[probe] farm exists: false

$ # same fixture, new module:
[skill-registry] linked 1 of 1 source skill(s) into <tmp>/home/.pi/agent/skills
[probe] farm alpha: true -> <tmp>/proj/skills/alpha
```

## Chosen approach (Phase 5)

| # | Approach | Verdict |
|---|---|---|
| **a** | Vendor the generator into agent-infra (`operations/tools/skill_registry.py`) | **Rejected.** agent-infra has no `operations/` directory *by design* — `scripts/link-skills.sh` and `scripts/check-skill-links.sh` both refuse to run here precisely because that directory marks a CONSUMER repo. Creating it would make the canonical source look like a consumer, and the generator's eldato-only semantics are not obtainable from this repo (copying them would be a guess). |
| **b** | Make the extension layout-aware, in-process, and honest | **Chosen** — see below. |
| **c** | Retire the extension; the farm is `setup.sh`'s job | **Rejected (conditionally).** It satisfies indicators 1–3 but regresses indicator 4: eldato's project-root probe is the ONLY mechanism that makes a consumer repo's `operations/skills/` visible to pi (pi's default discovery is `~/.pi/agent/skills` + `<cwd>/.pi/skills` only — verified in the installed `dist/core/skills.js` `loadSkills`). Retiring it would drop consumer-only skills off the farm with nothing to replace them. If a future decision hands consumer skills to another mechanism, (c) is the right follow-up. |

`setup.sh` and this extension both write into `~/.pi/agent/skills`. Rather than
pretend they do not, the extension's contract is **additive-only**: it creates a
link only where the name is absent, repairs only a **dangling** link, and never
removes or overwrites anything else. That is a contract the tests pin, not a
comment.

## The contract (implemented)

1. **Layout-aware, in-process.** Sources are enumerated in TypeScript from the
   shapes pi/consumers use — `skills/`, `operations/skills/`, `.agents/skills/`,
   `.pi/skills/` — under the project root AND under this module's **real** repo
   root (`realpathSync(__filename)`, the #1321 discipline: jiti keeps the
   symlink path in `__dirname`). No Python, no cache file, no env-var path.
2. **Additive-only writer.** Never overwrite a real directory; never remove a
   live symlink (even a foreign one); repair only a dangling link whose name
   matches a source.
3. **Never write through a symlinked farm.** If `~/.pi/agent/skills` is itself a
   symlink (a supported setup.sh layout) the farm is *delegated*: pi already
   reads that directory, and a per-skill link written through it would land
   inside a git work tree. Sources absent from the delegated directory are
   reported instead of written.
4. **A linked worktree is not the machine's configuration.** Worktree roots are
   skipped so a torn-down sandbox cannot leave dangling links in the farm (the
   #1214b class).
5. **Empty is not success.** The handler prints a success line only when it
   linked or repaired something; every failure is an `❌` error line. An empty
   source set prints nothing and does **not** create a farm.
6. **Staleness is reported** (indicator 3) with the remedy named — a path that
   exists (`<agent-infra>/sync.sh`), not a variable that may be unset.

## Indicator → test map

| # | Indicator | Test |
|---|---|---|
| 1 | No warning naming a path that cannot exist | `source of the warning` — a repo with no `operations/` produces no such text; the module contains no `skill_registry.py` / `AGENT_INFRA_PATH` / `skills-registry.json` in code |
| 2 | A missing/unusable input is surfaced, never silently swallowed; an empty input must not read as success | `empty is not success` — the unreadable root, the unusable farm and the dangling farm are `❌` + `ok=false`; an empty source set prints NOTHING; the handler prints a success line only when something changed |
| 3 | A user-visible signal when a farm skill is stale | `staleness and failure reporting` — a diverging real copy is named with an existing remedy; a change to a *supporting* file (SKILL.md unchanged) is detected |
| 4 | No regression for the layout the old probe served | `source discovery` — `operations/skills/` is one of the enumerated shapes; shape precedence and dedup are pinned |

**Target 2 mapping (stated, not glossed):** the issue's second target is "a test
asserting a **missing generator** is surfaced (non-silent)". This change removes
the generator concept entirely, so the target is met by its generalisation — the
equivalent missing/unusable **input** (an unreadable source root, an unusable
farm, a dangling farm link) is a `❌` and `ok=false`, and the empty-input path is
pinned to print nothing rather than a success. That is a deliberate re-derivation
of the target, not a claim of literal compliance.

## `### Adversarial Threat Surface`

Gate/enforcement-adjacent code whose correctness is "a hostile skill directory
cannot make this walk or write somewhere it must not". **2-cycle bound**; the
declared classes below are the acceptance criterion, and out-of-scope classes
are declared rather than chased.

| # | Threat class | Adversarial input | Required behaviour | Test |
|---|---|---|---|---|
| A1 | Symlink to a real directory inside a skill (the #1051 class) | `skills/alpha/root -> /` | the signature walk does **not** descend; the link is recorded as its target | `staleness walk NEVER dereferences a symlink` (measured pre-fix: 37,036 filesystem entries read from one skill dir) |
| A2 | Symlink loop | `skills/alpha/self -> alpha` | terminates; no depth-limit marker (no descent at all) | same test |
| A3 | Symlinked farm | `~/.pi/agent/skills -> <a repo>/skills` | nothing is written through it; absent sources are reported | `delegated farm` section (asserts the delegated dir's `readdir` is unchanged) |
| A4 | Live foreign symlink in the farm | `farm/<name> ->` somewhere else | untouched, not removed, not reported as a problem | `NEGATIVE CONTROL: a live foreign symlink is left alone` |
| A5 | A diverging farm COPY | farm holds a real dir equal-named but different | reported stale, bytes untouched (asserted verbatim) | `NEGATIVE CONTROL: a diverging farm COPY ... never overwritten` |
| A6 | Name collision with a non-directory | `farm/<name>` is a plain file | reported as a conflict, never replaced | `a plain FILE where a skill belongs is a conflict` |
| A7 | Self-link | a root whose `skills/` **is** the farm | contributes no sources (no farm→farm link) | `SELF-LINK guard` |
| A8 | Sandbox leak | a linked worktree root | contributes no sources; the machine farm is not pointed at a teardown-able path | `LINKED WORKTREE guard` |
| A9 | Dangling links | a link whose target is gone | repaired **only** when the name matches a source | `dangling link ... repaired` + its negative control |
| A10 | Deployed layout (#1321 mechanism) | module loaded through a farm symlink under `--preserve-symlinks` | `REPO_DIR` is the REAL repo; the project's skills still link | `T8/T1` farm-child leg with a loader precondition |

**Explicitly out of scope (declared, not chased):**

- **A worktree with a BROKEN `git`** is classified as a main checkout (the
  conservative default), so its skills could be linked. The guard's purpose is
  to avoid dangling links; failing closed here would drop a real repo instead.
- **Files above `HASH_MAX_BYTES` (2 MiB)** are compared by size only. Skill text
  is well below this; the marker is visible in the signature either way.
- **A same-size, same-mtime content swap below the limit is still hashed**, so
  the only miss is a >2 MiB file whose size is unchanged.
- **The eldato generator's exact semantics are assumed to be "one skill per
  directory holding `SKILL.md`"** — the shape its cache key consumed. The
  generator is not reachable from this repo, so this is an assumption, recorded
  here rather than presented as verified.
- **Write races** (another process creating the link between `lstat` and
  `symlink`) surface as a loud `❌ cannot link … EEXIST`: a false *failure* line,
  never a false success, and nothing is overwritten.

## Files

| File | Change |
|---|---|
| `extensions/skill-registry.ts` | rewritten (layout-aware enumerator, additive writer, honest report) |
| `extensions/skill-registry.test.ts` | new — 34 tests, zero-dep |
| `.github/workflows/ci.yml` | PR-lane step for the suite (the `test-command` accumulator is exact-pinned, so it is its own step) |
| `.github/workflows/ci-main.yml` | post-merge backstop step |
| `scripts/workflow-lock.json` | regenerated (`--update-lock`) — the two edits above are locked files |

## Test evidence

```
$ npx tsx extensions/skill-registry.test.ts
✅ 34 passed, 0 failed

$ bash scripts/check-pi-config-extensions.sh
✅ pi-config/extensions = symlink farm into extensions/ (32 entries)
✅ manifest.json files.extensions.entries ↔ extensions/ tree parity holds
exit 0

$ node scripts/check-pi-pin-lockstep.mjs
123 passed, 0 failed — ✅ ALL TESTS PASSED

$ bash scripts/check-workflow-actionlint.sh .github/workflows/ci.yml .github/workflows/ci-main.yml
exit 0   (and RED on a deliberately broken fixture, so the gate is not inert)
```
