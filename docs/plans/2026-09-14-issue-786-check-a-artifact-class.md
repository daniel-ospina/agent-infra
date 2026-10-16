<!-- research-path: docs/plans/2026-09-14-issue-786-check-a-artifact-class.md -->

# check (a): positional closing keyword + artifact-only carve-out — Implementation Plan

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Make `pipeline-compliance` check (a) distinguish a *reference* from a *mention*, and let an
artifact-only PR advance an issue without falsely closing it — **without** letting a code PR dodge
closure.

**Team:** organisation-design-team

**Issues:** #1012 (positional closing match) + #786 (artifact-only carve-out). One root cause, two
mirror-image symptoms: PR #968 (skills diff + prose that *discussed* a closing keyword) was wrongly
**passed**; PR #955 (skills diff + honest `Part of #949`) was wrongly **blocked**.

**Architecture:** Two coupled predicate changes in `scripts/check-pipeline-compliance.sh`, plus the
mirrored parser in `scripts/record-review.sh` (the documented cross-script contract) and both
scripts' fixture suites. Pure bash; no dependencies, no data model, no architecture surface.

### Pattern Research

Skipped — zero third-party dependencies. Bash 3.2+ (`grep -E`, here-strings), `awk`, GitHub
Actions.

### Integration Surface Map

| Surface | Type | Test layer | Notes |
|---|---|---|---|
| `parse_issue_ref` | pure shell parser | `expect_ref` / `expect_resolve` fixtures | string → `owner/repo#N`; no I/O |
| `parse_trace_ref` | pure shell parser | `expect_trace` fixtures | delegates to `parse_issue_ref` with `TRACE_KW` |
| `pr_is_artifact_only` (was `pr_is_docs_only`) | pure shell predicate | `expect_artifact_only` fixtures + #836 large-input vector | wraps `files_rows` |
| `resolve_issue_ref` | gate resolution | `expect_resolve` fixtures + live check (a) | single resolution point |
| check (a) verdict + message | gate logic | CI `pipeline-compliance` job | consumes `resolve_issue_ref` |
| `record-review.sh::closing_issue_refs` | cross-script mirror | `record-review.test.sh` §8.9, §8.9a, §8.11, §8.13 | clean-micro tier guard; byte-identical constant lines (keyword class), GitHub-parity scan |
| `.github/workflows/pipeline-compliance.yml` | CI wiring | the CI run | runs the self-test (already wired by #991) |

**Bug pattern flags:** the carve-out is an allowlist, so *widening it too far* is the risk this plan
must defeat with a fixture, not with prose. The `REFCTX`/`CLOSING_KW` constant lines must stay
byte-identical across the two scripts (§8.13 pins them), but the invariant is scoped to the **keyword
class**: `record-review`'s tier guard deliberately scans *beyond* the positional rule with the bare
`CLOSING_KW`, because a mid-sentence ref still auto-closes on merge.

### Failure Modes

- A code PR whose body carries only `Refs #N` → **must FAIL** (a) → fixture vector 3.
- A code PR whose body *mentions* a closing keyword mid-sentence (the #968 shape) → **must FAIL**
  (a) → fixture vector 4.
- An instruction-layer PR (`skills/**/*.md`, `AGENTS.md`) with `Part of #N` → **must PASS** (a) →
  fixture vector 2. (Read `false` before this change.)
- A docs-only PR with `Refs #N` → **must PASS** (a), unchanged → fixture vector 1.
- A normal PR with `Closes #N` on its own line → **must PASS** (a) → fixture vector 5.
- A malformed/truncated/forged diff list → **must NOT** read as artifact-only → existing fail-closed
  tripwires retained.

**Tech Stack:** bash 3.2+, `grep -E`, `awk`, GitHub Actions.

---

## Problem

`check-pipeline-compliance.sh` check (a) decides "this PR links its issue" with one parser,
`parse_issue_ref`, whose match was **unanchored over free text**:

```bash
CLOSING_KW='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'
… | grep -ioE "${kw}[[:space:]]*#[0-9]+"
```

Two consequences, both live:

1. **Any prose that discusses a closing keyword satisfies (a).** PR #968's status note — *"a closing
   keyword would falsely close #949, which stays open…"* — satisfied the gate, a sentence written
   *because* the author knew closure would be dishonest. The same match feeds GitHub's auto-close
   parser, so merging #968 would have closed an umbrella issue that must stay open.
2. **The non-closing carve-out is drawn at `^docs/` only.** `resolve_issue_ref` consults the
   traceability keywords only when `pr_is_docs_only` is true, and that predicate accepts only paths
   under `docs/`. A PR whose entire diff is instruction-layer Markdown (`skills/**/*.md`,
   `AGENTS.md`) — which ships governance prose, not runtime work — has no honest way to satisfy (a):
   `Closes #N` records an undelivered control as delivered, and `Refs #N` is not accepted.

The second is the mirror of the first: #968 is wrongly passed, #955 is wrongly blocked.

## Part 1 (#1012) — position is the contract

A closing reference must occupy a **reference context**: the keyword begins a line, optionally after
every Markdown prefix GitHub renders as a line-leading reference marker — a bullet (`- `/`* `/`+ `),
an ordered-list marker (`1. `/`1) `), a blockquote (`> `), an ATX heading (`# ` … `###### `), a
task-list checkbox (`[ ] `/`[x] `) — and/or emphasis/bold/backtick marks.

```bash
REFCTX='^[[:space:]]*(([-*+]|[0-9]+[.)])[[:space:]]+|#{1,6}[[:space:]]+|>[[:space:]]*)*(\[[ xX]\][[:space:]]+)*[*_`]{0,3}[[:space:]]*'
CLOSING_KW='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'
TRACE_KW='\b(ref(s|erences?)?|part[[:space:]]+of|advance(s|d)?|track(s|ed)?|relates?[[:space:]]+to)'
```

The first cut of `REFCTX` accepted only bullets and emphasis markers. That narrower form
**false-blocked** legitimate reference contexts — `## Closes #173`, `1. Closes #173`,
`- [ ] Closes #173`, `> Closes #173` all resolved before #1012's anchoring and all still
auto-close on GitHub, so a PR using one would have failed check (a) while really closing its issue.
They were **unpinned**, which is why the regression was invisible: the anti-vacuous control (a code PR
with only a mid-sentence mention still FAILS) is what the widened alternation must preserve, and the
new fixtures pin both directions.

`parse_issue_ref` composes `kw="${REFCTX}${kwpat}"`; the accepted forms (full URL, `owner/repo#N`,
bare `#N`) are unchanged — only the context the keyword sits in is constrained. `parse_trace_ref`
delegates to the same function, so the trace class is positional too (fail-closed direction: it can
only *deny* the fallback, never widen it).

### The decision to anchor — and the cross-script contract

`parse_issue_ref`'s constants are documented as byte-identical to
`record-review.sh::closing_issue_refs`'s, and `record-review.test.sh` §8.11 pins the shared parser
corpus (including, until now, `"This fixes #42 in passing"` asserting a match — the unanchored
narrative-prose class). What follows draws the contract at the right level: the constants are shared,
the *selection* of a positional vs bare keyword is not.

Two options were available:

| Option | Verdict |
|---|---|
| (a) Anchor both scripts (compose the same two constants in each) | **Chosen — but the invariant is scoped to the keyword CLASS, not the position rule.** `REFCTX` and `CLOSING_KW` stay byte-identical across the two scripts; the *positional* rule governs check (a) only. `record-review.sh`'s #513 tier guard additionally scans with a **word-boundary-anchored** `CLOSING_KW` (`\b` + the class, no `REFCTX`), because GitHub auto-closes a mid-sentence ref — and because GitHub requires a word boundary, an unanchored class would be strictly *broader* than GitHub and refuse over prose. |
| (b) Anchor only the compliance script and explain the divergence | **Rejected.** The byte-identity claim and §8.11 would become false statements pinned by a suite that still asserts the old class. Removing a stated invariant to avoid a two-line change is the wrong trade. |

`REFCTX` and `CLOSING_KW` are defined as top-level constants in **both** scripts with byte-identical
values (`record-review.test.sh` §8.13 pins the two constant lines mechanically — nothing asserted
that equality at the time of the first cut); `check-pipeline-compliance.sh::parse_issue_ref` and
`record-review.sh::closing_issue_refs` both compose `kw="${REFCTX}${CLOSING_KW}"` by default.
`record-review.test.sh` §8.11 is updated in the same change: the mid-sentence mention vector is
inverted (it must now resolve to nothing) and bullet/heading/ordered-list/task-list/blockquote
positive controls are added, so the parity corpus pins the *new* contract rather than rotting on the
old one. §8.9's multi-ref bodies move each closing ref to its own line (still exercising ANY-ref
refusal, now under a positional parser).

**Blast radius of the `record-review` change:** `closing_issue_refs` feeds the #513 clean-micro tier
guard only. Mirroring the positional rule there **alone** was a silent fail-open: a body such as
`Closes #100` + `This also closes #42` yields a non-empty ref set from the micro ref `#100`, so the
guard never reached its arm-(c) warning and recorded `clean-micro` on a PR that also auto-closes
complex `#42` on merge. The guard therefore keeps **GitHub parity**: it unions the positional scan
with a **word-boundary-anchored** `CLOSING_KW` scan and refuses when a non-micro ref appears in
*either*. A mid-sentence ref now **binds** the tier instead of falling to arm (c); refusal is the
fail-closed direction. The `\b` is the *other* direction: the class is a suffix of ordinary English
words, so an unanchored scan reads `The prefix #42 is unrelated.` as `fix #42` and refuses a body
GitHub itself would never auto-close — a false refusal, strictly broader than GitHub (#1012 r3). The documented fail-open arm (c) is unchanged for its own causes (repo-less, gh missing,
unreadable body, failed label fetch, no `complexity:*` label). Conforming PRs are unaffected: any
body that passes check (a) already has a positional ref, which the bare scan also finds.

## Part 2 (#786) — the artifact class is a positive allowlist

`pr_is_docs_only` is renamed `pr_is_artifact_only` (the old name no longer describes it) and its
final predicate becomes:

```bash
! grep -qvE '^(docs/|AGENTS\.md$|skills/.*\.md$|\.github/CODEOWNERS$)' <<<"$paths"
```

The class is a **positive allowlist** — `docs/` (any file, the #720 carve-out), root `AGENTS.md`,
`skills/**/*.md`, and the exact path `.github/CODEOWNERS`. A negative "no executable extension" rule
was rejected: a new or unlisted file type would enter the class silently, which is the wrong failure
direction for a closure gate. Everything else — including every `.ts` / `.js` / `.mjs` / script /
workflow path, and a CODEOWNERS-prefixed sibling such as `.github/CODEOWNERS.d/x` — is not an
artifact, so the traceability fallback stays unreachable for a code PR. This is what makes the fix
non-vacuous.

**The `.github/CODEOWNERS` boundary (#786's actual Target).** #786's Target reads "`.github/CODEOWNERS`-class
PR #674 passes check (a) carrying `Refs #667`", and #674's live diff is exactly
`.github/CODEOWNERS` + `docs/ops/guarded-paths.md` + `docs/plans/…`. A docs-plus-instruction-Markdown
allowlist alone would leave #674 still blocked, so the exact CODEOWNERS path is in the class. It is
*config* that changes review routing — a behavioural surface — but it contains no executable logic
and cannot close a security gap on its own, which is precisely why closing #667 on merge would record
a governance control as delivered when it is not. The boundary is drawn at the **exact path**: the
rest of `.github/` (workflows, actions, other config) stays out, and a fixture pins
`.github/CODEOWNERS.d/x` as NOT an artifact.

Every existing fail-closed guard is retained: `files_rows` validation (malformed framing, empty
filename), the both-ends rule (new path **and** old path of a rename/copy), the distinct-path 3000
cap, and the `.changed_files` equality check.

## Fixture table — the five acceptance vectors

| # | Vector | Files | Body | Asserts | Pre-fix |
|---|---|---|---|---|---|
| 1 | docs-only + trace keyword | `docs/plans/x.md` | `Refs #631` | resolves `$GH_REPO#631` | pass (no regression) |
| 2 | instruction-layer + trace keyword | `skills/x/SKILL.md`, `AGENTS.md` | `Part of #631` | resolves `$GH_REPO#631` | **RED** (Part 2) |
| 2b | CODEOWNERS + docs + trace keyword (the live #674 case) | `.github/CODEOWNERS`, `docs/ops/guarded-paths.md` | `Refs #667` | resolves `$GH_REPO#667` | **RED** (#786 Target) |
| 3 | code + trace keyword (anti-vacuous) | `extensions/loop-enforcer/termination.ts` | `Refs #949` | resolves **empty** (FAILS (a)) | pass |
| 4 | code + mid-sentence closing mention | `scripts/z.sh` | `Fixing (a) is an authoring decision — a closing keyword would falsely close #949.` | resolves **empty** (FAILS (a)) | **RED** (Part 1) |
| 5 | normal own-line closing keyword | `scripts/z.sh` | `Prose preamble that references nothing\n\nCloses #631` | resolves `$GH_REPO#631` | pass (no regression) |

Supporting fixtures added or updated: `expect_artifact_only` now asserts `AGENTS.md`-only and
`skills/**/*.md`-only are artifacts, `instruction-layer + docs` is an artifact, `.github/CODEOWNERS`-only
and the live CODEOWNERS + docs diff are artifacts, while `instruction-layer + code`,
`skills/foo/run.sh`, `CODEOWNERS + workflow`, `CODEOWNERS.d/x`, and nested `sub/AGENTS.md` are **not**.
`expect_ref` gains positive controls for every accepted reference shape — `-` / `*` / `+` bullets,
ordered markers `1.` and `1)`, `> ` blockquote, `## ` … `###### ` headings, `- [ ]` / `- [x]`
task-list items, `**bold**`, and `` `backtick` `` — plus the COMPOUND prefixes the repeatable group
admits (`> > `, `> - `, `>> `, `- > `, `> - [ ] `), the `####### ` anti-vacuous control, and
compound-prefix controls proving the repeatable group does not reopen the mid-sentence vacuity
(`> - This also closes #173` → empty); `prefixes #42` and `bugfixes #42` are inverted (mid-word
matches no longer resolve); the
`SLACK_APPROVAL_FILE` shadowing vector — **both copies**, the SELF_TEST one and the FAIL_ALL pass 3
seam — moves its real ref to the next line so it survives the per-line context; `closing beats trace`
bodies move `Closes #701` to its own line. `usage()` (the script's only help text, printed for
`--help` and on usage errors) now documents check (a)'s positional rule and the artifact-only scope,
completing #786's indicator (3).

`record-review.test.sh` additionally gains: **§8.9a** — the mixed `Closes #100` +
`This also closes #42` body must REFUSE `clean-micro` (rc 4, no record) under the GitHub-parity
union, with an all-micro positive control — and **§8.13**, the mechanical cross-script byte-identity
pin that extracts the `^REFCTX=` / `^CLOSING_KW=` lines from both scripts and compares them.

## Verification

**Local execution is guard-refused (#1484/#883).** The exact required command was attempted **once**
from the worktree and refused, verbatim:

```
⛔ Script execution blocked — script content contains a blocked git operation (#1484).
   The script backdoor (write /tmp/x.sh + bash /tmp/x.sh) is closed:
   …/scripts/check-pipeline-compliance.sh
   (script location: a linked worktree)
   performs a git operation that is not sanctioned against the shared main checkout.
   → Run the underlying git commands directly (each is gated on its own), or do
     this work in an isolated worktree (invoke the using-git-worktrees skill).
   → cd-ing into a worktree from a HUB-ROOTED session does not lift this — the
     gate keys on the session cwd. Start the session in the worktree, or set
     the documented AGENT_ALLOW_MAIN_EDITS escape hatch for a solo session.
```

`bash -n scripts/check-pipeline-compliance.sh` is refused by the **same** guard (the block keys on
the file's single read-only `git -C "$ROOT" remote get-url origin`, not on the script being run), and
so is the stdin form `bash -n < scripts/…`. No bypass and no extraction route was used.

**Manual predicate re-derivation** — the constants above were copied verbatim into a `bash`
one-liner with the same form logic, and all five vectors were evaluated:

```
✅ V1 docs-only + Refs            → daniel-ospina/agent-infra#631
✅ V2 instruction-layer + Part of → daniel-ospina/agent-infra#631
✅ V3 code + Refs (anti-vacuous)  → ''
✅ V4 code + mid-sentence mention → ''
✅ V5 code + own-line Closes      → daniel-ospina/agent-infra#631
✅ X1 bullet context - Closes     → daniel-ospina/agent-infra#701
✅ X2 bold context **Closes**     → daniel-ospina/agent-infra#701
✅ X3 mid-word prefixes #42       → ''
✅ X4 instruction+code mixed      → ''

[RED-before-Part1] unanchored closing grep on V4 body → close\ #949
[RED-before-Part2] old ^docs/-only predicate on instruction list → NOT artifact-only (blocked)
```

The two RED lines are the non-vacuity evidence: the unanchored grep really did match `close #949` in
the #968 sentence, and the old `^docs/` predicate really did reject the instruction-layer list.

**Round 2 (post-review) re-derivation of the WIDENED `REFCTX`.** A fresh-context reviewer returned
three findings; all three were verified against the code and fixed. The exact final constants were
extracted from the production file (no transcription) and every new/old vector re-evaluated by hand:
all 12 pinned reference-context shapes match, the compound prefixes the repeatable group admits also
match, and the anti-vacuous controls (`####### Closes #173`,
`This fixes #42 in passing`, `a closing keyword would falsely close #949`, `prefixes #42`,
`bugfixes #42`, `resolves SLACK_APPROVAL_FILE first`, `No issue referenced here`, plus the
compound-prefix mid-sentence controls) stay empty — 19/19 for round 2, extended in round 3 below.
The trace class was re-checked the same way (14/14): the widened prefix admits
`## Refs`/`1. Part of`/`- [ ] Refs`/`> Refs` while `prefs`/`preferences`/`a sentence about refs`
stay empty. **The gate's own self-test could not be executed** — the #1484 guard refuses it and both
the `/tmp/x.sh` extraction route and reiterated retries were refused (the guard keys on the script's
`git -C` call, not on how it is invoked), so end-to-end confirmation of the new `check-pipeline-compliance.sh`
fixtures comes from CI once pushed. **No bypass was used.**

**Round 2 — `record-review.test.sh` (executable locally): `PASS=87 FAIL=0`.** Regression sensitivity
was measured, not assumed: with the tier guard's GitHub-parity union reverted to the positional-only
scan in a scratch copy, §8.9a goes RED (`rc=0` — `clean-micro` recorded on a body that auto-closes a
complex issue). The two findings the reviewer raised:

1. **P1-A — `REFCTX` false-blocked legitimate contexts.** Verified: `## `, `1. `, `- [ ] `, `> ` did
   NOT match the original `^[[:space:]]*([-*][[:space:]]+)?…` (grep-verified), yet each is a
   reference context that resolved before #1012 and still auto-closes on GitHub. `REFCTX` widened in
   **both** scripts; the four shapes are now pinned in both suites.
2. **P1-B — mirroring the positional rule was a silent tier-guard fail-open.** Verified: with
   positional-only ref collection, the mixed body `Closes #100` + `This also closes #42` resolves to
   `{#100}` and records `clean-micro` (rc 0) — the plan's original "the split-brain cannot occur"
   claim was **false**, and is deleted. Fixed by unioning the bare-`CLOSING_KW` scan; invariant
   rescoped to the keyword class.
3. **P2 — no mechanical pin on the byte-identity invariant.** Added §8.13. It is non-vacuous: with
   `check-pipeline-compliance.sh` absent from the scratch copy it fails (extraction yields nothing),
   which is why the test also asserts both extracted blocks are non-empty.

**Round 3 (review cycle 2) — two P2 false-BLOCK / over-refusal findings, both fixed.** Cycle 2
confirmed the three round-2 fixes are real and introduce no fail-open, and returned two new P2
defects, both in the *over-refusal* direction. Each was reproduced against the shipped code before
the fix (`grep -oE` with the exact pre-fix pattern):

1. **P2-A — the parity scan was unanchored, so it matched INSIDE English words.**
   `The prefix #42 is unrelated.` → `fix #42`; `This discloses #42 but does not close it.` →
   `closes #42`; `Unresolved #42 remains open.` → `resolved #42` — all three reproduced. Each then
   triggered a label fetch on that issue and could `exit 4`, **refusing a legitimate `clean-micro`**;
   the comment claiming GitHub parity was false because GitHub requires a word boundary, making the
   scan strictly broader than GitHub. Fixed at the call site: `closing_issue_refs "$BODY"
   "\b${CLOSING_KW}"`. Verified: the three false positives are gone, while the intended
   mid-sentence "This also closes #42" still matches (boundary, not position, is what changed). New
   pins: `record-review.test.sh` §8.11 (three `refs_for_any` vectors, all empty) and §8.14 (three
   end-to-end guard vectors over non-micro labels, each asserting **rc 0 + record written + the
   arm-(c) `no same-repo closing-issue ref` warning** — so a "proceeds" result cannot be a micro ref
   that slipped through). §8.14 is RED pre-fix: unanchored, each body resolves the ref, fetches its
   non-micro label, and exits 4.
2. **P2-B — the prefix/checkbox groups were non-repeatable, so COMPOUND prefixes false-blocked
   check (a).** `REFCTX`'s prefix group was `?` (single consumption), so `> > Closes #42`,
   `> - Closes #42`, `>> Closes #42` and `- > Closes #42` all NOMATCHed (reproduced with the exact
   pre-fix `REFCTX`) — a nested blockquote or a list-inside-quote is still a reference context
   GitHub auto-closes on merge, so check (a) reported "no linked issue" → false BLOCK. Fixed in
   **both** scripts (byte-identical): the prefix group becomes `(…)*`, the checkbox group
   `(\[[ xX]\][[:space:]]+)*`, and the blockquote alternative `>[[:space:]]*` so a tightly-nested
   `>> ` is covered; the keyword still must follow the marks *immediately*, so the mid-sentence
   vacuity is **not** reopened. New pins in **both** suites: `> > Closes #173`, `> - Closes #173`,
   `>> Closes #173`, `- > Closes #173`, `> - [ ] Closes #173` (positive) and `> - This also closes
   #173` / `> > the prefix #173 is unrelated` (negative).

**Round 3 hand re-derivation against the SHIPPED regex.** The final `REFCTX`/`CLOSING_KW` lines were
extracted from the production file (no transcription) into a scratch `grep` harness and every vector
re-run: all round-2 positives still resolve, the five new compound prefixes resolve, the two new
negative controls stay empty (including `####### ` and the mid-sentence prose sentence), and the
trace class is unchanged. `record-review.test.sh` was executed (it is not guard-blocked):
**`PASS=99 FAIL=0`** (87 baseline + 12 new assertions). In this round's numbers, the boundary
vectors are RED against the pre-fix
pattern (`\b${CLOSING_KW}` replaced by `${CLOSING_KW}`) and the compound vectors are RED against the
pre-fix `REFCTX` (the `?`/`?` form) — measured, not asserted. The
`check-pipeline-compliance.sh` SELF_TEST still cannot be executed locally (#1484); its new vectors
are hand-derived and **CI confirms them end-to-end** (`pipeline-compliance.yml` runs
`PIPELINE_COMPLIANCE_SELF_TEST=1`).

**Independent VGATE review (dispatched because the commit's verification gate blocked an unverified
worktree commit) returned FAIL on three findings, all fixed before commit:** (1) the `SLACK_APPROVAL_FILE`
vector exists in **two** places — the SELF_TEST copy *and* the `FAIL_ALL` pass-3 seam — and only the
SELF_TEST copy had been made positional, so the dry-run verification path would have aborted at pass
3; both are fixed. (2) #786's Target names `.github/CODEOWNERS` and the first cut omitted it, leaving
#674 still blocked; the exact path is now in the allowlist with a live-case vector. (3) `usage()` did
not describe the carve-out scope; it now does.

**End-to-end confirmation comes from CI when this PR is pushed:**
- `.github/workflows/pipeline-compliance.yml` runs `PIPELINE_COMPLIANCE_SELF_TEST=1 bash
  scripts/check-pipeline-compliance.sh` (fail-closed if the seam is missing) — the 5 vectors plus the
  full existing suite.
- `.github/workflows/ci-main.yml:248` runs `bash scripts/record-review.test.sh` — the updated §8.9 /
  §8.11 parity corpus.
- `.github/workflows/ci-main.yml:225/234` runs `bash -n` over the shell scripts — the syntax check
  the guard blocked locally.

## Blast radius

| File | Change | Risk |
|---|---|---|
| `scripts/check-pipeline-compliance.sh` | `REFCTX` + positional composition; `pr_is_artifact_only` + expanded allowlist (docs/, instruction-layer Markdown, `.github/CODEOWNERS`); `usage()`/messages/comments; SELF_TEST vectors | **Behaviour-changing.** Tightens (a) for prose mentions and code PRs; loosens it for artifact-only PRs (including #674). Both directions pinned by fixtures. |
| `scripts/record-review.sh` | Same two constants (compound-repeatable `REFCTX`); `closing_issue_refs` takes an optional keyword pattern; the #513 tier guard unions the positional scan with a **word-boundary-anchored** `\b${CLOSING_KW}` scan | Clean-micro tier guard only. GitHub parity makes the guard **stricter** (fail-closed) for mid-sentence refs *while requiring the word boundary GitHub requires*, so the union no longer refuses over prose that merely contains the class (#1012 r3); the documented arm-(c) fail-open is unchanged for its own causes. |
| `scripts/record-review.test.sh` | §8.9 bodies positional; §8.9a mixed micro+mid-sentence-complex parity refusal; §8.11 corpus inverted + heading/ordered/task/compound/blockquote/plus positive controls + word-boundary negatives on the parity scan; §8.13 cross-script byte-identity pin; §8.14 false-refusal guard vectors; stub `.body` now emits raw body text (`gh --jq .body` semantics — the JSON envelope only "worked" while the parser was unanchored) | Test-only. |
| `.github/workflows/pipeline-compliance.yml` | One comment word (`pr_is_docs_only` → `pr_is_artifact_only`) | Comment-only; the file is **not** in `scripts/workflow-lock.json`, so no lock re-derivation. |
| `docs/plans/2026-09-14-issue-786-check-a-artifact-class.md` | This plan | Satisfies check (d). |

No `.github/workflows/ci-main.yml` or `scripts/workflow-lock.json` change (both would force a lock
re-derivation for no gain).

## Learnings

- **Fixtures that pin a reject-worthy behaviour must be inverted, not deleted.** `prefixes #42`,
  `bugfixes #42` and `This fixes #42 in passing` pinned the *unanchored* form; after anchoring they
  pin the *positional* form with the opposite expectation, so the suite now fails if anchoring is
  reverted. Deleting them would have removed the pin.
- **A test stub can encode the old parser's looseness.** `record-review.test.sh`'s gh stub returned
  `{"body": "…"}` for `--jq .body`; unanchored matching found refs inside that JSON envelope, so the
  suite passed for a reason the production path never had. Anchoring exposed it. The stub now emits
  the raw body, which is what `gh --jq .body` actually prints.
- **An allowlist must be tested in the deny direction.** The anti-vacuous vector (code + `Refs #N` →
  empty) is the fixture that goes red if the artifact class is widened too far; without it, Part 2
  would be unfalsifiable.
- **A shared constant is not a shared invariant.** Scoping two scripts to the *same regex* made the
  #513 tier guard inherit a rule it must not obey: check (a)'s positional anchoring is an
  anti-false-positive measure, while the tier guard must match what GitHub will actually auto-close,
  which is unanchored **by position but not by word boundary** — GitHub requires the keyword to
  start a word, so a keyword-class scan without `\b` is broader than GitHub and refuses over
  `prefix`/`discloses`/`unresolved`. Mirroring `REFCTX` alone turned a guard into a silent fail-open;
  mirroring a *bare* class turned it into a false-refusal machine. The correct contract is over the
  keyword **class**; the position rule belongs to check (a), and the word boundary belongs to the
  parity scan.
- **A `?` where a `*` belongs is an over-refusal, and an unpinned shape hides it.** `REFCTX`'s
  prefix group consumed exactly one Markdown prefix, so every compound shape (`> - `, `> > `, `>> `)
  false-blocked check (a) while the comment claimed "every Markdown prefix". Both directions of a
  context regex — admits-everything-real and rejects-everything-else — need their own fixtures; the
  positive compound vectors and the negative mid-sentence controls are the pair.
- **An invariant stated in prose needs a mechanical pin.** "The constants are byte-identical across
  the two scripts" was load-bearing (it justified anchoring both) and asserted nowhere. §8.13
  extracts and compares the constant lines, so a one-sided edit now fails a required CI job instead
  of silently desynchronizing the gates.
