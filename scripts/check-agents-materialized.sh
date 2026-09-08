#!/bin/bash
# check-agents-materialized.sh — authoring-time gate: consumer AGENTS.md must be
# MATERIALIZED (full base rules inline), never a URL-inheritance stub.
#
# Why: pi's resource-loader reads only local AGENTS.md/CLAUDE.md — it never
# fetches the AGENTS.base.md URL. A stub that "extends AGENTS.base.md" delivers
# ZERO universal rules to the model (Auto-Continue, Skill Compliance, Research
# Discipline, review loops, ...). tortoise + premise-labs ran stubbed for weeks;
# epic sessions had 0 occurrences of the NEVER-PAUSE rule in context (#600).
#
# Cost: guard-first — one git call on normal commits; full check ONLY when
# AGENTS.md is staged (stage-guard is the first statement). Exit 1 blocks the
# commit with remediation.
#
# Design: evaluates the STAGED blob (git show :AGENTS.md), NOT the worktree
# file. The hook commits the index blob, so checking the worktree would either
# (a) let a staged stub through when the worktree happens to be materialized,
# or (b) block on an unrelated divergent worktree edit. Checking the staged
# blob is byte-exact what the commit will contain (#600 review, P1).
set -euo pipefail

# ── Stage guard FIRST: only enforce when AGENTS.md is staged. Must be the
# first statement so normal commits pay one git call and nothing more.
if ! git diff --cached --name-only -- AGENTS.md 2>/dev/null | grep -q .; then
  exit 0
fi

# ── Staged DELETION policy: a repo deliberately removing AGENTS.md (leaving
# the materialization model) is a repo-owner decision, not a stub regression.
# Allow it, but say so — never silently skip.
if git diff --cached --name-only --diff-filter=D -- AGENTS.md 2>/dev/null | grep -q .; then
  echo "[agent-infra] ℹ️ AGENTS.md staged for DELETION — materialization gate skipped (repo-owner decision)."
  exit 0
fi

# ── Resolve the materializer. Physical pwd: scripts/ may be a symlink to
# agent-infra (consumer repos). Logical pwd would keep HERE under the consumer
# and the AGENT_INFRA_PATH fallback would resolve to the CONSUMER root → base
# template lookup fails → false "STUB" block on a materialized repo
# (P1-1, #600 review).
HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
MATERIALIZER="$HERE/materialize-agents.sh"

if [ ! -f "$MATERIALIZER" ]; then
  echo "[agent-infra] ⚠️ materialize-agents.sh not found — skipping AGENTS.md materialization gate"
  exit 0
fi

AGENT_INFRA_PATH="${AGENT_INFRA_PATH:-$(cd -P "$HERE/.." && pwd -P)}"
export AGENT_INFRA_PATH

# ── Evaluate the STAGED blob. Materializer --check expects a repo dir with an
# AGENTS.md on disk, so stage the blob into a scratch dir that holds only the
# staged content. This is byte-exact what the commit will contain.
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
if ! git show :AGENTS.md > "$STAGE_DIR/AGENTS.md" 2>/dev/null; then
  echo "⛔ [agent-infra] cannot read staged AGENTS.md blob — aborting gate"
  exit 1
fi

OUTPUT="$(bash "$MATERIALIZER" --check "$STAGE_DIR" 2>&1 || true)"
if [ $? -ne 0 ] || ! echo "$OUTPUT" | grep -q 'materialized (all base markers present)'; then
  echo ""
  echo "⛔ [agent-infra] AGENTS.md is a STUB — universal rules never reach the model."
  echo "   The file references AGENTS.base.md by URL, but pi only reads LOCAL files."
  echo "   Materialize it (base text inline + repo-specific tail below):"
  echo "     bash $MATERIALIZER --new $(pwd -P) <repo-tail-file>"
  echo "   Or refresh an existing materialized file:"
  echo "     bash $MATERIALIZER --merge $(pwd -P)"
  echo ""
  exit 1
fi

# Passed — surface a non-blocking drift warning if the materializer flagged one
# (consumer predates a base change; --merge refreshes).
echo "$OUTPUT" | grep -q 'base head differs' && echo "$OUTPUT" | grep 'base head differs'
echo "[agent-infra] ✅ AGENTS.md materialization gate: passed"
exit 0
