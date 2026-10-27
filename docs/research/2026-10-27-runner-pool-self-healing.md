# The runner pool cannot heal itself — measured on `pi-cell-4`, 2026-10-27

**Status:** research + verified design. **Issue:**
[#2892](https://github.com/daniel-ospina/agent-infra/issues/2892) — R1–R4 ship with this change
(`scripts/ci_runner_pool.sh`). R5–R7 are filed as [#2893](https://github.com/daniel-ospina/agent-infra/issues/2893),
[#2894](https://github.com/daniel-ospina/agent-infra/issues/2894),
[#2895](https://github.com/daniel-ospina/agent-infra/issues/2895) — this file is the durable record
for all seven, so the measurements do not have to be taken again.

⚠️ One defect was found by the first LIVE run of the new verb and one by review, and both are recorded
here because they are the reason the retirement is a rename: a partially failed `rm -rf` stripped
`.runner` and left 6.9 GB that no verb could see (§3.6), and `tail | grep -q` returns 141 under
`pipefail`, silently disabling the whole evidence read on any large log (§3.7).

Companion code: `scripts/ci_runner_pool.sh` (header carries the "why" per verb),
`scripts/ci_runner_pool.test.sh` (hermetic suite), `scripts/ci_runner_gate.sh` (the fallback gate,
which this file's R5 wires to provisioning).

---

## 1. The report that started this

> "cell 4 has 0 runners … its registration was deleted server-side, `--replace` can't recover
> because `config.sh` refuses 'already configured' and the tool never clears the local `.runner`, and
> provisioning a replacement is refused by its own guard (9G free against 44G needed). So we run at
> 8, not 11."

Every clause reproduces. The diagnosis is right about the mechanism and incomplete about the
arithmetic: **the box was never down to zero usable capacity, and one of its three slots was
recoverable with a verb that already shipped but is not armed anywhere.**

## 2. What the box actually has (measured 2026-10-27 03:52–04:20Z)

`cmux vm exec pi-cell-4` — 8 vCPU / 16 GB, disk `126G 112G 8.6G 93% /`.

| registration dir | `.runner` `agentName` | agentId | listener |
|---|---|---|---|
| `/opt/gh-runner-x64` | `pi-runner-x64-1` | 33 | **LIVE** |
| `/opt/gh-runner-x64-1` | `pi-runner-cell4-x64-1` | 47 | dead → **REVIVED in this session** |
| `/opt/gh-runner-x64-2` | `pi-runner-x64-2` | 34 | **LIVE** |
| `/opt/gh-runner-cell4-x64` | `pi-runner-cell4-x64-1` | 35 | dead, **registration deleted server-side** |
| `/tmp/actions-runner/tortoise-cell4-1` | — | — | no `.runner` (empty dir) |

Four findings that the "0 runners" framing hides:

1. **All four registrations are `daniel-ospina/tortoise`** (`"gitHubUrl"` in every `.runner`). The
   box contributes **zero agent-infra runners by construction** — registration is repo-scoped.
   Capacity math for *agent-infra merges* is not a runner problem at all: agent-infra CI is
   `.github/workflows/*.yml` × 5 jobs, every one `runs-on: ubuntu-latest` (GitHub-hosted).
2. **Two directory names point at ONE GitHub name.** `gh-runner-x64-1` and `gh-runner-cell4-x64`
   both carry `"agentName": "pi-runner-cell4-x64-1"` (agentIds 47 and 35). GitHub's identity is the
   *agentName*, the tool's slot identity is the *directory basename* — so the pool over-counts.
   This is the signature of a `--replace`/duplicate-config: replacing a name deletes the old
   registration, which is exactly the "registration has been deleted from the server" state agentId
   35 is in.
3. **agentId 47 was revivable, and is now live.** Starting its listener produced
   `Session created` → `Listening for Jobs`. Cell-4 now carries 3 live runners = its own
   core-aware ceiling (`ceil(8/3) = 3`). The "8, not 11" shortfall is therefore mostly *dead
   listeners and orphans*, not missing capacity.
4. **The box never had a measuring pool root.** `RUNNER_ROOT=/opt` (where all four installs live)
   makes every pass exit 2: `/opt/containerd` is `drwx--x--x root`, unreadable to `cmux`, and
   "a dir we cannot inspect is counted as a slot" turns a legitimately mixed root into a permanent
   `cannot-measure`. See §4.4.

## 3. Reproduced failure chain

**3.1 The orphan.** Its systemd unit is `inactive`; the journal is unambiguous:

```
03:31:29 runsvc.sh: Failed to create a session. The runner registration has been deleted from
         the server, please re-configure. Runner registrations are automatically deleted for
         runners that have not connected to the service recently.
03:31:29 runsvc.sh: Runner listener exit with terminated error, stop the service, no retry needed.
03:32:30 config.sh: WRITE ERROR: Cannot configure the runner because it is already configured.
         To reconfigure the runner, run 'config.cmd remove' or './config.sh remove' first.
```

**3.2 `--replace` cannot reach the server.** Verified against GitHub's own contract: the refusal
comes from `ConfigurationManager`'s LOCAL precondition (`.runner` present ⇒ "already configured"),
raised before the flag is read — so `--replace` is never evaluated. The documented sequence is
`config.sh remove` (needs a *remove token* from the API, 1 h TTL) **or** deleting the stale local
install. `actions/runner#3238` and `#756` both name `.runner` deletion as the local cleanup for a
registration that no longer exists server-side.

**3.3 The recovery loop is invisible.** I ran the exact start the tool performs, on the orphan:

```
( cd /opt/gh-runner-cell4-x64 && exec ./run.sh ) >> listener.log 2>&1 &
→ DIED rc=0 after 4s
listener.log: Failed to create a session. The runner registration has been deleted from the
              server, please re-configure. … / Runner listener exit with terminated error …
```

⛔ **`rc=0`.** Exit status does not classify this state, and neither does process appearance:
`start_listener` returns the moment the process appears (~0.5 s) and reports `listener_pid=N`,
~3.5 s before the death. That is why `reconcile` on this box would print `restarted=N` forever while
the slot stayed dead — the "self-healing" pass exists, is idempotent, and **cannot fail**.

**3.4 The pass refuses before it acts.** On the box's own harness copy:

```
$ RUNNER_ROOT=/opt bash scripts/ci_runner_pool.sh reconcile --dry-run
dry-run: would start the listener for name=gh-runner-cell4-x64     ← will die at +4s
dry-run: would start the listener for name=gh-runner-x64-1
dry-run: ceiling would be reached slots=5+0 ceiling=3 ncpu=8
reconcile: dead=2 restarted=2 added=0 … cannot=1 slots=5 ceiling=3 … dry_run=1
rc=2   cannot-measure why=instance-unreadable path=/opt/containerd
```

`slots=5` = 4 registrations + `/opt/containerd`. Against `ceiling=3`, the ADD arm can never run, and
the orphan can never be retired, because **no verb deletes a registration directory**.

**3.5 Nothing is ever scheduled.** Timers on the cell: `eldato-harness-apply`, `cell-self-pin`,
`eldato-disk-reaper`, `cell-reclaim`, `eldato-ai-drainer`. No runner timer, and
`grep -r ci_runner_pool` finds no caller anywhere in the repo. `ci_runner_gate.sh` re-labels existing
runners only; it has never created capacity.

## 4. Why a naive fix would be wrong (the four traps)

**4.1 Deletion is not proof of orphanhood — clock skew fakes it.** GitHub emits this exact message
when the host clock is wrong and session creation fails for that reason
(`actions/runner#4648`, `#1798`; `actions-runner-controller#3748`). Cell-4 reports
`System clock synchronized: no`, NTP `n/a` (measured skew vs GitHub's `Date:` header was 4 s, so
*this* deletion is real). ⇒ any retirement must be gated on a **measured** skew, or on API
confirmation, and must refuse (`preserve`) when neither can be read.

**4.2 Re-registering a name can destroy a live runner.** `pi-runner-cell4-x64-1` is held by agentId
47 (now live). Re-registering that name would delete agentId 47's registration — turning a working
capacity recovery into a new orphan. ⇒ retire the *stale directory*; re-register the name **only**
when no other directory on the box holds that `agentName` with a live listener.

**4.3 The 14-day policy does not explain this one.** GitHub removes standard self-hosted runners
after **>14 days** without connecting (ephemeral: 1 day). These were registered 2026-10-22 and went
quiet within days. ⇒ name the causes honestly (replacement/duplicate-config), and do not build a
policy explanation on a timeline that does not fit.

**4.4 Excluding a non-runner directory is provable without `read` permission.** `/opt/containerd` is
`0711`: iteration (`r`) is denied but traversal (`x`) is allowed, so
`[ -e /opt/containerd/.runner ]`, `…/config.sh`, `…/run.sh`, `…/bin/Runner.Listener` all answer
**false** — measurably *not a registration*, not "unmeasurable". The existing safety rule (count what
you cannot inspect) is right for `chmod 000`/`444`, where the markers cannot be probed at all; it is
over-broad for a searchable directory. Distinguishing them fixes the root without weakening the
over-add guard.

## 5. The four shipped fixes (R1–R4)

| # | Change | Invariant it restores |
|---|---|---|
| **R1** | New verb `reclaim`: retire a registration whose `.runner` is present, whose listener is dead, and whose evidence says GitHub deleted the registration. Retire = remove the local install (the documented cleanup); re-register the name only if no live sibling holds it. | "A state the tool created must be a state the tool can leave." |
| **R2** | `start_listener` verifies the session, not the process: after the process appears it holds for the settle window and requires it still alive **and** no `registration has been deleted` line in the newest evidence. Death with that signature ⇒ `rc 6` (`orphaned`, a new code) so `reconcile` routes it to R1 instead of counting it restarted. | "A start is not a session." |
| **R3** | `slots` counts **capacity** — live + revivable, deduped by `agentName` — not directory names; `registrations=` and `orphaned=` are printed alongside. Ceiling gates use capacity. | "The ceiling bounds concurrent runners, not directory names." |
| **R4** | `registered_dirs` excludes a directory that is searchable but unreadable **and** carries none of the four install markers; unreadable-and-unsearchable stays counted (over-add guard unchanged). | "Provably-not-a-registration ≠ unmeasurable." |

Exit-code contract after this change (extends the documented set): `6` = the registration is
provably orphaned (recoverable with `reclaim`), distinct from `2` (could not measure/act) and `3`
(gate refusal) — a scheduler must be able to branch on it.

## 3.6 The retirement is a RENAME, because the first version left 6.9 GB named by nothing

The first `reclaim` did what every other teardown in this repo does: `rm -rf "$dir"`. On `pi-cell-4`
that failed halfway — systemd had written `_diag` as root — and the pass honestly reported
`cannot-act why=retire-failed`. The result was still the worst of both worlds: `rm -rf` had already
unlinked `.runner`, so 6.9 GB sat on disk that `status`, `slots` and every later pass were blind to
(each identifies a registration *by* `.runner`). A bare `rm -rf` cannot be made atomic; a rename can.
`reclaim` now moves the install to `<name>.retired-<stamp>` first — the pool loses the registration in
one step regardless of what the bytes do next — then deletes, and any survivor is reported as
`quarantined=` and kept visible as a `QUARANTINE` row in `status` until somebody removes it.

## 3.7 `tail | grep -q` returns 141 under `pipefail` — the whole evidence read, disabled by log size

`grep -q` exits at the first match, `tail` dies of SIGPIPE, and with `set -o pipefail` the *pipeline*
returns 141 — so the `if` was false with the signature sitting in the file. Reproduced on an identical
230 KB log (signature at byte 0): `preserve why=no-orphan-evidence`, rc 0. Below the pipe buffer the
same file retired correctly, i.e. the defect was size-dependent, so it would appear and disappear
between passes on exactly the long-lived installs that accumulate a log. The read now captures the
bytes and matches with `case` — no pipeline, no external process.

## 6. What the fleet should do today (operator steps, no code)

1. `bash scripts/ci_runner_pool.sh restart --name <dead>` recovers every revivable slot — it did on
   cell-4 (2 → 3 live) and needs no capacity reading at all.
2. `bash scripts/ci_runner_pool.sh reclaim --dry-run` (this change) then `reclaim` retires the
   orphan and frees the name.
3. `RUNNER_ROOT` must name the directory that CONTAINS the installs (`/opt` here) — a root that
   excludes a live listener is refused as `pool-root-incomplete` by design.

## 7. Filed as follow-ups (R5–R7)

- **[#2893](https://github.com/daniel-ospina/agent-infra/issues/2893) — arm it, and arm it on demand.** `cell-runner-reconcile.timer` (10 min) + the macOS launchd
  twin; plus `reconcile --if-demand` keyed on `gh api …/runs?status=queued` vs live capacity, called
  from the controller's `[cap]` block and from `ci_runner_gate.sh`'s fallback arm. Without this,
  R1–R4 are verbs nobody calls — the exact defect that kept cell-4 at 2 live runners.
- **[#2894](https://github.com/daniel-ospina/agent-infra/issues/2894) — disk: reclaim before refusing.** Runner `_work` is 5–9 GB per install here
  (`_tool/Python` 2.8 GB, checkout 1.5 GB, `_update` 682 MB); `disk-reaper`'s duplicate-install class
  reads `roots=/tmp` and never sees `/opt`. Add a `runner-work` class (age-floored prune) and extend
  `REAP_DI_ROOTS`. ⛔ And the "9 GB free against 44 GB needed" refusal is not a number in this
  repo's runner tooling (`ci_runner_pool.sh` has no disk gate at all; an add costs ~300 MB of install
  copy): whatever guard produced it must print `free_before → free_after(post-reclaim) → floor`.
- **[#2895](https://github.com/daniel-ospina/agent-infra/issues/2895) — the cell's own maintenance is red.** `cell-reclaim.service` fails every 30 min
  (`REFUSING: no PR surface readable`, exit 2) so worktrees never drain; the harness checkout's
  gitdir (`/tmp/cell-ai/.git/worktrees/harness`) is gone and the box runs pinned `38d4ed70cacf`,
  so no merged fix reaches it until the pin moves. Both are "silent off" failures of the same family
  as this one.
