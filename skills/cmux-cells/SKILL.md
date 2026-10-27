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
updated: 2026-10-27
---

> ⛔ **This skill MUST be read in full — not skimmed.** Every section below is a measurement that cost a lost lane, a
> wasted hour, or a wrong conclusion. The traps are the content.

# Operating the cmux cloud cells

The fleet runs on the macOS laptop (launchd) plus the Linux cells (cell-1 `pi-lane-1`, cell-2 `pi-cell-2`, cell-3
`pi-cell-3`, cell-4). Cells are Linux, so **any harness change must work on both platforms** — one source of truth with a
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
| **`gh` shim** | every lane logs `#984 argv-level gh shim not found — only the string scanner is active`; the merge gate runs degraded and cannot verify the evidence it demands | **fixed in `pi-bootstrap/cell-install.sh` (agent-infra#2164, closed 2026-10-24)**: it installs the shim at `$HOME/.pi/agent/scripts/gh-shim/gh` and **fails the install** if it is missing. A manual `ln -sf … $HOME/.pi/agent/shims/gh` is a *legacy* workaround for a box installed before that — do not present it as the plan |
| **capture extension** | `capture: BLOCKED (N queued, 402 quota)` on stdout blocks turns and corrupts the bringup probe (a healthy box reports `FATAL: provider probe failed`) | move `$HOME/.pi/agent/extensions/tortoise-capture*` aside (agent-infra#2147); `TORTOISE_CAPTURE=0` does **not** disable it |

Verify activation by **artifact**, never by a banner:

```bash
for f in .pi/agent/scripts/record-review.sh .pi/agent/scripts/gh-shim/gh; do [ -e $HOME/$f ] && echo "ok $f" || echo "MISSING $f"; done
echo "scripts=$(ls $HOME/.pi/agent/scripts|wc -l) ext=$(ls $HOME/.pi/agent/extensions|wc -l) skills=$(ls $HOME/.pi/agent/skills|wc -l)"
git -C /tmp/cell-ai rev-parse --short HEAD    # the version, not the claim
```

A cell is "on main" only if `git -C /tmp/cell-ai rev-list --count HEAD..origin/main` is **0**.

## 2. Capacity is RAM and DISK, never CPU

⛔ **Corrected 2026-10-27 — the numbers below used to REFUSE healthy dispatches.** Read them before
quoting any ceiling:

| resource | cost (measured) | note |
|---|---|---|
| **analysis / doc lane** (`pi` tree: wrapper + pi + bash) | **0.19–0.23 GB** whole tree | RSS summed over the process tree, 4 lanes, cell-4, 2026-10-27 |
| **test-running lane** (pi tree + pytest workers + per-lane FalkorDB) | **~0.4–0.7 GB** peak | containers 21–149 MB each (`docker stats --no-stream`, cells 3–4, 2026-10-27); the scheduler budgets 512 MB (`ai-drainer.sh` `LANE_MEM_MB`) |
| plan each lane at | **~1 GB** (test) / **~0.3 GB** (analysis) | the PEAK, not the idle |
| worktree `.venv` | **`du` 5.6 GB, but only ~316 MB marginal** under a warm hardlinked cache — the gate reserves **6144 MB** for it | re-derived in agent-infra#2721; the old "1.1 GB" figures measured a lane's worktree *before* its venv |
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
# a JUDGEMENT AID — the gate below is the authority. The answer is HEADROOM ("more lanes"), not a ceiling:
# add it to the LIVE lane count, never read it as "this box holds N".
# bash-3.2 clean (no `case` inside $( ) — macOS /bin/bash): runnable as a script OR pasted into $().
TARGET=${TARGET:-.}                       # the worktree you are dispatching into, not /
if [ -f "$TARGET/uv.lock" ]; then TREE_MB=${TREE_MB:-350}; RESERVE_MB=${RESERVE_MB:-6144}
else TREE_MB=${TREE_MB:-64}; RESERVE_MB=${RESERVE_MB:-1024}; fi   # agent-infra lane: 48 MB tree
PER_MB=${PER_MB:-1000}                    # plan on the PEAK below; the scheduler budgets 512 (ai-drainer)
for v in "$TREE_MB" "$RESERVE_MB" "$PER_MB"; do
  [ "$v" -ge 0 ] 2>/dev/null || { printf 'seeds: non-numeric (%s) — refusing\n' "$v"; exit 0; }
done
if [ "$TREE_MB" -le 0 ] || [ "$PER_MB" -le 0 ]; then printf 'seeds: zero tree/PER — refusing\n'; exit 0; fi
free_mb=$(df -Pm "$TARGET" 2>/dev/null | awk 'NR==2{print $4}')                  # MB, no unit parsing
avail_mb=$(command -v free >/dev/null 2>&1 && free -m | awk 'NR==2{print $7}') || true   # Linux only
# an unreadable/garbage probe is NOT "zero room" and NOT room — refuse to answer (the gate's polarity)
if [ "$free_mb" -ge 0 ] 2>/dev/null; then disk_more=$(( (free_mb - RESERVE_MB) / TREE_MB ))
  [ "$disk_more" -lt 0 ] && disk_more=0 || true; else disk_more=UNREADABLE; fi
if [ "$avail_mb" -ge 0 ] 2>/dev/null; then ram_more=$(( (avail_mb - 1500) / PER_MB ))
  [ "$ram_more" -lt 0 ] && ram_more=0 || true; else ram_more=UNREADABLE; fi
more=UNKNOWN
if [ "$disk_more" != UNREADABLE ] && [ "$ram_more" != UNREADABLE ]; then
  more=$(( ram_more < disk_more ? ram_more : disk_more )); fi
printf 'more_lanes=%s (ram=%s disk=%s, target=%s)\n' "$more" "$ram_more" "$disk_more" "$TARGET"
# 0 means MEASURE BEFORE DISPATCHING. It is never "this box can do no work" — and never a licence to
# clamp the disk term to 1: a disk-zero is the state that does NOT clear by waiting (see §3).
# `free` is Linux-only; on the macOS laptop this prints ram=UNREADABLE by design — use `vm_stat` there.
```

⚠️ **WHAT THE GATE ACTUALLY REFUSES** (read 2026-10-27) — FOUR refusals, in the gate's own order (fork → disk → load):

1. **fork** — `AGENT_FORK_REFUSED`, exit **73**, and it runs **first**. A process-bound box refuses a spawn that would
   fork-bomb it; the remedy is a restart/drain, **not** waiting;
2. **disk floor** — `DISK_MIN_FREE_MB`, default **500**, exit 77;
3. **disk headroom** — `DISK-NOHEADROOM`, **the binding one**, exit 77: requires `free_mb ≥ tree + reserve`, with per-lane
   costs **350 + 6144 MB** for a target containing `uv.lock` and **64 + 1024 MB** otherwise. One spawn on a uv worktree
   needs **6,494 MB** free, so the floor is not the number that decides (agent-infra#2721);
4. **load** — `MAX_LOAD`, default `nproc × 10` (exit 75; `PI_GATE_REFUSED` 76 is translated into 75).

The creation back-pressure gate (`AGENT_LAND_BACKLOG`, exit **74**) runs last, and only for creation workers. Diagnosing a
73 as "disk or load" and waiting is the trap: it is the one refusal waiting does not clear.

**RAM is split across two instruments and neither is `spawn-gate.sh`**, which has floors only (`MIN_MEM_FREE_MB`,
default 512, in `orch-loop.sh`; `CAP_MIN_MEM_MB` in `capacity.sh`). The **scheduler** does budget per lane: `ai-drainer.sh`
uses `LANE_MEM_MB` (default **512**) against `MEM_BUDGET_PCT` (default **75**) of the pool. So there are two numbers —
scheduler 512, planning ~1000 for a test-running lane (the table above) — and this file deliberately uses the larger.
Reconcile against `docs/ops/ai-drainer.md` before raising either. Where the gate speaks, the gate is right.

`MAX_LANES` is **derived** (`2.5 × cores`) and enforced by the controller — but it knows neither disk nor RAM, so it is an
upper bound, never the answer (§7).

⛔ **DO NOT RE-INVENT THE CAPACITY GATE — `scripts/orchestrator-harness/spawn-gate.sh` ALREADY IS IT** (checked
2026-10-27). It derives `MAX_LOAD` from `nproc × 10` when unset, refuses on a non-empty disk band (`disk_free_mb` vs
`DISK_MIN_FREE_MB`/`MIN_FREE_MB`, exit 77), **refuses again on per-lane headroom** (`DISK-NOHEADROOM`, tree + reserve,
exit 77 — see above), and validates its own probes against wrap/garbage readings. Its capacity behaviour is asserted in
`spawn-gate.test.sh` (its disk, headroom and load sections); read that rather than trusting a count quoted in prose. The
failure it already names is the one worth reading: the band where `scripts/cloud-cell-supervisor.sh --check` prints
`CELL CAN RUN A CONTROLLER` while every lane spawn is refused 77. (`scripts/orchestrator-harness/cloud-cell-doctor.sh` has
no `--check` mode — that flag belongs to `scripts/cloud-cell-bringup.sh`, and the banner is printed by the supervisor's
`cmd_check`.)

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

**Dispatch through the gated path — that is the only form of this section to copy:**

```bash
scripts/orchestrator-harness/nonblocking-dispatch.sh <name> <worktree> <prompt-file>
```

It backgrounds `run_agent()` from `spawn-gate.sh`, so the worker gets the **load gate, the disk headroom gate, the
wall-clock watchdog and the walltime row**. `lane.sh` and `fix-one.sh` are the same shape.

⛔ **NEVER LAUNCH A RAW `pi`.** The block below is kept only as the shape **NOT** to write — `spawn-gate.test.sh` calls
it a **"fourth, ungated launch path"** and its invoker census asserts the invoker SET as an equality, so it goes red:

```bash
tmux new-session -d -s <slug> \
  "HOME=/tmp/cell-home bash -lc 'cd <worktree>; . /tmp/cell-home/keys.env; \
   nohup pi --model deepseek/deepseek-v4-flash --provider deepseek -p \"\$(cat <brief>)\" > /tmp/cell-home/L-<slug>.log 2>&1 < /dev/null'"
```

Measured 2026-10-19: driving the cells this way is how 23 lanes landed on one box (8 cores, **32 GB**) and the kernel
killed 37 processes *and the tmux server*, losing every lane. The gate would have refused that spawn.

- Model must be `provider/model` (`deepseek/deepseek-v4-flash`), never bare.
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
  mid-flight correction available. (For a steerable session, launch interactive and dispatch with tortoise's
  `tools/cmux_dispatch.py` — it confirms the message became a turn. That tool is not installed on the cells; there,
  use `nonblocking-dispatch.sh` and a new brief.)

## 6. Landing work from a lane — the five-step contract

The single biggest waste measured: lanes doing the work and then failing to land it. `record-review.sh` **requires
`--evidence`**, and that evidence must be a real PR comment that postdates the diff. Five steps, in this order:

```bash
scripts/record-review.sh --print-diff-hash <pr>              # 1. what the gate sees
#                                                            2. ONE fresh-context review of the diff
# 3. post the review as a comment on the PR, keep its id (REST: POST /repos/<o>/<r>/issues/<n>/comments)
scripts/record-review.sh <pr> <head_sha> clean <owner/repo> --evidence comment:<id>   # 4. bind to the head
bash scripts/admin-merge.sh <pr>                                                      # 5. land it, via the rail
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
| cell-2 | **agent-infra / harness** | landers + harness fixes; disk-bound |
| cell-1, cell-3 | **tortoise / product** | P0/P1 product work; disk-bound on cell-1, **memory-bound** on cell-3 (8 GB, 2 OOM kills measured 2026-10-27) |
| laptop | product + orchestration | the only box that can reach every channel; do not overfill it |

⛔ **TWO DIFFERENT CEILINGS — DO NOT CONFUSE THEM, AND DO NOT TREAT EITHER AS THE WHOLE ANSWER.** The owner ruled on
2026-10-17 (`docs/ops/fleet-capacity.md`) that **between boxes** dispatch is gated on capacity, not a lane count — that is
`cap_place`, and the objection is to a count standing in for capacity **across a fleet**. **Inside one box there IS a real
ceiling**: `MAX_LANES`, derived as **2.5 × cores** (`orch-loop.sh`: `10#$_NCPU * 5 / 2`, rendered into the launchd plist),
and the controller refuses at `lanes >= MAX_LANES` (`GATE_WHY=lanes=N>=max_lanes=M`). It is real — and it knows **neither
disk nor RAM**, so it is an upper bound, never the answer. The binding constraint is **free disk vs one lane's
`tree + reserve`** (§2), then free RAM against the per-lane peak, then load. So this table names a box's ROLE, never a
number of lanes.

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
- **The 900 / 3000 arithmetic is gone on purpose.** If you meet it anywhere, it is stale: it used a test-running peak as
  every lane's cost and a flat reserve that dominates a small box, and it returned "no lanes" on boxes with room. §2
  carries the measured figures, their dates, and the method.

> Continue following the workflow as mandated by this skill. Do not skip steps.
