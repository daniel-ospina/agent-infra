# Plan v2 — #1027: AGENTS.md / templates/AGENTS.base.md base-owned-region drift

> **Tier:** standard · **Domain:** adversarial (gate `materialize-agents.sh --check`; documented fail-open #600)
> **Research path:** scoping `.pi-scratch/1027-scope-v4.md` (+ v5 design note); Phase 1.5 justified skip +
> internal comparison of the three in-repo drift mechanisms. No third-party deps.
> **v2 changes:** the exit-3/4 + hook-staging/`--base-source` machinery was DROPPED (plan-review cycles 1–2
> showed it was consumer-unsafe and over-complex). Enforcement is the **required CI suite**; `--check` stays
> non-blocking for content drift (honest status, never a plain ✅) and blocking only for a missing required
> heading.
> **v3 changes (plan-review cycle 2):** (a) the required gate is disclosed honestly — it is a step in the
> PR-editable `pipeline-compliance` workflow, so the "fail-closed" claim is scoped to *suite-file-missing*
> only and step-removal/no-op is a disclosed residual of the repo's documented #713 class; (b) `--check`
> template resolution prefers the **script's own physical location** over `AGENT_INFRA_PATH` (fixes a
> worktree spurious-drift warning without any base-source plumbing); (c) exact safe-resolve primitive + the
> remaining consumer-blocking vector (the 9th heading) stated; (d) base-only **deletion** (T6) carved out of
> the acceptance claim; (e) local-mode consumer `agent-infra check` = hard fail (not a warning) — and that
> pre-existing whole-file byte-compare bug is filed as **#1048** (a materialized consumer is never byte-equal,
> so the #1045 refresh wave cannot clear it); (f) the compare mechanism + operand order + a positive control
> are pinned.

## Problem
`templates/AGENTS.base.md` (ships to every consumer) and agent-infra's `AGENTS.md` (same universal rules +
repo-specific sections) diverged in the base-owned region (65 diff lines; `$15` vs `$10`; typos; `## Memory
Hygiene` deleted; a research step only in the repo). `scripts/materialize-agents.sh --check` cannot see it:
it validates 8 headings by presence, skips the content compare for marker-less files (agent-infra included)
and whenever the template does not resolve, and prints `✅ … materialized (all base markers present)`.

## Design decisions
1. **Content direction.** Promote the `Fix Broken Infrastructure` enrichment (research/SOTA step, "ask for
   credentials", durable-solutions framing — typos fixed) to the **base**; conform the repo to the base for
   everything else; declare the two agent-infra-specific blocks (`Vendored swarm artifacts`,
   `Durable Dispatch Record #783`) behind `<!-- REPO-SPECIFIC (agent-infra): … -->` **in `AGENTS.md` only**
   (never in the base — that would ship an agent-infra marker to every consumer).
2. **Required headings = 9** (existing 8 + `#### Hard Cap`). Missing → exit 1. **Precedence:** the presence
   check runs BEFORE the content compare, so deleting a required heading is a STUB (exit 1) while deleting a
   *paragraph under a surviving heading* is content drift.
3. **Enforcement split (honest scope).** `--check` content drift is **non-blocking** (exit 0, distinct ⚠️
   status, no plain ✅). The **blocking** gate is `tests/materialize-agents/run.sh` added as a **step in the
   existing `pipeline-compliance` job** (NOT a new job — a new job would not be the required context). Its
   real-repo pin (`^<`==0) reds a stale `AGENTS.md` for base **additions/modifications**. This is needed
   because the local hook is dead in agent-infra (`core.hooksPath` unset, #672).
   **Disclosed limitation:** that workflow is PR-editable (every CI gate in this repo is — the documented
   #713 class). The step's guard is the three-branch shape in task 6 (a *missing* suite in the agent-infra
   checkout → `::error:: exit 1`; a consumer checkout → `::notice::` skip). A PR that **removes the step** or
   **no-ops the suite** can still merge green. Not claimed as fail-closed. The optional hardening (add
   `pipeline-compliance.yml` to `LOCKED_FILES`) is rejected here because `check-pi-pin-lockstep.mjs:1978`
   hard-asserts the locked set — a cross-guard change out of this issue's scope.
4. **Content compare (mechanism pinned):** marker file ⇒ existing exact head compare (unchanged). Marker-less
   ⇒ `diff`-based line-subsequence compare (extras allowed), implemented as
   `if DIFF_OUT=$(diff "$BASE" "$f"); then drc=0; else drc=$?; fi` (template FIRST; `^<` = base line absent
   from the consumer), `drc==2` ⇒ internal-error line, else `BASE_ONLY=$(grep -c '^<' <<<"$DIFF_OUT" || true)`
   — the `|| true` is a **script requirement** (under `set -euo pipefail` a bare `grep -c` returning 1 on
   zero matches would abort, and `diff` returning 1 on any difference would too). Drift is exit 0. No
   base-source plumbing; the compare runs for any repo whose template resolves. Legacy marker-less consumers
   thus get a non-blocking warning — accepted, migration tracked in #1042.
5. **Exit contract = 0/1/2** (materialized / stub-or-missing-heading / usage). No new codes. The #600
   invariant (unresolvable template ⇒ skip the compare, never exit non-zero) is preserved; `--check` resolves
   the template **read-only** and must NOT call the fatal `resolve_base_template`.
   **Exact safe primitive** (named so the #600 trap cannot be reintroduced):
   `BASE_DIR="$(cd -P "$(dirname "$0")" && pwd -P)/.."`; prefer `"$BASE_DIR/templates/AGENTS.base.md"` when
   it exists (this is the **physical script location** — a worktree resolves its own base; a symlinked
   consumer's `scripts/` resolves to the agent-infra install), else fall back to
   `"${AGENT_INFRA_PATH:-}/templates/AGENTS.base.md"`; if neither exists set `BASE=""` and skip the compare.
   Resolution happens **after** the heading gate; a missing template takes the skip path (exit 0).
6. **Honest success lines** (exact text pinned by tests):
   - clean, compare ran (marker-less): `✅ <repo>: materialized (9 base rule headings present; all base lines present in order — repo additions allowed)`
   - marker-less compare skipped (template unresolvable): `✅ <repo>: materialized (9 base rule headings present; content compare skipped — base template not resolvable)`
   - marker-file clean: `✅ <repo>: materialized (9 base rule headings present; base head matches AGENTS.base.md)`
   - drift (both marker-file and marker-less): `⚠️ base head differs from current AGENTS.base.md — <N> base line(s) missing/modified; refresh with --merge`
     then `⚠️ <repo>: materialized (9 base rule headings present) but BASE-OWNED CONTENT DRIFTED` (no plain ✅) · exit 0
     (the `base head differs` first line is emitted on the marker-less path too, deliberately, for legacy-hook
     compatibility — a comment records this; the machine key is `BASE-OWNED CONTENT DRIFTED`, emitted on BOTH paths)
   - internal `diff` error (rc 2): `⚠️ <repo>: materialized (9 base rule headings present) but base-owned content compare could not run (internal error)` · no plain ✅ · exit 0
   The `base head differs` substring is retained deliberately for legacy/unmigrated hook copies (the updated
   hook matches on `BASE-OWNED CONTENT DRIFTED` instead); a comment records this.
7. **Hook (`check-agents-materialized.sh`):** keep the existing stage guard (`AGENTS.md` only — a base-only
   commit is caught by the required CI pin, not the dead local hook). Keep the `if ! OUTPUT=…` shape (only
   rc 0/1 now). rc 0 ⇒ echo the materializer output, then print `✅ … gate: passed` only when the output has
   no drift/internal marker, else `⚠️ [agent-infra] AGENTS.md materialization gate: markers present, but
   base-owned content DRIFTED (non-blocking; the required CI check pins content)`. rc 1 ⇒ existing STUB block.
   **Remaining consumer-blocking vector (stated, not overclaimed):** rc 1 fires when a required heading is
   missing, so **any consumer whose `AGENTS.md` lacks `#### Hard Cap`** (the base has carried it since its
   creation `1e038c4`, so this is the legacy hand-written population, not materialized consumers) is blocked
   on its next `AGENTS.md` commit until re-materialized. Bounded by the marker-aware STUB message; migration
   → #1042. `.husky/pre-commit` itself needs no change (caller contract stays 0/1) but is listed in the map.
8. **Alternatives considered.** Give agent-infra's `AGENTS.md` an `<!-- AGENTS-BASE-END -->` marker and rely
   on the existing exact head compare. Rejected: the repo's extras are **interleaved** between base lines
   (`Vendored` at line 77; `Durable Dispatch` at 194–227), so the marker needs a tail reorganisation — a
   riskier, larger change than a subsequence compare, and it is a layout migration the issue does not ask for.

## Task breakdown (TDD)
1. **`tests/materialize-agents/run.sh` first** (bash, no network, temp fixtures):
   - T1a marker-less fixture missing `#### Hard Cap` → exit 1; T1b missing another heading → exit 1;
     assert the remediation message branches on marker presence.
   - T2 base-owned **paragraph** deleted, heading intact → ⚠️ `BASE-OWNED CONTENT DRIFTED`, **no** plain ✅, exit 0.
   - T3 a base line **modified** → drift status, exit 0.
   - T4a extra section appended; T4b extra block **spliced between two base lines** → clean ✅ (compare-ran text).
   - Reorder control: two base lines swapped → drift.
   - Identical files → clean ✅ AND `BASE_ONLY`==0 (the `grep -c … || true` + pipefail control).
   - Marker-file: head == template → clean; head modified → drift warning, exit 0.
   - Skip path: template unresolvable → `content compare skipped`, exit 0.
   - Env: `env -u AGENT_INFRA_PATH` → compare still runs via the script default (fixture == real base → clean).
   - Hook-level: temp git repo, AGENTS.md with a base line deleted, staged → `⚠️ … DRIFTED`, no green
     `passed`, exit 0. (`git init` is blocked locally by the hub-state gate — print a visible `SKIP` on that
     failure; it runs in CI.)
   - Regression pin (explicit operand order): `diff templates/AGENTS.base.md AGENTS.md | grep -c '^<'` == 0,
     "clean" = `--check .` exit 0 AND its output contains neither `BASE-OWNED CONTENT DRIFTED` nor the
     internal-error marker. Positive control: copy the base, delete one line → count ≥ 1 (proves the counter
     is not vacuous).
   - Anchor pin: `grep -c 'adversarial-bound: cap=2'` == 1 in each AGENTS file.
2. `scripts/materialize-agents.sh` — decisions 1–6; header/`usage` documents 0/1/2 and the #600 invariant.
3. `scripts/check-agents-materialized.sh` — decision 7.
4. `templates/AGENTS.base.md` — Fix-Broken enrichment (anchor untouched).
5. `AGENTS.md` — conform + restore `## Memory Hygiene` + `$10` + typos + declared blocks; `^<`==0.
6. CI: a new **step in the existing `pipeline-compliance` job** (`.github/workflows/pipeline-compliance.yml`),
   shape: `if [ -f tests/materialize-agents/run.sh ]; then grep -q '^<' tests/materialize-agents/run.sh || { echo "::error::suite carries no real-repo pin"; exit 1; }; bash tests/materialize-agents/run.sh; elif [ -f manifest.json ] && [ -f bin/agent-infra.js ]; then echo "::error::…"; exit 1; else echo "::notice::consumer checkout — skipped"; fi`
   (the self-integrity grep sits INSIDE the suite-exists branch so it cannot run — or red — on a consumer
   checkout). `.github/workflows/ci.yml` `drift-check` job runs `bash tests/materialize-agents/run.sh`
   (visible). Re-record `scripts/workflow-lock.json`. Acceptance: the required context name stays
   `pipeline-compliance`.
7. This plan doc; 8. scoping comment on #1027 (`<!-- issue-scoping:` marker on line 1 or the first content
   line after leading blanks/ATX headings, **or** a blank-line-separated footer whose last line is the marker).

## Integration Surface Map
| Surface | Change | Test / guard |
|---|---|---|
| `templates/AGENTS.base.md` | text | real-repo pin; anchor ×1; `tests/drift/run.sh` re-run |
| `AGENTS.md` | text | real-repo pin (`^<`==0); anchor ×1 |
| `scripts/materialize-agents.sh` | gate | T1–T4, skip, env, reorder |
| `tests/materialize-agents/run.sh` | NEW suite | self; wired into ci.yml + pipeline-compliance; SIGPIPE scan set |
| `bin/agent-infra.js` | consumer of base | unchanged; consequence documented + pre-existing bug #1048 |
| `scripts/check-agents-materialized.sh` | hook | hook-level ⚠️ case (CI) |
| `.github/workflows/{ci,pipeline-compliance}.yml` | CI | local mirrors + `check-workflow-lock` |
| `scripts/workflow-lock.json` | lock | `check-workflow-lock.mjs` |
| `docs/ops/guarded-paths.md` | doc | update: new CI leg; hook inert until #672 |
| `.husky/pre-commit` | caller | unchanged (contract stays 0/1) |
| `tests/drift/run.sh` | fixture copies base | re-run |
| SIGPIPE scan set | gate | `check-no-sigpipe-grep.sh` |

## Risk / failure modes
| Risk | Impact | Mitigation |
|---|---|---|
| Base bytes change → consumer `agent-infra check` local mode exits 1 (`tier: fail`; only `--ci` is warn-only) | hard local failure | structural pre-existing mismatch filed as **#1048** (a materialized file is never byte-equal; #1045 cannot clear it) |
| New 9th heading blocks a pre-`1e038c4` marker consumer | their commit blocks | STUB message branches; consumer migration → #1042 |
| Legacy marker-less consumers get warnings | bounded noise (only when AGENTS.md staged) | accepted; #1042 |
| Required-check suite **missing** | fail-open | guard → `::error:: exit 1` |
| Required-check step **removed** / suite no-op'd | fail-open, PR-editable | **disclosed residual (#713 class)** — not claimed fail-closed; cross-guard lock change out of scope |
| Base-only commit that **deletes** base lines | stale extra rules in `AGENTS.md` survive (`^<`==0) | T6 declared OUT; noted as residual |
| Local hook dead in agent-infra (#672) | no local block | required CI pin is the enforcement; documented |
| `diff` edit-script heuristic | over-report (`^<` on moved lines) / under-report (T6) | real-repo pin + identical/reorder controls; both directions disclosed |

## Acceptance criteria
- `AGENTS.md` contains every line of the base, in order, unmodified (`^<`==0); one cost value (`$10/mo`);
  typos gone; `## Memory Hygiene` restored; `#### Hard Cap` in the required list; anchor ×1 per file.
- `--check` reports drift for a deleted/changed base paragraph and never prints a plain ✅ in that case;
  success lines name exactly what was asserted.
- Required CI suite fails on a stale `AGENTS.md` for base **additions/modifications**; base-only **deletions**
  are a declared OUT-of-scope residual (T6).
- Local green: `check-skill-lint`, `tier-config-parity` (52/0), `termination` (46/0), `materialize --check .`,
  `tests/materialize-agents/run.sh`, `tests/drift/run.sh`, `check-no-sigpipe-grep`, `check-workflow-lock`
  (after `--update-lock`).

## Adversarial Threat Surface
T1 missing heading → exit 1 · T2 paragraph deleted, heading intact → drift, no plain ✅ · T3 line modified →
drift · T4 repo addition → not drift (appended **and** interleaved). OUT: T5 duplicate base line; T6
base-template shrinkage; T7 undeclared extras. Acceptance = T1–T4 tested + green CI.

## Content direction (per divergence — explicit)
| Divergence | Direction | Why |
|---|---|---|
| Auto-Continue first line | conform repo → base | base's absolute default + explicit pause list; the repo edit narrowed the escape to "hard dependency" |
| P0 cost gate `$15` vs `$10` | conform repo → `$10` | **forced:** `$10/mo` on the base + 7 skill files (12 occurrences); `$15/mo` nowhere else |
| Fix-Broken 4-step vs 5-step | **promote repo → base** | the research/SOTA step is the corrective to the rule's own documented 2026-08-05 incident — the base is genuinely deficient |
| `Good > Easy` SOTA sentence | conform repo → base | `## Research Discipline` already covers research-before-acting |
| `File Pre-Existing Bugs` SOTA sentence | conform repo → base | base rule complete; refinement filed (#1041) |
| Auto-file dedup wording | conform repo → base | refinement filed (#1041) |
| `## Memory Hygiene` | restore from base | base owns it; the #1020 edit deleted it |
| typos | conform repo → base | base is clean |
| `Vendored swarm artifacts`, `Durable Dispatch #783` | keep, declared repo-specific | not universal; would ship agent-infra specifics |

## Learnings
(filled after execution)
