---
title: "pi patch set — the silent auto-compaction death (#1214)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-18
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, pi-coding-agent, pi-ai, issue-1214, issue-1215, issue-1178, issue-1263, issue-1316
---

# pi patch set — the silent auto-compaction death (#1214, #1263, #1316)

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
  allowed can never be re-armed. This patch set deliberately **does not change it** — see
  **Deliberately excluded** below.

## The changes, and where each one lives

| # | Change | Where | Status |
|---|---|---|---|
| **(a)** | Persist a failed compaction as a durable session entry | **extension-side only** — `extensions/compaction-watchdog.ts` (issue #1215, merged in `f082ec8`) | **already done, verified here** — see `tests/verify-a-durable-failure-record.mjs` |
| **(b)** | Never clamp below a usable output floor | upstream source patch **+** `extensions/clamp-output-floor.ts` (upgrade-proof layer) | **new — the change this set originally carried** |
| **(d)** | Floor the summarization budget at the size of the summary it must preserve | upstream source patch (the ESM copy + both inlined copies in the bundle chunk, #1263) | **new — added to this set** — see `tests/verify-summarization-budget-floor.mjs` |
| **(e)** | Exempt the summarization request from `clampMaxTokensToContext`; fail loudly when the prompt cannot fit | upstream source patch (the caller marker in `compaction.js` + the honouring side in every `buildBaseOptions` copy, #1316) | **new — added to this set** — see `tests/verify-summarization-clamp-exemption.mjs` |

(a) is verified by this set but lives entirely in the #1215 extension; the source patch set itself
carries **(b), (d) and (e)**.

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

### (d) the summarization budget floor (#1263)

A second, independent death in the same compaction path. Before compacting, pi asks the model to
merge the previous summary into a new one, and `UPDATE_SUMMARIZATION_PROMPT` instructs the model to
**PRESERVE the entire previous summary**. The output budget for that call was a flat
`floor(0.8 * reserveTokens)` — with no relationship to the size of the summary it was being told to
preserve. When the previous summary was larger than the budget, the generation ran to the cap, came
back `stopReason: "length"`, and `getSummarizationFailure()` discarded the partial summary and
failed the whole compaction — then failed identically on the overflow path, so the session could
never compact again.

Measured on this fleet (2026-09-21): `reserveTokens = 16384` ⇒ cap **13,107**; a session's previous
summary was **56,077 chars ≈ 13,452 output tokens** (> cap). **21** session files carried a summary
at or above the cap, and `~/.pi/agent/state/compaction-failures.log` held **4** `compaction-failed`
records plus **1** `clamp-death` record.

The fix floors the budget at the size of the summary it must preserve, bounded by the model's own
ceiling:

```js
const modelCeiling = model.maxTokens > 0 ? model.maxTokens : Number.POSITIVE_INFINITY;
const summaryCap = Math.min(Math.floor(0.8 * reserveTokens), modelCeiling);
const priorTokens = previousSummary ? Math.ceil(previousSummary.length / 2) : 0;
const maxTokens = previousSummary ? Math.max(summaryCap, Math.min(priorTokens + 4096, modelCeiling)) : summaryCap;
```

An upper bound costs nothing unless the model actually emits it, so the safe direction is generous.
`chars/2` is a deliberately conservative token estimate: pi's own `estimateTextTokens` uses
`chars/4`, and the densest summary measured across the fleet's compaction records is **3.19 chars per
summary token** (81,542 chars / 25,534 output tokens net of reasoning), so `chars/2` over-estimates
the summary's own token count.

The floor is applied **only when there is a previous summary to preserve**. With none, the budget
stays exactly `min(floor(0.8 * reserveTokens), model.maxTokens)`, so the initial-summary path is
provably unchanged — the test asserts `pristine === patched` for that case at the shipped reserve
(`16384`) and at `2048`, a value below the `5120` where an unconditional `+ 4096` term would have
shifted the initial budget upward.

As with (b), the change is carried in **three copies**: the ESM
(`dist/core/compaction/compaction.js`) and the two independent inlined copies in the bundle chunk
the running CLI loads (`dist/bundle/chunks/chunk-JVUZSMYM.js`) — `generateSummaryWithUsage`, which
is the one pi's own auto-compaction reaches, and `generateSummaryWithRequest` (the bundled
pi-agent-core facade), which pi's auto-compaction paths do not reach but an SDK consumer importing
pi-agent-core's `compact` would. What (d) does **not** cover is listed under **Known gaps** 9.

One property of the manifest is load-bearing and easy to lose: every `verifyPresent` needle must be
**code-shaped**, i.e. absent from the **marker-only rendering of its own payload**, never a
fragment of the `pi-patch #1263(d)` provenance marker (`"pi-patch"`, `"1263"`, `"#1263(d)"` are all
fragments a naive strip leaves behind). With a marker-only needle, a tree where the marker survived
and the floor code was **gone** (and no pristine anchor present either) read as "already applied" —
`apply.sh --check` exited 0 and printed "the fix is in place" over a tree with no floor, a
verification gate passing on nothing.
`tests/verify-summarization-budget-floor.mjs` builds that shape **for every `d` entry** (the patched
block replaced by its marker-only stub, so the anchor is absent too; the file is rebuilt from the
pristine copy per entry so `d2`/`d3`, which share a bundle chunk, cannot contaminate each other) and
asserts `--check` **exits non-zero** — the neither-pristine-nor-patched refusal, exit 2 — never
prints "the fix is in place" and never reports that entry as applied. It also covers the
scattered-substring bypass directly: a tree whose floor code is replaced by a **comment that quotes
the needles** must not read as applied. And it carries a direct unit table over the classifier —
every fragment of the marker classifies NOT code-shaped, every real code needle classifies
code-shaped — so the non-vacuity predicate is falsifiable rather than merely asserted.

That second shape is why `apply.mjs` decides "already applied" on the entry's **own replacement
payload present verbatim** (`next.includes(entry.replace)`), not on scattered `verifyPresent`
substrings. A substring test answers "does this text appear anywhere?", and a comment that merely
quotes the needles satisfies it over a tree whose fix code is gone. `verifyPresent` is kept for the
diagnostics — the "neither pristine nor patched" refusal names the expected needles — but it is no
longer the *proof* that the fix is installed.

The change is proved by `tests/verify-summarization-budget-floor.mjs`, which is hermetic: it builds
a pristine tree and a patched tree in a temp dir (a copy of the installed `dist/` plus a symlinked
`node_modules`), drives the real `generateSummaryWithUsage` with a stub `streamFn`, and asserts the
budget **handed to the stream function** — the pre-clamp value, since the real clamp
(`clampMaxTokensToContext`) runs later inside `buildBaseOptions` and this probe never exercises it
(**the residual formerly recorded as gap 10**, now closed by change (e)) — **13,107 unpatched → 32,135 patched** against the measured 56,077-char summary. The
RED leg fails on the unpatched code by construction (it asserts the value is exactly the old cap and
that the green assertion is false), so "no-repro → green" is impossible. The installed tree is never
modified.

### (e) the summarization clamp exemption (#1316)

The other half of #1263, and the half (d) explicitly left open. Even with the budget
floored at the summary it must preserve, the summarization request is still handed to the same
`clampMaxTokensToContext` that (b) patched — and that clamp does not know the request is a
summarization:

```
available = contextWindow − estimateContextTokens(serialized conversation) − CONTEXT_SAFETY_TOKENS
```

The summarization context **is** the serialized conversation, so it is large by construction. As it
approaches the window, `available` falls below both the requested budget and (via the update prompt)
the size of the summary that must be preserved — the **same** `stopReason: "length"` →
`getSummarizationFailure()` → discarded-summary failure (d) fixed, reached through a different
binding constraint. The clamp's starvation branch (`available < MIN_USABLE_MAX_TOKENS`) is the
single-token death (b) closed for normal turns; for this caller a starved budget is not survivable
at all, because the output cannot be smaller than the summary it must reproduce.

**Measured margin, so this is a residual and not an urgent defect.** Reconstructed on the live
failure (session `01a093d5`, 2026-09-21): the summarization prompt estimated **201,637** tokens
against a 300,000-token window, so `available ≈ 94,267` against a requested **29,625** — the clamp
only binds above ~266,000 prompt tokens (and reaches the 1024 floor near ~294,880). The mechanism
is real but not casually reachable at the 300K window; the 2,000-char tool-result truncation in
`serializeConversation` keeps the summarization input at ~67% of the turn's context.

**The seam.** `clampMaxTokensToContext` is called from `buildBaseOptions`, which has ~10 call sites,
so a blanket removal would exempt every normal turn — a regression. The exemption is therefore
gated on a marker set at the one shared summarization choke point:

- `createSummarizationOptions` (the single constructor every summarization call goes through —
  `generateSummaryWithUsage` **and** `generateTurnPrefixSummary`) sets `skipContextClamp: true`;
- `buildBaseOptions` honours the marker and, when the prompt cannot fit (`promptTokens +
  CONTEXT_SAFETY_TOKENS >= contextWindow`, i.e. `available <= 0`), throws an explicit error naming
  the prompt size and the window, distinguishable from the token-cap error. Otherwise it returns
  the requested budget with no clamp at all.

A normal turn's options never carry the marker, so the shared clamp is untouched for every other
caller — asserted as a CONTROL rather than argued. The loud throw replaces a silently truncated
generation with a message that says what actually happened and that it is *not* the cap error:

```
Summarization prompt does not fit the model context window: prompt ~297000 tokens against a
300000-token window (safety reserve 4096). This is NOT the "generation hit the token cap"
truncation and the output budget was not clamped: the prompt itself must shrink before compaction
can run.
```

Note the trade, and why it is the safe direction: when `available` is positive but smaller than the
requested budget (the starvation window), the request now goes out with its full budget and the
provider either serves it or rejects it — **loud**, and already routed into pi's overflow path.
That is the same reasoning as (b): an estimator that over-counts is not proof the request is too
long, and refusing locally would fail a request the provider would have served. The one case that
cannot be served — `available <= 0` — now fails locally with the sizes named, instead of spending a
round-trip to get the same discarded 1024-token truncation.

Carried in **five copies**: the caller marker in the compaction ESM and the inlined compaction copy
in the bundle chunk, and the honouring side in all three `buildBaseOptions` copies (the pi-ai ESM,
the shared bundle chunk, and bedrock's inlined copy). The bedrock payload is byte-identical to the
shared chunk's.

**A second clamp, in the provider adapters.** `buildBaseOptions` is not the only place the budget
can be cut. The `anthropic-messages` and `bedrock-converse-stream` adapters clamp **again** inside
their own `streamSimple` — `adjusted = adjustMaxTokensForThinking(base.maxTokens, …)` and then
`clampMaxTokensToContext(model, context, adjusted.maxTokens)` — *after* `buildBaseOptions` has
already run. That branch is reached whenever the model reasons and the session thinking level is on,
which the summarization request satisfies (`createSummarizationOptions` sets `options.reasoning`
when the model supports it). Without the same marker gate there, the exemption would be silently
undone inside the adapter for every reasoning model on those two APIs — the adapter's clamp, not the
shared one, would bind. All four re-clamp sites therefore carry the same gate: the two ESM copies
and the two inlined bundle copies (the minified form is byte-identical in both bundle files).

The change is proved by `tests/verify-summarization-clamp-exemption.mjs`, which is hermetic and
drives the REAL caller in **both** representations (the pi-ai ESM and the bundle chunks the CLI
loads). Its stub `streamFn` calls the REAL `buildBaseOptions` on a fabricated context whose
`available` is **5,000** — below the requested **32,135** budget and above the 1,024 floor — and on a
prompt that cannot fit at all. RED (pre-change): the request is clamped to 5,000 and the un-fittable
prompt silently collapses to 1,024. GREEN (post-change): 32,135 and a loud throw. CONTROL (both
trees, both representations): the same call with no marker is still clamped to 5,000 and still does
not throw. For the adapter re-clamp the proof is **end-to-end on the request body**: the test drives
the real `streamSimple` for `anthropic-messages`, again in both representations, with a registered
reasoning model on a shrunk window and a stubbed `fetch`, and reads the `max_tokens` that actually
lands in the request. Pre-change the marker is ignored (marked and unmarked both **5,904**);
post-change it survives the adapter (marked **40,327** = budget + thinking budget, unmarked 5,904;
normal turns identical across both trees). `bedrock-converse-stream` cannot be driven this way — it
authenticates through the AWS SDK, not `fetch` — so its two re-clamp entries are proved by the same
region-verbatim shape verification `apply.mjs` uses plus a `node --check` of each patched file,
which this test performs. The test builds its own trees,
and — because change (e) patches a file **under `node_modules/`** — it copies
`node_modules/@earendil-works/pi-ai` for real rather than symlinking `node_modules`: a symlinked
`node_modules` made the false-PASS fixtures write straight through into the live install (reproduced
on the first run of this test).

## Deliberately excluded — change (c): bounding overflow recovery

This set does **not** touch `_overflowRecoveryAttempted`, the one-shot recovery latch in
`agent-session.js`; the latch ships exactly as upstream wrote it. Bounding it was considered and
rejected because:

- **(b) alone closes the silent death** — with a usable output floor the 1-token turn cannot occur,
  so the latch is never reached in the death scenario;
- bounding it **contradicts four upstream tests** that encode the one-shot design as intentional —
  including a *named characterization test* (`does not retry overflow recovery more than once`) and
  `stops after one compact-and-retry when a second response is also truncated`;
- the latch is a recovery **policy**: changing it belongs upstream, or in a decision of its own, not
  in a version-pinned patch to `node_modules` riding along with a narrow clamp fix.

The rejected patch remains in git history for that future decision.

## Artifacts

```
scripts/pi-patches/
├── apply.sh                                  # the entrypoint — apply / --check / --revert
├── apply.mjs                                 # version pin, two-pass apply, verification, backups
├── verify.sh                                 # re-runs ALL SIX evidence classes in one command
├── make-manifest.mjs                         # re-derives manifests/<version>/manifest.json
├── manifests/0.85.1/manifest.json            # 15 byte-exact replacements (changes (b) + (d) + (e)) for the INSTALLED tree
├── upstream/0001-pi-ai-never-clamp-below-a-usable-output-budget.patch   # change (b), source + test
├── tests/verify-a-durable-failure-record.mjs # change (a), end to end
├── tests/verify-summarization-budget-floor.mjs # change (d), pristine → patched max_tokens
├── tests/verify-summarization-clamp-exemption.mjs # change (e), clamp exemption + normal-turn control + loud failure
└── evidence/
    ├── 2026-09-18-b-only/                    # raw outputs of every claim in the Evidence section (the (b)-only revision, pre-(d))
    └── 2026-09-18/                           # earlier snapshot, captured while change (c) was still in the set
```

`manifests/` is deliberately not called `dist/` — a `dist/` directory is ignored by this repo's
`.gitignore`, so a fresh clone would silently arrive without the manifest and `apply.sh` would find
none. `make-manifest.mjs` is **derived, never hand-written**: it reads the installed tree and requires
every anchor to match **exactly once** — or, on an already-patched tree, to already hold the patched
form — and refuses to emit anything for a file that is **neither**. So a manifest that would replace
nothing (a false PASS) cannot exist.

**The manifest is selected by its `writtenAgainst` pin, not by "there is exactly one directory".**
After an upgrade, `manifests/` normally holds the old version's directory *and* the newly derived one.
`apply.mjs` reads every `manifest.json`, picks the one whose `writtenAgainst` equals the installed
`pi-coding-agent`/`pi-ai` versions, and refuses (exit `3`) if none matches — so the **two-directory
post-upgrade state is the normal state, not an error**. Old version directories are **kept on purpose**
and never pruned by `make-manifest.mjs`: a manifest the pin does not select is still the only thing
that can apply or revert the patch on an install that has not upgraded yet. To force one specific
directory anyway, set `PI_PATCH_VERSION=<dir>` — the pin is still re-checked, so forcing cannot turn
into a silent apply of a mismatched patch set.

**The apply is two-pass on purpose.** Pass 1 plans every file and may refuse; only pass 2 writes.
A single pass that wrote as it went would leave a **half-patched tree** when a later file refused —
some files carrying the fix and others not, which is worse than not patching at all. Individual
writes go through a temp file + `rename`, so a crash cannot truncate a 4 MB bundle and a pi process
starting up can never read a half-written file. `evidence/2026-09-18-b-only/04-revert-roundtrip.txt`
and `evidence/2026-09-18/05-mangled-refusal.txt` both assert this by diffing against a pristine tree
or hashing the whole tree before and after.

## Re-arm after a pi upgrade

```bash
bash scripts/pi-patches/apply.sh --check   # 0 = in place · 1 = ABSENT · 2 = broken checkout · 3 = drift
bash scripts/pi-patches/verify.sh          # all six evidence classes, then ALL EVIDENCE HOLDS
```

If it exits `3`, the version moved. Re-derive, do not hand-edit:

```bash
# 1. confirm the defect is still present upstream (it is not fixed as of HEAD e4ce7b4)
node scripts/pi-patches/make-manifest.mjs          # writes manifests/<new version>/manifest.json
bash scripts/pi-patches/apply.sh                   # applies + verifies
NODE_ENV=test node scripts/pi-patches/tests/verify-a-durable-failure-record.mjs
NODE_ENV=test node scripts/pi-patches/tests/verify-summarization-budget-floor.mjs
NODE_ENV=test node scripts/pi-patches/tests/verify-summarization-clamp-exemption.mjs
npx tsx extensions/clamp-output-floor.test.ts
```

`make-manifest.mjs` **keeps** the old `manifests/<old version>/` directory. That is expected and
deliberate: `apply.mjs` selects the manifest by matching the installed version against
`writtenAgainst`, so the old directory cannot be mistaken for the new one — and it is the only thing
that can still apply or revert the patch on an install that has not upgraded. **Do not delete it**
unless you are certain no install still needs it. If you ever need to run the set against a specific
version directory out of order, select it explicitly with `PI_PATCH_VERSION=<dir> bash
scripts/pi-patches/apply.sh`; the version pin is re-checked, so a mismatch still refuses loudly
(exit `3`) rather than applying anchors derived for another version.

`apply.sh` behaviour, all of it non-silent:

| Situation | Behaviour | Exit |
|---|---|---|
| anchor present | replaces it, backing up the original first | 0 |
| anchor absent, the entry's replacement payload present verbatim | reports `already applied` (idempotent) | 0 |
| anchor absent, patched form absent | **refuses** and writes nothing at all — the tree is left byte-identical, because the refusal is found in pass 1 | 2 |
| `manifests/` directory missing | **refuses** and names it a broken checkout, rather than reporting "0 version directories" | 2 |
| several version directories present | **selects the one whose `writtenAgainst` pin matches the installed version** — the normal post-upgrade state, not an error | 0 / 1 |
| no version directory pins the installed version | **refuses**, names the installed version *and* the directories found, and names the `PI_PATCH_VERSION` escape | 3 |
| `PI_PATCH_VERSION=<dir>` set but no such directory | **refuses** and lists the directories that do exist | 2 |
| installed version ≠ pinned version (forced selection) | **refuses** with the drift table and runnable re-arm steps, writes nothing | 3 |
| post-apply verification fails | **refuses** with the failing assertion | 4 |
| `--check` on an unpatched tree | prints `NOT APPLIED` plus the behavioural evidence (`available=0 → max_tokens 1`) | 1 |

Backups are keyed by **pi root AND version** — `~/.pi/agent/state/pi-patches/backup-<version>-<hash of the pi root>/`.
A version-only key would have let a `--revert` on a second install restore the *first* install's files
over it, so the revert would be a corruption rather than a restore. `apply.sh --revert` restores from
that directory, and `evidence/2026-09-18-b-only/04-revert-roundtrip.txt` proves the restore is
byte-identical to the pristine tree rather than merely "close".

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
    This is the closest match and the natural home for a comment covering (b).
  - **#8864** (CLOSED, auto-closed) — *Long sessions die unrecoverably: … max_tokens clamped to 1*
  - **#8691**, **#9726**, **#8061**, **#7270** — adjacent reports of the same clamp.
  - **#9718** — `--print` exits 0 with empty output when the budget is exhausted (the adjacent
    silence defect).
- **No upstream PR touches `clampMaxTokensToContext`** (checked at 2026-09-18), so the source patch
  is novel. Upstream HEAD `e4ce7b4` still carries `MIN_MAX_TOKENS = 1`.

## Evidence

Evidence is raw output, kept in `scripts/pi-patches/evidence/`. Each row is a real command with real
output, not a claim.

The **shipped (b)-only revision** is captured in `evidence/2026-09-18-b-only/` — a dated snapshot
taken before change (d) was added, so its "3 replacements" and "four evidence classes" counts are
historical, not the current shape of the set:

| File | What it proves |
|---|---|
| `01-red-pristine-check.txt` | a pristine 0.85.1 tree: `--check` reproduces the defect — **8 behavioural failures** as the probe set stood at capture (both the bundled runtime and the pi-ai ESM return `max_tokens: 1` at `available ≤ 0`). The death-probe line was **inert** in that capture — see `06-…` — so the current probe set reports **10**. Exit 1. |
| `02-green-apply-verify.txt` | `apply.sh` applies **3 replacements** to 3 files, then `verify.sh` runs all four evidence classes — `ALL EVIDENCE HOLDS`, exit 0. A second apply writes nothing. |
| `03-extension-negative-controls.txt` | `clamp-output-floor.test.ts` — **26 passed, 0 failed**, including every negative control (a healthy ceiling, a missing/non-numeric field, and a floor-or-above payload are left byte-identical). |
| `04-revert-roundtrip.txt` | `--revert` then `--check` goes RED again, and `diff` against the pristine tree is **byte-identical** — a true restore. |
| `05-c-absent.txt` | the manifest carries **zero** `_overflowRecoveryAttempt*` markers, and the installed `agent-session.js` + `chunk-JVUZSMYM.js` are byte-identical to the pristine tree. |
| `06-manifest-selection-and-live-death-probe.txt` | the fix cycle: with two version directories the manifest matching the **installed** version is selected (`--check` exit 0, was exit 2 — the re-arm procedure no longer dead-ends); the no-match path fails **closed** (exit 3) naming the installed version, the candidate directories and the `PI_PATCH_VERSION` escape; and the death probe now fires, so a pristine tree's `--check` rises **8 → 10** behavioural failures. |

`evidence/2026-09-18/` is the **earlier** snapshot and is left as a dated record: it was captured for
the revision that still carried change (c), so its `apply` lines show **13 replacements**. Its claims
about change (a), the drift/refusal behaviour and the revert round-trip still hold; only the
replacement count and the `agent-session.js` entries are superseded.

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

Change **(d)** is covered by `tests/verify-summarization-budget-floor.mjs`, which prints its own raw
evidence on every run (the pristine→patched `maxTokens`, the shape of both trees, the patched files'
`node --check` result, and the `apply.sh --check` output against a pristine tree). It is a live
evidence class, not a stored capture, because it must re-prove the defect against whatever version is
installed. It is run as section 5/6 of `verify.sh`.

Change **(e)** is covered by `tests/verify-summarization-clamp-exemption.mjs`, also a live evidence
class (section 6/6). It prints the RED/GREEN/control values for both representations, the loud-failure
message, and the raw `apply.sh --check` output for the pre-change, marker-only and quoted-needle
trees. It builds its own trees and never modifies the installed one.

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
   That is no longer prose-only: `scripts/check-pi-config-extensions.sh` check 5 fails loudly
   when a shipped live-farm link dangles, naming the entry and its dead target. The script runs in
   `ci.yml`'s `pi-config-extensions` job, in `ci-main.yml`, and in `.husky/pre-commit` — but check 5
   only has a farm to inspect on a machine (on a CI runner it prints an explicit `⏭️` skip), so the
   loud report is a local one.
   **What check 5 cannot catch:** a *resolvable but non-canonical* target — a link still parked on a
   worktree that is still on disk resolves fine, so it passes until the worktree is removed. That
   half belongs to `bin/agent-infra.js check`, which reports any live-farm target that differs from
   the installed `extensions/` path as `⚠️ stale`.
5. **The `_overflowRecoveryAttempted` latch is intentionally left as upstream ships it** — this set
   changes the clamp only. See **Deliberately excluded** above.
6. **The 1024-token floor is a judgement, not a measurement.** It matches the existing
   `MIN_ANSWER_TOKENS = 1024` in the same module and is 4x under the 4096 safety reserve. No
   measurement establishes that 1024 is the smallest usable budget.
7. **`gh issue create` exit-0-false-success is filed nowhere yet** — it is an agent-infra tooling
   finding (a CLI reporting success while creating nothing), not a pi defect.
8. **`make-manifest.mjs` on an already-patched tree cannot re-prove that the pristine anchors exist
   in the version it is running against** — the anchors are byte-exact for that version (they came
   from it), but the generator can only see the patched form and says so in its output. Re-derive on
   a pristine tree whenever one is available.
9. **Change (d) does not patch the turn-prefix summarization budget.** It uses
   `Math.floor(0.5 * reserveTokens)` and is the same defect class, but its anchor occurs **twice**
   in `chunk-JVUZSMYM.js`, so `apply.mjs`'s unique-anchor resolver refuses it
   (`"ambiguous — remove the duplicate, or select one explicitly with PI_PATCH_VERSION"`). It needs
   its own entry with distinct surrounding context.
10. **Change (e) throws locally when `available <= 0`, where (b) deliberately chose to let the
    provider reject an over-long request.** The two are consistent (the (b) reasoning is about an
    *estimator that over-counts*, not about a request that cannot fit by pi's own accounting), but
    the trade is real: if pi's estimator over-counts a summarization prompt that the provider would
    have served, (e) refuses it locally. The alternative — send it anyway and let the provider
    decide — was rejected because a provider rejection at that point is already a failure of the
    summarization, and the local error names the sizes, which the provider's does not. No measurement
    establishes where pi's estimator diverges from a provider's own tokenizer on a summarization
    prompt; the 1024-floor judgement (gap 6) is the only related measurement. The turn-prefix
    summarization budget (gap 9) *does* get the (e) exemption and the (e) loud failure, because both
    summarization callers share `createSummarizationOptions` and `buildBaseOptions`.
11. **The (e) test must copy `node_modules/@earendil-works/pi-ai` rather than symlink
    `node_modules`** (the (d) test symlinks it). Change (e) patches a file under `node_modules/`, so
    a symlinked `node_modules` let the false-PASS fixtures write straight through into the live
    install; the first run of this test corrupted the installed pi-ai ESM and it was restored from
    the patch backup. The fixture is a temp tree, but the audit lesson is recorded here because the
    failure mode is silent: `apply.sh --check` then read the live tree as "already applied".
12. **The adapter re-clamp is not reachable in the current fleet — it is carried because the
    manifest must be the whole fix, not the reachable half.** Every model this fleet serves
    (`deepseek-flash`, the `openai-completions` API) takes the shared `buildBaseOptions` clamp and
    never the anthropic/bedrock adapter branch, so the four (e6–e9) entries change nothing that runs
    here today. They are carried (and gate-tested) because a patch set that fixes only the reachable
    path silently undoes itself the first time a reasoning Anthropic or Bedrock model is enabled —
    and because `apply.mjs` verifies every carried entry on every apply, so an entry that stops
    matching is caught loudly rather than rotting. The behavioural proof of the two anthropic copies
    runs against a **registered** model on a deliberately shrunk window (see the (e) section); no
    claim is made that the shipped configuration exercises it.
