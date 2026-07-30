> **Sync note:** Local copy at `~/.claude/skills/code-review/references/fixer-loop.md`. Repo copy at `operations/skills/code-review/references/fixer-loop.md`. Keep in sync.

# Fixer Loop — Reference

Automated fix-loop implementation invoked from the main `code-review` skill's Step 6 when the gate would otherwise leave issues unaddressed.

## Precondition

Only entered from full-review mode (not `--re-review`) when `FIXER_ENABLED == true` AND at least one issue survived Step 6.

## Gate-clearing rule

A cycle clears the gate **only** when a fresh reviewer pass on the latest commit returns zero issues. The implementation_agent's self-report — "DONE", "no-op", "tests green" — is necessary but never sufficient: L6 must re-run `code_review_pattern_scan` on the fix commit and observe an empty issue array before `EXIT_REASON="clean"`. If the fixer pushed any commit this cycle, the regression scan MUST run before exit. "Fixer says done → exit" is NOT clean; "Fixer pushed fix → pattern_scan re-ran on fix commit → pattern_scan returned zero issues → exit" IS clean. (The Stage-2 double-gate after loop exit further verifies NVIDIA-routed agents' issues against an independent Claude pass.)

> **Notation note:** MCP tool calls (`mcp__ai-workflow-tools__implementation_agent`, `mcp__ai-workflow-tools__code_review_pattern_scan`) are invoked by Claude as orchestrator — results are in Claude's working context, not bash variables. Bash commands run via the Bash tool. UPPERCASE variable names span both; the distinction is enforced at implementation time.

## Step 6.5 — Serialize surviving issues

The confidence filter in Step 6 holds surviving issues as structured objects in Claude's context. Before entering the loop, serialize them to `SURVIVING_ISSUES_JSON` — a JSON array of `{severity, location, description, suggestion}` objects:

```
SURVIVING_ISSUES_JSON = '[{"severity":"P1","location":"...","description":"...","suggestion":"..."}]'
```

## Pre-loop setup

```bash
PR_BRANCH=$(gh pr view $PR_NUMBER --json headRefName --jq '.headRefName')
WORKTREE_PATH="/tmp/code-review-fixer-${PR_NUMBER}-$$"
SKIP_LOOP=false
git worktree add "$WORKTREE_PATH" "$PR_BRANCH" || { EXIT_REASON="git-error"; SKIP_LOOP=true; }

ALLOWLIST_JSON=$(gh pr diff $PR_NUMBER --name-only | python3 -c "
import sys, json
print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))
")

# implementation_agent requires positive integer issue_number.
# Fall back to PR_NUMBER when no linked issue — uses issue_number for logging only.
ISSUE_NUMBER_SAFE=${ISSUE_NUMBER:-$PR_NUMBER}
```

## Initialize

```bash
FIXER_ISSUES_BEFORE=$(echo "$SURVIVING_ISSUES_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
CYCLE=0
FILES_CHANGED_PER_CYCLE_JSON='[]'
ISSUES_PER_CYCLE_JSON='[]'
PREV_FINGERPRINTS_JSON='[]'
EXIT_REASON=""
```

## Loop (skip entirely if SKIP_LOOP=true)

### L1 — Exit conditions
```bash
CYCLE=$((CYCLE + 1))
if [ $CYCLE -gt $MAX_FIX_CYCLES ]; then EXIT_REASON="cycle-cap"; break; fi
PR_STATE=$(gh pr view $PR_NUMBER --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
if [ "$PR_STATE" != "OPEN" ]; then EXIT_REASON="pr-closed"; break; fi
```

### L2 — Build FIXER_PLAN_TEXT (via `os.environ` — avoids triple-quote injection from issue content)
```bash
export __SURVIVING_JSON="$SURVIVING_ISSUES_JSON"
export __ALLOWLIST_JSON="$ALLOWLIST_JSON"
FIXER_PLAN_TEXT=$(python3 -c "
import os, json
issues = json.loads(os.environ['__SURVIVING_JSON'])
allowlist = json.loads(os.environ['__ALLOWLIST_JSON'])
lines = ['Fix the following code-review issues in PR #$PR_NUMBER:', '']
for i in issues:
    lines += [f\"[{i.get('severity','')}] {i.get('location','')}\",
              f\"Problem: {i.get('description','')}\",
              f\"Fix: {i.get('suggestion','')}\", '']
lines.append('Files in scope: ' + str(allowlist))
print('\n'.join(lines))
")
unset __SURVIVING_JSON __ALLOWLIST_JSON
```

### L3 — Call `mcp__ai-workflow-tools__implementation_agent`

Parameters: `plan_text=FIXER_PLAN_TEXT`, `worktree_path=WORKTREE_PATH`, `allowlist=ALLOWLIST_JSON`, `issue_number=ISSUE_NUMBER_SAFE`, `tier="standard"`. `research_path` omitted intentionally.

STATUS dispatch (read from first line of MCP result in Claude's context):

| STATUS | Action |
|---|---|
| `ok` | Continue to L4 |
| `unavailable` | `EXIT_REASON="tool-unavailable"`, break |
| `capped` | `EXIT_REASON="cycle-cap"`, break |
| `no-op` | `EXIT_REASON="clean"`, break |
| `paused-needs-files` | Read FILES_NEEDED section; if absent/empty, proceed with current allowlist (no retry); if non-empty, merge into allowlist and retry L3 once |

Read FILES_WRITTEN section (comma-separated). Set `FILES_WRITTEN_CSV` from Claude's context, then:

```bash
CYCLE_FILE_COUNT=$(echo "$FILES_WRITTEN_CSV" | tr ',' '\n' | \
  grep -v '^\s*(none)\s*$' | grep -v '^\s*$' | wc -l | tr -d ' ')
```

### L4 — Detect changes and stage/commit

`implementation_agent` may commit internally. Check both uncommitted changes AND unpushed commits:

```bash
UNCOMMITTED=$(git -C "$WORKTREE_PATH" diff --name-only)
UNPUSHED=$(git -C "$WORKTREE_PATH" log --oneline "origin/${PR_BRANCH}..HEAD" 2>/dev/null || echo "")

if [ -z "$UNCOMMITTED" ] && [ -z "$UNPUSHED" ]; then
  EXIT_REASON="clean"; break
fi

if [ -n "$UNCOMMITTED" ]; then
  # file --mime-type -b returns e.g. `text/plain; charset=utf-8` — filter on `text/` prefix
  while IFS= read -r f; do
    MIME=$(file --mime-type -b "$WORKTREE_PATH/$f" 2>/dev/null || echo "unknown")
    case "$MIME" in text/*) git -C "$WORKTREE_PATH" add "$f" ;; esac
  done < <(git -C "$WORKTREE_PATH" diff --name-only)
  git -C "$WORKTREE_PATH" commit -m "fix(code-review): automated fixer cycle $CYCLE — PR #$PR_NUMBER" \
    || { EXIT_REASON="git-error"; break; }
fi
# If only UNPUSHED (agent committed internally): fall through to L5
```

### L5 — Push
```bash
git -C "$WORKTREE_PATH" push origin HEAD || { EXIT_REASON="push-failed"; break; }
```

### L6 — Update count, re-review (pattern_scan only), stall detection

```bash
FILES_CHANGED_PER_CYCLE_JSON=$(python3 -c "
import json
lst = json.loads('$FILES_CHANGED_PER_CYCLE_JSON')
lst.append(int('$CYCLE_FILE_COUNT') if '$CYCLE_FILE_COUNT'.isdigit() else 0)
print(json.dumps(lst))
")

# Zero-progress detection: files changed = 0 for 2 consecutive cycles → fingerprint-stall
ZERO_PROGRESS=$(python3 -c "
import json
lst = json.loads('$FILES_CHANGED_PER_CYCLE_JSON')
if len(lst) >= 2 and lst[-1] == 0 and lst[-2] == 0:
    print('true')
else:
    print('false')
")
if [ "$ZERO_PROGRESS" = "true" ]; then EXIT_REASON="fingerprint-stall"; break; fi
```

Call `mcp__ai-workflow-tools__code_review_pattern_scan` with `gh pr diff $PR_NUMBER`. Store result as `PATTERN_SCAN_RAW`. Parse via `os.environ`:

```bash
export __SCAN_RAW="$PATTERN_SCAN_RAW"
CURRENT_ISSUES_JSON=$(python3 -c "
import os, json, re
text = os.environ.get('__SCAN_RAW', '')
issues = []
for block in re.split(r'\n(?=severity:)', text.strip()):
    m = {}
    for field in ('severity', 'location', 'description', 'suggestion'):
        match = re.search(rf'^{field}:\s*(.+?)$', block, re.MULTILINE)
        if match:
            m[field] = match.group(1).strip()
    if 'location' in m and 'description' in m:
        issues.append(m)
print(json.dumps(issues))
")
unset __SCAN_RAW
```

If CURRENT_ISSUES_JSON is empty array → `EXIT_REASON="clean"`, break.

Fingerprint stall detection (all multi-field JSON via `os.environ` — avoids bash double-quote injection):

```bash
export __CURR_ISSUES="$CURRENT_ISSUES_JSON"
export __PREV_FPS="$PREV_FINGERPRINTS_JSON"
STALL_RESULT=$(python3 -c "
import os, json, hashlib
current_issues = json.loads(os.environ['__CURR_ISSUES'])
prev_fps = set(json.loads(os.environ['__PREV_FPS']))
current_fps = set()
for issue in current_issues:
    raw = issue.get('location','') + ':' + issue.get('description','') + ':' + issue.get('suggestion','')
    current_fps.add(hashlib.sha256(raw.encode()).hexdigest())
stalled = bool(prev_fps) and (len(current_fps & prev_fps) / len(prev_fps)) >= $STALL_THRESHOLD
print(json.dumps({'stalled': stalled, 'fingerprints': sorted(current_fps)}))
")
unset __CURR_ISSUES __PREV_FPS

export __STALL_RESULT="$STALL_RESULT"
STALLED=$(python3 -c "import json,os; d=json.loads(os.environ['__STALL_RESULT']); print('true' if d['stalled'] else 'false')")
PREV_FINGERPRINTS_JSON=$(python3 -c "import json,os; print(json.dumps(json.loads(os.environ['__STALL_RESULT'])['fingerprints']))")
unset __STALL_RESULT

if [ "$STALLED" = "true" ]; then EXIT_REASON="fingerprint-stall"; break; fi

# Honest-stuck detection: issue count non-decreasing 3 consecutive cycles
# (fingerprint-stall above already catches same-fingerprint cycles, so if we
# reach here with non-decreasing count, the fingerprints genuinely differ —
# meaning the fixer is introducing new issues faster than resolving existing ones)
export __HONEST_ISSUES="$ISSUES_PER_CYCLE_JSON"
HONEST_STUCK=$(python3 -c "
import os, json
issues_lst = json.loads(os.environ['__HONEST_ISSUES'])
if len(issues_lst) < 3:
    print('false')
else:
    last3 = issues_lst[-3:]
    non_decreasing = all(last3[i] <= last3[i+1] for i in range(2))
    print('true' if non_decreasing else 'false')
")
unset __HONEST_ISSUES
if [ "$HONEST_STUCK" = "true" ]; then EXIT_REASON="honest-stuck"; break; fi
```

### L7 — Update surviving issues
```bash
SURVIVING_ISSUES_JSON="$CURRENT_ISSUES_JSON"
```

(Loop back to L1)

## Post-loop — cleanup and telemetry

```bash
git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true

FIXER_ISSUES_AFTER=$(echo "$SURVIVING_ISSUES_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

python3 -c "
import json
from datetime import datetime, timezone
er = '$EXIT_REASON'
entry = {
  'ts': datetime.now(timezone.utc).isoformat(),
  'skill': 'code-review', 'version': '1.8.0',
  'pr_number': $PR_NUMBER,
  'fix_loop_enabled': '$FIXER_ENABLED' == 'true',
  'fix_loop_cycles': $CYCLE,
  'fix_loop_exit_reason': er or None,
  'fix_loop_issues_per_cycle': json.loads('$ISSUES_PER_CYCLE_JSON'),
  'fix_loop_files_changed_per_cycle': json.loads('$FILES_CHANGED_PER_CYCLE_JSON')
}
print(json.dumps(entry, ensure_ascii=False))
" >> operations/logs/code-review-fix-loop.jsonl
```

Log dir: `operations/logs/` (NOT `operations/ai-workflow-tools/logs/`). The file is created on first run — do not pre-create it.

**Cycle-status YAML**: Write on loop exit:

```bash
python3 -c "
import json, yaml, os
from datetime import datetime, timezone
status = {
  'exit_reason': '$EXIT_REASON',
  'cycles': $CYCLE,
  'issues_per_cycle': json.loads('$ISSUES_PER_CYCLE_JSON'),
  'files_changed_per_cycle': json.loads('$FILES_CHANGED_PER_CYCLE_JSON'),
  'pr_number': $PR_NUMBER,
  'ts': datetime.now(timezone.utc).isoformat(),
}
os.makedirs('operations/logs', exist_ok=True)
with open('operations/logs/cycle-status.yaml', 'w') as f:
    yaml.dump(status, f, default_flow_style=False)
" 2>/dev/null || true
```

> Maintenance note: if `FixLoopLogEntry` in `src/double-gate-log.ts` changes shape, update this python template to match. This is a known sync point.

## PR comment prefix (prepended to Step 8 comment body)

- `EXIT_REASON == "fingerprint-stall"`: `⚠️ Auto-fix stalled after ${CYCLE} cycles — requires human review\n\n`
- `EXIT_REASON == "honest-stuck"`: `⚠️ Auto-fix stuck (honest-stuck — new issues each cycle, non-decreasing 3×) — requires human review\n\n`
- `EXIT_REASON == "cycle-cap"`: `⚠️ Auto-fix reached cycle cap (${MAX_FIX_CYCLES}) — unresolved issues remain\n\n`
- `EXIT_REASON == "tool-unavailable"` or `"push-failed"` or `"git-error"` or `"pr-closed"`: `⚠️ Auto-fix aborted (${EXIT_REASON}) — issues require human review\n\n`
- `EXIT_REASON == "clean"`: no prefix

After post-loop cleanup, the main skill proceeds to Step 7.
