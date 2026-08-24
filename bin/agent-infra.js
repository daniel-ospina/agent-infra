#!/usr/bin/env node
'use strict';

// ─── agent-infra bootstrap CLI ──────────────────────────────────────────────
// Plain CJS — no npm dependencies. Uses only Node.js built-ins.
//
// Commands:
//   init <repo>   Bootstrap a repo with symlinks + templates
//   update         Refresh symlinks, preserve local files, report version
//   check [repo]   Verify symlinks match manifest.json
//                  --ci  CI mode: tiered drift gate — structural drift fails
//                        (exit 1), content drift warns (exit 0), machine-local
//                        surfaces skipped/informational (#305)

const fs = require('fs');
const path = require('path');
const os = require('os');
const ciRefCheck = require('../scripts/ci-ref-check.cjs');

// ─── Env / paths ────────────────────────────────────────────────────────────

const AGENT_INFRA_PATH = path.resolve(process.env.AGENT_INFRA_PATH || path.join(__dirname, '..'));
const PI_HOME = path.join(os.homedir(), '.pi');
const PI_AGENT = path.join(PI_HOME, 'agent');
const PI_EXTENSIONS = path.join(PI_AGENT, 'extensions');
const PI_SKILLS = path.join(PI_AGENT, 'skills');

const MANIFEST_PATH = path.join(AGENT_INFRA_PATH, 'manifest.json');
const EXTENSIONS_SRC = path.join(AGENT_INFRA_PATH, 'extensions');
const SKILLS_SRC = path.join(AGENT_INFRA_PATH, 'skills');
const SCRIPTS_SRC = path.join(AGENT_INFRA_PATH, 'scripts');
const TEMPLATES_SRC = path.join(AGENT_INFRA_PATH, 'templates');
const CI_SRC = path.join(TEMPLATES_SRC, '.github', 'workflows');

// ─── Helpers ────────────────────────────────────────────────────────────────

/** Ensure a directory exists (mkdir -p). */
function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

/** Remove a path whether it's a file, symlink, or directory. Graceful — no error if missing. */
function removeIfExists(p) {
  fs.rmSync(p, { recursive: true, force: true });
}

/** Create a symlink (removing any existing entry at dest first). */
function forceSymlink(src, dest) {
  removeIfExists(dest);
  fs.symlinkSync(src, dest);
}

/** Copy a file from src to dest, preserving mode. Creates parent dirs. */
function copyFile(src, dest) {
  ensureDir(path.dirname(dest));
  fs.copyFileSync(src, dest);
  // Preserve mode for executables (hooks)
  const stat = fs.statSync(src);
  fs.chmodSync(dest, stat.mode);
}

/** Recursively copy a directory. */
function copyDir(srcDir, destDir) {
  ensureDir(destDir);
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const src = path.join(srcDir, entry.name);
    const dest = path.join(destDir, entry.name);
    if (entry.isDirectory()) {
      copyDir(src, dest);
    } else {
      copyFile(src, dest);
    }
  }
}

/** Check if two files have the same content. */
function filesEqual(a, b) {
  if (!fs.existsSync(a) || !fs.existsSync(b)) return false;
  try {
    return fs.readFileSync(a).equals(fs.readFileSync(b));
  } catch {
    return false;
  }
}

/** Read a symlink target, or null if not a symlink / doesn't exist. */
function readlinkSafe(p) {
  try {
    if (fs.lstatSync(p).isSymbolicLink()) {
      return fs.readlinkSync(p);
    }
  } catch (e) {
    if (e.code !== 'ENOENT') throw e;
  }
  return null;
}

/** Detect repo stack from filesystem hints. */
function detectStack(targetDir) {
  if (fs.existsSync(path.join(targetDir, 'pyproject.toml')) ||
      fs.existsSync(path.join(targetDir, 'setup.py')) ||
      fs.existsSync(path.join(targetDir, 'setup.cfg'))) return 'python';
  if (fs.existsSync(path.join(targetDir, 'package.json'))) return 'node';
  return 'docs';
}

/** Map detected stack to the expected CI template filename. */
function ciTemplateForStack(stack) {
  return { python: 'python-ci.yml', node: 'node-ci.yml', docs: 'docs-ci.yml' }[stack];
}

/** Resolve a symlink target relative to the link's directory. */
function resolveLink(p) {
  const target = readlinkSafe(p);
  if (!target) return null;
  return path.resolve(path.dirname(p), target);
}

/** Load and validate manifest.json. */
function loadManifest() {
  if (!fs.existsSync(MANIFEST_PATH)) {
    console.error(`❌ manifest.json not found at ${MANIFEST_PATH}`);
    console.error(`   AGENT_INFRA_PATH=${AGENT_INFRA_PATH}`);
    process.exit(1);
  }
  try {
    return JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf-8'));
  } catch (e) {
    console.error(`❌ Failed to parse manifest.json: ${e.message}`);
    process.exit(1);
  }
}

// ─── Commands ───────────────────────────────────────────────────────────────

/** init <targetDir> — bootstrap a repo */
function cmdInit(targetDir) {
  targetDir = path.resolve(targetDir);

  // ── Prerequisite: warn if AGENT_INFRA_PATH not explicitly set ──
  if (!process.env.AGENT_INFRA_PATH) {
    console.warn('⚠️  AGENT_INFRA_PATH is not set in your environment.');
    console.warn('   Add to your shell profile (~/.zshrc): export AGENT_INFRA_PATH=/path/to/agent-infra');
    console.warn('   Falling back to auto-detected path: ' + AGENT_INFRA_PATH);
    console.warn('');
  }

  if (!fs.existsSync(targetDir)) {
    console.error(`❌ Target directory does not exist: ${targetDir}`);
    process.exit(1);
  }

  const manifest = loadManifest();
  const version = manifest.version;

  console.log(`🚀 Bootstrapping ${targetDir} with agent-infra v${version}`);
  console.log(`   agent-infra at: ${AGENT_INFRA_PATH}`);

  // ── Extensions → ~/.pi/agent/extensions/ ──
  ensureDir(PI_EXTENSIONS);
  const extManifest = manifest.files['extensions/'];
  if (extManifest && Array.isArray(extManifest.entries)) {
    console.log('\n📦 Extensions:');
    for (const rawEntry of extManifest.entries) {
      const entry = rawEntry.replace(/\/+$/, ''); // strip trailing slashes — Node.js fails on symlinks with them
      const src = path.join(EXTENSIONS_SRC, entry);
      const dest = path.join(PI_EXTENSIONS, entry);
      if (!fs.existsSync(src)) {
        console.warn(`   ⚠️  Skipping missing entry: ${entry}`);
        continue;
      }
      removeIfExists(dest);
      fs.symlinkSync(src, dest);
      console.log(`   ✅ ${entry}`);
    }
  }

  // ── Skills → ~/.pi/agent/skills/ ──
  if (manifest.files['skills/']) {
    if (resolveLink(PI_SKILLS) === null && fs.existsSync(PI_SKILLS)) {
      console.warn(`\n   ⚠️  ~/.pi/agent/skills exists as a real directory — skipping`);
    } else {
      ensureDir(PI_AGENT);
      forceSymlink(SKILLS_SRC, PI_SKILLS);
      console.log(`\n📚 Skills → ${PI_SKILLS}`);
    }
  }

  // ── Scripts → <target>/scripts/ ──
  if (manifest.files['scripts/']) {
    const scriptsDest = path.join(targetDir, 'scripts');
    if (resolveLink(scriptsDest) === null && fs.existsSync(scriptsDest)) {
      console.warn(`\n   ⚠️  scripts/ exists as a real directory — skipping`);
    } else {
      forceSymlink(SCRIPTS_SRC, scriptsDest);
      console.log(`\n🔧 Scripts → ${scriptsDest}`);
    }
  }

  // ── Templates (copy, don't overwrite if exists) ──
  if (manifest.files['templates/']) {
    console.log('\n📋 Templates:');

    // AGENTS.base.md → AGENTS.md
    const agentsSrc = path.join(TEMPLATES_SRC, 'AGENTS.base.md');
    const agentsDest = path.join(targetDir, 'AGENTS.md');
    if (!fs.existsSync(agentsSrc)) {
      console.log(`   ⚠️  AGENTS.base.md missing — skipping AGENTS.md`);
    } else if (fs.existsSync(agentsDest)) {
      console.log(`   ⏭️  AGENTS.md already exists (preserved)`);
    } else {
      copyFile(agentsSrc, agentsDest);
      console.log(`   ✅ AGENTS.md`);
    }

    // .mcp.base.json → .mcp.json
    const mcpSrc = path.join(TEMPLATES_SRC, '.mcp.base.json');
    const mcpDest = path.join(targetDir, '.mcp.json');
    if (!fs.existsSync(mcpSrc)) {
      console.log(`   ⚠️  .mcp.base.json missing — skipping .mcp.json`);
    } else if (fs.existsSync(mcpDest)) {
      console.log(`   ⏭️  .mcp.json already exists (preserved)`);
    } else {
      copyFile(mcpSrc, mcpDest);
      console.log(`   ✅ .mcp.json`);
    }

    // .husky/ hooks
    const huskySrc = path.join(TEMPLATES_SRC, '.husky');
    const huskyDest = path.join(targetDir, '.husky');
    if (!fs.existsSync(huskySrc)) {
      console.log(`   ⚠️  .husky/ source missing — skipping`);
    } else if (fs.existsSync(huskyDest)) {
      console.log(`   ⏭️  .husky/ already exists (preserved)`);
    } else {
      copyDir(huskySrc, huskyDest);
      console.log(`   ✅ .husky/`);
    }

    // CI workflow symlinks (detected stack only)
    _initCI(targetDir);
  }

  // ── Write .agent-infra-version ──
  const versionFile = path.join(targetDir, '.agent-infra-version');
  fs.writeFileSync(versionFile, version + '\n');
  console.log(`\n📌 .agent-infra-version → ${version}`);
  console.log(`\n✅ Done. agent-infra v${version} bootstrapped.`);
}

/** update — refresh symlinks, preserve local files, report version */
function cmdUpdate() {
  const targetDir = process.cwd();
  const manifest = loadManifest();
  const version = manifest.version;

  console.log(`🔄 Updating agent-infra to v${version}`);
  console.log(`   target: ${targetDir}`);
  console.log(`   agent-infra at: ${AGENT_INFRA_PATH}`);

  let changes = 0;

  // ── Extensions ──
  const extManifest = manifest.files['extensions/'];
  if (extManifest && Array.isArray(extManifest.entries)) {
    ensureDir(PI_EXTENSIONS);
    for (const rawEntry of extManifest.entries) {
      const entry = rawEntry.replace(/\/+$/, '');
      const src = path.join(EXTENSIONS_SRC, entry);
      const dest = path.join(PI_EXTENSIONS, entry);
      if (!fs.existsSync(src)) {
        console.warn(`   ⚠️  Missing source: ${entry}`);
        continue;
      }
      const current = resolveLink(dest);
      if (current !== src) {
        forceSymlink(src, dest);
        console.log(`   🔄 ${entry}`);
        changes++;
      }
    }
  }

  // ── Skills ──
  if (manifest.files['skills/']) {
    const current = resolveLink(PI_SKILLS);
    if (current === null && fs.existsSync(PI_SKILLS)) {
      // Real directory at dest — don't destroy user content
      console.warn(`   ⚠️  ~/.pi/agent/skills exists as a real directory (not a symlink) — skipping`);
    } else if (current !== SKILLS_SRC) {
      ensureDir(PI_AGENT);
      forceSymlink(SKILLS_SRC, PI_SKILLS);
      console.log(`   🔄 skills/`);
      changes++;
    }
  }

  // ── Scripts ──
  if (manifest.files['scripts/']) {
    const scriptsDest = path.join(targetDir, 'scripts');
    const current = resolveLink(scriptsDest);
    if (current === null && fs.existsSync(scriptsDest)) {
      console.warn(`   ⚠️  scripts/ exists as a real directory (not a symlink) — skipping`);
    } else if (current !== SCRIPTS_SRC) {
      forceSymlink(SCRIPTS_SRC, scriptsDest);
      console.log(`   🔄 scripts/`);
      changes++;
    }
  }

  // ── Templates (only if missing) ──
  if (manifest.files['templates/']) {
    const agentsSrc = path.join(TEMPLATES_SRC, 'AGENTS.base.md');
    const agentsDest = path.join(targetDir, 'AGENTS.md');
    if (!fs.existsSync(agentsSrc)) {
      console.log(`   ⚠️  AGENTS.base.md missing — skipping AGENTS.md`);
    } else if (!fs.existsSync(agentsDest)) {
      copyFile(agentsSrc, agentsDest);
      console.log(`   ✅ AGENTS.md (created)`);
      changes++;
    } else {
      console.log(`   ⏭️  AGENTS.md (preserved)`);
    }

    const mcpSrc = path.join(TEMPLATES_SRC, '.mcp.base.json');
    const mcpDest = path.join(targetDir, '.mcp.json');
    if (!fs.existsSync(mcpSrc)) {
      console.log(`   ⚠️  .mcp.base.json missing — skipping .mcp.json`);
    } else if (!fs.existsSync(mcpDest)) {
      copyFile(mcpSrc, mcpDest);
      console.log(`   ✅ .mcp.json (created)`);
      changes++;
    } else {
      console.log(`   ⏭️  .mcp.json (preserved)`);
    }

    const huskySrc = path.join(TEMPLATES_SRC, '.husky');
    const huskyDest = path.join(targetDir, '.husky');
    if (!fs.existsSync(huskySrc)) {
      console.log(`   ⚠️  .husky/ source missing — skipping`);
    } else if (!fs.existsSync(huskyDest)) {
      copyDir(huskySrc, huskyDest);
      console.log(`   ✅ .husky/ (created)`);
      changes++;
    } else {
      console.log(`   ⏭️  .husky/ (preserved)`);
    }

    // CI workflow symlinks (detected stack only)
    changes += _updateCI(targetDir);
  }

  // ── .agent-infra-version ──
  const versionFile = path.join(targetDir, '.agent-infra-version');
  const currentVersion = (() => {
    try { return fs.readFileSync(versionFile, 'utf-8').trim(); } catch { return null; }
  })();
  if (currentVersion !== version) {
    fs.writeFileSync(versionFile, version + '\n');
    console.log(`   📌 .agent-infra-version: ${currentVersion || 'none'} → ${version}`);
    changes++;
  }

  if (changes === 0) {
    console.log(`\n✅ Already up to date (v${version}).`);
  } else {
    console.log(`\n✅ Updated (${changes} change${changes === 1 ? '' : 's'}). v${version}.`);
  }
}

/** Classify a non-matching symlink target.
 *  'machine-local' — committed absolute/escaping path, unverifiable on a CI
 *  runner (the normal state of a consumer's committed symlinks).
 *  'stale' — resolves inside the repo tree (a genuinely rotted relative link). */
function classifyUnresolved(linkTarget, resolved, targetDir) {
  const external = path.isAbsolute(linkTarget) || path.relative(targetDir, resolved).startsWith('..');
  return external ? 'machine-local' : 'stale';
}

/** check [targetDir] — verify symlinks match manifest.json */
function cmdCheck(targetDir, ciMode) {
  targetDir = targetDir ? path.resolve(targetDir) : process.cwd();

  const manifest = loadManifest();
  const version = manifest.version;
  // Repo identity for exemptions + summary. In CI the checkout dir is a fixed
  // name (drift-check.yml checks out to ./consumer), so the real repo name is
  // passed via AGENT_INFRA_REPO_NAME; locally it is the target dir's basename.
  const repoName = process.env.AGENT_INFRA_REPO_NAME || path.basename(targetDir);
  // Manifest-driven exemptions (#305): manifest.check.exemptions[<repo>] lists
  // surfaces to skip for this repo (unlinked consumers, self-contained CI, ...).
  // NOTE: exemptions apply in BOTH local and CI mode — they replace the old
  // hardcoded eldato-outreach skip, which was also mode-independent.
  const exemptList = ((manifest.check && manifest.check.exemptions) || {})[repoName] || [];
  const exempted = (surface) => exemptList.includes(surface);

  console.log(`🔍 Checking agent-infra v${version}${ciMode ? ' (CI mode)' : ''}`);
  console.log(`   agent-infra at: ${AGENT_INFRA_PATH}`);
  console.log(`   target: ${targetDir}\n`);

  const issues = []; // { type, entry, reason, tier: 'fail' | 'warn' | 'info' }
  let ok = 0;

  // ── Check extensions ── (machine-local ~/.pi farm — skipped in CI mode)
  if (ciMode) {
    console.log('   ⏭️  Extensions — skipped in CI mode (machine-local; owned by the local pre-commit gate)');
  } else {
    const extManifest = manifest.files['extensions/'];
    if (extManifest && Array.isArray(extManifest.entries)) {
      console.log('📦 Extensions:');
      for (const rawEntry of extManifest.entries) {
        const entry = rawEntry.replace(/\/+$/, '');
        const expectedSrc = path.join(EXTENSIONS_SRC, entry);
        const linkPath = path.join(PI_EXTENSIONS, entry);

        if (!fs.existsSync(expectedSrc)) {
          issues.push({ type: 'extensions', entry, reason: `source missing: ${expectedSrc}` });
          console.log(`   ❌ ${entry} — source missing`);
          continue;
        }

        const linkTarget = readlinkSafe(linkPath);
        if (linkTarget === null) {
          issues.push({ type: 'extensions', entry, reason: `not a symlink (or missing): ${linkPath}` });
          console.log(`   ❌ ${entry} — not symlinked`);
          continue;
        }

        const resolved = path.resolve(path.dirname(linkPath), linkTarget);
        if (resolved !== expectedSrc) {
          issues.push({ type: 'extensions', entry, reason: `points to ${resolved}, expected ${expectedSrc}` });
          console.log(`   ⚠️  ${entry} — stale (→ ${linkTarget})`);
        } else {
          ok++;
          console.log(`   ✅ ${entry}`);
        }
      }
    }
  }

  // ── Check skills ── (machine-local — skipped in CI mode)
  if (ciMode) {
    console.log('   ⏭️  Skills — skipped in CI mode (machine-local; owned by the local pre-commit gate)');
  } else if (manifest.files['skills/']) {
    const expected = SKILLS_SRC;
    if (!fs.existsSync(expected)) {
      issues.push({ type: 'skills', reason: `source missing: ${expected}` });
      console.log(`\n📚 Skills:\n   ❌ skills/ — source missing`);
    } else {
      const linkTarget = readlinkSafe(PI_SKILLS);
      console.log(`\n📚 Skills:`);
      if (linkTarget === null) {
        issues.push({ type: 'skills', reason: `not a symlink (or missing): ${PI_SKILLS}` });
        console.log(`   ❌ skills/ — not symlinked`);
      } else {
        const resolved = path.resolve(path.dirname(PI_SKILLS), linkTarget);
        if (resolved !== expected) {
          issues.push({ type: 'skills', reason: `points to ${resolved}, expected ${expected}` });
          console.log(`   ⚠️  skills/ — stale (→ ${linkTarget})`);
        } else {
          ok++;
          console.log(`   ✅ skills/`);
        }
      }
    }
  }

  // ── Check scripts (in target repo) ──
  if (manifest.files['scripts/']) {
    const scriptsDest = path.join(targetDir, 'scripts');
    if (exempted('scripts')) {
      console.log(`\n🔧 Scripts:\n   ⏭️  scripts/ — exempted via manifest check.exemptions`);
    } else if (!fs.existsSync(SCRIPTS_SRC)) {
      issues.push({ type: 'scripts', tier: 'fail', reason: `source missing: ${SCRIPTS_SRC}` });
      console.log(`\n🔧 Scripts:\n   ❌ scripts/ — source missing`);
    } else {
      console.log(`\n🔧 Scripts:`);
      const linkTarget = readlinkSafe(scriptsDest);
      if (linkTarget === null) {
        // Only flag as issue if this is a target repo check (not agent-infra itself)
        if (targetDir !== AGENT_INFRA_PATH) {
          issues.push({ type: 'scripts', tier: 'fail', reason: `not symlinked: ${scriptsDest}` });
          console.log(`   ❌ scripts/ — not symlinked`);
        } else {
          console.log(`   ℹ️  scripts/ — source repo (no symlink needed)`);
        }
      } else {
        const resolved = path.resolve(path.dirname(scriptsDest), linkTarget);
        if (resolved === SCRIPTS_SRC) {
          ok++;
          console.log(`   ✅ scripts/`);
        } else if (ciMode && !fs.existsSync(resolved) && classifyUnresolved(linkTarget, resolved, targetDir) === 'machine-local') {
          // Committed absolute symlinks point at a machine-local agent-infra
          // checkout — unverifiable on the CI runner, not propagation drift.
          issues.push({ type: 'scripts', tier: 'info', reason: `symlink target machine-local (${linkTarget}) — unverifiable on CI runner` });
          console.log(`   ℹ️  scripts/ — symlink → ${linkTarget} (machine-local, unverifiable in CI)`);
        } else {
          issues.push({ type: 'scripts', tier: 'fail', reason: `points to ${resolved}, expected ${SCRIPTS_SRC}` });
          console.log(`   ⚠️  scripts/ — stale (→ ${linkTarget})`);
        }
      }
    }
  }

  // ── Check templates (target repo) ──
  if (manifest.files['templates/']) {
    console.log(`\n📋 Templates:`);

    // AGENTS.md
    const agentsDest = path.join(targetDir, 'AGENTS.md');
    const agentsSrc = path.join(TEMPLATES_SRC, 'AGENTS.base.md');
    if (exempted('templates/AGENTS.md')) {
      console.log(`   ⏭️  AGENTS.md — exempted via manifest check.exemptions`);
    } else if (!fs.existsSync(agentsDest)) {
      issues.push({ type: 'templates', entry: 'AGENTS.md', tier: 'fail', reason: 'missing' });
      console.log(`   ❌ AGENTS.md — missing`);
    } else if (!fs.existsSync(agentsSrc)) {
      issues.push({ type: 'templates', entry: 'AGENTS.md', tier: 'fail', reason: 'source missing: AGENTS.base.md' });
      console.log(`   ❌ AGENTS.md — source missing`);
    } else if (!filesEqual(agentsDest, agentsSrc)) {
      issues.push({ type: 'templates', entry: 'AGENTS.md', tier: ciMode ? 'warn' : 'fail', reason: 'differs from AGENTS.base.md' });
      console.log(ciMode
        ? `   ⚠️  AGENTS.md — differs from base (content drift — warning only in CI)`
        : `   ⚠️  AGENTS.md — differs from base`);
    } else {
      ok++;
      console.log(`   ✅ AGENTS.md`);
    }

    // .mcp.json
    const mcpDest = path.join(targetDir, '.mcp.json');
    const mcpSrc = path.join(TEMPLATES_SRC, '.mcp.base.json');
    if (exempted('templates/.mcp.json')) {
      console.log(`   ⏭️  .mcp.json — exempted via manifest check.exemptions`);
    } else if (!fs.existsSync(mcpDest)) {
      issues.push({ type: 'templates', entry: '.mcp.json', tier: 'fail', reason: 'missing' });
      console.log(`   ❌ .mcp.json — missing`);
    } else if (!fs.existsSync(mcpSrc)) {
      issues.push({ type: 'templates', entry: '.mcp.json', tier: 'fail', reason: 'source missing: .mcp.base.json' });
      console.log(`   ❌ .mcp.json — source missing`);
    } else if (!filesEqual(mcpDest, mcpSrc)) {
      issues.push({ type: 'templates', entry: '.mcp.json', tier: ciMode ? 'warn' : 'fail', reason: 'differs from .mcp.base.json' });
      console.log(ciMode
        ? `   ⚠️  .mcp.json — differs from base (content drift — warning only in CI)`
        : `   ⚠️  .mcp.json — differs from base`);
    } else {
      ok++;
      console.log(`   ✅ .mcp.json`);
    }

    // .husky/
    const huskyDest = path.join(targetDir, '.husky');
    const huskySrc = path.join(TEMPLATES_SRC, '.husky');
    if (exempted('templates/.husky/')) {
      console.log(`   ⏭️  .husky/ — exempted via manifest check.exemptions`);
    } else if (!fs.existsSync(huskyDest)) {
      issues.push({ type: 'templates', entry: '.husky/', tier: 'fail', reason: 'missing' });
      console.log(`   ❌ .husky/ — missing`);
    } else if (!fs.existsSync(huskySrc)) {
      issues.push({ type: 'templates', entry: '.husky/', tier: 'fail', reason: 'source missing' });
      console.log(`   ❌ .husky/ — source missing`);
    } else {
      let huskyOk = true;
      for (const entry of fs.readdirSync(huskySrc, { withFileTypes: true })) {
        const srcHook = path.join(huskySrc, entry.name);
        const destHook = path.join(huskyDest, entry.name);
        if (!fs.existsSync(destHook)) {
          issues.push({ type: 'templates', entry: `.husky/${entry.name}`, tier: 'fail', reason: 'missing' });
          console.log(`   ❌ .husky/${entry.name} — missing`);
          huskyOk = false;
        } else if (!fs.existsSync(srcHook)) {
          issues.push({ type: 'templates', entry: `.husky/${entry.name}`, tier: 'fail', reason: 'source missing' });
          console.log(`   ❌ .husky/${entry.name} — source missing`);
          huskyOk = false;
        } else if (entry.isFile() && !filesEqual(destHook, srcHook)) {
          issues.push({ type: 'templates', entry: `.husky/${entry.name}`, tier: ciMode ? 'warn' : 'fail', reason: 'differs from base' });
          console.log(ciMode
            ? `   ⚠️  .husky/${entry.name} — differs from base (content drift — warning only in CI)`
            : `   ⚠️  .husky/${entry.name} — differs from base`);
          huskyOk = false;
        }
      }
      if (huskyOk) {
        ok++;
        console.log(`   ✅ .husky/`);
      }
    }

    // CI workflows (#303): real-file/pin contract — no symlinks + pin compare.
    ok += _checkCI(manifest, targetDir, issues, ciMode, exempted);
  }

  // ── Check .agent-infra-version ── (the propagation contract — always fails)
  const versionFile = path.join(targetDir, '.agent-infra-version');
  const fileVersion = (() => {
    try { return fs.readFileSync(versionFile, 'utf-8').trim(); } catch { return null; }
  })();
  console.log(`\n📌 .agent-infra-version:`);
  if (!fileVersion) {
    issues.push({ type: 'version', tier: 'fail', reason: 'missing .agent-infra-version' });
    console.log(`   ❌ missing`);
  } else if (fileVersion !== version) {
    issues.push({ type: 'version', tier: 'fail', reason: `${fileVersion} ≠ ${version}` });
    console.log(`   ❌ ${fileVersion} (manifest: ${version}) — run agent-infra update`);
  } else {
    ok++;
    console.log(`   ✅ ${version}`);
  }

  // ── Summary ──
  console.log(`\n${'─'.repeat(50)}`);
  if (ciMode) {
    // Tiered gate (#305): structural drift fails the job; content drift warns
    // (exit 0) because consumers legitimately customize copied templates;
    // machine-local symlink targets are informational.
    const fails = issues.filter((i) => i.tier === 'fail');
    const warns = issues.filter((i) => i.tier === 'warn');
    const infos = issues.filter((i) => i.tier === 'info');
    const status = fails.length ? 'FAIL' : (warns.length ? 'WARN' : 'CLEAN');

    for (const issue of fails) {
      const loc = issue.entry ? `${issue.type}/${issue.entry}` : issue.type;
      console.log(`   ❌ ${loc}: ${issue.reason}`);
    }
    for (const issue of warns) {
      const loc = issue.entry ? `${issue.type}/${issue.entry}` : issue.type;
      console.log(`   ⚠️  ${loc}: ${issue.reason}`);
    }
    for (const issue of infos) {
      const loc = issue.entry ? `${issue.type}/${issue.entry}` : issue.type;
      console.log(`   ℹ️  ${loc}: ${issue.reason}`);
    }

    console.log(`\n${'─'.repeat(50)}`);
    console.log(`agent-infra drift summary (${repoName}):`);
    console.log(`   status: ${status}`);
    console.log(`   structural: ${fails.length}`);
    console.log(`   content: ${warns.length}`);
    console.log(`   info: ${infos.length}`);
    console.log(`   exempted surfaces: ${exemptList.length ? exemptList.join(', ') : '(none)'}`);

    if (status === 'FAIL') {
      console.log(`   remediation: run \`agent-infra update\` in this repo — or \`./sync --all\` from`);
      console.log(`                agent-infra to batch-fix all linked repos. If the repo was`);
      console.log(`                never bootstrapped: run \`agent-infra init\`.`);
      process.exit(1);
    }
    if (status === 'WARN') {
      console.log(`   → content drift only — passing (exit 0). Customization is legitimate;`);
      console.log(`     the template merge/overwrite policy is out of scope (#305).`);
    } else {
      console.log(`   → clean`);
    }
    process.exit(0);
  }

  // Local mode — unchanged behavior: any issue fails
  if (issues.length === 0) {
    console.log(`✅ All checks passed (${ok} items). agent-infra v${version}.`);
  } else {
    console.log(`❌ ${issues.length} issue${issues.length === 1 ? '' : 's'} found:`);
    for (const issue of issues) {
      const loc = issue.entry ? `${issue.type}/${issue.entry}` : issue.type;
      console.log(`   • ${loc}: ${issue.reason}`);
    }
    process.exit(1);
  }
}

// ─── CI Workflow Helpers (#303 real-file/pin model) ─────────────────────────
// GitHub Actions CANNOT parse symlinked workflow files (#555): the loader
// reads the blob, not the checkout filesystem. Reusable workflows are real
// committed files; consumers pin a semver tag recorded in manifest.json
// `ci.ref`. `agent-infra check` (ci-ref surface) BLOCKS on a stale pin or on
// ANY symlink under a consumer's .github/workflows/ (a symlink there is
// itself a broken-workflow entry). No auto-rewrite (owner decision).

/** Warn loudly about symlinks under a consumer's .github/workflows/ (D3). */
function warnCISymlinks(targetDir) {
  const symlinks = ciRefCheck.findWorkflowSymlinks(targetDir);
  for (const f of symlinks) {
    console.log(`   ⚠️  ${path.relative(targetDir, f)} — SYMLINK (invalid on GitHub Actions, #555) — replace with a real file`);
  }
  return symlinks.length;
}

/** _initCI — called from cmdInit(). No symlink creation (D3). */
function _initCI(targetDir) {
  const n = warnCISymlinks(targetDir);
  if (n > 0) {
    console.log(`\n🔧 CI Workflows:\n   ⚠️  ${n} symlink(s) under .github/workflows/ — symlinked workflows are invalid on GitHub Actions (#555). Replace with real files.`);
  } else {
    console.log(`\n🔧 CI Workflows:\n   ✅ no symlinks under .github/workflows/ (real-file contract, #303)`);
  }
}

/** _updateCI — called from cmdUpdate(). BLOCK on symlinks; never auto-rewrite pins. */
function _updateCI(targetDir) {
  const n = warnCISymlinks(targetDir);
  if (n > 0) {
    console.log(`   ⚠️  ${n} symlink(s) under .github/workflows/ — replace with real files before committing (#555)`);
  } else {
    console.log(`   ✅ CI: no symlinks under .github/workflows/ (#303)`);
  }
  // ci-ref pins are NOT auto-rewritten (owner decision #303): a stale pin
  // must be bumped explicitly — `agent-infra check` reports and blocks.
  return 0;
}

/** _checkCI — called from cmdCheck(). Pushes issues[] (exit 1 on any).
 *  D3: zero symlinks under .github/workflows/.
 *  D2/D6: consumer pins must equal manifest ci.ref (agent-infra itself uses
 *  @main for its self-caller and is exempt from the pin compare).
 *  #305: the hardcoded eldato-outreach skip is replaced by the manifest-driven
 *  exemptions (manifest.check.exemptions); CI-mode issues carry a `tier` for
 *  the tiered summary.
 *  Returns the count of green items. */
function _checkCI(manifest, targetDir, issues, ciMode, exempted) {
  const repoName = path.basename(targetDir);
  const ciDest = path.join(targetDir, '.github', 'workflows');
  let ok = 0;

  // #305: the hardcoded skip list (was: ['eldato-outreach']) is replaced by
  // the manifest-driven exemptions (manifest.check.exemptions).
  if (exempted('templates/.github/workflows/')) {
    console.log(`\n🔧 CI Workflows:\n   ⏭️  ${repoName} — CI-workflow surface exempted via manifest check.exemptions`);
    return 0;
  }

  console.log('\n🔧 CI Workflows:');

  // D3 — no symlinks (any symlink = broken workflow entry on GitHub Actions).
  const symlinks = ciRefCheck.findWorkflowSymlinks(targetDir);
  if (symlinks.length > 0) {
    for (const f of symlinks) {
      issues.push({ type: 'ci', entry: path.relative(targetDir, f), tier: 'fail', reason: 'symlink under .github/workflows/ — invalid on GitHub Actions (#555), replace with a real file' });
      console.log(`   ❌ ${path.relative(targetDir, f)} — symlink (invalid, #555)`);
    }
  } else {
    ok++;
    console.log(`   ✅ .github/workflows/ — no symlinks (real-file contract)`);
  }

  // D2/D6 — pin compare (skip for agent-infra itself: @main self-caller is
  // the locked design; consumers must pin @vX.Y.Z).
  const ci = manifest.ci;
  const selfRepo = targetDir === AGENT_INFRA_PATH;
  if (!selfRepo && !fs.existsSync(ciDest)) {
    issues.push({ type: 'ci-ref', entry: 'ci.yml', tier: 'fail', reason: 'no .github/workflows/ — run agent-infra init' });
    console.log(`   ❌ ci.yml — missing (no .github/workflows/)`);
  } else if (selfRepo) {
    console.log(`   ℹ️  ${repoName} — source repo (@main self-caller, pin compare skipped)`);
  } else if (!ci || !ci.ref) {
    console.log(`   ⚠️  manifest.json has no ci.ref (old manifest) — pin compare skipped`);
  } else {
    const drift = ciRefCheck.checkCiRefs(targetDir, ci.ref);
    if (drift.length === 0) {
      ok++;
      console.log(`   ✅ ci-ref — all agent-infra pins @${ci.ref}`);
    } else {
      for (const d of drift) {
        issues.push({ type: 'ci-ref', entry: d.file, tier: 'fail', reason: `pinned @${d.ref}, expected @${d.expected} — run agent-infra update to learn the bump, then edit the uses: ref (no auto-rewrite)` });
        console.log(`   ❌ ${d.file} — pinned @${d.ref}, expected @${d.expected}`);
      }
    }
  }

  return ok;
}

// ─── CLI entry ──────────────────────────────────────────────────────────────

function usage() {
  console.log(`Usage: agent-infra <command> [args]

Commands:
  init <repo>    Bootstrap a repo with symlinks + templates
  update          Refresh symlinks, preserve local files
  check [repo]    Verify symlinks + version + CI pin (ci-ref) match manifest.json
                 --ci  CI mode: structural drift fails (exit 1), content
                       drift warns (exit 0), machine-local surfaces skipped

Env:
  AGENT_INFRA_PATH   Path to the agent-infra repo (default: parent of this script)
  AGENT_INFRA_CI=1   Equivalent to --ci (both select CI mode)`);
  process.exit(1);
}

const args = process.argv.slice(2);
const cmd = args[0];

if (!cmd || cmd === '--help' || cmd === '-h') usage();

switch (cmd) {
  case 'init':
    if (!args[1]) {
      console.error('❌ init requires a target directory: agent-infra init <repo>');
      process.exit(1);
    }
    cmdInit(args[1]);
    break;

  case 'update':
    cmdUpdate();
    break;

  case 'check':
    cmdCheck(
      args.slice(1).find((a) => !a.startsWith('--')) || null,
      args.includes('--ci') || process.env.AGENT_INFRA_CI === '1'
    );
    break;

  default:
    console.error(`❌ Unknown command: ${cmd}`);
    usage();
}
