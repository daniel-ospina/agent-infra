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
| `record-review.sh::closing_issue_refs` | cross-script mirror | `record-review.test.sh` §8.9, §8.11 | clean-micro tier guard; byte-identical constants |
| `.github/workflows/pipeline-compliance.yml` | CI wiring | the CI run | runs the self-test (already wired by #991) |

**Bug pattern flags:** the carve-out is an allowlist, so *widening it too far* is the risk this plan
must defeat with a fixture, not with prose. The positional regex must stay byte-identical across the
two scripts, or `record-review`'s tier guard binds refs check (a) no longer accepts.

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
a Markdown bullet or emphasis/bold/backtick marker.

```bash
REFCTX='^[[:space:]]*([-*][[:space:]]+)?[*_`]{0,3}[[:space:]]*'
CLOSING_KW='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'
TRACE_KW='\b(ref(s|erences?)?|part[[:space:]]+of|advance(s|d)?|track(s|ed)?|relates?[[:space:]]+to)'
```

`parse_issue_ref` composes `kw="${REFCTX}${kwpat}"`; the accepted forms (full URL, `owner/repo#N`,
bare `#N`) are unchanged — only the context the keyword sits in is constrained. `parse_trace_ref`
delegates to the same function, so the trace class is positional too (fail-closed direction: it can
only *deny* the fallback, never widen it).

### The decision to anchor — and the cross-script contract

`parse_issue_ref` is documented as byte-identical to `record-review.sh::closing_issue_refs`, and
`record-review.test.sh` §8.11 pins the shared parser corpus (including, until now,
`"This fixes #42 in passing"` asserting a match — the unanchored narrative-prose class).

Two options were available:

| Option | Verdict |
|---|---|
| (a) Anchor both scripts (compose the same two constants in each) | **Chosen.** The documented invariant stays true, and the split-brain — a ref binding the clean-micro tier but not check (a), or vice versa — cannot occur. |
| (b) Anchor only the compliance script and explain the divergence | **Rejected.** The byte-identity claim and §8.11 would become false statements pinned by a suite that still asserts the old class. Removing a stated invariant to avoid a two-line change is the wrong trade. |

`REFCTX` and `CLOSING_KW` are now defined as top-level constants in **both** scripts with byte-identical
values; `record-review.sh::closing_issue_refs` sets `kw="${REFCTX}${CLOSING_KW}"`, mirroring
`parse_issue_ref`. `record-review.test.sh` §8.11 is updated in the same change: the mid-sentence
mention vector is inverted (it must now resolve to nothing) and a bullet-context positive control is
added, so the parity corpus pins the *new* contract rather than rotting on the old one. §8.9's
multi-ref bodies move each closing ref to its own line (still exercising ANY-ref refusal, now under a
positional parser).

**Blast radius of the `record-review` change:** `closing_issue_refs` feeds the #513 clean-micro tier
guard only. A PR body with a mid-sentence closing keyword no longer binds the tier, so the guard
falls to arm (c) — the documented fail-open with a loud warning. Conforming PRs are unaffected: any
body that passes check (a) now has a positional ref, which the tier guard sees identically.

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
`expect_ref` gains bullet / `*` bullet / `**bold**` / `` `backtick` `` positive controls;
`prefixes #42` and `bugfixes #42` are inverted (mid-word matches no longer resolve); the
`SLACK_APPROVAL_FILE` shadowing vector — **both copies**, the SELF_TEST one and the FAIL_ALL pass 3
seam — moves its real ref to the next line so it survives the per-line context; `closing beats trace`
bodies move `Closes #701` to its own line. `usage()` (the script's only help text, printed for
`--help` and on usage errors) now documents check (a)'s positional rule and the artifact-only scope,
completing #786's indicator (3).

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
| `scripts/record-review.sh` | Same two constants; `closing_issue_refs` composes them | Clean-micro tier guard only; non-conforming bodies fall to the documented fail-open arm (c). |
| `scripts/record-review.test.sh` | §8.9 bodies positional; §8.11 corpus inverted + positive control; stub `.body` now emits raw body text (`gh --jq .body` semantics — the JSON envelope only "worked" while the parser was unanchored) | Test-only. |
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
