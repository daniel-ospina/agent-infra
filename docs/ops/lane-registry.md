---
title: "Lane state registry — four states over git refs, so the orchestrator can answer 'did it finish?' (agent-infra#3382, slice 1)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-11-04
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-3382, issue-1759, issue-1761, issue-943, issue-3016, issue-1777, issue-1178, lane-registry, refs-lanes, orchestrator-mcp, lane-liveness, spawn-gate
---

# Lane state registry (#3382, slice 1)

**What this is.** The durable **state** record for a lane: four states, one small JSON per lane, stored as
a git ref (`refs/lanes/<lane-id>`) and written by the launcher that owns the lane. It exists because the
fleet ran 26 lanes and the orchestrator **could not tell whether any single one had finished** — every
verdict was an inference over a proxy, and each proxy produced a wrong answer.

**What this is NOT.** It is not a liveness verdict. `tools/fleet/liveness.py` remains the ONE function that
classifies a lane's process (`dead | running-quiet | wedged | idle | unknown`, #1178). The registry answers
a different question, from a different kind of evidence: *what does the lane itself say about its state?*
A registry record is **holder-authored evidence**; a liveness verdict is **reader-side evidence**. They are
two axes, and this document keeps them apart rather than merging them into a fifth ladder.

---

## 1. The five measured proxies, and what replaced each

Measured 2026-11-03/04 across 26 lanes. Every row is a proxy the orchestrator actually used, and the wrong
answer it produced.

| proxy | what it said | what was true |
|---|---|---|
| artifact byte count | "parked, superseded" | the lane was mid-turn |
| `cmux vm exec` timing out | "control plane failed" | the box was saturated by the orchestrator's own dispatch |
| an empty `git diff` from a fetch that silently never ran | "48 PRs already absorbed" | **0** were |
| a truncated list page | "P0 collapsed 13 → 3" | it was **13** |
| a merge count keyed on OPEN labels | "0 P0 landed" | the closures were invisible by construction |

The replacement is not a better proxy. It is a **terminal record with an exit code and a lease**, which is
how CI systems already represent completion (§4).

---

## 2. The contract

### 2.1 Four states, and no fifth

| state | asserted | NOT asserted |
|---|---|---|
| `RUNNING` | a record exists and its lease is **open** (`now <= lease_until`) | that any process is alive, or that the lane is making progress |
| `DONE` | a **terminal** record exists and names its **artifacts** | that the artifacts are correct, merged, or sufficient |
| `FAILED` | a terminal record exists and states its **reason** | that the failure is recoverable, or whose fault it was |
| `EXPIRED` | **no heartbeat past the stated budget, and no terminal record** | that the lane is dead — the box may be alive and simply not writing |

> **`EXPIRED` is DERIVED, NEVER WRITTEN.** The writer verbs refuse `expired` as an argument (exit 2). A
> state a writer could forget to record is the proxy problem again, one layer down; a state any reader can
> derive from two numbers in the record needs no actor to notice it. This is the single most important
> property in the contract.

**`NOT-FOUND` is a lookup outcome, not a state.** A lane id with no record exits **4** and is never
reported as one of the four. **`UNMEASURED(<cmd> + <error>)`** is what an unreadable registry produces
(exit **3**) — never `RUNNING=0`. Collapsing "I could not read" into "nothing is running" is the
FALSE-CLEAN class this fleet keeps paying for (#3382 invariant 1: *unknown ≠ zero*).

### 2.2 The record

```json
{
  "schema": 1,
  "lane_id": "cell-4.klane-3382-1762000000-p1234-9f3ac1de",
  "state": "RUNNING | DONE | FAILED",
  "host": "cell-4", "pid": 1234,
  "kind": "lane | fix | chain | review", "tag": "3382",
  "repo": "daniel-ospina/agent-infra", "issue": 3382,
  "branch": "feat/...", "worktree": "/path",
  "started_at": 1762000000,
  "heartbeat_at": 1762000060,
  "budget_s": 7200,
  "lease_until": 1762007260,
  "artifacts": [{"kind": "pr", "value": "3419"}, {"kind": "sha", "value": "..."}],
  "reason": null, "exit_code": 0, "ended_at": 1762000800, "duration_s": 800
}
```

**Invariants, each enforced in code and each with a test:**

1. `lease_until == heartbeat_at + budget_s` — **one** derivation, re-applied by every write including
   `beat` (so a beat can never append to a stale lease).
2. `EXPIRED` cannot be written; it is the reading of a `RUNNING` record whose lease has lapsed.
3. `DONE` requires ≥1 artifact (`--artifact kind:value`, `--pr`, `--sha`). A `done` that names nothing is
   the FALSE-DEATH defect in reverse: it asserts finished and cannot say *finished with what*.
4. `FAILED` requires `--reason`. "It failed" is precisely what the fleet already had.
5. A **terminal record is final**. `beat` refuses it and a second `done`/`fail` refuses it. (A record whose
   lease merely lapsed is *not* final — a late writer still gets to say what happened.)
6. A **corrupt or unparsable record fails the WHOLE read** (exit 3). It is never skipped (which would
   report the lane as never having existed) and never rendered as `EXPIRED` (which would assert a lapsed
   lease about a record whose heartbeat may be perfectly present). A ref whose payload names a
   **different `lane_id`** than the ref it lives under is corrupt for the same reason: everything
   downstream keys on the payload's id, so it could silently stand in for another lane.
7. **A corrupt shared registry is never answered from the local cache.** Unreachable and corrupt are two
   different facts: only unreachability may fall back (labelled `coverage: local-only`). Masking
   corruption with a stale local copy would hide it from the one reader placed to notice it.
8. **The write side abstains too.** `beat`/`done`/`fail`/`start` answer **3 (UNMEASURED)** — never **4** —
   when the registry cannot be read. Collapsing that into "no record, start it first" loses the terminal
   record *and* lets `start` force a fresh `RUNNING` over a finished lane.
9. **A lane id is a ref component and a file name.** It is validated against
   `^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$` before either use, so `../x`, `a/b` and an empty id are refused
   rather than resolved.

### 2.3 Verbs and exit codes

```
lane_registry.py start --kind <kind> --tag <tag> [--issue N] [--repo o/n] [--branch B]
                       [--worktree W] [--pid P] [--budget S] [--lane-id ID]
lane_registry.py beat  --lane-id ID [--push]
lane_registry.py done  --lane-id ID (--artifact KIND:VALUE | --pr N | --sha S)…  [--exit-code N]
lane_registry.py fail  --lane-id ID --reason TEXT                              [--exit-code N]
lane_registry.py list  [--json] [--state S] [--host H] [--repo o/n]
lane_registry.py show  --lane-id ID [--json]
```

**`beat` is local unless the lease needs renewing.** Publishing every beat would be one commit and one ref
write per lane per minute (~1.4k unreachable objects/day at 25 lanes) to say the same thing. The lease is
what a reader consults, so the ref is renewed at the **half-way point**; `--push` forces it. `start`,
`done` and `fail` always publish.

| exit | meaning |
|---|---|
| `0` | the verb did what it says |
| `2` | usage — bad or contradictory arguments (including `--state expired`, which cannot be written) |
| `3` | **UNMEASURED** — the registry could not be read. **Never** an empty registry. |
| `4` | **NOT-FOUND** — this id has no record. **Never** a state — and never asserted from a read that
      did not reach the shared store |
| `5` | **REFUSED** — a contract violation (see invariants 3–5) |
| `6` | **LOCAL-ONLY** — written on this box, the ref push failed; invisible to peers. Not success. |

---

## 3. Why git refs

`refs/lanes/<lane-id>`, force-updated, one commit whose tree carries `lane.json`.

* **It survives a dead box.** The reader is on the hub; the lane is on a cell. A file on the cell is
  unreadable exactly when the cell is the thing that died — and *"`cmux vm exec` timed out" → "the control
  plane failed"* is one of the five measured proxies above. A ref is readable from the repo by anything
  with a clone.
* **No exec channel.** Reading a cell's file needs `cmux vm exec`; reading a ref needs `git ls-remote`.
* **It cannot fire CI.** `refs/lanes/*` is outside the branch namespace and matches no `on: push:`
  trigger — verified empirically for the sibling `refs/claims/*` namespace on 2026-10-14 in both repos
  (`scripts/orchestrator-harness/claims.sh` §"WHY `refs/claims/*` AND NOT `refs/heads/claim/*`").
* **Persistence is not the server's job.** The MCP server is a reader; state that lived in its process
  would die with the process.

### 3.1 ⛔ Why not `refs/claims/*`, which already exists

`refs/claims/<pr>-<sha12>` answers **"who holds this head?"** and #1777 states exactly why it cannot answer
**"is this lane finished?"**: it is HEAD-keyed (a second commit mints a second key), it is **deleted on
release** and **pruned on expiry**, it is **released mid-lane** between `fix-one.sh` and `merge-one.sh` by
design, and it is **absent when `HEAD` is unresolvable**. #1777's plan says so in as many words: refs/claims
"does **not** supply the durable 'lane registry'". That registry is this one. This module neither reads nor
writes `refs/claims/*`.

### 3.2 One registry, in the harness repo

The registry lives in **one** repo — the harness repo (`$LANE_REGISTRY_REPO`, else `$AGENT_INFRA_PATH`) —
not in whatever repo a lane happens to be working on. Cross-repo visibility comes from the **record's
content** (`repo: owner/name`), never from which repo holds the ref. With 26 lanes across several repos,
polling N remotes would be a discovery problem stacked on a state problem.

`lane.list --repo owner/name` filters in memory. A box whose records are split across two repos is a
`LANE_REGISTRY_REPO` misconfiguration, and it is stated here rather than discovered later.

### 3.3 Uniqueness without a lock

`lane_id = <host>.k<kind>-<tag>-<start-epoch>-p<pid>-<8 hex>`

Host + start instant + pid + 8 random hex is unique across boxes **and** across lanes on one box, so the
force-update cannot clobber a peer (#1761: one owner per controller). `start` additionally **refuses** an id
that already exists (exit 5) — the random suffix makes the collision unreachable in practice, but the
check is there because a silent overwrite would make one lane's record replace another's, which is
invisible after the fact.

> The suffix is not decoration. **Measured:** two lanes started in the same second from the same launcher
> produced the *same* id — a controller that dispatches twice in one tick gives both lanes an identical
> host, instant and parent pid.

### 3.4 Leases, clock skew, and what `EXPIRED` costs

`EXPIRED` is decided by comparing the reader's clock to `lease_until`. **Cross-box clock skew is therefore
an exposure**: a reader whose clock runs fast can call a live lane `EXPIRED`. The mitigations are structural
rather than clever — the default budget is the lane's own absolute backstop (`7200 s`), so the error window
is bounded by the skew against a two-hour lease; `heartbeat_at` is carried so the reason names both numbers;
and `EXPIRED` is **not** a tombstone, so a late writer can still record `DONE` and correct the reading.

**A false `EXPIRED` costs a re-dispatch. A false `RUNNING` costs the lane's whole result** — the fleet
stops looking and the work is lost with the box. The trade is deliberate in that direction.

---

## 4. External prior art — the model is not invented here

Searched 2026-11-04 through the `research` skill (rung 1 unavailable: `mcp_load seo-intelligence` →
`spawn …/node_modules/.bin/tsx ENOENT`; rung 2 `web_search model="sonar"` used; 2 queries attempted, 1
returned then 1 after a serial retry on HTTP 429 — both covered).

| source | what it establishes | what this adopts |
|---|---|---|
| Kubernetes `Job` API reference — `.status.conditions` `Complete=True` / `Failed=True` | a job is finished when an **explicit terminal condition** is present; `completionTime` is set on success only | `DONE`/`FAILED` are written terminal conditions; `RUNNING` is never terminal |
| `kubernetes/kubernetes#117303` (Job state on `DeadlineExceeded`) | the **intermediate** fields (`.status.succeeded`) must not be read as definitive completion | nothing intermediate is exposed; the four states are terminal-or-not, and counts are only ever of records |
| Kubernetes **Leases** (`kube-node-lease`, renew ≈10 s, unreachable ≈40 s) and *Node Status* | liveness is a **renewed lease**, and its expiry is an explicit signal "rather than a filesystem timestamp" | `budget_s` + `heartbeat_at`; `EXPIRED` is the reading of a lapsed lease |
| [Long-running MCP operations](https://www.gmicloud.ai/en/blog/long-running-operations-in-mcp-job-tracking-polling-and-idempotency) · [Azure durable-functions MCP sample](https://learn.microsoft.com/en-us/samples/azure-samples/mcp-functions-long-running-tools/mcp-functions-long-running-tools/) · [MCP async-jobs pattern](https://www.powerduck.com/blog/mcp-tool-long-running-async-jobs/) | return a handle; expose a **status tool with explicitly enumerated terminal states**; **persist state outside the server process**; `not_found` is a lookup outcome, not a state | `start` prints the handle; the MCP exposes only reads; the store is the ref, not the process; `NOT-FOUND` exits 4 |
| [Designing MCP servers for infrastructure](https://www.itential.com/resource/blog/designing-mcp-servers-for-infrastructure/) | separation of read and write tools; explicit side-effect disclosure; structured errors; predictable recovery | the MCP surface is **read-only with no flag that changes that**; the writer is the launcher |

**What the prior art does not settle, decided here:** mtime/size is *never* an input. A file's mtime is not
an act — anything that touches the file resets it, and a process that dies cannot stop touching it. The
five measured proxies above are all in that family.

---

## 5. Wiring: the ONE launcher

State is written by `scripts/orchestrator-harness/spawn-gate.sh::run_agent` — the single agent invocation
every worker goes through (`lane.sh`, `fix-one.sh`, `nonblocking-dispatch.sh`; `spawn-gate.test.sh` asserts
that launch-path set as an equality). A per-caller hook would be the drift #1720 removed: a launcher added
tomorrow would silently not satisfy the contract.

* `lane_registry_begin` immediately **before** the spawn, so a refusal **at the spawn point** — the `pi`
  run refused by the loader, or the `pi` **shim's own** fork refusal (`PI_FORK_REFUSED`) — gets its own
  `FAILED agent-never-started` record rather than a `RUNNING` record that lapses into `EXPIRED` two hours
  later. **The gates ABOVE it do not**, and the list is specific: brief, disk, load, land-backlog,
  capability **and the pre-spawn fork gate** (`AGENT_FORK_REFUSED`) all refuse before a record exists, so
  such a refusal reads `NOT-FOUND` — the honest answer, because the lane never started.
* `lane_registry_begin` costs **one** bounded `ls-remote` of the exact ref (`ref_exists`), not a full
  registry read: a `start` that fetched every lane's payload before spawning the agent would put the
  registry's read cost on the launch path — 40 s+ on a blackholed remote, and growing with the fleet. It
  also derives `--budget` from the lane's own wall bound (plus a margin), so a long lane cannot read
  `EXPIRED` before its own terminal record exists.
* `lane_registry_beat` starts a beat loop watching the agent pid; it exits when the agent does and is
  reaped explicitly on the far side of `wait`.
* `lane_registry_end` **last**, after every diagnostic, so `AGENT_BOUND_VERDICT` and `AGENT_CAP_HIT` are
  final:

| condition | verdict |
|---|---|
| agent never started | `FAILED` `agent-never-started:rc=<rc>` |
| a bound ended it | `FAILED` `bound:<verdict>` |
| cap hit | `FAILED` `cap-hit:rc=<rc>` |
| exit ≠ 0 | `FAILED` `exit:<rc>` |
| otherwise | `DONE`, with `log`, `branch`, `sha`, `worktree` artifacts |

⛔ **The leg cannot refuse, delay or change a spawn.** Every call is best-effort, bounded, and its failure
is a `WARN` in the lane's log — never an exit code, never a `return`. Same rule as the uv pin beside it. A
registry that could fail a lane would be a bigger defect than the blindness it fixes.

**`LANE_REGISTRY=0`** is the documented off switch, for a test fixture that drives `run_agent` (or a box an
operator has drained by hand). An ambient OFF is a fleet that cannot answer the question, so the switch is
asserted load-bearing by its own test arms.

---

## 6. The MCP surface for this slice — and the surface that is NOT approved

`mcp-servers/orchestrator/server.py`, registered in `templates/.mcp.base.json` (→ every installation's
`~/.pi/agent/.mcp.json`) and in this repo's `.mcp.json`. Zero third-party packages: `node_modules` /
`pip install` must not be a precondition for the fleet to be able to say whether its lanes finished.

| tool | verb |
|---|---|
| `lane.list` | `list --json` — the four-state counts, every record, `running`, `expired`, `oldest_unfinished` |
| `lane.show` | `show --lane-id --json` — one record, or `not_found` |

**`lane.list` takes the same filters as the CLI (`state`, `host`, `repo`) and applies them through the
SAME read function (`collect`); `lane.show` takes one id.** They used to be applied only in `cmd_list`, so the MCP answered a *wider*
population than the caller asked for with no marker — a filter-shaped false answer that diverged from the
CLI with identical arguments. A filtered payload now carries `filters: {...}`, because a filtered
`RUNNING=0` must not read as a full-fleet measurement of zero.

**An unrecognised filter is refused on both surfaces, never answered with a zero.** The CLI got that from
argparse `choices`; the MCP had nothing, so `lane.list {state:"BOGUS"}` answered `counts.RUNNING = 0` with
`isError: false` — a confident "nothing is running" for a question the tool did not understand, while the
CLI exited 2 for the same argument. The check now lives in `collect`, which both surfaces pass through, and
`state` is normalised (`" RUNNING "` finds the lane rather than matching nothing). A `host`/`repo` filter
that could not match also publishes `excluded_no_host` / `excluded_no_repo` / `filter_matched_nothing`: a
record whose `repo` was never written cannot satisfy `--repo`, and "no lane could answer" is not "no such
lane".

**A filter is not a verdict either:** `lane.show` for an id absent from a **local-only** read answers
`UNMEASURED`, not `not_found` — the lane may simply be on a box this read cannot see.

**Both are reads. There is no flag that makes the server write**, and the surface is **pinned by a test**
(`test_S3_the_surface_is_EXACTLY_two_read_only_tools`): adding a third tool reddens CI. That is what makes
"do not expand the surface without owner approval" enforceable rather than aspirational.

The server reports `registry_sha256` on `initialize` and on every payload, so a **stale deployed copy is
detectable** (#3382 invariant 5; the incident is #3016's 151-commits-behind checkout whose `scripts/` was
older than the box claimed).

⛔ **Proposed, NOT approved — Phase 2 of #3382, awaiting an owner decision:** `lane.tree`,
`lane.artifact`, `lane.dispatch`, `lane.message`, `box.exec`, `fleet.census`, `pr.queue`, `claim.check`,
`review.record`, `verify.independent`, `closure.audit`, `reminder.*`, `beat.checkpoint`. Their wrap targets
are inventoried in [`orchestrator-mcp-inventory.md`](orchestrator-mcp-inventory.md) §5; none is built here.

---

## 7. Portability traps (mac / Linux cell / `CELL_HOME` cell)

* **stdlib only**; `python3` (or `python`) is the only interpreter dependency, no venv — a lane venv does
  not exist yet at this point in a spawn.
* **No `timeout(1)`, no `bc`, no `/proc`.** Every git call is bounded inside Python (`subprocess.run` with
  `timeout`), because the mac has no `timeout` and the cells do.
* **`GIT_AUTHOR_*` / `GIT_COMMITTER_*` are set explicitly.** `commit-tree` refuses with
  `rc=128 Author identity unknown` on a box with no global git identity — **measured on cell-4**:
  `fatal: unable to auto-detect email address (got 'cmux@cmux.(none)')`. Without this, the write path
  works on the hub and fails on the box that actually runs the lanes.
* **`CELL_HOME` then `HOME`** for the state root; `$O` / `$AGENT_INFRA_PATH` / `~/.pi/agent/scripts` for the
  module (the same candidate ladder `spawn-gate.sh` uses for `lane-bound.sh`).
* **The local write-through copy is never the authority.** `local_dir()` — `$LANE_REGISTRY_LOCAL`, else
  `${LANE_REGISTRY_STATE:-${CELL_HOME:-$HOME}/.pi/agent/state}/lanes`, so **`CELL_HOME` wins over `HOME`**
  (a cell runs `CELL_HOME=/tmp/cell-home` with `HOME=/home/cmux`, and the two are different directories) —
  is the box's own witness; the ref is the shared record. When only the local copy can be read, the payload says
  `coverage: "local-only"` and the MCP raises `isError` — a partial answer labelled is useful; labelled as
  complete it is not. A failure to write that copy is a **WARN, never a returned failure**: an
  unwritable `HOME` must not be able to abort the write of the shared record, which is the authority.
* **The destination ref comes from the record's OWN validated id**, never from an unchecked payload — a
  hand-edited or peer-published ref whose payload names another lane cannot redirect a write.

---

## 8. The five questions, and how to ask them

```bash
lane_registry.py list --json            # the whole answer, one object
lane_registry.py list --state RUNNING   # 1) which lanes are RUNNING
lane_registry.py list --state DONE      # 2) which finished (each with its artifacts/shas)
lane_registry.py list --state FAILED    # 3) which FAILED, and why (each with its reason)
lane_registry.py list --state EXPIRED   # 4) which EXPIRED (lease lapsed, no terminal record)
lane_registry.py list --json | jq .oldest_unfinished   # 5) the oldest unfinished lane
```

Or from a session, without a shell: `lane.list` / `lane.show`.

---

## 9. Known residuals (stated, not implied)

1. **`merge-one.sh` carries its own `run_agent()`** (this is not new — `spawn-gate.sh`'s header already
   names it for the disk gate). Reviewer and merge lanes reached that way do **not** write a record.
2. **`check-deployed-drift.sh` hashes only `*.sh`** (#3016), so a stale `lane_registry.py` in `$O` is not
   caught by that gate. The mitigation shipped here is the `registry_sha256` fingerprint on every payload;
   adding python to the drift gate is #3016's work, not this slice's.
3. **Clock skew** — see §3.4.
3b. **A corrupt record has no shipped remedy.** A record that fails `_record_problem` (a bad `lease_until`,
   a `DONE` with no artifacts, a ref/payload id mismatch) fails the **whole** read by design — skipping it
   would report the lane as never having existed — and it also disables this box's local fallback for every
   lane. There is no `prune`/`repair` verb in this slice. The remedies, in order:

   ```bash
   # a corrupt SHARED ref (this is what makes the fleet read UNMEASURED)
   git -C <registry-repo> push origin :refs/lanes/<lane-id>
   # a corrupt record in THIS BOX's witness
   rm "${LANE_REGISTRY_LOCAL:-${LANE_REGISTRY_STATE:-${CELL_HOME:-$HOME}/.pi/agent/state}/lanes}/<lane-id>.json"
   ```
4. **A beat publishes only when the lease needs renewing** (see §2.3): `beat` re-derives the lease locally
   on every call and pushes at the half-way point, or when `--push` is given. A lane beating every 60 s on
   a 2 h lease therefore performs one small ref push per hour, not per minute. This entry used to say the
   opposite ("a beat is a push"), which was both wrong about the code and the authority a reader would
   have cited for the beaten path.
