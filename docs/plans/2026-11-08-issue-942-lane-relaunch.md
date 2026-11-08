---
title: "Plan: #942 — ship the relaunch remedy the fleet kept prescribing (and never had)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-11-08
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-942, lane-relaunch, safe-send, orchestrator-heartbeat, cmux, respawn-pane
---

<!-- research-path: the issue comment carrying `<!-- research: v1 -->` (issue #942, issuecomment-6719777290) -->
<!-- plan-review: cycles=0, status=not-dispatched (this lane has no `task` tool; the review is the harness's, at the PR head), version=2.3.0 -->

**Goal:** an operator (or an agent) who has a CONFIRMED dead lane has **one reachable, non-destructive
command** to bring it back — and no instruction anywhere in this repo that points at a remedy which
does not exist.

**Team:** organisation-design-team

## Why this shape (and what the issue's own suggested handling asked for)

Issue #942 reports a cmux defect: `respawn-pane` whose command fails closes the last surface and
**deletes the workspace**. Four suggested handlings were offered; two are cmux's to build (`keep the
pane in the failed state`; `do not auto-remove a workspace whose only surface closed on a launch
failure`), one is "run it through a login shell **or document loudly** that `--command` has no
profile/PATH/env", one is cmux-side validation of stored resume targets.

The double diamond did not stop at the issue's prescription. **Measured 2026-11-08:** this repo does
not call `respawn-pane` anywhere (`rg -n 'respawn-pane'` → prose warnings only), so a call-site guard
would be inert; but three places *prescribe a relaunch and name a remedy that exists nowhere*:

| Locator | Text | Status measured |
|---|---|---|
| `scripts/orchestrator-heartbeat.sh:1124` | "They need a RELAUNCH (recover-fleet / relaunch, board §72), not an item." | no `recover-fleet`, no `relaunch` script in the repo or `~/.pi/agent/scripts/`; no `ORCHESTRATION-BOARD-*.md` on the box |
| `scripts/safe-send.sh:129` | "Relaunch the lane first (ORCHESTRATION-BOARD 72)." | same dangling pointer |
| `scripts/lane-status.py:958`, `scripts/lane-actions.py:57` | "respawn-pane DELETES workspaces" / "relaunch, which REPLACES the pane command" | correct, and offered nothing in its place |

So the in-repo defect is one step **earlier** than the issue: the fleet tells its own operators to
relaunch, names nothing real, and the only reachable verb is the destructive one. The fix ships the
missing remedy and deletes the dangling pointers.

**Alternatives rejected** (detail in the plan comment): close OUT-OF-REPO (leaves the pointers and the
improvisation path); gate the verb in `enforcement/dangerous-ops.txt` (a reminder to a cooperating
agent, with declared wide bypass classes, blocking a human's legitimate use, and it would gate on a
skill that does not document the procedure); edit `extensions/cmux-session.ts` (its header says DO NOT
EDIT — cmux upgrades it in place).

## Design

`scripts/lane-relaunch.py` — **never** `respawn-pane`, `close-workspace` or `kill-pane` on any path.
It types the launch line into the pane's own login shell, where the user's PATH and exported env
exist (the respawn wrapper is `login -flp … --noprofile --norc`, #942 aggravating factor 1), and it
confirms by **transcript ADVANCE**, the fleet's existing proof standard
(`docs/ops/outcome-canary.md:102`: a respawn must advance the log, not merely be recent).

Guards, in this order, each a state this fleet has been burned by (refusal → exit 3, nothing sent):
pane readable → not `Working` → **positive** shell-prompt match on the last line → **no live pi
session record** for the workspace (the orthogonal half of the heartbeat's own DEAD definition) →
the resolved session has an existing transcript (`--new` is the explicit fresh-session arm) → cwd
resolves → `pi` resolves. Then ONE `cmux send` with a trailing newline (#941: without it the text
never submits). Exit 0 CONFIRMED / 3 REFUSED / 4 UNCONFIRMED.

Shared primitives are **imported from `lane-status.py`** (`read_screen`, `ui_working`,
`resolve_session`, `session_file`, `workspace_cwds`) — a second copy of "which session is this lane
on" is how the last two liveness defects were born.

## Tasks (all DONE; evidence inline)

1. **DONE** `scripts/lane-relaunch.py` — the tool. Evidence:
   `python3 -m pytest scripts/test_lane_relaunch.py -q` → **18 passed**.
2. **DONE** `scripts/test_lane_relaunch.py` — 18 assertions over the guard order, the send payload's
   trailing newline, `--new`, `--dry-run`, the ADVANCE confirmation, and a **no-destructive-verb**
   sweep of every argv on every path (R4). Same command as (1).
3. **DONE** `docs/ops/lane-recovery.md` — the procedure, the two aggravating factors, the refusal
   table, the "identify the session by content" recipe, and the honest limits (a build without
   `cmux sessions list` refuses; the cell grammar differs).
4. **DONE** wiring: `scripts/orchestrator-heartbeat.sh` DEAD-LANES clause and `scripts/safe-send.sh`
   refusal now name `scripts/lane-relaunch.py`; `tests/heartbeat-fleet-advance/golden/dead.txt`
   re-pinned. Evidence: `bash tests/heartbeat-fleet-advance/run.sh` → **✅ passed (201 assertions)**;
   `bash -n` clean on both scripts. Pinned by `test_beat_remedy_names_a_script_that_exists` and
   `test_safe_send_remedy_is_reachable` (R6) — the second half of the landing, without which the
   first is a promise.
5. **DONE** `.github/workflows/ci.yml` — the suite is registered in the explicit pytest list (an
   unlisted `scripts/test_*.py` never runs; "a suite the repo does not RUN is a suite it does not
   HAVE"). YAML re-parsed and the target confirmed present.

## Review Scope Contract (as posted on the issue)

`Class: ops-infra`. R1 typing into a live session · R2 a stale session id resuming silently ·
R3 the wrong cwd · R4 the tool growing the destructive verb · R5 reporting success when nothing
started · R6 the beat naming a remedy that does not exist. Each has a named test; R6 is the
regression that produced the issue and is pinned directly.

**PROVE — contract close-out** is in the PR body in the machine-readable shape.

## Not in this PR (honest boundary)

- **The cmux defect itself.** The teardown, `remain-on-exit`-equivalent behaviour and validation of
  stored resume targets on `surface resume set` are cmux's to build; this repo cannot host them.
- **A live cmux integration test.** There is no daemon reachable from this lane
  (`cmux tree` → `cannot connect to session socket /tmp/cmux-tui-1000/cloud.sock`), and this cell's
  cmux build has no `respawn-pane` verb at all (`unknown resource scope`), so the destructive path
  cannot be reproduced here. The suite drives an injected runner instead, and the argv it asserts is
  the exact form the fleet already uses.
- **The `cmux list-workspaces` → `cmux workspace list` grammar drift** on cell builds — separate
  defect, unchanged by this PR.

## Learnings

- `rg -rn 'pattern'` is **not** `grep -rn`: in ripgrep `-r` is `--replace`, so it rewrote every match
  in the output to the literal `n` and made me believe two files read `RELAUNCH (n / relaunch …)`
  mid-session. Bounded searches are cheap; *misread* ones are what cost a lane an hour.
- The fleet already knew `respawn-pane` deletes workspaces — in four comments — and still had no tool
  behind the knowledge. A documented hazard with no alternative is an instruction to improvise.
