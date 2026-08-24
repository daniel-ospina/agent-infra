// ci-ref-check.cjs — pin-drift detection for agent-infra reusable workflows (#303)
//
// Consumed by bin/agent-infra.js (`agent-infra check` ci-ref surface) and
// unit-tested by scripts/ci-ref-check.test.mjs. Plain CJS — zero deps.
//
// Version contract (locked decisions #303 D2/D3/D6):
//   * Consumers pin `uses: daniel-ospina/agent-infra/.github/workflows/<wf>.yml@vX.Y.Z`
//     — a semver git tag, bumped explicitly. agent-infra's own self-caller may
//     use @main.
//   * manifest.json `ci.ref` is the source of truth for the current pin.
//   * A stale pin BLOCKS (`agent-infra check` exits 1) — no auto-rewrite.
//   * Any symlink under a consumer's .github/workflows/ is itself a broken
//     workflow entry to GitHub Actions (#555) — reported as an issue.

'use strict';

const fs = require('fs');
const path = require('path');

// Reusable workflows live under this path in the agent-infra repo.
const AGENT_INFRA_WORKFLOW_PREFIX = 'daniel-ospina/agent-infra/.github/workflows/';

/** Reusable workflow files that consumers may pin. */
const REUSABLE_WORKFLOWS = ['python-ci.yml', 'node-ci.yml', 'docs-ci.yml'];

/**
 * Parse `uses:` lines out of a workflow file.
 * Returns [{ uses, path, ref }] — `path` is the part before the last @,
 * `ref` the part after. Handles optional surrounding quotes. Commented-out
 * lines (`# uses: …`) are skipped so stale comments cannot false-positive.
 */
function parseUsesRefs(content) {
  const refs = [];
  for (const line of String(content).split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const m = /^(?:-\s+)?uses:\s*['"]?([^\s'"]+)['"]?\s*$/.exec(trimmed);
    if (!m) continue;
    const uses = m[1].trim();
    const at = uses.lastIndexOf('@');
    if (at === -1) continue;
    refs.push({ uses, path: uses.slice(0, at), ref: uses.slice(at + 1) });
  }
  return refs;
}

/** Filter parsed refs down to agent-infra reusable-workflow references. */
function agentInfraUses(content) {
  return parseUsesRefs(content)
    .filter(r => r.path.startsWith(AGENT_INFRA_WORKFLOW_PREFIX));
}

/** List workflow YAML files under <dir>/.github/workflows/ (missing dir → []). */
function workflowFilesIn(dir) {
  const wfDir = path.join(dir, '.github', 'workflows');
  if (!fs.existsSync(wfDir)) return [];
  return fs.readdirSync(wfDir)
    .filter(f => /\.(ya?ml)$/i.test(f))
    .map(f => path.join(wfDir, f));
}

/**
 * Find symlinks under <dir>/.github/workflows/. Any symlink is a broken
 * workflow entry (D3): GitHub reads the link-target string as YAML, so every
 * run fails at 0 jobs (#555 — cross-repo, same-repo, and discovery variants).
 */
function findWorkflowSymlinks(dir) {
  return workflowFilesIn(dir).filter(f => {
    try { return fs.lstatSync(f).isSymbolicLink(); } catch { return false; }
  });
}

/**
 * Compare a consumer's pinned `uses:` refs against the manifest ci.ref.
 * Returns [{ file, uses, ref, expected }] — empty when all pins match.
 * The target repo's own self-caller (@main) is included: a consumer on @main
 * IS drift (D2: only agent-infra itself may use @main); caller decides.
 */
function checkCiRefs(targetDir, ciRef) {
  const issues = [];
  for (const file of workflowFilesIn(targetDir)) {
    let content;
    try { content = fs.readFileSync(file, 'utf-8'); } catch { continue; }
    for (const r of agentInfraUses(content)) {
      // Only the workflow_call-capable reusable workflows are pin-compared;
      // a consumer can't hold a live ref to a non-callable workflow.
      if (!REUSABLE_WORKFLOWS.some(w => r.path.endsWith('/' + w))) continue;
      if (r.ref !== ciRef) {
        issues.push({
          file: path.relative(targetDir, file),
          uses: r.uses,
          ref: r.ref,
          expected: ciRef,
        });
      }
    }
  }
  return issues;
}

module.exports = {
  AGENT_INFRA_WORKFLOW_PREFIX,
  REUSABLE_WORKFLOWS,
  parseUsesRefs,
  agentInfraUses,
  workflowFilesIn,
  findWorkflowSymlinks,
  checkCiRefs,
};
