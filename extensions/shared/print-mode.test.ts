/**
 * print-mode.test.ts — unit tests for shared/print-mode.ts
 * Run: npx tsx extensions/shared/print-mode.test.ts
 */

import { isPrintMode } from "./print-mode.js";
import { ok, equal } from "node:assert/strict";

// env set (builtin-tools spawn path)
equal(isPrintMode({ PI_MODE: "print" }, []), true, "env PI_MODE=print → true");
// argv -p (bare `pi -p` — the #172 case)
equal(isPrintMode({}, ["pi", "-p"]), true, "argv -p → true");
// argv --print
equal(isPrintMode({}, ["pi", "--print"]), true, "argv --print → true");
// neither
equal(isPrintMode({}, ["pi"]), false, "no flag → false");
equal(isPrintMode({ PI_MODE: "gate" }, ["pi"]), false, "other env value → false");
// env-over-argv precedence (env wins even with clean argv)
equal(isPrintMode({ PI_MODE: "print" }, []), true, "env-first precedence");
// custom params (sequence-enforcer seam: env print → warn)
equal(isPrintMode({ PI_MODE: "print" }, ["pi"]), true, "seam: env print → true");
equal(isPrintMode({ PI_MODE: undefined }, ["pi"]), false, "seam: env unset no flag → false");
// bare `pi -p` scenario (env unset + argv -p → true)
equal(isPrintMode({ PI_MODE: undefined }, ["pi", "-p"]), true, "bare pi -p → true");
// argv without -p but with other flags
equal(isPrintMode({}, ["pi", "-v"]), false, "-v is not print mode");

ok(true, "all isPrintMode cases pass");
console.log("print-mode.test OK");
