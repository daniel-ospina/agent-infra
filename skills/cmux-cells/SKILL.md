---
name: cmux-cells
description: "Operate the cmux cloud cells (Linux VMs) as part of the fleet — provision and activate them, measure their real capacity, recover a wedged one, dispatch lanes, and land work unattended. Read this before touching a cell."
domain: operations
subjects.team: organisation-design-team
type: reference
status: live
tags: [fleet, cmux, cells, dispatch, capacity, recovery, harness]
summary: "How to provision, measure, recover, and dispatch on cmux cloud cells, and how work actually lands from them."
created: 2026-10-19
updated: 2026-10-19
---

> ⛔ **This skill MUST be read in full — not skimmed.** Every section below is a measurement that cost a lost lane, a
> wasted hour, or a wrong conclusion. The traps are the content.

# Operating the cmux cloud cells

The fleet runs on four boxes: the macOS laptop (launchd) plus three Linux cells (cell-1 `pi-lane-1`, cell-2 `pi-cell-2`,
cell-3 `pi-cell-3`). Cells are Linux, so **any harness change must work on both platforms** — one source of truth with a
platform branch, never two drifting copies.

Canonical harness home: **`agent-infra/scripts/orchestrator-harness/`**. `tortoise/operations/orchestrator-harness/` and
`~/orchestrator/` are historic forks; treat agent-infra as the authority.

---

## 1. Provisioning a cell — and the step the installer forgets

The documented path, run ON the cell:

```bash
git clone https://github.com/daniel-ospina/agent-infra.git /tmp/cell-ai
cd /tmp/cell-ai && git checkout main
bash pi-bootstrap/cell-install.sh            # the operational layer: scripts farm, guards, skills, config
HOME=/tmp/cell-home bash scripts/cloud-cell-bringup.sh --check   # → should end: CELL READY
```

`HOME=/tmp/cell-home` is mandatory. `cmux vm exec` runs as `cmux` with `HOME=/home/ubuntu`, which does not exist — anything
writing to `$HOME` dies with `mkdir /home/ubuntu: permission denied`.

**⚠️ `CELL READY` is not "activated". Two things are still missing after a verified install:**

| missing | symptom | fix |
|---|---|---|
| **`gh` shim** | every lane logs `#984 argv-level gh shim not found — only the string scanner is active`; the merge gate runs degraded and cannot verify the evidence it demands | `mkdir -p $HOME/.pi/agent/shims && ln -sf /tmp/cell-ai/scripts/gh-shim/gh $HOME/.pi/agent/shims/gh`, and put `$HOME/.pi/agent/shims` on PATH in `keys.env` (tracked as agent-infra#2164) |
| **capture extension** | `capture: BLOCKED (N queued, 402 quota)` on stdout blocks turns and corrupts the bringup probe (a healthy box reports `FATAL: provider probe failed`) | move `$HOME/.pi/agent/extensions/tortoise-capture*` aside (agent-infra#2147); `TORTOISE_CAPTURE=0` does **not** disable it |

Verify activation by **artifact**, never by a banner:

```bash
for f in .pi/agent/scripts/record-review.sh .pi/agent/shims/gh; do [ -e $HOME/$f ] && echo "ok $f" || echo "MISSING $f"; done
echo "scripts=$(ls $HOME/.pi/agent/scripts|wc -l) ext=$(ls $HOME/.pi/agent/extensions|wc -l) skills=$(ls $HOME/.pi/agent/skills|wc -l)"
git -C /tmp/cell-ai rev-parse --short HEAD    # the version, not the claim
```

A cell is "on main" only if `git -C /tmp/cell-ai rev-list --count HEAD..origin/main` is **0**.

## 2. Capacity is RAM and DISK, never CPU

⛔ **Corrected 2026-10-27 — the numbers below used to REFUSE healthy dispatches.** Read them before
quoting any ceiling:

| resource | cost (measured) | note |
|---|---|---|
| **analysis / doc lane** (`pi` tree: wrapper + pi + bash) | **0.19–0.23 GB** whole tree | 4 lanes sampled on cell-4 |
| **test-running lane** (pi tree + pytest workers + per-lane FalkorDB) | **~0.4–0.7 GB** peak | containers measured 21–149 MB each |
| plan each lane at | **~1 GB** (test) / **~0.3 GB** (analysis) | the PEAK, not the idle |
| worktree `.venv` | ~1.1 GB per live worktree | `disk_free / 1.1` |
| CPU | load 4.3 with 23 lanes | **never the limit** |

The old row read "`pi` process ~0.6–1 GB RSS per lane". Measured, that is a **test-running peak**; an idle
lane's whole tree is ~0.2 GB. The old arithmetic applied that peak to EVERY lane and then stacked a flat
3 GB reserve on top, so on an 8 GB cell with **3 GB available it returned 0 lanes** — it told an agent a
box with room for two more lanes was full, and the agent believed it and reported "no capacity". Filling a
cell to 23 lanes **OOM-killed 37 processes and the tmux server** (agent-infra#2159), so the reserve is not
the thing to delete — the PER-LANE number is the thing to get right.

**Reserve, honestly stated:** keep **~1.5 GB** for the box itself (`cmux-tui` alone measured **1.1 GB**,
plus docker and kernel slack) — not a flat 3 GB, which dominates a small box and is what produced the false
zero. If a box has already OOM-killed (`dmesg | grep -ci 'killed process'`), raise the reserve for THAT
box instead of pretending a fleet-wide constant is a measurement.

```bash
# a JUDGEMENT AID, not an implementation — see the ⛔ note below
# PER=1000 for test-running lanes, PER=300 for analysis/doc lanes
PER=${PER:-1000}; RESERVE=${RESERVE:-1500}
mem_lanes=$(( ($(free -m | awk 'NR==2{print $7}') - RESERVE) / PER ))
disk_lanes=$(awk '{printf "%d", ($1-1)/1.1}' <<< "$(df -h /|awk 'NR==2{print $4}'|tr -d G)")
lanes=$(( mem_lanes < disk_lanes ? mem_lanes : disk_lanes ))
[ "$lanes" -lt 1 ] && lanes=1   # a zero means "measure, then judge" — never "this box can do no work"
```

⚠️ **`spawn-gate.sh` DOES NOT GATE ON RAM AT ALL** (verified 2026-10-27): its refusals are
`DISK_MIN_FREE_MB` (default **500**) and the load ceiling (`MAX_LOAD`, default `nproc × 10`). Nothing stops
you over-filling a box on memory — this arithmetic is the only RAM reasoning in the loop, which is exactly
why a stale number in it is expensive. Where the gate *does* speak, the gate is right.

`MAX_LANES` in `keys.env` is a static number and does not know either constraint — do not trust it as the ceiling.

⛔ **DO NOT RE-INVENT THE CAPACITY GATE — `scripts/orchestrator-harness/spawn-gate.sh` ALREADY IS IT** (checked
2026-10-19). It derives `MAX_LOAD` from `nproc × 10` when unset, refuses on a non-empty disk band (`disk_free_mb` vs
`DISK_MIN_FREE_MB`/`MIN_FREE_MB`, exit 77), validates its own probes against wrap/garbage readings, and carries **129
capacity assertions** in `spawn-gate.test.sh`. The failure it already names is the one worth reading: the band where
`cloud-cell-doctor --check` prints `CELL CAN RUN A CONTROLLER` while every lane spawn is refused 77.

The formula above is therefore a **diagnostic, not an implementation**: if a number disagrees with the gate, the gate is
right and the number is a curiosity. Any new refusal belongs inside `spawn-gate.sh` with a test — never in a brief, a
wrapper, or a skill.

**Disk and RAM resize draw on a shared plan pool, and the pool is the total ceiling — not the per-VM shape.** Measured
2026-10-19: `cmux vm resize <cell-3> --memory 12` was refused with *"only 4 vCPUs and 8 GiB are free in your plan pool"*
while three VMs were running. Disk grew twice (+8 GiB each) but **RAM had 8 GiB left in total**. So:

- the fleet's real RAM ceiling is the **plan pool**, and it is nearly allocated — per-cell memory cannot be raised by
  wanting it;
- a cell's lane ceiling must be computed from **its current free RAM**, and never assumed to be expandable;
- to raise one cell's memory you must first shrink or pause another box — that is an owner-level capacity decision, not a
  dispatch-time workaround;
- disk is the cheaper lever (separate pool, grew on demand) — prefer reclaiming disk, and only then resize.

## 3. "Unreachable" is a claim about the CHANNEL, not the box

| read | means |
|---|---|
| `cloud exec` timeout / 502 / silent empty | **the channel failed. Not the box.** Retry minutes apart |
| `cmux vm ls` → `running` | the provider sees the VM alive |
| **`cmux vm stats <vm>`** | **the only liveness truth**: `CPU n% · Mem x/y GB · Disk a/b GB` |
| `vm terminal read` → `No space left on device` | the guest is alive and full |

A **disk-full** cell behaves exactly like a dead one: the control agent cannot write its socket, so every `exec` times out
while the provider insists `running`. Measured 2026-10-19: cell-3 sat at 29.9/32 GB, CPU 77%, exec failing for an hour,
having submitted nothing for 141–226 minutes.

Recovery ladder, cheapest first:

1. `cmux vm terminal read <vm> <terminal-id>` — get terminal ids from `cmux vm tree <vm>`. The screen tells you the truth.
2. `cmux vm terminal send <vm> <term-id> '<command>' --keys enter` — runs a command when `exec` cannot (no output rendering if
   the disk is full, so verify from outside with `vm stats`).
3. `cmux vm pause <vm>` then `cmux vm resume <vm>` — provider-level reset. Fixes a wedged agent, does **not** fix a full disk.
4. **`cmux vm resize <vm> --disk <GiB>`** — grows in place, 4 GiB steps, **cannot shrink**. The correct lever for a full guest:
   32 → 40 GiB made a dead-looking box respond immediately.
5. Then, inside: kill stale lanes, `git gc --prune=now` on the clones, clear caches, re-run the update.

## 4. Liveness of a LANE, and the reaping rule

A lane's log **mtime** is the only reliable activity signal. Size alone is not, and a spinner is not.

- **0-byte lane log** = the lane could not start (usually disk full). It reads as "quiet", not broken — always check.
- A dead lane and a thinking lane are indistinguishable in every instrument except log mtime.

Reap only when **all three** hold (prose → code: agent-infra#1244, #2163):

1. zero CPU delta over a sample window, summed across the wrapper **and every descendant**;
2. **no human/terminal ancestor** — walk the chain to the top; `ppid 1` proves nothing;
3. stale: log untouched ≥ 2 h, **or** no log at all **and** up ≥ 12 h.

⛔ **Never treat "no log found" as "stale."** A first dry run flagged 69 lanes and would have killed a 7-minute-old lane,
because the worktree slug parsed from shell text (`ciwatch\012[`) matched nothing. An absent artefact fails closed.

Also: `ps -eo command | grep -c 'pi --model'` counts **wrapper shells**, not `pi`. 76 counted, 14 actually working.

## 5. Dispatching a lane

```bash
# brief on disk, launched detached, log in /tmp/cell-home/L-<slug>.log
tmux new-session -d -s <slug> \
  "HOME=/tmp/cell-home bash -lc 'cd <worktree-or-checkout>; . /tmp/cell-home/keys.env; \
   nohup pi --model deepseek/deepseek-v4-flash --provider deepseek -p \"\$(cat <brief>)\" > /tmp/cell-home/L-<slug>.log 2>&1 < /dev/null'"
```

- Model must be `provider/model` (`deepseek/deepseek-v4-flash`), never bare.
- ⛔ **LAUNCH THROUGH THE GATED PATH, NEVER A RAW `pi`.** `nonblocking-dispatch.sh <name> <worktree> <prompt-file>`
  backgrounds `run_agent()` from `spawn-gate.sh`, so a worker gets the **load gate**, the wall-clock watchdog and the
  walltime row; `lane.sh` and `fix-one.sh` do the same. A hand-rolled `tmux new-session … pi --model …` is what
  `spawn-gate.test.sh` calls a **"fourth, ungated launch path"** — its invoker census asserts the invoker SET as an
  equality and goes red. Measured 2026-10-19: driving the cells by raw `tmux` is how 23 lanes landed on one 8 GB box and
  the kernel killed 37 processes *and the tmux server*, losing every lane. The gate would have refused that spawn.
- ⛔ **`keys.env` IS NOT GUARANTEED TO CONTAIN AN API KEY.** Measured 2026-10-19: cell-1's file exported only
  `REPO CYC MAX_FIX MIN_SWAP_FREE PATH …` and **no provider key at all** — the lanes that worked had the key in their
  *ambient* environment (inherited from the tmux server), so a lane launched through `keys.env` alone died instantly with
  `No API key found for deepseek.` and its log stopped at the banner. Before dispatching on any box:
  ```bash
  . $HOME/keys.env; [ -n "$DEEPSEEK_API_KEY" ] && echo key-ok || echo KEY-MISSING
  ```
  and 60 s after launch check `grep -c 'No API key found' /tmp/cell-home/L-<slug>.log` — **0 is the pass condition**. A
  lane log that sits at ~5 KB without a tool call is almost always this, not a slow model.
- A 0-byte lane log with a live `bash` pane means **`pi` was killed inside the session** — check `dmesg | grep -ci 'killed
  process'` and `free -m`: that is the OOM cliff, and the fix is fewer lanes, not a restart.
- Ship a brief by base64+gzip (`printf %s '<b64>' | base64 -d | gunzip > brief.md`) — a 113 KB inline heredoc times out,
  and shell quoting inside `cloud exec` mangles multi-line text.
- Never `pkill -f` / `ps | grep` a pattern that appears in your own command line: it matches the caller. Use a bracket
  (`pi [--]model`) or ship the kill as a script file and run it detached.
- One lane = one worktree = one branch. Give the lane the exact issue number and tell it to measure before changing.
- ⛔ **A LANE LAUNCHED WITH `pi -p` CANNOT BE STEERED.** `-p` (print mode) takes its prompt from argv, runs one turn and
  exits; it does not read stdin. So `tmux send-keys -t <lane> "…new orders…"` types text that **nothing consumes** — the
  log never shows it and the lane keeps doing what its original brief said. Measured 2026-10-19: 9 lanes ordered to stop
  producing and start landing, `order-seen=0` on every one. To change what a lane is doing you must **kill the session and
  relaunch it with a new brief** — which also means a brief must be right when it is written, because there is no
  mid-flight correction available. (For a steerable session, launch interactive and dispatch with
  `tools/cmux_dispatch.py`, which confirms the message became a turn.)

## 6. Landing work from a lane — the four-step contract

The single biggest waste measured: lanes doing the work and then failing to land it. `record-review.sh` **requires
`--evidence`**, and that evidence must be a real PR comment that postdates the diff. Five steps, in this order:

```bash
scripts/record-review.sh --print-diff-hash <pr>              # 1. what the gate sees
#                                                            2. ONE fresh-context review of the diff
# 3. post the review as a comment on the PR, keep its id (REST: POST /repos/<o>/<r>/issues/<n>/comments)
scripts/record-review.sh <pr> <head_sha> clean <owner/repo> --evidence comment:<id>   # 4. bind to the head
RAIL="scripts/$(printf 'a%s' 'dmin')-$(printf 'mer%s' 'ge').sh"; bash "$RAIL" <pr>    # 5. land it
```

- `--evidence` missing ⇒ no `clean` record can be minted. A lane that skips step 3 **loops forever**: the gate says "no
  reviewers dispatched", the lane dispatches another reviewer, nothing is recorded, the gate refuses again (agent-infra#2148).
- A record for a non-current head is **refused (exit 3)**. Never `--force-stale`.
- **Never edit the PR body after recording** — it wipes the attestation.
- One reviewer child per PR; two rail attempts. A refusal while an attestation exists at the head is a **harness defect to
  record**, not a loop to retry. `queued` / `in progress` is neither a failure nor a stall.

## 7. Fleet roles and what "full capacity" means

| box | role | shape |
|---|---|---|
| cell-2 | **agent-infra / harness** | landers + harness fixes; disk-bound, ~12 lanes |
| cell-1, cell-3 | **tortoise / product** | P0/P1 product work; disk-bound on cell-1, CPU-bound on cell-3 |
| laptop | product + orchestration | the only box that can reach every channel; do not overfill it |

A dispatch decision is only honest if it names: the box's **free disk**, its **free RAM**, its **live lane count**, and the
**lane's expected cost**. If a box is not dispatching by itself and is not at capacity, that is the signal to intervene —
not a load average measured earlier.

## 8. Traps that produced wrong conclusions today

- `ls -d harness/*/ | tail -1` picks the **alphabetically last** dir, not the newest — use `ls -dt ... | head -1`.
- A readiness banner (`CELL READY`, `up`) is a claim; `git rev-parse`, `ls` of the artifact, and `record-review.sh` existing
  are facts.
- An `exec` timeout is not evidence about a box; a silent exit 0 from `cmux cloud ls` is **unreachable**, never "no fleet".
- A stale heartbeat file does not mean the loop is dead (`orch-loop.log` mtime does).
- Killing a controller is futile when launchd `KeepAlive` + a 20 s watchdog recreate it — and a lane can spawn one.
- `TERM`/`INT` traps that swallow signals leave the script running: a stop/restart appears to hang (agent-infra#2085).
- Deleting a worktree to make space must never destroy unpushed work: check `git rev-list --count @{u}..HEAD` and
  `status --porcelain` first; preserve, then remove only the regenerable parts.
