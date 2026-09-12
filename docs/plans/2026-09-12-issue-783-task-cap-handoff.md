---
title: "Task-tool cap: recoverable handoff Implementation Plan (#783)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-12
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, builtin-tools, issue-783, task-tool, hard-cap, dispatch-record, task-sessions
---

# Task-tool cap: recoverable handoff Implementation Plan — **rev 10**

<!-- research-path: skip -->

**Issue:** daniel-ospina/agent-infra#783 · **Scope artifact:**
`docs/scoping/2026-09-12-issue-783-census/SCOPE-ARTIFACT.md` (rev 10, problem-verify CLEAN)
· **Complexity:** standard · **Level:** task · **Team:** organisation-design-team
· **Branch:** `fix/783-task-cap-handoff` · **Worktree:** `.worktrees/fix/783-task-cap-handoff`

`<!-- writing-plans: v2 standard -->`

---

## Plan revision log

| Rev | Trigger | What changed |
|---|---|---|
| 1 | initial draft | 6 tasks; `DEFAULT_TOOL_STALL_MS` lowered in place; hand-rolled git probe |
| 2 | review c1 (6 P0) | task-local stall constant; backstop pinned; session semantics corrected; unified composer; durable record; retention wired |
| 3 | review c2 (6 P0) | payload composes synchronously; secret denylist; `headSha` named; record write-site moved; Task 7 wired; reaper test |
| 4 | review c3 (3 P0 / ~17 P1) | **All line citations re-pinned**; **auto-commit restructured** into a detached worker; **Task 5 root cause corrected**; prune liveness; detached-HEAD; CI wiring |
| 5 | review c4 (3 P0 / ~7 P1) | **Task 6 given a trigger** (rev 4's worker had *none* — a `pending` row was never consumed), a **`git update-ref`** (rev 4's `commit-tree` left a dangling, GC-able object), and a **persisted spawn-time path list** (rev 4's staging set was unobtainable out-of-process). **Task 1 finally passes `--session-dir`** (rev 4 replaced `--no-session` but never redirected the dir, so its own acceptance path was unreachable and transcripts landed in the interactive `/resume` dir). **Census rendering fixed to `name=value`** — `census.py:121` matches `branch=`, and rev 4's acceptance said `branch: null`, which would have pinned `git_state=0` forever. Census `ROOT` updated for Task 1's relocation. `appendLedger` wrapped to honour the `{ok,error}` contract; writer env-gated so tests stop writing the operator's real ledger. `attempt` threaded; shared `.ts` test glob de-duplicated; 4 citation repins. *(Two citations were carried from cycle-4 reviewers and caught on independent re-check: the census probe is `:121`, not `:126`, and `ROOT` is `/Users/danielospina/…`, not `/Users/pi/…`.)* |
| 6 | **operator decision (in-session, 2026-09-12)** | **Task 6 (opt-in WIP commit) carved out to #840.** It was off by default yet produced the majority of this plan's P0s across cycles 3–4, and its remaining obligations (trigger, ref update, spawn-time snapshot, isolated index, reclaimer) are a subsystem, not a task. #783 now ships fixes 1–4. This is a deliberate, operator-approved narrowing of the scope artifact's fix 5; the scope artifact's fix-5 row stands as the record of what was originally scoped, and #840 carries the six accumulated failure modes forward |
| 8 | review c6 (1 P0 / ~6 P1) | **A P0 that would have silently broken retryability:** a fresh `--session-id` makes pi print `Warning: No project session found with id '<uuid>'…` on **stderr** (`main.js:338-344`), which `builtin-tools` counts as real output (`hasOutput=true`) — so `resolveUndefined = !hasOutput` would be permanently false, `retry()` would stop retrying, and the `!hasOutput` arms at `:2528`/`:2621`/`:2841` (three of Task 4's four write sites) would be **dead**. Now filtered as known-noise in `ingestHeartbeatChunk` with a pinning test. Also: Task 2 no longer invents a nonexistent `tick()`/`RepoState` (it specifies a per-dispatch `let repoState` filled once at spawn — the invented form would have put `execFileSync` on the 10 s heartbeat); the record writer's gate is **named and defaults ON** (`DISPATCH_LEDGER` — the "like the usage ledger" phrasing meant off-by-default, which would have made indicator 3 false on the shipped config); `doResolve`'s table gains the **backstop hasOutput arm `:2848`** and moves `:2632` to its own `failed` row; `ctx` now carries per-killer headline/delimiters/slice sizes (the four killers are **not** textually uniform); census.py + selftest added to Task 3's Files |
| 9 | review c7 (0 P0 / 0 P1 / 8 P2) | **Converged on substance** — the first cycle in eight with **zero P0 and zero P1**. The 8 P2s were citation hygiene only (Surface-Map heartbeat settle `:2787`→`:2808`; `execFileSync`→`execSync`; `:2794-2800`→`:2788-2795`; `:1996-1999`→`:1993-1995`; `spawnSubAgent` `:2279`→`:2283`) plus the Task 4 Files list, all fixed here |
| 10 | (this revision) | **Plan declared verified.** Substance clean at cycle 8; all P2s closed. One caveat the verifier recorded: `tick` **does** exist at `repo-freshness.ts:492` and `task-heartbeat.ts:388`, so Task 2's "there is no `tick()`" holds **within `builtin-tools/index.ts`** — its stated scope — not repo-wide |

---

### Pattern Research

**Skipped — zero third-party dependencies.** Only repo-local modules plus the installed
`pi` CLI's existing flags. The one external contract (`pi --session-id` / `--session-dir`)
was verified against the installed build.

### Integration Surface Map

| # | Surface | Existing code (verified c3) | Layer | Test layer |
|---|---|---|---|---|
| 1 | `task` spawn arg vectors | `:3440` (`buildArgs`), `:3530` (`fbArgs`) | standard | integration (fake `pi` + one real-CLI) |
| 2 | cap timer + kill | `:2522-2540` (settle `:2532`, `text:` `:2535`, no-output `:2528`) | complex | integration |
| 3 | exit-path cut | `:2604-2629` (`undefined` at `:2621`) | complex | integration |
| 4 | heartbeat | `:2785-2812` (no-output `:2781`, settle `:2808`) | standard | unit |
| 5 | backstop | `:2826-2852` (no-output `:2842`) | standard | unit |
| 6 | tool-stall clause 1 | `heartbeatKillDecision:2151-2157`; `getToolStallMs()` `:1503`; `hbThresholds.toolStallMs` `:2548`; constant `:1482` | complex | unit |
| 7 | tool-stall clauses 2/3/4 | `:2160-2163`, `:2166-2174` / `:2177-2193` / `:2196-2229` | — | unchanged |
| 8 | terminal result | `:3555`, `:3562`, `:3570` (returns) | standard | integration |
| 9 | tool schema (`task`) | `:3200-3234` (registered), `:3235` (`execute`) | standard | unit |
| 10 | `repo-freshness` readers | exported: `currentBranch:109`, `repoClean:143`, `mergeOrRebaseInProgress:280`, `indexLocked:287`; `tryGit` **private** `:83` | standard | unit |
| 11 | dispatch ledger | `shared/provider-failover.ts:1321` `appendLedger`; `~/.pi/agent/audit/provider-failover.jsonl`; key `dispatchId = TASK_HEARTBEAT_NONCE` (minted `index.ts:3438`) | standard | unit |
| 12 | CI suite enumeration | `.github/workflows/ci-main.yml:123-158` (explicit) **plus a `:69` glob over `extensions/shared/*.test.ts`** — new shared tests are auto-collected; adding them explicitly double-runs them | — | shell |
| 13 | launchd farm | `templates/launchd/*.plist` (5), `install-launchd.sh:142` (`verify_targets`)/`:366`, `install-launchd.test.sh:105`,`:207`, `setup.sh:289` | standard | shell test |
| 14 | reaper | `scripts/pi-reap-idle.sh` — `:165` is the `tty ~ /^ttys/` gate; `:157` is a pid sanity check (cannot see tty-less task children) | — | shell test |
| 15 | census instrument (live reader) | `docs/scoping/…/census.py:52,114,119,136,133,163` | — | must stay green |
| 16 | `subagent` tool (must NOT change) | `extensions/subagent/index.ts:21,25,316` — imports the constant but reads it via its **own** local margin | — | parity test |
| 17 | #796 ledger (async) | unbuilt; joins on `dispatchId` | — | declared contract |

### Bug Pattern Flags

- **Unreachable guard:** `DEFAULT_TOOL_STALL_MS` (`:1482`) == `DEFAULT_HARD_CAP_MS` (`:1567`). *(The scope's narrowed form is correct: `effToolAge = toolAgeMaxMs + markerAge` (`:2136`) can exceed the cap in the tail; `turnActive=false` uses `min(L,T)` (`:2156`). It just cannot fire **meaningfully earlier**.)*
- **Last-writer-loses:** `doResolve` is settle-once (`:2419`). Rev 3's "await the commit, then resolve" would have lost the payload. Rev 4 never awaits before settle.
- **Shared mutable index across concurrent children** — class: *cross-talk*. Rev 3's `git add` + bare `git commit` would commit a sibling child's files.
- **Append-only log used as a mutable record** — class: *write-once can't be updated*. Rev 3 required a sha in a row already appended.
- **Path-enumeration leak:** `git add -u` in the parent's checkout stages a tracked `.env`.

### Integration Checklist Notes

- `DEFAULT_TOOL_STALL_MS` is **frozen**; Task 5 adds a task-local constant and changes no export.
- `getTaskBackstopMs()` (`:1620`) stays derived from the frozen constant; the decoupling from the task's *effective* bound is deliberate — its docstring (`:1601`) is updated to say so.
- `spawnSubAgent` forces `cwd: process.cwd()` (`:2306`) and the `task` schema has no `cwd`.
- **Session context:** `execute` is `async execute(_toolCallId, params, signal)` (`:3235`) — **no `ctx`**. pi supplies it as the 5th arg (`dist/core/extensions/types.d.ts:372`); `ctx.sessionManager.getSessionId()`/`.getSessionDir()` is the only sound source. `process.env.PI_SESSION_ID` is **unsafe** — pi sets it only in *bash-tool* child envs (`dist/core/tools/bash.js:121-128`), so an extension reading it inherits an **ancestor** session id (the misattribution channel `extensions/sequence-enforcer/index.ts:365-366` closes). Task 1 adds `ctx` to the signature.

---

### Journey Test Map

| Journey | Steps | Test |
|---|---|---|
| J1 **Recover a capped child, incl. detached HEAD** | cap → payload names branch/`headSha`/dirty/transcript/record → resume. Detached variant asserts `branch=null` **and `worktree=<cwd>` as the recovery key** (`worktree` is the payload field; `cwd` is the record-row key) | `extensions/builtin-tools/task-cap-handoff.integration.test.ts` |
| J2 **A silent child leaves a countable row** (cap, heartbeat, backstop variants; 2-attempt retry ⇒ 2 rows, one `dispatchId`) | `extensions/shared/dispatch-record.test.ts` |
| J3 **A stalled tool alarms while the dispatch stays recoverable** | `builtin-tools.test.ts` |
| J4 **`subagent` unchanged** | `extensions/subagent/subagent-parity.test.ts` |

### Failure Modes

| Mode | Trigger | Handling |
|---|---|---|
| Git missing / not a repo | any probe | `tryGit` → `null`; fields render `unknown`; never throws into the tick |
| Record unwritable | full disk | writer returns `{ok:false}`; payload prints `record: "failed: <err>"` — never a dangling path |
| Prune vs live child | hourly job | `ps`-derived liveness match on `--session-id`; re-probe before each unlink; files only; fail-closed |
| Session id invalid | bad grammar | rejected pre-spawn (`assertValidSessionId`; `session-manager.js:15`) |
| Detached HEAD | child on no branch | `branch=null`; `cwd` is the recovery key |
| Absent identity fields | old/mixed-version row | reader tolerates missing fields (no throw) |

---

## Task 1: Durable child session per spawn (fix 1)

**Files:** `extensions/builtin-tools/index.ts` (`:3440`, `:3530`, `:1373`, `:3235`, `:3200-3234`),
new `extensions/shared/session-id.ts`, `extensions/provider-exhaustion.ts:189`,
`scripts/time-to-first-activity-sweep.ts:16,33-36`, + tests.

**Depends on:** —

Replace `--no-session` at **both** `task` spawn sites (`:3440` `buildArgs`, `:3530` `fbArgs`) with a
**fresh `--session-id <uuid>`** per spawn, **and pass `--session-dir <root>/<childId>` in both
arg vectors**. Rev 4 changed only the id and never redirected the directory, so `getSessionDir()`
(`main.js:532-534` falls back to `settingsManager.getSessionDir()`, default depth-1) wrote the
transcripts into the **interactive** session dir — its own acceptance path was unreachable, the
resume-picker pollution the scope forbids (`SCOPE-ARTIFACT.md:223`) would have occurred, and
Task 6 would have pruned an empty tree.

**The id must be minted inside an argument *function*, not a `const`.** `buildArgs` (`:3439`) is
called per attempt inside `retry(() => spawnLeg(dispatchLeg))` (`:3443`), so the primary leg
mints fresh — but **`fbArgs` is a `const` built once at `:3530`** and reused by
`retry(() => spawnSubAgent(…, fbArgs, …))` (`:3531`) with `maxAttempts: 3` (`:3369`). pi's
`--session-id` path opens an existing session by exact id (`main.js:338-341`), so fallback
attempt 2 would **append to attempt 1's transcript** — self-defeating the duplicate-id rationale
below and making Task 4's per-attempt rows indistinguishable on that leg. Both sites therefore
mint per call. `--session-dir` is a real pi flag (`cli/args.js:88`).
`PI_CODING_AGENT_SESSION_DIR` (`dist/config.js:407`) is an equivalent — and it must be
**added** to `subAgentEnv`; it is not there today (`:2293-2295` is the `TASK_HEARTBEAT_NONCE`
block).

**Session root is env-overridable:** `TASK_SESSION_ROOT` (default `~/.pi/agent/task-sessions/`),
so tests and CI point at a tmpdir instead of accumulating real child session dirs under the
operator's home.

**A new failure mode the root introduces:** with `--no-session`, pi wrote nothing and a
read-only or full `$HOME` was harmless. A persisted session makes pi call
`mkdirSync(sessionDir, {recursive:true})` at startup (`session-manager.js:599-605`), so a
read-only home, a full disk, or a permissions error now crashes the child (or rejects the tool)
where the old dispatch succeeded. The root is therefore created **defensively before the first
spawn**, and on failure the dispatch **degrades to `--no-session`** (works, no transcript) rather
than failing — with a distinct, **non-retryable** error class surfaced in the payload, since
`shared/retry.ts:88-91` treats a `failed` composition as success for retry purposes.

**Remove** `--no-session` — do not supplement it:
it short-circuits into an in-memory session at `main.js:279-281`, so the id is accepted and no
file is ever written. A fresh id (not the parent's) is required because pi's duplicate-id path
(`main.js:338-345`) **silently re-opens and appends**.

**Session root:** the scope's static root `~/.pi/agent/task-sessions/`, created
`mkdirSync(root, {recursive:true, mode:0o700})` **followed by an explicit `chmodSync(root,
0o700)`** — `mkdirSync`'s mode is a no-op on a directory that already exists from an earlier
run under a 0755 umask, so the mode assertion would otherwise pass only on a fresh box while
transcripts (echoed commands + model output) stayed world-readable. **Keyed by the minted child id,
not by the parent session id** — a parent id may be absent (ephemeral/`--no-session` orchestrator),
which would collapse every such parent into one shared directory. Depth ≥2 also keeps the files
out of the global resume picker (`session-manager.js:1326-1340` iterates one level).

**Context source:** add `ctx` to the tool's `execute` (`:3235`) and read
`ctx.sessionManager.getSessionId()` / `.getSessionDir()`. `PI_SESSION_ID` is **not** a
substitute (ancestor-id misattribution — see Integration Checklist Notes).

**⚠️ The fresh-id warning must be filtered, or Task 1 silently breaks retryability.** With a
`--session-id` that does not yet exist, pi writes
`Warning: No project session found with id '<uuid>'; creating a new session with that id.` to
**stderr** (`main.js:338-344`). `builtin-tools` classifies non-marker stderr as real output
(`onRealOutput()` → `hasOutput = true`, `:1993-1995` / `:2379-2380`), and the whole retryability
contract is `resolveUndefined = !hasOutput` (`:2093`, `:2117`). So the warning would make
`hasOutput` **permanently true**: `retry()` stops retrying hung children, and the `!hasOutput`
arms at `:2528`, `:2621`, `:2841` become **dead** — which are three of Task 4's four record write
sites. **Fix:** add this warning to the known-noise filter in `ingestHeartbeatChunk` *before*
`onRealOutput()`, and pin it with a test asserting `hasOutput === false` for a child whose only
stderr is this warning. (No existing test catches it: the harnesses spawn with their own args and
a fake `pi` — `cut-resume.integration.test.ts:297`, `:368` — so the real CLI's warning never
appears.)

**Id grammar:** `assertValidSessionId` is not re-exported from the package index
(`dist/index.d.ts:19` exports `SessionManager` only), so `session-id.ts` re-implements the
grammar. Invalid id → **fail loudly before spawn**; otherwise `validateSessionIdFlags`
`process.exit(1)`s (`main.js:256`, after the `assertValidSessionId` throw at `:251`), which surfaces as `failed`, which `shared/retry.ts:88-91`
reads as success.

**Stale premises refreshed in the same task:** `provider-exhaustion.ts:189` and
`scripts/time-to-first-activity-sweep.ts:16,33-36` both assert "children run `--no-session`".
Neither is functionally load-bearing (`isTaskSubAgent` keys on `TASK_HEARTBEAT`+`PI_MODE`), but
both comments become false. The sweep's own KNOWN LIMITATION (needs a verified channel for the
child session id) is *unblocked* by Task 4's `childSessionId` — noted in Out of Scope.

**Acceptance:**
- **One real-CLI dispatch** (not a fabricated file) leaves a `.jsonl` at
  `$TASK_SESSION_ROOT/<childId>/<fileTimestamp>_<childId>.jsonl`
  (`session-manager.js:667`); the root is mode 0700 **even when it pre-existed at 0755**.
- `--no-session` appears in **neither** arg vector (`:3440`, `:3530`), and **both** carry
  `--session-dir`.
- **N retry attempts produce N distinct session ids and N transcript files on *both* legs**
  (the `fbArgs`-as-`const` defect above).
- A malformed id is rejected before spawn.

## Task 2: The **parent** reports where the child ran (fix 2)

**Files:** `extensions/builtin-tools/index.ts` (heartbeat `:2785-2812`),
`extensions/repo-freshness.ts`, `extensions/session-checks.ts:150`,
`extensions/builtin-tools/builtin-tools.test.ts`.

**Depends on:** —

Add `branch`, `headSha`, `dirty`, `worktree` (the child's `cwd`), `transcriptPath`,
`recordPath` to the heartbeat **and** to all four abnormal-exit payloads (Task 3).

**Reuse, do not hand-roll** (c3 verified these exports exist):

| Field | Reader |
|---|---|
| `branch` | `currentBranch(cwd)` (`repo-freshness.ts:109`) — returns `null` on detached HEAD |
| `dirty` | `!repoClean(cwd)` (`:143`) |
| `headSha` | **new** `headSha(cwd)` — the only genuinely missing reader; `syncState:122` already runs `rev-parse HEAD` through private `tryGit` (`:83`) |
| async probe | extend the existing `execFileAsync` (`extensions/session-checks.ts:150`) with an optional `signal` — do **not** add a second promisified `execFile` wrapper |

`headSha`'s new home is `repo-freshness.ts`; `verification-gate/index.ts:876 localHeadSha` and
`auto-sync.ts:50` are noted as consolidation targets (out of scope, recorded).

**Off the tick path — and there is no `tick()` today.** `builtin-tools/index.ts` does not import
`repo-freshness` at all, `RepoState` exists nowhere in the repo, and the only repo-state readers
(`currentBranch:109`, `repoClean:143`, the new `headSha`) are **synchronous** (`tryGit:83` →
`execSync`). An implementer following a vague "cached, refreshed by a detached call" would put
`execSync` on the 10 s heartbeat interval (`:2696`), blocking the parent's event loop every tick. Task 2 therefore defines, concretely, a per-dispatch `let repoState: RepoState | null`
populated **once by `asyncRepoState` at spawn** and read at settle; the heartbeat reads whatever is
cached (initially `null` → fields render `unknown`) and **never** invokes git itself.

**`RepoState` also carries the uncommitted-path list.** `dirty` alone is a **boolean**
(`repo-freshness.ts:143`), which is not enough for the handoff payload: the parent needs to know
*which* files are uncommitted, not just that some are. `RepoState` therefore includes
`paths: string[]` = `git status --porcelain -z` (the `-z` form is already the codebase's
convention, `repo-freshness.ts:249`), captured at spawn and reported as `dirtyPaths=<n>` in the
`Alive state:` line. *(A spawn-vs-settle delta was needed only by the carved-out commit feature
(#840), which owns that requirement.)*

**Rendering — `name=value`, NOT `name: value`.** `census.py:121` counts git state with
`re.search(r"(^|\s)(branch|headSha|worktree|dirty)=", v)`. Rendering `branch: null` (rev 4's
acceptance text) would leave `git_field_state` at **0 on every new payload forever** while the census
self-test stayed green. Fields render space-separated, `=`-form, in the `Alive state:` line:
`branch=<v> headSha=<v> worktree=<v> dirty=<v>`. *(Note: the scope's current `git_field_state`
is 0 on the historical corpus, so this field's first non-zero value will be a new payload —
which is also the assertion that proves the fix landed.)*

**Acceptance:** for a dirty worktree-repo, payload fields match `git` run by hand; **detached
HEAD renders `branch=null` with `worktree=<cwd>` present**; `RepoState.paths` is non-empty for a
dirty tree and is persisted; `builtin-tools.test.ts:1845` and `:1937` (the `Alive state:`
single-line regexes) stay green — **the new fields must not introduce a newline**.

## Task 3: One composer, four killers (fix 3) — **DEPENDS ON 1, 2**

**Files:** `extensions/builtin-tools/index.ts` (`:2522-2540`, `:2604-2629`, `:2785-2812`,
`:2826-2852`, `:3555-3578`), `extensions/builtin-tools/builtin-tools.test.ts`,
`extensions/builtin-tools/cut-resume.integration.test.ts`,
`extensions/builtin-tools/task-cap-handoff.integration.test.ts`,
`docs/scoping/2026-09-12-issue-783-census/census.py`,
`docs/scoping/2026-09-12-issue-783-census/census.selftest.sh`.

Route all four killers — cap (`:2522-2540`), exit-cut (`:2604-2629`), heartbeat
(`:2785-2812`), backstop (`:2826-2852`) — through one `composeAbnormalExit(reason, ctx)`.

**`ctx` must carry the per-killer presentation, because the four killers are not textually
uniform.** The cap body uses `--- last stderr ---` with a 2000-char stderr slice and a 500-char
stdout slice (`:2535`); the exit-cut body uses a bare `--- stderr ---` with a 2000-char **stdout**
slice (`:2615`, `:2618`); and the heartbeat killer has **six distinct headlines** keyed by
`decision.reason` (`:2788-2795`). So `reason` alone cannot reproduce any of them. `ctx` carries
`{ headline, delimiters, stderrSlice, stdoutSlice }` per killer, and **only the cap form is
census-frozen** — the invariant below binds that arm, not the other three.

**Invariant — the census instrument is a live reader.** `census.py` gates on
`PREFIX = "⚠️ Sub-agent exceeded the task hard cap"` (`:52`, `:114`), splits on
`"Alive state:"` / `"--- last stderr ---"` / `"--- last stdout ---"` (`:119,136,133`), parses
`hard cap \((\d+)s\)` (`:163`), and counts git state via
`re.search(r"(^|\s)(branch|headSha|worktree|dirty)=", v)` (**`:121`** — verified directly;
cycle 4 cited `:126`, which is `saw_true += 1`) — the **`=` form**. Therefore:
the `hard-cap` headline, the single-line `Alive state: …` prefix, both delimiters, the `(Ns)`
format, **and the `name=value` rendering** are unchanged; handoff fields are appended
**after `trace=[…]`**.

**The instrument must follow the transcripts — ADDITIVELY, never by repointing `ROOT`.**
The cap payload is composed by the **parent** `task` tool and stored in the **parent's**
`~/.pi/agent/sessions` transcript — that is why all 144 corpus payloads are parent-session hits.
`census.py:48` sets `ROOT = "/Users/danielospina/.pi/agent/sessions"` and globs it (`:96`).
Task 1 relocates only the *child's* transcript.

**So replacing `ROOT` with `task-sessions/` would find 0 payloads and make `--assert-nonzero`
FAIL by construction** — rev 6 said "update `ROOT`", which was wrong. Task 3 instead makes the
scan **additive**, which requires editing the instrument: `census.py:49-50` currently parses
`--root` as a single value (`ROOT = sys.argv[sys.argv.index("--root") + 1]`), so "repeatable
`--root`" is a real code change to `census.py`, not a flag-only tweak. `sessions` stays the
default; the child transcript root is an extra root. The post-date assertion is satisfied by a
**scripted fixture** under `--root`, not by waiting for a real 6-hour capped run (nothing
schedules one).

Task 3 acceptance includes
`python3 docs/scoping/2026-09-12-issue-783-census/census.py --assert-nonzero` on the default
root, plus the fixture-root variant. `census.py` and `census.selftest.sh` are added to Task 3's
**Files** (rev 6 ran the instrument without listing it).

**Preserved source-text pins** (currently asserted, must survive): `builtin-tools.test.ts:2406`
(`"!hasOutput\n            ? undefined"`), **`:2436`** (`reason: "hard-cap", hardCapMs:
getTaskHardCapMs()`), **`:2437`** (`no real output — retryable (#271)`) — *(rev 4 had these two
swapped; verified in cycle 4)* — and the per-killer
`details.reason` values asserted in `cut-resume.integration.test.ts:339,356,395,413,485,514,528,546`
plus `exitCode` (`:357,414`). "Identical field sets" means identical **field sets**, not
identical `reason` values.

`circuit_open` (`:3555-3560`) is in scope, gated on a real prior spawn; the pre-spawn path is
asserted unchanged.

**The composer must not break the `reason:` object literals.** `builtin-tools.test.ts` asserts by
`source.includes` that the call sites still contain `reason: "cut", exitCode: code` (`:2405`),
`reason: "cut", backstop: true` (`:2434`) and `reason: "hard-cap", hardCapMs: getTaskHardCapMs()`
(`:2436`). A `composeAbnormalExit(reason, ctx)` that builds the `details` object internally moves
those literals out of the call sites and silently reds those assertions. The composer therefore
takes the **details/ctx object** (so each killer keeps its own literal), **or** all five
`source.includes` pins are explicitly repinned to the composer's new shape. The plan does one of
these — it does not leave the pins unaccounted for.

**Acceptance:** four integration tests (one per killer) + a **detached-HEAD variant** of the cap
case asserting **`branch=null` with `worktree=<cwd>` present** (`=`-form, per Task 2 — the colon
form would keep `git_field_state` at 0 forever); census self-test + live assertion green.

## Task 4: Durable outcome record (scope fix 4)

**Files:** new `extensions/shared/dispatch-record.ts`, `extensions/builtin-tools/index.ts`,
new `extensions/shared/dispatch-record.test.ts`,
`extensions/builtin-tools/cut-resume.integration.test.ts`,
`extensions/builtin-tools/provider-failover.integration.test.ts`.

**Depends on:** Task 3.

**Write sites — all four no-payload settles.** `resolveUndefined` is a *decision field*, not a
function; the zero-output class settles on the early-return `doResolve(undefined, {sweep:true})`
calls that **never build a payload**, so a composer-only writer records nothing:

- cap, no output — `:2528`
- exit-path cut — `:2621` (the `? undefined` arm of `:2619-2624`)
- heartbeat, `decision.resolveUndefined` — `:2781`
- backstop, no output — `:2842`

plus the two payload setters (cap settle `:2532`, heartbeat **`:2808`** — rev 4 cited `:2787`, which is
`const aliveSummary = …` and is not a settle site). **Writer placement — one choke point, inside `doResolve`.** `doResolve` is the only settle-once
gate (`:2419-2420`), but `finalize` is invoked **unconditionally** from both `proc.on("exit")`
after 2 s (`:2883-2894`) and `proc.on("close")` (`:2898-2901`). So a cap kill settles row A,
then `killTreeAndEscalate()` (`:2525`) kills the tree → `close` → `finalize` →
`classifyTaskExit(null,…) = "cut"` and a **call-site** writer would emit row B for the same
attempt. Rows are append-only (`audit-log.ts:45-52` — `appendJsonl`; `appendLedger` is
`provider-failover.ts:1321-1334`), so that could never be repaired.

Writing at call sites also **misses the cut-with-output arm**: `:2619-2624` is one `doResolve`
whose `hasOutput` arm routes through the composer while only the `? undefined` arm (`:2621`) is
listed — the hasOutput cut population (the one most resembling cap payloads) would stay
uncountable, contradicting issue indicator 3.

The writer therefore lives **inside `doResolve`, immediately after `settled = true`**, taking
the reason from its caller. This covers all four no-payload settles (`:2528`, `:2621`,
`:2781`, `:2842`), both payload setters (cap `:2532`, heartbeat `:2808`), **and** the
cut-with-output arm, with exactly-once semantics by construction.

**The choke point needs an explicit abnormal/success discriminator, or it writes the wrong rows.**
`doResolve`'s signature is `(value, opts?: {keepCompletionWatchdog?, sweep?})` (`:2418`) — **it
carries no reason**, and the four abnormal sites pass only `{sweep:true}`. A writer keyed naively
off "reached `doResolve`" would emit `dispatch-outcome` rows for the **success** paths (`:2581`
sessionEnded completion, `:2604` clean exit, `:2867` abort-after-end, `:2908` spawn error) —
contradicting the acceptance "a child that exits normally writes none" — while a writer gated on a
reason it cannot obtain writes **nothing** at its own primary sites.

`doResolve`'s `opts` therefore gains a **required-on-abnormal** `reason`:

| call site | kind | reason |
|---|---|---|
| `:2528`, `:2532` | cap | `"hard-cap"` |
| `:2619` (both arms) | cut | `"cut"` |
| `:2781`, `:2808` | heartbeat | `decision.reason` |
| `:2842` | backstop | `"backstop"` |
| `:2581`, `:2604`, `:2867`, `:2908` | success / clean / spawn-error | **omitted → no row** |
| `:2632` | non-zero `failed` | `"failed"` (its own row) |
| **`:2848`** | **backstop, hasOutput arm** | `"backstop"` |

The writer fires **only when `reason` is present**. **`:2848` is easy to miss** — it is the
backstop's *payload* arm (`details: { … reason: "cut", backstop: true … }`), the twin of
`:2842`'s `!hasOutput` arm; omitting it means Task 4's own acceptance ("the backstop variant with
`TASK_BACKSTOP_MS` below the cap writes exactly one primary row") writes **nothing** whenever the
child produced output. `:2632` is likewise abnormal and gets its own reason — rev 9 listed it under
the success row, contradicting its own prose.

**Reuse the existing dispatch ledger — do not fork it.** `shared/provider-failover.ts:1321`
`appendLedger(entry, eventName, env)` already writes per-dispatch rows to
`~/.pi/agent/audit/provider-failover.jsonl` keyed by `dispatchId = TASK_HEARTBEAT_NONCE`
(minted `index.ts:3438`; documented join at `:2445-2450`; already imported at `index.ts:67`).
The outcome row is written through `appendLedger(row, "dispatch-outcome", env)` so #796 and
the failover ledger **join on the same key in the same file**. `dispatchId` semantics are
declared as that nonce.

**Two obligations `appendLedger` cannot meet as-is**, both raised in cycle 4:
1. It returns `void` and swallows every exception (`:1321-1333`), so it cannot back the
   `{ok, error}` contract — a full or unwritable ledger is indistinguishable from success and
   the payload would name a `recordPath` nothing was written to. `dispatch-record.ts` therefore
   wraps it: write, then **confirm with a stat/read-back** and return `{ok, error}`.
2b. **The gate is named and defaults ON.** Rev 9 said "env-gated the way the usage ledger is" —
   but that ledger is `TASK_USAGE_LEDGER === "1"`, i.e. **off by default**, which would make
   indicator 3 (both populations countable) false on the shipped config while the payload still
   advertised a `recordPath`. The gate is `DISPATCH_LEDGER` and **defaults on**; tests isolate by
   pointing `PI_CODING_AGENT_DIR` at a tmpdir (`agentDir()`, `provider-failover.ts:197-198`), and
   the existing real-`spawnSubAgent` suites (`cut-resume.integration.test.ts:307`,
   `provider-failover.integration.test.ts:177`) get that env so they stop appending test rows to
   the operator's real `~/.pi/agent/audit/provider-failover.jsonl`. *(Both files are added to
   Task 4's **Files**.)*
2. The writer runs at every settling site **unconditionally**, so existing real-`spawnSubAgent`
   integration tests (`cut-resume.integration.test.ts:307`) would append junk to the operator's
   real `~/.pi/agent/audit/provider-failover.jsonl`. The writer is **env-gated** the way the
   usage ledger already is, and tests point it at a tmp file.

**Row:**
```json
{"ts","event":"dispatch-outcome","extension","dispatchId","parentSessionId","childSessionId",
 "attempt","cwd","branch","headSha","dirty","dirtyPaths","reason","toolAgeMaxMs",
 "toolsInFlight","everSawTool","transcriptPath","exitCode","dispatchClass"}
```

**`attempt` must be threaded, not assumed.** Rev 4 required per-attempt rows; `retry()` does
pass an attempt (`shared/retry.ts:88` `fn(attempt)`), but the call site discards it —
`index.ts:3443` `retry(() => spawnLeg(dispatchLeg), …)` and `spawnLeg` (`:3441`) →
`spawnSubAgent` (`:2283`) take no attempt parameter, and `onRetry` (`:3373`) only logs it.
Moreover the write sites are **inside** `spawnSubAgent`, whose signature
`(model, provider, subAgentEnv, args, signal)` carries neither `attempt` nor `childSessionId`.
Task 4 therefore threads the attempt through (env or an added parameter) and specifies how the
writer obtains `childSessionId` (minted into the arg vectors at `:3440`/`:3530`). **`attempt` is
required, not optional** — contract point 2 and the checklist row both depend on it, so the
"or drop it" fallback rev 6 offered is deleted. (`spawnSubAgent` is at **`:2283`**.)

**Two contract points the c3 auditor forced:**
1. **Rows are append-only and immutable.** `appendJsonl` (`audit-log.ts:45-52`) and
   `appendLedger` (`provider-failover.ts:1321-1334`)
   have no update primitive — a written line can never be amended. This plan therefore records
   only values known **at settle**, and its acceptance is **"exactly one row per spawn attempt"**.
   A later reader that needs to *amend* a dispatch's outcome must append a follow-up row keyed by
   `dispatchId`+`childSessionId`+`attempt` (this is #840's obligation, and the reason its commit
   outcome cannot be written into the primary row).
2. **One row per spawn attempt, not per dispatch.** `retry()` respawns up to 3× (`retry.ts:84-90`,
   `fn(attempt)` at **`:88`**) and the failover loop + fallback leg add more (`:3441`, `:3530`). Every
   spawn is an independent child with a fresh session id (Task 1), so a scripted 2-attempt run
   asserts **2 rows sharing
   one `dispatchId`**, distinguished by `attempt`.

**Writability:** the writer returns `{ok, error}`; when `ok === false` (full disk, unwritable
root) the payload carries `record: "failed: <err>"` rather than a path the parent would follow
to nothing. `dispatchClass` distinguishes a builtin-task child from a reviewer/eval child.

**Acceptance:** silent child hitting the cap writes exactly one primary row (J2); the backstop
variant with `TASK_BACKSTOP_MS` below the cap writes exactly one primary row; a 2-attempt run
writes two; an unwritable root yields `record: "failed: …"` in the payload, not a path.

## Task 5: Make the alarm reachable — the constant split only (fix 4) — **DEPENDS ON 1–4**

**Files:** `extensions/builtin-tools/index.ts` (`:1482`, `:1503`, `:1620`, `:2548`),
`extensions/builtin-tools/builtin-tools.test.ts`.

**Corrected root cause.** Rev 3 asserted `toolAgeMaxMs` is monotonic and never reset. **That is
false**: it is zeroed at `turn_start` (`:1858`) and `turn_end` (`:1871`) and overwritten by each
tick (`:1888`, `case "tool_age_max_ms"`), and clause 1 already requires `st.toolsInFlight > 0`
(`:2153`). Rev 3 therefore deleted a real detector for no reason. The actual defect is the one
the **scope** states (`:88`): `DEFAULT_TOOL_STALL_MS` (`:1482`) == `DEFAULT_HARD_CAP_MS`
(`:1567`), so the bound provides no margin.

**The change:** add a task-local `DEFAULT_TASK_TOOL_STALL_MS = 7_200_000` **(2 h)**, env-overridable
as `TASK_TOOL_STALL_MS`, consumed by `getToolStallMs()` (`:1503`) and reaching clause 1 via
`hbThresholds.toolStallMs` (`:2548`).

**Why 2 h, and why the value matters more than the mechanism.** Clause 1 kills whenever
`stateFresh && st.toolsInFlight > 0 && effToolAge > bound` (`:2151-2157`), and **it deliberately has
no `!everSawRealActivity` gate** — it is the wedged-*tool* detector, and a child keeps its markers
fresh while a tool runs. So the bound must exceed any legitimate single-tool duration, or it kills
healthy children and (per the scope's own safety argument) destroys in-flight work. 2 h is chosen
against this repo's real durations: ~20 min for a cold `npm ci`, ~40 min for the longest full
`npx tsx` suite — 3× headroom — while still firing **4 h before** the 6 h cap, which is the whole
point. The mechanism (task-local constant, frozen export) is what makes it revertible; the value is
what makes it safe. A future bound below ~1 h should be treated as a behaviour change requiring its
own justification, not a tuning tweak. The exported
`DEFAULT_TOOL_STALL_MS` is **unchanged** — `extensions/subagent/index.ts:21` imports it and
`:316` reads it through its **own** local `DEFAULT_BACKSTOP_MARGIN_MS` (`:25`); neither
`getToolStallMs()` nor the composers are imported by `subagent/` (c3 verified: the only other
builtin-tools importer is `extensions/subagent/index.test.ts:40`). The backstop
(`getTaskBackstopMs()` `:1620`, = frozen constant + 30 min) therefore stays **above** the cap;
its docstring (`:1601`) is updated to record that it is deliberately no longer
"task-stall + margin".

**No `!everSawRealActivity` gate. No new kill semantics.** There is exactly **one** parent-visible
output channel (settle-once, `:2419`), so an alarm cannot "fire without killing the dispatch" —
a log-only line is the only implementable non-settling alarm and is not requested. The bound is
the whole change.

**Acceptance:** `builtin-tools.test.ts:1036` updated; `:2123`, `:2439` green unchanged;
`:1461` (E9) still green; `subagent` parity green (Task 7).

---

### ⚠️ Carved out of this plan: the opt-in WIP commit (scope fix 5) → **#840**

Rev 5's Task 6 is **deliberately removed** by operator decision (2026-09-12). It was
**off by default**, yet produced the majority of this plan's P0 findings across review cycles
3–4 — a shared git index across concurrent children, a commit worker with **no trigger**, and a
`commit-tree` with no ref update (a dangling, GC-prunable object). Its remaining obligations
(trigger + stale-row reclaimer, ref compare-and-swap, spawn-time path snapshot, isolated index,
`--no-verify` policy) are a subsystem, not a task. It is filed as **#840**, which carries all
six accumulated failure modes forward. #783 ships fixes 1–4.

The scope artifact records the same decision as a dated addendum; its original fix-5 rows are
left intact as the record of what was scoped.

---

## Task 6: Retention, wired — and safe against live children

**Files:** new `scripts/pi-task-session-prune.sh`,
new `templates/launchd/com.eldato.pi-task-session-prune.plist`,
`scripts/install-launchd.sh`, `scripts/install-launchd.test.sh` (`:105` = the fake-home seed loop, `:207` = the count `"5"`),
`pi-bootstrap/setup.sh` (`:289`).

**Depends on:** Task 1 (the session layout).

**All four farm sites are required, and the plist is the one rev 3 missed.**
`install-launchd.sh` installs by iterating `"$TEMPLATES_DIR"/*.plist` (`:366`) and hard-fails on
an unresolvable target (`:142` `verify_targets` → `:180-184` → `exit 1`), so the job **cannot exist** without a
new template. With it: fake-home seed loop (`install-launchd.test.sh:105` — this is **not** a
separate farmed list; the test enumerates via rendered-plist assertions `:174-198` plus the
count), count assertion (`:207`, **5 → 6**), `fleet_srcs` (`setup.sh:289`).
Script name `pi-task-session-prune.sh` matches the scope.

**Liveness — the part rev 3 got wrong.** There is **no pid in a session filename**, and the
reaper's proof is unusable here: `pi-reap-idle.sh:165` gates candidates on
`tty ~ /^ttys/`, and task children are spawned `detached:true` with
`stdio:["ignore","pipe","pipe"]` (`:2306` area) → **no tty, never a candidate**. A session
file's mtime is also buffered (materialises on append), so a child in a long tool call can hold
a stale mtime for hours. The prune therefore:

1. derives liveness from `ps -axo pid=,command=` matching `--session-id <uuid>` /
   `--session-dir <path>` — the only per-child identity that exists after Task 1;
2. **fails closed** if the probe errors (never delete on an unknown);
3. **deletes files only, never the per-parent directory** (a sibling child may be starting), then
   `rmdir`s the per-child directory **only when it is empty and the child is not live** — rev 4
   left every emptied directory behind, converting a file leak into an unbounded inode leak at
   24–1,410 new dirs/day;
4. **re-probes immediately before each `unlink`** (TOCTOU).

**Dry-run by default** (`TASK_SESSION_PRUNE_DRY_RUN=1` in the shipped plist), per the scope.
Arming is a separate, manual, **owned** step: Task 7.4's `AGENTS.md` note names the
organisation-design-team on-call operator as the owner and requires a dated trigger for arming,
since otherwise the 7-day/2 GB bounds never bind and nobody notices.

**Arithmetic, corrected.** Rev 3 wrote "24–1,410 dispatches/day ≈ 2–3 GB/day ⇒ 7 days ≈ 15–18 GB".
24 × 2.5 MB ≈ 60 MB/day; the 2–3 GB/day figure is the scope's **recent high end**. Honest range:
**≈0.06–3.5 GB/day**, so 7 days ≈ 0.4–24 GB. The enforceable rule is **age (7 days) or size
(2 GB), whichever binds first**, evicting oldest-non-live first; the steady state is set by the
bounds, not by the age floor. Bounds are env-tunable: `TASK_SESSION_MAX_AGE_DAYS` (7),
`TASK_SESSION_MAX_BYTES` (2 GB).

**Owner:** the **organisation-design-team operator on call for agent-infra** (recorded here and
in the **Task 7.4** `AGENTS.md` contract note).

**Acceptance:** dry-run on a fixture evicts exactly the expected set; a session whose `ps` line
matches is **not** deleted; the probe is fail-closed when `ps` is unavailable; the parent dir is
never removed; farmed count asserts 6.

## Task 7: Regression sweep, CI wiring, reaper/prune interaction, contract note

**Files:** new `extensions/subagent/subagent-parity.test.ts`, new
`scripts/pi-task-session-prune.test.sh`, `.github/workflows/ci-main.yml` (`:123-158`),
`.github/workflows/ci.yml` (`:104-152`), `AGENTS.md`.

**Depends on:** all.

1. **CI wiring — and the one suite that is already globbed.** `ci-main.yml` enumerates most
   `.ts` suites **explicitly** (`:123-125` builtin-tools, `:126-127` provider-failover,
   `:128-129` cut-resume, `:151-158` subagent), but `:69` **already globs
   `extensions/shared/*.test.ts`**. So add only the two new
   `extensions/builtin-tools/*.integration.test.ts` entries — adding
   `dispatch-record.test.ts` explictly would **double-run** it (the hazard the file's own
   `.mjs` comment at `:44-46` warns about) — and wire the parity pin into **`ci-main.yml`'s
extension-tests job (which runs `npm ci`)**, not `ci.yml`: `extensions/subagent/index.ts` imports
   **runtime** values from four `@earendil-works/*` packages, and `ci.yml`'s `verify` job
deliberately runs **without** `npm ci` (`:138`, `:151`) — a parity test that must live there has
to be a `readFileSync` source pin (zero-dep, like
   `extensions/shared/default-coverage.test.ts`). Task 7.1 and the residual table are reconciled on
   **`ci-main.yml`**.

   **Shell suites are enumerated explicitly too** (`ci-main.yml:198-206`):
   `scripts/pi-task-session-prune.test.sh` must be added to that block, or indicator 7's liveness,
   fail-closed and TOCTOU assertions run **nowhere**.
   *(The file's comments record this bug class at `:65` #382, `:91` #357, `:103` #379,
   `:207` #449 — rev 4 mis-cited three of these four, and cycle 4 verified the corrected four.)*
2. **Prune/reaper interaction.** Rev 3's test asserted "a live child is neither reaped nor
   double-counted" — **vacuous**: the reaper cannot see a tty-less task child (`:165`). Replace
   with a test that runs the **prune script** against a fixture containing a live child's
   session file whose `ps` line matches, asserting the file survives and that a probe failure
   deletes nothing.
3. **`subagent` parity.** Assert `subagent/`'s timeout (`:261`) and stall (`:316`) behaviour is
   unchanged. Do **not** write this as a repo-wide "`--no-session` appears nowhere" grep:
   `extensions/subagent/index.ts:876` legitimately retains it.
4. **`AGENTS.md` contract note.** The durable-record contract, the session root + mode, the
   retention owner (organisation-design-team on-call operator), the two bounds, and the
   tolerance rule: **rows from other versions may lack identity fields; readers must tolerate
   absent fields**.
5. **Regression re-run:** `builtin-tools.test.ts`, `cut-resume.integration.test.ts`,
   `provider-failover.integration.test.ts`, and `census.py --assert-nonzero`.
   **⚠️ There is no trustworthy baseline on this tree.** Two consecutive runs of
   `builtin-tools.test.ts` gave **222 passed / 0 failed** and then **221 passed / 1 failed**
   (failing: `disarmed completion watchdog lets a clean-exit child exit naturally`, a 0.4 s
   wall-clock race in the completion-watchdog path). `cut-resume.integration.test.ts` reports
   **12**, not the 13 rev 5/6 claimed. The flake is filed as **#844** and must be fixed (or
   quarantined) **before** this plan's implementation lands — Task 3 touches the same
   completion-watchdog/composer path, so the two failures would otherwise be confusable. Task 7
   therefore asserts **0 *new* failures on the two post-change runs**, not an absolute count.

---

## Dependencies (corrected)

```
1 ─┐
2 ─┤
   ├─→ 3 ─→ 4 ─→ 5
   └─────────────────→ 6          (needs 1's layout)
                       7          (last; needs all)
```

Task 3 and Task 4 touch the same regions of `index.ts` **and** Task 4 writes through Task 3's
composers, so `4 →` is strictly after `3`.
Parallelisable: **{1, 2} → {3} → {4} → {5} → {6} → {7}** (6 may overlap 5).

## Out of Scope — each with a re-check mechanism

| Deferred | Why | Re-check |
|---|---|---|
| **Opt-in WIP commit (scope fix 5)** | **carved out to #840** by operator decision — off by default, yet the source of most P0s in cycles 3–4; its remaining obligations are a subsystem | #840; it depends on this plan's Task 4 record |
| **No-progress kill (issue checklist rows 3/4)** | the issue asked for a no-progress fail-fast kill and per-dispatch cap resolution; the scope **rejected the latter on mechanism**, and this plan delivers *countability* (`stopReason` per exit in the durable record) rather than a new kill | **#763** (cap with no real output) and **#800** (streaming but tool-less) track the two classes; Task 4's rows make both countable. Only the per-dispatch-cap case carries the scope's own re-open trigger: **the first observed scoping/reviewer dispatch that hits the host cap** |
| Load-aware queueing | not required by the indicators | census supplies the arrival rate |
| Auto-resume of a killed child | needs durable sessions first (Task 1) | after Task 1 + one week of transcripts |
|`#763` zero-output runs | recorded by Task 4, not fixed here | rows make them countable |
| `#769` hatch inheritance, `#777` VGATE registry | filed during scope | tracked issues |
| `#796` cross-dispatch ledger | joins on `dispatchId` via `appendLedger` | #796 consumes `dispatch-record.ts` |
| `time-to-first-activity-sweep` prompt-hash pairing | unblocked by Task 4's `childSessionId` | pair on the id instead of a prompt hash |
| `localHeadSha` / `auto-sync.ts:50` consolidation | duplicates `headSha` | fold when either is next touched |
| In-file secret scanning | the allowlist is not a scanner | a real scanner is its own issue |
| Splitting the 93 KB scope artifact | housekeeping | optional |

## Verification Checklist (amended indicators)

Rows 3 and 4 of the issue's original checklist are **superseded** — the issue asked for a
no-progress fail-fast kill and for per-dispatch cap resolution; the scope **rejected the latter
on mechanism**, and this plan delivers *countability* rather than a new kill. The substitution
is recorded in Out of Scope with the scope's own re-open trigger.

| # | Indicator | Delivered by |
|---|---|---|
| 1 | payload carries branch + `headSha` + dirty + location, **incl. detached-HEAD** | Tasks 2, 3 (J1) |
| 2 | the abnormal exit is reported, never silent; `stopReason` correct for hard-cap **and no-progress** exits **in the durable record**, proven by a test asserting the written record | Tasks 3, **4** |
| 3 | hard-cap **and** no-progress populations both countable | Task 4 (4 write sites, per-attempt rows) |
| 4 | the alarm can fire before the cap it warns about | Task 5 |
| 5 | **no regression in `builtin-tools.test.ts` and `cut-resume.integration.test.ts`** | Task 7.5, run in CI via Task 7.1 |
| 6 | a recovered child's work is findable and resumable | Tasks 1, 2, 4 |
| 7 | **retention binds and never deletes a live child** — the 7-day/2 GB bounds actually evict, and a live child's transcript survives every pass | Task 6 (prune + reaper-interaction fixtures) |
| 8 | **the census instrument still admits payloads after the change** — `--assert-nonzero` green on the default root *and* on a fixture root, with the new fields visible in the payload | Task 3 (additive `--root`) |

The issue's Indicator 1 second clause (“a WIP commit exists **only when the parent opted in**”)
is delivered by **#840**, not here.

---

## Implementation status — 2026-09-12 (session handoff)

**Branch:** `fix/783-task-cap-handoff` @ `.worktrees/fix/783-task-cap-handoff` · **HEAD `f3dbb4f`**
· **Nothing committed** — all work staged, intended to go in with the implementation PR.

### ✅ Task 1 — durable child session per spawn — DONE (verified)

| | |
|---|---|
| New | `extensions/shared/session-id.ts` (132 lines) + `session-id.test.ts` (**8/0**) |
| Changed | `extensions/builtin-tools/index.ts`, `extensions/provider-exhaustion.ts`, `scripts/time-to-first-activity-sweep.ts` |

- `--no-session` removed from both arg vectors; `--session-id` + `--session-dir` minted **per call** (the `fbArgs`-as-`const` defect is fixed).
- **The P0 stderr-warning filter is in and passing** — `✅ #783: fresh --session-id warning is known-noise — never flips hasOutput`, asserting `hasOutput === false` for the plain warning, the ANSI-wrapped variant, and the residue-flush path, while a genuine error line alongside still flips it.
- Verified against the **real CLI**: warning arrives on stderr; transcript lands at `<root>/<uuid>/…jsonl`; root is `drwx------` (0700).
- Root is `$TASK_SESSION_ROOT` (default `~/.pi/agent/task-sessions/`), `mkdirSync(mode:0o700)` **+ explicit `chmodSync`**; on failure the dispatch **degrades to `--no-session`** with a distinct non-retryable class.
- **Deliberate deviation from the plan:** `PI_CODING_AGENT_SESSION_DIR` was **not** added to `subAgentEnv`. `--session-dir` is passed per attempt and takes precedence over the env (`main.js`: `parsed.sessionDir ?? ENV ?? settings`), so a fixed value is a no-op — and a fixed *root* would be actively wrong beside per-attempt dirs. The plan's wording was superseded by the implementation; flag-only is correct.

### ✅ Task 2 — parent reports where the child ran — DONE (verified)

| | |
|---|---|
| Changed | `extensions/repo-freshness.ts` (`headSha`, `RepoState`, `parsePorcelainZ`, `asyncRepoState`), `extensions/session-checks.ts` (`execFileAsync` gains an `AbortSignal`), `extensions/builtin-tools/index.ts`, `builtin-tools.test.ts` |

- **Only `headSha` was genuinely missing** — `currentBranch`/`repoClean`/`mergeOrRebaseInProgress`/`indexLocked` were already exported and were reused, not re-implemented.
- Rendered `=`-form at `index.ts:2340`: `branch= headSha= worktree= dirty= dirtyPaths=`, single line, appended **after `trace=[…]`** on all four `Alive state:` templates (cap, cut, heartbeat, backstop). No colon form anywhere.
- Per-dispatch `let repoState`, filled **once** at spawn, read at settle — no `tick()`, no git on the heartbeat interval.

### ✅ Task 3 — one composer, four killers — DONE (verified)

| | |
|---|---|
| Changed | `extensions/builtin-tools/index.ts` (`composeAbnormalExit` + `AbnormalExitCtx`/`AbnormalExitSection`/`AbnormalExitDetails` + exported `ABNORMAL_EXIT_DETAIL_KEYS`), new `extensions/builtin-tools/task-cap-handoff.integration.test.ts`, `docs/scoping/2026-09-12-issue-783-census/census.py`, `census.selftest.sh` |

- **One composer, four killers.** Cap / exit-path cut / heartbeat / backstop now all resolve through `composeAbnormalExit(details, ctx)`. `ctx` carries the per-killer presentation (`headline`, `aliveSummary`, `stderrSection`, `stdoutSection`); the four are **not** flattened — cap/heartbeat/backstop keep `--- last stderr ---` over `cleanStderr(stderr.slice(-2000))` + `--- last stdout ---` over `stdout.slice(-500)` (both delimiters always emitted), the exit-path cut keeps the bare `--- stderr ---` over `cleanStderr(stderr.trim()).slice(-4000)` and omits empty sections.
- **`details` stays at the call site** so the `source.includes` pins survive verbatim — `reason: "cut", exitCode: code`, `reason: "hard-cap", hardCapMs: getTaskHardCapMs()`, `reason: "cut", backstop: true` — and the composer **normalizes** to the canonical field set `ABNORMAL_EXIT_DETAIL_KEYS = [model, provider, killed, reason, exitCode, hardCapMs, backstop, heartbeatTimeout]`, identical on all four (only the `reason` **value** differs; absent extras render `null` / `false`). The `!hasOutput\n ? undefined` cut pin is intact, and all four `Alive state:` templates survive (E271g/T2 pins green).
- **Census invariant proven live.** The new suite composes a real cap payload, writes it into a fixture session, and invokes the committed `census.py --root <fixture> --assert-nonzero`, asserting `payloads=1 files=1 git_field_state=1`; it also asserts the gates directly (headline prefix, one-line `Alive state:`, `trace=[…]` then `branch=` on that line, both `last …` delimiters, `hard cap (<Ns>)`, `=`-form only). Default-root `--assert-nonzero` remains green (`payloads=155`; `git_field_state=0` is the **historical** pre-Task-2 corpus, not a regression).
- **`--root` is now repeatable and ADDITIVE** (union, path-de-duplicated, order-independent); the default root is **not** repointed. `census.selftest.sh` gained a single-root discriminator + a two-root union check (both orders) + a default-root-not-repointed guard.
- **`circuit_open`:** the pre-spawn arm is **unchanged** and pinned by the new suite (refusal text + `details` literal + the `retries === 0` discriminator). The post-spawn terminal (`retries > 0`) is **not** routed through the composer — that return is in the tool's `execute()` scope, where the child's `stderr`/`stdout`/alive state no longer exist; the plan's "gated on a real prior spawn" is satisfied by the existing `breakerNeverSpawned` discriminator. Recorded as a plan/scope finding for Task 4 (the durable record is where a post-spawn circuit_open can be annotated).

### ✅ Task 4 — durable outcome record — DONE (verified)

| | |
|---|---|
| New | `extensions/shared/dispatch-record.ts` (row contract + gate + write-and-confirm) + `dispatch-record.test.ts` (**16/0**) |
| Changed | `extensions/builtin-tools/index.ts`, `builtin-tools.test.ts` (one repin), `cut-resume.integration.test.ts`, `task-cap-handoff.integration.test.ts` (ledger isolation) |

- **Writer at the ONE choke point** — inside `doResolve`, immediately after `settled = true`, gated on a caller-supplied `reason`. Not at call sites: `finalize` is invoked unconditionally from both `proc.on("exit")` and `proc.on("close")`, so a cap kill would otherwise settle row A and the close-path `cut` a second row for the same attempt (append-only → unrepairable). The 60 s cap test proves it at runtime: the fake child's SIGTERM trap confirms the close path ran, and the ledger holds **exactly one** row (`reason=hard-cap`).
- **`doResolve` gained `reason` (required-on-abnormal) + `exitCode`.** The 12 sites: `:2815`/`:2819` cap → `hard-cap`; `:2903` exit-path cut (one `doResolve`, both ternary arms) → `cut`; `:2927` non-zero → `failed`; `:3076`/`:3102` heartbeat → `decision.reason ?? "silence-threshold"`; `:3141`/`:3146` backstop → `backstop`; `:2870` sessionEnded, `:2893` clean exit, `:3170` abort-after-end, `:3211` spawn error → **no reason → NO row**. *(The brief listed three separate "cut" numbers; in the code the cut is ONE settle with two arms, and the other two numbers are the success settles. Followed the code — see the review note.)*
- **Same ledger, same key.** Rows go through `appendLedger(row, "dispatch-outcome", subAgentEnv)` → `~/.pi/agent/audit/provider-failover.jsonl`, `dispatchId = TASK_HEARTBEAT_NONCE`, so #796 and the #512/#476 rows join on one key in one file.
- **`appendLedger` cannot back `{ok,error}`, so the writer wraps it**: write, then stat + read-back the appended byte range for OUR identity (robust to a concurrent sibling append). An unwritable root yields `record: "failed: <err>"` in the payload — never a path to nothing (pinned by a test).
- **Gate `DISPATCH_LEDGER`, default ON.** Explicitly off → the row is skipped AND the payload carries no `record` field at all (no advertised path, no false failure claim).
- **`attempt` threaded** from `retry((attempt) => spawnLeg(leg, attempt))` through `recordCtx(attempt)` on the primary, failover and fallback legs; the spawn boundary defaults a missing value to `1` (tsx does not typecheck). `childSessionId` is read from the **arg vector** (`--session-id`), the source of truth for what spawned. A scripted 2-attempt run writes **2 rows, one `dispatchId`, `attempt` 1/2**.
- **`dispatchClass`**: no existing reviewer/eval discriminator exists anywhere (the review-enforcer counts any `task`/`subagent` tool_result and keeps no class) — so it is caller-declared via `TASK_DISPATCH_CLASS`, default `"task"`. Recorded as the honest form of "distinguishes builtin-task from reviewer/eval".
- **Ledger isolation:** `cut-resume` and `task-cap-handoff` now point `PI_CODING_AGENT_DIR` at their tmpdir (`provider-failover` already did). After all four real-`spawnSubAgent` suites, the operator's `~/.pi/agent/audit/provider-failover.jsonl` **does not exist** — zero test rows leaked.
- `dispatch-record.test.ts` is auto-collected by `ci-main.yml`'s existing `extensions/shared/*.test.ts` glob — adding it explicitly would double-run it.

### ✅ Tasks 5, 6, 7 — DONE (verified)

| Task | Deliverable | Verified |
|---|---|---|
| 5 | Task-local 2 h alarm, **constant split only** | `DEFAULT_TASK_TOOL_STALL_MS = 7_200_000` (`:1527`); export still `21_600_000` (`:1515`); `getToolStallMs()` returns the task-local value with env override + 60 s clamp; **`git diff --stat extensions/subagent/` empty** |
| 6 | Retention: prune script + launchd plist, live-child safe | `scripts/pi-task-session-prune.sh`, `templates/launchd/com.eldato.pi-task-session-prune.plist`, `scripts/pi-task-session-prune.test.sh`; plist ships **`TASK_SESSION_PRUNE_DRY_RUN=1`** + `StartInterval 3600`; `install-launchd.test.sh` count 5→**6**; `pi-bootstrap/setup.sh` `fleet_srcs` |
| 7 | Regression sweep, CI wiring, reaper/prune interaction, contract note | CI `ci-main.yml:133` (task-cap-handoff), `:162` (subagent-parity), `:220` (prune shell test); `extensions/subagent/subagent-parity.test.ts` (9/0, zero-dep source pin); `AGENTS.md:182` contract section |

**Final sweep — 0 NEW failures:** `builtin-tools` 229/0 · `cut-resume` 11/1 *(#844-class pgid flake, varying set)* · `provider-failover` 16/0 · `task-cap-handoff` 8/0 · `dispatch-record` 16/0 · `session-id` 8/0 · `subagent-parity` 9/0 · prune shell **PASS=58** · `census --assert-nonzero` RC=0.

**Notes carried forward:** Task 2's `transcriptPath`/`recordPath` payload fields were omitted from the Tasks 2–3 briefs and were added by Task 4 to the abnormal payload's `details`; `dispatchClass` has no existing referent so it is a caller-declared `TASK_DISPATCH_CLASS` (default `"task"`); `circuit_open` post-spawn is **not** routed through the composer (its terminal lives in `execute()`, where child stderr/stdout no longer exist) — the pre-spawn arm is byte-identical and pinned; **#743** (pre-existing) blocks `bash` on git-free repo scripts from hub-rooted sessions — run from a worktree-rooted shell.

### ⚠️ Test-state caveats for the next session

| Suite | Observed | Note |
|---|---|---|
| `extensions/shared/dispatch-record.test.ts` | **16/0** | New (Task 4). Includes the 60 s cap exactly-once proof and the unwritable-ledger payload assertion. ~2.5 min (one 60 s cap arm). |
| `extensions/builtin-tools/task-cap-handoff.integration.test.ts` | **8/0** | Task 3 suite, green with Task 4's record wiring. ~3 min (two 60 s cap arms). |
| `builtin-tools.test.ts` | **228 passed, 1 failed** | The failure is **#844** (flaky completion-watchdog, 0.4 s wall-clock race). One source pin was repinned by Task 4 (`retry((attempt) => spawnLeg(dispatchLeg, attempt), …)` — the venice-route-after-first-spawn property it guards is unchanged). |
| `cut-resume.integration.test.ts` | **11/1** and **10/2** on consecutive runs | **Verified load-sensitive, not a regression** — the failing wave changes between runs (AC1 then AC3 wave 0) under loadavg 190+. Both failures are "child pid captured" (pgid-capture). Do not chase it; re-run on an idle machine. |
| `session-id.test.ts` | **8/0** | New. |
| `repo-freshness.test.ts` / `session-checks.test.ts` / `provider-failover.integration.test.ts` | 36/0 · 33/0 · 16/0 | Green. |
| `census.selftest.sh` | ✅ | Instrument still self-tests. |
| `census.py --assert-nonzero` (default root) | ✅ `payloads=155 files=53 git_field_state=0` | `git_field_state=0` is the historical pre-Task-2 corpus, not a regression. |

### Filed during implementation

- **#855** — fast-settling dispatches render repo-state fields as `unknown` (the async probe races the synchronous settle; ~0.5 s cut shows `unknown`, a 3 s sleep shows real values). The 6 h cap is unaffected, so the issue's indicators hold. Two candidate fixes are in the ticket.
- **#844** — flaky completion-watchdog test (above). **Fix or quarantine before this plan lands** — Task 3 touches the same composer/watchdog path.

### Not yet exercised

No billed end-to-end LLM dispatch through the tool's `execute()` (the real-CLI flag behaviour and file layout were verified directly, and `provider-failover.integration.test.ts` drives the real `execute()` against a fake `pi`); and the **degrade path** is unit- and source-pinned but not driven end-to-end.

---

## Review history — **substance clean at cycle 8**

Eight `plan-review` cycles ran. P0 counts went **6 → 6 → 3 → 3 → 2 → 0 → 1 → 0**, and cycle 8
returned **0 P0 and 0 P1** (8 P2s, all citation hygiene, closed in rev 10). Cycles 5 and 7 each
exited at a cap with issues open — those were **escalation exits, not completions** — and were
resolved rather than declared clean.

The plan is **verified**: no open P0/P1, no dangling cross-references, dependency graph matching
the task list, every Files entry existing, and every checklist row (1–8) mapping to a delivering
task.

| # | Item | Status |
|---|---|---|
| 1 | `pi-reap-idle.sh:157` → **`:165`** (the `tty ~ /^ttys/` gate; `:157` is a pid sanity check) | ✅ fixed (3 places) |
| 2 | `install-launchd.sh:139` → **`:142`** (`verify_targets`); `install-launchd.test.sh:167-171` → **`:174-198`** | ✅ fixed |
| 3 | `census.py` glob `:100` → **`:96`**; last-stdout delimiter `:139` → **`:133`** | ✅ fixed |
| 4 | Surface Map row 12's "no glob" contradicted Task 7.1 (`:69` globs `extensions/shared/*.test.ts`) | ✅ fixed |
| 5 | cap payload setter `:2535` → the settle is **`:2532`** | ✅ fixed |
| 6 | no checklist row for Task 6 / the census instrument | ✅ rows 7–8 added |
| 7 | `cut-resume` is **12** tests, not 13 | ✅ fixed |

**P0s closed in rev 7–8:** the census-`ROOT` error (would have broken the instrument) and the
per-attempt session-id minting on the fallback leg. **P1s closed:** record-writer choke point
inside `doResolve` (kills the double-settle and covers the cut-with-output arm), `attempt` made
mandatory, session root env-overridable, parity pin moved to `ci-main.yml`.

**Blocking external dependency:** **#844** (flaky completion-watchdog test) must be fixed or
quarantined before this plan lands — Task 3 touches the same composer/watchdog path.
