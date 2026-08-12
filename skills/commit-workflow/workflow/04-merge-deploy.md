> **Step 4/5** | ← requires: `03-code-review.md` | → next: `05-cleanup.md`

# Merge Gate — AI Review (no human approval)

Merge is gated by AI review, not human approval. The merge proceeds when ALL of:

1. **Appropriate review clean** — the review matched to the ISSUE CONTENT + PR diff surface
   returned 0 P0, 0 P1, and 0 P2 — all findings with confidence ≥ 50 resolved (fixer loop converged;
   Qwen final gate clean when applicable). The review
   is domain-dispatched, not one-size. ALWAYS-ON reviewers: bug scan (shallow+deep), guidance
   compliance, history, prior-PR comments, and SECURITY (security-review skill — HIGH-confidence
   findings only, research-before-report). Domain reviewers as applicable: infrastructure
   (skills/extensions/.mcp.json/ontology) → Skill Infrastructure / Ontology & Templates /
   Extension Safety; UX → ux-verification; config/research/docs → proportional review.
   Dispatch per `code-review` Step 0.8 (infra detection) + Step 3.6 (surface-first dispatch; ratings scale depth)
   and `test-routing` (domain-aware verification). P2s are BLOCKERS — every finding with
   confidence ≥ 50 (any severity) must be resolved before merge (aligns with the code-review
   fixer loop exit: zero issues with confidence ≥ 50). Low-confidence items (< 50, scored false
   positives) do not block. (Confidence scores are produced by code-review Step 5 — isolated
   sub-agent scoring on a 0-100 scale; < 50 = false positives, filtered at Step 6.)
2. **Pre-flight passed** — tests/typecheck per the risk tier in `01-preflight.md`; for PRs
   touching runtime code, the affected test suites are green (regression check — no regressions).
3. **Verification gate passed** — the [VGATE] sub-agent verified all staged files (matching hashes).
4. **PR mergeable** — GitHub reports MERGEABLE (no conflicts).

> **GraphQL rate-limit resilience (#192):** `gh pr view` uses the GraphQL pool,
> which resets independently of the REST pool (`gh api rate_limit` is REST).
> Parallel sessions can exhaust GraphQL while REST stays healthy. The
> review-enforcer merge gate now resolves the head via the REST pulls endpoint
> (`gh api repos/{owner}/{repo}/pulls/{pr}` — instant recovery when only GraphQL
> is down); only if REST is ALSO unavailable does it wait for the GraphQL reset
> window and retry (bounded by `REVIEW_GATE_RATE_LIMIT_MAX_WAIT_MS`, default
> 10 min) instead of failing mid-ceremony. If a ceremony still hits "GraphQL: API
> rate limit already exceeded" on both pools, wait for the window or raise the
> cap — do NOT re-record the review.
> Note: #193 (gh pr merge --delete-branch vs worktree-locked default branch)
> will also touch 04/05 later — keep these merge/cleanup changes compatible.
5. **Current-with-main when overlapping** — if the code-review overlap signal (Step 0.9)
   flagged overlapping files OR the branch is behind `origin/main`: `git fetch origin && git
   merge origin/main` into the PR branch, then RE-RUN the affected pre-flight regression tests
   on the merged state BEFORE merging. Non-overlapping, current branches skip this (no standing
   churn). Literal conflicts surface here and remain blocked by condition 4.

**Human escalation (only for):** P0 findings requiring an architectural or security decision —
irreversible operations, data loss, security breach — and only after the code-review fixer loop
escalation (per the `code-review` skill, Step 6.5 Orchestrator Escalation) is exhausted.
Everything else proceeds unattended and auto-merges per the code-review Auto-Continue protocol.

Post-merge verification below (deploys, smoke tests, clickthrough) remains **warn-only**:
it detects problems and auto-files issues, never blocks.


## Stale-Merge Recovery (#178/#181 — strict up-to-date ladder)

On repos with "Require branches to be up to date before merging", another merge
can land between the last reconciliation and `gh pr merge` — the merge is then
blocked as stale. Recovery (bounded, then escalate):

```bash
DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
git fetch origin "$DEFAULT_BRANCH" --quiet
git -c commit.gpgsign=false rebase "origin/$DEFAULT_BRANCH" || { echo "⛔ rebase conflict — resolve manually"; exit 1; }
# RE-RUN the affected pre-flight regression tests here (same set as condition 5)
git push --force-with-lease   # the rebase rewrote a previously-pushed branch
# retry gh pr merge — MAX 2 recovery attempts, then escalate to the user
```

Distinct from condition 5 (proactive pre-merge overlap reconciliation via
`git merge origin/main`): this recovery is REACTIVE after a stale block and
uses rebase + `--force-with-lease` (single-owner agent branches; never plain
`--force`). Mandatory companion to strict up-to-date protection (project #178
plan-review fold).


## Step 3.6 — Deploy Edge Functions

**Skip if** the merged PR diff contains no files matching `supabase/functions/`.

### Detection

After merge, check which edge functions were modified:

```bash
# Get function directories changed in the PR (exclude _shared and _-prefixed dirs)
gh pr view <PR_NUMBER> --json files --jq '.files[].path' \
  | grep -oP '^supabase/functions/([^/_][^/]+)/' \
  | sort -u \
  | sed 's|supabase/functions/||; s|/||'
```

Store as `CHANGED_FUNCTIONS`.

### _shared-only PR handling

If the diff contains changes in `supabase/functions/_shared/` but `CHANGED_FUNCTIONS` is empty (only shared modules changed):

1. Identify which shared files changed
2. For each changed shared file, grep all function `index.ts` files for imports of that file:
   ```bash
   grep -rl "from '../_shared/<changed-file>'" supabase/functions/*/index.ts | \
     sed 's|supabase/functions/||; s|/index.ts||'
   ```
3. Emit a **blocking warning** naming all affected functions:
   ```
   ⚠️ Shared module(s) changed but no function index.ts files modified.
   The following functions import the changed shared module(s) and may be stale:
     - scanner-lookup
     - scanner-confirm
     - ...
   Deploy these functions manually with: supabase functions deploy <name>
   ```
4. Do NOT silently skip deployment.

### Deployment

Capture `T_deploy_start = new Date().toISOString()` before the first MCP deploy call (used by Step 3.7 for verification).

For each function in `CHANGED_FUNCTIONS`:

1. **Read source files**: Read the function's `index.ts` and identify all `_shared/` imports by scanning for `from '../_shared/'` patterns. Read each referenced `_shared/*.ts` file.

2. **Resolve `verify_jwt`** (CRITICAL — wrong value breaks auth):
   Read `supabase/config.toml` and extract the `verify_jwt` value for this function:
   ```bash
   # Extract verify_jwt for function <name> from config.toml
   VERIFY_JWT=$(awk '/^\[functions\.'"$FUNC_NAME"'\]/{found=1; next} found && /^verify_jwt/{print $3; exit} found && /^\[/{exit}' supabase/config.toml)
   # Default to true if not specified
   VERIFY_JWT=${VERIFY_JWT:-true}
   ```
   Per-function config (`supabase/functions/<name>/config.toml`) overrides if it exists.
   
   **NEVER use the MCP default (`true`) without checking config.toml first.** Many edge functions implement custom auth via `auth.getUser()` and require `verify_jwt = false`. Using `true` breaks auth because Supabase's gateway rejects ES256 JWTs against the HS256 JWT_SECRET before the function code runs.

3. **Deploy** via MCP `deploy_edge_function`:
   - `project_id`: from `supabase/config.toml`
   - `name`: function name
   - `entrypoint_path`: `index.ts`
   - `verify_jwt`: resolved value
   - `files`: array of `{name, content}` objects for `index.ts` + all `_shared/` dependencies

4. **Verify** by calling MCP `get_edge_function` — confirm `updated_at` is recent.

5. **Post-deploy `verify_jwt` check**:
   After deploying, verify the deployed verify_jwt matches config.toml:
   - Call `get_edge_function` and check the `verify_jwt` field
   - If it doesn't match config.toml: **BLOCK** and report the mismatch

### Failure Handling

- Deploy each function **independently**. On individual failure, **continue** to remaining functions.
- After all deployments complete, report results:
  ```
  📡 Supabase — deployed edge functions:
    ✓ scanner-lookup (updated)
    ✗ scanner-confirm (failed: <error>)

  ⚠️ scanner-confirm deployment failed. Deploy manually:
    supabase functions deploy scanner-confirm
  ```
- Failures are **non-blocking** — warn and continue to Step 3.7.

### Stale function advisory

After deploying PR-changed functions, compare all local functions against `list_edge_functions` to identify pre-existing drift. If any stale functions found:

```
ℹ️ Other potentially stale functions (pre-existing, not from this PR):
  - analytics-ingest (local newer by 15 days)
  - crm-sync (local newer by 30 days)
```

## Step 3.7 — Post-Merge Verification

Verifies that all deployable components from the merged PR are actually running in production.

**Skip if** the PR contains no migration files AND no edge function changes.

### Migration Verification

If the PR contained migration files (`supabase/migrations/*.sql`):

1. Query production via MCP `execute_sql`:
   ```sql
   SELECT version FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 20;
   ```
2. For each migration file in the PR diff, check its timestamp version appears in the results.
3. **New drift** (migration from THIS PR not applied): **BLOCK**
   ```
   ❌ Migration not applied: 20260327000000_add_feature.sql
      This migration was in the PR but is missing from production.
      Apply manually: supabase db push
   ```
4. **Pre-existing drift** (old migration missing, not from this PR): **WARN**
   ```
   ⚠️ Pre-existing migration drift detected (not from this PR):
     - 20260315000000_old_migration.sql
   ```

### Edge Function Verification

If Step 3.6 deployed any functions:

1. Call MCP `list_edge_functions` to get current deployed state
2. For each function that Step 3.6 attempted to deploy, verify:
   - Function appears in the deployed list
   - `updated_at >= T_deploy_start` (allowing 30-second grace for propagation)
3. **New drift** (function from THIS PR not deployed): **BLOCK**
   ```
   ❌ Edge function not deployed: scanner-lookup
      Step 3.6 reported success but function is not live.
      Deploy manually: supabase functions deploy scanner-lookup
   ```
4. **Pre-existing drift** (other stale functions): **WARN** (already handled by Step 3.6 advisory)

### RPC Verification

If any migration from this PR contains `CREATE OR REPLACE FUNCTION`:

1. Extract function names from the SQL
2. Query production via MCP `execute_sql`:
   ```sql
   SELECT proname, pronargs, proargtypes::text
   FROM pg_proc
   WHERE proname = '<function_name>'
     AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public');
   ```
3. Verify the function exists with the expected argument count
4. Check for surviving overloads:
   ```sql
   SELECT count(*) FROM pg_proc p
   JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = '<function_name>';
   ```
   If count > 1: **BLOCK** (report error, then still proceed to Step 3.8 per existing convention):
   ```
   ❌ Surviving overload detected: <function_name> has <count> overloads
      A signature change left the old overload in place — PostgreSQL will throw error 42725.
      Manual cleanup required: DROP FUNCTION IF EXISTS public.<function_name>(<old_signature>);
   ```
5. **Missing RPC**: **BLOCK**
   ```
   ❌ RPC not found: my_function(expected 3 args)
      The migration created this function but it doesn't exist in production.
   ```

### Completion

If all verifications pass:
```
✓ Post-merge verification complete:
  - Migrations: 2/2 applied
  - Edge functions: 1/1 deployed
  - RPCs: 1/1 verified
```


### Playwright Production Verification (CPI-10)

**When:** CPI-9 generated Playwright tests exist (specs/{feature}.md). Skip otherwise.

**Purpose:** Run pre-merge tests against production. Pre-merge PASS + post-merge FAIL = deploy broke something = BLOCK.

**Healer:** Read-only on production — reports failures, does not modify tests.

**Metrics:** Write operations/logs/smoke-result.json per deploy.

### Production Reachability Check

After backend verification, confirm the app itself loads in production:

```bash
agent-browser open $PROD_URL --screenshot=/tmp/verify-prod-reach.png
agent-browser get title 2>&1
agent-browser errors 2>&1
```

**Gate**: Page must return 200 and render expected content. Console errors = **BLOCK** (app is live but broken). Warn-only — the deploy is already done, but surface immediately.

## Step 3.75 — Post-Deploy Journey Smoke Test

**Skip if:**
- The PR contains only config/docs/skill-file/type-def changes (no runtime code)
- The PR is a migration-only change (no user-facing behavior)
- `ISSUE_NUMBER = 'none'` (no linked issue to track failures)

**Purpose:** Verify 1-2 critical user journeys still work after deploy. Catches "tests pass but production is broken" scenarios. **Warn-only — does not block the deploy** (deploy is already done). Auto-files a follow-up issue on failure.

### Detection — Should We Run?

Check if the PR touches runtime code that affects user journeys:

```bash
# Check if PR diff contains runtime files (pages, components, API routes, edge functions, hooks)
RUNTIME_FILES=$(gh pr diff <PR_NUMBER> --name-only | grep -E '\.(tsx|ts)$' | grep -v '\.test\.' | grep -v '\.d\.ts' | grep -v 'skills/' | grep -v 'docs/' | grep -v 'scripts/')
if [ -z "$RUNTIME_FILES" ]; then
  echo "⏭️ No runtime code changed — skipping journey smoke test"
  SKIP_SMOKE=true
fi
```

Also skip if `AGENT_SKIP_SMOKE=1` is set.

### Journey Selection

Walk up to 2 critical journeys based on what the PR touches:

| PR Touches | Smoke Test Journey |
|------------|-------------------|
| Deal pages, search, listing | **Search → Browse deals → View deal page** |
| Auth, login, profile | **Login → View profile → Logout** |
| Booking, reservations, rewards | **Search → View deal → Book reservation → Receive confirmation** |
| Edge functions, API routes | **API health check + one critical endpoint** |
| Components, UI shared | **Browse 3 random pages for console errors** |

If the PR touches multiple areas, run the most relevant journey. If unsure, default to **Search → Browse deals**.

### Execution

Use agent-browser to walk the journey against production:

```bash
PROD_URL="${PROD_URL:-https://example.com}"

# 1. Load landing page — check it renders
agent-browser open "$PROD_URL" --screenshot=/tmp/smoke-landing.png
agent-browser errors 2>&1

# 2. Verify key elements present via snapshot
agent-browser snapshot -i 2>&1 | grep -q "search" || echo "⚠️ No search input found"
agent-browser snapshot -i 2>&1 | grep -q "deal" || echo "⚠️ No deal cards found"

# 3. Mobile viewport check
agent-browser open "$PROD_URL" --viewport=375x812 --screenshot=/tmp/smoke-mobile.png
agent-browser errors 2>&1
```

### Result Handling

**On success:**
```
✓ Journey smoke test passed: Search → Browse deals
```

**On failure:**
```
⚠️ Journey smoke test FAILED: Search → Browse deals
   Error: <error details>
   
   Auto-filing follow-up issue...
```

Auto-file a follow-up issue:
```bash
gh issue create   --title "Post-deploy smoke test failure: <journey> on <date>"   --body "## Smoke Test Failure
  
  **Deploy:** PR #<PR_NUMBER>
  **Journey:** <journey walked>
  **Error:** <error details>
  **Time:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  The post-deploy journey smoke test failed after merging this PR.
  The deploy is live — this issue tracks the broken journey.
  
  **Action:** Investigate and fix the journey. The PR that introduced this is #<PR_NUMBER>."   --label "bug,ci-failure,smoke-test" 2>&1
```

**Always proceed** to Step 3.8 after smoke test (pass or fail). The smoke test is a detection mechanism, not a gate.

If any BLOCK-level issues: report the errors, then **still proceed to Step 3.8** (worktree teardown must always run, see `05-cleanup.md`). Halt before Step 4 — do not continue to documentation update.
If only WARN-level issues: continue to Step 3.8 and beyond.


## Step 3.8 — Post-Deploy Clickthrough Verification

**Skip if** the PR contains only config/docs/skill-file/type-def changes with no runtime code (same skip conditions as Step 3.75).

**Purpose:** Verify that deployed changes actually work for a real user by running **agent-executed clickthrough protocols** — the agent reads the Tortoise graph for relevant journeys, then walks the app with common sense (finding buttons by text, filling forms by label, verifying outcomes visually). This is the **user-outcome verification gate** above the infrastructure-level verification in Steps 3.6-3.7.

**Gate type:** WARN-ONLY. The deploy is already done. This verification detects problems and auto-files issues but never blocks the pipeline.

### Detection

```bash
RUNTIME_FILES=$(gh pr diff <PR_NUMBER> --name-only | grep -E '\.(tsx|ts)$' | grep -v '\.test\.' | grep -v '\.d\.ts')
if [ -z "$RUNTIME_FILES" ]; then
  echo "⏭️ No runtime code changed — skipping clickthrough verification"
  SKIP_CLICKTHROUGH=true
fi
```

Also skip if `AGENT_SKIP_CLICKTHROUGH=1` is set.

### Execution

Invoke the `post-deploy-verify` skill, which:
1. Detects deploy surface (web/desktop/infra) via `scripts/detect-deploy-surface.sh`
2. Dispatches the appropriate agent-executed protocol:
   - **web** → `web-clickthrough/SKILL.md` — agent + Playwright MCP: common-sense navigation
   - **desktop** → `desktop-clickthrough/SKILL.md` — agent + cliclick + CDP (macOS only)
   - **infra** → `infra-verify/SKILL.md` — script validation (no UI to click through)
3. Collects results, auto-files GitHub issues for failures

```
Read and follow skills/post-deploy-verify/SKILL.md.
Pass: PR_NUMBER, REPO_ROOT, DEPLOY_URL (if web), APP_PATH (if desktop)
```

### Result Handling

**On all pass:**
```
✅ Post-deploy clickthrough: all surfaces passed
```

**On failure:**
```
⚠️ Post-deploy clickthrough: 1/2 surfaces failed
   web: Journey "Primera Visita" — Step 4 FAILED (QR modal did not appear)
   → auto-filed issue #N
```
Failures auto-file issues labeled `bug` with title prefix `clickthrough-failure:`.

**On skip** (no surfaces, user declined desktop, no Playwright):
```
⏭️ Post-deploy clickthrough: no verification run
```

### Failure Modes

| Failure | Handling |
|---------|----------|
| `post-deploy-verify` skill not found | Warn, skip, proceed |
| `detect-deploy-surface.sh` missing | Warn, skip, proceed |
| Sub-agent crash/timeout | Log as error, proceed |
| Playwright MCP not available (web) | Skip web with "Playwright MCP not available" |
| cliclick not installed (desktop) | Skip desktop with install instructions |

**Always proceed** to `05-cleanup.md` after Step 3.8 (pass, fail, or skip).
