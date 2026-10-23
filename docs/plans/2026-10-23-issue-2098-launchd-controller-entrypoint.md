---
title: "#2098 — the launchd entry point lives in the repo, not only on one Mac's disk"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-23
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2098, issue-2020, issue-2222, issue-2402, orchestrator-harness, launchd-controller, macos-tcc, launchd
---

# #2098 — the launchd entry point lives in the repo, not only on one Mac's disk

**Issue:** daniel-ospina/agent-infra#2098 (the live-only inventory) · **Tier:** standard ·
**Components:** `scripts/orchestrator-harness/launchd-controller.sh` (new),
`scripts/orchestrator-harness/launchd-controller.test.sh` (new), `scripts/run-bash-shards.sh` (wiring) ·
**Related:** #2020 (the open PR that carries the same path, reviewed NOT CLEAN), #2222 (the same class
for `supervisor.sh`), #2402 (the Linux counterpart: a controller that is a service, not a tmux
session), #1996 (a launchd job's cwd), #2248 (bash 3.2 executes a heredoc body inside `$( )`)

## Confirmed problem

The process that supervises every other process on the Mac is a tmux-session wrapper, and that wrapper
existed **only in `~/orchestrator`**. `git grep -l launchd-controller` found two `docs/ops/*.md`
paragraphs and no script. So:

- **a redeploy cannot carry it.** `deploy-harness.sh` mirrors `scripts/orchestrator-harness/` from the
  repo, so what lands is whatever main ships; the job's own `ProgramArguments` is not main's business.
- **drift could not report it MISSING**, because it only compares files the repo ships. Its only
  possible verdict on a hand-placed copy is `present in $O but NOT shipped by the repo` — a different,
  weaker statement than "the entry point the job executes is not in any commit".
- **the file was also broken, and nothing could see that either.** Measured 2026-10-23 15:08Z:

  ```
  launchctl print … com.eldato.orchestrator-loop   state=failing   runs=8107
  ~/orchestrator/logs/launchd.err                  616,522 bytes, mtime LIVE
                                                   repeating: open terminal failed: not a terminal
  ```

  The entry point was `new-session -A -d -s "$S" "exec /bin/bash '$O/orch-loop.sh'" || exit $?`.
  `-A` makes `new-session` "behave like `attach-session` if `session-name` already exists" (tmux(1)),
  and **attaching needs a client**. A launchd job has no terminal, so on every `KeepAlive` kick with
  the controller session already present tmux printed that line and exited 1 — `|| exit $?` turned
  every relaunch into an immediate failure (7,633 supervisor launches). It reproduced exactly:
  `has-session -t =orch-controller` returned 0 while that line returned 1, and the same command with a
  clean env and **no** existing session returned 0 — which is why it looked environmental for weeks.
  Reproduced on Linux/tmux 3.4 as well, which is what makes it a testable regression.

## Design decisions

1. **Branch on `has-session`; never let tmux attempt an attach.** The guard enforces `-A`'s documented
   purpose ("succeed and do nothing when the session exists … can never start a SECOND controller") by
   a guard instead of by an attach path that cannot work. ⛔ Rejected: kill-and-replace the session on
   every job start (PR #2020's arm). It applies a changed plist value on restart, but it churns a
   healthy controller, and the box that carries this defect is running the no-op form today — a
   behaviour change is not what a fix for "the file is not in the repo" should smuggle in.
2. **The wait loop is OUTSIDE the guard**, so the process that did not create the session still
   supervises it. That is what makes `KeepAlive` supervise the *controller* rather than a one-shot
   launcher, and it is why a job restart with a live session neither spins nor exits.
3. **Forward the whole plist environment into the pane.** tmux gives a new session the *server's*
   environment, not the client's, so on a box whose server was born from an operator's terminal the
   controller inherits none of the job's `REPO`/limits. The list is pinned to the template's
   `EnvironmentVariables` key set **in both directions** by the suite — a rendered-but-dropped limit
   reverts to the loop's default without a word (a pinned `MAX_RED_FIX_TRIES=0` becoming 2).
4. **Fail closed and by name**: a missing/unreadable `$O/orch-loop.sh` is exit 78 (not an exit-127
   crash loop), and a session name matching `lane-*|fix-*|merge-*` is refused because `orch-loop.sh`
   would count and reap it as a worker.
5. **The restart-rate floor is a floor, not a delay**: the wrapper's own lifetime is floored at
   `CONTROLLER_RESTART_FLOOR` (default 15 s, launchd's own `ThrottleInterval`), so a controller that
   dies at once produces one line per window; a controller that ran for an hour exits immediately.
6. **A create is proved, not announced**: wait for the session to APPEAR (a cold server is not yet
   visible — a first-miss is not a death), then require it to still be there after 2 s (a dead pane's
   session lingers ~300 ms). Both directions measured; both would otherwise lie.

## Wiring (check d — Wiring table)

| what | mechanism | evidence |
|---|---|---|
| a deploy INSTALLS the file | `deploy-harness.sh`'s inventory is `find "$SRC" -type f` — **the source tree IS the manifest**; there is no list to add a line to (adding one would create the second list this repo fights) | `deploy-harness.sh --src …/orchestrator-harness --o /tmp/dep-scratch --no-notify` → `VERIFIED — 86/86 file(s) written by this run and byte-identical`; `launchd-controller.sh` present, same blob sha as the source, executable bit preserved |
| drift SEES the file | `check-deployed-drift.sh` derives its shipped set from `git ls-tree -r … "$REL" \| grep -E "^REL/[^/]+\.sh$"` and pins BOTH directions (shipped-but-MISSING, and present-but-unshipped) | after this commit: shipped-but-missing and present-but-unshipped both name `launchd-controller.sh` |
| the suite RUNS in CI | `run-bash-shards.sh` is the single shard list both lanes call; an unwired `*.test.sh` reds `bash-suites` by design (`spawn-gate.test.sh` asserts the unwired population is exactly the two documented non-loop suites) | `run-bash-shards.sh --list` lists the suite; `spawn-gate.test.sh` 96/0 |
| the plist → pane hand-off cannot rot | the suite derives `<key>`s under `EnvironmentVariables` and compares to `CONTROLLER_ENV`, with a drop-one non-vacuity control — and case H pins the VALUE side (an empty value is a meaning) | suite cases E and H |
| the operator's OWN verb sees a stale entry point | `install.sh`'s `DRIFTED` list now carries `launchd-controller.sh` — the installed plist executes it, so its stale bytes are the most expensive drift on the box | `install.sh:817` |

## Tests (cases A–G)

`launchd-controller.test.sh`, hermetic (private `TMUX_TMPDIR` socket, throwaway `HOME`/`$O`, no
network), 23 checks, ~20 s:

- **A** no session → created detached, live pane, no attach, exit 0;
- **B** session already there → exit 0, **no** attach (`open terminal failed` absent), **the same pane
  and session** (no second controller, no replace), and the wrapper **blocking** while it lives;
- **C** **the regression**: the OLD `-A` form must FAIL in the same tty-less conditions B uses, with
  `open terminal failed: not a terminal`. ⛔ C is a **positive control** — if the harness could reach a
  terminal, C would pass and B would prove nothing, so C succeeding is a RED by design;
- **D** the restart-rate floor is measured on the clock: a 10 s floor with a ~4 s session forces a
  ≥ 12 s total, which a floorless build cannot reach; a non-numeric floor is refused by name;
- **E** plist↔pane environment parity, both directions, with a drop-one non-vacuity control;
- **F** a lane-prefixed session name is refused;
- **G** a static arm (no `new-session` line carries `-A`, comments stripped) **plus a mutant control**,
  so the regression is still pinned on a runner without tmux.
- **H** an EMPTY plist value still reaches the pane — `install.sh` renders `OR` empty on purpose
  (#2040), so forwarding on non-emptiness loses it;

## Review round 1 — findings and dispositions

Fresh-context reviewer at the first head; every finding verified against the source before it was
applied (a finding is a claim, not a fact).

| # | finding | disposition |
|---|---|---|
| **P1** | The env loop forwarded on **non-emptiness**, so a plist value rendered EMPTY was dropped and the pane could take that name from the tmux SERVER. `install.sh` renders `OR` empty **on purpose** (#2040), so this is the #2040 symptom returning silently. | **FIXED**: forward on **presence** (`${var+x}`), and case H pins it. Confirmed against `install.sh:37` (`OR="${OR:-}"`) before the fix was made. |
| **P2** | Case D's floor assertion was **inert**: it took `D_T0` before a `sleep 4`, then asserted `>= 2`, so deleting the floor still passed. | **FIXED**: a 10 s floor with a ~4 s session forces a ≥ 12 s total, which a floorless build cannot reach (measured: 12–13 s). |
| **P2** | The header claimed the file *is* the plist's `ProgramArguments`, which main's template does not render. | **FIXED**: the header now says what is true — the installed Mac plist points here, main's template still renders `__O__/orch-loop.sh`, and flipping it is #2020's hunk. |
| **P3** | The header claimed the plist renders `WorkingDirectory`; main's does not. | **FIXED**: the comment now states the requirement and that main renders no such key (a job with none inherits `/`, #1996). |
| **P3** | `install.sh`'s operator-visible `DRIFTED` list did not carry the entry point. | **FIXED**: added, with the reason (its stale bytes ARE this defect). |
| **P3** | The supervise loop's `has-session` read is unbounded: a wedged tmux server pins the job running with a dead controller. | **NOT FIXED HERE — follow-up: #2531.** A portable bounded read in bash 3.2 is real work (no coreutils `timeout` on macOS), and the exposure is the one the live file already has; changing it in this PR would trade a known state for an unproven one. |

## Residuals / what this does not do

- **It does not flip the template.** Main's `launchd.plist.template` still renders
  `__O__/orch-loop.sh`; the `ProgramArguments` switch is PR #2020's hunk, and duplicating it here would
  create two conflicting copies of the same change. Until one lands, the shipped file is installable
  but not yet selected on a fresh box — and the Mac that already selects it stops losing it.
- **A supervised restart does not replace a live session** (decision 1). A changed plist value applies
  when the controller next ends; the operator remedy is in the file header.
- **#2020 must drop its copy.** That PR adds the same path with the kill-and-replace arm and a
  `CONTROLLER_ENV` that misses 5 rendered keys (its own review's P1). Whichever lands first, the file
  must be ONE; this one is strictly the superset (all 21 keys, the guard, the three-case suite).
- **`_shq` duplicates `orch-loop.sh`'s `shq()`** deliberately: sourcing that file would *start the
  controller*, so a one-line twin is the only option; the POSIX form (`'\''`), never `printf %q`, is
  what keeps it correct on a dash-based box (#1988).
