---
title: "#573 — hermetic deterministic stall for timeout-integration (PATH-shadow fake pi) — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-07
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-573, issue-553, issue-208, issue-137
---

# #573 — timeout-integration hermetic deterministic stall — Scope & Plan

## Confirmed Problem

`extensions/subagent/timeout-integration.test.ts` cannot run hermetic because pi 0.84.3
keyless exits fast (~2-6s, `stopReason: "error"`) instead of stalling — so the 5s-timeout
assertion (`elapsed >= 4500`) fails deterministically. The suite must exercise
`runSingleAgent`'s #137 timeout-kill / #208 external-SIGKILL-cut / settle-path sweep wiring
deterministically WITHOUT provider keys or billed LLM calls. Test 2's current hermetic
"green" is the incidental pass this issue eliminates (pgrep-empty passes vacuously — nothing
spawns keyless).

## Decisions

- **Chosen (option b — re-derived with evidence):** PATH-shadowing fake `pi` stub inside
  `timeout-integration.test.ts` itself (cut-resume.integration.test.ts precedent: temp dir +
  executable `pi` script + `process.env.PATH` prepend + `process.argv[1] = undefined`). The
  test drives the REAL `runSingleAgent` — only the resolved binary differs. No production
  code change, no new deps, no mock provider.
- **Sweep-reap observability (holder pid file):** the fake pi forks a pipe-holding
  grandchild (`sleep 120 &`) and records its pid to `$FAKE_PI_HOLDER_PID_FILE`. In the
  external-SIGKILL cut test ONLY the settle-path sweep can kill that orphan (external SIGKILL
  targets the wrapper; treeKill is not invoked; the orphan is reparented but keeps the pgid) —
  a post-settle holder-death poll is the DISCRIMINATING proof that Indicator 2's sweep-reap
  scenario actually runs. Guard `ok(holder > 0)` so a missing file fails hard, never silently.
- **Anti-vacuous guard:** tests 1/2 gain a concurrent pgrep poller asserting `spawned > 0`
  (the child genuinely spawned and was killed) before the pgrep-empty-after assertion.
- **Rejected:** (a) mock-provider harness — requires changing pi itself (dead end) and would
  not exercise the spawn/PATH/timeout/sweep wiring; (c) dev-machine-only — leaves CI blind;
  shared fake-pi module (approach B) — speculative dedup (~40 trivial lines) vs real regression
  risk refactoring cut-resume's green 12+ scenario suite; `SUBAGENT_PI_COMMAND` env override
  in production code (approach C) — test seam in `getPiInvocation`, less faithful spawn path.
- **Coverage division:** timeout-integration covers the subagent ext's runSingleAgent wiring
  (taskTimeout→killTree, resolveStopReason, doResolve→sweep hook). Shared treeKill/process-sweep
  internals + exit-settle/close taxonomy already have hermetic deep coverage in
  cut-resume.integration.test.ts + extensions/shared unit tests (tree-kill.test.ts,
  process-sweep.test.ts) — untouched.

## Fake pi script body

```sh
#!/bin/sh
sleep 120 &
echo $! > "${FAKE_PI_HOLDER_PID_FILE:-/dev/null}"
wait
```

- MUST NOT `exec sleep` — exec replaces argv; the wrapper's argv carries the
  `Task: sleep 120 && echo done` marker text that `pgrep -f "[s]leep 120 && echo done"`
  matches (wrapper = the spawned child; test 3's killPoller SIGKILLs exactly this pid).
- `sleep 120 &` forks the pipe-holding orphan (holder); `echo $! > file` records it;
  `wait` keeps the wrapper alive until killed.
- `#!/bin/sh` is POSIX-safe on ubuntu (dash) + macOS (bash); `$!`, `&`, `wait`,
  redirects all POSIX. Multi-command body prevents dash's last-command exec optimization.

## Files

1. `extensions/subagent/timeout-integration.test.ts` — fake-pi harness:
   - imports `fs`/`os`/`path` (Node builtins)
   - `FAKE_PI_SCRIPT` const + suite-level `setup()` / `teardown()` wrapping `run()` in
     try/finally: `mkdtempSync` + `writeFileSync(mode 0o755)` + PATH prepend + `argv[1] =
     undefined` (per-test holder pid file via `FAKE_PI_HOLDER_PID_FILE`)
   - `teardown()`: restore PATH + argv[1], `rmSync` tmp dir, SIGKILL leftover holder pids
   - helper: `markerPattern()` (char-class first char — #542 Linux procps self-match),
     `findPid()`, `readHolder()`, `isAlive()`, `pollDead()`
   - tests 1 & 3 assertions byte-identical (stopReason / elapsed >= 4500 / < 30000 /
     isFailedResult / pgrep-empty) + holder-death poll (`ok(holder > 0)` first)
   - test 2: keep pgrep-empty-after assertion + anti-vacuous `spawned > 0` guard
   - header comment updated (no longer claims real-pi keyless stall premise)
2. `.github/workflows/ci-main.yml` — flip the #553 "deliberately NOT wired" comment (~111-124);
   add after subagent-e2e-smoke (~130):
   `npx tsx extensions/subagent/timeout-integration.test.ts || failures=$((failures+1))`
   No PATH prefix needed (fake pi via the test's own temp dir; npm ci at ~125 covers deps).
3. `docs/plans/2026-09-07-issue-573-*.md` — this doc.

## Testing / Verification

Hermetic run (CI-equivalent: empty HOME, no provider keys):

```bash
cd /path/to/repo
env -u DEEPSEEK_API_KEY -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY \
  HOME=$(mktemp -d) \
  npx tsx extensions/subagent/timeout-integration.test.ts
```

Full relevant suites (must stay green):
- extensions/builtin-tools/subagent-integration.test.ts → 11/0 hermetic (unchanged)
- extensions/builtin-tools/subagent-e2e-smoke.test.ts → exit 0 keyless (unchanged)
- extensions/builtin-tools/cut-resume.integration.test.ts → all scenarios (unchanged)
- extensions/subagent/index.test.ts, provider-fallback.test.ts (unchanged)
- extensions/shared/*.test.ts (unchanged)

## Acceptance Criteria (issue indicators)

1. Suite passes hermetic (empty ~/.pi, no provider keys, fresh dir) with the fake-pi stall
   → 3/0 green.
2. The discriminating mid-task-cut + sweep-reap scenario ACTUALLY runs — test 3's
   holder-death poll passes ONLY via the settle-path sweep (external SIGKILL of the wrapper
   cannot kill the reparented holder; no pgrep marker on the orphan) — not the incidental
   pgrep pass.
3. No billed LLM calls — the fake pi is a shell script; no provider key exported.

## Learnings

- pi 0.84.3 keyless behavior is environment-dependent (exits ~2-6s with a provider error;
  never a deterministic stall) — do not design hermetic suites around real-pi stall premises.
- A fake `pi` on PATH reproduces the exact process shape a real sub-agent child needs for
  pgrep-marker assertions (the `Task: <text>` arg lands in the wrapper argv) while making the
  timeout/cut/sweep machinery run deterministically. Proven precedent: cut-resume.
- pgrep can only observe processes whose argv carries the marker text; orphan reaping must be
  made observable via a holder pid file (pid written by the child, death-polled after settle).
