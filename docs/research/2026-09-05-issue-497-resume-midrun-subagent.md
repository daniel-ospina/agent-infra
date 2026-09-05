---
title: "Research: #497 — can pi resume a task sub-agent that died mid-run on a provider 402?"
type: operations
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
is that task sub-agents spawn with `--no-session`, so a dead child leaves
**no transcript on disk at all**. The fix is a small spawn change (persist
children sessions + capture the path) plus a resume re-dispatch path. This
is option (a) in §6, and it is the recommended primary. Full-rerun safety
(option d, tool idempotency) is a complementary guard, not a substitute.

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
<dead-file>` with a continuation prompt. No pi patch required.**

---

## 2. What a killed child leaves behind today (agent-infra machinery)

### 2.1 Task children are sessionless — the actual blocker

Both spawners pass `--no-session`:
- `extensions/builtin-tools/index.ts` (task tool): `args = ["-p", "--provider",
  provider, "--model", model, "--no-session", params.prompt]` (~line 2355)
- `extensions/subagent/index.ts`: `args = ["--mode", "json", "-p", "--no-session"]`

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
   prompt instructs verify-before-act; (ii) natural guards exist — `edit`
   fails when the old text no longer matches, `write` is idempotent, git
   push of an already-pushed ref is a no-op, gh comment dedupe needs a
   marker convention; (iii) #476's auto-hop to a healthy leg is the
   common-case recovery and only INCOMPATIBLE legs halt.
3. **No replay-safe markers exist today** for gh comments / git pushes
   (no dedupe marker convention). This is option (d) work.
4. The #476 census class (mid-run death AFTER tool calls) is exactly the
   class auto-recovery refuses today — the resume question is whether a
   transcript-seeded continuation (which does NOT replay tool calls, it
   re-reasons from their recorded results) is materially safer than a full
   re-run. It is: strictly less re-execution, strictly more context.

---

## 4. Options

### (a) Session-file replay into a new `pi -p --session` run — RECOMMENDED PRIMARY

- **Mechanism:** (1) spawn children WITHOUT `--no-session` (session dir is
  child-cwd-encoded, so the parent must also resolve/forward the child's
  effective cwd); (2) capture the session file path — the ONLY viable
  mechanism without new machinery is child-side emission: the
  `task-heartbeat` session_start hook (or a dedicated hook) prints the
  resolved session file path to stderr, which the parent already streams;
  fallback: newest-file-in-child-cwd-dir discovery (filenames are
  `<ISO-timestamp>_<uuid>.jsonl` — `--name` lives only in the header, never
  the filename, so there is no name→path resolution API); (3) on a
  terminal-error death (402 signature in stderr + non-zero exit), dispatch
  `pi -p --session <path> --provider <hop-leg> "<resume prompt>"` — resume
  prompt templates: "The prior run died on a provider billing error after
  completing the tool work visible in this transcript. Do NOT redo completed
  work; verify state and finish the task."
- **Feasibility: HIGH** — every mechanism verified at source (§1). No pi
  patch. Effort: small-to-moderate (builtin-tools spawn change + marker +
  resume dispatch + integration tests; reuse of the #476 hop machinery for
  leg selection).
- **Risk: MEDIUM** — quality rests on the resume prompt + model discipline
  (verify-don't-redo). Truncated tool outputs can hide partial effects.
- **Best fit:** the 402 mid-run class; generalizes to any crash with a
  persisted transcript (SIGKILL, OOM, laptop sleep).

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

- Make high-frequency tools replay-safe: gh-comment dedupe markers, git
  push already-pushed no-op detection, edit/apply guards (mostly natural).
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
sub-agent sessions (drop `--no-session`; capture the session path via
child-side stderr emission of the resolved session file, newest-file-in-
child-cwd fallback — a deterministic `--name` is header-only and gives no
path resolution; optionally usable for header-matching disambiguation in the
fallback), detect the terminal-402 death signature from the child, and
re-dispatch on a healthy leg with a verify-don't-redo resume prompt via
`pi -p --session <path>`. Add (d) idempotency guards for the top side-effect
tools, and log resume outcomes in the existing Tortoise ledger.

**Suggested follow-on (spike, not implementation):** prove end-to-end with a
stubbed 402: run a real task child against a scripted provider failure after
N tool calls, capture the session file, re-dispatch `pi -p --session`, and
verify (1) the resumed context omits the failed turn, (2) the agent does not
re-execute completed tool calls, (3) the run finishes. This converts the
MEDIUM end-to-end confidence to HIGH.

**Confidence tiers**
- HIGH (source + census): 402 leaf shape; empty-error-message drop at
  serialization; `--session` restore mechanics; task children are
  sessionless; 402 non-retryable; external agents all manual-resume.
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
