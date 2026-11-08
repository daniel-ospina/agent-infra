<!-- research-path: the issue comment carrying the research: v1 block (2026-11-08) -->
<!-- plan-review: cycles=0, status=pending, version=2.3.0 -->

# #853 — a degraded classifier load must be LOUD and DURABLE, not one warn line

**Issue:** daniel-ospina/agent-infra#853 · **Branch:** `feat/853-tm` · **Date:** 2026-11-08
**Governing decision:** `docs/research/2026-09-13-guard-failure-fail-open-vs-closed.md` (epic #917
decision **D1**, the fail-open vs fail-closed brief), rules 1/3/4/6 — see §Decision below.

## What the issue reports, re-measured

The body has three Expected items. Only one of them is still open, and it is not the one the title
names:

| # | Expected | State on 2026-11-08 | Evidence |
|---|---|---|---|
| 1 | fix the `ReferenceError` in `classify-git.mjs` | **DONE** since `699ecde5b` (#756), an ancestor of `main` | `git merge-base --is-ancestor 699ecde5b origin/main` → exit 0; `let _extractCodePayload` declared at `index.ts:222`; `test-module-load.mjs` B1 captures **zero** degradation warnings |
| 2 | fail **closed** on load failure | **NOT DONE, and not decided** | `#761` option 1 — "#761 … needs an explicit decision", because it contradicts the module's documented never-false-block contract (`index.ts:110-123`). Re-homed by the owner comment on #853, 2026-10-16: "The two remaining 'Expected' items are the SAME root as open #761" |
| 3 | a startup self-test so a broken classifier is a **loud session-level failure** | **NOT DONE — delivered here** | the only degradation surface was one `console.warn` in the load `catch`; no `ui.notify`, no `appendJsonl`, and `gate-events.jsonl`'s event union carried no guard-degradation member |

## Decision (the contradiction test, answered)

`docs/research/2026-09-13-guard-failure-fail-open-vs-closed.md` is a **recorded decision** that reaches
this work directly. It states the conditions under which fail-open is legitimate at all:

> "**Fail-open is legitimate only when all three hold:** the action is reversible/low-impact **or** a
> compensating detection control will surface what got through, **and** the fail-open event is recorded
> as a state distinct from 'passed'." (rule 3)
> "**Failure-to-decide must never be indistinguishable from a decision to allow.**" (rule 4)
> "1. … **fail-open-with-loud-alarm on the guard's own internal error** — never a silent `0`.
> 6. **Prove the guard can fail** — inject the internal-error path in CI and assert it surfaces
> distinguishably." (Application to this repo, rules 1 and 6)
> "silent self-disablement has occurred at least five times (**#853**, #789, #744, #761, #708)"
> (`:83`)

So the recorded decision **mandates exactly Expected #3** and treats #853 as one of its own instances.
It does **not** mandate Expected #2 — fail-closed is left as a cost-asymmetry judgement, which is what
#761 still holds open. Taking this branch therefore **carries out** a recorded decision rather than
contradicting one; adding a notification to a path that has already decided to allow cannot introduce
a block, so the module's never-false-block contract is untouched.

## Design

The in-repo precedent is `review-enforcer`'s `gh_shim_degraded` (#984/#3297), whose own comment states
the rule: "⛔ LOUD, NOT ⚠️. This line used to be the ONLY surface that knew the guard was degraded …
it now names the consequence and the remedy, and it RECORDS a gate event so a report can read the
state without anyone parsing prose." (`extensions/review-enforcer/index.ts:9120`)

`_reportClassifierDegradation(ctx)` in `extensions/main-worktree-guard/index.ts`, called as the FIRST
statement of the registered `session_start` handler:

1. **A durable `guard_degraded` event** in `~/.pi/agent/audit/gate-events.jsonl`
   (`extension`, `reason`, `error`, `session_cwd`, `ts`), written **FIRST**, declared in the
   `GateEventName` vocabulary in `extensions/shared/audit-log.ts` so a report matches on a recorded
   name rather than a free string. ⛔ The vocabulary is **derived from a runtime `GATE_EVENT_NAMES`
   array**, not a bare type union: `appendJsonl` takes an unconstrained `event` and no tsconfig covers
   `extensions/` (they are type-stripped, never typechecked), so a bare union would be DOCUMENTATION
   and removing a member would redden nothing — measured. With the array, membership is assertable:
   deleting `"guard_degraded"` reddens `audit-log.test.ts` **and** Part C **C13**.
2. **A LOUD boxed banner** via `console.warn` naming the STATE, the consequence (bash git mutations
   allowed; write/edit in a main checkout fails OPEN — #761), the **cause** (`_classifierLoadFailure`,
   recorded in the load `catch`), and the **remedy** (reinstall the extension tree; re-run
   `test-module-load.mjs`), plus the deliberate acceptance (`AGENT_ALLOW_MAIN_EDITS=1`).
3. **`ctx.ui.notify(…, "error")`** in interactive sessions — a warn line in a noisy startup log is
   exactly what nothing reads.

⛔ **THE ORDER IS THE POINT, and each surface gets its OWN `try`** (review cycle 2, P3). With one
`try` around all three and the row LAST, a `ui.notify` that THREW skipped the row — and because the
pid is marked before it, the loss was PERMANENT for the process: the only machine-readable surface
would never learn the session ran unguarded, while the banner implied it could. A presentation
surface must never be able to cost the durable record. Pinned by **C14** (a throwing `notify` still
leaves exactly one row) and **C14b** (the throw does not propagate out of `session_start`).

Properties that make it safe:

- **Placed before every early return** in `session_start` — a degradation report that sat behind the
  escape-hatch return (`index.ts:5177`) would be silent on the sessions that need it most. Pinned by
  **C12** (a hatched arm still gets the banner + the row) and **C12b** (source-order: the call precedes
  `if (_isAllowMainEdits()) return;`).
- **Once per session process** (`_classifierDegradedPids`), so `/resume` cannot spam the banner or
  duplicate the audit row.
- **Never throws, and no surface can suppress another** — each of the three arms has its own `try`,
  so a throw in one cannot cost the others; a report that throws would change a verdict.
- **Print-mode lanes still get the banner and the event**; only the `ui.notify` arm is skipped
  (there is no UI). No surface is silent.

## Wiring

| Thing | Call site / importer / consumer | What it does there |
|---|---|---|
| `_reportClassifierDegradation` | `extensions/main-worktree-guard/index.ts:5142` — the only caller, first statement of `pi.on("session_start")` (`:5137`); its own definition is `:5072` | turns the degraded state into the banner + notify + event |
| `_classifierLoadFailure` | written in the classify-git load `catch` (`index.ts:399-404`, the write at `:402`); read only by `_reportClassifierDegradation` | carries the real load error into the banner and the event's `error` field |
| `_classifierDegradedPids` | read+written only inside `_reportClassifierDegradation` | once-per-session-process dedupe (mirrors the existing pid-keyed `warnedDeviations`) |
| `appendJsonl` (`extensions/shared/audit-log.ts`) | imported at `index.ts:147`; existing callers `:539`, `:4094`, `:4711`, `:5360`; new caller inside `_reportClassifierDegradation` at `:5104` | appends one JSONL row to `~/.pi/agent/audit/gate-events.jsonl`; already fail-safe (never throws) |
| `GateEventName` (`extensions/shared/audit-log.ts:72`) | the shape a report/replay MATCHES ON; `extensions/shared/audit-log.test.ts`; Part C `C13` | `GATE_EVENT_NAMES` (`:47-71`) is the runtime source and `GateEventName` (`:72`) is derived from it, so membership is ASSERTABLE (`appendJsonl` still takes `Record<string, unknown>`, so the type alone enforces nothing): deleting the member reddens `audit-log.test.ts` + `C13`. |
| `isPrintMode()` (`extensions/shared/print-mode.ts`) | already imported at `index.ts:146`; new call site inside `_reportClassifierDegradation` | suppresses the `ui.notify` arm for headless lanes, which get the banner in their own log |
| `module-load-hooks.mjs` (`resolve`/`load`) | imported by `test-module-load.mjs` Part B (in-process) and by the new Part C probe (child process) | Part C wraps `load` to make `classify-git.mjs` throw while evaluating — the ONE injection |
| `test-module-load.mjs` | `ci.yml:980` (per-PR `verify` job) and `ci-main.yml:158` (post-merge `extensions/*/test*.mjs` glob) | Part C runs on the PR lane, so the report is proved before a merge; no new CI step or file registration needed |

## Implementation steps (built — each with the test that proves it)

1. `audit-log.ts` — declare `"guard_degraded"` in the runtime `GATE_EVENT_NAMES` array the `GateEventName` type derives from → `npx tsx extensions/shared/audit-log.test.ts` (8 passed).
2. `index.ts` — record the load failure in the `catch`; add `_reportClassifierDegradation`; wire it as
   the first `session_start` statement → `test-module-load.mjs` **C1-C6** (banner content, cause,
   remedy, dedupe, notify level) and **C7-C8** (event row + attribution).
3. `test-module-load.mjs` — Part C child-process probe, five arms (interactive-degraded,
   print-mode-degraded, healthy control, escape-hatch-on, throwing-notify) → **C9** (print mode keeps
   banner + event, no notify), **C11/C11b** (a healthy load reports nothing and really loaded the
   classifier), **C12/C12b** (the report is NOT behind the escape-hatch return — behaviourally, plus a
   source-order pin so a later refactor cannot silently move it under the hatch), **C13/C13b** (the
   name the guard WRITES is a name the real module DECLARES — emit ↔ vocabulary, end-to-end), and
   **C14/C14b** (a throwing `ui.notify` still leaves the durable row, and does not propagate).
   ⛔ The labels are disjoint on purpose: `C13` is the vocabulary pin, `C14` the ordering pin — a
   report citing "C13" must name ONE assertion.
4. Mutation proof — every arm must be able to go RED, or it is a pin that cannot fail. **All five
   re-measured at this head against the 152-assertion baseline, not carried forward:**
   - delete the `session_start` wiring → **13 red** (C1-C9, C12, C12b, C13, C14);
   - delete only the durable row → **6 red** (C7, C8, C9, C12, C13, C14);
   - restore the pre-fix ordering (row LAST, one shared `try`) → **1 red** (C14);
   - move the call BELOW `if (_isAllowMainEdits()) return;` → **2 red** (C12, C12b);
   - delete the `"guard_degraded"` vocabulary member → **C13 red + `audit-log.test.ts` 7/8**.
   All restored. ⛔ The placement mutation reddens 2 arms, not 13: in a degraded session
   `isWorktreeCwdWrite` is the fail-safe stub `() => false` (`index.ts:157`), so the non-hatched arms
   still reach a call placed further down the handler — which is exactly why C12 had to be added.

## Out of scope — must NOT be raised

- **Fail-CLOSED on load failure** (issue Expected #2). #761 option 1; needs an owner decision. Not decided here.
- **Partial-abort / missing-export skew** (#759 item 1) — `classifierLoaded` stays `true` with one
  export stubbed. `_classifierLoadFailure` is set only by the total-load `catch`.
- **`test.mjs`'s 3 pre-existing reds** (`bd runtime … → recovery`, `X2: partial craft`). Proven not
  introduced here: the same 3 fail from pristine `HEAD` sources run with this CWD; they depend on the
  ambient hub (detached HEAD + ~50 live worktrees).
- `#789` — the pre-fix duplicate of the same #744 root.

## Rounds

**Rounds:** — (PLAN-VERIFY is dispatched by the parent at the review gate, not by this lane)
