<!-- research-path: https://github.com/daniel-ospina/agent-infra/issues/1265#issuecomment-6722549255 -->
<!-- plan-review: cycles=3, status=capped, exit_reason=adversarial-capped, version=2.3.0 -->

# #1265 — session-start recovery counts a *sibling* worktree's entries, and the non-adoption never reaches the parent

**Plan date:** 2026-11-08 · **Branch:** `feat/1265-tm` · **Class:** gate-enforcement

## Confirmed problem

The issue's headline ("the gate adopts ANOTHER worktree's root as the git-op root") is **no longer
true**, and that is provable from this tree rather than from a commit that is not in this branch's
history: `recoveryOnlyRoot` is **inspection-only** — its return never becomes a git-op root and never
becomes the reported count — the `tool_call` handler's git-op path is
`const cwd = resolveGitRoot(cdPath ?? inputCwd)`, and `pickVerifiedRoot` is documented
RECOVERY-ONLY. (The narration `"…the git-op root is NOT adopted"` reached `origin/main` in
`6580850cc`, #3334.) PR #1780 **was** merged to `main` on 2026-10-15 (merge commit `26ad39a33`), but
that commit is not an ancestor of today's `origin/main`, so it is not cited as this head's evidence.

Two acceptance indicators in the issue are nevertheless still unmet at this head:

1. **AC (b) — "the adoption/skip decision is visible to the parent (task return value or a shared
   log), not only in child stderr."** `diagnoseRootMismatch` emits one `console.log` and nothing else:
   no `appendJsonl`, no durable record. A task child's stdout is read
   only when the child is already dead, so this is exactly the "the parent sees *wedged*" failure the
   issue measures.
2. **The neighbouring false signal (`session_start`).** Session-start recovery is executed at the root
   `recoveryOnlyRoot` hands back, so when this worktree has **no** entries and one same-repo sibling
   has them, `recovered` is the **sibling's** count and the child prints
   `📂 Recovered N verified files from bridge`. Every one of those N is dropped by
   `recoverBridgeForRoot`'s `parsed.root !== normRoot` guard (`foreign root — inert`), so the line
   claims verified state the session does not have — and because `recovered > 0`, the
   `else if (isTaskSubAgent())` zero-entry warning (the #264 P2 "every commit will block" signal, added
   *precisely* because the parent needs it) never fires. A false PASS over a real block, in the one
   direction finding 1 says must not be silent.

The narrow fix is therefore in **reporting**, not in root selection: the session's own root is the
only root whose entries can cover this session's git ops, and the report must say so — durably.

## Alternatives considered

1. **Remove `recoveryOnlyRoot` entirely (never inspect a sibling's entries).** Rejected: it would
   drop the only way a hub session can *see* that a linked worktree's change is already verified, and
   #1780's message exists for that. The entries are inert, not harmful; the defect is the count.
2. **Make the parent read `gate-events.jsonl` in the `task` return value.** Deferred, not rejected:
   it is a `extensions/builtin-tools` change (a different extension, a different test surface, and a
   risk of touching the dispatch return contract). AC (b) accepts "a **shared log**", and
   `~/.pi/agent/audit/gate-events.jsonl` is that log. Note precisely what this buys: **no production
   consumer PARSES that file.** Its readers are (a) `scripts/vgate.sh`, which `tail`s the last lines in
   `status()` for a human (never parses, never selects by `event`), and (b) in-repo TEST helpers —
   `extensions/shared/audit-log.test.ts` (asserts the path and the row schema; selects by NOTHING),
   `extensions/verification-gate/index.e2e.test.ts`'s `readAuditLines()`,
   `extensions/review-enforcer/index.test.ts`, and
   `extensions/review-enforcer/index.spawn-evidence.test.ts` (these three select by `event`).
   `gateEventsFile()` has exactly one production caller, `appendJsonl`. So the record is durable and
   greppable by a parent or a future reader, and no shipping instrument can mis-read the new names.
   Recorded as a named residual.
3. **Change root selection back to adoption.** Refused flat: it re-opens the fail-open documented in
   `pickVerifiedRoot`'s docblock (a clean adopted tree yields an EMPTY scope, and the empty-scope path
   ALLOWS an op carrying unverified content).
4. ✅ **Recover this worktree's own root first and report THAT count; merge the sibling's entries for
   INSPECTION only, record that decision durably, and give the root-mismatch diagnosis a durable
   record too.** This does not touch root selection or the block/mismatch decision (both stay
   fail-closed and unchanged). It also rewrites the mismatch remedy, which no AC literally demands:
   that is justified on its own measurement — the previous text ("re-run the op from the verified tree
   (cd into it)") **led the first of three consecutive children that died in that worktree into a tree
   it did not own** (issue #1265: "doing so is what the first child did, after which it too was
   killed"; the three deaths are attributed there to per-worktree determinism, not to three separate
   followers of the remedy) — and it is the smallest edit that stops prescribing that path.

### Acceptance criteria (the issue's, quoted so the plan can be checked against them)

- **AC (a)** a git op in a worktree with no bridge entries **fails closed** with the correct root
  named, and does not adopt another worktree's registry. *Already true at this head; the change must
  not weaken it — e2e 1265a asserts B's commit stays `block === true` after A's entries were
  inspected.*
- **AC (b)** the adoption/skip decision is visible outside child stdout — "task return value **or a
  shared log**". *This plan takes the shared-log arm.*
- **AC (c)** a worktree that previously had no entries can be verified and used normally afterwards,
  with no temp-path/sibling root ever substituted — e2e 1265a: only B's own PASS allows the op.

## Complexity + domains

`complexity:standard` (issue carries no complexity label → fail-closed to standard). Domains:
`gate-enforcement` (a verification gate), `code`. Adversarial threat surface declared below.

## Integration surface map

| Surface | Layer | Test |
|---|---|---|
| `session_start` handler | unit-of-behaviour | e2e scenario 1265a (real linked worktrees + real bridge) |
| `diagnoseRootMismatch` → `tool_call` git-op path | unit-of-behaviour | e2e scenario 1265a (block + audit record + reworded remedy) |
| `appendJsonl` / `GateEventName` union (`extensions/shared/audit-log.ts`) | type + contract | **documentation-only**: `appendJsonl` takes `Record<string, unknown>`, the repo has no `tsconfig.json`, and no roster pin exists — the union edit cannot be type-enforced (see step 3) |
| source pins ("#3255 policy" test in `index.test.ts`) | structural | five pins across this PR — own-root declaration, own-root COUNT, durable-record `root`, rendered-remedy absence, followable-remedy presence |
| `recoverBridgeForRoot` perf fast-path (`lastRecoveryMtime`) | regression | existing e2e scenario 16 (first_push mid-session bridge recovery) |

## Research

See the `<!-- research: v1 -->` artifact (issue comment 6722549255). It settles:
(a) the mechanism is `session_start`'s `recoveryOnlyRoot` call plus `recoverBridgeForRoot`'s foreign-root
skip, (b) the industry rule is *key by real path, report the miss,
never substitute a hit* (Turborepo `cacheDir` guidance; Bazel hermeticity), (c) on a busy box adoption
is already unreachable (`pickVerifiedRoot` returns `null` at 2+ siblings — measured 12 agent-infra
roots and 20+ tortoise roots in the live bridge), so this is the narrow one-sibling case.

## Wiring

| Call site / consumer | What it does there |
|---|---|
| `recoveryOnlyRoot(root)` — 1 call site, `session_start` | names a same-repo sibling whose entries may be merged **for inspection**. Its return becomes `inspectRoot`; it never becomes a recovery *count* nor a git-op root. |
| `recoverBridgeForRoot(normRoot)` — **3** call sites: `session_start` twice (`ownRoot` = the count, `inspectRoot` = inspection only) and the git-op mid-session recovery path | filters `parsed.root !== normRoot` ("foreign root — inert"), so it only ever installs entries for the root it is given. |
| `diagnoseRootMismatch(root)` — 1 call site, the git-op path | narrates a root mismatch; gains the durable `gate_root_mismatch` record + dedupe. Block decision untouched. |
| `bridgeRoots()` | reads the bridge's PASS roots; unchanged. |
| `gitCommonDir(root)` | same-repo test (`--git-common-dir`); unchanged. |
| `appendJsonl(entry, file?)` — `extensions/shared/audit-log.ts` | appends to `~/.pi/agent/audit/gate-events.jsonl`; **four** new event names added to `GateEventName` (`gate_recovery`, `gate_recovery_empty`, `gate_recovery_foreign_root`, `gate_root_mismatch`). `gate_recovery` carries the `root` it recovered for, so an inspection merge is **attributable** to the SIBLING root. It is not un-attributable by `session_cwd`: that field still names the inspecting session, so a session-keyed reader must select on `root`. |
| `gate-events.jsonl` consumers | **no production consumer** — `gateEventsFile()` has one production caller (`appendJsonl`); the only readers are in-repo TEST helpers (`audit-log.test.ts`, `index.e2e.test.ts`'s `readAuditLines()`, `review-enforcer/index.test.ts`), each selecting by `event`. An external reader selects by `event`/`reason` and must tolerate unknown **fields** (`audit-log.ts` header); the header's `event —` line is a stale closed enumeration (pre-existing) that names none of the four new events. |
| `extensions/verification-gate/index.e2e.test.ts`, `index.test.ts` | run by `ci-main.yml` (`npx tsx …`) — no new file, so no CI-surface registration applies (this repo has no `config/ci-surfaces.yml`). |

## Implementation steps

1. **`session_start`**: `ownRoot = normalizeWorktreeRoot(resolveGitRoot(process.cwd()))`;
   `recovered = recoverBridgeForRoot(ownRoot)`; `inspectRoot = normalizeWorktreeRoot(recoveryOnlyRoot(ownRoot))`;
   `inspected = inspectRoot === ownRoot ? 0 : recoverBridgeForRoot(inspectRoot)`.
   Report `recovered` as this worktree's count (naming the root); the `else if (isTaskSubAgent())`
   zero-entry warning is now reachable whenever this worktree has none. When `inspected > 0`, log that
   the entries are INSPECTION ONLY / inert here and append `gate_recovery_foreign_root`.
   *Proves it:* e2e 1265a — exactly ONE `gate_recovery` keyed on **worktree A** (the sibling it
   recovered for) and NONE keyed on B, one `gate_recovery_foreign_root`, and one durable
   `gate_recovery_empty` for B (the #264 P2 signal the pre-fix run suppressed).
2. **`diagnoseRootMismatch`**: keep the narration, put the **safe** remedy first
   ("re-dispatch verification for `<this root>`") and state that adopting another tree's entries is
   refused by design; append `gate_root_mismatch` once per `(root, siblings)` fingerprint, reset at
   `session_start`.
   *Proves it:* e2e 1265a — two identical blocked ops produce exactly one record, **and the `Set` memo
   is discriminated**: the scenario adds a third worktree C and alternates B → C → B inside one
   session, asserting B and C each land exactly ONE `gate_root_mismatch` (a single-slot memo
   re-records B on the return visit and reddens it). What is still NOT discriminated is the `.sort()`
   on the sibling list — each (root, siblings) pair here has one sibling, so it sorts a one-element
   list.
3. **`extensions/shared/audit-log.ts`**: add `gate_recovery`, `gate_recovery_empty`,
   `gate_recovery_foreign_root`, `gate_root_mismatch` to `GateEventName` (the first two were already
   emitted untyped — a pre-existing gap closed while adjacent).
   *Proves it:* **nothing type-enforces this** — `appendJsonl` takes `Record<string, unknown>`, the
   repo has no `tsconfig.json`, and no roster pin exists (the union already carries names outside it,
   recorded in the #634 plan). The edit is documentation: it **extends the union with four names**; the
   header's `event —` enumeration at the top of the file was already stale (it lists seven names and
   omits `reviewer_preflight`, `bridge_clear`, `review_spawn_no_verdict`, `gh_shim_degraded` too) and
   stays stale here. A roster pin (emit-site `event:` literals ⊆ `GateEventName`) is the check that
   could fail, and is NOT added here.
4. **Tests**: e2e scenario 1265a appended to `index.e2e.test.ts` (the file's own sequential harness
   with real `git worktree` pairs and a temp `HOME`), run as a TASK CHILD so the second half of the
   defect (the suppressed #264 P2 zero-entry warning) is reachable; the "#3255 policy" test in
   `index.test.ts` **gains five structural pins and inverts one prior pin** across this PR — the
   own-root declaration, the own-root COUNT expression, the durable `gate_recovery` record's `root`
   field, the absence of the rendered `cd into it` remedy, and the presence of the followable remedy
   plus "refused by design"; and `origin/main`'s must-EXIST `sessionRoot` pin becomes a must-NOT-exist
   pin (six changed pin sites, not five).
   `recoverBridgeForRoot`'s
   `gate_recovery` record now carries the `root` it recovered for, so an inspection merge is recorded
   against the sibling root — never read as an own-root count.
5. **Verification**: full `index.test.ts` (baseline 317) + `index.e2e.test.ts` (baseline 119; 120 with
   1265a) must be green; mutation proof — a PARTIAL revert (count from the inspected sibling while
   keeping the foreign-root record) must turn 1265a red, and dropping the `root` field must turn the
   source pin red.

## Rounds

**Exit: `capped` — the adversarial bound (2 cycles) is spent, and both cycles found real defects.** This
marker is deliberately NOT `clean`; the residual class below is named rather than closed.

| Cycle | Reviewer | Issues | Disposition |
|---|---|---|---|
| 1 | fresh-context plan reviewer | 6 (2×P1, 4×P2) | all applied — R5's false "readers" claim, "Proves it: typecheck" for an unenforced union, pin count, a citation that is not in `origin/main`, undefined ACs + unjustified remedy rewrite, the out-of-vocabulary marker |
| 2 | fresh-context plan reviewer | 8 (2×P1, 6×P2) | all applied — the reader inventory corrected in the OTHER direction (test helpers do read the log), the `Set`/`sort` refinement restated as untested, `#1780` replaced by the commit actually in `main` (`6580850cc`), the stale header enumeration stated as stale, `session_cwd` attribution corrected, "message-only" → "inspection-only", the #1265 measurement corrected (the FIRST of three dead children followed the `cd` remedy — not three), and the inverted prior pin counted |
| 3 | fresh-context verification of the cycle-2 fixes (the deep-fix round the cap requires) | 7 (2×P1, 5×P2) | all applied — R3's "three children" corrected; step 2's "the `Set` is untested" replaced with what the tests now DO discriminate (`03227c5a2` — `f192265b3` before the branch was rebased onto `main`; patch-id `5e9bcada`, identical — added worktree C and the B→C→B alternation; only the `.sort()` remains untested); the reader inventory corrected a third time (`scripts/vgate.sh` `tail`s the file in `status()`, `audit-log.test.ts` selects by nothing, and a fourth test reader — `review-enforcer/index.spawn-evidence.test.ts` — added); #1780 restated (merged to `main` on 2026-10-15, but its merge commit is not in today's `origin/main`); the acceptance line scoped to the NAMED residual; the PR body's two falsehoods corrected in a comment plus the `[ADVERSARIAL-BOUND]` disclosure added |

The same head was code-reviewed by a separate fresh context, which found one P2 in this diff: the
`gate_recovery` comment in `audit-log.ts` described the inspection pairing as unconditional, when the
git-op call site's recovery is for that op's OWN root and is live (it is the state that gates the op).
Scoped to `session_start` and the distinction stated.

**Named residual (not closed):** R5 asks whether a consumer of `gate-events.jsonl` mis-reads the new
names or the changed `gate_recovery` payload. There is no production consumer in this repo, so no test
can go red for it; the evidence is an inventory of the in-repo test readers plus the header's
reader contract. Filing a roster pin (emit-site `event:` literals ⊆ `GateEventName`) is the check that
*could* fail and is left as follow-up work rather than smuggled into a reporting fix.

### Review Scope Contract
**Class:** gate-enforcement

**Risk surface** — what this change can break, each with the check that would catch it:

- **R1** The reordered recovery installs entries that let an op through, i.e. the change becomes the
  fail-open it is meant to report → caught by e2e 1265a: after worktree A's entries are inspected,
  worktree B's commit must still be `block === true`; only B's own PASS may allow it.
- **R2** The new durable record floods the shared log (one line per git op) → caught by e2e 1265a:
  two identical blocked ops produce **exactly one** `gate_root_mismatch` line for that root.
- **R3** The reworded diagnosis stops naming the correct root, or reintroduces the un-followable
  remedy that the **first of the three children killed in that worktree** followed into a tree it did
  not own (the three deaths are attributed in #1265 to per-worktree determinism, not to three separate
  followers) → caught by e2e 1265a's captured console: the
  mismatch remedy must say "re-dispatch verification for THIS root" naming worktree B's **realpath**,
  and must state that adoption is refused by design. (The *block reason* does not carry a root in this
  scenario — the sibling holds a DIFFERENT path, so `rootsHoldingPath` returns nothing to name; the
  remedy line is the right evidence for R3.) Additionally pinned at source level in `index.test.ts`:
  the rendered form `(cd into it)` must be absent from every message string — the historical mention
  in the docblock wraps across lines, so it does not match that pin.
- **R4** The `lastRecoveryMtime`/`lastRecoveredRoot` fast path is disturbed so a
  mid-session bridge write is no longer seen → caught by the pre-existing e2e scenario 16
  (externally-written bridge recovered mid-session) staying green.
- **R5** A consumer of `gate-events.jsonl` mis-reads the new names, or the changed `gate_recovery`
  payload (it now carries `root`) → **no production consumer PARSES this file**, so the only
  evidence obtainable is the inventory itself: `gateEventsFile()` has one production caller
  (`appendJsonl`, `audit-log.ts:81`); `scripts/vgate.sh` `tail`s it for a human in `status()` and
  selects nothing; the other references are in-repo TEST helpers that read the file
  (`extensions/shared/audit-log.test.ts` — path + row schema, no `event` filter;
  `extensions/verification-gate/index.e2e.test.ts`'s `readAuditLines()`;
  `extensions/review-enforcer/index.test.ts`;
  `extensions/review-enforcer/index.spawn-evidence.test.ts` — the latter three select by `event`), plus
  comment-only mentions in `scripts/registry-sync.sh` and `scripts/admin-merge.sh`. Those helpers are
  the closest thing to a regression check and they stay green.
  `audit-log.ts`'s header binds a reader to tolerate unknown **fields**; its `event —` line is a stale
  closed enumeration (pre-existing) that names none of the four new events. Recorded as a residual, not
  as a passing test.

**Threat classes** (gate-enforcement):
- `T1 an op carrying unverified content is ALLOWED because recovery counted a foreign root` → covered
  by R1 (e2e 1265a stays blocked).
- `T2 the gate performs the diagnosis but drops it, so the parent must re-derive it` → covered by R2
  (durable, deduped `gate_root_mismatch`).

**Out of scope — must NOT be raised** (note, file, do not chase):
- the `task` **return value** channel (a `builtin-tools` change) — named as a residual in the research
  artifact and followed up as its own issue;
- root selection / adoption policy (the narration in today's `origin/main` came from `6580850cc`;
  #1780's merge commit `26ad39a33` is not in that history; #1303's own correction records the keying as
  intended);
- the `#1303` block-message root-naming work, and any prose preference about `#3255` numbering;
- pre-existing defects outside this diff.

**Acceptance:** every `R<n>` that is test-backed names a test that CAN fail (R1-R4), R5 is an
inventory-backed residual stated as such, and no UN-NAMED open item remains on the declared surface
(R5 is the named one).
