#!/usr/bin/env node
/**
 * check-migration-order.cjs — agent-infra
 *
 * Validates that migration filenames (SQL files in a migrations directory)
 * have strictly increasing timestamp prefixes. Duplicate or out-of-order
 * timestamps cause different final DB state on fresh deploys vs production.
 *
 * Supports Supabase migrations by default (timestamped .sql files in
 * supabase/migrations/), but works with any timestamp-prefixed migration dir.
 *
 * Usage:
 *   node scripts/check-migration-order.cjs --repo /path/to/repo
 *   node scripts/check-migration-order.cjs --repo /path/to/repo --migrations-dir db/migrations
 *   REPO_PATH=/path/to/repo node scripts/check-migration-order.cjs
 *
 * Exit codes:
 *   0 — all timestamps are strictly increasing (or only known exceptions, or no migrations dir)
 *   1 — new duplicate or out-of-order timestamps found
 *   2 — script error (invalid args)
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// ── CLI ────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const args = {
    repo: process.env.REPO_PATH || process.cwd(),
    migrationsDir: 'supabase/migrations',
    help: false,
    baseBranch: 'origin/main',
  };

  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--repo': {
        const v = argv[++i];
        if (!v || v.startsWith('--')) { console.error('Error: --repo requires a path'); process.exit(2); }
        args.repo = path.resolve(v);
        break;
      }
      case '--migrations-dir': {
        const v = argv[++i];
        if (!v || v.startsWith('--')) { console.error('Error: --migrations-dir requires a path'); process.exit(2); }
        args.migrationsDir = v;
        break;
      }
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
        // Positional: treat as --repo for backwards compat
        if (!args._repoFromPos && !argv[i].startsWith('-')) {
          args.repo = path.resolve(argv[i]);
          args._repoFromPos = true;
        } else {
          console.error(`Error: unknown argument "${argv[i]}". Use --help for usage.`);
          process.exit(2);
        }
    }
  }
  return args;
}

function printHelp() {
  console.log(`check-migration-order.cjs — validate migration timestamp ordering

Usage:
  node check-migration-order.cjs [--repo <path>] [--migrations-dir <dir>]

Options:
  --repo <path>           Repo root (default: $REPO_PATH or cwd)
  --migrations-dir <dir>  Migrations directory relative to repo (default: supabase/migrations)
  --base-branch <branch>  Base branch for git diff (default: origin/main)
  --help, -h              Print this help

Environment:
  REPO_PATH               Fallback repo path if --repo not set

Exit codes:
  0  all timestamps strictly increasing, or no migrations dir present
  1  duplicate or out-of-order timestamps found
  2  script error`);
}

// ── Main ────────────────────────────────────────────────────────────────────
function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) { printHelp(); process.exit(0); }

  const REPO_ROOT = args.repo;
  const MIGRATIONS_DIR = path.join(REPO_ROOT, args.migrationsDir);

  // Graceful degradation: no migrations dir → succeed silently
  if (!fs.existsSync(MIGRATIONS_DIR)) {
    // Check if it's a directory symlink
    try { fs.statSync(MIGRATIONS_DIR); } catch { /* not accessible */ }
    if (!fs.existsSync(MIGRATIONS_DIR)) {
      console.log(`ℹ  No migrations directory at ${path.relative(process.cwd(), MIGRATIONS_DIR)} — nothing to check.`);
      process.exit(0);
    }
  }

  // Known duplicate-timestamp pairs that are safe (touch different tables, no data conflict).
  // These are repo-specific — pass an empty set by default unless the repo provides exceptions.
  // For backwards compat, the KNOWN_EXCEPTIONS set can be configured per-repo.
  const KNOWN_EXCEPTIONS = new Set([
    // Agent-infra does not ship with known exceptions — product repos should
    // override this via a .migration-exceptions file or env var.
  ]);

  // Try to load repo-specific exceptions from .migration-exceptions (one filename per line)
  const exceptionsFile = path.join(REPO_ROOT, '.migration-exceptions');
  if (fs.existsSync(exceptionsFile)) {
    const lines = fs.readFileSync(exceptionsFile, 'utf8').split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed && !trimmed.startsWith('#')) KNOWN_EXCEPTIONS.add(trimmed);
    }
  }

  // Files introduced in this branch (vs baseBranch). null = git unavailable → fall back to KNOWN_EXCEPTIONS.
  function getNewMigrationFiles() {
    try {
      const migrationsRelPath = path.relative(REPO_ROOT, MIGRATIONS_DIR);
      const out = execSync(`git diff --name-only ${args.baseBranch} HEAD -- ${migrationsRelPath}/`, {
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'pipe'],
        cwd: REPO_ROOT,
      });
      return new Set(
        out.trim().split('\n').filter(f => f.endsWith('.sql')).map(f => path.basename(f))
      );
    } catch {
      return null;
    }
  }

  const newFiles = getNewMigrationFiles();

  let files;
  try {
    files = fs.readdirSync(MIGRATIONS_DIR)
      .filter(f => f.endsWith('.sql'))
      .sort(); // lexicographic = Supabase execution order
  } catch (err) {
    console.error(`Error: cannot read migrations directory "${MIGRATIONS_DIR}": ${err.message}`);
    process.exit(2);
  }

  if (files.length === 0) {
    console.log(`ℹ  No SQL migration files in ${path.relative(process.cwd(), MIGRATIONS_DIR)} — nothing to check.`);
    process.exit(0);
  }

  // Extract the numeric timestamp prefix (first 14 digits: YYYYMMDDHHmmss)
  function getTimestamp(filename) {
    const match = filename.match(/^(\d{14})/);
    return match ? match[1] : null;
  }

  let prevTimestamp = null;
  let prevFile = null;
  let errors = 0;
  let warnings = 0;

  // Lint: CREATE INDEX CONCURRENTLY is rejected by `supabase db push` (pgx pipeline
  // mode, SQLSTATE 25001). Block any PR that introduces it. Existing files on base
  // branch are tolerated.
  for (const file of files) {
    if (newFiles && !newFiles.has(file)) continue;
    const content = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
    if (/CREATE\s+(UNIQUE\s+)?INDEX\s+CONCURRENTLY/i.test(content)) {
      console.error(`✗  ${file}: CREATE INDEX CONCURRENTLY is incompatible with \`supabase db push\` (pgx pipeline mode rejects it, SQLSTATE 25001).`);
      console.error(`     Use plain CREATE INDEX. For a large table, apply the index outside the migration with a manual psql session, then add an empty bookkeeping migration.`);
      errors++;
    }
  }

  for (const file of files) {
    const ts = getTimestamp(file);
    if (!ts) {
      console.error(`✗  Cannot parse timestamp from: ${file}`);
      errors++;
      continue;
    }

    if (prevTimestamp && ts <= prevTimestamp) {
      const label = ts === prevTimestamp ? 'Duplicate' : 'Out-of-order';

      // Pre-existing if: git is available and neither file is new to this branch,
      // OR git is unavailable but both files are in KNOWN_EXCEPTIONS.
      const isPreExisting = newFiles
        ? !newFiles.has(file) && !newFiles.has(prevFile)
        : KNOWN_EXCEPTIONS.has(file) && KNOWN_EXCEPTIONS.has(prevFile);

      if (isPreExisting) {
        console.warn(`⚠  ${label} timestamp ${ts} (pre-existing on ${args.baseBranch}, not introduced by this branch):`);
        console.warn(`     ${prevFile}`);
        console.warn(`     ${file}`);
        warnings++;
      } else {
        console.error(`✗  ${label} timestamp ${ts}:`);
        console.error(`     ${prevFile}`);
        console.error(`     ${file}`);
        errors++;
      }
    }

    prevTimestamp = ts;
    prevFile = file;
  }

  if (errors > 0) {
    console.error(`\n${errors} migration ordering issue(s) found.`);
    console.error('Fix: rename the newer migration to a timestamp after the latest existing one.');
    process.exit(1);
  } else if (warnings > 0) {
    console.log(`✓  ${files.length} migrations — ${warnings} known exception(s), no new issues.`);
    process.exit(0);
  } else {
    console.log(`✓  ${files.length} migrations — all timestamps strictly increasing.`);
    process.exit(0);
  }
}

if (require.main === module) {
  main();
} else {
  module.exports = { parseArgs, printHelp, main };
}
