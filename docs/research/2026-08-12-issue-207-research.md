# Issue #207 — Research

**Status:** DRAFT
**Branch:** feat/207-main-edits-marker
**Date:** 2026-08-12
**Level:** project | **Complexity:** standard | **Team:** organisation-design-team

Research stage (Phase 2 of 6) for issue #207: give `main-worktree-guard` a
TTL'd file-based escape marker so a deliberate session can escalate
mid-session (the env-only `AGENT_ALLOW_MAIN_EDITS=1` hatch cannot be set on a
running pi process). All paths relative to the repo root; line refs verified
against `feat/207-main-edits-marker` worktree on 2026-08-12.

---

## 1. Guard flow — where `_isAllowMainEdits()` is evaluated

`extensions/main-worktree-guard/index.ts`. Imports (lines 23-24):

```ts
import { resolve, dirname } from "node:path";
import { realpathSync, existsSync } from "node:fs";
```

The env check (lines 52-55):

```ts
function _getEnv(name: string): string | undefined {
  return process.env[`AGENT_${name}`] ?? process.env[`ELDATO_${name}`];
}
function _isAllowMainEdits(): boolean {
  return _getEnv("ALLOW_MAIN_EDITS") === "1";
}
```

Call sites (exactly two):

1. **Per tool_call** — `pi.on("tool_call", ...)` handler at line 84; the
   allow-path early returns at lines 92-96:
   ```ts
   if (isAgentInfraRepo()) {
     return undefined; // agent-infra is a small infra repo — no worktree needed
   }
   if (_isAllowMainEdits()) {
     return undefined;
   }
   ```
   The handler is registered once at load and fires for every `write`/`edit`/
   `bash` tool call (event-type gate at lines 86-91). **A marker-file re-read
   slots in directly beside line 95** — it is already evaluated per event, so
   a per-event `statSync` (metadata-only, no content parse) adds negligible
   cost and no architectural change.
2. **Session-start hub discipline check** — line 240:
   ```ts
   if (!isAgentInfraRepo() && !_isAllowMainEdits()) {
   ```
   Runs once at load; a marker check here is optional (the per-tool_call
   check is authoritative) but keeps the "suppress warning" parity with the
   env hatch.

**Feasibility of per-call re-read:** confirmed. `statSync` on a single
user-state file is a metadata call; the loop-enforcer already does an
equivalent mtime filter inside `session_start` and per-manifest reads
(`extensions/loop-enforcer/index.ts:1328-1329`). The re-read must NOT be
cached in a module-level variable — the TTL is dead weight otherwise (this is
align condition 3 and must be asserted by a stale-mtime test fixture).

## 2. Pure-logic home — classify-git.mjs

> ⛔ Staleness note (round-2 F6, 2026-08-12): cite exports by NAME — line
> numbers drift. Current numbers: DESTRUCTIVE_GIT_PATTERNS 19,
> classifyGitCommand 44, isWorktreeCwd 59, extractPushDeleteBranch 78,
> getWorktreeBranches 97, isBranchInMainCheckout 124,
> getMainCheckoutBranch 141, isAgentInfraRepo 176.

`extensions/main-worktree-guard/classify-git.mjs` is pure JS (node:fs +
node:child_process + node:path only), imported by BOTH `index.ts` (via jiti,
lines 35-43) and `test.mjs` (line 8). Current export surface:

```js
export const DESTRUCTIVE_GIT_PATTERNS = [...];            // line 19
export function classifyGitCommand(command)               // line 44
export function isWorktreeCwd(cwd)                        // line 59
export function extractPushDeleteBranch(command)          // line 78
export function getWorktreeBranches()                     // line 97
export function isBranchInMainCheckout(branch)            // line 124
export function getMainCheckoutBranch()                   // line 141
export function isAgentInfraRepo(cwd, env)                // line 176
```

The established convention is **dependency-injected pure functions**:
`isAgentInfraRepo(cwd = process.cwd(), env = process.env)` (line 176) takes
injectable params so test.mjs exercises the SAME logic with fake env objects
(test.mjs "Infra-repo detection (#99)" section). The header comment states
the design intent explicitly: *"Pure JS so both index.ts (via jiti) and
test.mjs can import the SAME rules."*

**Recommendation: marker-check logic belongs in classify-git.mjs** — e.g.

```js
export const ALLOW_MAIN_EDITS_MARKER_TTL_MS = 15 * 60 * 1000; // named constant
export function isAllowMarkerActive(stats, nowMs = Date.now(), ttlMs = ALLOW_MAIN_EDITS_MARKER_TTL_MS)
export function isAllowMarkerPath(path, home)  // exact-match guard against traversal/symlink
```

Taking `stats` (the `fs.Stats` object from `statSync`) rather than a path
keeps it 100% unit-testable with fake stat objects — no tmp files, no git —
and the TTL/now injection mirrors the `isAgentInfraRepo(cwd, env)` pattern.
`node:fs` is already imported there (`existsSync`, line 5), so adding
`statSync` is trivial. The existing lazy-import fallback in index.ts
(`let isAgentInfraRepo = () => false` with a try/catch around the dynamic
import, lines 35-47) already provides the degradation contract for any new
export: **fail-safe default must be `false` (block)** so a failed import
never silently allows.

## 3. Test structure — test.mjs harness conventions

`extensions/main-worktree-guard/test.mjs` runs with plain node
(`node extensions/main-worktree-guard/test.mjs`, header line 4). Harness:

- **Helpers:** `expect(name, command, expected)` for classification
  (line 14), `expectBool(name, got, expected)` (line 148),
  `expectBranches(command, expectedArray)` (line 176), and `check(name,
  path, expectedContains, sessionCwd)` for path-scoping mirror of
  index.ts (line 91).
- **Counters:** module-scoped `let pass = 0, fail = 0` (line 13), each
  helper does `ok ? pass++ : fail++`, final
  `console.log(\`\n${pass} passed, ${fail} failed\`); process.exit(fail > 0 ? 1 : 0)`
  (last two lines).
- **Conventions:** one `console.log` per assertion (✅/❌ prefix, name, got,
  expected-on-fail); sections are separated by `// ── Section name ──`
  comments; pure-logic tests need no fixtures; git-dependent tests
  provision/cleanup tmp state in try/finally (worktree test, tmpRepo).
- **Current size:** 32 direct `expect(` calls + 8 `check(` + 7 `expectBool(`
  + 12 `expectBranches(` + 5 inline ternary assertions ≈ **64 assertions** —
  consistent with the issue's "64+ existing" reference (attributed to #210's
  count).

**New marker tests slot in as a new `// ── Escape marker (#207) ──` section**
at the end, using the pure-function style (fake `fs.Stats`-shaped objects →
`expectBool("marker present+valid", isAllowMarkerActive(fakeStats), true)`)
plus the path-guard cases. No tmp-file plumbing needed for the pure
functions; the only fs-touching case is optional (an integration assertion
that a real file's mtime is read — but that would depend on fs timing, so a
fake-stats approach is the deterministic choice).

## 4. Path conventions — per-user state in ~/.pi/agent

`~/.pi/agent/` is the established per-user state directory across the
extension fleet:

| Extension | Path |
|---|---|
| audit-logger | `~/.pi/agent/audit/audit.jsonl` (`audit-logger.ts:9`) |
| sequence-enforcer | `~/.pi/agent/bridge` (`index.ts:55`), `~/.pi/agent/audit/enforcement.jsonl` (`index.ts:169`) |
| shared/audit-log | `~/.pi/agent/audit/gate-events.jsonl` (`gateEventsFile()`, `shared/audit-log.ts:42`) |
| loop-enforcer | `~/.pi/agent/loops/`, `~/.pi/agent/auth.json` (`scheduler.ts:2`, `verifier.ts:200`) |
| subagent | `~/.pi/agent/task-results/<sha256>/result.json` (`subagent/index.ts:253`) |
| review-enforcer | `~/.pi/agent/reviews/<PR>.json` (`review-enforcer/index.ts:97`) |
| slack-bridge | `~/.pi/agent/slack-socket-owner.json`, `slack-approval-seen.json` (`socket-mode.ts:30,99`) |
| mcp-client | `~/.pi/agent/.mcp.json` — **dotfile precedent** (`mcp-client/index.ts:236`) |
| tortoise-capture / reflect-hook | `~/.pi/agent/tortoise-config.json` (`tortoise-capture/index.ts:24`) |

`~/.pi/agent/.allow-main-edits` is fully consistent — same root, dotfile
convention has a direct precedent (`~/.pi/agent/.mcp.json`), and the paths
are built with `join(homedir(), ".pi", "agent", ...)` (never hardcoded —
`shared/audit-log.ts:42`, `sequence-enforcer/index.ts:55`). **No existing
`.allow-*` or marker-file precedent** exists in the repo (grep found none),
so this introduces a new filename but not a new convention.

**TTL/mtime precedents (dotfile/TTL family):**
- `loop-enforcer/index.ts:1292-1293` — `const MANIFEST_MTIME_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;` then
  `(Date.now() - st.mtimeMs) < MANIFEST_MTIME_WINDOW_MS` (lines 1328-1329,
  1355-1356, 1592-1593) — **mtime-based staleness is an established pattern**.
- `slack-bridge/socket-mode.ts:30` — owner-lock file with embedded
  `{pid, startTime, heartbeat}` — embedded-timestamp + heartbeat refresh
  precedent (heartbeat = refresh-by-rewrite).

## 5. Session logging — audit facilities for marker creation

Two existing mechanisms, both append-only JSONL under
`~/.pi/agent/audit/`, both fail-silent (never throw into the gate path):

1. **shared/audit-log.ts** — the shared facility. `appendJsonl(entry, file?)`
   (line 48) stamps `ts` and writes `{ ts, event, extension, reason?,
   session_cwd, ...extra }` to `~/.pi/agent/audit/gate-events.jsonl`
   (`gateEventsFile()`, line 42). The `GateEventName` union (lines 29-33) is
   `"gate_bypass" | "review_dispatch" | "merge_gate_block" | "merge_gate_pass"`
   — a marker event would either extend the union or pass a string (the type
   is the only constraint; `appendJsonl` writes whatever string it gets).
   Import pattern used by review-enforcer:
   ```ts
   import { appendJsonl, type GateEventName } from "../shared/audit-log.js";   // review-enforcer/index.ts:7
   ```
   and wrapped for per-extension tagging:
   ```ts
   appendJsonl({ event, extension: "review-enforcer", ...extra, session_cwd: process.cwd() }, file);  // review-enforcer/index.ts:211
   ```
2. **sequence-enforcer's local auditLog()** — `~/.pi/agent/audit/enforcement.jsonl`
   (`index.ts:168-176`): `mkdirSync(dirname(...))` + `appendFileSync(...,
   JSON.stringify(entry) + "\n")`, catch → fail silently. This is the
   **closest semantic precedent**: it is a gate decision (bypass) being
   audited, and the guard's marker is exactly a gate bypass with a reason.

**Recommendation:** log marker creation through `shared/audit-log.ts`
(`appendJsonl({ event: "main_edits_marker", extension: "main-worktree-guard",
reason, session_id? }, ...)`) — it is the shared, tested facility
(`audit-log.test.ts` covers all four union events) and review-enforcer proves
the cross-directory import works from an extension `index.ts`. Sequence
enforcer's local copy is the fallback if the shared import is deemed too
heavy. The marker file itself can ALSO carry the reason + session id
(embedded-content variant, see §7), making creation self-describing even if
the audit write is unavailable.

## 6. README precedent

Only one extension ships a README today:
`extensions/slack-bridge/README.md` (repo-wide find: `./extensions/slack-bridge/README.md`, root `README.md`, `templates/.github/**/README.md`, `skills/carousel-b2b-images/templates/README.md`). The guard README would be the second extension README. Precedents it can follow:

1. **`extensions/slack-bridge/README.md`** — extension-level README: capability overview, "Zero runtime dependencies beyond Node stdlib", an **env-var table** (name / purpose / required-for), current environment status, defaults and kill switches. The guard README can mirror this with the env vars (`AGENT_ALLOW_MAIN_EDITS=1` / `ELDATO_ALLOW_MAIN_EDITS=1`) plus the new marker section.
2. **`docs/research/2026-08-07-multi-agent-git-coordination.md`** — the guard's own WHY text cites the hub discipline from this doc; it is the reference for the shared-hub policy the marker temporarily suspends.
3. **`skills/using-git-worktrees/SKILL.md`** — the operational counterpart; the skill currently has NO mention of `AGENT_ALLOW_MAIN_EDITS` or the guard escape hatch (grep: only the shared-checkout policy at lines 25-27). The I3 doc deliverable (one `touch` command, why it expires, parallel-session behavior) needs a home in BOTH the new README and this skill.

## 7. TTL semantics — mtime vs embedded timestamp

**mtime-based** (`Date.now() - statSync(marker).mtimeMs > TTL_MS`):

- Pros: zero-content reads (metadata only — cheapest possible per-tool_call
  check); `touch` naturally refreshes the window (matches the "one touch
  command" I3 claim with no file writes); nothing to parse or corrupt; direct
  precedent (`loop-enforcer` MANIFEST_MTIME_WINDOW_MS).
- Cons: ANY process as the same user can extend the window by touching again
  — this is exactly the parallel-session leak from align condition 1, and it
  cannot be detected from mtime alone; `touch -d` can forge mtime.

**embedded timestamp** (file content holds `{ ts, reason, session_id }`):

- Pros: the marker is self-describing — carries the **reason** (I2 audit
  requirement) and a **creating session id** (the only mechanism that can
  satisfy align condition 1's session-scoping option, since the guard can
  read `ctx.sessionManager.getSessionId()` per loop-enforcer/index.ts:53-54);
  authoritative timestamp that survives mtime forgeries; content can be
  validated (JSON parse).
- Cons: refresh requires a content write (no bare `touch`); parse-failure
  handling needed (unparseable marker should → block, fail-safe); slightly
  heavier per-call read (readFileSync of a tiny file — still negligible).

**Hybrid (recommended direction):** mtime as the TTL clock (cheap re-read,
touch-refreshable, loop-enforcer precedent) PLUS an embedded line/content
carrying `session_id` + `reason` for scope/audit. The per-tool_call re-read
cost is one `statSync` + one small `readFileSync` — both trivial for a
single-user-state file and both consistent with existing extension patterns
(slack-bridge reads its owner-lock every poll; loop-enforcer stats manifest
files in hot paths). Whatever the choice, the Scope gate must pin: (a) TTL
constant value + env-overridability, (b) session-scoped vs
machine-wide-within-TTL (align condition 1), (c) refresh semantics
(touch-only vs rewrite).

**fs access:** index.ts already imports `realpathSync, existsSync` from
`node:fs` (line 24) — adding `statSync`/`readFileSync` is a one-line change
to an existing import; classify-git.mjs already imports `existsSync` (line 5)
and loop-enforcer shows the full `readFileSync, writeFileSync, existsSync,
statSync, unlinkSync` import set is the fleet norm (loop-enforcer/index.ts:26).

---

## Implications for Scope

- **Parallel-session leakage (align condition 1) is a design fork, not a doc
  fix.** A user-level file in `~/.pi/agent/` is machine-global: a parallel
  session on the same user/host within the TTL would also pass. Options:
  session-scoped marker (embed `session_id`, guard matches
  `ctx.sessionManager.getSessionId()` — precedent at
  loop-enforcer/index.ts:53-54) OR explicit documented acceptance of
  "machine-wide within TTL, creation is deliberate + audit-logged". The
  issue's I3 wording "never applies to parallel sessions automatically" must
  be corrected either way. If session-scoping wins, the embedded-content
  variant of §7 is required (mtime alone cannot carry a session id).
- **README deliverable (align condition 2):** create
  `extensions/main-worktree-guard/README.md` (only slack-bridge has one
  today) AND add the marker section to `skills/using-git-worktrees/SKILL.md`
  (currently has zero escape-hatch documentation — grep confirmed). Drift
  guard: the "one touch command / why it expires / parallel-session behavior"
  claims are untested text — either repo-convention source assertions or a
  manual verification checklist item in the README.
- **TTL semantics + stale-marker tests (align condition 3):** T1 must include
  `marker present+valid → allow`, `absent → block`, `expired → block`
  (stale-mtime fixture proves the per-tool_call re-read is not cached),
  `re-touch → allow` (refresh), and path-guard cases (marker path must
  resolve exactly to `~/.pi/agent/.allow-main-edits` — traversal/symlink
  guarded; note the write/edit path logic already treats `~/.pi/...` as
  "outside project" per test.mjs:119, so a symlinked marker elsewhere must be
  rejected). Marker-logic tests use the pure-function harness (fake
  `fs.Stats`-shaped objects, `expectBool`) — no tmp-file plumbing.
- **Marker logic home:** classify-git.mjs, as pure dependency-injected
  functions (`isAllowMarkerActive(stats, nowMs, ttlMs)` etc.) following the
  `isAgentInfraRepo(cwd, env)` precedent; fail-safe default `false` (block)
  under the existing lazy-import degradation contract (index.ts:35-47).
  index.ts keeps only the per-tool_call orchestration beside `_isAllowMainEdits()`
  (line 95) — no new architecture.
- **Audit logging:** marker creation logs through `shared/audit-log.ts`
  `appendJsonl` (extension event, `reason`, `session_id`) — review-enforcer
  proves the cross-directory import; GateEventName union extended or string
  passthrough. Fail-silent contract preserved.
- **Scope boundary (align challenge 2):** the marker fixes the
  guard-blocked class, NOT the hung-process class (a hung session cannot
  issue any tool call). The 29h incident's primary failure mode belongs to
  #203 / process supervision — the README/skill docs must say so.
