#!/usr/bin/env node
// tests/search-cost/scan.mjs — the classifier-driven corpus scan for #1069.
//
// Extracts every command from the fenced code blocks of the given roots and
// classifies it through the REAL extensions/search-guard/index.ts (loaded with
// the #744 module-load hooks, never a copy).
//
// Why the scan is classifier-driven rather than a regex over `grep -r`: a regex
// is evadable by flag ordering (`grep -nr`, `grep -ir`) and cannot see that the
// section it enforces is itself a taught command. Driving it through the
// classifier makes the harness and the guard the same contract.
//
// Rules (see docs/plans/2026-09-15-issue-1069-search-cost.md §14):
//   (ii)  a command that classifies non-null is a violation — EXCEPT inside the
//         `## Search` → `### Avoid` subsection, where non-null is REQUIRED.
//   (iii) every `### Use` command must classify null; every `### Avoid` command
//         must classify non-null. A subsection with zero commands fails
//         non-vacuity, so rewriting either into prose cannot disarm the pin.
//         Asserted only under `--require-anchors` (the corpus invocation).
//   (iv)  the classifier must not be a constant (`null` for everything) — same
//         scoping: a scoped fixture has no anchors, so the rule is meaningless
//         there and enforcing it makes every exit code 1 regardless of content.
//   (v)   `## Search` must be present in both AGENTS files.
//
// Fence shapes handled: tagged and untagged openers, indented fences (up to 4
// leading spaces — `skills/commit-workflow/workflow/04-merge-deploy.md`), and
// openers preceded by any number of `> ` blockquote markers
// (`skills/carousel-b2b-design/SKILL.md`, `skills/reviewers/duplication-architecture/SKILL.md`).
//
// Usage: node tests/search-cost/scan.mjs <path…> --cwd <fixture> [--require-anchors]
//   --require-anchors  assert the (iii)/(iv) non-vacuity rules — the CORPUS
//                      invocation's contract (AGENTS.md carries `## Search` →
//                      `### Use`/`### Avoid`). A scoped fixture has no anchors by
//                      construction, and enforcing (iii)/(iv) there made the exit
//                      code say nothing about the file under test: an INNOCUOUS
//                      fixture also exited 1 (only the non-vacuity rules fired),
//                      so run.sh's exit-code checks passed for the wrong reason.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { register, registerHooks } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(fileURLToPath(new URL(".", import.meta.url)), "../..");
const argv = process.argv.slice(2);
const FLAGS = new Set(["--require-anchors"]);
const cwdAt = argv.indexOf("--cwd");
// `--cwd` may appear anywhere — including FIRST — and may be absent entirely. The
// pre-fix `cwdAt > 0` silently fell back to ROOT when `--cwd` headed the argv, and
// with no `--cwd` at all (`cwdAt === -1`) the target filter `i !== cwdAt + 1`
// dropped argv[0], so `scan.mjs skills` scanned nothing.
const CWD = cwdAt === -1 ? ROOT : argv[cwdAt + 1] ?? ROOT;
const REQUIRED_ANCHORS = argv.includes("--require-anchors");
const TARGETS = argv.filter(
  (a, i) => !FLAGS.has(a) && (cwdAt === -1 || (i !== cwdAt && i !== cwdAt + 1)),
);

const hooks = await import(
  new URL("../../extensions/main-worktree-guard/module-load-hooks.mjs", import.meta.url).href
);
if (typeof registerHooks === "function") {
  registerHooks({ resolve: hooks.resolve, load: hooks.load });
} else {
  register(new URL("../../extensions/main-worktree-guard/module-load-hooks.mjs", import.meta.url), import.meta.url);
}
const mod = await import(pathToFileURL(join(ROOT, "extensions/search-guard/index.ts")).href);
const classify = mod.classifySearchCommand;

// ── collect the scan set ───────────────────────────────────────────────────
function walk(target) {
  const abs = resolve(ROOT, target);
  if (!existsSync(abs)) return [];
  if (statSync(abs).isFile()) return [abs];
  const out = [];
  for (const entry of readdirSync(abs, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
    const child = join(abs, entry.name);
    out.push(...(entry.isDirectory() ? walk(relative(ROOT, child)) : child.endsWith(".md") ? [child] : []));
  }
  return out;
}
const FILES = TARGETS.flatMap(walk).sort();
if (!FILES.length) {
  console.error("scan: no markdown files found for", TARGETS.join(" "));
  process.exit(2);
}

/** Strip an optional ≤4-space indent and any `> ` blockquote markers. */
function stripDecoration(line) {
  let out = line.replace(/^ {0,4}/, "");
  while (out.startsWith("> ")) out = out.slice(2);
  return out;
}

/**
 * Extract commands per file, tagging each with the enclosing `## Search`
 * subsection (or null when the command is outside that section).
 */
function extract(file) {
  const lines = readFileSync(file, "utf8").split("\n");
  const found = [];
  let fence = false;
  let section = null; // last `## ` heading
  let subsection = null; // last `### ` heading
  for (const raw of lines) {
    const line = stripDecoration(raw);
    const m = line.match(/^(`{3,})(.*)$/);
    if (m) {
      fence = !fence;
      continue;
    }
    if (!fence) {
      const h2 = line.match(/^## +(.+?)\s*$/);
      if (h2) {
        section = h2[1];
        subsection = null;
        continue;
      }
      const h3 = line.match(/^### +(.+?)\s*$/);
      if (h3) {
        subsection = h3[1];
        continue;
      }
      continue;
    }
    const cmd = line.trim();
    if (!cmd || cmd.startsWith("#")) continue;
    found.push({
      file: relative(ROOT, file),
      cmd,
      where: section === "Search" ? subsection : null,
    });
  }
  return found;
}

const ALL = FILES.flatMap(extract);
const inUse = ALL.filter((c) => c.where === "Use");
const inAvoid = ALL.filter((c) => c.where === "Avoid");
const violations = [];

for (const c of ALL) {
  const verdict = classify(c.cmd, CWD, () => {});
  if (c.where === "Avoid") {
    if (!verdict) violations.push(`(iii) ### Avoid command is ALLOWED: \`${c.cmd}\` (${c.file})`);
    continue;
  }
  if (verdict) {
    violations.push(`(ii) taught command is REFUSED: \`${c.cmd}\` (${c.file}) — ${verdict.reason.split("\n")[0]}`);
  }
}

// (iii)/(iv) non-vacuity — the corpus contract, asserted only for the invocation
// that actually carries the anchors (see --require-anchors in the usage note).
if (REQUIRED_ANCHORS) {
  if (inUse.length === 0) violations.push("(iii) ### Use yielded zero commands — the pin would be vacuous");
  if (inAvoid.length === 0) violations.push("(iii) ### Avoid yielded zero commands — the pin would be vacuous");
  const blocks = [...inUse, ...inAvoid].filter((c) => classify(c.cmd, CWD, () => {}) !== null);
  if (blocks.length === 0) violations.push("(iv) the classifier returns null for every declared-shape command — vacuous");
}

console.log(`   scanned ${ALL.length} commands in ${FILES.length} files (Use=${inUse.length}, Avoid=${inAvoid.length})`);
if (violations.length) {
  for (const v of violations.slice(0, 40)) console.error(`   ${v}`);
  if (violations.length > 40) console.error(`   … and ${violations.length - 40} more`);
  process.exit(1);
}
process.exit(0);
