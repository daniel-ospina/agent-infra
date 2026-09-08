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
# Cost: ~40ms (4 greps on a 300-line file). Run from .husky/pre-commit
# STAGE-GUARDED (only when AGENTS.md is staged) so it costs nothing on normal
# commits. Exit 1 blocks the commit with remediation instructions.
set -euo pipefail

# Resolve PHYSICAL path (pwd -P): scripts/ may be a symlink to agent-infra
# (consumer repos). Logical pwd would keep HERE under the consumer and the
# AGENT_INFRA_PATH fallback would resolve to the CONSUMER root → base template
# lookup fails → false "STUB" block on a materialized repo (P1-1, #600 review).
HERE="$(cd -P "$(dirname "$0")" && pwd -P)"
MATERIALIZER="$HERE/materialize-agents.sh"
# The hook runs from the repo being committed — check THAT repo, not this
# script's location (the script may live in agent-infra while the commit
# happens in a consumer repo).
REPO="$(pwd -P)"

if [ ! -f "$MATERIALIZER" ]; then
  echo "[agent-infra] ⚠️ materialize-agents.sh not found — skipping AGENTS.md materialization gate"
  exit 0
fi

AGENT_INFRA_PATH="${AGENT_INFRA_PATH:-$(cd -P "$HERE/.." && pwd -P)}"
export AGENT_INFRA_PATH

# Stage guard: only enforce when AGENTS.md is actually staged (zero cost otherwise).
if ! git diff --cached --name-only | grep -qE '(^|/)AGENTS\.md$'; then
  exit 0
fi

if bash "$MATERIALIZER" --check "$REPO" >/dev/null 2>&1; then
  echo "[agent-infra] ✅ AGENTS.md materialization gate: passed"
  exit 0
fi

echo ""
echo "⛔ [agent-infra] AGENTS.md is a STUB — universal rules never reach the model."
echo "   The file references AGENTS.base.md by URL, but pi only reads LOCAL files."
echo "   Materialize it (base text inline + repo-specific tail below):"
echo "     bash $MATERIALIZER --new $REPO <repo-tail-file>"
echo "   Or refresh an existing materialized file:"
echo "     bash $MATERIALIZER --merge $REPO"
echo ""
exit 1
