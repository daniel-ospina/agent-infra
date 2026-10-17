---
title: "Plan: agent-infra#1761 — ONE orchestrator entry point, redundancy-safe per (machine, repo)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-17
aboutSubjects: organisation-design-team
aboutObjects: agent-infra-1761, orchestrator-bringup, orchestrator-registry, cloud-cell-supervisor, per-repo-redundancy-guard
---

# Plan — agent-infra#1761 → `scripts/orchestrator-bringup.sh`

> Refs: agent-infra#1761 (the issue), PR #1856 (this branch), agent-infra#1901 (the
> queue-target-is-the-checkout gate reused here), agent-infra#1745 (harness provenance),
> agent-infra#1713/#1736 (the supervisor's refuse-don't-certify doctrine).

## The requirement, in the owner's words

> "have some sort of bundle script that launches all the needed scripts together, that has some sort
> of check so there are no accidental redundancies (note that we might want multiple orchestrators in
> the future so that one shouldn't be guarded for redundancies ... at some point I might want in the
> same machine an orchestrator for repo A and an orchestrator for repo B, so that needs to be
> possible). And the easy way to create and test and validate that script is by getting it to run in
> one of the cells and once it's running and verified and working then merge it to agent-infra main."

Three deliverables, and the third one shapes the first two:

1. **one entry point** that brings the whole stack up (`check | start | stop | status`);
2. **a redundancy guard** that is per `(machine, repo)` — refusing a second controller for the SAME
   repo while **allowing** controllers for DIFFERENT repos on one machine;
3. **validated on a live cell before merge** — a script that has never brought a cell up is a design,
   not a working thing.

## Confirmed problem

Bringing a box up was five commands in an order an operator had to remember, with two different
mechanisms (`install.sh` + `launchctl` on a Mac; `cloud-cell-supervisor.sh apply` + `start` on a cell)
and two different failure vocabularies. Three defects were measured, not theorised:

**(a) Two state dirs, one repo, both healthy.** `cloud-cell-supervisor.sh` keys controller ownership
on `$O`. Necessary and not sufficient: `$O=/a/orchestrator` and `$O=/b/orchestrator` running the same
repo each read perfectly healthy, both drain one queue, both arm auto-merge, and neither can see the
other — the read is scoped to different directories *by design*. The supervisor's own `stop` refuses
to kill a controller outside its scope, so nothing on either surface can name the duplicate.

**(b) A repo path from another machine aborts refresh forever, silently.** On a cell:

```
cd: /Users/danielospina/Documents/GitHub/tortoise: No such file or directory
[refresh] ABORT: repo not found at /Users/danielospina/Documents/GitHub/tortoise
```

The harness ships a machine-specific default for `REPO`; nothing on the cell contradicted it. The
controller kept a fresh heartbeat and one loop the whole time — it LOOKED alive and dispatched
nothing, so every observable except the work itself was green.

**(c) A controller that is alive is not a controller that is dispatching.** `candidates.txt` at zero
lines with a fresh heartbeat is the state (b) produces, and no layer reported it.

## What was built

**`scripts/orchestrator-bringup.sh`** — the one entry point. Exit codes are the contract:
`0` ok · `1` refused (one actionable line on stderr) · `2` cannot determine (fail closed — never a
green pass). It **does not re-implement the platform verbs**: `install.sh` renders and validates the
plist, `cloud-cell-supervisor.sh` pins/seeds/starts, and the entry point calls them. One authority per
question is what stops `check` and `start` disagreeing (the failure #1745 measured).

**`scripts/lib/orchestrator-registry.sh`** — the machine-local registry at
`${XDG_STATE_HOME:-$HOME/.local/state}/orchestrator/<owner>-<repo>` recording `{repo, O, pid,
started, state}`. The identity is the **pair**, never the box and never the state dir:

| state | verdict |
|---|---|
| same repo, live controller in a DIFFERENT `$O` | **refused**, naming the live pid and that `$O` |
| a DIFFERENT repo | untouched — must not block (the owner's second half) |
| dead pid | **reclaimed**, and the reclaim is said out loud |
| live pid whose invocation is not an `orch-loop.sh` | reported as **foreign** — never signalled, never reclaimed |
| `state=starting` (written with the STARTING process's pid, before launch) | blocks a concurrent `start` in the window where a duplicate is born |

**`--reseed`** repairs (b): it rewrites the machine-local lines from a clone that is actually on this
disk, preserves every other line (the secrets) byte for byte, backs the old file up `0600`, and
touches nothing that holds state — the lock, `$O/state`, the candidate files, the repo's claim refs.

**`status`** publishes the read that "is it running" cannot answer: the candidate file's line count
and mtime, and a warning when it is empty.

## Decisions

- **The registry is keyed on `owner/repo` derived from the checkout's `origin`,** the same one fact
  `cloud-cell-supervisor.sh` derives its queue target from (#1901), so the two surfaces cannot
  disagree about what "this repo" means. An explicit `OR` is an override that must MATCH the remote.
- **A refusal is one line.** An operator who has to read a wall of text to learn what to fix will fix
  the wrong thing; every refusal names the fact and the remedy.
- **Drift does not refuse on the Mac** (it does on an identity it cannot read). `start` DEPLOYS the
  harness into `$O` before launching — the plist runs `$O/orch-loop.sh` and `install.sh` only WARNS
  when `$O` differs — so drift is the state `start` repairs. Same rule the supervisor applies to
  `behind`.
- **`check` starts nothing and writes nothing.** Asserted by the suite (install.sh and launchctl
  stubs are never invoked).
- **No new machinery for the two cell failure modes** that are not repo-state: gh's response cache
  and transient DNS are reported as findings, not patched with a retry (see the PR body).

## Wiring

| Behaviour | Where | Test |
|---|---|---|
| one entry point, 4 verbs, 3 exit codes | `scripts/orchestrator-bringup.sh` | `§5` (verb contract, check launches nothing) |
| same-repo duplicate refused, naming the pid | `lib/orchestrator-registry.sh` `registry_verdict` + `check_registry` | `§1` (and `§7` on the cell path) |
| different repo allowed on one machine | `check_registry` | `§1` second direction |
| stale record reclaimed + reported | `registry_claim_or_refuse` | `§2`, `§7` |
| a **reused** pid is reclaimed, not a permanent refusal | `proc_start_epoch` + `registry_verdict` | `§3b` |
| foreign pid refused with the record to remove, never signalled | `registry_pid_is_controller` | `§3` |
| repo path from another machine refused, naming it | `cmd_check` arm 1 | `§4` |
| `--reseed` preserves secrets + state | `cmd_reseed` | `§4b` |
| dispatch read published | `cmd_status` | `§6` |
| the controller is found where it actually runs (harness path, not `$O`) | `local_controller_pids` | `§6b` |
| the config file's `O=` is honoured; an explicit env `O` still wins | `O_ENV` provenance | `§6c` |
| a failing delegated verb refuses in one line (never dies on `set -u`) | `start_cell` / `start_mac` | `§7b` |
| a stale lock naming a **peer** controller is never signalled; a dead-pid lock is released | `lock_controller_pid` + `cmd_stop` | supervisor suite `§(m)` |

Registered in `scripts/run-bash-shards.sh`, so **both** CI lanes run the suite by construction.

## Review findings (fresh-context reviewer over the whole change)

Seven, all verified against the source before applying; every one is pinned by an arm that reddens on
the pre-fix code (`BRINGUP=`/`SUP=` pointed at `HEAD` in a scratch worktree: 10 and 5 red
respectively).

| # | Finding | Disposition |
|---|---|---|
| P0 | `lock_controller_pid` matched `*orch-loop.sh*` as a SUBSTRING, so a stale `$O/.orch.lock` naming a pid the OS recycled to a **peer lane's controller** made `stop` TERM/KILL another repo's controller — reproduced, peer killed | **fixed**: argv must be `<shell> …/orch-loop.sh` AND the process must not have begun after the lock was written (`proc_start_epoch`); the supervisor suite's `§(m)` reddens on the pre-fix code |
| P1 | the `apply`-failure refusal expanded `$HARNESS_REF`/`$HARNESS_REPO`, which this script never assigns — under `set -u` the shell died before the refusal printed, so a live controller's refusal reached the operator as `unbound variable` | **fixed** (`${VAR:-…}`), `§7b` |
| P1 | a record whose pid was **recycled** was a permanent false refusal (nothing revalidated it — the #8175 class) | **fixed** (wall-clock re-check), `§3b` |
| P1 | `§3`'s "the foreign process was NOT signalled" ran only `check`, which has no signalling path — an assertion that cannot fail | **fixed**: the real property moved to the supervisor's `§(m)`, which drives `stop` |
| P2 | `registry_slug` joined `owner-repo` with `-`, which BOTH parts may contain: `premise-labs/agent-infra` and `premise/labs-agent-infra` shared one record | **fixed** → `owner~repo` |
| P2 | the config file's `O=` was captured AFTER the platform default, so the arm was dead — `check` read a state dir the controller never uses | **fixed** (`O_ENV` before defaulting), `§6c` |
| P2 | no arm drove a FAILING `start`, which is why the P1 above was green | **fixed** (`§7b`, cell + mac) |

## Validation (live cell)

Run on `pi-cell-2` (`vm-d4f21dc5359a4f219a61b69b5dc9012e`) against the branch pinned as the cell's
harness — `check` → `start` → one controller → the loop spawns its own lanes → a second `start`
refused naming the live pid → a DIFFERENT repo's controller untouched and allowed. The verbatim
transcript is in the PR body.

## Not done, deliberately

- The machine-specific `REPO` defaults in `install.sh` / `orch-loop.sh` / `refresh-candidates.sh` are
  still there. Removing them changes the documented one-command Mac flow, and the refusal +
  `--reseed` already close the failure; filed rather than changed unilaterally.
- The gh response cache (`~/.cache/gh`) that replays a stale rate-limit response for 24 hours, and
  the cell's 1s/2-attempt resolver — both diagnosed and reported, neither patched here: a retry loop
  is what made the cache look like an outage, and adding one would have made it worse.
