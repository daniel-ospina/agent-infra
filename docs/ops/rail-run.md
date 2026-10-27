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
bash scripts/rail-run.sh start  <PR> [rail args...]                        # returns at once
bash scripts/rail-run.sh status <PR> [--repo owner/repo] [--run <run-id>]  # poll; 10 = running
```

`start` launches the rail in its own session with its own log and its own recorded exit status,
prints the run id / log path / exact poll command, and exits. Nothing in this script waits on the
rail, so no tool call can be capped by it.

## States (each one derived, never guessed)

| state | exit | meaning |
|---|---|---|
| `running` | 10 | the recorder is alive and has written no exit status |
| `landed` | 0 | the PR is MERGED. `verdict=rail` when the rail exited 0; `verdict=artifact` when the merge is real but the rail wrote no verdict |
| `refused` | 20 | the rail exited non-zero; its own last `admin-merge: ✗ …` line is printed |
| `killed` | 21 | the rail died of a signal (rc ≥ 128), named (SIGTERM / SIGKILL / …) |
| `gone-without-verdict` | 22 | **no exit status and the recorder is gone — this run produced no verdict.** Never reported as a landing |
| `exited-zero` | 23 | rc=0 and the PR is not merged (a `--dry-run` / `--print-bounds` inspection run) |
| `unknown` | 25 | an evidence read abstained (`ps` unreadable, an unusable recorded start, a corrupt status file, or rc=0 with an unreadable PR state) |
| `no-run` | 24 | nothing was ever started for this PR |

Other codes: `2` usage, `3` a live (or unverifiable) run already holds this PR, `5` the launch did
not start, `78` the identity library is missing.

Every poll prints its evidence on one line — `pid`, `rc`, `pr_state`, `merged`, `started`,
`log_bytes`, `log_age_s`, `verdict` — followed by reason lines.

**Liveness is not `%CPU` and not a first-match `ps` grep.** It comes from
`scripts/lib/pid-identity.sh`, the fleet's one process-identity rule, whose `unknown` verdict is an
abstention and never a death witness; a live pid whose incarnation does not match is not "running".
"Still running" and "no verdict" therefore cannot be confused: `running` (10) requires positive
evidence that *this* run is alive, and `gone-without-verdict` (22) requires positive evidence that it
is not — anything else is `unknown` (25).

## What is NOT fixed here (the honest half)

**The 1800 s tool cap is the harness's, not this repo's.** Changing it belongs in `pi` (a
per-dispatch tool timeout), and this script does not depend on that happening: the poll is the
interface, so a lane works identically with or without a longer cap. Until the cap moves, **do not
run the rail in a blocking tool call** — use `start` + `status`.

Two stated residuals:

- **`session=shared`.** Isolation is used when `setsid` (or `python3`) is available; when neither is,
  the rail shares the caller's process group and a process-*group* kill aimed at the caller reaches
  it. `start` measures this after the spawn and says which one happened — it never claims isolation
  it did not get. The tool-cap collision is still removed in that case, because the caller's call has
  already returned.
- **A SIGKILL of the recorder** (SIGKILL, OOM, reboot) writes no exit status by construction, and the
  rail can outlive it. The poll then reports `gone-without-verdict`; if that rail (or anyone else)
  merges the PR afterwards, the state becomes `landed verdict=artifact`, which says the merge is real
  and that *this run* certified nothing. It is never reported as a rail verdict it did not produce.

## Tests

```bash
bash scripts/rail-run.test.sh      # no network, no real gh, no real rail
```

The suite is mostly negative — `running` must never read as landed or refused, `rc=0` is not a
landing when the artifact disagrees, `gone-without-verdict` is never a landing, an unreadable
liveness or PR read abstains, and a live pid with the wrong incarnation is not "running". Every arm
names the guard it discriminates; removing that guard fails the arm (mutation-checked while writing
it).
