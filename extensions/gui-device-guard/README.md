# gui-device-guard (#2249)

A lane may not silently seize the host's camera/microphone.

## The incident

2026-10-21, ~5 minutes before a customer call: Google Meet refused the camera
("something else is using it") and the microphone did not work either. No call
client was running. The holder was a **pi agent lane** — `.worktrees/launch-ping`
ran `npm exec electron .`, launching the DMeer Electron app, which held
`AVCaptureDevice`. **Killing the app did not help**: the live lane relaunched it
within ~15 seconds. Only killing the LANE released the devices. Diagnosis took
six rounds; the decisive read was macOS's *privileged* app list, because
`ps | grep electron` never surfaced it — the argv is
`…/electron/dist/Electron.app/Contents/MacOS/Electron`.

Nothing in the fleet could see it. `tools/fleet/liveness.py`, `fleet_state.py`
and the claim registry answer *"is this lane alive?"*, never *"does this lane's
child own a host device?"*. A lane can be perfectly healthy while making the
owner's machine unable to take a call.

## What this extension does

| rule | when | effect |
|---|---|---|
| **R1 RECORD** | an **unattended** run launches a host GUI app | one row appended to `~/.pi/agent/state/host-app-launches.jsonl` |
| **R2 BLOCK THE MEDIA SHAPES** | an Electron launch, or a **headed** Playwright run, without `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream` | the `bash` call is refused, and the refusal names both flags |

R1 is the cheap half and the one that would have cut the incident to a single
lookup. R2 is the load-bearing half: it stops the seizure instead of documenting
it.

**Kinds recorded:** Electron (`electron`, `npx/npm exec electron`, a
`node_modules/.bin/electron`, the `…/Contents/MacOS/<bin>` shape), macOS
`open -a` / `open -b` / `open Foo.app`, and headed Playwright/Puppeteer.

**"Unattended" is DERIVED, not declared** — `shared/print-mode.ts` (print mode)
or `shared/headless-lane.ts` (a headless run in a *linked worktree*). The
answer therefore comes from the process, never from whether a launcher
remembered to export a variable. An **interactive** session is never guarded: a
human typing `open -a Safari` at their own prompt is not this bug.

## Knobs

| variable | effect |
|---|---|
| `GUI_DEVICE_GUARD_RECORD` | ledger path (default `~/.pi/agent/state/host-app-launches.jsonl`) |
| `GUI_DEVICE_GUARD_ALLOW_MEDIA=1` | permit one deliberate real-device launch — still **recorded** |
| `GUI_DEVICE_GUARD_DISABLED=1` | turn the guard off entirely (no ledger, no refusal) |

Reading the ledger — the lookup that was missing during the incident:

```bash
jq -c 'select(.media)' ~/.pi/agent/state/host-app-launches.jsonl | tail -20
jq -r '[.ts, .decision, .rule, .app, .cwd] | @tsv' ~/.pi/agent/state/host-app-launches.jsonl
```

## Wrappers and substitutions are RE-READ, not declared away

`bash -c "<cmd>"`, `sh -c`, `sudo bash -lc`, `eval …`, and the body of `$( … )`
or backticks are **recursed into** (bounded to 3 levels) — the command string is
argv and can be classified. Playwright's `codegen` and `open` subcommands are
headed **by default**, and a `PWDEBUG` exported in an earlier segment applies to
the whole line.

This was review cycle 1's **F2**: those shapes were measured as `[]` (no finding)
while the header claimed completeness, and `bash -c` is a form `AGENTS.md` hands
lanes routinely. Every one of them is now pinned in the suite (L13/L14) with an
ALLOW twin (A10–A12), because a guard that refuses correct work is its own defect.

## Declared residuals — what is STILL not classified

This is a residual list, not a completeness claim:

- `node script.js` that `require("electron")`s, a compiled `.app` started by a
  shell function, `xcodebuild test`, `xcrun simctl` — **not classified**. argv
  cannot tell them from a plain `node` run.
- A command assembled at **run time** is invisible: `find … -exec`, `xargs`, a
  `while read` loop that runs its input, and `node -e`/`python -c` bodies (only a
  literal `-c`-style **shell** string is re-read). At the moment this hook sees
  the command those are data, not argv.
- A launch built from a shell variable (`APP=Electron; open -a "$APP"`) is
  recorded with the unexpanded name — the shape is kept, the string is not.
- A process started by anything that is not `pi` (`cron`, systemd, a human
  shell) is not seen. The complement is
  [`scripts/orchestrator-harness/media-holders.sh`](../../scripts/orchestrator-harness/media-holders.sh):
  *who holds the device right now*.
- Headless Playwright is **recorded by neither rule** — it cannot present a
  device picker, and refusing every `npx playwright test` is the category-B
  friction `AGENTS.md` has already paid for once.

## Tests

```bash
node extensions/gui-device-guard/test.mjs                    # 68 assertions, threat table L1–L14 + handler H1–H11
node extensions/gui-device-guard/test.mjs --classify 'npm exec electron .'
```

The suite loads the **real** `index.ts` through
`../main-worktree-guard/module-load-hooks.mjs` and drives the **real registered
`tool_call` handler** — the #744/#697 lesson: a suite that imports only a helper
stays green while `index.ts` is broken and the guard is inert in every session.
Mutations are pinned: turning the Electron rule's `media` to `false` reds 11
assertions; removing the wrapper recursion reds 5; removing the fake-switch
mitigation reds the L11 arm.

## Runbook

[`docs/ops/media-devices.md`](../../docs/ops/media-devices.md) — *kill the lane,
not the app*, and the privileged-app-list fallback.
