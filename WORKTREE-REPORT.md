# WORKTREE-REPORT — lane-liveness-fix (log-lane axis of `tools/fleet/liveness.py`)

- **Worktree:** `/home/cmux/agent-infra/.worktrees/lane-log-liveness`
- **Branch:** `fix/lane-log-liveness` (base: agent-infra `main` @ `91a3b29be`)

## Files changed

- `tools/fleet/liveness.py` — the ONE verdict function, extended with the log-lane evidence axis
- `tools/fleet/liveness.test.py` — 7 new tests (T32–T38) + 6 paired mutations
- `docs/ops/fleet-liveness.md` — new §13 (states, signals, resolution, window, what this is not)

## Suites run

| command | result |
|---|---|
| `python3 tools/fleet/liveness.test.py` | **38 tests, PASS=38 FAIL=0** |
| `python3 tools/fleet/liveness.test.py --mutations` | **MUTATIONS=44 CAUGHT=44 MISSED=0** |
| `LIVENESS_ONLY=T32..T38` against `main`'s `liveness.py` (pre-fix copy in a detached scratch worktree) | **FAIL T32 … FAIL T38 (7/7 RED)** |

## Not done

- **No reader is wired.** The `[cap]` census (`lane-reap.sh count`) still keys on log mtime; adopting
  the axis there needs a two-sample window on an every-cycle path — a separate design change. Filed
  as a follow-up, not bolted on here.
- `tools/worktree_report.py` does not exist in agent-infra, so this report is hand-written.
- No `lane-reap.sh` / kill-path file was touched: this lane changes the INSTRUMENT, not any live lane.
