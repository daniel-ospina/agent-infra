---
title: "#854 — name every reversal the hub-salvage cleanup makes (and never reverse what it did not capture) — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-10-16
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-854, issue-718, issue-1181, issue-1393, main-worktree-guard, hub-worktree
---

# Issue #854 — M4 recovery guidance silently discards an unrelated uncommitted tracked change

**Issue:** [#854](https://github.com/daniel-ospina/agent-infra/issues/854) · **Complexity:** standard · **Date:** 2026-10-16

## Objective

A sub-agent following the hub-discipline / checkout-hygiene recovery guidance must not be
able to **silently** discard an uncommitted tracked-file change belonging to another
session, and any reversal the recovery path performs must be visible in the recovering
session's own output.

## Confirmed problem (reproduced, not inferred)

The sanctioned dirty-hub recovery path is `bash scripts/checkout-hygiene/hub-worktree.sh
salvage <branch> <repo>` — prescribed verbatim by `hub-state-check.sh`'s `recovery_guide()`
(the "Terminal recovery" text, and the `refresh` dirty refusal), i.e. the text an agent in a
DIRTY hub is told to act on. Its hub-cleanup pass **reverts every tracked-modified/deleted
path in the shared main checkout to HEAD** (`git show HEAD:<path> > <path>`) and removes
untracked paths, and until this change it **printed nothing naming the paths it reversed**.

Reproduction (fixture repo, tracked `.mcp.json` modified in the hub, exactly the shape of the
2026-09-12 incident):

```
$ bash scripts/checkout-hygiene/hub-worktree.sh salvage repro/salvage-854 "$REPO"
hub-worktree: salvage: capturing dirty + untracked (junk excluded)…
hub-worktree: salvage: captured 1 path(s), 0 deletion(s), 0 junk skipped.
hub-worktree: salvage: committed on repro/salvage-854 …
hub-worktree: salvage: pushed repro/salvage-854 to origin …
hub-worktree: salvage: returning the hub to clean…

✅ Salvage complete: dirty set captured on repro/salvage-854 (pushed) and the hub is back to main+CLEAN.
```

The hub's `.mcp.json` is back to its exact HEAD bytes (mtime = the redirect), and **not one
line names it**. That is the reported symptom: the sub-agent's report can only repeat "hub
returned to main+CLEAN", the dispatcher's change now lives only on a branch nobody knows
about, and the loss is found days later by an unrelated check.

Two defects, one pass:

1. **The reversal is unnamed** — the pass that destroys uncommitted work emits no record of
   *what* it destroyed, so it cannot reach the agent's report (indicator 3 of the issue).
2. **The reversal is not gated on the capture** — the capture skip-list (env-fixture alias,
   gitlink) and the revert list are never cross-checked, so any path the capture pass could
   not preserve was reverted anyway: a reversal with no preserved copy is unrecoverable.

A third, reachable instance of the same class was found **inside the same sweep** while
reproducing (2), and is fixed here because it is the same `rm -rf` loop: with `.worktrees/`
absent from `.gitignore`, `git status --porcelain` reports the **container** `?? .worktrees/`,
and the untracked-removal arm ran `rm -rf` on it — destroying **every sibling session's live
worktree** and its uncommitted work, naming no worktree at all. Reproduced: a sibling worktree
holding an uncommitted edit was deleted by a salvage of the hub (`git diff` of the pre-fix run
shows `❌ the sibling's uncommitted edit was destroyed`). This is also a concrete candidate
deleter for [#1393](https://github.com/daniel-ospina/agent-infra/issues/1393) (a live worktree
and branch deleted mid-work, cause unestablished, evidence "the path was never named").

## Why not "make recovery non-destructive by default"

`hub-worktree.sh salvage` exists to break the dirty-on-main deadlock (#2238/#435): the hub's
only legal state is main+CLEAN, and M4 blocks every other hub verb, so capture-then-revert is
the sanctioned remedy. Making it refuse whenever the dirty set is non-empty would re-create
the deadlock and would reverse a recorded decision (issue #435's contract). The issue's own
indicators ask for **named** and **preserved**, not for the remedy to be removed.

Rejected alternatives:

- **Refuse by default when the dirty set is non-empty** (re-create the #2238 deadlock;
  reverses #435's contract). Rejected.
- **Snapshot the hub's dirty set at dispatch time from the `task` wrapper**, so a reversal is
  detectable without trusting the child's report — the issue's research question 4. Larger
  surface (the dispatch machinery), and its hard half is per-path **authorship attribution**,
  which is exactly the open design of [#718](https://github.com/daniel-ospina/agent-infra/issues/718)
  ("loss is undetected and recovery depends on an unrelated salvage"). Not absorbed here;
  cross-referenced, not duplicated.
- **A durable reversal ledger** (JSONL under `~/.pi/agent/state/`). Rejected for now: the
  report contract below satisfies the issue's own checklist ("a discarded change is reported
  **or** the dispatch record shows the pre-state"), and a new state file needs an owner and a
  retention bound. If the report proves insufficient, the ledger belongs with #718's
  attribution work.
- **Make M4 attribute "dirty because of me"** (research question 3). Same reason: it needs
  per-path authorship, which does not exist yet. The named reversal is the achievable half.

## Plan (implemented)

| # | Change | File |
|---|---|---|
| 1 | The cleanup pass **names** every path it reverts (`↩ reverted to HEAD … lives ONLY on <branch>`) and every path it removes, before any exit path, plus a summary line repeated after `✅ Salvage complete` so a clean exit cannot swallow it | `scripts/checkout-hygiene/hub-worktree.sh` |
| 2 | The **capture set is the allowlist**: a tracked path absent from it is left untouched, named, and salvage exits 1 (`remaining` is non-empty) instead of reporting a cleaned hub | same |
| 3 | One porcelain snapshot read into a variable (no pipeline → no subshell), with an explicit failure arm: an unreadable `git status` is not "nothing to clean" | same |
| 4 | `.worktrees/` is never captured (a copy would carry sibling trees and the push would publish them) and never removed (it is the isolated-work container); it is named, and the hub is reported NOT clean | same |
| 5 | The guidance that prescribes salvage states the contract — it REVERTS tracked dirt to HEAD, it NAMES every path, report any path you did not author | `scripts/checkout-hygiene/hub-state-check.sh` (3 sites), `hub-worktree.sh` refresh refusal |
| 6 | Regression tests for 1–4, each proven non-vacuous against the pre-fix script | `hub-worktree.test.sh`, `hub-state-check.test.sh` |

Not changed: the M4 block message text in `extensions/main-worktree-guard` (it points at the
**create** mode `hub-worktree.sh <branch>`, which never mutates the hub), and the public
TortoiseSDK / MCP tool registry (owner-gated).

## Adversarial threat surface

**(not adversarial)** — this is a recovery-scenario script, not gate/enforcement code whose
correctness is "an attacker cannot make it fail open". The invariant added (never revert what
you did not capture) is fail-closed by construction, and the reset/force-discard paths it
replaces are the guard's own M5 surface (`#709`), which is unchanged.

## Acceptance / verification

| Surface | Layer | Test |
|---|---|---|
| The cleanup names the reverted path AND the removed path, and the reversal really happened | integration | `hub-worktree.test.sh` §6b |
| A tracked `.mcp.json` (the incident file) is reverted to HEAD byte-exact **and** preserved on the branch | integration | §6b |
| No reversal record is emitted when nothing was reversed (the record is a measurement, not a ritual) | contract | §6b |
| A sibling worktree with an uncommitted edit survives the untracked sweep when `.worktrees/` is not gitignored | integration | §6c |
| The recovery guidance states the reversal contract | contract | `hub-state-check.test.sh` §2 |

## Wiring

| Touch Point | Type | Covered By | Status |
|---|---|---|---|
| `hub-worktree.sh salvage` cleanup pass | script (destructive) | rows 1–4 above | ✅ |
| `hub-state-check.sh` recovery guidance (detached+dirty, dirty-on-main, off-main+dirty) | script (agent-facing text) | row 5 | ✅ |
| `hub-worktree.sh refresh` dirty refusal (names salvage) | script (agent-facing text) | row 5 | ✅ |
| `run-bash-shards.sh` (the ONE PR+main shard list) | CI | both suites are already listed (lines 125–126) — no new file, no manifest change | ✅ |
| `docs/plans/` plan doc (pipeline-compliance check d) | process artifact | this file | ✅ |
| Dispatch-time dirty-set snapshot / per-path authorship | not built | #718 (detection + attribution) | ⚠️ out of scope, cross-referenced |

## Evidence

- Shard-run attempt (`bash scripts/run-bash-shards.sh`, sandbox, git 2.43): reached shard ~20
  of 32 before the 1500 s budget was exhausted; the only failure observed was the pre-existing,
  environment-gated `hub-state-check.test.sh` relative-worktree-record fixture (see below).
- `TMPDIR=<non-/tmp> bash scripts/checkout-hygiene/hub-worktree.test.sh` → **138 passed, 0 failed**
  (124 passed, 0 failed before this change; the 14 new assertions are §6b/§6c).
- `TMPDIR=<non-/tmp> bash scripts/checkout-hygiene/hub-state-check.test.sh` → 165 passed,
  1 failed (164 passed, 1 failed on the pristine HEAD copies) — the failure is `fixture: git wrote a RELATIVE record for this worktree`
  (`worktree.useRelativePaths` needs git ≥ 2.46; this sandbox has 2.43). Identical on the
  pristine HEAD copy of both files (verified by stashing them), and `bash-suites` is green on
  recent PRs — so it is environmental, not a regression, and not filed.
- Non-vacuity: with the pre-fix `hub-worktree.sh` restored, the new §6b/§6c assertions fail
  **8/8** — including `❌ #854: the sibling's uncommitted edit was destroyed`.
