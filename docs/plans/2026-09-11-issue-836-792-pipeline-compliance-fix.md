---
title: "#836 + #792 — one PR: pin the pipeline-compliance broken-pipe fix with a deterministic regression test, and detect the artifact miss at preflight"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-11
updated: 2026-09-12
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-836, issue-792, issue-716, issue-823, issue-745, issue-488, pr-751, check-pipeline-compliance, commit-workflow, pipeline-compliance
---

# Issues #836 + #792 — the `pipeline-compliance` gate: pin the broken-pipe fix, and detect the miss earlier

**Issues:** [#836](https://github.com/daniel-ospina/agent-infra/issues/836) (bug) ·
[#792](https://github.com/daniel-ospina/agent-infra/issues/792) (improvement, `complexity:standard`)
· **Complexity:** standard · **Branch:** `fix/836-792-compliance` · **Base:** `72d2185` → reconciled with
`origin/main` `cc288d5`

One PR, because both issues are the **same mechanism**: `scripts/check-pipeline-compliance.sh`.
#836 is about what the gate computes and how it is proven; #792 is about *when* it is consulted.

## Supersession — `820ff66` removed the local static pin (indicator 2)

While this PR was open, **#863** (`91275a9`/`317c4a0`) landed
`scripts/check-no-sigpipe-grep.sh` — a **repo-wide** guard for the same
`printf/echo … | quiet-grep` idiom whose `SCAN_DIRS=(scripts .husky pi-bootstrap)` put this
script in its scan set — plus `tests/sigpipe-grep/run.sh`, which pins that guard's detection
of the joined (`-q`), separated (`-i -q`) and `--quiet` spellings, its negation controls, the
`\`-continued form, comment exclusion and its own self-scan. Two pins for one idiom are two
sources of truth free to drift, so commit **`820ff66` removed this PR's local static pin and
its positive control** (15 insertions / 58 deletions, this file only).

Consequences for the claims below — **§1 item 3**, the pin rows in §3's Wiring table, task 4
in §4, the pin bullet in §5 and the pin risk in §6 are all **historical**: the head contains no
static pin (`anti`/`anti_a`/`anti_b`/`pipe_hits`/`pin_hit` are gone) and no `#863`-era pin either.
Indicator 2 is owned by `scripts/check-no-sigpipe-grep.sh` from now on.

The handover is **not** total: the repo-wide guard is narrower than the pin removed here — it
requires `grep` immediately after the pipe (a post-pipe env prefix is a MISS), knows only the
`printf`/`echo` producers (`cat` is a MISS) and looks for the quiet flag before the pattern
(`grep x -q` is a MISS); and nothing executes it (no workflow or hook invokes it, and
`tests/sigpipe-grep/run.sh` is not wired into `ci.yml`/`ci-main.yml`). Both gaps are filed as
**#877**. Everything else this PR delivers — the hoisted `has_*` matchers, the large-input
positive/negative controls, the `run_checks` end-to-end vector, the `pr_is_docs_only` fail-OPEN
vector and the whole of #792 — is unchanged and still covered by the verification below.

## 0. Base drift — #716 landed the #836 *fix* while this PR was in flight

This PR was opened against `72d2185`. `origin/main` then advanced **31 commits** (`cc288d5`,
merge of PR #751), **12 of them touching this script**. One of them is decisive:

> `0542c6d fix(scripts): make the pipeline-compliance text checks SIGPIPE-proof (#716)`
> — plus follow-ups `4230ffc`, `25a51e7`. All **8** `printf … | grep -q` sites were moved to
> here-strings. Diagnosis, site list, and mechanism identical to #836's.

So the *code fix* for #836 is already on main. **#716 added no regression test for it, and no
static pin** — verified: `origin/main`'s script contains no large-input/SIGPIPE/`65536`
reference anywhere outside the fix's own prose. #836's own **indicators 2 and 3** are therefore
still unmet on main:

* indicator 1 — a matching evidence string passes deterministically at >`PIPE_BUF`;
* indicator 2 — the pipeline cannot exit non-zero from `printf`'s SIGPIPE, i.e. no
  `printf … | grep -q` remains (a *pin*);
* indicator 3 — **a new fixture with a >64 KB evidence text that must PASS**.

**This PR's remaining scope, after the reconciliation:** supply indicators 2–3 as tests that
pin the *production* code path; add the behavioural vector for the one site whose failure mode
is fail-**OPEN** (unreachable by any assertion on the fixed code, so it needs its own large-input
pin); and deliver #792 in full. **[Scope note, `820ff66`: indicator 2's *static* half is no
longer in this PR — it was removed in favour of #863's repo-wide guard, see §Supersession. Its
behavioural half (the large-input vectors, incl. the fail-OPEN `pr_is_docs_only` one) is what
this PR still delivers.]** It does **not** re-do #716's edit: the reconciled diff contains
no site change that main already made, and a diff audit (`git diff origin/main -- <script>`)
rewrites exactly 18 of main's lines to the same behaviour, removing nothing (see §5 for the
audit; no insertion total is quoted here, since it changes with every edit to the file).

### Why the regression test still matters when main already has the here-strings

A fix with no pin regresses — that is the whole history of this gate (`#692`, `#708`, `#744`
are all "a gate silently degraded and no test noticed"). The measured RED evidence below is
against the **pre-#716 idiom**: the test is a pin whose RED was demonstrated, so a revert to
`printf | grep -q` (in this file or a new site) fails the suite instead of merging green.

## 1. #836 — the mechanism, and what is now pinned

`grep -q` exits at the **first match** while `printf` is still writing; `printf` takes
`SIGPIPE` (141); under `set -euo pipefail` the **pipeline** status is 141, so the `if` takes
the `else` branch and reports **present** evidence as missing. Measured 3 failures in 4 runs
on PR #823, with the failure moving between (c) and (e) while the evidence text was unchanged
and a re-run of the identical job passing (9 body / 6 commit matches for (c); 16 / 33 for (e)).

**Reproduced locally against the pre-fix idiom** (bash 3.2.57, matching token on line 1):

```
input bytes: 66022
OLD idiom (printf | grep -q): 20/25 runs reported 'no evidence'
NEW idiom (here-string):      0/25 runs reported 'no evidence'
```

| input | OLD false-negatives | here-string |
|---|---|---|
| 1 KB / 8 KB / 64 KB | 0/30 | 0/30 |
| 256 KB | **30/30** | 0/30 |
| 1 MB | **30/30** | 0/30 |

A here-string has no reader process to close the write end, so `grep -q` reads to EOF and no
`SIGPIPE` can reach the writer. (The review measured this directly on bash 3.2 and 5.2 at
200 000+ invocations, including bash 5.x's pipe-backed small-string here-strings.)

### The failure *directions* — why the pin covers more than (c)/(e)

The 8 sites did not all fail the same way. Two were **fail-OPEN**:

| Site (base `72d2185`) | Old form | If it raced |
|---|---|---|
| `pr_is_docs_only` L278 | `! printf … \| grep -qvE '^docs/'` | **FAIL-OPEN** — a non-docs list read as "docs-only", unlocking check (a)'s non-closing traceability keyword for a **code** PR |
| (c) #513 clean-micro binding L424 | `printf … \| grep -qE 'verdict=clean-micro…'` | **FAIL-OPEN** — a matching marker read as absent, silently disarming the tier binding |
| (b) L400, (c) L410, (d) L439, (e) L485 | `printf … \| grep -q…` | fail-closed false **BLOCK** (the #836 bug) |
| tier detection L390/L391 | `printf … \| grep …` | fail-closed / fail-open (check d skipped) |

Sites whose reader is `head -1` **and** whose pipeline is wrapped in `$( … || true)` (the
`parse_issue_ref` family, the plan-file / test-file `head -1` lookups) are not control-flow
hazards: the producer's status is discarded and `head` has already printed the captured line.

### What this PR adds for #836

1. **Hoisted patterns + matcher functions** (`REVIEW_EVIDENCE_RE`, `TEST_EVIDENCE_RE`,
   `CLEAN_MICRO_MARKER_RE`; `has_review_evidence` / `has_test_evidence` /
   `has_clean_micro_marker`). This is what lets the regression test call the **production**
   path instead of asserting against a copy of the pattern — the difference between a test
   and a self-fulfilling assertion. The patterns are byte-identical to the base's literals
   (review-verified: 0 mismatches over a 148-comparison differential on bash 3.2 and 5.2).
2. **The >64 KB deterministic regression** (indicator 1 + 3): 25 repetitions of each matcher
   on a 66 KB input with the token on line 1; 25 repetitions of the same filler with **no**
   token as a negative control (so the positive cannot pass vacuously); and **25 repetitions
   of the real `run_checks` end-to-end** on a `complexity:standard` issue with full evidence —
   `FAILURES` must be 0 every time. A fixture-size assertion (>65536 bytes) keeps it from
   silently degrading.
3. **[SUPERSEDED at `820ff66` — see §Supersession: the pin was removed; indicator 2 is owned
   by `scripts/check-no-sigpipe-grep.sh` (#863) from now on.]** ~~The static pin~~ (indicator 2): no live *quiet* `grep` may be fed by a
   `printf`/`echo`/`cat` pipeline on a non-comment line, in every spelling — env-prefixed
   (`LC_ALL=C grep -q`), joined (`grep -q`), separated (`grep -i -q`) and `--quiet`. It fails
   **loudly** if it cannot read its own source, and it carries its own **positive control**
   (the pattern must match all four spellings and must ignore a here-string), so a pattern
   edit cannot disarm it into a green scan. Documented limits: a multi-stage pipeline or a
   backslash continuation is not matched by a line-oriented regex, and a quoted string
   containing the text is an accepted false positive (the message names the line).
4. **The fail-OPEN site gets a behavioural vector**, because no assertion on the fixed code
   can reach it: `pr_is_docs_only` on a >64 KB row list whose **first** row is a non-docs path
   must read NOT docs-only on every one of 25 runs (pre-fix: ~88 % of runs inverted).

## 2. #792 — chosen option

**Option 1 — the gate's issue-side checks run in `01-preflight.md`, via a new `--issue-only`
mode on the script.** Option 2 (a bespoke assertion in the skill doc) duplicates the gate's
marker/tier/`Wiring` semantics in prose — two definitions of "scoped" that drift. Option 3 is
enforcement-free.

`--issue-only <N|owner/repo#N>` evaluates **exactly the checks that need no PR** and skips the
rest, reusing the same code and tier rules:

| Check | Needs a PR? | Full PR run | `--issue-only` |
|---|---|---|---|
| (a) linked issue | yes (PR body) | enforced | skipped — the target issue is an *input*, not a parse |
| (b) scoping comment | no | enforced | **enforced** |
| (c) code-review evidence | yes | enforced | skipped |
| (d) plan doc | PARTLY — `docs/plans/*.md` needs the diff; `Wiring` does not | enforced | **enforced via the `Wiring` branch only** |
| (e) test-coverage evidence | yes | enforced | skipped |
| (f) second-model gate (#716) | yes (diff + body/commits + base ref) | enforced | skipped |

Tier exemptions are identical. **The full-PR verdict logic is untouched**:
`ISSUE_ONLY=0` is the only path a PR takes, the new guards are branches around (never within)
the existing expressions, and the review measured every pre-existing check message plus the
DRY_RUN/FAIL_ALL output as byte-identical to the baseline (no count is quoted: the number of
message strings grows as checks are added, and only the equality is the claim).

Also added: `PIPELINE_COMPLIANCE_ISSUE_ONLY=1` + `PIPELINE_COMPLIANCE_ISSUE=<N>` as the env
equivalent, `--issue-only` in `usage()`, an issue-only arm in the `DRY_RUN` plan, and argv
validation (`<N> --issue-only` and a surplus argument are usage errors, not a silent
fall-through to the full-PR gate).

### Preflight wiring

`skills/commit-workflow/workflow/01-preflight.md`, immediately after **Tier Detection** — issue
resolved, tier known, nothing implemented, committed, reviewed, or PR'd. The snippet resolves
the gate from the checkout **or `$AGENT_INFRA_PATH`** (consumer repos do not carry the script),
passes `GH_REPO` explicitly (the script auto-detects its own origin from its own path, which
would be agent-infra's when invoked from there), and documents the exit-code contract
**0 = proceed / 1 = BLOCK / 2 = could-not-run** rather than collapsing every non-zero exit into
one message.

## 3. Wiring

| Interface / artifact | Producer | Consumer | Verified by |
|---|---|---|---|
| `REVIEW_EVIDENCE_RE` / `TEST_EVIDENCE_RE` / `CLEAN_MICRO_MARKER_RE` constants | this PR | checks (c), (e) and the #513 binding in `run_checks` | SELF_TEST #836 block — production path, 25 reps, >64 KB, positive + negative controls |
| `has_review_evidence()` / `has_test_evidence()` / `has_clean_micro_marker()` | this PR | checks (c)/(e) call sites; the SELF_TEST regression | SELF_TEST #836 block (the pin that used to share this row moved to #863 at `820ff66`) |
| ~~The #836 static pin (no quiet-grep pipeline)~~ **REMOVED at `820ff66`** — see §Supersession | this PR | the whole script source; protects #716's fix from regression | positive control (deleted with the pin): matched all four spellings and ignored a here-string; caught all 8 pre-#716 sites; 0 hits on the reconciled head |
| `pr_is_docs_only` large-input vector | this PR | the fail-OPEN site in `pr_is_docs_only` | 25 reps at >64 KB, non-docs row first |
| `--issue-only <N\|owner/repo#N>` CLI mode | this PR | `skills/commit-workflow/workflow/01-preflight.md` | SELF_TEST vectors: micro (0 failures) / standard+Wiring (0) / standard w/o Wiring (1, local remedy) / no marker (1, b) / unlabeled (1, b) |
| `resolve_issue_only_ref()` + the CLI/env contract | this PR | the issue-only dispatch block | SELF_TEST `expect_io_ref` vectors + 10 subprocess exit-code vectors (8 rejections: no target, malformed, surplus, misordered, bad `owner/repo#N`, malformed env target, env+positional, env+argv; 2 successes: the env form and the PR path with the env seam set) |
| `PIPELINE_COMPLIANCE_ISSUE_ONLY` / `PIPELINE_COMPLIANCE_ISSUE` env seam | this PR | the documented env form of `--issue-only` | SELF_TEST: env form must resolve its target (dry-run prints `Issue: 123`) |
| issue-only skips for checks a/c/e/**f** | this PR | every `run_checks` branch that reads PR state | the `checks a/c/e/f are SKIPPED with a named reason (4 skip lines)` assertion (exactly 4); check (f) probe is not even run in this mode |
| Preflight BLOCK step (issue-side artifacts) | this PR | every commit-workflow session | live `--issue-only 792` / `--issue-only 836` → exit 0; `--issue-only 1` → exit 1 with the remedy |
| Merge-time verdict (checks a–f, full-PR mode) and #716's check (f) | **unchanged** | `.github/workflows/pipeline-compliance.yml` required check | FAIL_ALL multi-pass + all #716 `sm_*` vectors unchanged; every pre-existing check message byte-identical |
| `docs/plans/2026-09-11-issue-836-792-pipeline-compliance-fix.md` | this PR | check (d) at merge time for #792 | `check-pipeline-compliance.sh` check (d) on this PR |

## 4. Tasks

1. Reconcile with `origin/main` (`cc288d5`): keep #716's here-string fixes and check (f)
   verbatim; re-apply only the additive work. — `scripts/check-pipeline-compliance.sh`
2. Hoist the three evidence patterns into constants + matcher functions with the #836
   rationale block.
3. Add the `--issue-only` mode: args/env parsing with argv validation, mode-aware guards, the
   issue-side fetch, the `ISSUE_ONLY` branches for a/c/e/**f** and the issue-only (d) arm, the
   mode-aware `summarize`, the `DRY_RUN` arm, `usage()`.
4. Add the SELF_TEST #836 block (regression + controls + e2e + fail-OPEN vector + static pin —
   the pin half removed at `820ff66`, see §Supersession),
   the `resolve_issue_only_ref` vectors, and the 5 issue-only vectors.
5. Wire the preflight BLOCK step (consumer-safe path, `GH_REPO`, exit-code contract) into
   `01-preflight.md`.
6. This plan doc + the scoping comments on #792 and #836.

## 5. Verification

- `bash -n scripts/check-pipeline-compliance.sh` → clean.
- `PIPELINE_COMPLIANCE_SELF_TEST=1 bash scripts/check-pipeline-compliance.sh` → exit 0,
  **92 ✅ / 0 ❌** (91 assertion prints + the final summary line), empty stderr, and
  byte-identical across 3 consecutive runs in the same checkout. (No md5 is quoted: the output
  embeds `$GH_REPO` and the script path, so a hash is checkout-dependent.) This block covers
  the #720 parser corpus plus
  this PR's #836/#792 assertions. #716's check-(f) `sm_case` vectors live in the
  `FAIL_ALL` block, not here — that block runs first (it precedes the self-test block in the
  script) and exits 1 by design, so they are
  exercised by the FAIL_ALL run, not by `SELF_TEST=1`. (Failures print to stderr, so the ❌
  count must be taken from stderr; stdout carries only the ✅ lines.)
- The rejection vectors are **mutant-discriminating**, which an exit code alone is not: `2`
  is also the contract value for "could not run", so a deleted argv guard still returned 2
  via the live path's unauthenticated `gh` — the same code the vector expected. The eight
  target-rejection vectors now run under `DRY_RUN=1` (a fall-through reaches the plan and
  exits 0) and assert the diagnostic text. Verified against a mutant: disarming the four
  `ISSUE_ARGV_ERR` assignments plus the two target guards makes exactly the 8 negative
  vectors fail (RC 2, 83 assertion ✅ lines) while the positive vectors and the rest stay green.
- **[REMOVED at `820ff66` — see §Supersession.]** The static pin has a **positive control**: the ban pattern must still match the
  env-prefixed (`LC_ALL=C grep -q` after the pipe), joined (`grep -q`), separated
  (`grep -i -q`) and `--quiet` spellings and must NOT match a here-string — otherwise a
  pattern edit could disarm the pin silently and a green scan would prove nothing. The samples
  are assembled from parts so the pin does not flag its own control.
- `PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 …` → all of main's 43
  check-(f) `sm_case` assertions (36 direct call sites + one 7-path loop) still pass in the
  simulation; the run's terminal exit 1 is the simulation's own status, unchanged from main.
- Behavioural equality with `origin/main` (the strongest form of "the verdict logic did not
  change"): the `FAIL_ALL` multi-pass simulation and the normal `DRY_RUN` plan produce
  **byte-identical** output from main's script and this one when both are invoked from an
  equivalent path (checked in a symmetric farm with identical `origin` URLs so both resolve the
  same second-model config, and re-checked after the argv-block change because that block is on
  the PR path too) — same line count, the same failure lines, the same exit codes. Exact line
  counts are
  environment-dependent (they include the check-(f) `sm_case` output, which needs a readable
  config), so only equality is claimed.
- `PIPELINE_COMPLIANCE_DRY_RUN=1 bash scripts/check-pipeline-compliance.sh --issue-only 792`
  → plan printed, exit 0.
- `bash scripts/check-pipeline-compliance.sh --issue-only 792` / `--issue-only 836` → exit 0;
  `--issue-only 1` (unscoped) → exit 1 with the actionable remedy and named a/c/e/f skips;
  `--issue-only` (no target), `--issue-only 792 999`, `792 --issue-only`, `a/b#nope`,
  `ISSUE_ONLY=1 ISSUE=42` + positional `792`, `ISSUE_ONLY=1 ISSUE=42` + `--issue-only 999`
  → exit 2 with the specific diagnostic;
  `PIPELINE_COMPLIANCE_ISSUE_ONLY=1 PIPELINE_COMPLIANCE_ISSUE=792` (dry run) → exit 0 and
  `Issue: 792` in the output; `… 792` (plain PR dry run) → exit 0 and an `ISSUE-ONLY`-free
  PR plan.
- Diff audit: `git diff origin/main -- scripts/check-pipeline-compliance.sh` **adds** the new
  machinery and rewrites exactly 18 of main's lines: the check-(b) marker grep tightened to
  `grep -qF`; the check-(c), check-(e) and clean-micro (#513 binding) greps replaced by the
  hoisted matcher calls (byte-identical patterns); the two `sm_*` probes moved inside an
  `ISSUE_ONLY != 1` guard; the `issue_ref` assignment/kind block, the repositioned
  `❌ No PR number given.` echo, and the `PR:`/PASS echoes
  moved into the `ISSUE_ONLY`-aware arms; and `if`→`elif` conversions. No verdict expression,
  message, or ordering is removed.

## 6. Risks / non-goals

- **Non-goal:** re-implementing #716's fix, changing any verdict expression, the required-check
  workflow, or the #488 linked-issue invariant. Every site #716 moved to a here-string stays a
  here-string on the reconciled head, including the sites whose expressions survive verbatim; where a matcher now serves a site, the pattern is the byte-identical one,
  hoisted out of the call site.
- **Non-goal:** #792's option 2/3.
- Risk: `--issue-only`'s plan-doc branch is unprovable pre-PR by construction, so preflight
  accepts the `Wiring` alternative only. Stated in the mode's output, the doc, and this plan.
- **[REMOVED at `820ff66` — see §Supersession.]** Risk: the static pin's documented limits (multi-stage pipelines, continuations, quoted-text
  false positives). The message names the line number, so a hit is a one-line clarification.
- Residual (filed as a follow-up issue): **nothing in CI runs
  `PIPELINE_COMPLIANCE_SELF_TEST=1`**, so these new assertions are exercised by hand and by
  this PR's verification only. Wiring it into `ci-main.yml`/`ci.yml` touches workflow files
  under the `workflow-lock.json` content lock, so it is filed rather than swept in here.
