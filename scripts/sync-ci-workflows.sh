#!/usr/bin/env sh
# sync-ci-workflows.sh — materialize reusable workflows from templates (#303)
#
# GitHub Actions CANNOT parse symlinked workflow files (#555, verified): the
# workflow loader reads the blob, not the checkout filesystem, so a symlink
# under .github/workflows/ is read as its link-target string and every run
# fails with "error parsing called workflow" / "workflow file issue" at 0 jobs.
#
# Therefore the reusable workflows are REAL COMMITTED FILES in
# .github/workflows/, copied from templates/.github/workflows/ (the source of
# truth). This script performs the copy; the pipeline-compliance
# `workflow-drift` job fails CI if a template edit is committed without
# materialization.
#
# Usage: scripts/sync-ci-workflows.sh   (from the agent-infra repo root)
# After running: review `git diff --stat`, then commit the materialized copies.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/templates/.github/workflows"
DST="$ROOT/.github/workflows"

if [ ! -f "$SRC/python-ci.yml" ] || [ ! -f "$SRC/node-ci.yml" ] || [ ! -f "$SRC/docs-ci.yml" ]; then
  echo "❌ templates/.github/workflows/{python,node,docs}-ci.yml missing — run from the agent-infra repo root" >&2
  exit 1
fi

for f in python-ci.yml node-ci.yml docs-ci.yml; do
  if [ -L "$DST/$f" ]; then
    echo "❌ $DST/$f is a symlink — remove it first (symlinked workflows are invalid on GitHub Actions, #555)" >&2
    exit 1
  fi
  cp "$SRC/$f" "$DST/$f"
  echo "✅ materialized $DST/$f"
done

echo ""
echo "Next: git diff --stat to review, then commit. Run scripts/ci-ref-check.test.mjs afterwards."
