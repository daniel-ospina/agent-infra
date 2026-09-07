# #553 — Wire the real-pi subagent suites into ci-main — Scope & Plan

## Confirmed Problem
The three real-pi subagent suites (`extensions/subagent/timeout-integration.test.ts`,
`extensions/builtin-tools/subagent-integration.test.ts`, `subagent-e2e-smoke.test.ts`)
never run in CI. They spawn real `pi -p --no-session` children (getPiInvocation →
bare `pi`), so the exact failure mode #542 fixed (pgrep self-match on Linux)
stays undetected. Blockers: no `pi` binary on runners, no reproducible dep tree
(subagent imports four @earendil-works packages), provider-key hermeticity.

## Decisions
- **Dep tree** (author proposal, executed): devDep the four @earendil-works
  packages @0.84.3 in `extensions/subagent/package.json` (pi-coding-agent /
  pi-ai / pi-agent-core / pi-tui — the runtime import surface per index.ts +
  agents.ts), regenerate the stale lock, `npm ci` once in the ci-main step.
  Route = #426/#379/#533 precedent.
- **`pi` CLI**: pi-coding-agent's `bin` provides it → add
  `extensions/subagent/node_modules/.bin` to PATH for the three suite runs
  (per-command PATH prefix, no export leak).
- **Keyless hermeticity** (empirically chosen over farm-provisioning): the job
  env exports NO provider keys. Verified keyless-CI-equivalent local runs
  (empty HOME, `env -u *API_KEY`):
  - timeout-integration is NOT wired (see below — its keyless-stall premise
    is false on pi 0.84.3); tracked in #573,
  - subagent-e2e-smoke exit 0 (self-skips the LLM e2e without DEEPSEEK_API_KEY),
  - subagent-integration 11/0 — 8 env-construction assertions run; the 3
    startup-stderr assertions need a pi that finishes startup + a deployed
    extension farm, which hermetic CI cannot provide. The suite already guards
    2 of them on `!DEEPSEEK_API_KEY` ("pi stalls during provider/MCP init in
    CI"); added the same guard to the third ("pi -p process starts and produces
    stderr"). They run on dev machines (keys + deployed farm present).
- **Not chosen**: provisioning a full runner pi-home + extension farm to run the
  startup-stderr assertions in CI — fragile (replicates the deploy surface),
  and the assertions' value is in the dev-machine loop where the farm is real.

## Verification (corrected after review r1)
- subagent-integration 11/0 and subagent-e2e-smoke exit 0 hermetic (empty HOME,
  no provider keys).
- timeout-integration FAILS hermetic (2/1): pi 0.84.3 exits ~2s with "No API
  key found" instead of stalling keyless, so the 5s-timeout assertion
  (`elapsed >= 4500`) fails deterministically — the earlier "3/0 keyless"
  claim in this doc was wrong (that run must have reached real auth). The
  suite's timeout/cut semantics cannot be exercised in hermetic CI without a
  deterministic stall; tracked in #573. DELIBERATELY NOT WIRED here.
- YAML parses; ci-main.yml is not a template-materialized workflow (drift gate
  covers python/node/docs-ci only). actionlint runs in CI.
- ci-main extension-tests runs all pre-existing suites + the three new ones to
  the same failure accumulator (any failure → issue auto-filed, no merge gate
  change).
