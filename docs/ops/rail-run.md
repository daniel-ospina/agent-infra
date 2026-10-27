---
title: "rail-run — running the merge rail without letting a tool call kill it (#2885)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-27
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2885, issue-1167, merge-rail, admin-merge, rail-run, pid-identity, fleet-liveness, tool-timeout
---

# rail-run — running the merge rail without letting a tool call kill it

`scripts/rail-run.sh` starts the merge rail (`scripts/admin-merge.sh`) **detached** and gives a lane a
first-class verdict to poll. It exists because of a bound mismatch between two processes.

## The defect (measured, agent-infra#2885)

| bound | value | owner |
|---|---|---|
| a blocking tool call | **1800 s** | the harness (`pi`) — not settable from this repo |
| the rail's FIRST-CHECKS ceiling (`ADMIN_MERGE_FIRST_CHECKS_CEILING`) | **18064 s** | `scripts/admin-merge.sh` (#1167 is this one) |

A lane that ran `bash scripts/admin-merge.sh <PR>` inside a blocking tool call was SIGTERMed at
1800 s while the rail was legitimately still waiting on CI. Measured 2026-10-26 on PR #2873:

| event | timestamp |
|---|---|
| the lane's rail invocation started | `22:40:54Z` |
| the rail still logging `FIRST-CHECKS wait: still RUNNING and PROGRESSING` | `23:10:47Z` |
| the lane's bash call killed at its 1800 s cap | `23:10:47Z` |
| **#2873 merged** (head unchanged, attestation intact) | `03:56:04Z` |

So a *healthy* rail read as a failure, and **no rail verdict exists for that head at all** — the
lane could not tell "still running" from "refused" from "killed".

## Use

```bash
bash scripts/rail-run.sh start  <PR> ARGS...                              # returns at once
bash scripts/rail-run.sh status <PR> (--repo owner/repo) (--run <run-id>)        # poll
```

`start` launches the rail in its own session with its own log and its own recorded exit status,
prints the run id / log path / exact poll command, and exits. Nothing in this script waits on the
rail, so no tool call can be capped by it.

State lives under `${RAIL_RUN_DIR:-${O:-$HOME/orchestrator}/state/rail-run}/<repo-key>/pr-<N>/<run-id>/`
(`pid`, `start`, `railpid`, `railstart`, `rc`, `log`, `repo`, `rail`, `args`, `started`, and a
`latest` pointer). Three knobs: `RAIL_RUN_DIR`, `RAIL_RUN_RAIL` (the rail, default `admin-merge.sh`
beside this script), and `RAIL_RUN_CLAIM_MAX` (default 60 s).

**One rail per PR.** `start` takes an atomic `mkdir` claim *before* it probes, so two concurrent
starts for one PR cannot both launch a rail (two merge attempts on one head). The claim is released
only once `latest` is published; a claim whose launcher is positively gone, or one older than
`RAIL_RUN_CLAIM_MAX`, is cleared and retried once. A claim that has not written its pid yet is **in
flight, not dead** — reading that window as "no owner" is how a guard deletes a live claim.

## States (each one derived, never guessed)

| state | exit | meaning |
|---|---|---|
| `running` | 10 | no exit status yet, and the **recorder** is alive — or the **rail** is, when the recorder has been SIGKILLed out from under it |
| `landed` | 0 | the PR is MERGED. `verdict=rail` when the rail exited 0; `verdict=artifact` when the merge is real but the rail wrote **no verdict or a non-zero one** |
| `refused` | 20 | rc=2 (it refused the **invocation**), or rc≠0 **with the rail's own `admin-merge: ✗ …` line** in the log: it refused this head |
| `killed` | 21 | the rail died of a signal (rc ≥ 128), named (SIGTERM / SIGKILL / …) |
| `gone-without-verdict` | 22 | **no exit status, recorder gone, rail not alive, PR not MERGED: this run produced no verdict.** Never reported as a landing |
| `exited-zero` | 23 | rc=0 and the PR is not merged (a `--dry-run` / `--print-bounds` inspection run) |
| `unknown` | 25 | an evidence read abstained: `ps` unreadable, no recorded incarnation, an unusable recorded start, a corrupt status file, an unreadable PR state, or a non-zero exit with **no** `admin-merge: ✗` line (an ERROR, not a verdict about this head) |
| `no-run` | 24 | nothing was ever started for this PR |

Other codes: `2` usage, `3` a live (or unverifiable) run already holds this PR, `5` the launch did
not start, `78` the identity library is missing.

Every poll prints its evidence on one line — `pid`, `rail_pid`, `rc`, `pr_state`, `merged`,
`started`, `log_bytes`, `log_age_s`, `verdict` — followed by reason lines.

**Liveness is not `%CPU` and not a first-match `ps` grep.** Identity comes from
`scripts/lib/pid-identity.sh`, the fleet's one process-identity rule, whose `unknown` verdict is an
abstention and never a death witness; a live pid whose incarnation does not match is not "running".
Both the **recorder's** and the **rail's** incarnations are checked, which is what keeps the two
load-bearing distinctions honest:

- **"still running" vs "no verdict"**: `running` (10) needs positive evidence that the run is alive
  (recorder or rail); `gone-without-verdict` (22) needs positive evidence that neither is; anything
  else — including an absent or unreadable record — is `unknown` (25).
- **"a verdict" vs "a merge"**: `landed` needs the MERGED artifact; `rc=0` alone is `exited-zero`
  (23) unless the PR says MERGED, and a failed artifact read is `unknown` for **every** exit status,
  so `killed`/`refused` can never be printed over a merge the API failed to report.

One live rail per PR: `start` takes an **atomic claim** (`mkdir`) *before* it probes the existing
run, so two racing starts cannot both launch a rail (two merge attempts on one PR). The probe itself
is on the previous run's incarnation, so a stale run directory never blocks a start — only positive
evidence of a live or unverifiable one does.

## What is NOT fixed here (the honest half)

**The 1800 s tool cap is the harness's, not this repo's.** Changing it belongs in `pi` (a
per-dispatch tool timeout), and this script does not depend on that happening: the poll is the
interface, so a lane works identically with or without a longer cap. Until the cap moves, **do not
run the rail in a blocking tool call** — use `start` + `status`.

Three stated residuals:

- **`session=shared`.** Isolation is used when `setsid` (or `python3`) is available; when neither is,
  the rail shares the caller's process group and a process-*group* kill aimed at the caller reaches
  it. `start` measures this after the spawn and prints `session=own|shared|unknown` — it never claims
  isolation it did not get. The tool-cap collision is still removed in the `shared` case, because the
  caller's call has already returned.
- **A SIGKILL of the recorder** writes no exit status by construction. The rail can outlive it and
  still merge; the poll then reports `running` (the rail is what is alive), and once the rail is gone
  it reports `gone-without-verdict`. If the PR turns out MERGED, the state is `landed
  verdict=artifact`, which says the merge is real and that *this run* certified nothing.
- **A microsecond window**: the rail's pid is recorded immediately after the spawn, so a SIGKILL in
  that window leaves a run whose rail is unrecorded. It reads `gone-without-verdict`, and each
  subsequent poll re-reads the artifact — a merge that then happens is reported as
  `landed verdict=artifact`, never as a rail verdict.

## Tests

```bash
bash scripts/rail-run.test.sh      # no network, no real gh, no real rail
```

**105 passed, 0 failed** (`bash scripts/rail-run.test.sh`, ~47 s, no network). The suite is mostly
negative — `running` must never read as landed or refused, `rc=0` is not a landing when the artifact
disagrees, `gone-without-verdict` is never a landing *or* claimed over an unread artifact, an
unreadable liveness or PR read abstains, a live pid with the wrong incarnation is not "running", a
claim in its `mkdir`→`pid` window is in flight rather than dead, `--repo`/`--run` cannot escape the
run root, and two racing starts reach the rail exactly once. Every arm names the guard it discriminates; removing that guard
fails the arm (mutation-checked while writing it).
