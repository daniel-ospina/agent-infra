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

// ─── Inline generic test job detection (#389) ───────────────────────────────
//
// The #387 reusable unit-test capability (node-ci.yml unit-test job with
// test-glob / test-command inputs) centralizes generic JS/TS suite runners.
// This rule FAILS drift-check on a consumer workflow that instead inlines a
// generic suite job (node --test / vitest / npx tsx --test over a static
// glob/directory), with remediation naming node-ci.yml@<ref>. Repo-specific
// gates (file-specific runs, migration guards, e2e harnesses, service-
// container/matrix/container jobs, build-artifact suites, dynamic targets,
// changed-files loops) must NOT trip. See
// docs/scoping/2026-08-31-issue-389-inline-jobs-plan.md (rev 6) for the
// boundary contract and the pin list; the unit tests mechanically enforce it.

/** Build-output directory names — client-build class (issue-named repo-specific). */
const ARTIFACT_DIRS = ['dist', 'build', 'out', '.next'];

/** Node/tsx flags that consume a separate value token (space form). */
const NODE_VALUE_FLAGS = new Set([
  '--import', '--loader', '-r', '--env-file',
  '--test-name-pattern', '--test-reporter', '--test-reporter-destination',
  '--test-shard', '--test-concurrency', '--test-timeout', '--test-isolation',
  '--test-skip-pattern', '--test-coverage-lines', '--test-coverage-branches',
  '--test-coverage-functions', '--test-coverage-statements',
]);

/** Vitest flags that consume a separate value token (space form). */
const VITEST_VALUE_FLAGS = new Set([
  '-t', '--testNamePattern', '-c', '--config', '-r', '--root', '--dir',
  '--environment', '--pool', '--include', '--exclude',
]);

/** Vitest subcommands consumed before target extraction. */
const VITEST_SUBCOMMANDS = new Set(['run', 'watch', 'related', 'bench']);

/** Static test-looking iterable qualifier (substring match wins). */
const TEST_LOOKING = /tests?\/|__tests__|\.test\.|\.spec\./;

/** Concrete source-file extensions → file-specific (repo-specific class). */
const SOURCE_EXT = /\.(?:js|mjs|cjs|ts|mts|cts|jsx|tsx)$/i;

/** Dynamic-target markers. */
const DYNAMIC = /\$\{\{|\$\(|\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]*\}|\$@|\$[1-9]/;

/** Leading whitespace count (tabs count as 1 for indentation comparison). */
function leadingSpaces(line) {
  const m = /^[ \t]*/.exec(line);
  return m ? m[0].length : 0;
}

/** Escape a string for use inside a RegExp. */
function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Quote-aware strip of leading/trailing quotes on a single token. */
function stripTokenQuotes(t) {
  if (t.length >= 2 && ((t[0] === '"' && t[t.length - 1] === '"') || (t[0] === "'" && t[t.length - 1] === "'"))) {
    return t.slice(1, -1);
  }
  return t;
}

// ── Workflow job model (indentation-aware, scalar-state tracked) ────────────

/**
 * Extract the jobs map from a workflow file's YAML text (line-based subset).
 * Returns [{ name, rawLines: [{ indent, raw }] }]. Comment lines and `---`
 * are skipped. `jobs:` must be a top-level key (indent 0).
 */
function parseWorkflowJobs(content) {
  const lines = String(content).split(/\r?\n/);
  let jobsIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (!t || t.startsWith('#')) continue;
    if (/^jobs\s*:\s*(?:#.*)?$/.test(t)) { jobsIdx = i; break; }
  }
  if (jobsIdx === -1) return [];
  const jobs = [];
  let current = null;
  for (let i = jobsIdx + 1; i < lines.length; i++) {
    const raw = lines[i];
    const trimmed = raw.trim();
    if (!trimmed || trimmed.startsWith('#') || trimmed === '---') continue;
    const indent = leadingSpaces(raw);
    if (indent < 2) break; // back at top level → jobs map ended
    if (indent === 2 && !trimmed.startsWith('- ')) {
      const name = trimmed.replace(/\s*:\s*(?:#.*)?$/, '').trim();
      if (!name) continue;
      current = { name, rawLines: [] };
      jobs.push(current);
    } else if (current) {
      current.rawLines.push({ indent, raw });
    }
  }
  return jobs;
}

/** True when the job has a sub-key (indent 4) with the given name. */
function jobHasKey(job, key) {
  return job.rawLines.some(({ indent, raw }) => indent === 4 && raw.trim().startsWith(key + ':'));
}

/**
 * Extract `run:` command bodies from a job's steps. Step-scoped: `run:` is
 * only read as a sub-key of the current step item (`- run:` or `run:` under
 * `- name:`/`- uses:`), never a bare key inside a `uses:` action's `with:`
 * block. Supports single-line, `|` literal and `>` folded blocks.
 */
function extractRunCommands(job) {
  const cmds = [];
  let stepsIdx = -1;
  for (let i = 0; i < job.rawLines.length; i++) {
    if (/^steps\s*:\s*$/.test(job.rawLines[i].raw.trim())) { stepsIdx = i; break; }
  }
  if (stepsIdx === -1) return cmds;
  const stepsIndent = job.rawLines[stepsIdx].indent;
  const itemIndent = stepsIndent + 2;
  const keyIndent = itemIndent + 2;
  let inBlock = null; // { indent, lines } — a `run: |` / `run: >` block
  for (let i = stepsIdx + 1; i < job.rawLines.length; i++) {
    const { indent, raw } = job.rawLines[i];
    if (indent < stepsIndent) break; // left the steps section (indent-0/2 key)
    if (indent === stepsIndent) continue; // another job-level key
    if (inBlock) {
      // Scalar-state tracking: block content is opaque command text — its
      // lines are collected (dedented) and never re-parsed for structure.
      if (indent > inBlock.indent) { inBlock.lines.push(raw.replace(new RegExp('^ {0,' + (inBlock.indent + 2) + '}'), '')); continue; }
      cmds.push(inBlock.lines.join('\n'));
      inBlock = null;
    }
    if (indent === itemIndent && raw.trim().startsWith('- ')) {
      // New step item; sub-keys live at keyIndent.
      const body = raw.trim().slice(2);
      const m = /^run\s*:\s*(.*)$/.exec(body);
      if (m) {
        const v = m[1];
        if (v === '|' || v === '>' || v === '|-' || v === '>-') inBlock = { indent: itemIndent, lines: [] };
        else if (v.trim()) cmds.push(v);
      }
      continue;
    }
    if (indent === keyIndent) {
      const m = /^run\s*:\s*(.*)$/.exec(raw.trim());
      if (m) {
        const v = m[1];
        if (v === '|' || v === '>' || v === '|-' || v === '>-') inBlock = { indent: keyIndent, lines: [] };
        else if (v.trim()) cmds.push(v);
      }
    }
    // Keys deeper than keyIndent (with:, env: contents) are never `run:`.
  }
  if (inBlock) cmds.push(inBlock.lines.join('\n'));
  return cmds;
}

// ── Command preprocessing (interleaved pipeline, rev 6) ─────────────────────

/**
 * Quote-aware heredoc opener scan. Returns null or
 * { term, feedingCommand } — the command text before `<<`.
 */
function findHeredocOpener(line) {
  let quote = null;
  let depth = 0;
  let i = 0;
  while (i < line.length) {
    const ch = line[i];
    if (quote) {
      if (ch === quote && line[i - 1] !== '\\') quote = null;
      i++;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; i++; continue; }
    if (ch === '#') return null; // comment — no opener after it
    if (ch === '$' && line[i + 1] === '(') { depth++; i += 2; continue; }
    if (ch === ')' && depth > 0) { depth--; i++; continue; }
    if (depth === 0 && ch === '<' && line[i + 1] === '<') {
      let k = i + 2;
      if (line[k] === '-') k++; // <<-
      let q = '';
      if (line[k] === "'" || line[k] === '"') { q = line[k]; k++; }
      let term = '';
      while (k < line.length && /[A-Za-z0-9_]/.test(line[k])) { term += line[k]; k++; }
      if (q && line[k] === q) k++;
      if (term) return { term, feedingCommand: line.slice(0, i).trim(), trailingCommand: line.slice(k).trim() };
      i += 2;
      continue;
    }
    i++;
  }
  return null;
}

/** True when the heredoc is fed to (or piped into) a shell interpreter. */
function isExecutedHeredoc(opener) {
  const shellTail = /(?:^|[|])\s*(?:env\s+)?(?:sudo\s+-E\s+)?(?:bash|sh|zsh|ksh)(?:\s+-[a-zA-Z]+)*\s*$/;
  // The feeding command may end in a shell (`bash <<`), or the heredoc may
  // be piped into a shell (`cat <<'EOF' | bash` — the pipe lives AFTER the
  // heredoc, so check the trailing command too).
  return shellTail.test(opener.feedingCommand) || shellTail.test(opener.trailingCommand);
}

/**
 * Replace heredoc spans with placeholders; collect executed bodies.
 * Returns { text, executedBodies }. Unterminated openers are NOT heredocs
 * (kept as plain text).
 */
function extractHeredocSpans(cmd) {
  const lines = String(cmd).split(/\r?\n/);
  const out = [];
  const executed = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const opener = findHeredocOpener(line);
    if (!opener) { out.push(line); i++; continue; }
    const termRe = new RegExp('^[ \\t]*' + escapeRegExp(opener.term) + '[ \\t]*$');
    let found = -1;
    for (let j = i + 1; j < lines.length; j++) {
      if (termRe.test(lines[j])) { found = j; break; }
    }
    if (found === -1) { out.push(line); i++; continue; } // unterminated → not a heredoc
    const body = lines.slice(i + 1, found);
    if (isExecutedHeredoc(opener)) executed.push(body.join('\n'));
    out.push('__HEREDOC__');
    i = found + 1;
  }
  return { text: out.join('\n'), executedBodies: executed };
}

/** Quote-aware + `$(`-depth-aware comment stripping (shell semantics). */
function stripComments(text) {
  return String(text).split('\n').map((line) => {
    let quote = null;
    let depth = 0;
    let out = '';
    let i = 0;
    while (i < line.length) {
      const ch = line[i];
      if (quote) {
        out += ch;
        if (ch === quote && line[i - 1] !== '\\') quote = null;
        i++;
        continue;
      }
      if (ch === "'" || ch === '"') { quote = ch; out += ch; i++; continue; }
      if (ch === '$' && line[i + 1] === '(') { depth++; out += '$('; i += 2; continue; }
      if (ch === ')' && depth > 0) { depth--; out += ch; i++; continue; }
      if (depth === 0 && ch === '#' && (i === 0 || /\s/.test(line[i - 1]))) {
        out += line.slice(i); // keep tail so line structure is preserved
        i = line.length;
        continue;
      }
      out += ch;
      i++;
    }
    return out;
  }).join('\n');
}

/**
 * Segment split at newlines/`;`/`&&`/`||`/`|`/`&` — quote-opaque,
 * `$(`-depth-opaque, `[0-9]?>&?[0-9]?` redirects opaque.
 */
function splitSegments(text) {
  const segs = [];
  let cur = '';
  let quote = null;
  let depth = 0;
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (quote) {
      cur += ch;
      if (ch === quote && text[i - 1] !== '\\') quote = null;
      i++;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; cur += ch; i++; continue; }
    if (ch === '$' && text[i + 1] === '(') { depth++; cur += '$('; i += 2; continue; }
    if (ch === ')' && depth > 0) { depth--; cur += ch; i++; continue; }
    if (depth === 0) {
      if (/^[0-9]?>&?[0-9]?/.test(text.slice(i, i + 4)) && ch !== '&') { cur += ch; i++; continue; }
      if (ch === '\n' || ch === ';' || ch === '&' || ch === '|') {
        if (cur.trim()) segs.push(cur.trim());
        cur = '';
        while (i < text.length && (text[i] === '\n' || text[i] === ';' || text[i] === '&' || text[i] === '|')) i++;
        continue;
      }
    }
    cur += ch;
    i++;
  }
  if (cur.trim()) segs.push(cur.trim());
  return segs;
}

/** Collapse `.`/`..` path segments for artifact detection. */
function collapsePath(p) {
  const out = [];
  for (const seg of String(p).split('/')) {
    if (seg === '..') out.pop();
    else if (seg !== '.' && seg !== '') out.push(seg);
  }
  return out;
}

/**
 * Per-segment-head wrapper + shell-control strip (fixpoint). Returns
 * { text, innerHit } — innerHit carries a suite found inside a bash -c/sh -c
 * extraction (full-pipeline recursion).
 */
function stripHeadWrappers(seg) {
  let s = String(seg).trim();
  // Strip comments first (a segment may still carry an inline comment tail).
  s = stripComments(s).trim();
  let prev = null;
  while (s && s !== prev) {
    prev = s;
    if (/^\(.*\)$/.test(s)) { s = s.slice(1, -1).trim(); continue; } // subshell parens (single command)
    const envm = /^(?:env\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)+/.exec(s); // VAR=value / env VAR=..
    if (envm) { s = s.slice(envm[0].length).trim(); continue; }
    const setm = /^set(?:(?:\s+[+-][a-zA-Z]+)+)?\s*;?\s*/.exec(s); // set -e; set -euo pipefail; …
    if (setm && /^set\b/.test(s)) { s = s.slice(setm[0].length).trim(); continue; }
    const tm = /^(?:g?timeout)\s+[0-9]+[smhd]?\s+/.exec(s); // timeout 300 / 5m
    if (tm) { s = s.slice(tm[0].length).trim(); continue; }
    const bm = /^(?:bash|sh|zsh|ksh)(?:\s+-[a-zA-Z]+)*\s+-?[a-zA-Z]*c\s+("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/.exec(s);
    if (bm) {
      const inner = bm[1].slice(1, -1);
      const innerHit = matchGenericSuite(inner); // full recursive pipeline
      if (innerHit) return { text: s, innerHit };
      s = s.slice(bm[0].length).trim();
      continue;
    }
    const wm = /^(?:sudo(?:\s+-E)?|nohup|nice(?:\s+-n\s+\d+)?|stdbuf\s+\S+|env)\s+/.exec(s);
    if (wm) { s = s.slice(wm[0].length).trim(); continue; }
    const cm = /^(?:time|exec|!)\s+/.exec(s);
    if (cm) { s = s.slice(cm[0].length).trim(); continue; }
    const casem = /^case\b/.test(s);
    if (casem) {
      // `case <expr> in` consumed as a unit (subject included). A `;` inside
      // the expression breaks the bounded regex — documented miss.
      const unit = /^case\b[^;{}]*?\bin\b\s*/.exec(s);
      if (unit) { s = s.slice(unit[0].length).trim(); continue; }
      const cs = /^case\b\s*/.exec(s);
      if (cs) { s = s.slice(cs[0].length).trim(); continue; }
    }
    const swm = /^(?:if|elif|else|then|fi|do|done|esac|in)\b\s*/.exec(s);
    if (swm) { s = s.slice(swm[0].length).trim(); continue; }
    const lm = /^[^()\s]+\s*\)\s+/.exec(s); // case label `linux) cmd`
    if (lm) { s = s.slice(lm[0].length).trim(); continue; }
  }
  return { text: s };
}

// ── Tokenizer + runner detection ────────────────────────────────────────────

/** Quote-aware token split. */
function tokenize(text) {
  const tokens = [];
  let cur = '';
  let quote = null;
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (quote) {
      cur += ch;
      if (ch === quote && text[i - 1] !== '\\') quote = null;
      i++;
      continue;
    }
    if (ch === "'" || ch === '"') { quote = ch; cur += ch; i++; continue; }
    if (/\s/.test(ch)) { if (cur) { tokens.push(cur); cur = ''; } i++; continue; }
    cur += ch;
    i++;
  }
  if (cur) tokens.push(cur);
  return tokens;
}

/** Indices of positional tokens (non-flag, non-value-of-value-flag). */
function positionalIndexes(tokens, valueFlags) {
  const out = [];
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].startsWith('-')) continue;
    if (i > 0 && valueFlags.has(tokens[i - 1])) continue;
    out.push(i);
  }
  return out;
}

/**
 * Classify a primary target token. Returns 'suite' | 'neutral'.
 * Order: dynamic → artifact → glob → file-specific → dir/bare.
 */
function classifyTarget(tok, opts = {}) {
  const t = stripTokenQuotes(String(tok));
  if (!opts.ignoreTargetDynamics && DYNAMIC.test(t)) return 'neutral';
  const segs = collapsePath(t.replace(/^\.\//, ''));
  if (segs.some((seg) => ARTIFACT_DIRS.includes(seg))) return 'neutral';
  if (/[*?[]/.test(t)) return 'suite'; // glob
  if (SOURCE_EXT.test(t)) return 'neutral'; // concrete file
  return 'suite'; // directory or bare
}

/** First line of a command, truncated for diagnostics. */
function previewCommand(cmd) {
  const first = String(cmd).split(/\r?\n/).find((l) => l.trim()) || '';
  const t = first.trim();
  return t.length > 120 ? t.slice(0, 117) + '...' : t;
}

/** Detect a generic suite invocation in a prepared segment. */
function matchRunner(text, opts = {}) {
  const tokens = tokenize(text);
  if (!tokens.length) return null;
  const nodeHit = matchNodeTest(tokens, opts);
  if (nodeHit) return nodeHit;
  const vitestHit = matchVitest(tokens, opts);
  if (vitestHit) return vitestHit;
  return matchTsx(tokens, opts);
}

/** node --test: exact `--test` before the first positional after the runner. */
function matchNodeTest(tokens, opts) {
  let idx = 0;
  while (idx < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[idx])) idx++;
  if (tokens[idx] !== 'node') return null;
  const testIdx = tokens.indexOf('--test');
  if (testIdx === -1 || testIdx <= idx) return null;
  const pos = positionalIndexes(tokens, NODE_VALUE_FLAGS);
  const afterRunner = pos.filter((i) => i > idx);
  if (afterRunner.length && testIdx > afterRunner[0]) return null; // a positional precedes --test → not suite mode
  const afterTest = pos.filter((i) => i > testIdx);
  if (!afterTest.length) {
    if (tokens.includes('--help') || tokens.includes('--version')) return null; // probe
    return { pattern: 'node --test', command: null };
  }
  const target = tokens[afterTest[0]];
  if (classifyTarget(target, opts) === 'neutral') return null;
  return { pattern: 'node --test', command: null };
}

/** vitest: first-token or runner-prefix + subcommand-aware target extraction. */
function matchVitest(tokens, opts) {
  const PREFIX = new Set(['npx', 'yarn', 'pnpm', 'bun', 'bunx']);
  let vIdx = -1;
  if (tokens[0] === 'vitest') vIdx = 0;
  else if (PREFIX.has(tokens[0]) || (tokens[0] === 'npm' && tokens[1] === 'exec')) {
    vIdx = tokens.indexOf('vitest');
    if (vIdx === -1) return null;
  } else return null;
  const pos = positionalIndexes(tokens, VITEST_VALUE_FLAGS);
  const afterVitest = pos.filter((i) => i > vIdx);
  let targetIdx = null;
  if (afterVitest.length) {
    const firstPos = afterVitest[0];
    targetIdx = VITEST_SUBCOMMANDS.has(tokens[firstPos]) && afterVitest[1] !== undefined
      ? afterVitest[1]
      : (VITEST_SUBCOMMANDS.has(tokens[firstPos]) ? null : firstPos);
  }
  if (tokens.includes('--version') || tokens.includes('--help')) {
    if (targetIdx === null) return null; // probe
  }
  if (targetIdx === null) return { pattern: 'vitest', command: null };
  if (classifyTarget(tokens[targetIdx], opts) === 'neutral') return null;
  return { pattern: 'vitest', command: null };
}

/** npx tsx --test / bare tsx --test: same precedence as node --test. */
function matchTsx(tokens, opts) {
  let tIdx = -1;
  if (tokens[0] === 'tsx') tIdx = 0;
  else if (['npx', 'yarn', 'pnpm', 'bun', 'bunx'].includes(tokens[0])) {
    tIdx = tokens.indexOf('tsx');
    if (tIdx === -1) return null;
  } else return null;
  const testIdx = tokens.indexOf('--test');
  if (testIdx === -1) return null;
  const pos = positionalIndexes(tokens, NODE_VALUE_FLAGS);
  const afterRunner = pos.filter((i) => i > tIdx);
  if (afterRunner.length && testIdx > afterRunner[0]) return null; // flag after script path → not suite mode
  const afterTest = pos.filter((i) => i > testIdx);
  if (!afterTest.length) {
    if (tokens.includes('--help') || tokens.includes('--version')) return null;
    return { pattern: 'tsx --test', command: null };
  }
  const target = tokens[afterTest[0]];
  if (classifyTarget(target, opts) === 'neutral') return null;
  return { pattern: 'tsx --test', command: null };
}

/**
 * Anchored loop classification. Only commands STARTING with for/while are
 * loops; the verdict governs the whole span (opaque to segment processing).
 * Executed-heredoc bodies are OR'd into the body check.
 */
function matchAnchoredLoop(prepared) {
  const text = prepared.text.trim();
  const loop = parseLoop(text);
  if (!loop) return null;
  const iterable = loop.iterable || loop.src;
  if (!iterable) return null;
  // Dynamic iterable / bare glob → neutral whole span.
  if (DYNAMIC.test(iterable)) return null;
  // Artifact iterable → neutral (consistent with the direct form).
  if (collapsePath(iterable.replace(/^\.\//, '')).some((seg) => ARTIFACT_DIRS.includes(seg))) return null;
  if (!TEST_LOOKING.test(iterable)) return null; // bare *? globs alone don't qualify
  // Body suite check — reuses the full runner classification, target
  // dynamics IGNORED (the iterable's staticness IS the dynamic decision).
  const body = loop.body || '';
  if (suitePresentInText(body)) return { pattern: 'loop', command: null };
  for (const eb of prepared.executedBodies) {
    if (suitePresentInText(eb)) return { pattern: 'loop', command: null };
  }
  return null;
}

/** True when the text contains a suite invocation (loop-body context). */
function suitePresentInText(text) {
  const prepared = prepareCommand(text);
  if (matchAnchoredLoop(prepared)) return true;
  for (const eb of prepared.executedBodies) {
    if (suitePresentInText(eb)) return true;
  }
  for (const seg of splitSegments(prepared.text)) {
    const { text: stripped, innerHit } = stripHeadWrappers(seg);
    if (innerHit) return true;
    if (stripped && matchRunner(stripped, { ignoreTargetDynamics: true })) return true;
  }
  return false;
}

/** Parse an anchored for/while loop. Returns null or { iterable, src, body }. */
function parseLoop(text) {
  const fm = /^for\s+\S+\s+in\s+(.+?)(?:\s*;\s*do\b|\s+do\b)([\s\S]*)$/.exec(text);
  if (fm) {
    const body = fm[2].replace(/\s*done\s*$/, '');
    return { iterable: fm[1].trim(), body };
  }
  const wm = /^while\b([\s\S]*?)\s*;\s*do\b([\s\S]*?)\s*done\s*(?:<\s*<*\s*(.+?))?\s*$/.exec(text);
  if (wm) {
    return { src: wm[3] ? wm[3].trim() : null, body: wm[2] };
  }
  return null;
}

// ── Public API ──────────────────────────────────────────────────────────────

/** Prepare a run command: heredoc spans → placeholder/executed bodies. */
function prepareCommand(command) {
  const spans = extractHeredocSpans(command);
  const joined = spans.text.replace(/\\\r?\n/g, ' '); // continuation join (outside spans)
  return { text: joined, executedBodies: spans.executedBodies };
}

/**
 * Classify one run command. Returns null or { pattern, command }.
 * pattern ∈ 'node --test' | 'vitest' | 'tsx --test' | 'loop'.
 */
function matchGenericSuite(command) {
  const prepared = prepareCommand(command);
  // Anchored loops are atomic units: their verdict governs the whole span
  // (a neutral anchored loop is opaque — no fall-through to segments).
  const loopHit = matchAnchoredLoop(prepared);
  if (loopHit === null && /^(for|while)\b/.test(prepared.text.trim())) return null;
  if (loopHit) return { pattern: 'loop', command: previewCommand(command) };
  for (const body of prepared.executedBodies) {
    const hit = matchGenericSuite(body); // recursive (executed heredoc body)
    if (hit) return hit;
  }
  for (const seg of splitSegments(prepared.text)) {
    const { text: stripped, innerHit } = stripHeadWrappers(seg);
    if (innerHit) return innerHit;
    if (!stripped) continue;
    const hit = matchRunner(stripped);
    if (hit) return { pattern: hit.pattern, command: previewCommand(command) };
  }
  return null;
}

/**
 * Find inline generic test jobs in a workflow file's content.
 * Returns [{ job, pattern, command }] — one finding per job.
 */
function findInlineGenericTestJobs(content) {
  const findings = [];
  for (const job of parseWorkflowJobs(content)) {
    if (jobHasKey(job, 'uses') || jobHasKey(job, 'services') || jobHasKey(job, 'strategy') || jobHasKey(job, 'container')) continue;
    for (const cmd of extractRunCommands(job)) {
      const hit = matchGenericSuite(cmd);
      if (hit) {
        findings.push({ job: job.name, pattern: hit.pattern, command: hit.command });
        break;
      }
    }
  }
  return findings;
}

/**
 * Scan a consumer repo's workflow files for inline generic test jobs.
 * Returns [{ file, job, pattern, command, remediationRef }].
 */
function checkInlineGenericJobs(targetDir, ciRef) {
  const findings = [];
  for (const file of workflowFilesIn(targetDir)) {
    let content;
    try { content = fs.readFileSync(file, 'utf-8'); } catch { continue; }
    for (const f of findInlineGenericTestJobs(content)) {
      findings.push({
        file: path.relative(targetDir, file),
        job: f.job,
        pattern: f.pattern,
        command: f.command,
        remediationRef: ciRef || null,
      });
    }
  }
  return findings;
}

module.exports = {
  AGENT_INFRA_WORKFLOW_PREFIX,
  REUSABLE_WORKFLOWS,
  ARTIFACT_DIRS,
  parseUsesRefs,
  agentInfraUses,
  workflowFilesIn,
  findWorkflowSymlinks,
  checkCiRefs,
  parseWorkflowJobs,
  findInlineGenericTestJobs,
  checkInlineGenericJobs,
  matchGenericSuite,
};
