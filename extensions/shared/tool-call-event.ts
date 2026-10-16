/**
 * tool-call-event.ts — THE single copy of pi's `isToolCallEventType` predicate
 * for the extensions whose gate suites run on a bare checkout (#1330).
 *
 * WHY THIS EXISTS. `extensions/skill-enforcer.ts` and
 * `extensions/sequence-enforcer/index.ts` run their suites in CI's `verify` job,
 * which performs no `npm ci`, so they cannot value-import the pi SDK at runtime.
 * pi's export is one line, so it used to be inlined in each file. TWO copies
 * drift independently, and a copy whose shape stops matching silently makes
 * every gate a no-op while the extension still reports `✅ Loaded — enforcing N
 * skill gates` — the inert-enforcer class (category A, #1330). One copy means
 * one place to fix and the pins below all point at it.
 *
 * THE PIN. Verified against pi 0.85.1 internals (Q1):
 *   dist/core/extensions/types.js:45  export function isToolCallEventType(toolName, event) {
 *   dist/core/extensions/types.js:46      return event.toolName === toolName;
 *   dist/core/extensions/types.js:47  }
 * The `pi 0.85.1` above is a mirror version stamp: scripts/check-pi-pin-lockstep.mjs
 * guard (i) fails on any bump of PI_VERSION_PIN that leaves it stale, so the
 * predicate can never be carried across a pi upgrade without a deliberate
 * re-verification. The behavioural half of the pin is the SDK parity assertion
 * in extensions/verification-gate/index.test.ts — the shared function and the
 * installed SDK's real export must agree on the whole event matrix.
 *
 * NULL-SAFETY IS DELIBERATE, NOT DRIFT. pi reads `event.toolName` unguarded and
 * throws on a null/undefined event; this copy is its null-safe totalization,
 * because a `tool_call` handler can be invoked with an absent event during
 * teardown. The parity pin applies the same totalization to pi, so this
 * superset is asserted rather than assumed.
 *
 * The signature stays exactly `(string, unknown) => boolean`: the callers keep
 * their own `(event.input as ...)` narrowing, and returning a plain boolean (not
 * a pi-style type predicate) preserves their current compile behaviour.
 */
export function isToolCallEventType(toolName: string, event: unknown): boolean {
  return (event as { toolName?: unknown })?.toolName === toolName;
}
