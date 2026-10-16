# Plan — #1505 + #1500: restore the `tool_updates` evidence gate and bound the child's bash call

**Issue:** #1505 (+ #1500) · **Branch:** `fix/1505-tool-updates-evidence-gate`
**Scope:** cycle-2 SCOPE comment on #1505 (`[ADVERSARIAL-BOUND] cycles=2 threats=5 covered=5`)
**Complexity:** standard (adversarial verification mode declared, bounded at 2 cycles)

> **Revision 3.** Cycle 1 found 8 issues (1 P0, 3 P1, 4 P2) → §Disposition-A. Cycle 2 found 9 (3 P1, 6 P2), two of which **falsify claims in Revision 2** → §Disposition-B. Where the two cycles agree, the finding is treated as high-confidence.

## Disposition-A — plan-review cycle 1

| # | Finding | Disposition |
|---|---|---|
| P-1 (P0) | Test 5 imports `createBashTool` at runtime; the pi package is not a dep of `extensions/builtin-tools` → CI-red, locally green | **Superseded by Q-2** — a pi-bearing home exists; the claim "not testable" was false |
| P-2 (P1) | Child-registration parity: adding `pi.on("tool_call")` makes `heartbeat-progress-edges.test.ts` red | **Accepted, verified** → `PREVENTION_EVENTS = ["tool_call"]` |
| P-3 (P1) | `builtin-tools.test.ts` asserts `DISABLE=1 → 0 handlers`, which D5 breaks | **Accepted, verified** → expectation becomes `["tool_call"]` |
| P-4 (P2) | `computeToolUpdates` assertion not constructible; only the tick observes it | **Accepted** → tick-observation pattern, **corrected by Q-4** to two observations |
| P-5 (P2) | (a) whitespace-only output never arms the latch; (b) no latch scope for the warning | **Accepted** → (a) residual R-B2; (b) pure predicate + call-site closure latch |
| P-6 (P2) | New bound not registered in the #1068 stall vocabulary | **Accepted, refined by Q-1** → **both** names need `OUT_OF_FAMILY_TERMS` |
| P-7 (P2) | 3600 s is right-censored; the 80-min grep is an instance Leg B would destroy | **Accepted, corrected by Q-6** → the *completed-call* tail is **not** censored; default becomes **7200 s** |
| P-8 (P2) | Comments describing the false invariant are uncorrected | **Accepted, corrected by Q-7** → the site set was incomplete and one site mislabelled |
| P-9 (P2) | The `partialResult: "out"` fixture goes vacuous under D2 | **Accepted, verified** → renderable payload |
| P-10 (P1) | "must land together" over-stated | **Accepted** → Leg A alone fixes the report; Leg B alone is harmful |

## Disposition-B — plan-review cycle 2

| # | Finding | Disposition |
|---|---|---|
| Q-1 (P1) | `DEFAULT_TOOL_TIMEOUT_S` is **not** in-family (no family token; `_S` is not a bound suffix) → the registry test `ok(inFam \|\| exempt.has(name))` fails unless the name **itself** is exempt. Adding only the getter is insufficient | **Accepted, verified** (test at `heartbeat-progress-edges.test.ts:663-674`; `inFamily` at `declared-surface.ts:388-397`) → **both** names go in `OUT_OF_FAMILY_TERMS`, each with a value pin |
| Q-2 (P1) | The "termination is not unit-testable" claim is **false**: `extensions/subagent` carries `@earendil-works/pi-coding-agent@0.85.1` as a devDependency and `ci-main.yml` runs its suites after `npm ci`; the reviewer reproduced `createBashTool(...).execute('tc',{command:'sleep 20 && echo done',timeout:2},…)` rejecting at ~2015 ms with `Command timed out after 2 seconds` | **Accepted, verified** → the termination test moves to a **pi-bearing hermetic suite** (beside `extensions/subagent/timeout-integration.test.ts`); the "PR evidence only" framing is deleted |
| Q-3 (P2) | D8/R1 claim step 3 keeps the parity suite green — arithmetically impossible: after step 3 the declaration contains `tool_call` while the registration does not, so the set-equality is red in the **other** direction. Steps 3+4 must be **atomic**. Also the `heartbeat-progress-edges.test.ts` "expectation" edit is unnecessary (the assertion is derived) | **Accepted, verified** → steps 3+4 merged into one atomic step; the derived-assertion edit dropped |
| Q-4 (P2) | Step 7 as written observes only the **final** state — one tick per ~5 s sleep, so the `0` half is never seen | **Accepted** → two observations, one per transition |
| Q-5 (P2) | The stated CI lanes are wrong: `node-ci.yml` is always invoked with `test-command` (which overrides `test-glob`); `builtin-tools.test.ts` is **`ci-main` only (post-merge)**; `heartbeat-progress-edges.test.ts` **is** per-PR; `task-heartbeat.orphan.test.ts` is in **no** workflow | **Accepted, verified** → Verification section states the true lane per suite, and the post-merge-only status of the adversarial coverage is **disclosed** (see Risks) |
| Q-6 (P1) | R2 self-contradicts: the *completed-call* distribution is **not** censored and is directly measured; 3600 s would kill 8 observed completions, 7 with **no** explicit timeout | **Accepted, verified by re-measurement** → default **7200 s**; R2 rewritten (below) |
| Q-7 (P1) | The comment set is incomplete and one site mislabelled: the root-cause statement **as fact** is `task-heartbeat.ts:347-349`; the genuinely-false **clause-1 legend** is `builtin-tools/index.ts:1492-1496`, not `:1501` (which is the clause-1b legend); `:221-227`, `:183`, and `docs/ops/load-policy.md:86` also carry the mechanism | **Accepted, verified** → step 10 extended and split into *false now* vs *made stale by Leg A* |
| Q-8 (P2) | The **pair's** after-fix end state was never stated, and "up to 60 min before the child gets a signal" is wrong for the CPU-flat case — clause 1b **kills the child** at `C` = 30 min, so no tool signal is delivered there | **Accepted** → stated precisely below |
| Q-9 (P2) | Leg B caps **every** dispatched child's bash (reviewers, verification-gate children, design-reviewer subagents), not just the measured class; and `dispatchMarkerActive()` would be the fourth copy of the pair, guarded by `print-mode-wiring.test.ts` ("no production `.ts` may read `process.env.PI_MODE` raw") | **Accepted, verified** → mirror `orphanWatchdogActive`'s **env-param seam** (a default parameter, which does not contain the raw string); name the affected populations; add the guard file to Files |
| Q-supp | A replacement `bash` tool via `registerTool` is possible but **worse** — see §Rejected alternatives | **Accepted** → recorded |

## Deliverable

One PR.

- **Leg A** — the child's `tool_updates` flag means what its comment says: *this tool has produced output*.
- **Leg B** — a dispatched child's `bash` call carries a default, configurable, disarmable `timeout`.

The parent watchdog's **clauses are not modified**. Clause 1 stays universal, clause 1b stays the strict complement, clause 2 stays the 4 h age backstop.

**Sequencing, stated honestly.** Leg A alone fixes the reported failure (a silent-but-working `grep` is no longer killed at 20 min; the #928 80-minute grep would run to completion); it only fails to bound a *genuinely* hung silent call. Leg B alone is **harmful**: the timeout is a wall-clock `setTimeout` → `killProcessTree` (`dist/core/tools/bash.js`) regardless of output, so it would cap every dispatched `bash` while leaving the 20-min false kill in place. Hence one PR.

**The pair's end state, stated precisely** (vs today — destroyed at 20 min):
- wedged silent `bash`, CPU evidence available → **destroyed by clause 1b (`tool-dead`) at `C` = 30 min** (no tool signal to the model);
- wedged silent `bash`, probe inert / unattributable → **recoverable `Command timed out after 7200 seconds` at the bound (7200 s)**, which the model can act on;
- silently-working `bash` → not killed; ends on its own, or at the bound as a recoverable error.

## Design decisions

**D1 — Evidence, not liveness.** `updatedToolIds.add` moves behind a renderable-output test; `touchActivity("tool_execution_update")` stays **unconditional**. Scope is *evidence of streaming*; liveness semantics are byte-identical to today. Conflating the two is the defect, so the fix must not re-conflate them the other way (dropping `touchActivity` would weaken `#279`'s `everSawRealActivity`).

**D2 — `hasRenderableOutput(partialResult)`.** True iff `partialResult.content` is an array containing a `{type:"text"}` entry whose `text` is a string with non-whitespace content. It must test the **text**, not array length: pi emits `content: [{type:"text", text: snapshot.content || ""}]` for real updates. Fails **closed** (`false`) on any unexpected shape.

**D3 — Default bound and polarity (#1500 c2/c3; T3a/T3b).**

| `TASK_TOOL_TIMEOUT_S` | Result |
|---|---|
| absent | `DEFAULT_TOOL_TIMEOUT_S = 7200` (bound **ON**) — T3a |
| `"120"` | 120 |
| `"0"`, negative, `Infinity`, `NaN`, `"abc"`, `""` | `null` → bound **OFF** + once-only warning — T3b |

Absent is *not* OFF (#1500 c2). Only c3 disarms, and only on a value the operator actually supplied.

**D3b — Warning shape.** `toolTimeoutDisarmWarning(raw)` is a **pure predicate** returning the message or `null` (precedent: `streamStallInertWarning`); a latch **inside the factory closure** makes it fire once per dispatch. No module-level latch (order-dependent across a test run).

**D4 — Never override an explicit timeout (#1500 c1; T2).** Fill only when `event.input.timeout` is `undefined`/`null`. Residual: an explicit value can evade the default; bounded by clause 2 (4 h) and the 6 h cap.

**D5 — Registration site (T4).** Register **above** `taskHeartbeatActive()`'s early return (`task-heartbeat.ts:863`), gated on a new `dispatchMarkerActive()` written **exactly like `orphanWatchdogActive`** — `(env: Record<string,string|undefined> = process.env)` — so the raw string `process.env.PI_MODE` never appears and `print-mode-wiring.test.ts` stays green. The predicate is `env.TASK_HEARTBEAT === "1" && env.PI_MODE === "print"` (the pair **both** dispatch paths set; `TASK_HEARTBEAT_DISABLE=1` must not defeat Leg B). Do **not** reuse `orphanWatchdogActive` — its `ORPHAN_WATCHDOG !== "0"` term is wrong here.

**D6 — `bash` only.** `timeout` exists for bash/powershell; bash is 270/271 of the measured class.

**D7 — Clause 1 stays universal (T5).** The existential form would re-create the E279a2 false kill the gate exists to prevent. Accepted residual: a masked (streamed) wedge is unreachable by clause 1 **and** clause 1b (the CPU probe is unattributable whenever `outstandingTools.size !== 1`), so it is bounded by **clause 2 at 4 h**, and at the bound by Leg B when the wedged tool is `bash`.

**D9 — Registry.** `DEFAULT_TOOL_TIMEOUT_S` in `STALL_TERM_REGISTRY` (kill axis, with a value pin) **and both** `DEFAULT_TOOL_TIMEOUT_S` and `getToolTimeoutSeconds` in `OUT_OF_FAMILY_TERMS`.

## Files

| File | Change |
|---|---|
| `extensions/task-heartbeat.ts` | `hasRenderableOutput`; `getToolTimeoutSeconds` + `DEFAULT_TOOL_TIMEOUT_S` + `toolTimeoutDisarmWarning`; `dispatchMarkerActive`; the `tool_call` handler above the early return; the gate in the `tool_execution_update` arm; **comments** at `:183`, `:221-227`, `:347-349` |
| `extensions/builtin-tools/index.ts` | **comment-only** — clause-1 legend `:1492-1496` (false today) and the clause-1b legend `:1500-1501` (`"never emitted an update"` → `"never emitted a *renderable* update"`) |
| `extensions/subagent/tool-timeout-bound.test.ts` | **new** — the hermetic termination test, in a suite that already resolves the pinned pi package (Q-2) |
| `extensions/shared/heartbeat-progress-edges.ts` | `PREVENTION_EVENTS = ["tool_call"]`; `childRegisteredEvents()` folds it in; registry + `OUT_OF_FAMILY_TERMS` entries |
| `extensions/builtin-tools/builtin-tools.test.ts` | new tests; the `DISABLE=1` expectation; the `:4744` fixture |
| `docs/ops/load-policy.md` | `:86` — the `TASK_CPU_STALL_MS` row: "never emitted an update" → "never emitted a *renderable* update" |
| `extensions/shared/print-mode-wiring.test.ts` | guard — **no change**, listed so the implementer knows the constraint D5 must satisfy |

## Task breakdown

0. **Baseline** — run the three affected suites before any code.
1. `hasRenderableOutput` — unit tests first: `[]`, `[{type:"text",text:""}]`, whitespace-only, real text, missing `content`, `content` not an array, `null`, bare string.
2. `getToolTimeoutSeconds` + `toolTimeoutDisarmWarning` — absent → 7200; `"120"` → 120; `"0"`/`"-1"`/`"abc"`/`""`/`"Infinity"`/`"1e400"` → `null`; the predicate returns a message per bad value and `null` per good one.
3. **ATOMIC (Q-3):** the `tool_call` registration in `task-heartbeat.ts` **and** `PREVENTION_EVENTS = ["tool_call"]` in the declaration **and** the `DISABLE=1` expectation in `builtin-tools.test.ts` (`["tool_call"]`) **and** the `:4744` fixture → renderable payload. *No intermediate state is green; the parity assertion cannot be satisfied one side at a time.*
4. Registry entries (D9), with the value pin matching the source exactly.
5. **Behavioural registration (T4).** Drive `childFactory(fakePi)` under `TASK_HEARTBEAT=1 / PI_MODE=print / TASK_HEARTBEAT_DISABLE=1` → `tool_call` **is** registered; with the marker pair absent → **not** registered. Env set before each factory call, restored after (the gate is read at registration time).
6. **Handler mutation (T2).** absent → injected; explicit preserved verbatim; non-`bash` untouched; the injected value is finite, `> 0`, `<= 2_147_483.647`.
7. **Evidence gate (T1), two observations (Q-4):** `session_start` → `tool_execution_start` → empty update → `sleep(5_300)` → read tick (**expect `tool_updates=0`**) → real update → `sleep(5_000)` → read tick (**expect `1`**) → `session_shutdown` (clears the timer).
8. **T5.** Two in-flight tools, one streamed-then-silent, one never-streamed: clause 1 does not fire; `tool-dead` does **not** fire (preconditions unreachable under concurrency); `tool-stall` owns it. Reuse `silentToolState` + `heartbeatKillDecision`.
9. **Termination (T1, real — Q-2).** In `extensions/subagent/`: call `createBashTool(cwd, { exposeSessionEnvironment: false })` and `execute(..., { command: "sleep 20 && echo done", timeout: <injected> }, ...)`; assert it rejects at the bound with `Command timed out after <n> seconds`. Also assert the handler-injected value flows into that call.
10. **Comments (Q-7).** *False now:* `task-heartbeat.ts:347-349` (the root cause stated as fact) and `builtin-tools/index.ts:1492-1496` (the clause-1 legend). *Made stale by Leg A:* `task-heartbeat.ts:183` and `:221-227`, `builtin-tools/index.ts:1500-1501`, `docs/ops/load-policy.md:86` — all "never emitted an update" → "never emitted a **renderable** update" where the wording is now wrong.
11. Green — run all affected suites.

## Integration surfaces

| Surface | Contract | Impact |
|---|---|---|
| child→parent marker wire format | `[task-heartbeat] tick … tool_updates=<0\|1>` | **unchanged** |
| parent marker parser arms | `toolUpdates = v === 1` | **unchanged** |
| child registered-handler parity | `childRegisteredEvents()` ≡ child `pi.on(...)` set | **changed** — `PREVENTION_EVENTS` |
| #228 print-mode wiring | no production `.ts` may read `process.env.PI_MODE` raw | **constraint on D5** — satisfied by the env-param seam |
| pi `tool_call` hook | `event.input` mutable in place, no re-validation | **depended on** |
| `DispatchOutcomeRow` | JSONL schema | **unchanged** |
| config | new env `TASK_TOOL_TIMEOUT_S` | additive; registered in the stall vocabulary |

**Blast radius of Leg B (Q-9):** the gate is "is a dispatched child", so the bound applies to **every** dispatched child's `bash` — including code-review / test-review reviewer children, verification-gate children, and design-reviewer subagent children, not only the class this issue measured. Named here deliberately; the population is intended (a hung bash is a hazard in all of them).

## Rejected alternatives

- **Claude Code's `BASH_DEFAULT_TIMEOUT_MS=120000` / `BASH_MAX_TIMEOUT_MS=600000`.** Verified verbatim: *"When a command reaches its timeout without finishing, Claude Code moves it to the background instead of stopping it."* Those numbers tune a **background handoff**; pi's timeout kills the process tree. A 10-min ceiling would make 2,050 measured calls unrunnable. Right for a mechanism we do not have.
- **A replacement `bash` tool via `registerTool`** (mechanically possible: `createBashToolDefinition`/`createLocalBashOperations` are exported and a built-in can be overridden by name). **Worse, not simpler:** it addresses only Leg B; to fix Leg A too it must also suppress the start `onUpdate({content:[]})` — a second behaviour change to a tool every child depends on; it needs a **runtime** SDK import inside the extension (the P-1/Q-2 failure class moved into production, where a load failure breaks the child); and it replaces truncation/renderers/`onUpdate` wholesale, so a drift bug breaks all bash in every child, whereas the `tool_call` hook is a one-field mutation that cannot drift.

## Verification — true lane per suite

| Suite | Lane |
|---|---|
| `extensions/shared/heartbeat-progress-edges.test.ts` (parity, registry) | **per-PR** — `ci.yml` verify job |
| `extensions/builtin-tools/builtin-tools.test.ts` (T1 gate, T2, T4, T5, T3a/b) | **post-merge** — `ci-main.yml` (`push`→main) ⚠️ see Risks |
| `extensions/subagent/tool-timeout-bound.test.ts` (termination) | `ci-main.yml`, after `(cd extensions/subagent && npm ci)` |
| `extensions/task-heartbeat.orphan.test.ts` | **in no workflow** — run locally; noted, not implied covered |

Adversarial coverage table (this domain's acceptance):

| Class | Test |
|---|---|
| T1 evidence suppression | 7 (gate) + 9 (termination — independent of the child's cooperation) |
| T2 explicit-timeout evasion | 6 |
| T3a absent → default ON | 2 |
| T3b unparseable → OFF + warn | 2 |
| T4 registration site | 5 |
| T5 concurrency masking | 8 |

## Accepted residuals (disclosed, not chased)

- **R-B1** A legitimate silent `bash` call exceeding **7200 s** is killed by Leg B. Observed max is 5417.8 s (90.3 min) over 658,543 calls, so the bound sits ~33 % above observed demand — but the **hang** population is by definition absent from a completed-call corpus, so this residual cannot be measured, only bounded.
- **R-B2** Output that is only whitespace never arms the latch, so clause 1 can still end such a command at `S`. Pathological.
- **R-B3** An explicit `timeout` can exceed the default (D4, by design); bounded by clause 2 and the 6 h cap.
- **R-B4** The masked-wedge residual (D7).

## Risks

- **R1** The child-registration parity suite is red in **every** intermediate state until step 3's atomic edit lands — expected, not a bug.
- **R2 (rewritten, Q-6)** The bound is derived from the **completed-call** tail, which is *not* censored: 658,543 bash calls, p99.9 = 1135.9 s, p99.99 = 2091.5 s, p99.999 = 3689.4 s, **max 5417.8 s (90.3 min)**; **8 calls exceed 3600 s and 7 of those passed no explicit timeout** — so #1500's asserted 60 min would destroy measured legitimate work. Default is **7200 s**, which exceeds every observed call (0 calls > 7200 s) while still tightening the probe-inert silent case from clause 2's 4 h to 2 h and returning a *recoverable* error. Operator-settable via `TASK_TOOL_TIMEOUT_S`; #1500 to be updated with this measurement.
- **R3** Shipping Leg B **OFF by default** is the fail-open class this plan exists to prevent → pinned by test 2 (T3a).
- **R4** `touchActivity` is deliberately unconditional; a future edit gating it would weaken `#279`. Noted at the edit site.
- **R5 (Q-5, disclosed)** The adversarial coverage for T1/T2/T3/T4/T5 lives in `builtin-tools.test.ts`, which runs **post-merge** (`ci-main`), not per-PR. The PR therefore rests on **locally executed** evidence for those classes plus per-PR green for the parity/registry gates. This is disclosed in the PR body under `[ADVERSARIAL-BOUND]`, not presented as per-PR-gated.

## Out of scope

`cut`-class false kills (#1339, 257 rows) · per-tool CPU attribution under concurrency · the background/handoff architecture · `search-guard` bypasses (#1486, #1100, #1099–1097) · wiring `builtin-tools.test.ts` into a per-PR lane (category-B machinery; noted, not filed).

---

# Revision 4 — cycle-3 corrections (BINDING; these supersede the sections named)

Plan-review cycle 3 (final) found 5 defects. All are mechanical; none is a design flaw. Applied without a cycle-4 re-review, because the standard tier's 3-cycle bound is spent — recorded as a bounded exit, not a clean one (see §Gate exit).

**C1 — registry: BOTH names need a `STALL_TERM_REGISTRY` entry** (supersedes D9, step 4). `OUT_OF_FAMILY_TERMS` requires every listed name to *also* be a registry entry (`heartbeat-progress-edges.test.ts:677-679`). So:
- register `DEFAULT_TOOL_TIMEOUT_S` **and** `getToolTimeoutSeconds` in `STALL_TERM_REGISTRY` (`axis: "kill"`, owners `["extensions/task-heartbeat.ts"]`; the getter with `value: null`, mirroring `getToolStallMs`);
- list **both** in `OUT_OF_FAMILY_TERMS`;
- `guardedBy: BT_TEST` **and** step 2 must reference the symbols by name — `equal(childHb.getToolTimeoutSeconds({}), childHb.DEFAULT_TOOL_TIMEOUT_S)` and `equal(childHb.DEFAULT_TOOL_TIMEOUT_S, 7200)` — because the registry's `guardedBy` check requires the cited test file to name the term (`:478-507`).
- **Correction to the Q-1 disposition row:** its parenthetical "`_S` is not a bound suffix" is **wrong** — `_S` *is* in `SCAN_BOUND_SUFFIXES`; the name is out-of-family solely because it carries no family **token** (`inFamily` = token AND shell-suffix).

**C2 — the termination test must be wired into CI** (supersedes step 9, adds a file). `ci-main.yml`'s subagent leg is a **hard-coded list**, not a glob (no glob reaches `extensions/subagent/*.test.ts`). Add `.github/workflows/ci-main.yml` to the Files table and to step 9, with, after the existing `(cd extensions/subagent && npm ci)` block:
```yaml
echo "== extensions/subagent/tool-timeout-bound.test.ts =="
npx tsx extensions/subagent/tool-timeout-bound.test.ts || failures=$((failures+1))
```
Without this the file is never executed and the `covered=5` claim for T1's termination half is false.

**C3 — the atomic step 3 also covers a SECOND parity expectation** (supersedes step 3, the Files row for `builtin-tools.test.ts`). `builtin-tools.test.ts:4587` builds `expected = [...ACTIVITY_EDGE_EVENTS, ...LIFECYCLE_EVENTS].sort()` and `deepEqual`s it against the registered set; adding `pi.on("tool_call")` makes it 10-vs-9, so step 11 cannot pass as written. Fold `PREVENTION_EVENTS` in there too (or switch it to `progressEdges.childRegisteredEvents()`), in the same atomic edit.

**C4 — the comment set is still incomplete** (supersedes step 10 and the `builtin-tools/index.ts` Files row). Add these, which state the false mechanism **today**:
- `extensions/builtin-tools/index.ts:2112-2115` — "Only streaming tools emit `tool_execution_update` (`bash` does; …)"
- `extensions/task-heartbeat.ts:879-887` — "Only streaming tools emit updates — `bash` does, …"
- `extensions/builtin-tools/index.ts:2794-2800` — "a tool that BUFFERS all its output … emits no `tool_execution_update` at all"
- `extensions/builtin-tools/index.ts:2808-2812` — "a tool that has never emitted a single `tool_execution_update` keeps it false"
- `extensions/builtin-tools/index.ts:2823` — "never emitted an update"
- test-comment restatements: `extensions/builtin-tools/builtin-tools.test.ts:3045` and `:3722`

All become: *the harness emits a zero-byte start update for every tool, so "emitted an update" ≠ "produced output"; the child arms `updatedToolIds` only on a **renderable** update.*

**C5 — residual statement corrected (supersedes the Deliverable end-state lines and R-B1).** Two *working* classes are still destroyed and were in no residual, and Leg B is not a narrow fallback.

| Shape | After the pair | Before → After |
|---|---|---|
| silent bash, **CPU-busy** (#928 shape) | clause 1 off (never armed), clause 1b off (CPU advancing) → **Leg B at 7200 s**, recoverable | destroyed @20 min → child survives. **Better** |
| silent bash, **CPU-flat**, probe live | **clause 1b @30 min** — child destroyed, no tool signal | destroyed @20 min → destroyed @30 min. **Neutral** |
| silent bash, CPU-flat, probe inert/unattributable | **Leg B**, recoverable (or clause 2 @4 h) | destroyed @20 min → recoverable @2 h. **Better** |
| **streamed then silent > S** | **clause 1 @20 min** — unchanged | **Neutral** |
| two bash, one streamed / one not (T5) | clause 1 off, clause 1b off (unattributable) → clause 2 @4 h / Leg B @2 h | destroyed @20 min → 2–4 h |
| command legitimately exceeding 7200 s | **Leg B kills the command** | ≤4 h or completion → 2 h. **Worse** |

- **R-B1 (rewritten):** *any* dispatched child's bash call without an explicit timeout — **streaming or not** — is killed at 7200 s. This **lowers the effective maximum bash duration for a dispatched child from clause 2's 4 h to 2 h**, and so supersedes clause 1's "a healthy tool survives however long it runs" guarantee for bash. That override is intended (#1500 asks for a default timeout) but is stated here explicitly rather than implied.
- **R-B5 (new):** a bash that emitted renderable output and then has a legitimate silent phase > S is **still destroyed by clause 1 at 20 min** — one real update arms the latch for the whole round, so "silence after output" remains sufficient evidence. Leg A does **not** fix this class (#1030's measured 1203–1341 s gaps). Mitigation: the per-dispatch `stream_stall_ms` / `TASK_STREAM_STALL_MS` override.
- **R-B6 (new):** a silent bash that burned startup CPU and is then blocked on I/O (`npm ci`, `curl`, `git fetch`) is destroyed by **clause 1b at 30 min** with no tool signal — clause 1b's own comment says a deadlock and a long I/O block are indistinguishable there. Before = 20 min; after = 30 min. **Delayed, not prevented.**
- **Reworded claims:** "silently-working bash → not killed" becomes "silently-working bash **that never emitted a renderable update**"; "wedged" is not applied to the CPU-flat I/O-blocked class.
- **Effect estimate:** "≤ ~40 % of abnormal dispatch outcomes" is an upper bound on the **clause-1 population**, **not** an estimate of work saved. The saved share is **not computable today** — the outcome row carries no CPU channel, and only 5 of the current 272 `tool-silence` transcripts still carry an `Alive state` blob.

**C6 — a named clause-policy decision for the record (not resolved here).** With Leg A landed, clause 1b (`tool-dead`, destroy-at-30-min) becomes the **first** bound for silent bash. Whether it should be **report-first** rather than destroy is a clause-policy question raised by #928's own closing comment. Recorded as an open decision for the owner; **not** silently decided by this change.

## Gate exit

**Plan gate: bounded exit at the 3-cycle cap — NOT clean.** Cycle 1: 8 findings. Cycle 2: 9. Cycle 3: 5 — a strict subset of previously-identified dimensions (registry, ordering, comment completeness, residual accuracy), i.e. convergence, with no new dimension or file introduced in cycle 3. All 5 are applied above as C1–C6 without a cycle-4 re-review. Residual risk of that choice: a mechanical correction could itself be wrong; it is caught by the implementation's own suite runs (a real gate, not a paper one) at step 11.

`[ADVERSARIAL-BOUND] cycles=3(plan) threats=5 covered=5 residuals=R-B1..R-B6 + C6` — to be repeated verbatim in the PR body.
