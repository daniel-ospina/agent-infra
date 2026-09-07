---
title: "#574 — hermetic cache-integration timeout path (PATH-shadow fake pi, inline replication) — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-07
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-574, issue-573, issue-137, issue-208
---

# #574 — cache-integration hermetic timeout path — Scope & Plan

## Confirmed Problem

`extensions/subagent/cache-integration.test.ts` cannot run hermetic because it premises on real
`pi`'s deterministic stall: keyless pi 0.84.3 exits ~2–6s (`stopReason: "error"`) instead of
stalling, so the 5s `SUBAGENT_TASK_TIMEOUT_MS` kill never fires and
`equal(result.stopReason, "timeout")` fails deterministically hermetic (`'error' !== 'timeout'` —
reproduced). This is the identical disease class #573 eliminated for `timeout-integration.test.ts`.
The suite is the runSingleAgent CACHE-PATH analog of timeout-integration: the ONLY hermetic
coverage of the combined timeout→cache scenario (a timeout-killed child whose result is still
cached to disk with the timeout stopReason) — timeout-integration asserts no `cachePath`/on-disk
result.json, and index.test.ts unit-tests `getCacheDir`/`cacheResult` in isolation without a real
dispatch. It is NOT wired in ci-main (no CI regression today).

## Scope note (problem-verify P1 fix)

The pipe-holder grandchild (`sleep 120 & … echo $! > file … wait`) in timeout-integration's
`FAKE_PI_SCRIPT` is NOT architecturally required for cache-integration's timeout-only path:
`killTree("SIGTERM")` signals the process group (children-first, extensions/shared/tree-kill.ts),
so `close` fires and settle completes via the close path (the 2s `DEFAULT_EXIT_SETTLE_GRACE_MS`
timer is cleared when close fires first). The fake-pi body choice below is explicit; the plan does
not claim the grandchild is required.

## Decisions

- **Chosen (B + V2 — inline replication):** copy the #573 fake-pi harness inline into
  `cache-integration.test.ts` with the MINIMAL script body `#!/bin/sh\nsleep 120` (no grandchild,
  no holder pid file, no pgrep/marker helpers — cache-integration has zero such assertions). Same
  seam as #573: temp dir + executable `pi` stub + `process.env.PATH` prepend + `process.argv[1] =
  undefined` (falls through `getPiInvocation`'s script branch to the bare-`pi` PATH fallback; the
  stub dir at the FRONT of the inherited PATH wins over the runtime bin dir appended LAST by
  `getSubAgentPath`). No production code change, no new deps, no mock provider.
- **Rejected (A) — shared helper module** (`extensions/subagent/fake-pi-test-helper.ts` imported
  by BOTH suites): the green merged #573 suite would be refactored (extraction risk to its 3/0
  hermetic green); a new value-export module trips the repo's `scripts/check-untested-modules.cjs`
  per-PR gate (mandatory companion `fake-pi-test-helper.test.ts` — ceremony testing test-infra);
  cache-integration would use ~half the export surface. #573's own scoping rejected extraction even
  with cut-resume as an existing inline consumer; the repo has chosen inline duplication twice
  (cut-resume → timeout-integration). Consumer set is BOUNDED: extensions/subagent's runSingleAgent
  suites are abort-resilience (key-gated by design — needs real LLM completion), provider-fallback
  (own .cjs mock seam), timeout-integration (fake pi), cache-integration (this issue), index.test
  (unit). No 3rd hang-fake-pi consumer is on the books — extraction is premature; if one
  materializes, extract with 3 visible consumers and a clear interface.
- **Rejected (C) — .cjs node-stub via argv[1] (provider-fallback seam):** `getPiInvocation`
  returns `{ command: process.execPath, args: [stub, …] }` — a DIFFERENT spawn branch than the
  bare-`pi` PATH branch timeout-integration exercises via the same `argv[1] = undefined` fallback.
  Breaks two-suite coherence (sibling suites must exercise the same dispatch branch) and adds a
  third harness pattern for no gain.
- **Rejected — relax the `stopReason === "timeout"` assertion:** violates Indicator 2 (timeout
  path must GENUINELY fire, not an incidental pass) and destroys the only hermetic coverage of the
  settle-flow `cachePath`/`cacheResult` wiring.
- **Rejected — dev-machine-only (issue option b):** leaves the disease + CI blind.
- **Fake-pi body — V2 over V1:** V1 (reuse #573's grandchild script verbatim) is viable but its
  holder/pid-file machinery would be dead weight. V2's `sleep 120` single-command body is simpler;
  its potential dash exec-optimization is irrelevant here (no pgrep-marker assertions). Worst case
  (close never fires → 2s exit-settle grace) still settles `stopReason: "timeout"` within the 8s
  waitForFile margin (~5s timeout + ~2s grace + write < 8s poll).

## Files

1. `extensions/subagent/cache-integration.test.ts` — inline fake-pi harness:
   - header comment REWRITTEN (the current "Deterministic and API-key-free: the timeout kill is
     used…" is a false forward claim on a suite that today fails hermetic) → describe the
     PATH-shadowing fake-pi mechanism, the #573 origin, and the V2 stance (no holder/grandchild —
     cache-integration asserts cache contract only)
   - `FAKE_PI_SCRIPT = "#!/bin/sh\nsleep 120"`
   - `setup()`: `mkdtempSync` + `writeFileSync(pi, FAKE_PI_SCRIPT, { mode: 0o755 })` + PATH
     prepend + `process.argv[1] = undefined`
   - `teardown()`: restore PATH + argv[1], `rmSync` tmp dir; delete `SUBAGENT_TASK_TIMEOUT_MS`
   - `run()` wraps the test in `setup() / try { tests } finally { teardown() }`
   - test body: the existing argv[1] save/restore + timeout-env try/finally moves into
     setup/teardown; keep `SUBAGENT_TASK_TIMEOUT_MS=5000` and file-top `SUBAGENT_FALLBACK_DISABLE=1`
   - **anti-vacuous addition:** `elapsed >= 4500` guard (the timeout genuinely fired — mirrors
     timeout-integration; suite currently has no elapsed bound)
   - cache assertions byte-identical (stopReason "timeout", cachePath, result.json content poll,
     new cache dir under task-results, getCacheDir reconstruction)
2. `.github/workflows/ci-main.yml` — wiring mirror immediately AFTER the #573 timeout-integration
   block (before the two PATH-prefixed real-pi builtin-tools suites):
   ```yaml
   echo "== extensions/subagent/cache-integration.test.ts =="
   npx tsx extensions/subagent/cache-integration.test.ts || failures=$((failures+1))
   ```
   No PATH prefix (fake pi via the test's own temp dir; npm ci on the line above covers deps).
   Extend the #553/#573 comment block to mention both hermetic suites.
3. `docs/plans/2026-09-07-issue-574-cache-timeout-fake-pi.md` — this doc.

## Testing / Verification

Hermetic run (CI-equivalent: empty HOME, no provider keys):

```bash
cd /path/to/repo
# deps once (also extensions/builtin-tools for the up-tree typebox resolution):
(cd extensions/subagent && npm ci --no-audit --no-fund --loglevel=error)
(cd extensions/builtin-tools && npm ci --no-audit --no-fund --loglevel=error)
export PATH="$PWD/extensions/subagent/node_modules/.bin:$PATH"
env -u DEEPSEEK_API_KEY -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY \
  HOME=$(mktemp -d) \
  npx tsx extensions/subagent/cache-integration.test.ts   # → 1/0, stopReason timeout
```

Full relevant suites (must stay green):
- extensions/subagent/timeout-integration.test.ts → 3/0 hermetic (UNTOUCHED — B+V2 chosen so the
  green #573 suite is not refactored)
- extensions/builtin-tools/subagent-integration.test.ts → 11/0 hermetic (unchanged)
- extensions/builtin-tools/subagent-e2e-smoke.test.ts → exit 0 keyless (unchanged)
- extensions/subagent/index.test.ts, provider-fallback.test.ts (unchanged)
- ci-main job run (ubuntu) exercises the wired suite end-to-end after merge.

## Acceptance Criteria (issue indicators)

1. Suite passes hermetic (empty HOME, no provider keys, fresh dir) with the fake-pi stall → 1/0
   green; `result.stopReason === "timeout"` AND `elapsed >= 4500` (the timeout genuinely fired —
   not an incidental pass).
2. Cache assertions intact: `cachePath` set; result.json written under
   `~/.pi/agent/task-results/<sha256>/` with content matching (agent "test-agent", task
   "sleep 120 && echo done", stopReason "timeout"); a new cache dir appeared and includes the
   result's cachePath; `getCacheDir` reconstruction under resultsRoot.
3. Wired in ci-main after the #573 block (no PATH prefix), so the suite guards the cache contract
   in CI — no billed LLM calls (the fake pi is a shell script; no provider key exported).
4. timeout-integration STILL 3/0 hermetic (untouched by the chosen inline approach).

## Learnings

- The repo now has THREE inline fake-pi/override harnesses chosen deliberately over a shared
  module (cut-resume scenario-routed, timeout-integration sleep-holder, cache-integration minimal
  `sleep 120`). At each step the consumer set was bounded and the harness surfaces differed; the
  dedup-vs-inline decision is consumer-count + interface-fit dependent, not a fixed rule.
- A fake-pi suite that only needs a deterministic hang does NOT need the pipe-holder grandchild:
  treeKill's pgid SIGTERM closes the child pipes and settle completes via the close path. The
  grandchild exists solely to make settle-path sweep reaping OBSERVABLE (external-SIGKILL cut
  scenarios) — don't cargo-cult it into suites without orphan-reap assertions.
- `check-untested-modules.cjs` treats any new value-export `.ts` module repo-wide as needing a
  companion `.test.ts` — a real cost weighing AGAINST extracting test-support helpers into new
  modules in this repo.
