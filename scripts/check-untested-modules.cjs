#!/usr/bin/env node
/**
 * check-untested-modules.cjs — agent-infra
 *
 * Detects new .ts/.tsx modules that have zero corresponding test files.
 * Runs in CI preflight — blocks merge for new modules with integration
 * surfaces that lack test infrastructure.
 *
 * Exit codes:
 *   0 — all new modules have tests (or are exempt, or no new modules)
 *   1 — new modules found without tests
 *   2 — script error
 *
 * Usage:
 *   node scripts/check-untested-modules.cjs --repo /path/to/repo
 *   node scripts/check-untested-modules.cjs --repo /path/to/repo --json
 *   node scripts/check-untested-modules.cjs --repo /path/to/repo --warn
 *   REPO_PATH=/path/to/repo node scripts/check-untested-modules.cjs
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

// ── CLI ────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const args = {
    repo: process.env.REPO_PATH || process.cwd(),
    json: false,
    warnOnly: false,
    baseBranch: 'origin/main',
    help: false,
  };

  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--repo': {
        const v = argv[++i];
        if (!v || v.startsWith('--')) { console.error('Error: --repo requires a path'); process.exit(2); }
        args.repo = path.resolve(v);
        break;
      }
      case '--json':
        args.json = true;
        break;
      case '--warn':
        args.warnOnly = true;
        break;
      case '--base-branch': {
        const v = argv[++i];
        if (!v || v.startsWith('--')) { console.error('Error: --base-branch requires a branch name'); process.exit(2); }
        args.baseBranch = v;
        break;
      }
      case '--help':
      case '-h':
        args.help = true;
        break;
      default:
        console.error(`Error: unknown argument "${argv[i]}". Use --help for usage.`);
        process.exit(2);
    }
  }
  return args;
}

function printHelp() {
  console.log(`check-untested-modules.cjs — detect new modules without tests

Usage:
  node check-untested-modules.cjs [--repo <path>] [flags]

Options:
  --repo <path>          Repo root (default: $REPO_PATH or cwd)
  --json                 Output results as JSON
  --warn                 Warn instead of blocking (exit 0 even with untested modules)
  --base-branch <branch> Base branch for git diff (default: origin/main)
  --help, -h             Print this help

Environment:
  REPO_PATH              Fallback repo path if --repo not set

Exit codes:
  0  no untested modules (or --warn)
  1  untested modules found
  2  script error`);
}

// ── Heuristics for exempt files ────────────────────────────────────────────
function isExempt(filePath) {
  let content;
  try {
    content = fs.readFileSync(filePath, 'utf8');
  } catch {
    return { exempt: true, reason: 'unreadable file' };
  }
  const lines = content.split('\n').filter(l =>
    l.trim() && !l.trim().startsWith('//') && !l.trim().startsWith('/*') && !l.trim().startsWith('*')
  );

  // Type-only files: only export/import type, interface, or declare
  const hasValueExport = lines.some(l => /\bexport\s+(default\s+)?(const|function|class|let|var)\b/.test(l));
  const hasTypeExport = lines.some(l => /\bexport\s+(type|interface)\b/.test(l));
  if (hasTypeExport && !hasValueExport) return { exempt: true, reason: 'type-only file' };

  // Config/constants files
  if (filePath.includes('/config/') || filePath.includes('/constants/') || filePath.includes('/i18n/')) {
    return { exempt: true, reason: 'config/constants/i18n' };
  }

  // Pure re-exports (aggregate barrels)
  const nonExportLines = lines.filter(l => !l.trim().startsWith('export'));
  const allExports = nonExportLines.length <= 2;
  if (allExports && hasValueExport) return { exempt: true, reason: 'pure re-export barrel' };

  // Files with zero logic
  const hasLogic = lines.some(l => /\b(function|class|const\s+\w+\s*=\s*(async\s*)?\(|if\s*\(|for\s*\(|while\s*\(|switch\s*\()/.test(l));
  if (!hasLogic && !hasValueExport) return { exempt: true, reason: 'no executable logic' };

  return { exempt: false };
}

// ── Find corresponding test file ───────────────────────────────────────────
function findTestFile(filePath) {
  const dir = path.dirname(filePath);
  const base = path.basename(filePath);
  const candidates = [
    path.join(dir, base.replace(/\.(ts|tsx)$/, '.test.$1')),
    path.join(dir, base.replace(/\.(ts|tsx)$/, '.spec.$1')),
    path.join(dir, '__tests__', base),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

// ── Get new files from git diff ────────────────────────────────────────────
function getNewFiles(repoRoot, baseBranch) {
  try {
    const output = execSync(
      `git diff --name-only --diff-filter=A ${baseBranch}...HEAD -- "*.ts" "*.tsx"`,
      { cwd: repoRoot, encoding: 'utf8' }
    ).trim();
    return output.split('\n').filter(Boolean);
  } catch {
    return [];
  }
}

// ── Main ────────────────────────────────────────────────────────────────────
function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) { printHelp(); process.exit(0); }

  const REPO_ROOT = args.repo;

  // Graceful degradation: not a git repo → nothing to diff
  if (!fs.existsSync(path.join(REPO_ROOT, '.git'))) {
    console.log('ℹ  Not a git repository — nothing to check.');
    process.exit(0);
  }

  const newFiles = getNewFiles(REPO_ROOT, args.baseBranch);
  if (newFiles.length === 0) {
    if (args.json) console.log(JSON.stringify({ new_files: 0, untested: [] }));
    else console.log('✅ No new modules — nothing to check.');
    process.exit(0);
  }

  const untested = [];
  const tested = [];
  const exempt = [];

  for (const file of newFiles) {
    const fullPath = path.join(REPO_ROOT, file);
    if (!fs.existsSync(fullPath)) continue;

    // Skip test files themselves
    if (file.includes('.test.') || file.includes('.spec.') || file.includes('__tests__')) continue;

    // Check exemption
    const exemptResult = isExempt(fullPath);
    if (exemptResult.exempt) {
      exempt.push({ file, reason: exemptResult.reason });
      continue;
    }

    // Check for test file
    const testFile = findTestFile(fullPath);
    if (testFile) {
      tested.push({ file, test_file: path.relative(REPO_ROOT, testFile) });
    } else {
      untested.push({ file });
    }
  }

  if (args.json) {
    console.log(JSON.stringify({
      new_files: newFiles.length,
      tested: tested.length,
      untested: untested.length,
      exempt: exempt.length,
      details: { tested, untested, exempt },
    }, null, 2));
  }

  if (untested.length > 0) {
    const label = args.warnOnly ? '⚠️ WARN' : '❌ BLOCK';
    console.error(`${label} — ${untested.length} new module(s) without tests:`);
    for (const u of untested) {
      console.error(`  ${u.file}`);
    }
    console.error(`\nCreate a test file or add an exemption reason.`);
    console.error(`Exemptions: type-only files, config/constants, pure re-exports, no-logic files.`);
    process.exit(args.warnOnly ? 0 : 1);
  }

  console.log(`✅ All ${tested.length} new module(s) have test files.`);
  if (exempt.length > 0) {
    console.log(`   ${exempt.length} file(s) exempt: ${exempt.map(e => e.file).join(', ')}`);
  }
  process.exit(0);
}

// ── Module guard ────────────────────────────────────────────────────────────
if (require.main === module) {
  main();
} else {
  module.exports = { parseArgs, printHelp, isExempt, findTestFile, getNewFiles, main };
}
