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
# Preferred: `bash scripts/scratch-worktree.sh run --repo <repo> --ref <branch> -- <cmd>`
# creates and removes the checkout itself (same shared object store, no copy).
# The hand-rolled form below is the fallback when the helper is unavailable; it is
# a WORKTREE, never a `git clone`/`cp -R`/`rsync` copy of the repo (#1141).
PR_BRANCH=$(gh pr view $PR_NUMBER --json headRefName --jq '.headRefName')
WORKTREE_PATH="/tmp/code-review-fixer-${PR_NUMBER}-$$"
SKIP_LOOP=false
git worktree add "$WORKTREE_PATH" "$PR_BRANCH" || { EXIT_REASON="git-error"; SKIP_LOOP=true; }

ALLOWLIST_JSON=$(gh pr diff $PR_NUMBER --name-only | python3 -c "
import sys, json
print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))
")

# #838 — adversarial domain: set to 1 iff the scoping comment carries the
# `### Adversarial Threat Surface` declaration. Drives the 2-cycle bound in L1
# and the `adversarial-capped` exit. Unset/0 → the class's own cap.
ADVERSARIAL_BOUND=${ADVERSARIAL_BOUND:-0}

# #1537 — the ceiling is the CHANGE's own, so the loop needs the class Step 3.6
# resolved. Unset → L1 fails safe to the widest class's cap and RECORDS that it did.
RISK_CLASS="${RISK_CLASS:-}"

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
# #1537 — the count that DRIVES the loop is the blocking one. Both are recorded: a
# total-only record cannot distinguish "converging, filing follow-ups" from "not
# converging", which is why the loops looked stalled while making progress.
BLOCKING_PER_CYCLE_JSON='[]'
BLOCKING_ISSUES_JSON='[]'
FOLLOW_UPS_JSON='[]'
# #1537 -- set ONLY by L6.1, after a real scan. The landing prefix keys on this: `blocking=0`
# is meaningless if no scan ran this cycle, and an uninitialised `BLOCKING_ISSUES_JSON='[]'`
# must never be readable as "the round landed with nothing blocking" (a low-class change
# breaks out at L1 before L6.1 ever runs -- that false PASS was found in review).
LANDED=0
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
# The ceiling is THIS change's own (#1537) — `proportional-gates` §Review Cycles owns the
# numbers, and Step 3.6 already resolved RISK_CLASS before dispatch. A flat 10 is not a
# proportional bound: it is a default to max. `review-scale.ts::cycleCapForClass` is the
# executable reader; this `case` is its shell twin and MUST agree with it.
# 2 = the adversarial-domain bound (#838, SKILL.md "Adversarial domain — declared threat
# surface"), set ADVERSARIAL_BOUND=1 from the scoping declaration. It can only TIGHTEN the
# class's cap, never widen it.
# adversarial-bound: cap=2
case "${RISK_CLASS:-}" in
  low)         CLASS_BOUND=0 ;;
  low-medium)  CLASS_BOUND=3 ;;
  medium-high) CLASS_BOUND=5 ;;
  high)        CLASS_BOUND=10 ;;
  *)
    CLASS_BOUND=10
    echo "[code-review] RISK_CLASS unset or unrecognised ('${RISK_CLASS:-}') — Step 3.6 must resolve it before the loop; failing safe to the widest class's cap, and the exit record says so" >&2
    RISK_CLASS="unresolved" ;;
esac
BOUND=$CLASS_BOUND
if [ "${ADVERSARIAL_BOUND:-0}" = "1" ] && [ "$BOUND" -gt 2 ]; then BOUND=2; fi
if [ $CYCLE -gt $BOUND ]; then
  if [ "$BOUND" -eq 0 ]; then EXIT_REASON="no-loop-budget"
  elif [ "${ADVERSARIAL_BOUND:-0}" = "1" ] && [ "$BOUND" -eq 2 ]; then EXIT_REASON="adversarial-capped"
  elif [ "$BOUND" -eq 10 ]; then EXIT_REASON="cycle-cap"
  else EXIT_REASON="proportional-capped"; fi
  break
fi
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
lines = ['Fix the following code-review issues in PR #$PR_NUMBER:', '',
         'VERIFY FIRST — a finding is a CLAIM, not a fact. For EACH issue, open',
         'the primary source it CITES (line range, file, gh output, commit) and',
         'confirm the source says what the finding says. If it does NOT hold: do',
         'not change the code — return FALSIFIED: <issue> — <what the source',
         'actually says>. If it cites nothing checkable: return',
         'UNVERIFIABLE: <issue> and do not apply it. A CORRECTED marker is not',
         'evidence. A decline does NOT clear the gate: write nothing and return',
         'the FALSIFIED:/UNVERIFIABLE: lines — the fresh scan at L6 decides, and',
         'if it re-flags the issue the loop stops after 2 no-change cycles.',
         'Never apply a finding you have just verified as false.', '']
for i in issues:
    # #1537 -- carry the disposition with the finding: `outcome` is WHY it blocks, and the
    # fixer must know that to make a minimal fix rather than a rewrite.
    lines += [f\"[{i.get('severity','')}] {i.get('location','')}\",
              f\"Blocks because: {i.get('outcome','') or 'undeclared (treated as blocking)'}\",
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
| `no-op` | No break — fall through to L4 → L5 → L6. A fixer SELF-REPORT never clears the gate (line 13: "the implementation_agent's self-report — DONE, no-op, tests green — is necessary but never sufficient"). If nothing actually changed, the L6 zero-progress detector escalates after 2 consecutive cycles; `clean` can only come from the fresh scan at L6. This row used to `EXIT_REASON="clean"`, break — a self-report clearing the gate with issues outstanding |
| `paused-needs-files` | Read FILES_NEEDED section; if absent/empty, proceed with current allowlist (no retry); if non-empty, merge into allowlist and retry L3 once |

Read FILES_WRITTEN section (comma-separated). Set `FILES_WRITTEN_CSV` from Claude's context, then:

```bash
CYCLE_FILE_COUNT=$(echo "$FILES_WRITTEN_CSV" | tr ',' '\n' | \
  grep -v '^\s*(none)\s*$' | grep -v '^\s*$' | wc -l | tr -d ' ')
```

### L4 — Detect changes and stage/commit

`implementation_agent` may commit internally. Stage and commit any uncommitted changes; an
internal commit is pushed unconditionally at L5, so only the uncommitted set is checked here:

```bash
UNCOMMITTED=$(git -C "$WORKTREE_PATH" diff --name-only)

# ⛔ A no-change cycle does NOT exit here — it FALLS THROUGH to L5/L6. This
# branch used to `EXIT_REASON="clean"; break`, which contradicted line 13 ("a
# cycle clears the gate ONLY when a fresh reviewer pass returns zero issues")
# and short-circuited the L6 zero-progress detector (which needs 2 consecutive
# no-change cycles) — so a single fixer that wrote nothing, including one that
# legitimately DECLINED every finding as FALSIFIED:/UNVERIFIABLE: (a finding is
# a CLAIM — #5014), reached `clean` having resolved nothing. Falling through
# keeps ONE threshold for zero progress (the L6 detector), lets the fresh scan
# at L6 decide, and keeps the clean exit reachable ONLY through it. The
# `if [ -n "$UNCOMMITTED" ]` guard below already handles the empty change set.

if [ -n "$UNCOMMITTED" ]; then
  # file --mime-type -b returns e.g. `text/plain; charset=utf-8` — filter on `text/` prefix
  while IFS= read -r f; do
    MIME=$(file --mime-type -b "$WORKTREE_PATH/$f" 2>/dev/null || echo "unknown")
    case "$MIME" in text/*) git -C "$WORKTREE_PATH" add "$f" ;; esac
  done < <(git -C "$WORKTREE_PATH" diff --name-only)
  git -C "$WORKTREE_PATH" commit -m "fix(code-review): automated fixer cycle $CYCLE — PR #$PR_NUMBER" \
    || { EXIT_REASON="git-error"; break; }
fi
# No staged changes and/or an internally-committed (unpushed) commit both fall
# through to L5 — this path is now UNCONDITIONAL, so a no-change cycle reaches
# the L6 detector and the fresh scan rather than exiting clean here.
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

### L6.1 — Finding disposition: what BLOCKS, what is a FOLLOW-UP (#1537)

The loop iterates on **blocking** findings only. Two rules (SKILL.md §"Finding disposition — what
BLOCKS, what is a FOLLOW-UP"); this is their executable form — a shell twin of
`extensions/loop-enforcer/review-scale.ts::dispositionOf`, which `review-scale.test.ts` drives:

- a finding is **non-blocking by default** and blocks only when it names **the wrong outcome it can
  produce**;
- a finding is **attributable to the change** only if it declares `origin: diff` AND cites a file in
  `ALLOWLIST_JSON` — `origin: process` (the PR description, a commit message, or prose about this
  review process) and `origin: pre-existing` are follow-ups;
- ⛔ **an ABSENT `origin` or `outcome` is malformed and stays BLOCKING.** Absence is never a pass.

Both fields are optional on the wire, so the filter can only ever *shorten* the loop when a finding
carries an explicit, checkable non-blocking declaration. A scanner that emits neither field behaves
exactly as before — nothing is deferred by omission.

```bash
export __CURR_ISSUES="$CURRENT_ISSUES_JSON"
export __ALLOWLIST="$ALLOWLIST_JSON"
DISPOSITION=$(python3 -c "
import os, json, re
issues = json.loads(os.environ['__CURR_ISSUES'] or '[]')
# Path normalisation MUST match review-scale.ts::normalisePath exactly: strip any number of
# leading './' groups, then leading '/'. `lstrip('./')` is a CHARACTER SET, not a prefix --
# it mangles a leading-dot path ('.github/workflows/ci.yml' -> 'github/...') and disagrees
# with the module, which the twin-equivalence pin now catches.
changed = {re.sub(r'^(\./)+', '', p.strip()).lstrip('/') for p in json.loads(os.environ['__ALLOWLIST'] or '[]') if p.strip()}
blocking, follow_ups = [], []
for f in issues:
    origin = str(f.get('origin') or '').strip().lower()
    outcome = f.get('outcome')
    verdict, reason = 'blocking', ''
    if not origin:
        verdict, reason = 'blocking', 'no origin declared (malformed — treated as blocking)'
    elif origin == 'process':
        verdict, reason = 'follow_up', 'about the change own process prose — resolve by DELETION'
    elif origin == 'pre-existing':
        verdict, reason = 'follow_up', 'pre-existing code the change does not touch — file an issue'
    elif origin != 'diff':
        verdict, reason = 'blocking', 'unknown origin (malformed — treated as blocking)'
    else:
        cited = str(f.get('file') or '').strip()
        if not cited or re.sub(r'^(\./)+', '', cited.strip()).lstrip('/') not in changed:
            verdict, reason = 'follow_up', 'not attributable to this change — file an issue'
        elif outcome is None or str(outcome).strip() == '':
            verdict, reason = 'blocking', 'no outcome declared (malformed — treated as blocking)'
        elif str(outcome).strip().lower() == 'none':
            verdict, reason = 'follow_up', 'outcome: none — a suggestion, recorded'
        elif str(f.get('severity') or '').strip().upper() == 'P3':
            verdict, reason = 'follow_up', 'P3 — recorded, never blocking'
        else:
            reason = 'about this change and names a wrong outcome: ' + str(outcome).strip()
    (blocking if verdict == 'blocking' else follow_ups).append({**f, 'disposition': verdict, 'disposition_reason': reason})
print(json.dumps({'blocking': blocking, 'follow_ups': follow_ups}))
")
unset __CURR_ISSUES __ALLOWLIST
export __DISP="$DISPOSITION"
BLOCKING_ISSUES_JSON=$(python3 -c "import json,os; print(json.dumps(json.loads(os.environ['__DISP'])['blocking']))")
FOLLOW_UPS_JSON=$(python3 -c "import json,os; print(json.dumps(json.loads(os.environ['__DISP'])['follow_ups']))")
unset __DISP
```

**The gate clears on ZERO BLOCKING findings, not on zero findings.** When no blocking finding
remains, the loop does **not** start another round: it records the follow-ups, and the agent files
each one as an owned issue — naming its number in the PR comment — before the exit is honoured (`land`
at the ceiling, SKILL.md §"The ceiling is the change's own"). A follow-up is *deferred*, never
*dropped*: it is carried into the PR comment and `cycle-status.yaml` either way.

If `BLOCKING_ISSUES_JSON` is an empty array → set **`LANDED=1`** first, then
`EXIT_REASON="clean"` when `FOLLOW_UPS_JSON` is also empty, else `EXIT_REASON="proportional-capped"`
(the **landing** form, `blocking=0`), break. `LANDED=1` is what makes that exit a landing: the
prefix table keys on it, so an unrun scan can never be read as one.

Append this cycle's counts — TOTAL in `issues_per_cycle`, **blocking** in `blocking_per_cycle`,
because the blocking count is the one that drives the loop. **Without this, `ISSUES_PER_CYCLE_JSON` stays `[]` forever, `honest-stuck`'s `len(...) < 3` guard is permanently true, and that layer can never fire** — which is how it went unnoticed until a review found the layer was documented as live but was dead code.

```bash
export __IPC="$ISSUES_PER_CYCLE_JSON"
export __BPC="$BLOCKING_PER_CYCLE_JSON"
export __CUR="$CURRENT_ISSUES_JSON"
export __BLC="$BLOCKING_ISSUES_JSON"
RESULT=$(python3 -c "
import os, json
ipc = json.loads(os.environ['__IPC'] or '[]')
bpc = json.loads(os.environ['__BPC'] or '[]')
ipc.append(len(json.loads(os.environ['__CUR'] or '[]')))
bpc.append(len(json.loads(os.environ['__BLC'] or '[]')))
print(json.dumps({'all': ipc, 'blocking': bpc}))
")
export __RESULT="$RESULT"
ISSUES_PER_CYCLE_JSON=$(python3 -c "import json,os; print(json.dumps(json.loads(os.environ['__RESULT'])['all']))")
BLOCKING_PER_CYCLE_JSON=$(python3 -c "import json,os; print(json.dumps(json.loads(os.environ['__RESULT'])['blocking']))")
unset __IPC __BPC __CUR __BLC __RESULT
```

Fingerprint stall detection (all multi-field JSON via `os.environ` — avoids bash double-quote injection):

```bash
export __CURR_ISSUES="$BLOCKING_ISSUES_JSON"
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

# Honest-stuck input: **blocking** count non-decreasing for 3 consecutive cycles.
# The count test is computed BEFORE any detector breaks — see classification
# below — so a cycle can be labelled by BOTH signals rather than whichever
# branch happened to run first.
# #1537: the input is the BLOCKING count, not the total. A loop whose total stays
# flat because each round files another non-blocking follow-up is converging, and
# reading that as `honest-stuck` is how a P3 treadmill got escalated as a stall.
export __HONEST_ISSUES="$BLOCKING_PER_CYCLE_JSON"
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
# Only BLOCKING findings are carried into the next fixer cycle (#1537): a follow-up is
deferred to an owned issue, never re-fed to the fixer as work this PR owes.
SURVIVING_ISSUES_JSON="$BLOCKING_ISSUES_JSON"
```

(Loop back to L1)

## Post-loop — cleanup and telemetry

```bash
git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
# No `git worktree prune` here. It deregisters EVERY record whose directory is
# not stat-able at that instant (unmounted volume, permission blip, stale mount),
# so it destroys unrelated sibling checkouts while their files stay on disk
# (#1141). `git worktree remove --force` already dropped this one's record.

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
  # #1537 -- the counts the loop is actually judged on. A total-only record cannot
  # distinguish converging-with-follow-ups from not-converging, and a bare `cycles: N`
  # cannot show WHICH ceiling applied (the flat 10 made every exit look in-budget).
  'blocking_per_cycle': json.loads('$BLOCKING_PER_CYCLE_JSON'),
  'landed': '$LANDED' == '1',
  'follow_ups': json.loads('$FOLLOW_UPS_JSON'),
  'risk_class': '$RISK_CLASS',
  'cycle_cap': ${BOUND:-10},
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
  (the **High** row's own ceiling; the tighter classes exit `proportional-capped` instead, so this
  label keeps meaning exactly what `AGENTS.md` §Hard Cap quotes it for)
- `EXIT_REASON == "adversarial-capped"`: `[ADVERSARIAL-BOUND] cycles=${CYCLE} threats=<K> covered=<K> residuals=<#N,…|none> — bounded by the declared threat surface (#838); residuals filed, not chased\n\n`
- `EXIT_REASON == "tool-unavailable"` or `"push-failed"` or `"git-error"` or `"pr-closed"`: `⚠️ Auto-fix aborted (${EXIT_REASON}) — issues require human review\n\n`
- `EXIT_REASON == "proportional-capped"` — **two different events share this label, and they are distinguished by the blocking count**:
  - `LANDED == "1"` and `BLOCKING_ISSUES_JSON` is empty (**L6.1 landed it after a real scan**): `[PROPORTIONAL] cycles=${CYCLE} cap=${BOUND} blocking=0 follow-ups=<#N,…|none> — landed at this change's ceiling (RISK_CLASS=${RISK_CLASS}); the follow-ups are filed, not chased (#1537)\n\n`. This is a **clean completion**: nothing blocking remains, and the follow-ups are named. Put the same `[PROPORTIONAL]` line in the PR body.
  - ⛔ **`LANDED != "1"` is NOT a landing, whatever `BLOCKING_ISSUES_JSON` says.** `LANDED` is set only by L6.1 after the scan; a loop that broke out at L1 (a `low` change's zero-cycle budget, or a ceiling reached with blockers from the previous cycle) never ran a scan, so `'[]'` there is the *initial* value, not a verdict. Keying the prefix on the blocking array alone minted a false PASS for exactly that case (found in review).
  - `BLOCKING_ISSUES_JSON` is non-empty (**the ceiling BLOCKED it**): `⚠️ Auto-fix reached this change's proportional cycle ceiling (${CYCLE} of ${BOUND} cycles, RISK_CLASS=${RISK_CLASS}) — blocking issues remain; escalate to a human\n\n`. This is an **escalation exit**, never a completion, and it names each blocker. (A `low` change's single Step 4 pass is not a loop cycle, so it reads `1 of 0` — that IS the skip sentinel doing its job.)
- `EXIT_REASON == "no-loop-budget"` (`low` class: its `—` row budgets no re-review loop, so the loop
  never ran a scan): `[NO-LOOP-BUDGET] RISK_CLASS=low — the single Step 4 pass is the whole budget; its findings are in the review comment and were never re-reviewed (#1537)\n\n`. ⛔ This is **not** a landing: with no scan there is nothing to land on, and any blocking finding the single pass reported must be fixed or escalated to a human.
- `EXIT_REASON == "clean"`: no prefix (zero findings of any severity, and zero follow-ups)

> **No ceiling is ever a landing permission.** `proportional-capped` lands only on `blocking=0`;
> with a blocking finding it escalates at every cycle number, `AGENTS.md` §Hard Cap's "a capped exit
> is never reported as clean" unchanged.

After post-loop cleanup, the main skill proceeds to Step 7.
