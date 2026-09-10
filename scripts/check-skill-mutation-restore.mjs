#!/usr/bin/env node
/**
 * check-skill-mutation-restore.mjs — #664 guard.
 *
 * The review-fix loops (code-review, issue-scoping, plan-review, test-review,
 * prototype-review) prescribe deliberate RED mutations ("verify the guard goes
 * RED") without defining the restore. Agents fill the gap with `git checkout --
 * <path>` / `git restore <path>`, which restore to the INDEX/HEAD state — not to
 * "the state before my mutation" — and therefore silently delete the uncommitted
 * work the mutation was verifying (#640: the ci.yml concurrency group and a
 * frontmatter-validate.mjs 121→122 relabel, both nearly lost).
 *
 * This check fails when an AGENT-FACING instruction surface prescribes a
 * working-tree discard as the post-mutation restore:
 *
 *   - AGENTS.md
 *   - templates/AGENTS.base.md   (canonical base; propagates to every consumer)
 *   - skills/**\/*.md            (every skill / skill reference)
 *
 * Matching is CONTEXT-BASED, not word-based (the string legitimately appears in
 * operational prose, e.g. using-git-worktrees' M4 notes, and in the protocol's
 * own hazard description):
 *
 *   1. the line must contain a working-tree discard command
 *      (`git checkout -- <path>`, `git checkout .`, `git restore ...`), AND
 *   2. the occurrence's enclosing fenced code block / ±3-line window must
 *      contain a mutation marker (`mutation`, `mutate`, `negative test`,
 *      `planted`, uppercase `RED`, `falsif`), OR the line itself must.
 *
 * Escape hatch (auditable, reason-required): a line that must NAME the forbidden
 * form carries `<!-- mutation-restore-ok: <reason> -->` on that line or on the
 * line directly above. An empty pragma is still a violation.
 *
 * Usage:
 *   node scripts/check-skill-mutation-restore.mjs              # scan the repo
 *   node scripts/check-skill-mutation-restore.mjs --root <dir> # scan a fixture tree
 *   node scripts/check-skill-mutation-restore.mjs --quiet
 *
 * Exit 0 = clean, 1 = violation(s), 2 = usage error.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const SELF_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** Working-tree discards — each name is for the message; each re matches one line. */
export const DISCARD_PATTERNS = [
  // `git checkout -- <path>` (the explicit-pathspec form; `--orphan` etc. have no space after `--`)
  { name: "git checkout -- <path>", re: /\bgit\s+checkout\s+--\s+\S/ },
  // `git checkout .` (bare dot pathspec)
  { name: "git checkout .", re: /\bgit\s+checkout\s+\./ },
  // `git restore <path>` / `git restore .` (any form)
  { name: "git restore <path>", re: /\bgit\s+restore\b/ },
];

/** Mutation/negative-test context markers — the "deliberate RED mutation" signal. */
export const MUTATION_MARKERS = [
  /\bmutat(?:e|es|ed|ing|ion|ions)\b/i,
  /\bnegative[-\s]test/i,
  /\bplanted\b/i,
  /\bRED\b/, // uppercase only — the repo's idiom ("confirm RED", "goes RED")
  /\bfalsif/i,
];

const PRAGMA_RE = /<!--\s*mutation-restore-ok\s*:\s*([\s\S]*?)-->/i;
const MIN_PRAGMA_REASON = 3;

/** @returns {string|null} the pragma reason, or null when no pragma is present. */
export function pragmaReason(line) {
  const m = PRAGMA_RE.exec(line);
  return m ? m[1].trim() : null;
}

/** All fence spans (``` or ~~~, 3+) in a file, as {start,end} line indices. */
export function fenceSpans(lines) {
  const spans = [];
  let open = -1;
  for (let i = 0; i < lines.length; i++) {
    if (!/^\s*(?:`{3,}|~{3,})/.test(lines[i])) continue;
    if (open === -1) open = i;
    else {
      spans.push({ start: open, end: i });
      open = -1;
    }
  }
  if (open !== -1) spans.push({ start: open, end: lines.length - 1 });
  return spans;
}

/** Context text for a hit: enclosing fence (if any) + a ±3-line window. */
export function contextFor(lines, spans, idx) {
  let start = Math.max(0, idx - 3);
  let end = Math.min(lines.length - 1, idx + 3);
  const span = spans.find((s) => idx >= s.start && idx <= s.end);
  if (span) {
    start = Math.min(start, span.start);
    end = Math.max(end, span.end);
  }
  return lines.slice(start, end + 1).join("\n");
}

/**
 * Scan one file's text.
 * @returns {Array<{line:number, command:string, context:boolean, emptyPragma:boolean}>}
 */
export function scanText(text) {
  const lines = text.split(/\r?\n/);
  const spans = fenceSpans(lines);
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const discard = DISCARD_PATTERNS.find((p) => p.re.test(line));
    if (!discard) continue;
    const context = contextFor(lines, spans, i);
    const inMutationContext = MUTATION_MARKERS.some((re) => re.test(context));
    if (!inMutationContext) continue; // the word alone is not a violation
    const reasons = [lines[i - 1] ?? "", line, lines[i + 1] ?? ""].map(pragmaReason);
    const reason = reasons.find((r) => r !== null && r.length >= MIN_PRAGMA_REASON);
    if (reason) continue; // explicit, reasoned allowance (naming the hazard)
    hits.push({
      line: i + 1,
      command: discard.name,
      emptyPragma: reasons.some((r) => r !== null),
    });
  }
  return hits;
}

function walk(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(abs, out);
    else out.push(abs);
  }
}

/** Files in scope, relative to `root`, deterministically ordered. */
export function collectFiles(root) {
  const files = [];
  for (const rel of ["AGENTS.md", path.join("templates", "AGENTS.base.md")]) {
    const abs = path.join(root, rel);
    if (fs.existsSync(abs) && fs.statSync(abs).isFile()) files.push({ rel, abs });
  }
  const skillsDir = path.join(root, "skills");
  if (fs.existsSync(skillsDir) && fs.statSync(skillsDir).isDirectory()) {
    const abs = [];
    walk(skillsDir, abs);
    for (const p of abs) {
      if (p.endsWith(".md")) files.push({ rel: path.relative(root, p), abs: p });
    }
  }
  return files.sort((a, b) => a.rel.localeCompare(b.rel));
}

/** @returns {{files:number, violations:Array<{file:string,line:number,command:string,emptyPragma:boolean}>}} */
export function findViolations(root) {
  const files = collectFiles(root);
  const violations = [];
  for (const f of files) {
    for (const hit of scanText(fs.readFileSync(f.abs, "utf8"))) {
      violations.push({ file: f.rel, ...hit });
    }
  }
  return { files: files.length, violations };
}

function main(argv) {
  let root = SELF_ROOT;
  let quiet = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--root") {
      const v = argv[++i];
      if (!v) {
        console.error("check-skill-mutation-restore: --root requires a directory");
        return 2;
      }
      root = path.resolve(v);
    } else if (a === "--quiet") {
      quiet = true;
    } else if (a === "--help" || a === "-h") {
      console.log("usage: node scripts/check-skill-mutation-restore.mjs [--root <dir>] [--quiet]");
      return 0;
    } else {
      console.error(`check-skill-mutation-restore: unknown argument: ${a}`);
      return 2;
    }
  }
  if (!fs.existsSync(root)) {
    console.error(`check-skill-mutation-restore: root not found: ${root}`);
    return 2;
  }

  const { files, violations } = findViolations(root);

  if (violations.length === 0) {
    if (!quiet) {
      console.log(
        `✅ check-skill-mutation-restore: 0 violations — ${files} agent-facing file(s) scanned ` +
          "(no working-tree discard prescribed as a post-mutation restore)"
      );
    }
    return 0;
  }

  for (const v of violations) {
    const tail = v.emptyPragma
      ? "the `mutation-restore-ok` pragma has an empty reason — a reason is required"
      : "use the cp-backup restore (AGENTS.md Mutation-Testing Restore Protocol), " +
        "or add <!-- mutation-restore-ok: <reason> --> if the line must name the forbidden form";
    console.error(
      `::error file=${v.file},line=${v.line}::working-tree discard \`${v.command}\` in a ` +
        `mutation/negative-test context — ${tail}`
    );
  }
  console.error(
    `❌ check-skill-mutation-restore: ${violations.length} violation(s) in ` +
      `${new Set(violations.map((v) => v.file)).size} file(s) — a working-tree discard reverts to ` +
      "HEAD and silently destroys uncommitted work (#664)"
  );
  return 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv.slice(2)));
}
