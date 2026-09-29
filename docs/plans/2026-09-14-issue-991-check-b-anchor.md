<!-- research-path: docs/plans/2026-09-14-issue-991-check-b-anchor.md -->

# check (b) marker anchoring + fixture wiring — Implementation Plan

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** Make `pipeline-compliance` check (b) require the `<!-- issue-scoping:` marker to *begin a line* (an artifact) rather than appear anywhere (a mention), and make the gate's fixture suite actually execute.

**Team:** organisation-design-team

**Architecture:** Extract the scoping detection from an inline `grep -qF` into a pure helper `has_scoping_marker()` so the parser self-test can pin it — the same shape the file already uses for `parse_issue_ref` / `parse_trace_ref` / `pr_is_docs_only`. Anchor the match to line start. Wire the existing `PIPELINE_COMPLIANCE_SELF_TEST=1` suite into `pipeline-compliance.yml`, because it currently runs nowhere.

### Pattern Research

Skipped — the plan touches zero third-party dependencies. Pure bash plus a GitHub Actions YAML step; no libraries, no API surface.

### Integration Surface Map

| Surface | Type | Test layer | Notes |
|---|---|---|---|
| `has_scoping_marker()` | pure shell predicate | `expect_scoping` fixtures (self-test) | string in → bool out; no I/O |
| check (b) call site | gate logic | self-test + failure simulation | consumes the helper; verdict text asserted |
| `$SCOPING_COMMENT` assembly | integration | `gh api … '.[].body'` | `jq` preserves each body's line structure — the property the `^` anchor depends on |
| `.github/workflows/pipeline-compliance.yml` | CI wiring | the CI run itself | new step; no new required check |
| `templates/.github/workflows/pipeline-compliance.yml` | consumer template | none | deliberately NOT changed — see Task 3 |

**Bug pattern flags:** the anchor depends on line structure surviving `jq`; if that ever changed to a lossy join, genuine artifacts would start failing. Pinned by a fixture using a two-line input.

**Journey Test Map** — not applicable (no user-facing journey). Replaced by the artifact/mention vectors below, which are the observable behaviour.

### Failure Modes

- A comment whose marker is **neither** the first line with content **nor** a blank-separated footer — e.g. crowded behind a prose preamble → **must FAIL** → fixtures `marker after a crowded prose preamble (not the first line)`, `marker as the last line, crowded (no blank line above)`, `marker crowded in the SECOND comment (not its first line)`. *(An earlier draft of this map said a later-line marker "must still PASS"; that was the pre-positional contract, where the check only asked whether the marker began *a* line. The blank line is what separates the #783 footer — a real artifact — from these mentions.)*
- A first line indented ≥4 columns, or tab-indented → **must FAIL** → fixtures `marker indented 4 spaces on the first line (indented code block)`, `marker tab-indented on the first line (indented code block)`. GFM renders these as an **indented code block**, displaying the marker — a mention. *(An earlier revision tolerated indentation on the first line and pinned it as `true`; that was wrong and is corrected here.)*
- A genuine artifact: marker at **column 0** of the comment's first content line, where leading **blank** lines and leading **ATX headings** are skipped → **must PASS** → fixtures `genuine artifact (marker on line 1)`, `genuine artifact (marker after leading blank lines)`, `genuine artifact (heading, then the marker) — the #843 shape`. *(The heading form is not hypothetical: four real artifacts in this repo use it — #729, #843, #857, #858 — and a strict first-line rule rejected all four.)*
- A genuine artifact whose marker is the **last** line with content, **set off by a blank line** → **must PASS** → fixture `genuine artifact (marker as the LAST line, after a blank line) — the #783 shape`. *(Also not hypothetical: #783 carries two such artifacts. Its PR, #873, merged 2026-09-13 — before this fix — so the cost is a *future* false reject, not a present block, and the widening is justified by the shape being real rather than by rescuing a live PR. Without the blank-line condition this form would swallow the crowded-preamble mentions above, which is what the rejected widening does.)*
- A **heading followed by prose that mentions the marker** (a discussion comment that opens with a heading and names the marker inside a sentence — the real #674 shape) → **must FAIL** → fixture `heading, then prose CALLING the marker (not an artifact) — the #674 shape`. *(The vector carries the marker on purpose: an earlier version of it omitted the marker entirely, which made it indistinguishable from the `no marker at all` guard and pinned nothing. Caught in review.)*
- A genuine artifact posted as a **later comment** → **must PASS** → fixtures `genuine artifact in the SECOND comment`, `real #883 shape — artifact is comment 3 of 3`. *(Only the thread's first comment could satisfy this check under the first positional form — a regression that broke #883, whose artifact lands after two discussion comments.)*
- A comment quoting the marker in prose → **must FAIL** → fixture `prose mentioning the marker (#786, the live defect)`.
- A marker inside a code fence, blockquote, or code span → **must FAIL** → fixtures `marker at column 0 inside a fence`, `marker inside a blockquote`, `marker quoted inside code span`.
- `$SCOPING_COMMENT` empty (no comments at all) → **must FAIL**, not error → fixture `empty comment text`.

**Tech Stack:** bash 3.2+ (`grep -E`, here-strings — no `bash 4` features), GitHub Actions, `jq`.

---

### Task 1: Extract and anchor the predicate

**Intent:** Make the artifact-vs-mention distinction an explicit, testable unit instead of an inline substring grep — so a future edit cannot silently regress it.
**Acceptance:** `has_scoping_marker '<marker on line 1>'` → true; `'<marker after leading blank lines>'` → true; `'<heading, then the marker>'` → true (the #843 shape); `'<marker as the LAST line, after a blank line>'` → true (the #783 shape); `'<artifact in a later comment, per-comment record>'` → true; `'<marker after a crowded prose preamble>'` → false; `'<marker as the last line, crowded>'` → false; `'<heading, then prose>'` → false; `'<marker indented on the first line>'` → false; `'<marker mid-line>'` → false; `'<marker at col 0 inside a fence>'` → false; `'<marker inside a NESTED fence>'` → false. Shell syntax valid.
**Files:**
- Modify: `scripts/check-pipeline-compliance.sh` (helper after `parse_trace_ref`; call site in check (b))
- Test: `scripts/check-pipeline-compliance.sh` (self-test)

**Step 1: Add the helper** after `parse_trace_ref()`:

```bash
has_scoping_marker() {
  # RS = 0x1e, injected by the caller's jq. See the sanitization note at each
  # fetch site: the separator is in-band, so the data is stripped of it first.
  #
  # POSITION IS THE CONTRACT. An artifact carries the marker either as the
  # comment's FIRST line with content, or as its LAST one when set off by a
  # blank line. Both branches ask WHERE the marker sits — never what Markdown
  # makes of it — so there is no fence, indentation or container grammar left to
  # get wrong. Measured over this repo's 235 marker-bearing comments: 223 first,
  # 2 last (the two #783 artifacts), 10 neither — and all 10 are prose, tables
  # or fenced examples, i.e. mentions.
  awk -v RS='\036' '
    {
      n = split($0, lines, "\n")
      # Branch 1 — the first line with content, skipping blanks and any leading
      # ATX headings (the producer emits both a bare-marker and a heading-first
      # shape: four real artifacts open with an ATX heading — #729 uses
      # "## Scoping — #729", the other three "## Scope —").
      j = 0
      while (j < n && (lines[j+1] ~ /^[[:space:]]*$/ || lines[j+1] ~ /^#{1,6}[[:space:]]/)) j++
      if (j < n && lines[j+1] ~ /^<!-- issue-scoping:/) found = 1
      # Branch 2 — the last line with content, and only when a blank line sets
      # it off as a footer block. Drop the blank-line condition and a crowded
      # "preamble\n<marker>" passes, which is the mention shape.
      k = n
      while (k >= 1 && lines[k] ~ /^[[:space:]]*$/) k--
      if (k >= 2 && lines[k] ~ /^<!-- issue-scoping:/ && lines[k-1] ~ /^[[:space:]]*$/) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' <<<"$1"
}
```

with the rationale comment (why not a bare substring; why the rule is *positional*; why **column 0** with no indentation tolerance; why leading **ATX headings** are skipped; why a trailing marker needs a **blank line** above it; why **each comment is a separate record** and why the separator is stripped from the data before being appended; the parser revisions that preceded it; and why the schema option stays rejected).

**Step 1b: the rule is position, not structure — added after review, see `## Learnings`.** Anchoring alone was not sufficient; nor was a fence toggle, nor character/length tracking, nor bounding indentation to 3 columns. Each was a fence parser that closed one false-pass axis and was blind to the next. The shipped form asks only **where the marker sits**, which makes every fence axis irrelevant by declining to parse — at the cost of the **one re-opened residual** documented in `## Learnings` (an unterminated trailing fence can occupy the footer position) — and is a *deletion*, not another patch: the fence parser's 25-line awk program collapses to a two-branch positional test — the parser, and the entire CommonMark surface it depended on, are gone. *(Four earlier drafts of this step quoted superseded revisions. One of them asserted that a first-line rule 'would invalidate genuine artifacts written before this rule' and dismissed it as false — and that dismissal was WRONG: six real artifacts carry the marker off the first line, four after a heading and two in a footer. See `## Learnings`. The quotation is now the shipped code, byte-for-byte, which each review re-checks by diff.)*

**Step 1c: the corrections each review round forced on the positional form.** (i) It stripped leading whitespace, admitting a first line indented ≥4 columns: GFM renders that as an **indented code block**, so the marker is *displayed* — a mention, not an artifact. Column 0 is now required. (ii) It ran on the **concatenation** of all comments, so it tested the thread's oldest comment rather than each one — which broke #883, whose genuine artifact is comment 3. Each comment is now its own record, which is what the check's own message ("one of its comments") had always claimed. (iii) A strict first-line rule then rejected **four real artifacts** (#729, #843, #857, #858) that carry the marker on line 3 after a `## Scope —` heading — a shape the producer emits. Leading ATX headings are now skipped. (iv) It still rejected **two more** (#783), which carry the marker as a blank-line-separated **footer** on their last line. #783's PR (#873) had already merged before this fix, so no live PR was at stake — but the shape is real work, and a rule that silently invalidates it would fail closed on a *future* PR whose issue carries one. That is why the last-line branch exists: measured over the repo's 235 marker-bearing comments, 223 put the marker first, **2** put it last (#783), and **10** put it neither — all 10 being prose, tables or fenced examples. A prose preface and a crowded last line are still rejected, so the branch widens to exactly the shapes that exist and no further. All four were found by review against live data, not by reasoning, and the committed vectors pin each.

**Step 2: Replace the call site.** `if grep -qF '<!-- issue-scoping:' <<<"$SCOPING_COMMENT"; then` → `if has_scoping_marker "$SCOPING_COMMENT"; then`.

**Step 3: Rewrite the (b) failure message** to state the required position and the remedy (the marker must be the first line with content of one of the issue's comments, or its last line set off by a blank line; a mention — prose, quoted example, fence, table, blockquote, or an indented first line — does not count).

**Step 4: Verify the input shape.** `SCOPING_COMMENT` is assembled per comment with `.[].body | gsub("\u001e"; "") + "\u001e"` — the strip is load-bearing, because the separator is in-band and a comment body could otherwise forge a boundary. So each comment is its own record and no comment's line structure is lost. Confirm BOTH fetch sites carry the strip-and-append — the live one and the issue-only one.

Run: `bash -n scripts/check-pipeline-compliance.sh`
Expected: clean.

---

### Task 2: Add the `expect_scoping` fixture family

**Intent:** Pin the behaviour so the fix cannot silently revert — the suite is the only thing standing between this and another bare-substring drift.
**Acceptance:** the prose vector fails under the pre-fix matcher and passes under the new one (non-vacuity by control); genuine artifacts pass under both.
**Files:**
- Modify: `scripts/check-pipeline-compliance.sh` (self-test, after the `expect_resolve` block)

**Step 1: Add the vectors.** Genuine artifacts (marker on the comment's first line; after leading blank lines; after a heading; as a blank-separated last line; posted as a later comment; the real #991 comment), and must-fail vectors including **the literal #786 sentence**, prose asserting absence, a marker in a code span, a blockquote, a crowded later-line marker, the fence/nesting/indentation forms, empty input.

**Step 2: Prove non-vacuity.** Run the same vectors against `grep -qF`. Expected: the *mention-shaped* must-fail vectors — the #786 prose sentence, the absence-assertion, the inline quote, and the code span — are wrongly **accepted** by the pre-fix form. (The `empty comment text` and `no marker at all` vectors are false under both matchers by construction; they guard the true-direction, not the fix.) Non-vacuity rests on the mention-shaped set: if any of those is already rejected pre-fix, it pins nothing and must be replaced.

---

### Task 3: Wire the suite into CI

**Intent:** A fixture nothing executes pins nothing. The suite ran nowhere (the env var is set only inside the script) and, at the time of writing, could not be run from the main checkout either (#883 blocked execution of this script).
**Acceptance:** `pipeline-compliance` shows a green "Run the gate's fixture suite" step that actually executes the assertions.
**Files:**
- Modify: `.github/workflows/pipeline-compliance.yml` (new step in the `pipeline-compliance` job)
- NOT modified: `templates/.github/workflows/pipeline-compliance.yml` — consumers reuse the template against their own script copy; imposing this repo's fixture expectations on them is out of scope.
- NOT modified: `.github/workflows/ci-main.yml` — this PR makes its `:55-56` comment stale, but that file is pinned in `scripts/workflow-lock.json`, so a comment tweak would cascade into a lock re-derivation for no functional gain. Correct it in whichever PR next touches the file.
- NOT modified: `scripts/workflow-lock.json` — it locks `ci.yml`, `node-ci.yml`, `ci-main.yml`; `pipeline-compliance.yml` is not locked, and `scripts/sync-ci-workflows.sh` does not materialize it, so the edit cannot be clobbered.

**Step 1: Add the step**, pure shell, no token:

```yaml

      - name: Run the gate's fixture suite
        # #991 — the parser/fixture suite was executed by NOTHING. The env var is
        # set nowhere outside the script itself (grep: only the script's own
        # help text and its own guard), and this job ran the gate only —
        # `ci-main.yml:55-56` said so outright ("pipeline-compliance.yml is also
        # PR-triggered, but runs no test suite"). That line is now stale, and
        # this step is what makes it so; it is not corrected here because
        # ci-main.yml is pinned in scripts/workflow-lock.json and a comment
        # tweak would force a lock re-derivation. A fixture nothing runs pins
        # nothing, so every assertion the suite carries — expect_ref,
        # expect_trace, pr_is_docs_only, resolve_issue_ref, and the
        # has_scoping_marker family added by #991 — was decorative.
        #
        # CI is also the ONLY venue for it: the #1484 main-worktree-guard
        # blocks local execution of this script (it contains a read-only
        # `git -C "$ROOT" remote get-url origin`), so neither the maintainer nor
        # an agent can run the suite on their own machine (#883).
        #
        # NOT a new gate. This executes a suite the script ALREADY ships and
        # which already asserts; it adds no requirement a PR must satisfy and
        # changes no check's verdict. It is pure shell with no gh calls, so it
        # needs no token and cannot flake on API availability.
        env:
          GH_REPO: ${{ inputs.repo || github.repository }}
        run: |
          set -euo pipefail
          # The self-test seam is a hard requirement of this script. If it is
          # ever renamed or removed, FAIL LOUDLY rather than skipping: a bare
          # `exit 0` here would be a silent no-op of the exact class #991
          # removes — the suite would quietly stop running while the job stayed
          # green, which is how check (b) rotted into a substring match in the
          # first place.
          #
          # This step is therefore fail-closed for EVERY caller, including a
          # consumer that reuses this file via workflow_call against a script
          # copy predating the seam. That is deliberate. An earlier version
          # skipped with a `::notice::` when a hardcoded repo slug did not
          # match, which review flagged twice: first because `exit 0` anywhere
          # is a silent no-op, then because `github.repository` is not stable
          # across a rename or transfer — so renaming this repo would have
          # silently downgraded this repo's own run to the skip path. A loud,
          # self-explaining error costs a consumer one build; a silent skip
          # costs everyone the guarantee.
          if ! grep -q 'PIPELINE_COMPLIANCE_SELF_TEST' scripts/check-pipeline-compliance.sh; then
            echo "::error::scripts/check-pipeline-compliance.sh carries no PIPELINE_COMPLIANCE_SELF_TEST seam, so the fixture suite cannot run — and a fixture nothing runs pins nothing (#991). If this is a consumer copy that predates the seam, either update it or stop calling this workflow."
            exit 1
          fi
          PIPELINE_COMPLIANCE_SELF_TEST=1 bash scripts/check-pipeline-compliance.sh
```

The seam guard is not decoration, and its **failure direction is the point**: it is **fail-closed for every caller**. A bare `exit 0` would be a silent no-op of the exact class #991 removes — rename the seam literal and the suite stops running while the job stays green. An earlier version tried to except a `workflow_call` consumer by comparing `github.repository` against a hardcoded slug; review rejected that twice — first because *any* `exit 0` path is the silent no-op this PR exists to remove, and then because `github.repository` is not stable across a rename or transfer, so renaming this repo would have silently downgraded this repo's own run to the skip path. A loud, self-explaining error costs a consumer one build; a silent skip costs the guarantee. The block above is quoted verbatim from the shipped workflow, comments included, so it can be diffed against the file rather than compared by eye.

The seam guard is not decoration: this file is `workflow_call`-able, so without it a consumer invoking the file directly against a script copy that predates the seam would run the *gate* a second time under the self-test env var, and could red a required check for a suite it does not have. Review raised this; the guard is the proportionate answer. It cannot mask a problem in *this* repo — the seam is present here, so the branch is never taken.

**Step 2: Prove it is not vacuous.** Confirm on the PR's head that the step actually **ran the assertions** (the CI log shows the `has_scoping_marker` lines and `SELF-TEST PASS`, not an early exit), and that exiting non-zero from the suite really fails the build — the script's own handler exits 2 when `selffail > 0`, and the step has no `continue-on-error`. A CI step that passes because it silently no-op'd is the same defect one level up.

---

### Task 4: Verify against live artifacts

**Intent:** The change must be judged on real comments, not only synthetic vectors.
**Acceptance:** #786 (no scoping comment) now FAILS (b); #949 and #783 (genuine comments, the latter the footer shape) still PASS (b).
**Files:** none (verification only)

**Step 1:** Run the gate against #786 — expect check (b) to fail.
**Step 2:** Run against an issue with a genuine scoping comment (#949) — expect (b) to pass.

**Note:** blocked from the main checkout at the time of writing (#883); performed via CI, via extracted copies, and later natively from the worktree.

---

## Learnings

**Anchoring was necessary but not sufficient — review found the residual five times, each one level deeper, until the fourth showed the parser approach itself was the problem and the fifth showed the replacement needed two corrections of its own.** The first revision required the marker to begin its own line. A review caught that a marker at column 0 **inside a fenced code block** still passed, and this is not a contrived input: `skills/issue-scoping/SKILL.md:938-940` documents the posting form as a ```bash fence whose content line is the marker at column 0, so a comment *quoting the skill's own instructions* satisfied the check while containing no artifact — the #786 shape again, one fence deeper. That was fixed with a fence toggle. A **second** review then caught that a boolean toggle is itself a false pass one level deeper, on the canonical way to quote a fence inside a fence. The diagram that follows needed a **five**-backtick wrapper — a three-backtick wrapper around a four-backtick example is closed early by the example's own content, which is precisely the defect the fix is about, and a review caught the doc committing it:

`````
````markdown      <- opens a 4-backtick fence
```bash            <- 3 backticks CANNOT close it
<!-- issue-scoping: x -->   <- literal content, not an artifact
```
````
`````

The toggle treated the inner ```bash as a closer, flipped state off, and accepted the marker. Mixed fence characters and a closer with trailing text failed identically. Fixed by tracking the opener's character and length and only accepting a matching closer. A **third** review then caught that *that* was still a false pass: CommonMark bounds fence indentation to **3 columns** (a tab advances to the next multiple of 4), so a ` ``` ` line indented 4+ columns is content, not a closer — and `[[:space:]]*` accepted any indentation. The result was a **fail-open**: the indented ` ``` ` closed the block early and a following column-0 marker was accepted, while GitHub renders that marker inside `<pre>`. Confirmed against GitHub's own renderer. Indentation width is now computed (tabs expanded) and an over-indented line is not a fence.

A **fourth** review then found the pattern that ended the parser: `[[:space:]]` after a closer admits `\f`/`\v` (which CommonMark does not), and a leading UTF-8 BOM desyncs the parser from the renderer. Both were **fail-opens** — GitHub renders the marker inside `<pre>` while the check accepted it. That is when the shape of the problem became clear rather than the next patch.

**The revision that shipped is a DELETION, and that is the finding.** Four rounds had grown a 25-line awk fence parser inside a required gate, each revision closing one axis and blind to the next, because answering "artifact or mention?" by hand-rolling a Markdown block parser means inheriting CommonMark's entire surface — anchoring, fence characters, nesting, indentation width, whitespace classes, BOMs, block containers, line endings, info strings. That set has no end, so no further revision would have been the last one.

**The generalisable lesson:** the contract was **positional** all along — the producer posts the marker either as the comment's opening line or as a blank-line-separated footer — so the check reads position and stops parsing, and the fence axes that consumed four rounds (nesting, indentation width, whitespace classes, BOMs, info strings) stop existing as a category rather than being handled. The durable shape is not "parse the structure the way the renderer does" (that is what failed); it is **"ask the narrowest question the contract actually supports, and prefer deleting a parser over extending one."**

**But the deletion is a TRADE, not a strict improvement, and review caught me claiming otherwise.** An earlier draft of this section said every false pass from the four parser rounds was "closed *by construction*", including "any fence". That is false, and the counterexample is cheap: `Here is a quoted example:` + blank + an **unterminated** ` ```bash ` fence + blank + the marker. The marker is the last line with content and a blank line precedes it, so branch 2 **accepts** — measured: the committed rule `ACCEPT`s it while v2, v3 and v4 all `reject` it, because they tracked the unclosed fence. So the positional rule **re-opens one false pass the parsers had closed**, and it is the same shape as the #783 footer the rule exists to accept: by position alone, "a footer artifact" and "an unterminated fenced example" are identical. The honest statement is therefore narrower: the positional rule closes every *measured* false pass except the one it re-opens, and that one is the disclosed residual rather than a new discovery. It is still the right trade — six real artifacts versus a constructible shape with zero occurrences in a 235-comment corpus — but it is a trade, and the doc's earlier wording claimed a guarantee it does not have.

**Non-vacuity had to be shown per generation, not once.** The predicate has now had eight measured forms, so the control is an **eight-way** comparison over the **36** committed vectors (all evaluated against the *current* expectations, so every generation is scored on the contract that actually shipped). Every number below is produced by running the generation — extracted from git for the four historical parsers — against the committed suite, not written by hand, because the hand-written version of this table was wrong five review rounds running:

| generation | mismatches | what it gets wrong |
|---|---|---|
| first-content-line **or** blank-separated last line, per comment (committed) | **0** | — |
| strict first-line, per comment | **2** | the two real off-first-line artifact shapes — the heading-first form (#843) and the blank-separated footer (#783) — which stand for **six** real artifacts live (#729, #843, #857, #858, #783×2) |
| first-content-line **or** last line *without* the blank-line condition (the rejected widening) | **9** | the crowded-marker vectors, the fence/indentation guards, and a crowded later-comment vector — **every one of the 9 is a false pass**, which is why the blank line is load-bearing rather than cosmetic |
| indent-aware parser (v4) | **8** | the crowded-marker vectors, some indentation guards, and the later-comment artifact vectors |
| character/length parser (v3) | **7** | the crowded-marker vectors, the indented-closer guards, and the later-comment artifact vectors |
| boolean fence toggle (v2) | **9** | the crowded-marker vectors, the nested/mixed-fence vectors, a tab-indented closer, and the later-comment artifact vectors |
| anchored-only (v1) | **18** | the crowded-marker vectors, the fenced-heading vector, the whole fence family, and the later-comment artifact vectors |
| pre-fix substring | **26** | the crowded-marker vectors, the heading-then-prose-**calling**-the-marker vector, the fenced-heading vector, the mention vectors, the whole fence family, the indentation guards, and the crowded later-comment vector |

**The counts above are re-derived from the committed suite every review round; the per-row bucket arithmetic is deliberately not given, because hand-written bucket sums were wrong in five consecutive rounds while the counts never were.** Exact failing sets are printed by the harness that produces this table.

**The counts are not monotone — the committed form's two rejected predecessors sit at 9 and 8, above a parser it replaced — and that is evidence, not a measurement error.** Successive parsers traded one error class for another rather than converging, and the widening that removed the blank-line condition scored worse than the strict form it was meant to relax. Five rounds of refinement produced no trend toward zero; deleting the parser reached zero outright, and the corrections after it each removed a real failure. Any future proposal to reintroduce structural parsing here should have to explain why it would not resume that sequence.

**That a form scores low does not make it right.** The strict first-line rule missed **two** vectors, and those two stood for **six real artifacts** already in this repo. A near-zero count on a curated vector set measures the set, not the rule; the live scan is what caught it, twice. Both of the last two corrections were found after the rule already looked clean — neither would have blocked live work (the second one's PR had already merged), but both would have silently invalidated real artifacts on the next PR that referenced them.

**The fixture is self-protecting under CI, which was checked rather than assumed.** Reverting `has_scoping_marker` to the pre-fix form makes **26** fixtures assert the wrong value, so the suite's self-test failure handler (`SELF-TEST FAILED`, `exit 2`) trips and the new CI step goes red. Non-vacuity therefore does not depend on a control that exists only outside CI. *(Earlier drafts of this section said 6, then 8, then 12, then 15, then 18, then 23, then 24, then 25 — stale counts carried over from earlier suites, and the figure moved once more when review found a vector that omitted the marker entirely and therefore pinned nothing. The rule now: derive it from the committed suite at review time, never write it from memory.)*

**Three claims retracted — and the retraction of one of them was itself wrong, which is the most useful entry here.**

1. *"Requiring the marker on the first line would invalidate genuine artifacts written before this rule."* — **This one was TRUE, and I retracted it as "false" on a three-issue sample** (#883, #949, #991), each of which happens to put the marker on line 1. Scanning the repo's comments found **six genuine scoping artifacts** that a strict first-line rule rejects: **four** carrying the marker after a `## Scope —` heading (#729, #843, #857, #858), and **two** carrying it as a blank-line-separated footer (#783; its PR #873 merged 2026-09-13, before this fix, so the cost is a future false reject rather than a present block). The pre-fix substring check accepted all six. So the claim I dismissed was correct, my measurement was too small to see it, and the fix now tolerates both shapes. **The lesson is the epic's own: a claim is not refuted by a sample that happens to agree with you** — and it took a *second*, larger scan to find the footer shape that the first correction had missed.
2. *"Indentation on the first line cannot mean 'inside a code block'."* — False, and it was a live **false pass**: GFM renders a first line indented ≥4 columns (or tabbed) as an indented code block, which *displays* the marker.
3. *"The marker must be on the thread's first comment."* — Never claimed in prose, but the implementation assumed it, and it broke #883. Now per-comment.

Claims 1 and 2 were the same failure mode from opposite directions — a confident statement about real-world data, never checked at the right scope — for the weaker rule in one case and the stronger rule in the other. Since they point in opposite directions, no single default is safe: the answer is to measure the whole corpus before narrowing *or* widening.

**Cost, disclosed:** a **crowded prose preface** still fails, and a marker **indented on its first line** still fails. Both are deliberate and loud — the failure message names the required position and the remedy is to move one line. Leading **ATX headings**, leading **blank** lines, and a **blank-line-separated footer** are tolerated, because all three are shapes the producer actually emits. Measured over the repo's 235 marker-bearing comments: **223** have the marker as the first content line (four of those after a leading ATX heading — #729 uses `## Scoping — #729`, the others `## Scope —`), **2** as a blank-separated footer (#783), and **10** are neither, every one a genuine mention.

**Residual — one false-accept shape remains, and it is named rather than hidden.** Because the footer branch reads position only, a comment whose *last* content line is a blank-separated marker is accepted even if it is a mention rather than an artifact. No such comment exists in the current corpus (all 10 "neither" comments are caught), but the shape is constructible: `See the scoping comment above.\n\n<!-- issue-scoping: … -->` would pass — and so would an *unterminated* fence whose last content line is the marker, since by position alone the two are identical. That is the price of accepting the #783 footer without parsing structure, and it is a deliberate, measured trade: the alternative is a rule that rejects two real artifacts. **The guarantee is therefore about the first-content-line position only, plus that one disclosed footer shape.** A mention in prose, a table, a blockquote, a code span, any indentation, any fence, or a quotation of this very rule cannot occupy the first-content-line position; and no marker inside a *terminated* fence can occupy either position, because a fence's delimiters bracket it. *(An earlier draft of this paragraph claimed flatly that no fence of any kind could reach either position. Review showed an unterminated trailing fence is a counterexample — it is an instance of the disclosed residual, but the absolute wording was wrong.)*

**`bash -n` and the suite could not be run from the main checkout while this work was done** — the #1484 worktree guard blocked execution of this script (#883), so the gate was exercised through extracted copies and, in CI, through the step this PR adds. That is why the fixture suite had never run: `ci-main.yml:55-56` said that "pipeline-compliance.yml is also PR-triggered, but runs no test suite". *(That line is now stale at its source, and this PR is what makes it so. It is deliberately **not** edited here: `ci-main.yml` is pinned in `scripts/workflow-lock.json`, so a comment tweak would cascade into a lock re-derivation for no functional gain. The citation is framed as what it was — the state of the repo before this change — and the file should be corrected in whichever PR next touches it.)* **The suite was later re-run natively from this worktree and passed — `exit 0`, 127 assertions plus the terminal `SELF-TEST PASS` line (128 `✅` lines in all), 0 failures, 36 scoping vectors — so the CI wiring is corroborated by a local run rather than only by CI.** No causal claim is made about which change lifted which block: the guard's behaviour here depends on how the invoking session is rooted (#883, #967/#973), and an earlier draft of this section attributed the run to #973, which the evidence does not support. Every measurement in this document before that run was taken via extracted copies or CI, not by executing the script in place.
