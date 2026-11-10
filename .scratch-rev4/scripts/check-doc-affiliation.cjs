#!/usr/bin/env node
// check-doc-affiliation.cjs — agent-infra
// Validates front matter in docs/*.md files.
// Modes: --files <list> | --changed | --all
// Options: --repo <path> [--subjects-dir <dir>] [--docs-dir <dir>]
//
// Note (#102): team slugs were previously validated against an eldato-era
// `operations/subjects/` tree in the same repo. The canonical source is now
// swarm's Supabase SOR (teams table) — pass --subjects-dir pointing at a swarm
// checkout (or its derived YAML mirrors in swarm/operations/subjects), or omit
// it to run leniently. See scripts/swarm-org.mjs for SOR queries.
//
// Default required fields: title, type, domain, doc_status, subjects.team, created
// Valid values for type/domain/doc_status are configurable via .doc-conventions.json
// in the repo root, or via sensible defaults.
//
// Exit: 0=clean 1=errors 2=script error
'use strict';
const fs = require('fs'), path = require('path'), {execFileSync} = require('child_process');

// ── CLI ────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const args = {
    repo: process.env.REPO_PATH || process.cwd(),
    mode: null,   // '--files', '--changed', or '--all'
    fileList: [],
    subjectsDir: null,
    docsDir: null,
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
      case '--subjects-dir': {
        const v = argv[++i];
        if (!v || v.startsWith('--')) { console.error('Error: --subjects-dir requires a path'); process.exit(2); }
        args.subjectsDir = v;
        break;
      }
      case '--docs-dir': {
        const v = argv[++i];
        if (!v || v.startsWith('--')) { console.error('Error: --docs-dir requires a path'); process.exit(2); }
        args.docsDir = v;
        break;
      }
      case '--files':
        args.mode = '--files';
        // Consume remaining args as file list
        while (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
          args.fileList.push(argv[++i]);
        }
        break;
      case '--changed':
        args.mode = '--changed';
        break;
      case '--all':
        args.mode = '--all';
        break;
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
  console.log(`check-doc-affiliation.cjs — validate docs/*.md front matter

Usage:
  node check-doc-affiliation.cjs --repo <path> [--mode] [flags]

Modes (required, one of):
  --files <list>    Check specific files
  --changed         Check git staged changes
  --all             Check all docs/*.md files

Options:
  --repo <path>        Repo root (default: $REPO_PATH or cwd)
  --subjects-dir <dir> Subjects dir for team slug validation (default: <repo>/operations/subjects)
                      NOTE: eldato-era tree — pass a swarm checkout path (swarm/operations/subjects)
                      or run without it (lenient). Canonical: swarm Supabase SOR (see scripts/swarm-org.mjs).
  --docs-dir <dir>     Docs directory (default: <repo>/docs)
  --help, -h           Print this help

Environment:
  REPO_PATH            Fallback repo path if --repo not set

Configuration:
  Place .doc-conventions.json in repo root to override valid types, domains, and statuses.
  Without it, defaults are used: type=[decisions,engineering,...], domain=[product,growth,...],
  doc_status=[draft,live,superseded,deprecated,broken,archived].

  If no subjects/ directory exists, team slug validation is skipped.

Exit codes:
  0  clean
  1  errors found  
  2  script error`);
}

// ── Config loading ──────────────────────────────────────────────────────────
const DEFAULT_VALID_TYPES = new Set([
  'decisions','engineering','operations','growth','capability','product',
  'ux','data','legal','finance-accounting','archive','synthesis','index',
  'log','patterns','gotchas'
]);
const DEFAULT_VALID_DOMAINS = new Set([
  'product','growth','operations','capability','platform','data','ux',
  'legal','finance-accounting','strategy'
]);
const DEFAULT_VALID_STATUSES = new Set([
  'draft','live','superseded','deprecated','broken','archived'
]);

function loadConventions(repoRoot) {
  const configPath = path.join(repoRoot, '.doc-conventions.json');
  if (!fs.existsSync(configPath)) {
    return {
      validTypes: DEFAULT_VALID_TYPES,
      validDomains: DEFAULT_VALID_DOMAINS,
      validStatuses: DEFAULT_VALID_STATUSES,
    };
  }
  try {
    const cfg = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    return {
      validTypes: cfg.types ? new Set(cfg.types) : DEFAULT_VALID_TYPES,
      validDomains: cfg.domains ? new Set(cfg.domains) : DEFAULT_VALID_DOMAINS,
      validStatuses: cfg.doc_statuses ? new Set(cfg.doc_statuses) : DEFAULT_VALID_STATUSES,
    };
  } catch (e) {
    console.warn(`Warning: cannot parse .doc-conventions.json — using defaults. Error: ${e.message}`);
    return {
      validTypes: DEFAULT_VALID_TYPES,
      validDomains: DEFAULT_VALID_DOMAINS,
      validStatuses: DEFAULT_VALID_STATUSES,
    };
  }
}

// ── Front matter parser ─────────────────────────────────────────────────────
function parseFM(c) {
  const m = c.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return null;
  const fm = {};
  for (const l of m[1].split('\n')) {
    const k = l.match(/^([a-zA-Z][\w.]*):\s*(.*)/);
    if (k) {
      let v = k[2].trim();
      v = v.replace(/\s+#.*$/, '').trim();
      fm[k[1]] = v;
    }
  }
  return fm;
}

// ── Team slug validation ────────────────────────────────────────────────────
function loadSlugs(subjectsDir) {
  if (!subjectsDir || !fs.existsSync(subjectsDir)) return new Set();
  let entries;
  try {
    entries = fs.readdirSync(subjectsDir);
  } catch { return new Set(); }
  const slugs = new Set();
  const files = entries.filter(f => f.endsWith('.yaml') || f.endsWith('.yml'));
  for (const f of files) {
    try {
      const c = fs.readFileSync(path.join(subjectsDir, f), 'utf8');
      const m = c.match(/slug:\s*(\S+)/);
      if (m) {
        let s = m[1].toLowerCase();
        s = s.replace(/\s+#.*$/, '').trim();
        slugs.add(s);
      }
    } catch { /* skip unreadable file */ }
  }
  return slugs;
}

// ── Validation ──────────────────────────────────────────────────────────────
function validate(fp, slugs, conventions) {
  const err = [], warn = [];
  let c;
  try { c = fs.readFileSync(fp, 'utf8'); } catch(e) { return {errors:['Cannot read: '+e.message],warnings:[]}; }
  const fm = parseFM(c);
  if (!fm) { err.push('Missing front matter block'); return {errors:err,warnings:warn}; }

  if (!(fm.title||'').trim()) err.push('Missing: title');

  const t = (fm.type||'').trim().toLowerCase();
  if (!t) err.push('Missing: type');
  else if (!conventions.validTypes.has(t)) err.push(`type "${t}" invalid (valid: ${[...conventions.validTypes].join(', ')})`);

  const d = (fm.domain||'').trim().toLowerCase();
  if (!d) err.push('Missing: domain');
  else if (!conventions.validDomains.has(d)) err.push(`domain "${d}" invalid (valid: ${[...conventions.validDomains].join(', ')})`);

  const ds = (fm.doc_status||'').trim().toLowerCase();
  if (!ds) err.push('Missing: doc_status');
  else if (!conventions.validStatuses.has(ds)) err.push(`doc_status "${ds}" invalid (valid: ${[...conventions.validStatuses].join(', ')})`);

  const team = (fm['ownedBy'] || fm['subjects.team'] || '').trim();
  if (!team) {
    err.push('Missing: subjects.team (or ownedBy) — populate from team affiliation or team slug.');
  } else if (slugs.size > 0 && !slugs.has(team.toLowerCase())) {
    err.push(`subjects.team "${team}" not a valid slug. Registered teams: ${[...slugs].join(', ')}.`);
  }

  const cr = (fm.created||'').trim();
  if (!cr) err.push('Missing: created (YYYY-MM-DD)');
  else if (!/^\d{4}-\d{2}-\d{2}$/.test(cr)) err.push(`created "${cr}" invalid — YYYY-MM-DD`);

  // Entity fields — warn, don't block
  const aboutS = (fm.aboutSubjects||'').trim();
  if (!aboutS) warn.push('Missing: aboutSubjects — declare what Subjects this doc relates to (comma-separated).');
  const aboutO = (fm.aboutObjects||'').trim();
  if (!aboutO) warn.push('Missing: aboutObjects — declare what Objects this doc relates to (comma-separated).');

  return {errors:err, warnings:warn};
}

// ── File discovery ──────────────────────────────────────────────────────────
function getFiles(mode, extra, docsDir, repoRoot) {
  if (mode === '--files') {
    return extra.map(f => path.resolve(process.cwd(), f)).filter(f => f.endsWith('.md'));
  }
  if (mode === '--changed') {
    try {
      const o = execFileSync('git', ['diff', '--cached', '--name-only', '--diff-filter=ACM'], {
        encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], cwd: repoRoot,
      }).trim();
      return o.split('\n').filter(f => f.startsWith('docs/') && f.endsWith('.md')).map(f => path.resolve(repoRoot, f));
    } catch { return []; }
  }
  if (mode === '--all') {
    if (!docsDir || !fs.existsSync(docsDir)) return [];
    const files = [];
    (function walk(dir) {
      let e;
      try { e = fs.readdirSync(dir, {withFileTypes:true}); } catch { return; }
      for (const x of e) {
        const full = path.join(dir, x.name);
        if (x.isDirectory()) walk(full);
        else if (x.name.endsWith('.md')) files.push(full);
      }
    })(docsDir);
    return files;
  }
  return [];
}

// ── Report ──────────────────────────────────────────────────────────────────
function report(fp, {errors, warnings}, repoRoot) {
  if (!errors.length && !warnings.length) return {errors:0, warnings:0};
  const d = fp.startsWith(repoRoot) ? fp.slice(repoRoot.length + 1) : fp;
  console.error('\n' + d + ':');
  for (const e of errors) console.error('  ERROR: ' + e);
  for (const w of warnings) console.error('  WARN: ' + w);
  return {errors: errors.length, warnings: warnings.length};
}

// ── Main ────────────────────────────────────────────────────────────────────
function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) { printHelp(); process.exit(0); }

  if (!args.mode) {
    console.error('Error: mode required — use --files, --changed, or --all. See --help.');
    process.exit(2);
  }
  if (args.mode === '--files' && args.fileList.length === 0) {
    console.error('Error: --files needs at least one path. See --help.');
    process.exit(2);
  }

  const REPO_ROOT = args.repo;
  const DOCS_DIR = args.docsDir || path.join(REPO_ROOT, 'docs');
  const SUBJECTS_DIR = args.subjectsDir || path.join(REPO_ROOT, 'operations', 'subjects');

  // Graceful degradation: no docs dir
  if (!fs.existsSync(DOCS_DIR)) {
    console.log(`ℹ  No docs directory at ${DOCS_DIR} — nothing to check.`);
    process.exit(0);
  }

  const conventions = loadConventions(REPO_ROOT);
  const slugs = loadSlugs(SUBJECTS_DIR);
  if (slugs.size === 0) {
    console.warn('Note: no subjects directory with team slugs — team validation will be lenient.');
  }

  const files = getFiles(args.mode, args.fileList, DOCS_DIR, REPO_ROOT);
  if (!files.length) {
    console.log('✓ No .md files to check.');
    process.exit(0);
  }

  let te = 0, tw = 0;
  for (const f of files) {
    const c = report(f, validate(f, slugs, conventions), REPO_ROOT);
    te += c.errors;
    tw += c.warnings;
  }
  const l = files.length === 1 ? 'file' : 'files';
  if (te) {
    console.error('\n' + files.length + ' ' + l + ' — ' + te + ' error(s), ' + tw + ' warning(s).');
    process.exit(1);
  }
  console.log(tw
    ? '\n' + files.length + ' ' + l + ' — clean (' + tw + ' warning(s)).'
    : '\n✓ ' + files.length + ' ' + l + ' — all clean.');
  process.exit(0);
}

main();
