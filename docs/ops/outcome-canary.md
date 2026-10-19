# Outcome canary — assert what the fleet PRODUCES

`tools/fleet/outcome_canary.py` answers one question: **is the system producing outcomes**, not *does
the function return what it was written to return*.

Every fleet failure in the week ending **2026-10-18** was invisible to unit tests, because each part
was healthy on its own:

| what was observed | what the tests said |
|---|---|
| the controller was **running** and dispatching nothing (live pid, frozen log) | green |
| the boxes were **up with no controller at all** (launchd had no pid) | green |
| `cmux-tui` was **OOM-killed** while its unit still read `active` | green |
| landers **expired silently**, so green PRs waited for a human | green |
| `pr-doctor` **exited 2 for hours** | green |
| a refresh that could not read the pool **idled the box all evening** (`queue=UNREADABLE` beside `backlog=0`) | green |

In each case the system did no work and nothing said so.

## The eight checks

Each check is an **outcome**, and each has an *absent* and a *stale* variant. `PASS` requires the
outcome to be produced **inside its window** — a pid, a process, or a number from last week is not the
outcome.

| check | passes only when | absent variant | stale variant |
|---|---|---|---|
| `controller_cycling` | a controller process exists **and** its log advanced within the window | `CONTROLLER_ABSENT`, `LAUNCHD_PID_UNRESOLVED` | `LOG_SILENT`, `LOG_MISSING`, `LOG_NO_CYCLE`; `LOG_UNREADABLE`, `PROCESS_TABLE_UNREADABLE` (inconclusive) |
| `queue_readable` | the last refresh produced a READABLE verdict (**from the newer of the header token and `state/queue-state`'s own verdict**) | `QUEUE_UNREADABLE`, `QUEUE_NEVER_READ`, `QUEUE_PARTIAL` | `NO_REFRESH` |
| `work_dispatched` | a `[dispatch] … -> <issue>` line is inside the window **and the batch's lane actually started** | `NOT_DISPATCHED`, `NO_DISPATCH`, `NO_DISPATCH_GATED`, `NO_LANE_STARTED` | `NO_CYCLE_IN_WINDOW`, `DISPATCH_UNCONFIRMED` |
| `pr_created` | ≥1 PR opened in the PR window (**the created population includes PRs opened and then CLOSED unmerged** — a superseded PR was still opened; the closed page is read for both counts, so one call carries both) | `NO_PR_CREATED` | `IDLE_NO_WORK`, `ACTIVITY_UNKNOWN`, `GH_COUNT_UNREAD` (inconclusive: the surface answered but carried no count, so "opened nothing" was never measured; `ACTIVITY_UNKNOWN` means how much work was in hand could not be read — an unreadable pool, a non-current record, or no cycle header in the window) |
| `pr_merged` | ≥1 PR merged in the PR window | `NO_PR_MERGED` (also fired when `open_pr_count > 0` **and** every check above it is up — that arm needs no cycle header, because open PRs are measured work in hand) | `IDLE_NO_WORK`, `ACTIVITY_UNKNOWN`, `MERGED_SURFACE_TRUNCATED`, `GH_COUNT_UNREAD` (inconclusive). **The merge count comes from a MERGE-ORDERED read** (`merged:>=<date of now-window>`), not from the closed page — an empty result of it is a real measurement, so this check's absent-outcome FAIL stays reachable; the closed page only supplies the created population. **The truncation flag models the page ORDERING, per surface**: the creation-desc list (`pr list`) really can hide a merge behind a full closed page (truncated); the `sort=updated` REST page whose oldest `updated_at` is older than the window covers it completely (NOT truncated — measured 38.65h on the live target; keying the flag on the row count alone deleted this check’s only FAIL arm on a repo where every closed page is full) |
| `pane_daemon` | a live `cmux-tui` **and** a readable protection value that protects it | `DAEMON_ABSENT`, `PROTECTION_ABSENT` | `PROTECTION_UNEVALUABLE`, `PROTECTION_PARTIAL_UNREAD` (inconclusive: an UNREAD value is not an unprotected one — the tag is distinct from the FAIL's `PROTECTION_PARTIAL` because the notifier suppresses on `name\|variant` and only a PASS clears the key) |
| `headroom` | disk and available memory above their floors, **with the numbers printed** | `BELOW_FLOOR` | `PROBE_UNREADABLE` |
| `landers` | every green+mergeable PR is armed or railed (**a decision in the log counts only when the log's own repo matches `--repo`; a log that names NO repo is treated as this cell's — identity unknown is not a mismatch**) — see Honest gaps | `LANDER_MISSING` | `LANDER_EXPIRED`, `PARTIAL_POPULATION` |

**`work_dispatched` is the one that matters most.** Everything above it can pass while it fails —
measured 2026-10-18: controller cycling, `queue=READ(223)`, 47 candidates, and **47
`could not build claim commit` refusals with zero dispatches**. That is the shape a component-level
suite is structurally unable to see.

A `PASS` that hides a degradation is the failure this file exists to end, so `work_dispatched` prints
the refusal counts **even when it passes**: four dispatches beside 955 refusals is not a green fleet,
and the reader must be able to see that in one line.

**⛔ The batch line is an INTENT, not the dispatch.** `orch-loop.sh` echoes
`[dispatch] load=… lanes=… -> N` and only **then** calls `dispatch-merge.sh`, whose spawn fails in
ways that print their own lines (`#N: worktree add failed (branch exists?) — skipping`,
`#N: chain-N could NOT be started`) — or print **nothing at all**, because the `tmux new-session`
branch has no `else`, so a dead tmux server or a full session table is silent. The disambiguating
lines are in the same tail. Grading the intent was a `PASS`/`DISPATCHED` **and exit 0** for a fleet
that spawned nothing, i.e. a green verdict on the exact outcome this check exists to assert. The
batch now needs its **spawn outcome**:

- `#N: lane-M (implement+PR)` **for one of that batch's issues, written no earlier than the batch
  line** → `PASS`/`DISPATCHED`, and the spawn line is named in the evidence (a pass may not
  hide a *failed* sibling spawn, which is printed beside it). A spawn from an earlier cycle is
  named as `for a DIFFERENT batch` and does not vouch for this one: measured, an older batch's
  4400/4401 spawn made the newest batch (which spawned nothing) read `PASS` + exit 0;
- a batch whose **every** spawn failed → `FAIL`/`NO_LANE_STARTED`;
- a batch with **no spawn outcome** in the window (a truncated tail looks identical) →
  `INCONCLUSIVE`/`DISPATCH_UNCONFIRMED`. Measured 2026-10-18: 110 of 110 real batch lines are
  followed by a lane line, so the outcome is genuinely available and its absence is not normal.

## INCONCLUSIVE is not green

Three statuses, not two: `PASS`, `FAIL`, `INCONCLUSIVE`.

A check whose inputs could not be read — gh refused, no `/proc`, an unreadable log, no
`oom_score_adj` on this platform — is `INCONCLUSIVE`, it renders differently from `PASS`, and it makes
the exit code non-zero. **An unevaluable check must never read as green**: that is precisely how a
blind fleet looks healthy.

## Two modes

```bash
python3 tools/fleet/outcome_canary.py --static              # CI: fixtures only. No network, no process table, no clock.
python3 tools/fleet/outcome_canary.py --live                # this machine
python3 tools/fleet/outcome_canary.py --live --box cell-2   # a cmux cloud machine (probes via `cmux cloud exec`)
python3 tools/fleet/outcome_canary.py --live --dry-run      # report only: never send, never respawn
python3 tools/fleet/outcome_canary.py --live --json         # machine-readable
```

`--static` evaluates the **same predicates** over `tests/fixtures/outcome-canary/*.json`, and each
fixture declares its own `_expect`, so a change that breaks a predicate fails a normal test run. The
design rule that makes that possible: **predicates never read the clock and never read a file** — they
consume ages in seconds and pre-computed booleans. The collector turns a machine into that shape; a
fixture is the same shape written by hand. There is no second implementation to drift.

Exit codes: **0** all pass · **1** at least one `FAIL` · **2** nothing failed but something was
`INCONCLUSIVE` · **3** usage error.

## The signal

On a non-`PASS` check:

1. **Respawn, only if the controller is genuinely absent** (`CONTROLLER_ABSENT`,
   `LAUNCHD_PID_UNRESOLVED`). `launchctl kickstart -k` restarts it in place; `launchctl bootstrap` is
   the fallback for a service that is not loaded. ⛔ Never `unload -w`/`load -w` — `-w` writes a
   **persistent Disabled override**, so a load whose bootstrap fails leaves the controller removed
   *and* disabled, silently (measured 2026-10-17, agent-infra#1975). A live-but-silent controller is
   **never** respawned: it holds work.
   The respawn is then **proved**: a controller pid must appear *and* the log must advance. A
   `launchctl` exit code proves the request was accepted, not that a controller runs.
2. **Otherwise message the controller** through the sanctioned path — `scripts/safe-send.sh` →
   `lane-guard.py` → `cmux_dispatch.py` — never a bare `cmux send` (which returns 0 for text merely
   typed). `safe-send` refuses a lane that is busy or whose state is UNKNOWN, so a mid-turn controller
   is not interrupted; a refusal is reported as **NOT DELIVERED** with the guard's reason, and the
   composed message is kept on disk so nothing is lost.
   ⛔ Auto-discovery **never** selects a pane whose name says *never dispatch*: a supervisor pane that
   happens to be idle consumes the message, the send returns 0, and the failure would be recorded as
   delivered and silenced forever while the actor who could fix it was never told
   (`FINDING-lane-dispatched-to-orchestrator-2026-10-11`). Use `--controller-ws` to name the
   destination explicitly.
3. **The message must be actionable**: the failing check, the evidence (the log line, the numbers,
   the timestamps), a one-line orientation pointer into
   `scripts/orchestrator-harness/README.md` naming the **section**, and the **next command**. A
   message that only says "something is wrong" is not sent by this tool.
4. **One message per state change**, keyed on `(box, check, variant)` — the *shape*, never the
   numbers, or every new log line would be a new "state change" and the alert becomes noise. A key is
   recorded **only after a confirmed delivery**, so a refused send is retried on the next poll. A
   `PASS` on that check clears the key, so a re-break after a recovery speaks again.

## Wiring a schedule (a manual step, deliberately)

Nothing here arms a timer. That mirrors `com.eldato.pi-task-session-prune`: a job that can restart a
controller and message a pane should be switched on by a human, with a dated trigger. To arm it:

```
# ~/Library/LaunchAgents/com.eldato.outcome-canary.plist
#   StartInterval 600
#   ProgramArguments: [python3, <agent-infra>/tools/fleet/outcome_canary.py,
#                      --live, --repo <owner>/<name>]
```

⛔ **The `cmux` CLI is unusable from launchd** ("Access denied - only processes started inside cmux
can connect" — measured in `lane_liveness.py`). Run the armed job from a cmux-spawned context (a lane
or the controller's own loop), or accept that the delivery half reports NOT DELIVERED with that exact
reason and use the exit code + log for the signal.

## Honest gaps

- **`pane_daemon` protection is `INCONCLUSIVE` on macOS.** `oom_score_adj` is a Linux `/proc` value;
  darwin exposes no equivalent. The daemon being alive is reported, and protection is reported as
  *unproven* rather than assumed — a Mac box must demonstrate protection some other way.
- **`0` is not protection.** `oom_score_adj = 0` is every process's kernel default; only a **negative**
  value deprioritises the process (`-1000` is `OOM_SCORE_ADJ_MIN`, immune). `PROTECTION_ABSENT` is a
  real verdict, not a theoretical one — a `cmux-tui` at `0` is exactly as killable as it was before
  anyone "protected" it.
- **There may be no addressable cmux destination at all.** On a box whose controller is a
  launchd/tmux job with no chat channel (this Mac: `launchd.plist.template` → `/bin/bash
  $O/orch-loop.sh`, loaded by `scripts/orchestrator-harness/launchd-cycle.sh`), the
  message cannot be delivered to it. That is reported as `NOT DELIVERED` with the reason and the
  message path, never as sent. Delivery works where the controller IS a pane, named explicitly with
  `--controller-ws`.
- **Respawn is local-only.** `--box` evaluates a remote machine's outcomes; a controller on another
  machine is reported as `NOT ATTEMPTED (remote)` rather than pretended-restarted.
- **A frozen pool read cannot establish EMPTINESS.** The refresh appends the reading's age to the
  token precisely so a value frozen by a dead refresh cannot pass as current, and an `EMPTY(6h)` read
  with `backlog=0` used to let both queue checks pass and the whole run exit 0. Now an `EMPTY` read
  older than `--queue-stale-min` (default 90, the harness's own minutes-to-hours boundary) is
  `INCONCLUSIVE / STATE_FROZEN` for `queue_readable` and `work_dispatched`. A stale **non-empty** read
  is `INCONCLUSIVE / READABLE_STALE`: legible, so a FAIL would accuse a box that may still be
  dispatching off it, and old, so a PASS would certify a pool number from hours ago while the
  controller read a stale `candidates.txt` — #1931 wearing a pass. Neither: abstain, and let
  `work_dispatched` report the dispatches it can actually see. `work_dispatched` abstains on ANY stale
  record for the same reason, and its two backlog-based FAIL arms sit **below** that abstention: an
  abstention placed after the arm it must suppress is dead code, and the FAIL it let through
  (`NO_DISPATCH`, "work existed and did not move") accused a box whose refresh had merely frozen. An `EMPTY` read carrying **no age at
  all** is `STATE_FROZEN`: the harness emits that shape from a torn state file, and an unaged record is
  a stale flag waiting to be read as current.
  The limit is `--queue-stale-min` / `config.queue_stale_s`, and it is a real field — not an
  advertised flag that `Cfg` silently discards.
- **A future-dated log mtime is UNKNOWN, not the freshest possible.** `max(0, now - mtime)` made a
  clock-skewed cell's log read as 0s old, so "the pid is alive but the log stopped" — the state that
  must fire — read PASS.
- **`landers` never speaks for a PR it did not read** — including a population truncated at the gh
  page bound (a full page means PRs beyond it were never fetched) — and a fixture with no `_expect`
  is a mismatch rather than a silently satisfied empty assertion set. The REST fallback stops probing at a bound
  (`rest_probe_max`, 25) and a failed check-runs call also leaves a PR unprobed. Once ANY unprobed
  non-draft PR exists the verdict is `INCONCLUSIVE / PARTIAL_POPULATION`, even when a probed PR is
  armed — a checked PR says nothing about the ones nobody looked at, and this is the check whose whole
  purpose is a lander expiring silently.
- **Mergeability is normalised at the collector boundary.** REST answers `mergeable_state: "clean"`
  (lowercase) while GraphQL answers `mergeStateStatus: "CLEAN"`; comparing REST's spelling to the
  upper-case set dropped every REST-probed PR from the candidate list while leaving it `probed`, so it
  appeared in neither the candidates nor the unprobed list. An empty or `UNKNOWN` state (GraphQL
  computes it lazily) is `probed: False`, which reaches `PARTIAL_POPULATION` instead of vanishing.
- **An `_expect` naming a check that does not exist is a MISMATCH**, and a check excluded by `--only`
  is reported as not evaluated — a fixture key that asserts nothing must not let the runner print
  "every fixture matched".
- **`landers` reads `autoMergeRequest` as the live truth.** A log line saying `#N auto-armed` next to
  a GitHub PR with no auto-merge is exactly `LANDER_EXPIRED` — the log is evidence of intent, GitHub
  is evidence of state.
- **The two gh surfaces are both read-only.** GraphQL is tried first (one call, rollup +
  auto-merge); REST answers when GraphQL's shared bucket is exhausted, and **the evidence says which
  one answered**. Neither answering is `INCONCLUSIVE`.

## The controller census is SCOPED to this cell

"A controller exists" must be a claim about THIS cell, not about the box. The census requires the
process's argv to be exactly `<shell> <this cell's orch-loop.sh>` — the same rule
`scripts/cloud-cell-supervisor.sh` applies, and the reason it applies it:

- "6 controllers for 3 cells" (2026-10-15) — an unscoped match counted jobs that are not controllers;
- a `bash -c '<text>'` whose string ends in the script path — a dead fleet read as cycling, so the
  ABSENT state that owns the respawn was never reached;
- leaked test fixtures (`…/T/fleet-inventory-test.*/O/orch-loop.sh`) — measured 2026-10-18: the census
  read 3 controllers for 1, a false `PASS`, and the respawn then refused to act because every live pid
  was a stub.

Rejected processes are reported as **near misses** with the reason, so "no controller" is
distinguishable from "nothing was there to see".

## One message per state CHANGE, and silence that cannot outlive the state

The notifier keys a message on `(box, check, variant)`. A delivered message supersedes every other
shape of the same check, and a **recovery** clears both halves of the alert — the delivered keys *and*
any `AMBIGUOUS` marker (see below). Without that second half, `fail → recover → fail identically` is
silent forever, which is the loudest possible failure of a notifier.

An **`AMBIGUOUS`** delivery — `safe-send.sh` rc 1/4, "bytes written, turn not confirmed" — is **not**
blind-retried: its own contract reserves retry for rc 3 (`REFUSED`, nothing consumed) and says a
retry of an ambiguous send *stacks a second instruction*. The key stays suppressed until the failure
shape changes, and it is pruned with the rest of its check.

## The suite

```bash
python3 tools/fleet/outcome_canary.test.py              # the acceptance suite
python3 tools/fleet/outcome_canary.test.py --mutations  # every entry in MUTATIONS must go RED
```

The signal tests drive the **real CLI** end-to-end (`--live --facts … --capture-dir …`), so what is
asserted is the message that would actually be sent and the exit code a scheduler would actually see:
a failing check produces the message and a non-zero exit; a passing run produces neither; the notifier
de-duplicates on unchanged state; a recovery re-arms it; respawn is planned only when the controller
is genuinely absent.

Two *collector-contract* tests exist because the fixtures supply ALREADY-PARSED events and therefore
prove the predicates but never the parser: one feeds the literal strings `orch-loop.sh` emits
(`[dispatch] skipped (…) lanes=… workers=…`, both refusal forms), the other feeds the three shapes
`stat` returns (`stat -f %m` on BSD, `stat -c %Y` on GNU, and GNU's multi-line `-f` filesystem block).
Both classes of defect shipped once and were caught by review, not by the suite.

Three more tests exist for the same reason — an outcome read as present when it is not:

- **A re-run is an ATTEMPT, not a check.** The rollup is a list in which a flaky job appears twice, so
  a flat "every entry must be green" walk reads a commit that re-ran green as **red**, and a
  red-reading green PR drops out of the `landers` population. Attempts are grouped on
  `(workflowName, name)` and ordered by the attempt's `id` where the surface carries one (the REST
  check-runs payload does), else by the latest of `completedAt`/`startedAt` (the GraphQL surface
  carries no `id`), else — only when an entry carries neither, e.g. a legacy status context — by
  list position, and never on `app`. The live GraphQL surface
  (`gh pr list --json statusCheckRollup`) carries no `id`: it emits
  `name, workflowName, status, conclusion, startedAt, completedAt, detailsUrl`. Grouping on `app` (or
  on the merge rail's `(app, name)`) collapsed every workflow into one check — `changes` is published
  by both `CI` and `Python CI` — and its list order is not chronological. `app.slug` is the fallback
  the REST check-runs payload offers, where an `id` also exists. A group with an attempt still IN
  FLIGHT is not green. A legacy status context carries `state`, not `conclusion`, and is read too.
- **A decision in the log is a decision NOW.** `#N PENDING (rail mode …)` from last night, or an entry
  whose enclosing cycle header was unparseable and so carries no age at all, is not a lander: both
  kept a green PR reading PASS after the rail was gone. Decisions are filtered by age against
  `--pr-window-min` (not the 12-minute `--window-min`: a rail legitimately persists for hours, and a
  3-cycle bound would fail every green PR on the box), and what was dropped is printed, so "there is
  no lander" is distinguishable from "the log mentions one and we refused to believe it".
- **The REST probe bound is a knob.** `rest_probe_max` (`--rest-probe-max`, default 25) bounds how
  many open PRs the REST fallback probes; a PR past it is `probed: False` and reaches `landers` as
  `PARTIAL_POPULATION`. It used to be read as `getattr(cfg, "rest_probe_max", 25)` and declared
  nowhere — an inert setting, which is the defect class this tool exists to catch, so the suite
  asserts the bound is actually honoured, not merely that the field exists.

Five more, from the same review: every one of them was a PASS (or a FALSE FAIL) produced by a datum
the module already held and did not read.

- **An unread check surface is UNPROBED, not "not green".** `rollup_is_green` answers `None` when
  there is no rollup at all — a path-filtered workflow, a fork PR awaiting approval, a repo with no
  required checks — and both collectors now mark that PR `probed: False`. Before, the `False` was
  skipped by the candidate filter while `probed: True` kept the PR out of the unprobed list, so a
  CLEAN, APPROVED, UNARMED PR produced `PASS/NOTHING_GREEN` and **exit 0**: the silent expiry this
  check exists for, recorded as health. The REST check-runs page is bounded too, so `total_count` is
  now compared with the page (`TRUNCATED` → unprobed) — the doctrine `page_full` already applied to
  the PR list.
- **An empty `gh` response is a failed read.** `json.loads(txt or "[]")` turned a `gh` that exited 0
  with no output into "zero PRs", so `landers` PASSed over a population it never read.
- **The pane census is scoped to the daemon's own argv.** A substring match counted
  `tail -f …/cmux-tui.out` — a process this check's own NEXT COMMAND tells an operator to create —
  and because the fleet deprioritises lanes it inherits a negative `oom_score_adj`, so a machine with
  no daemon read `ALIVE_PROTECTED`. Rejected rows are printed as evidence.
- **The header's timezone token is used, not dropped.** Reading the rest as local time is only
  correct while every cell shares the canary's zone: a PST cell read from an EST box reported a
  5-minute-old event as 4h05m old, so its `#N auto-armed` line fell out of the window and a green
  ARMED PR read `LANDER_MISSING`. Known abbreviations (and numeric offsets) give an absolute epoch;
  an unknown token falls back to the local reading rather than being guessed at.
- **A preview does not persist, and `--box` does not borrow this machine's repo.** A bare `--dry-run`
  no longer writes the default notification state (it was clearing a delivered key, re-arming an
  alert already sent so the next real poll stacked a second brief); a caller who names `--state` or
  `--capture-dir` has declared where its state lives and may write there. And `--box` used to read
  the LOCAL launchd plist for `OR`, grading a remote cell against whichever repo this machine runs —
  it now abstains (`GH_UNREADABLE`) unless `--repo` is given.

Also corrected: `--static --only X` reported every other expectation as a mismatch (105 of them on
the shipped fixtures), i.e. a flag pair that could never succeed; a known check excluded by `--only`
is now **SKIPPED and listed**, never silently counted as asserted.

Four more, found by measuring the surface the tool actually reads rather than the shape it assumed:

- **The rollup is grouped and ranked on fields the LIVE surface emits.** `gh pr list --json
  statusCheckRollup` sends `name, workflowName, status, conclusion, startedAt, completedAt,
  detailsUrl` — and **no `app`, no `id`**. Grouping on `app` therefore collapsed every workflow into
  one check, so `changes` (published by both `CI` and `Python CI`) and `ai-review-gate` (measured
  twice with differing conclusions on the same PR) were graded as one, and ranking on `id` always fell
  through to list position — which is not chronological (18 of 59 adjacent pairs have a later position
  with an earlier `startedAt`). Grouping is now `(workflowName, name)`, ordering is the timestamp, and
  **a group with an attempt still in flight is not green**: a queued attempt carries no timestamp at
  all, so an ordering alone would rank it last and grade the stale green.
- **"Graded or unprobed, never neither" is enforced in the predicate**, not only in the collectors.
  `pr.get("probed", True)` read an ABSENT key as probed, and a row the filters could not grade (no
  mergeability, no check surface) left BOTH lists — an unread PR disappearing from a PASS. An absent
  or unrecognised mergeability state now abstains, while the known non-mergeable states (`BEHIND`,
  `BLOCKED`, `DIRTY`, `DRAFT`, `HAS_HOOKS`, `UNSTABLE`) are still simply skipped, so a busy box does
  not go INCONCLUSIVE just because its PRs are behind.
- **A future-dated clock is UNKNOWN in the heartbeat and the queue-state file too.** The
  `CLOCK_SKEW_TOLERANCE_S` rule had been applied to the log mtime only; `max(0.0, now - ts)` made a
  stale record the freshest possible reading, which defeats the `queue_stale_s` guard whose whole job
  is to stop a frozen EMPTY read establishing "nothing to do".
- **⛔ The header's `queue=` token is always one refresh OLD, so the state record outranks it.** The
  cycle header is written at the top of a cycle and `refresh-candidates.sh` runs later in the same
  cycle, which makes `state/queue-state` the newer record. Only its epoch used to be read, so a
  header `EMPTY(3m)` beside a 40s-old `state/queue-state: UNREADABLE` graded `PASS`/`READABLE`
  + `PASS`/`IDLE_EMPTY_POOL` and exit 0 with **no message** — agent-infra#1931 ("the fleet is
  BLIND, which is not 'nothing to do'") recorded as health. `queue_readable` and
  `work_dispatched` now read the same authoritative token (`authoritative_queue_token`), and the
  evidence names which source was graded and that it is newer.
- **`--only` narrows; it does not certify** — in `--live` (exit 2, `not_evaluated` named) *and* in
  `--static` (exit 2 when any check was excluded). A green static run that asserted 1 of 8 checks is
  quotable as "the suite passes", which is precisely the claim it must not support. A mismatch still
  exits 1: an observed FAIL is stronger evidence than "not asked".
- **`--static` asserts ALL of a fixture's expectations, and the fixture POPULATION is part of the
  pin.** `_expect: {"headroom": "PASS"}` ran seven checks, asserted one and reported success; a
  DELETED fixture removes the outcome it pinned while every remaining assertion still passes. A
  partial `_expect` is a `PARTIAL_EXPECT` mismatch and a missing outcome-critical fixture is a
  `MISSING_FIXTURE` mismatch.

Six more (cycle 13), each a case where a datum the tool held was not the one it graded on:

- **An age-UNKNOWN pool read is not READABLE.** The staleness guard fired only for `EMPTY`, so
  `queue=READ(223)` written without an epoch — the bare token the harness emits when its `$at` field
  is missing or unparsable — was graded `READABLE` with the age printed as `UNKNOWN`. An unaged one is
  `STATE_FROZEN`, and a known-and-old non-empty read is `READABLE_STALE` (see below) — it is legible,
  and it is not current.
- **An absent `pids` KEY is not an empty process table.** `controller_cycling` read
  `ctrl.get("pids") or []`, so a payload with no `pids` list graded `FAIL / CONTROLLER_ABSENT` — the
  one verdict that fires `launchctl kickstart -k` — on a process table that was never returned, and
  the re-measure could not save it because the fingerprint carried the same broken probe. It is now
  `INCONCLUSIVE / PROCESS_TABLE_UNREADABLE`, the action path refuses on an absent list
  (`pids_ok`), and a measured `[]` is still the absence it says it is.
- **An unreadable rollup ENTRY is unprobed, not red.** A non-dict entry in the rollup returned
  `False` — a positive claim that a PR's CI is red — so `landers` filed a CLEAN, APPROVED, UNARMED PR
  under the known-not-landable skips and returned `PASS / NOTHING_GREEN`, which is the silent expiry
  this check exists to catch. An unreadable entry now abstains exactly like an unreadable surface
  (`PARTIAL_POPULATION`). An entry that PARSES but has not concluded is **not green** (in flight is
  not a pass, so the PR is not landable yet) and is labelled `:inflight`, not `:red`: the verdict is
  the same, the CLAIM is true. `rollup_state()` is that three-way read; `rollup_is_green()` is the
  boolean projection the collectors use.
- **A missing `tail_ok` is a missing read.** `is False` caught a FAILED tail but let a payload that
  never reported one — the `--facts` injection mode, or any producer that loses the field — fall
  through to the content arms, where `FAIL/LOG_NO_CYCLE` claims "the log is advancing, but not by a
  cycle" about lines nobody read. All 30 fixtures now declare `tail_ok: true` explicitly.
- **`checks_green` is graded allow-list.** `if not green` read the string `"false"` (or `"no"`, `1`)
  as GREEN, so a collector regression or a hand-written facts file published `PASS/LANDERS_ARMED` for
  a PR whose own evidence line printed `green=false`. Only `True` is green.
- **"Green" here means NOT RED.** `GREEN_CONCLUSIONS` treats `cancelled`/`stale` as non-red, matching
  the merge rail (`scripts/admin-merge.sh` does the same); a `CANCELLED` check therefore reads
  `checks_green: True`, which answers "nothing here blocks a merge", not "CI passed". The docstring
  said the opposite of what the code did; both now say this.
- **A `--box` run refuses to message the LOCAL pane, in a shape the report can render.** The refusal
  was appended as a tuple while every other producer appends a dict, so EVERY `--box` text-mode run
  crashed in the render phase: the NOT-DELIVERED block, the composed message and the state error were
  lost, and the exit code became the traceback's 1 (an all-INCONCLUSIVE run must exit 2).
- **A rejected census row is not an absence — in EITHER absence arm, and for the pane daemon too.**
  `CONTROLLER_ABSENT` was still reachable when launchd reported no pid (or its read failed): the guard
  was gated on `launchd.pid is not None`, so whether the cell used launchd decided the verdict, not
  whether the controller existed. It is hoisted above both arms now. `pane_daemon` had the same shape
  (`DAEMON_ABSENT` with "REJECTED (mentioned the name, is not the daemon)" in its own evidence). The
  match is on **exact tokens** of the cell's own controller paths (or the daemon's basename) — a
  substring test counted the operator's `tail -f ~/.cmux/cmux-tui.out` as the daemon, and a bare
  `orch-loop.sh` basename counted a leaked fixture as this cell's controller.
- **An undisclosed page bound means truncation only when the bound was REACHED.**
  `gh.get("page_full")` read a payload that never said so as a COMPLETE population: a 100-row payload
  with no disclosure graded as whole (the collector's own rule is "unprovable coverage is truncated,
  never complete"), while a 1-row payload cannot have been cut by a 100-row page. Same for
  `merged_page_full`, and a BOOLEAN `open_pr_count` is not a count.
- **A concluded RED outranks an in-flight check, in either order.** `rollup_state` returned on the
  first in-flight group, so `[red, queued]` said "red" and `[queued, red]` said "inflight" — a PR with
  a FAILED check labelled `:inflight`.
- **`--facts` is disclosed as INJECTED, not "LIVE".** The header said "LIVE" and stamped the RUN's
  clock, so two runs supplying the same fact file days apart were indistinguishable in the field a
  reader uses to judge currency; an `observed_at` in the payload now wins, and the respawn re-check
  that swaps injected facts for live ones says so.
- **A `--box` run does not message the LOCAL controller.** `--box` scoped the facts and the state key,
  but the send path discovered and delivered into *this* machine's pane (the cmux socket is local), so
  the report recorded `delivered` for a recipient that cannot act on that box. It is `NOT DELIVERED`
  with the reason, as the respawn path already refused.
- **A rejected controller row is not an absent controller.** The controller census is scoped to
  exactly `<shell> <this cell's orch-loop.sh>`, so a controller started as `nice -n 5 /bin/bash
  …/orch-loop.sh` lands in `near_misses`. The launchd arm turned that zero into
  `FAIL / LAUNCHD_PID_UNRESOLVED` — "no such process exists" — and that variant is a RESPAWN TRIGGER,
  so `kickstart -k` killed a live controller mid-cycle while the log, the header and the heartbeat all
  said it was working. A rejected row that NAMES this cell's controller is
  `INCONCLUSIVE / CENSUS_NEAR_MISS`; the action path's re-measure refuses on the same evidence, and a
  near miss naming a DIFFERENT script still leaves the real absence fireable.
- **`rollup_state()` is the ONE rollup read.** `rollup_is_green()` is its boolean projection, so the
  two cannot drift — before that, the state read did not group attempts and answered "green" for a
  red check masked by a newer green attempt of another workflow. The collectors also write
  `checks_state`, which is what `landers` prints (`7:inflight` vs `7:red`).
- **A malformed fixture `config` is a USAGE error (exit 3).** `Cfg` coerces its numerics, so
  `{"pool_threshold": "many"}` raised `ValueError` straight out of `run_static`; the traceback exited
  1, which a scheduler reads as "at least one check FAILed" about a fleet that was never evaluated.
- **The probe FAILURES reach the report.** The REST collector has always recorded WHY a PR went
  unprobed (`detail_errors`, per-row `unprobed_reason`); nothing read them, so "beyond
  `rest_probe_max`", "the detail call 403'd" and "this page was truncated" — three different failures
  with three different fixes — were indistinguishable in a report that listed only PR numbers.
- **`NO_CANDIDATES` uses the header's OWN pair.** It compared the graded token's pool (possibly the
  NEWER `state/queue-state`) with the header's one-refresh-old backlog and called the difference a
  defect "upstream (queue_readable owns it)" — which `queue_readable`'s arm can never report, because
  it deliberately pairs the pool with its own header.
- **A superseded `backlog=` cannot grade "work existed and did not move".** The header's `backlog=`
  and `queue=` are one refresh old, so when the newer `state/queue-state` reads the pool EMPTY the
  header's remaining candidates are already gone. `work_dispatched` graded them anyway, producing —
  for ONE facts dict — `queue_readable PASS/READABLE ("graded from: state/queue-state, it is NEWER")`
  beside `work_dispatched FAIL/NO_DISPATCH` and a message to the controller. Both backlog FAIL arms
  are now gated on `superseded_backlog`, and `IDLE_EMPTY_POOL` is reachable from a header that still
  carries a backlog.
- **`--skip` refuses an unknown probe (exit 3).** `--skip githbu` was dropped silently: the operator
  believed a probe was suppressed and the run neither suppressed it nor said so. `--only` already
  refused unknown names; `--skip` now does, against the same kind of closed list (`SKIPPABLE`).
- **`--no-notify` suppresses MESSAGES only.** Its help said "evaluate only", which an operator reads
  before silencing alerts on a live box — and the respawn still fired. The action is governed by
  `--no-respawn` alone, and the help now says so.
- **An unreadable log is not an empty log.** `read_log` discarded the `tail` exit status, so a log
  whose content could not be read (EACCES, TCC, a timed-out remote exec) came back with a fresh mtime
  and no lines, and `controller_cycling` graded that pair `FAIL / LOG_NO_CYCLE` — "the log IS
  advancing, but not by a cycle": a measured claim about content nobody read, on the first check an
  operator looks at. A failed tail is `INCONCLUSIVE / LOG_UNREADABLE` with the error in the evidence.
  **The mtime verdict outranks the content one**, because `LOG_SILENT` is measured from the mtime
  alone and needs no bytes: asked the tail first, a live pid whose log had been frozen for three
  hours reported "the content was not read" instead of the measured FAIL that was available.
- **A frozen pool record cannot certify work in hand either.** Currency was guarded only in the
  direction that makes the fleet IDLE; a frozen `backlog=47` (written from the previous refresh's
  `candidates.txt`) certified "the fleet had work in hand" and turned `pr_created`/`pr_merged` into
  `FAIL/NO_PR_CREATED` + `FAIL/NO_PR_MERGED` and two pages — while `queue_readable` said
  `READABLE_STALE` and `work_dispatched` said `STATE_FROZEN` about the same record in the same run.
  One world, graded two ways, and the FAIL was the one that paged someone. A non-current record is
  `INCONCLUSIVE/ACTIVITY_UNKNOWN` in both directions.
- **Only `True` is armed, and only a `bool` is a draft bit — an ABSENT one is unread.** `if pr.get("auto_armed")` read the
  string `"false"` as ARMED and published `PASS/LANDERS_ARMED` for a PR whose own evidence line
  printed `armed=false` — in the one check whose purpose is catching a silent lander expiry — while
  `if pr.get("draft")` read `"false"` as a draft and silently removed a live PR from the population.
  The same allow-list polarity already required for `checks_green`: a non-bool is an unread bit.
  `.get("draft", False)` was the last place a MISSING key became a measurement, so a row with no
  `draft` bit at all was admitted as a definite non-draft and could `FAIL/LANDER_MISSING` a PR that
  might be a draft.
- **`headroom` allows-lists its `ok` too.** `if disk.get("ok")` is truthiness and `"false"` is
  truthy, so a surface that said its read FAILED was graded as a successful one carrying
  `avail_bytes: 0` and produced `FAIL/BELOW_FLOOR` — a fake OOM emergency on the check whose FAIL
  must mean one. A missing `used_pct` now prints as `used_pct not read`, never as `-1.0% used`.
- **A measured per-PR failure outranks a population-level abstention.** `landers` graded the
  truncation abstention before `expired`/`missing` were computed, so a full open-PR page turned
  `LANDER_EXPIRED` — "the lander expired silently and the PR waits for a human", the exact failure
  the check exists for — into exit 2, and threw away the arming analysis for the rows it HAD read.
  Truncation now abstains only when there is no candidate row to grade, and otherwise rides below
  the measured FAILs. The same precedence applies to `pane_daemon`: one pid READ as
  `oom_score_adj: 500` is `PROTECTION_PARTIAL` even when a sibling value is unreadable.
- **A bool is not a count, in `work_dispatched` either.** `isinstance(True, int)` is true, so
  `backlog: true` produced "the refresh reported 1 candidate(s)" and a delivered FAIL;
  `_activity` and `queue_readable` already refused the same field, and all three now share one
  `_is_count` helper.
- **A spawned lane its own failure line refutes is not a started lane.** `_activity` read the raw
  `lane_started` bucket, so `#4601: chain-1 could NOT be started` plus a start line produced
  "a lane started 3m ago" in the evidence of a FAIL sitting directly under `NO_LANE_STARTED`.
  A refuted start falls back to the INTENT, which is what it always was.
- **A `PARTIAL` token cannot certify an empty pool.** `parse_queue_token` sets `pool` only for
  `READ(...)`; a `PARTIAL(...)` token carries `partial` and leaves `pool` None, so admitting it let a
  shape whose pool SIZE was never read fall through to "the fleet had nothing in hand" while
  `queue_readable` FAILed `QUEUE_PARTIAL` on the same record. And the "current `EMPTY` supersedes the
  header" shortcut now requires the header's own `backlog=`, because `HEADER_INCOMPLETE` is the same
  judgement its two sibling checks make.
- **The batch INTENT line is not a landed dispatch.** `_activity` read `[dispatch] … -> N` as "a
  dispatch landed", putting that sentence in the evidence of a FAIL three lines under
  `work_dispatched`'s `NO_LANE_STARTED` for the same batch. A confirmed `lane_started` is preferred;
  when only the intent exists the line says "a dispatch was ATTEMPTED … no lane spawn was confirmed".
- **No cycle header in the window is not an empty backlog.** `_activity` answered "the fleet had
  nothing in hand" when no header was in the window — so a WEDGED controller (which writes none) was
  graded as evidence that there was nothing to do. That shape is now `ACTIVITY_UNKNOWN`, as
  `queue_readable`/`work_dispatched` already grade it.
- **A corrupt notification state file is ignored and disclosed, never a crash.** Only the outer
  `boxes` map was validated, so a per-box value that was not a dict raised after the verdicts and
  before the report — exit 1 with no output, which a scheduler reads as "a check FAILed" while the
  JSON is lost. EVERY discarded shape is disclosed — a per-box value that is not a map, a `boxes`
  that is not a map, an unparseable file — and the run says de-duplication restarted empty and
  whether anything was persisted this run — which is the WRITE OUTCOME, never the dry-run policy: a
  bare `--dry-run` writes nothing while `--dry-run --state P` does persist, and an unwritable path
  fails, so a report that said "was replaced" would be a claim about the disk that did not happen.
- **A current `state/queue-state: EMPTY` supersedes the header's pair.** The header's `queue=` and
  `backlog=` are one refresh old; when the newer record says the pool is now empty, grading the
  header's pair anyway produced `queue_readable FAIL / EMPTY_WITH_LARGE_POOL` beside
  `work_dispatched PASS / IDLE_EMPTY_POOL` for one world — two checks reading the same facts in
  opposite directions.
- **Open PRs and a fresh dispatch are work in hand.** The queue record answers "what did the last
  refresh say"; the PR checks' "nothing in hand" abstention reads it, so a stale record could silence
  a real FAIL while the log showed a dispatch inside the PR window. Measured: `work_dispatched
  PASS/DISPATCHED` three lines above "nothing in hand".
- **A moving log is not a cycling controller.** `cycles` was computed, printed and never graded, so a
  controller wedged mid-cycle read `PASS/CYCLING` for as long as anything appended to the log —
  `claim-prune` and the `[reap-worker]` lines do, by design. Zero cycle headers in the window is now
  `FAIL/LOG_NO_CYCLE`.
- **A partial run cannot exit 0.** `--live --only headroom` evaluated one check and exited 0 while
  seven outcomes were unprobed. The unevaluated checks are named in the report and in the JSON, and the
  exit code is 2. (`--only` narrows; it does not certify the rest.)
- **A payload must BE a population.** An absent `open_prs` list, or an `open_pr_count` that disagrees
  with the rows, is `GH_UNREADABLE` — the contradicting count sits in the same dict, so it is compared.
- **Every row is graded, skipped-for-a-known-reason, or unprobed — and the skips are PRINTED.** A
  `BEHIND`/`DIRTY`/`BLOCKED` PR is still skipped, but counted and named; and a `CHANGES_REQUESTED` /
  `REVIEW_REQUIRED` / `DISMISSED` review is a known skip, while an UNRECOGNISED review decision is
  unprobed rather than dropped. Measured on this box: 53 of 53 open PRs are `BEHIND` or `DIRTY`, so
  before this the check graded nothing at all and said `PASS`.
- **Usage errors are exit 3, as documented.** argparse exits 2, which is this tool's INCONCLUSIVE
  code; `--bogusflag` read to a caller as "the fleet is inconclusive".
