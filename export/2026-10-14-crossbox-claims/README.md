# Cross-box claim registry — source export

**From:** `Daniels-MacBook-Air` (`REPO=/Users/home/eldato/tortoise`, `O=/Users/home/orchestrator`)
**For:** agent-infra `scripts/orchestrator-harness/` — requested by the other laptop via tortoise#8603.
**Issues:** agent-infra#1709 (research + measurements), tortoise#8603, tortoise#8602, agent-infra#1746

> **agent-infra is the correct home.** tortoise's `operations/orchestrator-harness/` was the
> accidental copy and is **still on tortoise `origin/main`**; it is stale (its `chain-merge.sh`
> matches neither agent-infra's nor this box's). Prefer agent-infra; delete the tortoise copy.

---

## ⚠️ Do not copy `files/` over `scripts/orchestrator-harness/`

This box has drifted from agent-infra **independently of the cross-box work**. Measured against
agent-infra origin/main at export time — see `divergence.txt` for the hashes:

| file | total delta vs agent-infra | patch applies? |
|---|---|---|
| `orch-loop.sh` | large (pre-existing drift, not all mine) | ❌ **manual merge** — hunks overlap agent-infra's newer structure |
| `merge-one.sh` | moderate | ❌ **manual merge** |
| `lane.sh` | small | ✅ applies cleanly |
| `fix-one.sh` | small | ✅ applies cleanly |
| `chain-merge.sh` | **0 — identical** | nothing to do |

agent-infra has **no** cross-box code (`refs/claims` × 0) but has evolved elsewhere, so a blind
overwrite would revert it. Take the hunks, keep agent-infra's surrounding structure.

## Contents

```
files/                    the live files from this box (for diffing / reference)
crossbox-changes.patch    the cross-box work only, base = this box's pristine backups
stall-fix-prompt.patch    the agent-prompt stall fix, base = pre-fix copies
divergence.txt            hashes + deltas vs agent-infra
REVIEW-FINDINGS.md        independent review + the defect it caught in the first version
```

Four files are **new** (not in any patch — copy whole): `claims.sh`, `test-claims.sh`,
`test-crossbox.sh`, `test-gates.sh`.

## The protocol

`refs/claims/*` in the repo every box already shares — `git push` to a ref is an **atomic CAS**.
No broker, no service, no new infrastructure.

| property | implementation |
|---|---|
| content-addressed key | `refs/claims/<PR>-<head-sha12>` — two boxes on the same head is duplicate work; a newer head is new work |
| atomic create + read-back | `git push <commit>:refs/claims/<key>`; claim commits are **roots**, so a different claim can never fast-forward it. The ref is **read back** — the exit code alone is not trusted |
| lease is **data**, not liveness | `owner` + `lease_until` in the claim commit message: a remote pid cannot be probed with `kill -0` |
| fencing | release/reclaim use `--force-with-lease=<ref>:<observed-sha>` — a box that lost ownership **cannot** delete or overwrite the winner's claim |
| jitter | ±20% of the 240 s cycle, so boxes stop waking together |

`refs/claims/*` is outside `refs/heads/*`, so it matches no `on: push:` trigger and never appears
as a branch.

Wiring: `merge-one.sh` resolves HEAD **before** claiming, and exits 0 if another box owns that head.
`orch-loop.sh` refreshes **all** claims in **one** fetch/cycle into `state/claims-snapshot`;
`claim_live` reads that file. **The snapshot is an optimisation; the acquire-time CAS is the
authority** — a stale snapshot costs a wasted spawn, never a duplicate review.

**Fail-open on purpose:** if the store is unreachable the harness proceeds and **logs** it. #1709's
finding is that duplicate execution is unavoidable and side effects are idempotent per head; failing
closed would stall the fleet on one transient error.

Lease is derived: `CLAIM_LEASE=$(( REVIEW_TIMEOUT + 1200 ))` so it outlives a worst-case review plus
the 30×30 s gate wait. (A bare constant silently lost to `CLAIM_TTL=1800` at source time — a real bug
found during the work.)

## The stall fix — the reason reviewers were returning nothing

A reviewer's cwd is the **main checkout, which has no `.venv`** (251 of 302 worktrees do), yet the
prompt told it to run `.venv/bin/python`. So it hunted for an interpreter and escalated to
`find /Users/home` — measured **>120 s cold, ~25 min under load** — consuming the entire 1800 s
budget with **no verdict** (43 of 124 runs cap-hit; 7 of 7 recent cap-hits returned nothing).

Now: the reviewer is told test execution is unavailable, must not search outside the repo root, and
must report `UNVERIFIED` + the exact settling command. The fixer (whose worktree does have `.venv`)
keeps execution; `fix-one.sh`/`lane.sh` gained the same no-search bound.

> ⚠️ **The prompts live in UNQUOTED heredocs.** Every backtick must be escaped as `` \` ``. The first
> version of this fix used bare backticks, which would have **executed `uv sync` at prompt-build
> time** and spliced an `ls` listing into the prompt, erasing the word `UNVERIFIED`. Caught in
> review; fixed and verified by expanding the heredoc with command shims (0 substitutions).

## Verify before trusting

```bash
bash test-claims.sh     # two clones racing live origin — 18 ordered assertions
bash test-crossbox.sh   # end-to-end through the real merge-one.sh (hermetic gh stub)
bash test-gates.sh      # dispatch-gate rule table — 10 assertions, offline
```

`test-crossbox.sh` as shipped expects `files/merge-one.sh` and two local clones — adjust its paths.
Live check: `git ls-remote origin 'refs/claims/*'` — claims appear while a reviewer runs, and are
**released by `merge-one.sh`'s `EXIT` trap** (verified: an abrupt stop left 0 orphans).

## Also in this diff

- `run_agent()` writes **elapsed** wall-time to append-only `state/walltime.tsv` (the per-PR logs are
  truncated on rerun and destroyed three real samples within minutes).
- `[dispatch] skipped (…) lanes=N workers=N` — measured **4/4 blocks were while BUSY**
  (`lanes=0 workers=8`), so raising `MERGE_PRIORITY_AT` would add WIP with no throughput.
- `mp_reason` counts **`lanes + workers`** — in-flight work, not "a lane happens to be running".

## Open follow-ups — do not re-derive

- **agent-infra#1741** — a verdict-less timeout must not consume `MAX_FIX_TRIES`; that is what makes a
  stall a **false park**. Also: `fixcount` is **not keyed on the head SHA**, so a counter accumulated
  at a superseded revision re-parks a PR at its new head.
- **#1709 recs 5 & 7** — affinity, and verifying `record-review.sh`'s marker is idempotent per head.
- **Corrected:** #1741's original advice to *raise the caps* was wrong (superseded by #1746).
