# Worktree report — agent-infra#4034 (5× lane backstop as the repository default)

Worktree: `/home/cmux/agent-infra/.worktrees/4034-backstop`
Branch: `fix/4034-backstop-5x` · base: `origin/main` (`319c82526`)
`tools/worktree_report.py` and `scripts/worktree_report.py` **do not exist in this repository** — there is
no generated suite summary from them. Everything below is hand-copied from the run logs named in each row.

## Suite results (this tree, this head's parent; commands verbatim)

| # | command | result | log |
|---|---|---|---|
| 1 | `bash scripts/orchestrator-harness/lane-bound.test.sh` | **77 passed, 0 failed** | `~/.pi/agent/state/4034-baseline/lane-bound.final2.log` |
| 2 | `bash scripts/orchestrator-harness/lane-merge.test.sh` | **ALL 207 lane-merge checks passed** | `…/lane-merge.run3.log` |
| 3 | `bash scripts/orchestrator-harness/claim-orphan.test.sh` | **150 passed, 0 failed** | `…/claim-orphan.final.log` |
| 4 | `bash scripts/orchestrator-harness/branch-claim.test.sh` | **53 passed, 0 failed** | `…/branch-claim.final.log` |
| 5 | `bash scripts/orchestrator-harness/test-claims.sh` | **301 passed, 0 failed** | `…/test-claims.run2.log` |
| 6 | `bash scripts/orchestrator-harness/ai-drainer.test.sh` | **194 passed, 0 failed** | `…/ai-drainer.final.log` |
| 7 | `uv run --quiet --with pytest --with pytest-timeout python3.12 -m pytest scripts/test_pr_doctor.py scripts/test_lane_registry.py -x --timeout=60 -q` | **375 passed** | `…/pytest.after.log` |
| 8 | `npx tsx extensions/shared/heartbeat-progress-edges.test.ts` | **33 passed, 0 failed** | `…/heartbeat.after.log` |
| 9 | `for f in $(git diff --name-only origin/main...HEAD -- '*.sh'); do bash -n "$f"; done` | **no output (all OK)** | — |
| 10 | `python3 -c 'ast.parse(...)'` over `lane_registry.py`, `pr-doctor.py`, `tools/fleet/liveness.py` | **OK** | — |

### Flake, stated rather than hidden

Run 1 of suite 1 was executed concurrently with suites 3 and 4 and reported **76 passed, 1 failed**:

```
❌ (i1) …and it really was progressing the whole way (silent=2s < 2s, elapsed=10s)
```

That arm samples a fixture that prints once a second and asserts the last growth was < 2 s before the
kill; on a box running three suites at once the sampling landed exactly on the 2 s boundary. A solo
re-run of the same file on the same tree is **77 passed, 0 failed** (`final2.log`), and the two new
`(i0)` arms — the ones this change adds — passed in **both** runs. It is a timing assertion in a test
this change does not touch; it is not repaired here.

### Baseline (before the change), for the delta

| suite | baseline | after |
|---|---|---|
| `claim-orphan.test.sh` | 150 passed | 150 passed |
| `lane-bound.test.sh` | 75 passed | **77 passed** (the two new `(i0)` arms) |
| `lane-merge.test.sh` | 207 passed (7200 s clock) | **207 passed** (36000 s clock — re-derived, not re-labelled) |
| `test-claims.sh` | not run before the change | 301 passed |

## What the change is

- `LANE_BACKSTOP_S` **7200 → 36000** (5×, the top of #4034's 3–5× range) as the compiled default in
  `scripts/orchestrator-harness/spawn-gate.sh`, and every literal copy of the seam follows it.
- `CLAIM_TTL_MAX` **9600 → 43200**, `CLAIM_ISSUE_TTL` **18000 → 48000**,
  `CLAIM_UNREADABLE_LEASE_MAX_AGE` **18000 → 48000** — because `fix-one.sh` derives its claim lease as
  `LANE_BACKSTOP_S + 1200` = **37200 s**, and `claims.sh` **clamps** a lease above `CLAIM_TTL_MAX`,
  silently expiring the claim under a worker still inside its own bound (a second fixer on the same
  head, #2888).
- `LANE_REAP_LIVE_MIN` **125 → 601 min** — an mtime-only liveness window must sit above the wall backstop.
- The 45-minute PROGRESS allowance is **untouched** (`lane-bound.sh --idle` default 2700,
  `DEFAULT_PROGRESS_AGE_MS`).

## Evidence behind the number (measured, not estimated)

`pi-cell-4`, 2026-11-12, **2,033 lane logs**: **20** `verdict=exceeded-wallclock` vs **2** `stalled`;
**12** of the 20 carried `silent=0s` and **12** `cpu_delta_cs > 0`, i.e. the watchdog's own idle detector
said the lane was **not idle** when the clock ended it — so the 2700 s progress rule never got its window.
One lane was killed mid-`git push` holding 12 commits and four review rounds.

## Residuals, stated

1. `CLAIM_ISSUE_TTL` (48000) covers the default-gate merge sum (46290) with 810 s spare, but a box with
   `GATE_POLL_SECS=60` has a merge term of 6000 and a sum of **49290 — 1290 s over**. Pre-existing (it was
   20490 vs 18000 before), now stated correctly in `claims.sh` instead of mis-summed.
2. `claim-reaper.sh`'s `CR_MIN_AGE` (10800) is a belt, not the longest lease, and did not follow the
   leases up; release still requires holder-absence evidence and branch keys abstain. Prose corrected.
3. The lane-bound timing arm in the flake note above.
4. No MCP/SDK surface changed; no Tortoise graph read or written; no cell `keys.env` touched.

## CI failures this change does NOT cause (measured, with the evidence)

`bash-suites` and `sigpipe-grep` were red on this head. Two of the three failing shards are not this
change, and one WAS — it is fixed in the last commit:

| check | failing arm | verdict |
|---|---|---|
| `bash-suites (4)` → `lane-reap.test.sh` | `EVIDENCE-TEE-LSOF` census (`want lanes=0/1, got 1/1`), `COUNT`/`COUNT-NO-EVIDENCE`/`FALLBACK` (`want lanes=1/2, got 2/2`) | **CAUSED HERE.** The suite hardcoded 3 h / 6 h "stale" fixture ages; `LIVE_MIN` moved 125 → 601 min, so those ages fell INSIDE the live window. Fixed by deriving the age from the shipped window (`(LIVE_MIN + 60) * 60`), same discipline as `lane-bound.test.sh` (i0). Re-run: **233 passed, 0 failed** (and 233/0 at `origin/main`). |
| `bash-suites (5)` → `rail-run.test.sh` | `CONCURRENT: two racing starts reach the rail exactly ONCE (want rc=1, got rc=2)`, `want one rc=0 and one rc=3, got rc=0 and rc=0` | **NOT caused here.** `250 passed, 0 failed` locally on THIS tree and on a scratch worktree at `origin/main` — the legs race two launchers and are load-sensitive. |
| `bash-suites (4)` → `mac-pin-parity.test.sh`, `pi-bootstrap/tests/test-setup-no-nesting.sh` | `daemon PATH cannot run cmux …` | **NOT caused here.** No mac-pin / bootstrap file is touched by this PR; the arms need a `cmux` on the runner's PATH. |
| `sigpipe-grep` | `scripts/record-review.test.sh — 3 occurrence(s), undeclared` | **NOT caused here.** Identical failure on `origin/main`'s own head `319c82526` (run 43449271686, job 131966848513), in a file this PR does not touch. |
| `pipeline-compliance` | `[b] no scoping comment`, `[c] no head-bound code-review record` | `[b]` fixed by posting the scoping record on #4034; `[c]` is the **harness reviewer's** artifact (`record-review.sh` at the final head) — not self-certified here. |

⚠️ **`origin/main` is red on `sigpipe-grep-guard` as of `319c82526`** — recorded here because it makes
every PR that touches `scripts/` look red for a reason unrelated to it.

## Not done here (by instruction)

- **No merge.** The final head is pushed and left for the harness reviewer (`merge-one.sh`) to mint the
  attestation with `record-review.sh`.
- The constants take effect on the **next dispatch**; this lane's own bound was fixed at spawn, so nothing
  in this run could verify 36000 empirically end-to-end. The `cap=` field on the `launched` line is the
  field that reads it back.
