/**
 * module-load-hooks.mjs — Node module-customization hooks that make
 * `extensions/main-worktree-guard/index.ts` importable from a test with ZERO
 * dependencies (no node_modules, no tsx, no jiti).
 *
 * Why this exists (#744): `test.mjs` imports `classify-git.mjs` directly, so it
 * stays green even when `index.ts` itself is broken (a 2026-09-10 regression
 * shipped an undeclared rename-destructuring target; ESM strict mode threw
 * ReferenceError inside the module's load try/catch and every session silently
 * ran the degraded legacy path). The only way to regress-test that is to load
 * the REAL module through a loader. pi loads extensions with jiti, which is
 * bundled inside @earendil-works/pi-coding-agent — not resolvable from this
 * repo (CI has no node_modules). These hooks reproduce the same surface:
 *
 *   1. `.ts` files are loaded as ESM with types stripped
 *      (`module.stripTypeScriptTypes`, Node >= 22.13). pi's jiti does the
 *      equivalent transform, including the `.js` → `.ts` mapping below.
 *   2. `@earendil-works/pi-coding-agent` is aliased to a minimal stub exporting
 *      the runtime value index.ts actually imports (`isToolCallEventType`);
 *      `ExtensionAPI` is a type-only import and is erased by the strip.
 *
 * The transform is deliberately the REAL module source — not a copy — so a
 * scope/level error in the shipped file is caught here.
 *
 * Used by: test-module-load.mjs — it imports resolve/load and installs them
 * with module.registerHooks() (in-thread, Node >= 22.15), falling back to
 * register("./module-load-hooks.mjs", ...) on 22.13/22.14.
 */
import { stripTypeScriptTypes } from "node:module";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** Virtual URL for the stubbed pi package (never a real file). */
const PI_PACKAGE_STUB = "pi-coding-agent-stub:";

/** Bare specifiers index.ts may import from the pi runtime. */
const PI_PACKAGE_SPECIFIERS = new Set([
  "@earendil-works/pi-coding-agent",
  "@mariozechner/pi-coding-agent",
]);

/** The runtime value surface index.ts imports from the pi package. */
const PI_STUB_SOURCE = `
export function isToolCallEventType(toolName, event) {
  return event.toolName === toolName;
}
export default {};
`;

/**
 * Resolve hook: stub the pi package; map a relative `./x.js` specifier onto the
 * sibling `x.ts` when the `.js` does not exist (repo convention: TS sources
 * import each other with `.js` ESM specifiers — pi's jiti resolves these
 * identically).
 */
export function resolve(specifier, context, nextResolve) {
  if (PI_PACKAGE_SPECIFIERS.has(specifier)) {
    return { url: PI_PACKAGE_STUB, shortCircuit: true, format: "module" };
  }
  if (specifier.startsWith(".") && specifier.endsWith(".js") && context.parentURL?.startsWith("file:")) {
    const jsUrl = new URL(specifier, context.parentURL);
    const tsUrl = new URL(jsUrl.href.replace(/\.js$/, ".ts"));
    if (jsUrl.protocol === "file:" && !existsSync(fileURLToPath(jsUrl)) && existsSync(fileURLToPath(tsUrl))) {
      return { url: tsUrl.href, shortCircuit: true, format: "module" };
    }
  }
  return nextResolve(specifier, context);
}

/**
 * Load hook: serve the pi stub; type-strip every `.ts` module as ESM.
 */
export function load(url, context, nextLoad) {
  if (url === PI_PACKAGE_STUB) {
    return { format: "module", shortCircuit: true, source: PI_STUB_SOURCE };
  }
  if (url.startsWith("file:") && url.endsWith(".ts") && !url.endsWith(".d.ts")) {
    return {
      format: "module",
      shortCircuit: true,
      source: stripTypeScriptTypes(readFileSync(fileURLToPath(url), "utf8"), {
        mode: "strip",
        sourceUrl: url,
      }),
    };
  }
  return nextLoad(url, context);
}
