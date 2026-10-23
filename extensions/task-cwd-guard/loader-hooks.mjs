/**
 * loader-hooks.mjs — Node module-customization hooks that make
 * `extensions/task-cwd-guard/index.ts` importable from a zero-dependency test.
 *
 * Mirrors `extensions/main-worktree-guard/module-load-hooks.mjs` (#744): pi loads
 * extensions with jiti (bundled inside @earendil-works/pi-coding-agent, not
 * resolvable from this repo's CI), so the test reproduces the surface it needs:
 *
 *   1. `.ts` files load as ESM with types stripped (node:module
 *      stripTypeScriptTypes, Node >= 22.13).
 *   2. `@earendil-works/pi-coding-agent` is aliased to a minimal stub that
 *      RE-EXPORTS the repo's one shared predicate copy
 *      (`../shared/tool-call-event.ts`); the `ExtensionAPI` import is type-only
 *      and erased by the strip.
 *
 * #1330 — the stub used to carry its own copy of the predicate body, which made
 * this file a second un-pinned copy of an SDK function (the very defect #1330
 * exists to close). It now re-exports `shared/tool-call-event.ts`, so this
 * suite exercises the copy that the SDK-bearing parity pin asserts against the
 * real pi export.
 *
 * Deliberately a SEPARATE FILE rather than a cross-extension import: the sibling
 * hook lives under `extensions/main-worktree-guard/`, a directory under active
 * edit (open PR #1153), and a test must not break when a foreign lane moves it.
 * The PREDICATE, however, is single-homed by #1330 — both hooks re-export
 * `extensions/shared/tool-call-event.ts` rather than each carrying their own
 * copy, so the SDK-bearing parity pin covers whichever hook a test loads.
 */

import { stripTypeScriptTypes } from "node:module";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** Virtual URL for the stubbed pi package (never a real file). */
const PI_PACKAGE_STUB = "pi-coding-agent-stub:";

const PI_PACKAGE_SPECIFIERS = new Set([
  "@earendil-works/pi-coding-agent",
  "@mariozechner/pi-coding-agent",
]);

/** The repo's ONE predicate copy — the same module production imports (#1330). */
const SHARED_PREDICATE_URL = new URL("../shared/tool-call-event.ts", import.meta.url).href;

const PI_STUB_SOURCE = `
export { isToolCallEventType } from ${JSON.stringify(SHARED_PREDICATE_URL)};
export default {};
`;

/** Resolve hook: stub the pi package; map `./x.js` onto sibling `x.ts`. */
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

/** Load hook: serve the pi stub; type-strip every `.ts` module as ESM. */
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
