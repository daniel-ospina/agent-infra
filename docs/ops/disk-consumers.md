---
title: "What actually fills a cloud cell — measured disk consumers on cell 3 and cell 4 (diagnosis only)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-27
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2159, issue-1852, issue-9672, issue-2542, issue-1939, issue-3043, disk-reclaim, /tmp-consumers, uv-cache, lane-scratch, ci-runners, runner-work, cell-home
---

# What actually fills a cloud cell — measured

**Status: diagnosis only.** Nothing on either cell was deleted, pruned, truncated or restarted to
produce this document. Every number below is a `du`/`df`/`docker system df`/`journalctl` reading taken
read-only between **2026-10-27 04:05 and 04:55 UTC**.

| cell | vm id | `df -m /` | inodes | `du -xsm /` | gap |
|---|---|---|---|---|---|
| cell 3 | `vm-915c3930c4e94e4884229d974522d05d` | 128,828 total · **112,670 used · 10,736 avail (92%)** | 33% | 103,257 | 9,413 |
| cell 4 | `vm-ce2c2fc9fd844a32851d46c3723b903e` | 128,828 total · **114,993 used · 8,413 avail (94%)** | 32% | 110,727 | 4,266 |

Inodes are **not** the problem on either cell (32–33%). The gap between `df` and `du` is the ext4 root
reserve (~5% of a 126 G volume ≈ 6.4 G) plus `/var/lib/docker`, which `cmux` cannot `du` — see
[What could not be attributed](#what-could-not-be-attributed).

## The answer in one line

**`/tmp` is the disk.** It holds 85.4 GiB of cell 3's 110 GiB and 68.8 GiB of cell 4's 112 GiB, and
`/opt` — where everyone looked — holds only 2 GiB on cell 3 (it is 27 GiB on cell 4, almost all of it\xa0CI runners). That is not an accident of layout: on
these cells **`/tmp` *is* the working filesystem** — `HOME=/tmp/cell-home` and the tortoise checkout
with all its worktrees is `/tmp/cell-t3` (`pi-bootstrap/cell-install.sh:191`) — so it holds every lane
venv, every review/mutation scratch copy, and the uv cache, and nothing sweeps it before 30 days.

## Measured buckets

### Cell 3 (`vm-915c…`)

| bucket | size | what creates it | reclaimable how | risk if reclaimed |
|---|---|---|---|---|
| `/tmp` — lane scratch, ≥100 MB dirs (**165 dirs**) | **65,953 MB** | every review/verify/mutation/build lane makes a private tree (`rv-*`, `vfy-*`, `mut-*`, `pr*`, `rev*`, `wt*`, plain `cp -a` copies with **no `.git`**) | age-floored sweep; **none carries a PR link**, so nothing can be proven landed → see [R4](#r4--lane-scratch-copies) | the copy is the only artifact of an unfinished review/investigation; losing it loses that evidence |
| `/tmp/cell-t3` (tortoise main checkout) | 10,517 MB | `cell-install.sh` clones tortoise to `/tmp/cell-t3`; `.worktrees` = 9,829 MB (23 worktrees), `.venv` 962 MB, `.git` 474 MB | reaper `class=worktree` (7-day age floor, PR-state proof) | live lanes work here — **never** a bulk target |
| `/tmp/cell-home` (the cell's `HOME`) | 9,824 MB | `HOME=/tmp/cell-home`; `.cache` 6,553 MB (**uv 5,736 MB in `archive-v0`, 154 packages**), `.venvs` 1,126 MB, `.npm` 813 MB, `.pi` 687 MB, `harness.preserved-012629` 180 MB | `class=uv` (bounded 2,048 MB) + `disk-floor.sh` stale-copy class | uv cache blocks are copied into venvs on these cells (prune freed **5,707 MB real** at 03:03) → safe; `.venvs` are lane envs → not safe |
| `/tmp/actions-runner` | **9,423 MB** | 8 GitHub-runner installs (`ai-runner-cell3-x64-1..4` 717 MB each, `pi-runner-cell3-x64-1/2` 2.5/2.6 GB, `tortoise-cell3-1/2` ~720 MB). All 8 carry `.runner`; **zero live `Runner.Listener`; no installed systemd unit** | `class=duplicate-install` (#2542) — **the class exists in the repo and is not deployed on this cell** | a runner registration goes stale; a job in flight would be lost (none here) |
| `/tmp/venv-shared-py312` | **5,844 MB** | a shared python 3.12 venv, last touched 2026-10-23 | nothing claims it: not a uv cache, not a lane venv path, not a checkout | a lane still pointing `VIRTUAL_ENV` at it loses its interpreter |
| `/tmp/cell-ai` (agent-infra checkout) | 1,460 MB | `cell-install.sh`; `.worktrees` 1,126 MB (19) | `class=worktree` | live harness lives here |
| `/tmp/ai-runner-work-c3-1..4` | 2,843 MB | the four `ai-runner-cell3-*` runner `_work` dirs | same as the runner installs above | runner job scratch — regenerable |
| `/home/cmux` | 4,403 MB | `tortoise` 2,765 MB (`.worktrees` 1,536 MB, 3 worktrees), `.cache` 2,048 MB (uv 1,126, ms-playwright 681, hf 129) | worktree/venv classes (`DISK_REAPER_REPOS` does **not** list this repo — see [G1](#g1--the-reaper-only-knows-two-repos)) | mac-side lanes work here |
| `/usr` | 4,608 MB | OS | — | — |
| `/opt` | 2,048 MB | freestyle 1,536, google 442, cua-driver 49 | — | the cell runtime |
| `/var` | 1,741 MB | `/var/tmp` 1,126 (`mutrepo` 676), cache 342, lib 228, log 103 | age-floored | — |
| `/var/lib/docker` | **unreadable as `cmux`**; docker reports images 1,407 (765 reclaimable) + containers 64 + volumes **7,036** | 13 falkordb lane DB containers + **2 buildx builder state volumes: 4,213 MB + 2,774 MB** | `docker buildx prune` for the two builders only | a lane's test DB lives in a container — **never** a bulk `docker prune` |
| deleted-but-open | 248 MB | 26 `redis-server` fds | process restart | — |

### Cell 4 (`vm-ce2c…`)

| bucket | size | what creates it | reclaimable how | risk if reclaimed |
|---|---|---|---|---|
| `/tmp` — lane scratch, ≥100 MB dirs (**105 dirs**) | **49,309 MB** (incl. the two below) | same lane families as cell 3 | as cell 3 | as cell 3 |
| `/tmp/cell-t3` | **14,155 MB** | tortoise main checkout here; `.worktrees` **13 GB (48 worktrees)**, **`.venv` 5,698 MB** | `class=worktree` | live lanes |
| `/tmp/cell-home` | **13,478 MB** | `HOME`; **`.cache/uv` = 11,439 MB > the 2,048 MB bound, DEFERRED every hour**; `.pi` 707, `.npm` 302 | `class=uv` — see [G3](#g3--the-uv-bound-cannot-be-claimed-on-a-busy-cell) | safe *when* it can be claimed |
| `/opt` | **27,648 MB** | 3 runner installs + 1 broken: `gh-runner-x64` ≈9,216 · `gh-runner-x64-2` ≈9,011 · `gh-runner-cell4-x64` ≈7,066 · `gh-runner-x64-1` **683** (dead, cannot re-register) | [R2](#r2--surplus-runner-installs) for the dead one; the live three are capacity | removing a live runner's dir silently shrinks the pool |
| `/home/cmux` | 12,288 MB | `tortoise` 8,499 MB (`.worktrees` **7,884 MB**, 6 worktrees), `.cache` 2,253, `.npm` 570 | worktree/venv classes (repo not registered — [G1](#g1--the-reaper-only-knows-two-repos)) | live lanes |
| `/usr` | 4,608 MB | OS | — | — |
| `/var` | 765 MB | journal 96 MB | — | — |
| `/tmp/actions-runner` | 28 KB | leftover empty `tortoise-cell4-1`; the farm moved to `/opt` here | — | — |

### The runner `_work` sink — measured on cell c1, 2026-10-28 (a THIRD cell, at 98%)

The two cells above were diagnosed on 2026-10-27. The next day a third cell hit the wall with a bucket
neither of them led us to, and **no class in `scripts/disk-reaper.sh` matched it**:

| cell | vm id | `df -m /` | the sink | `_work` per runner |
|---|---|---|---|---|
| c1 | `vm-efa6cc8fdb974e61b5c054acf41d8846` (8 cores, **12 runners**) | **98% used, 3.5 G free** | `/opt/gh-runner-x64-{2,4,5,6,7,8}/_work` = **19 G** | 2.6 G – 4.7 G |

**Why it accumulates.** A GitHub Actions runner cleans its own `_work/<entry>` **only on a NORMAL job
end**. A job that is cancelled, crashes, or is OOM-killed leaves its full checkout behind, and nothing
on the box ever revisits it. Six of c1's twelve runners held 19 G of exactly that.

**Why it had no owner.** Runner `_work` is not a package cache (`uv`), not a lane env (`venv`), not a
checkout of a repo we track (`worktree`), and not a duplicate install (`duplicate-install`) — so the
hourly pass was green while 19 G of the box sat in none of its classes. The **structural** reason is
that `scripts/disk-reaper-run.sh` had ZERO coverage of `gh-runner`/`_work` (grep proves it), so a box
that GAINED five runners in a week silently lost its headroom and nothing measured it.

**The policy, now `class=runner-work`** (`scripts/reap-runner-work.sh`, owner; the class in
`scripts/disk-reaper.sh` only runs and accounts for it):

* discovery is a bounded, documented glob list: `/opt/gh-runner*/_work`, `$HOME/actions-runner*/_work`,
  `/tmp/actions-runner*/_work` (`DISK_REAPER_RUNNER_GLOBS`);
* **the gate is mtime over the entry and its content**: an entry is a candidate only when **nothing in
  it has been written for longer than `DISK_REAPER_RUNNER_MIN_AGE`** (default 3600 s), the entry's own
  top directory included — the conservative direction, since any write there restores the floor. A
  running job writes into its entry
  continuously, so mtime is a positive proof of death; there is no local busy-check on a runner to
  consult, and a `pgrep`-shaped guess would keep every dead entry while ANY runner is idle. ⚠️ Residual:
  a job that writes NOTHING for longer than the floor (one long quiet step) is indistinguishable from a
  dead entry by that test — raise the floor for such a box (`DISK_REAPER_RUNNER_MIN_AGE=7200`), which is
  the intended response;
* **`_work/_tool` and `_work/_actions` are DELIBERATELY RETAINED**: they are the runner's cross-job
  caches (downloaded actions, fetched toolchains), so reaping them does not free dead checkout — it
  forces a re-download on the NEXT job and makes every later CI run slower. That is a different trade
  from this class's, so they are excluded before anything is measured and counted (`retained=`);
* the hand reap that validated it (delete `_work` entries whose newest content was older than 120 min)
  took c1 **98% → 90% without disturbing a single running job**.

⛔ **The other sink on the same box is NOT this class.** c1's `/tmp` held **148 826 entries older than
24 h ≈ 15 G** (and c4's `/tmp` measured **48 G**). That population needs its own class and it is harder:
a live lane's cwd can BE under `/tmp` (measured: a running `pi` lane cwd'd in
`/tmp/cell-t3/.worktrees/…`), so an mtime floor alone is not sufficient evidence. Filed as **#3043**,
not fixed here.

### What a "5 GB venv" actually is
`du -xsh` inside `/tmp/cell-t3/.venv` (cell 4) and `/tmp/cell-t3/.worktrees/fix-10021/.venv`
(cell 3) — both 5.7 GB, identically shaped:

| package | size |
|---|---|
| `nvidia/*` (CUDA runtime wheels) | **2,700 MB** |
| `torch` | 1,100 MB |
| `triton` | 690 MB |
| `jaxlib` | 339 MB |
| `pyarrow` | 152 MB |
| everything else | ~800 MB |
| **total (34,051 files, 5.7 GB)** | |

Cheapest venv measured in the same population: 92 KB (never synced); typical synced lane: ~914 MB.
So the per-lane disk cost is **bimodal** — an ML-synced lane is 5.7 GB, not the ~1.1 GB
`docs/ops/disk-reaper.md` (#2159) budgets. That single fact is what the 20 GB reserve is really
buying: **~3.5 ML lanes, not 18**.

## The provisioner's number, answered directly

The refusal on cell 4 is:

```
REFUSED: disk headroom: 9G free against 44G needed for 3 runners (+20G reserve)
  — its own headroom guard is stricter than this tool's measured ceiling, so nothing was added
```

**It is not 15 GB per runner.** The arithmetic is `COUNT × DISK_PER_RUNNER_GB + DISK_RESERVE_GB`:

`tortoise/tools/install-ci-runner-x64.sh`
```
 99: DISK_PER_RUNNER_GB="${CI_RUNNER_DISK_PER_RUNNER_GB:-8}"   # checkout (~0.2G) + uv venv + docker images, measured per lane
100: DISK_RESERVE_GB="${CI_RUNNER_DISK_RESERVE_GB:-20}"        # keeps the agent lanes' worktrees safe
...
332:   disk_need_gb=$(( COUNT * DISK_PER_RUNNER_GB + DISK_RESERVE_GB ))
333:   [ "$disk_free_gb" -ge "$disk_need_gb" ] || die "disk headroom: ${disk_free_gb}G free against ${disk_need_gb}G needed for $COUNT runners (+${DISK_RESERVE_GB}G reserve)"
```
`3 × 8 + 20 = 44`.

**Measured with and without the runner's workspace** (cell 4, `/opt`):

| runner dir | total | binaries (`bin`+`externals`+`_diag`) | `.cache` (uv 1,843 · pip 546 · hf 129) | `_work` |
|---|---|---|---|---|
| `/opt/gh-runner-x64` | **9,216 MB** | 1,536 | 2,560 | 5,325 — `_tool` 2,867 (Python 2,151, node 453, flyctl 219) · checkout 1,741 (`.venv` 914) · **`_update` 682 (extracted duplicate of `externals`)** · `_actions` 60 |
| `/opt/gh-runner-x64-2` | ≈9,011 MB | 1,536 | 2,560 | ≈5,018 |
| `/opt/gh-runner-cell4-x64` | 7,066 MB | 1,536 | 1,536 | 4,014 |
| `/opt/gh-runner-x64-1` (**dead**) | **683 MB** | 683 | — | — |
| **fresh install (no `.cache`, no `_work`)** | **1,536 MB** | | | |

**Verdict on the constant: it is accurate, not inflated.** The mean of the three warm runners is
**8.2 GiB (8,431 MB)** against `DISK_PER_RUNNER_GB=8` — the guard is ~3% *optimistic* (it under-states
a warm runner), not 50% inflated. The
refusal is therefore **correct by its own rule**: 8.4 GB free cannot host three more 8 GB runners.

The guard's real defects are different, and both are already tracked:

1. **`#9672`** (tortoise, open): *the installer's headroom guard counts only its OWN runners, so a
   second invocation oversubscribes a host.* Invoking it with a different prefix (`/opt/gh-runner-cell4-*`)
   double-counts nothing and complains about nothing.
2. **The ask itself is misleading.** The autoscaler is asking for slot **#3** while one of its slots is
   `DEAD`: `/opt/gh-runner-x64-1` (683 MB) cannot be re-registered —
   `Cannot configure the runner because it is already configured` plus
   `ldd: ./bin/libcoreclr.so: No such file or directory`. Repair-or-reap that install **before**
   provisioning another runner; it costs no headroom and needs no 44 GB.

Per-runner waste that needs nobody's decision (inside a runner we would keep anyway):
`_update/` is a 682 MB extracted duplicate of `externals.2.338.0`, and every runner keeps its **own**
`.cache` (2.5 GB) and Python toolcache (2.1 GB) instead of sharing them — ~5 GB per runner, ~15 GB
across the three.

## The reaper: it runs, hourly, and it reclaims almost nothing

| | cell 3 | cell 4 |
|---|---|---|
| `eldato-disk-reaper.timer` | **active**, fires hourly at :01 | **active**, hourly |
| last pass | 04:01:35 → 04:02:43, `verdict=3`, **freed 85 MB** (uv 2 · venv 83 · worktree 0) | 04:02:10 → 04:03:13, `verdict=6`, **freed 70 MB** (uv 0 · venv 66 · worktree 4) |
| service result | **failed** (`status=3/NOTIMPLEMENTED`) | finished (6 = *deferred*, green by #2036) |
| classes actually wired | `uv,venv,worktree` | `uv,venv,worktree` |
| `cell-reclaim.service` (merged-worktree sweep) | last run OK (04:00:34, `end free=10656MB`) | **FAILED every 30 min since 02:09** — `REFUSING: no PR surface readable -- not treating an unreadable read as 'nothing is merged'` (exit 2) |
| worktree `REMOVED=` | **0** (every candidate preserved with `rule=`/`proof=`) | **0** |

So the honest finding is not "there is no reaper". There is one, it is scheduled, and it is
**structurally unable to touch the buckets that filled the disk**:

### G1 — the reaper only knows two repos
`Environment=DISK_REAPER_REPOS=/tmp/cell-t3:/tmp/cell-ai` (installed unit, both cells). `/home/cmux/tortoise`
— 2.8 GB on cell 3 and **8.5 GB on cell 4**, with 3 and 6 worktrees — is **not in the list**, so
`class=worktree` never looks at it. 14 GB of the two cells' worktree estate is outside the pass.

### G2 — the lane-scratch population is seen and always preserved
165 dirs ≥100 MB (65.9 GB) on cell 3 / 105 (49.3 GB) on cell 4. The pass does classify them
(`CLASSIFY preserve /tmp/rv-10013 reason=ignored-artifact rule=2 …`,
`reason=no-pr rule=6 proof=gh-state:no-PR-matches-this-head …`) and preserves every one: a scratch
copy has no PR, so it cannot be proven landed, and rule 2 keeps it if it holds an untracked artifact.
That is the correct safety rule and it means **this population is unbounded by design** — it grows
~2–4 GB/day/cell (measured age distribution below) and only `systemd-tmpfiles` (below) removes any of it.

### G3 — the uv bound cannot be claimed on a busy cell
`CACHE_REAP_MAX_MB` default **2048** (`scripts/pi-cache-reap.sh:180`). Cell 4, every pass:
```
pi-cache-reap: DEFERRED — uv: /tmp/cell-home/.cache/uv is 11439MB > 2048MB and a live uv process is
running … NOT escalating; prune=contended, nothing EVICTED … process(es): uv run python tools/ci_*.py
```
Lanes run `uv run` continuously, so on cell 4 the bound is a **permanent 11.4 GB overshoot** (5.6×);
cell 3 only got its window at 03:03 (freed 5,707 MB) because the box happened to be quiet. This is
declared behaviour (`docs/ops/disk-reaper.md`: *"the bound is enforced in the gaps between lanes"*) — on
cell 4 there are no gaps.

### G4 — the two classes written for exactly these sinks are **not deployed on either cell**
`#2542` / PR #2676 (merged 2026-10-25) added `class=duplicate-install` and the abandoned-worktree arm,
whose own header cites the measured defect *"cell-1 … 11.3 GB of `/tmp/actions-runner` holding EIGHT
identical runner installs"*. **Cell 3 has that exact bucket today: 9,423 MB, 8 installs, 0 listeners.**

The class cannot run there, for three independent reasons:
* the delegates are **absent from the cell's harness**: `/tmp/cell-home/.pi/agent/scripts/` has
  `disk-reaper.sh`, `pi-cache-reap.sh`, `reap-lane-venvs.sh`, `pi-reap-worktrees.sh` — but **no
  `reap-duplicate-installs.sh` and no `reap-abandoned-worktrees.sh`** (both are in the repo at
  `scripts/`, and both are in the farm list at `pi-bootstrap/setup.sh:522`);
* the installed unit has **no `DUP_INSTALL_REAPER` / `ABANDONED_WT_REAPER`** env pins (the template does,
  `templates/systemd/eldato-disk-reaper.service:50-51`);
* the pass record confirms it: `classes=uv,venv,worktree`.

The harness pins on the cells (`c46fe9ae…` / `e90973eb…`) predate `b13f1f4e0` (2026-10-25 02:08), and
`eldato-harness-apply` reports *"the pin already names origin/main — no-op"* while the delegate is
still missing: **the pin advances, the deploy does not carry the file.** (Re-running
`scripts/install-disk-reaper-timer.sh` on the cells re-renders the unit and its delegate check warns when
a pinned delegate is missing — `install-disk-reaper-timer.sh:303`.)

### G5 — nothing sweeps `/tmp` on a useful timescale
`/usr/lib/tmpfiles.d/tmp.conf` ships `D /tmp 1777 root root 30d`. Lane scratch is 10–11 days old at its
oldest, so **the only aged sweep in place cannot free a byte before day 30**, on a filesystem that
fills in ~5 days at the current input rate.

### G6 — cell 4's second reclamation path is dead
`cell-reclaim.service` has failed on every 30-minute tick since 02:09:14 (`no PR surface readable`,
exit 2). Its merged-worktree arm has not run on cell 4 for the whole window in which the disk went
from 11 G to 8.4 G free.

### G7 — one transient `gh` failure costs a whole repo's pass
Cell 3's 04:02 worktree class aborted:
```
GH pr-list failed (rc=1) for daniel-ospina/agent-infra — fail-closed (reason=gh-error(rc=1))
FAIL-CLOSED abort: PR-state gate unverifiable for /tmp/cell-ai
```
`gh auth status` and `gh pr list` succeed now, so this was transient — a secondary-rate-limit shape
(#1939). Fail-closed is right; the cost is one lost window per occurrence, and the exit 3 paints the
unit red on a healthy box (#2036 territory).

### G8 — the runner `_work` sink was in NO class at all (**fixed**: `class=runner-work`)
Measured on c1 the next day (see *The runner `_work` sink* above): **19 G** in six
`/opt/gh-runner-x64-*/_work` directories, on a box at **98 % used, 3.5 G free**, with the hourly pass
reporting healthy. `scripts/disk-reaper-run.sh` had zero coverage of `gh-runner`/`_work`, so the sink
was unmeasurable by construction. Shipped as `class=runner-work` + `scripts/reap-runner-work.sh`
(owner), with the mtime gate and the `_tool`/`_actions` carve-out; its suite fails against the
pre-change tree (4 passed / 13 failed) and kills all nine of its mutants
(`scripts/disk-reaper-runner-work.test.sh`).

### G9 — the stale `/tmp` sink (filed as **#3043**, deliberately NOT fixed with G8)
c1's `/tmp` held **148 826 entries older than 24 h ≈ 15 G**; c4's `/tmp` measured **48 G**. It is not
the same trade as G8: a live lane's cwd can be under `/tmp` (measured, a running `pi` lane cwd'd in
`/tmp/cell-t3/.worktrees/…`), and a scratch copy is the only artifact of an unfinished review, so
nothing can prove it landed (this doc's G2 and `docs/ops/disk-reaper.md`'s rule 6). It needs a liveness
witness plus an owner ruling on what scratch counts as evidence — see **#3043**.

## Age distribution — the disk is a rolling 7-day window, not a rot

Top 250 `/tmp` children, summed by directory mtime (covers ~71 GB of cell 3's 86 GB, ~58 GB of cell 4's 69 GB):

| age | cell 3 | cell 4 |
|---|---|---|
| < 24 h | 35 dirs · **36,383 MB** | 18 dirs · **31,289 MB** |
| 1–3 d | 50 · 8,480 MB | 84 · 5,869 MB |
| 3–7 d | 90 · **18,292 MB** | 148 · **20,423 MB** |
| 7–14 d | 75 · 7,959 MB | 0 |
| > 14 d | 0 | 0 |

Nothing is ancient — the fleet does churn its scratch — but the *input rate* is ~2–4 GB/day/cell and
nothing removes it before 30 days. A one-off clean buys about a week.

## Bounded reclaim recipes

Every recipe is a **separate, dry-run-first** action. None is executed by this document's author; none
of them touches a `.git`, a live process's cwd, or a lane's own worktree. "Expected" is measured size;
"actual" must be read from `df` afterwards — on these cells `uv` cache blocks are *copied* into venvs
(5,707 MB of a 5,765 MB prune was real), so `du` and `df` agree here, but the rule stays: **claim the
`df` delta, never the `du`.**

### R1 — uv cache down to its bound
```bash
bash /tmp/cell-home/.pi/agent/scripts/pi-cache-reap.sh --dry-run   # then --apply
```
* **Expected:** cell 4 **up to 9,391 MB** (11,439 → 2,048 bound); cell 3 ~3,700 MB.
* **Guard:** refuses (exit 7) while a live `uv` process holds the cache — that is why cell 4 defers.
  Needs a gap, so run it on the quiet cell or raise the bound deliberately
  (`CACHE_REAP_MAX_MB=…`, one number, one decision).

### R2 — surplus runner installs
```bash
# 1) deploy the delegate that already exists in the repo (it is not on the cell — G4)
bash <agent-infra>/scripts/install-disk-reaper-timer.sh           # re-render the unit
# 2) dry-run, then apply — keeps the NEWEST copy per family, never empties a family
bash /tmp/cell-home/.pi/agent/scripts/reap-duplicate-installs.sh --dry-run --root /tmp
bash /tmp/cell-home/.pi/agent/scripts/reap-duplicate-installs.sh --apply   --root /tmp
```
* **Expected:** cell 3 up to **~7,500 MB** of the 9,423 MB `/tmp/actions-runner` (families:
  `ai-runner-cell3-x64-*` 4×717 MB, `pi-runner-cell3-x64-*` 2×(2.5 GB), `tortoise-cell3-*` 2×720 MB —
  the newest of each family is kept).
* **Guard:** only a copy that is provably idle (no live `/proc` cwd/exe/argv, no unit naming it) is
  removed; newest always kept; unprovable ⇒ kept and named. Cell 3 has **0** `Runner.Listener`
  processes and no `actions.runner` unit at all, so all 8 are idle. ⚠️ Removing the *directory* alone
  does not remove the GitHub registration — run `./config.sh remove --token …` first if the name must
  be reused.

### R3 — the orphan shared venv
```bash
# prove nothing points at it first
ls -l /proc/*/cwd 2>/dev/null | grep -c venv-shared-py312          # expect 0
rm -rf /tmp/venv-shared-py312                                       # 5,844 MB, last touched 2026-10-23
```
* **Expected:** 5,844 MB on cell 3 (absent on cell 4).
* **Guard:** the `/proc` census above, plus a `grep -r venv-shared-py312` in the live lane scripts.

### R4 — lane scratch copies (the only bucket that scales)
```bash
# dry-run: name them, size them, prove no live holder
find /tmp -maxdepth 1 -mindepth 1 -type d -mmin +4320 \
     ! -name 'cell-*' ! -name 'actions-runner' ! -name 'venv-shared*' \
     ! -name 'G-*' ! -name '.pytest_cache' ! -name 'systemd-*' -print0 |
  xargs -0 du -xsh 2>/dev/null | sort -h | tail -20
# every candidate must then pass: no .git dir/file, no /proc cwd/exe/argv inside it
```
* **Expected:** the 3–7 day band is **18,292 MB (cell 3)** / **20,423 MB (cell 4)**; the 7–14 day band
  adds 7,959 MB on cell 3.
* **Guard (all must hold):** age ≥ 72 h **and** not a git checkout (`.git` present ⇒ skip) **and** no
  live process holds it **and** the run is a dry-run whose count matches on a second read. Never take
  this from a single `find | head` — a first-match reading is exactly the artifact class in
  `AGENTS.md`.
* ⚠️ These copies carry unlanded review/mutation evidence; this is a **deliberate** trade of evidence
  for headroom. Prefer R1/R2/R5 first, which trade nothing.

### R5 — docker buildx builder state (cell 3 only)
```bash
docker buildx ls                                   # the two builders and their age
docker buildx prune --filter until=168h --force    # requires no build in flight
```
* **Expected:** up to **6,987 MB** (two builder state volumes, 4,213 MB + 2,774 MB; 3 days and 21 h old).
* **Guard:** `docker buildx ls` shows no running build; **never** `docker system prune -a` here — the
  13 running `fdb-lane-*` containers are live lane test databases.

### R6 — `/var/tmp` leftovers
```bash
du -xsh /var/tmp/* | sort -h | tail        # mutrepo 676 MB, rv7357b 66 MB, prc 47 MB, …
```
* **Expected:** ~1,100 MB on cell 3, ~2 MB on cell 4.
* **Guard:** age + no live holder, same rule as R4.

### Not recommended
* **`class=worktree` on `/tmp/cell-t3` / `/tmp/cell-ai` / `/home/cmux/tortoise`** — the pass already
  owns it and preserves correctly. Raising its age floor or removing "no-PR" protection would start
  deleting other lanes' work.
* **Lowering `DISK_PER_RUNNER_GB`** to make the refusal go away — the measured number says 8 is right
  (8.36 GB mean). The refusal is a true reading of a full disk, not a bad constant.
* **`sudo rm -rf /tmp/*`**, `docker system prune -a`, `uv cache clean` under a live `uv` — each can
  take a lane's working state with no proof anything was landed.

## What could not be attributed

* **`/var/lib/docker` bytes.** `cmux` lacks permission to `du` it (`Permission denied`); `docker system
  df -v` gives *logical* sizes (8.5 GB on cell 3, 2.4 GB on cell 4) but overlay accounting is not `du`.
  **Needed:** `sudo du -xsm /var/lib/docker`. This is the bulk of cell 3's 9,413 MB `df`−`du` gap
  alongside ext4's reserve.
* **ext4 reserved blocks.** `tune2fs -l /dev/root | grep -i reserved` would confirm the ~5% (≈6.4 GB)
  share of that gap. Not run (sudo).
* **Which lane owns a given `/tmp` dir.** Live ones are attributable from `/proc/*/cwd` (22 on cell 3,
  26 on cell 4), and dead ones are attributable only by joining the path against lane transcripts in
  `~/.pi/agent/sessions/*.jsonl` — a join, not a measurement. **Nothing in the scratch trees carries a
  PR or issue link**, which is exactly why `class=worktree` cannot prove them landed.
* **`/tmp/cell-home/.venvs` (1,126 MB, cell 3).** Not covered by `reap-lane-venvs.sh` (it looks at lane
  worktrees) and not a uv cache. Unattributed by owner; **needed:** `ls -l` its entries against live
  `VIRTUAL_ENV`s.
* **`harness.preserved-012629` (180 MB, cell 3).** Owned by `disk-floor.sh`'s stale-copy class
  (`$O/harness.preserved-*`, 1-day age floor) — it survived, so the class either did not run on this
  path or the age floor has not elapsed with the pass reaching it. Not chased further.

## If these findings were fixed, what the change would touch

None of the defects found is a one-line, obviously-correct change with a test, so this PR ships the
diagnosis only. What a follow-up PR would touch, per finding:

| finding | what a PR would touch |
|---|---|
| **G1** `/home/cmux/tortoise` outside `DISK_REAPER_REPOS` | nothing in code — an installer argument. `install-disk-reaper-timer.sh --repo` on each cell, then verify `classes=` and the worktree census in the next pass. |
| **G2** lane-scratch population unbounded | a decision, not a patch: replacing `systemd-tmpfiles`' 30 d with an aged class needs an owner ruling on what scratch counts as evidence. Out of scope by design (see the two rules in `docs/ops/disk-reaper.md`). |
| **G3** uv bound unclaimable on a busy cell | `scripts/pi-cache-reap.sh` — a deferral that recurs on N consecutive passes cannot stay a silent `deferral`; it needs a named escalation (raise the bound deliberately, or report `bound-unclaimed-for=…` in the status record) plus a test. Two-arm change, not one line. |
| **G4** `class=duplicate-install` never runs on the cells | `scripts/harness-apply-pass.sh` — a pin advance that leaves a *pinned* delegate absent must fail, not report `deployed=<rev>`. The farm list (`pi-bootstrap/setup.sh:556`) already names both delegates, so the list is not the defect. Needs its own test. |
| **G8** the runner `_work` sink had no class | **shipped** (2026-10-28): `scripts/reap-runner-work.sh` + `class=runner-work` in `scripts/disk-reaper.sh`, pinned in both scheduled artifacts and in the farm list. A class an operator has to remember to enable is the hole it closes, so it is in the DEFAULT `--only` list — and its globs are in `DISK_REAPER_RUNNER_GLOBS`, so an explicit-but-unmatched layout is a refusal rather than a measured zero. |
| **G9** stale `/tmp` has no class | filed as **#3043** — a liveness witness (`scripts/lib/live-paths.sh`) per candidate, an owner ruling on what scratch counts as evidence, and an exclusion set that is not a name list. |
| **G5** `/tmp` swept only at 30 d | policy (`/etc/tmpfiles.d/`), one owner decision; no repo change. |
| **G6** cell 4's `cell-reclaim.service` failing since 02:09 | not yet diagnosed — the message (`no PR surface readable`) is *correct* fail-closed behaviour; the open question is why that read fails while `gh pr list` succeeds from the same `HOME`. Needs a read-only repro before any patch. |
| **G7** one transient `gh` failure costs a repo's pass | `#2036` territory (exit-code semantics already split); the recoverable half is a bounded retry inside `pi-reap-worktrees.sh`'s gh probe, with a test that a second failure still fails closed. |

## Related issues — evidence added here, no peer filed

| issue | relation |
|---|---|
| **#2159** cell capacity / venv reaper cannot raise the ceiling | this doc re-measures the per-lane cost: **5.7 GB for an ML-synced lane**, not ~1.1 GB |
| **#1852** dispatch disk floor below the real cost of a lane | shipped floor is now `DISK_FLOOR_MB=3072` (`disk-floor.sh:98`) — still below one 5.7 GB venv |
| **#9672** runner guard counts only its own runners | the 44 G arithmetic is correct; the constant is not the defect |
| **#2543** reviewer transcript directory unbounded and unreaped | same failure shape as G2 here |
| **#2198 / #2443 / #2036** reaper install + red-on-healthy-cell | G4 (delegate not deployed) and G7 (transient `gh` ⇒ exit 3) are instances |
| **#1939** GraphQL secondary limit | the transient `gh pr list` rc=1 in G7 |
| **#2316** "disk or database is full" at 82 G free | the instrument-vs-artifact confusion that this read is meant to replace |

## Method (reproducible, read-only)

```bash
cmux cloud exec --timeout 200 <vm> -- sh -c '
  df -h; df -i
  du -xhd1 / 2>/dev/null | sort -h | tail -30
  du -xsm /tmp/* 2>/dev/null | sort -rn | head -1000
  docker system df; docker system df -v
  systemctl list-units --all | grep -iE "reap|disk|clean"
  journalctl -u eldato-disk-reaper -n 40; journalctl -u cell-reclaim -n 20
  cat /tmp/cell-home/.pi/agent/state/disk-reaper.status
  grep -E "^(ExecStart|Environment)" /etc/systemd/system/eldato-disk-reaper.service'
```
No `rm`, no `prune`, no `truncate`, no restart, no `docker` mutation, no sudo beyond reads.
