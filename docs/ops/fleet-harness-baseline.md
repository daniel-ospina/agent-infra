# Fleet harness baseline — the deployed sha of every live orchestrator copy

**Why this file exists.** Auditing "what is actually deployed" used to mean re-deriving it from four
machines by hand, every time — and that derivation has already failed twice (the claim-cwd fix and the
REST refresh were live-only, and a redeploy reverted them). A baseline that is *recorded* turns the next
audit into a diff. A baseline that is *recorded wrong* is worse than none, so every row states how it
was measured and **when**.

This file is **hand-maintained**. It is a record of a measurement, not a measurement: re-run §2 before
trusting a row, and update one row (with a timestamp) whenever a box moves.

---

## 1. Baseline — measured 2026-10-18T12:45–12:52Z

Target: **`agent-infra` `origin/main` = `64385b254f474965637250a175f4eab8e7715730`** (child of
`81a190ee`; the delta is `orch-loop.sh` + `selftest.sh`).

| # | Box | Deployment mechanism | Active harness path | Deployed sha | State |
|---|-----|----------------------|---------------------|--------------|-------|
| 1 | Local Mac (`~/orchestrator`, launchd `com.eldato.orchestrator-loop`) | **flat copied files** in a dir with no `.git`, plus a **launchd entrypoint script** that runs the controller inside a tmux pane | `~/orchestrator` | `64385b25` as deployed 12:42Z, **then superseded 12:46–12:49Z by live-only bytes from a concurrent lane** (§3.1) | ✅ dispatching |
| 2 | cell-2 `vm-d4f21dc5359a4f219a61b69b5dc9012e` | **versioned snapshot** — `/tmp/cell-home/harness/<sha12>/`, pinned by `/tmp/cell-home/.harness-path` | `/tmp/cell-home/harness/64385b254f47/scripts/orchestrator-harness` | `64385b25` | ✅ dispatching |
| 3 | cell-3 `vm-915c3930c4e94e4884229d974522d05d` | **versioned snapshot** (same) | `/tmp/cell-home/harness/81a190ee47db/scripts/orchestrator-harness` | `81a190ee` | ⚠️ one commit behind; a lane was in flight at measurement time (§3.3) |
| 4 | lane-1 `vm-efa6cc8fdb974e61b5c054acf41d8846` | **versioned snapshot** (same) | `/tmp/cell-home/harness/bed278f4bbb1/scripts/orchestrator-harness` | `bed278f4` (2026-10-17) | ⛔ **MERGE-INERT** — measured config defect, §3.2 |

Snapshot deployments are **immutable**: the snapshot directory's bytes are the commit's bytes, so a
per-file `git hash-object` comparison is a complete provenance proof (equal *size* is not). The Mac
runtime is a **flat copy with no git identity**, so its provenance must be proven file by file — and it
additionally has a launchd entrypoint script that is **not a harness entry at all**, so a file-by-file
compare against `scripts/orchestrator-harness/` cannot see it (§3.1).

`scripts/orchestrator-harness/` at this baseline holds **38 tree entries — 35 files plus 3 directories
(`gh-limit/`, `gh-rest/`, `retired/`)**. `deploy-mac-orchestrator.sh` reports "copied 37", which is
correct for its own phase A: that count is *all entries except `orch-loop.sh`* (phase B installs it).

**Other surfaces on the Mac that carry harness code.** `~/.pi/agent/scripts/` — `pi-cache-reap.sh`,
`pi-reap-idle.sh`, `pi-reap-worktrees.sh`, `pi-task-session-prune.sh`, `orphan-reap.py`,
`lane-watchdog.py` — all six byte-identical to `origin/main:scripts/<name>` at this baseline. Only four
are actually invoked by a LaunchAgent: `pi-cache-reap.sh` → `com.eldato.pi-cache-reap`,
`pi-reap-idle.sh` → `com.eldato.pi-session-reaper`, `pi-task-session-prune.sh` →
`com.eldato.pi-task-session-prune`, and `pi-reap-worktrees` via the sibling wrapper
`pi-reap-worktrees-launchd.py` → `com.tortoise.worktree-reaper` / `com.tortoise.branch-reaper`.
(The consolidated disk reaper, #2048, is scheduled the same way on Darwin:
`com.eldato.disk-reaper` runs `disk-reaper.sh` through that same wrapper, because a launchd-spawned
`bash` cannot read a repo under `~/Documents`. It is installed by `install-disk-reaper-timer.sh`, not
by `install-launchd.sh` — see `docs/ops/disk-reaper.md`.)
**`orphan-reap.py` and `lane-watchdog.py` are referenced by no LaunchAgent on this box** — they are
armed elsewhere or not at all; do not infer that they run from their presence.

**Not part of any box's deployed harness** (they execute from a git checkout):
`scripts/record-review.sh`, `scripts/cloud-cell-{bringup,supervisor}.sh`, `scripts/orchestrator-bringup.sh`,
`scripts/deploy-mac-orchestrator.sh`.

---

### 1.1 Re-measured 2026-10-18T13:15Z, at merge time — the rows above are HISTORY, not current state

`main` moved on (`64385b25` → `df746a05`, **5** commits) while this file sat in review, so the Mac row above
is **two kinds of stale at once** — and telling them apart is the whole point of §2. The Mac runtime has
not been touched since **12:53:01Z** (the last of the five live-only file edits made between 12:46Z and
12:53Z), so the live-only bytes are **still live-only**:

```
$ bash scripts/orchestrator-harness/check-deployed-drift.sh --no-fetch   # exit 1, never a pass
# 11 findings. CONDENSED here — the tool prints one line per file, with blob shas.
DRIFT: recorded from a4a1249794e7, which is BEHIND origin/main (df746a05)   <- the STAMP is stale
DRIFT: the deployed copy changed after it was recorded (ff1b27dd → 99a28a52) <- a hand edit
DRIFT: claims.sh, orch-loop.sh                     DIFFER  <- LIVE-ONLY   (§3.1)
DRIFT: install.sh                                  DIFFERS <- LIVE-ONLY and behind (its DRIFTED guard)
DRIFT: launchd-cycle.sh, refresh-candidates.sh,
       install-launchd-durability.test.sh          DIFFER  <- main moved AHEAD
DRIFT: launchd-controller.sh, watchdog.sh,
       watchdog-loop.sh present but NOT shipped     <- not on main
# and, INVISIBLE to this tool (it hashes only *.sh): launchd.plist.template — see §3.1. That one is
# the pivot; §2's hand loop is the only read that surfaces it.
```

Two directions of drift with **opposite** remedies, and one "differs" column cannot tell them apart:
*live-only* must be **lifted** (copying over it is the loss), *behind* must be **installed** — and
`install.sh` is **both**, which is why the tool's own printed remedy (§3.1) is the one command on this
box that must not be run. So **do not read this exit 1 as "the runtime is wrong"**. The 11 findings
break down as: 2 arms of the stale stamp, 6 differing `*.sh` (2 live-only, 1 both, 3 main-ahead), and 3
scripts not on main. And it is the `*.sh` half of the picture — §2's hand loop, which is not
`*.sh`-blind, reports **8** differing files, adding `launchd.plist.template` and `README.md`, which this
tool structurally cannot report. The stamp those first two arms read still says `a4a12497` /
2026-10-17T00:39Z, i.e. it describes the 12:42Z install and none of the five edits after it.

---

## 2. How to re-derive this table (do not trust a row you have not re-measured)

```bash
# The target sha. FETCH first — a bare `rev-parse origin/main` reads a stale ref and yields a false
# "current", which is the more dangerous direction of error.
cd "$AGENT_INFRA_PATH" && git fetch -q origin main && git rev-parse origin/main

# A cloud cell: which harness does the LIVE controller run, and do its bytes equal that commit?
VM=vm-d4f21dc5359a4f219a61b69b5dc9012e
cmux cloud exec "$VM" -- bash -lc '
  cat /tmp/cell-home/.harness-path
  pgrep -af "^bash /tmp/cell-home/harness" | head -1   # the RUNNING path is authoritative; the pin is a record
  cat /tmp/cell-home/orchestrator/.agent-infra-stamp.json'

# Per-file proof (same size != same content):
git rev-parse "origin/main:scripts/orchestrator-harness/claims.sh"
cmux cloud exec "$VM" -- bash -lc \
  'git hash-object /tmp/cell-home/harness/<sha12>/scripts/orchestrator-harness/claims.sh'

# The Mac runtime. Compare ONLY files that exist on one side, or every file that is not a harness
# entry reports a false DRIFT. Measured 2026-10-18T13:15Z: THREE runtime-only *scripts* —
# launchd-controller.sh, watchdog.sh, watchdog-loop.sh — plus (a) 11 state/backup files this loop
# also lists as RUNTIME-ONLY (candidates.txt, *.bak-*, heartbeat, …; ignore those) and (b) two
# DRIFT lines the *.sh-only tool structurally CANNOT produce: launchd.plist.template and README.md.
# (An earlier draft named `merged-not-closed.sh`, which is NOT on this box, and omitted
# watchdog-loop.sh and the template — the template is the most consequential of the three.)
for f in "$HOME"/orchestrator/*; do b=$(basename "$f"); [ -d "$f" ] && continue
  want=$(git rev-parse "origin/main:scripts/orchestrator-harness/$b" 2>/dev/null) || {
    echo "RUNTIME-ONLY (not a harness entry): $b"; continue; }
  [ "$(git hash-object "$f")" = "$want" ] || echo "DRIFT: $b"; done

# Which controller is live, and is there exactly ONE?
pgrep -fl "[b]ash $HOME/orchestrator/orch-loop.sh"
cat "$HOME/orchestrator/.orch.lock"     # orch-loop.sh writes its own $$; a second launch normally exits on it
```

⛔ **Read the DEEPEST process, never the first `pgrep` match.** A cell's controller is a 2–3-deep chain
(`tmux new-session` client → `bash -c` → `orch-loop.sh`), and the outer client can carry a *stale* env
from the launch that created it — measured on cell-3 during this audit: the first match reported
`MAX_LANES=6`, the deepest reported `10`. `MAX_LANES` is **derived, not configured**:
`install.sh` computes `MAX_LANES=${MAX_LANES:-$(( _NCPU * 5 / 2 ))}` (2.5 × cores) with a fallback of 10.
So Mac 25 (10 cores), 8-core cells 20, cell-3 10 (4 cores). **Do not "fix" a per-box MAX_LANES** — a
mismatch with 2.5 × cores means the *env* was not the plist's, not that the number is wrong.

---

## 3. What is wrong, measured

### 3.1 The Mac cannot read its repo from launchd — and the fix that works is live-only

**The failure (measured, reproduced three ways).** `[dispatch] #<n> NOT dispatched — could not build
claim commit` for 100% of candidates, while `gh` reads (cwd-blind) look healthy and `launchctl print`
says `running`. A throwaway `LaunchAgent` shows why — the denial is on the tree's **content**, not
merely on the cwd:

```
../Documents/GitHub/tortoise/pyproject.toml  read from a launchd-born /bin/bash : Operation not permitted
same read from a launchd-born tmux             : OK
git rev-parse --show-toplevel                  : fatal: Unable to read current working directory
```

`~/Documents` is TCC-protected and the launchd job holds no Full Disk Access grant. The claim registry
must push `refs/claims/*` **from inside `$REPO`**, so:

- ⛔ **A cwd-only fix is insufficient** — which is the shape #1996/#1990 describe (`( cd "$REPO" && git … )`
  plus a readable `WorkingDirectory`). `cd` into the repo *succeeds*; every read inside it still fails.
  That is worth stating plainly before #1990 lands, because it would otherwise ship as "fixed".
- ✅ **What actually works, and is running now**: the **Full Disk Access grant is attached to the `tmux`
  binary**, so a process in a tmux pane inherits it. The job's entrypoint is a script that launches the
  controller as a tmux session (`tmux new-session -A -d -s orch-controller "exec /bin/bash '$O/orch-loop.sh'"`)
  and blocks while that session lives so `KeepAlive` stays honest. The session name is deliberately
  outside the `^(lane|fix|merge)-` prefixes so the controller is never counted as a lane or reaped.
- The job's `WorkingDirectory` is `~/orchestrator` (outside TCC). While it pointed at the repo, every
  child got `getcwd: cannot access parent directories`, which broke `python3` (`PermissionError`) and
  therefore the refresh's reap pass — that is how the candidate queue froze for six hours.

⛔ **Owner decision (unchanged, and now cheap to state):** the tmux-pane entrypoint depends on an FDA
grant attached to one binary on one machine. The durable alternatives are (a) make that grant explicit
and re-grantable after an OS update that re-signs the interpreter, or (b) move the canonical clone out
of `~/Documents` and point `REPO` at it, which is TCC-free but moves the tree every lane works in.

⛔ **This box's runtime was edited live, by more than one lane.** At 12:42Z this audit installed
`64385b25` into `~/orchestrator` and verified all files byte-identical; by 12:53Z a concurrent lane had
written **five** live-only edits over it, none of which is on `origin/main`:

```
claims.sh              47,291 B  12:47:04Z  afea5179ea0a…  (adds a _claim_debug_log that logs cwd=[$PWD])
orch-loop.sh          128,112 B  12:49:37Z  fd44db41c936…  (main at 64385b25 is 124,052 B — below)
launchd-controller.sh   3,246 B  12:46:19Z  — not on main; it is the plist's ProgramArguments now
launchd.plist.template  c545f507  12:52:43Z  — not on main; it is what POINTS ProgramArguments there
install.sh             923ddfa7  12:53:01Z  — not on main; adds the entrypoint to its DRIFTED check
com.eldato.orchestrator-loop.plist — ProgramArguments rewritten 12:46:23Z
```

**The lift is in flight, not hypothetical: PR #2020** (`fix/lift-live-only-harness-fixes`, head
`7ef31cde`) carries `claims.sh`, `install.sh`, `launchd-controller.sh`, `launchd.plist.template` and
`orch-loop.sh`. Check its state before re-authoring any of them — and the whole point stands while it is
unmerged: until it lands, one command reverts all five, on the box, silently.

**`orch-loop.sh`'s 4,060-byte delta is THREE behaviour fixes, not instrumentation** — lift it as such;
lifting one or two of the three leaves the queue able to silence its own repair:

1. `queue_age_secs` — an unreadable queue mtime returns a LARGE age, never `0` (`0` reads as "the queue
   is fresh, leave it" and re-freezes it).
2. An **age-based refresh trigger** (`REFRESH_MAX_AGE`, default 1800s) beside the old `backlog < 6`.
   Measured: a refresh ABORTed mid-pass and left a PARTIAL `candidates.txt` of 42 entries. 42 is not
   `< 6`, so no refresh ever spawned again and the queue froze for six hours — the larger the backlog,
   the less likely anything refreshed it. Age is the trigger that cannot be starved by its own input.
3. Dispatching in `$O/.pool` order instead of `candidates.txt` order, because the queue is
   **append-only** — so, as its own comment records, the live queue had **12 open P0-blockers sitting at
   positions 28–29 of 47** while P2 work dispatched (#8465's severity inversion re-entering through the
   append path instead of the pool sort).

None of the three is on `origin/main`; all three are in #2020.

**This is the loss mode this file exists to prevent**, caught in the act: the working fix is live-only,
so the next `deploy-mac-orchestrator.sh` (or any harness install) silently reverts it and the box goes
back to refusing every candidate. It must be lifted into `scripts/orchestrator-harness/` (entrypoint
included in `launchd.plist.template`) before any redeploy — see §5.

**⛔ AND "any harness install" INCLUDES the supported one.** Re-measured 13:15Z, the revert is in
shipped code, so no operator error is needed to trigger it — but **which copy you run decides the
effect**:

- **`launchd.plist.template` is the pivot, and the live one is already patched** (`c545f507` emits
  `__O__/launchd-controller.sh`; main still emits `__O__/orch-loop.sh`). `install.sh` renders
  `TEMPLATE="$HERE/launchd.plist.template"` and then `mv -f`s the result over
  `~/Library/LaunchAgents/com.eldato.orchestrator-loop.plist` on the **install path — bare `install.sh`,
  `--start`, `--restart`** (only `--uninstall` skips the render, and that one deletes the plist instead).
  So `bash ~/orchestrator/install.sh` **preserves** the entrypoint *only because the live template beside
  it is the patched one*; the SAME command run from the repo renders main's template and deletes it. A
  bare `install.sh`'s header says it "NEVER touches a running job" — true of the *job*, false of the
  plist FILE.
- `install.sh` is itself live-only, and it is a GUARD rather than a bystander: its `DRIFTED` list gained
  `launchd-controller.sh`, so it is what makes a harness install *report* the unshipped entrypoint at all.
  Copying main's `install.sh` over it removes the detector for the defect this section describes.
- ⛔ **`deploy-mac-orchestrator.sh` PHASE=A silently reverts the template, and no checker can see it.**
  It does `git archive "$SRC_REF" scripts/orchestrator-harness` and copies every entry, so it overwrites
  the patched `launchd.plist.template` (and `README.md`) with `origin/main`'s. `check-deployed-drift.sh`
  hashes only `*.sh` (`grep -E "^${REL}/[^/]+\.sh$"`), so this is drift it structurally CANNOT report —
  §2's hand loop is the only read that sees it. Safe once #2020 merges; not before.
- `check-deployed-drift.sh` reports the `.sh` state correctly — `DRIFT: launchd-controller.sh — present in
  /Users/danielospina/orchestrator but NOT shipped by the repo at origin/main (a hand-placed or retired
  script)`, exit 1 — and then prints a remedy that **causes the loss**: `cp …/harness/*.sh $O/ && install.sh`.
  Following it byte-overwrites `claims.sh`, `orch-loop.sh` and `install.sh` with main's bytes — discarding
  three of the five — and then runs the **repo** copy of `install.sh`, which renders the **repo** template.
  Until #2020 merges, treat that printed remedy as ⛔ and use §5's sequence instead. A checker must not
  hand out a remedy that destroys the condition it was asked to report.

### 3.2 lane-1 is merge-inert: the queue repo and the checkout name different repositories

```
[merge 1941] repo-authority: required=[pipeline-compliance] source=env authority=rail
[merge 1941] REFUSED: merge authority for daniel-ospina/agent-infra is its rail, but
             /tmp/cell-t3/scripts/admin-merge.sh does not exist — refusing to fall back to a raw
             gh pr merge (agent-infra#1764)
```

`keys.env` carries `OR=daniel-ospina/agent-infra` with `REPO=/tmp/cell-t3`, and `/tmp/cell-t3`'s origin is
**tortoise**. Every agent-infra merge looks for the agent-infra merge rail inside a tortoise tree and
refuses. `cloud-cell-supervisor.sh check` (main's code) refuses the pair outright:

```
FATAL: the QUEUE and the CHECKOUT name DIFFERENT repos … (agent-infra#1901)
```

**Why it was left running and un-deployed — stated precisely.** `cmd_start` calls `assert_queue_target`
**first** (before `harness_apply`), so `start` refuses *without touching the harness tree*. But the
documented deploy is `stop` → `start` (because `cmd_apply` refuses while a controller runs), and the
refusal then lands *after* the stop. So the sequence would leave the box **stopped, with the harness not
refreshed** — strictly worse than leaving it on `bed278f4`. Fix the pair first (point `HARNESS_REPO`, or
`--repo` on a `harness-up` run, at an agent-infra checkout — `REPO` is the **work** repo the controller
drains and must NOT name the harness; or drop the `OR` line so it derives from the checkout), then
`stop` → `start`.

### 3.3 Not deployed for scheduling reasons, not for correctness

cell-3 was one commit behind (`81a190ee` vs `64385b25`) with a `fix-8938` lane live at measurement time.
The delta is `orch-loop.sh` + `selftest.sh` (the swap gate must reflect present pressure). Deploy it at a
quiet moment: `bash <snapshot>/scripts/cloud-cell-supervisor.sh stop` then `start` (`start` runs `apply`
before launching). Note cell-3 also logged `#4812 NOT dispatched — could not build claim commit`, the
same message as §3.1 on a box with no TCC — so the claim-refusal message is not by itself evidence of a
TCC cause, and must not be read as one.

---

## 4. Proof of deployment has two halves — a `[cap]` line is not one of them

A `[cap]` line proves **the cycle runs**, not that anything dispatched: it is emitted even when every
candidate is refused. (Measured before this baseline: 793 consecutive `could not build claim commit`
refusals alongside healthy `[cap]` lines.) A real dispatch is:

```
[cap] load=54/100 lanes=3/25 …                      <- the cycle runs
[dispatch] load=45 lanes=2 -> 4628 4643             <- candidates actually entered the batch
+ a matching `tmux ls` session per issue (lane-4628, chain-4628)
```

Read both. `lanes=0` with a healthy `[cap]` and a non-empty backlog is the "alive but dispatching
nothing" shape, and it is the state this audit found on the Mac.

---

## 5. The deploy recipe each surface actually needs

- **Cloud cell** — `bash <snapshot>/scripts/cloud-cell-supervisor.sh stop` → `start`. `start` runs
  `apply` (fetch `origin/main`, write an immutable `<sha12>/` snapshot, move the pin, stamp) before
  launching. Never hand-edit a file inside a snapshot: it destroys the per-file provenance proof.
- **Mac** — do **not** use `deploy-mac-orchestrator.sh` phase B on a launchd-loaded box. Two measured
  consequences: its `nohup bash "$O/orch-loop.sh"` child **inherits the operator shell's TCC grant**, so
  it dispatches while the durable launchd job cannot (a false PASS reported as success); and it does
  **not** write `$O/.agent-infra-stamp.json` (this box's stamp was 1.5 days stale, `a4a12497`, while the
  runtime held other bytes). It also relaunches from its own environment, so `SCOPE` drops from the
  plist's `own` to `orch-loop.sh`'s `auto` default — an unpinned cell draining the shared queue.
  ⛔ **The entrypoint survives or dies by WHICH `install.sh`/template you run — not by a flag (§3.1).**
  `bash ~/orchestrator/install.sh --restart` renders the box's OWN patched `launchd.plist.template` and so
  KEEPS the tmux entrypoint, and it is the restart that **proves itself**: it goes through
  `launchd-cycle.sh` (`enable` → `bootout` → `bootstrap`, never `unload -w`) and then asserts a pid **and**
  an advancing heartbeat, instead of trusting that a `bootstrap` returning 0 means the loop is running —
  which is how #1975 left the controller removed AND disabled while the installer exited 0. ⚠️ It
  re-renders **every** limit and `SCOPE` from the CALLER's environment, so it is only safe invoked with
  the box's pinned values; without them it re-pins `own` → `auto`, the same trap as phase B above.
  ⛔ The REPO copy (`scripts/orchestrator-harness/install.sh`) renders main's UNFIXED template and
  deletes the entrypoint — that is the revert.
  ⛔ **And not phase A either, while #2020 is unmerged**: it copies `origin/main`'s
  `launchd.plist.template` (and `claims.sh`) over the box's patched/live-only copies, and no checker can
  see the template half (§3.1) — so the next install reverts the entrypoint. The atomic `cp`+`mv` phase A
  uses is still the right *method*; the wrong *source*. Until #2020 merges, touch only what §1.1 shows as
  behind — never `claims.sh`, `install.sh` or the template — and restart with the runtime `install.sh
  --restart` above.
  If you must drive launchd by hand instead (the runtime `install.sh` is unavailable), the sequence is
  `launchctl enable gui/$(id -u)/com.eldato.orchestrator-loop` →
  `launchctl bootout gui/$(id -u)/com.eldato.orchestrator-loop` →
  `launchctl bootstrap gui/$(id -u) <plist>` — in that order, and understand that this one does **not**
  prove itself: check `launchctl print` names a pid AND `logs/heartbeat` advanced.
  ⛔ Never `launchctl unload -w` / `load -w` (a persistent disable). ⛔ Never an unscoped `pkill`.
  ⛔ **Stop `com.eldato.orchestrator-watchdog` before the cycle and start it after** — it reloads the
  loop when it sees the job absent, so it resurrects the job mid-change (measured: a `bootout` looked
  ineffective because the watchdog had already put the job back).
- **When two controllers ARE alive** (measured 12:36Z: pids 165 and 1409, both cycling — one with
  `SCOPE=auto`, one `SCOPE=own` — while `.orch.lock` named only one). `acq()` makes a *second launch*
  exit on the lock, but it cannot stop a controller that acquired the lock **before** the lock was
  removed: the Mac deploy does `rm -f "$O/.orch.lock"` after killing the old pid, so a launchd
  `KeepAlive` respawn and the deploy's `nohup` child can each acquire in the window between. Converge by
  stopping the stray by **exact pid** (enumerated with `ppid` + `cmdline` first), then bootout/bootstrap
  a single launchd-owned controller, and confirm `.orch.lock` names it.
