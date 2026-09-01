---
title: "#383 — Parallel-check checkpoint gates passable without swarm board — SCOPING IN PROGRESS (handoff)"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-08-29
aboutSubjects: sequence-enforcer, parallel_work_check, enforcement, checkpoint-gate
aboutObjects: agent-infra, issue-383
---

# HANDOFF — Issue #383 scoping (resume point)

> **Pipeline:** issue-workflow → task-workflow-standard (Level: task, complexity: standard).
> **Branch:** `feat/383-vendor-parallel-work-check` (created from fresh origin/main @ 1dcdb1e; 0 commits ahead).
> **Labels on #383:** `bug`, `complexity:standard`, `team:organisation-design-team`, `implementing`, `scoping`.
> **Issue:** https://github.com/daniel-ospina/agent-infra/issues/383

## Pipeline stage — where we are

**DONE:**
- Routing (task-workflow-standard) + label lifecycle + branch gate
- Phase 0.5 clarifying-questions round (20 Qs; 1 human question answered)
- Phase 1 problem-diverge (2 agents) + Phase 2 problem-converge (2 agents) — **converged**
- **Human gates passed:** Q15 → Option A (skip-by-default); scope-expansion → **Option A (full converged scope)**

**PENDING (in order):**
1. **Phase 1.5 — External Research** (axis matrix, Standard cap 8 queries post-dedup; axes: Org-Infra/Architecture medium+, Config medium+, Library-deps trigger from connectors/ imports) + consume the Deferred-to-Research queue below. Persist via `scripts/_research_append.sh`.
2. **Phase 2.5 — problem-verify** (2 parallel verifiers; check the confirmed problem + `### Axis Research` artifact; loop until no P0/P1).
3. **Phase 3 — Codebase Explorer** (1 sub-agent; affected files/patterns/deps).
4. **Phase 4 solution-diverge (1 agent) → Phase 5 solution-converge (1 agent)** — draft the plan.
5. **Phase 5.5 — solution-verify** (2 parallel verifiers).
6. **Phase 5.6 — second-model coherence check** (task model = `$SECOND_MODEL` default `deepseek/deepseek-v4-pro`).
7. **Phase 6 — Wiring Check** (hard gate: all touch points covered).
8. **Phase 7 — Parallel Review Gates** (4 agents + fix loop to NO ISSUES FOUND; fresh-context each cycle).
9. **Phase 8 — Finalize**: post plan comment to issue #383 with the `<!-- issue-scoping: v5.1 double diamond + verify -->` marker (pipeline-compliance CI reads it), labels scoping→scoped, then task-workflow-standard continues: **PLAN** (writing-plans skill) → **PLAN-VERIFY** (2 verifiers) → **IMPLEMENT** → **VERIFY** → commit-workflow (PR + code-review + merge).

## USER DECISIONS (binding)

1. **Q15 — skip-by-default (Option A):** board-dependent checks skip when `SWARM_CARD_ID` AND board URL (`SUPABASE_URL_ORG_DATA`/`SUPABASE_URL`) are BOTH absent; git-local checks still run; verdict detail carries a `no-board-skip` advisory; narrow predicate preserves fail-closed when ANY board signal exists. (NOT the opt-in `PARALLEL_CHECK_MODE=local` flag.)
2. **Scope — Option A (full converged scope):** ONE PR achieving the O/I/T:
   - Vendor checker + `checkout_guard.sh` + all 3 `connectors/` modules
   - Skip semantics distinguishable in the token/verdict contract + gate-side repo binding
   - Path rewrite: `extensions/sequence-enforcer/index.ts:819` hardcoded swarm path + 6 skill path instances (writing-plans:31, commit-workflow:17, executing-plans:15+42, issue-scoping:88+94) → `$AGENT_INFRA_PATH/scripts` (env-overridable via existing `PARALLEL_CHECK_BIN`)
   - CI wiring: call the reusable `python-ci.yml` (exists, uncalled) for the vendored pytest suite

## CONFIRMED PROBLEM DEFINITION (both converge agents, confidence 88/90)

**The parallel-check checkpoint pipeline is single-tenant (swarm) by construction — checker verdicts/token contract, enforcer path wiring (index.ts:819 + 6 skill path instances), and gate semantics all assume the swarm board — while the consuming skills are shared across repos. The fix must make C1–C5 passable for no-board tenants via a narrow tenant predicate with honest skip semantics + gate-side repo binding, distribute checker+connectors+checkout_guard.sh through a single canonical + sync, and re-point every hardcoded swarm path. C3/C4-only hand-vendoring cannot achieve the Objective.**

> **Amendment (problem-verify cycle 1, incorporated P2/P3 — verifier B):**
> - **Skip-predicate signal set (pinned in the definition, not split across Q15 shorthand + deferred answers):** the no-board skip fires ONLY when ALL of the following are absent: `SWARM_CARD_ID`/`CARD_ID`, board URL (`SUPABASE_URL_ORG_DATA`/`SUPABASE_URL`, with its key), `SWARM_TOUCHED_PATHS`/`TOUCHED_PATHS`, `AGENT_ID`/`SWARM_AGENT_ID`. ANY of these present → fail-closed exactly as today (partial-env = intended fence). The plan MUST include (a) a realistic-environment probe — run the vendored checker in an actual no-board consumer session env (fresh tortoise/DMeer checkout, whatever pi/swarm-launched sessions export) to confirm the skip fires, and (b) a negative test asserting fail-closed when only `AGENT_ID`/`CARD_ID` is present.
> - **Enforcer source + deployment boundary (bounds the ONE-PR claim):** the enforcer SOURCE lives in agent-infra at `extensions/sequence-enforcer/index.ts` (source of truth, git-tracked); the deployed copy at `~/.pi/agent/extensions/sequence-enforcer/` is a sync artifact reached via the established deploy/sync mechanism (#265 sync.sh branch-guard / auto-sync extension — #357 precedent: merge → deploy sync + md5 gate → audit window). The #383 PR covers the agent-infra source + docs; deploy-sync + md5 gate is a post-merge step, not part of the PR's git diff.
> - **Fix-mandate additions (stand-alone scope contract):** C4's git-local pickaxe MUST be hoisted before the card gate (predicate alone leaves the no-board tenant deadlocked at C4 — pre-mortem 2); C1's unconditional board scan (`list_cards` before the card branch) MUST be gated by the same predicate.
> - **Sync direction (pinned):** swarm main REMAINS the authoritative upstream (indicator 3: swarm unchanged); agent-infra holds the vendored distributor copy pinned to a recorded base rev (swarm `29dd67e8`) with a documented sync/drift mechanism (drift is proven: connectors already 28 lines stale) — agent-infra is NOT the upstream for swarm.
> - **Revival conditions (verifier A P4):** Framing 2 (vendoring-only) revives if swarm ever stops being the canonical host or a no-board path needs no checker change; Framing 3 (`skip_without: card`) revives if gate machinery must change per-skill rather than per-tenant; Framing 4 (C3/C4-only) revives if a C3/C4-only path is ever proven satisfiable against indicators 2–3. (Raw diverge/converge transcripts were never persisted to disk — handoff reconstructs them; cycle log records this provenance limitation.)

### problem-verify — Cycle 1 (gate PASS)

- Verifier A: P0=0, P1=0, P2=0, P3=0, P4=1
- Verifier B: P0=0, P1=0, P2=2, P3=2, P4=1
- Controller action: no P0/P1 → pass-through per gate mechanics (no re-dispatch). Incorporated into the confirmed definition (see amendment above): P2-a predicate signal set pinned + realistic-env probe + negative test; P2-b enforcer source/deploy boundary; P3-a C4 pickaxe hoist + C1 board-scan gating; P3-b sync direction; P4-a revival conditions; P4-b raw-transcript provenance noted.
- Research-artifact checks (both verifiers): Axis Research present with per-framing provenance ✓; high axes carry pitfalls framings ✓; Library-deps justified-skip valid ✓; 4 queries post-dedup within the 8-cap ✓.

## Verified evidence (all probed in source — do not re-derive, but re-verify before implementation)
| Fact | Evidence |
|---|---|
| Checker IS tracked on **swarm main** at `operations/coordination/` (issue's "only stale worktree" claim is wrong) | `git -C ~/swarm ls-files operations/coordination/` |
| agent-infra has NO committed copy | `git ls-files | grep parallel_work_check` empty; working-tree copies untracked |
| `checkout_guard.sh` (C1 dep) absent from agent-infra → executing-plans `parallel_check_start` can NEVER CLEAR | `_guard_runner` sources `dirname(__file__)/checkout_guard.sh`; `scripts/checkout-hygiene/` has no guard |
| C1 has TWO no-board blockers: missing guard AND unconditional board scan (`list_cards` before card branch) | `_check_c1` |
| C3 = pure board (card_id → get_card → paths → PR search); **zero git-local content** | `_check_c3` |
| C4 git-local part (fetch/behind) runs FIRST; pickaxe runs AFTER `board.get_card` (must be hoisted for no-board) | `_check_c4` |
| C2/C5 equally card+board-required (touched_paths write; release/advance orchestration) | `_check_c2`/`_check_c5` |
| Verdict contract: only CLEAR/STALE/OVERLAP/DUP_FIX/UNKNOWN; `_apply_token` deletes token on everything except CLEAR; token payload has NO mode/details field | `_apply_token` |
| `checkpointTokenOk` real-token path never checks `token.repo` (force-file path does) → cross-tenant skip-CLEAR hole (#378/#18393 adjacent) | index.ts ~712 |
| Enforcement SKILL.md NEVER references `$AGENT_INFRA_PATH/scripts` (issue target 3 = fiction; must be WRITTEN) | grep enforcement/SKILL.md |
| Real path refs: index.ts:819 hardcoded `/Users/danielospina/swarm/operations/coordination/parallel_work_check.sh` + 6 skill path instances (writing-plans:31, commit-workflow:17, executing-plans:15+42, issue-scoping:88+94; `#4907` marker at issue-scoping:87) | grep |
| `connectors/supabase_swarm.py` already STALE vs swarm HEAD (missing #4899 QA fields, #4906 renew_lease); supabase_org.py + hosted_tortoise.py identical | diff vs swarm |
| Zero no-board test coverage (33 tests, all swarm-env `_env()` fixtures); vendored test byte-identical to swarm (env-seam tests NOT yet written) | test_parallel_work_check.py |
| `python-ci.yml` reusable workflow exists but **uncalled**; ci.yml = node-ci/drift-check/cost-config only | .github/workflows/ |
| Post-#357 `pi -p` resolves warn — deadlock class only hits forced gate/strict + interactive | audit: 4354 warn / 262 gate / 2375 strict startups; 0 checkpoint_block_recovery |
| Live deadlock reproduced: `env -i python3 scripts/parallel_work_check.py plan` → `C3: UNKNOWN missing-card-context SWARM_CARD_ID` | probe |
| `_REPO_ROOT` already does an ancestor-walk for connectors/ (lines 79-87) — the local "patch" may already be correct; verify by diff vs swarm | parallel_work_check.py |

### Skip predicate (Option A, narrowed per converge)
Fail-open ONLY when ALL of: no `SWARM_CARD_ID`/`CARD_ID`, no board URL (+key), no `SWARM_TOUCHED_PATHS`/`TOUCHED_PATHS`, no `AGENT_ID`/`SWARM_AGENT_ID`. ANY board signal present → fail-closed as today (partial-env = intended fence, do NOT widen). Skip must be distinguishable from a real CLEAR (advisory in verdict line; the token contract needs a mode/flag field OR the gate treats no-board-skip CLEAR with an audit marker — decide in solution-diverge; never a byte-identical vacuous CLEAR). Gate-side repo binding: extend `checkpointTokenOk` real-token path to honor `token.repo` like the force-file path (or file as separate issue if too large — but converge marked it contract-safety-hard).

### Rejected (recorded, do not resurrect without evidence)
- `skip_without: card` frontmatter opt-out (issue's Research-Needed suggestion): requires NEW sequence-enforcer frontmatter machinery, doesn't fix C1 guard absence or path fiction; rejected on evidence by both converge agents.
- `PARALLEL_CHECK_MODE=local` opt-in flag: cleaner semantics but adds an env-propagation contract across sub-agent dispatch seams for marginal gain over Option A's narrow predicate; folded in as "explicit mode semantics discipline" only.
- Raw hand-vendoring without sync: drift is PROVEN (connectors 28 lines stale); the templates/+sync-ci-workflows.sh pattern (#303/#555) is the repo's established anti-drift mechanism — sync mechanism may be filed as separate issue per scope option B discussion, but user chose full scope.

## Deferred to Research queue (Phase 1.5 must answer)
1. Exact skip predicate membership (which env keys count as "board signal") — mostly resolved by codebase read (see above)
2. Git-local checks retained in no-board mode (C4 behind-origin + hoisted pickaxe; C3 open-PR scan only when paths claimed; C1 guard+dup-search when repo_slug determinable)
3. Distinguishable skip semantics — how other tools express "not-applicable" passes (pitfalls framing: "quietly stop protecting anything" failure mode)
4. Vendored layout + `_REPO_ROOT` ancestor-walk correctness; provenance of the untracked copy vs swarm main (byte-diff the 3 files + connectors/)
5. Which checkpoint steps across the 4 gated skills hit C3/C4 today (executing-plans start+implement, writing-plans plan, commit-workflow implement; issue-scoping prose C1/C2)
6. CI wiring pattern for the python suite (python-ci.yml params; pytest availability on ubuntu runners)

## Key files
- `scripts/parallel_work_check.sh` (119 L, untracked), `scripts/parallel_work_check.py` (820 L, untracked), `scripts/test_parallel_work_check.py` (785 L, untracked), `connectors/` (supabase_swarm.py 608 L STALE, supabase_org.py, hosted_tortoise.py — untracked)
- Canonical: `~/swarm/operations/coordination/parallel_work_check.{sh,py}` + `checkout_guard.sh` + `~/swarm/connectors/`
- `extensions/sequence-enforcer/index.ts` (deployed copy at `~/.pi/agent/extensions/sequence-enforcer/`; source at `extensions/sequence-enforcer/`)
- 5 skill files with #4907 comments (see path-refs row)
- `.github/workflows/ci-main.yml` (extension-tests job wires the TS suite; python-ci.yml exists uncalled)

## Session gotchas (learned this run — apply in the fresh session)
- **Branch ownership guard:** session baseline re-adopts new branches via the `git checkout -b <branch>` M3 carve-out in agent-infra; commits on the current branch are allowed once the baseline matches. If a commit/push to the branch is blocked with "branch ownership violated", use the TTL escape marker: `touch ~/.pi/agent/.allow-main-edits` as a BARE command (the guard stamps it with the session id on observation), then the op, then `rm -f` it. Never compound the touch with other commands.
- **Checkpoint C1 start** currently DEFERs ("checkout collision" — agent-infra has ~22 worktrees) → mapped STALE. Expected; don't chase it. The no-board skip fix is exactly what makes this stop mattering.
- **Write commit messages with the `write` tool** to /tmp and `git commit -F <file>` — heredocs break on backticks/`$()`/braces.
- **Never `git add -A`** — stage specific files.
- **Testing:** sequence-enforcer suite = `npx tsx extensions/sequence-enforcer/sequence-enforcer.test.ts` (129 tests, zero-dep). Python suite = `pytest scripts/test_parallel_work_check.py` (needs pytest; check availability). Audit hygiene gate: `wc -l ~/.pi/agent/audit/enforcement.jsonl` must be unchanged across test runs.
- **VGATE** (review-enforcer pre-merge) needs repo-relative paths in the verifier prompt; record-review.sh before `gh pr merge`.
- **Labels:** `scoping` on now; Phase 8 flips to `scoped`. Issue #357 precedent: full pipeline = scope commit → plan commit → implement commit → PR → code-review (4 cycles) → merge → deploy sync + md5 gate → audit window.
- The untracked vendoring material (scripts/parallel_work_check.* + connectors/) is the FIX CONTENT — do not delete or commit prematurely; provenance-verify against swarm main first (byte-diff), then commit deliberately in the implementation phase.

## Artifacts on disk
- Clarifying round: `/tmp/issue383-clarifying.md` (scored table, Q15 + scope decisions, deferred queue)
- This handoff: `docs/scoping/2026-08-29-issue-383-checkpoint-no-board-gate.md` (committed to feat/383)
- Diverge/converge agent outputs are NOT persisted to disk — re-derive from this doc's evidence tables (the confirmed definition + falsification table above is complete enough to stand on)
