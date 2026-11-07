# WIP sweep — is a lane's uncommitted work on origin, or only on this box?

**Status:** shipped. `scripts/wip-sweep.sh` + `scripts/wip-sweep.test.sh`, plus a hook in
`scripts/cloud-cell-quiesce.sh`. The suite builds real `git init --bare` remotes for the runs it makes,
reads the records those runs write, and drives some arms from hand-written records or refused inputs with
no remote at all. No assertion is recorded without an observation from that run.
⛔ This line carries no assertion COUNT and no inventory of which arm touches a remote, on purpose: two
counts (55, then 65) and four separate attempts to enumerate the remote-touching arms were stale or
simply wrong within a round of being written. A number or a list here is a claim the suite cannot keep.
`grep -c 'ok "' scripts/wip-sweep.test.sh` is the count, and it is never wrong.
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

**Two** record classes are not measured. A **bare repository** record has no working tree at all, so it
is recorded as `skip` (`bare-repo-no-working-tree`). A worktree record whose **checkout directory is
gone** is the other: git says the record is `prunable`, no directory exists to hold uncommitted work,
and the row is recorded as `skip` (`prunable-checkout-dir-absent`). Requiring *git's own* prunable verdict
for the second is what stops it becoming fail-open — a permission blip makes the directory
stat-invisible without git saying prunable, and that case is `cannot-verify`.

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
  (`WIP_SWEEP_BUDGET`, default 900 s) bounds the WHOLE pass: it is tested before every examination, not
  only before an archive, so a pass over a checkout with hundreds of CLEAN worktrees is still bounded by
  the budget rather than by `worktree_count x WIP_SWEEP_STATUS_TIMEOUT`.
  ⛔ **And every bounded call INSIDE an examination is clamped to what is left of the budget** — the
  verdict, the commit count, the age read, the rescue and the origin read-back all run under
  `min(their own bound, remaining budget)`. Without that, the true worst case was
  `WIP_SWEEP_BUDGET + one examination` (up to 540 s with the defaults), and a rescue cut off mid-PUSH
  loses the very work it exists to move — on a quiesce whose own reclaim timeout the operator sized
  against this number. A call the budget cuts off is a **DEFERRAL**, not a failure: it is recorded
  `deferred-pass-budget`, counted in `deferred=`, and makes the pass `incomplete` (exit 1), never
  `failed`. A budget stop is stated — `status=incomplete`, `detail=… budget_stopped=yes` — never a green
  0 over worktrees it did not reach.
  **One exception:** `cloud-cell-quiesce.sh` passes `--max 0`, because on the path that destroys the disk
  a cap is a silent partial archive and nothing re-runs the pass.
  ⛔ **`0` is a disable for exactly those two and nothing else.** `tb_timeout 0 …` means *unbounded*, and
  a zero staleness window means *everything is stale* while reading as *do not check* — so
  `WIP_SWEEP_STATUS_TIMEOUT`, `WIP_SWEEP_RESCUE_TIMEOUT` and `WIP_SWEEP_STALE_SECONDS` must be greater
  than zero and are refused otherwise (exit 2). Every call THIS script makes that can block on the
  network or on a large tree runs under the shared `scripts/lib/bounded.sh` watchdog — each verdict,
  each status, each `git` call and the read-back below. The RESCUE is bounded as a WHOLE by
  `WIP_SWEEP_RESCUE_TIMEOUT` through that same watchdog; its *internal* phases are bounded by
  `bg-rescue-wip.sh`'s OWN private `bounded()` (its `bounded 25 git fetch` / `bounded 45 git push`),
  which is a second implementation this doc does not claim is the shared one — audit that file for
  rescue-phase bounds, not `scripts/lib/bounded.sh`. There is no unbounded call that can reach the
  network; such a hang is the failure this pass cannot survive, because it is what the quiesce runs
  before the box goes. (`mktemp`, `date`, `sed` and the record write run outside the watchdog: a local
  syscall, not a hang surface.) **The ONE remaining call the watchdog cannot cover is the usability probe
  that FINDS the watchdog** (`bounded_lib_path` sources each candidate library in a subshell and asks it
  to resolve its own timer — chicken-and-egg, so `tb_timeout` does not exist yet). It reads a local file
  and starts no subprocess, so it cannot reach the network; a candidate that hangs *there* is a broken
  install, and is named here rather than implied away. The sibling probe that executes the RESCUER
  (`rescue_usable`) runs after the library is resolved and is bounded by `WIP_SWEEP_STATUS_TIMEOUT`, so a
  rescuer that hangs is a REFUSAL (it cannot answer), never a hung pass. What the cap defers is **named** (`deferred=N`,
  `status=incomplete`, exit `1`), never silently dropped.
  ⛔ **A `124`/`137` IS NOT ONE FACT, AND ONLY ONE OF THEM IS A DEFERRAL.** The pass budget expiring is a
  deferral (`deferred-pass-budget`, exit 1). The RESCUE hitting its own `WIP_SWEEP_RESCUE_TIMEOUT` — a
  hung `git push` — is a **failure** (`rescue-exit-124`/`-137`, `failed=1`, exit `3`): the work is still
  only on this disk and, on a quiesce, no next pass is coming. Both surface on the same call, so the
  branch is gated on the budget actually being spent; a rescue timeout counted as “no time” is how a
  broken archive gets handed on as an unfinished one.
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
  test — which is why the note is worded `ref-present` and not `verified`. What that residual costs is
  a stale-archive CLAIM; it is not a claim that the work is safe, and it must not be read as one: a
  commit on a local branch is saved only if that branch is PUSHED, and this tool does not push branches
  (see "What this does NOT do").
- **No ambient repo.** There is deliberately no `$REPO` default. `$REPO` is a generic name the cell
  supervisor and the Mac bring-up both export, and a sweep that adopted it archived work from a repo
  nobody asked about — measured while writing this: an arm meant to prove "no repo resolvable" swept a
  139-worktree checkout and pushed 7 archives to a real origin. `cloud-cell-quiesce.sh` passes
  `--repo "$REPO"` explicitly.

### Exit codes

| code | meaning |
|---|---|
| 0 | nothing failed and nothing was deferred: every enumerated record was either EXAMINED or deliberately skipped (a bare repo, or a git-`prunable` record with no directory), and (apply) every dirty worktree was archived. A `skip` row does NOT mean "nothing to rescue" — it means nothing COULD be there; the sweep still refuses (exit 3) when it cannot tell |
| 1 | INCOMPLETE — the cap or the budget deferred work, or a dry run found work it would archive |
| 2 | usage (including an unparseable `--max`: a typo'd bound must never mean "no bound") |
| 3 | FAIL-CLOSED — a worktree unmeasured, a rescue failed (the work is still only on this disk), no repo resolved, or the rescue / bounded-execution library is missing |

A missing rescuer is exit `3`, never `0`: the absence of the tool says nothing about the state of the
worktrees. This is the same polarity as `spawn-gate.sh`'s `rescue=UNAVAILABLE`.

## The index

One TSV row per worktree examined, in `${O:-$HOME/orchestrator}/state/wip-sweep.tsv`:

```
ts  repo  path  branch  head  verdict  paths  age_h  issue  ref  note  unpushed
```

The header line is `#ts\trepo\t…` — one field per column, exactly like a data row, so a header-driven
reader resolves every column. `verdict` is `clean` / `dirty` / `skip` (a bare repo, or a record git calls
`prunable`) / `cannot-verify` / `unreached`. **`unreached` is one row per worktree the pass budget
stopped before examining**, so the index still reconciles against `git worktree list` after a stopped
pass and the pass under-reports nothing silently. Its `branch` is normalised (`fix/x`, not
`refs/heads/fix/x`) and its head is in the `head` column, exactly like an examined row — arms C5c/C5d/C5e
pin the COUNT and the COLUMNS, not just the row's presence, because round 3 of review measured a
transposed pair that a row-count assertion had passed. Two shapes are stated rather than implied: a
detached worktree's unreached row has an EMPTY `branch` (an examined one says `detached-<sha>`), and a
bare repository's has an empty `branch` and an empty `head` (an examined one says `-`/`-`) — the parser
forwards porcelain's own fields for a record it deliberately did not examine. `unpushed` is the count of commits on that branch
which **no remote has** — see "What this does NOT do"; it is `?` when HEAD or the remote set could not be
read, and it is carried on the cap/budget-DEFERRED rows too (those are the rows where work was **not**
archived). An `unreached` row cannot carry it (nothing was read), and neither can a `skip` row.

`issue` is the issue number the classifier itself read out of the branch — `bg-rescue-wip.sh --verdict`
reports it as `issue=<N>` beside the `slug=` it named the ref from, and this index copies that field. It
is **not** re-derived here: a second rule is a second answer, and it disagreed with the ref in both
directions (`fix/lane-3485` got a `3485` the ref does not carry, while `fix/1-x` got no link the ref
plainly has). One rule, one home. A dirty
worktree whose branch carries no issue number is **reported** (`issue=-`, a loud line, `no_issue=N`) —
the archive still exists on origin, but nothing ties it to an issue, and searching the existing refs —
whose names are inconsistent, because the slug is sometimes an issue number and sometimes a topic — is
not a substitute for an index. (No count is quoted here: the live registry moves, and a number written
into a doc goes stale silently.) The typed version of this, and the ref-naming rule, is
**#3484**; this file records the link and does not re-decide the naming.

`wip-sweep.status` (key=value, written atomically, the surface a fleet instrument should read):

```
status=ok|incomplete|failed   rc=…  ts=…  mode=apply|dry-run
seen=… clean=… skipped=… dirty=… archived=… deferred=… unmeasured=… failed=… no_issue=… repos=… watchdog=…
```

`seen = clean + skipped + dirty + unmeasured` holds **over the worktrees examined**, and **`skipped`
is not folded into `clean`**. A bare repo and a record git itself calls `prunable` were *not examined*;
counting them as clean would make a summary over an unexamined disk indistinguishable from one where
nothing is at risk. The one exception, stated rather than implied: a REPO-level failure (`git worktree
list` refused, or a path that is not a repository) adds an `unmeasured` count and its own
`cannot-verify` row and does **not** add to `seen` — it is a failure about the repository, not an
examination of a worktree, and it always fails the pass (exit 3).

⛔ **A LISTING THAT IS SHORTER THAN GIT'S OWN ADMIN RECORDS IS A REPO-LEVEL FAILURE, NOT A CLEAN REPO.**
The three repo-level notes are `worktree-list-failed` (the call refused), `worktree-list-empty` (it named
no worktree at all), `worktree-list-unverifiable` (git's common dir could not be resolved, so completeness
cannot be checked) and `worktree-list-partial`. The last one exists because `git worktree list --porcelain`
can answer a **subset** with `rc=0` and **completely empty stderr** — so an rc check and a stderr check
both miss it. Measured shape: damage one worktree's admin record (`.git/worktrees/<name>/gitdir`
removed), which an interrupted `git worktree add`, a racing `prune`, or a partial restore all produce; a
4-worktree repo then lists 3 and the omitted worktree is never enumerated, never swept, and the pass used
to answer `status=ok`. The cross-check is the count of directories in `$(git rev-parse --git-common-dir)
/worktrees/`, which is git's own authority for how many linked worktrees the repo HAS: a pass requires
`listed >= admin_dirs + 1` (the `+1` is the main worktree, which has no admin dir; a bare repo has no
`worktrees/` dir and lists exactly itself, so a missing dir reads as 0). It is **one-sided on purpose** —
only a listing BELOW the expectation escalates, so a future git that lists more than it holds admin dirs
can never false-block a sweep that was complete.

⛔ **The record is written TWICE: `status=running` before any worktree is touched — and before every
startup refusal that follows it — then the verdict.** That is what makes an interrupted pass visible. A
pass that crashes, is OOM-killed, is cut off by a quiesce, **refuses at startup** (a missing rescuer, no
repo to scan), or cannot write its verdict leaves `running` — which `--print-status` maps to
`failed`/exit 3 — instead of the PREVIOUS pass's `status=ok` standing there, fresh, for up to
`WIP_SWEEP_STALE_SECONDS`. **Two kinds of `exit 2` are different, and only one is untouched**: a
mistyped ARGUMENT is parsed before the record is resolved and leaves it alone; an ENVIRONMENT-BOUND
refusal (`WIP_SWEEP_BUDGET`, `WIP_SWEEP_STATUS_TIMEOUT`, `WIP_SWEEP_RESCUE_TIMEOUT`,
`WIP_SWEEP_STALE_SECONDS` that do not parse, or a zero watchdog) is the same failure mode as a missing
rescuer — a pass that will refuse EVERY time until the box is fixed — so it marks the pass as started and
`--print-status` answers `failed`/exit 3. Moving those validations above the marker would leave the
previous `status=ok` standing over a box that is sweeping nothing, which is the stale-green class this
marker exists to close. The one limit is stated rather than implied: a state dir
unwritable at BOTH the start and the end cannot be marked at all, so the old record stands and the pass
can only be loud on stderr with a non-zero exit — that is a host problem, and the reader cannot see it.
(`disk-reaper.sh` gets its equivalent witness from the scheduler's own exit status; this pass has no
scheduler yet, so the marker is the substitute.)

`--print-status` answers from that record **and from the same startup checks the pass makes**: `0` ok,
`1` incomplete, `3` failed / stale / never, and it prints a derived `rc=` on EVERY path including `never`
(a consumer keyed on `rc=` finds a value even on a box that has never run).
⛔ **THE READER IS NEVER GREEN OVER A BOX THAT CANNOT SWEEP.** Every startup refusal — an unusable
`WIP_SWEEP_BOUNDED_LIB` pin, an unparseable or zero bound (`WIP_SWEEP_BUDGET`, `WIP_SWEEP_MAX`, the two
watchdogs, the staleness window), a rescuer that does not exist — is answered on the reader surface as
`status=failed` / `rc=3` / `detail=<the cause>`, never as an older `ok`. That is why it is not literally
"the record alone": a green from a record the pass could no longer reproduce would be the stale-green
class this doc opens with. The ONE case it still answers from the record alone is a `WIP_SWEEP_BUDGET=0`
or `--max 0` (documented disables), which change no verdict.
**`never` and `stale` are not success** — a sweeper that has not run is a box whose WIP is on the disk
and nowhere else. The printed `status=` and `rc=` are the **derived** ones, emitted last, so the
key=value surface agrees with the exit code; the recorded values are kept beside them as `recorded=` and
`recorded_rc=` (both preceded by every other key, so each derived value is the LAST occurrence of its
own key — `detail=` follows `status=`, which is why the rule is per-key, not "derived keys end the
stream"). Neither emitted key can contain the substring `status=ok`, so even a `grep 'status=ok'`
consumer cannot read green off a record this run judged stale — the same polarity
`disk-reaper.sh --print-status` prints. Two clocks it refuses to
judge: a `ts=` that is missing or unreadable (an uncomputable age is not freshness), and a `ts=` in the
FUTURE (a clock step backwards — VM restore, NTP, a cell re-image — would otherwise disable the
staleness test for the whole skew).

## The quiesce hook

`cloud-cell-quiesce.sh` runs the sweep **after** it has killed every session and **before** it re-seeds
and restarts one controller (step 3b). Lanes are dead by then, so their trees are final.

- A missing or failing sweep is **loud** (`FATAL:` lines) and makes the quiesce **exit non-zero**.
- It does **not** abort the quiesce. Aborting would leave the cell with zero controllers — worse than
  the state the script exists to end. Supervision is restored, the run prints `NOT DONE`, and the exit
  code is non-zero for whatever RAN the quiesce.
  ⛔ And that is the whole alarm channel, stated so a green line is not read as more: **nothing reads
  that exit code automatically.** `cloud-cell-bringup.sh` contains no `quiesce` reference and no
  `wip`/sweep check — its siblings DO have one (`check_disk_reaper`, `check_reaping_armed`,
  `check_harness_apply`), so a `check_wip_sweep` is the obvious follow-up and this change does not
  claim it exists. Until then the failure reaches the operator who ran the quiesce, and the record at
  `$O/state/wip-sweep.status` reaches whoever looks. Do not restate this as a wired monitor.

## What this does NOT do (stated, not implied)

- **There is no timer yet.** The sweep is the mechanism; `cloud-cell-quiesce.sh` is the one lifecycle
  hook that runs it, and that closes the row of the matrix where the work is *destroyed* rather than
  merely at risk. A periodic clock (a launchd/systemd unit) is **not** shipped here: `fleet_srcs`
  already delivers `install-disk-reaper-timer.sh` and `install-harness-apply-timer.sh`, each a full
  render -> install -> read-back -> verify stack for BOTH platforms, and a third scheduling stack is a
  different change with its own review surface. Until it exists, an OOM-killed lane on a box nobody quiesces keeps the pre-#3485 exposure —
  and `refs/wip/*` from the next `run_agent` end, or from a manual `wip-sweep.sh --apply`, is what
  rescues it. Recorded here so a green PR is not read as "the clock exists".
- **The quiesce's claim is REPO-scoped, not box-scoped.** It sweeps `--repo "$REPO"`, which is the one
  checkout the cell is being reset onto; another clone's worktrees on the same box are NOT swept and the
  success line says so. A box-wide sweep is `WIP_SWEEP_REPOS=A:B wip-sweep.sh --apply`.
- **It does NOT save commits that exist only locally.** `bg-rescue-wip.sh` archives UNCOMMITTED work
  (#2045's scope, unchanged), so a branch with clean status and three unpushed commits is `clean` to
  this pass. It is not silent for any worktree the pass EXAMINED: such a worktree gets a
  `COMMITS ONLY ON THIS DISK` line recording the count, its TSV row carries `unpushed=<n>` (except the
  two post-rescue failure rows, `archived-but-ref-unparsed` and `rescue-exit-<rc>`, which carry `-` and
  fail the pass anyway), and the pass record carries `unpushed_worktrees=<n>`. Three row classes cannot say — `cannot-verify` (the pass
  fails, exit 3), and `skip` / `unreached` (no examination happened) — and none of the three can end as
  a green pass when work was left behind. On a
  box about to be reclaimed those commits die with it unless the branch is pushed; archiving branch
  commits is a separate capability and is not claimed here.
- **It never deletes, and it changes no working tree.** It adds commits to `refs/wip/<slug>` on
  ORIGIN; inside the examined worktree's own repository it writes two refs — the local pin
  `refs/wip-local/<slug>`, and the fetched copy of origin's snapshot `refs/wip-remote/<slug>` that the
  accumulate-don't-replace logic chains onto — plus the unreferenced commit/tree/blob objects the pin
  holds and `.git/FETCH_HEAD`. None of them is removed by this tool, and none is a branch. The working
  tree, the real index and the branch are untouched (`bg-rescue-wip.sh` stages into a throwaway index
  and never moves the branch — pinned by the suite's A5/A6).
- **A `cannot-verify` worktree is a failed pass, not a retry.** A record that is both unreadable and
  dirty needs a human; the sweep names it and stops short of claiming the box clean.
