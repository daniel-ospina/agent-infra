---
title: "Lane recovery — how to restart a dead lane WITHOUT deleting its workspace (#942)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-11-08
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-942, lane-relaunch, safe-send, orchestrator-heartbeat, fleet-liveness, respawn-pane, cmux
---

# Lane recovery — restart a dead lane without deleting its workspace (#942)

**One rule: a lane is relaunched by typing its launch line into the pane's OWN shell —
`scripts/lane-relaunch.py --ws <uuid>`. Never `cmux respawn-pane`.**

This page exists because three places in this repo prescribed a relaunch and named a remedy that
did not exist (`recover-fleet / relaunch`, "board §72", `ORCHESTRATION-BOARD 72` — measured
2026-11-08: no such script in the repo or in `~/.pi/agent/scripts/`, and no `ORCHESTRATION-BOARD-*.md`
on the box). An operator who follows a pointer to nothing improvises, and the improvisation was the
one verb this repo already documents as destructive.

## Why `respawn-pane` is not the tool

`cmux respawn-pane --workspace <W> --command "<cmd>"` replaces the pane's process. When `<cmd>` exits
immediately — the binary is not on the respawn PATH, a wrapper cannot find `node` — the pane's
process terminates, the surface closes, and because it was the workspace's only surface **the
workspace is removed**. It then presents one step later as `Error: not_found: Workspace not found`,
which does not point back at the respawn. The blast radius includes the session binding: the
workspace is where the resume state lives, so the orchestrator loses its handle on that thread.

Measured (issue #942): two workspaces destroyed in one session («π - tortoise 1», «Issue workflow»),
and a later controlled repro destroyed a *scratch* workspace with `--command "pi --help"` — the
command that was being tested precisely because the previous attempt had failed.

Two aggravating factors, both designed around:

1. **The respawn environment is `--noprofile --norc`.** Ghostty launches
   `/usr/bin/login -flp <user> /bin/bash --noprofile --norc -c exec -l /bin/sh -c '<cmd>'`, so the
   user's PATH and exported keys are absent. `pi` is typically not on it; a tool needing a key starts
   broken ("No models available. Use /login"). The pane's own login shell has both.
2. **Stored resume state can point at a session file that does not exist.** `cmux surface resume
   show` returned ids for which `ls ~/.pi/agent/sessions/*/*<id>*.jsonl` found nothing; resuming from
   one would silently start an EMPTY session that looks like a restore. See
   [Identifying the real session](#identifying-the-real-session) below.

This is also the multiplexer convention, not a fleet idiosyncrasy: tmux makes pane destruction on
child exit **opt-in** (`remain-on-exit` keeps a "dead pane" with its output; modes `failed` /
`failed-key` keep it exactly when the child *failed*), and an application is started in an existing
pane by `send-keys` into that pane's shell — after which `respawn-pane` would restart the *shell*,
not the application (tmux wiki *Advanced Use*, tmux(1), tmuxp#139). We cannot give cmux
`remain-on-exit`; we can stop depending on the destructive verb.

## The procedure

```bash
# CONFIRMED dead: the pane is a bare shell (no pi footer) AND the workspace has no live pi record.
scripts/lane-relaunch.py --ws <workspace-uuid> --dry-run      # prints the exact launch line
scripts/lane-relaunch.py --ws <workspace-uuid>                # sends it, then confirms
```

Exit codes are the answer, not the pixels:

| Exit | Meaning |
|---|---|
| `0` | **CONFIRMED** — the line was sent and the session transcript **advanced** |
| `3` | **REFUSED** — a guard refused and nothing was sent; the message names the guard |
| `4` | **UNCONFIRMED** — sent, but no transcript advance inside `--wait`; the message carries the pane tail |
| `1` | **ERROR** — the tool itself raised. Never reported as DRY-RUN or as an unconfirmed send: the operator's next move is chosen on this line |

The launch line it sends is the form the fleet's own recovery used to bring back 14 lanes (issue
#942):

```
cd <cwd> && exec <abs path to pi> --session <id>
```

…sent as ONE `cmux send` payload **with a trailing newline** (`cmux send` without one types but never
submits — #941, a silent dispatch no-op). If the line is wrong you get a shell prompt back. Nothing
is destroyed.

### What it refuses, and why each refusal exists

| Refusal | Why it is a refusal and not a warning |
|---|---|
| pane unreadable | UNKNOWN is not idle, and it is not dead either. Never type into a pane you cannot read. |
| `Working` in the pane | a turn is in flight; the text would be taken as **steering into a live model** |
| no shell prompt on the last line | the pane is not at a bare shell (a pi footer, a pager, an editor would take the text). Positive match only — a negative list fails open. `>` is deliberately NOT accepted: pi draws `> ` as its input line |
| a LIVE pi session record for the workspace | the lane is not dead; the orthogonal half of the fleet's own DEAD definition (`cmux sessions list` records + pane) |
| the session record is unreadable | an unread read is not "no live pi" |
| the resolved session has no transcript | #942 aggravating factor 2. `--new` is how you say "fresh session" deliberately |
| no cwd / no `pi` binary | a launch line that cannot resolve is the failure this tool exists to avoid |
| `lane-status.py` not importable | the fleet's resolution primitives are not installed beside the tool; nothing was read, so nothing may be sent |

`--new` starts a fresh session (no `--session`), and is the only way to relaunch a lane whose
transcript is genuinely gone.

### Identifying the real session

Do not trust the stored resume id when the transcript is missing — find the session **by content**:

```bash
grep -rl "<a distinctive phrase from that thread>" ~/.pi/agent/sessions/*/
# then confirm no live writer: size and mtime stable over ~25s
```

That is how the sessions in #942 were recovered (`loop_liveness` located `01a09b33…` and
`01a09bcd…`; the stored ids `01a09c4a…` and `5a51b1ed…` matched no file).

## Scope and known limits

- **It is not a fix for cmux.** The teardown belongs to cmux and is not in this repo; this page and
  the tool remove this fleet's *reason* to invoke it.
- **On a build without `cmux sessions list`, the tool refuses** (exit 3). That is deliberate: the
  live-pi half of the guard cannot be answered, and a refusal is cheaper than typing into a live
  session. Use the manual form above on such a box, with the pane read as the only evidence.
- **Missing imports are a refusal, not a crash.** `pi-bootstrap`'s farm withholds `lane-status.py`
  deliberately (#1553), so dropping this tool beside the *farmed* heartbeat leaves its imported
  primitives absent — the tool then refuses (exit 3) with a message saying so, rather than raising.
  Run it from a repo checkout.
- **Declared residual (not closed):** the shell-prompt guard is a last-character test, so a live pi
  whose session record is stale (the documented record-only-dead class), not drawing `Working`, and
  whose last line happens to end in `$ % # ❯ »` would be mistaken for a shell. Three guards must miss
  at once, and pi draws its footer ending in the model/thinking level, not in a prompt character. A
  footer-ABSENT check would close the window but would need a second copy of the footer vocabulary
  that `orchestrator-heartbeat.sh`'s `_shell_visible` already owns — one source of truth beats a
  drifted second one, so the window stays declared here rather than duplicated.
- **The cmux CLI grammar drifts between builds** (`cmux send --workspace <ws>` on the Mac build vs
  `cmux terminal send <id>` on a cell). The tool uses the Mac/fleet form — the one every other script
  in this repo uses — and prints the exact argv it tried when the send fails.
- **It does not decide whether the lane is dead.** That is
  [fleet liveness](./fleet-liveness.md)'s five states; this tool acts only on the state that page
  calls CONFIRMED bare-shell, and it re-proves both halves itself rather than trusting a snapshot.

## Related

- [fleet-liveness.md](./fleet-liveness.md) — the verdicts, the identity rule, the abstention doctrine
- [session-lifecycle-contract.md](./session-lifecycle-contract.md) — one issue per session, handoff budget
- `scripts/safe-send.sh` — the dispatch path; its refusal for a pane with no pi now names this tool
- `scripts/orchestrator-heartbeat.sh` — the DEAD LANES clause names this tool
