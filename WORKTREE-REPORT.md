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
| `python3.12 tools/fleet/triage.test.py` | `PASS=223 FAIL=0` |
| `python3.12 tools/fleet/triage.test.py --red-control` | `exit=0` (12 RED controls, all fired) |
| `/tmp/pyenv4046/bin/python -m pytest scripts/test_bounce_state.py scripts/test_dispatch_wiring.py scripts/test_turn_classify_state.py scripts/test_lane_relaunch.py -q --timeout=180` | `137 passed in 14.64s` |
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

## What changed

```
tools/fleet/triage.py          NEW  the router: precedence, wedged subcases, remedies, proof table
tools/fleet/triage_arms.py     NEW  the three arms, each proving its effect at its artifact
tools/fleet/triage.test.py     NEW  hermetic suite, 223 assertions, 12 RED controls
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
