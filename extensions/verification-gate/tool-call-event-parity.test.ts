/**
 * tool-call-event-parity.test.ts — the SDK-bearing half of #1330's pin: assert
 * the repo's ONE copy of pi's `isToolCallEventType`
 * (`extensions/shared/tool-call-event.ts`) agrees with the REAL export from the
 * pinned `@earendil-works/pi-coding-agent`.
 *
 * Run: npx tsx extensions/verification-gate/tool-call-event-parity.test.ts
 * Needs the pinned SDK installed in THIS directory (it is a declared devDep):
 *   (cd extensions/verification-gate && npm ci --no-audit --no-fund)
 *
 * ── WHY THIS FILE LIVES IN verification-gate/ ────────────────────────────────
 * It pins a SHARED module, but the pin can only exist where the SDK does. The
 * consumers of the copy (skill-enforcer, sequence-enforcer) are ZERO-DEPENDENCY
 * by construction — their `ci.yml` job performs no `npm ci`, which is exactly why
 * the copy exists — so a parity suite placed beside them could not import the
 * real export at all. `verification-gate/index.ts` is itself a consumer of the
 * predicate (`isToolCallEventType("bash", event)`), and this directory is the
 * repo's SDK-bearing suite home with the pi devDependency already pinned to
 * PI_VERSION_PIN (also enforced by scripts/check-pi-pin-lockstep.mjs guard (h)).
 * This is the #966 precedent: the drift pin for a shared module lives in a
 * consumer's SDK-bearing suite, not next to the shared module.
 *
 * ── WHAT IT CATCHES, AND WHAT IT CANNOT ──────────────────────────────────────
 * CATCHES an upgrade that changes the predicate: the real export is driven over
 * a matrix of event shapes (top-level `toolName`, relocated names, nested
 * wrappers, non-string values, malformed events) and must agree with the copy on
 * EVERY case — return value AND thrown-ness. A pi release that starts reading
 * `event.name`, `event.toolCall.name`, or that stops throwing on a null event,
 * fails here.
 * CANNOT CATCH a drift nobody installed: the pin is only as current as the
 * pinned version. The lockstep guard (h) is what keeps that pin moving with
 * PI_VERSION_PIN; this suite is what makes the move observable.
 *
 * ── WHY THE COMPARISON IS A NAMED FUNCTION ───────────────────────────────────
 * `parityFindings(impl, upstream, cases)` is driven below with two DELIBERATELY
 * WRONG implementations and must report each of them. A suite that only asserts
 * "the real one agrees" stays green if the comparison is neutered (a loop that
 * never runs, a `===` rewritten to `===`-anything); the RED controls are what
 * make the instrument itself falsifiable.
 */
import { ok, equal, deepEqual } from "node:assert/strict";
import * as pi from "@earendil-works/pi-coding-agent";
import { isToolCallEventType as shared } from "../shared/tool-call-event.js";

let passed = 0;
let failed = 0;
const failures: string[] = [];
function test(name: string, fn: () => void) {
  try {
    fn();
    passed += 1;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed += 1;
    failures.push(name);
    console.log(`  ❌ ${name}\n     ${err instanceof Error ? err.message : String(err)}`);
  }
}
function section(name: string) {
  console.log(`\n${name}`);
}

type Impl = (toolName: string, event: unknown) => boolean;
type Case = { label: string; toolName: string; event: unknown };

/**
 * The matrix. The first four are the shapes that MUST match today; the rest are
 * the shapes an upgrade would have to move for the predicate to break — a
 * relocated tool name, a nested wrapper, or a different value domain. They are
 * asserted to be non-degenerate below (the real export must answer both `true`
 * and `false` across the set), so an all-false implementation cannot agree
 * vacuously.
 */
const CASES: Case[] = [
  { label: "bash hit", toolName: "bash", event: { toolName: "bash", input: { command: "git commit" } } },
  { label: "read hit", toolName: "read", event: { toolName: "read", input: { path: "/x" } } },
  { label: "wrong tool name", toolName: "bash", event: { toolName: "read", input: {} } },
  { label: "empty tool name hit", toolName: "", event: { toolName: "" } },
  { label: "absent toolName", toolName: "bash", event: {} },
  { label: "nested under toolCall", toolName: "bash", event: { toolCall: { name: "bash" } } },
  { label: "keyed as `name`", toolName: "bash", event: { name: "bash" } },
  { label: "nested under input", toolName: "bash", event: { input: { toolName: "bash" } } },
  { label: "undefined toolName", toolName: "bash", event: { toolName: undefined } },
  { label: "null toolName", toolName: "bash", event: { toolName: null } },
  { label: "numeric toolName", toolName: "bash", event: { toolName: 5 } },
  { label: "object toolName", toolName: "bash", event: { toolName: { name: "bash" } } },
  { label: "inherited toolName", toolName: "bash", event: Object.create({ toolName: "bash" }) },
  { label: "number event", toolName: "bash", event: 5 },
  { label: "string event", toolName: "bash", event: "bash" },
  { label: "array event", toolName: "bash", event: [] },
  { label: "null event", toolName: "bash", event: null },
  { label: "undefined event", toolName: "bash", event: undefined },
];

/**
 * One invocation, reduced to a comparable value. Thrown-ness is PART of the
 * observation on purpose: upstream reads `event.toolName` unguarded, so a
 * private copy that adds `?.` diverges exactly on the malformed cases while
 * agreeing everywhere else — comparing only return values would call that
 * agreement.
 */
type Observation = { threw: true; error: string } | { threw: false; value: boolean };
function observe(impl: Impl, c: Case): Observation {
  try {
    return { threw: false, value: impl(c.toolName, c.event) === true };
  } catch (err) {
    // Name only: the message text is not a contract, and v8's wording for a
    // null property read is not worth pinning.
    return { threw: true, error: err instanceof Error ? err.name : String(err) };
  }
}

/** PURE predicate: every case on which `impl` and `upstream` disagree. */
function parityFindings(impl: Impl, upstream: Impl, cases: Case[]): string[] {
  const findings: string[] = [];
  for (const c of cases) {
    const a = observe(impl, c);
    const b = observe(upstream, c);
    if (JSON.stringify(a) !== JSON.stringify(b)) {
      findings.push(`${c.label}: copy=${JSON.stringify(a)} upstream=${JSON.stringify(b)}`);
    }
  }
  return findings;
}

const upstream = (pi as Record<string, unknown>).isToolCallEventType;

section("the pin corresponds to a real, installed export");

test("the pinned pi package exports isToolCallEventType", () => {
  ok(typeof upstream === "function",
    "the SDK export this pin compares against does not exist — either the package is not installed " +
      "in extensions/verification-gate (run `npm ci` there) or a pi upgrade moved/renamed it. Both " +
      "are RED here rather than a silent pass.");
});

section("the copy agrees with the real export on every case");

test("the matrix is non-degenerate (the real export answers true AND false)", () => {
  const observed = CASES.map((c) => JSON.stringify(observe(upstream as Impl, c)));
  ok(observed.includes('{"threw":false,"value":true}'),
    "the real export never returned true over the matrix — a vacuous corpus would let any all-false copy pass");
  ok(observed.includes('{"threw":false,"value":false}'),
    "the real export never returned false over the matrix — a vacuous corpus would let any all-true copy pass");
});

test("shared/tool-call-event.ts matches the real export (returns AND thrown-ness)", () => {
  deepEqual(parityFindings(shared, upstream as Impl, CASES), [],
    "the shared copy of isToolCallEventType no longer agrees with the installed pi export. " +
      "Re-derive shared/tool-call-event.ts against the pinned dist " +
      "(dist/core/extensions/types.js) — do NOT relax this comparison.");
});

section("RED controls — the comparison itself is falsifiable");

test("a copy that reads a RELOCATED tool name is reported", () => {
  // The exact upgrade shape this pin exists for: pi moves the name one level down.
  const nested: Impl = (_t, event) => {
    const e = event as { toolCall?: { name?: unknown } } | null;
    return e?.toolCall?.name === _t;
  };
  ok(parityFindings(nested, upstream as Impl, CASES).length > 0,
    "a relocated-name implementation must be reported — if this is empty, parityFindings has been neutered");
});

test("a copy that accepts EVERY tool name is reported", () => {
  const alwaysTrue: Impl = () => true;
  ok(parityFindings(alwaysTrue, upstream as Impl, CASES).length > 0,
    "an always-true implementation must be reported");
});

test("a copy that adds an optional chain is reported (the divergence found while building this pin)", () => {
  const tolerant: Impl = (t, event) => (event as { toolName?: unknown } | null)?.toolName === t;
  const findings = parityFindings(tolerant, upstream as Impl, CASES);
  ok(findings.length > 0,
    "`event?.toolName` swallows the malformed-event case that upstream throws on; it must be reported");
  ok(findings.some((f) => f.startsWith("null event:")),
    `the null-event case must be among the findings, got: ${JSON.stringify(findings)}`);
});

test("a matching implementation reports NOTHING (the control's other side)", () => {
  deepEqual(parityFindings(upstream as Impl, upstream as Impl, CASES), [],
    "an implementation identical to upstream must not be reported — otherwise the RED controls above are vacuous");
});

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  for (const f of failures) console.log(`   - ${f}`);
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
