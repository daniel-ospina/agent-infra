<!-- research-path: https://github.com/daniel-ospina/agent-infra/issues/2823#issuecomment-6780970579 -->
<!-- plan-review: cycles=0, status=deferred-to-harness-reviewer, version=2.3.0 -->
# #2823 — attribute a child that died before its first turn

## Problem

**`task`** presents pre-turn output as the child's message, and returns no attributable failure. The
scope of this document and of PR #3925 is the **`task`** dispatcher ONLY: the `subagent` tool
(`extensions/subagent/index.ts` `runSingleAgent`) has its own spawn path, never calls `spawnSubAgent`,
carries no liveness attribution at all, and runs its children with the heartbeat emitter deliberately
ejected (`TASK_HEARTBEAT_DISABLE: "1"`) — so its half of the issue's ask 1 needs its own evidence
source and is tracked separately in **#3930**. Re-measured on today's main, the
production defect is narrower than the issue body says and its producer is already fixed:

- The producer — test files farmed into `~/.pi/agent/extensions` and executed as extensions at
  session start — is fixed (`38d4ed70c`, #1509/#2841) and the farm on this box is clean
  (no `*.test.ts|*.spec.ts|*.test.js|*.spec.js` under `~/.pi/agent/extensions`). So ask 3 ("why does
  `auto-sync.test.ts` fail only under a child?") is ANSWERED: the child *was* running the suite.
- What is NOT fixed is attribution. Measured: a child that dies at extension load produces
  **empty stdout**, the suite text on **stderr**, exit **2**, and **zero** heartbeat markers. The task
  tool then composes that stderr text as `content` (the "message") and stamps
  `childState: "exited-no-result"` — a value whose docstring means "it ran, produced nothing
  readable". Nothing in the payload says the text was never the child's. That is the #2823 complaint
  ("invisible as a failure": the text is plausible test output).
- `classifyChildLiveness` treats ANY stdout as `completed` (`index.ts:2380`) and `childLivenessFor`
  floors `childMessagesSent` to 1 whenever stdout exists — so the one channel that could prove
  "no turn began" is explicitly overridden.

## Fix (one measurement, one new state, one composition arm)

1. `childNeverBeganTurn()` — a pure, exported predicate over evidence the parent ALREADY holds:
   - **Proof A:** the emitter ran (`sawReady || markerCount > 0`) and `everSawWork` (latched on
     `turn_start`/`tool_start`) is false ⇒ no turn began. Covers the false-PASS case where stdout
     carries text but pi never wrote a final message.
   - **Proof B:** the parent's emitter for this child was **LIVE** and got ZERO markers back on a
     **non-zero** exit ⇒ the child never completed `session_start` ⇒ no turn began. This is the
     measured #2823 payload. LIVE is not "armed": the task tool sets `TASK_HEARTBEAT=1`
     UNCONDITIONALLY as the sub-agent identity marker, so the premise is the emitter's own three-term
     gate — `TASK_HEARTBEAT === "1" && PI_MODE === "print" && TASK_HEARTBEAT_DISABLE !== "1"` — read
     through `hbEmitterLiveFor()` and pinned to `taskHeartbeatActive` by a drift row. A child whose
     emitter was ejected emits zero markers BY DESIGN and proves nothing; the non-zero exit gate is
     the second bound, so a `TASK_HEARTBEAT_DISABLE=1` success is never relabelled.
2. New `TaskChildState` member `died-before-first-turn` (subsumes nothing: the existing
   `died-before-first-message` arm keeps its population — `!hasStdout && childMessagesSent === 0`).
   The `childMessagesSent` floor is skipped when a turn is DISPROVED, so the field set cannot
   contradict itself (`0`/`null` beside "no turn", never a floored `1`).
3. `doResolve` gains an arm beside the `died-before-first-message` one: a loud header that names the
   cause ("SETUP failure — an extension/session_start hook, or pi before the prompt"), states the text
   is NOT the reply, quarantines it under `--- what the child left behind (NOT its message) ---`, sets
   `details.status = "died-before-first-turn"` + `isError: true`, and derives the **same** string for
   the durable ledger row (one settle, two surfaces, one claim).
4. `FAILED_TASK_STATUS` gains the member, and its MIRROR `extensions/shared/spawn-capacity.ts:99`
   (`FAILED_STATUS`) is updated in the same commit — pinned by the existing drift row.

## Alternatives considered

- **Re-plumb the transport (`--mode json` / a side-channel file for the final message).** Canonical per
  the external finding, but it changes the transport every consumer of `task` depends on, and it fixes
  a stream the measurement shows is ALREADY clean (extension `console.log` goes to stderr). Rejected as
  disproportionate.
- **Treat any stdout as suspect unless a turn marker exists, with no exit-code gate (drop Proof B's
  gate).** Simpler, but it relabels a genuine answer from a heartbeat-less child — a false failure on a
  success, the worst direction. Rejected.
- **Retry on this state.** Retrying a setup failure re-runs the same broken setup and pays a model call;
  the existing `died-before-first-message` arm does not retry either. The caller decides.

## Residual (stated, not hidden)

Two windows this design does **not** close, named so a later reader's risk model is correct rather than
optimistic. They are NOT the same window and they are not bounded the same way:

1. **Proof A fires on ANY exit code — it has no exit-code gate.** `childNeverBeganTurn` answers
   `!everSawWork` whenever the emitter is seen to have run (`sawReady || markerCount > 0`), and that arm
   is deliberately exit-agnostic (the truth table pins *"ready + no `turn_start` is 'no turn', **even on
   exit 0** (the false PASS)"*). So an **exit-0 child that answered on stdout is relabelled a setup
   failure if both its `turn_start` and its `turn_end` marker were lost**: the answer is quarantined
   behind `--- what the child left behind (NOT its message) ---`, `isError: true` is stamped, and the
   durable row records `died-before-first-turn`. Proof A's guarantee therefore rests on those two
   markers arriving; unlike Proof B it is NOT bounded by the exit code. `everSawMsg` — a streamed
   assistant message, which does prove a turn existed — is deliberately not a `positiveMessageEvidence`
   term (it is content-blind, so trusting it would be a systematic false PASS on the #5195 E shape),
   so it cannot rescue this window either.
2. **An emitter that is live-but-failing in a way that emits no `ready` and no turn markers** is
   indistinguishable from a child that never started. Proof B's non-zero-exit gate bounds this one to
   failing children.

## Wiring

| Call site / consumer | What it does there |
|---|---|
| `extensions/builtin-tools/index.ts` `childLivenessFor` | sole producer of `TaskChildLivenessSnapshot`; now passes `everSawWork` + `heartbeatArmed` |
| `doResolve` (`spawnSubAgent`) — `livenessSnapshot`, `rowReason`, payload arm | stamps `childState`/`status`/`isError`, writes the outcome row, composes the message |
| `classifyBackgroundOutcome` → `FAILED_TASK_STATUS` | `task({background:true})` settle: `status: failed`, `reason: died-before-first-turn` |
| `extensions/shared/spawn-capacity.ts` `FAILED_STATUS` | mirror, so the review floor never counts the payload as a dispatch verdict (drift row `spawn-capacity.test.ts:91`) |
| `exhaustionStatusFor` / `UNCONFIRMED_END_STATES` | kill precedence unchanged; the new state joins the terminal set so an un-exited child reads `running` |
| `builtin-tools.test.ts`, `dispatch-record.test.ts` | the tests that must go red without the change |
| `hbEmitterLiveFor` (drift row) | the parent's "emitter live" premise must stay term-for-term equal to the emitter's `taskHeartbeatActive` gate |

## Scope boundary

- IN: the `task` dispatcher (`spawnSubAgent`), its payload, its durable row, its mirrors.
- OUT: the `subagent` tool's `runSingleAgent` path — separate spawn, no liveness attribution, emitter
ejected by design. Tracked in **#3930** (opened from this PR's review, so the claim and the code agree).

## Steps

1. Predicate + classifier + state member; unit tests incl. the false-attribution legs. (test must fail first)
2. Payload arm + ledger reason; `dispatch-record` test asserting row reason == payload status.
3. `FAILED_TASK_STATUS` + spawn-capacity mirror; drift row stays green.
4. Mutation proof: delete the new classification arm, show the guarding tests red; restore.
