---
title: "Plan: #1348 — the clean-low verdict: a content-only shape check at record time"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-22
aboutSubjects: epistemic-team
aboutObjects: agent-infra, issue-1348, record-review, review-enforcer, proportional-gates, code-review, commit-workflow, tortoise-4755
---

# Plan — agent-infra #1348: the `clean-low` verdict

> Status: scoped (revised after the problem-verify + solution-verify gate; all P0/P1s addressed).
> Adversarial domain (gate/enforcement code) — bound 2 cycles.

## Confirmed problem

`record-review.sh` accepts exactly two verdicts (`scripts/record-review.sh:166-168`). A PR whose diff
is genuinely content-only (prose / stylesheet) but whose linked same-repo issue is
`complexity:standard` or `complexity:complex` can record **neither honestly**:

- `clean` records fine but attests *"a code-review skill convergence recorded its clean verdict"* —
  a review that, per `proportional-gates`' Low row (1 reviewer, no cycle loop), did not happen.
  Recording it is a false attestation, not merely a shortcut.
- `clean-micro` is refused (exit 4) by the #513 tier guard (`:245-320`), because the guard reads the
  *linked issue's* tier, not the *diff's* shape.

So `proportional-gates`' Low row has **no representation in the gate**. That is a real correctness
defect: the gate offers a well-behaved PR an *untrue* certificate as its only exit.

### Framing that the issue body does not state — the dominant cause is different

The 71-PR deadlock is **not** caused mainly by the verdict-space gap. Measured on
`daniel-ospina/tortoise` open PRs (command below, 2026-09-22):

| Measure | Count |
|---|---|
| open PRs | 70 |
| fail `ai-review-gate` and nothing else | 27 |
| of those, content-only under this plan's Low class | **4** |
| content-only overall | 7 |

For a **code-bearing** PR, `clean` is both honest and available — the review simply has to run. So
the dominant cause of the queue stall is *no verdict is being recorded*, not *no honest verdict
exists*. `clean-low` is a **correctness fix that unblocks ≤4–5 PRs**; it is not the queue drain.
Stated plainly so "clean-low closes the deadlock" is not an overclaim.

Measurement command:
`for pr in $(gh pr list --repo daniel-ospina/tortoise --state open --limit 100 --json number --jq '.[].number'); do …; done`
(compare `…/compare/$base...$head` files → Low class; `gh pr checks` → failing set).

### Corrections to the issue body's premises — both [validated]

- **[validated]** *"the linked same-repo issue must carry `complexity:low`"* — **no `complexity:low`
  label exists** in `daniel-ospina/agent-infra` or `daniel-ospina/tortoise` (`gh label list` → only
  `complexity:micro|standard|complex`). The crosswalk in `skills/proportional-gates/SKILL.md:91` maps
  `micro → Low`, so a *label* arm is dead on arrival — and labels are agent-writable, so it would
  also be attacker-controlled. The operative arm is **content shape**.
- **[validated]** the blocked population is mostly **code-bearing** (PR `#4747` 6 non-doc files,
  `#4729` 3/3, `#4728` 4/4) and most linked issues carry **no** `complexity:*` label at all.
- **[unverified]** that the 71-PR queue would drain at all once a verdict exists — 7 of 70 are
  content-only, and some content-only PRs are also blocked on other checks.

## Chosen solution: `clean-low` (option a, narrowed)

A third verdict. It attests:

> the Low risk row of the canonical tier table applies to this diff — every changed path is prose or
> a stylesheet (no program code, no config file, no enforcement input). The shape is the whole
> VERIFIABLE attestation: the Low row's single reviewer pass is the caller's obligation, and the
> guard cannot observe it.

Its guard is **content-shape and fail-CLOSED on every arm**: the content shape *is* the entire
attestation, so "could not verify" must never read as "certified Low". This is the decisive
difference from `clean-micro`, whose fail-open arm is safe because the label is a *cross-check* on a
micro flow that already ran its own pre-flight and dispatch floor.

### Rejected alternatives

- **(b) gate derives required evidence from the tier and accepts no record for Low.** Makes the last
  gate *infer* rather than *require* evidence, with no tier read in `evaluateMergeGate` and no label
  available at the remote check. Evidence-absent-is-pass is the #1319 defect class. Rejected.
- **(c) require the full review ceremony for every PR including content-only.** Contradicts
  `proportional-gates`' core principle and is unreachable at ~70 PRs vs ~12 lanes. Rejected.
- **Make `clean-micro` read the diff shape instead of the issue label (no new verdict).** Genuinely
  attractive — no remote-regex change needed. Rejected because a content-only PR on a non-micro
  issue recording `clean-micro` is refused *downstream* by the #513 binding
  (`scripts/check-pipeline-compliance.sh:916` → `fail c`), so this "no new verdict" option in fact
  requires weakening a separate deliberate fail-closed guard. Recorded so a later lane does not
  "simplify" `clean-low` back into `clean-micro`.
- **Widen `clean`'s documented attestation to cover the Low row (one verdict, no companion change).**
  Rejected: `clean` is the machine-readable token the required check and the merge gate branch on;
  collapsing two different attestations into one token destroys the ability to audit *which* review
  happened, and re-creates exactly the false-attestation defect this issue is about.
- **`complexity:low` label arm.** Label does not exist; labels are agent-writable. Dead + unsafe.
- **Reusing `pr_is_artifact_only` (check a, `:709`) or `isShapeExemptFile` (VGATE, `:759`) as the
  class.** Reusing another gate's class changes that gate's semantics; copying its regex creates a
  second writer of that contract that drifts silently. `clean-low` declares its own, deliberately
  narrower, positive allowlist, and the divergence is documented at the definition.

## Low class (the whole predicate)

A changed path is Low **iff** one of:

1. **`docs/` + a content extension, exactly one level or deeper:**
   `^docs/[^/].*\.(md|markdown|txt|rst|adoc|css|scss)$`
2. **a root-level inert prose file, by exact basename** (not by extension):
   `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`

and, for both, the path contains no `\n`, `\r`, `\t`, or NUL; does not start with `/` or `~`; and
contains no `..` segment, no `.` segment, and no empty segment.

The allowlist is **structural and anchored**, so enforcement inputs cannot ride in on an extension
argument: `.github/workflows/ai-review-gate.yml`, `scripts/record-review.sh`,
`extensions/review-enforcer/index.ts`, `skills/code-review/SKILL.md`, `templates/**`,
`pi-bootstrap/**`, `.pi/**` are all refused (not under `docs/`, not a listed root basename) —
without needing a deny rule that extension reasoning could re-open.

**`.mdx` is deliberately excluded** (it compiles JSX to JS, so it *is* build-consumed program code).
`.html` is also excluded. The attestation wording therefore does not claim "non-executable"; it
claims **prose/stylesheet content, not build-consumed program code**.

**Deliberately narrower than `proportional-gates`' Low row** (which reads "Docs, **config**, CSS,
**strings** only"): config and i18n strings can change runtime behaviour — the issue's own `#4708`
CSP regression *is* a config change. Root `requirements.txt` / `constraints.txt` are build inputs and
are excluded for the same reason.

**OVERRIDES:** `proportional-gates` §Change Classification → the `Code impact` column's **Low** value
("Docs, config, CSS, strings only") — the `clean-low` class admits prose and stylesheets only, never
config or strings, because a config change is where a runtime-behaviour change hides and this verdict
is a merge attestation. (Anchor named exactly: the string quoted is the Code-impact COLUMN's Low
value. The §Review Cycles table's Low ROW — 1 reviewer, no cycle loop — is a different artifact in the
same file; conflating them is what makes such a marker hard to find.)

## Adversarial Threat Surface

Correctness claim: **a `clean-low` record cannot be obtained for a revision whose diff is not
provably content-only.** Exit codes: `2` = bad arg or incompatible flag/verdict combination; `4` =
shape guard refused, **no record written** (neither `<owner>-<repo>-<pr>.json` nor the legacy
`<pr>.json`), no marker PATCHed. Object under test: `scripts/record-review.sh`.

### In scope — each class covered by a test that is RED against the pre-change script

| # | Class | Adversarial input | Required behaviour |
|---|-------|-------------------|--------------------|
| C1 | Code-bearing diff | `src/app.ts`; `package.json`; `requirements.txt` | refuse, exit 4, no write |
| C2 | Enforcement input | `scripts/record-review.sh`, `extensions/review-enforcer/index.ts`, `.github/workflows/ai-review-gate.yml`, `skills/code-review/SKILL.md`, `templates/AGENTS.base.md`, `AGENTS.md`, `MEMORY.md`, `VENDOR.md`, and `docs/evil.sh` (enforcement-looking content under a docs prefix) | refuse, exit 4, no write |
| C3 | Unverifiable shape | `gh` absent; repo undetectable; PR read failure; compare failure; **fork-PR 404**; empty file list; file list at the 300-entry compare cap; distinct-path count ≠ `.changed_files` | refuse, exit 4, no write (**fail-CLOSED**) |
| C4 | Revision mismatch | `clean-low` with `--force-stale`; `clean-low` at a sha ≠ current head | **exit 2** for the flag/verdict combination (named message); exit 4 when the head cannot be confirmed equal to the recorded sha; no write |
| C5 | Path-shape spoof | `notes.md.ts`; `docs/x.md.bak`; `docs/../src/a.ts`; `docs//x.md`; `/docs/x.md`; `docs/.`; a split row (`docs/a.md\tscripts/evil.sh`) | refuse, exit 4, no write. **Not** a filename carrying a real `\n`/`\t`: `jq @tsv` ESCAPES those, so the row arrives with a literal `\n` inside an in-class path and is ADMITTED (declared, pinned by a test). The control-character arms stay as defence in depth for a raw-row caller — the sibling gate builds rows with a raw template, where they ARE live. |
| C6 | Row-framing / old path | `renamed` `scripts/evil.sh` → `docs/evil.md`; `copied`; a row whose `previous_filename` is outside the class; a row with `NF != 3`; an unknown status enum | refuse, exit 4, no write (both ends of every row) |
| C7 | Local merge gate | a `clean-low` record whose head has advanced; a non-`clean-low` verdict; a `clean-low` record on a mismatched head; a matching `clean-low` record | with a **verifiable head**, `evaluateMergeGate` allows **only** the head-AND-base-matching `clean-low`; every other case blocks with the right audit reason — `clean-low` gets the same head binding as `clean`, PLUS the base binding below. (Two pre-existing paths allow a merge without a verified head: the #138 **interactive** fail-open when the head cannot be fetched, and a hand-minted record — both disclosed below, both identical for `clean`/`clean-micro`, neither introduced here.) |
| C8 | **Content swap (base repoint)** | `clean-low` + `gh pr edit --base main` after recording; a `clean-low` record with no or invalid merge base; an unreadable merge base | the attestation is the three-dot diff `compare/<base>...<head>`, whose content is identified by the MERGE BASE. The record pins `merge_base_sha`; `evaluateMergeGate` blocks with `base_advanced` on a mismatch and `base_unverifiable` when either side cannot be read — fail-CLOSED, both. A BENIGN advance of the base branch must NOT block (the merge base is invariant under it) — that false block is why the binding is the merge base and not `.base.sha`, and it is pinned by its own test. `clean`/`clean-micro` stay merge-base-blind (declared, #1362). |

### Out of scope — declared, with reason

| Class | Why out of scope |
|-------|------------------|
| A docs change that ALSO adds a non-prose file under `docs/` (`.png`, `.json`, `.csv`, `.svg`) | The class is an extension ALLOWLIST, so an inert asset or data file is refused too. Deliberate, and DISCLOSED at the refusal site rather than left silent: widening the allowlist adds exactly the config/data ambiguity the class exists to exclude, and the honest fallback (`clean` via the review skill) is named. Measured on the open tortoise queue: 8 docs-only PRs admitted, 2 refused — one correctly (`docs/**/*.sh|*.py`), one over-strictly (`docs/scoping/receipts/*.json`). `pr_is_artifact_only` went the other way (`docs/**` wholesale) with its own recorded rationale; the divergence is deliberate. |
| Symlink (mode 120000) / gitlink (160000) at a docs path | The endpoints the guard uses (`pulls/{n}`, `compare`) do not expose blob modes. Detecting this needs a mode-bearing tree walk — a change with its own surface. **Filed: agent-infra #1355.** |
| A served repo packages or consumes a `docs/**` file as build data | The class is PATH+EXTENSION based and deliberately does not consult a build graph the guard cannot read. Tortoise declares `../docs/EXPANSION_PACKS.md` under `[tool.setuptools.package-data]`, so a change to that doc alters a shipped artifact. The guard's attestation wording was NARROWED to stop overclaiming (it now says "prose or a stylesheet", not "no build-consumed artifact"); the class itself is unchanged. |
| Diff-keyed staleness / carry-forward | tortoise #3057 / #2982. Orthogonal: `clean-low` stays head-bound. |
| `complexity:low` label arm | Label does not exist (verified) and labels are agent-writable. |
| Config / i18n-strings under `proportional-gates`' Low change-classification cell | Deliberate departure; see the `OVERRIDES:` line. |
| Remote re-verification of content shape in the GitHub workflow | The workflow must never check out or execute PR code; it verifies marker shape + HMAC + head only. |
| `check-pipeline-compliance.sh` check (c) re-deriving the clean-low shape | Check (c) is a **presence-of-evidence** check, not an authenticity check: `has_review_evidence` (`:291`) matches `review recorded` generically, and that file contains no HMAC/key verification at all. A hand-pasted `verdict=clean` line already passes it. The #513 clean-micro binding (`:916`) exists for a *different* reason — micro skips checks b–e, so that binding protects a **tier exemption**; `clean-low` grants no exemption (a standard/complex issue still runs b–e). Re-deriving the shape at check (c) means a second writer of the class contract. **Residual recorded: check (c) accepts a `verdict=clean-low` body line on a code-bearing diff, unverified. Filed: agent-infra #1356.** |
| Unifying the three existing content-shape classes | Pre-existing divergence, documented at the new definition. Not a fail-open; folded into #1356. |
| Draining the queue | Operational, not this unit. |

### Deliberate residuals, disclosed

- **The remote required check is still base-blind, for every verdict.** The local gate is
  base-bound for `clean-low` (C8); the signed MARKER is not, and cannot be until the consumer
  compares a `base=` field. That requirement is now a scope addition on the widening issue,
  **daniel-ospina/tortoise#4755**. A base-edited PR can therefore still satisfy the remote required
  check on any verdict, `clean-low` included.
- **`clean`/`clean-micro` records carry no base at all**, locally or remotely: their base-blindness
  is pre-existing and **filed as agent-infra #1362** rather than silently widened by this change.
- **Both gates are forgeable by a local actor.** The HMAC key is readable by any local process
  (`~/.pi/agent/.ai-review-gate-key`), so a **signed** marker for any verdict, `clean-low` included,
  is mintable locally. This is pre-existing, and it is why the producer guard — not "the remote check
  is unforgeable" — is the sole place the shape is verified. `clean-low`'s specific effect: it widens
  the accepted verdict set (with the tortoise #4755 regex change) **without** remote shape
  verification.
- **A hand-minted local record does not require a signed marker.** Writing
  `~/.pi/agent/reviews/<owner>-<repo>-<pr>.json` by hand satisfies the *local* command gate; the
  record and the marker are two different mechanisms and this gate does not merge them. Pre-existing
  for all three verdicts; the local gate deliberately does not re-derive the shape (see C7).
- **`evaluateMergeGate`'s #138 interactive fail-open is untouched.** When the head cannot be fetched
  and the session is interactive, the gate allows the merge with a warning — for `clean-low` exactly
  as for `clean`/`clean-micro`. Task sub-agents are fail-closed (`currentHead === null` → block).
  Pre-existing; disclosed because C7's "every other case blocks" would otherwise read as a stronger
  claim than the code makes.
- **Symlink / gitlink** — agent-infra #1355.
- **A repo may package a `docs/**` file as build data** — the class is path+extension based; the
  attestation wording was narrowed rather than the class widened.
- **Fork PRs** whose head sha is not reachable from the base repo: `compare` returns 404 → exit 4.
  A predictable **false block**, in the fail-closed direction. Recorded so it is not re-diagnosed as
  a bug; vector C3 covers it.

## Change set

**agent-infra (this unit):**

1. `scripts/record-review.sh` — `clean-low` + the fail-closed shape guard. `clean`'s zero-extra-call
   property and `clean-micro`'s behaviour stay byte-unchanged. Guard implemented as
   **source-reachable pure functions** (`clean_low_path_ok`, `clean_low_rows`, `clean_low_shape_ok`)
   so the suite can unit-test the predicate and mutate it.
2. `scripts/record-review.test.sh` — one vector per class C1–C6 (RED pre-change), the positive
   (GREEN) vectors, and a **mutation harness** proving the guard is load-bearing.
   **Harness work required:** stub arms for `.base.sha`/`.changed_files` and for `compare/…`, plus
   env-keyed file-list / changed_files / failure controls. The existing stub (`:44-84`) had only
   `.head.sha`, `.body`, `.[].name` and a catch-all, so the compare read fell through; it now carries
   `.base.sha` / `.changed_files` / `compare/...` arms.
   `@tsv` is a STRONGER row source than the sibling gate's raw jq template: it ESCAPES `\t`/`\n`,
   so the control-character arms are DEFENCE IN DEPTH here, not live arms — the escaped form is
   admitted as in-class and is pinned by a test, and those two vectors are NOT counted as RED
   coverage. No fail-open (the escaped form is still a `docs/**` prose path in the real tree, and the
   raw-row splitting attack the arms defend against is impossible under `@tsv`). `files_rows` builds
   rows with a raw template, where the same arms ARE live — which is why this guard does not share
   that class.
3. `extensions/review-enforcer/index.ts` — accept `clean-low` at **both** verdict sites through ONE
   exported vocabulary (`ACCEPTED_VERDICTS` / `isAcceptedVerdict`), and the refusal text is DERIVED
   from that list rather than re-literalised. No local content re-check (the record is the
   attestation). Adds the **base binding** for `clean-low` (record `base_sha` vs the PR's current
   base, refused with reason `base_advanced`).
4. `extensions/review-enforcer/index.test.ts` — the C7 + C8 vectors (this is the suite that covers them).
5. `skills/code-review/SKILL.md` — Step 10b beside Step 10a; `skills/commit-workflow/workflow/`
   `03-code-review.md` + `04-merge-deploy.md` — the verdict-by-tier sentence.
6. `skills/proportional-gates/SKILL.md` — cite the class; the Low row's wording is unchanged.

**companion (separate repo, separate unit):**

7. `daniel-ospina/tortoise` `.github/workflows/ai-review-gate.yml` — `sha_ok_re` and the `all_lines`
   classification grep hardcode `verdict=clean(-micro)?`, so a signed `clean-low` marker fails the
   required check. Filed as a companion issue with the exact patch. **#1348 is not fully landed for
   the remote check until that lands** — stated plainly rather than papered over.

## Axis Research

> **Trigger assessment:** axes all low-to-medium with in-repo precedent for every mechanism; no
> third-party dependencies; no novel pattern. Precedent: the `clean-micro` verdict + its tier guard
> (`scripts/record-review.sh:241-320`), the `files_rows` row validator and `pr_is_artifact_only`
> positive-allowlist pattern (`scripts/check-pipeline-compliance.sh:644-730`), `isShapeExemptFile`'s
> build-output-segment idea (`extensions/verification-gate/index.ts:759-769`), and the source-reachable
> guarded-main pattern already used for cross-script pins (`scripts/record-review.test.sh` §8.13).
> No external research demonstrated — skipped per the activation rule.

## Verification

- `bash scripts/record-review.test.sh` — full suite. **Observed: `PASS=247 FAIL=0`.**
- `NODE_ENV=test npx tsx extensions/review-enforcer/index.test.ts` — **observed: `181 passed, 0 failed`.**
- `bash scripts/check-no-sigpipe-grep.sh` + `bash tests/sigpipe-grep/run.sh` (the suite's own
  #841 guard caught two `printf | grep -q` sites in this change; they are here-strings now).
- `node scripts/check-skill-lint.mjs --skills-dir skills`; `npx tsx extensions/loop-enforcer/tier-config-parity.test.ts`;
  `bash tests/drift/run.sh`; `bash scripts/check-pi-config-extensions.sh`.
- `node scripts/check-doc-affiliation.cjs --files docs/plans/2026-09-22-issue-1348-clean-low-verdict.md`
  (this plan doc needs its frontmatter block — it failed this gate until the code-review cycle added it).
- `PIPELINE_COMPLIANCE_SELF_TEST=1 bash scripts/check-pipeline-compliance.sh` (the env-var form — the
  script takes a numeric `PR_NUMBER` positionally, so `--self-test` is rejected).

### RED-pre-change evidence

- The new suite against `git show origin/main:scripts/record-review.sh` (pre-change): **`PASS=171 FAIL=76`** —
  every declared class has failing vectors (C1 5, C2 11, C3 14, C4 3, C5 10, C6 6), and at least one
  (C4 `--force-stale`) fails on the guard's NAMED message rather than on rc (pre- and post-change the
  verdict `case` refuses with rc 2 there), so the discriminator is demonstrated to be the guard, not
  the `case`.
- **Mutation harness (in-suite, durable, §10.9 + the C7 pin):**
  | Mutation | Result |
  |---|---|
  | replace the guard call with `true` | **54 failures** — the guard is load-bearing |
  | revert the verdict arm to `clean|clean-micro)` | the positive vector goes rc 2 — RED pre-change |
  | accept `copied` rows | **3 failures** (C6) |
  | delete the truncation detector (main validation + both arms) | **6 failures** (C3) |
  | stop writing the merge base in the record | **1 failure** (the content-bound positive vector) |
  | certify the diff against the HEAD instead of the BASE | **1 failure** (the compare-argv assertion) |
  | drop the `command -v gh` disjunct from the clean-low guard | **1 failure** (the gh-absent vector) |
  | neuter the `clean-low` content branch in `evaluateMergeGate` | **4 failures** (the C8 vectors) |
  | re-literalise the refusal message's verdict list | **1 failure** (the derivation pin) |
  The last five were found by review as **silent** mutations (the first version of the drift pin was
  itself too weak, and the first version of the gh-absent vector passed for the wrong reason); each is
  covered now. Every one of these
  was verified by mutation, not by assertion — a test that passes before the change proves nothing.
- C7/C8's RED evidence is **structural, not behavioural**: pre-change, `index.ts` exports neither
  `ACCEPTED_VERDICTS` nor `isAcceptedVerdict` and has no base branch, so the suite fails at import with
  0 tests run. The durable complement is the in-suite **drift pin**: the pre-change expression
  (`record.verdict !== "clean"`) and any re-listing of the vocabulary outside the declaration are
  asserted ABSENT, and both verdict sites are asserted to consult `isAcceptedVerdict`.

## Acceptance

Every declared in-scope class C1–C6 (record-review suite) and C7–C8 (review-enforcer suite) covered by
a test that fails against the pre-change code, plus green CI. C3's fork-404, the symlink/gitlink gap
(#1355), the check-(c) gap (#1356), the docs-as-build-data case, the inert-asset refusal, the
base-blindness of `clean`/`clean-micro` and of the REMOTE marker (#1362) are disclosed, not claimed as
covered. A fresh reviewer returning `THREAT SURFACE COVERED` closes the adversarial gate; the
code-review gate closes on its own reviewers' clean verdict.

## Review Cycle Log

### adversarial review — Cycle 1 (fresh context)
- Verdict: `ISSUES:` — 1 P2, 4 P3. **No in-scope bypass found**; every declared class C1–C7
  reproduced as covered, and the §10.9 mutation harness reproduced independently.
- Fixed: P2 attestation overclaim ("no build-consumed artifact" → narrowed); P3 two SILENT mutations
  (truncation detector, `copied` arm) — arm 1 made redundant + fail-closed, arm 2 removed as dead
  code, and both now have catching vectors; P3 plan `--self-test` invocation corrected; P3 false
  "filed" claims — the residuals are now genuinely filed (#1355, #1356); P3 C7 declaration softened
  and the #138 interactive fail-open disclosed.
- Cycle 2: re-review of the fixes (bound: 2).

### adversarial review — Cycle 2 (fresh context, the bound)
- Verdict: **`THREAT SURFACE COVERED`** — the domain's defined clean equivalent. All 6 fixes verified
  REAL by independent reproduction (mutation of the truncation detector → `FAIL=6`; `copied` mutation
  → `FAIL=3`; the old overclaim phrase absent; #1355/#1356 OPEN; the env-var self-test runs rc 0 and
  the flag form is rejected; the drift pin fails on a one-site revert, 158 passed/10 failed, with the
  control at 168/0). No in-scope bypass across a 58-candidate path corpus plus framing, count/cap,
  ordering and vocabulary attacks — every admission was in-class. No new defect in the new material;
  the count validation has one caller and adds no production false block.
- Weakest remaining point (accepted, declared): the class is path+extension based and does not consult
  a build graph. Residuals #1355, #1356 OPEN.
- Out-of-surface note, category B ("nothing but time"), not filed: the drift pin forbids two exact
  literal forms and counts `isAcceptedVerdict(record.verdict)` occurrences, so a third site using a
  different literalisation could evade the *text* pin. Any such site is in the more-restrictive
  direction, and the behavioural C7 tests exercise the gate end-to-end; this is machinery
  observability, not a fail-open.

### code-review gate — Cycle 1 (fresh context, 4 always-on reviewers)

Guidance, Bug (blind + deep passes), History/PR-comments, Security. Verdicts: **ISSUES** — one P1 and
nine P2s. The P1 and the material P2s, and their dispositions:

| # | Finding | Disposition |
|---|---|---|
| P1 | **The attestation was content-relative but the record pinned only the HEAD.** The guard reads `compare/<base>...<head>`; `gh pr edit --base main` after recording leaves the head sha unchanged, so the certified docs-only diff and the merged diff diverge — and the local gate allowed it. The reviewer reproduced it with real `git` three-dot semantics. | **Fixed — new class C8.** The record now carries the MERGE BASE (`merge_base_sha`, clean-low only) and `evaluateMergeGate` blocks with `base_advanced` / `base_unverifiable`; fail-CLOSED on an unreadable base. 6 vectors + 3 mutations. The remote marker stays base-blind → the requirement is a scope addition on **tortoise#4755**; `clean`/`clean-micro` base-blindness → **#1362**. |
| P1 (found by cycle 2) | **The first C8 fix pinned the base branch's TIP (`.base.sha`), which is the wrong signal in both directions**: it moves on every unrelated merge into the base branch (so every clean-low record would expire within minutes and false-block the merge it was minted for) while still not identifying the certified content. | **Fixed** — bind the MERGE BASE, which is invariant under a benign advance and moves exactly when the base is repointed or rewritten. The benign-advance case now has its own test (it would have failed against the tip-binding) and the compare-base argv is asserted so the two sides are demonstrably reading the same revision. |
| P2 | The plan doc has no YAML frontmatter → `check-doc-affiliation.cjs` FAILS (a real pre-flight gate, under-run by me). | Fixed (frontmatter added); the gate is now in the verification list. |
| P2 | The refusal message hard-codes the verdict list, so the drift-pin comment's "the two decision sites are consulted" overclaimed single-source-of-truth. | Fixed: the message is DERIVED from `ACCEPTED_VERDICTS`, and the pin was STRENGTHENED to forbid any line outside the declaration from naming two or more verdicts. |
| P2 | The two control-character arms are **unreachable on the guard's own path** — `jq @tsv` escapes `\t`/`\n`, so C5's "filename containing `\n` or `\t`" is admitted, not refused; the direct-predicate vectors cannot exercise it. | Declared, not papered over: C5 corrected, the arms kept as defence in depth with the reason, a test pins the escaped-admit behaviour, and those vectors are NOT counted as RED coverage. No fail-open. |
| P2 | `clean_low_rows`' header claimed framing parity with `files_rows` on the status enum — false for `copied`. | Fixed (comment states the one divergence). |
| P2 | The header said both "the Low row's single reviewer pass ran" AND "the content shape IS the whole attestation" — the guard observes no dispatch. | Fixed: the reviewer pass is named as the caller's obligation, unobservable here. |
| P2 | "`./*.md` would admit `.github/…`" — factually wrong illustration. | Fixed. |
| P2 | §10.15 cited for a §10.9 harness. | Fixed. |
| P2 | "docs/ or a stylesheet" understated the class (5 root prose basenames) at 4 sites — a `README.md`-only PR was told the verdict did not apply to it. | Fixed in 03-code-review.md + all three remediation messages + Step 10b. |
| P2 | The head-advanced advice told a `clean-low` holder to "re-record at the SAME verdict" — unsatisfiable, since a moved head with code is refused (exit 4) by the guard. | Fixed: the advice branches on verdict; `clean-low` re-derives the shape. Pinned by a test asserting the tier-bearing verdicts KEEP the same-verdict advice. |
| P2 | A docs change that also adds an inert asset/data file is refused, and the exclusion was silent. | Disclosed at the refusal site + Step 10b, with the honest fallback named; the class stays an allowlist (widening it re-imports the config ambiguity it excludes). |
| P2 | `clean-low` is **inert in tortoise** until the consumer widening lands — the remediation text recommended it unconditionally, so the agent would fall back to recording a false `clean`. | Fixed: `record-review.sh` warns on stderr at record time (same posture as the existing missing-HMAC-key warning), Step 10b documents the dependency, and the requirement is on tortoise#4755. |

| P2 | The plan's own "It attests" blockquote still carried the "single reviewer pass ran" overclaim after the script header and Step 10b were corrected. | Fixed (the plan is the declaration — it must not be the last place the overclaim survives). |
| P2 | The `OVERRIDES:` anchor named `§Pre-flight Verification / Low row`, but "config, strings" is the Low COLUMN value of §Change Classification's `Code impact` row — a section with no such wording, so a future adopter would look in the wrong place. | Fixed in all three copies (plan, `record-review.sh`, and a correction comment on issue #1348), with the two tables in that file explicitly distinguished. |
| P1 (found by cycle 2) | The remediation lines read `record-review.sh <PR> <head_sha> [owner/repo]` — but position 3 IS the verdict, so a literal run either exits 2 (repo parsed as a verdict) or, without the bracket, DEFAULTS to `clean` and mints exactly the false attestation this verdict exists to remove. | Fixed: every advice/refusal line now names the verdict explicitly, with the `clean` fallback on its own line; a test asserts both tokens are present. |
| P2 (found by cycle 2) | `getPrMergeBaseSha` (then `getPrBaseSha`) had zero test coverage, and the `declared boundary` test could not fail for the property it named; the vocabulary-consistency loop was unfalsifiable; `tempAuditFile` leaked a directory per call. | All fixed: 5 I/O unit tests (validation, GH_REPO env, no `--repo`, null mappings, no-call-on-bad-head), the boundary test now asserts an observable (zero gate-issued API calls + no producer predicate imported), the vocabulary test asserts against a literal and a behavioural derivation pin, and audit temp dirs are removed at exit. |

### code-review gate — Cycle 2 (fresh context)

Skill-infrastructure, extension-safety, ontology/templates and test-quality reviewers, plus a focused
adversarial verifier on the NEW C8 class and on the Cycle-1 fixes. Verdicts: **ISSUES** — 3 P1 and ~15
P2, all in evidence quality or documentation rather than in the gate's correctness. The reviewer
independently reproduced every declared class, reproduced the C8 mutation, and found **no in-scope
bypass**. Findings and dispositions: see the table above (the P1s are the base-TIP binding, the
non-executable remediation, and the unpinned compare-base argument).

One process point, recorded because it changed what the reviewers reviewed: cycle 2 ran against the
WORKING TREE while the pushed head (`ecb5803`) still lacked the C8 work. A reviewer reading
`gh pr diff` sees a different artifact from the one the plan describes — so the fixes are committed
and the review re-recorded at the new head before the gate closes.
