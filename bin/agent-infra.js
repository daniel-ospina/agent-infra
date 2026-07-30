#!/usr/bin/env node
'use strict';

// ─── agent-infra bootstrap CLI ──────────────────────────────────────────────
// Plain CJS — no npm dependencies. Uses only Node.js built-ins.
//
// Commands:
//   init <repo>   Bootstrap a repo with symlinks + templates
//   update         Refresh symlinks, preserve local files, report version
//   check [repo]   Verify symlinks match manifest.json

const fs = require('fs');
const path = require('path');
const os = require('os');

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

/** check [targetDir] — verify symlinks match manifest.json */
function cmdCheck(targetDir) {
  targetDir = targetDir ? path.resolve(targetDir) : process.cwd();

  const manifest = loadManifest();
  const version = manifest.version;

  console.log(`🔍 Checking agent-infra v${version}`);
  console.log(`   agent-infra at: ${AGENT_INFRA_PATH}`);
  console.log(`   target: ${targetDir}\n`);

  const issues = [];
  let ok = 0;

  // ── Check extensions ──
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

  // ── Check skills ──
  if (manifest.files['skills/']) {
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
    if (!fs.existsSync(SCRIPTS_SRC)) {
      issues.push({ type: 'scripts', reason: `source missing: ${SCRIPTS_SRC}` });
      console.log(`\n🔧 Scripts:\n   ❌ scripts/ — source missing`);
    } else {
      console.log(`\n🔧 Scripts:`);
      const linkTarget = readlinkSafe(scriptsDest);
      if (linkTarget === null) {
        // Only flag as issue if this is a target repo check (not agent-infra itself)
        if (targetDir !== AGENT_INFRA_PATH) {
          issues.push({ type: 'scripts', reason: `not symlinked: ${scriptsDest}` });
          console.log(`   ❌ scripts/ — not symlinked`);
        } else {
          console.log(`   ℹ️  scripts/ — source repo (no symlink needed)`);
        }
      } else {
        const resolved = path.resolve(path.dirname(scriptsDest), linkTarget);
        if (resolved !== SCRIPTS_SRC) {
          issues.push({ type: 'scripts', reason: `points to ${resolved}, expected ${SCRIPTS_SRC}` });
          console.log(`   ⚠️  scripts/ — stale (→ ${linkTarget})`);
        } else {
          ok++;
          console.log(`   ✅ scripts/`);
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
    if (!fs.existsSync(agentsDest)) {
      issues.push({ type: 'templates', entry: 'AGENTS.md', reason: 'missing' });
      console.log(`   ❌ AGENTS.md — missing`);
    } else if (!fs.existsSync(agentsSrc)) {
      issues.push({ type: 'templates', entry: 'AGENTS.md', reason: 'source missing: AGENTS.base.md' });
      console.log(`   ❌ AGENTS.md — source missing`);
    } else if (!filesEqual(agentsDest, agentsSrc)) {
      issues.push({ type: 'templates', entry: 'AGENTS.md', reason: 'differs from AGENTS.base.md' });
      console.log(`   ⚠️  AGENTS.md — differs from base`);
    } else {
      ok++;
      console.log(`   ✅ AGENTS.md`);
    }

    // .mcp.json
    const mcpDest = path.join(targetDir, '.mcp.json');
    const mcpSrc = path.join(TEMPLATES_SRC, '.mcp.base.json');
    if (!fs.existsSync(mcpDest)) {
      issues.push({ type: 'templates', entry: '.mcp.json', reason: 'missing' });
      console.log(`   ❌ .mcp.json — missing`);
    } else if (!fs.existsSync(mcpSrc)) {
      issues.push({ type: 'templates', entry: '.mcp.json', reason: 'source missing: .mcp.base.json' });
      console.log(`   ❌ .mcp.json — source missing`);
    } else if (!filesEqual(mcpDest, mcpSrc)) {
      issues.push({ type: 'templates', entry: '.mcp.json', reason: 'differs from .mcp.base.json' });
      console.log(`   ⚠️  .mcp.json — differs from base`);
    } else {
      ok++;
      console.log(`   ✅ .mcp.json`);
    }

    // .husky/
    const huskyDest = path.join(targetDir, '.husky');
    const huskySrc = path.join(TEMPLATES_SRC, '.husky');
    if (!fs.existsSync(huskyDest)) {
      issues.push({ type: 'templates', entry: '.husky/', reason: 'missing' });
      console.log(`   ❌ .husky/ — missing`);
    } else if (!fs.existsSync(huskySrc)) {
      issues.push({ type: 'templates', entry: '.husky/', reason: 'source missing' });
      console.log(`   ❌ .husky/ — source missing`);
    } else {
      let huskyOk = true;
      for (const entry of fs.readdirSync(huskySrc, { withFileTypes: true })) {
        const srcHook = path.join(huskySrc, entry.name);
        const destHook = path.join(huskyDest, entry.name);
        if (!fs.existsSync(destHook)) {
          issues.push({ type: 'templates', entry: `.husky/${entry.name}`, reason: 'missing' });
          console.log(`   ❌ .husky/${entry.name} — missing`);
          huskyOk = false;
        } else if (!fs.existsSync(srcHook)) {
          issues.push({ type: 'templates', entry: `.husky/${entry.name}`, reason: 'source missing' });
          console.log(`   ❌ .husky/${entry.name} — source missing`);
          huskyOk = false;
        } else if (entry.isFile() && !filesEqual(destHook, srcHook)) {
          issues.push({ type: 'templates', entry: `.husky/${entry.name}`, reason: 'differs from base' });
          console.log(`   ⚠️  .husky/${entry.name} — differs from base`);
          huskyOk = false;
        }
      }
      if (huskyOk) {
        ok++;
        console.log(`   ✅ .husky/`);
      }
    }
  }

  // ── Check .agent-infra-version ──
  const versionFile = path.join(targetDir, '.agent-infra-version');
  const fileVersion = (() => {
    try { return fs.readFileSync(versionFile, 'utf-8').trim(); } catch { return null; }
  })();
  console.log(`\n📌 .agent-infra-version:`);
  if (!fileVersion) {
    issues.push({ type: 'version', reason: 'missing .agent-infra-version' });
    console.log(`   ❌ missing`);
  } else if (fileVersion !== version) {
    issues.push({ type: 'version', reason: `${fileVersion} ≠ ${version}` });
    console.log(`   ⚠️  ${fileVersion} (manifest: ${version})`);
  } else {
    ok++;
    console.log(`   ✅ ${version}`);
  }

  // ── Summary ──
  console.log(`\n${'─'.repeat(50)}`);
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

// ─── CLI entry ──────────────────────────────────────────────────────────────

function usage() {
  console.log(`Usage: agent-infra <command> [args]

Commands:
  init <repo>    Bootstrap a repo with symlinks + templates
  update          Refresh symlinks, preserve local files
  check [repo]    Verify symlinks match manifest.json

Env:
  AGENT_INFRA_PATH   Path to the agent-infra repo (default: parent of this script)`);
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
    cmdCheck(args[1] || null);
    break;

  default:
    console.error(`❌ Unknown command: ${cmd}`);
    usage();
}
