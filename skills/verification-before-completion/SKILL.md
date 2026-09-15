---
name: verification-before-completion
description: "Proof-of-work gate before claiming any task is done. Runs verification appropriate to the task type (code → typecheck+tests, deploy → browser screenshot, content → schema validate). Use whenever Pi is about to tell the user something is 'done' or 'fixed.' Not tied to commit-workflow — covers non-commit verification (research, content, config, deploy)."
subjects.team: organisation-design-team
allowed-tools: read write edit bash
version: 1.2.0
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Verification Before Completion

## Overview

Agents are comfortable saying "Fixed" or "Done" without evidence. This skill makes Pi **prove the work** before claiming success.

## When to Invoke

- After implementing a feature (before `commit-workflow` pre-flight)
- After deploying something (edge function, migration, config change)
- After writing content (editorial, deal, guide)
- After making configuration changes
- After fixing a bug
- After scoping an issue (confirm verification gates passed)
- Before telling the user "this is ready" / "done" / "fixed"

## Scoping Verification

**⛔ MANDATORY before claiming scoping is complete.**

The `issue-scoping` skill (v5.1.0) has integrated verification gates — `problem-verify` and `solution-verify` (or `full-diamond-verify` for Micro). Each gate dispatches verifier sub-agents that check diamond quality (diverge thoroughness, converge rigor, quality over convenience).

This section is a **thin confirmation wrapper** — it does not re-verify. It confirms the gates ran and passed.

### Step 1 — Check Gate Results

Read the scoping plan comment:

```bash
gh issue view $ISSUE_NUMBER --json body -q '.body' | grep -A5 "Verification Gates"
```

Expected output (varies by tier):
```
## Verification Gates

> **Finding contract — `consequence:` required** (canonical: `proportional-gates` §Findings Must Declare
> Consequence). Every finding from every verifier this skill dispatches must declare
> `consequence: <what breaks, who observes it>`. Without an adequate one the finding is **advisory:
> non-blocking, not counted toward this gate, and not filed as an issue** (it is still recorded in the
> cycle log). A cycle with ≥1 finding and none adequate is malformed reviewer output, not clean: record
> `⚠️ reviewer returned N consequence-less findings`, re-dispatch once, and exit non-clean. "Clean" is
> this gate's own full clean token, never a count.
<!-- Standard/Complex: -->
### problem-verify: N cycles, clean
### solution-verify: N cycles, clean
<!-- Micro: -->
### full-diamond-verify: N cycles, clean
```

### Step 2 — Gate Confirmation

| Result | Action |
|--------|--------|
| Both gates clean | ✅ Scoping verified. Proceed to label transition. |
| Gate shows "N issues remain" | ❌ Do NOT claim scoping done. Re-open the gate and re-verify. |
| No Verification Gates section | ⚠️ Scoping was run with pre-v5.1.0 skill. Gate missing — escalate to human. |
| Micro tier: full-diamond-verify clean | ✅ Scoping verified (same check). |

### Step 3 — Evidence

```
## Scoping Verification — #N
**problem-verify:** N cycles, clean  (or **full-diamond-verify:** N cycles, clean for Micro)
**solution-verify:** N cycles, clean  (skip for Micro)
**Result:** ✅ Gates passed
```

No sub-agent dispatch needed — the gates already ran during scoping.

<HARD-GATE>

## Verifier Sub-Agent Dispatch (Code Changes Only)

For ALL code changes (any `.ts`, `.tsx`, `.js`, `.jsx`, `.sql`, `.json` file touched), dispatch an independent verifier sub-agent before claiming "done."

**Dispatch command:**
```
subagent(agent='verifier', task='[VGATE] verify files: <space-separated list>. Classification: <UI|backend|both>. Project root: <PROJECT_ROOT>.', cwd=<PROJECT_ROOT>)
```

The verifier runs typecheck + tests + lightweight test-quality gate for changed `.test.ts`/`.test.tsx` files.

Verifier result format:
```
ISSUE:
  check_type: <type>
  severity: P0|P1|P2
  location: <file>:<line> or [section name]
  description: <what's wrong>
  suggestion: <how to fix>
```

**Skip only when:** No code files were changed. **Micro fix fast-path (#6699):** For complexity:micro fixes (1 file, <20 lines, no schema changes), skip verifier sub-agent dispatch.

**Micro fix in-session commit:** Set `ELDATO_SKIP_VGATE=1` and `AGENT_SKIP_REVIEW_GATE=1` before session start, run typecheck + affected tests, commit normally.

</HARD-GATE>

## Outcome Verification (NEW — #6544)

**⛔ MANDATORY for all task completions where an issue exists.**

Before claiming "done," verify the desired USER OUTCOME was achieved.

### Step 1 — Check Verification Plan

```bash
gh issue view $ISSUE_NUMBER --json body -q '.body' | grep -A20 "Verification Plan"
```

### Step 2 — Outcome Test

| Outcome type | Verify by |
|---|---|
| User action → system response | E2E test or manual walkthrough |
| Process running continuously | Check daemon alive + health endpoint |
| UI element appearing | Screenshot or DOM assertion |
| Message delivered | Check receiving system (Slack, email) |
| Data persisted | Query the database/state file |
| Config applied | Read config + verify runtime behavior |

**Gate:** At least ONE outcome verification must pass with observable evidence.

### Step 3 — Evidence

```
## Outcome Verification — #N
**Expected:** <from issue>
**Method:** <how tested>
**Evidence:** <output, screenshot, log>
**Result:** ✅ PASS | ❌ FAIL | ⚠️ PARTIAL
```

### Step 4 — No Silent Skips

If outcome cannot be verified automatically: file a test gap issue, document manual steps, ask user to confirm.

## Change Classification (UI-visible)

```bash
cd <PROJECT_ROOT> && git diff --name-only HEAD~1 > /tmp/verify-changed.txt
grep -E '\.(tsx|css|scss)$' /tmp/verify-changed.txt  # UI files
grep -E '\.(sql|edge\.ts|functions/)' /tmp/verify-changed.txt  # backend files
```

| Files found | Classification |
|-------------|----------------|
| Only `.tsx`/`.css`/`.scss` | UI |
| Only `.sql`/`.edge.ts`/`functions/` | backend |
| Both | both |
| Neither | backend (default) |

## CTA Click-Through Checklist

- [ ] **Typecheck:** `npx tsc --noEmit` → 0 errors
- [ ] **Tests:** `npx vitest run --changed` → 0 failures
- [ ] **Build:** `npm run build` → exit code 0 (UI changes only)
- [ ] **Verifier sub-agent:** Dispatched and returned PASS
- [ ] **No regressions:** `git diff` shows only intended changes

## Proportional Verification Strategy

| Risk Level | Change Type | Verification |
|------------|-------------|--------------|
| Low | Docs, config, labels, i18n | Hash files only. No typecheck. |
| Medium | 1-3 TS/TSX files, no shared infra | Typecheck + tests + verifier (convergence-gated — see the 10-cycle cap below) |
| High | 3+ files, migrations, auth, shared infra, desktop app | Full suite + verifier (convergence-gated) + browser screenshot |
| Critical | Data migrations, auth changes, payment flows | Full suite + verifier + browser on all routes + schema validate |

## Review Loop (CPI-5 — Convergence-Gated)

When the verifier sub-agent returns issues: fix flagged issues → re-dispatch → repeat until clean. Max 10 cycles.

**Stuckness detection:**

| Signal | Threshold | Action |
|--------|-----------|--------|
| Fingerprint `location + severity` — **never** `description`/`suggestion` (a fresh reviewer re-words the same defect; hashing the wording makes recurrence read ~0 on a real stall) | — | — |
| Recurrence `|current ∩ prev| / |prev|` ≥ `stall_threshold` (default `0.8`) | Fingerprint-stall | Escalate to human with stuck issue + attempted fixes |
| Issue count non-decreasing 3 consecutive cycles — **fires on its own, regardless of recurrence** | Honest-stuck | The loop is not shrinking (churn, or issues outpace fixes) — escalate |
| No file changes 2 cycles | Zero-progress | Fixer making no progress — escalate |

> **Fire if `recurrence ≥ stall_threshold` OR the count is non-decreasing for 3 cycles.** Either alone is sufficient; they are independent signals for different pathologies. Recurrence picks the *label* only (`honest-stuck` when the count is not shrinking, else `fingerprint-stall`) — never a precondition for the count signal.

**Exit outcomes:** CLEAN (zero issues), Convergence (shrinking set → escalate), Stall, Honest-stuck, Capped (10 cycles).

## Pre-existing Failure Detection

```bash
cd <PROJECT_ROOT> && git stash push -m "pre-verify-stash" && npx tsc --noEmit 2>&1 | tail -20 > /tmp/verify-base.txt; cat /tmp/verify-base.txt; git stash pop
```

New failures (not in base) block "done" claim. Pre-existing failures are documented.

## Verification Strategy by Task Type

### Code Changes
```
npx tsc --noEmit 2>&1 | tail -5 > /tmp/verify-tsc.txt && cat /tmp/verify-tsc.txt
npx vitest run --reporter=verbose 2>&1 | tail -20 > /tmp/verify-tests.txt && cat /tmp/verify-tests.txt
```
Gate: 0 typecheck errors, 0 test failures. New modules must have test files.

### Deploy (Edge Functions, Migrations, Desktop App)
```
supabase functions list 2>&1
agent-browser open $PROD_URL --screenshot=/tmp/verify-deploy.png
```
Desktop app: invoke `app-test` skill.

### Content (Editorial, Deal, Guide)
```
agent-browser open <page-url> --screenshot=/tmp/verify-content.png
```

### Bug Fix
Reproduce before fix → apply fix → verify repro case passes → run covering test.

### Config Changes
```
cat <config-file> | python3 -m json.tool > /dev/null 2>&1  # JSON
# or language-appropriate validator
```
Gate: config parses without errors. If runtime-required, restart and check logs.

### Research/Decision Verification

Self-audit: was research invoked? Adversarial queries run? Contradictions resolved? Review cycle completed? Claims traceable to sources?

## Browser Verification (agent-browser)

- **Basic Health:** `agent-browser open <url> --screenshot=/tmp/verify-<task>.png`
- **Console Errors:** `agent-browser open <url> --console 2>&1`
- **Mobile Viewport:** `agent-browser open <url> --viewport=375x812 --screenshot=/tmp/verify-mobile.png`

## Verification Gate

| Result | Action |
|--------|--------|
| **CLEAN** | "✅ Verified: <what was checked>." Proceed. |
| **WARNINGS** | "⚠️ Verified with warnings: <list>." Claim "done" but note warnings. |
| **FAILURES** | "❌ Verification failed: <specific>." Do NOT claim "done." |

### Approval Routing (inlined from human-input-framework v2.1.1)

> **Canonical:** `skills/human-input-framework/SKILL.md` → "Approval Routing — Canonical".
> Inlined operational excerpt — cross-session resilience: this skill must run in a fresh session
> without loading the framework skill first. Only the operational core is inlined; the status table,
> store/transport contract, and Slack enablement live canonically (restating them is how the original
> six copies drifted apart).

When a human gate fires — proof adjudication: FAILURES that block the "done" claim, stuck review loops (stall / honest-stuck / zero-progress escalation), or missing gate evidence ("No Verification Gates section") — the agent MUST invoke the approval router to surface the request:

```bash
# Portable invocation (works from ANY repo checkout — swarm #1402 rollout):
python3 -c "
import os, sys
sys.path.insert(0, os.environ.get('SWARM_ROOT', os.path.expanduser('~/swarm')))
from operations.coordination.approval import request_approval
request_approval('product-implementer', artifact='<verify-evidence>.md', context='<task> proof gate for issue <N>')
print('Approval request created')
"
```

⛔ **No dialog pops — do not wait for one.** A `pending` request fires a macOS *notification banner*
(`osascript … display notification`), which has no buttons and no answer path; it is best-effort and
silently no-ops on non-macOS/CI/SSH. Reaching a human on Slack needs more than `SLACK_BOT_TOKEN` +
`SLACK_APPROVAL_CHANNEL`: the bridge derives a **different** store slug than the router, so
`SLACK_APPROVAL_FILE` must be pinned to the router's store (agent-infra #956) or the request just
waits in `~/.swarm/approvals/<slug>.json`.

**Detect the answer — read the record, never infer from a shrinking list:**
```bash
SWARM="${SWARM_ROOT:-$HOME/swarm}/operations/coordination/approval.py"
python3 "$SWARM" --pending --role human    # still open
python3 "$SWARM" --status <req_id>         # this record's status + reviewer
```
A Slack thread reply sets `changes_requested`, which leaves `--pending` **without approving**;
`is_approved(..., requires_human=True)` also returns `False` after a Slack *button* approval (the
bridge overwrites `reviewer` with the clicking user's id — agent-infra #959). Trust `status == 'approved'`.

**Role-based escalation:** with `APPROVAL_AUTO_APPROVE=0`, omitting `requires_human=True` pends for
the requester's `reports_to` role — e.g. `product-strategist` for `product-implementer`; only
`chain[1]` is used, so nothing walks the chain further. Under the default (`APPROVAL_AUTO_APPROVE`
unset, which means `1`) such a request **auto-approves** and never reaches a human — **unless** an
escalation keyword (`deploy`/`delete`/`destroy`/`migrate`/`release`) appears in the artifact/context,
which pends for a human regardless. Pass `requires_human=True` for a real human checkpoint.

⚠️ **This gate currently passes no `requires_human`**, so under the default config it auto-approves —
a FAILURES verdict does not reach a human unless an escalation keyword happens to appear in the
artifact/context (agent-infra #964). Raising it to `requires_human=True` is a deliberate behaviour
change needing its own review; this excerpt documents the current truth.

## What NOT to Verify

- Don't run full test suite for one-line comment change
- Don't open browser for backend-only changes
- One verification method is enough

## RECENT_INSPECTIONS / Tool Output Gap

For critical verification outputs, pipe to file then `read`:
```bash
npx vitest run 2>&1 | tail -20 > /tmp/verify-result.txt
cat /tmp/verify-result.txt
```

## Integration with execution-intent

| Profile | Verification Behavior |
|---------|---------------------|
| **Fast** | Type-appropriate. Report results. |
| **Autonomous** | Type-appropriate + one extra check. Auto-fix to convergence (10-cycle safety cap) — no profile-level retry ceiling. |
| **Budget** | Minimum viable check. Skip browser unless deploy. |

## Examples

### Scoping — "Scoped issue #123"
```
gh issue view 123 --json body -q '.body' | grep -A5 "Verification Gates"
# problem-verify: 2 cycles, clean
# solution-verify: 1 cycle, clean
```
✅ Scoping verified: both diamond gates passed.

### Code — "Refactored the card component"
```
npx tsc --noEmit && npx vitest run src/components/Card
```
✅ Verified: typecheck clean, 12/12 tests pass.

### Deploy — "Deployed new edge function"
```
supabase functions list | grep <name> && agent-browser open $PROD_URL/api/test --console
```
✅ Verified: function deployed, endpoint returns 200.

## References

- agent-browser: https://www.npmjs.com/package/agent-browser
- commit-workflow skill (pre-flight checks)
- ux-qa skill (full UX audit)
- issue-scoping skill (Double Diamond + integrated verification gates)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
