#!/usr/bin/env node
/**
 * check-test-regression.cjs — agent-infra
 *
 * Detects test regressions on the current branch by:
 *   1. Selecting affected tests (vitest related + changed *.test.* files)
 *   2. Running them and comparing failures against test-baseline.json
 *   3. Classifying each failure: regression | pre-existing | flaky | skipped
 *
 * Modes:
 *   (default)        Run affected tests, diff vs baseline, classify
 *   --debt-status    Read baseline, output markdown debt ledger
 *   --affected-only  Print affected tests without running them
 *   --auto-file      Create GitHub issues for untracked pre-existing failures
 *   --help, -h       Print usage and exit
 *
 * Flags:
 *   --repo <path>          Repo root (default: $REPO_PATH or cwd)
 *   --debt-status          Output markdown table of pre-existing failures
 *   --affected-only        Print affected test files and exit (no run)
 *   --auto-file            Auto-file GitHub issues for untracked failures
 *   --dry-run              With --auto-file: print issue JSON instead of creating
 *   --timeout <ms>         Subprocess timeout in ms (default: 120000)
 *   --rerun-timeout <ms>   Per-test re-run timeout in ms (default: 30000)
 *   --baseline <path>      Use alternative baseline file (default: ./test-baseline.json relative to repo)
 *   --base-branch <branch> Base branch for git diff (default: origin/main)
 *   --help, -h             Print this help
 *
 * Exit codes:
 *   0 — no regressions found (or --debt-status / --help / --affected-only),
 *       or --auto-file with no untracked failures
 *   1 — regression detected (new failures not in baseline),
 *       or --auto-file created issues
 *   2 — script error (missing baseline, vitest not found, malformed JSON,
 *       gh CLI not authenticated, etc.)
 *
 * Usage:
 *   node scripts/check-test-regression.cjs --repo /path/to/repo
 *   node scripts/check-test-regression.cjs --repo /path/to/repo --debt-status
 *   node scripts/check-test-regression.cjs --repo /path/to/repo --affected-only
 *   REPO_PATH=/path/to/repo node scripts/check-test-regression.cjs --timeout 60000
 */
const fs = require('fs');
const path = require('path');
const { execFileSync, execSync } = require('child_process');

// ── CLI argument parsing ────────────────────────────────────────────────────
function parseArgs(argv) {
  const args = {
    repo: process.env.REPO_PATH || process.cwd(),
    debtStatus: false,
    affectedOnly: false,
    autoFile: false,
    dryRun: false,
    launchAgent: false,
    help: false,
    timeout: 120000,
    rerunTimeout: 30000,
    baseline: null, // resolved after repo is known
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
      case '--debt-status':
        args.debtStatus = true;
        break;
      case '--affected-only':
        args.affectedOnly = true;
        break;
      case '--help':
      case '-h':
        args.help = true;
        break;
      case '--timeout': {
        const v = parseInt(argv[i + 1], 10);
        if (isNaN(v) || String(v) !== argv[i + 1] || (argv[i + 1] && argv[i + 1].startsWith('--'))) {
          console.error(`Error: --timeout requires an integer value in milliseconds, got "${argv[i + 1]}"`);
          process.exit(2);
        }
        args.timeout = v;
        i++;
        break;
      }
      case '--rerun-timeout': {
        const v = parseInt(argv[i + 1], 10);
        if (isNaN(v) || String(v) !== argv[i + 1] || (argv[i + 1] && argv[i + 1].startsWith('--'))) {
          console.error(`Error: --rerun-timeout requires an integer value in milliseconds, got "${argv[i + 1]}"`);
          process.exit(2);
        }
        args.rerunTimeout = v;
        i++;
        break;
      }
      case '--baseline': {
        const p = argv[++i];
        if (!p || p.startsWith('--')) {
          console.error('Error: --baseline requires a file path argument');
          process.exit(2);
        }
        args.baseline = p; // resolved later relative to repo
        i++;
        break;
      }
      case '--base-branch': {
        const v = argv[++i];
        if (!v || v.startsWith('--')) { console.error('Error: --base-branch requires a branch name'); process.exit(2); }
        args.baseBranch = v;
        break;
      }
      case '--auto-file':
        args.autoFile = true;
        break;
      case '--dry-run':
        args.dryRun = true;
        break;
      case '--launch-agent':
        args.launchAgent = true;
        break;
      default:
        console.error(`Error: unknown flag "${argv[i]}". Use --help for usage.`);
        process.exit(2);
    }
  }
  return args;
}

function printHelp() {
  console.log(`check-test-regression.cjs — detect test regressions on the current branch

Usage:
  node check-test-regression.cjs [--repo <path>] [flags]

Modes:
  (default)          Run affected tests, diff vs baseline, classify
  --debt-status      Read baseline, output markdown debt ledger
  --affected-only    Print affected test files and exit (no run)
  --auto-file        Create GitHub issues for untracked pre-existing failures

Flags:
  --repo <path>          Repo root (default: $REPO_PATH or cwd)
  --auto-file            Auto-file GitHub issues for untracked failures
  --dry-run              With --auto-file: print issue JSON instead of creating
  --timeout <ms>         Subprocess timeout (default: 120000)
  --rerun-timeout <ms>   Per-test re-run timeout (default: 30000)
  --baseline <path>      Alternative baseline file (default: ./test-baseline.json)
  --base-branch <branch> Base branch for git diff (default: origin/main)
  --help, -h             Print this help

Environment:
  REPO_PATH              Fallback repo path if --repo not set

Exit codes:
  0  no regressions, or --auto-file with no untracked failures
  1  regression detected, or --auto-file created issues
  2  script error`);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function ensureRepoIsGit(repoRoot) {
  const gitDir = path.join(repoRoot, '.git');
  if (!fs.existsSync(gitDir)) {
    console.log(`ℹ  ${repoRoot} is not a git repository — nothing to diff.`);
    process.exit(0);
  }
}

function ensureVitestAvailable(repoRoot) {
  const pkgJson = path.join(repoRoot, 'package.json');
  if (!fs.existsSync(pkgJson)) {
    console.error(`Error: no package.json found in ${repoRoot}`);
    process.exit(2);
  }
  try {
    const pkg = JSON.parse(fs.readFileSync(pkgJson, 'utf8'));
    const hasVitest = (pkg.devDependencies && pkg.devDependencies.vitest) ||
                      (pkg.dependencies && pkg.dependencies.vitest);
    if (!hasVitest) {
      console.log('ℹ  vitest not found in package.json — nothing to test.');
      process.exit(0);
    }
  } catch {
    console.error(`Error: cannot parse package.json in ${repoRoot}`);
    process.exit(2);
  }
}

// ── Git diff ────────────────────────────────────────────────────────────────
function getChangedFiles(repoRoot, baseBranch) {
  let files;
  try {
    const out = execFileSync('git', ['diff', '--name-only', `${baseBranch}...HEAD`], {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
      cwd: repoRoot,
    });
    files = out.trim().split('\n').filter(Boolean);
  } catch (err) {
    console.error(`Error: cannot run "git diff --name-only ${baseBranch}".`);
    console.error('Details:', err.message);
    console.error(`Ensure ${baseBranch} is available (try: git fetch origin main --depth=1).`);
    process.exit(2);
  }
  return files;
}

// ── Affected-test selection ─────────────────────────────────────────────────
function selectAffectedTests(changedFiles, repoRoot) {
  const testPattern = /\.test\./;
  const excludePattern = /\.d\.ts$|^docs\//;

  const sourceFiles = changedFiles.filter(f => !testPattern.test(f) && !excludePattern.test(f));
  const testFiles = changedFiles.filter(f => testPattern.test(f));

  let relatedTests = [];
  if (sourceFiles.length > 0) {
    try {
      const out = execFileSync('npx', ['vitest', 'related', ...sourceFiles, '--run', '--reporter', 'json'], {
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'pipe'],
        cwd: repoRoot,
        timeout: 60000,
      });
      try {
        const result = JSON.parse(out);
        if (result.testResults) {
          relatedTests = result.testResults.filter(r => r && r.name).map(r => path.relative(repoRoot, r.name));
        }
      } catch {
        console.warn('Warning: vitest related produced non-JSON output. Related-test discovery may be incomplete.');
      }
    } catch (err) {
      if (err.stdout) {
        try {
          const result = JSON.parse(err.stdout);
          if (result.testResults) {
            relatedTests = result.testResults.filter(r => r && r.name).map(r => path.relative(repoRoot, r.name));
          }
        } catch {
          console.warn('Warning: vitest related failed and produced non-JSON output. Proceeding with only changed test files. Error:', err.message);
        }
      } else {
        console.warn('Warning: vitest related failed. Proceeding with only changed test files. Error:', err.message);
      }
    }
  }

  const allTests = [...new Set([...relatedTests, ...testFiles])].filter(f =>
    f.endsWith('.test.ts') || f.endsWith('.test.tsx') || f.endsWith('.test.cjs') ||
    f.endsWith('.test.js') || f.endsWith('.test.mjs') || f.endsWith('.spec.ts') ||
    f.endsWith('.spec.tsx') || f.endsWith('.spec.js')
  );

  return { sourceFiles, testFiles: allTests };
}

// ── Run vitest ──────────────────────────────────────────────────────────────
function runVitest(testFiles, repoRoot, timeout) {
  if (testFiles.length === 0) return { testResults: [] };

  let out;
  try {
    out = execFileSync('npx', ['vitest', 'run', ...testFiles, '--reporter', 'json'], {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
      cwd: repoRoot,
      timeout,
    });
    return JSON.parse(out);
  } catch (err) {
    if (err.killed || err.signal) {
      console.error('Error: vitest subprocess was killed (timeout or signal).');
      process.exit(2);
    }
    if (err.stdout) {
      try {
        return JSON.parse(err.stdout);
      } catch {
        console.error('Error: vitest produced non-JSON output:', err.stdout.substring(0, 200));
        process.exit(2);
      }
    }
    if (err.code === 'ENOENT') {
      console.error('Error: vitest not found. Run "npm install" first.');
      process.exit(2);
    }
    console.error('Error: vitest subprocess failed:', err.message);
    process.exit(2);
  }
}

// ── Parse vitest JSON → failure map ─────────────────────────────────────────
function parseVitestResults(jsonOutput, repoRoot) {
  if (!jsonOutput || !jsonOutput.testResults) return new Map();

  const failures = new Map();

  for (const fileResult of jsonOutput.testResults) {
    const relativePath = path.relative(repoRoot, fileResult.name);
    for (const assertion of fileResult.assertionResults || []) {
      if (assertion.status === 'failed') {
        const key = buildKey(relativePath, assertion.ancestorTitles || [], assertion.title);
        failures.set(key, {
          file: relativePath,
          test: assertion.title,
          describeChain: assertion.ancestorTitles || [],
          error: (assertion.failureMessages || [])[0] || 'unknown error',
          duration: assertion.duration || 0,
          timedOut: (assertion.failureMessages || []).some(m => m.toLowerCase().includes('timed out')),
        });
      }
    }
  }

  return failures;
}

// ── Build baseline key ──────────────────────────────────────────────────────
function buildKey(file, ancestors, title) {
  const chain = ancestors.length > 0 ? ancestors.join(' > ') + ' > ' : '';
  return `${file}::${chain}${title}`;
}

// ── Escape regex metacharacters for vitest -t ───────────────────────────────
function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// ── Read baseline ───────────────────────────────────────────────────────────
function readBaseline(baselinePath, createIfMissing) {
  if (!fs.existsSync(baselinePath)) {
    if (createIfMissing) {
      console.warn('Warning: test-baseline.json not found. All failures treated as regressions.');
      return { version: 1, failures: {} };
    }
    console.error(`Error: ${baselinePath} not found.`);
    console.error('Run vitest to create the baseline, or use --baseline <path>.');
    process.exit(2);
  }

  try {
    const raw = fs.readFileSync(baselinePath, 'utf8');
    const data = JSON.parse(raw);
    if (!data.failures || typeof data.failures !== 'object') {
      console.error(`Error: ${baselinePath} is missing "failures" object.`);
      process.exit(2);
    }
    return data;
  } catch (err) {
    console.error(`Error: cannot parse ${baselinePath}: ${err.message}`);
    process.exit(2);
  }
}

// ── Re-run a single test for flaky detection ────────────────────────────────
function rerunTest(file, testName, repoRoot, timeout) {
  const escaped = escapeRegex(testName);
  let passes = 0;
  const maxReruns = 2;
  const results = [];

  for (let i = 0; i < maxReruns; i++) {
    try {
      const out = execFileSync('npx', ['vitest', 'run', file, '-t', escaped, '--reporter', 'json'], {
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'pipe'],
        cwd: repoRoot,
        timeout,
      });
      const parsed = JSON.parse(out);
      let matchedAssertions = 0;
      let matchedFailed = 0;
      for (const r of (parsed.testResults || [])) {
        for (const a of (r.assertionResults || [])) {
          const aKey = buildKey(path.relative(repoRoot, r.name), a.ancestorTitles || [], a.title);
          if (aKey.endsWith('::' + testName)) {
            const keySuffix = aKey.slice(aKey.indexOf('::') + 2);
            if (keySuffix !== testName) continue;
            matchedAssertions++;
            if (a.status === 'failed') matchedFailed++;
          }
        }
      }
      const passed = matchedAssertions > 0 && matchedFailed === 0;
      results.push({ run: i + 1, passed, matched: matchedAssertions });
      if (passed) passes++;
    } catch (err) {
      if (err.killed || err.signal) {
        results.push({ run: i + 1, passed: false, error: 'subprocess killed (timeout/signal)' });
        continue;
      }
      if (err.stdout) {
        try {
          const parsed = JSON.parse(err.stdout);
          let matchedAssertions = 0;
          let matchedFailed = 0;
          for (const r of (parsed.testResults || [])) {
            for (const a of (r.assertionResults || [])) {
              const aKey = buildKey(path.relative(repoRoot, r.name), a.ancestorTitles || [], a.title);
              if (aKey.endsWith('::' + testName)) {
                const keySuffix = aKey.slice(aKey.indexOf('::') + 2);
                if (keySuffix !== testName) continue;
                matchedAssertions++;
                if (a.status === 'failed') matchedFailed++;
              }
            }
          }
          const passed = matchedAssertions > 0 && matchedFailed === 0;
          results.push({ run: i + 1, passed, matched: matchedAssertions });
          if (passed) passes++;
        } catch {
          results.push({ run: i + 1, passed: false, error: err.message });
        }
      } else {
        results.push({ run: i + 1, passed: false, error: err.message });
      }
    }
  }

  return { passes, total: maxReruns, results, flaky: passes > 0 };
}

// ── Classify failures ───────────────────────────────────────────────────────
function classifyFailures(currentFailures, baseline, repoRoot, rerunTimeout) {
  const baselineFailures = new Set(Object.keys(baseline.failures || {}));

  const regressions = [];
  const preExisting = [];
  const flakyTests = [];
  const newlyPassing = [];

  for (const [key, failure] of currentFailures) {
    if (baselineFailures.has(key)) {
      preExisting.push({ key, ...failure });
    } else {
      const fullName = failure.describeChain.length > 0
        ? failure.describeChain.join(' > ') + ' > ' + failure.test
        : failure.test;
      const rerun = rerunTest(failure.file, fullName, repoRoot, rerunTimeout);
      if (rerun.flaky) {
        flakyTests.push({ key, ...failure, rerun });
      } else if (failure.timedOut) {
        regressions.push({ key, ...failure, rerun, category: 'timeout' });
      } else {
        regressions.push({ key, ...failure, rerun });
      }
    }
  }

  for (const key of baselineFailures) {
    if (!currentFailures.has(key)) {
      newlyPassing.push(key);
    }
  }

  return { regressions, preExisting, flakyTests, newlyPassing };
}

// ── --debt-status mode ──────────────────────────────────────────────────────
function debtStatus(baseline) {
  const entries = Object.entries(baseline.failures || {});
  if (entries.length === 0) {
    console.log('No pre-existing failures in baseline.');
    return;
  }

  const byIssue = new Map();
  for (const [key, entry] of entries) {
    const issue = (entry && typeof entry === 'object' && entry.issue) || 'untracked';
    if (!byIssue.has(issue)) byIssue.set(issue, []);
    byIssue.get(issue).push(key);
  }

  console.log(`| Issue | Count | Files |`);
  console.log(`|---|---|---|`);
  const sorted = [...byIssue.entries()].sort((a, b) => b[1].length - a[1].length);
  for (const [issue, failures] of sorted) {
    const files = [...new Set(failures.map(f => f.split('::')[0]))].join(', ');
    console.log(`| ${issue} | ${failures.length} | ${files} |`);
  }

  console.log(`\n**Total:** ${entries.length} pre-existing failures`);
  console.log(`**Files:** ${new Set(entries.map(e => e[0].split('::')[0])).size}`);
  console.log(`**Issues:** ${sorted.map(s => s[0]).join(', ')}`);
}

// ── --auto-file mode ────────────────────────────────────────────────────────
function ensureGhCli(repoRoot) {
  try {
    execFileSync('gh', ['auth', 'status'], {
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
      cwd: repoRoot,
    });
  } catch {
    console.error('Error: gh CLI not authenticated. Run "gh auth login" first.');
    process.exit(2);
  }
}

function execWithRetry(cmd, args, repoRoot, { maxRetries = 3, backoffMs = [1000, 2000, 4000] } = {}) {
  let lastErr;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return execFileSync(cmd, args, {
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'pipe'],
        cwd: repoRoot,
      });
    } catch (err) {
      lastErr = err;
      if (err.code === 'ENOENT') throw err;
      if (attempt < maxRetries) {
        console.error(`Retry ${attempt + 1}/${maxRetries} for "${cmd} ${args.join(' ')}": ${err.message}`);
        const ms = backoffMs[Math.min(attempt, backoffMs.length - 1)];
        execSync(`sleep ${ms / 1000}`, { stdio: 'pipe', cwd: repoRoot });
      }
    }
  }
  throw lastErr;
}

function getUntrackedFailures(baseline) {
  const entries = [];
  for (const [key, entry] of Object.entries(baseline.failures || {})) {
    if (!entry || !entry.issue || entry.issue === '') {
      entries.push({ key, ...entry });
    }
  }
  return entries;
}

function buildIssueTitle(failure) {
  const basename = path.basename(failure.key.split('::')[0]);
  const describe = failure.key.includes('::') ? failure.key.split('::')[1] : '';
  let title = `[test-regression] ${basename}: ${describe}`;
  if (title.length > 200) {
    title = title.substring(0, 197) + '...';
  }
  return title;
}

function buildIssueBody(failure) {
  const file = failure.key.split('::')[0];
  const testName = failure.key.includes('::') ? failure.key.split('::')[1] : '';
  const error = (failure.error || '').substring(0, 500);

  return [
    `**File:** \`${file}\``,
    `**Test:** ${testName}`,
    '',
    '**Error:**',
    '```',
    error || 'no error message',
    '```',
    '',
    `<!-- auto-file: ${failure.key} -->`,
  ].join('\n');
}

function autoFileIssues(untracked, repoRoot, { dryRun = false, launchAgent = false } = {}) {
  if (untracked.length === 0) {
    return 0;
  }

  ensureGhCli(repoRoot);

  let created = 0;

  for (const failure of untracked) {
    const marker = `<!-- auto-file: ${failure.key} -->`;
    let existingIssue = null;

    try {
      const out = execWithRetry('gh', [
        'issue', 'list',
        '--label', 'ci-failure',
        '--state', 'open',
        '--json', 'title,body,number',
        '--limit', '100',
      ], repoRoot);
      const issues = JSON.parse(out);
      existingIssue = issues.find(issue => issue.body && issue.body.includes(marker));
    } catch (err) {
      console.error(`Warning: failed to query GitHub issues: ${err.message}`);
    }

    if (existingIssue) {
      console.log(`exists: #${existingIssue.number}`);
      continue;
    }

    const title = buildIssueTitle(failure);
    const body = buildIssueBody(failure);

    if (dryRun) {
      const entry = { title, body, key: failure.key };
      if (launchAgent) entry.launchAgent = true;
      console.log(JSON.stringify(entry));
      created++;
      continue;
    }

    try {
      const result = execWithRetry('gh', [
        'issue', 'create',
        '--title', title,
        '--body', body,
        '--label', 'ci-failure,bug,tech-debt',
      ], repoRoot);
      created++;
      console.log(`created: ${title}`);

      if (launchAgent) {
        const issueUrl = result.trim();
        const issueNumber = issueUrl.split('/').pop();
        if (issueNumber) {
          try {
            execFileSync('gh', [
              'issue', 'comment', issueNumber,
              '--body', '/implement-issue',
            ], { stdio: 'pipe', timeout: 10000, cwd: repoRoot });
            console.log(`  ↳ launch-agent: posted /implement-issue on #${issueNumber}`);
          } catch (commentErr) {
            console.error(`  ↳ launch-agent: failed to post comment on #${issueNumber}: ${commentErr.message}`);
          }
        }
      }
    } catch (err) {
      console.error(`Error: failed to create issue for "${failure.key}": ${err.message}`);
      console.error('Continuing with remaining failures...');
    }
  }

  return created > 0 ? 1 : 0;
}

// ── Main ────────────────────────────────────────────────────────────────────
function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    printHelp();
    process.exit(0);
  }

  const ROOT = args.repo;

  // Resolve baseline path
  if (!args.baseline) {
    args.baseline = path.join(ROOT, 'test-baseline.json');
  } else {
    args.baseline = path.resolve(ROOT, args.baseline);
    // Container/virtualisation safety: ensure path stays within repo
    let realPath;
    try { realPath = fs.realpathSync(args.baseline); } catch { realPath = args.baseline; }
    if (!realPath.startsWith(path.resolve(ROOT) + path.sep) && realPath !== path.resolve(ROOT)) {
      console.error(`Error: --baseline path must be within the repo directory. Got: ${args.baseline}`);
      process.exit(2);
    }
  }

  // Validate timeout
  if (args.timeout <= 0) {
    console.error('Error: --timeout must be a positive number of milliseconds');
    process.exit(2);
  }
  if (args.rerunTimeout <= 0) {
    console.error('Error: --rerun-timeout must be a positive number of milliseconds');
    process.exit(2);
  }

  // --auto-file
  if (args.autoFile) {
    const baseline = readBaseline(args.baseline, false);
    const untracked = getUntrackedFailures(baseline);
    const exitCode = autoFileIssues(untracked, ROOT, { dryRun: args.dryRun, launchAgent: args.launchAgent });
    process.exit(exitCode);
  }

  // --debt-status
  if (args.debtStatus) {
    const baseline = readBaseline(args.baseline, false);
    debtStatus(baseline);
    process.exit(0);
  }

  // Graceful degradation: not a git repo → nothing to diff
  ensureRepoIsGit(ROOT);

  // Graceful degradation: no vitest → nothing to test
  ensureVitestAvailable(ROOT);

  const changedFiles = getChangedFiles(ROOT, args.baseBranch);
  if (changedFiles.length === 0) {
    console.log(JSON.stringify({ status: 'no-changes', affectedTests: 0 }));
    process.exit(0);
  }

  const { testFiles } = selectAffectedTests(changedFiles, ROOT);

  if (args.affectedOnly) {
    console.log(JSON.stringify({ status: 'affected-only', testFiles, changedFiles }));
    process.exit(0);
  }

  if (testFiles.length === 0) {
    console.log(JSON.stringify({ status: 'no-affected-tests', sourceFiles: changedFiles.length }));
    process.exit(0);
  }

  const result = runVitest(testFiles, ROOT, args.timeout);
  const currentFailures = parseVitestResults(result, ROOT);
  const baseline = readBaseline(args.baseline, true);

  const { regressions, preExisting, flakyTests, newlyPassing } =
    classifyFailures(currentFailures, baseline, ROOT, args.rerunTimeout);

  const summary = {
    status: regressions.length > 0 ? 'regression' : 'clean',
    affectedTests: testFiles.length,
    regressions: regressions.map(r => ({ file: r.file, test: r.test, error: r.error ? r.error.substring(0, 200) : '' })),
    preExisting: preExisting.length,
    flaky: flakyTests.length,
    skipped: 0,
    newlyPassing: newlyPassing.length,
    debtSummary: {
      total: Object.keys(baseline.failures || {}).length,
      files: new Set(Object.keys(baseline.failures || {}).map(k => k.split('::')[0])).size,
      issues: [...new Set(Object.values(baseline.failures || {}).map(v => v.issue).filter(Boolean))],
    },
  };

  console.log(JSON.stringify(summary, null, 2));

  if (regressions.length > 0) {
    console.error(`\nRegression detected: ${regressions.length} new failure(s).`);
    for (const r of regressions) {
      console.error(`  ${r.key}`);
    }
    process.exit(1);
  }

  process.exit(0);
}

// ── Module guard ────────────────────────────────────────────────────────────
if (require.main === module) {
  main();
} else {
  module.exports = {
    parseArgs, printHelp, getChangedFiles, selectAffectedTests,
    runVitest, parseVitestResults, buildKey, classifyFailures,
    escapeRegex, readBaseline, rerunTest, debtStatus,
    getUntrackedFailures, buildIssueTitle, buildIssueBody,
    autoFileIssues, ensureGhCli, execWithRetry, ensureRepoIsGit, ensureVitestAvailable,
    main,
  };
}
