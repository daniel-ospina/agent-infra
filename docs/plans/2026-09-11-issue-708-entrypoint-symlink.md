---
title: "#708 — symlink-insensitive entry-point guard (fail-closed gates must not no-op) — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-11
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-708, issue-744, issue-709, issue-666, issue-675, scripts, provider-failover
---

# Issue #708 — the entry-point guard silently no-ops through a symlinked path

**Issue:** [#708](https://github.com/daniel-ospina/agent-infra/issues/708) · **Complexity:** standard · **Date:** 2026-09-11

## Objective

A script's "am I the entry point?" check must survive a **symlinked invocation path**, so a
fail-closed gate cannot silently degrade to a no-op. On ambiguity the guard must be **loud** —
never answer "not main" without a visible signal.

## Confirmed problem

The idiom

```js
const isMain =
  process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url;
```

is **symlink-sensitive by construction**. `pathToFileURL` does *no* filesystem resolution; it is a
pure string→URL mapping. Node's ESM loader **does** realpath `import.meta.url`. So whenever *any*
component of the invocation path is a symlink, the two sides differ and the `if (isMain)` body
never runs.

The failure mode is therefore **not** "the gate errors" — it is "the gate prints nothing and exits
0", which is byte-identical to a clean run. There is no assertion anywhere that the gate's
`N files checked.` line exists, so nothing but a human reading the CI log sees it.

**This is not hypothetical.** macOS default temp dirs (`/var/folders/…` → `/private/var/…`) and
every bootstrapped consumer repo (`scripts/` is a **symlink** into agent-infra — see the
`node-ci.yml` skip-input rationale, #387) are affected. CI workspaces, `mktemp -d` scratch trees
and `git archive | tar -x` extractions all traverse symlinked ancestors routinely.

### Reproduction (macOS, `mktemp -d` — the temp dir itself is under the `/var` symlink)

```
$ T=$(mktemp -d); cp -R <repo>/scripts "$T/real/scripts"
$ mkdir -p "$T/real/skills/bad"
$ printf -- '---\nname: bad\ndescription: Build skills: with care\n---\n' > "$T/real/skills/bad/SKILL.md"
$ ln -s "$T/real" "$T/link"

# A — CONTROL: the script invoked at its realpath  → gate RUNS
$ node <repo>/scripts/check-skill-lint.mjs --skills-dir "$T/real/skills"
1 SKILL.md files checked. 4 issue(s).
[P0] frontmatter: throw-unquoted-colon-value — unquoted ': ' in a plain value
...exit 1

# B — BUG: symlinked ANCESTOR ($T is under /var → /private/var) → gate SILENTLY no-ops
$ node "$T/real/scripts/check-skill-lint.mjs" --skills-dir "$T/real/skills"
                                        ← 0 bytes of stdout, exit 0

# C — BUG: explicit symlinked directory component → same silent no-op
$ node "$T/link/scripts/check-skill-lint.mjs" --skills-dir "$T/link/skills"
                                        ← 0 bytes of stdout, exit 0
```

Measured before the fix: A → exit 1 + 4 P0 issues; B and C → **exit 0, empty stdout**.

### The failure class, not just the instance

Same class as [#744](https://github.com/daniel-ospina/agent-infra/issues/744) (a `ReferenceError`
swallowed by a load `try`, leaving `allow` stubs bound — the bash-git gate silently degraded to
"allow" for every session) and [#709](https://github.com/daniel-ospina/agent-infra/issues/709)
(an ungated command family at the effect layer). The unifying lesson:

> **A guard that cannot prove it loaded must not silently allow.**

## Audit — every entry-point guard in the repo

| File | Line | Form | Verdict |
|---|---|---|---|
| `scripts/check-skill-lint.mjs` | 255 | `pathToFileURL(argv1).href === import.meta.url` | ❌ **symlink-sensitive** (the #254 fail-closed gate) |
| `scripts/load-gate.mjs` | 156 | same | ❌ **symlink-sensitive** |
| `scripts/probe-frontmatter-fixtures.mjs` | 364 | `path.resolve(argv1) === fileURLToPath(import.meta.url)` | ❌ **symlink-sensitive** |
| `extensions/shared/provider-failover.ts` | 1366 | `path.resolve(entry) === fileURLToPath(import.meta.url)` | ❌ **symlink-sensitive** (CLI silently skipped) |
| `scripts/check-workflow-lock.mjs` | 420 | `sameRealPath(argv1, fileURLToPath(import.meta.url))` | ✅ fixed under #675 (realpath both sides + fallback) |
| `scripts/check-migration-order.cjs` | 237 | `require.main === module` | ✅ CJS **module-identity** compare — symlink-insensitive |
| `scripts/check-untested-modules.cjs` | 228 | `require.main === module` | ✅ idem |
| `scripts/check-test-regression.cjs` | 755 | `require.main === module` | ✅ idem |

`process.argv[1]` appears in ~30 further sites; all are test harnesses *setting* it
(`extensions/*/*.test.ts`) or non-entry uses (`builtin-tools/index.ts:161`,
`subagent/index.ts:439` read it as "where was pi installed"), not entry-point guards. Audit is
exhaustive over the repo's `process.argv[1]` and `require.main` occurrences.

## Decision

### 1. One shared helper, `scripts/is-main.mjs` — the audit found **four** sites, not two

The issue's open decision 1 asks for the helper iff the audit finds more than two sites. It found
four, so the helper wins over four local fixes (four copies of a subtle fallback chain would drift).

`scripts/` is also the only layer guaranteed present everywhere this guard is needed: consumers
symlink `scripts/` (`node-ci.yml` skip-input rationale, #387), which means *the consumer-repo case
is itself a symlinked invocation path*. A helper under `extensions/` would not be reachable from
`scripts/`.

### 2. A tri-state classification, with a fail-closed default

```js
classifyEntry(metaUrl, argv1) → { verdict, reason, self, argv1 }
```

| Verdict | When | `isMain()` |
|---|---|---|
| `ENTRY` | literal match, realpath match (symlinked ancestor **or** leaf), or dirname-realpath + basename match | `true` |
| `IMPORTED` | **no** `argv[1]` (REPL / `node -e` / plain import), or both sides realpath **definitively to different files** | `false` |
| `UNRESOLVED` | own module path unresolvable, or `argv[1]` unresolvable *and* unprovable | **loud warning + `true`** |

`UNRESOLVED → true` is the fail-closed direction: for all four call sites the guard body **is** the
gate, so running it is the safe answer, and a wrong `true` is *visible* (the gate's output plus a
`[is-main] ⚠️  FAIL-CLOSED` line on stderr) whereas a wrong `false` is invisible. This is the
"refuse or warn loudly" requirement, resolved as *warn loudly and run*.

The `dirname-realpath` fallback is #675 P2-f's chain, kept: it resolves a symlinked **ancestor**
even when the leaf itself is gone (deleted mid-run), which is the other silent-no-op shape.

### 3. `extensions/shared/provider-failover.ts` gets an inline equivalent, deliberately

Shipped extension code importing `../../scripts/…` would be a new cross-layer dependency (no
production extension does it today: `grep -rn "\.\./\.\./scripts" extensions/` matches one test
only) and `scripts/` is not guaranteed to be resolvable relative to a materialized `~/.pi/agent/
extensions/` tree. So the ~10-line comparison is inlined there, with a comment naming
`scripts/is-main.mjs` as canonical. Accepted residual: two implementations can drift; the static
tripwire (below) covers both.

### 4. Regression test at `extensions/shared/test-is-main.mjs`

Chosen because the requirement is the CI glob `extensions/*/test*.mjs`, and `extensions/shared/`
already holds three plain-`.mjs` suites (`test-branch-ownership.mjs`, `test-git-freshness.mjs`,
`test-never-unbounded.mjs`). A new `extensions/<top-level>/` entry would additionally have to be
farm-wired into `pi-bootstrap/pi-config/extensions` or `scripts/check-pi-config-extensions.sh`
goes RED.

The suite is a **positive control**, not a unit test of the helper only (issue open decision 3: a
helper-only unit test *would not have caught this bug*):

- **Part A** — `classifyEntry` cases: literal, symlinked ancestor, symlinked leaf, relative
  `argv[1]`, different file, absent `argv[1]`, unresolvable-leaf-same-basename, unresolvable +
  different basename, `self` unresolvable (`data:` URL), and an explicit assertion that the **old
  idiom returns false** for the symlinked case (documents what the fixture pins).
- **Part B** — spawns the **real** `scripts/check-skill-lint.mjs` with a planted P0 through a
  symlinked `scripts/` dir and through a symlinked ancestor, and asserts byte-comparable *count
  line* + **exit 1** against the realpath control; asserts the fast path was used (no
  `[is-main]` warning). Same for `scripts/load-gate.mjs --json` (must emit a JSON verdict, not
  silence). Negative control: importing the module **must not** run the gate.
- **Part C** — heuristic static tripwire over `scripts/`, `extensions/`, `bin/`: no file may
  compare a **non-realpath'd** path against `import.meta.url`. Labelled heuristic (it catches the
  two shipped idioms, it is not a shell/YAML-semantics model — see #666 for why those do not
  converge).

### 5. CI wiring — both legs, following #744/#709

- `extensions/*/test*.mjs` glob in `ci-main.yml` picks the suite up **post-merge** (no edit needed).
- A per-PR step in `ci.yml`'s `verify` job — the precedent set by #744
  (`test-module-load.mjs`) and #709 (`test-discard-gate.mjs`), because the glob leg is
  **post-merge only**.
- `.github/workflows/ci.yml` is **byte-locked** (`scripts/workflow-lock.json`, #666); the edit is
  paired with a deliberate `node scripts/check-workflow-lock.mjs --update-lock`.

### Wiring

| Surface | Wiring point | Test |
|---|---|---|
| `scripts/is-main.mjs` | new module: `classifyEntry` / `isMain` / `ENTRY`/`IMPORTED`/`UNRESOLVED` | `extensions/shared/test-is-main.mjs` Part A |
| `scripts/check-skill-lint.mjs:255` | guard replaced with `isMain(import.meta.url, process.argv[1])`; unused `pathToFileURL` import dropped | Part B (planted-P0 symlink control) |
| `scripts/load-gate.mjs:156` | same replacement | Part B (`--json` verdict present) |
| `scripts/probe-frontmatter-fixtures.mjs:364` | same replacement | Part A + Part C |
| `extensions/shared/provider-failover.ts:1366` | inline realpath comparison (no cross-layer import) | Part C |
| `extensions/shared/test-is-main.mjs` | new suite | `extensions/*/test*.mjs` glob (ci-main) |
| `.github/workflows/ci.yml` | per-PR `verify` step | `node extensions/shared/test-is-main.mjs` |
| `scripts/workflow-lock.json` | re-lock after the ci.yml edit | `node scripts/check-workflow-lock.mjs` |

## Non-goals / accepted residuals

- **Not** enumerating shell or YAML bypasses — a known unbounded domain (residuals already filed:
  #814, #793; #666 is the evidence that re-modelling does not converge).
- The scripts' validation logic — untouched (this is purely "did the gate run").
- `provider-failover.ts` has **no behavioural** regression test (plain-`node` `.mjs` cannot import a
  `.ts`); it is covered by the helper's Part A logic equivalents + Part C static scan. A `tsx`-run
  behavioural test is a follow-up candidate, not this PR.
- The static tripwire (Part C) is heuristic by design and does not model control flow.

## Verification plan

| Check | Command | Expected |
|---|---|---|
| reproduction, before | repro B/C above | exit 0, empty stdout (bug) |
| reproduction, after | repro B/C above | exit 1, same count line as control |
| new regression suite | `node extensions/shared/test-is-main.mjs` | all pass, 0 failed |
| #744 module-load pin | `node extensions/main-worktree-guard/test-module-load.mjs` | **49 passed / 0 failed** |
| #709 discard gate | `node extensions/main-worktree-guard/test-discard-gate.mjs` | unchanged from baseline |
| lint suite | `node scripts/check-skill-lint.test.mjs` | pass |
| pin gate + lock | `node scripts/check-pi-pin-lockstep.mjs`, `node scripts/check-workflow-lock.mjs` | pass |
| TDD red | temporarily restore the old idiom at `check-skill-lint.mjs` | Part B RED |
