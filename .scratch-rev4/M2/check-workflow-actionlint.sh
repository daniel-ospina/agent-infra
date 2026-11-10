#!/bin/bash
# check-workflow-actionlint.sh — #398 actionlint gate: workflow YAML syntax +
# Actions-expression errors fail CI BEFORE merge (the #394 defect class).
#
# #394: node-ci.yml shipped a literal '${{' inside a plain YAML scalar
# description. GitHub parses ${{ in plain scalars; the trailing quote broke
# the expression lexer → the WHOLE workflow failed at validation with
# 'workflow file issue', zero jobs, zero logs — only the post-merge backstop
# (ci-main) caught it. This gate makes that class a pre-merge failure.
#
# Zero-new-deps (repo convention): runs the official rhysd/actionlint docker
# image (pinned 1.7.12) — no go install, no npm package, nothing committed.
# Docker is present on ubuntu-latest runners + macOS.
#
# Scope: syntax-check + expression errors ONLY. Shellcheck integration is
# disabled (-shellcheck=): actionlint bundles shellcheck, and pre-existing
# style-level shellcheck findings in enforce-skills.yml / python-ci.yml
# (SC2086/SC2129) would trip the gate on clean main — they are not the #394
# defect class. See #398 Test 2: "passes on current main".
#
# Usage:
#   scripts/check-workflow-actionlint.sh                  # lint repo workflows + templates
#   scripts/check-workflow-actionlint.sh FILE...          # lint explicit files (fixture tests)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="rhysd/actionlint:1.7.12"

# Fail-closed on missing docker — a gate that cannot run must not read green.
command -v docker >/dev/null 2>&1 || {
  echo "error: docker required (runs the official $IMAGE image) — present on ubuntu-latest runners" >&2
  exit 2
}

cd "$ROOT"

if [ "$#" -gt 0 ]; then
  # Normalize explicit args to repo-relative paths (absolute host paths don't
  # resolve inside the container, which mounts $ROOT at /repo).
  FILES=()
  for f in "$@"; do
    FILES+=("${f#$ROOT/}")
  done
else
  # Default scope: all committed workflows + the templates source of truth.
  # templates/ holds the reusable workflows (node-ci/python-ci/docs-ci) that
  # #394 broke in BOTH copies — parity-checked by workflow-drift but not
  # parse-checked until now.
  FILES=(.github/workflows/*.yml templates/.github/workflows/*.yml)
fi

docker run --rm -v "$PWD:/repo" -w /repo "$IMAGE" -shellcheck= "${FILES[@]}"
