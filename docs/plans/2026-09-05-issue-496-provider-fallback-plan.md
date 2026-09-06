---
title: "#496 — subagent-tool #152-class provider-failure fallback"
type: engineering
domain: platform
doc_status: draft
subjects.team: epistemic-team
aboutSubjects: [agent-infra, epistemic-team]
aboutObjects: [issue-496, issue-476, issue-152]
created: 2026-09-05
---

# #496 — subagent tool: per-dispatch provider-failure fallback

## Scope (from issue body, confirmed against code)

Give `extensions/subagent/index.ts` (`runSingleAgent`, used by single/parallel/chain
modes) the same #152-class provider-failure recovery the builtin task tool has, so a
mid-run provider failure (connection error; 402/exhaustion per #476; generic provider
5xx/rate-limit) does not kill single/parallel/chain batches. Constraints:

- Preserve #208 settle-exactly-once + abort-signal guarantees (per-dispatch settle code
  untouched — fallback re-dispatches at a HIGHER level, one fresh settle per attempt).
- Preserve per-dispatch result-cache semantics (#137 F6): each attempt caches under its
  OWN timestamped digest dir; the returned result carries its own attempt's `cachePath`.
- Max ONE fallback dispatch per original dispatch (never fallback-loop; structural).
- Failures WITHOUT a provider signature (agent-task errors, unknown-agent, our own
  timeout/abort kills, marker-less cuts) must NEVER trigger a fallback — a fallback
  would mask real agent bugs or duplicate expensive work.
- Attempt-0 spawn behavior and child env BYTE-IDENTICAL to today.
- Pre-existing debt, unrelated to the staged guard files (#437/#476 worktrees untouched).

## Why today's code is deficient (verified in source)

`runSingleAgent` performs exactly ONE spawn per dispatch (single settle state machine,
#208). All three modes already surface per-dispatch failures explicitly (`isFailedResult`
per task; chain stops at the failed step with `isError`), so a THROW never silently kills a
batch — but a **provider failure produces a FAILED result with no recovery**: in parallel
mode a provider storm fails every task in the batch (whole-batch loss = all results failed,
no re-dispatch); in chain mode the first provider-dead step terminates the remaining
chain. The builtin task tool (#152) recovers by re-dispatching once on a fallback model
when a connection-error signature is detected (qwen-only gate). #496 generalizes: classify
ANY provider-failure class and re-dispatch ONCE on a fallback model, per dispatch.

## Design

### 1. Pure classification — `classifyProviderFailure(result)` (exported, unit-tested)

Input: the completed `SingleResult` of an attempt. Returns
`"none" | "connection" | "exhaustion" | "provider"`.

Gating (all must hold or → `"none"`):

1. `isFailedResult(result)` — success never classifies.
2. `stopReason` NOT in `{"timeout", "aborted"}` — those are OUR kills (per-task cap /
   user abort), not provider deaths; re-dispatch would be wrong (worker may have been
   productive; abort must be honored).
3. **TWO-PASS SCAN over each scanned field** (`errorMessage`, stderr-TAIL, and output when
   scanned):
   - **TEXT PRE-CLEAN** (both passes) — `stripLocalLines` drops WHOLE lines that
     reference loopback/unix targets UNLESS the line reads as a provider transport
     with a local proxy HOP: a scheme-fronted loopback authority
     (`http://localhost:8000/api` — the /api is the LOCAL url's own path) is always
     local; otherwise the line survives only when a strong transport token
     (`https?|api|provider|upstream`) PRECEDES the loopback reference (a
     "via/through <loopback>" hop reads after the provider host — "402 from
     https://api.deepseek.com via localhost:8080"). Round-3: the round-2
     any-token-on-line refinement re-admitted pure-local lines whose local URL
     carried /api tokens — now closed.
   - **PHRASE scan on STRIPPED text** — first remove stack-frame tails
     (`[\w$@./:-]+:\d+(?::\d+)?` — `index.ts:402:11`, `loader:507:10`,
     `lib/api/request.js:402:11`, `src/provider.ts:507:10`), then match the text phrases
     below.
   - **NUMERIC scan on the cleaned (unstripped) text** — numerics are left-delimited
     `(?<![\w$@./:-])(402|429|5\d\d)(?![a-zA-Z])` (a glued `:402` in a frame path is
     excluded by the left guard; a glued unit `512ms`/`500MB` by the right guard) plus
     a post-filter (`unitSuffixFollows`) excluding measurement/duration contexts
     (`500 ms`, `402.5 ms`, `500 msec`, `402 seconds`, `500 SEC` — code-review rounds
     found the space-delimited, decimal, spelled and uppercase forms slipped the
     original `(?![a-z])` guard) AND
     adjacent (≤25 chars, either direction) to a transport/API token
     (`http|status|response|request|api|provider|upstream|message`). This keeps genuine
     port-bearing/gateway shapes (`402 from api.deepseek.com:443`, `error 402 from
     https://api.deepseek.com:443`, `504 from https://proxy:8443` — transport word
     survives in the cleaned text even though the strip would delete the glued host)
     while no stack frame or measurement shape can match.
   Then the always-scanned fields are `errorMessage` (FULL) + the **stderr TAIL —
   last ~8KB** (`stderr.slice(-(8192+128))`; the 128B overlap ensures a signature
   straddling the window edge is never split) for EVERY stopReason, including a
   "cut" whose in-band `errorMessage` still carries the provider signature from a
   `message_end` error event before signal-death. The stderr window bounds the
   classifier to the terminal death context: a RECOVERED early provider blip (pi
   retries internally) or MCP/local-tool noise farther than 8KB from the end can
   no longer latch a later non-provider death (code-review rounds: full-buffer
   scanning let an early blip latch a bug crash). The composed result output is
   additionally scanned ONLY when `exitCode !== 0 || stopReason === "error"` —
   and the channel is the agent's final TRANSCRIPT text
   (`getFinalOutput(result.messages)`) ONLY: never the errorMessage/stderr
   fallbacks of `getResultOutput`, which are already scanned above (round-3
   finding: routing full stderr through the transcript channel silently bypassed
   the 8KB window). Transcript prose is agent/LLM content, not provider evidence:
   a phrase match needs a strong transport token
   (`OUTPUT_PHRASE_ANCHOR = https?|api|provider|upstream` — status/response are
   deliberately excluded prose words) CO-LOCATED within ±40 chars
   (`PHRASE_COLOCATION_WINDOW`), so bare or remote-topic "terminated"/"no
   credits"/"rate limit" prose never re-runs the task (round-3: co-location
   replaced the round-2 anywhere-in-field anchor test, which still latched
   transport-adjacent topic prose). Numeric matches on the transcript channel
   likewise require the STRONG anchor inside the ≤25-char window (the loose
   request/message tokens never qualify on prose — round-3 closure). A clean exit
   whose output merely MENTIONS a phrase is not a provider failure.
   `stopReason === "cut"` classifies
   via the always-scanned `errorMessage`/stderr-TAIL fields ONLY (a cut's exitCode stays 0
   — its output content is NOT scanned; a marker-less cut = no signature in either field =
   bug-crash/backstop/OOM — the #476 "bug-crash must not latch" analog; a cut that
   carries an in-band error signature DOES classify — genuine provider-death-then-signal
   recovery must not be silently missed).

Signature patterns — a stack-frame strip (§1 gate 3) runs on every scanned field first;
with frames removed, numeric tokens are further ANCHORED to transport/API context so
realistic non-provider stderr shapes (JS stack frames, node-internal frames, ENOSPC
`Disk quota exceeded`, an error-object dump `{ code: 429 }` without transport context)
cannot match. Text phrases are loose. Case-insensitive; ordered for reporting priority:

| class | patterns |
|---|---|
| `exhaustion` | phrases: `insufficient balance`, `credit balance too low`, `out of credits`, `insufficient credits`, `no credits`, `payment required`; numeric `402`: ≤25-char transport adjacency either direction (token list below) — ALL numerics carry the §1 gate-3 guards `(?<![\w$@./:-])`…`(?![a-zA-Z])` + a post-filter excluding measurement suffixes (`unitSuffixFollows`: optional space/decimal + a unit token `ms|us|ns|mb|kb|gb|b|s|m|h|msec|sec|bytes?|milliseconds?|seconds?|minutes?|hours?`, case-insensitive — `512ms`, `500 ms`, `402.5 ms`, `500 SEC`, `500 MB` all stay out) (the table shows the adjacency shape only; never match a bare numeric without the guards) |
| `connection` | `connection error`, `connection lost`, `other side closed`, `stream ended`, `terminated`, `econnreset`, `econnrefused`, `enotfound`, `etimedout`, `epipe`, `socket hang up`, `network error`, `connect timed out`, `fetch failed` — the added mid-stream/socket family (`connection lost`, `other side closed`, `stream ended`, `fetch failed`) aligns with pi's OWN runtime retry vocabulary (pi-ai `RETRYABLE_PROVIDER_ERROR_PATTERN`): a run that DIED after pi exhausted its internal provider retries carrying these terminal texts is high-signal provider death (code-review round: empirically-verified misses on the mid-stream socket family) |
| `provider` | phrases: `rate limit`, `too many requests`, `upstream error`, `provider error`, `internal server error`, `bad gateway`, `service unavailable`; numerics `429`/`5\d\d`: same transport-adjacency + §1 guards |

Unit negatives MUST include realistic non-provider stderr (none of these can match
under the two-pass scan): a JS stack frame (`at run (/repo/extensions/index.ts:402:11)`),
a node-internal frame (`node:internal/modules/cjs/loader:507:10`), TOKEN-BEARING module
frames (`.../node_modules/undici/lib/api/request.js:402:11`, `.../src/provider.ts:507:10`,
`at getProvider (src/provider.ts:402:11)` — glued `:402` fails the numeric left guard),
`Disk quota exceeded` (ENOSPC), an error-object dump containing `code: 429` with no
transport token, duration/measurement shapes (`api responded in 512ms`,
`{"message":"done","elapsed":"500ms"}`, `upstream ok in 500ms`, AND the
space-delimited/decimal/spelled/uppercase forms `api responded in 500 ms`,
`request took 402 ms to complete`, `upstream latency 402.5 ms`, `500 msec`,
`402 seconds`, `500 SEC`, `500 MB`, throughput/binary `500 Kbps`, `500 MiB`
— code-review rounds), loopback-only local
dependency failures (`Error: connect ECONNREFUSED 127.0.0.1:5432`, docker daemon
`unix://` line, `http://localhost:8000/api` scheme-fronted URLs, token-after-hop
lines), composed-output prose without/remote from a transport anchor ("The
background process was terminated by the supervisor.", a budget/status note about
no credits), and a stale early blip >8KB before a non-provider terminal error —
including one whose terminal frame carries transport-ish tokens
(`at getProvider (src/provider.ts:402:11)` — the transcript channel is
TRANSCRIPT-only, so the full-stderr fallback can never bypass the window) — each
asserting `"none"`.

### 2. Decision — `shouldFallbackDispatch(...)` (exported, unit-tested)

All must hold: `classifyProviderFailure(...) !== "none"`, fallback enabled
(`SUBAGENT_FALLBACK_DISABLE !== "1"`), caller signal not aborted, this is NOT already
a fallback attempt (orchestrator guarantees by structure — max 1), and — NEW for the
`exhaustion` class specifically — the fallback is not a PROVABLY-DOOMED same-account
duplicate (`exhaustionFallbackDoomed`): 402 is account-scoped (#476), so re-running the
full task on the same exhausted account cannot recover yet re-executes side effects at
~2× cost (the exact harm #497 documents). Doomed when (a) attempt 0 rode pi's default
model (no `agent.model`) AND the fallback env is UNSET (both resolve to the same default
family — the common default-config case), or (b) both model families are KNOWN-equal
(`modelProviderFamily`: provider for `provider/model` ids, known family for bare
`deepseek`/`qwen`/`kimi`/`glm` ids, null for unknown bare ids — a provably-cross-account
exhaustion fallback, e.g. default dispatch + explicit `qwen/...` fallback or a qwen/kimi
primary (#284 second-model gate) + default deepseek fallback, STILL fires). The
orchestrator logs an honest-failure line to stderr when the exhaustion skip applies. The
connection/provider classes IGNORE this gate (a transient blip can clear between
attempts — only account-scoped 402 is doomed). Mirrors builtin `shouldFallback` shape
(env kill-switch + max-1-fallback + signature gate) minus the qwen-only provider gate
(generalized per issue).

### 3. Fallback model — `getSubagentFallbackModel()` (exported, unit-tested)

`SUBAGENT_FALLBACK_MODEL` env (default `deepseek-v4-pro`, mirroring builtin
`TASK_FALLBACK_MODEL`). NO `--provider` flag on either attempt: primary dispatches pass
none today and the child resolves provider from model config; passing a bare model keeps
child-side resolution identical to today and leaves #476's latch-aware resolution (which
will slot in here) authoritative. The default-config same-provider residual is now
HANDLED at the decision gate (§2): a default-config 402 no longer pays a doomed
duplicate run — recovery value requires `SUBAGENT_FALLBACK_MODEL` to point at a
provider-diverse model, or #476's latch-aware alias-chain (the actual exhaustion fix).
NOTE: the operator's env choice is trusted with one codified exception — an EXPLICIT
same-family fallback IS suppressed when attempt 0's model is pinned/known-equal
(families provably equal), and is allowed only when attempt 0 reported no model at
all (account not provable). The gate's attempt-0 input is the child's RESOLVED model
(`result.model ?? agent.model` — filled from the attempt-0 `message_end`), so a
model-less dispatch under a qwen-default session still resolves qwen → a default
deepseek fallback is cross-account and fires (round-3). Family inference is name-based
(`modelProviderFamily`); operator aliases that dodge the prefixes resolve null → not
provably same → the fallback fires (bounded by max-1; #476's latch-aware alias-chain
resolution owns the exact-account case).

### 4. Orchestration — `runSingleAgent` (public signature UNCHANGED)

Refactor: the existing single-spawn body becomes an internal per-attempt closure
`runAttempt(isFallback)` invoked by a thin orchestrator:

```
agent lookup + unknown-agent early return        (unchanged — never falls back)
fallbackModel = getSubagentFallbackModel();      (resolved once)
fallbackModelExplicit = SUBAGENT_FALLBACK_MODEL set non-empty
result = await runAttempt(false)                 (attempt 0 — args/env byte-identical to today)
willFallback = shouldFallbackDispatch({ classify(result), fallbackDisabled,
                                        signalAborted, attempt0Model: agent.model,
                                        fallbackModel, fallbackModelExplicit })
if !willFallback && class == exhaustion && !disabled && !aborted:
    log to stderr: "[subagent] provider failure (exhaustion) not re-dispatched: ..."
    (honest-failure visibility — default-config 402 is account-scoped; §2)
if willFallback:
    log to stderr: "[subagent] provider fallback: <from> → <to> (<class>)"
    result = await runAttempt(true)              (attempt 1)
return result                                    (attempt 1's result, annotated, wins)
```

**Per-attempt ownership (attempt closure creates ALL of these fresh — never shared with
a prior attempt):** `currentResult`, `cacheDir` (`getCacheDir(agentName, task)` re-computed
inside — timestamp differs → distinct digest dir per attempt), `emitUpdate`, `args`,
`wasAborted`, `timedOut`, settle state (`settled`/`swept`/timers), tmp-prompt lifecycle.
The #208 source-drift pins survive the relocation verbatim (`includes()` is
indentation-tolerant; the `resolveStopReason(` count stays ≥ 4 — do NOT dedupe the
close/exit-settle/backstop call sites).

**Attempt-0 vs attempt-1 differences (and ONLY these):**

1. **Model slot:** args are built fresh per attempt from
   `effectiveModel = isFallback ? fallbackModel : agent.model`. When `effectiveModel` is
   set the args gain exactly ONE `--model <effectiveModel>` pair in the SAME position
   attempt-0 uses today (before `--append-system-prompt`/`Task:` positionals — never
   append after the Task positional: pi's parser skips a value-less trailing `--model`
   and duplicate-pair placement must not be relied on). `currentResult.model` is
   initialized to `effectiveModel` (attempt-1's result truthfully reports the fallback
   model — `processLine` only fills `msg.model` when the field is falsy).
2. **Child env marker (per-level):** `SUBAGENT_ATTEMPT=1` is set on the fallback child
   ONLY, and attempt-0's childEnv EXPLICITLY `delete childEnv.SUBAGENT_ATTEMPT` (mirrors
   the existing `ELDATO_SKIP_VGATE` key-specific strip) — when the dispatch parent is
   itself a fallback child (nested subagent hierarchies) the grandchild's attempt-0 would
   otherwise inherit `SUBAGENT_ATTEMPT=1` from the parent env spread and be
   indistinguishable from a fallback attempt. Deleting restores byte-identical-to-today
   semantics at EVERY nesting depth and keeps the marker per-level meaningful (and the
   hermetic stub contract deterministic). Documented: the var is observability-only
   (children can distinguish primary vs fallback dispatches; it is the hermetic test
   seam) — never read by enforcers/gates.
3. **Annotation (fallback attempt only):** `runAttempt` receives `isFallback` +
   `fallbackModel`; WHEN `isFallback` it sets `currentResult.fallbackFrom =
   agent.model ?? "(default)"` and `currentResult.fallbackTo = fallbackModel` BEFORE
   `cacheResult`, so the on-disk `result.json` and the live result carry identical fields
   (orchestrator reads the cache after abort — it must see the annotation). Attempt-0's
   cache + live result carry NO fallback fields. New optional `SingleResult` fields
   `fallbackFrom?: string`, `fallbackTo?: string` (JSON-open details — safe).

**Between attempts:** the orchestrator re-checks `signal?.aborted` before spawning
attempt 1 (defense-in-depth — the window is synchronous so a real abort cannot land
there on the event loop; the reachable abort points are DURING attempt 0 → stopReason
`aborted` → classify `"none"` → no fallback, and DURING attempt 1 → settles per
#137/#208, its result returned, no attempt 2). Timeout/abort results likewise classify
`"none"` (timeout-integration + abort-resilience suites unaffected).

**Signal-listener hygiene (bounds fallback amplification of a pre-existing leak):** each
attempt adds `signal.addEventListener("abort", killProc, { once: true })` which today is
only removed on fire. `doResolve` now also removes the listener (a per-attempt
`signalListener` holder assigned in the signal block, removed at settle) — a
16-task × 2-attempt storm no longer leaks 32 listener+closure trees for the session.

### 5. Streaming / updates

Attempts stream via the existing `onUpdate`/`emitUpdate` path (each attempt owns its
`currentResult`; per-task parallel update wrapper keeps writing `allResults[index]`).
A failed attempt 0 followed by attempt 1 naturally overwrites the streamed slot with the
final result. No mode-level (single/parallel/chain) code changes needed — recovery is
invisible to them (each `runSingleAgent` call just returns a recovered result).

### 6. Env surface (documented in code + tests)

| var | default | meaning |
|---|---|---|
| `SUBAGENT_FALLBACK_MODEL` | `deepseek-v4-pro` | model id for the single fallback dispatch |
| `SUBAGENT_FALLBACK_DISABLE` | unset | `"1"` turns fallback OFF (kill-switch) |
| `SUBAGENT_ATTEMPT` | unset on primary | `"1"` on the fallback child only (observability + test seam) |

## Hermetic stub contract (provider-fallback.test.ts)

- Plain `.cjs` written to `os.tmpdir()` (fixed absolute path per run, no TS imports; the
  stub is spawned as `node <stub> <args…>` via `getPiInvocation` — set
  `process.argv[1]` to the stub path so the existing `existsSync` branch fires; restore
  in `finally`).
- The stub APPENDS one line `{pid, attempt, task}` per spawn to an OUT-OF-BAND log file
  (path via env `SUBAGENT_STUB_LOG`, flushed before exit). Spawn accounting NEVER uses
  stdout/stderr (stdout is consumed by `processLine`, stderr is scanned by the
  classifier).
- Behavior selection is deterministic from child env + argv. ALL stdout JSON events are
  written with `fs.writeSync(1, …)` (never async `process.stdout.write` followed by
  `process.exit` — an unflushed pipe write would silently truncate the in-band event);
  the stub sets `process.exitCode` and exits naturally:
  - `SUBAGENT_ATTEMPT=1` → succeed (unless the selected mode says otherwise): emit one
    `message_end` JSON event
    (`{"type":"message_end","message":{role:"assistant",content:[{type:"text",text:"recovered"}],stopReason:"end",model:"stub-model",...}}`),
    then exit 0.
  - `SUBAGENT_ATTEMPT` unset (attempt 0) → fail provider-style: emit a `message_end`
    event with `stopReason:"error"` + `errorMessage:"Insufficient Balance (402)"`
    (exercises the in-band classification path), write `connection error`/`402` text to
    stderr, exit 1. Variants selectable via a second env (`SUBAGENT_STUB_MODE`, default
    `exhaustion`):
    - `connection` — stderr `Connection error.` + exit 1, no in-band event (stderr-only
      signature path).
    - `nonprovider` — stderr `TypeError: x is not a function`, exit 1 (NO provider
      signature — the bug-crash must-NOT-latch negative).
    - `always-success` — attempt 0 AND attempt 1 both succeed (success-path regression).
    - `always-fail` — attempt 0 fails provider-style AND attempt 1 (`SUBAGENT_ATTEMPT=1`)
      ALSO fails provider-style (double-failure rows 4 & 6 — the fallback fires then
      explicitly fails; no attempt 2).
    - `hold-attempt-1` (row 9) — attempt 0 fails provider-style; attempt 1
      (`SUBAGENT_ATTEMPT=1`) appends its spawn-log line FIRST, then sleeps indefinitely
      (holding stdout open — never exits on its own). The test aborts AFTER observing the
      attempt-1 spawn-log line (written before the sleep → deterministic), so the abort
      lands mid-settle → attempt 1 is killed → settles `stopReason "aborted"`.
- Chain row needs attempt-specific behavior per STEP: stub keys off the `Task: <text>`
    positional in argv — task text containing `fail-step1` → attempt 0 fails, attempt 1
    (SUBAGENT_ATTEMPT=1) succeeds; `ok-step2` → succeeds on attempt 0.

## Test matrix

| file | layer | covers |
|---|---|---|
| `extensions/subagent/index.test.ts` (extend) | unit | `classifyProviderFailure` (per class + positives: exit-0 + stopReason "error" in-band, cut with stderr signature → classifies per §1 always-scan, cut carrying an in-band `errorMessage` provider signature → classifies (genuine provider-death-then-signal), port-bearing transport positives `402 from api.deepseek.com:443`, `error 402 from https://api.deepseek.com:443`, `504 from https://proxy:8443`; negatives: success, agent-error text, unknown-agent, exit-0 output mentions, timeout, aborted, marker-less cut, realistic non-provider stderr: JS stack frame `index.ts:402:11`, node-internal frame `loader:507:10`, token-bearing module frames `lib/api/request.js:402:11` + `src/provider.ts:507:10` + `at getProvider (src/provider.ts:402:11)`, `Disk quota exceeded` (ENOSPC), error-object dump `code: 429` without transport token, duration/measurement text `api responded in 512ms` + `{"message":"done","elapsed":"500ms"}` + `upstream ok in 500ms`), `shouldFallbackDispatch` decision matrix (disable env, signal aborted, class none), `getSubagentFallbackModel` env resolution (default/override/blank), source-drift pins for orchestrator wiring |
| `extensions/subagent/provider-fallback.test.ts` (NEW) | hermetic E2E (stub contract above) | 1. single-mode recovery: attempt 0 exhaustion-fail → attempt 1 success; assert success, `fallbackTo` set, `fallbackFrom`, `result.model === fallbackModel`, spawn log = 2 lines, TWO distinct cache dirs exist and returned `cachePath` = attempt-1's dir. 2. success-path regression: always-success stub → 1 spawn, NO `fallbackFrom`/`fallbackTo`. 3. non-provider failure negative: `nonprovider` mode → 1 spawn, no annotation (bug-crash must NOT latch, E2E). 4. single-mode double-failure (`always-fail` mode): stub fails both attempts → explicit failure + `fallbackFrom`/`fallbackTo` set, spawn log = 2, no attempt 2. 5. parallel-mode recovery (headline): N tasks, all fail attempt 0 / succeed attempt 1 → `successCount == N`, spawn log = 2N, each recovered result carries `fallbackTo`. 6. parallel always-fail (`always-fail` mode): N tasks fail both attempts → batch completes with N explicit per-dispatch failures, spawn log = 2N (recovery attempted per dispatch; no silent whole-batch loss). 7. chain continuation: step 1 recovers (fail→succeed), step 2 succeeds → chain completes 2/2 steps, spawn log = 3. 8. disable-env: `SUBAGENT_FALLBACK_DISABLE=1` + exhaustion mode → 1 spawn, no recovery. 9. abort during attempt 1 (`hold-attempt-1` mode): attempt 0 fails; attempt-1 stub appends its spawn-log line then sleeps; abort fired after the poller observes the attempt-1 line → attempt-1 killed → settles `stopReason "aborted"`, spawn count = 2, no attempt 2 (deterministic — abort lands during the attempt's settle, not the synchronous orchestrator window; attempt-1 log-before-sleep ordering closes the race). 10. connection-mode variant of row 1 (stderr-only signature path). 11. exhaustion + UNSET fallback env (same-account default): the §2 gate skips the doomed duplicate — 1 spawn, no annotation, honest explicit failure. Suite also clears the abort-test's losing 15s race guard timer so the suite exits immediately on the success path (code-review round: the un-cleared timer idled the suite ~15s/run). |

No CI wiring in this issue: extensions/builtin-tools + subagent suites require the pi
runtime packages + real `pi` binary, which the GitHub runner lacks (#498 tracks
extension-farm CI wiring). New + existing suites run locally via the repo recipe.

## Files touched

- `extensions/subagent/index.ts` — classification + decision + getters (pure, exported),
  `runSingleAgent` orchestrator refactor (per-attempt closure w/ model slot +
  `SUBAGENT_ATTEMPT` per-level marker + annotation-before-cache + abort-listener
  cleanup), `SingleResult` annotation fields.
- `extensions/subagent/index.test.ts` — extend with unit sections.
- `extensions/subagent/provider-fallback.test.ts` — NEW hermetic E2E (stub contract above).
- `extensions/subagent/timeout-integration.test.ts`, `extensions/subagent/abort-resilience.test.ts`,
  `extensions/subagent/cache-integration.test.ts` — set `SUBAGENT_FALLBACK_DISABLE=1` at
  the top of each real-pi suite so they deterministically exercise the non-fallback path
  (see Verification).
- `docs/plans/2026-09-05-issue-496-provider-fallback-plan.md` — this plan.

## Verification

- Baseline suites green before/after (index/abort-resilience/cache/timeout + new file),
  run with `SUBAGENT_TASK_TIMEOUT_MS` unset.
- Settle-exactly-once source-drift pins (#208) still pass (attempt extraction preserves
  the settle code text verbatim).
- Real-pi integration suites re-run to prove no regression on the actual spawn path.
  **They run with `SUBAGENT_FALLBACK_DISABLE=1`** (each suite sets it in its env): the
  timeout-integration external-SIGKILL cut test runs with `SUBAGENT_TASK_TIMEOUT_MS=0`
  (backstop = fixed 6h30m) — a real pi child's ambient stderr before the SIGKILL could
  carry a signature token (provider 429 logged during retry, a local MCP `connection
  error`) and trigger a fallback attempt that would hang the suite for hours. The
  disable env keeps the real-pi suites deterministically on the non-fallback path; the
  fallback path is covered by the hermetic stub suite instead.
- **Code-review convergence (PR #505, 4 parallel reviewers → 0 P0/P1):** every P2
  finding was triaged, empirically verified, and fixed in this revision — classifier
  false-positives (space-delimited/decimal duration numerics, loopback-local dependency
  lines, composed-output prose without a transport anchor, stale early blips via the
  stderr terminal window) and false-negatives (pi retry.js mid-stream socket vocabulary:
  `connection lost` / `other side closed` / `stream ended` / `fetch failed`) were both
  closed with regression rows; the default-config exhaustion 402 no longer pays a doomed
  same-account duplicate run (§2 gate + honest-failure log); the hermetic abort test's
  leaked 15s guard timer is cleared (suite wall 20.8s → 9.7s). **Rounds 2-3 re-review**
  (fresh reviewers on the fix commit) found and closed: the composed-output channel
  silently re-scanning FULL stderr via `getResultOutput`'s fallback (bypassing the 8KB
  window) — the channel is now transcript-only; phrase anchoring tightened from
  anywhere-in-field to ±40-char co-location with a strong token set that excludes
  status/response; spelled/uppercase duration units (`msec`, `seconds`, `MB`, `SEC`);
  loopback-line drops now spare proxy-fronted provider lines; the exhaustion gate reads
  the child's RESOLVED model (`result.model ?? agent.model`) so model-less qwen-default
  sessions still get cross-account 402 recovery; the stderr window gets a 128B overlap.
  **Round-3 closures:** scheme-fronted local URLs (`http://localhost:8000/api` — the
  local path's own tokens) are dropped again (strong token must PRECEDE the loopback
  hop); UNIT_RE covers compound/binary forms (`Kbps`, `MiB`); transcript numerics
  require the STRONG anchor inside the 25-char window (loose `request`/`message` prose
  never re-runs); `msg.model` fill is typeof-string guarded (unvalidated child JSON can
  never crash the family resolver).
  Final suite counts: index.test.ts 107/107, provider-fallback.test.ts 13/13, real-pi
  suites green.
