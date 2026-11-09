---
title: "Activation matrix — how each harness component becomes ACTIVE on a Mac vs a Linux cell"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-19
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, activation, gh-shim, review-enforcer, cloud-cell-bringup, cell-install, launchd, orchestrator-harness
---

# Activation matrix — provisioned vs improvised

**The question this answers.** "Deployed" and "active" are different states, and the harness has
never stated the difference in one place. A cell can carry the whole operational layer and still
have a *merge gate that is not enforced*, because the layer arrives as **files** while a handful of
components only become **active** through something else: a shell profile, an env var, a launchd
plist, a tmux command string.

Measured 2026-10-19 on this laptop (`Daniels-MacBook-Air-new`) and on the three live cmux cells
(`pi-lane-1` / `pi-cell-2` / `pi-cell-3`). Every row below was read from the artifact, not from an
installer's promise. Where a row is a *state* that no file declares, it says so.

## Legend

| verdict | meaning |
|---|---|
| **provisioned** | a shipped file installs it, and a read-back verifies it. Re-running the installer restores it. |
| **provisioned (on demand)** | a shipped *code path* creates it the first time it needs it. An installer neither creates nor restores it; it reappears with the next run of the controller. |
| **improvised** | it works today because of something a human or a lane did by hand — a shell-rc line, a hand-written plist, a symlink into a worktree, an operator-pushed file. Nothing re-creates it. |
| **absent** | it is not there. Not degraded, not partial. A read that *failed* is never recorded as absent — see the abstention notes in rows 8, 10 and 16. |
| **mixed** | provisioned on some boxes and not on others; the row's own body names which, and every box in it was MEASURED. Used where a single verdict would be a claim about boxes nobody read. |

## The matrix

| # | component | mac | cell | the file that activates it | divergence risk |
|---|---|---|---|---|---|
| 1 | **`gh` shim source** — the argv-level admin-merge guard (`scripts/gh-shim/gh`) | **provisioned** | **mixed** (Mac + cells 3/4 present; cell-1's account home stale) | `pi-bootstrap/setup.sh::merge_gate_srcs` farms it and `pi-bootstrap/cell-install.sh` fails the install without it (this column read *nothing installs it* until #3297 — measured stale on 2026-11-02, which is how a cell kept running degraded). `extensions/review-enforcer/index.ts::resolveGhShimDir` resolves `$AGENT_GH_SHIM_DIR`, else `EXTENSION_DIR/../../scripts/gh-shim` | **HIGH** — the only layer a **token** splice cannot defeat (`--ad""min`, `$'--admin'`, `xargs {}`); a *discarded* PATH entry still defeats it, which is the shim's own declared limit (`ghShimWillEnforce`). **Re-measured 2026-11-02 (this column previously read `absent` and was stale):** on this Mac `~/.pi/agent/scripts/gh-shim/gh` is PRESENT and executable (byte-identical to the checkout, farmed 11:37), as is its `verify-admin-merge-evidence.sh` sibling, so resolution succeeds with `AGENT_GH_SHIM_DIR` unset. `pi-cell-3` and `pi-cell-4` are PRESENT+EXEC in both the account home and `/tmp/cell-home`. `pi-cell-1` is the one degraded box: its ACCOUNT home carries a six-entry `scripts/` with `gh-shim/gh`, `review-pr.sh` and the verifier all MISSING — an install that predates the `merge_gate_srcs` farm — while its `/tmp/cell-home` is complete; its own `task-runs/*.log` carry the `#984` warning. Measure the box, never this cell. Degradation was LOGGED ONLY (`#984 argv-level gh shim not found`) and the gate silently fell back to string scanning; **#3297 makes the absent layer REFUSE the admin-merge certification** (`ghArgvLayerRefusal`, one `gh_shim_degraded` gate event, `AGENT_GH_SHIM=0` keeps the old posture) |
| 2 | **`~/.pi/agent/shims` on PATH** | **improvised** | **absent** *where a tmux server exists to read* | mac: `~/.zshrc` (hand) + the extension's `withGhShim` absolute-path injection; cell: nothing | **MEDIUM** — for the extension's own calls PATH is irrelevant (it injects an absolute dir), so the *guard* does not need this; a lane that types `gh` does. On this box an interactive shell's PATH begins with that directory (twice — inherited, then injected). The **daemon** PATH deliberately excludes it (`install.sh` `add_dir` refuses `*/shims`; `deploy-mac-orchestrator.sh:220` same; `selftest.sh:641-642` and `:2043-2044` pin it) for macOS TCC. The cell controller's measured PATH is stock: `/usr/local/nvm/versions/node/v24.21.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin`. ⛔ On `pi-cell-2` there is **no tmux server at all**, so that box's PATH is an **abstention**, not an absent reading |
| 3 | **extensions loaded** (review-enforcer, verification-gate, sequence-enforcer, loop-enforcer, auto-sync, repo-freshness, reflect-hook, task-heartbeat, session-checks, mcp-client, builtin-tools, …) | **provisioned** | **provisioned** | mac: `pi-bootstrap/setup.sh` (real copies refreshed from `extensions/*`); cell: `pi-bootstrap/cell-install.sh::install_extensions` from `manifest.json`'s ship-list (31 of 32; `cmux-session.ts` denied by design) | **LOW-MED** — content is byte-compared by `--verify`. Residual: a cell never auto-refreshes from a git pull, the Mac does on every `setup.sh` |
| 4 | **extension runtime deps** (`node_modules` for `builtin-tools`, `mcp-client`, `loop-enforcer`, `custom-provider-qwen`) | **provisioned** | **provisioned** | mac: `setup.sh`; cell: `cell-install.sh::install_extension_deps` (`npm install --ignore-scripts`, scrubbed env) | **LOW** — measured present on both (`builtin-tools/node_modules` exists on the Mac and on `pi-lane-1`) |
| 5 | **hooks: `session_start` / `reflect`** | **provisioned** | **provisioned** | they are *extensions*, not a hooks dir — `session-checks.ts` + `reflect-hook.ts`. `~/.pi/agent/hooks/` does not exist on either side | **LOW** — `reflect-hook` needs the cloud opt-in; `pi-lane-1`'s `keys.env` carries `TORTOISE_CAPTURE` |
| 6 | **hooks: git `pre-commit` / `commit-msg`** (`.husky/*`) | **absent** | **absent** | *nothing.* Needs `git config core.hooksPath .husky` per repo — repo-local state, which no layer installer can set | **MEDIUM, and silent** — measured: `core.hooksPath` unset in **both** `tortoise` and `agent-infra`, and `.git/hooks/` holds **0** non-sample hooks. `AGENTS.md` states the pre-commit hook enforces agent-infra version sync; it does not run today on either platform |
| 7 | **controller entry point** | **improvised** | **provisioned** | mac: **the shipped** `scripts/orchestrator-harness/launchd.plist.template` renders `__PROGRAM__`, which `install.sh` sets to the stable stub `$O/orch-pin-exec.sh` (agent-infra#3309 — it resolves the pin's entrypoint on every tick), → `com.eldato.orchestrator-loop`; cell: `scripts/install-controller-service.sh` renders `templates/systemd/eldato-orchestrator.service` and `scripts/cloud-cell-bringup.sh::check_controller_service` runs that installer on every bring-up, so `start` is the unit's main process (`Environment=ORCH_FOREGROUND=1`); `scripts/cloud-cell-supervisor.sh::cmd_start` reaches `tmux new-session … bash orch-loop.sh` **only** when no unit is installed, or when the operator explicitly disabled it (#2402) | **MEDIUM** — measured divergence on this Mac: the **installed** plist's `ProgramArguments` is `/bin/bash $O/launchd-controller.sh`, and `launchd-controller.sh`'s tracked copy **IS in `origin/main`** (`git ls-tree origin/main` → blob `d2c78ab8`; this PR re-pins it to `f9ba6e7c`) — the untracked artifact is the **installed** plist's target, a home-dir copy in `~/orchestrator`, and a `.bak-divergence-*` next to the plist records the edit. At measurement time a lane held uncommitted changes to both the template and that launcher, so treat this row as *in flight*, not settled. **Update (agent-infra#2231):** `install.sh` REFUSES when the resolved directory is not that worktree at the recorded sha — so the installed path can no longer be a copy. **Update (agent-infra#3309):** the rendered `ProgramArguments` program is neither the pin nor a home-dir copy but the STABLE stub `$O/orch-pin-exec.sh`, seeded from the pinned tree on every install; it reads the pin dir record on each tick and execs `<pin>/launchd-controller.sh` when the pin carries it, else `<pin>/orch-loop.sh` — which is what survives a pin advance, since launchd reads `ProgramArguments` once at bootstrap and the hash-named pin tree is garbage-collected as the pin moves. `install.sh` refuses unless the stub, run with `--resolve-only`, resolves to the pin's own entrypoint. ⛔ The pre-#2020 sentence that this file "still has to land" is WITHDRAWN — it is tracked, and `git ls-tree origin/main` names its blob (`d2c78ab8`, re-pinned by this PR to `f9ba6e7c`), so nothing is waiting on PR #2020 for the file to exist; see `scripts/orchestrator-harness/README.md` → "The Mac runs the PIN, not a home-dir copy" for the per-row parity table |
| 8 | **controller watchdog** | **improvised** | **absent** | mac: **as measured**, `~/Library/LaunchAgents/com.eldato.orchestrator-watchdog.plist` (`StartInterval` 20) → `/Users/danielospina/orchestrator/watchdog.sh`, absolute home hardcoded, installed by no surface in this repo. The TRACKED replacement now SHIPS: `templates/launchd/com.eldato.controller-watchdog.plist` (`StartInterval` 300) → `scripts/orchestrator-harness/watchdog-loop.sh`, rendered by `install-launchd.sh`'s own template loop, and the hand-provisioned label is listed in `templates/launchd/RETIRED` so the installer **unloads and removes it**. ⛔ THE TWO MUST NOT COEXIST, and they are NOT a redundant pair: the old job runs `watchdog.sh` (check → load → log → exit, idempotent) while the new one takes a NON-idempotent `launchctl kickstart -k`, so two loaded watchdogs are two MUTATING actors on one controller — this watchdog's restarts are disabled by retirement, not left to race. ⛔ **Nothing is installed by the change that ships the template** — the template is the capability; running `scripts/install-launchd.sh` is the activation, and until an operator runs it this row stays `improvised`. cell: the shipped `install-controller-service.sh` + `templates/systemd/eldato-orchestrator.service` (`Restart=always`, and `check_controller_service` installs it on every bring-up) is the supervisor above the controller; the pre-existing `orchestrator-harness/watchdog-loop.sh` cell branch still calls `cloud-cell-supervisor.sh start`, and nothing schedules it — the unit **replaces** the need for it only once it is installed on a box, which is a per-box state, not a repo fact | **HIGH** — this is the "self-healing" claim. A cell has found **no supervisor above the tmux session**: `crontab` is **not on the cell shell's PATH**, so no scheduled job was observable from that shell (that is not a "no cron installed" reading), and the user systemd manager is **not queryable from the cell shell** (`systemctl --user list-timers` → *Failed to list units*) — an **abstention, not a "zero units" reading**. #2130 measured the units directly on a cell (0 present, 0 enabled). Either way the controller can die and the only signal is a quiet queue |
| 9 | **operational tunables** (`MAX_LANES`, `MAX_LOAD`, `MAX_FIX`, `MAX_REVIEW`, `CYC`, `SCOPE`, `MERGE_PRIORITY_AT`, …) | **provisioned** | **improvised** | mac: rendered into the plist `EnvironmentVariables` by `install.sh` (`__MAX_LANES__` from the installer's own core probe); cell: operator-pushed `keys.env`, sourced by `cloud-cell-supervisor.sh` (`set -a; . $ENV_FILE`) | **HIGH** — measured: `pi-lane-1` and `pi-cell-3` both carry a `keys.env`, and **neither sets `PATH` (0 lines) nor `MAX_LOAD`**; `pi-cell-2` has **no `keys.env` at all** and no tmux server, i.e. no controller. A box with no `MAX_LOAD` is throttled only by the swap gate, and a box with no `keys.env` runs on whatever env the operator's session happened to carry |
| 10 | **daemon/controller PATH** | **provisioned** | **improvised** | mac: `__PATH__` rendered by `install.sh` from the dirs the binaries actually resolve to (refusing `*/shims` and `*/.pi/*`); cell: inherited from the tmux session that ran `start`, or from `keys.env` if it sets one (it does not) | **HIGH** — a cell's PATH is documented nowhere and reproducible only by re-running the same hand command |
| 11 | **`AGENT_INFRA_PATH`** | **provisioned** | **improvised** | mac: `pi-bootstrap/setup.sh:814` appends it to `$ZSHRC`; cell: whichever `keys.env` the operator wrote | **HIGH, and per-cell** — `scripts/orchestrator-harness/README.md` §4 states the requirement, and it is met by hand or not at all: measured **set** in `pi-cell-3`'s `keys.env`, **absent** from `pi-lane-1`'s. Where it is absent, `session-checks` / `auto-sync` **silently skip** and `sequence-enforcer` in gate mode reports an unpassable checkpoint |
| 12 | **provider auth** (`auth.json`, `models.json`) | **provisioned** | **provisioned** | both: pi's own credential store; cell bring-up pushes a verified key (`check_gh` / provider probe with a real call) | **LOW** |
| 13 | **scripts farm** (`~/.pi/agent/scripts`, incl. `record-review.sh` + `lib/diff-normalize.py`) | **provisioned** | **provisioned** | mac: `setup.sh` farms (real copies, #427); cell: `cell-install.sh::install_farms` reads the **same** arrays out of `setup.sh` (parsed, not re-listed) | **LOW** — the parse is floored (`MIN_FARM_FILES=20`) and byte-compared; measured 20 `*.sh` + `record-review.sh` + `lib/diff-normalize.py` on `pi-lane-1` |
| 14 | **skills + `AGENTS.md` + `settings.json` + sub-agents** | **provisioned** | **provisioned** | mac: `setup.sh`; cell: `cell-install.sh::install_skills` / `install_config` (`settings.json` merged, `AGENTS.md` installed only when absent) | **LOW** — measured present on `pi-lane-1` and `pi-cell-3`; **absent on `pi-cell-2`**, where `/tmp/cell-home/.pi/agent` holds only `audit/` and `skill-reads.json` — i.e. that box never received the layer at all (see 16) |
| 15 | **state + reviews dirs** (`$O/state`, `$O/logs`, `~/.pi/agent/reviews`) | **provisioned (on demand)** | **provisioned (on demand)** | created by shipped code the first time it needs them, both sides: `orch-loop.sh:251`, `record-review.sh:2140` | **LOW** — an installer neither creates nor restores these, so they are listed under their own legend row rather than as provisioned |
| 15b | **harness activation on a clock** (`harness-apply-pass.sh` → `cloud-cell-supervisor.sh apply` / `./sync.sh`) | **provisioned** | **provisioned** | `scripts/install-harness-apply-timer.sh`, run by `cloud-cell-bringup.sh --check` on a cell and by hand on a Mac (`com.eldato.harness-apply`); `--status` is the readiness gate | **HIGH until #2416** — this row did not exist, and the measured state was a Mac 91 commits behind `main` and a cell whose `HARNESS-PIN` named a commit its checkout did not have, with every signal reading `auto`. Rows 7-11 answer *what is deployed*; none of them answers *whether the deployed code is still main* — see `docs/ops/harness-apply.md` |
| 15c | **runner pool autoscale on a clock** (`runner_autoscale.py` — measure the box, derive the ceiling, converge the local pool) | **absent** (source ships; no installer has run) | **improvised** (pi-cell-1 only: this lane ran the installer and armed it; no bring-up or schedule re-creates it) | `scripts/install-runner-autoscale-timer.sh` renders and converges both platforms (`templates/systemd/eldato-runner-autoscale.{service,timer}` / `templates/launchd/runner-autoscale/com.eldato.runner-autoscale.plist`), farmed by `pi-bootstrap/setup.sh`; `--status` reports installed / armed / drift / last tick | **HIGH until #2403** — the converger landed in #2877/#2900 and **nothing ran it**, so a box kept whatever runner count it happened to have: pi-cell-1 measured 5 live against a measured ceiling of 3 (8 cores) while tortoise CI sat at 16-34 queued runs. `--install` is dry-run; `--arm` is a separate dated owner step, and it refuses a box that cannot measure its own ceiling. ⛔ **NOTHING INVOKES THE INSTALLER YET** — no bring-up check, no schedule-of-schedules — which is why the mac column reads `absent` and the cell column reads `improvised` rather than `provisioned`: farming the installer is a copy, not an install (row 8's own precedent), and this lane installed and armed pi-cell-1 by hand. Wiring `install-runner-autoscale-timer.sh --install` into `cloud-cell-bringup.sh --check` (installing DISARMED, like the harness-apply timer it sits beside) is the follow-up that turns this row into `provisioned` — see `docs/ops/runner-autoscale.md` |
| 16 | **a readiness verdict that measures the merge gate** | **improvised** | **absent** | `cloud-cell-bringup.sh --check` (`CELL READY`) probes home/tools/network/provider/gh auth/push/clone/dispatch-preflight/layer; `cloud-cell-supervisor.sh check` (`CELL CAN RUN A CONTROLLER`) probes `git python3 pi`, `gh auth status`. **Neither probes the admin-merge shim** — the supervisor's two shim probes are its own layers: the rate-limit layer (`[ -x "$O/gh-limit/gh" ]` then `"$O/gh-limit/gh" --version`) and, since #2039, the REST adapter (`[ -x "$O/gh-rest/gh" ]` then `"$O/gh-rest/gh" --version` — executed **by its own path**, never through a `PATH` lookup, because the kernel skips a candidate it cannot execute and continues the search, so a `PATH`-resolved probe certifies whichever `gh` it landed on; refused when the pinned harness ships the adapter and `$O` lacks it, or has it non-executable/unrunnable) — and neither of those is the guard (`scripts/gh-shim/gh`) | **HIGH** — this is the two-definitions-of-ready defect. `gh auth status` answers "is gh authenticated", never "is gh guarded". Measured: `pi-cell-2` has **no operational layer at all**, and `pi-cell-3` has the layer with **no `shims/`** — both can reach their own green banner. ⛔ And the new `activation:` line is **discarded** by the path an operator runs: `cloud-cell-bringup.sh:441` greps the installer's output down to `mode=--verify\|LAYER VERIFIED` |

## What the matrix says

Counting each **(component, platform)** pair: **8 improvised, 6 absent, 19 provisioned, 1 mixed**, plus 2 `provisioned (on demand)` — **36 pairs in all** (18 rows × 2). Recounted from the table on 2026-11-02 (row 1 moved to provisioned/mixed, row 15c added as absent/improvised).

The measured per-box state behind the cell column, so the generic verdicts above are not misread:

| box | layer | `keys.env` | controller | `shims/` |
|---|---|---|---|---|
| `pi-lane-1` | full (`AGENTS.md`, `agents/`, `extensions/`, `scripts/`, `skills/`, `reviews/`, `state/`) | yes — no `PATH`, no `MAX_LOAD`, no `AGENT_INFRA_PATH` | tmux (`orch`, plus `pk1`, `pack`, `closer2`, `diskreaper`) | `gh → /tmp/cell-ai/.worktrees/tm-1203/scripts/gh-shim/gh` (a lane's worktree) |
| `pi-cell-3` | full | yes — no `PATH`, no `MAX_LOAD`; `AGENT_INFRA_PATH` **set** | tmux (`p0a`, `p0b`, `restart`, `diskreaper`) | **absent** |
| `pi-cell-2` | **none** (`/tmp/cell-home/.pi/agent` = `audit/`, `skill-reads.json`) | **none** | **none** (no tmux server) | **absent** |

Three things, in order of how much they cost:

1. **Row 1 is the component that gates a merge, and it WAS improvised on the Mac and absent on
   cells** — it is now FARMED (`setup.sh::merge_gate_srcs` provisions `scripts/gh-shim/gh` and its
   verifier sibling; `cell-install.sh` fails the install without it), re-measured
   `provisioned`/`mixed` on 2026-11-02. Row 2 is the layer a merge *lane* uses and is still
   improvised/absent, but it is not the gate: the guard injects its own absolute PATH dir, so a lane
   that does not type `gh` itself never needed it. Rows 8 and 16 are improvised/absent too — but
   they cost *recovery* and *truthfulness*, not a merge, and #2130 already owns them. And this is
   **not** a cell-only defect: before the farm landed the Mac resolved the shim from a shell-rc line
   the launchd controller does not inherit,
   so "the Mac is activated" is true of interactive sessions and unproven for daemon-born lanes.
2. **The two rows that make the harness *unattended* are the two that cells do not have** — a
   watchdog (8) and an explicit env (9-11). A cell's controller now has a **shipped** service unit that
   restarts it (#2402, row 7), but the unit is a per-box install: until `install-controller-service.sh`
   has run there, the controller is still a tmux session with an ambient environment, watched by nothing.
   That is the gap between "runs" and "self-healing".
3. **Every gap is a *state*, not a file.** That is why it survived: `check-deployed-drift.sh`
   compares files, `--verify` compares files, and none of them can see a PATH, a shell-rc line, a
   `core.hooksPath`, or a plist that is not in the repo.

## Ranked fixes — the single change per gap, by landing capability restored

Ranked by how much capability the change restores. #1 was first for a reason — it is the layer that
decides whether a merge may happen at all — and it has since LANDED (`merge_gate_srcs`, plus the
`#3297` runtime refusal), so it is no longer the weakest on every cell: **the live list starts at #2**.

| rank | gap (rows) | the single change | why this one | cost |
|---|---|---|---|---|
| ~~1~~ **LANDED** | — | **Farm `gh-shim` onto the box** — DONE: `pi-bootstrap/setup.sh::merge_gate_srcs` declares `gh-shim/gh` **and** `verify-admin-merge-evidence.sh` (one declaration; `cell-install.sh` parses the same set and FAILS the install without the shim, `:477-480`), so it lands at `$DEST/scripts/gh-shim/gh` on **both** platforms. Row 1 re-measured `provisioned`/`mixed` 2026-11-02; the `#3297` runtime half makes an absent layer refuse rather than warn | `resolveGhShimDir`'s relative fallback is `EXTENSION_DIR/../../scripts/gh-shim` — that path is `~/.pi/agent/scripts/gh-shim` for a copied install, and it is what a **launchd-born** Mac lane and **every** cell lane resolves. Farming it fixes both sides with one declaration, needs no env var, and the extension then materializes `~/.pi/agent/shims/gh` itself (`materializeGhShim`) | one array + one layout row; `--verify` then byte-compares it for free |
| **2** | 9, 10, 11 | **Provision the env, do not inherit it**: a `keys.env` *template* in the repo (PATH incl. `~/.pi/agent/shims`, `MAX_LOAD`, `AGENT_INFRA_PATH`), and make `cloud-cell-bringup.sh --check` refuse `CELL READY` when `keys.env` is absent | measured: one of three live cells has no `keys.env` at all, and **none** of the two that have one sets `PATH` or `MAX_LOAD`. Without it a cell's throttle is the swap gate alone, `AGENT_INFRA_PATH` is a per-cell lottery, and `gh` is unguarded outside the extension | a template + one refusal; the refusal is the part that keeps it true |
| **3** | 8 | **A cell watchdog**: a `systemd --user` timer (or a tmux-side respawn loop) that restarts a dead controller. The MAC half is now shipped — `templates/launchd/com.eldato.controller-watchdog.plist` → `scripts/orchestrator-harness/watchdog-loop.sh`, with the hand-provisioned `com.eldato.orchestrator-watchdog` added to `templates/launchd/RETIRED` so the installer removes it instead of leaving two mutating watchdogs — but **the job is not installed by the change that ships it**, and a cell still has no scheduler above the tmux session. ⛔ The CELL half is now shipped as `templates/systemd/eldato-orchestrator.service` + `install-controller-service.sh` (#2402), which makes the controller its own restarting unit instead of a watched session: installing it (the bring-up's `check_controller_service` does) is what closes this gap on a box | this is the literal content of the "self-healing" claim; today a cell controller dies silently until the unit is installed. The Mac's capability now exists as source, so what is left is arming it (an installer run) | one installer run on the Mac; a per-cell `install-controller-service.sh` run (the bring-up already does it) |
| **4** | 11 | **Export `AGENT_INFRA_PATH` in the supervisor's controller command** (`cloud-cell-supervisor.sh::cmd_start`, next to `HOME=/REPO=/O=/OR=`) | restores `session-checks`, `auto-sync` and `sequence-enforcer` on cells, all of which currently skip **silently** — the worst failure shape | one word in a `tmux new-session` string; the README already states the requirement |
| **5** | 6 | **Activate the git hooks on both**: `git config core.hooksPath .husky` in each repo (or a `husky` prepare step) | restores `commit-msg` + `pre-commit` on the Mac too, where they are also absent today — the row is *not* a cell-specific gap, so it is cheap and everywhere | one config line per repo; per-repo state, so it can never live in the layer |
| **6** | 16 | **Unify the readiness verdicts** — make `cloud-cell-bringup.sh --check` probe the things the merge gate needs (shim resolvable, `scripts/gh-shim/gh` executable, PATH carries `~/.pi/agent/shims`) and delete the claim that `gh auth status` means "ready" | do this **after** 2, or it only turns every cell red. It is the row that stops the class from returning | small read-only probes; the same three the matrix used |

Rows **3, 4, 5, 12, 13, 14, 15** are provisioned on both platforms and need nothing.

## How to re-measure

Every verdict in the table is reproducible from a checkout, without trusting this document:

```bash
# on any box — what resolves the argv layer, and to what (the extension's own two candidates)
python3 - <<'PY'
import os, pathlib
ext = pathlib.Path.home()/".pi/agent/extensions/review-enforcer"
for c in [os.environ.get("AGENT_GH_SHIM_DIR"), str(ext/"../../scripts/gh-shim")]:
    if c: print(f"{c}: executable={os.access(pathlib.Path(c,'gh'), os.X_OK)}")
PY

# the cell layer's own read-back (now also reports the shim's activation state)
CELL_HOME=/tmp/cell-home bash pi-bootstrap/cell-install.sh --verify | grep -i 'activation:'

# the env a cell controller actually got — a box with no tmux server reads NOTHING, which is an
# abstention and must never be recorded as "PATH carries no shim"
tmux show-environment -g 2>/dev/null | grep -E '^PATH' || echo 'ABSTAIN: no tmux server — nothing to read'
```

`cell-install.sh --verify` prints one `activation:` line for the `gh` shim, resolved through the
**same two** candidates `review-enforcer` reads, so this document's central row is checked by the
installer rather than by prose. It deliberately does **not** accept `~/.pi/agent/shims` as a
candidate, and the distinction is precise: that directory is not *ignored* by the extension — it is
**written** (`materializeGhShim`) from a **resolved source** and then **injected** onto PATH
(`withGhShim`), and revalidated on every bash call. What it never is, is a **resolution candidate**
(`resolveGhShimDir` does not read it), so a healthy-looking neutral symlink with **no resolvable
source** is a link the gate never arms. Case B below is exactly that state, on this laptop:

```
$ CELL_HOME=$HOME cell-install.sh --verify | grep activation            # ~/.zshrc var set
  activation: gh shim PRESENT at …/agent-infra/scripts/gh-shim (argv-level admin-merge guard armed)

$ env -u AGENT_GH_SHIM_DIR CELL_HOME=$HOME cell-install.sh --verify | grep activation   # launchd env
  activation: gh shim ABSENT — … the review-enforcer then runs the string scanner only (#984),
                                which is all the GATE itself has. A `gh` already resolved through
                                PATH is not measured by this line — see row 2. ⛔ ~/.pi/agent/shims/gh
                                exists but it is never a resolution CANDIDATE …
```

## The QUOTA layer is injected AHEAD of the argv guard (#3477)

`withGhShim` now prefixes **two** directories, in this order:

```
export PATH="$O/gh-limit":"$HOME/.pi/agent/shims":"$PATH"
```

`resolveGhLimitDir()` resolves the first entry (`$O/gh-limit`, `$O` = the `O` env or
`$HOME/orchestrator`). `AGENT_GH_LIMIT=0` drops only that entry (the admin-merge guard survives);
`AGENT_GH_SHIM=0` still disables the whole injection.

⛔ **Identity is the SENTINEL *plus* `--self`, never the sibling helper — and that is a measured
rule, not a preference.** Two independent bypasses were recorded, in two review rounds.

1. `gh-limit.py:3296` records that accepting “a `gh` beside a `../gh-limit.py`” as a layer
   “SILENTLY SKIPPED any other `gh` sitting in such a directory — measured with the tree's own
   admin-merge guard (`scripts/gh-shim/gh`) placed beside the helper: `gh pr merge --admin` then
   reached the real gh UNGUARDED”.
2. The sentinel alone is **not** the quota layer either: it identifies every entry point of the
   family, and `scripts/orchestrator-harness/gh-rest/gh` carries it at bytes 2602 and 5988 *and* sits
   beside the same `../gh-limit.py` (`LIMIT_HELPER=…`). That adapter skips harness layers by a
   **whole-file** marker grep, so prepending it would skip `~/.pi/agent/shims/gh` and exec the real
   `gh`.

Because this entry is prepended **ahead of** the guard, a wrong directory here is worse than none.
So `resolveGhLimitDir()` requires all of:

| condition | where it is checked | why |
|---|---|---|
| `harness-gh-shim-marker` (byte 1100) | first 8 KiB of `<dir>/gh` | it is a harness entry point |
| `--self` (byte 5886/6156) | first 8 KiB of `<dir>/gh` | it is THIS layer, not the `gh-rest` adapter (which never passes `--self`) |
| a regular, executable `gh` | `<dir>/gh` | bash silently skips a PATH entry that is not |
| the sibling helper | `<dir>/../gh-limit.py`, `existsSync` — **a separate file, no window** | without it the wrapper takes its fail-open arm |

Absent any one of them it resolves to `null` and nothing is injected. The helper is a *different
file* from the wrapper, so it has no 8 KiB window — the wrapper's own header merely *mentions* the
path `$SELF_DIR/../gh-limit.py`, so a predicate that only scanned the first 8 KiB for those three
strings would be satisfied by a layer whose helper is **absent**: the state the third condition
exists to close, in which the wrapper prints “that call was NOT serialised or backed off” while the
box believes the cache is in force.

⛔ **The order is the correctness argument — and the GUARD is the half that survives it.** The
chain is `gh-limit → gh-shim → real gh`. `gh-limit`'s `is_harness_shim` reads only the first 8 KiB,
and `scripts/gh-shim/gh` keeps its own marker at byte **26405** — deliberately outside that window —
so the quota layer resolves the argv guard as its CHILD and the #984 admin-merge gate stays in the
chain.

**Reverse the order and it is the QUOTA LAYER that is lost, not the guard** (measured, review round
5). `scripts/gh-shim/gh`'s `_is_harness_layer` also reads the first 8 KiB, and `gh-limit`'s marker
sits at byte **1100** — inside it — so the guard skips `gh-limit` and resolves the real `gh`. The
failure an operator will actually meet with the wrong order is therefore **“gh-limit is still unused
on this box”** (`averted=0`, the `839 gh-core-floor … read refused` state returning), not “merges are
unguarded”. Stated in that direction because the opposite sends the diagnosis to the wrong place —
and would have a future change that moves the quota dir after the guard reviewed as gate-destroying
when it actually re-opens this defect.

**Parity, stated precisely.** `lane.sh:83-84` prepends `$O/gh-limit` and then `$O/gh-rest`, so the
resulting PATH has **`$O/gh-rest` first** (its own comment: “adapter last so `$O/gh-rest` … wins
where it exists”). This extension composes the **cell** layer only — `resolveGhLimitDir` has no
`gh-rest` candidate — so it establishes the quota-before-guard half of that order, not the whole of
it. On a Mac, `install.sh` seeds `$O/gh-rest/gh` and `$O/gh-limit.py` but never creates
`$O/gh-limit/`, so the resolver returns `null` and pane-spawned Mac lanes get no quota layer; that
bypass is unchanged by this change and is named here rather than implied away.

**Measured, cell `cmux`, 2026-11-05 — why it was needed.** 11 of 12 live lane `pi` processes had
**no** `gh-limit` on PATH: they resolved `~/.pi/agent/shims/gh` and then the real `gh`, bypassing
the cache, the budget and `--stats` entirely. The same box's `gh-limit` events log (21 h, 1005
lines) recorded **839** `pressure: gh-core-floor … read refused` events and **zero**
`read-cache: <class> hit`, **zero** `single-flight: shared` and **zero** `conditional: 304` —
`--stats` read `averted=0` — with `core` at `0/5000` while `graphql` held `4159/5000`.
Re-verification takes the emitted prefixes, not prose: `rg -c 'read-cache: .* hit' events.log`
(the literal string `read-cache hit` is not emittable and would read 0 on a healthy cache).
Cost of the extra hop, measured: `gh --version` 123 ms direct vs **278 ms** through the chain.

**Residual, stated rather than implied.** The quota entry is `$O/gh-limit` (or
`AGENT_GH_LIMIT_DIR`), which is an operator-controlled absolute path and is **not** neutralised the
way the shim entry is. A home directory containing a gate word (`/home/admin/…`) therefore lands
in the injected text, which is the VGATE #984 class that made a checkout path containing `admin`
look like an admin merge. The default (`$HOME/orchestrator/gh-limit`) is clean and is asserted; a
non-default `O`/`AGENT_GH_LIMIT_DIR` carrying a gate word is not, and is left visible here rather
than silently guarded.
