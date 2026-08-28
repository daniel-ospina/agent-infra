#!/usr/bin/env node
/**
 * check-skill-lint.mjs — agent-infra
 *
 * Skill Lint — frontmatter validation for every SKILL.md.
 *
 * Catches (via scripts/frontmatter-validate.mjs, the dep-free validator that
 * mirrors pi's loader grammar — issue #254):
 *   - unquoted `: ` in description  → "Nested mappings not allowed"
 *   - missing/empty frontmatter     → body parsed as YAML → alias errors
 *   - duplicate keys in one mapping → "Map keys must be unique"
 *   - every enumerated pi-loader throw class (quotes/flow/tabs/aliases/
 *     multi-doc/reserved-starts/block-seq hazards)
 *   - silent truncation at unquoted ` #` (P1 — pi loads the truncated value)
 *   - string-type gate on name/description (pi DROPS non-string descriptions)
 *   - Bounded/Workflow/Routing missing allowed-tools → writing-skills schema
 *   - name != directory name mismatch (shared-<dir> routing wrappers allowed)
 *
 * Usage:
 *   node scripts/check-skill-lint.mjs --repo /path/to/repo
 *   node scripts/check-skill-lint.mjs --skills-dir /path/to/skills
 *   REPO_PATH=/path/to/repo node scripts/check-skill-lint.mjs
 *
 * Exit: 0 = clean, 1 = findings (P0 or P1 — any finding fails, D3),
 *       2 = script error. An EXPLICIT --skills-dir pointing at a missing
 *       directory → exit 2 (fail-closed, D9); an implicitly resolved missing
 *       skills dir → exit 0 (the reusable workflow runs on consumer repos
 *       that may have no skills tree — flipping would break every consumer).
 */

import { readFileSync, readdirSync, existsSync } from 'fs';
import { join, basename, dirname } from 'path';
import { pathToFileURL } from 'url';
import { validateFrontmatter } from './frontmatter-validate.mjs';

// ── CLI ────────────────────────────────────────────────────────────────────
export function parseArgs(argv) {
  const args = {
    repo: null,
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

export function printHelp() {
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
  6. <--repo>/skills        (agent-infra canonical tree)
  7. ./skills (cwd fallback — agent-infra canonical tree)

Exit codes:
  0  clean
  1  findings found (P0 = pi would drop the skill; P1 = pi loads but the
     value is silently corrupted)
  2  script error (incl. explicit --skills-dir pointing at a missing dir — the
     fail-closed flip, D9; an IMPLICIT no-skills-dir stays exit 0 so consumer
     repos without a skills tree keep passing)`);
}

// ── Resolve skills directory ────────────────────────────────────────────────
export function resolveSkillsDir(args, cwd = process.cwd()) {
  if (args.skillsDir) return args.skillsDir;

  // If repo is set, try repo/operations/skills
  if (args.repo) {
    for (const candidate of [
      join(args.repo, 'operations', 'skills'),
      join(args.repo, '.agents', 'skills'),
      join(args.repo, 'skills'), // agent-infra canonical tree
    ]) {
      if (existsSync(candidate)) return candidate;
    }
  }

  // Try cwd-relative candidates in the same order
  for (const candidate of [
    join(cwd, 'operations', 'skills'),
    join(cwd, '.agents', 'skills'),
    join(cwd, 'skills'), // agent-infra canonical tree
  ]) {
    if (existsSync(candidate)) return candidate;
  }

  return null;
}

// ── Skill file discovery ────────────────────────────────────────────────────
export function findSkillFiles(dir) {
  const out = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith('_') || e.name.startsWith('.')) continue;
    const full = join(dir, e.name);
    if (e.isDirectory()) out.push(...findSkillFiles(full));
    else if (e.name === 'SKILL.md') out.push(full);
  }
  return out;
}

// ── lint one file → issue lines ─────────────────────────────────────────────
function lintFile(file, rel) {
  const issues = [];
  const dirName = basename(dirname(file));

  let content;
  try {
    content = readFileSync(file, 'utf-8');
  } catch (e) {
    issues.push(`[P0] file-read: ${e.message}\n  ${rel}`);
    return issues;
  }

  const fm = validateFrontmatter(content);

  if (!fm.ok) {
    for (const f of fm.findings) issues.push(`[P0] frontmatter: ${f.class} — ${f.message}\n  ${rel}`);
    return issues;
  }
  for (const f of fm.findings) {
    issues.push(`[${f.severity}] frontmatter: ${f.class} — ${f.message}\n  ${rel}`);
  }

  // name != dir (shared-<dir> routing-wrapper exemption; non-string names are
  // already flagged by gate-name-* — pi falls back to the dir name)
  if (typeof fm.data.name === 'string' && fm.data.name && fm.data.name !== dirName && fm.data.name !== `shared-${dirName}`) {
    issues.push(`[P0] name: frontmatter name '${fm.data.name}' != directory '${dirName}'\n  ${rel}`);
  }

  // writing-skills frontmatter schema: allowed-tools is required for
  // Bounded/Workflow skills (Routing is the shared-router variant used by
  // planning/shared). reference and typeless skills are exempt.
  if (fm.data.type && ['Bounded', 'Workflow', 'Routing'].includes(fm.data.type) && !('allowed-tools' in fm.data)) {
    issues.push(`[P0] allowed-tools: type '${fm.data.type}' requires allowed-tools (writing-skills frontmatter schema)\n  ${rel}`);
  }

  // Catch agents asking forbidden question — AGENTS.md §Batch Implementation
  if (/sequential\s+or\s+parallel/i.test(content)) {
    issues.push(`[P0] forbidden-prompt: "sequential or parallel" — agents must plan parallelism themselves\n  ${rel}`);
  }

  return issues;
}

// ── run() seam (deps injection, load-gate.test.mjs pattern) ────────────────
export function run(argv, deps = {}) {
  const cwd = deps.cwd || process.cwd();
  const args = parseArgs(argv);

  if (args.help) { printHelp(); return 0; }

  const SKILLS_DIR = resolveSkillsDir(args, cwd);

  if (args.skillsDir && SKILLS_DIR && !existsSync(SKILLS_DIR)) {
    // D9 — explicit --skills-dir pointing at a missing dir is a script error
    console.error(`Error: skills directory not found: ${SKILLS_DIR}`);
    return 2;
  }

  if (!SKILLS_DIR || !existsSync(SKILLS_DIR)) {
    // implicit resolution found nothing — consumer repos may have no skills
    // tree; exit 0 (D9 dir-level decision)
    console.log(`ℹ  No skills directory found — nothing to lint.`);
    console.log('   Tried: --skills-dir, --repo/operations/skills, --repo/.agents/skills, --repo/skills, ./operations/skills, ./.agents/skills, ./skills');
    return 0;
  }

  const files = findSkillFiles(SKILLS_DIR);
  const issues = [];
  for (const file of files) {
    const rel = file.startsWith(cwd) ? file.slice(cwd.length + 1) : file;
    issues.push(...lintFile(file, rel));
  }

  console.log(`${files.length} SKILL.md files checked. ${issues.length} issue(s).`);
  if (issues.length === 0) {
    console.log('Clean.');
    return 0;
  }
  for (const i of issues) console.log(`\n${i}`);
  return 1;
}

const isMain =
  process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url;
if (isMain) {
  process.exit(run(process.argv.slice(2)));
}
