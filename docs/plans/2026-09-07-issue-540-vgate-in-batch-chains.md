---
title: "#540 — in-batch mutation chains + sweep/gh chains (pre-execution single-state residual) — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-07
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-540, issue-489, issue-538, issue-539, issue-559
---

# #540 — pre-execution single-state gating residual (in-batch mutation chains + sweep/gh chains)

## Confirmed Problem

VGATE's `tool_call` hook computes its diff ONCE from the repo state BEFORE the command
executes. A single tool_call that mutates state in-batch — `echo 'export const x=1' > f.ts
&& git add f.ts && git commit -m y` (or `… && git commit -am x`) — shows an EMPTY diff at
hook time (neither the add nor the dirtying has run; the written content does not exist on
disk) → "no changed files — allow" → the batch commits unverified code. Empirically
confirmed (exit 0, file lands in HEAD). Pre-existing class (affects bare commits equally
since #38); #489 documents it as residual.

Second member (mixed sweep/gh chains): `git commit -am x && gh pr create` routes through the
gh arm (the sweep-first branch is excluded when a gh op is present) whose branch-diff scope
(`git diff origin/main...HEAD`) is computed BEFORE the in-command sweep runs — the sweep's
uncommitted WT files are invisible to it → empty-branch allow → unverified content ships in
the PR. The same hole exists for bare-commit + gh (`git commit -m x && gh pr create` over
staged code).

## Why the obvious alternatives are unsound

- **(a) post-execution re-verification** (diff HEAD^ vs new HEAD at tool_result; block the
  next op): the unverified content is ALREADY in HEAD when the next op is blocked; an
  in-batch `&& git push` / `&& gh pr create` ships before tool_result fires. Too late,
  weak.
- **(c) widened/pre-verification scope from command text**: for an in-batch file WRITE the
  content does not exist at hook time — there is nothing to verify. Any pre-verification of
  "intended" content is guessing and gameable.
- Over-broad refusal ("no compound commands"): breaks pinned Leg-G-style commit+commit and
  read-only chains.

## Chosen model

**M1 — shape refusal (`commitChainMutationClass`).** When a command executes a commit AND
contains, before an executed commit, a segment that is not provably content-neutral, the
hook REFUSES (block) before any scope computation. Content-neutral = the normalizeCommitSegment
fixpoint leaves (a) empty (cd/env/prefix-verb scaffolding, comments), (b) a head-anchored
git commit invocation (a commit never creates content a later commit records that the
hook-time snapshot cannot already see — it only CONSUMES staged content; mixed bare+sweep is
pinned by scenario 48 Leg G with the union scope), (c) a git READ-only verb (status/log/diff/
show/rev-parse/branch/remote/config/ls-files/ls-tree/cat-file/rev-list/describe/name-rev/
merge-base/blame/grep/shortlog/…), (d) stdout-only echo/printf (no unquoted file redirect),
(e) `:`/`true` shell no-ops. Everything else — file redirects, `git add`/`checkout`/`reset`/
`restore`/`rm`/`mv`/`push`/`fetch`, arbitrary programs (python/node/tee/cat/sed), gh ops,
unprovable wrapper payloads — is a mutation candidate. Provably-executing wrapper prefixes
(`sh -c`/`bash -c` payloads, `!`, `eval`, quoted env) are peeled and their payload re-run
through the FULL segment pipeline (the #539 machinery), so `sh -c 'echo x > f.ts && git
commit -am y'` refuses while `sh -c 'git commit -am x'` stays legal. Depth cap (≥8) expands
to a mutating+commit pair (fail-closed: cannot see inside → the wrapper may both mutate and
commit).

Soundness argument: the refusal is **shape-based, not content-based** — no re-arrangement of
the command text moves an in-batch mutation before a commit without tripping it, because the
only allowed pre-commit shapes cannot change the file set the commit records (reads/writes
nothing, stdout-only echo writes nothing, a commit only consumes state the hook snapshot
already contains). The ONLY route to a commit is a tool_call whose pre-commit segments are
neutral → any content the commit records existed at hook time → the normal scope producers
(staged/WT/WT-path/union) bound it → the existing verify/block loop is sound. Refusal is
never an allow; over-refusal (piped reader before a commit) is safe accepted friction that
resolves by splitting. Refusal feeds NO `blockAttempts`/`lastBlockedFiles` and does not
increment the #7591 counters — a repeated identical compound is refused every time
(auto-bypass on an unverifiable shape would recreate the hole; mirrors the parse-block
posture).

**M2 — gh-commit scope widening.** In the gh arm (after the #204 merge-scope skip), when the
command EXECUTES a head-anchored commit AND contains `gh pr create` (create-only; merge is
untouched), widen the routing scope to `union(runBranchScope, commit-record-scope)` where
commit-record-scope mirrors the #489/#538 routing for the command's executed commits:
sweep → WT; mixed → union(staged, WT); pathspec WT-path → union(staged, named-path WT /
full-WT for --pathspec-from-file); else bare → staged. `git commit -am x && gh pr create`
over dirty WT code now blocks naming the code (branch scope would empty-allow);
`git commit -m x && gh pr create` over staged code blocks too. A gh pr create whose body
merely MENTIONS a commit (or a pure gh command) never widens — the trigger is the same
executed-commit walker, which classifies prose-bearing echo/gh segments by their HEAD
(`gh` is not a commit), never by substring containment. A commit AFTER `gh pr create`
(`gh pr create && git commit`) is refused by M1's ordering (the gh segment is a mutation
candidate preceding the commit) — the commit must be its own tool_call to be gated on the
real state.

## Acceptance tests (beyond the pinned 1–71)

1. `echo … > f.ts && git add f.ts && git commit -m y` (and `&& git commit -am y`) → REFUSED
   (block, in-batch-chain reason), never an empty-allow; repeated attempts stay refused
   (no auto-bypass).
2. Second pass: split the write/add into real ops + fire the PURE `git commit` → normal
   VGATE verify (block naming f.ts → PASS → allow → real commit) — "blocked until a second
   pass" resolves to the sanctioned ceremony.
3. `git add f.ts && git commit -m y` / `git checkout -- f.ts && git commit -am y` →
   REFUSED (issue I-section explicitly names git add/checkout/reset + commit).
4. `git commit -am x && gh pr create` over dirty WT code + staged docs → BLOCK naming the
   code file (union branch+WT); docs-only PASS must NOT unlock it; code PASS → allow.
5. `git commit -m x && gh pr create` over staged code → BLOCK naming code; pure
   `gh pr create` unchanged (branch scope).
6. Regressions: Leg G commit+commit stays legal; wrapper pure sweeps (`sh -c 'git commit
   -am x'`) stay legal; bare docs commits stay shape-exempt; prose `-m`/`--body` mentioning
   git commit never reroutes; delete-push chains stay skipped; push-range behavior
   unchanged.
7. Pure classifier unit pins (table-driven, subprocess-free) for M1 + executed-commit
   presence, including the neutral scaffolding families.

## Verification

- Unit: 296 passing (baseline 290 → +6: module-load smoke + 5 pure-classifier pins for
  `commitChainMutationClass` / `commandRunsCommit`, incl. neutral scaffolding and
  redirecting git-read families).
- E2E: 81 passing (baseline 76 → +5: scenarios 72–76). Scenario 72 = full issue repro
  (refusal → repeat refusal → split-ceremony verify→commit), 73 = write/sweep/stage/
  wrapper families, 74 = sweep+gh union(branch, WT), 75 = bare+gh union(staged) + docs
  exempt + pure-gh parity, 76 = prose-message/over-refusal guard + wrapper neutrality.
- Pinned 1–71 regression scenarios all green under the refusal + widening (the only
  pinned compound commit command, scenario 48 Leg G `git commit -m … && git commit -am …`,
  is commit+commit — never refused).

## Learnings

- Edit-tool atomicity: a multi-edit call whose SECOND oldText mismatches fails the WHOLE
  call — verify each oldText against the file before batching edits (the import-line edit
  silently failed once here and the suite ran against stale exports until re-applied).

## Residuals (documented)

- A mutation smuggled via an op whose text contains NO git commit verb in the SAME command
  still requires its own non-intercepted tool_call to create content — that call is the
  ceremony step and the NEXT commit sees it in the snapshot (gated). The gate is a
  ceremony enforcer, not a sandbox; a determined agent can always set ELDATO_SKIP_VGATE
  (the escape hatch is deliberate and audited).
- Non-neutral op AFTER the last commit in a command (`git commit -m x && git add y`) is
  not refused — it stages for a FUTURE op and is equivalent to a separate non-intercepted
  `git add` tool_call (unchanged posture).
- Repo-redirecting spellings (`git -C repo commit`) are foreign by design (#490) and never
  reach this classifier's refusal path (not intercepted).
- gh pr merge chains with local commits keep today's branch-scope behavior (out of scope;
  pathological shape, #204 merge machinery unchanged).
- `git diff --output=<tracked-file>` (a file write NOT expressed as a shell `>` redirect)
  before a sweep commit is outside the shell-shape detection — documented accepted corner
  of the shape-refusal model (any real evasion eventually requires ELDATO_SKIP_VGATE).
- review-r2/r3 corners (review-cycle adjudicated): a PURE shell payload under an execution
  modifier (`timeout 5 sh -c 'git commit -am x'`) carries the shell-carrier marker and is
  refused (over-refusal — recoverable by running the plain commit; no value-parsing of
  modifier options is attempted because the earlier peel misparsed `timeout -s KILL 10`
  and lost the commit class, re-opening the M1/M2 bypass — head-based classification is
  value-agnostic and cannot). A git READ behind a stripped prefix verb with args
  (`sudo -u me git status && git commit`) classifies the read remnant as mutating and
  refuses (over-refusal of an exotic combo).
