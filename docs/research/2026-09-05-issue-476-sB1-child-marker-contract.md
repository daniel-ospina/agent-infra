---
title: "Issue #476 sB1 — in-child stderr marker contract for the [provider-exhaustion] kind"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-05
aboutSubjects: provider-failover, builtin-tools, task-heartbeat
aboutObjects: agent-infra, pi, issue-476
---

# Issue #476 sB1 — In-Child Stderr Marker Contract for the [provider-exhaustion] Kind

- **Date:** 2026-09-05
- **Spike:** sB1 (issue #476 — provider-exhaustion failover)
- **Question:** Precisely define the child-side stderr marker contract for the NEW exhaustion marker
  `[provider-exhaustion] hop=… model=<leg> reason=402|blocked provider=…` as the FINAL stderr line:
  prefix/kind classification, line-format + escaping, final-line capture guarantees, nonce
  authentication, and stdout isolation.
- **Method:** Read-only source analysis. Repo: `.worktrees/476/` (`extensions/builtin-tools/index.ts`,
  `extensions/task-heartbeat.ts`, `extensions/shared/print-mode.ts`). Pi runtime:
  `…/node_modules/@earendil-works/pi-coding-agent/dist/` (`core/agent-session-runtime.js`,
  `core/extensions/runner.js`, `modes/print-mode.js`, `core/output-guard.js`, `core/extensions/types.d.ts`).
  No web searches, no git ops.

## Findings (with evidence)

### 1. Kind vocabulary, prefix gating, unknown-kind handling
- Parent prefix: `HEARTBEAT_MARKER_PREFIX = "[task-heartbeat]"` (index.ts L587). ALL 7 recognized kinds
  live under it: `KNOWN_MARKER_KINDS = {ready, tool_start, tool_end, turn_start, turn_end, tick, session_end}`
  (L854–863).
- Classification is **parse success on a full line**, not mere prefix: `parseHeartbeatLine`
  (L870–906) strips ANSI + trims, requires the line to START with `[task-heartbeat]` (L878–879), takes the
  first whitespace token as kind (L884), requires kind ∈ KNOWN set (L880), then nonce-gates (L881–884).
- A `[provider-exhaustion]` line **cannot collide**: prefix mismatch → parse returns `false` at L878 →
  `ingestHeartbeatChunk` (L1078–1124) appends the ENTIRE line to the capped stderr accumulator with `"\n"`
  and fires `onRealOutput` (L1106–1108). It is treated as **real stderr** — preserved, not filtered, and it
  flips `hasOutput`.
- Unknown kinds under the `[task-heartbeat]` prefix are ALSO real stderr (preservation is deliberate — the
  orphan watchdog's `[task-heartbeat] orphan_watchdog …` attribution line rides this path).
- `markerKindOf` (L845–852) mirrors kind extraction; used only to fire the `session_end` completion edge.
- Mid-line prefix handling (L1092–1105): any `[task-heartbeat]` occurring after column 0 splits the line —
  head survives as real stderr, marker tail parsed/discarded. Irrelevant to `[provider-exhaustion]` (its
  substring never contains the heartbeat prefix; keep it that way).

### 2. Line-format contract + filtering
- Format is NOT strictly `key=value`: it is `[task-heartbeat] <kind> <token>*` where tokens are whitespace-
  separated; `tool_start`/`tool_end` carry POSITIONAL tokens (`<id> <name>`, L194–209 task-heartbeat.ts);
  only `tick` and `nonce` are `key=value` (`([a-z_]+)=(\d+)` digit fields L949–961; nonce
  `([A-Za-z0-9_-]+)` L883). No quoted values, no escape mechanism anywhere. Values therefore must be
  single `\s`-delimited ASCII tokens.
- Arrows survive any parser: nothing splits on `->`; `hop=deepseek->qwen-tp` is safe as long as detectors
  don't split on `\s` inside it (they don't — the marker is matched whole-line).
- Filtering: TRUE markers never reach the accumulator (discarded at data arrival, never call
  `onRealOutput` — guarantee-6 comment L1473–1477; this holds for BOTH stdout and stderr result paths).
  A line failing kind/nonce gate is NOT filtered — it lands in `details.stderr` / content stderr sections.
- stdout is NEVER marker-parsed: `proc.stdout.on("data")` (L1505–1509) raw-appends; marker parsing exists
  only on `proc.stderr.on("data")` (L1510–1511) via `ingestHeartbeatChunk`.

### 3. Final-line capture guarantee
- Parent reads stderr until EOF/close; `finalize` (close/exit-settle) runs `flushHeartbeatLineBuf` first
  (L1616, L1745) so an unterminated trailing line is still handled.
- 1 MB cap keeps the TAIL (`appendCap(…, 1_000_000)` L1465–1467, applied L1483): a FINAL-line marker
  survives even if total stderr > 1 MB (oldest bytes drop). Line-buffer overflow (4096, L1047) discards
  only `[task-heartbeat]`-prefixed residue (L1036–1046); `[provider-exhaustion]` residue is preserved —
  an unterminated exhaustion line at EOF survives, an unterminated unknown `[task-heartbeat]` kind would
  be dropped. Another concrete reason the new prefix is the safer choice.
- Markers arriving AFTER `session_end` are still parsed (ingest is byte-driven; no lock after session_end).
- Child-side flush: markers via `console.error` (task-heartbeat emit L~330) rely on natural event-loop
  drain — proven by the shipped `session_end` marker, but for a latch trigger prefer `fs.writeSync(2,…)`
  so no exit path (signal handler `process.exit(143)`, output-guard `process.exit(1)`) can cut an async
  pipe write.
- Teardown hook confirmed: `AgentSessionRuntime.dispose()` fires `session_shutdown` (reason `"quit"`) then
  `session.dispose()` (agent-session-runtime.js L288–294); `emitSessionShutdownEvent` awaits handlers
  (extensions/runner.js L50–61). In print mode this runs in `finally` on BOTH success and error paths
  (print-mode.js L133–138; stopReason-error sets exitCode=1 at L120–122) — always before process exit and
  AFTER the stdout payload write (L124–128), so stdout-first → marker-last → close ordering holds
  (matches the comment at task-heartbeat.ts session_shutdown hook).
- Caveat: `SessionShutdownEvent.reason` is only `quit|reload|new|resume|fork` — no error payload. The
  child must LATCH the 402 in-session and emit at teardown. **Latch hook = `message_end` text
  classification, NOT `after_provider_response`** — s2 verified that `after_provider_response` never
  fires on non-2xx for the SDK-backed `openai-completions` transport used by every agent-infra
  provider (incl. the openrouter hop legs), because the SDK throws on `!response.ok` before the
  `onResponse` hook. The reliable signal is `message_end` firing on the failed turn with
  `message.errorMessage` text (s2 Finding 1) in both interactive and print children (s2 Finding 4).

### 4. Nonce + non-collision
- No heartbeat kind matches `provider-exhaustion` (kind gate is exact set membership) and no regex matches
  the token; a different prefix never even reaches the gate.
- Nonce gates ONLY lines that pass the prefix+kind gate, and only when `expectedNonce !== undefined`
  (L881). Parent sets `expectedNonce = hbNonce` (L1481) when `TASK_HEARTBEAT=1`; nonce =
  `randomBytes(6).toString("hex")` injected as `TASK_HEARTBEAT_NONCE` (L1402–1405).
- Today a `[provider-exhaustion]` line is neither authenticated nor rejected — it is un-gated real stderr.
  For #476, if the parent-side exhaustion parser authenticates (RECOMMENDED — MCP servers inherit the
  child's fd 2 and could forge the latch), the marker MUST carry `nonce=<hex>` matching the heartbeat
  nonce, and the child only has it when `TASK_HEARTBEAT=1` + env present (task-heartbeat.ts L~315).

### 5. Zero-stdout / stdout isolation
- Print mode redirects ALL `process.stdout.write`/`console.log` to stderr (`takeOverStdout`,
  output-guard.js L28–55); stdout carries ONLY the final assistant text via `writeRawStdout`, serialized
  through an awaited tail and `flushRawStdout()` (L67–88) before exit. Markers are stderr-only by
  construction.
- Bug-crash case (exit-0, stdout prose QUOTES the 402 text): the real marker is in the stderr channel →
  always `details.stderr` (clean-success path L473–474, tail 4000) or the content stderr section (failure/
  cut/hard-cap paths). The latch detector MUST match against `details.stderr` (the stderr channel) with a
  line anchor — never against `content` stdout text — so a quoted stdout lookalike without a real stderr
  marker never latches, and a real marker is never missed on stdout.

## SPEC — [provider-exhaustion] marker

- **Exact bytes:** `[provider-exhaustion] hop=<hop> model=<leg> reason=<reason> provider=<provider> nonce=<n>\n`
  — single line, `\n`-terminated (writeSync; never bare at EOF by design, though the parent preserves an
  unterminated tail under this prefix).
- **fd / channel:** stderr ONLY (`fs.writeSync(2, …)` after `console.error` session_end or standalone as
  the last statement of the session_shutdown handler — must be the LAST stderr write of the process).
- **Placement:** emitted from the same `session_shutdown` hook as `session_end` (fires in dispose, both
  success and error paths, before process exit); latch the exhaustion EARLIER in-session via
  `message_end` stopReason==="error" + exhaustion-text classification (s2 — `after_provider_response`
  is NOT reliable on 402 for the SDK transport). Marker order vs `session_end` is irrelevant to the
  parent (markers are filtered); what matters is that NO real-stderr bytes follow it.
- **Nonce:** REQUIRED once the parent authenticates the kind — `nonce=<TASK_HEARTBEAT_NONCE>` (12-hex);
  mirrors the heartbeat gate so forged fd-2 lines cannot latch.
- **Escaping rules:** single `\s`-delimited ASCII tokens; no spaces/quotes/control bytes in values; no
  ANSI; charset `[A-Za-z0-9_.:/\->+=-]` (arrows legal, keep each field token-internal); total < 4096 B;
  never contain the literal `[task-heartbeat]` substring.

## Implications
1. Prefix choice is load-bearing: `[provider-exhaustion]` can never be mis-parsed/discarded by the current
   heartbeat pipeline — but it is REAL stderr today, so it will surface in kill/error content and
   `details.stderr` (fine — that is the latch surface) and flips `hasOutput` (already true on failure).
2. The parent change in #476 is additive: teach the latch detector to line-anchor `^\[provider-exhaustion\]`
   in the stderr channel + verify nonce; no existing parser state is touched.
3. Nonce-mandatory once recognized — ship the child emit gated on `TASK_HEARTBEAT_NONCE` presence.
4. Use `fs.writeSync(2)` (not `console.error`) for this marker to make "final line" deterministic under
   every exit path.
5. Detector must read `details.stderr`/stderr sections, never `content` stdout — closes the quoted-402
   false-positive class.
