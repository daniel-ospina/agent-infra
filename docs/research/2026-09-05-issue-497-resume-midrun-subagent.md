---
title: "Research: #497 — can pi resume a task sub-agent that died mid-run on a provider 402?"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-05
aboutSubjects: epistemic-team
aboutObjects: agent-infra, pi, issue-497, issue-476, builtin-tools, subagent, task-heartbeat
---

# Research: #497 — mid-run task sub-agent resume after provider terminal error (402)

> **Findings date:** 2026-09-05
> **Trigger:** #476 A19 documented residual — a task sub-agent that dies on
> `402 {"message":"Insufficient Balance"}` AFTER tool calls / side effects
> halts with an alert and requires a manual FULL re-run. #497 asks whether
> pi can instead resume the dead run from its partial transcript.
> **Domain classification:** Complicated (codebase mechanics + provider
> serialization semantics + process lifecycle — verifiable at source).
> **Verification method:** pi dist source (installed 0.84.x, agent-infra
> patched), agent-infra extension source, empirical session-file census of
> ~/.pi/agent/sessions (272 files, 29 with 402 records), external ecosystem
> scan (3 sonar queries). Tortoise epistemic graph offline (no
> TORTOISE_API_KEY) — no prior claims retrieved.

## Bottom line

**Resume-after-402 is mechanically feasible — but NOT with today's task-tool
spawn.** The blocker is not pi's session machinery (it is fully capable); it
is that task sub-agents spawn with `--no-session` (three call sites — §4(a)
scopes persistence to the two task-tool sites first), so a
dead child leaves **no transcript on disk at all**. The fix is a small spawn
change (persist children sessions with a parent-known `--session-id` +
capture the path) plus a resume re-dispatch path. This is option (a) in §6,
and it is the recommended primary. Full-rerun safety (option d, tool
idempotency) is a complementary guard, not a substitute.

Confidence: **HIGH** on the mechanism claims (source-verified); **MEDIUM** on
end-to-end resume quality (needs a spike — no live 402→resume run was
executed in this research; the claim rests on source + the observed fact
that interactive sessions already continue cleanly after 402 error turns).

---

## 1. Pi session mechanics (codebase-first, verified)

### 1.1 What a 402 death leaves on disk — for sessions that persist

Session files are JSONL trees (`~/.pi/agent/sessions/--<cwd>--/<ts>_<uuid>.jsonl`,
v3, `id`/`parentId`, header first line). Every `message_end` is persisted —
**including failed assistant turns**. Empirical census (272 session files, 29
containing `Insufficient Balance` records) shows the canonical mid-run 402
death leaf shape:

```
abe5d39e [assistant] stop=toolUse   ← last successful tool-call turn (bash/git/gh)
56a63e12 [toolResult] isError=false ← tool result PERSISTED (side effect applied)
9936c398 [assistant] stop=error     ← 402 leaf: content:[], errorMessage:
                                        "402: {"message":"Insufficient Balance",...}"
```

The full transcript of completed work — user task, every tool call, every
tool result (truncated outputs), thinking blocks — sits in the file
immediately before the error leaf. `stopReason:"error"` + `errorMessage` is
the documented terminal shape (§session-format.md).

### 1.2 The 402 is non-retryable at source

`isRetryableAssistantError()` (pi-ai): returns false when the error matches
NEITHER list. `NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN` includes
"available balance"/"insufficient_quota"/"out of budget"/"billing";
`RETRYABLE_PROVIDER_ERROR_PATTERN` covers network/5xx/429/timeouts.
`"Insufficient Balance"` matches neither → **not retryable** → no
`_prepareRetry`, the run ends. The agent-infra offline-resume patch
(`scripts/patch-pi-retry.sh`, 5-min-capped infinite backoff) does NOT help —
it only extends RETRYABLE failures, and 402 never enters the retry path.
#476's "no re-drive-after-terminal-error API" is confirmed: pi will not
re-drive the failed turn in-process. **None is needed** for process-level
resume (§1.4).

### 1.3 Empty-content error messages are dropped at serialization

When the next prompt fires on a session whose last entry is the empty 402
assistant message, the provider request builder omits it:
- Anthropic serializer (`pi-ai/dist/api/anthropic-messages.js`): `if
  (blocks.length === 0) continue;` for assistant messages.
- OpenAI-compatible serializer (DeepSeek, `openai-completions.js`): an
  empty assistant message is DROPPED from the request entirely — content is
  initialized to `null`/`""`, and the branch ends with `if (!hasContent &&
  !assistantMsg.tool_calls) { continue; }` (mirroring the Anthropic
  `blocks.length === 0` drop); `content: null` reaches the wire only when
  tool_calls are present.

So a resumed run sends clean history (failed turn omitted) and continues.
**Empirical confirmation:** many archived sessions contain 402 error records
followed by successful later turns (interactive recovery already works
today, e.g. DMeer 2026-09-01: 75 error records incl. 402s, final `stop`);
agent-infra 2026-09-03T15-06-24 session shows the drop mechanism on the real
DeepSeek path directly — an empty 402 error assistant entry omitted from a
later request that completed with `assistant stop`.

### 1.4 Resume is a new-process feature, already present

| Flag | Semantics (verified in `dist/main.js`, `SessionManager`) |
|---|---|
| `pi -p --session <path> "<prompt>"` | Open existing file, restore transcript as context, append prompt, run, exit |
| `pi -c` / `--continue` | Continue most recent session for cwd |
| `pi -r` / `--resume` | Interactive session picker |
| `pi --fork <path\|id>` | New session seeded from an old one |
| `/clone`, `/tree` w/ branch summaries, compaction `retainedTail` | Context hand-off primitives (self-contained checkpoints) |

`SessionManager.open()` keeps the leaf where the file ended (the 402 error
entry). `buildSessionContext()` walks leaf→root → the full transcript is the
resumed context. Compaction entries carrying `retainedTail` are documented
as "self-contained checkpoints ... so we can rebuild context from this
checkpoint without walking older entries" — a compaction-aware resume is a
natural extension.

**So the "resume from last turn" primitive is: start a NEW `pi -p --session
<dead-file>` (or `--fork` for a clean-room copy — §4(a) mandates fork for
repeated-attempt safety) with a continuation prompt. No pi patch required.**

---

## 2. What a killed child leaves behind today (agent-infra machinery)

### 2.1 Task children are sessionless — the actual blocker

Both spawners pass `--no-session` — three call sites total (the
recommendation in §4(a) changes the two builtin-tools/task-tool sites now
and defers the subagent-extension site):
- `extensions/builtin-tools/index.ts` task tool primary dispatch (~2355):
  `["-p", "--provider", provider, "--model", model, "--no-session",
  params.prompt]`
- the SAME file's fallback dispatch (`fbArgs`, ~2397) — the #476 hop-leg
  path: if it stays sessionless, a hop-leg child still dies with zero
  recoverable state
- `extensions/subagent/index.ts` (~477): `["--mode", "json", "-p",
  "--no-session"]`

`--no-session` → `SessionManager.inMemory` → **nothing written to
`~/.pi/agent/sessions/`**. The Sep-4 census "94s runs dying after tool calls"
leaves zero recoverable state today. The parent's captured stdout/stderr is
the ONLY residue, and it lacks tool-call granularity → today's manual resume
really is a full re-run (#476 A19).

### 2.2 The parent already has rich death telemetry (no session path)

The task tool's heartbeat/backstop machinery (Tier-1 zero-output 60s →
retryable; Tier-2 state-aware silence; Tier-3 exit watchdog; stream/tool
stall, 6h hard cap; #271 cut taxonomy with `cutGap` marker-gap detection;
network-outage kill suppression) resolves each death with: exit code, reason
taxonomy (`success`/`cut`/`failed`/`hard-cap`/`killedAfterCompletion`),
heartbeat state (`toolsInFlight`, `turnActive`, `streamAgeMs`, marker
trace), and last stderr/stdout. A 402 death = exit 1 + 402 text on stderr,
`toolsInFlight: 0` → `failed` classification → partial output to the
controller (the #476 halt-with-alert boundary).

The retry wrapper only auto-re-runs ZERO-OUTPUT failures (the #152
pre-first-tool-call boundary: no output ⇒ no side effects ⇒ safe to re-run).
Mid-run deaths are deliberately never auto-re-run — the side-effect replay
guard. The cut composition itself says: "parent should decide: accept,
re-dispatch, or escalate."

### 2.3 epic-executor resume = issue-batch level, not transcript level

epic-executor cross-session resume (Tortoise/FalkorDB) answers "which issues
merged?" → re-dispatch remaining issues FROM SCRATCH. It is an orchestration
ledger, not a mid-run transcript vehicle. It complements (c) in §6 but does
not recover the 94s of completed tool work per run.

---

## 3. Side-effect idempotency constraints

1. **Tool results are evidence, not state.** The transcript records
   `toolResult` outputs (truncated — bash output capped at 51200 bytes;
   git/gh/file effects are external). A resumed agent can SEE what was done
   but cannot always reconstruct full prior state from truncated output.
2. **The replay danger is real and bounded.** The concrete risk: the resumed
   agent re-executes an already-applied tool call (re-push a merged commit,
   re-comment on an issue, re-apply an edit). Mitigations: (i) the resume
   prompt instructs verify-before-act; (ii) NATURAL GUARDS COVER ONLY THE
   DEDICATED file/git tools — `edit` fails when the old text no longer
   matches (the genuinely failsafe tool), git push of an already-pushed ref
   is a no-op, gh-comment dedupe needs a marker convention. `write` is NOT
   a natural guard: it truncates and overwrites, so it fails-safe only when
   the new content is byte-identical — the dangerous replay case (stale
   view → different content) CLOBBERS state. The census danger-class calls
   run as **bash** (bash/git/gh/curl), and any bash-mediated non-idempotent
   call (curl POST, gh comment, heredoc append, DB writes) has NO natural
   guard — for that subset the only mitigation is prompt discipline, which
   is unvalidated → this is the concrete motivation for (d) hardening on
   the high-frequency side-effect tools.
3. **No replay-safe markers exist today** for gh comments / git pushes
   (no dedupe marker convention). This is option (d) work.
4. The #476 census class (mid-run death AFTER tool calls) is exactly the
   class auto-recovery refuses today. Transcript-seeded continuation does
   NOT replay tool calls — it re-reasons from their recorded results — so
   it is *less* re-execution than a full re-run; but the comparison is NOT
   strict: resumed context is lossy (truncated tool outputs) and time-stale,
   while a full re-run re-derives *current* state (fresh reads beat stale
   records for read-verify purposes). Replay safety therefore rests on the
   resume prompt + model discipline, gated by the (d) guard set.

---

## 4. Options

### (a) Transcript-seeded resume — `pi -p --fork` of the dead child's session — RECOMMENDED PRIMARY

- **Mechanism:**
  1. **Spawn WITH a parent-known session id — at the TWO task-tool sites.**
     Remove `--no-session` from the builtin-tools task tool primary AND its
     fallback dispatch (§2.1) and spawn with `--session-id <per-dispatch
     nonce>` — the session id is filename-encoded
     (`<ISO-timestamp>_<uuid>.jsonl` where the uuid IS the session id;
     `createSessionManager` creates that session if missing), and the parent
     resolves the file post-mortem via `findLocalSessionByExactId` from its
     own cwd. No cwd forwarding needed for the primary spawner:
     `spawnSubAgent` hardcodes `cwd: process.cwd()` (builtin-tools ~1415),
     so child cwd ≡ parent cwd. The THIRD site (`extensions/subagent`)
     KEEPS `--no-session` for now (§4(a).5): persisting sessions there
     would orphan them — divergent child cwd breaks exact-id resolution
     from the parent cwd, so the parent could not locate, delete-on-success,
     or mark them, and they would pollute interactive `/resume` pickers
     unaddressably.
  2. **Fallback capture** (future, for the divergent-cwd subagent site):
     child-side emission of the resolved session file path on stderr — an
     explicit small change to the `task-heartbeat` session_start handler
     (today it emits only the `ready` marker). This emission must be
     implemented DISABLE-agnostic (like the orphan watchdog, which arms
     under `TASK_HEARTBEAT_DISABLE=1`): the subagent site currently spawns
     with `TASK_HEARTBEAT_DISABLE=1`, and the whole emitter including
     session_start is gated on `taskHeartbeatActive()` — a gated emission
     could never fire for site-3 children, leaving their persisted sessions
     unlocatable. The site joins only when the emission is DISABLE-agnostic
     AND a parent-side consumer exists. Newest-file-in-child-cwd-dir
     discovery is ONLY safe for serial runs — under parallel same-cwd
     children (epic-executor fan-out, the #476 census fleet class) it can
     select a sibling's session.
  3. **Re-dispatch**: on a terminal-error death (402 signature in stderr +
     non-zero exit) where the attempt made REAL tool progress — heartbeat
     `toolsMaxInFlight > 0` / `everSawTool` latched for THAT attempt, NOT
     `toolsInFlight` (an immediate first-turn 402 never increments
     `toolsInFlight`, so it reads 0 in BOTH the progress and no-progress
     arms and cannot discriminate them) — dispatch `pi -p --fork
     <dead-file> --session-id <fresh per-attempt nonce> --provider
     <hop-leg> "<resume prompt>"`. Compose `--fork` + `--session-id`
     (verified in createSessionManager: the fork branch passes
     parsed.sessionId to forkFrom; the duplicate-id guard exits 1, so each
     attempt's nonce must be fresh) so every attempt's fork file is
     resolvable via findLocalSessionByExactId — do NOT rely on newest-file
     discovery (§4(a).2 parallel-safety). **Fork, not in-place continuation**:
     in-place appends from a failed resume would pollute the dead child's
     transcript for the next attempt. LADDER with a BOUND: if a resume
     attempt itself dies on a fresh 402 AFTER real tool work (latch
     above), seed the NEXT attempt from that attempt's fork file
     (fork-of-fork preserves progress); zero-tool-work deaths route to the
     existing #476 hop/alert path instead of the resume path — detection
     rests SOLELY on the per-attempt latch (`everSawTool === false` /
     `toolsMaxInFlight === 0`), never on file existence: a 402 original
     run ALWAYS leaves a file (header + user prompt + empty error leaf —
     the failure leaf is persisted, and lazy session-file creation fires on
     the first persisted entry), so "pristine re-fork" against an
     empty-progress file would waste a ladder rung re-running from scratch;
     a genuinely missing file indicates a hard-kill death (SIGKILL/OOM),
     which is out of option (a) scope. Cap the ladder at MAX N attempts
     (or exhaustion of the hop-leg set), then escalate to the #476
     halt-with-alert boundary — 402 is never transient at source (§1.2),
     so an unbounded ladder would hammer a billing API on an unfunded
     account.
     Resume prompt template:
     "The prior run died on a provider billing error after completing the
     tool work visible in this transcript. Do NOT redo completed work;
     verify state and finish the task."
  4. **Operational consequences (scope for the implementer):** persisting
     every task child's session (multi-MB transcripts with full tool I/O,
     prompts, thinking — census files reach 11+ MB) into the shared cwd
     session dir pollutes human `/resume` pickers and grows unboundedly per
     dispatch. Needs a retention/cleanup policy: delete on success, prune
     after N days, and a filter/marker convention (e.g., a label or a
     dedicated session subdir per dispatch) so task-child sessions do not
     surface in interactive pickers.
  5. **Gate scope — task-tool children FIRST:** persistence AND
     gated auto-resume apply to the two builtin-tools/task-tool spawn sites
     only. The third site (`extensions/subagent`) keeps `--no-session`
     until (a) its heartbeat emitter is enabled (drop
     `TASK_HEARTBEAT_DISABLE` for its children) with the path emission
     implemented DISABLE-agnostic, AND (b) a parent-side marker consumer
     exists — otherwise its persisted sessions would be unlocatable
     (divergent cwd) and auto-resume there would cover exactly the
     mid-tool-call-death class that needs an in-flight marker.
- **Feasibility: HIGH** — every mechanism verified at source (§1). No pi
  patch. Effort: small-to-moderate (spawn change at the TWO task-tool
  sites — subagent-extension site deferred per §4(a).5, with its
  DISABLE-agnostic emission + parent consumer as future add-on — plus
  session-id plumbing + resume dispatch + integration tests; reuse of the
  #476 hop machinery for leg selection).
- **Risk: MEDIUM** — quality rests on the resume prompt + model discipline
  (verify-don't-redo); truncated tool outputs can hide partial effects; see
  §6 spike for the hop-window and repeated-402 cases.
- **Best fit:** the 402 mid-run class — deaths where the in-flight tool
  batch COMPLETED and was recorded (the census signature: `toolsInFlight`
  0 at death because the 402 killed the NEXT request after the tools
  finished). The re-dispatch gate uses the attempt's real-progress latch
  (`toolsMaxInFlight > 0`), NOT `toolsInFlight` (§4(a).3). Generalization
  to SIGKILL/OOM/laptop-sleep is ONLY safe when the parent's recorded state
  shows no unrecorded in-flight call; a death mid-tool-call leaves the
  in-flight call unrecorded and possibly half-applied, and the resume
  instruction "don't redo completed work" points the wrong way for exactly
  that call — that hazard class needs a marker for in-flight calls before
  option (a) extends to it.

### (b) Compaction-summary continuation

- A child periodically (or on stall) emits a compaction/branch-style summary
  of progress; resume seeds a fresh run with the summary.
- **Feasibility: MEDIUM; effort: higher than (a); value: lower** — the
  transcript itself is the best summary, so (b) only wins where a session
  file is absent (sessionless children today) or a single turn is enormous.
  Costs tokens; summarizing mid-tool is fragile.
- **Best fit:** rare. Not recommended as primary.

### (c) Orchestrator-level checkpointing (epic-executor/Tortoise)

- **Already exists** at issue-batch granularity. Extending to per-run
  progress ledgers is cheap but coarse — resume is still mostly a re-run
  guided by notes.
- **Feasibility: HIGH; risk: LOW (no replay); value: LOW for the 94s class**
  (wastes completed work). Keep as the cross-session accounting layer.

### (d) Tool-level idempotency so full re-runs are safe

- Make high-frequency DEDICATED tools replay-safe first: gh-comment dedupe
  markers, git push already-pushed no-op detection, edit/apply guards
  (mostly natural for dedicated file/git tools; the bash-mediated set —
  curl POST, heredoc append, DB writes — has NO natural guard and needs
  tool-level wrapping or explicit prompt discipline).
- **Feasibility: MEDIUM-HIGH for the common set; effort: moderate.** Does
  not reuse completed work — it removes the DANGER that blocks auto-re-run.
  With (a) in place, (d) is the safety net for when the transcript is
  ambiguous or the resume prompt fails.
- **Best fit:** complementary guard; pairs with the #152 zero-output gate —
  with (d), the gate could extend from "zero output" to "any death" for the
  guardable tool set.

### (e) Hybrid — RECOMMENDED SHAPE

1. **(a) primary**: persist child sessions + transcript-seeded resume on
   terminal-error deaths (402 first; generalize later).
2. **(d) guard**: idempotency for the top-N side-effect tools so re-run /
   resume drift stays safe.
3. **(c) ledger**: orchestrator records resume attempts/outcomes in the
   Tortoise/FalkorDB ledger (epic-executor already owns this pattern).
4. **(b)** only if a spike shows transcript-only resume is insufficient for
   very long single turns.

---

## 5. External: does any other coding agent solve mid-run crash resume?

1–3 sonar queries (2026-09-05). Consensus: **nobody auto-resumes mid-run
after a provider error by default; everyone persists transcripts and resume
is a manual CLI re-open.** OpenHands is the exception at the SDK level.

| Ecosystem | Resume vehicle | Auto mid-run resume? |
|---|---|---|
| Claude Code | `claude --continue` / `--resume` + checkpoints (rewind); transcript persisted to disk; GitHub issue #28489: crash mid-run → "session is lost unless you manually resume with the session ID" | No — manual |
| Codex CLI | `codex resume <SESSION_ID>` / `--last`; sessions under `~/.codex/sessions` | No — manual |
| OpenHands | SDK persists state per event; resume = load `base_state.json` + REPLAY event log; `conversation.pause()`/`run()`; agents detect incomplete conversations and continue from the last processed event | Yes (SDK-level) |
| Durable-execution literature | checkpoint-after-each-step + replay/skip on recovery | Yes (framework-level) |

Takeaway: pi's `--session` + transcript restore is on par with Claude
Code/Codex. Full automatic mid-run resume is novel in CLI agents; OpenHands
shows the checkpoint+replay pattern works, but its replay is event-log
determinism — pi (like Claude/Codex) is LLM-driven, so replay means
"re-reason with the recorded history," which is what option (a) does.

## 6. Recommendation

**Pursue (e)-hybrid with (a) as the implementation core**: persist task
sub-agent sessions — drop `--no-session` at the two task-tool spawn sites
(§2.1/§4(a).1) and spawn with a parent-known `--session-id`
(filename-encoded, `findLocalSessionByExactId`-resolvable; a `--name` is
header-only and gives no path resolution). The subagent-extension site
defers (§4(a).5): it joins only when its heartbeat emitter is enabled (path
emission DISABLE-agnostic) AND a parent consumer exists. Detect the
terminal-402 death signature from the child (non-zero exit + 402 in stderr)
with a real-progress latch (`toolsMaxInFlight > 0` for that attempt, NOT
`toolsInFlight` — see §4(a).3), then re-dispatch via `pi -p --fork <file>
--session-id <fresh per-attempt nonce> --provider <hop-leg>` with a
verify-don't-redo resume prompt, fork-ladder bounded (MAX N attempts or
hop-leg exhaustion → #476 halt-with-alert). Add (d) idempotency
guards for the top side-effect tools (dedicated file/git tools first — the
bash-mediated set has no natural guards), a retention/cleanup policy for
persisted child sessions, and log resume outcomes in the existing Tortoise
ledger.

**Suggested follow-on (spike, not implementation):** prove the MECHANICS
end-to-end with a stubbed 402: run a real task child against a scripted
provider failure after N COMPLETED tool calls (the census signature: all
in-flight tools recorded before the 402 killed the next request),
capture the session file, re-dispatch `pi -p --fork`, and verify (1) the
resumed context omits the failed turn, (2) the resumed run is executable on
a smaller-window hop model WITHOUT silently compacting away the
fine-grained tool history (or, if it compacts, the compaction entry is
recorded so the agent KNOWS history was summarized), (3) the run finishes,
(4) a resume that itself dies does not pollute the dead child's file (fork
keeps each attempt clean-room; verify BOTH ladder arms — fork-of-fork
preserving tool-work progress on a second 402, and zero-tool-work deaths
routing to the hop/alert path — AND the ladder cap: N attempts then
escalation to #476 halt-with-alert), and (5) redo-discipline: the agent
does not
re-execute completed tool calls on the stubbed run. Note (5) is a
probabilistic model-discipline property — a single clean pass verifies
mechanics, not behavioral reliability; redo-avoidance at scale needs
repeated-run evidence and/or (d) hardening before the hazard is "bounded".

**Confidence tiers**
- HIGH (source + census): 402 leaf shape; empty-error-message drop at
  serialization; `--session` restore mechanics; task children are
  sessionless; 402 non-retryable; external CLI agents manual-resume by
  default (OpenHands is the SDK-level exception, per §5).
- MEDIUM (source-analogous, not executed): transcript-seeded resume produces
  a clean, non-replaying continuation. `⚠️ emerging` — the spike above is the
  Required Evidence.

## Sources
- pi docs (installed): sessions.md, session-format.md, compaction.md
- pi dist (installed): modes/print-mode.js, core/agent-session.js,
  core/agent-session-runtime.js, main.js, cli/args.js;
  pi-agent-core agent.js/agent-loop.js; pi-ai api/anthropic-messages.js,
  api/openai-completions.js (serialization drop logic)
- agent-infra: extensions/builtin-tools/index.ts (spawn args, retry wrapper,
  cut taxonomy, heartbeat machinery), extensions/subagent/index.ts,
  extensions/task-heartbeat.ts, skills/epic-executor/SKILL.md,
  docs/providers.md §6 (offline-resume patch), scripts/patch-pi-retry.sh
- Empirical: ~/.pi/agent/sessions census (272 files, 29 with 402 records;
  leaf-shape dump from tortoise 2026-09-03T19-37-37 session)
- External (sonar, 2026-09-05): Claude Code docs + GitHub issue #28489;
  OpenHands SDK docs (pause/resume, event replay, persistence); Codex CLI
  resume docs; durable-execution article
