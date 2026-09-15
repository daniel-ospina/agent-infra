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
# agent-infra (consumer repos). The physical pwd keeps the DEFAULT
# AGENT_INFRA_PATH (= HERE/..) pointing at the real agent-infra install rather
# than the consumer root. It is not what resolves the template for `--check`
# (that resolves script-first from the materializer's own physical parent, and
# `cd -P` already follows a symlinked `scripts/`); it matters for the default
# AGENT_INFRA_PATH handed to the materializer, and for resolving the
# materializer itself when invoked through a symlink.
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

# Run the materializer gate. The exit code is authoritative (0 = materialized
# — clean OR content-drift, 1 = stub/missing required heading); assignment-inside-if
# is safe under set -e and preserves the real status (no `|| true` — it would mask
# the code and make this a dead branch).
if ! OUTPUT="$(bash "$MATERIALIZER" --check "$STAGE_DIR" 2>&1)"; then
  echo ""
  echo "⛔ [agent-infra] AGENTS.md is a STUB — universal rules never reach the model."
  echo "   The file references AGENTS.base.md by URL, but pi only reads LOCAL files."
  # Surface the materializer's own output: it carries the `MISSING:` heading list
  # and a MARKER-AWARE remediation. Discarding it (as an earlier revision did)
  # left a marker-less file being told to run `--new`, which the materializer's
  # own clobber guard refuses. Its own `Fix: run …` line is STRIPPED, because
  # that command names the scratch dir this hook is about to delete — printing it
  # would hand the developer a command that cannot work.
  printf '%s\n' "$OUTPUT" | grep -v '^   Fix: run' || true
  echo "   Materialize it (base text inline + repo-specific tail below):"
  echo "     bash $MATERIALIZER --new $(pwd -P) <repo-tail-file>"
  echo "   Or refresh an existing materialized file:"
  echo "     bash $MATERIALIZER --merge $(pwd -P)"
  echo "   (If the message above says this file predates the BASE-END marker, follow"
  echo "    ITS guidance instead — both --new and --merge refuse in that case.)"
  echo ""
  exit 1
fi

# Passed (exit 0). The materializer distinguishes three non-failing outcomes,
# and they must NOT be collapsed into one green line (#1027):
#   clean  → base-owned region compared and matches
#   drift  → BASE-OWNED CONTENT DRIFTED (non-blocking; rules still reach pi)
#   skip   → no template resolvable, so the content compare never ran
#            ("content compare skipped") — a green "passed" here would be a
#            comparison-free pass, exactly what this gate must not print.
if grep -q 'base-owned content compare could not run' <<<"$OUTPUT"; then
  # A DEGRADED compare must not be reported as drift: the gate did not
  # establish drift, and "run --merge to refresh" is the wrong remedy for a
  # compare that never ran. Its own status, mirroring the skip branch.
  printf '%s\n' "$OUTPUT" | grep -E 'compare could not run' || true
  echo "[agent-infra] ⚠️ AGENTS.md materialization gate: passed HEADINGS ONLY — base-owned content compare could not run (not a verified pass)"
  exit 0
fi
if grep -q 'BASE-OWNED CONTENT DRIFTED' <<<"$OUTPUT"; then
  printf '%s\n' "$OUTPUT" | grep 'base head differs' || true
  echo "[agent-infra] ⚠️ AGENTS.md materialization gate: markers present, but base-owned content DRIFTED (non-blocking — run --merge to refresh; the required CI check pins content)"
  exit 0
fi
if grep -q 'content compare skipped' <<<"$OUTPUT"; then
  printf '%s\n' "$OUTPUT" | grep 'content compare skipped' || true
  echo "[agent-infra] ⚠️ AGENTS.md materialization gate: passed HEADINGS ONLY — base-owned content was not compared (base template not resolvable)"
  exit 0
fi
echo "[agent-infra] ✅ AGENTS.md materialization gate: passed"
exit 0
