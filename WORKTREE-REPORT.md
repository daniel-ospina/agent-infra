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
| `python3.12 tools/fleet/triage.test.py` | `PASS=439 FAIL=0` |
| `python3.12 tools/fleet/triage.test.py --red-control` | `exit=0` (17 RED controls, all fired) |
| `uv run --quiet --with pytest --with pytest-timeout python -m pytest scripts/ -q --timeout=180` | `1436 passed, 3 skipped, 1 xpassed in 216.96s` |
| `python3.12 tools/fleet/liveness.test.py` | `PASS=58 FAIL=0` (+ `every stated count matches the suite (58 tests, 113 mutations)`) |
| `bash pi-bootstrap/tests/test-setup-no-nesting.sh` | `FAILURES: 1` — **PRE-EXISTING, base-owned** (see below) |
| `bash scripts/check-farm-drift.sh` | `UNKNOWN — COMPARING AGAINST THE WRONG TREE` (rc 0): the box is pinned at `d5c6dc7530` and this worktree is at `330ac09c0`. Not a red, and not a green — it refuses to compare across a pin, which is the behaviour it documents. |

**pytest was not installed on this box** (`python3.12 -m pip install pytest` → `Errno 13: Permission
denied: /opt/freestyle/python/lib/python3.12/site-packages/iniconfig`; a `--user` install is refused
because the interpreter is already a virtualenv). The suites above run through `uv run --with pytest`,
which needs no install and no repo change. (An earlier version of this table used a throwaway venv at
`/tmp/pyenv4046`; that path was swept — a `/tmp` interpreter is not a durable way to state a result, so
the command was replaced with one that can be re-run.)

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

## Round 7 — the confirmation review, and two P0s it found in the shipped fixes

A seventh fresh-context reviewer (`71de0a7e2`) was asked to FALSIFY five claims with its own inputs
rather than re-read the suite. Four claims held; it reproduced two P0s, both in code the earlier rounds
had written, both re-verified here before anything was applied:

| finding | verdict | evidence |
|---|---|---|
| **[P0]** `question-lane-ack` verified off a **stale pane**: the question lane is persistent at index 0, so its tail still showed the PREVIOUS question's brief, and every brief carries the same six mandate tokens by construction. The dedupe honours only a prior `verified: true`, so the non-delivery was then permanent. | **CONFIRMED, FIXED** | measured through `lane-route.py --apply` with a transport that returns rc 0 and never paints: tick 1 `verified: true` off the prior brief, ticks 2–3 `already-routed, verified: true`, and the new question never on the pane. Now `question_qid(lane, question)` emits `qid=<8 hex>` in the brief and `mandate_missing(pane, qid)` requires THAT token, so the retry loop actually waits for this paint. |
| **[P0]** `_PAST_HARD`'s temporal anchors disarmed a **live** approval ask whose object merely dates → `not-asked` → `send-continue` into a lane waiting on its owner | **CONFIRMED, FIXED** | 7 of 7 measured: "Please approve yesterday's expense report.", "Please sign off on the invoice from last week.", "Please confirm the plan from Monday.", "I need your approval for the migration we discussed this morning.", "Awaiting your approval on the vendor quote from last month.", "Please confirm we ship at 14:02.", "Your call on the schema we reviewed last week." — all `not-asked`, all `may_continue=True`. The anchor now disarms only with a COMPLETION verb in the same clause and no future cue; a denial stays unconditional; a past-decision frame (`per your decision`, `as you decided`, `approved by`, `already approved`) is a report on its own. The cue list also gained the addressed `sign off` (it had only `for sign-off`). |
| **[P2]** the `rerun`→`inspect` post-pass was keyed on `ASKED` only, so an **UNREAD** tail still reached the destructive action | **CONFIRMED, FIXED** | `Evidence(turn=open, last_text="", lane_verdict="WEDGED")` → `rerun`. Now `inspect`, and the reason names `ask=unread`. `lane-relaunch.py` refused it downstream, which is why it is P2 — but a router may not outsource its own stated safety property. |
| **[P2]** `execute()` (the documented fixture entry point) raised `TypeError` for `rerun` with its default `relaunch=None` | **CONFIRMED, FIXED** | `arm_rerun` already had the right answer for a box with no tool (`None` → UNAVAILABLE, verified False); `execute()` now supplies it instead of crashing. |
| **[P2]** `test-setup-no-nesting.sh` exits 1 at this head | **PRE-EXISTING, base-owned** | the reviewer reproduced it against `git archive origin/main` (`MAIN_EXIT=1`, same single `REMOVED: script:conflict-rebase.py`); this branch's two farm entries are on the right side of the pin and appear as neither `ADDED` nor `REMOVED`. |

Claims that HELD under the reviewer's own inputs: `send-continue` unreachable for every ask shape it
invented (approval ask with no `?`, question + several status paragraphs, `?` inside a URL/path token
correctly NOT counted, and every turn state); the other three arms' proofs (`child-handoff-record`
written-then-re-read, `transcript-growth` with no baseline, order-based `pane-ready`); no kill/terminate
call site anywhere in the three files; the consumer non-inert (router absence logged every tick, and
three consecutive ticks produced exactly ONE send, then `already-routed`); and the farm decision
(`lane-relaunch.py` correctly withheld — it hard-requires `lane-status.py`, itself withheld by #1553).

Both P0 fixes are pinned by RED controls that prove them load-bearing: **R11** restores the
unconditional date anchor and requires the same input's answer to change to `not-asked`; **R12** removes
the nonce and requires the stale pane to certify the new question (`verified: true`). With the fixes in
place both mutants are caught.

## Rounds 8–10 — three more fresh-context reviewers, all against the guard

Rounds 8, 9 and 10 each falsified the PREVIOUS round's fix with inputs that round's corpus did not
contain. Every finding was reproduced against the shipped code before anything was applied; the two
items that could not be reproduced were dropped rather than re-worded.

| round | the finding that mattered | outcome |
|---|---|---|
| 8 (`78ce2098f`) | **[P0]** the completion gate was defeated by the ask's own OBJECT — a relative clause supplies the completion verb (*"…the invoice I **sent** last week"*), 7 of 7 read `not-asked`; **[P0]** `question-lane-ack` passed on a paint **truncated** after the mandate (the qid at char ~89 and the mandate after ~200 merely co-existed, so a cut of 118 or 400 chars was certified by the PREVIOUS brief's tokens); **[P1]** the mirror — a closed `_COMPLETION` list made 9 of 10 plausible completion reports read `asked`, pausing finished lanes | a completion that starts AFTER the clause's addressed cue does not disarm; the qid became a **high-water mark** (`verified` judges only what follows it) and is matched with optional whitespace so a wrap inside it still verifies; `_COMPLETION` broadened |
| 9 (`f19ce64f7`) | **[P0]** the position rule consulted its OWN 25-phrase cue list while the module has 59 hand-off phrases, so asks phrased outside it (*"Awaiting approval on the hotfix we released yesterday."*) had no offset at all — 14 of 14 read `not-asked`; **[P0]** the proof still passed on a paint cut at **1061 of 1409 chars** (after `recommendation`, before the question): the question was gone and the record said *"the full mandate visible on the pane"*; **[P1]** applying the position rule to denials and possessives made 11 of 11 finished reports read `asked` | `asks_owner()` passes the offset of the phrase that ADMITTED the clause, so the rule cannot drift from the vocabulary; the brief ends with `end=<8>` and the artifact requires that sentinel after the qid — it is the payload's last bytes, so truncation anywhere fails; denials unconditional again, position rule scoped to the anchor branch |
| 10 (`158724eb9`) | **[P0]** the now-unconditional denial silenced an ask whose OBJECT is a negative (*"Please confirm nothing needs your attention on the staging config before I promote."* → `send-continue`); **[P1]** *"I can't proceed without sign-off."* had no cue at all; **[P1]** a completion and its hold joined by `and` in one clause (*"Checks passed at 14:02 and I'm blocked on your approval."*) disarmed the ask; **[P2]** a past-decision frame followed by a deferral (*"Per your decision last week I'll wait for your go-ahead."*, no comma) disarmed it | a denial is gated on an addressed hold before it; the negative-dependency forms joined `_HANDOFF`; a `_DEPENDENCY` predicate after the completion keeps the clause an ask; the frame branch gained a scoped future veto (`_FUTURE_CUE` cannot be reused — it carries `your call on`). The pane read window is now sized from the payload (`_pane_lines`), because requiring the first AND last bytes of the brief within a fixed 60 rows would make a long question's proof unreachable — and therefore re-send it every tick forever |

The shape is consistent enough to be worth recording: **every finding from round 5 onward was in the
guard, never in the router** — a detector read one paragraph of the tail, a signature that matched a
ticket number, a pane read that never happened, a proof satisfied by the previous question, a
completion list that named the wrong subject. Each fix is pinned by a RED control that MUTATES the
shipped mechanism and requires the answer to change, and the corpora are rebuilt from inputs the fix
was not written from — twice a fixture that already contained the answer was the only reason a
non-gating gate looked green.

Named residual from round 10, stated rather than absorbed: a single clause that reports a completion and
then a hold (*"Checks passed at 14:02 and I'm blocked on your approval."*) is now an ask via
`_DEPENDENCY`, but a clause where the completion and the possessive are the SAME phrase
(*"It was blocked on your approval yesterday, then it went through."*) still reads as an ask — the
consequence is a paused finished lane and a bogus question, which is the cheap direction.

## What changed

```
tools/fleet/triage.py          NEW  the router: precedence, wedged subcases, remedies, proof table
tools/fleet/triage_arms.py     NEW  the three arms, each proving its effect at its artifact
tools/fleet/triage.test.py     NEW  hermetic suite, 439 assertions, 17 RED controls
scripts/lane-route.py          NEW  operator CLI (route / --json / --apply)
scripts/turn-end.py            MOD  gates its WIP nudge on route_gate(), and APPLIES a
                                    user-question route (batched, capped, bounded, logged)
pi-bootstrap/setup.sh          MOD  farms triage.py + triage_arms.py into $DEST/scripts/fleet,
                                    and lane-route.py (the only caller of the arms) into $DEST/scripts
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
