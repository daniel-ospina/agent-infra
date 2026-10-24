---
title: "conflict-rebase — the CONFLICTING queue, mechanised where it can be and refused where it cannot (#2698)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-24
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2698, merge-queue, rebase, review-record, conflict-hotspots
---

# conflict-rebase — the CONFLICTING queue, mechanised where it can be and refused where it cannot

**Status:** live on the cell · **Owner:** agent-infra · **Issue:** #2698 · **Tools:**
`scripts/conflict-rebase.py`, `scripts/conflict-rebase-timer.sh`,
`scripts/conflict-rebase.test.sh`

## Why this exists

The PR queue looked like a labour shortage — 72 open PRs, 48 `CONFLICTING`, and the count
went 41 → 33 → 48 while 17 PRs merged the same day. It is not a labour shortage and it is
not (mostly) a rebase problem. `main` has `required_status_checks.strict = true`, so every
merge pushes every other branch out of date, and a small set of churn files is where that
becomes a conflict.

**The measurement that decides the design** (2026-10-24, agent-infra, 36 candidates):

| method | rebase/merge clean | conflict |
|---|---|---|
| `git rebase --onto main <merge-base> <head>` (replay semantics) | **0** | 35 (1 head moved) |
| `git merge-tree --write-tree main <head>` (merge semantics — GitHub's own "update branch") | **0** | 44 |

A `CONFLICTING` PR is *by construction* one whose content disagrees with `main`. There is
nothing mechanical to do to it: any resolution is a content decision, which is how a bot
lands a tree that compiles and is wrong.

## What the bot therefore does

1. **Refuses, out loud.** A content conflict → `needs-human-conflict` label + a comment
   naming the commit and the conflicting paths, and **nothing is pushed**. The refusal is
   the product.
2. **Rebases what is genuinely mechanical** — `--include-behind` (off by default): a
   `MERGEABLE` + `BEHIND` PR whose required context is green and whose head already carries
   a clean record. That is the rail's only remaining blocker, conflict-free by definition,
   and the diff is unchanged so the record still attests what would merge.
3. **Keeps the review record honest.** After a push it recomputes the PR's diff hash with
   `record-review.sh --print-diff-hash` (READ-ONLY, the gate's own implementation):
   identical → the record carries (the #2982 arm) and the comment says so *with the hash*;
   changed → the record is moved to `…json.superseded-<oldhead>` and the comment demands a
   re-review. Review-asserting labels are removed. The PR body is never edited (#1224).
4. **Reports the census**, including the hotspot ranking — see below.

## Where it runs, and why not in Actions

On the cell, under the cell's credential (`conflict-rebase-timer.sh start`). Two mechanical
reasons decide it:

- A push made with `GITHUB_TOKEN` does **not** create workflow runs (the documented
  exception is `workflow_dispatch` / `repository_dispatch`). The rebased head would carry no
  checks, and `scripts/admin-merge.sh` precondition 1 — *the head must have been TESTED* —
  would refuse every PR the bot touched. The bot would make PRs unlandable.
- The review record is a **local** file store (`~/.pi/agent/reviews/`). A runner cannot
  invalidate it, so an Actions bot would leave an attestation standing over a diff no
  reviewer saw — the one outcome worse than doing nothing.

## Merge queue (checked, not assumed)

Not available: GitHub scopes merge queues to "any public repository owned by an
**organization**", and `daniel-ospina` is a **User** (`gh api users/daniel-ospina --jq .type`);
the API agrees (`mergeQueue: null`, zero rulesets, no merge-queue entry in branch
protection). And it would not have dissolved this class anyway — a merge queue removes a
conflicting PR from the queue rather than resolving the conflict. What it removes is the
`strict: true` cost.

## Operation

```bash
scripts/conflict-rebase.py --dry-run                        # the census, pushes nothing
scripts/conflict-rebase.py --max 3                         # act on up to 3 conflicting PRs
scripts/conflict-rebase.py --include-behind --max 3        # + the staleness arm
scripts/conflict-rebase-timer.sh start                     # every 30 min, max 3/run
scripts/conflict-rebase-timer.sh status | pause | resume | stop
```

**The shipped schedule runs `--include-behind` and publishes a report every pass**
(`$STATE/last-report.md`). That is deliberate: with 0 of 36 CONFLICTING PRs rebaseable, a
pass restricted to that class can only publish refusals — the arm that actually rebases is
the staleness one. `CONFLICT_REBASE_INCLUDE_BEHIND=0` restricts a pass to the CONFLICTING
class; `CONFLICT_REBASE_DRY_RUN=1` makes every pass a census with no side effects.

**Expect a ramp on the first day.** Every refusal publishes one label + one comment, so a
queue of ~40 labelled PRs costs ~40 of each, at `--max 3` per 30-minute pass. That is the
point (it converts "unknown ownership" into "needs a human"), but it is a visible event:
pause with the brake file if the labels are unwanted.

`--checkout` (or `CONFLICT_REBASE_CHECKOUT`, defaulting to `AGENT_INFRA_PATH`) is what
makes the **detached-worktree** half of the lane-hold check work; without it the bot says
so every pass and relies on the claim registry, the head-stability window and the lease.

State lives in `~/.pi/agent/state/conflict-rebase/` (`backoff-<pr>.json`, `run.lock`,
`scratch.git`, `PAUSED`). Exit 2 means a surface could not be read — never "nothing to do".

## Guards (each one was a measured failure first)

- head identical across two `ls-remote` reads 30 s apart, **and** `--force-with-lease` bound
  to the observed sha — the second is the enforcement, the first is the manners;
- no live lane: fleet state (matched on `head_sha`, because most real lanes report
  `branch: "(detached)"`), local worktrees including **detached** ones such as the sibling
  conflict lane's `/tmp/rcwt/<PR>` directories, and `refs/claims/*` (the fleet's designed
  CAS). An unreadable lane surface refuses the pass instead of reading as "nobody holds
  it"; a board that names another repo is ignored, loudly;
- fork PRs are skipped: a head in another repository is not `origin`'s branch to push;
- a failed replay is classified by EVIDENCE (unmerged index entries) — a signing hook or a
  full disk is reported as `rebase-failed`, not as a content conflict on someone's PR;
- the cap bounds **attempts**, not successes (that bug labelled 36 PRs in one pass);
- backoff for content conflicts (1 d → 14 d) and **none** for transient refusals — a
  dropped `ls-remote` once put a PR in a 6-hour backoff and mislabelled the read as
  "peer pushing";
- `rerere` explicitly disabled: a replayed resolution is a content decision made when
  nobody is looking.

## The finding that matters more than the bot

Across the 35 refusals, five files block 29 of the PRs:

| file | PRs blocked |
|---|---|
| `MEMORY.md` | 9 |
| `scripts/orchestrator-harness/README.md` | 8 |
| `scripts/orchestrator-harness/install.sh` | 5 |
| `scripts/run-bash-shards.sh` | 4 |
| `scripts/workflow-lock.json` | 3 |

That is contention, not staleness. Splitting `MEMORY.md`, deriving `run-bash-shards.sh`
(#2609 says the same), and regenerating `workflow-lock.json` mechanically (#1170) removes
the queue's actual cause. A rebase bot cannot.

## Re-measurement (independent, 2 h later, on a different population)

The decision above rests on one sample, so it was re-taken at 2026-10-24T17:00Z by a
second lane against `origin/main@c13af5cd`: **26 `CONFLICTING` open PRs, 25 tested
(`#2517` is a draft), `git merge-tree --write-tree` clean for 0 of 25.** The hotspot
ranking reproduced (top two still `MEMORY.md` 7 and `orchestrator-harness/README.md` 6).

The queue had fallen 48 → 26 since the first census, which is the drain by hand — not a
change in the class. **A `CONFLICTING` PR is one whose content disagrees with `main`;
there is no mechanical population to harvest, at either sample.**

## Residuals (named, not fixed)

- **No per-subprocess timeout.** A hung `gh`/`git` holds the pass's `flock` for its whole
  life, and every later pass then exits 0 with "another run holds the lock". The timer now
  bounds the pass (`tb_timeout 1800`) and records the failure in `status`, so the operator
  *sees* it — the direct-invocation path (`--max 3` by hand) still has no outer bound.
- **`refs/claims/*` absent reads as "free".** Both lane surfaces that gate are per-cell;
  a lane on another cell that has not pushed yet is invisible, and the lease only refuses
  a *concurrent* push. Per the fleet's own doctrine, no-claim is an abstention, not
  freedom. Closing this needs the cross-cell board, not a change here.
- **`statusCheckRollup` carries no app slug**, so two workflows publishing the same job
  name are conflated when picking the newest attempt — the rail's own stated residual.
