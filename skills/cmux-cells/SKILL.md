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

The fleet runs on the macOS laptop (launchd) plus the Linux cells the provider currently allocates — `cmux vm ls` on
2026-10-27 showed **three**: `pi-cell-1`, `pi-cell-3`, `pi-cell-4`. (`pi-lane-1` is an **earlier label of the same VM now
labelled `pi-cell-1`** — `vm-efa6cc8f…`; `cloud-cell-bringup.sh:42` pairs them — a relabel, not a lost box. **cell-2** is the
one that is genuinely absent. `docs/ops/ACTIVATION-MATRIX.md` still speaks in the OLD labels (`pi-lane-1`, `pi-cell-2`), so read
it with this mapping in hand. Treat any inventory, including this one, as a reading: re-run `cmux vm ls` before acting on
it.) ⚠️ **`pi-cell-N` is the LABEL column; on the Mac every `cmux vm <verb>` that takes a machine takes the
NAME column (`vm-<hex>`; from inside a cell the peer grammar accepts the peer slug, the LABEL and the NAME alike — see §3)**
— `cmux vm stats pi-cell-4` returns a 404 whose own advice is "start a new one", a spend-flavoured remedy for a box that is
already running. Read the NAME from `cmux vm ls`. Cells are Linux, so **any
harness change must work on both platforms** — one source of truth with a platform branch, never two drifting copies.

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

`HOME=/tmp/cell-home` is mandatory — not because exec's own home is broken (measured 2026-10-27: exec runs as `cmux` with a
writable `HOME=/home/cmux`), but because **the operational layer is installed under `$CELL_HOME=/tmp/cell-home`**:
`record-review.sh`, the `gh` shim and the extensions all live under `/tmp/cell-home/.pi/agent`, so a lane launched without it
reads an empty home and silently loses the merge path. (`scripts/cloud-cell-bringup.sh` still carries an older
`/home/ubuntu` explanation — that part is stale.)

**⚠️ One thing is still missing after a verified install — plus a trap for boxes installed before the fix:**

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

## 2. Capacity is RAM and DISK — load is a distant third

⛔ **Corrected 2026-10-27 — the numbers below used to REFUSE healthy dispatches.** Read them before
quoting any ceiling:

| resource | cost (measured) | note |
|---|---|---|
| **analysis / doc lane** (`pi` tree: wrapper + pi + bash) | **0.06–0.5 GB** whole tree (a bare `pi` alone reaches ~0.28 GB) | RSS summed over each process tree, 14–22 sampled, cell-4, 2026-10-27 — a planning BAND, not a fixed cost |
| **test-running lane** (pi tree + pytest workers + per-lane FalkorDB) | **~0.4–0.7 GB** peak | a FalkorDB/PG sidecar is **~5–105 MB in a normal sample**, with **peaks seen at 207.9 MB (cell-3) and 313 MB (cell-1)** — `docker stats --no-stream`, per sidecar container, cells **1, 3 and 4**, 2026-10-27 (the 313 MB peak is **cell-1's**, so a cells-3–4 re-sample will not reproduce it); plan on the peak, not on ~150 MB, and re-measure per box. The scheduler budgets 512 MB (`ai-drainer.sh` `LANE_MEM_MB`) |
| plan each lane at | **~1 GB** (test) / **~0.5 GB** (analysis) | the PEAK, not the idle |
| worktree `.venv` | **`du` 5.6 GB, but only ~316 MB marginal** under a warm hardlinked cache — the gate reserves **6144 MB** | the figures are `spawn-gate.sh`'s own measurement block (`du` 5,625 MB, ~316 MB marginal, RESERVE 6144); agent-infra#2721 is the incident that made the gate reserve it. #2159 recorded ~1.1 GB per **venv-bearing** worktree (134 MB for one without) — all right about different quantities |
| CPU | load 4.3 with 23 lanes | almost never the limit — but the gate still refuses at `MAX_LOAD` (below) |

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
# the gate's own override names are DISK_LANE_TREE_MB / DISK_LANE_RESERVE_MB — if you set those on a cell,
# set these to the same pair, or the aid and the gate disagree by construction. EXCEPT 0: the gate honours
# an explicit 0 and this aid refuses it on purpose (a zero tree makes the ratio meaningless, not infinite)
if [ -f "$TARGET/uv.lock" ]; then TREE_MB=${TREE_MB:-350}; RESERVE_MB=${RESERVE_MB:-6144}
else TREE_MB=${TREE_MB:-64}; RESERVE_MB=${RESERVE_MB:-1024}; fi   # agent-infra lane: 48 MB tree
PER_MB=${PER_MB:-1000}                    # plan on the PEAK below; the scheduler budgets 512 (ai-drainer)
for v in "$TREE_MB" "$RESERVE_MB" "$PER_MB"; do
  [ "$v" -ge 0 ] 2>/dev/null || { printf 'seeds: non-numeric (%s) — refusing\n' "$v"; exit 0; }
done
if [ "$TREE_MB" -le 0 ] || [ "$PER_MB" -le 0 ]; then printf 'seeds: zero tree/PER — refusing\n'; exit 0; fi
free_mb=$(df -Pm "$TARGET" 2>/dev/null | awk 'NR==2{print $4}')                  # MB, no unit parsing
avail_mb=$(command -v free >/dev/null 2>&1 && free -m | awk 'NR==2{print $7}') || true   # Linux only
# an unreadable/garbage probe is NOT "zero room" and NOT room — this aid ABSTAINS. That is a DELIBERATE
# DEPARTURE from the gate, which fails OPEN on an unreadable probe (it admits and WARNs): an aid with no reading
# should not answer at all.
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
# EXIT STATUS: every path exits 0, including the two `seeds:` refusals and the UNKNOWN/UNREADABLE abstentions.
# The ANSWER is the printed `more_lanes=` value — read stdout, never the exit code (a caller that tests `$?`
# sees a refusal as success).
```

⚠️ **WHAT THE GATE ACTUALLY REFUSES** (read 2026-10-27) — **brief admission answers first**, then the capacity refusals in
this order (fork → disk → load). The brief gate (`AGENT_BRIEF_REFUSED`, exit **80**) fires **before fork** and before any
disk or load reading (agent-infra#2258), and a **brief refusal is deterministic**: it cannot clear by waiting, and
re-dispatching the same brief on another box refuses there too — re-author the brief, do not retry. (A missing or
incomplete validator returns **78** instead — `CANNOT VERIFY`; that one *is* repairable, by fixing the install rather than
the brief.) The gate's own comments disagree about the order — the comment above `AGENT_DISK_REFUSED` calls the disk refusal
"evaluated FIRST" (search that phrase) while the fork-gate block says "fork -> disk -> load"; cite the phrase, not a line
number, because these anchors moved within hours of being written. The exit codes and the code agree with the second: 80 before
73 before 77.

1. **fork** — `AGENT_FORK_REFUSED`, exit **73**. A process-bound box refuses a spawn that would fork-bomb it; the remedy is
   a restart/drain, **not** waiting;
2. **disk floor** — `DISK_MIN_FREE_MB`, default **500**, exit 77;
3. **disk headroom** — `DISK-NOHEADROOM`, **the binding one**, exit 77: requires `free_mb ≥ tree + reserve`, with per-lane
   costs **350 + 6144 MB** for a target containing `uv.lock` and **64 + 1024 MB** otherwise. One spawn on a uv worktree
   needs **6,494 MB** free, so the floor is not the number that decides (agent-infra#2721);
4. **load** — `MAX_LOAD`, default `nproc × 10` (exit 75; `PI_GATE_REFUSED` 76 is translated into 75).

The creation back-pressure gate (`AGENT_LAND_BACKLOG`, exit **74**) runs last, and only for creation workers. **Only
`MAX_LOAD` (75) clears because the box quietens on its own.** The rest clear when their **resource is released** or their
**input changes** — a lane finishes or drains (73), disk is reclaimed or a lane finishes (77), the brief is re-authored (80),
the install is repaired (78 — which also covers a bad invocation: an `unknown role` is a typo in the call, not a broken
install, so read the emitted line), the repo's open-PR queue actually lands (74). **74 has three arms and they do not share a
remedy:** the ratio (`land_backlog_verdict` rc=1 — repo-wide, so land the queue and re-dispatching it elsewhere refuses too);
the slug (`land_backlog_repo` cannot derive one: that worktree's `origin` is not an `owner/name` slug, **or `repo-slug.sh` is
missing** — per-worktree or an install fault; `land_backlog_verdict` carries a **second copy** of that message, `UNREADABLE
repo … (not an owner/name slug)`, emitted by its OWN slug-shape check and **unreachable through `run_agent`** — the slug is
derived first and refuses there — so it is the test seam's twin of this arm, same remedy, and it is not a `gh` fault); and
**rc=2, a read that did not resolve** (`UNREADABLE open-PR count` / `UNREADABLE landing rate` — each carries "(the gh read
failed)"; a third line, `UNREADABLE landing counts for …`, guards counts that do not parse, but `land_backlog_lands` returns
1 on any read failure and otherwise prints two integers it built itself, so that guard **cannot fire today** — do not
diagnose a 74 as a parse problem) — box-local, so fixing that box's gh chain clears them and **a re-dispatch to a healthy box does clear them**, even
though the gate prints the ratio remedy text for it too. A P0-blocker or a base-red repair is **exempt by evidence** and dispatches under the hold — **when the exemption read
itself succeeds**; on the rc=2 arm it fails with the same gh chain, so a P0 *is* held until the chain is fixed (the
gate's refusal line says so). **Idling on its own changes none of them**: for 73
and 77 the release *is* a lane draining, so the drain has to actually complete rather than just pass time — which is why the
gate's own two messages read "does NOT clear by waiting" (fork) and "This is NOT a load refusal: waiting does not clear it"
(headroom) while both still offer "or let its lanes drain" / "or let a lane finish". So diagnosing a 73, 77, 74, 78 or 80 as
"the box is busy" and idling is the trap.

**RAM is read by two other instruments — `spawn-gate.sh` reads NO memory at all.** The two floors live in `orch-loop.sh`
(`MIN_MEM_FREE_MB`, default 512) and `capacity.sh` (`CAP_MIN_MEM_MB`, 512). The **scheduler** does budget per lane: `ai-drainer.sh`
uses `LANE_MEM_MB` (default **512**) against `MEM_BUDGET_PCT` (default **75**) of the pool. So there are two numbers —
scheduler 512, planning ~1000 for a test-running lane (the table above) — and this file deliberately uses the larger.
Reconcile against `docs/ops/ai-drainer.md` before raising either. Where the gate speaks, the gate is right.

`MAX_LANES` is **derived** (`2.5 × cores`) when nothing sets it — **and repaired to the derivation when a set value is not a
valid limit** (`is_limit`) — and on every cell something does set it: `keys.env` pins `export MAX_LANES=20`, and a valid
explicit value wins over the derivation. The controller still enforces it, but the number knows
neither disk nor RAM, so it is an upper bound, never the answer (§7).

⛔ **DO NOT RE-INVENT THE CAPACITY GATE — `scripts/orchestrator-harness/spawn-gate.sh` ALREADY IS IT** (checked
2026-10-27). It derives `MAX_LOAD` from `nproc × 10` when unset, refuses on a non-empty disk band (`disk_free_mb` vs
`DISK_MIN_FREE_MB`/`MIN_FREE_MB`, exit 77), **refuses again on per-lane headroom** (`DISK-NOHEADROOM`, tree + reserve,
exit 77 — see above), and validates its own probes against wrap/garbage readings. Its capacity behaviour is asserted in
`spawn-gate.test.sh` (its disk, headroom and load sections); read that rather than trusting a count quoted in prose. The
failure it already names is the one worth reading: the band where `scripts/cloud-cell-supervisor.sh check` prints
`CELL CAN RUN A CONTROLLER` while every lane spawn is refused 77. (`scripts/orchestrator-harness/cloud-cell-doctor.sh` has
no `--check` mode; `--check` is `scripts/cloud-cell-bringup.sh`'s flag, while the banner is the supervisor's `check`
subcommand.)

The formula above is therefore a **diagnostic, not an implementation**: if a number disagrees with the gate, the gate is
right and the number is a curiosity. Any new refusal belongs inside `spawn-gate.sh` with a test — never in a brief, a
wrapper, or a skill.

**Disk and RAM resize draw on a shared plan pool, and the pool is the total ceiling — not the per-VM shape.** Measured
2026-10-19: `cmux vm resize <cell-3> --memory 12` was refused with *"only 4 vCPUs and 8 GiB are free in your plan pool"*
while three VMs were running. Disk grew twice (+8 GiB each) but **RAM had 8 GiB left in total**. So:

- the fleet's real RAM ceiling is the **plan pool**, and it is **fully** allocated (measured 2026-10-27: `usedMemoryMb`
  40,960 of 40,960, `usedVcpus` 20 of 20) — per-cell memory cannot be raised by wanting it;
- a cell's lane ceiling must be computed from **its current free RAM**, and never assumed to be expandable;
- to raise one cell's memory you must first shrink or pause another box — that is an owner-level capacity decision, not a
  dispatch-time workaround;
- disk used to be the cheaper lever (separate pool, grew on demand) — but all three boxes are now at the per-VM cap
  (`maxDiskMb` 131,072 = 128 GB each, measured 2026-10-27), so **reclaim is the only lever left** until the plan changes.

## 3. "Unreachable" is a claim about the CHANNEL, not the box

| read | means |
|---|---|
| `cloud exec` timeout / 502 / silent empty | **the channel failed. Not the box.** Retry minutes apart |
| `cmux vm ls` → `running` | the provider sees the VM alive |
| **`cmux vm stats <vm>`** | the provider's own liveness read, and the cheapest — `CPU n% · Mem x/y GB · Disk a/b GB`. Two caveats that matter: it cannot tell you the guest is **unusable** (a full guest still reads `awake` while every `exec` times out), and its `Disk a` term is the guest's `df` **used**, in GiB — `df -Pm` reports MiB, so divide by 1024 to compare — while `/b` is the **provisioned** size, not `df`'s total. Compare `used`; take headroom from `df`'s `Available`. The provider side can also lag **high** after a reclaim, so if the two disagree, trust `df -Pm /`. Pair it with `vm terminal read` — **the row below** |
| `vm terminal read` → `No space left on device` | the guest is alive and full |

A **disk-full** cell behaves exactly like a dead one: the control agent cannot write its socket, so every `exec` times out
while the provider insists `running`. Measured 2026-10-19: cell-3 sat at 29.9/32 GB, CPU 77%, exec failing for an hour,
having submitted nothing for 141–226 minutes.

Recovery ladder, cheapest first. **Establish a channel before anything else.** Two of the three readings below are *not*
channel verdicts — the first one **is**, and it is listed with them only to say what it settles:

- **A real refusal kills steps 1-2 outright**, whatever its cause — that one *is* a verdict. The channel that then answers is
  `cmux vm exec <vm> -- <cmd>` (it needs no `cmux-tui` daemon) — **unless `/` is nearly full**: a guest at 93 % has already
  been measured with `exec` failing for an hour (above), so treat a nearly-full box as no-channel, not only a 100 % one. With
  **both** of those gone, the surface left is the **display** the same render prints (`cmux surface open
  <vm>/display/display:1` — a noVNC console that was live on cell-4 while its `cmux-tui` port was refused; that is **Mac-CLI
  syntax**, and from inside a cell `cmux surface …` is `unknown resource scope "surface"` — the guest-side equivalent is the
  `cmux layout apply` noted below — **and only where the guest CLI runs at all: on the shape described two bullets down,
  where it does not, `tmux` is what starts a worker, not any guest `cmux` verb**). Beyond that the
  levers are provider-level (step 3) and owner-level (a plan change or a **recreate** — and a recreate is the one step here
  that can destroy unpushed work, so run the work-at-risk check below first).
- **`cmux vm tree` printing `(no terminals)` is not a reading of the box** when the same render shows a link error or a null
  workspace list — cell-4 today reports `link_error: "The Cloud hub could not reach the VM port: connection refused."` and
  `remote_workspaces: null` while its own registry holds **945** terminals. `null` means *unknown*, not *zero*: fall back to
  `exec` — and note that `--refresh`, which the tool's own render suggests, **can itself time out** (measured: 120 s, exit 1, no
  catalog at all on a box whose link is refused) and reports "VM request timed out". That is the channel failing, not the box.
  Only a **connected** link that genuinely enumerates zero terminals justifies creating one
  (`cmux surface new-terminal --machine <vm> --no-open -- <cmd>` — **Mac-CLI syntax**; the CLI that ships INSIDE a cell has no
  `surface` scope at all (`cmux surface ls` → `cmux: unknown resource scope "surface"`), and the guest-side equivalent is
  `cmux layout apply` with a one-surface layout, which produces the same artifact — a shell in the cwd plus a command typed
  into it. `scripts/orchestrator-harness/worker-terminal.sh:30-32` carries that correction with its own measurement).
  ⛔ **The guest-CLI advice in this bullet and every bullet above assumes the guest CLI RUNS AT ALL, and on a measured cell shape it does
  not:** `cmux: cmux-tui daemon binary not found at /root/.cmux/bin/cmux-tui` — the `cmux-tui` symlink dangling and no daemon
  process (agent-infra#2368; the same measurement as `worker-terminal.sh:168-171` and `scripts/orchestrator-harness/README.md:568`).
  On such a box every guest verb below is unavailable, and that error reads as a broken box rather than the known install shape
  it is — the surface that still works is **`tmux`**, started with an EXPLICIT environment (`HOME` pointing at the HOME that
  holds the credential, that HOME's `keys.env` sourced when present, `O` exported — `wt_launcher`'s `tmux` arm is the
  reference); README:568 records it as the ONLY surface that can start a worker there.
- **A usage error is not a channel verdict, and neither is a wrong-but-valid argument.** From the Mac, `cmux vm tree` with
  **no machine** prints the whole fleet; `terminal read/send` without an id prints the usage block. And because §7's table is
  keyed by LABEL, `cmux vm tree pi-cell-4` renders **`No cloud machines. Try: cmux vm new`** from the Mac — a false empty, not
  a missing box — so use the NAME. **From inside a cell — when the guest CLI runs at all; see the #2368 ⛔ above — the grammar is the PEER one and it answers the same arguments
  differently:** `cmux vm` there carries only the remote verbs (`ls`, `connect`, `exec`, `tree`, `terminal`,
  `send`/`send-key`/`read-screen`, `workspace`, `push`, `agent`, `layout`, `env`, and the mirrored resources) — `resize`,
  `pause`, `resume` and `stats` are **`unknown vm subcommand`**, so step 3, step 4 and every `stats` reading in this file have
  to be run **from the Mac**; a missing argument prints `usage: cmux vm tree <machine> [args…]`; and `<machine>` is matched
  against `cmux self peers`, whose entries carry all three names side by side — `name` (the peer slug, e.g.
  `early-ivory-moth`), `display_name` (the LABEL) and `provider_vm_id` (the NAME) — so **any** of the three is accepted, and a
  link that cannot be established renders `link to '<arg>' exited; see <log>`. ⛔ **Three renders from a cell are not verdicts
  about a box:** `no link for machine '<arg>': reflection lists no such machine; reachable machines: <slug>, <slug>` means the
  argument matched **nothing** — and the box you are on is not its own peer, so `cmux vm tree <this box's LABEL>` lands here,
  a correct argument on the wrong target; `terminal read` with no id prints `a terminal id is required (see cmux terminal
  list)` while `terminal send` with no payload prints `give text and/or --keys (e.g. --keys enter)` — one render per verb, not
  a usage block.

And if the volume that is full is the **`cmux-tui` state volume** described under step 5, read that paragraph before the steps
below — **grow the loop file first** (cheapest, destroys nothing); the reset there is the owner-level fallback. None of the
reclaim steps below touch it.

1. `cmux vm terminal read <vm> <terminal-id>` — get terminal ids from `cmux vm tree <vm>`. The screen tells you the truth.
2. `cmux vm terminal send <vm> <term-id> '<command>' --keys enter` — runs a command when `exec` cannot. The **send** verb
   prints nothing back; read the result with `vm terminal read` (step 1).
3. `cmux vm pause <vm>` then `cmux vm resume <vm>` — provider-level reset. Fixes a wedged agent, does **not** fix a full disk.
4. **`cmux vm resize <vm> --disk <GiB>`** — grows in place, 4 GiB steps, **cannot shrink**, and only helps while the VM is
   **below `maxDiskMb`**. Measured 2026-10-27, all three boxes are AT the per-VM cap (128 GB of a 131,072 MB ceiling), so
   today this lever refuses: the remedy for a full guest is step 5 (reclaim), and real growth needs a plan change
   (owner-level). When a box *is* below the cap, 32 → 40 GiB has made a dead-looking box respond immediately.
5. Then, inside: kill stale lanes, `git gc --prune=now` on the clones, clear caches, re-run the update.
   ⚠️ **`/` is not the only volume that fills.** On a cell also read the **`cmux-tui` state volume** — a loop mount of
   `cmux-tui-state.ext4` on **`/home/cmux/.local/state/cmux-tui`**. Use that **absolute** path: a cell's login shell may have
   `HOME=/tmp/cell-home`, where a plain *directory* of the same name exists, so `df -Pm ~/.local/state/cmux-tui` answers about
   **`/`** and reports a healthy percentage — a false PASS on exactly the box you are checking. If the path moves, derive it:
   `df -Pm "$(mount | awk '/cmux-tui-state/{print $3}')"`. It fills independently of `/` and holds the terminal state the
   ladder depends on — `df` reported **99 % capacity, 947 MB of 974 MB used, 11 MiB free** on cell-3 (measured 2026-10-27,
   while `/` was at 60 %), the consumer being a `workspace-registry.sqlite3` of ~900 MB in that volume's `sessions/`. This
   volume moves — observed 31 → 11 MiB free within a single day — so **re-read it**; do not trust the figure above. None of
   the reclaim steps above touch it, and **no `cmux vm` verb resizes it** — it is a per-box loop file (`cmux-tui-state.ext4` —
   974 MB on cell-3, 3,996 MB on cell-4). **Two levers exist, and growing the file comes first because it destroys nothing.**
   It costs space from `/` (read `df -Pm /` first — cell-4 had 41 GB free at 66 % when this was measured, cell-3 60 %), and it
   runs **online**, so the daemon keeps running and the box keeps its terminal inventory:
   `sudo truncate -s +2G /var/lib/cmux/cmux-tui-state.ext4` → `LD=$(sudo losetup -j /var/lib/cmux/cmux-tui-state.ext4 | cut
   -d: -f1) && sudo losetup -c "$LD"` → `sudo resize2fs "$LD"` → re-read `df -Pm /home/cmux/.local/state/cmux-tui`.
   The mechanism is the kernel's on-line ext3/ext4 resize (`man 8 resize2fs`), and `losetup -c` is the separate step that makes
   the loop device's new size visible to it (`man 8 losetup`: `-c, --set-capacity`); verified on pi-cell-4 (2026-10-27) on a
   scratch 64 → 96 MB loop file, which `df` read as 56 → 88 MB **while mounted**. ⚠️ **Not yet run against this volume
   itself** — and the failure this recipe can silently have is NOT a refusal: with the backing file grown but `losetup -c`
   skipped, `resize2fs` **exits 0** and prints **“Nothing to do!”** while the device is still the old size. So re-read
   `df -Pm /home/cmux/.local/state/cmux-tui` and require it to MOVE: an unchanged figure means the device size was not
   refreshed, so re-run `losetup -c` and then `resize2fs` — and only if it still will not grow, or the daemon stops
   answering, stop there and fall back to the reset. A **reset** is the owner-level action, and it is
   not just an unlink: the `cmux-tui` daemon holds that registry **open** (6 fds on cell-3 — 4 read-write, one of them the
   `-shm`, and 2 read-only; *any* of them pins the inode), so deleting the file frees nothing until those fds close. ⛔ **And stopping it is not a
   small act:** the unit is `KillMode=control-group`, so `sudo systemctl stop cmux-tui-daemon.service` SIGTERMs **every process
   in it** — and it needs `sudo` (an unprivileged `systemctl stop` is "Access denied"). That cgroup held **45 processes at zero
   lanes and 124–207 with the box full** on 2026-10-27 (re-counts since: 30–38, so it moves with the lanes) — **re-count first** with
   `cat /sys/fs/cgroup/system.slice/cmux-tui-daemon.service/cgroup.procs | wc -l` (there is no `-p Tasks` property; `TasksCurrent`
   counts *threads* — 315 vs 35 processes on cell-3 — so do not substitute it). What it holds is not all lanes: on cell-3 about
   two thirds were orphaned `redislite` sidecars reparented to `ppid 1` from **dead** worktrees, the rest the daemon, one live
   lane and its `pytest`. So read the number as "open each one before you stop" — the ones you cannot re-create are the lanes.
   You are also deleting the box's **terminal inventory** — the registry that steps 1-2 are the channel *through* (the display is
   `cmux-desktop.service`, its own cgroup, and outlives the daemon) — so afterwards `exec` or the console is the only way back.
   Run the work-at-risk check below across every repo on the box first, and list the registries you expect to delete
   (`ls -d /home/cmux/.local/state/cmux-tui/sessions/*/workspace-registry.sqlite3*` — with more than one session dir,
   deleting one under-reclaims while `df` still shows an improvement). Then: `sudo systemctl stop` the unit and **confirm it actually stopped before deleting
   anything** — `systemctl is-active cmux-tui-daemon.service` must read `inactive` or `failed`; if it still reads `active`, stop
   there, because a denied `sudo`, a non-interactive lane, or `Job for … canceled` leaves the daemon holding the very fds this is
   for: the unlink frees nothing, `df` does not move, and the box loses its terminal inventory anyway. Only then delete every
   match of that glob — the `-wal` is a separate ~43 MB file and one of the pinned fds, so it goes too and regenerates smaller —
   `sudo systemctl start` it, and check **both** `systemctl is-active --quiet
   cmux-tui-daemon.service` **and** a fresh registry under `sessions/` **and** the `df` you came for — `df` alone cannot
   tell "reclaimed" from "reclaimed and now dead", and a failed start is the moment to escalate, not to recreate. A **recreate**
   is the bigger hammer and takes the whole guest: every worktree (the unpushed commits that check exists for), `keys.env`, the
   harness pin, `orchestrator/logs` + `orchestrator/state` (`merge-*.log`, `orch-loop.log`, the `state/` series), **the
   `orchestrator/*.txt` ledgers that sit directly under it** — `dispatched.txt`, `landed.txt`, `checked.txt`,
   `candidates.txt`: `install.sh:649-650` puts them BESIDE `logs/` and `state/` and `wip/`, not inside them — `:650`
   creates `candidates.txt`, `dispatched.txt` and `checked.txt`, and `install.sh` never creates `landed.txt`: that one
   arrives from `refresh-candidates.sh` (`:2951`), on any pass that gets that far — so a check that reads only `state/`
   and `logs/` misses the queue and landing ledgers — and **`orchestrator/wip/`**, the cap-killed lanes' dirty-work captures.

## 4. Liveness of a LANE, and the reaping rule

A lane's log **mtime** is the strongest *transcript-derived* signal a **harness lane** has — those run `pi -p
--no-session` (`spawn-gate.sh`, `lane-exec.sh`, `merge-one.sh` all pass it), so a lane leaves no `.jsonl`. Other `pi` on a
cell (interactive sessions, `task` children) **do** write `~/.pi/agent/sessions/*/*.jsonl` — and the count depends on WHICH home
you count (`/home/cmux` and `$CELL_HOME` held very different populations, with very different newest-mtimes, on the same box) — so never conclude "no transcript exists on a cell"; conclude "no
transcript exists *for this lane*". mtime is **necessary, not sufficient**: pair it with a CPU delta (reaping gate 1) and
an ancestry check. Size alone is not a signal, and a spinner is not.

- **0-byte lane log** = the lane could not start (usually disk full). It reads as "quiet", not broken — always check.
- A *thinking* lane and a dead one are indistinguishable **by activity readings** — zero CPU delta, frozen mtime, no size
  change. Only the **length** of the quiet window separates them, which is why the reaping gate needs a zero-CPU window
  **and** a 2 h idle bound before it acts. A live `pi` row proves **existence**, never progress.

Reap only when **all three** hold (prose → code: agent-infra#1244, #2163):

1. zero CPU delta over a sample window, summed across the wrapper **and every descendant**;
2. **no human/terminal ancestor** — walk the chain to the top; `ppid 1` proves nothing;
3. stale: log untouched ≥ 2 h, **or** no log at all **and** up ≥ 12 h.

⛔ **Never treat "no log found" as "stale."** A first dry run flagged 69 lanes and would have killed a 7-minute-old lane,
because the worktree slug parsed from shell text (`ciwatch\012[`) matched nothing. An absent artefact fails closed.

Also: `ps -eo args | grep -c '[p]i --model'` returns **0 on a box with `pi` live** — and not because of flag order. (Unbracketed, that pattern returns **1**: the grep's own argv contains it — the self-match trap §5 states as "never
`pkill -f` / `ps | grep` a pattern that appears in your own command line".)
`pi` is a Node script that **rewrites its process title**, so every live `pi` shows `args` = `pi` alone (`/proc/<pid>/cmdline`
is `pi` + NULs). The only rows carrying `--provider … --model …` are the launcher wrappers — **never a `pi` row** — so
"fixing" that pattern's flag order counts **wrapper shells**, not lanes. Enumerate with
`ps -eo comm= | grep -c '^pi$'` (or `lane-reap.sh`'s census): a low count is not a quiet box, and a high one is not lanes.
A box's `dmesg | grep -ci 'killed process'` is worth reading beside that — as context, never as a gate: the reaping gate
below decides on a CPU delta, ancestry and log staleness, and reads no OOM count at all.

## 5. Dispatching a lane

**Dispatch through the gated path — that is the only form of this section to copy:**

```bash
scripts/orchestrator-harness/nonblocking-dispatch.sh <name> <worktree> <prompt-file>
```

It backgrounds `run_agent()` from `spawn-gate.sh`, so the worker gets the **load gate, the disk headroom gate, the
wall-clock watchdog and the walltime row**. `lane.sh` and `fix-one.sh` are the same shape.

⛔ **NEVER LAUNCH A RAW `pi`.** The block below is kept only as the shape **NOT** to write — `spawn-gate.test.sh` calls
"a fourth launch path nobody routed", and its invoker census asserts the invoker SET as an equality. Note the guard's
population: it scans `git ls-files 'scripts/*'` and **skips `*.md`** — so this block cannot red it from here, and a lane
brief cannot either; only a `.sh` under `scripts/` can. The hazard is copy-paste, not CI:

```bash
tmux new-session -d -s <slug> \
  "HOME=/tmp/cell-home bash -lc 'cd <worktree>; . /tmp/cell-home/keys.env; \
   nohup pi --provider deepseek --model deepseek-flash -p \"\$(cat <brief>)\" > /tmp/cell-home/L-<slug>.log 2>&1 < /dev/null'"
```

Measured 2026-10-19: driving the cells this way is how 23 lanes landed on one box (8 cores, **32 GB**) and the kernel
killed 37 processes *and the tmux server*, losing every lane. The gate would have refused that spawn.

- Model form is split: a launch with no `--provider` needs `provider/model` (`deepseek/deepseek-v4-flash`), while the
  harness passes `--provider` and a bare `--model` (`deepseek-flash`) as two separate halves. A bare `--model` with no
  provider falls back to the wrong provider.
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

The shape below is durable; the **numbers are a reading** — re-read `cmux vm stats` (RAM) and the guest's own `df -Pm /` (disk) at
dispatch time, because both move.

| box | role | shape (measured 2026-10-27; re-read it) |
|---|---|---|
| `pi-cell-1` | product work | 16 GB / 8 vCPU / 128 GB — the **same shape as cell-4**, and **activated in the operative home** (`/tmp/cell-home`: `record-review.sh` + the `gh` shim, merge lanes ran on it 2026-10-27). Its `/home/cmux` home has **no `gh` shim**, so check which `HOME` a lane will get before expecting it to land |
| `pi-cell-3` | product work | 8 GB RAM / **4 vCPU** / 128 GB — the fleet's lowest-core box, but the **same pinned `MAX_LANES=20` as the 16 GB ones** (the `keys.env` pin, §7 below): 20 is twice the core-derived 10, on a box §2's arithmetic puts nearer 6 lanes and whose own aid now answers 2–3. It has OOM-killed too (`dmesg`: 2), so **§2's rule is the same as cell-4's: reserve UP, fewer lanes** |
| `pi-cell-4` | product + CI-cost work | 16 GB / 8 vCPU / 128 GB — the current default dispatch target, and **the box with the most OOM kills of the three (5)**: per §2 that means its reserve goes UP, i.e. fewer lanes here, not more |
| laptop | product + orchestration | the only box that can reach every channel; do not overfill it |

⛔ **TWO DIFFERENT CEILINGS — DO NOT CONFUSE THEM, AND DO NOT TREAT EITHER AS THE WHOLE ANSWER.** The owner ruled on
2026-10-17 (`docs/ops/fleet-capacity.md`) that **between boxes** dispatch is gated on capacity, not a lane count — that is
`cap_place`, and the objection is to a count standing in for capacity **across a fleet**. **Inside one box there IS a real
ceiling**: `MAX_LANES` — `2.5 × cores` when unset (`orch-loop.sh`: `10#$_NCPU * 5 / 2`; **on the laptop it is rendered into the
launchd plist** by `install.sh` from `scripts/orchestrator-harness/launchd.plist.template`'s `__MAX_LANES__`), **but the cells pin it** (`keys.env`:
`export MAX_LANES=20` — operator-pushed, so re-read it), and all three enforce 20 today regardless of core count:
cell-3 (8 GB, 4 vCPU) and cell-4 (16 GB, 8 vCPU) both refuse at `lanes >= 20` (`GATE_WHY=lanes=N>=max_lanes=M`). That is
exactly why the number cannot be trusted as capacity — on cell-3 it admits 20 lanes into 8 GB. It is real — and the *number* knows
**neither disk nor RAM**. The controller's own refusals (`mem_avail <= MIN_MEM_FREE_MB`, default 512; the swap gate, which
arms only when RAM is tight; and the load gate) sit in the same `GATE_WHY` chain — but they are floors and gates, **not a
per-lane budget**, so `MAX_LANES` remains an upper bound rather than the answer. The binding constraint is **free disk vs one lane's
`tree + reserve`** (§2), then free RAM against the per-lane peak, then load. So this table names a box's ROLE, never a
number of lanes.

⚠️ **`docs/ops/fleet-capacity.md` states the contrary twice** — `:157` *"there is deliberately no lane ceiling
tied to cpu count"*, and `:283` restating it as "§4's ruling" (the doc's own cross-reference is stale: that text sits at
`:157`, inside §5) — while the code has the 2.5× rule. **Two recorded positions, unresolved** — this skill reports what
the code does and does not claim the doc is wrong. Whoever settles it should mark the resolution `OVERRIDES:` in the doc:
silently letting a reader pick one is how a ruling gets tidied away.

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
- Deleting a worktree to make space must never destroy unpushed work, and the guard has to **read the right trees, in a
  population sized to what you are destroying, and fail closed.** Six traps, each measured on a cell:
  - `git -C "$wt" rev-list --count '@{u}..HEAD'` **exits 128 with empty stdout** on a branch with no upstream — often the
    branch holding the unpushed work — so an error is UNSAFE, never clean.
  - **`--not` negates every revision after it**, so `rev-list --count --not --remotes HEAD` counts nothing and prints `0` for a
    worktree that has unpushed commits (measured `0` as written, `1` corrected, same tree). Positive end first.
  - **`awk '{print $2}'` truncates a path containing a space** — and if another worktree exists at the truncated path the guard
    measures *that* tree and prints a clean line **twice**, saying nothing about the real one. Read the porcelain stream
    (`sed -n 's/^worktree //p'`, then `while IFS= read -r`), never a field.
  - **A pipeline ending in `wc -l` (or `grep -c`) cannot fail**, so `d=$(… | wc -l) || d=UNKNOWN` never fires and a *failed*
    `git status` prints `dirty=0`. Test `git status` itself, then count.
  - **The population depends on the destruction.** Deleting a *worktree* needs its repo's trees; a **recreate** or the
    `cmux-tui` reset takes the whole guest — on cell-3 that was **five repos**, with unpushed commits in trees outside `$REPO`. Count them,
    never quote a count: the tree total moved 22 -> 29 within a day of readings, so a number written here becomes a wrong
    number that the next reader plans against. ⛔ **The fifth member is the ai-drainer's SEED_REPO, and it is not necessarily where the
    documentation says.** `ai-drainer.sh` creates `$AI/wt-drainer-<lane>` with `git -C "$SEED_REPO" worktree add` (search
    that phrase; `AI` defaults to `$HOME/orchestrator-ai`), and `install-drainer-timer.sh:72` defaults
    **`DRAINER_SEED_REPO`** to `$HOME/agent-infra-main` at **install** time — the unit-side name `SEED_REPO` is only what the
    template renders that value into (`:129`), so exporting `SEED_REPO` yourself and re-running the installer changes nothing. ⛔ **Do not carry a value from this page: the unit itself moves.** The
    template always renders the knob (`templates/systemd/eldato-ai-drainer.service:36` → `Environment=SEED_REPO={{SEED_REPO}}`),
    so the value in force is a `systemctl cat eldato-ai-drainer.service` reading — and on `pi-cell-4` the **same box gave two
    different answers the same day**: an earlier reading had a wrapper (`ExecStart=/bin/bash $CELL_HOME/run-ai-drainer.sh`,
    whose own `SEED_REPO=/tmp/cell-ai-main`) with **no** `Environment=SEED_REPO=` at all, while the 2026-10-27 14:08Z reading
    had `ExecStart=/bin/bash /home/cmux/agent-infra/scripts/orchestrator-harness/ai-drainer.sh` with
    `Environment=SEED_REPO=/home/cmux/agent-infra` — the unit had been reinstalled between the two, and
    `$CELL_HOME/agent-infra-main` does not exist in either. So **read it, then derive the seed checkout from the trees** —
    `git -C <any $AI/wt-drainer-*> rev-parse --git-common-dir` names the repo that owns them (at 14:08Z it answered
    `/home/cmux/agent-infra/.git`, the unit's value, not the wrapper's). Naming a
    `wt-drainer-*` path itself *does* work (`git worktree list` inside a linked checkout lists the whole repository,
    measured) — the reason not to is that `ai-drainer.sh` **reaps** those trees as soon as a lane dies (`_rm_wt`,
    `_reap_leftovers`), so a path named now is gone later, and a missing path turns that repo into an `AT-RISK-UNKNOWN`
    exit 1 instead of a reading. And `HEAD` is not the box's work: a local branch that no worktree holds as `HEAD` dies in a
    recreate too — the block's `BRANCH-AT-RISK` lines are that reading, so count them there, never from a number here.
  - **`git status --porcelain` omits ignored state**, so the block reports it in a third column: the ignored paths **inside
    each worktree of `$REPO`** (`.venv/`, `__pycache__/`, `.worktrees/`, caches). An ignored **count** never moves the exit
    code (an unreadable one sets `1`, like every other UNKNOWN), so a `0` never means "nothing here matters" for a recreate.
    ⛔ **The two things a recreate actually destroys are in no worktree at all**: `keys.env` and `orchestrator/{state,logs}/`
    live in `$CELL_HOME`, which is not a git repo (`git check-ignore` in the cell repos returns nothing for `keys.env`), so no
    `!!` line can ever report them and `ignored=0` says nothing about them. The guest block checks those separately, and
    their **presence sets `2`** — a printed `BOX-AT-RISK` with `rc=0` would be the false PASS this section exists to prevent.
  Run it as a loop over the stream, and let the **exit status** carry the verdict (`0` every tree read, no unpushed commits, no
  dirty or untracked paths · `1` something could not be read · `2` work at risk). `continue` outside a loop is a no-op, and a block
  whose stdout says "at risk" while it exits 0 teaches the caller to ignore it:
  ```bash
  # EXIT: 0 = read clean · 1 = something could not be read · 2 = work at risk (read the lines)
  if ! { [ -n "${REPO:-}" ] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; }; then
    echo "AT-RISK-UNKNOWN repo=${REPO:-<unset>}"; exit 1
  fi
  # BOTH population reads are asserted first: an enumeration that fails must not read as a clean box.
  WTS=$(git -C "$REPO" worktree list --porcelain 2>/dev/null) || { echo "AT-RISK-UNKNOWN worktree-list $REPO"; exit 1; }
  [ -n "$WTS" ] || { echo "AT-RISK-UNKNOWN worktree-list-empty $REPO"; exit 1; }
  BR=$(git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null) \
    || { echo "AT-RISK-UNKNOWN for-each-ref $REPO"; exit 1; }
  rc=0
  while IFS= read -r wt; do            # sed, not awk: keep paths that contain spaces whole
    if ! { [ -d "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; }; then
      echo "AT-RISK-UNKNOWN $wt"; [ "$rc" = 0 ] && rc=1; continue
    fi
    n=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) || n=UNKNOWN
    if d=$(git -C "$wt" status --porcelain 2>/dev/null); then
      d=$(printf '%s' "$d" | grep -c '^' || true)
    else d=UNKNOWN; fi
    if o=$(git -C "$wt" status --porcelain --ignored 2>/dev/null); then
      ig=$(printf '%s' "$o" | grep -c '^!!' || true)
    else ig=UNKNOWN; fi
    case "$n" in UNKNOWN|"") n=UNKNOWN; [ "$rc" = 2 ] || rc=1 ;; 0) ;; *) rc=2 ;; esac
    case "$d" in UNKNOWN|"") d=UNKNOWN; [ "$rc" = 2 ] || rc=1 ;; 0) ;; *) rc=2 ;; esac
    [ "$ig" = UNKNOWN ] && { [ "$rc" = 2 ] || rc=1; }
    echo "WT $wt unpushed=$n dirty=$d ignored=$ig"
  done < <(printf '%s\n' "$WTS" | sed -n 's/^worktree //p')
  if s=$(git -C "$REPO" stash list 2>/dev/null); then        # refs-wide: once per repo, never per tree
    if [ -n "$s" ]; then echo "$s" | sed 's/^/STASH-AT-RISK /'; rc=2; else echo "STASHES 0"; fi
  else echo "STASH-UNKNOWN $REPO"; [ "$rc" = 2 ] || rc=1; fi
  while IFS= read -r br; do                                  # a recreate also loses local branches
    [ -n "$br" ] || continue
    bn=$(git -C "$REPO" rev-list --count "$br" --not --remotes 2>/dev/null) || bn=UNKNOWN
    case "$bn" in UNKNOWN|"") bn=UNKNOWN; echo "BRANCH-UNREADABLE $br"; [ "$rc" = 2 ] || rc=1 ;; 0) ;; *) echo "BRANCH-AT-RISK $br $bn"; rc=2 ;; esac
  done < <(printf '%s\n' "$BR")
  echo "VERDICT $rc"; exit "$rc"
  ```
  `UNKNOWN` is an error, not a zero. **For anything that takes the whole guest — a recreate, the `cmux-tui` reset — save the
  block to a file and run it once per repo, keeping the worst status.** Inlining it in a loop cannot work: it ends with
  `exit`, so the first repo would end the loop.
  ```bash
  W="${W:-/tmp/work-at-risk.sh}"      # the block above, saved; named explicitly so it runs from any cwd
  [ -f "$W" ] || { echo "AT-RISK-UNKNOWN work-at-risk-missing $W"; exit 1; }
  [ -d "${CELL_HOME:-}" ] || { echo "AT-RISK-UNKNOWN CELL_HOME=${CELL_HOME:-<unset>}"; exit 1; }
  rc_all=0
  # The seed checkout is whatever repo owns the drainer's trees — DERIVED, never assumed. On pi-cell-4 it was
  # /tmp/cell-ai-main under one install of the unit and /home/cmux/agent-infra under the next (2026-10-27), while
  # install-drainer-timer.sh:72's DRAINER_SEED_REPO default ($HOME/agent-infra-main) exists in neither — which is why this DERIVES instead of
  # reading the unit: `systemctl cat` is the value in force, the trees are the value that matters.
  seed=""
  for w in "${AI:-$HOME/orchestrator-ai}"/wt-drainer-*; do
    [ -d "$w" ] || continue
    seed=$(git -C "$w" rev-parse --git-common-dir 2>/dev/null | sed 's|/\.git$||')
    [ -n "$seed" ] && break
  done
  # The population is the roots this block can SEE, one level deep: $REPO, the derived seed, /tmp/cell-*, "$CELL_HOME"/*, and
  # /home/*/*. That last root is not optional: exec's HOME is /home/cmux while the login shell's is $CELL_HOME, so the two
  # homes are different trees — measured on pi-cell-4 (2026-10-27), /home/cmux/agent-infra and /home/cmux/tortoise are repos
  # this root reaches and the $CELL_HOME glob never does. A repo parked anywhere else is INVISIBLE here, and a `0` does not
  # speak for it, so add its root before trusting the verdict. A path you only BELIEVE is there is not a floor either — it is
  # a permanent exit 1 on every run, which trains the reader to discount the stop signal; a path that exists and is not a repo
  # still reports AT-RISK-UNKNOWN. Streamed one path per line so a path with a space survives, for the same reason the block
  # above reads the porcelain stream instead of awk fields.
  # `$REPO` is asserted HERE, not left to the glob below: an unset one emits an EMPTY line, `sort -u` keeps it, the
  # `[ -n "$POP" ]` floor passes on any other root that matched, and the loop's `[ -n "$R" ] || continue` drops it — so the
  # one repo the caller named is the one never read. Block 1 fails closed on exactly this input; this half must not be weaker.
  [ -n "${REPO:-}" ] || { echo "AT-RISK-UNKNOWN REPO=<unset>"; exit 1; }
  POP=$( { printf '%s\n' "$REPO"
            [ -n "$seed" ] && printf '%s\n' "$seed"
            for d in /tmp/cell-* "$CELL_HOME"/* /home/*/*; do [ -e "$d/.git" ] && printf '%s\n' "$d"; done
          } | sort -u )
  [ -n "$POP" ] || { echo "AT-RISK-UNKNOWN no-repos $CELL_HOME"; exit 1; }   # nothing enumerated is not "clean"
  while IFS= read -r R; do
    [ -n "$R" ] || continue
    ( REPO=$R bash "$W" ) || { s=$?; [ "$s" -gt "$rc_all" ] && rc_all=$s; }
  done <<< "$POP"
  # ⛔ `orchestrator/wip/` and the `orchestrator/*.txt` ledgers are NOT optional extras on this list. `install.sh:649-650`
  # creates `logs/ state/ wip/` plus `candidates.txt dispatched.txt checked.txt` SIDE BY SIDE under `$O`, and `wip/` holds the
  # only copy of a cap-killed lane's dirty work (`spawn-gate.sh:844` writes `wip/capwip-<stamp>-<pid>/`; the README's state
  # table documents it). A list of three named paths was the list that lost them.
  for f in "$CELL_HOME"/keys.env "$CELL_HOME"/orchestrator/state "$CELL_HOME"/orchestrator/logs \
           "$CELL_HOME"/orchestrator/wip "$CELL_HOME"/orchestrator/*.txt; do
    # outside every repo, so no worktree read can see these. Their PRESENCE is work at risk and must move the CODE: printed
    # alone with rc=0 the caller proceeds with the recreate and destroys exactly the paths this line names — which is
    # the "stdout says at risk while it exits 0" failure stated three paragraphs up. The `*.txt` arm is a GLOB on purpose:
    # the next ledger the harness adds is then covered without an edit here, and a transcribed list is how one goes missing.
    [ -e "$f" ] && { echo "BOX-AT-RISK $f"; rc_all=2; }
  done
  echo "GUEST VERDICT $rc_all"; exit "$rc_all"
  ```
  **Nothing above is a list you carry**: the seed comes from the trees and the rest from a glob, every run. A transcribed list
  is the list that omits the repo holding the work — the version of this block that hardcoded four paths printed
  `GUEST VERDICT 0` on cell-3 while a repo it never opened held `unpushed=8` and `unpushed=2`. So confirm the enumeration before
  trusting a `0`: it must name a `VERDICT` line per repo, and an empty population is not a clean box — if the glob and `$REPO`
  yield nothing, treat the run as unreadable, not as permission. Preserve, then remove only the regenerable parts.
- **Capacity is a MEASUREMENT, not a constant.** Every earlier version of §2 substituted one number for the lane type and one
  for the reserve, and both errors ran in the direction that **refuses** dispatches it should allow. The figures in §2 carry
  their date and method so the next reader can re-derive them instead of inheriting them.

> Continue following the workflow as mandated by this skill. Do not skip steps.
