/**
 * module-load-hooks.mjs — load the real `index.ts` extension in a plain
 * `node <file>.mjs` test (zero deps, no tsx).
 *
 * Mirrors `extensions/main-worktree-guard/module-load-hooks.mjs`: TypeScript
 * types are stripped in-process (`node:module.stripTypeScriptTypes`), so the
 * source under test is the real extension, not a copy. `index.ts` imports the
 * pi package as a TYPE only (`import type { ExtensionAPI }`), which type
 * stripping erases — so no pi stub is needed.
 */

import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { fileURLToPath } from "node:url";

/**
 * Resolve `.ts`/`.js` specifiers the TS sources use.
 *
 * NOTE: both hooks are SYNCHRONOUS. `module.registerHooks()` runs hooks
 * in-thread and requires a synchronous return value; an `async` hook returns a
 * Promise, which Node rejects with
 * `ERR_INVALID_RETURN_PROPERTY_VALUE ... "shortCircuit"`.
 */
export function resolve(specifier, context, nextResolve) {
  if (specifier.startsWith(".") && !/\.[cm]?[jt]s$/.test(specifier)) {
    const base = new URL(specifier, context.parentURL);
    for (const ext of [".ts", ".mjs", ".js"]) {
      try {
        const candidate = new URL(base.href + ext);
        if (readFileSync(fileURLToPath(candidate), "utf8")) {
          return { url: candidate.href, shortCircuit: true };
        }
      } catch {
        /* try the next extension */
      }
    }
  }
  return nextResolve(specifier, context);
}

/** Strip types on load so `import("./index.ts")` works without a transpiler. */
export function load(url, context, nextLoad) {
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
