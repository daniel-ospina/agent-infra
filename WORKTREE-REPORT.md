# WORKTREE REPORT — agent-infra #4046 · `fix/4046-lane-triage`

Worktree: `/home/cmux/agent-infra/.worktrees/4046-triage`
Branch: `fix/4046-lane-triage`
Base at branch point: `c42b1ba04` — `fix(harness): grade the review stage on its own last pass… (#4037)`

⛔ **`tools/worktree_report.py` DOES NOT EXIST IN THIS REPO.** The brief says to use it "if it does not
exist here, say so in the report rather than inventing counts" — so this file is written by hand and
every number below is a MEASURED tail of a command run in this worktree, never an assertion. Each
command is quoted verbatim so it can be re-run.

## Suites, verbatim, as measured

| command | result |
|---|---|
| `python3.12 tools/fleet/triage.test.py` | `PASS=297 FAIL=0` |
| `python3.12 tools/fleet/triage.test.py --red-control` | `exit=0` (12 RED controls, all fired) |
| `/tmp/pyenv4046/bin/python -m pytest scripts/ -q --timeout=300` | `1436 passed, 3 skipped, 1 xpassed in 216.67s` |
| `python3.12 tools/fleet/liveness.test.py` | `PASS=58 FAIL=0` (+ `every stated count matches the suite (58 tests, 113 mutations)`) |
| `bash pi-bootstrap/tests/test-setup-no-nesting.sh` | `FAILURES: 1` — **PRE-EXISTING, base-owned** (see below) |
| `bash scripts/check-farm-drift.sh` | `UNKNOWN — COMPARING AGAINST THE WRONG TREE` (rc 0): the box is pinned at `d5c6dc7530` and this worktree is at `330ac09c0`. Not a red, and not a green — it refuses to compare across a pin, which is the behaviour it documents. |

**pytest was not installed on this box** (`python3.12 -m pip install pytest` → `Errno 13: Permission
denied: /opt/freestyle/python/lib/python3.12/site-packages/iniconfig`; a `--user` install is refused
because the interpreter is already a virtualenv). Rather than skip the Python suites, a throwaway venv
was created at `/tmp/pyenv4046` and pytest/pytest-timeout installed there — that is the interpreter
behind every `pytest` row above. No repo file was changed to work around it.

## The one red, and why it is not this branch's

`pi-bootstrap/tests/test-setup-no-nesting.sh` reports:

```
FAIL: producer-set: the DERIVED producer population is not the pinned set — a producer moved.
ADDED: none | REMOVED: script:conflict-rebase.py .
```

Reproduced with `pi-bootstrap/setup.sh` checked out UNMODIFIED (`git checkout pi-bootstrap/setup.sh`,
run, then restored), so it is base-owned. Per AGENTS.md it is recorded rather than fixed here (its
category is the pin/marker class), and it is disclosed in the PR.

## Round 3 — an independent reviewer's findings, verified before applying

A second fresh-context review (dispatched by the second lane on this worktree) returned at
`228699917`; every finding was re-verified against the CURRENT head before anything was applied, and
two were falsified and dropped. Measured on the final head:

| finding | verdict | evidence |
|---|---|---|
| **[P0]** `retry_signature`'s bare `429` + an ungated `model-retry` branch → a WORKING lane routed `rerun` (a relaunch) | **CONFIRMED, FIXED** | `retry_signature("Merged PR #14290 and verified all checks.")` was `True`; a `WORKING` lane routed `wedged/model-retry` → `rerun`. Now `\b429\b`, last-paragraph-scoped, and gated on `_turn_open(ev)` + not in `WORKING_VERDICTS`. |
| **[P1]** `arm_child` read keys the producer never emits, and synthesised a child name from a state word | **CONFIRMED, FIXED** | producer (`lane-status.py:1586-1590`) emits `call_id/ts/age/abandoned/cwd/task/agent`; a real record gave `verified=False`, and `child_state`-only gave `verified=True` off `{'name': 'stuck'}`. Now reads the producer's key set; the synthesis is deleted. |
| **[P1]** question followed by ≥2 status sentences still reached `send-continue` | **already fixed** by the round-2 commit (`798e987fc`) — the paragraph window is gone | re-measured: 8 must-ask shapes × → 0 leaks |
| **[P1]** the question arm's mandate read-back was vacuous (`CmuxSurface` had no `last_sent`) | **already fixed** in `798e987fc` | `scripts/lane-route.py:99,137` record the flattened payload; the arm reads it at `triage_arms.py:245` |
| **[P2]** `arm_boot_prompt` hardcoded `sent=True` | **already fixed** in `798e987fc` | no `sent=True` literal remains; `sent=rc in (0, 4)` |
| **[P2]** `confirm`/`approve` matched as bare substrings | **already fixed** in `798e987fc` | `_ASK_FRAME`/`_HANDOFF` split; `"Confirmed the fix and merged it."` → `not-asked` |
| **[P2]** R6 was a fixed-string assertion that could not fail | **⛔ FALSIFIED — NOT APPLIED** | measured: disabling the fence stripper makes the same input answer `asked`, so R6 does discriminate. It was still STRENGTHENED into a mutation control (disables `_FENCE_RE`, requires the answer to change). |
| **[P2]** the wiring leg cannot catch wrong arguments to `steerable()` | **CONFIRMED, FIXED** | the leg only checked the `if not _may:` window; the P0 in `228699917` was wrong ARGUMENTS at that call site. Now pins `sid`/`ws=`/`session_path=` in the `_triage.steerable(` call. |
| **[P2]** CI comment said "seven ways", the suite runs twelve controls | **CONFIRMED, FIXED** | `.github/workflows/ci.yml:620` |

Behaviour re-measured after the fixes (`python3.12`, importing the real modules):
`#14290` → `retry_signature=False`; `WORKING`/`UNATTRIBUTED-WORKING`/`LONG-TOOL`/`WAITING-CHILD` + an
open turn + a retry tail → `route=none`; a closed turn + retry tail → `wedged-unverified`/`inspect`; an
open turn + retry tail → `model-retry`/`rerun` (the positive control, still reachable); a real
`lane-status` child record → `verified=True`; `child_state` alone → `verified=False`, no fabricated child.

## What changed

```
tools/fleet/triage.py          NEW  the router: precedence, wedged subcases, remedies, proof table
tools/fleet/triage_arms.py     NEW  the three arms, each proving its effect at its artifact
tools/fleet/triage.test.py     NEW  hermetic suite, 254 assertions, 12 RED controls
scripts/lane-route.py          NEW  operator CLI (route / --json / --apply)
scripts/turn-end.py            MOD  gates its WIP nudge on triage.may_continue()
pi-bootstrap/setup.sh          MOD  farms triage.py + triage_arms.py into $DEST/scripts/fleet
.github/workflows/ci.yml       MOD  two steps: the suite, and its RED controls alone
docs/ops/fleet-liveness.md     MOD  §0z: a verdict is not a route; `wedged` means two things
```

## Measured on the real fleet (routing-only, no arms executed)

`python3.12 scripts/lane-route.py` on this box routed 7 rows, every one `none` — the box's cmux
terminals have all exited (`lifecycle: exited` in `cmux tree --json`), so no lane earned an arm. That is
a truthful reading of an idle box, not a demonstration; the arm demonstrations are the suite's fixture
legs.

The first version of the CLI routed **nothing at all** and reported success, because it looked for
`lane-status.py` only in `$HOME/.pi/agent/scripts` — where it **does not exist on this box**, and whose
absence is a recorded decision (#1553 withholds it from the farm). Fixed to resolve repo-first and to
say which path it used; a reader that only looked in `$SCRIPTS` reads "no lane-status" as an idle fleet.
