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
| P1 | `parallel_work_check.py` | Pre-existing 3-hunk divergence: (a) `_REPO_ROOT` ancestor-probe for the agent-infra `scripts/` layout (10 lines — swarm's `parent.parent.parent` resolves to the wrong dir here; without it `from connectors.supabase_swarm import store` fails and the checker degrades to UNKNOWN); (b) `no-card-no-scope` CLEAR branch in `_check_c3`; (c) `no-card` CLEAR branch in `_check_c4`. **Task 2 (#383 Phase B) replaces the partial CLEARs with the full no-board machinery:** the shared five-family signal constants (`_SB_URL_NAMES`/`_SB_KEY_NAMES`/`_CARD_ID_NAMES`/`_AGENT_ID_NAMES`/`_PATHS_NAMES` — 14 names, consumed by BOTH the read paths and the `_is_no_board` predicate, never prose); the predicate (absent = unset OR empty/whitespace, ANY signal → fail-closed); the distinguishable `CLEAR no-board-skip: <advisory>` verdict + `mode:"no-board-skip"` token field (`_skip` helper; C1–C5 no-board branches; the vacuous CLEARs deleted — board-mode-no-card → swarm-parity UNKNOWN); the retained git-local checks (C1 fetch/guard/dup-search, C4 fetch/behind/symbol-gated hoisted pickaxe — failures stay UNKNOWN, never skip); `GitOps.remote_url()` + cwd-based ops-target resolution (--repo → PARALLEL_CHECK_REPO → cwd — never presence-keyed); the python-side budget clamp to `PARALLEL_CHECK_BUDGET_MAX` (default 60, non-finite-safe); the ATOMIC `_apply_token` (per-invocation-unique mkstemp tmp `<tokenfile>.tmp.<unique>` in dirname — mode 0600 — + `os.rename`, finally-cleanup, write-failure → unlink-existing + `warn=token-write-failed`, unlink failures → `warn=unlink-failed`); **the code-quality round (#383 Task 2 P2/P3): `GitOps.remote_url()` strips ANY userinfo on scheme-bearing URLs — `user:pass@`, the bare-PAT form `https://ghp_…@host/...` (no colon), and `ssh://git@host/...` all → stripped (netloc rebuilt via `rsplit("@", 1)[-1]`, host:port preserved; userinfo is never part of repo identity); scp-form `git@github.com:org/repo.git` has NO scheme → no netloc → byte-identical; parse failure → "unknown"; Task-3 `bindingRepo()` MUST strip ALL userinfo identically) + lazy token_repo (resolved only on a CLEAR verdict) + the non-OSError isolation around the `_apply_token` call (`warn=token-error:<TypeName>`); the near-miss/new-signal warn notes (B27); **#378:** per-session token-file scoping — `_session_scope_suffix`/`_token_file_path` (PARALLEL_CHECK_TOKEN_FILE override wins VERBATIM → when `PI_SESSION_ID` is set (pi bash-tool child env) the default is `/tmp/parallel-check-token.<sid>.json` → else the legacy unscoped default; BYTE-wise utf-8 sanitization (`[^A-Za-z0-9._-]` → `_`, mirroring the .sh `LC_ALL=C tr -c` and the enforcer's Node-Buffer scope — a code-point regex would drift from `tr` on multibyte input); `run_check` + `main`'s exception path resolve the token via `_token_file_path` (reads the `TOKEN_FILE_DEFAULT` global at call time so tests monkeypatch it to a tmp base); docstring INTERFACE/ENV updated. |
| P2 | `parallel_work_check.sh` | #383 wrapper patch: budget clamp to `PARALLEL_CHECK_BUDGET_MAX` (env, default 60 — non-finite/unbounded values cannot stall the watchdog; raw-string regex gate because macOS one-true-awk leaves `nan`/`inf` as strings that compare lexically); `setsid` + process-group kill (Linux/CI — a hung `git fetch` dies with python instead of orphaning); error branch unlinks the token on `rc != 0` OR a non-CLEAR first-line verdict, plus a scoped tmp-glob `$(dirname)/$(basename)`*.tmp.* (watchdog SIGKILL skips python's own cleanup; a stale CLEAR token would otherwise pass the enforcer's marker advance). **#391:** both watchdog subshells redirect their stdio to `/dev/null` — on macOS bash 3.2 `kill "$watchdog_pid"` kills the subshell but orphans its `sleep` child, which previously held the caller's stdout/stderr pipe open until the full watchdog timer elapsed (every invocation under pipe capture paid budget+2.0s); the redirect makes the orphan hold `/dev/null` instead, so the caller's pipe closes when the script exits. **#378:** the wrapper derives the SAME per-session default as python (env override trimmed; else `PI_SESSION_ID` present → `/tmp/parallel-check-token.<sid>.json` via ASCII-whitespace-trimmed (python `strip(" \t\n\r\v\f")` / TS same-set parity) + `LC_ALL=C tr -c` byte-wise sanitization; else the legacy path) so the error-branch unlink targets the SCOPED file a watchdog SIGKILL leaves behind (a stale scoped CLEAR must not survive to pass the enforcer's marker advance). |
| P3 | `test_parallel_work_check.py` | Restores the 2 `CHECKOUT_GUARD_SWARM_ROOT` fixture lines at their swarm positions (the C1 bash e2e tests hang without them); xfail (strict=False) on the swarm-flaky timeout test + the deterministic `test_bash_timeout_contract` sibling + `test_bash_watchdog_unlink_on_hang` + `test_bash_watchdog_unlink_on_non_clear_verdict`; **the full B1–B34 series** (no-board skips per check, negative fences, guard/dup precedence, pickaxe hoist + symbol gate, token mode/repo, distinguishable contract, bash e2e + realistic consumer probe incl. the non-main and no-origin fork variants, repo resolution incl. insteadOf, drift-script mechanics, consumer-env fixture assertions, board-mode resolution, the 14-name predicate fold + names-parity + timeout edge/non-finite folds, vacuous-CLEAR deletion, override parity, near-miss/new-signal warns + stale-clone edge, deterministic concurrency, write/unlink-failure verdict notes, atomic mechanism, retained-check failure edges, guard-parity two-case, watchdog×concurrent-writer barrier variant + heartbeat contract, the extended B26 strip-ALL-userinfo sanitization (bare-PAT + ssh://git@ stripped, scp-form + plain https unchanged) and the non-finite-budget watchdog test (fake-interpreter hang + `PARALLEL_CHECK_TIMEOUT_SECS=inf`, bounded run, `C1: UNKNOWN`, no token)) **+ the #388 deterministic-timeout fix (mock sleep 5.0s outside the watchdog window + `CHECKOUT_GUARD_SWARM_ROOT` so the guard cannot race the budget)** + **the #378 suite (`test_378_*`): session-suffix unit folds (empty/whitespace → None, byte-wise multibyte, traversal-safe), `_token_file_path` resolution (override verbatim with a session present / session-scoped default / unscoped fallback, monkeypatched tmp base), hermetic `run_check` E2E (scoped vs unscoped write targets), enforcer-parity shape (`/tmp/parallel-check-token.<sid>.json`), and the .sh watchdog e2e (unique uuid sid, NO token override → the error branch unlinks the SESSION-SCOPED default)** + **the .sh↔python parity e2e (whitespace-PADDED non-ASCII id — python predicts the scoped path, the wrapper must unlink exactly it: pins the trim + byte-wise behavior together)**. |

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
- **Budget clamp:** `PARALLEL_CHECK_BUDGET_MAX` (env, default 60) bounds
  BOTH sides, but the two clamps are DELIBERATELY DIVERGENT — the verified
  .sh-vs-python table (all fail-closed): `inf` → .sh 2.0 vs python 60.0;
  `nan` → .sh 2.0 vs python immediate-UNKNOWN (`min(nan, max)` = nan →
  deadline nan → `budget_ok()` False); `0` → .sh 0.05 (min clamp) vs python
  0.0 (immediate UNKNOWN); `budget_max > 86400` → .sh resets to 60 vs
  python accepts verbatim. The .sh watchdog clamp is the HARD BACKSTOP: the
  raw strings are regex-gated (one-true-awk on macOS leaves `nan`/`inf` as
  strings that compare lexically, so only a plain finite decimal literal is
  accepted — anything else → default 2.0), the max cap is regex-gated +
  hard-capped at 86400s (→ 60), and the min is 0.05 — a non-finite or
  unbounded value can never stall the watchdog (kills at ≤ cap+2s →
  fail-closed UNKNOWN). The PYTHON side clamps python's OWN deadline:
  `budget = min(float(raw), PARALLEL_CHECK_BUDGET_MAX)` with the same
  env-read constant + default 60 + `except (ValueError, OverflowError) →
  default` — `float("inf")`/`"1e309"` parse without ValueError and min()
  bounds them; `float("nan")` → immediate fail-closed UNKNOWN. The
  divergences are intentional and fail-closed: the watchdog always fires
  within a bounded window (≤ cap+2s) — no stall, and a misbehaving python
  can neither stall the gate nor wrongly pass it (killed → UNKNOWN, no
  token); pinned by the B23 non-finite/upper-bound folds + the wrapper-level
  non-finite watchdog test (fake-interpreter hang with
  `PARALLEL_CHECK_TIMEOUT_SECS=inf`, bounded run, `C1: UNKNOWN`, no token).
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
  (ubuntu, setsid present) pins the reaped-tree assertion. **fd-redirect
  (#391):** each watchdog subshell redirects its stdio to `/dev/null`; on
  macOS bash 3.2 killing the subshell orphans its `sleep` child, which would
  otherwise hold the caller's stdout/stderr pipe open until the full
  `watchdog_s` (budget+2.0s) elapsed — the redirect makes the orphan hold
  `/dev/null` instead, so invocations return ≈ the python pipeline time
  (bounded by budget) rather than budget+2.0s; the residual orphaned `sleep`
  (self-cleaning within `watchdog_s`) is accepted as a benign, bounded
  residual. **Job-control caveat
  (setsid branch):** under `set -m`/interactive job control, bash backgrounds
  `setsid` into a fresh process group and it forks — the wrapper's captured pid
  is the dead parent and the group-kill misses. Non-interactive automation (the
  enforcer's actual invocation, job control off) is unaffected — setsid then
  execs directly and pid == pgid.
- **Read-only token dir:** if BOTH the token write AND the unlink fail
  (EROFS/EACCES), the failure surfaces as a `warn=unlink-failed` verdict note —
  an accepted environmental fail-open, never silent.
- **Per-session token default (#378):** the token default is no longer a single
  machine-global path. Inside a pi session the checker + wrapper resolve
  `/tmp/parallel-check-token.<sid>.json` (sid = `PI_SESSION_ID`, which pi
  injects into bash-tool children — the SAME value the sequence-enforcer
  resolves via `ctx.sessionManager.getSessionId()`), so concurrent sessions
  neither satisfy nor clobber each other's tokens. The three implementations
  (python `_token_file_path`, .sh `LC_ALL=C tr -c`, enforcer `scopedTokenFilePath`)
  sanitize BYTE-wise (`[^A-Za-z0-9._-]` → `_`) and MUST stay in lockstep — a
  divergence would split writer vs reader. Explicit `PARALLEL_CHECK_TOKEN_FILE`
  overrides win verbatim everywhere (never session-scoped). No session id
  (operator shell run / no-ctx enforcer boundary) → the legacy unscoped path on
  BOTH sides (the contract never splits). The **force file stays machine-shared**
  (#357 h) — the operator writes it by hand from a shell with no session id; the
  new-session unlink hazard is the documented cost, and a per-session force
  suffix would need an operator-visible id (deferred).
