#!/bin/bash
# materialize-agents.sh — regenerate a consumer repo's AGENTS.md as:
#   [full current AGENTS.base.md verbatim] + [repo-specific tail]
#
# The repo-specific tail is the portion of the consumer's existing AGENTS.md
# after the BASE-END marker (`<!-- AGENTS-BASE-END -->`). The script has
# three modes:
#
#   --check <repo>   Verify base markers present (all universal rules reach pi).
#                    Exit 0 = materialized, 1 = stub/missing (authoring-time gate).
#   --merge <repo>   Rewrite AGENTS.md = current base + existing tail after the
#                    marker (idempotent; safe to re-run after base changes).
#                    FIRST-TIME migration is NOT automatic — the human curates the
#                    tail once (see --new), because repo content must be deduped
#                    against universal sections that moved into the base head.
#   --new <repo> <tail-file>  First-time materialization: AGENTS.md = base +
#                    <tail-file> content, with BASE-END marker inserted.
#
# Why: pi's resource-loader reads ONLY local AGENTS.md/CLAUDE.md (walks up
# ancestors, never fetches URLs). A stub that "extends AGENTS.base.md by URL"
# delivers ZERO universal rules to the model (verified: tortoise/premise-labs
# sessions had 0 occurrences of the NEVER-PAUSE rule). Materialization is the
# only mechanism that works.
#
# Consumer AGENTS.md layout after materialization:
#   <AGENTS.base.md verbatim>            ← universal rules (mechanical, base-owned)
#   <!-- AGENTS-BASE-END -->             ← stable marker (never remove)
#   ## Repo-Specific Conventions         ← repo-owned tail
#   <repo content...>
set -euo pipefail

MARKER="<!-- AGENTS-BASE-END -->"

usage() { echo "usage: $0 --check|--merge <repo-dir> | --new <repo-dir> <tail-file>"; exit 2; }

[ $# -ge 2 ] || usage
MODE="$1"; REPO="$2"
# BASE_TEMPLATE is resolved lazily: only --new/--merge read it. --check
# greps the consumer's own AGENTS.md against its marker list and must work
# even when the template can't be resolved (consumer real-dir scripts/, no
# AGENT_INFRA_PATH) — otherwise a false "STUB" block masks a materialized
# file (#600 review P2).
resolve_base_template() {
  BASE_TEMPLATE="${AGENT_INFRA_PATH:-$(cd -P "$(dirname "$0")/.." && pwd -P)}/templates/AGENTS.base.md"
  [ -f "$BASE_TEMPLATE" ] || { echo "❌ base template missing: $BASE_TEMPLATE"; exit 1; }
}

# `--check` and `--merge` operate on an existing AGENTS.md; `--new` can create one.
if [ "$MODE" != "--new" ] && [ ! -f "$REPO/AGENTS.md" ]; then
  echo "❌ $REPO/AGENTS.md not found"
  exit 1
fi

# ── --check: structural marker gate ────────────────────────────────────
if [ "$MODE" = "--check" ]; then
  f="$REPO/AGENTS.md"
  missing=0
  for marker in \
    "HARD RULE: Auto-Continue" \
    "NEVER PAUSE WITHOUT A REASON" \
    "HARD RULE: Process Discipline" \
    "HARD RULE: Fix Broken Infrastructure" \
    "HARD RULE: Skill Compliance" \
    "Research Discipline" \
    "Debugging Discipline" \
    "Review Loop Protocol"; do
    grep -qF "$marker" "$f" || { echo "   MISSING: $marker"; missing=1; }
  done
  if [ $missing -eq 0 ]; then
    # Materialized. Optionally surface base-head drift vs the canonical
    # template (non-blocking warning — rules still reach the model; drift
    # means the file predates newer base sections and --merge would refresh).
    # Requires BOTH a resolvable template AND a canonical BASE-END marker
    # (anchored, same rule as extraction — a lenient substring guard here
    # would open the same guard/extract mismatch bug class fixed in --merge,
    # producing a false drift warning on a byte-current file). Without the
    # marker the head region is undefined (pre-marker repos like DMeer/
    # eldato/agent-infra are exempt — their whole file incl. tail would
    # otherwise be compared). EOLs are normalized (tr -d '\r') so a CRLF
    # checkout doesn't trip a spurious drift warning.
    if [ -n "${AGENT_INFRA_PATH:-}" ] \
       && [ -f "$AGENT_INFRA_PATH/templates/AGENTS.base.md" ] \
       && grep -qE "^${MARKER}[[:space:]]*$" "$f"; then
      HEAD=$(sed -n "1,/^${MARKER}[[:space:]]*$/p" "$f" | sed '$d' | tr -d '\r')
      TEMPLATE="$(cat "$AGENT_INFRA_PATH/templates/AGENTS.base.md" | tr -d '\r')"
      # Compare only the pre-marker head (base-owned region) — repo edits in
      # the head region count as drift (base is mechanical, base-owned).
      if [ "$HEAD" != "$TEMPLATE" ]; then
        echo "   ⚠️  base head differs from current AGENTS.base.md — refresh with --merge"
      fi
    fi
    echo "✅ $REPO: materialized (all base markers present)"
    exit 0
  fi
  echo "⛔ $REPO: AGENTS.md is a STUB — universal rules never reach the model."
  echo "   Fix: run  scripts/materialize-agents.sh --new $REPO <tail-file>"
  exit 1
fi

# ── --new: first-time materialization (base + curated tail) ────────────
if [ "$MODE" = "--new" ]; then
  [ $# -ge 3 ] || usage
  resolve_base_template
  TAIL="$3"
  [ -f "$TAIL" ] || { echo "❌ tail file missing: $TAIL"; exit 1; }
  if grep -qF "$MARKER" "$REPO/AGENTS.md" 2>/dev/null; then
    echo "⛔ $REPO already materialized (marker present). Use --merge to refresh."
    exit 1
  fi
  { cat "$BASE_TEMPLATE"; echo; echo "$MARKER"; echo; cat "$TAIL"; } > "$REPO/AGENTS.md.new"
  mv "$REPO/AGENTS.md.new" "$REPO/AGENTS.md"
  echo "✅ $REPO: AGENTS.md materialized (base + repo tail). Review then commit."
  exit 0
fi

# ── --merge: refresh base head, preserve existing tail ─────────────────
if [ "$MODE" = "--merge" ]; then
  resolve_base_template
  f="$REPO/AGENTS.md"
  # Guard and extraction must use ONE matching rule. grep -qF is a substring
  # match (lenient) while `sed -n "/^marker$/"` is anchored (strict): a
  # trailing space or CRLF on the marker line made the guard pass but the sed
  # range match nothing → TAIL_BODY empty → silent tail truncation (#600
  # review P1). Use an anchored grep with [[:space:]]*$ that tolerates
  # trailing whitespace/CRLF.
  if ! grep -qE "^${MARKER}[[:space:]]*$" "$f"; then
    echo "⛔ $REPO has no BASE-END marker — cannot auto-merge. First materialize with --new."
    exit 1
  fi
  # Tail = everything after the marker line (marker line itself included once),
  # CR-normalized so the LF template head and CRLF tail don't produce a
  # mixed-EOL file (#600 review P2).
  TAIL_BODY=$(sed -n "/^${MARKER}[[:space:]]*$/,\$p" "$f" | tr -d '\r')
  # Safety: refuse a merge that would lose the tail (extraction produced
  # nothing below the marker but the file is longer than the marker alone).
  # The original is untouched until the new file is fully built + mv'd, so no
  # .bak is needed — a failed build never reaches mv (set -e).
  TAIL_LINES=$(printf '%s\n' "$TAIL_BODY" | sed '1d' | grep -c . || true)
  if [ "$TAIL_LINES" -eq 0 ]; then
    echo "⛔ $REPO: --merge found no content below the BASE-END marker — refusing"
    echo "   to overwrite (would drop the repo tail). Inspect $f manually."
    exit 1
  fi
  { cat "$BASE_TEMPLATE"; echo; echo "$MARKER"; echo; printf '%s\n' "$TAIL_BODY" | sed "1d;2{/^$/d;}"; } > "$f.new"
  mv "$f.new" "$f"
  echo "✅ $REPO: AGENTS.md base head refreshed (tail preserved)."
  exit 0
fi

usage
