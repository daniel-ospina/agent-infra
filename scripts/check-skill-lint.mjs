#!/usr/bin/env node
/**
 * check-skill-lint.mjs — agent-infra
 *
 * Skill Lint — frontmatter validation for every SKILL.md.
 *
 * Catches:
 *   - unquoted `: ` in description  → "Nested mappings not allowed"
 *   - missing/empty frontmatter     → body parsed as YAML → alias errors
 *   - duplicate top-level keys      → "Map keys must be unique"
 *   - name != directory name mismatch
 *
 * Usage:
 *   node scripts/check-skill-lint.mjs --repo /path/to/repo
 *   node scripts/check-skill-lint.mjs --skills-dir /path/to/skills
 *   REPO_PATH=/path/to/repo node scripts/check-skill-lint.mjs
 *
 * Exit: 0 = clean, 1 = P0 violations, 2 = script error
 */

import { readFileSync, readdirSync, existsSync } from 'fs';
import { join, basename, dirname } from 'path';

// Dynamic import: js-yaml is optional. If not installed, frontmatter
// validation is limited to structural checks (no YAML parsing).
let load;
try {
  const jsYaml = await import('js-yaml');
  load = jsYaml.load;
} catch {
  load = null;
}

// ── CLI ────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const args = {
    repo: process.env.REPO_PATH || null,
    skillsDir: null,
    help: false,
  };

  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--repo': {
        const v = argv[++i];
        if (!v || v.startsWith('--')) { console.error('Error: --repo requires a path'); process.exit(2); }
        args.repo = v;
        break;
      }
      case '--skills-dir': {
        const v = argv[++i];
        if (!v || v.startsWith('--')) { console.error('Error: --skills-dir requires a path'); process.exit(2); }
        args.skillsDir = v;
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
  console.log(`check-skill-lint.mjs — validate SKILL.md frontmatter

Usage:
  node check-skill-lint.mjs [--repo <path>] [--skills-dir <dir>]

Options:
  --repo <path>        Repo root. Skills dir defaults to <repo>/operations/skills
  --skills-dir <dir>   Direct path to skills directory (overrides --repo derivation)
  --help, -h           Print this help

Environment:
  REPO_PATH            Fallback repo path if --repo not set

Skills directory resolution order:
  1. --skills-dir <dir>
  2. <--repo>/operations/skills
  3. $REPO_PATH/operations/skills
  4. ./operations/skills (cwd)
  5. .agents/skills (cwd fallback for pi setups)

Exit codes:
  0  clean
  1  P0 violations found
  2  script error`);
}

// ── Resolve skills directory ────────────────────────────────────────────────
function resolveSkillsDir(args) {
  if (args.skillsDir) return args.skillsDir;

  const cwd = process.cwd();

  // If repo is set, try repo/operations/skills
  if (args.repo) {
    const candidate = join(args.repo, 'operations', 'skills');
    if (existsSync(candidate)) return candidate;
    // Fallback: .agents/skills (pi-style)
    const altCandidate = join(args.repo, '.agents', 'skills');
    if (existsSync(altCandidate)) return altCandidate;
  }

  // Try cwd/operations/skills
  const cwdCandidate = join(cwd, 'operations', 'skills');
  if (existsSync(cwdCandidate)) return cwdCandidate;

  // Try cwd/.agents/skills
  const cwdAltCandidate = join(cwd, '.agents', 'skills');
  if (existsSync(cwdAltCandidate)) return cwdAltCandidate;

  return null;
}

// ── Skill file discovery ────────────────────────────────────────────────────
function findSkillFiles(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith('_') || e.name.startsWith('.')) continue;
    const full = join(dir, e.name);
    if (e.isDirectory()) out.push(...findSkillFiles(full));
    else if (e.name === 'SKILL.md') out.push(full);
  }
  return out;
}

// ── Frontmatter parser ─────────────────────────────────────────────────────
function parseFrontmatter(content) {
  if (!content.startsWith('---')) return { ok: false, reason: 'missing opening ---' };
  const end = content.indexOf('---', 3);
  if (end === -1) return { ok: false, reason: 'missing closing ---' };
  const yaml = content.slice(3, end).trim();
  if (!yaml) return { ok: false, reason: 'empty frontmatter' };

  // js-yaml not available — do structural check only
  if (!load) {
    // Basic structural validation: check for required fields in raw YAML
    const hasName = /^name\s*:/m.test(yaml);
    const hasDesc = /^description\s*:/m.test(yaml);
    const issues = [];
    if (!hasName) issues.push('missing required field name');
    if (!hasDesc) issues.push('missing required field description');
    if (issues.length > 0) return { ok: false, reason: issues.join('; ') };
    // Return minimal data for downstream checks
    const nameMatch = yaml.match(/^name\s*:\s*(.+)$/m);
    const descMatch = yaml.match(/^description\s*:\s*(.+)$/m);
    return { ok: true, data: { name: nameMatch ? nameMatch[1].trim() : '', description: descMatch ? descMatch[1].trim() : ' ' }, yaml };
  }

  try {
    return { ok: true, data: load(yaml) || {}, yaml };
  } catch (e) {
    return { ok: false, reason: e.message };
  }
}

function findDuplicateKeys(yaml) {
  const seen = new Set();
  const dups = [];
  for (const line of yaml.split('\n')) {
    const m = line.match(/^\s*([A-Za-z0-9_-]+)\s*:/);
    if (!m) continue;
    const key = m[1];
    if (seen.has(key)) dups.push(key);
    else seen.add(key);
  }
  return [...new Set(dups)];
}

// ── Main ────────────────────────────────────────────────────────────────────
function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) { printHelp(); process.exit(0); }

  const SKILLS_DIR = resolveSkillsDir(args);

  if (!SKILLS_DIR || !existsSync(SKILLS_DIR)) {
    console.log(`ℹ  No skills directory found — nothing to lint.`);
    console.log('   Tried: --skills-dir, --repo/operations/skills, ./operations/skills, ./.agents/skills');
    process.exit(0);
  }

  const REQUIRED = ['name', 'description'];

  const files = findSkillFiles(SKILLS_DIR);
  const issues = [];

  for (const file of files) {
    const rel = file.replace(process.cwd() + '/', '');
    let content;
    try {
      content = readFileSync(file, 'utf-8');
    } catch (e) {
      issues.push(`[P0] file-read: ${e.message}\n  ${rel}`);
      continue;
    }
    const dirName = basename(dirname(file));
    const fm = parseFrontmatter(content);

    if (!fm.ok) {
      issues.push(`[P0] frontmatter: ${fm.reason}\n  ${rel}`);
      continue;
    }
    for (const field of REQUIRED) {
      if (!(field in fm.data)) issues.push(`[P0] frontmatter: missing required field '${field}'\n  ${rel}`);
    }
    if (fm.data.name && fm.data.name !== dirName) {
      issues.push(`[P0] name: frontmatter name '${fm.data.name}' != directory '${dirName}'\n  ${rel}`);
    }
    if ('description' in fm.data && String(fm.data.description).trim() === '') {
      issues.push(`[P0] description: empty\n  ${rel}`);
    }
    for (const key of findDuplicateKeys(fm.yaml)) {
      issues.push(`[P0] duplicate-key: '${key}' appears more than once\n  ${rel}`);
    }

    // Catch agents asking forbidden question — AGENTS.md §Batch Implementation
    if (/sequential\s+or\s+parallel/i.test(content)) {
      issues.push(`[P0] forbidden-prompt: "sequential or parallel" — agents must plan parallelism themselves\n  ${rel}`);
    }
  }

  console.log(`${files.length} SKILL.md files checked. ${issues.length} issue(s).`);
  if (issues.length === 0) {
    console.log('Clean.');
    process.exit(0);
  }
  for (const i of issues) console.log(`\n${i}`);
  process.exit(1);
}

main();
