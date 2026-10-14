# Cross-box claim registry — source export

**From:** `Daniels-MacBook-Air` (8 CPU/8 GB box, `REPO=/Users/home/eldato/tortoise`, `O=/Users/home/orchestrator`)
**To:** every other box — this is the transfer the other laptop asked for via tortoise#8603.
**Date:** 2026-10-14 · **Issues:** agent-infra#1709 (research + measured results), tortoise#8603

> **Placement note: agent-infra `scripts/orchestrator-harness/` is the correct home.** tortoise's
> `operations/orchestrator-harness/` was the accidental copy; it is still present on tortoise
> `origin/main` and is **stale** (verified: its `chain-merge.sh` differs from both agent-infra's and
> this box's). Prefer agent-infra and treat the tortoise copy as dead.

---

## ⚠️ Read this before copying anything

**Do not copy `files/` over `scripts/orchestrator-harness/`.** This box's harness has drifted from
agent-infra's canonical copy *independently of* the cross-box work — `orch-loop.sh` differs by
**392 lines** that are not mine. `chain-merge.sh` is byte-identical; the rest are not.

Measured against agent-infra `origin/main` (`8e2daf3`):

| file | agent-infra | this box | total delta | of which my edits | patch applies? |
|---|---|---|---|---|---|
| `orch-loop.sh` | `08ab705f` | `df201b67` | 456 | **66** | ❌ **NEEDS MANUAL MERGE** (10 hunks, misordered) |
| `merge-one.sh` | `eb0e2bc5` | `4cef58a4` | 68 | ~30 | ❌ **NEEDS MANUAL MERGE** (1 of 3 hunks fails) |
| `lane.sh` | `c3a18518` | `bc5f9fc1` | 15 | 14 | ✅ applies cleanly (2 hunks) |
| `fix-one.sh` | `b68ac493` | `53dbdaf9` | 29 | 27 | ✅ applies cleanly (2 hunks) |
| `chain-merge.sh` | `8fade1f0` | `8fade1f0` | 0 | 0 | n/a — identical |

So: `lane.sh` + `fix-one.sh` can be patched directly. **`orch-loop.sh` and `merge-one.sh` need a
real merge** — take the cross-box hunks, keep agent-infra's newer structure around them.

Note agent-infra's `orch-loop.sh` has **no** cross-box code (`refs/claims` × 0) but has evolved
elsewhere (`mp_reason` × 6 vs 4 on this box), so a blind overwrite would revert that.

---

## Contents

```
files/                       the actual live files from this box (for reference / diffing)
crossbox-changes.patch       minimal edits ONLY (my work), base = this box's pristine backups
divergence.txt               hashes + deltas vs agent-infra and vs tortoise
```

`crossbox-changes.patch` (321 lines) covers `orch-loop.sh`, `merge-one.sh`, `lane.sh`, `fix-one.sh`.
The four new files are not in it — copy them whole:

- `claims.sh` — the registry (~11 KB)
- `test-claims.sh` — 18 assertions, two clones, against live origin
- `test-crossbox.sh` — end-to-end through the real `merge-one.sh`
- `test-gates.sh` — `mp_reason` rule table, 10 assertions

---

## What the protocol is

`refs/claims/*` in the repo both boxes already share — `git push` to a ref is an **atomic CAS**, so
no broker, no service, no new infrastructure.

| # | property | implementation |
|---|---|---|
| 1 | **content-addressed key** | `refs/claims/<PR>-<head-sha12>`, not `<PR>` — two boxes on the same head is duplicate work, a box on a newer head is new work |
| 2 | **atomic create + read-back** | `git push origin <commit>:refs/claims/<key>`; every claim commit is a **root** commit so a different claim can never fast-forward it. The ref is **read back** to confirm ownership, not trusted from the exit code |
| 3 | **lease is data, not liveness** | `owner` + `lease_until` in the claim commit message — a remote pid cannot be probed with `kill -0` |
| 6 | **fencing** | every release/reclaim is `--force-with-lease=<ref>:<observed-sha>`: a box that lost ownership **cannot** release the winner's claim |
| 4 | **jitter** | ±20% of the 240 s cycle so boxes stop waking together |

Namespace rationale: `refs/claims/*` is **outside** `refs/heads/*`, so it matches no `on: push:`
trigger in any workflow and never appears as a branch.

Wiring: `merge-one.sh` resolves HEAD **before** claiming and exits 0 if another box owns that head.
`orch-loop.sh` refreshes **every** claim in **one** fetch/cycle into `state/claims-snapshot`;
`claim_live` answers from that file, so the sweep pays no per-PR network call. Layering matters:
**the snapshot is an optimisation, the acquire-time CAS is the authority** — a stale snapshot costs
at most a wasted spawn, never a duplicate review.

**Fail-open on purpose.** If the claim store is unreachable, the harness proceeds and **logs** it.
agent-infra#1709's headline finding is that duplicate execution is unavoidable and side effects must
be idempotent per head; failing closed would stall the whole fleet on one transient network error.

Lease is **derived**, not constant: `CLAIM_LEASE=$(( REVIEW_TIMEOUT + 1200 ))`, so it outlives a
worst-case review + the 30×30 s gate wait. (A bare constant silently lost to `CLAIM_TTL=1800` set at
source time — that was a real bug found during the work.)

---

## Verify it before trusting it

```bash
# 0. the primitive + lease + fencing, two clones racing the live remote
cd /Users/home/tortoise && bash test-claims.sh      # expect: 18 passed, 0 failed
# 1. end-to-end through the real merge-one.sh (hermetic: gh injected as a bash function)
bash test-crossbox.sh
# 2. the dispatch-gate rule table
bash test-gates.sh                                  # expect: 10 passed, 0 failed
```

Live evidence: the protocol is **already running on origin** right now —
`git ls-remote origin 'refs/claims/*'`. Claims appear while a reviewer runs and are **released by
`merge-one.sh`'s `EXIT` trap**; after an abrupt stop (user switch) all held claims were released,
leaving 0 orphans.

---

## Also in this diff (same session, same reason)

- `run_agent()` records **elapsed** wall-time into append-only `state/walltime.tsv`. The per-PR logs
  it also writes are **truncated on rerun**, which destroyed three real samples within minutes — the
  series had to be append-only to be collectable at all.
- `[dispatch] skipped (…) lanes=N workers=N` — the `workers` counter made "blocked while busy vs
  idle" answerable. Measured: **4/4 blocks were while BUSY** (`lanes=0 workers=8`), so raising
  `MERGE_PRIORITY_AT` would have added WIP with no throughput.
- `mp_reason` now counts **`lanes + workers`**, so "the box has in-flight work" means in-flight
  work, not "a lane happens to be running".

## Two open follow-ups (do not re-derive)

- **agent-infra#1741** — a verdict-less timeout must not consume `MAX_FIX_TRIES`; that is what turns
  a stall into a **false park** (4 PRs: 8115, 8221, 8281, 8370).
- **Recs 5 & 7** from #1709 are still open: affinity (prefer PRs this box recently reviewed) and
  verifying `record-review.sh`'s marker is idempotent per head.
- **Corrected:** #1741's original advice to *raise the caps* was wrong and is superseded — a stalled
  call burns double the wall-clock and holds the slot twice as long. See #1746.
