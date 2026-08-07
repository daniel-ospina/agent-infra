#!/usr/bin/env bash
# _research_path.sh — resolve a research brief path for a GitHub issue.
#
# Pipeline skills dispatch this to find the research brief that should
# contextualize issue scoping or code review:
#   - skills/issue-scoping (Phase 0.5): --issue-body + --epic-path
#   - skills/code-review (Step 3.5):   --issue-body + --epic-path ""
#
# Resolution order:
#   1. Issue body `**Research:** <path>` field (issue-creation convention:
#      `**Research:** docs/epics/.../research-brief.md` or "none"). "none",
#      empty, or a non-existent path → fall through.
#   2. Epic doc path (`--epic-path docs/epics/<slug>/plan.md`): try sibling
#      research briefs `research-brief.md`, `research-brief.yaml`, `research.md`.
#      If --epic-path is a directory, look inside it for the same names.
#
# A path is printed ONLY if it exists on disk. When nothing resolves, prints
# nothing and exits 0 — callers already guard with:
#     [ -n "$PATH" ] && [ -f "$PATH" ] || PATH=""
#
# Exit codes: 0 = resolved (or none found — empty output), 2 = usage error.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/_research_path.sh --issue-body "$BODY" [--epic-path "$EPIC_DOC_PATH"]

  --issue-body <text>   GitHub issue body (required). Resolution source for
                        the `**Research:**` field.
  --epic-path <path>    Epic doc path extracted from `**Epic:**` (optional).
                        Used as fallback to derive a sibling research brief.

Prints a single line: the resolved research brief path (relative, as written
in the issue/derived), or nothing when no brief exists.

Exit: 0 = resolved or none (empty output), 2 = usage error.
EOF
}

ISSUE_BODY=""
EPIC_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue-body)
      [[ $# -ge 2 ]] || { echo "Error: --issue-body requires a value" >&2; exit 2; }
      ISSUE_BODY="$2"
      shift 2
      ;;
    --epic-path)
      [[ $# -ge 2 ]] || { echo "Error: --epic-path requires a value" >&2; exit 2; }
      EPIC_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$ISSUE_BODY" ]] || { echo "Error: --issue-body is required" >&2; exit 2; }

resolve_research_field() {
  # `**Research:** <path or "none">` — single-line convention (issue-creation).
  local value
  value=$(printf '%s\n' "$ISSUE_BODY" | awk '/^\*\*Research:\*\*/ { sub(/^\*\*Research:\*\*[[:space:]]*/, ""); print; exit }')
  [[ -n "$value" ]] || return 1
  value=$(printf '%s' "$value" | xargs)   # trim whitespace
  [[ -n "$value" ]] || return 1
  [[ "$value" == "none" || "$value" == "None" ]] && return 1
  [[ -f "$value" ]] || return 1
  printf '%s\n' "$value"
}

resolve_epic_sibling() {
  [[ -n "$EPIC_PATH" ]] || return 1
  local base
  if [[ -d "$EPIC_PATH" ]]; then
    base="$EPIC_PATH"
  else
    base=$(dirname "$EPIC_PATH")
  fi
  local candidate
  for candidate in "$base/research-brief.md" "$base/research-brief.yaml" "$base/research.md"; do
    [[ -f "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

if ! resolve_research_field && ! resolve_epic_sibling; then
  # No brief — empty output, exit 0 (callers treat empty as "no brief").
  exit 0
fi
