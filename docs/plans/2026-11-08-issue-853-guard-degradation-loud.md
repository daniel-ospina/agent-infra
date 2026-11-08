<!-- research-path: issue comment (<!-- research: v1 -->, 2026-11-08) -->
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

1. **A LOUD boxed banner** via `console.warn` naming the STATE, the consequence (bash git mutations
   allowed; write/edit in a main checkout fails OPEN — #761), the **cause** (`_classifierLoadFailure`,
   recorded in the load `catch`), and the **remedy** (reinstall the extension tree; re-run
   `test-module-load.mjs`), plus the deliberate acceptance (`AGENT_ALLOW_MAIN_EDITS=1`).
2. **`ctx.ui.notify(…, "error")`** in interactive sessions — a warn line in a noisy startup log is
   exactly what nothing reads.
3. **A durable `guard_degraded` event** in `~/.pi/agent/audit/gate-events.jsonl`
   (`extension`, `reason`, `error`, `session_cwd`, `ts`), and `"guard_degraded"` added to the
   `GateEventName` union in `extensions/shared/audit-log.ts` so a report matches on a recorded name
   rather than a free string. ⛔ That union is DOCUMENTATION, not enforcement: `appendJsonl` takes an
   unconstrained `event` and no tsconfig covers `extensions/`, so removing the member reddens nothing.

Properties that make it safe:

- **Placed before every early return** in `session_start` — a degradation report that sat behind the
  escape-hatch return would be silent on the sessions that need it most. Pinned by **C12** (a hatched
  arm still gets the banner + the row) and **C12b** (source-order: the call precedes
  `if (_isAllowMainEdits()) return;`).
- **Once per session process** (`_classifierDegradedPids`), so `/resume` cannot spam the banner or
  duplicate the audit row.
- **Never throws** — the whole report is wrapped: a report that throws would change a verdict.
- **Print-mode lanes still get the banner and the event**; only the `ui.notify` arm is skipped
  (there is no UI). No surface is silent.

## Wiring

| Thing | Call site / importer / consumer | What it does there |
|---|---|---|
| `_reportClassifierDegradation` | `extensions/main-worktree-guard/index.ts:5129` — the only caller, first statement of `pi.on("session_start")` | turns the degraded state into the banner + notify + event |
| `_classifierLoadFailure` | written in the classify-git load `catch` (`index.ts:399-404`, the write at `:402`); read only by `_reportClassifierDegradation` | carries the real load error into the banner and the event's `error` field |
| `_classifierDegradedPids` | read+written only inside `_reportClassifierDegradation` | once-per-session-process dedupe (mirrors the existing pid-keyed `warnedDeviations`) |
| `appendJsonl` (`extensions/shared/audit-log.ts`) | imported at `index.ts:147`; existing callers `:539`, `:4094`, `:4711`, `:5347`; new caller in `_reportClassifierDegradation` (`:5110`) | appends one JSONL row to `~/.pi/agent/audit/gate-events.jsonl`; already fail-safe (never throws) |
| `GateEventName` (`extensions/shared/audit-log.ts:40-63`) | the shape a report/replay MATCHES ON; `extensions/shared/audit-log.test.ts` | `"guard_degraded"` added, with a comment naming the failure mode. ⛔ DOCUMENTATION ONLY: `appendJsonl(entry: Record<string, unknown>)` (`audit-log.ts:72`) takes an unconstrained `event` string and no tsconfig covers `extensions/` (extensions are type-stripped, never typechecked), so nothing ENFORCES the union — deleting the member reddens no suite. The member is the recorded name, not a gate. |
| `isPrintMode()` (`extensions/shared/print-mode.ts`) | already imported at `index.ts:146`; new call site in `_reportClassifierDegradation` | suppresses the `ui.notify` arm for headless lanes, which get the banner in their own log |
| `module-load-hooks.mjs` (`resolve`/`load`) | imported by `test-module-load.mjs` Part B (in-process) and by the new Part C probe (child process) | Part C wraps `load` to make `classify-git.mjs` throw while evaluating — the ONE injection |
| `test-module-load.mjs` | `ci.yml:980` (per-PR `verify` job) and `ci-main.yml:158` (post-merge `extensions/*/test*.mjs` glob) | Part C runs on the PR lane, so the report is proved before a merge; no new CI step or file registration needed |

## Implementation steps (built — each with the test that proves it)

1. `audit-log.ts` — add `"guard_degraded"` to `GateEventName` → `npx tsx extensions/shared/audit-log.test.ts` (5 passed).
2. `index.ts` — record the load failure in the `catch`; add `_reportClassifierDegradation`; wire it as
   the first `session_start` statement → `test-module-load.mjs` **C1-C6** (banner content, cause,
   remedy, dedupe, notify level) and **C7-C8** (event row + attribution).
3. `test-module-load.mjs` — Part C child-process probe, four arms (interactive-degraded,
   print-mode-degraded, healthy control, escape-hatch-on) → **C9** (print mode keeps banner + event,
   no notify), **C11/C11b** (a healthy load reports nothing and really loaded the classifier),
   **C12/C12b** (the report is NOT behind the escape-hatch return — behaviourally, plus a
   source-order pin so a later refactor cannot silently move it under the hatch).
4. Mutation proof — every arm must be able to go RED, or it is a pin that cannot fail:
   - delete the `session_start` wiring → **9 red** (C1-C9);
   - delete only the `appendJsonl` block → **3 red** (C7-C9);
   - move the call BELOW `if (_isAllowMainEdits()) return;` → **12 red** (C1-C9, C12, C12b).
   All three restored.

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
