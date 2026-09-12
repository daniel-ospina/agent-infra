#!/usr/bin/env node
// #755 tripwire — zero-dependency, plain `node`, auto-picked by ci-main.yml's
// `extensions/*/test*.mjs` glob and wired into ci.yml's `verify` job.
//
// ⛔ It cannot EVALUATE TypeScript (no tsx, no types in this job), so every
// check is a regex/source-string extraction. That is deliberate: the defects
// this guards against are *textual drift*, and the checks are chosen so that
// each one would have caught a real cycle-7..12 defect.
//
// What it guards, and its honest limits:
//   • the deleted-symbol class (a rename guard)
//   • the "one statement per mechanism" property for the two highest-traffic
//     restatements (the seam signature, the reason vocabulary)
//   • the two anchors the rule's safety depends on (`:2204`, the push/commit
//     discrimination at the scope-resolution site)
// It does NOT prove the rule is correct — the test suites do that.

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..");

let failed = 0;
function check(label, ok, detail = "") {
  if (ok) {
    console.log(`  ✅ ${label}`);
  } else {
    failed++;
    console.log(`  ❌ ${label}${detail ? `\n     ${detail}` : ""}`);
  }
}
function read(p) {
  return existsSync(p) ? readFileSync(p, "utf8") : null;
}

console.log("#755 merge-scope tripwire\n");

// ── 1. Deleted/renamed symbols must not reappear in the source tree ──
// Scope: extensions/verification-gate/ ONLY. (An earlier version scoped this to
// the plan doc and was red at its own commit — the plan legitimately *names*
// these symbols in deletion notes.) All three are pre-existing zero here, so
// this is a re-introduction guard.
const FORBIDDEN = ["subtractFromScope", "baseEntryMode", "armKind"];
// NOTE: this file is excluded from its own scan — its FORBIDDEN array must
// name the symbols it forbids, which otherwise makes the check red at its own
// commit (the cycle-9/11/12 defect class, one level up).
const srcFiles = readdirSync(HERE).filter(
  (f) => (f.endsWith(".ts") || f.endsWith(".mjs")) && f !== basename(fileURLToPath(import.meta.url))
);
for (const sym of FORBIDDEN) {
  const hits = [];
  for (const f of srcFiles) {
    const body = read(join(HERE, f)) ?? "";
    // Ignore comment lines that document the deletion by name.
    const live = body.split("\n").filter((l) => l.includes(sym) && !/^\s*(\/\/|\*|\/\*)/.test(l));
    if (live.length > 0) hits.push(`${f}: ${live.length} live occurrence(s)`);
  }
  check(`deleted symbol "${sym}" does not reappear in extensions/verification-gate/`, hits.length === 0, hits.join("; "));
}

// ── 2. The seam: exactly ONE stated makeGitSubCtx argument form ──
// Scoped OUTSIDE the plan's Cycle Log (the log quotes historical forms).
const planPath = join(REPO, "docs", "plans", "2026-09-11-755-vgate-merge-scope.md");
const plan = read(planPath);
if (plan === null) {
  check("plan doc present", false, planPath);
} else {
  const cut = plan.indexOf("## Plan Review Cycle Log");
  const normative = cut === -1 ? plan : plan.slice(0, cut);
  const keySets = new Set();
  const re = /makeGitSubCtx\(\s*(cwd\s*,\s*\{[^}]*\})/gs;
  let m;
  while ((m = re.exec(normative)) !== null) {
    const keys = [...m[1].matchAll(/([A-Za-z_][A-Za-z0-9_]*)\s*[?:]?\s*[:,}]/g)]
      .map((k) => k[1])
      .filter((k) => k !== "cwd")
      .sort()
      .join(",");
    keySets.add(keys);
  }
  check(
    `the plan states exactly ONE makeGitSubCtx argument-object shape (found ${keySets.size})`,
    keySets.size <= 1,
    [...keySets].join(" | ")
  );
}

// ── 3. The reason vocabulary: no duplicate literal anywhere ──
const index = read(join(HERE, "index.ts")) ?? "";
const vocabStart = index.indexOf("const GATE_SKIP_REASONS = [");
if (vocabStart === -1) {
  check("GATE_SKIP_REASONS declared in index.ts", false);
} else {
  const block = index.slice(vocabStart, index.indexOf("] as const;", vocabStart));
  const literals = [...block.matchAll(/"([a-z_]+)"/g)].map((x) => x[1]);
  const dupes = literals.filter((l, i) => literals.indexOf(l) !== i);
  check(
    "GATE_SKIP_REASONS lists no reason literal twice (a duplicate is the cycle-7/9 defect class)",
    dupes.length === 0,
    dupes.join(",")
  );
}

const merge = read(join(HERE, "subtract-scope.ts")) ?? "";
const subStart = merge.indexOf("export const SUBTRACT_SKIP_REASONS = [");
if (subStart === -1) {
  check("SUBTRACT_SKIP_REASONS declared in subtract-scope.ts", false);
} else {
  const block = merge.slice(subStart, merge.indexOf("] as const;", subStart));
  const literals = [...block.matchAll(/"([a-z_]+)"/g)].map((x) => x[1]);
  check(
    "SUBTRACT_SKIP_REASONS has two distinct members and no duplicate",
    literals.length === 2 && new Set(literals).size === 2,
    literals.join(",")
  );
  check(
    "the kill-switch reason is owned by SUBTRACT_SKIP_REASONS (single source of truth)",
    literals.includes("subtract_disabled_by_env"),
    literals.join(",")
  );
}

// ── 4. The two safety anchors ──
// (a) `:2204`'s `tracking` is ALSO the tier input; the fix must not touch it.
check(
  "index.ts still derives `tracking` from `dst` (the tier input is byte-identical)",
  /const tracking = `refs\/remotes\/\$\{remote\}\/\$\{dst\}`;/.test(index)
);
// (b) The scope-resolution site must discriminate push from commit — a bare
// `git commit` falls through the SAME `??` as the tier-C push fallback, so
// passing one bundle to both silently disables the commit leg (e2e scenario 77).
check(
  "the scope-resolution site discriminates the push attempt from the commit fallback",
  /parsePushRefSpecs\(command\)\.eligible/.test(index) &&
    /resolvePushRangeScope\(command, cwd, pushAttempt \? sub : null\)/.test(index)
);
// (c) The emit site must not be anchored inside the push branch.
check(
  "the subtraction audit is emitted outside the push branch",
  /if \(scope\.subtractions !== undefined && scope\.subtractions\.length > 0\)/.test(index)
);

// ── 5. SDK-freeness of the new module and its suite ──
// subtract-scope.ts may import ./index.js as a TYPE only; index.ts:2 is a value
// import of the pi SDK, so a value import would break the zero-dep verify job.
for (const f of ["subtract-scope.ts", "subtract-scope.test.ts"]) {
  const body = read(join(HERE, f));
  if (body === null) {
    check(`${f} present`, false);
    continue;
  }
  check(
    `${f} imports ./index.js as a TYPE only`,
    !/^import\s+\{[^}]*\}\s+from\s+"\.\/index\.js"/m.test(body)
  );
  check(`${f} declares no local DiffScope`, !/interface DiffScope|type DiffScope\s*=/.test(body));
}
check(
  "subtract-scope.ts does not import the pi SDK",
  !(read(join(HERE, "subtract-scope.ts")) ?? "").includes("@earendil-works/pi-coding-agent")
);

console.log(failed === 0 ? "\n✅ #755 tripwire: all checks passed" : `\n❌ #755 tripwire: ${failed} check(s) failed`);
process.exit(failed === 0 ? 0 : 1);
