---
title: "Host media devices — who holds the camera and microphone, and the rule that killing the APP is a trap (#2249)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-11-03
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2249, gui-device-guard, media-holders, fleet-liveness, lane-dispatch
---

# Host media devices (#2249)

## The rule, in one line

> **Kill the LANE, not the app.** A GUI app launched by a live lane is relaunched
> within seconds of being killed; only the lane's own process tree holds the
> device. And until a read proves otherwise, assume the holder is a lane.

The rest of this page is the evidence for that line, the reads that do and do
not exist, and the two shipped artifacts.

## What happened (2026-10-21)

~5 minutes before a customer call: Google Meet refused the camera ("something
else is using it") and the microphone did not work either. No call client was
running — no Zoom, Teams, WebEx, FaceTime in the app list.

The holder was **a pi agent lane**: `.worktrees/launch-ping` in the DMeer repo ran
`npm exec electron .`, which launched the DMeer Electron app. That app holds
`AVCaptureDevice`. **It kept relaunching itself each time the app was killed**, so
the camera reappeared ~15 seconds later, every time. Only killing the **lane** —
pi PID 3311 and its bash/npm/electron tree — released the devices for good.

Six rounds were needed, and the rounds are the lesson:

| # | action taken | result |
|---|---|---|
| 1 | `ps` for Zoom/Teams/skype/obs | nothing — the app list showed `Finder, cmux, OrbStack, DMeer, Chrome` |
| 2 | `sudo killall coreaudiod cameracaptured avconferenced` | mic started working; camera still "in use" |
| 3 | quit DMeer.app + kill 2 stale Playwright Chromes | camera **still** in use |
| 4 | restart Chrome (stale `AVCaptureDevice` handle) | camera **still** in use |
| 5 | `pkill -9 -f 'electron/dist/Electron.app'` | freed for **~15 s**, then reappeared |
| 6 | killed the **lane** (process tree + process group) | **stayed free** |

Two details made it undiagnosable from the obvious reads:

- `ps | grep electron` **never matched**. The argv is
  `…/electron/dist/Electron.app/Contents/MacOS/Electron`, so the word `electron`
  appears only as a path component. The decisive read was the **privileged app
  list**, which showed `Electron` as a foreground app.
- Device ownership is **not a fleet signal**. `tools/fleet/liveness.py`,
  `fleet_state.py` and the claim registry answer *"is this lane alive?"*. A lane
  can be perfectly healthy, reporting progress, while its child owns the camera.

## Which reads exist, and which do not (measured, not assumed)

| read | macOS | Linux |
|---|---|---|
| "who holds the camera" as a supported CLI verb | **none** | `/proc/*/fd` targets pointing at `/dev/videoN` |
| `log show --predicate 'subsystem == "com.apple.coremedia"'` | returned **nothing** over 3- and 10-minute windows, at default *and* `--info --debug` levels | n/a |
| TCC database (`~/Library/Application Support/com.apple.TCC/TCC.db`) | needs Full Disk Access — not a lane-era read | n/a |
| exclusive-open probe (`ffmpeg` / `imagesnap`) | not installed, so there is no way to attempt an open and read the contention error | `arecord`/`ffmpeg` may exist; still a *grab*, not an owner read |
| privileged app list (`osascript … background only is false`) | **the fallback that worked**; needs Automation (TCC) permission, which a headless lane cannot grant | not a concept |
| presence (`system_profiler SPCameraDataType`) | distinguishes "contested" from "hardware absent" (slow, seconds) | device node exists / ALSA PCM lists `capture` |
| per-client microphone owner | **none published** | **none** — ALSA has no holder table |

## The two shipped artifacts

### 1. `extensions/gui-device-guard/` — prevents the seizure

A `tool_call` pre-hook on pi's `bash` tool, active only for **unattended** runs
(print mode, or a headless run in a linked worktree — derived from the process,
never from a launcher-set variable). An interactive session is never guarded.

- **R1 RECORD** — every host GUI launch appends one row to
  `~/.pi/agent/state/host-app-launches.jsonl`. This is the cheap half: with it,
  the incident above is one lookup instead of six rounds of `ps`.
- **R2 BLOCK THE MEDIA SHAPES** — an Electron launch, a **headed** Playwright run,
  or `open <path>.app`, without
  `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream` is refused,
  and the refusal names both flags. A named-app launch (`open -a Safari`) is only
  recorded: refusing every GUI launch is the friction the scoping comment rejects.

The lookup that was missing:

```bash
jq -c 'select(.media)' ~/.pi/agent/state/host-app-launches.jsonl | tail -20
jq -r '[.ts, .decision, .rule, .app, .cwd] | @tsv' ~/.pi/agent/state/host-app-launches.jsonl
```

`select(.media)` answers "what could take the camera": Electron, headed Playwright,
and an `open <path>.app`. A named-app launch (`open -a Safari`) is recorded with
`media: false` deliberately, so use plain `jq -c '.' …` for every GUI launch.

See [`extensions/gui-device-guard/README.md`](../../extensions/gui-device-guard/README.md)
for the knobs and the declared residuals (a `node script.js` that requires
electron is not classified; nor is an unexpanded shell variable).

### 2. `scripts/orchestrator-harness/media-holders.sh` — makes the next one diagnosable

Answers "who holds the camera / the microphone **right now**", or says plainly
that it cannot:

```bash
bash scripts/orchestrator-harness/media-holders.sh          # camera + microphone
bash scripts/orchestrator-harness/media-holders.sh --apps   # the privileged app list
bash scripts/orchestrator-harness/media-holders.sh --ancestry <pid>   # chain to the LANE root
```

Every answer is one of four words, and the two that mean "unknown" always carry
a reason:

| verdict | meaning |
|---|---|
| `HELD-BY(pid=… comm=… device=…)` | a reader **proved** an open handle (an alias is resolved and reported as `via=`) |
| `FREE` | the whole holder population was enumerated and no holder exists |
| `ABSENT(<evidence>)` | the hardware is not present |
| `UNVERIFIABLE(<why>)` | the read did not happen. **Never** read as "free" |

⛔ `FREE` is the only answer that rests on absence, and it may rest only on a
**complete** census. A `/proc` scan that could not read another user's fd
directory yields `UNVERIFIABLE(partial: N unreadable)` — and so does a process
holding a camera-shaped character device that is **not** one of the globbed nodes
(an alias, a bind mount, a second node with the same major/minor). Holder identity
is compared as a **device**, not as a path string: the target and the globbed node
are both resolved (`readlink -f`) before they are compared. The exit code is part of
the answer: `2` means **cannot verify**, which is not the same as "nothing to
report". Silence is not an acceptable answer to #2249; "I cannot tell you" is.

## Runbook: the owner says the camera or mic is in use

1. **Do not kill the app.** If a lane launched it, it comes back. Repeat killing
   is rounds 5–6 of the table above.
2. Ask the host:
   ```bash
   bash scripts/orchestrator-harness/media-holders.sh
   bash scripts/orchestrator-harness/media-holders.sh --apps
   ```
3. If it named a pid, walk up to the lane root **before** acting:
   ```bash
   bash scripts/orchestrator-harness/media-holders.sh --ancestry <pid>
   ```
   The lane root is the ancestor whose argv is `pi -p …` or
   `bash …/lane.sh <N>` (a harness controller is a 3-deep `tmux client → bash -c →
   script` chain — the **deepest** process is the controller). ⛔ `--ancestry`
   **acquires** evidence; it does not pronounce a liveness verdict. `FREE`,
   `HELD-BY` and the five liveness states are different questions with different
   owners — see [`fleet-liveness.md`](fleet-liveness.md).
4. Kill the **lane tree** (the process group), not one child. Re-check with
   `media-holders.sh`: a read that still says `HELD-BY` means the lane is still
   alive or a second lane holds it.
5. If the read says `UNVERIFIABLE`, the documented fallback is the **privileged
   app list** (`--apps`), and the owner-facing advice is "quit the app once, and
   if it returns, the lane behind it must be stopped".

## Why this is a process defect, not an owner decision

Per `AGENTS.md`, an instrument that cannot answer its own question is ours to
fix — which is why both halves shipped: the guard prevents the seizure, and the
verb makes the next one a single lookup instead of six rounds.
