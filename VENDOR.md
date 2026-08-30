# VENDOR.md — Vendored Swarm Artifacts (issue #383)

agent-infra vendors the parallel-work checker + its test suite + the connectors
package from [daniel-ospina/swarm](https://github.com/daniel-ospina/swarm) so a
fresh agent-infra clone has the full checker runtime (issue #383, indicator 1).

**Base rev:** `29dd67e8` — `scripts/.vendor-manifest.json` records the
byte-identical base sha256 + patched sha256 per file.

## File Table

| File | Swarm source @ `29dd67e8` | State | Ledger patch |
|---|---|---|---|
| `scripts/checkout_guard.sh` | `operations/coordination/checkout_guard.sh` | identical@base | — |
| `scripts/parallel_work_check.sh` | `operations/coordination/parallel_work_check.sh` | patched | `scripts/.vendor-patches/parallel_work_check.sh.patch` |
| `scripts/parallel_work_check.py` | `operations/coordination/parallel_work_check.py` | patched | `scripts/.vendor-patches/parallel_work_check.py.patch` |
| `scripts/test_parallel_work_check.py` | `operations/coordination/test_parallel_work_check.py` | patched | `scripts/.vendor-patches/test_parallel_work_check.py.patch` |
| `scripts/fake_supabase.py` | `tests/fake_supabase.py` | identical@base | — |
| `connectors/__init__.py` | `connectors/__init__.py` | identical@base | — |
| `connectors/supabase_swarm.py` | `connectors/supabase_swarm.py` | identical@base | — |
| `connectors/supabase_org.py` | `connectors/supabase_org.py` | identical@base | — |
| `connectors/hosted_tortoise.py` | `connectors/hosted_tortoise.py` | identical@base | — |

## Patch Ledger

Patches are machine-readable forward diffs with `a/…`/`b/…` headers using
agent-infra-relative paths — `git apply -R` (or the drift script) restores the
swarm base byte-for-byte from the repo root.

| # | File | Content |
|---|---|---|
| P1 | `parallel_work_check.py` | Pre-existing 3-hunk divergence: (a) `_REPO_ROOT` ancestor-probe for the agent-infra `scripts/` layout (10 lines — swarm's `parent.parent.parent` resolves to the wrong dir here; without it `from connectors.supabase_swarm import store` fails and the checker degrades to UNKNOWN); (b) `no-card-no-scope` CLEAR branch in `_check_c3`; (c) `no-card` CLEAR branch in `_check_c4` (the pre-#383 partial — Task 2 replaces these with the distinguishable no-board skip). |
| P2 | `parallel_work_check.sh` | #383 wrapper patch: budget clamp to `PARALLEL_CHECK_BUDGET_MAX` (env, default 60 — non-finite/unbounded values cannot stall the watchdog; raw-string regex gate because macOS one-true-awk leaves `nan`/`inf` as strings that compare lexically); `setsid` + process-group kill (Linux/CI — a hung `git fetch` dies with python instead of orphaning); error branch unlinks the token on `rc != 0` OR a non-CLEAR first-line verdict, plus a scoped tmp-glob `$(dirname)/$(basename)`*.tmp.* (watchdog SIGKILL skips python's own cleanup; a stale CLEAR token would otherwise pass the enforcer's marker advance). |
| P3 | `test_parallel_work_check.py` | Restores the 2 `CHECKOUT_GUARD_SWARM_ROOT` fixture lines at their swarm positions (the C1 bash e2e tests hang without them); xfail (strict=False) on the swarm-flaky timeout test + the deterministic `test_bash_timeout_contract` sibling + `test_bash_watchdog_unlink_on_hang` + `test_bash_watchdog_unlink_on_non_clear_verdict`; later B-series/T-series additions from the #383 plan land here too. |

## Sync & Conflict Procedure

1. **Detect:** `scripts/check-vendor-drift.sh` (live mode vs `$SWARM_ROOT`,
   default `$HOME/swarm` — the env, never a hardcoded absolute path).
2. **Verify the ledger:** `scripts/check-vendor-drift.sh --manifest` — reverse-
   applies every patch and checks `identical@base` sha256s. Exit 0 = in sync.
3. **Upstream change → sync:**
   - `identical@base` file changed: copy the new swarm file, re-run the suite.
   - Patched file changed upstream: `git -C $SWARM_ROOT show HEAD:<path>` →
     resolve conflicts against the current patch intent → regenerate the
     `.patch` (`diff -u --label a/… --label b/… base current`) → bump
     `scripts/.vendor-manifest.json` (`base_sha256`/`patched_sha256`).
4. **Local intentional change:** modify the file, regenerate its patch + the
   manifest, update the ledger table above. The drift gate (CI) fails until
   the manifest matches.

## Behavior Notes (documented, deliberate)

- **Guard config (`CHECKOUT_GUARD_SWARM_ROOT`):** the vendored guard's default
  swarm-root is the agent-infra checkout (`$CHECKOUT_GUARD_DIR/../..`). Under
  the canonical invocation that is the MAIN checkout, NOT a worktree —
  `_guard_is_swarm_root(worktree)` is false, so the main/worktree collision
  checks are SKIPPED for worktree sessions (foreign dirty-check-only verdicts).
  BOARD-mode worktree sessions MUST set `CHECKOUT_GUARD_SWARM_ROOT` to their
  swarm checkout to keep parity — the unset default diverges and that
  divergence is the documented deployment delta (pinned by B33's two cases).
- **`origin/main` assumption:** fetch/behind target `origin/main`; consumers
  with a non-main default branch fail closed UNKNOWN (B17 non-main variant),
  and the C1-guard-behind (foreign → 0) vs C4-behind (blocks) asymmetry is
  inherited from swarm — documented, not re-balanced. A consumer with no
  `origin` remote (fork layout, only `upstream`) fails closed UNKNOWN on
  C1/C4 with binding passing via both-"unknown" (B17 renamed-remote variant);
  guidance names the `origin` requirement.
- **Budget clamp:** `PARALLEL_CHECK_BUDGET_MAX` (env, default 60) clamps the `.sh` watchdog budget — non-finite values (`inf`/`nan`/`1e309`) and huge values cannot stall the watchdog indefinitely. The `nan`/`inf` strings are gated by a raw-string regex before numeric conversion (one-true-awk on macOS leaves them as strings; the numeric `x != x` NaN test is unreliable there), and the max cap itself is regex-gated + hard-capped at 86400s so a misconfigured `PARALLEL_CHECK_BUDGET_MAX` cannot re-open the stall class. The PYTHON side (`run_check`) gains the SAME clamp in Task 2 Step 4 — until then python-side non-finite budgets do NOT fail closed on their own (`float("1e309")` silently overflows to `inf`, no exception), so the clamped shell watchdog is the only bound (kills at ≤ BUDGET_MAX+2s → fail-closed UNKNOWN).
- **Heartbeats (`scripts/heartbeats/`, gitignored):** holds the guard's single
  accumulating `checkout_guard.log` — the checker itself writes NO heartbeat
  files (`heartbeat_at` is a supabase lease column); per-run heartbeat files
  with clean-exit cleanup would be a NEW vendored divergence, deliberately not
  introduced. Growth is bounded (≤ 1 file); watchdog-killed sessions leave the
  log (no per-run cleanup path — pinned by the Task 1 Step 3 residue test);
  cleanup is the documented manual procedure.
- **macOS watchdog:** `setsid` is unavailable on macOS — the wrapper falls back
  to a plain kill and a hung `git fetch` could orphan on the kill path (python
  deadlines bound git calls, so this is a narrow hang-class residual). CI
  (ubuntu, setsid present) pins the reaped-tree assertion. **Job-control caveat
  (setsid branch):** under `set -m`/interactive job control, bash backgrounds
  `setsid` into a fresh process group and it forks — the wrapper's captured pid
  is the dead parent and the group-kill misses. Non-interactive automation (the
  enforcer's actual invocation, job control off) is unaffected — setsid then
  execs directly and pid == pgid.
- **Read-only token dir:** if BOTH the token write AND the unlink fail
  (EROFS/EACCES), the failure surfaces as a `warn=unlink-failed` verdict note —
  an accepted environmental fail-open, never silent.
