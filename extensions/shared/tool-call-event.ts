/**
 * shared/tool-call-event.ts — THE single home for the inlined copy of pi's
 * `isToolCallEventType` (#1330).
 *
 * ── WHY A COPY EXISTS AT ALL ────────────────────────────────────────────────
 * The extensions that need this predicate (skill-enforcer, sequence-enforcer)
 * have ZERO-DEPENDENCY gate suites: `ci.yml`'s `verify` job runs them with no
 * `npm ci`, so `import { isToolCallEventType } from "@earendil-works/pi-coding-
 * agent"` is unavailable in the module under test. pi's loader resolves the
 * package from its own bundled module table at runtime, but the suite loads the
 * module directly, so the value import had to be replaced by a copy.
 *
 * ── THE FAILURE MODE THIS FILE IS WRITTEN AGAINST (#1330) ───────────────────
 * A copy of an SDK predicate drifts silently under an upgrade: if pi moves the
 * tool name (nested, renamed, wrapped), the copy returns `false` for EVERY
 * event, the block branches are never reached, and the extension keeps printing
 * `✅ Loaded — enforcing N skill gates` — an inert enforcer reporting success.
 * So the copy is not allowed to be a private detail of whichever file needed it
 * first: it is ONE exported function, and it is PINNED against the real export
 * by `extensions/verification-gate/tool-call-event-parity.test.ts`, which runs
 * with the pi
 * package installed (see that file's header for why the pin is SDK-bearing).
 *
 * ── THE PINNED UPSTREAM SOURCE ─────────────────────────────────────────────
 *   @earendil-works/pi-coding-agent 0.85.1
 *   dist/core/extensions/types.js:45-47
 *     export function isToolCallEventType(toolName, event) {
 *         return event.toolName === toolName;
 *     }
 *   (d.ts overloads narrow per built-in tool name; the runtime body is the
 *   single line above.)
 *
 * The body below is upstream's, EXACTLY — including its behaviour on a
 * `null`/`undefined` event (a TypeError, not `false`). The earlier private
 * copies were written as `event?.toolName === toolName`, which is NOT what
 * upstream does: it swallowed the malformed-event case where upstream throws.
 * That was an unintentional divergence found while building this pin, and it is
 * why the parity suite compares thrown-ness as well as return values. Do not
 * re-add the optional chain here — add tolerance upstream first, or the pin is
 * asserting something the SDK does not do.
 *
 * Consumers import this with an ESM `.js` specifier (repo convention; pi's jiti
 * and tsx both resolve it to this `.ts`):
 *   import { isToolCallEventType } from "./shared/tool-call-event.js";   // flat extension
 *   import { isToolCallEventType } from "../shared/tool-call-event.js";  // dir extension
 */
export function isToolCallEventType(toolName: string, event: unknown): boolean {
  return (event as { toolName?: unknown }).toolName === toolName;
}
