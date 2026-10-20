# Scheduled jobs — one declaration, one gate, one command (agent-infra#2048)

The fleet's scheduled work is declared **once** and rendered for both platforms. Nothing about a
schedule lives only in a unit file, a launchd plist, or someone's `~/Library/LaunchAgents`.

| | |
|---|---|
| the declaration | [`config/scheduled-jobs.declaration`](../../config/scheduled-jobs.declaration) |
| the reasoned exclusions | [`config/scheduled-jobs.unmanaged`](../../config/scheduled-jobs.unmanaged) |
| the command (`install`/`status`/`start`/`stop`/`restart`/`uninstall`/`parity`/`list`) | [`scripts/scheduled-jobs.sh`](../../scripts/scheduled-jobs.sh) |
| the gate | [`scripts/check-scheduled-parity.sh`](../../scripts/check-scheduled-parity.sh) |
| parser + renderers + live-surface readers (one implementation) | [`scripts/lib/scheduled-jobs.sh`](../../scripts/lib/scheduled-jobs.sh) |
| the portability shim every component uses | [`scripts/lib/portable.sh`](../../scripts/lib/portable.sh) |

## The failure this removes

Measured 2026-10-18, on the two kinds of box the fleet runs on:

| surface | scheduled components |
|---|---|
| macOS host (`~/Library/LaunchAgents`) | **35** files (24 in the fleet's namespace) |
| `install.sh` / `pi-bootstrap` | **1** (`com.eldato.orchestrator-loop`) |
| `templates/systemd/` | **0** units — the Linux cells received none of the scheduled harness layer |

Nothing was lying. No component claimed a job it did not have. **Nobody compared the two
directions**, so 34 of 35 schedules existed only as machine state on one laptop: not declared, not
reproducible, and lost the day that disk (or its user) forgot them. Meanwhile the cells — which have
no crontab and no launchd — accumulated disks at 100% twice in one day.

Two defects, one root:

- **#2048** — one installer that schedules the consolidated disk reaper on **both** platforms, from
  one declaration, with a parity check that fails in either direction.
- **#2046** — the same class in a second register: components that *installed* and then failed to
  *execute* on one platform because they used GNU-only flags (`timeout`, `date -d`, `stat -c`,
  `nproc`). On the laptop `timeout` does not exist, so every class of the disk reaper died with
  `timeout: command not found` (rc=127 → fail-closed) **while the pass completed** and printed
  `verdict=fail-closed` — a false PASS that freed 0 MB.

## The declaration

One record per scheduled job; both platform artifacts are rendered from it.

```
job eldato-disk-reaper
  description=eldato disk reaper — bound uv caches, reap dead lane venvs and merged worktrees
  platforms=linux,darwin
  schedule=hourly
  script=disk-reaper.sh
  runner=python-launcher
  arming=report-only
  managed=yes
  label=com.eldato.disk-reaper
  unit=eldato-disk-reaper
  env DISK_REAPER_STATE_DIR=@state
```

| key | meaning |
|---|---|
| `platforms` | `linux,darwin` — every listed platform must render and run it |
| `schedule` | `hourly` · `daily` · `weekly` · `<N>s` · `<N>m` · `<N>h` |
| `script` | resolved at install: `$SJ_FARM` (the farm) first, then this repo |
| `runner` | `bash` · `python` · `python-launcher` (the macOS TCC seam, #427/#1095: a launchd-spawned `bash` cannot read a repo under `~/Documents`, so the job starts an interpreter that can and hands it the script — on Linux the same record renders a plain bash `ExecStart`) |
| `arming` | `report-only` (the shipped stance, #1678) or `armed`; the flag is rendered **into** the artifact |
| `managed` | `yes` = `scheduled-jobs.sh` installs it · `no` = another **named** `owner` does, and `install` delegates to that owner |
| `label` / `unit` | the launchd label / systemd unit base |
| `env KEY=VALUE` | repeatable; `@home @path @state @repos @tortoise` are rendered from machine state |

**An unknown key is a validation error**, not a comment: a misspelled `platfroms=` would otherwise
render a Linux-only job and report parity clean — the silent default this feature exists to remove.
So is a missing `owner` on a `managed=no` record, a `darwin` record with no `label`, and a
`managed=yes` record whose script does not resolve.

## The gate — `check-scheduled-parity.sh`

It compares the declaration with the **live** host, in both directions, and it is what would have
caught the 34 undeclared components on the first run:

| verdict | meaning | exit |
|---|---|---|
| `UNDECLARED` | the host runs a scheduled job the declaration does not name | FAIL |
| `MISSING` | the declaration names a job this host does not run | FAIL |
| `INERT` | declared + installed but not loaded/enabled — it never fires | FAIL |
| `SCHEDULE-DRIFT` | the installed interval is not the declared one | FAIL |
| `PAYLOAD-DRIFT` | the installed artifact is not what the declaration renders — a **second** `ExecStart=`, a second trigger, an added `Environment=`, a replaced program, a missing unit | FAIL |
| `NO-JOBS` | the surface was readable and carried **zero** in-scope jobs | FAIL |
| `STALE-REGISTER` | the unmanaged register names a job that is no longer live | FAIL |
| `RETIRING` | a register entry whose label `templates/launchd/RETIRED` declares retired **and** which is still live here — the removal simply has not run yet | note (counted) |
| `NO-REASON` | an unmanaged entry carries no reason | FAIL |
| `CONFLICT` | a job is both declared and registered as unmanaged — or two mechanisms clock the same job (a crontab line running the declared script) | FAIL |
| `UNMANAGED` | live, not declared, registered **with a reason** | ok, counted |
| out-of-scope | a third-party agent (`com.google.*`, `com.premise.*`, …) | ok, counted |

⛔ **An unreadable surface is exit 3, never 0.** "I found no undeclared jobs" must be distinguishable
from "I looked at nothing". The same rule applies to the declaration (zero records is a failure) and
to a readable-but-empty surface (`NO-JOBS`).

⛔ **A MISSING TOOL IS NOT AN UNREADABLE SURFACE.** `crontab` is not installed on every host
(measured: absent on a stock macOS dev box, `crontab -l` → 127), and classifying that with the genuine
read failures made `install` end `rc=1` through its own closing gate — so `pi-bootstrap/setup.sh`
reported *"this Mac has NO disk-reaper schedule"* over units it had just installed, on every sync.
When the client is absent the library reads the **daemon's spool** (`/var/spool/cron/crontabs/$USER`,
`/var/spool/cron/$USER`, `/var/at/tabs/$USER`), because a daemon reads the spool without the client and
an entry can therefore exist where the client does not; a spool file that exists but cannot be read is
still exit 3. Only when there is no spool entry is the surface an empty, **counted** one — and the gate
says so in its `measured cron:` line (`cron_tool=absent` in the reader's `#meta`), so "no cron client"
never silently stands in for "no cron entries".

`--static` (the CI mode) touches no scheduler: it validates the declaration and **renders every
record for every platform it declares** — a systemd unit + timer and a launchd plist — refusing an
unresolved placeholder, an empty `ExecStart`, or a malformed plist. That is what makes "one
declaration rendered for both platforms" true rather than claimed.

⛔ **"Unresolved placeholder" means any `@`-word that survives rendering, not only `{{`.** A `args=`
word beginning with `@` is a machine-state placeholder by construction (`@home @path @state @repos
@tortoise @installed`) and is resolved per word; a token no resolver knows is a declaration **error**,
because rendering it verbatim puts an argument no program can use into the job's argv. The check looks
for `{{` **and** for `@`-words, and an email inside an env *value* is content, not a placeholder.

⛔ **`@repos` IS READ FROM THE BOX AND GIT-VALIDATED — it is never defaulted.** It renders the repo
list the reaper's venv and worktree classes scan, from `$SJ_REPOS`, else `$SJ_TORTOISE_REPO,
$TORTOISE_REPO, $REPO, $WORKDIR, $AGENT_INFRA_PATH`, keeping an entry **only when `git -C` answers for
it**, `:`-separated. The old default was `$HOME/Documents/GitHub/tortoise` — macOS-shaped — and a
**non-empty wrong value is worse than an empty one**: `scripts/disk-reaper.sh` consults its own
candidate chain only when `DISK_REAPER_REPOS` is *empty*, so a phantom path left `REPOS` empty and both
per-worktree classes took their `FAIL-CLOSED — no repo to scan` arm (rc 3) on every pass while
`install`/`status`/the gate all read green. An empty resolution stays **empty** (the reaper's own chain
then runs on `REPO`/`TORTOISE_REPO`/`WORKDIR`/`AGENT_INFRA_PATH`) and is announced at render time.
A rendered `args=` must also be **parseable by the program it names**: `--repo` takes a value, so it may
never be the last word (measured: `args=@tortoise --repo` rendered `--repo` with nothing after it, and
`--static` blessed it).

### The unmanaged register

[`config/scheduled-jobs.unmanaged`](../../config/scheduled-jobs.unmanaged) is the one sanctioned
exit from `UNDECLARED`: `<label|unit base>|<reason>`. It is a **work list, not an amnesty** — an entry
whose job is gone is `STALE-REGISTER`, and an entry that duplicates a declared record is `CONFLICT`.
Every entry names who actually installs it, so the register shrinks as those jobs are templated or
retired.

**One stated exemption, and it is exactly as wide as the retirement manifest.** A label listed in
[`templates/launchd/RETIRED`](../../templates/launchd/RETIRED) is a job the fleet is *removing* —
`install-launchd.sh:retire_pass` boots it out and deletes its plist on the next run. Such an entry
whose job is gone is **green** (counted as `retired=`), because "the job disappeared" is the one thing
that entry asks for; and such an entry whose job is **still live** is reported as `RETIRING`, because a
duplicate clock is real until the removal runs. Without this, the two retired per-class reapers made
the gate fail forever on the Mac it was built for — `install` exited 1 over the two jobs it had just
retired in the same run, and `pi-bootstrap/setup.sh` then reported *"this Mac has NO disk-reaper
schedule"* over an installed one. Every **other** entry that outlives its job is still `STALE-REGISTER`.

## The command

```
bash scripts/scheduled-jobs.sh install                 # converge the whole declared set for this platform
bash scripts/scheduled-jobs.sh install --apply         # arm (the flag lands INSIDE the artifact)
bash scripts/scheduled-jobs.sh install --preview       # render and show; write nothing
bash scripts/scheduled-jobs.sh install --only eldato-disk-reaper
bash scripts/scheduled-jobs.sh status                  # installed? loaded? armed? last exit? drift?
bash scripts/scheduled-jobs.sh start|stop|restart      # act on the SET
bash scripts/scheduled-jobs.sh uninstall               # only what this command installed
bash scripts/scheduled-jobs.sh parity                  # the gate
```

- **One command for the whole set.** Records with `managed=no` are **delegated** to their named owner
  installer, so you do not need to know which job is whose; a missing owner is a failure, never a
  skip. `install` finishes by running the parity gate — the set is only installed if the host agrees.
- **Idempotent.** A second install re-renders nothing, reloads nothing, and issues no new bootstrap.
- **A changed script reloads its job (#1738).** Each script's SHA-256 is stamped; a byte change forces
  a reload even when the artifact text is identical, and `status` prints
  `pass_drift=CHANGED since install` for a stale install.
- **⛔ A non-zero exit or an absent unit is a FAILURE, never OK.** `status` exits 1 for `ABSENT`,
  `INERT` or a non-zero `last_exit`, 3 when the scheduler cannot be measured, 0 only when every
  declared job is installed, loaded and clean. A systemd unit carries **no** `SuccessExitStatus`
  unless the record DECLARES one (`success_exit_codes=`, #2071): the retired unit's
  `SuccessExitStatus=0 4 5` made a pass that failed a class read as success to `systemctl status`, and
  the one record that does declare a set (`eldato-disk-reaper` → `0 6`) accepts exactly one non-zero
  code, the routine "a delegate DEFERRED the pass" — 3 (fail-closed), 4 (a removal FAILED) and 5 (over
  bound) all stay RED. Which non-zero exits mean "the pass did its job" is a per-record decision, so
  it lives in the declaration and is re-rendered by the parity gate like every other field.
- **Arming is visible (#1678).** The shipped stance renders the report-only flag into the artifact;
  `--apply` renders the armed flag; `status` reads the arming off the **installed** artifact, never
  from the flags the invocation was given.

## The portability shim — `scripts/lib/portable.sh`

Every scheduled component sources it, and a component that cannot load it **refuses at startup**
(exit 3): running on with no helper is exactly the #2046 shape — the work silently does not happen
while the component reports a considered result.

| helper | why the platform difference bites |
|---|---|
| `_timeout <secs> <cmd…>` | `timeout` is GNU coreutils; macOS ships neither it nor `gtimeout`. Resolution `timeout` → `gtimeout` → an internal background watchdog (same contract: 124 = timeout). `0` = unbounded; a non-integer bound is 125 **without running the command** (fail-closed, never fail-open) |
| `_nproc` | `nproc` is GNU; macOS has `sysctl -n hw.ncpu`. Returns EMPTY + non-zero rather than a fabricated `1` |
| `_stat_size` / `_stat_mtime` / `_stat_dev` | `stat -c` is GNU, `stat -f` is BSD, with different letters. Exact bytes, epoch seconds and device id |
| `_date --epoch/--iso/--parse/--add/--fmt` | `date -d` does not exist on the BSDs, and BSD `date -j -f '%Y-%m-%d'` fills the **time of day from the current clock** (measured: `1970-01-01` parsed to 4016, not 0). One rule, both platforms; an unparseable value is EMPTY + non-zero, never `0` (which is a real timestamp) |

The engine (`scripts/lib/bounded.sh`, merged for #2046) is loaded by the shim, so there is ONE
implementation of the bound. A missing engine, or a pinned-but-unusable `TB_TIMEOUT_BIN`, is a
refusal — a pin that is silently ignored is the defect the refusal exists to prevent.

## Tests

| suite | owns |
|---|---|
| [`scripts/lib/portable.test.sh`](../../scripts/lib/portable.test.sh) | the shim, asserted **on the platform it runs on** against that platform's independent truth: a real overrun is 124 and the child actually stops; a non-integer bound is 125 and the command does not run; `_nproc` equals `sysctl`/`getconf`; `_stat_size` is exact for a name with spaces, a tab and a newline, an empty file (0 is a value) and a leading dash; `_date` round-trips ISO/date-only/`@epoch`/relative/`--fmt`; a missing engine is a refusal; the whole shim loads under the platform's **system bash** (macOS 3.2 — a bash-4-ism would pass on Linux CI and break the laptop) |
| [`scripts/check-scheduled-parity.test.sh`](../../scripts/check-scheduled-parity.test.sh) | both directions of the gate, on fixture hosts: `UNDECLARED`, `MISSING`, `INERT`, `SCHEDULE-DRIFT`, the **34-of-35 case literally** (35 live jobs, 1 declared ⇒ exactly 34 findings), `UNMANAGED`/`NO-REASON`/`STALE-REGISTER`/`CONFLICT`, out-of-namespace exclusion being **counted**, unreadable surface = exit 3, readable-but-empty = `NO-JOBS`, the systemd side, and crontab |
| [`scripts/scheduled-jobs.test.sh`](../../scripts/scheduled-jobs.test.sh) | the command: one record → both artifacts with the same script/args/env; `install` delegating the unmanaged record; idempotency (`changed=0`, no new bootstrap); arming rendered into the artifact and read back by `status`; `start`/`stop`/`restart` reaching **every** declared unit and label; `ABSENT`/`FAILED` making `status` non-zero; a changed script reloading its job; every impossible state loud (`--only` naming nothing, missing owner, unknown platform, temp HOME on Darwin); `uninstall` leaving the unowned job alone; `--preview` writing nothing; and **the shim used by every component**, with the population derived from the declaration (a component added tomorrow is covered without touching the test) |

`run-bash-shards.sh` runs all three in both CI lanes.

## What is not managed yet, and why that is written down

17 live jobs on the Mac are in the unmanaged register with a reason: role-agent jobs installed by
another deployer, tortoise-repo schedules that repo owns, and the two per-class reapers retired into
the consolidated pass. `install-launchd.sh` removes the retired ones on its next run; those two entries
stay green (they are the retirement notice — see the exemption above) and every other entry is
`STALE-REGISTER` the moment its job is gone — the register is designed to shrink, and the gate refuses
to let it lie.
