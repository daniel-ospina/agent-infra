---
title: "PR state router — one command, one table, one action per PR (#2866)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-26
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2866, issue-2540, issue-2725, issue-2706, pr-state, tools-fleet, tortoise
---

# PR state router (#2866)

`tools/fleet/pr_state.py` answers **one question, once, for every open PR**:

> *what does this PR need next, and should anything be running for it right now?*

Before it existed, every actor answered a slice of that question for itself — `admin-merge.sh` merges
one PR safely, `pr-doctor.py` pushes a fix, `refresh-candidates.sh` picks issues, `record-review.sh`
binds an attestation to a sha, `pr-sickness.sh` selects red PRs, `collision_preflight.py` says who
holds an issue — and *none* of them could say "do not spend CI on a head that cannot merge", so the
fleet substituted volume: run everything, cancel later. Measured on `daniel-ospina/tortoise`,
2026-10-26: 100 queued runs, **19 of them on PRs that could not merge**, while 7 fully merge-ready PRs
sat behind them and 5 runners were online of 16 advertised.

```
python3 tools/fleet/pr_state.py --repo owner/name            # the table
python3 tools/fleet/pr_state.py --repo owner/name --json     # the same rows, machine-readable
python3 tools/fleet/pr_state.py --repo owner/name --only 1234 --action   # the actor seam (one TSV row)
python3 tools/fleet/pr_state.py --repo owner/name --suppress # cancel queued CI on heads about to change
python3 tools/fleet/pr_state.py --repo owner/name --cancelled            # what was cancelled + re-trigger
```

## The actions

| action | when | what it means |
|---|---|---|
| `CLOSE-STALE` | `changed_files == 0` | the diff is gone; nothing to run, nothing to merge |
| `WAIT:draft` | draft | a draft cannot merge, so nothing it runs can make it mergeable |
| `REPAIR-CONFLICT` | `mergeable == CONFLICTING` | no CI result can matter until the branch has main |
| `FIX-RED` | a real red caused by this tree | run the **failing job**, not the suite |
| `RERUN-FLAKE` | the same group **passed** (`success`/`neutral`/`skipped`) on an **earlier attempt at this same head** | `gh run rerun <id> --failed` once |
| `WAIT:inherited-red` | the same `(app, workflow, job)` is red at main's head | a fixer cannot fix main |
| `REVIEW` | nothing attested at this head (review-requiring repo) | dispatch a reviewer, cancel its queued CI |
| `WAIT:attested-elsewhere` | attested on the PR body, not in this box's store | the rail's gate reads the store |
| `WAIT:owes-review` | record at another head **and the diff changed** | re-review; both shas printed |
| `WAIT:diff-unreadable` | record at another head, live diff unreadable | **retry** the comparison, do not re-review |
| `WAIT:in-flight` | no red, ≥1 group running | it becomes an answer on its own; touching it is the waste |
| `WAIT:no-check-surface` | the surface is empty or unreadable | a missing check is not a green check |
| `WAIT:mergeable-unknown` | GitHub has not computed mergeability | re-read; never guessed into MERGEABLE |
| `WAIT:authority-unreadable` | branch protection unreadable | `repo-authority.sh`'s abstention, honoured |
| `LAND` | attested at this head (or carried) + mergeable + no real red | **the rail may run** — never "merge unseen" |

Precedence is *what must happen first in time*: reviewing a tree that is about to be rebased, or
running CI on a conflicting head, is not the next action.

## Two rules that decide whether CI is spent

**The verdict is by polarity, on the newest attempt per group.** Groups are
`(app.slug, workflow, job)` — the workflow is resolved from `details_url` through the head's run
listing, because a check-run payload does not carry it, and two workflows sharing a job name must
never mask one another. Newest attempt wins by check-run **id** (GitHub keeps every attempt).

* green — `success` / `neutral` / `skipped`
* **non-red — `cancelled` / `stale`** ⛔ most "red PRs" measured on 2026-10-26 were cancelled runs
* in flight — `queued` / `in_progress` / `waiting` / `requested` / `pending`
* **RED — everything else, including a conclusion GitHub has not documented and a null one**

⛔ **`cancelled`/`stale` are non-red for the VERDICT, and are NOT a pass for `RERUN-FLAKE`.** The two
uses are different questions: "may this attempt redden the PR?" (no) and "has this tree ever been
shown to pass this job?" (a cancelled attempt shows nothing). Only a green attempt is evidence for a
re-run, because the claim printed is "passed on an earlier attempt" — and both consumers act on it
(the fixer declines the head, the lander exits 11 WAITING), so a guess dressed as evidence withholds
a real red from repair.

**An unreadable read is never a zero.** A check surface that could not be read is
`WAIT:no-check-surface` with *that* reason (an empty-but-read surface keeps its own reason — the two
are reported differently), and a queued-run inventory that could not be read renders the `Q` column
as `?` with a header note, never `0` (its count is also `--suppress`'s `before=` figure). Only
`--action` + `--only <pr>` produces a row: a bare `--action` would answer with whichever PR sorts
first in the whole table. An **empty or truncated API body is a failed read**, not an empty surface:
`gh` exits 0 with no body when a token or a proxy eats the answer, and that used to arrive as `[]` —
indistinguishable from "this PR has no checks", which is the one reading the NOREAD arm exists to
prevent.

⛔ **A suppression pass that could enumerate nothing is not a pass that found nothing.** If the
queued-run inventory could not be read, no run id exists to cancel, so `--suppress` cancels nothing and
**exits 2** with that reason — never `cancelled=0` and exit 0, which is a success signal for a pass
that never ran.

**Suppression.** A row in `REVIEW`, `REPAIR-CONFLICT` or `FIX-RED` has a head that is *about to
change*, so `--suppress` cancels its **queued** runs before they are spent. A run is re-read
immediately before the cancel and is **never** cancelled if it is no longer `queued` (the
measurement-artifact rule: re-measure at the moment of action). Every cancelled id is appended to
`${O:-$HOME/orchestrator}/state/pr-state-suppressed.jsonl`, and `--cancelled` prints each one with the
`gh run rerun <id>` that re-triggers it. Re-trigger is otherwise automatic: a push starts the new
head's runs.

## Fidelity: `attested_sha == head_sha`, with the carry the gate already has

`LAND` requires the attestation to bind this head — **in the shape the review gate itself decides
it**. A record whose head moved is still valid when the reviewed *diff* is byte-identical (the
`carried` arm of `extensions/review-enforcer/index.ts`; `record-review.sh --check-carry`). So:

| fidelity | meaning | land? |
|---|---|---|
| `at-head` | `attested_sha == head_sha` | yes |
| `carried` | head moved, `record.diff_sha256` == the live diff | yes (as the gate does) |
| `owes-review` | head moved, the diff differs, or no digest at all | **no** — the two shas are printed |
| `diff-unreadable` | the comparison could not be made | **no** — retry, never re-review |

The live diff comes from `record-review.sh --print-diff-hash`, the read-only seam that file documents
for exactly this comparison — there is ONE definition of "the diff is unchanged".

⛔ The issue's literal wording ("a mismatch is a refusal") would have refused every legitimate carry.
That is a recorded decision, so this module implements the decision — see the PR's contradiction test.

## The two actors

`scripts/orchestrator-harness/pr-state.sh` is the ONE seam (`prstate_row <repo> <pr>` →
`ACTION<TAB>run<TAB>reason`, or `unavailable<TAB>-<TAB>why`), sourced by:

* **the fixer** — `pr-sickness.sh` (`ps_decide`): a `WAIT:inherited-red` or `RERUN-FLAKE` head is
  **not** handed to a fixer; the re-run command is printed instead.
* **the lander** — `lane-merge.sh` (the RED branch): `RERUN-FLAKE` exits **11 WAITING** instead of
  spending a FIX round on a flake, so no new head is pushed and no attestation is stranded.

⛔ An unresolved router prints `unavailable` **and the actor behaves exactly as before**. A router that
did not run is never a reason to stop repairing reds, and never reads as "nothing to say".

## What it deliberately does not do

* It never merges, never writes a review record, and never cancels a **running** job.
* `admin-merge.sh` is unchanged: the rail remains the only merge path, and `LAND` only *permits* it.
* No automatic dispatch, no lane ceiling, no second landing path.
