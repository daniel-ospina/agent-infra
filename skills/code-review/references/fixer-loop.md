> **Source:** Canonical copy at `skills/code-review/references/fixer-loop.md`.

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
STALL_RECURRENCE=0
STALL_NEW_COUNT=0
DETECTOR_FIRED=""
# The skill's stall_threshold default, defined here so the value interpolated into
# python can never be empty. An empty value reached python as `recurrence >= ` — a
# SyntaxError — which produced an empty DETECTOR_FIRED and therefore NO exit at all
# (fail-open: the loop walked to cycle-cap with no diagnosis).
STALL_THRESHOLD="${STALL_THRESHOLD:-0.8}"
EXIT_REASON=""
```

## Loop (skip entirely if SKIP_LOOP=true)

### L1 — Exit conditions
```bash
CYCLE=$((CYCLE + 1))
if [ $CYCLE -gt 10 ]; then EXIT_REASON="cycle-cap"; break; fi  # 10 = the convergence-gated safety cap (SKILL.md "Safety cap at 10 cycles")
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

# Zero-progress detection: files changed = 0 for 2 consecutive cycles → zero-progress
ZERO_PROGRESS=$(python3 -c "
import json
lst = json.loads('$FILES_CHANGED_PER_CYCLE_JSON')
if len(lst) >= 2 and lst[-1] == 0 and lst[-2] == 0:
    print('true')
else:
    print('false')
")
# Its own exit label: mapping zero-progress onto "fingerprint-stall" made three
# distinct conditions (identical issues recurring / new issues outpacing fixes /
# the fixer writing nothing at all) indistinguishable in the persisted record.
# DETECTOR_FIRED is set here too — it is an audit field, and a layer DID fire.
# Leaving it empty made cycle-status.yaml record `exit_reason: zero-progress`
# alongside `detector_fired: ''`, which reads as "no detector fired".
# Recurrence is None rather than a stale number: this exit happens before the
# scan, so the previous cycle's value would be a number this exit never used.
# NOTE: the literal must be Python's `None`, not YAML/JSON's `null` — this value
# is interpolated bare into a `python3 -c` program, where `null` is a NameError
# that silently skips the whole cycle-status write (the shell `||` fallback
# absorbs it and still exits 0). `yaml.dump(None)` renders it as `null`.
if [ "$ZERO_PROGRESS" = "true" ]; then DETECTOR_FIRED="zero-progress"; STALL_RECURRENCE=None; EXIT_REASON="zero-progress"; break; fi
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

Append this cycle's issue count. **Without this, `ISSUES_PER_CYCLE_JSON` stays `[]` forever, `honest-stuck`'s `len(...) < 3` guard is permanently true, and that layer can never fire** — which is how it went unnoticed until a review found the layer was documented as live but was dead code.

```bash
export __IPC="$ISSUES_PER_CYCLE_JSON"
export __CUR="$CURRENT_ISSUES_JSON"
ISSUES_PER_CYCLE_JSON=$(python3 -c "
import os, json
lst = json.loads(os.environ['__IPC'])
lst.append(len(json.loads(os.environ['__CUR'])))
print(json.dumps(lst))
")
unset __IPC __CUR
```

Fingerprint stall detection (all multi-field JSON via `os.environ` — avoids bash double-quote injection):

```bash
export __CURR_ISSUES="$CURRENT_ISSUES_JSON"
export __PREV_FPS="$PREV_FINGERPRINTS_JSON"
export __STALL_THRESHOLD="$STALL_THRESHOLD"
STALL_RESULT=$(python3 -c "
import os, json, hashlib
current_issues = json.loads(os.environ['__CURR_ISSUES'])
prev_fps = set(json.loads(os.environ['__PREV_FPS']))
current_fps = set()
for issue in current_issues:
    # Fingerprint = the defect's STABLE IDENTITY, not its wording. Hashing
    # description plus suggestion made recurrence depend on how a fresh,
    # memoryless reviewer happened to phrase things: the same defect re-described
    # in new words hashed differently, so recurrence read as zero on a cycle
    # where nothing had been fixed. That is the most common real stall, and it
    # made the primary detector blind to it. location plus severity identifies
    # the defect; the prose is the part the LLM varies.
    raw = issue.get('location','') + ':' + issue.get('severity','')
    current_fps.add(hashlib.sha256(raw.encode()).hexdigest())
# Recurrence = the fraction of LAST cycle's issues that came back. This is the
# stall signal, and the denominator is deliberately len(prev_fps) -- did the
# issues we already had survive? A symmetric denominator (max of the two sets)
# is WRONG here: it made the strongest stall signal score lowest. With all 10
# prior issues recurring plus 5 new ones, symmetric recall = 10/15 = 0.67 < 0.8
# which reads as no stall, even though literally nothing was resolved.
# NOTE: this comment lives INSIDE a double-quoted shell string -- never use a
# double quote or a backtick here; both break the invocation silently.
recurrence = (len(current_fps & prev_fps) / len(prev_fps)) if prev_fps else 0.0
# New issues this cycle -- a diagnostic count carried in the audit record.
new_count = len(current_fps - prev_fps)
thr = float(os.environ.get('__STALL_THRESHOLD') or 0.8)
print(json.dumps({'recurrence': recurrence, 'new_count': new_count, 'threshold': thr, 'fingerprints': sorted(current_fps)}))
")
unset __CURR_ISSUES __PREV_FPS __STALL_THRESHOLD

export __STALL_RESULT="$STALL_RESULT"
STALL_RECURRENCE=$(python3 -c "import json,os; print(json.loads(os.environ['__STALL_RESULT'])['recurrence'])")
STALL_NEW_COUNT=$(python3 -c "import json,os; print(json.loads(os.environ['__STALL_RESULT'])['new_count'])")
PREV_FINGERPRINTS_JSON=$(python3 -c "import json,os; print(json.dumps(json.loads(os.environ['__STALL_RESULT'])['fingerprints']))")
unset __STALL_RESULT

# Honest-stuck input: issue count non-decreasing for 3 consecutive cycles.
# The count test is computed BEFORE any detector breaks — see classification
# below — so a cycle can be labelled by BOTH signals rather than whichever
# branch happened to run first.
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

# ── Classification ───────────────────────────────────────────────────────────
# TWO INDEPENDENT stall signals. Either one is sufficient to fire.
#
#   (1) recurrence >= threshold   -- the same issues came back
#   (2) count non-decreasing 3x   -- the loop is not shrinking, whatever the cause
#
# (2) is deliberately NOT gated on (1). Gating honest-stuck behind recurrence was
# itself a regression: a loop that churns one-for-one (every issue fixed, a new
# one appearing in its place) has LOW recurrence but is not converging, and the
# recurrence gate left it undiagnosed — it fell through to the cycle cap.
#
# Label: honest-stuck when the count is not shrinking; otherwise fingerprint-stall
# (the narrower, more specific finding). Precedence exists only for the LABEL —
# both signals fire, so no non-convergent cycle is left undiagnosed.
export __RECURRENCE="$STALL_RECURRENCE"
export __NEW_COUNT="$STALL_NEW_COUNT"
export __HONEST="$HONEST_STUCK"
export __STALL_THRESHOLD="$STALL_THRESHOLD"
DETECTOR_FIRED=$(python3 -c "
import os
recurrence = float(os.environ['__RECURRENCE'] or 0)
new_count = int(os.environ['__NEW_COUNT'] or 0)
honest = os.environ['__HONEST'] == 'true'
thr = float(os.environ.get('__STALL_THRESHOLD') or 0.8)
if recurrence >= thr or honest:
    print('honest-stuck' if honest else 'fingerprint-stall')
else:
    print('')
")
unset __RECURRENCE __NEW_COUNT __HONEST __STALL_THRESHOLD
if [ -n "$DETECTOR_FIRED" ]; then EXIT_REASON="$DETECTOR_FIRED"; break; fi
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
  'pr_number': ${PR_NUMBER:-0},
  'fix_loop_enabled': '$FIXER_ENABLED' == 'true',
  'fix_loop_cycles': ${CYCLE:-0},
  'fix_loop_exit_reason': er or None,
  'fix_loop_issues_per_cycle': json.loads('$ISSUES_PER_CYCLE_JSON'),
  'fix_loop_files_changed_per_cycle': json.loads('$FILES_CHANGED_PER_CYCLE_JSON')
}
print(json.dumps(entry, ensure_ascii=False))
" >> operations/logs/code-review-fix-loop.jsonl || echo 'warn: fix-loop JSONL not appended (see stderr above)' >&2
```

Log dir: `operations/logs/` (NOT `operations/ai-workflow-tools/logs/`). The file is created on first run — do not pre-create it.

**Cycle-status YAML**: Write on loop exit:

```bash
python3 -c "
import json, yaml, os
from datetime import datetime, timezone
status = {
  'exit_reason': '$EXIT_REASON',
  'cycles': ${CYCLE:-0},
  'issues_per_cycle': json.loads('$ISSUES_PER_CYCLE_JSON'),
  'files_changed_per_cycle': json.loads('$FILES_CHANGED_PER_CYCLE_JSON'),
  'pr_number': ${PR_NUMBER:-0},
  # Auditable detector inputs. Without these, why did the loop exit? cannot be
  # answered after the fact -- the predicate's inputs are gone, which is exactly
  # what made the #755 plan-review non-convergence undiagnosable.
  # NOTE: this comment lives INSIDE a double-quoted shell string -- never use a
  # double quote or a backtick here. Both truncate the program silently, and the
  # stderr redirect below used to swallow the resulting SyntaxError, so the audit
  # record was never written at all on any exit path.
  'detector_fired': '$DETECTOR_FIRED',
  'fingerprint_recurrence_last_cycle': ${STALL_RECURRENCE:-0},
  'ts': datetime.now(timezone.utc).isoformat(),
}
os.makedirs('operations/logs', exist_ok=True)
with open('operations/logs/cycle-status.yaml', 'w') as f:
    yaml.dump(status, f, default_flow_style=False)
" || echo 'warn: cycle-status.yaml not written (see stderr above)' >&2
```

> Maintenance note: if `FixLoopLogEntry` in `src/double-gate-log.ts` changes shape, update this python template to match. This is a known sync point.

## PR comment prefix (prepended to Step 8 comment body)

- `EXIT_REASON == "fingerprint-stall"`: `⚠️ Auto-fix stalled after ${CYCLE} cycles — requires human review\n\n`
- `EXIT_REASON == "zero-progress"`: `⚠️ Auto-fix made no changes for 2 consecutive cycles (zero-progress) — requires human review\n\n`
- `EXIT_REASON == "convergence"` (**agent-judged** — the loop never sets this; the agent posts it after reading the remaining issue set): `⚠️ Auto-fix converged with issues unresolved — requires human review\n\n`
- `EXIT_REASON == "honest-stuck"`: `⚠️ Auto-fix stuck (honest-stuck — issue count not shrinking for 3 cycles) — requires human review\n\n`
- `EXIT_REASON == "cycle-cap"`: `⚠️ Auto-fix reached the 10-cycle safety cap — unresolved issues remain; escalate to a human\n\n`
- `EXIT_REASON == "tool-unavailable"` or `"push-failed"` or `"git-error"` or `"pr-closed"`: `⚠️ Auto-fix aborted (${EXIT_REASON}) — issues require human review\n\n`
- `EXIT_REASON == "clean"`: no prefix

After post-loop cleanup, the main skill proceeds to Step 7.
