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
it.) ⚠️ **`pi-cell-N` is the LABEL column; every `cmux vm <verb>` takes the
NAME column (`vm-<hex>`)** — `cmux vm stats pi-cell-4` returns a 404 whose own advice is "start a new one", a
spend-flavoured remedy for a box that is already running. Read the NAME from `cmux vm ls`. Cells are Linux, so **any
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
| **test-running lane** (pi tree + pytest workers + per-lane FalkorDB) | **~0.4–0.7 GB** peak | a FalkorDB/PG sidecar is **single-digit MB idle to a ~150 MB ceiling** — the idle FLOOR re-measured on cells 3–4, 2026-10-27 (5.5 MB minimum); the 149 MB ceiling is the earlier 21–149 MB sample's maximum, **not** re-measured (same-day maxima: 105 MB on cell-3, 147 MB on cell-4 — re-measure per box). The scheduler budgets 512 MB (`ai-drainer.sh` `LANE_MEM_MB`) |
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
# set these to the same pair, or the aid and the gate disagree by construction
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
```

⚠️ **WHAT THE GATE ACTUALLY REFUSES** (read 2026-10-27) — **brief admission answers first**, then the capacity refusals in
this order (fork → disk → load). The brief gate (`AGENT_BRIEF_REFUSED`, exit **80**) fires **before fork** and before any
disk or load reading (agent-infra#2258), and a **brief refusal is deterministic**: it cannot clear by waiting, and
re-dispatching the same brief on another box refuses there too — re-author the brief, do not retry. (A missing or
incomplete validator returns **78** instead — `CANNOT VERIFY`; that one *is* repairable, by fixing the install rather than
the brief.) The gate's own comments disagree about the order — `:1034` calls the disk refusal "evaluated FIRST" while `:1299`
says "fork -> disk -> load"; the exit codes do not, and neither does the code: 80 before 73 before 77.

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
missing** — per-worktree or an install fault); and **rc=2, a failed `gh` read** (`UNREADABLE open-PR count` / `UNREADABLE
landing rate`) — box-local, so fixing that box's gh chain clears it and **a re-dispatch to a healthy box does clear it**, even
though the gate prints the ratio remedy text for it too. A P0-blocker or a base-red repair is **exempt by evidence** and
dispatches under the hold. **Idling on its own changes none of them**: for 73
and 77 the release *is* a lane draining, so the drain has to actually complete rather than just pass time — which is why the
gate's own two messages read "does NOT clear by waiting" (fork) and "This is NOT a load refusal: waiting does not clear it"
(headroom) while both still offer "or let its lanes drain" / "or let a lane finish". So diagnosing a 73, 77, 74, 78 or 80 as
"the box is busy" and idling is the trap.

**RAM is read by two other instruments — `spawn-gate.sh` reads NO memory at all.** The two floors live in `orch-loop.sh`
(`MIN_MEM_FREE_MB`, default 512) and `capacity.sh` (`CAP_MIN_MEM_MB`, 512). The **scheduler** does budget per lane: `ai-drainer.sh`
uses `LANE_MEM_MB` (default **512**) against `MEM_BUDGET_PCT` (default **75**) of the pool. So there are two numbers —
scheduler 512, planning ~1000 for a test-running lane (the table above) — and this file deliberately uses the larger.
Reconcile against `docs/ops/ai-drainer.md` before raising either. Where the gate speaks, the gate is right.

`MAX_LANES` is **derived** (`2.5 × cores`) **only when nothing sets it** — and on every cell something does: `keys.env` pins
`export MAX_LANES=20`, and an explicit value wins over the derivation. The controller still enforces it, but the number knows
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
  **both** of those gone, the in-guest surface left is the **display** the same render prints (`cmux surface open
  <vm>/display/display:1` — a noVNC console that was live on cell-4 while its `cmux-tui` port was refused). Beyond that the
  levers are provider-level (step 3) and owner-level (a plan change or a **recreate** — and a recreate is the one step here
  that can destroy unpushed work, so run the work-at-risk check below first).
- **`cmux vm tree` printing `(no terminals)` is not a reading of the box** when the same render shows a link error or a null
  workspace list — cell-4 today reports `link_error: "The Cloud hub could not reach the VM port: connection refused."` and
  `remote_workspaces: null` while its own registry holds **945** terminals. `null` means *unknown*, not *zero*: fall back to
  `exec` — and note that `--refresh`, which the tool's own render suggests, **can itself time out** (measured: 120 s, exit 1, no
  catalog at all on a box whose link is refused) and reports "VM request timed out". That is the channel failing, not the box.
  Only a **connected** link that genuinely enumerates zero terminals justifies creating one
  (`cmux surface new-terminal --machine <vm> --no-open -- <cmd>`).
- **A usage error is not a channel verdict, and neither is a wrong-but-valid argument.** `cmux vm tree` with **no machine**
  prints the whole fleet; `terminal read/send` without an id prints the usage block. And because §7's table is keyed by LABEL,
  `cmux vm tree pi-cell-4` renders **`No cloud machines. Try: cmux vm new`** — a false empty, not a missing box. Use the NAME.

And if the volume that is full is the **`cmux-tui` state volume** described under step 5, skip to that owner-level action —
none of the reclaim steps below touch it.

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
   the reclaim steps above touch it, so if it is the volume that is full, that is an **owner-level** action: it is a per-box
   loop file (`cmux-tui-state.ext4` — 974 MB on cell-3, 3,996 MB on cell-4) and **no `cmux vm` verb resizes it**. A reset is
   not just an unlink: the `cmux-tui` daemon holds that registry **open** (6 fds on cell-3 — 3 read-write, 2 read-only, 1
   `-shm`; *any* of them pins the inode), so deleting the file frees nothing until those fds close. ⛔ **And stopping it is not a
   small act:** the unit is `KillMode=control-group`, so `sudo systemctl stop cmux-tui-daemon.service` SIGTERMs **every process
   in it** — and it needs `sudo` (an unprivileged `systemctl stop` is "Access denied"). That cgroup holds **45 processes at zero
   lanes and 124–207 with the box full** (cell-3, 2026-10-27), including live `pi` lanes, a running `pytest` and the terminal
   hosts — **re-count before you act** with
   `cat /sys/fs/cgroup/system.slice/cmux-tui-daemon.service/cgroup.procs | wc -l` (or `systemctl show -p Tasks`); they are lanes
   and they are what you lose. You are also deleting the box's **terminal inventory** — the registry that steps 1-2 and the
   display are the channel *through* — so afterwards `exec` or the console is the only way back. Run the work-at-risk check below
   across every worktree on the box first, then: `sudo systemctl stop` the unit, delete `sessions/<id>/workspace-registry.sqlite3`
   (its ~43 MB `-wal` regenerates), `sudo systemctl start` it, **then** re-read `df` — or recreate the box, which takes
   `keys.env`, the harness pin and every `L-*.log` with it (copy them off first).

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
| `pi-cell-1` | product work | 16 GB / 8 vCPU / 128 GB — the **same shape as cell-4**, but **needs activation (§1)** before it can land |
| `pi-cell-3` | product work | 8 GB RAM / **4 vCPU** / 128 GB — the fleet's lowest-core box, but the **same pinned `MAX_LANES=20` as the 16 GB ones** (§7): 20 is twice the core-derived 10, on a box §2's arithmetic puts nearer 6 lanes — and today the aid answers 2. It has OOM-killed too (`dmesg`: 2), so **§2's rule is the same as cell-4's: reserve UP, fewer lanes** |
| `pi-cell-4` | product + CI-cost work | 16 GB / 8 vCPU / 128 GB — the current default dispatch target, and **the box with the most OOM kills of the three (5)**: per §2 that means its reserve goes UP, i.e. fewer lanes here, not more |
| laptop | product + orchestration | the only box that can reach every channel; do not overfill it |

⛔ **TWO DIFFERENT CEILINGS — DO NOT CONFUSE THEM, AND DO NOT TREAT EITHER AS THE WHOLE ANSWER.** The owner ruled on
2026-10-17 (`docs/ops/fleet-capacity.md`) that **between boxes** dispatch is gated on capacity, not a lane count — that is
`cap_place`, and the objection is to a count standing in for capacity **across a fleet**. **Inside one box there IS a real
ceiling**: `MAX_LANES` — `2.5 × cores` when unset (`orch-loop.sh`: `10#$_NCPU * 5 / 2`; **on the laptop it is rendered into the
launchd plist** by `install.sh` from `launchd.plist.template`'s `__MAX_LANES__`), **but the cells pin it** (`keys.env`:
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
- Deleting a worktree to make space must never destroy unpushed work, and the guard has to **fail closed AND read the right
tree**: `git rev-list --count @{u}..HEAD` **errors and prints nothing** on a branch with no upstream — which is the branch
  whose every commit is unpushed — so treat that error as UNSAFE, not as clean. Name the population (the repo, plus
  `$CELL_HOME/wt-*`), then per worktree, always with `-C "$wt"` because every one of these commands is cwd-relative:
  `git -C "$wt" rev-list --count --not --remotes HEAD` (**the positive reading**: commits reachable from no remote, which
  answers even where `@{u}` is unset), `git -C "$wt" rev-list --count '@{u}..HEAD' 2>/dev/null || echo NO-UPSTREAM`,
  `git -C "$wt" stash list`, and `git -C "$wt" status --porcelain`. A bare `status` exits 127 with empty output — which reads
  exactly like clean, so guard it (`|| echo UNKNOWN`). Preserve, then remove only the regenerable parts.
- **Capacity is a MEASUREMENT, not a constant.** Every earlier version of §2 substituted one number for the lane type and one
  for the reserve, and both errors ran in the direction that **refuses** dispatches it should allow. The figures in §2 carry
  their date and method so the next reader can re-derive them instead of inheriting them.

> Continue following the workflow as mandated by this skill. Do not skip steps.
