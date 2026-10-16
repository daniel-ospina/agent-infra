---
title: "Orchestrator harness — autonomous lane dispatch and merge rail (`~/orchestrator`)"
type: operations
domain: platform
created: 2026-10-12
ownedBy: organisation-design-team
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: daniel-ospina/tortoise, tortoise#8246, daniel-ospina/agent-infra, agent-infra#1700, agent-infra#1712
doc_status: draft
---

# Orchestrator harness

> **What this is.** A self-contained, single-host harness that turns one laptop into an
> autonomous delivery lane: it sweeps the open PR queue, dispatches GitHub issues into
> isolated worktrees as autonomous `pi` lanes, runs a fresh-context review → signed-record
> → merge chain on each result, and repairs the PRs whose reviewer found real problems.
>
> **Where it came from.** Built ad hoc in `~/orchestrator/` on one box during the
> 2026-10-10 → 2026-10-11 run that merged ~99 PRs (77 of them between
> `2026-10-10T23:45Z` and `2026-10-11T21:22Z`). It was never version-controlled. It was first
> versioned in tortoise as `operations/orchestrator-harness/` (PRs #8251, #8308, #8329, #8298;
> tracked by tortoise#8246) as the handover so it could be **evaluated** before being adopted.
>
> **Where it lives now.** `agent-infra/scripts/orchestrator-harness/` (relocation:
> agent-infra#1700). The home is agent-infra because this is fleet/agent operations, not
> tortoise product code — the merge rail it sits alongside (`admin-merge.sh`, `atomic-land.sh`)
> and the fleet's box-level script `cadence-nudge.sh` are already in `agent-infra/scripts/`, as
> are the multi-file tool subdirectories `checkout-hygiene/`, `ci/` and `gh-shim/`. Three scripts
> this same change versions into that directory existed only in local config before:
> `ci_runner_gate.sh` (the CI runner-label fallback gate), `cloud-cell-bringup.sh` (cell bring-up)
> and `cloud-cell-supervisor.sh` (the per-cell launcher — on a cell it is what starts this
> controller, since launchd is macOS-only).
> The old tortoise path
> (`operations/orchestrator-harness/`) is replaced by a stub pointer to this home in a follow-up
> tortoise PR that opens only after this one merges — tracked by tortoise#8432 (the relocation
> issue); until that PR lands the old path is a stale duplicate, so do not run it.
>
> ⛔ **Every post-copy change through tortoise `ef59f6d6f` has been PORTED here (agent-infra#1712),
> and that port is the precondition for removing the tortoise copy.** This directory is a
> point-in-time copy taken at 2026-10-13 05:50 local (= 10:50Z) from tortoise `0e060082f`. **Eight**
> tortoise commits touching this directory merged between `0e060082f` and `ef59f6d6f`
> (2026-10-13T15:48:33 local) — the declared port point — and all eight are present here:
>
> | commit | tortoise | what it carries |
> |---|---|---|
> | `8fe1e7b13` | #8437 | core-derived load ceiling, `MIN_MEM_FREE_MB`, the dead `REPO` default corrected — `orch-loop.sh`, `install.sh`, `refresh-candidates.sh`, `launchd.plist.template`, `README.md`, `selftest.sh` |
> | `a59858d07` | #8465/#8467 | dispatch pool ordered by **severity**, not issue number — `refresh-candidates.sh` + `selftest.sh` |
> | `ff6d1bc19` | #8471 | the follow-up that makes #8465's self-tests discriminate — `refresh-candidates.sh` + `selftest.sh` |
> | `77a0c32bd` | #8515 | `checked.txt` written only on the terminal CLEAN verdict (agent-infra#1716) — `refresh-candidates.sh`, `selftest.sh`, `README.md` |
> | `b559cb02a` | #8516 | INT/TERM `exit` rather than returning from the trap, so the lock and the process end together (agent-infra#1715) — `orch-loop.sh` + `merge-one.sh` + `selftest.sh` |
> | `45dd16cc8` | #8519 | a FAILED PR listing is not an EMPTY one; the reaper fails closed (agent-infra#1705) — `refresh-candidates.sh`, `selftest.sh`, `README.md` |
> | `26f6c9488` | #8514 | portable load/swap/mtime/memory probes and `nproc` core count, so the Linux cell controller runs (agent-infra#1702) — `orch-loop.sh`, `install.sh`, `selftest.sh`, `README.md` |
> | `ef59f6d6f` | #8518 | required checks classified by **allow-list polarity**, not a deny-list, so an unrecognised or null conclusion is red rather than reading `PENDING` (agent-infra#1714) — `orch-loop.sh`, `fix-one.sh`, `selftest.sh`, `README.md` |
>
> ⚠️ **A COUNT is the wrong anchor; the SHA is.** Three different counts were each correct at a
> different moment while this port was being written: `26f6c9488` and `ef59f6d6f` both landed
> *between* a fetch of `origin/main` and the commit built on that fetch, so even a freshly-read ref
> was stale by the time it was used. The instruction for any future copy is therefore: **re-fetch,
> diff the tortoise tree against this one at that moment, port everything not present, and record
> the SHA you ported to here.** The removal PR must re-run that diff against the then-current
> tortoise tip: a port is only complete *relative to a declared sha*, and removing the tortoise copy
> while any delta remains deletes the only tree carrying that fix.
> The last of them merged at 15:16 local **while this port was being written**, which is the point:
> a hand-kept list only catches what its author already knew. Two guards exist instead of a list.
>
> 1. **`port-provenance.txt`** pins the tortoise blob hash of every file at the port's sync point,
>    and **`check-port-drift.sh`** fails if the tortoise tree no longer matches it, naming the file.
>    Run it before the follow-up tortoise PR removes anything:
>    `./check-port-drift.sh --tortoise /path/to/tortoise`.
> 2. **The ported `selftest.sh` checks are the anti-regression guard** — each of the seven commits
>    added checks that are RED on the pre-fix tree (16 for #1702 alone), so a reverted port fails the
>    suite rather than merely looking different.
>
> ⚠️ **The follow-up has a second obligation the sha list never covered.** tortoise's **open**
> branch `fix/8468-closure-linkage` also rewrites this directory (severity-ordered pool, a
> `.prio`-keyed P0 bypass of the merge-priority gate, `merged-not-closed.sh`, a `Closes`-not-`Refs`
> lane brief). It is **not** on `main`, so it is deliberately not ported here — it is still under
> review, and porting it would create a second home for work that has not landed. The live box is
> already running an earlier revision of it. Either that branch merges first, or the removal PR
> must port it; removing the directory while it is open orphans it.
>
> ⚠️ **This port is faithful EXCEPT for a declared set of fail-open / false-PASS fixes.** These are
> agent-infra's, not tortoise's — a later diff between the two trees WILL show them, and they must not
> be read as lost work in either direction:
>
> | divergence | why it is here |
> |---|---|
> | `orch-loop.sh` guards **every** limit with `is_limit` (digits **and** at most nine of them) before its first arithmetic read — `MAX_LANES`, `MAX_REVIEW`, `MERGE_PRIORITY_AT`, `MAX_FIX`, `MAX_FIX_TRIES`, `BATCH`, `CYC`, `STALE_MIN`, `SWEEP_MAX_AGE`, `SWEEP_MIN_REMAIN` (and `MAX_LOAD`/`MIN_SWAP_FREE`/`MIN_MEM_FREE_MB`, which had `is_num`: the first two are plist-supplied gates that `[` would ERR on at or above 2**63, the last is plist-supplied too, so all three moved to `is_limit`) | two failure modes, both fail-**OPEN**: `[ -ge ]` on a non-number is FALSE and FALSE in the gate chain ALLOWS, so `MAX_LANES=4x` dropped the lane cap, `MERGE_PRIORITY_AT=notanum` removed the drain-before-dispatch gate, `BATCH=abc` dispatched the whole backlog in one cycle, and `MAX_FIX_TRIES=abc` let fixer attempt 10 run past a cap of 3. `[` also ERRORS at or above 2**63, so an absurd-but-numeric limit opened them the same way. `is_num` itself stays unbounded for an **epoch mtime** (already 10 digits), but `_NCPU` is now `is_limit` too: its source is the host (`sysctl`/`nproc`), not the plist, so an absurd-but-numeric probe reached `$(( 10#$_NCPU * 10 ))` and WRAPPED — 99999999999999999999 to 3875820019684212726, 19 digits but still BELOW 2**63-1, so `[ -ge ]` does NOT ERROR: it simply never binds and the gate OPENS **silently** (the earlier wording said `[ -ge ]` ERRORS here — corrected, fifth review round 2026-10-14) — and 2**63 to exactly 0, which `is_limit` ACCEPTS because install.sh allows 0 for every limit but CYC (`[ "$L" -ge 0 ]` is always true, so the gate CLOSES and the box dispatches nothing). `install.sh` now mirrors the loop's guard (`is_limit` + the `_NCPU >= 1` probe guard + the two MAX_LOAD guards) because install.sh is what substitutes `__MAX_LOAD__` into the live plist — the wrap survived there on the real production path |
> | `orch-loop.sh` reads base 10 where it read base 8 | `$((MAX_REVIEW + 2))` read `030` as **octal** (26, not 30) and `$((STALE_MIN * 60))` did the same. `MERGE_PRIORITY_AT` already normalised with `10#` |
> | `install.sh` refuses a non-integer, an out-of-range value, or a value carrying a `__TOKEN__` | `MAX_LANES=4x` was written into the live launchd plist and `install.sh` exited 0, so the plist lied about the ceiling; and the sed rules run in order, so `OR=__MAX_LANES__` rendered as `4` — exit 0, valid XML, and the daemon then ran `gh --repo 4` |
> | `install.sh` renders to a temp file and `mv`s it into place, and asserts no `__…__` survived | the redirect truncates `$PLIST` **before** `sed` runs, so rejecting after writing straight to it left the live plist empty or poisoned — and §9's next step (`launchctl unload && load`) then failed, so a rejected re-install destroyed a working daemon config. `plutil -lint` cannot see a substitution that did not take |
> | `install.sh` creates the plist's directory (`mkdir -p "$(dirname "$PLIST")"`) | an agent-infra addition, not a lost tortoise line: a sandboxed or first-time `HOME` has no `Library/LaunchAgents` and the redirect then died |
> | `selftest.sh` pins the documented default of every host-independent limit, drives the swap gate with real swap (`SWTOTAL` != 0) **and** a non-default ceiling, drives `install.sh` instead of grepping it, and extracts the coercion lines to RUN them | the default-agreement check could not see both files drifting **together**; `SWTOTAL=0` short-circuits the swap gate before the comparison; a source-text pin survives the guard being disabled (`if false && grep …`); and a fixture that re-implements the pattern in the test asserts nothing about the shipped code |
> | `orch-loop.sh` moves the sweep's PR **listing** to a conditional REST call (`gh api --paginate -i` + `If-None-Match`, ETag in `state/sweep-etag`, age floor `SWEEP_MAX_AGE`) and takes its rate-limit signal from the **response headers** (`x-ratelimit-remaining`/`-reset`/`Retry-After`) rather than `/rate_limit`; the `# BEGIN sweep-quota` helper block (`sweep_fail_kind`/`sweep_defer_until`) and the new `sweep-quota.test.sh` are agent-infra-only (and the ported `selftest.sh` gains the section that runs it, with its coercion-count pin) | a `304` is not charged to the primary rate limit, so the listing is free, and the `/rate_limit` counter was measured reporting `graphql 4933/5000` while **every** GraphQL call failed — a cell that cannot list PRs cannot merge and read as idle-but-fine (agent-infra#1762). tortoise still carries the polling sweep, so a faithful port must not delete this block as "unported work": port it or keep it |
>
> The upstream-logic defects found in the same review are **not** diverged here; they are tracked
> instead — `fix-one.sh`'s spaced-check-name word-splitting (agent-infra#1703), `can_spawn()`'s
> load-only gate (agent-infra#1732) and the classifier's inert `(app, name)` grouping
> (agent-infra#1733) are all still present, matching tortoise.
>
> **Status: evaluation artifact.** Nothing here installs or runs on its own. `install.sh`
> renders a launchd plist and *prints* the load command; it does not execute it.
> Tracked by tortoise#8246.

---

## 1. Why it exists

The repo's normal path is one agent, one issue, one PR, human-paced. On a box that is left
running overnight that path is idle most of the time. This harness keeps the box saturated
without a human in the loop:

- **Fan-out:** N simultaneous implementation lanes, each in its own git worktree.
- **Fan-in:** a per-PR chain that reviews, records the review as a gate artifact, and merges.
- **Back-pressure:** every cycle is gated on load average and swap, so the box throttles
  itself instead of thrashing. Above `MERGE_PRIORITY_AT` open PRs (10) the balance shifts to
  **draining**: new lanes stop being dispatched and reviewer headroom rises, because a merge
  backlog means the scarce capacity belongs to review and merge, not to opening more PRs.
- **Self-healing:** a PR whose reviewer reports real findings is routed to a *fixer*, fixed,
  and re-reviewed — rather than being left red forever (this is the bug that stranded ~15
  PRs before it was fixed; see §7).

It deliberately does **not** use the `task` sub-agent tool. Workers are separate `pi -p`
processes in tmux sessions, so a killed worker cannot take the controller down with it.

---

## 2. Architecture

```text
                      launchd  com.eldato.orchestrator-loop  (RunAtLoad + KeepAlive)
                                        │
                                  orch-loop.sh        ← the controller, one process
                                        │
        ┌───────────────────────────────┼────────────────────────────────┐
        │                               │                                │
   (1) merge sweep              (2) capacity-gated dispatch      (3) backlog refresh
        │                               │                                │
        │  for every open non-draft PR  │  read candidates.txt            │  refresh-candidates.sh
        │  read repo's required checks  │  skip if in dispatched.txt      │  pre-flight each issue
        │                               │  dispatch-merge.sh:             │  (collision_preflight.py)
        │   GREEN   → merge authority   │    git worktree add             │  append CLEAN ones
        │   PENDING → auto (gate mode)  │    tmux new lane-<N>  ──┐       │
        │   FAILED  → see below         │    tmux new chain-<N> ──┤       │
        └───────────────────────────────┴─────────────────────────┼───────┘
                                                                  │
                        ┌─────────────────────────────────────────┘
                        ▼
        lane-<N>   → lane.sh   : pi -p in .worktrees/tm-<N>, implement → commit → push → open PR
                        │
        chain-<N>  → chain-merge.sh : poll for the PR to appear, then
                        ▼
        merge-<PR> → merge-one.sh :
                        the repo's merge authority decides the whole step (agent-infra#1764)
                        gate mode (the repo REQUIRES `ai-review-gate`):
                        1. fresh-context reviewer → posts its review as a PR comment (the audit artifact)
                        2. CLEAN   → record-review.sh (HMAC-signed marker into the PR body)
                                     → wait for ai-review-gate SUCCESS → gh pr merge --squash
                            ISSUES  → touch state/needsfix-<PR>-<head>   ← hands off to the fixer path
                        rail mode (the repo does NOT require the gate — e.g. agent-infra):
                        1. `scripts/admin-merge.sh <PR>` — the repo's own rail, which posts its own
                           head-bound evidence and merges. No reviewer is run and `gh pr merge` is
                           NEVER called: it would land on the required checks alone, bypassing the rail.
                           Refused 3x at one head → PARK that head.
                        ▼
        fix-<PR>   → fix-one.sh  : materialises a worktree for the branch (including foreign
                                   branches), runs a fixer over the reviewer's findings, pushes a
                                   new commit, then re-runs merge-one.sh end-to-end
```

### Worker types

| Session | Script | Writes to | Purpose |
|---|---|---|---|
| `lane-<N>` | `lane.sh` | `.worktrees/tm-<N>` on `feat/<N>-tm` | implement issue #N → commit → push → open PR |
| `chain-<N>` | `chain-merge.sh` | — | wait for the lane's PR, then delegate to `merge-one.sh` |
| `merge-<PR>` | `merge-one.sh` | — | **repo-authority-dependent**: gate mode = fresh review → signed record → wait green → squash-merge; rail mode = the repo's own `scripts/admin-merge.sh` |
| `fix-<PR>` | `fix-one.sh` | the PR's worktree | repair findings **or a failing required check**, push, re-run the merge chain |

### State files (`$O/`)

| File | Meaning |
|---|---|
| `heartbeat` | epoch seconds, rewritten every cycle — the liveness probe |
| `.orch.lock` | atomic single-instance lock (noclobber create); stale locks are reclaimed |
| `candidates.txt` | the dispatch backlog: issue numbers that passed collision pre-flight |
| `dispatched.txt` | issues already handed to a lane — **pruned** when the issue is still open, no PR branch matches it and no `lane-<N>` is live (see §7.1) |
| `checked.txt` | issues whose pre-flight returned **CLEAN** (the terminal verdict); an **errored** pre-flight and a **COLLISION** leave no entry, so the next pass re-attempts them (agent-infra#1716). A reaped number is dropped from it too, so the pre-flight re-queues the issue |
| `state/mergeclaim-<PR>.lock` | single-owner claim: only one worker may review/record/merge a given PR |
| `state/needsfix-<PR>-<head>` | "a reviewer found real issues at this exact head" |
| `state/fixcount-<PR>` | fixer attempts for that PR, capped by `MAX_FIX_TRIES` |
| `state/parked-<PR>` | terminal state: the fixer cap was reached at the head recorded inside the file, so the sweep skips it until a new push re-arms it |
| `state/rerun-<PR>-<runid>` | CI re-run already requested for this run — prevents loops |
| `state/merged-<PR>.done` | merge confirmation |
| `state/last-open-n` | the last SUCCESSFUL open-PR count; reused only when positive if a later count fails — a failure never reads as 0 |
| `logs/` | one log per worker: `lane-*.log`, `chain-*.log`, `merge-*.log`, `fix-*.log`, `orch-loop.log` |
| `wip/` | dirty-worktree captures taken before a shutdown (see §6) |

### Why the *reviewer* is a separate process from the *controller*

`merge-one.sh` spawns a fresh-context `pi -p` reviewer that has never seen the implementing
lane's reasoning. It reads the changed files at the PR head (`git show origin/<branch>:<path>`)
rather than only diff hunks, and posts its verdict as a PR comment. That comment is the
evidence the `record-review.sh` signature points at, so the merge gate is auditable after
the fact: the PR body names the comment it was signed against.

### Non-blocking dispatch — the orchestrator keeps its own time

`nonblocking-dispatch.sh` launches a headless worker and **returns immediately**. It exists because
the built-in `task`/`subagent` tools always block the caller (agent-infra#1662): an orchestrator that
dispatches N workers pays `max(worker)` wall-clock and cannot react to anything until the slowest
settles.

It is deliberately thin. It carries **no agent invocation of its own** — it backgrounds
`run_agent()` from `spawn-gate.sh`, so a background worker is load-gated exactly like `lane.sh` and
`fix-one.sh`, gets the same wall-clock watchdog, and appends the same `state/walltime.tsv` row with
`KIND=bg`. Routing it through the helper is also what keeps `spawn-gate.test.sh`'s invoker census an
equality: a direct spawn here would be a fourth, ungated launch path.

```bash
bash nonblocking-dispatch.sh <name> <worktree-dir> <prompt-file> [timeout-seconds]
bash nonblocking-dispatch.sh --status <name>     # running | done rc=0 | failed rc=N | lost
```

Status comes from the worker's own exit-status file plus a pid probe — **never `%CPU`**, which reads
0 for a worker that is merely WAITING (`docs/ops/fleet-liveness.md`). "launched" is the only success
this script reports: it cannot tell you the work succeeded.

⛔ **Nothing here reviews anything.** The worker runs with `AGENT_SKIP_REVIEW_GATE=1` (a child has no
`task` tool and cannot satisfy the gates itself), so **the PARENT owns the review gate** — hand the
PR to `chain-merge.sh`, which polls for it and runs `merge-one.sh`. A background worker whose PR is
never handed to the chain is unreviewed code by default.

⚠️ `install.sh` copies every `*.sh` into `$O`, but its drift comparison lists the loop scripts
explicitly, so this one is copied and *not* compared against the running copy. Run it from the
harness directory, or re-copy it after editing.

⚠️ This is a stopgap for an open gap, not the fix. **agent-infra#1666** lands non-blocking dispatch
as a first-class primitive (`task({ background: true })` plus `task_status`/`task_collect`). Once that
merges it supersedes this script for `task`-based orchestrators; the harness keeps this one for its
own `pi` workers, which do not go through `task`.

---

## 3. Prerequisites

| Dependency | Why | Notes |
|---|---|---|
| `tmux` | every worker is a detached tmux session | `brew install tmux` |
| `gh` (authenticated) | all queue + PR operations | needs push access to the target repo |
| `pi` on `PATH` | the worker runtime (`pi -p --provider deepseek --model deepseek-v4-flash`) | provider/model are literals in `lane.sh`/`merge-one.sh`/`fix-one.sh` — change them there |
| `uv` | `lane.sh` runs `uv sync --extra embeddings --extra parity` in each worktree | tortoise-specific; `refresh-candidates.sh`'s SCOUT venv is repo-aware since agent-infra#1736 (skipped when there is no `pyproject.toml`; the extras are read from that project) |
| `~/.pi/agent/scripts/record-review.sh` | writes the HMAC-signed review marker the `ai-review-gate` check verifies | shipped by `agent-infra`; **gate mode only** — a repo that does not require the gate consumes no such marker, so `merge-one.sh` does not mint one there |
| **`AI_REVIEW_GATE_KEY`** | the merge authority — env var, or `~/.pi/agent/.ai-review-gate-key` | **this harness cannot merge a gate-mode repo without it.** Treat as a secret; never commit it |
| the target repo's branch protection | the REQUIRED-check list and the merge authority are read from it at runtime (agent-infra#1764) | `gh api repos/$OR/branches/main/protection/required_status_checks`. `REQ=…` in the cell env / `keys.env` overrides the read. Unreadable → `FALLBACK_REQ` (non-empty, fail-closed). Requires admin read on the repo, else the fallback applies every cycle and nothing merges |
| `REVIEW_GATE` (optional) | names the check that IS the merge authority — the repo's gate | defaults to `ai-review-gate`; set it only for a repo whose gate has another name. It is read from the environment, so an ambient/`keys.env` value takes effect: **an override that changes the merge authority away from what the repo's own declaration gives is logged** as `⚠️ … CHANGES the merge authority`, naming the consequence. On a rail repo a flip to `gate` authority means a RAW merge (no head-bound evidence), so treat that line as an error, not noise |
| a collision pre-flight tool | `refresh-candidates.sh` refuses overlapping dispatches | resolved **per repo** (agent-infra#1736): the target repo's own `tools/collision_preflight.py`, else a tortoise checkout (`TORTOISE_REPO`, or its legacy `TORTOISE` alias). The tool requires **Python >= 3.12** and refuses an older interpreter with exit 3 and no verdict, so the selected interpreter (scout venv, or a bare `python3` when there is no `pyproject.toml`) is version-gated: `--check` and the refresh both refuse a too-old one (permanent `rc=3`) instead of queueing nothing in silence. `SCOUT_PY` pins the interpreter, like `SCOUT_UV` pins `uv`. Put `TORTOISE_REPO` in `keys.env` — the controller session re-sources it, while an ambient-only export does not reach a pre-existing tmux server |
| `.worktrees/` gitignored in the target repo | worktrees are created under it | `git check-ignore .worktrees` |

**Single-host assumption.** Everything is local: tmux sessions, worktrees, logs, the key.
There is no scheduler, no queue service, no shared database. Two boxes running this against
the same repo work fine *because* GitHub is the coordination medium — but they will duplicate
work unless they coordinate (see §5, "broad mode").

---

## 4. Install

```bash
# 1. Run all four steps from the ROOT of an agent-infra checkout — the harness now lives there.
#    Put it where $O will point (default ~/orchestrator): the daemon executes $O/<script>,
#    not the shipped copies.
mkdir -p ~/orchestrator && cp scripts/orchestrator-harness/*.sh ~/orchestrator/
mkdir -p ~/orchestrator/logs ~/orchestrator/state ~/orchestrator/wip

# 2. Point it at your box (all overridable; defaults are the original box's values)
export OR=daniel-ospina/tortoise         # owner/repo
export REPO=$HOME/eldato/tortoise        # the local main checkout
export O=$HOME/orchestrator              # the harness state directory
export SCOPE=own                         # drain scope: auto (default) | own | broad.
                                         # A fleet runs ONE broad box; the rest pin own (section 5).
                                         # install.sh renders this into the plist (launchd
                                         # inherits no shell env) and refuses a bad value.

# 3. Render + install the launchd agent (does NOT load it). Invoke it BY PATH, from that same
#    repo root: install.sh resolves `launchd.plist.template` from ITS OWN directory, so
#    `cd ~/orchestrator && ./install.sh` dies with "missing template" — step 1 copies only *.sh.
bash scripts/orchestrator-harness/install.sh

# 4. Start it when you mean to
launchctl load -w ~/Library/LaunchAgents/com.eldato.orchestrator-loop.plist

# liveness / stop
cat ~/orchestrator/heartbeat                 # epoch seconds, should be < ~5 min old
tmux ls                                      # lane-*, chain-*, merge-*, fix-*
launchctl unload -w ~/Library/LaunchAgents/com.eldato.orchestrator-loop.plist
```

`install.sh --uninstall` unloads the agent and removes the plist.

Run the offline self-test first — it needs no network, tmux server or git writes. **Every check
exercises the shipped script** (it extracts the real classifier, `sess()`, the claim block and the
reaper, or runs `install.sh` for real) rather than re-implementing the logic — a test that
re-implements the fix passes on the broken copy and proves nothing. `need()` fails a check whose
extraction comes back empty, so a check cannot pass by driving nothing; the live total is printed
by `./selftest.sh` rather than quoted here.

```bash
./selftest.sh          # run it for the live list. Covers: syntax, exact session matching, the
                       # fail-closed gate classifier, claim atomicity and stale-claim recovery,
                       # the reaper's keep/reap decisions, rejection of a hostile branch name,
                       # install.sh rendering with a hostile path, limit-default consistency,
                       # placeholder parity, the daemon PATH (shim exclusion + execute-probe) and
                       # the failed-count fallback, README overclaim guards, credential scan,
                       # repo-aware scout provisioning and the permanent/transient refresh split
                       # (refresh-scout.test.sh, #1736)
```

**The gate key only reaches the daemon if it is a FILE.** `install.sh` deliberately does not copy a
secret into a world-readable plist, and launchd inherits no shell environment — so an env-only
`AI_REVIEW_GATE_KEY` is reported as insufficient, not as "present". The box cannot merge without it.

### Tuning (10-core / 32 GB box — the values that were actually used)

| Var | Value | Why |
|---|---|---|
| `MAX_LOAD` | `cores*10` (100 on a 10-core box; sanity ceiling) | dispatch stops above this 1-min load |
| `MAX_LANES` | `4` | concurrent implementation lanes |
| `MAX_REVIEW` | `4` | concurrent `merge-<PR>` reviewers |
| `MERGE_PRIORITY_AT` | `10` | above this many open PRs, **merging takes priority**: dispatch of new lanes stops (unless none are running) and reviewer headroom rises to `MAX_REVIEW+2` |
| `MAX_FIX` | `3` | concurrent `fix-<PR>` fixers |
| `MAX_FIX_TRIES` | `3` | per-PR fixer attempts before it is left alone |
| `MIN_SWAP_FREE` | `600` | MB; with `MAX_LOAD` raised this and `MIN_MEM_FREE_MB` are the binding gates in practice |
| `MIN_MEM_FREE_MB` | `512` | MB of *available* memory (`MemAvailable` on Linux, else `MemFree`+`Cached`; `free`+`inactive` on macOS). macOS shows pressure as compression with swap flat, so swap alone does not see it |
| `BATCH` | `2` | issues dispatched per cycle |
| `CYC` | `240` | seconds between cycles |
| `STALE_MIN` | `40` | a worker whose log has not grown in this many minutes is presumed hung and its session is killed (§6) |
| `LANE_TIMEOUT` | `2400` | wall-clock limit on a lane's `pi` run (s) |
| `REVIEW_TIMEOUT` | `1800` | wall-clock limit on a reviewer `pi` run (s) |
| `FIX_TIMEOUT` | `2400` | wall-clock limit on a fixer `pi` run (s) |
| `SWEEP_MAX_AGE` | `600` | (s) the longest a `304 Not Modified` may reuse the cached PR listing before the sweep forces a full one. A completed check run does **not** reliably change the listing's ETag, so this floor is what stops a green PR sitting behind a cached "unchanged" forever (#1762) |
| `SWEEP_MIN_REMAIN` | `20` | when `x-ratelimit-remaining` is at or below this, the **next** sweep is deferred to the reset rather than hammering the shared bucket (#1762) |

⛔ **`STALE_MIN`, `SWEEP_MAX_AGE`, `SWEEP_MIN_REMAIN` and the three wall-clock timeouts are NOT rendered into the plist.** The template
carries 16 placeholders — the ten limits above them, `SCOPE`, `O`, `REPO`, `OR`, `PATH` and `HOME`
— and no `__STALE_MIN__`/`__SWEEP_MAX_AGE__`/`__SWEEP_MIN_REMAIN__`/`__LANE_TIMEOUT__`/`__REVIEW_TIMEOUT__`/`__FIX_TIMEOUT__`. So exporting one
of these and re-running `install.sh` silently has no effect, and a hand-added plist key is
overwritten by the next render. Set them through `$ENV_FILE` on a cell, or edit the defaults in the
scripts.

⛔ **And every limit that IS rendered must be a whole number, in range, and not a template token.**
The ten are substituted verbatim — deliberately not routed through the escaping path, since a whole
number has nothing to escape — so `install.sh` validates each before rendering: digits only, at most
nine of them (`[` errors at or above 2**63, and an errored test reads FALSE, which OPENS the gate it
configures), `CYC` additionally at least 5 (see below), and no `__…__` pattern, because the sed rules run in order and `OR=__MAX_LANES__`
therefore rendered as `4` and still exited 0. It then renders to a **temp file**, lints that, asserts
no placeholder survived, and only then moves it into place — the redirect truncates its target before
`sed` runs, so rejecting after writing straight to `$PLIST` left the live plist empty and the next
`launchctl unload && load` failed. The loop coerces the same values on its own, so a bad plist is
refused at both ends, and every limit is coerced *before* its first arithmetic read, because `[ -ge ]`
on a non-number is FALSE and a false test in the gate chain OPENS the gate.

⚠️ **`0` is a valid integer for most limits** — for `MIN_SWAP_FREE`/`MIN_MEM_FREE_MB` it means the
gate can never bind (disabled). Set one of those only when that is what you mean.
⛔ **`CYC` is the exception: it has a 5-second floor.** It is the one limit where `0` is not merely
useless but harmful — `sleep $(( CYC - JIT + RANDOM % (2*JIT+1) ))` becomes `sleep 0` or a negative
argument, so the controller revisits every cycle with no delay and hammers the GitHub API.
`install.sh` refuses `CYC<5` at render time and `orch-loop.sh` floors a zero/bad value to its 240s
default, so the two ends cannot disagree. `CYC=5` (a deliberately fast cycle) is still accepted.

**The CONTROLLER's spawn decisions are load-gated — not just lane dispatch.** A Mac reboot lands in an indexing
storm (Spotlight, `PerfPowerServices`, `duetexpertd`) that routinely pushes 1-min load past 200. The
lane gate already respected `MAX_LOAD`; the merge sweep did not, so a fresh boot got six reviewers
piled onto the spike. `can_spawn()` now guards the five spawn sites in `orch-loop.sh` — conflict
fixer, rail merge worker (GREEN), re-record fixer, re-record merge worker, CI-red fixer — while the
cheap actions (`gh pr ready`, `gh run rerun`, and `gh pr merge` in *gate* mode) stay ungated, so
**gate-mode** merges keep flowing during a spike and nothing is
starved. ⚠️ **On a rail-mode repo the merge is itself a gated worker, so it does NOT keep flowing.**
agent-infra#1764 moved the rail into a `merge-<PR>` worker (the inline rail run measured ~27 s of
BLOCKED controller cycle, halting dispatch); that worker is slot- and load-gated like every other
spawn, so a spike holds rail merges back with the rest. That is the intended trade, not an
oversight. ⛔ **That is the controller's *decisions*, not every spawn.** Three worker entry points
spawn a `pi` agent with no `MAX_LOAD` read of their own — `chain-<N>` → `merge-one.sh` (the
first-review path for every own-lane PR), `fix-one.sh` → `merge-one.sh`, and `adopt-fix.sh` →
`fix-one.sh`; tracked as agent-infra#1720.

⚠️ **`can_spawn()` tests load only.** The available-memory gate applies to *lane dispatch*, not to
these five spawn sites — the two cover different populations. Raising `MAX_LOAD` therefore narrows
the band in which the spawn sites hold back (`16`–`99` is now permitted, where `16` used to hold).
Closing that needs `can_spawn()` to consult memory as well, which changes the one-line shape its
self-test extracts from the shipped file; tracked as agent-infra#1732 rather than half-done here.

**Swap, not lanes, is what actually throttles this box.** Observed at 15 concurrent workers:
`swap_free=588M` → dispatch correctly refused. Raising `MAX_LANES` alone buys nothing on the box
this was measured on (the original 8 GB host — the current one is 32 GB);
it just moves the pressure into the compressor. `swap_total=0` right after boot is treated as
*uninitialised*, not as pressure (that bug silently blocked all dispatch for the first minutes
after a restart until it was fixed).

**The capacity probes are portable: Linux cell + macOS host.** `#1702`. Every probe used to be a
macOS primitive, so on a Linux cell `load1()` returned empty (the `MAX_LOAD` gate could never bind),
swap read as `0` (the gate skipped by its own "uninitialised" rule), and the reaper's
`stat -f '%m'` became an arithmetic error that killed the controller one cycle after its first
dispatch — every lane/merge/fix writes the log the reaper stats. Each probe now has a Linux path
(`/proc/loadavg`, `/proc/meminfo`, `nproc`) and a macOS one (`sysctl`, `vm_stat`), and the reaper's
mtime probe is a GNU-then-BSD `stat` ladder with a numeric guard (GNU first on purpose: GNU
`stat -f` writes the filesystem listing to **stdout** before exiting 1, so a BSD-first `||` ladder is
the bug itself).

⚠️ **Available memory was the fifth macOS-only probe, and the only one that fails CLOSED.** The gate
is deliberately "UNKNOWN is not ample" (`mem_probe_failed` → do not add work), so with a `vm_stat`-only
probe every Linux cell set `MEM_UNKNOWN=1` on every cycle: load, lanes and swap could all be healthy
and the memory gate still bound — the controller completed cycles, logged `mem_probe_failed` and
dispatched nothing, which is a *different* false green from the one #1702 removes. `mem_avail_mb()`
therefore reads `/proc/meminfo` (`MemAvailable`, else `MemFree`+`Cached`) on a cell and keeps the
`vm_stat` `free`+`inactive` parse on macOS. The fail-closed ruling for a genuinely unreadable probe is
unchanged — only its Linux measurability is.

A load reading that is *unreadable* stays the documented **fail-open** (`can_spawn()` defaults it to
`0`): both supported platforms are measurable now, and failing closed on an unreadable probe would
turn "no load back-pressure" into a permanent controller outage. `install.sh` still refuses to run
off macOS (it renders a launchd plist) — the portability that matters is `orch-loop.sh`, the file
`cloud-cell-supervisor.sh` starts.

---

## 5. Merge policy and safety invariants

1. **The gate is never bypassed — but WHICH gate is the repo's own answer (agent-infra#1764).**
   The required-check list is read from the target repo's branch protection, not hardcoded. A repo
   that requires `ai-review-gate` (tortoise) must have it `<SUCCESS>` —
   `SKIPPED`/`NEUTRAL`/absent do **not** count, because that means no signed review exists — and
   `merge-one.sh` additionally refuses to merge if the recorded head ≠ the current head, so a
   post-review push invalidates the evidence automatically. A repo that does NOT require it
   (agent-infra: `pipeline-compliance`) is merged through its **own rail**
   (`scripts/admin-merge.sh`), which posts its own head-bound evidence; the harness never falls back
   to a raw `gh pr merge` there. Either way the fail-closed rule holds *inside* the repo's own
   required set: a required check that has not reported is `PENDING`, never green, and an
   unreadable protection endpoint uses `FALLBACK_REQ` (non-empty), never an empty set.
1b. **One owner per PR, per box.** Every path into `merge-one.sh` (the lane's `chain-<N>`, a
   `fix-<PR>`, and the controller's sweep) takes the same atomic `state/mergeclaim-<PR>.lock` first.
   Without it a freshly opened PR gets two concurrent reviewers racing one head: duplicate evidence
   comments, duplicate `record-review` writes, and an `ISSUES`/`CLEAN` interleaving.
   **This is a local file, so it serialises one box only** — two boxes sharing a repo are not
   coordinated by it (§7.2b, tortoise#5052).
2. **The reviewer must state a plain outcome.** Its final line is exactly `CLEAN <comment-url>`
   or `ISSUES <n>`. A CLEAN comment may not assert an unresolved outcome. The enforcer is the
   evidence veto in `scripts/record-review.sh`, and its vocabulary is `NOT CLEAN`, "requires human
   attention/input/review", "unresolved issues",
   "auto-fix stalled/failed/reached/converged/aborted/stuck", "test review capped",
   `[ADVERSARIAL-BOUND]`, and a **counted** `N issues remain`. The count is
   deliberate: a bare "issues remain" is NOT matched, because the veto must not false-refuse the
   legitimate clean phrasing "No issues remain after the fixes" — which also means a CLEAN comment
   whose body says (uncounted) that issues remain does pass the veto. Quote the gate's list, not a
   wider one.
3. **Scope adapts to the queue — and can be pinned.** `open PRs > 10` → **broad** mode: the sweep
   covers every non-draft PR in the repo except the branch classes it deliberately never touches
   (`design/`, `scope/`, `dependabot/` — the selector is
   `select(.headRefName|test("^design/|^scope/|^dependabot/")|not)`), not just this box's. `≤ 10` →
   own branches only (`*-tm`, `*-cap`, `fix/*`). Broad mode is how this box drains a peer's queue;
   it is also how two boxes accidentally duplicate work if they both run broad. `SCOPE` overrides
   the count: `auto`
   (default — the rule above), `own` (own-only even above the threshold), `broad` (broad even below
   it); any other value is fatal, so a typo cannot silently pick a scope. In a multi-box fleet
   exactly one box takes `broad` and the rest pin `SCOPE=own` (measured 2026-10-13: an unpinned
   fresh cell logged `[scope] open=14 -> BROAD` and auto-armed #8425/#8420 within ~25s).
   ⛔ **This is a partition, not coordination.** Ownership is still inferred from *local*
   branches/worktrees, which are invisible across boxes, so two `own`-pinned boxes can still race
   the same PR (§7.2b, tortoise#5052) — the pin must not be mistaken for a claim registry.
4. **Drafts are deliberately excluded** from the sweep — a peer's draft PR is not yours to
   merge. The cost is that a *peer's* draft stalls until they ready it. Our **own** lanes' drafts do
   not: the sweep selects drafts whose branch matches the harness's own patterns (`*-tm`, `*-cap`,
   `fix/*`), readies them once, and sweeps them from the next cycle (see §7.2).
5. **Workers never touch the main checkout.** Every lane runs in `.worktrees/tm-<N>`; the
   controller only reads. `lane.sh` instructs its agent not to create or remove worktrees.
6. **No `task` sub-agents.** Extensions that would gate a nested agent (`review-enforcer`,
   `verification-gate`, `loop-enforcer`, `sequence-enforcer`) are explicitly disabled for
   workers, and the *harness* is the review gate instead.
7. **The key is the crown jewel.** The box that holds `AI_REVIEW_GATE_KEY` can authorise
   merges. It lives at `~/.pi/agent/.ai-review-gate-key`, is never written to logs, and is
   never copied into this bundle.
8. **One controller.** `.orch.lock` is created with `set -o noclobber`; a second start exits
   immediately, and a lock whose PID is dead is reclaimed.
9. **GitHub data never reaches a shell.** Inputs from the API are validated before use:
   `safe_ref` admits only `[A-Za-z0-9._/-]` **and** requires `git check-ref-format --branch`; PR ids
   must be all digits (`is_num`); worker arguments travel in a file and the daemon launches
   `merge-one.sh --argv <file>`, so no PR-derived value is embedded in the `sh -c` string that
   `tmux new-session` executes **on any live path**. (`retired/auto-loop.sh` still contains the old
   unsafe interpolation, annotated in place — it is unreachable from the live scripts and exists
   only as history; do not reuse it.) Branch names were the hole: git **permits** `'` `;` `$` `` ` `` `&` `|`
   `(` `)` `{` `}` `"` `<` `>` `#` in a ref (only spaces are forbidden, and `${IFS}` supplies
   those), so a fork PR on `fix/x';touch${IFS}/tmp/x;#` achieved arbitrary command execution on the
   host holding the merge key. Reproduced before the fix; the self-test now pins the validator.

### 5.3 Untrusted input and worker containment — read before running this unattended

This harness passes **attacker-controlled text** to language-model agents with shell access. Be
clear about what is and is not enforced:

- **Not sandboxed.** The spawned reviewer and fixer run with `AGENT_SKIP_REVIEW_GATE=1`,
  `ELDATO_SKIP_VGATE=1`, `AGENT_ALLOW_MAIN_EDITS=1`, `SKILL_ENFORCER_DISABLED=1` and
  `LOOP_ENFORCER_DISABLED=1`, with `bash` and `gh` on `PATH`. "Do NOT merge" and "do not touch the
  main checkout" are **prompt instructions, not controls**.
- **Prompt injection is possible.** `fix-one.sh` reads the PR's comments into the fixer prompt as
  the authoritative review, and `merge-one.sh` feeds the reviewer the PR title, body and diff. A
  malicious PR body can therefore attempt to steer an agent that has shell access.
- **What actually constrains it.** `gh pr merge` is reached only on a **gate-mode** repo (one whose
  branch protection requires `ai-review-gate`), and only after `record-review.sh` has written a
  signed marker for the exact head (§5.1), with `merge-one.sh` additionally waiting for
  `ai-review-gate` to read `SUCCESS`. On a **rail-mode** repo (agent-infra) the harness instead
  invokes `scripts/admin-merge.sh`, which posts its own head-bound evidence and merges with
  `--admin`; the harness does not call `gh pr merge` there at all, and auto-merge is deliberately
  never armed. The same refusal is one layer deeper: a merge worker whose OWN branch-protection
  read fails (REQ_SOURCE=fallback, no REQ override) exits 5 before reviewing or merging anything
  — which covers every ingress, including `chain-merge.sh` and `fix-one.sh`. A rogue *agent* cannot merge through the harness path; it could still `gh pr merge`
  or `git push` directly if the token permits, which is a property of the token, not this code.
- **What is deliberately not done:** the gate key is never placed in a prompt, a plist, a log or a
  command line, and no script creates a secret-bearing file.
- **Open item (tortoise#8246):** contain the workers properly — a read-only key path, no
  merge-scoped token during review, and treating PR content as delimited data rather than
  instructions. Until then, run this on a box whose GitHub token you would accept being used by an
  agent that has read a hostile PR body.

---

## 6. Operating notes

### Deliberate stop (handing the laptop to a human)

The ritual, in order — the point is that **no uncommitted work is lost**:

1. `launchctl unload -w …` — so it does not restart on boot.
2. `pkill -f orch-loop.sh`, then `rm -f $O/.orch.lock`.
3. Freeze workers: `tmux kill-server` (or kill sessions individually) and check for strays.
4. Capture every dirty worktree: `git -C <wt> diff HEAD > $O/wip/<name>.patch`, plus a
   copy of untracked files and a `.status` file recording `git status --porcelain`.
5. Post a note on the coordination issue naming the open PRs, so a peer box keeps draining.

Durable state survives a reboot regardless: the signing key, review records, the worktrees'
`.git`, and every PR on GitHub.

### Restart recovery (what has to be re-derived by hand)

Workers do not survive a reboot and their tmux sessions are gone, so the controller has no
record that they existed. Today this is recovered by reading `git worktree list`, the
`$O/logs/*.log` tails, and the `wip/` patches. **This is the main operational weakness — see
§7.1.**

### Detecting a hung worker (do this first if the queue stops moving)

`pi -p` has no internal timeout, so a reviewer or fixer can hang indefinitely — and because the
concurrency caps count **tmux sessions**, one hang permanently occupies a slot. Observed
2026-10-12: three merge workers hung for 6–9 hours (one had spawned a `find /` that ran for 8
hours), so half the merge capacity was dead weight overnight while the queue looked busy.

```bash
# a worker whose log has not grown in 40+ minutes is hung
tmux ls -F '#{session_name}' | grep -E '^(merge|lane|fix)-' | while read s; do
  f=~/orchestrator/logs/$s.log
  printf '%s silent %ss\n' "$s" "$(( $(date +%s) - $(stat -f %m "$f") ))"
done | sort -k3 -n -r | head
```

`orch-loop.sh` now reaps these itself (`STALE_MIN`, default 40): the session is killed and the PR
is re-dispatched on the next sweep, with `claim_live()` freeing the dead owner's claim.

### Reading the logs

`$O/logs/orch-loop.log` is the controller's decision log; every line is prefixed by a tag:

```text
[scope] open=24 -> BROAD (auto)             ← or (pinned SCOPE=own) / (pinned SCOPE=broad)
[cap] load=7/100 lanes=4/4 mem_avail=11761M/512M swap_free=588M/600M   ← every gate names its ceiling
[dispatch] load=7 lanes=4 -> 4429 4489
[refresh] +#4508 CLEAN -> backlog
#8219 FAILED:ai-review-gate          ← per-PR verdict for the required checks
#8192 fixer attempt 1                ← routed to a fixer, not a re-record
...
[cap] load=104/100 lanes=4/4 mem_avail=11890M/512M swap_free=588M/600M
[dispatch] skipped (load=104>=max_load=100)   ← and WHY, naming the binding gate
```

---

## 7. Gaps: what is fixed, what is not

Details and evidence for the remaining items: tortoise#8246. Same failure class in the fleet rail:
agent-infra#1678, #1680, #1683.

### 7.1 Dispatch bookkeeping never expires — **FIXED in this PR**

`orch-loop.sh` prunes `candidates.txt` against `dispatched.txt`, so an issue number is recorded as
"handled" the first time it is handed to a lane, and nothing re-checked whether that dispatch
**delivered**. A lane that dies (reboot, OOM, crash) stranded its issue permanently — invisible to
both the loop and to issue-triage, because the issue stays open with no PR.

Observed: **#4114, #4095, #3554** were dispatched 2026-10-10, their lanes died in a shutdown, and
each sat with a dirty worktree, no PR, and no re-attempt for >24 h.

**Fix:** the background refresh now runs a reaper — for each `dispatched.txt` entry, if the issue is
still open **and** no PR branch matches the number **and** no `lane-<N>` session is live, the entry
is removed from `dispatched.txt` **and** `checked.txt` so the pre-flight re-queues it. Four of the
self-test's checks pin exactly this decision table (`4114` reaped, `8888` kept for its PR, `9999`
kept because it is closed, `7777` kept for its live lane).

⛔ **A failed listing is not an empty one.** The reaper refuses the whole pass unless both
`.open_iss` and `.pr_brs` are **present**; the capture deletes a list when `gh` fails, so "the read
failed" (absent) is distinguishable from "the answer is none" (present but empty). Before the
guard, a failed `gh pr list` left an empty `.pr_brs`, `has_pr` was false for every issue, and
`dispatched.txt` was cleared — so `orch-loop.sh` re-spawned a lane for an issue that already had a
PR (duplicate work against the shared queue, agent-infra#1705). The self-test's failure-path checks
pin both halves (absent → nothing reaped and `checked.txt` untouched; empty-but-readable → still
reaps), and the capture site is driven directly with a stub `gh`.

### 7.2 Draft PRs are invisible to the sweep — **FIXED in this PR**

The selector was `select(.isDraft|not)` and nothing readied our own lanes' drafts, so a draft ran
its checks, failed `ai-review-gate`, and no worker ever touched it. Observed: **#8219**
(`feat/3524-tm`) and **#8085** (`feat/1037-tm`) sat with failed gates and an already-recorded
`ISSUES` verdict, stranded purely by the flag.

**Fix:** the sweep now includes drafts that match the harness's **own** branch patterns
(`*-tm`, `*-cap`, `fix/*`) and readies them once (`gh pr ready`) before the next cycle processes
them. Foreign drafts are excluded exactly as before — #4212 (`scope/w6b-graph-candidate`) is
another box's draft and is correctly left alone. (Note the two exclusions are independent: a PR on
`design/`, `scope/` or `dependabot/` is never swept even when it is not a draft — see §5.)

### 7.2c Conflicted PRs — **FIXED in this PR**

A CONFLICTING PR can never merge, but the sweep classified it GREEN/PENDING and called `gh pr merge`
on it every cycle, so the queue looked busy while nothing moved (observed: #8245, #8226, #8193, #8104). They are now routed to `fix-one.sh`, which integrates `origin/main`, resolves the conflict, and re-runs the review chain — capped by `MAX_FIX_TRIES` and parkable like any other fix loop. The
fixer prompt states that when a PR is CONFLICTING the conflict *is* the task.

### 7.2b Cross-box duplicate work — **FIXED in this PR**

The per-PR claim (§5.1b) is a **local file**, so it makes concurrency safe *within one box*. Two
boxes sweeping the same repo still both evaluate the same PR and the same issue, and the boxes
share GitHub, not a coordinator. The registry is now `refs/claims/<PR>-<head-sha12>` in the
repository the boxes already share (`<head-sha12>` because the key is `claim_key()`, which truncates
the head sha to its first 12 characters): `git push` to a ref is an **atomic create-or-fail** (a
CAS), so it needs no broker and no service, and the namespace is **outside `refs/heads/*`**, so it
triggers no workflow and never appears as a branch. **Verified empirically** on both
`daniel-ospina/agent-infra` and `daniel-ospina/tortoise`: pushing a probe ref to `refs/claims/*`
created **zero** workflow runs and **zero** check-runs, matching the static picture (every
`on: push` in both repos is filtered to `branches: [main]` or `tags`). `claims.sh` holds the
primitive; `merge-one.sh` resolves HEAD **before** claiming and exits 0 when another box owns that
head; `fix-one.sh` takes the **same** claim on the current head for the fixer's duration and
releases it before re-entering `merge-one.sh` (otherwise the reviewer-only claim left two boxes free
to spawn a fixer for the same PR); `orch-loop.sh` refreshes **every** claim in **one** fetch per
cycle into `state/claims-snapshot`, so `claim_live()` costs no per-PR network call. The lease is
**data, not liveness** (a remote pid cannot be probed), derived as `REVIEW_TIMEOUT + 1200` for the
reviewer and `FIX_TIMEOUT + 1200` for the fixer, and carried in the claim commit. Both tunables are
validated with `is_limit` (digits **and** at most nine of them) **before** that arithmetic, and
`claims.sh` clamps the ttl again at its own arithmetic site — because an overflowed lease is the
worst kind of failure: it goes **negative**, `_lease_of`'s `[0-9]*` cannot parse the minus sign, an
unparseable lease is read as **LIVE**, and `claim_prune` can never reap it, so that PR/head is frozen
across every box with no automatic recovery. Every
release/reclaim is `--force-with-lease`, so a box holding a **stale** commit (one that is no longer
the ref's tip) cannot release the winner's claim. Three hardening points from the adversarial
review of this PR: a **read-back failure on the create path still surfaces the commit we pushed**,
so the caller can fenced-release a claim that did exist instead of orphaning it for the whole lease;
a **failed reclaim push is classified by re-reading the ref** — unchanged or unreadable is an
infrastructure failure (rc=2, fail-open), a moved ref is a genuine lost race (rc=1) — rather than
reporting every transient error as a lost race and failing closed; and worker lease-read temp refs
live under `refs/claims-tmp/*`, **not** the pruned `refs/claims-cache/*` namespace, so
`claim_snapshot --prune` can no longer delete a concurrent read mid-flight. It **fails open on
purpose** — if the claim store is unreachable the harness proceeds and logs it — because
agent-infra#1709's headline finding is that duplicate execution is unavoidable and the side effects
must be idempotent per head, so failing closed would stall the whole fleet on one transient error.
`SCOPE=own` (§5, item 3) remains a useful partition but is no longer the only cross-box barrier.

### 7.3 The harness is unversioned (this directory is the remedy)

Until now it existed only as `~/orchestrator/*.sh` on one machine: no history, no review,
no way to hand it to another box, and no way to know which of the 14 scripts were live. §9
records which are live and which are retired.

### 7.4 Defects found in the first review of this artifact (all fixed here)

These are kept as a record because each one is a *failure mode of the design*, not a typo.
(`retired/` fixes are annotated in place and only parsed — the retired tree is dead code.)

| Defect | Impact | Fix |
|---|---|---|
| `MAX_LOAD` was rendered into the plist and documented as live back-pressure, but never compared to anything | the load ceiling did not exist; a lanes-bound stall logged itself as a load stall | the dispatch gate now tests load first and names the binding gate in `[dispatch] skipped (…)` |
| `SKIPPED`/`NEUTRAL` counted as satisfying **every** required check, including the merge authority | a skipped `ai-review-gate` read as `GREEN` and the PR merged **without any signed review** — a fail-open on the one gate that matters | the classifier requires explicit `SUCCESS` for `ai-review-gate` (absent counts as failed) |
| A lane's PR is driven by `chain-<N>`, whose session name the controller's in-flight guard could not see | two concurrent `merge-one.sh` runs per PR: duplicate evidence comments, duplicate `record-review` writes, `ISSUES`/`CLEAN` interleaving | atomic per-PR claim file, honoured by all three paths |
| `fixcount` was incremented and the findings marker deleted *before* the fixer spawn was attempted | a killed/failed spawn consumed one of `MAX_FIX_TRIES` and destroyed the findings, so no fixer ever ran | spawn first; bookkeep only on success, message the failure otherwise |
| Reaching `MAX_FIX_TRIES` fell through to the re-record branch | an unfixable PR burned a full fresh-context review **every cycle, forever** | terminal `state/parked-<PR>` state, keyed to the head so a new push re-arms it |
| `tmux has-session -t fix-82` prefix-matches `fix-820` | PRs whose number prefixes a running worker's were starved of attention for as long as it lived | exact session-name matching (`tmux ls -F … \| grep -qx`) |
| `refresh-candidates.sh` `cd`-ed into a scout worktree nothing ever created | on a fresh box the refresh exited 1 every cycle and the backlog silently never refilled | provision the worktree and its venv on first use, or fail loudly |
| `install.sh` reported an env-only gate key as present | the daemon silently started without it and the "merge role" install.sh just blessed did not work | only a key *file* is authoritative; env-only is reported as insufficient |
| **`refresh-candidates.sh` hardcoded a tortoise/Python shape** (`uv sync --extra embeddings --extra parity` and tortoise's `tools/collision_preflight.py`) | a cell pointed at a non-Python repo (agent-infra has no `pyproject.toml`) aborted **every** cycle, and because `orch-loop.sh` runs the refresh in a **backgrounded subshell** the non-zero exit could not fail the loop: the controller reported `RUNNING` with `lanes: 0` **forever** — a cell that looks alive and can only merge (agent-infra#1736) | the venv step is skipped only when it is genuinely **not applicable** (no `pyproject.toml`) — a real `uv sync` failure is still fatal, loud, and prints uv's own output; the extras are read from the project; the tool is resolved per repo (own copy, else a `TORTOISE_REPO` checkout) and its absence is a **permanent** `rc=3`; `--check` gives the same verdict read-only so `cloud-cell-supervisor.sh check`/`start` refuse a merge-only repo with the reason; and `orch-loop.sh` now reads the rc — permanent writes a `MERGE-ONLY` marker and stops retrying, transient still retries |
| **the merge-key preflight asked "is there a key?" in four mutually inconsistent ways** | every divergence is a false green on the one check that decides whether a cell signs its reviews: `install.sh` and `cmd_check` tested the key **file** by *size*, and a 1-byte newline — exactly what `echo "$KEY" > file` writes for an unset variable — read as present; `cmd_check` tested the **`keys.env` value** for raw non-emptiness, while the consumer strips whitespace and treats the result as absent; the **precedence was file-first** while the consumer is env-first, so a whitespace-only value shadowed a valid file (its fallback never runs on a non-empty raw value); and the file was read from `$HOME`, which `keys.env` may repoint while the session forces `HOME` back to `$CELL_HOME` after the source | both the file and the value are tested for **normalized content** at every site, the order matches the consumer (env first, the file as its fallback), the file is read from `$CELL_HOME` — the home the session actually uses (`keyfile_has_key` states it explicitly, and the supervisor re-exports `HOME=$CELL_HOME` after sourcing so both agree on every path) — and each of the four cases has a check that a mutation turns red, except that the two HOME guards are now equivalent: with the re-export in place, reading `$HOME` or `$CELL_HOME` gives the same answer, so the behavioural pin is the check that a keys.env `HOME=` cannot change the verdict. |
| Plist rendered with unescaped `sed` replacements | a `&` in a path expanded to the matched placeholder, producing a *valid* plist pointing at wrong paths (so `plutil -lint` cannot catch it) | escape `\`, `&` and `\|` in every substituted value |
| `retired/do-merge.sh` logged `rc=$?` after an unquoted `$(date)` | every merge failure logged as `rc=0` | capture the status first |
| `retired/watch-one.sh` built the fixer prompt from a log the reviewer had not written yet | the fixer always ran against an empty FINDINGS section | build the prompt after the reviewer run |
| the pre-fix sweep logged `#<PR> re-record` even when the concurrency cap suppressed the spawn (`{A\|\|B\|\|C;} \|\| D && echo` parses as `({A\|\|B\|\|C} \|\| D) && echo`) | a stalled drain looked busy | explicit `if/elif` branches |
| **this file's own self-test** re-implemented the fixed logic instead of reading the shipped scripts | it passed on the broken copy, so it pinned nothing | every check now extracts and drives the real classifier, `sess()`, claim block and reaper, or runs `install.sh`; §9/§7 claims corrected |
| `MAX_REVIEW` defaulted to 2 in `orch-loop.sh` but 4 in `install.sh`, the plist it renders, and §4 | running the loop directly (not via the plist) silently halved reviewer concurrency against the documented value; the `${MAX_REVIEW:-4}` fallback was dead code | default is 4 everywhere, and the self-test resolves all 10 limit defaults in both scripts and asserts they agree — including with the limits supplied via the environment, which is how the plist delivers them |
| the live sweep dropped the `CLOSED` guard that `retired/sweep.sh` had, keeping only `MERGED` | a PR listed open that closed in between fell through to `gh pr ready` + `gh pr merge` every cycle and logged `#<PR> merge fail` forever | `case "$PR_ST" in MERGED\|CLOSED) continue ;;` |
| `retired/auto-loop.sh` and `retired/sweep.sh` still carried the fail-open `ai-review-gate` classifier | shipping "the record" with the very bug being fixed invites reuse of it | both annotated in place as retired-with-known-fail-open |
| §3 and §8 admitted cross-box duplication while §5.1b said "one owner per PR" | the invariant was stated more strongly than the code delivers | §5.1b scoped to per-box; §7.2b states the open cross-box gap |
| **a PR branch name was interpolated into the `sh -c` string `tmux new-session` executes** | **arbitrary command execution on the unattended host that holds the merge key.** git permits `'` `;` `$` `` ` `` `&` `\|` `(` `)` `{` `}` `"` `<` `>` `#` in a ref name, so a fork PR on `fix/x';touch${IFS}/tmp/x;#` broke out of the quotes. Reproduced end-to-end before fixing | `safe_ref` allowlist + `check-ref-format`; numeric-only PR ids; and worker args now travel in a file (`--argv`) so no PR-derived value is interpolated at all |
| **the check classifier was a deny-list** (`bad = FAILURE\|ERROR\|CANCELLED\|TIMED_OUT\|ACTION_REQUIRED`) | a conclusion in **neither** list — one GitHub has not documented, or a **null** one — read `PENDING`, and `PENDING` arms the merge (`gh pr merge --auto`): the merge decision failed **open**. At the same time `CANCELLED` was named *red*, so a normally-superseded run (`cancel-in-progress: true`) was routed to `fix-one.sh` or to `gh run rerun` — failing **closed** on a green PR. `fix-one.sh`'s failing-check list named `CANCELLED` too, so such a run burned a capped fixer attempt (agent-infra#1714) | the classifier is an **allow-list with polarity**, the rule `admin-merge.sh` and `record-review.sh` already implement: non-red only for a NAMED conclusion (`success`/`neutral`/`skipped`/`cancelled`/`stale`), in-flight only for a NAMED status, and **everything else RED** — so an unrecognised or null conclusion blocks instead of arming; grouping is per `(app, name)` (newest attempt by `id`) so one app cannot mask another's — ⚠️ but the only call site feeds it `gh pr checks --json name,state,workflow`, which carries neither `id` nor `app`, so the grouping is in force only for a surface that carries them (agent-infra#1733); and an **empty** surface is `NOCHECKS`, never `GREEN`. `fix-one.sh` uses the same allow-list (agent-infra#1714) |
| the claim-file guard added in the first fix round introduced a permanent stall | the controller treated *the existence of* `mergeclaim-<PR>.lock` as "in flight", but only `merge-one.sh` removes it — a SIGKILLed worker or a reboot mid-merge left the PR skipped forever with no fixer and no re-record | `claim_live()` tests the recorded pid with `kill -0` and removes a dead owner's claim |
| 6 self-test checks passed vacuously because an empty extraction did not fail the check | the round-1 vacuity fix was incomplete: checks depending on `sess()`, the claim block or the reaper passed when the shipped script had no such code | `need()` turns a missing extraction into a FAIL |
| **a hung worker held a concurrency slot for 9 hours** | `pi -p` has no timeout and the caps count **tmux sessions**, so a hung reviewer (or a runaway `find /` it spawned) permanently reduced merge throughput while the queue looked busy — three slots were dead weight overnight on 2026-10-12 | portable `run_agent()` wall-clock limit (bash `wait` + watchdog subshell, since macOS ships no `timeout`) plus a `reap_stale_workers()` sweep that kills any worker silent for `STALE_MIN` minutes |
| **only `ai-review-gate` and `python-ci-gate` failures had a remediation path** | a PR red on any *other* required check (`docs`, `test-isolation`, `license-surface`, `legal-e2e`, `pricing-artifact`) was merely logged, so it sat red forever with **no worker at all**. Observed: #8278 carried two new `docs`-lint findings (MD056, an unescaped `\|` in a table row; MD046, fence style — fixed in `f15923b`) and #8193 a new `MD018` finding — both with zero workers for hours. ⛔ **And the name list was itself a tortoise constant (#1764):** on agent-infra a red `pipeline-compliance` matched none of those five, so the fix reappeared there | those checks now route to `fix-one.sh` too — but the arm is now **derived from the repo's own required set** (#1764), so a red required check routes on *any* repo (agent-infra's `pipeline-compliance` included) — capped and parkable like every other fix loop; and `fix-one.sh` fetches the failing check's **log** into the prompt, because it previously only ever read a reviewer comment — for a CI failure there may be no comment at all. ⚠️ **Known residual (agent-infra#1703):** that fetch reads the workflow RUN's `--log-failed` and `tail -80`, so a multi-failed-job run can hand the fixer the wrong job's log; tracked, not fixed here. |

### 7.5 Still open, deliberately not fixed here

> **Seven entries that were here are now FIXED** and have been removed from this list: the
> fail-open reaper when the PR listing fails (agent-infra#1705, tortoise#8519), `checked.txt`
> written before the pre-flight verdict (agent-infra#1716, tortoise#8515), the returning INT/TERM
> trap in `orch-loop.sh` and `merge-one.sh` (agent-infra#1715, tortoise#8516), the controller's
> macOS-only capacity probes (agent-infra#1702, tortoise#8514), the deny-list check classifier in
> `orch-loop.sh` (agent-infra#1714, tortoise#8518), this directory being older than its source
> (agent-infra#1712 — see the provenance note at the top of this file), and
> `cloud-cell-bringup.sh` deleting the pushed gh token only on the success branch
> (agent-infra#1718 — fixed in this branch, independent of the #1712 port).

- **`can_spawn()` gates on load only, so the memory ceiling does not cover the five controller spawn
  sites** (agent-infra#1732). Lane dispatch is bounded by swap and available memory; the five spawn
  sites are bounded by load alone, so raising `MAX_LOAD` widens the band in which they proceed while
  memory is already the binding gate. §4 states the gap; this is its tracker item.
- **The check classifier's `(app, name)` grouping and its newest-by-`id` selection cannot take effect
  at the call site** (agent-infra#1733). `gh pr checks --json name,state,workflow` carries no `id` and
  no `app`, so the newest attempt is decided by row order, and two non-Actions checks that share a
  name collapse into one bucket — the masking the grouping exists to prevent. §7.4's grouping claim
  holds only for a surface that carries `id`/`app`.

- **`state/` and `wip/` grow without bound.** There is no time- or size-based retention: nothing
  expires `merged-*.done`, `fixcount-*`, `parked-*` or stale `rerun-*`. (`mergeclaim-*.lock` and
  `needsfix-*` are pruned when they are consumed or their owner dies — `merge-one.sh`'s `trap`, the
  controller's `claim_live()`, and the successful-fixer path — so they are bounded by traffic, not by
  time.) Needs a retention rule rather than an ad-hoc `find -mtime`.
- **`[ -z "$WT" ] && { … }` as a script's last statement** makes the exit status that of the
  test. The shipped `fix-one.sh` ends with a positive `echo` so it no longer leaks a non-zero
  status, but the pattern is easy to reintroduce — a `exit 0` at the end of each script would pin it.
- **Worktree reaping.** Every dispatch and every foreign-branch fixer adds a worktree; the box
  carried ~150 by the end of the run. Nothing removes them after their PR merges.
- **A persistently-colliding issue can consume the whole refresh window (agent-infra#1729).**
  `refresh-candidates.sh` spends its pre-flight budget *before* it reads the verdict, and since
  agent-infra#1716 a `COLLISION`/no-verdict pre-flight writes no `checked.txt` — so while the first
  `LIMIT` pool entries keep colliding, the entries behind them are never pre-flighted and the
  backlog silently stops refilling (the log still reports a normal `checked N; backlog now M`).
  Faithful to upstream tortoise#8515, not a porting defect; bounded by `LIMIT` (6 from the loop).
- **The fixer's CI-log fetch (agent-infra#1703).** `fix-one.sh` reads the workflow run's
  `--log-failed | tail -80` rather than the failed *job's* log, so a multi-failed-job run can feed
  the fixer the wrong check's output. Raised as a P1 in the tortoise#8298 review and never applied.
- **The runner-label gate reports success on values it never read (agent-infra#1704).** In
  `ci_runner_gate.sh`, an unreadable queue count falls through to "healthy" (the integer test
  errors and the `||` chain reads that as false) and `set_labels()` reports success when the runner
  enumeration fails (the loop runs zero times and `[ "$fail" -eq 0 ]` succeeds). Both are false
  PASSes on a gate that changes runner labels.
  **✔ FIXED in agent-infra** — both now return 2 (could-not-measure), name the failure, and leave the
  state file and the notification untouched; pinned by `scripts/ci_runner_gate.test.sh` (a bash shard
  in both CI lanes), which is red on the pre-fix tree.
- **The reaper fails open when the PR listing fails (agent-infra#1705).** `refresh-candidates.sh`
  writes an empty `.pr_brs` on a failed listing, so `has_pr` is false for every issue and PR-bearing
  issues are un-blacklisted and re-dispatched. Same class as the `open_pr_count()` fail-closed fix
  in §7.4, in a file that fix did not reach.
- **`dispatch-merge.sh` interpolates `$REPO`/`$OR` unguarded (agent-infra#1710).** Both are built into
  a tmux `sh -c` lane/chain command with no metacharacter guard — the class closed for `$O` in
  `orch-loop.sh` and for six values in `cloud-cell-supervisor.sh`. A `'` in either closes the quoted
  span; separately, a lane that dies instantly is still logged as a successful spawn.
- **The merge key reaches the controller but not the merge workers (agent-infra#1711).** The workers
  are spawned through a second tmux boundary, and a tmux session is served from the SERVER's
  environment, so with a pre-existing server a keys.env key is reported present by `cmd_check` while
  every merge runs keyless (a false PASS; `record-review.sh` then posts an UNSIGNED marker). The
  same boundary also drops `$O`, so under a non-default `$O` the workers write `state/` the
  controller never reads — recorded with the measurements on that issue.
- **This directory was older than its source (agent-infra#1712) — ported, and now pinned.** Seven
  commits merged on tortoise `main` after the copy was taken (2026-10-13 10:50Z, `eda7df136`); all
  seven are ported here, listed in the provenance note at the top. `port-provenance.txt` pins every
  file's tortoise blob hash at that sync point and `check-port-drift.sh` fails if the tortoise tree
  moves again. ⚠️ Still open, and not fixable from here: tortoise's **unmerged**
  `fix/8468-closure-linkage` branch rewrites this same directory (P0 bypass, `.prio`,
  `merged-not-closed.sh`, lane brief). The removal PR must either wait for it to merge or port it —
  deleting the directory while that branch is open orphans that work.
- **A keys.env with a top-level `exit` disables the supervisor silently (agent-infra#1713).** The
  file is sourced in the supervisor's own shell, so `exit`/`exec` ends the script: `start` returns 0
  having created no session.
- **`cmd_check` never tests `record-review.sh` (agent-infra#1717).** `merge-one.sh` calls it at
  `$HOME/.pi/agent/scripts/record-review.sh` and neither cell script provisions it, so a fresh cell
  prints "CELL CAN RUN A CONTROLLER", runs a full paid first review, then 127s **before** any parked
  marker is written — one fresh review per cycle, forever, with no terminal state.
- **`ci_runner_gate.sh` is versioned here but wired to nothing (agent-infra#1719).** No
  `templates/launchd/` job renders it and `pi-bootstrap/setup.sh`'s farm lists omit it, so this box
  still executes a hand-made duplicate at `~/.pi/agent/scripts/` — a fix here never reaches the copy
  that runs — and a second box has no fallback gate at all.
  **✔ FIXED in agent-infra** — `templates/launchd/com.tortoise.ci-runner-gate.plist` renders the job
  under the label the hand-made duplicate already used (so the installer converges that machine
  rather than stranding a duplicate), and `pi-bootstrap/setup.sh` (fleet_srcs) farms the script to
  the path the plist executes.
- **Three worker launch paths spawn ungated (agent-infra#1720).** `chain-<N>` → `merge-one.sh` (the
  first-review path for every own-lane PR), `fix-one.sh` → `merge-one.sh` and `adopt-fix.sh` →
  `fix-one.sh` read no `MAX_LOAD`; only the controller's five spawn *decisions* are gated, and §4
  says so.

---

## 8. Measured results

Branch-signature proxy: this box opens `*-tm` / `*-cap` / `*-night` / `*-evening` branches;
everything else in these counts is a peer box. Attribution by branch name is a proxy, not a
certificate — but the split is unambiguous.

| Window | This box | Peer | Notes |
|---|---|---|---|
| 2026-10-10 → 2026-10-12 (48 h) | **94 merged** | 41 merged | |
| 2026-10-11T04Z → 2026-10-12T05Z (24 h) | 51 merged | 27 merged | hour-by-hour below |
| Peak hour (2026-10-11T18Z) | **8 merged** | 0 | 8 PRs in 60 minutes |
| The 2026-10-10T23:45Z → 2026-10-11T21:22Z run | 77 → **99 merged** | — | this box's own handover record |

Hourly histogram (00:00Z–23:00Z on 2026-10-11, merged / this-box):

```text
04: 1/1   05: 4/3   06: 3/2   07: 5/5   09: 3/3   10: 3/2   11: 3/3
13: 2/1   14: 3/2   15: 4/2   16: 6/5   17: 7/5   18: 8/8   19: 3/3
20: 3/1   21: 3/1   22: 5/4   23: 2/1
```

Observed steady state on the original 8 GB host: 15 concurrent workers (4 lanes + 4 chains + 3 fixers +
4 reviewers), load 7–18, swap 588 M–832 M free, dispatch throttled by the swap gate.

**Honest caveat on the comparison.** Two boxes running this harness against one repo
duplicate work unless they coordinate: both may pick the same issue, and both run the merge
sweep over the *same* PR queue. A large part of the throughput above is the harness keeping
a box saturated for hours with no human, plus the box holding the merge key — not an
algorithmic advantage. The claim worth evaluating is *utilisation*, not *efficiency per PR*.

---

## 9. What is shipped

**Live** (reachable from `orch-loop.sh`):

| Script | Role |
|---|---|
| `orch-loop.sh` | the controller: merge sweep → capacity-gated dispatch → backlog refresh |
| `claims.sh` | cross-box claim registry: `refs/claims/<PR>-<head-sha12>` CAS, lease-as-data, `--force-with-lease` fencing. Sourced by `orch-loop.sh`, `merge-one.sh` and `fix-one.sh` |
| `repo-authority.sh` | **the per-repo merge contract** (agent-infra#1764): reads THIS repo's required status checks and derives whether the review gate applies to it, so the controller no longer enforces tortoise's check names on every repo. Fail-closed — an unreadable or unrepresentable set refuses. Sourced by `orch-loop.sh` and `merge-one.sh` |
| `dispatch-merge.sh` | creates the worktree and starts the `lane-*` + `chain-*` pair for an issue |
| `lane.sh` | the implementation worker (prompt template included) |
| `chain-merge.sh` | waits for the lane's PR, then runs the merge chain |
| `merge-one.sh` | fresh review → signed record → wait green → merge; marks `needsfix-*` |
| `fix-one.sh` | fixes a reviewer's findings, pushes, re-runs the merge chain |
| `refresh-candidates.sh` | pre-flights issues (collision check) into the backlog |
| `selftest.sh` | offline checks; each one drives the shipped code. Not part of the loop |
| `test-gates.sh` | the `mp_reason` dispatch-gate rule table, extracted from the shipped `orch-loop.sh`. Not part of the loop |
| `test-claims.sh` | the claim CAS against live origin from two throwaway clones. Not the cross-box proof (one machine), but red on a defeated CAS. Not part of the loop |
| `test-crossbox.sh` | drives the real `merge-one.sh` claim acquire + trap release with `gh` stubbed. Not part of the loop |
| `refresh-scout.test.sh` | the agent-infra#1736 contract: repo-aware scout provisioning, per-repo tool resolution, and the permanent/transient refresh split. Not part of the loop |
| `check-port-drift.sh` | gates the tortoise-side removal: fails if the tortoise harness moved past the pinned sync point (`port-provenance.txt`). Not part of the loop |

**Manual utility:** `adopt-fix.sh` — run `fix-one.sh` against a specific PR by hand;
`nonblocking-dispatch.sh` — launch a headless worker in the background and return immediately (§2).
Neither is part of the loop.

**Retired** (`retired/`, kept so nothing is lost): `auto-loop.sh`, `dispatch.sh`,
`do-merge.sh`, `refix.sh`, `sweep.sh`, `watch-one.sh`. These are earlier iterations of the
same idea and are no longer invoked; they are included for the record, not for use.

**Portability edits applied to every shipped script.** Three per-box constants became
overridable with this box's values as defaults (the launchd `PATH` is no longer one of them —
`install.sh` renders the `__PATH__` placeholder from the directories `tmux`/`gh`/`uv`/`pi` actually
resolve to, refusing any `*/shims`, `*/shims/*` or `*/.pi/*` directory because macOS TCC makes such
a symlink EPERM under launchd, and then probes each tool by executing it):

```bash
OR="${OR:-daniel-ospina/tortoise}"
REPO="${REPO:-/Users/danielospina/Documents/GitHub/tortoise}"
O="${O:-$HOME/orchestrator}"
```

The shipped copies are **not** byte-identical to the ones running on the original box: they are
those copies **plus every §7.4 fix**. `install.sh` compares the scripts it invokes — the nine loop
scripts in §9 plus the manual `adopt-fix.sh` — against the running copies at `$O` and warns loudly
on drift, because the daemon executes `$O/<script>` — a fix that only lands in this directory is not
in effect. That set is the one `install.sh`'s drift loop lists; `selftest.sh` is shipped but not
compared, since the daemon does not run it. If you are adopting this onto an existing box, sync
them (`cp <harness>/*.sh $O/`) and restart the loop before trusting any §5 invariant.

⛔ **Copying the scripts is not enough when a *limit* changed.** The launchd plist carries its own
environment block, rendered by `install.sh` from these defaults, and that environment **overrides the
script's own**. A job already loaded with `MAX_LOAD=16` keeps `16` no matter what `orch-loop.sh` now
defaults to. `install.sh` overwrites the plist *file* but does not reload an already-loaded job, and
`launchctl load -w` on a job that is already loaded does not reliably re-read it. So for a limits
change: re-run `./install.sh`, then `launchctl unload -w <plist> && launchctl load -w <plist>` — or
reboot, which is the only thing that reliably re-reads it — before trusting the new value.

⚠️ **And `launchctl unload` touches nothing when the controller was not started by launchd.** On this
box the loop runs as `nohup … orch-loop.sh` from a session — `launchctl list | grep orchestrator` is
empty even though the plist exists — so the unload/load pair is a no-op and the old process keeps the
old limits: the operator believes a limits change took effect when it did not. Check with
`launchctl list` before trusting the pair, and stop a session-started controller with
`pkill -f orch-loop.sh` (§6) rather than with `launchctl`.

Everything else is still tortoise-shaped and must be changed on another target: the branch
suffix (`tm`), `feat/<N>-tm` naming, `lane.sh`'s `uv sync --extra embeddings --extra parity`, the
`TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest` invocation.
The required-check list is NOW repo-aware: it is read from the target repo's branch protection
(`gh api repos/$OR/branches/main/protection/required_status_checks`), `REQ=…` overrides the read,
and `FALLBACK_REQ` in `repo-authority.sh` is the non-empty fail-closed last resort when protection
cannot be read. The merge authority follows from that set: a repo requiring the review gate merges
via `gh pr merge` after the gate goes green, and a repo that does not is merged through its own
`scripts/admin-merge.sh` (agent-infra#1764).
Two things that were on this list are now repo-aware: the collision pre-flight tool is resolved per
repo (the target repo's own copy, else a `TORTOISE_REPO` checkout) and the scout venv step is skipped for
a repo with no `pyproject.toml` — and a repo that can be provisioned is verified at `check` time —
agent-infra#1736.

---

## 10. Open questions for the evaluator

1. ~~Does this belong in `agent-infra` (symlink-distributed via `manifest.json` + `sync.sh`,
   pull-only) rather than in a repo's `operations/`?~~ **Answered 2026-10-13:** moved to
   `agent-infra/scripts/orchestrator-harness/` (agent-infra#1700).
2. Should the two boxes coordinate through an explicit claim registry instead of branch-name
   heuristics? tortoise#5052 already proposes "an authoritative, expiring claim registry" —
   §7.1 is the same problem seen from the dispatcher's side.
3. Is a `~/`-rooted bash harness the right shape at all, or should this fold into the fleet
   rail's cmux workspaces (agent-infra#1683)?
