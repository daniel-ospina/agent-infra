/**
 * default-coverage.test.ts — per-PR drift pin for the SHIPPED fleet default (#715)
 *
 * The silent-failure mode this guards: a shipped `defaultModel` that the
 * failover family table does not know (`familyOf()` → undefined) silently
 * disables the whole #476 deepseek→qwen-tp→openrouter hop chain — no
 * pre-dispatch hop, no activeLeg advance, no interactive hop/restore — with no
 * error anywhere. Exactly what happened when DeepSeek renamed the flash id to
 * the canonical `deepseek-flash` while the table only knew the legacy spelling.
 *
 * Asserts:
 *   - the SHIPPED `pi-bootstrap/pi-config/settings.json` defaultProvider +
 *     defaultModel resolve to an alias family, and the default IS that
 *     family's ROOT leg model (not a hop) — the "default is the root" invariant;
 *   - both SHIPPED agent frontmatters' `model:` values resolve to a family
 *     whose root leg they name;
 *   - the negative-variant set stays family-less (no silent substitution);
 *   - non-vacuity: the family table has ≥2 families, the shipped models.json
 *     provider block registers the default id, and a non-zero number of
 *     positive assertions ran (so a silently-empty parse cannot pass).
 *
 * ZERO-DEPENDENCY IMPORT CONTRACT: the import list below is `node:*` +
 * `./provider-failover.js` only. provider-failover.ts imports only `node:`
 * modules, so this suite runs under `npx tsx` with NO `npm ci` — required
 * because the per-PR `verify` job in .github/workflows/ci.yml runs it without
 * installing node_modules. Do NOT import `resolveProviderModel` here: it lives
 * in extensions/builtin-tools/index.ts and pulls `@sinclair/typebox`. Provider
 * membership is asserted with `legIsFamilyMember` instead.
 *
 * WIRING HONESTY: this suite is run by the per-PR `verify` job, where it is
 * VISIBLE but NOT merge-blocking (the repo's only required status check is
 * `pipeline-compliance`). The blocking backstop is the post-merge
 * ci-main.yml `extensions/shared/*.test.ts` glob.
 *
 * Run: npx tsx extensions/shared/default-coverage.test.ts
 */

import {
  ALIAS_FAMILIES,
  familyOf,
  familyLegs,
  legIsFamilyMember,
} from "./provider-failover.js";

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { ok, equal } from "node:assert/strict";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../..");
const PI_CONFIG = path.join(REPO_ROOT, "pi-bootstrap", "pi-config");

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}\n${err.stack?.split("\n").slice(0, 4).join("\n")}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

/** Count of positive (root-matching) assertions actually executed — the
 * non-vacuity guard: 0 means the parse silently yielded nothing. */
let positiveChecks = 0;

function frontmatterModel(file: string): string {
  const body = fs.readFileSync(file, "utf-8");
  const m = body.match(/^model:\s*(\S+)\s*$/m);
  if (!m) throw new Error(`no 'model:' frontmatter line in ${file}`);
  return m[1];
}

/** Assert that `modelId` is a family root and, when `provider` is known, that
 * the provider is a member of that family. Returns the family key. */
function assertRootCovered(label: string, modelId: string, provider?: string): string {
  const fam = familyOf(modelId, provider);
  ok(fam !== undefined, `${label}: familyOf(${JSON.stringify(modelId)}${provider ? `, ${JSON.stringify(provider)}` : ""}) must resolve to a family — a family-less default silently disables the #476 hop chain`);
  const root = familyLegs(fam!)?.[0];
  ok(root !== undefined, `${label}: family ${fam} must have a root leg`);
  equal(modelId, root!.model, `${label}: the default must BE the family root leg model (not a hop)`);
  if (provider !== undefined) {
    ok(legIsFamilyMember(fam!, provider), `${label}: provider ${provider} must be a member of family ${fam}`);
  }
  positiveChecks++;
  return fam!;
}

section("shipped default coverage (#715 drift pin)");

test("non-vacuity: family table is populated and the shipped default id is registered", () => {
  // ≥2 families so an empty/renamed table cannot pass silently.
  ok(
    Object.keys(ALIAS_FAMILIES).length >= 2,
    `ALIAS_FAMILIES has ${Object.keys(ALIAS_FAMILIES).length} keys (< 2) — the table was emptied or renamed`,
  );
  const settings = JSON.parse(fs.readFileSync(path.join(PI_CONFIG, "settings.json"), "utf-8"));
  ok(typeof settings.defaultProvider === "string" && settings.defaultProvider.length > 0, "settings.json must carry defaultProvider");
  ok(typeof settings.defaultModel === "string" && settings.defaultModel.length > 0, "settings.json must carry defaultModel");
  // The shipped models.json provider block must register the default id — an
  // id the catalog doesn't know cannot be dispatched at all.
  const models = JSON.parse(fs.readFileSync(path.join(PI_CONFIG, "models.json"), "utf-8"));
  const prov = models.providers?.[settings.defaultProvider];
  ok(prov !== undefined, `models.json has no provider block for ${settings.defaultProvider}`);
  const ids: string[] = (prov.models ?? []).map((m: any) => m.id);
  ok(ids.includes(settings.defaultModel), `models.json ${settings.defaultProvider} block does not register ${settings.defaultModel} (has: ${ids.join(", ")})`);
});

test("shipped settings.json default resolves to a family ROOT (and is not a hop)", () => {
  const settings = JSON.parse(fs.readFileSync(path.join(PI_CONFIG, "settings.json"), "utf-8"));
  const fam = assertRootCovered("settings.json", settings.defaultModel, settings.defaultProvider);
  // The root leg's provider must be the shipped defaultProvider too.
  equal(familyLegs(fam)![0].provider, settings.defaultProvider, "family root leg provider must equal settings.defaultProvider");
  // The shipped default provider is a member of the default's family.
  ok(legIsFamilyMember(fam, settings.defaultProvider), `legIsFamilyMember(${fam}, ${settings.defaultProvider}) must be true`);
  ok(positiveChecks > 0, "non-vacuity: at least one positive root check must have run");
});

test("both shipped agent frontmatters resolve to a family ROOT", () => {
  const agents = ["agents/code-reviewer.md", "agents/bug-scanner.md"];
  for (const rel of agents) {
    const file = path.join(PI_CONFIG, rel);
    const model = frontmatterModel(file);
    assertRootCovered(rel, model);
    // Cross-check: an agent frontmatter may NOT name a hop leg.
    const fam = familyOf(model)!;
    const hopModels = familyLegs(fam)!.slice(1).map((l) => l.model);
    ok(!hopModels.includes(model), `${rel}: ${model} is a hop leg, not a family root`);
  }
  ok(positiveChecks >= agents.length, "non-vacuity: both agent frontmatters were checked");
});

section("negative set — variants stay family-less (no silent substitution)");

test("must-not-map ids remain undefined", () => {
  const negatives = [
    "deepseek-v4-flash-vision-exp",
    "deepseek-v4-pro-0813",
    "deepseek-flash:batch",
    "deepseek-v4.1-flash",
    "deepseek/deepseek-flash",
    "glm-5.2",
  ];
  for (const id of negatives) {
    equal(familyOf(id), undefined, `${id} must NOT resolve to a family (silent-substitution hazard, review R4 P2)`);
    equal(familyOf(id, "openrouter"), undefined, `${id} @openrouter must NOT resolve to a family`);
  }
  // The dotted canonical id has no upstream existence — also family-less.
  equal(familyOf("deepseek/deepseek-flash", "deepseek"), undefined);
});

section("Results");

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
