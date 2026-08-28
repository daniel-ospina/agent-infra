#!/usr/bin/env node
/**
 * check-staged-skill-frontmatter.mjs — authoring-time pre-commit hook (#254,
 * Task 0). Prevents the #242 incident class at the source: an author commits
 * a SKILL.md whose frontmatter pi's loader REJECTS (or whose description is
 * missing/empty) — CI is green because the linter used a different grammar,
 * and the skill silently dies in pi.
 *
 * For every staged SKILL.md file: import pi's REAL bundle (same resolution as
 * the oracle/probe), run parseFrontmatter (throws on parse-class frontmatter
 * errors), apply pi's hasDescription gate verbatim (`typeof description ===
 * "string" && description.trim() !== ""` — skills.js:232), and flag a leading
 * U+FEFF (D11). Exit 1 on any throw/drop with a clear message.
 *
 * Verdict scope (stated explicitly): the hook gates only throw/drop-via-
 * description classes + BOM. The truncate P1 class (` #`), name-gate classes
 * (R2), and the other validator rules are CI's job — a hook pass is NOT a CI
 * pass.
 *
 * Skips cleanly with a visible SKIP if pi is not installed (a missing local
 * pi must not block commits). Dev-machine only; the CI gate remains the
 * dep-free validator (scripts/frontmatter-validate.mjs).
 *
 * Dep-free (O/I 3); pi optional (dev machines with pi installed).
 */

import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { resolvePiBundle } from "./probe-frontmatter-fixtures.mjs";

let staged = [];
try {
  staged = execFileSync("git", ["diff", "--cached", "--name-only", "--diff-filter=ACM"], {
    encoding: "utf8",
  })
    .split("\n")
    .filter((f) => f.endsWith("SKILL.md"));
} catch {
  console.log("[skill-fm-hook] not a git checkout — SKIP");
  process.exit(0);
}

if (staged.length === 0) {
  process.exit(0); // nothing staged — nothing to check
}

let pi;
try {
  pi = await import(resolvePiBundle());
} catch {
  console.log(`[skill-fm-hook] pi not installed — SKIP (${staged.length} staged SKILL.md unverified)`);
  process.exit(0);
}

const failures = [];
for (const file of staged) {
  let content;
  try {
    content = fs.readFileSync(file, "utf8");
  } catch {
    continue;
  }
  const bom = content.charCodeAt(0) === 0xfeff;
  let frontmatter = null;
  let parseErr = null;
  try {
    ({ frontmatter } = pi.parseFrontmatter(content));
  } catch (e) {
    parseErr = e.message.split("\n")[0];
  }
  const description = frontmatter && typeof frontmatter === "object" ? frontmatter.description : undefined;
  const hasDescription = typeof description === "string" && description.trim() !== "";
  if (parseErr) {
    failures.push(`⛔ ${file}: pi rejects the frontmatter — ${parseErr}`);
  }
  if (!parseErr && !hasDescription) {
    failures.push(`⛔ ${file}: missing/empty description — pi will DROP this skill (quote your description)`);
  }
  if (bom) {
    failures.push(`⛔ ${file}: starts with a UTF-8 BOM (U+FEFF) — save without BOM`);
  }
}

if (failures.length > 0) {
  console.error("[skill-fm-hook] staged SKILL.md frontmatter will break the skill in pi:");
  for (const f of failures) console.error(f);
  console.error("[skill-fm-hook] fix the frontmatter (quote descriptions with colons; save without BOM) and re-stage.");
  process.exit(1);
}

console.log(`[skill-fm-hook] OK — ${staged.length} staged SKILL.md pass pi's loader (throws/drop/BOM)`);
