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

## The matrix

| # | component | mac | cell | the file that activates it | divergence risk |
|---|---|---|---|---|---|
| 1 | **`gh` shim source** — the argv-level admin-merge guard (`scripts/gh-shim/gh`) | **improvised** | **absent** | *nothing installs it.* `extensions/review-enforcer/index.ts::resolveGhShimDir` resolves `$AGENT_GH_SHIM_DIR`, else `EXTENSION_DIR/../../scripts/gh-shim` | **HIGH** — the only layer a **token** splice cannot defeat (`--ad""min`, `$'--admin'`, `xargs {}`); a *discarded* PATH entry still defeats it, which is the shim's own declared limit (`ghShimWillEnforce`). On this Mac it resolves **only** from `AGENT_GH_SHIM_DIR` in `~/.zshrc:11`; that file is not in the launchd controller's env, and the relative fallback `~/.pi/agent/scripts/gh-shim` is **absent** (probe: resolution returns `null` with the var unset). On `pi-lane-1` `~/.pi/agent/scripts/gh-shim` is absent and `~/.pi/agent/shims/gh → /tmp/cell-ai/.worktrees/tm-1203/scripts/gh-shim/gh` — a **lane's worktree**, i.e. gone when that worktree is reaped. `pi-cell-3` has no `shims/` at all. Degradation is logged (`#984 argv-level gh shim not found`) and the gate silently falls back to string scanning |
| 2 | **`~/.pi/agent/shims` on PATH** | **improvised** | **absent** *where a tmux server exists to read* | mac: `~/.zshrc` (hand) + the extension's `withGhShim` absolute-path injection; cell: nothing | **MEDIUM** — for the extension's own calls PATH is irrelevant (it injects an absolute dir), so the *guard* does not need this; a lane that types `gh` does. On this box an interactive shell's PATH begins with that directory (twice — inherited, then injected). The **daemon** PATH deliberately excludes it (`install.sh` `add_dir` refuses `*/shims`; `deploy-mac-orchestrator.sh:220` same; `selftest.sh:641-642` and `:2043-2044` pin it) for macOS TCC. The cell controller's measured PATH is stock: `/usr/local/nvm/versions/node/v24.21.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin`. ⛔ On `pi-cell-2` there is **no tmux server at all**, so that box's PATH is an **abstention**, not an absent reading |
| 3 | **extensions loaded** (review-enforcer, verification-gate, sequence-enforcer, loop-enforcer, auto-sync, repo-freshness, reflect-hook, task-heartbeat, session-checks, mcp-client, builtin-tools, …) | **provisioned** | **provisioned** | mac: `pi-bootstrap/setup.sh` (real copies refreshed from `extensions/*`); cell: `pi-bootstrap/cell-install.sh::install_extensions` from `manifest.json`'s ship-list (31 of 32; `cmux-session.ts` denied by design) | **LOW-MED** — content is byte-compared by `--verify`. Residual: a cell never auto-refreshes from a git pull, the Mac does on every `setup.sh` |
| 4 | **extension runtime deps** (`node_modules` for `builtin-tools`, `mcp-client`, `loop-enforcer`, `custom-provider-qwen`) | **provisioned** | **provisioned** | mac: `setup.sh`; cell: `cell-install.sh::install_extension_deps` (`npm install --ignore-scripts`, scrubbed env) | **LOW** — measured present on both (`builtin-tools/node_modules` exists on the Mac and on `pi-lane-1`) |
| 5 | **hooks: `session_start` / `reflect`** | **provisioned** | **provisioned** | they are *extensions*, not a hooks dir — `session-checks.ts` + `reflect-hook.ts`. `~/.pi/agent/hooks/` does not exist on either side | **LOW** — `reflect-hook` needs the cloud opt-in; `pi-lane-1`'s `keys.env` carries `TORTOISE_CAPTURE` |
| 6 | **hooks: git `pre-commit` / `commit-msg`** (`.husky/*`) | **absent** | **absent** | *nothing.* Needs `git config core.hooksPath .husky` per repo — repo-local state, which no layer installer can set | **MEDIUM, and silent** — measured: `core.hooksPath` unset in **both** `tortoise` and `agent-infra`, and `.git/hooks/` holds **0** non-sample hooks. `AGENTS.md` states the pre-commit hook enforces agent-infra version sync; it does not run today on either platform |
| 7 | **controller entry point** | **improvised** | **provisioned** | mac: **the shipped** `scripts/orchestrator-harness/launchd.plist.template` names `__O__/orch-loop.sh`, rendered by `install.sh` → `com.eldato.orchestrator-loop`; cell: `scripts/install-controller-service.sh` renders `templates/systemd/eldato-orchestrator.service` and `scripts/cloud-cell-bringup.sh::check_controller_service` runs that installer on every bring-up, so `start` is the unit's main process (`Environment=ORCH_FOREGROUND=1`); `scripts/cloud-cell-supervisor.sh::cmd_start` reaches `tmux new-session … bash orch-loop.sh` **only** when no unit is installed, or when the operator explicitly disabled it (#2402) | **MEDIUM** — measured divergence on this Mac: the **installed** plist's `ProgramArguments` is `/bin/bash $O/launchd-controller.sh`, and `launchd-controller.sh` **is not in `origin/main`** (`git ls-tree` → absent); the live launcher sits untracked in `~/orchestrator`, and a `.bak-divergence-*` next to the plist records the edit. At measurement time a lane held uncommitted changes to both the template and that launcher, so treat this row as *in flight*, not settled. **Update (agent-infra#2231):** `install.sh` now renders the program from the **pinned worktree** (`<pin>/launchd-controller.sh` when the pin carries it, else `<pin>/orch-loop.sh`) and REFUSES when the resolved directory is not that worktree at the recorded sha — so the installed path can no longer be a copy. The live-only `launchd-controller.sh` itself still has to land (PR #2020) before the pin may replace it; see `scripts/orchestrator-harness/README.md` → "The Mac runs the PIN, not a home-dir copy" for the per-row parity table |
| 8 | **controller watchdog** | **improvised** | **absent** | mac: **as measured**, `~/Library/LaunchAgents/com.eldato.orchestrator-watchdog.plist` (`StartInterval` 20) → `/Users/danielospina/orchestrator/watchdog.sh`, absolute home hardcoded, installed by no surface in this repo. The TRACKED replacement now SHIPS: `templates/launchd/com.eldato.controller-watchdog.plist` (`StartInterval` 300) → `scripts/orchestrator-harness/watchdog-loop.sh`, rendered by `install-launchd.sh`'s own template loop, and the hand-provisioned label is listed in `templates/launchd/RETIRED` so the installer **unloads and removes it**. ⛔ THE TWO MUST NOT COEXIST, and they are NOT a redundant pair: the old job runs `watchdog.sh` (check → load → log → exit, idempotent) while the new one takes a NON-idempotent `launchctl kickstart -k`, so two loaded watchdogs are two MUTATING actors on one controller — this watchdog's restarts are disabled by retirement, not left to race. ⛔ **Nothing is installed by the change that ships the template** — the template is the capability; running `scripts/install-launchd.sh` is the activation, and until an operator runs it this row stays `improvised`. cell: the shipped `install-controller-service.sh` + `templates/systemd/eldato-orchestrator.service` (`Restart=always`, and `check_controller_service` installs it on every bring-up) is the supervisor above the controller; the pre-existing `orchestrator-harness/watchdog-loop.sh` cell branch still calls `cloud-cell-supervisor.sh start`, and nothing schedules it — the unit **replaces** the need for it only once it is installed on a box, which is a per-box state, not a repo fact | **HIGH** — this is the "self-healing" claim. A cell has found **no supervisor above the tmux session**: `crontab` is **not on the cell shell's PATH**, so no scheduled job was observable from that shell (that is not a "no cron installed" reading), and the user systemd manager is **not queryable from the cell shell** (`systemctl --user list-timers` → *Failed to list units*) — an **abstention, not a "zero units" reading**. #2130 measured the units directly on a cell (0 present, 0 enabled). Either way the controller can die and the only signal is a quiet queue |
| 9 | **operational tunables** (`MAX_LANES`, `MAX_LOAD`, `MAX_FIX`, `MAX_REVIEW`, `CYC`, `SCOPE`, `MERGE_PRIORITY_AT`, …) | **provisioned** | **improvised** | mac: rendered into the plist `EnvironmentVariables` by `install.sh` (`__MAX_LANES__` from the installer's own core probe); cell: operator-pushed `keys.env`, sourced by `cloud-cell-supervisor.sh` (`set -a; . $ENV_FILE`) | **HIGH** — measured: `pi-lane-1` and `pi-cell-3` both carry a `keys.env`, and **neither sets `PATH` (0 lines) nor `MAX_LOAD`**; `pi-cell-2` has **no `keys.env` at all** and no tmux server, i.e. no controller. A box with no `MAX_LOAD` is throttled only by the swap gate, and a box with no `keys.env` runs on whatever env the operator's session happened to carry |
| 10 | **daemon/controller PATH** | **provisioned** | **improvised** | mac: `__PATH__` rendered by `install.sh` from the dirs the binaries actually resolve to (refusing `*/shims` and `*/.pi/*`); cell: inherited from the tmux session that ran `start`, or from `keys.env` if it sets one (it does not) | **HIGH** — a cell's PATH is documented nowhere and reproducible only by re-running the same hand command |
| 11 | **`AGENT_INFRA_PATH`** | **provisioned** | **improvised** | mac: `pi-bootstrap/setup.sh:814` appends it to `$ZSHRC`; cell: whichever `keys.env` the operator wrote | **HIGH, and per-cell** — `scripts/orchestrator-harness/README.md` §4 states the requirement, and it is met by hand or not at all: measured **set** in `pi-cell-3`'s `keys.env`, **absent** from `pi-lane-1`'s. Where it is absent, `session-checks` / `auto-sync` **silently skip** and `sequence-enforcer` in gate mode reports an unpassable checkpoint |
| 12 | **provider auth** (`auth.json`, `models.json`) | **provisioned** | **provisioned** | both: pi's own credential store; cell bring-up pushes a verified key (`check_gh` / provider probe with a real call) | **LOW** |
| 13 | **scripts farm** (`~/.pi/agent/scripts`, incl. `record-review.sh` + `lib/diff-normalize.py`) | **provisioned** | **provisioned** | mac: `setup.sh` farms (real copies, #427); cell: `cell-install.sh::install_farms` reads the **same** arrays out of `setup.sh` (parsed, not re-listed) | **LOW** — the parse is floored (`MIN_FARM_FILES=20`) and byte-compared; measured 20 `*.sh` + `record-review.sh` + `lib/diff-normalize.py` on `pi-lane-1` |
| 14 | **skills + `AGENTS.md` + `settings.json` + sub-agents** | **provisioned** | **provisioned** | mac: `setup.sh`; cell: `cell-install.sh::install_skills` / `install_config` (`settings.json` merged, `AGENTS.md` installed only when absent) | **LOW** — measured present on `pi-lane-1` and `pi-cell-3`; **absent on `pi-cell-2`**, where `/tmp/cell-home/.pi/agent` holds only `audit/` and `skill-reads.json` — i.e. that box never received the layer at all (see 16) |
| 15 | **state + reviews dirs** (`$O/state`, `$O/logs`, `~/.pi/agent/reviews`) | **provisioned (on demand)** | **provisioned (on demand)** | created by shipped code the first time it needs them, both sides: `orch-loop.sh:251`, `record-review.sh:2140` | **LOW** — an installer neither creates nor restores these, so they are listed under their own legend row rather than as provisioned |
| 15b | **harness activation on a clock** (`harness-apply-pass.sh` → `cloud-cell-supervisor.sh apply` / `./sync.sh`) | **provisioned** | **provisioned** | `scripts/install-harness-apply-timer.sh`, run by `cloud-cell-bringup.sh --check` on a cell and by hand on a Mac (`com.eldato.harness-apply`); `--status` is the readiness gate | **HIGH until #2416** — this row did not exist, and the measured state was a Mac 91 commits behind `main` and a cell whose `HARNESS-PIN` named a commit its checkout did not have, with every signal reading `auto`. Rows 7-11 answer *what is deployed*; none of them answers *whether the deployed code is still main* — see `docs/ops/harness-apply.md` |
| 16 | **a readiness verdict that measures the merge gate** | **improvised** | **absent** | `cloud-cell-bringup.sh --check` (`CELL READY`) probes home/tools/network/provider/gh auth/push/clone/dispatch-preflight/layer; `cloud-cell-supervisor.sh check` (`CELL CAN RUN A CONTROLLER`) probes `git python3 pi`, `gh auth status`. **Neither probes the admin-merge shim** — the supervisor's only shim probe is its own rate-limit layer (`PATH="$O/gh-limit:$PATH" … gh --version`, `cloud-cell-supervisor.sh:1206`) | **HIGH** — this is the two-definitions-of-ready defect. `gh auth status` answers "is gh authenticated", never "is gh guarded". Measured: `pi-cell-2` has **no operational layer at all**, and `pi-cell-3` has the layer with **no `shims/`** — both can reach their own green banner. ⛔ And the new `activation:` line is **discarded** by the path an operator runs: `cloud-cell-bringup.sh:441` greps the installer's output down to `mode=--verify\|LAYER VERIFIED` |

## What the matrix says

Counting each **(component, platform)** pair: **8 improvised, 6 absent, 18 provisioned**.

The measured per-box state behind the cell column, so the generic verdicts above are not misread:

| box | layer | `keys.env` | controller | `shims/` |
|---|---|---|---|---|
| `pi-lane-1` | full (`AGENTS.md`, `agents/`, `extensions/`, `scripts/`, `skills/`, `reviews/`, `state/`) | yes — no `PATH`, no `MAX_LOAD`, no `AGENT_INFRA_PATH` | tmux (`orch`, plus `pk1`, `pack`, `closer2`, `diskreaper`) | `gh → /tmp/cell-ai/.worktrees/tm-1203/scripts/gh-shim/gh` (a lane's worktree) |
| `pi-cell-3` | full | yes — no `PATH`, no `MAX_LOAD`; `AGENT_INFRA_PATH` **set** | tmux (`p0a`, `p0b`, `restart`, `diskreaper`) | **absent** |
| `pi-cell-2` | **none** (`/tmp/cell-home/.pi/agent` = `audit/`, `skill-reads.json`) | **none** | **none** (no tmux server) | **absent** |

Three things, in order of how much they cost:

1. **The component that gates a merge is the one whose activation is improvised on the Mac and
   absent on cells** (rows 1-2). Rows 8 and 16 are improvised/absent too — but they cost *recovery*
   and *truthfulness*, not a merge, and #2130 already owns them. And this is **not** a cell-only
   defect: the Mac resolves the shim from a shell-rc line the launchd controller does not inherit,
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

Ranked by how much capability the change restores. #1 is first for a reason: it is the layer that
decides whether a merge may happen at all, and it is currently the weakest on every cell.

| rank | gap (rows) | the single change | why this one | cost |
|---|---|---|---|---|
| **1** | 1 (+2) | **Farm `gh-shim` onto the box**: add it to the farm set `setup.sh` declares (a `gh_shim_srcs` row + a `FARM_LAYOUT` entry in `cell-install.sh`) so it lands at `$DEST/scripts/gh-shim/gh` on **both** platforms | `resolveGhShimDir`'s relative fallback is `EXTENSION_DIR/../../scripts/gh-shim` — that path is `~/.pi/agent/scripts/gh-shim` for a copied install, and it is what a **launchd-born** Mac lane and **every** cell lane resolves. Farming it fixes both sides with one declaration, needs no env var, and the extension then materializes `~/.pi/agent/shims/gh` itself (`materializeGhShim`) | one array + one layout row; `--verify` then byte-compares it for free |
| **2** | 9, 10, 11 | **Provision the env, do not inherit it**: a `keys.env` *template* in the repo (PATH incl. `~/.pi/agent/shims`, `MAX_LOAD`, `AGENT_INFRA_PATH`), and make `cloud-cell-bringup.sh --check` refuse `CELL READY` when `keys.env` is absent | measured: one of three live cells has no `keys.env` at all, and **none** of the two that have one sets `PATH` or `MAX_LOAD`. Without it a cell's throttle is the swap gate alone, `AGENT_INFRA_PATH` is a per-cell lottery, and `gh` is unguarded outside the extension | a template + one refusal; the refusal is the part that keeps it true |
| **3** | 8 | **A cell watchdog**: a `systemd --user` timer (or a tmux-side respawn loop) that restarts a dead controller. The MAC half is now shipped — `templates/launchd/com.eldato.controller-watchdog.plist` → `scripts/orchestrator-harness/watchdog-loop.sh`, with the hand-provisioned `com.eldato.orchestrator-watchdog` added to `templates/launchd/RETIRED` so the installer removes it instead of leaving two mutating watchdogs — but **the job is not installed by the change that ships it**, and a cell still has no scheduler above the tmux session. ⛔ The CELL half is now shipped as `templates/systemd/eldato-orchestrator.service` + `install-controller-service.sh` (#2402), which makes the controller its own restarting unit instead of a watched session: installing it (the bring-up's `check_controller_service` does) is what closes this gap on a box | this is the literal content of the "self-healing" claim; today a cell controller dies silently until the unit is installed. The Mac's capability now exists as source, so what is left is arming it (an installer run) | one installer run on the Mac; a per-cell `install-controller-service.sh` run (the bring-up already does it) |
| **4** | 11 | **Export `AGENT_INFRA_PATH` in the supervisor's controller command** (`cloud-cell-supervisor.sh::cmd_start`, next to `HOME=/REPO=/O=/OR=`) | restores `session-checks`, `auto-sync` and `sequence-enforcer` on cells, all of which currently skip **silently** — the worst failure shape | one word in a `tmux new-session` string; the README already states the requirement |
| **5** | 6 | **Activate the git hooks on both**: `git config core.hooksPath .husky` in each repo (or a `husky` prepare step) | restores `commit-msg` + `pre-commit` on the Mac too, where they are also absent today — the row is *not* a cell-specific gap, so it is cheap and everywhere | one config line per repo; per-repo state, so it can never live in the layer |
| **6** | 16 | **Unify the readiness verdicts** — make `cloud-cell-bringup.sh --check` probe the things the merge gate needs (shim resolvable, `scripts/gh-shim/gh` executable, PATH carries `~/.pi/agent/shims`) and delete the claim that `gh auth status` means "ready" | do this **after** 1-2, or it only turns every cell red. It is the row that stops the class from returning | small read-only probes; the same three the matrix used |

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
