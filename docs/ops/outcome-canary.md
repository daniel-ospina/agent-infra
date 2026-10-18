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
| `controller_cycling` | a controller process exists **and** its log advanced within the window | `CONTROLLER_ABSENT`, `LAUNCHD_PID_UNRESOLVED` | `LOG_SILENT`, `LOG_MISSING` |
| `queue_readable` | the last refresh produced a READABLE verdict | `QUEUE_UNREADABLE`, `QUEUE_NEVER_READ`, `QUEUE_PARTIAL` | `NO_REFRESH` |
| `work_dispatched` | a `[dispatch] … -> <issue>` line is inside the window | `NOT_DISPATCHED`, `NO_DISPATCH`, `NO_DISPATCH_GATED` | `NO_CYCLE_IN_WINDOW` |
| `pr_created` | ≥1 PR opened in the PR window | `NO_PR_CREATED` | `IDLE_NO_WORK` (inconclusive) |
| `pr_merged` | ≥1 PR merged in the PR window | `NO_PR_MERGED` | `IDLE_NO_WORK` (inconclusive) |
| `pane_daemon` | a live `cmux-tui` **and** a readable protection value that protects it | `DAEMON_ABSENT`, `PROTECTION_ABSENT`, `PROTECTION_PARTIAL` | `PROTECTION_UNEVALUABLE` |
| `headroom` | disk and available memory above their floors, **with the numbers printed** | `BELOW_FLOOR` | `PROBE_UNREADABLE` |
| `landers` | every green+mergeable PR is armed or railed | `LANDER_MISSING` | `LANDER_EXPIRED`, `PARTIAL_POPULATION` |

**`work_dispatched` is the one that matters most.** Everything above it can pass while it fails —
measured 2026-10-18: controller cycling, `queue=READ(223)`, 47 candidates, and **47
`could not build claim commit` refusals with zero dispatches**. That is the shape a component-level
suite is structurally unable to see.

A `PASS` that hides a degradation is the failure this file exists to end, so `work_dispatched` prints
the refusal counts **even when it passes**: four dispatches beside 955 refusals is not a green fleet,
and the reader must be able to see that in one line.

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
  still supports "readable, n candidates" — failing that would cry wolf on a box that is dispatching
  from it. An `EMPTY` read carrying **no age at all** is also `STATE_FROZEN`: the harness emits that
  shape from a torn state file, and an unaged record is a stale flag waiting to be read as current.
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
python3 tools/fleet/outcome_canary.test.py              # 70 tests
python3 tools/fleet/outcome_canary.test.py --mutations  # 44 mutations, each must go RED
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
  red-reading green PR drops out of the `landers` population. Attempts are grouped on `(app, name)` —
  the identity the merge rail itself groups on (`scripts/admin-merge.sh`) — and only the newest attempt per group is
  graded, newest being the highest `id` (`started_at` is nullable, so a timestamp-first rank can rank
  a stale attempt over a fresh one). A legacy status context carries `state`, not `conclusion`, and is
  read too: reading only `conclusion` graded every one of them RED.
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
