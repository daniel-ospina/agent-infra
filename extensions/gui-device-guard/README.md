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
| **R2 BLOCK THE MEDIA SHAPES** | an Electron launch, a **headed** Playwright run, or `open <path>.app`, without `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream` | the `bash` call is refused, and the refusal names both flags |

R1 is the cheap half and the one that would have cut the incident to a single
lookup. R2 is the load-bearing half: it stops the seizure instead of documenting
it.

**Kinds recorded:** Electron (`electron`, `npx/npm exec electron`, a
`node_modules/.bin/electron`, the `…/Contents/MacOS/<bin>` shape), macOS
`open -a` / `open -b` / `open <path>.app`, and headed Playwright/Puppeteer.

**A PATH is a media shape; a NAME is not.** `open ./Build/DMeer.app` — the
incident's own app, launched the way a lane launches the bundle it just built — is
`media: true` and is refused without the fake switches. `open -a Safari` /
`open -b com.apple.Safari` stays `media: false` and is only recorded: refusing
every named-app launch is the category-B friction the scoping comment records as
rejected.

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

The ledger is **append-only and not rotated**: one ~250-byte row per host GUI
launch, written only by unattended runs. It is a diagnostic record, not an audit
log — a lane that launches an app 100 times writes 100 rows, and nothing prunes
them. That is a deliberate trade (a rotation scheme that deletes the row you need
is worse than a file that grows by kilobytes), and it is stated here rather than
discovered by whoever finds a large file.

Reading the ledger — the lookup that was missing during the incident:

```bash
jq -c 'select(.media)' ~/.pi/agent/state/host-app-launches.jsonl | tail -20
jq -r '[.ts, .decision, .rule, .app, .cwd] | @tsv' ~/.pi/agent/state/host-app-launches.jsonl
```

⛔ `select(.media)` shows every launch that could take a capture device — Electron,
headed Playwright, and an `open <path>.app`. It does **not** show a named-app
launch (`open -a Safari`), which is recorded with `media: false` on purpose. If you
want every GUI launch regardless, drop the filter: `jq -c '.' …`.

## Wrappers and substitutions are RE-READ, not declared away

`bash -c "<cmd>"`, `sh -c`, `sudo bash -lc`, `flock … -c "<cmd>"`, `eval …`, and
the body of `$( … )` or backticks are **recursed into** (bounded to 3 levels) — the
command string is argv and can be classified. Playwright's `codegen` and `open`
subcommands are headed **by default**, and a `PWDEBUG` exported in an earlier
segment applies to the whole line.

**Wrapper words are prefixes.** `setsid`, `caffeinate`, `arch`, `taskset`, `flock`,
`script`, `chrt`, `unbuffer`, `prlimit`, `numactl`, `builtin`, `busybox` and
`firejail` are recognised as prefixes, and a launch behind one is classified
normally. Before that (`review cycle 3, F1`) they were read as the *command word*,
so the launch behind them produced **no finding at all** — which is not "allow":
the handler returns early on an empty list, so R1 did not record it either and the
diagnosis half of #2249 vanished with the block.

**Two spellings of one flag must not disagree.** Every value-taking option is
closed in both spellings (`--user` as well as `-u`, `--signal=` as well as `-s`,
`--prefix` as well as `-p`), `--flag=value` is treated as self-contained, and a
fail-safe word scan covers a flag nobody has seen yet — restricted to a segment
that began with a prefix word or an *exec*-style runner, so `rg electron .` and
`npm install electron` (an install, not a launch) stay clean.

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
  literal `-c`-style **command string** is re-read). At the moment this hook sees
  the command those are data, not argv.
- A wrapper word that is **not** in the list above behaves like a plain command:
  its own arguments are not scanned. The list is deliberate and finite; adding one
  is a one-word edit, and the `flock`-style command-flag case is one table row.
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
node extensions/gui-device-guard/test.mjs                    # 101 assertions, threat table L1–L18 + handler H1–H12
node extensions/gui-device-guard/test.mjs --classify 'npm exec electron .'
```

The suite loads the **real** `index.ts` through
`../main-worktree-guard/module-load-hooks.mjs` and drives the **real registered
`tool_call` handler** — the #744/#697 lesson: a suite that imports only a helper
stays green while `index.ts` is broken and the guard is inert in every session.
Mutations are pinned, each attributable to the row it is about, all measured at
ONE head: the Electron rule's `media` → `false` reds **39**; the wrapper recursion
removed reds **6**; the wrapper WORDS removed reds **5**; the comment stripper
removed reds **1** (L11d); the fail-safe word scan removed reds **3**; the
quote-aware paren scan removed reds **1** (L17); honouring the fake switches on an
`open` line reds **3** (L18b + H3b/H3c).

## Runbook

[`docs/ops/media-devices.md`](../../docs/ops/media-devices.md) — *kill the lane,
not the app*, and the privileged-app-list fallback.
