---
title: "pi patch set — the silent auto-compaction death (#1214)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-18
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, pi-coding-agent, pi-ai, issue-1214, issue-1215, issue-1178
---

# pi patch set — the silent auto-compaction death (#1214)

> **WRITTEN AGAINST `@earendil-works/pi-coding-agent` 0.85.1 / `@earendil-works/pi-ai` 0.85.1.**
> **EXPIRY: any pi upgrade reverts `dist/` and this patch set stops being applied.** That is not
> a silent event — `apply.sh --check` exits `1`, `apply.sh` exits `3` with a loud refusal, and the
> `clamp-output-floor` extension prints a warning at **every** pi process start. Re-arm with the
> procedure below before running long sessions on a new version.

## The defect

`clampMaxTokensToContext` (pi-ai) collapses the requested output budget as the context grows:

```js
const CONTEXT_SAFETY_TOKENS = 4096;
const MIN_MAX_TOKENS = 1;
const available = model.contextWindow - estimateContextTokens(context).tokens - CONTEXT_SAFETY_TOKENS;
return Math.min(maxTokens, Math.max(MIN_MAX_TOKENS, available));
```

Once pi's own estimate passes `contextWindow − 4096`, `available ≤ 0`, so pi asks the model for
**one token**. The model answers `stopReason: "length"` with `output: 1` — a turn that is
accounted as a normal turn, appended to history (so the context GROWS while dead), and leaves the
session alive but unable to ever reply again. Measured on this fleet: **188 such turns across 49
sessions, 4 of them permanent.**

Two aggravating defects in `agent-session.js`:

- `_emitSessionCompactFailed` calls only extension handlers and writes **no session entry**, so a
  failed compaction is recorded nowhere. (Closed separately — see **change (a)** below.)
- `_overflowRecoveryAttempted` is a **latch**: it resets only on a turn that ends normally or on a
  new user message, so a `length` loop never clears it and the one compact-and-retry a session is
  allowed can never be re-armed.

## The three changes, and where each one lives

| # | Change | Where | Status |
|---|---|---|---|
| **(a)** | Persist a failed compaction as a durable session entry | **extension-side only** — `extensions/compaction-watchdog.ts` (issue #1215, merged in `f082ec8`) | **already done, verified here** — see `tests/verify-a-durable-failure-record.mjs` |
| **(b)** | Never clamp below a usable output floor | upstream source patch **+** `extensions/clamp-output-floor.ts` (upgrade-proof layer) | new |
| **(c)** | Bound overflow recovery instead of latching it | upstream source patch only (not reachable from an extension) | new, **see the caveat below** |

**(a) is deliberately not re-implemented in the patch.** The #1215 watchdog already writes
`pi.appendEntry("compaction-watchdog", …)` on `session_compact_failed`, plus a fleet log and an
escalation line. Adding a second writer of the same record in pi itself would be redundant, and
the extension version cannot be reverted by `npm i`. `tests/verify-a-durable-failure-record.mjs`
proves it end to end against the **installed** `SessionManager` and reads the entry back off disk.

**(b) is the change that actually closes the silent death.** Two independent layers:

- the **source patch** fixes the clamp itself, and
- the **extension** raises an absurd ceiling back to `1024` at `before_provider_request` — the one
  hook where pi lets an extension replace the outgoing payload. When the source patch is applied
  the extension is a no-op (the clamp never produces an absurd value); when an upgrade reverts the
  patch the extension is the thing holding the line, and it says so at startup.

**Why raise the budget instead of throwing.** pi's ceiling sits far below what providers serve —
one route served a **988,202**-token prompt while pi was asking for 1 token, the provider's hard
limit is **1,048,576**, and this fleet has run ~1M. So an absurd ceiling is usually an estimator
artefact, not proof the request is too long: refusing it would fail a request the provider would
have served. Raising it means the provider rejects a genuinely over-long prompt — **loud**, and
already routed into pi's overflow path — and otherwise the turn just works. **Overflow is better
than death, because it is loud.** The trade is one wasted round-trip (and any input tokens the
provider charges for it) in the genuinely-over-limit case.

**⚠ (c) is an argued change, not a mechanical one, and it deviates from the instruction.**
The instruction was "reset `_overflowRecoveryAttempted` on `length` stops so recovery can retry".
A literal reset re-arms an **unbounded** compact-and-retry loop — each attempt spends a
summarization call — so it is implemented as a **bounded attempt counter**
(`MAX_OVERFLOW_RECOVERY_ATTEMPTS = 3`) that resets on a normal turn and on a new user message.
That change **contradicts four existing upstream tests**, including a *named characterization
test* (`does not retry overflow recovery more than once`) and
`stops after one compact-and-retry when a second response is also truncated`. Those tests are
updated in `0002`, and the deliberate one-shot design they encode is the reason `0002` is a
**separate patch you can drop**: (b) alone closes the silent death, because with a usable floor the
1-token turn cannot occur. Decide whether to take (c) on its merits.

## Artifacts

```
scripts/pi-patches/
├── apply.sh                                  # the entrypoint — apply / --check / --revert
├── apply.mjs                                 # version pin, two-pass apply, verification, backups
├── verify.sh                                 # re-runs ALL FOUR evidence classes in one command
├── make-manifest.mjs                         # re-derives manifests/<version>/manifest.json
├── manifests/0.85.1/manifest.json            # 13 byte-exact replacements for the INSTALLED tree
├── upstream/0001-pi-ai-never-clamp-below-a-usable-output-budget.patch   # change (b), source + test
├── upstream/0002-pi-coding-agent-bound-overflow-recovery-instead-of-latching.patch  # change (c)
├── tests/verify-a-durable-failure-record.mjs # change (a), end to end
└── evidence/2026-09-18/                      # raw outputs of every claim below
```

`manifests/` is deliberately not called `dist/` — a `dist/` directory is ignored by this repo's
`.gitignore`, so a fresh clone would silently arrive without the manifest and `apply.sh` would find
none. `make-manifest.mjs` is **derived, never hand-written**: it reads the installed tree and requires
every anchor to match **exactly once** — or, on an already-patched tree, to already hold the patched
form — and refuses to emit anything for a file that is **neither**. So a manifest that would replace
nothing (a false PASS) cannot exist.

**The apply is two-pass on purpose.** Pass 1 plans every file and may refuse; only pass 2 writes.
A single pass that wrote as it went would leave a **half-patched tree** when a later file refused —
some files carrying the fix and others not, which is worse than not patching at all. Individual
writes go through a temp file + `rename`, so a crash cannot truncate a 4 MB bundle and a pi process
starting up can never read a half-written file. `evidence/10-revert-roundtrip.txt` and
`evidence/05-mangled-refusal.txt` both assert this by hashing the whole tree before and after.

## Re-arm after a pi upgrade

```bash
bash scripts/pi-patches/apply.sh --check   # 0 = in place · 1 = ABSENT · 2 = broken checkout · 3 = drift
bash scripts/pi-patches/verify.sh          # all four evidence classes, then ALL EVIDENCE HOLDS
```

If it exits `3`, the version moved. Re-derive, do not hand-edit:

```bash
# 1. confirm the defect is still present upstream (it is not fixed as of HEAD e4ce7b4)
node scripts/pi-patches/make-manifest.mjs          # writes manifests/<new version>/manifest.json
bash scripts/pi-patches/apply.sh                   # applies + verifies
NODE_ENV=test node scripts/pi-patches/tests/verify-a-durable-failure-record.mjs
npx tsx extensions/clamp-output-floor.test.ts
```

`apply.sh` behaviour, all of it non-silent:

| Situation | Behaviour | Exit |
|---|---|---|
| anchor present | replaces it, backing up the original first | 0 |
| anchor absent, patched form present | reports `already applied` (idempotent) | 0 |
| anchor absent, patched form absent | **refuses** and writes nothing at all — the tree is left byte-identical, because the refusal is found in pass 1 | 2 |
| `manifests/` directory missing | **refuses** and names it a broken checkout, rather than reporting "0 version directories" | 2 |
| installed version ≠ pinned version | **refuses** with the drift table and runnable re-arm steps, writes nothing | 3 |
| post-apply verification fails | **refuses** with the failing assertion | 4 |
| `--check` on an unpatched tree | prints `NOT APPLIED` plus the behavioural evidence (`available=0 → max_tokens 1`) | 1 |

Backups are keyed by **pi root AND version** — `~/.pi/agent/state/pi-patches/backup-<version>-<hash of the pi root>/`.
A version-only key would have let a `--revert` on a second install restore the *first* install's files
over it, so the revert would be a corruption rather than a restore. `apply.sh --revert` restores from
that directory, and `evidence/10-revert-roundtrip.txt` proves the restore is byte-identical to the
pristine tree rather than merely "close".

## Upstream status — READ BEFORE PROPOSING A PR

- `earendil-works/pi` is the real upstream, it is **public and readable**, and this account has
  `pull: true, push: false`. **We cannot push a branch or open a PR.**
- `gh issue create --repo earendil-works/pi …` is a **false success**: GitHub answers
  `{"data":{"createIssue":{"issue":null}}}`, `gh` prints nothing and **exits 0**. Do not treat
  exit 0 from `gh issue create` as "filed". (`gh api -X POST …` gives the honest HTTP 403.)
- The repository **auto-closes every issue from a new contributor**; a maintainer must reply `lgtm`
  before issues/PRs stay open. So a cold issue will be closed automatically.
- **The defect is already reported upstream** and the reports are worth linking rather than
  duplicating:
  - **#9409** (OPEN) — *Sessions wedge permanently at the context ceiling on reasoning models* —
    quotes our exact error string (`Truncated response recovery failed after one compact-and-retry
    attempt.`), reports `usage.output: 16`, and notes **not one compaction entry was written**.
    This is the closest match and the natural home for a comment covering (b) and (c).
  - **#8864** (CLOSED, auto-closed) — *Long sessions die unrecoverably: … max_tokens clamped to 1*
  - **#8691**, **#9726**, **#8061**, **#7270** — adjacent reports of the same clamp.
  - **#9718** — `--print` exits 0 with empty output when the budget is exhausted (the adjacent
    silence defect).
- **No upstream PR touches `clampMaxTokensToContext`** (checked at 2026-09-18), so the source patch
  is novel. Upstream HEAD `e4ce7b4` still carries `MIN_MAX_TOKENS = 1`.

## Evidence

Evidence is raw output, kept in `scripts/pi-patches/evidence/2026-09-18/`. Each row is a real command
with real output, not a claim:

| File | What it proves |
|---|---|
| `01-verify-all-evidence.txt` | `verify.sh` end to end — patch state, a durable failure record, the extension guard, the #1215 watchdog suite — `ALL EVIDENCE HOLDS`, exit 0 |
| `02-red-before-patch.txt` | a faithful pristine 0.85.1 tree: **8 behavioural failures** — the bundled runtime and the pi-ai ESM BOTH return `max_tokens: 1` at `available ≤ 0`. Exit 1. |
| `03-green-after-apply.txt` | the same tree after `apply.sh` — 13 replacements, both representations verified, `--check` exit 0, a second apply writes nothing |
| `04-drift-refusal.txt` | a pristine **0.86.0** tree is refused with the drift table and runnable re-arm steps. Exit 3. |
| `05-mangled-refusal.txt` | a tree that is **neither** pristine **nor** patched is refused, and the **whole-tree hash is unchanged** — nothing was written |
| `06-`/`07-coding-agent-*.txt` | the 8 coding-agent compaction suites: **identical** failure sets before and after (12 pre-existing), 35/35 green in the two suites that assert retry semantics |
| `08-`/`09-ai-*.txt` | the ai package across 71 test files: **identical** failure sets before and after (5 files / 47 tests, all pre-existing network/provider-key) |
| `10-revert-roundtrip.txt` | revert then re-check goes RED again; `diff -r` against pristine reports **IDENTICAL**, so the restore is a true restore |

## Known gaps — stated, not hidden

1. **`dist/**/*.js.map` is not regenerated.** The bundle chunks and `dist/core` carry source maps
   whose `sourcesContent` is now stale. Execution is unaffected; stack traces into the patched
   functions may show pre-patch source. Regenerating them would require the upstream build.
2. **`pi-ai` is patched in two representations** (the bundled chunks that actually run, and the ESM
   copy for library consumers). A third consumer we have not found would not be covered — the
   extension layer is the backstop for exactly that.
3. **The `Unknown` self-check state is fuzzy.** `detectSourcePatch` returns `"unknown"` when the
   content-hashed chunk filename has moved; it warns, which is the safe direction, but it cannot
   distinguish "upgraded" from "upstream fixed it".
4. **The extension is symlinked to this worktree** (`~/.pi/agent/extensions/clamp-output-floor.ts`).
   After merge, repoint the symlink at the hub path
   (`agent-infra/extensions/clamp-output-floor.ts`) or the guard dangles when the worktree goes.
5. **(c) contradicts four upstream tests** and is still subject to the argument above; the
   one-shot recovery design may be deliberate for reasons we cannot see.
6. **The 1024-token floor is a judgement, not a measurement.** It matches the existing
   `MIN_ANSWER_TOKENS = 1024` in the same module and is 4x under the 4096 safety reserve. No
   measurement establishes that 1024 is the smallest usable budget.
7. **`gh issue create` exit-0-false-success is filed nowhere yet** — it is an agent-infra tooling
   finding (a CLI reporting success while creating nothing), not a pi defect.
8. **`make-manifest.mjs` on an already-patched tree cannot re-prove that the pristine anchors exist
   in the version it is running against** — the anchors are byte-exact for that version (they came
   from it), but the generator can only see the patched form and says so in its output. Re-derive on
   a pristine tree whenever one is available.
