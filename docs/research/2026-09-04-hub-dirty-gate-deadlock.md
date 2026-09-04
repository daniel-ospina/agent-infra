---
title: "Investigation: recurring dirty-main / hub-gate blockage — root cause, gate-design verdict, fix options (tortoise #2238)"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-04
aboutSubjects: main-worktree-guard, checkout-hygiene, hub-state-check.sh, hub-worktree.sh, record-review.sh, verification-gate, auto-sync
aboutObjects: agent-infra, tortoise, premise-labs, swarm, issue-2238, issue-1484
---

# Recurring dirty-main / hub-gate blockage — investigation

**Findings date:** 2026-09-04
**Issue:** tortoise #2238 (investigate: recurring dirty-main/hub-gate blockage).
**Scope note:** the gate (M4), its recovery tooling, and the WIP-discipline
surfaces are all agent-infra components (`main-worktree-guard`,
`scripts/checkout-hygiene/`) consumed by every repo — so the investigation
deliverable and the fix design live in agent-infra; the decision comment and
issue record stay on tortoise #2238. This doc doubles as the standalone-project
research output.

## tl;dr

1. **Root cause:** dirty sets land on hubs through **four unguarded flows** —
   hub-resident sessions whose write/edit tools are blocked falling back to
   bash python/heredoc writes (the #350-documented unguarded vector),
   epic-planning pipeline sessions run in the hub (WIP docs + untracked dirs),
   symlink-farm maintenance retargeting skill links without a commit, and
   tool-artifact writers (Playwright, screenshots, `.wrangler/`…). The 2026
   dirty set on tortoise is **legit, coherent ontology work product**
   (Problem-family object kind), not junk.
2. **Why it's never cleaned: a hygiene deadlock by construction.** Once the hub
   is dirty, M4 blocks `commit`/`add`/`checkout -b`/`stash` in the hub — there
   is **no sanctioned op that resolves a dirty-on-main hub**. The documented
   recovery hint (`checkout main && pull --ff-only`) only fixes off-main, not
   dirty-on-main. Meanwhile the **visibility layer was silently dead**: the
   launchd `hub-state-check` (the only thing that opens a "hub-state FAIL"
   issue prompting recovery) has been EPERM-dead since ≥ 2026-09-01 (TCC, #427)
   — zero hub-state issues exist despite three dirty hubs today.
3. **Verdict on the all-or-nothing gate:** the *mutations* freeze in a
   disordered hub is right (parallel-agent collision protection). But three
   over-reaches buy nothing and cost real work: blocking **new-file writes**
   (collision-free paths), blocking **unrelated ref cleanups** (`branch -D`,
   `push --delete` of branches that don't touch the dirty set), and having **no
   sanctioned dirty-set capture path** (the deadlock). The gate also ships a
   recovery hint that doesn't recover the dirty-on-main case it gates hardest.
4. **Fix options** (scoped in §5, follow-ups filed separately): (A) sanctioned
   dirty-set salvage path, (B) collision-free / unrelated-op carve-outs, (C)
   close the bash-write vector + restore visibility + route hub-resident
   sessions to worktrees. Plus an immediate per-repo dirty-set triage.

## Evidence: current hub states (2026-09-04, all repos checked)

| Repo | State | Dirty count | Composition |
|---|---|---|---|
| tortoise | dirty (on main) | 14 | 7 tracked modified + untracked `docs/planning/`, `docs/research/2026-08-31-gbrain-learnings/`, `.playwright-mcp/` |
| premise-labs | dirty (on main) | 19 | competitor `_analysis.md` (+272), untracked `.playwright-mcp/`, `.wrangler/`, screenshots, attio CSVs, `uv.lock`, `srv.pid` |
| swarm | **mid-operation wreck** | 135 | 3 `UU` unmerged (README.md, epic.md, approval.py), nested `swarm` repo dirty, 130 untracked — an abandoned merge/rebase |
| eldato / DMeer | clean | 0 | — |

Cross-repo confirmation of the issue's premise: three repos, three flavors of
root-checkout disorder, zero automated hub-state reports.

## Q1 — Which flows write to the main checkout directly? (evidence)

Forensics: dirty-file mtimes + pi session transcripts under
`~/.pi/agent/sessions/--Users-danielospina-Documents-GitHub-tortoise--/`
(recorded cwd = the hub main checkout) + reflog. Machine TZ is UTC−5; file
mtimes below are local, sessions are UTC.

| Flow | Evidence | Mechanism |
|---|---|---|
| **Hub-resident session → bash-write fallback** (primary) | Session `01a05704` (started 2026-08-31 08:52Z, cwd = tortoise hub). At 2026-09-01 03:03Z the `edit` tool on `tortoise/pack_registry.py` + `docs/ONTOLOGY.md` was **blocked by the guard**; the session then mutated files via `python3 - <<PYEOF` patches and `cat > packs/dev/manifest.yaml <<YAMLEOF` heredocs (2026-09-01 03:04–03:21Z) — the documented-unguarded bash-write vector (#350: "bash heredoc/tee/python writes are unguarded"). Session's own words: *"the guard blocked both edit/write tools — all changes are uncommitted on `main`. Want me to draft … as a GitHub issue, or hold for your review first?"* and *"This is confusing tooling layering."* The session **misattributed** the landing to a mid-command `export AGENT_ALLOW_MAIN_EDITS=1` prefix ("the bash-level guard honors the solo override — that's how the core edits landed, while the write tool doesn't", 03:07Z): the env hatch is read from the extension-host `process.env` only (`index.ts` `_getEnv`/`_isAllowMainEdits`, lines 143–158) and **cannot** be flipped by a mid-command export. The writes landed because the bash path is ungated — an enforcement-layering gap agents cannot reliably distinguish (the session's confusion is itself a finding). | write/edit tools blocked → bash python/heredoc writes (ungated) land despite the env-hatch not being active → dirty set appears → M4 freezes everything → work is trapped. |
| **Epic-planning pipeline in the hub** (#347 amplifier, confirmed live) | Epic #2080 (gbrain) planning sessions `01a05d11` (2026-09-01 13:03Z, hub cwd): wrote `/tmp` records, `cp`'d into hub `docs/planning/2026-09-01-2080-gbrain-*.md` + `docs/research/2026-08-31-gbrain-learnings/`, then `cp` hub→worktrees to commit (16:29/17:37Z). Hub copies never removed. | Pipeline WIP written to the session cwd; when cwd is the hub, docs land untracked on main. |
| **Symlink-farm maintenance** | `operations/skills/competitor-research` is a symlink; gitlink blob changed 2026-09-01 09:05 local without a commit (auto-sync / sync.sh retargeting the farm). | Farm refresh mutates tracked symlinks in the working tree. |
| **Tool artifacts** | `.playwright-mcp/` (2026-09-03 14:42 local, tortoise + premise-labs), `.wrangler/`, screenshots, attio CSVs, `uv.lock`, `srv.pid` (premise-labs). | UX/test/deploy tooling writes artifacts to session cwd. |
| **Runbook regenerators** | `docs/runbook/1987-ask-abstention-check.md` +78 lines 2026-09-02 06:31 local. | Generator/workflow scripts run from hub cwd overwrite tracked docs in place. |

Two flows the issue hypothesized did **not** appear: pre-commit partial
failures, and sub-agents — sub-agents run in worktrees (isolated). But note the
API-keys workstream session (`01a06410`) was forced to stage every doc in
`/tmp` because hub writes were blocked (the "friction" half of the issue).

## Q2 — Why is the dirty set never cleaned? (deadlock analysis)

1. **No sanctioned recovery op for dirty-on-main.** M4's recovery allowlist
   (`extensions/main-worktree-guard/classify-git.mjs`, `isHubRecoveryInvocation`)
   permits: `checkout main|master`, `fetch`, `pull --ff-only`, read-only ops,
   `worktree add/list/prune/remove`, `push origin <checked-out-branch>`,
   `stash list/show`, `branch` lists. It **blocks** `commit`, `add`,
   `checkout -b/-B`, `stash` (push/apply/pop), `reset`, `clean`, `restore`,
   `rm`, merge/rebase. A dirty-on-main hub therefore cannot be committed
   (commit blocked), cannot have its changes branched in place (`checkout -b`
   blocked), cannot have them stashed aside (stash push blocked), and cannot
   have them discarded (reset/clean/restore blocked — correctly). The only
   resolution paths are a human terminal (untracked by the guard) or an escape
   hatch — both out of reach of the agent that caused the dirt.
2. **The recovery ceremony doesn't cover the case it gates hardest.**
   `hub-state-check.sh` and the guard print `recovery: cd <repo> && git
   checkout main && git pull --ff-only` — that resolves an **off-main** hub;
   on a dirty-**on-main** hub it is a no-op (checkout) or a conflict failure
   (pull). The dirty-on-main class has no ceremony at all.
3. **The visibility layer was dead.** `hub-state-check` runs under launchd
   (every 6h, `--gh-report`, dedup on open "hub-state" issues). Since
   ≥ 2026-09-01 every run failed `Operation not permitted` (macOS TCC EPERM on
   `~/Documents` for launchd-spawned bash — #427, agent-infra). `/tmp/
   hub-state-check.log` shows the full EPERM tail; #427 + #431 document it.
   **Zero open hub-state FAIL reports exist** in tortoise, premise-labs or
   swarm today, and none ever fired for the dirty period — so no agent/session
   was ever loudly prompted to recover. (agent-infra #431 is OPEN and matches
   the checker's `hub-state in:title` dedup search, but it is the TCC-revival
   follow-up, not a dirty-hub FAIL report.)
   A secondary set -u crash (`FAIL_LINES[@]:
   unbound variable`) fired in a run that hit the unreadable-repo path (stale
   farm copy, since re-synced — P3 fragility).
4. **No hygiene sweep.** Nothing removes untracked WIP from hubs; sessions that
   `cp` docs into the hub never clean them up (no end-of-session hygiene gate).

## Q3 — Does the all-or-nothing design make sense? (verdict)

**Core: yes. Three over-reaches: no.** Evidence-based:

- **Keep:** freezing *hub mutations* (commit/add/reset/clean/checkout-forms/
  foreign push) while the hub is off-main or dirty is the right protection for
  parallel agents (2026-08-06 #74-on-#73, 2026-08-18 pr1467 incidents). A dirty
  hub is the one state where mutations are most dangerous; the freeze is cheap
  and correct.
- **Over-reach 1 — new-file writes blocked while dirty.** The issue's friction
  log: writing a brand-new doc under `docs/research/` was blocked, forcing
  `/tmp` staging for the whole API-keys session. A write to a path that is not
  currently modified or untracked cannot collide with any existing dirty change
  (the thing the block protects against). Blocking it costs hours and buys
  nothing. Carve-out: allow writes whose target is neither tracked-modified nor
  untracked-existing in the disordered hub (verified against the dirty set).
- **Over-reach 2 — unrelated ref cleanups blocked.** `git branch -D <stale
  local branch>` and `git push origin --delete <remote branch>` (both in the
  issue's blockage log) do not touch the dirty working tree or the shared
  refs of the checked-out branch. Remote cleanup had to route through
  `gh api`. Carve-out: permit branch deletes of branches other than the
  checked-out one and remote deletes whose ref is not the checked-out branch.
- **Over-reach 3 — no dirty-set capture path (the deadlock).** The
  design intends WIP preservation (push-of-checked-out-branch carve-out from
  the 2026-08-18 incident) but only for *committed* work on a stranded branch.
  Working-tree dirt (the far more common failure) has no sanctioned
  preserve-and-land path. Every dirty set therefore persists until a human
  intervenes — and when the dirty set is *legit work* (tortoise's
  Problem-family ontology edits), even the human needs a plan. This is a
  genuine design gap, not operator error.

Related ceremony frictions (Q4) get the same treatment — see §4.

## Q4 — record-review/VGATE frictions: design bugs or operator error?

Classified as **design interactions with real race components**, mostly with
existing follow-ups — not operator error:

1. **record-review head-sha staleness (#2234 needed 4 attempts):** after a
   rebase/force-push the recorded review sha no longer matches the PR head, so
   the merge gate blocks (`review-enforcer/index.ts`: "PR head has advanced
   since the review was recorded") until re-recorded at the new head. The
   re-record then fights a gh-API eventual-consistency race: `record-review.sh`
   (stale-sha guard #2133) validates the caller-supplied sha against the API's
   *current* head — during the propagation window the API still reports the old
   head and the record is refused, repeatedly. Two defects: (a) a tool-side
   race (local truth vs stale API), (b) mechanical rebases (zero content
   change) void the recorded review with no "rebase-only" certification path.
   → Follow-up candidates in the review-enforcer/record-review surface.
2. **VGATE registry (sub-agents don't inherit; merge commits demand ~100-file
   verification):** a per-session registry by design; the #336 bridge
   (audit: `gate_recovery` events) recovers verified-file sets across PASSes,
   but large upstream merges and fresh sessions still re-demand verification of
   files the session never authored. Registry-keying bugs are live in the same
   family: #426 (review-enforcer registry keyed by PR number only —
   cross-repo collision). → Follow-up: ancestry-aware / merge-root-scoped
   VGATE exemptions + cross-repo registry keying (#426, #365 session-lifecycle
   contract).
3. Sub-agent infra cuts mid-flight ("no life signs", 6h cap) are the
   session-lifecycle class (#365), out of scope here but part of the same
   "recurring ceremony pain" family.

## Fix options (scoped, with tradeoffs)

| # | Option | What | Tradeoffs | Home |
|---|---|---|---|---|
| **A** | **Sanctioned dirty-set salvage path** | Add one explicit, audited, single-purpose recovery verb to M4's allowlist for dirty-on-main hubs: e.g. `hub-worktree.sh salvage` that snapshots dirty+untracked (minus junk dirs) into a new worktree branch for PR landing, or a one-shot `git commit` of the current dirty set on main behind an explicit confirmation. Extend the printed recovery hint to cover dirty-on-main. | Pro: breaks the deadlock; legit work lands; no data loss. Con: a new escape surface in the most-reviewed guard code; risk of laundering discipline violations if not audited per-use. | agent-infra (guard + hub-worktree.sh) |
| **B** | **Collision-free carve-outs** | While dirty: allow (1) write/edit to paths not in the current dirty set (new files, untouched tracked files), (2) `branch -D`/`push --delete` of branches ≠ checked-out. | Pro: removes the highest-cost friction (docs blocked, remote cleanup via gh api); zero collision risk by construction. Con: more classification surface in a 24-round-reviewed parser; each carve-out needs probes + regressions. | agent-infra (guard) |
| **C** | **Prevention at source + restore visibility** | (1) Close the hub-targeted bash-write hole — extend #350's warn-only DETECTION toward gating tracked-path overwrites via bash (python `open(…,"w")`/heredoc/`cat >`) in a disordered hub, following the closed script-backdoor precedent. This does **not** fight the documented solo-session override (host-env, session-start — `index.ts:143–158`): a mid-command `export` never flips it, so gating bash writes only closes an ungated hole, and agents must see one coherent rule (write tool AND bash file writes both respect the same hub gate). (2) fix #427/#431 (TCC FDA grant — human decision) so `hub-state-check` fires again, and widen its recovery hint to dirty-on-main; (3) at session start, when a non-infra session's cwd IS the hub, print an actionable `hub-worktree.sh <branch>` prompt (banner exists — make it a routing nudge). | Pro: attacks the inflow, restores the alarm, makes enforcement legible. Con: bash-write gating risks false-positive blocks on legit bash workflows (why it is warn-only today) and needs regression probes; TCC fix is a human GUI decision; routing nudge can be ignored. | agent-infra (guard, bootstrap), human (FDA) |
| **D** | **Immediate dirty-set triage (ops, per repo)** | tortoise: preserve the legit Problem-family work (branch → PR), route gbrain epic #2080 docs into its worktrees, remove tool junk. premise-labs: triage 19 (competitor analysis work → branch; junk → remove). swarm: resolve/reset the abandoned merge. | Pro: unblocks all three repos now. Con: needs human sign-off on what is legit vs junk (data-loss boundary). | repo owners |

Recommendation: **A + C (structural), B (friction), D now**. A is the
must-have — without a sanctioned salvage path the deadlock recurs regardless of
prevention. B is the highest-value-per-line friction fix. C(2) is blocked on a
human TCC decision (#431); C(1) needs probes before gating (warn-only today).
Q1's layering finding (agents cannot distinguish blocked write/edit from
ungated bash writes) feeds the same workstream as C(1).

## Fix-option feasibility (code-validated, 2026-09-04)

Design-research pass against the guard implementation, so follow-up issues
carry grounded designs rather than mandates:

**A — salvage path: NOT implementable with today's allowlist; needs one narrow
allowlist extension.** Verified in `classify-git.mjs` `isHubRecoveryInvocation`
+ `index.ts` M4 block: after capturing dirty files into a new worktree branch
(`fetch` + `worktree add` + `cp` are already allowed/unguarded, and WT-local
commits + WT-branch pushes are exempt), the HUB can still not be returned to
clean — tracked-modified files are unrevertable by sanctioned ops (`git
restore`/`checkout --` blocked in M4, write tool hub-blocked). `rm` of
untracked files is ungated bash (warn-only #350), so untracked junk is
cleanable today — the tracked-dirty half is the hard part. Feasible design:
extend the existing script-content gating (`_backdoorBlock`/`scriptGitVerdict`
— the guard already classifies sanctioned scripts by their git content) to
recognize `hub-worktree.sh salvage <branch>` as a sanctioned unit that may run
a path-scoped `git restore` on the exact captured paths + `rm` the captured
untracked, after the WT commit lands. Audited (`appendJsonl` precedent).
Regression surface: `test.mjs` `m4(...)` cases pin `restore blocked` / `branch
-D blocked` today — the allowlist change must re-pin them.

**B — collision-free carve-outs: feasible with existing machinery + precedent.**
(a) Writes: the M4 write block (`index.ts` ~731–764) already computes
hub-toplevel + runs `git status` (`_hubState`); expanded porcelain
(`--untracked-files=all`) precedent exists at line 380. Carve-out = block only
writes whose target is in the dirty set (tracked-modified OR untracked-existing
paths, incl. ancestors inside an untracked directory — a sibling-collision
vector). (b) Git: the NOT-checked-out-anywhere carve-out ALREADY EXISTS in the
degradation path for `push --delete` (`index.ts` ~790–830: blocks only when
the deleted branch is checked out in a worktree/main; allows otherwise) — the
M4 classification (`isHubRecoveryInvocation` push/branch cases) is stricter and
does not mirror it. Carve-out = mirror the existing semantics into M4: allow
`push --delete <branch>` and `branch -D <branch>` when the branch ≠ the
checked-out branch (git itself refuses deleting a branch checked out anywhere,
so no sibling risk). Regression surface: `test.mjs` m4 pin `push --delete`/
`branch -D blocked` cases + new m4 allowance cases.

**C — bash-write gating: detector exists (warn-only today); flipping to gate
is the risky step.** The #350 machinery already detects hub-targeted non-git
writes (`>`/`>>`, `tee`, python `open(…,"w"|"a")`) and the WIP-pattern
inventory (`_wipFromPorcelain`, `_maybeWarnBashWrite`, throttled re-scan).
Gate = block hub-tracked-path overwrites via those vectors while the hub is
disordered (keep warn for untracked WIP — the legit scratch case).
False-positive risk on legit bash workflows is why it is warn-only today;
mitigate with probe-first development (the guard's own regression history
rewards probes). Recovery-hint widening = string change in
`hub-state-check.sh` + the guard's block messages + README. Session-routing
nudge = extend the #73 session-start inventory (~616–665) with an actionable
`hub-worktree.sh <branch>` line when a non-infra session starts in the hub.
TCC revival = human FDA decision, #431.

## Raw Notes

- 2026-09-04: gate-events audit (`~/.pi/agent/audit/gate-events.jsonl`, 27,956
  lines; histogram window ~2026-09-04 11:55Z): review-enforcer/
  verification-gate dominant (`gate_recovery` ×2525,
  `review_dispatch` ×5288, review-enforcer `gate_bypass` ×6152
  [escape-hatch family], `merge_gate_block` ×481); main-worktree-guard:
  787 `m4_worktree_exemption`, 10 `gate_bypass` all `main_edits_marker`
  (dated Aug 14/20/27/28 ×4, Aug 29 ×5, Sep 4 04:15Z ×1) — **no TTL-marker
  use by tortoise sessions Aug 31–Sep 3**. Audit silence cannot distinguish
  an env-hatched session from unguarded bash writes (env overrides are not
  audited); code + transcript support the bash-write mechanism (see Q1).
- 2026-09-04: session 01a05704 wrap-up (Sep 3 02:19Z) shows the session ran
  ~65h (Aug 31 08:52Z → Sep 3 02:19Z) spanning ontology work + trust-calibration
  research; its dirty work-product stayed on hub main the entire time.
- 2026-09-04: `docs/planning/2026-09-01-2080-gbrain-{alignment,plan}.md`
  (153KB plan) written in hub 2026-09-01 11:09–12:36 local by epic #2080
  planning sessions; worktree copies committed at 16:29/17:37Z the same day —
  hub copies orphaned.
- 2026-09-04: hub-state-check recovery hint verified against
  `classify-git.mjs` M4 allowlist — no dirty-on-main resolution op exists.
- 2026-09-04: premise-labs dirty includes tracked `product/competition/
  _analysis.md` (+272 — competitor-research output written to hub).
- 2026-09-04: swarm dirty includes 3 `UU` conflict files + 130 untracked —
  abandoned mid-merge; distinct class (needs merge resolution, not a gate).
- Prior research deduped (not re-queried): `docs/research/2026-08-14-
  shared-checkout-agent-safety.md`, `2026-08-14-checkout-discipline-homes.md`
  (agent-infra is the canonical home for the discipline), `2026-08-13-
  shared-checkout-branch-isolation.md`, `2026-08-11-git-freshness-agent-
  checkouts.md`, plan `2026-08-13-issue-265-shared-checkout-branch-ownership-
  plan.md`.
- 2026-09-04 (feasibility pass): `classify-git.mjs` `isHubRecoveryInvocation`
  re-verified — commit/add/stash-push/checkout-b/reset/clean/restore/rm block;
  only the recovery list passes; `branch -D`/`push --delete` block in M4 while
  the NON-M4 degradation path (`index.ts` ~790–830) already allows
  `push --delete` of branches not checked out anywhere (the B precedent).
  `test.mjs` pins m4 `restore blocked`/`branch -D blocked`/push-delete cases.
  Env-hatch read verified host-only (`index.ts` `_getEnv`/`_isAllowMainEdits`,
  lines 143–158) — a mid-command `export AGENT_ALLOW_MAIN_EDITS=1` cannot flip
  the gate; ungated bash writes are the mechanism (Q1).
- 2026-09-04: plain `rm` of untracked hub files is ungated bash (warn-only #350
  for WIP patterns) — untracked dirt is cleanable by an agent today; tracked-
  modified dirt is not (restore/checkout -- blocked) → the salvage-path
  allowlist gap is exactly the tracked half.
