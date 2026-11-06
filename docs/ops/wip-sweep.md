# WIP sweep — is a lane's uncommitted work on origin, or only on this box?

**Status:** shipped. `scripts/wip-sweep.sh` + `scripts/wip-sweep.test.sh` (one paired `ok`/`bad`
assertion per arm, every arm driven against a real bare remote — no assertion is recorded without an
observation from this run), and a hook in `scripts/cloud-cell-quiesce.sh`.
⛔ No assertion COUNT is written here on purpose: the two numbers this line has already carried (55,
then 65) both went stale the moment an arm was added, and a stale count in a status line is a claim the
suite does not support. `grep -c 'ok "' scripts/wip-sweep.test.sh` is the count, and it is never wrong.
**Issue:** agent-infra#3485. **Depends on:** `scripts/bg-rescue-wip.sh` (#2045, unchanged semantics).
**Not covered here:** the typed `refs/wip` index and the ref-naming rule — that is agent-infra#3484.

## The question this answers

> A lane's uncommitted work exists in exactly one place. Is that place still this box's disk?

`bg-rescue-wip.sh` answers it *for one worktree, at one moment*, and it is called from
`spawn-gate.sh`'s `run_agent` **at its end**. So it rescues the lanes that stop *through that
function* — an ordinary end of turn, and a cap kill — and nothing else:

| how the worktree is abandoned | WIP on origin? | WIP destroyed? |
|---|---|---|
| lane ends normally through `run_agent` | yes | no |
| lane killed at its cap (`spawn-gate`) | yes | no |
| **OOM / SIGKILL / crash / reboot** | **no** | not yet — disk only |
| **cell quiesce / reclaim / VM destroyed** | **no** | **yes, totally** |

The rescue is a *call inside a lifecycle*, not a sweep. `wip-sweep.sh` is the sweep: it walks every
worktree of every repo it is given, asks what is at risk, and archives each dirty one to
`refs/wip/<slug>` **on origin**. Once it has run, local disk is no longer authoritative.

## The three verdicts, and the one rule that matters

Every worktree is classified by `bg-rescue-wip.sh --verdict` — the same code path the rescue itself
uses, deliberately not a second copy:

| verdict | exit | meaning |
|---|---|---|
| `clean` | 0 | the status SUCCEEDED and enumerated everything, and there is nothing uncommitted |
| `dirty` | 1 | there is uncommitted work — `paths=<n>` says how much |
| `cannot-verify` | 2 | the listing FAILED or was INCOMPLETE (**no** `paths=` field) |

⛔ **`cannot-verify` is never `clean`, and `cannot-verify` is never "nothing to rescue".** An empty
`git status` only means clean when the status succeeded and could read every directory; a status that
warned `could not open directory` has NOT enumerated the worktree. This is the single most important
rule here — it is what a sweeper gets wrong when it re-derives the question from its own `git status`,
and the mutant that reverts it (`AT_RISK=1` → `AT_RISK=0` in `bg-rescue-wip.sh`) is the one recorded
on the PR: a dirty worktree with an unreadable directory then reports
`status=ok rc=0 seen=1 clean=1 dirty=0 unmeasured=0` — a clean fleet over unfiled work.

A worktree record whose **checkout directory is gone** is the one case that is not measured: git says
the record is `prunable`, no directory exists to hold uncommitted work, and the row is recorded as
`skip`. Requiring *git's own* prunable verdict is what stops that becoming fail-open — a permission
blip makes the directory stat-invisible without git saying prunable, and that case is
`cannot-verify`.

## The pass

```
wip-sweep.sh [--repo PATH]... [--apply] [--max N] [--print-status]
```

- **Dry run is the DEFAULT.** It classifies and reports, archives nothing, and exits `1` when it found
  work it would have archived. `--apply` is the arming decision and it lives in the caller's command
  line, never in an environment default (the `pi-reap-worktrees.sh` contract).
  `cloud-cell-quiesce.sh` passes `--apply` because it is about to hand the box on: a report-only hook
  on the path that destroys the disk would archive nothing for ever while reading as a safeguard.
- **Bounded twice.** `--max N` (default 25) caps ARCHIVES per pass, and the pass budget
  (`WIP_SWEEP_BUDGET`, default 900 s) stops it between worktrees.
  ⛔ **`0` is a disable for exactly those two and nothing else.** `tb_timeout 0 …` means *unbounded*, and
  a zero staleness window means *everything is stale* while reading as *do not check* — so
  `WIP_SWEEP_STATUS_TIMEOUT`, `WIP_SWEEP_RESCUE_TIMEOUT` and `WIP_SWEEP_STALE_SECONDS` must be greater
  than zero and are refused otherwise (exit 2). Every subprocess — each verdict, each status, each phase
  of a rescue, and the read-back below — runs under the shared `scripts/lib/bounded.sh` watchdog; there
  is no unbounded call **that can block on the network or on a large tree** — those are the failures
  this pass cannot survive, because it is what the quiesce runs before the box goes. (`mktemp`, `date`,
  `sed` and the record write run outside the watchdog: a local syscall, not a hang surface.) What the
  cap defers
  is **named** (`deferred=N`, `status=incomplete`, exit `1`), never silently dropped.
- **The archive is READ BACK, not inferred from an exit code.** `bg-rescue-wip.sh` exits `0` both for
  *archived and pushed* and for *clean — nothing at risk*, so a worktree that goes clean between the
  verdict and the rescue would otherwise be recorded as archived with a ref that does not exist. After
  the rescue, the sweep reads the ref from origin with one bounded
  `git ls-remote --exit-code origin refs/wip/<slug>` and keeps three outcomes apart: **0**
  `archived-ref-present-on-origin`; **2** (origin has no such ref) `rescue-exited-0-but-ref-absent-on-origin`
  and the pass fails; **any other rc** (origin unreadable) `archive-ref-unverifiable` and the pass fails.
  Neither failure says "not archived" — they say "not proven", which is the only thing the sweep is
  entitled to claim. A fourth failure, `archived-but-ref-unparsed` (a rescue that exited 0 without
  naming a slug), is the same class.
  ⛔ **What the read-back proves, exactly: that a `refs/wip/<slug>` EXISTS on origin.** It does not prove
  the commit is *this* pass's snapshot — a pre-existing ref of the same slug satisfies the existence
  test — which is why the note is worded `ref-present` and not `verified`. That residual is bounded and
  named: in the branch where a pre-existing ref makes it so, the rescue took its *clean* path, so the
  lane's work is committed on its branch, and what is wrong is a stale-archive claim rather than loss.
- **No ambient repo.** There is deliberately no `$REPO` default. `$REPO` is a generic name the cell
  supervisor and the Mac bring-up both export, and a sweep that adopted it archived work from a repo
  nobody asked about — measured while writing this: an arm meant to prove "no repo resolvable" swept a
  139-worktree checkout and pushed 7 archives to a real origin. `cloud-cell-quiesce.sh` passes
  `--repo "$REPO"` explicitly.

### Exit codes

| code | meaning |
|---|---|
| 0 | every worktree MEASURED, and every dirty one archived (apply), or nothing found (dry run) |
| 1 | INCOMPLETE — the cap or the budget deferred work, or a dry run found work it would archive |
| 2 | usage (including an unparseable `--max`: a typo'd bound must never mean "no bound") |
| 3 | FAIL-CLOSED — a worktree unmeasured, a rescue failed (the work is still only on this disk), no repo resolved, or the rescue / bounded-execution library is missing |

A missing rescuer is exit `3`, never `0`: the absence of the tool says nothing about the state of the
worktrees. This is the same polarity as `spawn-gate.sh`'s `rescue=UNAVAILABLE`.

## The index

One TSV row per worktree examined, in `${O:-$HOME/orchestrator}/state/wip-sweep.tsv`:

```
ts  repo  path  branch  head  verdict  paths  age_h  issue  ref  note
```

`issue` is derived from the branch (`feat/8090-tm`, `fix/3442-nonvacuity` → the issue number). A dirty
worktree whose branch carries no issue number is **reported** (`issue=-`, a loud line, `no_issue=N`) —
the archive still exists on origin, but nothing ties it to an issue, and searching 222 inconsistently
named refs is not a substitute for an index. The typed version of this, and the ref-naming rule, is
**#3484**; this file records the link and does not re-decide the naming.

`wip-sweep.status` (key=value, written atomically, the surface a fleet instrument should read):

```
status=ok|incomplete|failed   rc=…  ts=…  mode=apply|dry-run
seen=… clean=… skipped=… dirty=… archived=… deferred=… unmeasured=… failed=… no_issue=… repos=… watchdog=…
```

`seen = clean + skipped + dirty + unmeasured` holds, and **`skipped` is not folded into `clean`**. A
bare repo and a record git itself calls `prunable` were *not examined*; counting them as clean would
make a summary over an unexamined disk indistinguishable from one where nothing is at risk.

`--print-status` answers from that record alone: `0` ok, `1` incomplete, `3` failed / stale / never.
**`never` and `stale` are not success** — a sweeper that has not run is a box whose WIP is on the disk
and nowhere else. A record whose `ts=` is missing or unreadable also answers `3`: an uncomputable age is
not freshness.

## The quiesce hook

`cloud-cell-quiesce.sh` runs the sweep **after** it has killed every session and **before** it re-seeds
and restarts one controller (step 3b). Lanes are dead by then, so their trees are final.

- A missing or failing sweep is **loud** (`FATAL:` lines) and makes the quiesce **exit non-zero**.
- It does **not** abort the quiesce. Aborting would leave the cell with zero controllers — worse than
  the state the script exists to end. Supervision is restored, the run prints `NOT DONE`, and the exit
  code carries the failure to `cloud-cell-bringup.sh --check` and the operator.

## What this does NOT do (stated, not implied)

- **There is no timer yet.** The sweep is the mechanism; `cloud-cell-quiesce.sh` is the one lifecycle
  hook that runs it, and that closes the row of the matrix where the work is *destroyed* rather than
  merely at risk. A periodic clock (a launchd/systemd unit) is **not** shipped here: `fleet_srcs`
  already delivers `install-disk-reaper-timer.sh` and `install-harness-apply-timer.sh`, each ~800 lines
  of render-install-verify, and a third scheduling stack is a different change with its own review
  surface. Until it exists, an OOM-killed lane on a box nobody quiesces keeps the pre-#3485 exposure —
  and `refs/wip/*` from the next `run_agent` end, or from a manual `wip-sweep.sh --apply`, is what
  rescues it. Recorded here so a green PR is not read as "the clock exists".
- **The quiesce's claim is REPO-scoped, not box-scoped.** It sweeps `--repo "$REPO"`, which is the one
  checkout the cell is being reset onto; another clone's worktrees on the same box are NOT swept and the
  success line says so. A box-wide sweep is `WIP_SWEEP_REPOS=A:B wip-sweep.sh --apply`.
- **It never deletes.** It adds commits to `refs/wip/<slug>` on origin and writes nothing into the
  worktrees it examines (`bg-rescue-wip.sh` uses a throwaway index and never moves the branch).
- **A `cannot-verify` worktree is a failed pass, not a retry.** A record that is both unreadable and
  dirty needs a human; the sweep names it and stops short of claiming the box clean.
