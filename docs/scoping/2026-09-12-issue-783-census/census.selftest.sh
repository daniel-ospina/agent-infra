#!/usr/bin/env bash
# census.selftest.sh — proves the census instrument CAN FAIL.
#
# Revision history (why this keeps growing):
#   rev 2: checked a one-line regex against a hardcoded literal. Never invoked the
#          census — a structurally dead mutant still printed OK.
#   rev 3: invoked it, one seed. Blind to the de-dup regression and a weakened gate.
#   rev 4: three seeds, asserted only `payloads=` and `with_git_state=`. A mutant that
#          swapped the everSawTool counters and weakened the empty-stdout rule PASSED.
#   rev 5: asserted three lines. Mutants killing cap_seconds, has_activity_trace,
#          toolsInFlight>0, stderr_has_abs_path, stderr_mentions_worktree all PASSED;
#          the seeds carried no absolute path and no .worktrees/ string, so the two
#          stderr rows were not merely unguarded but UNGUARDABLE.
#   rev 6 (this one): diffs the ENTIRE published output block against a golden literal.
#          Cycle-6 verifiers then found two remaining blind spots, closed here:
#            - `files=` was non-discriminating (one seed file only). Now two files.
#            - `duplicate_payload_strings` was 0 with no duplicate seed, so breaking it
#              was invisible. Seed A2 is now a byte-identical copy of A.
#          `--assert-nonzero` is now actually exercised (it previously had zero cover).
#
# Scope: self-test revision 6. (The ARTIFACT's revision counter is separate and lives
# in SCOPE-ARTIFACT.md; do not conflate the two — cycle-6 review flagged the collision.)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENSUS="${1:-$SELF_DIR/census.py}"

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/--tmp--"

# --- file 1: A (admitted, git state), B (admitted, distinct), C (quotation, EXCLUDED) ---
PAYLOAD_A='⚠️ Sub-agent exceeded the task hard cap (7200s). Partial results below — parent should decide: accept, re-dispatch, or escalate.

Alive state: toolsInFlight=1 turnActive=true streamAgeMs=1000 everSawTool=true lastMarkerAgeMs=3548 tickCount=100 branch=fix/seeded headSha=abc123 dirty=2 trace=[ready,turn_start,tool_start]

--- last stderr ---
[verification-gate] ⚠️ MAIN CHECKOUT BRANCH CHANGED mid-session (#265): baseline "main" → current "feat/seeded"
[verification-gate] ⚠️ Sub-agent session started with 0 bridge-recovered files for root /Users/dev/repo
[skill-registry] loading /Users/dev/repo/.worktrees/469/skills/x.md

--- last stdout ---

'

# B: same first 40 chars of alive state as A, different tickCount -> a DISTINCT event.
PAYLOAD_B='⚠️ Sub-agent exceeded the task hard cap (7200s). Partial results below — parent should decide: accept, re-dispatch, or escalate.

Alive state: toolsInFlight=1 turnActive=true streamAgeMs=1000 everSawTool=true lastMarkerAgeMs=3349 tickCount=208 trace=[ready,turn_start,tool_start]

--- last stderr ---
[main-worktree-guard] MAIN CHECKOUT — HUB DISCIPLINE WARNING
  on branch "fix/other-banner" (not main/master)
[verification-gate] ⚠️ Sub-agent session started with 0 bridge-recovered files for root /Users/dev/repo

--- last stdout ---

'

# C: headline present MID-string (a quotation). Must NOT be admitted.
PAYLOAD_C='The child returned: ⚠️ Sub-agent exceeded the task hard cap (21600s). Partial results below.

Alive state: toolsInFlight=0 everSawTool=false

--- last stdout ---

'

# --- file 2: D (pre-field, empty stderr, NON-empty stdout) + A2 (byte-identical copy of A) ---
# D's non-empty stdout distinguishes "tail is literally empty" from "delimiter is present"
# — without it, weakening that rule is undetectable.
PAYLOAD_D='⚠️ Sub-agent exceeded the task hard cap (21600s). Partial results below.

Alive state: toolsInFlight=0 turnActive=false tickCount=5

--- last stderr ---
[main-worktree-guard] MAIN CHECKOUT — HUB DISCIPLINE WARNING
  working tree is dirty

--- last stdout ---
some partial stdout text

'

write_file() {
  python3 - "$1" "${@:2}" <<'PY'
import json, sys
out = sys.argv[1]
with open(out, "w") as fh:
    for p in sys.argv[2:]:
        fh.write(json.dumps({"type": "message", "message": {"role": "toolResult"},
                             "content": [{"type": "text", "text": p}]}) + "\n")
PY
}

write_file "$D/--tmp--/2026-01-01T00-00-00-000Z_seed1.jsonl" "$PAYLOAD_A" "$PAYLOAD_B" "$PAYLOAD_C"
write_file "$D/--tmp--/2026-01-01T00-01-00-000Z_seed2.jsonl" "$PAYLOAD_D" "$PAYLOAD_A"

OUT="$(python3 "$CENSUS" --root "$D")"

# A and A2 are admitted; B is admitted; C is not. So 4 payloads across 2 files, with
# exactly ONE byte-identical duplicate.
read -r -d '' GOLDEN <<'GOLDEN_EOF' || true
payloads=4 files=2 git_field_state=2
  everSawTool=true=3 false=0 no_field=1
  toolsInFlight>0=3
  stdout_tail_empty=3  stderr_tail_nonempty=4
  stderr_has_abs_path=3  stderr_mentions_worktree=2
  stderr_names_child_root=3 (distinct_roots=1)
  stderr_mentions_branch=4 stderr_names_branch=3
  has_activity_trace=3
  cap_seconds={'7200': 3, '21600': 1}
  active_days=1
  duplicate_payload_strings=1
  alive_prefix_collision_files=1
    2026-01-01: 2
GOLDEN_EOF

if [ "$OUT" != "$GOLDEN" ]; then
  echo "❌ SELFTEST FAIL — census output does not match the golden block."
  echo "--- expected ---"; echo "$GOLDEN"
  echo "--- actual ---";   echo "$OUT"
  echo "--- diff ---";     diff <(echo "$GOLDEN") <(echo "$OUT") || true
  echo
  echo "payloads=3 with duplicate_payload_strings=0 -> de-dup was (re)introduced;"
  echo "payloads=5 -> the mid-string quotation was admitted; payloads=0 -> instrument dead."
  echo "Any other differing field names the broken counter."
  exit 1
fi

# The golden must stay live: if the census stops printing a field the diff already fails,
# but this also catches a golden that silently shrank.
if [ "$(echo "$GOLDEN" | grep -c .)" -lt 13 ]; then
  echo "❌ SELFTEST FAIL: golden block shrank — fields are no longer asserted"
  exit 1
fi

# Exercise --assert-nonzero (previously advertised but with ZERO coverage: a mutant
# disabling it passed the whole self-test).
EMPTY="$(mktemp -d)"
if python3 "$CENSUS" --root "$EMPTY" --assert-nonzero >/dev/null 2>&1; then
  rm -rf "$EMPTY"
  echo "❌ SELFTEST FAIL: --assert-nonzero exited 0 on an EMPTY corpus (format drift would read as 'no losses')"
  exit 1
fi
rm -rf "$EMPTY"

# ── repeatable/additive --root (Task 3) ────────────────────────────────────────
# A single --root B sees only B's ONE admitted payload; `--root A --root B` must
# see the UNION (4 + 1 = 5). A last-wins parser (the pre-Task-3 shape) would
# print 1 for the two-root invocation in either order.
D2="$(mktemp -d)"
trap 'rm -rf "$D" "$D2"' EXIT
mkdir -p "$D2/--tmp--"
PAYLOAD_E='⚠️ Sub-agent exceeded the task hard cap (7200s). Partial results below — parent should decide: accept, re-dispatch, or escalate.

Alive state: toolsInFlight=0 turnActive=false tickCount=7 everSawTool=false trace=[ready]

--- last stderr ---
[verification-gate] ⚠️ Sub-agent session started with 0 bridge-recovered files for root /Users/dev/other

--- last stdout ---

'
write_file "$D2/--tmp--/2026-01-02T00-00-00-000Z_seed3.jsonl" "$PAYLOAD_E"

B_ONLY="$(python3 "$CENSUS" --root "$D2" | head -1)"
if [ "$B_ONLY" != "payloads=1 files=1 git_field_state=0" ]; then
  echo "❌ SELFTEST FAIL: single-root scan of the second root expected payloads=1, got: $B_ONLY"
  exit 1
fi

ADD_AB="$(python3 "$CENSUS" --root "$D" --root "$D2" | head -1)"
ADD_BA="$(python3 "$CENSUS" --root "$D2" --root "$D" | head -1)"
if [ "$ADD_AB" != "payloads=5 files=3 git_field_state=2" ] || [ "$ADD_BA" != "payloads=5 files=3 git_field_state=2" ]; then
  echo "❌ SELFTEST FAIL: --root must be ADDITIVE (union) and order-independent."
  echo "   --root D --root D2 → $ADD_AB (expected payloads=5 files=3 git_field_state=2)"
  echo "   --root D2 --root D → $ADD_BA (expected payloads=5 files=3 git_field_state=2)"
  exit 1
fi

# Repointing ROOT instead of adding to it is the exact rev-6 error the plan
# reverted: it must be impossible for the default root to be silently replaced.
if python3 "$CENSUS" --assert-nonzero 2>/dev/null | head -1 | grep -q '^payloads=0 '; then
  echo "❌ SELFTEST FAIL: the default root (no --root) scans 0 payloads — ROOT was repointed"
  exit 1
fi

echo "✅ instrument can fail — OK (every published field diff-asserted; --assert-nonzero exercised; --root additive + order-independent)"
