/**
 * git-command-parse.test.ts — THE suite for the shared command parsers (#966).
 *
 * This file replaces the four duplicated helper suites that used to live in
 * verification-gate/index.test.ts and review-enforcer/index.test.ts — the
 * duplication that let the two copies drift and their suites assert OPPOSITE
 * answers for `cd /a && cd /b && <op>` (VGATE /a, review-enforcer /b).
 *
 * "Last cd wins" is settled on evidence, not preference: `cd` is sequential
 * and mutating, and BOTH call sites use the result as the cwd the op actually
 * runs in (verification-gate → `resolveGitRoot(cdPath ?? inputCwd)`, the tree
 * whose files get hashed; review-enforcer → the `cwd` of its own gh
 * subprocesses). Bash runs `cd /a && cd /b && git commit` in /b, so the wrong
 * pin at verification-gate/index.test.ts:492 was DELETED, not duplicated here.
 *
 * Zero-dependency (stdlib only): CI runs extensions/shared/*.test.ts BEFORE
 * the extensions' npm ci, so this suite must not import a pi-using module.
 *
 * Run: npx tsx extensions/shared/git-command-parse.test.ts
 */

import {
  extractCdPath,
  parseCdChains,
  expandCdTarget,
  extractRepoFlag,
  extractGhRepoEnv,
  extractPrNumber,
  unquotedMask,
  GH_PR_MERGE_VERB,
} from "./git-command-parse.js";
import { ok, equal } from "node:assert/strict";
import { resolve as resolvePath } from "node:path";
import * as os from "node:os";
import * as fs from "node:fs";

let passed = 0;
let failed = 0;

function test(name: string, fn: () => void) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err: any) {
    failed++;
    console.log(`  ❌ ${name}: ${err.message}`);
  }
}

function section(name: string) {
  console.log(`\n${name}:`);
}

/** The base the module resolves a RELATIVE `cd` operand against: bash's LOGICAL
 * `$PWD` when it names the same directory as the physical cwd, else the physical
 * cwd (the module's `logicalCwd`). An expectation written as `resolvePath("b")`
 * uses the PHYSICAL cwd and is therefore WRONG whenever the suite runs from a
 * symlinked path (macOS `/tmp`, a symlinked checkout): the module returns the
 * logical path, bash prints the logical path, and the assertion fails through no
 * fault of the parser. Restating the rule here is deliberate — it is the
 * contract, and the dedicated logical-cwd test below pins the module against it.
 */
function logicalBase(): string {
  const pwd = process.env.PWD;
  if (pwd && pwd.startsWith("/")) {
    try {
      const a = fs.statSync(pwd);
      const b = fs.statSync(process.cwd());
      if (a.dev === b.dev && a.ino === b.ino) return pwd;
    } catch {
      /* $PWD vanished or is unreadable — the physical cwd is the only truth. */
    }
  }
  return process.cwd();
}

// ── #960 truth table ──────────────────────────────────

section("extractCdPath — #960 truth table (newline-separated cd)");

test("cd <wt> && <op> → the worktree", () => {
  equal(extractCdPath("cd /a && git commit"), resolvePath("/a"));
});

test("cd <wt> ; <op> → the worktree", () => {
  equal(extractCdPath("cd /a ; git commit"), resolvePath("/a"));
});

test("cd <wt> && ⏎ <op> → the worktree", () => {
  // A line STARTING with `&&` is a bash SYNTAX ERROR (`cd /a` ⏎ `&& op` never
  // runs), so that spelling pins nothing bash can do. The valid line-broken
  // form keeps the operator at the END of the first line.
  equal(extractCdPath("cd /a &&\ngit commit"), resolvePath("/a"));
});

test("#960: cd <wt> ⏎ <op> → the worktree (was NULL → session root)", () => {
  // The headline bug: the old regex required a &&/; right-hand terminator, so
  // a newline-terminated cd returned null and the caller fell back to the
  // session repo root — a false block from a worktree, and a fail-open when the
  // session tree happened to hash to verified values.
  equal(extractCdPath("cd /a\ngit commit"), resolvePath("/a"));
});

test("#960: cd <wt> ⏎ (trailing newline) → the worktree (was NULL)", () => {
  equal(extractCdPath("cd /a\n"), resolvePath("/a"));
});

test("#960: the path group must not SWALLOW the following line", () => {
  // `([^;&|]+?)` with a newline terminator would otherwise capture
  // "/a\ngit commit -m y" as the cd target.
  equal(extractCdPath("cd /a\ngit commit -m y && git push"), resolvePath("/a"));
});

test("no cd → null (the correct null)", () => {
  equal(extractCdPath("git commit"), null);
  equal(extractCdPath("gh pr merge 138"), null);
});

// ── first-vs-last cd (the contradiction #966) ─────────

section("extractCdPath — LAST cd wins (the #966 contradiction, settled)");

test("cd /a && cd /b && <op> → /b (bash runs the op in /b)", () => {
  // verification-gate's old copy + its test pinned /a ("first
  // boundary-anchored cd wins"); review-enforcer pinned /b. Bash semantics
  // decide it: the op runs in the LAST cd's directory.
  equal(extractCdPath("cd /a && cd /b && git commit"), resolvePath("/b"));
});

test("cd /a ; cd /b ; <op> → /b", () => {
  equal(extractCdPath("cd /a ; cd /b ; git commit"), resolvePath("/b"));
});

test("cd /a ⏎ cd /b ⏎ <op> → /b (newline chain, last wins)", () => {
  equal(extractCdPath("cd /a\ncd /b\ngit commit"), resolvePath("/b"));
});

test("multi-cd with a gh merge tail → /b", () => {
  equal(extractCdPath("cd /a && cd /b && gh pr merge 1"), resolvePath("/b"));
});

test("a single anchored cd after another command still resolves", () => {
  equal(extractCdPath("echo x && cd /tmp && git commit"), resolvePath("/tmp"));
});

// ── chain COMPOSITION (cycle-6 finding) ───────────────

section("extractCdPath — the chain composes (relative cd resolves against the previous cd)");

test("a relative cd after an earlier cd resolves against that cd, not process.cwd()", () => {
  // The old shared copy resolved only the LAST operand against process.cwd(),
  // fabricating <process.cwd>/extensions — a concrete NON-EXISTENT tree path
  // returned with unattributable=false. Bash runs the op in /tmp/wt/extensions.
  equal(parseCdChains("cd /tmp/wt && cd extensions && git commit").last, resolvePath("/tmp/wt/extensions"));
  equal(parseCdChains("cd /tmp/wt && cd extensions && git commit").unattributable, false);
});

test(". and .. compose against the running root", () => {
  equal(extractCdPath("cd /a && cd . && git commit"), resolvePath("/a"));
  equal(extractCdPath("cd /a && cd .. && git commit"), resolvePath("/"));
  equal(extractCdPath("cd /a && cd b && cd c && git commit"), resolvePath("/a/b/c"));
});

test("a relative cd after `cd ~` resolves against HOME", () => {
  equal(extractCdPath("cd ~ && cd sub && git commit"), resolvePath(os.homedir(), "sub"));
});

test("an absolute cd mid-chain restarts the base", () => {
  equal(extractCdPath("cd /a && cd sub && cd /b && cd deep && git commit"), resolvePath("/b/deep"));
  equal(extractCdPath("cd /a && cd /b && git commit"), resolvePath("/b"));
});

test("a quoted-empty cd is a no-op in bash and keeps the composed root", () => {
  // bash: `cd ""` returns 0 and does NOT change directory.
  equal(extractCdPath('cd /a && cd "" && git commit'), resolvePath("/a"));
  equal(extractCdPath("cd /a && cd '' && git commit"), resolvePath("/a"));
});

test("a bare cd mid-chain goes HOME and wins over the earlier operand", () => {
  // bash: `cd /a && cd && op` → op runs in $HOME. The old copy consulted bare
  // cds ONLY when no cd-with-operand existed, so it returned /a.
  equal(parseCdChains("cd /a && cd && git commit").last, resolvePath(os.homedir()));
  equal(parseCdChains("cd /a && cd && git commit").unattributable, false);
  equal(extractCdPath("cd /a && cd -- && git commit"), resolvePath(os.homedir()));
  equal(extractCdPath("cd /a && cd -P && git commit"), resolvePath(os.homedir()));
});

test("an unresolvable link mid-chain poisons the whole chain", () => {
  // The second operand cannot be resolved, so the cwd the op inherits is
  // unknown — decline rather than return the first cd's root.
  equal(parseCdChains("cd /a && cd $X && git commit").last, null);
  equal(parseCdChains("cd /a && cd $X && git commit").unattributable, true);
});

test("a CR-authored cd operand is NOT the trimmed path (CR is not IFS)", () => {
  // bash keeps \r in the word (IFS is space/tab/newline), so `cd /a\r` fails
  // and the following op runs in the invocation cwd.
  equal(parseCdChains("cd /a\r\ngit commit").last, null);
  equal(parseCdChains("cd /a\r\ngit commit").unattributable, true);
  equal(parseCdChains("cd /a\r").last, null);
  // …but a CR inside a stripped comment is harmless.
  equal(extractCdPath("cd /a # note\r\ngit commit"), resolvePath("/a"));
});

test("a vertical tab does not separate commands — a VT-prefixed word is conservatively unattributable", () => {
  // bash: IFS is space/tab/newline, so `<VT>cd` is ONE word naming an unknown
  // COMMAND (`bash: <VT>cd: command not found`) — bash runs NO cd, so the
  // module's contract for `unattributable` ("a cd bash WILL run") would say
  // false. The parser's cd-word boundary check still uses `\s` (which matches
  // VT), so it counts the word as cd-shaped and reports the conservative
  // over-report `unattributable: true` (a caller does extra work; it can never
  // attest a wrong root). This pins the CURRENT conservative behaviour, not
  // bash's; tightening the boundary to `[ \t...]` is tracked as a residual.
  equal(parseCdChains("\vcd /a && git commit").last, null);
  equal(parseCdChains("\vcd /a && git commit").unattributable, true);
});

test("a `||` between two cds is control flow — never composed (cycle-7)", () => {
  // bash: `cd A || cd B && op` parses as ((cd A) || (cd B)) && op. When cd A
  // SUCCEEDS (the normal case) the RHS cd never runs, so an unconditional
  // composition claims B while the op actually ran in A.
  // Ground truth: `bash -c 'cd /a || cd /b && pwd'` → /a.
  for (const cmd of [
    "cd /a || cd /b && git commit",
    "cd /a && echo || cd /b && git commit",
    "cd /a && git commit || cd /b && git push",
  ]) {
    equal(parseCdChains(cmd).last, null, cmd);
    equal(parseCdChains(cmd).unattributable, true, cmd);
  }
});

test("a `||` that separates no two cds keeps the idiom `cd X || exit 1 && op` working", () => {
  // bash: (cd /wt || exit 1) && op — either cd /wt succeeded (op runs in /wt)
  // or exit 1 aborted the chain. Resolving to /wt is exact, not a guess.
  equal(extractCdPath("cd /tmp/wt || exit 1 && git commit"), resolvePath("/tmp/wt"));
  equal(extractCdPath("cd /tmp/wt || exit 1 ; git commit"), resolvePath("/tmp/wt"));
  // `return` is deliberately NOT pinned as an aborting alternate, even though
  // the module's `/^(?:exit|return)\b/` accepts it: at TOP LEVEL a `return`
  // ERRORS ("can only `return' from a function or sourced script") and does NOT
  // abort, so `cd /nonexistent || return 1 ; op` runs op in the PRE-cd cwd —
  // resolving the cd's root would be a WRONG-root attribution (bash-verified on
  // the fleet's shell). Asserting /tmp/wt here would cement that; dropping
  // `return` from the abort set is a module change, reported as a residual.
  // `exit` IS correct: it terminates the shell before the op can run.
});

test("a `||` alternate WITHOUT an abort never attests the cd's root (cycle-8)", () => {
  // `cd /nonexistent || true && op`: the cd FAILS, `true` succeeds and does not
  // change the cwd, so op runs in the PRE-cd cwd — attesting /nonexistent would
  // be a fail-open. Only `exit` (and `return` INSIDE a function or sourced
  // script) forces the op to exist solely in the cd-succeeded branch, which is
  // why the idiom above still resolves — a TOP-LEVEL `return` does NOT abort
  // (see the note on the idiom test above).
  for (const cmd of [
    "cd /tmp/NOPE || git commit",
    "cd /a || git commit",
    "cd /nonexistent || true && git commit",
    "cd /a || echo x ; git commit",
  ]) {
    equal(parseCdChains(cmd).last, null, cmd);
    equal(parseCdChains(cmd).unattributable, true, cmd);
  }
});

test("a cd reached through `||` is conditional, wherever it sits (cycle-8)", () => {
  // `true || cd /a && op` runs op in the pre-cd cwd: the cd is in the alternate
  // branch, so nothing composes it. (bash: `true || cd X && pwd` → invocation cwd.)
  for (const cmd of [
    "true || cd /a && git commit",
    "echo x || cd /a && git commit",
    "(true) || cd /a && git commit",
    "cd /a || cd /b && git commit",
  ]) {
    equal(parseCdChains(cmd).last, null, cmd);
    equal(parseCdChains(cmd).unattributable, true, cmd);
  }
  // …an alternate that is NOT a cd stays resolvable — the op reaches the last
  // cd on both branches (bash-verified: `cd A || echo x && cd B && pwd` → B).
  equal(extractCdPath("cd /a || echo x && cd /b && git commit"), resolvePath("/b"));
});

test("a piped cd is dropped from the chain, not composed (cycle-8)", () => {
  // A pipeline element runs in a subshell and never changes the parent cwd, so
  // composing it fabricated a directory no op entered. bash-verified:
  // `cd /wg/a | cat && cd b && pwd` → <invocation>/b.
  // The relative operands resolve against bash's LOGICAL cwd, so the
  // expectation comes from `logicalBase()` — NOT `resolvePath(<relative>)`,
  // which is the physical cwd and disagrees under a symlinked checkout.
  equal(extractCdPath("cd /a | cat && cd b && git commit"), resolvePath(logicalBase(), "b"));
  equal(extractCdPath("cd /a | cat && cd .. && git commit"), resolvePath(logicalBase(), ".."));
  // A piped LATER cd leaves the earlier, effective one in charge.
  equal(extractCdPath("cd /a && cd /b | cat && git commit"), resolvePath("/a"));
  // A piped cd was the ONLY cd → nothing changed the shell's cwd.
  equal(parseCdChains("cd /a | cat && git commit").last, null);
  equal(parseCdChains("cd /a | cat && git commit").unattributable, true);
  equal(parseCdChains("echo x | cd /a && git commit").last, null);
});

test("a lone `&` backgrounds the preceding AND-OR list — its cd never reaches a LATER op (cycle-8)", () => {
  // bash: `cd /wg/a && true & op` → the AND-OR list is backgrounded, op runs in
  // the pre-cd cwd. `&>`/`2>&1` are redirections and must NOT be split.
  for (const cmd of [
    "cd /a && true & git commit",
    "cd /a && : & git commit",
    "cd /a & git commit",
  ]) {
    equal(parseCdChains(cmd).last, null, cmd);
    equal(parseCdChains(cmd).unattributable, true, cmd);
  }
  // A TRAILING `&` is a DIFFERENT shape, pinned separately: the op is INSIDE
  // the backgrounded list and bash DOES run it — in /a (`bash -c 'cd /a && pwd
  // &'` prints /a). The module declines because a backgrounded list does not
  // set the PARENT shell's cwd; this pin records the conservative decline, NOT
  // the (false) claim that the op ran in the pre-cd cwd.
  equal(parseCdChains("cd /a && git commit &").last, null);
  equal(parseCdChains("cd /a && git commit &").unattributable, true);
  // A `&` BEFORE the cd doés not void it (the next command is still the parent shell).
  equal(extractCdPath("bg & cd /a && git commit"), resolvePath("/a"));
  // Redirections are not command separators.
  equal(extractCdPath("cd /a && git commit 2>&1"), resolvePath("/a"));
  equal(extractCdPath("cd /a && git commit &> /dev/null"), resolvePath("/a"));
});

test("relative operands resolve against bash's LOGICAL cwd, not Node's physical one", () => {
  // bash `cd` is logical by default, so `..` climbs the SYMLINK prefix: from
  // <holder>/link (→ <real>) `cd ..` is <holder>, while resolving against Node's
  // physical process.cwd() yields <real>'s parent. The link lives in its OWN
  // holder dir (NOT a sibling of `real`) so the two differ on EVERY platform —
  // a sibling link under os.tmpdir() would make both `..` identical on Linux,
  // letting a physical-cwd implementation pass the `cd ..` leg.
  const real = fs.mkdtempSync(resolvePath(os.tmpdir(), "cdparse-logical-"));
  const holder = fs.mkdtempSync(resolvePath(os.tmpdir(), "cdparse-holder-"));
  const link = resolvePath(holder, "link");
  const prevCwd = process.cwd();
  const prevPwd = process.env.PWD;
  try {
    fs.symlinkSync(real, link);
    process.chdir(link);
    process.env.PWD = link;
    equal(extractCdPath("cd .. && git commit"), resolvePath(link, ".."));
    equal(extractCdPath("cd sub && git commit"), resolvePath(link, "sub"));
  } finally {
    process.chdir(prevCwd);
    if (prevPwd === undefined) delete process.env.PWD;
    else process.env.PWD = prevPwd;
    fs.rmSync(link, { force: true });
    fs.rmSync(real, { recursive: true, force: true });
    fs.rmSync(holder, { recursive: true, force: true });
  }
});

test("$PWD that names a DIFFERENT directory is not trusted (physical cwd wins)", () => {
  // The other half of `logicalCwd`: $PWD is only used when it names the same
  // directory (dev+ino) as the physical cwd. A stale/foreign $PWD (the old
  // session's directory, or a path that no longer exists) must not drag a
  // relative cd to a tree the process is not in.
  const base = fs.mkdtempSync(resolvePath(os.tmpdir(), "cdparse-pwdfallback-"));
  const prevCwd = process.cwd();
  const prevPwd = process.env.PWD;
  try {
    process.chdir(base);
    // The PHYSICAL base: `process.cwd()` resolves symlinks (macOS /var →
    // /private/var), and that is exactly what the module falls back to here.
    const physical = process.cwd();
    // (a) $PWD names a DIFFERENT existing directory.
    const other = resolvePath(base, "other");
    fs.mkdirSync(other, { recursive: true });
    process.env.PWD = other;
    equal(extractCdPath("cd sub && git commit"), resolvePath(physical, "sub"));
    // (b) $PWD vanished / is unreadable → fall back to the physical cwd.
    process.env.PWD = resolvePath(base, "gone-966");
    equal(extractCdPath("cd sub && git commit"), resolvePath(physical, "sub"));
  } finally {
    process.chdir(prevCwd);
    if (prevPwd === undefined) delete process.env.PWD;
    else process.env.PWD = prevPwd;
    fs.rmSync(base, { recursive: true, force: true });
  }
});

// ── quotes: target vs prose ───────────────────────────

section("extractCdPath — quoted targets parse, quoted prose never does");

test("single/double-quoted cd targets (spaces) resolve", () => {
  equal(extractCdPath("cd '/path with spaces' && git commit"), resolvePath("/path with spaces"));
  equal(extractCdPath('cd "/path with spaces" && git commit'), resolvePath("/path with spaces"));
});

test("a `cd` inside quoted prose is not a cd chain (#230 class)", () => {
  equal(extractCdPath('gh pr merge 1 --comment "see cd /tmp && x"'), null);
  equal(extractCdPath('gh pr merge 1 --comment "see; cd /tmp && x"'), null);
  equal(extractCdPath('gh pr merge 1 --body "first\ncd /tmp && second"'), null);
  equal(extractCdPath("git commit -m 'run cd /tmp && fix'"), null);
});

// ── shell forms the old VGATE regex fabricated ────────

section("extractCdPath — no fabricated paths (#960 garbage-path class)");

test("~ and ~/ expand to the home dir (old copy fabricated <cwd>/~/repo)", () => {
  equal(extractCdPath("cd ~ && git commit"), os.homedir());
  equal(extractCdPath("cd ~/repo && git commit"), resolvePath(os.homedir(), "repo"));
});

test("backslash line continuation is stripped (`cd /wt \\` ⏎ `&& op`) — a CRLF ending is normalised too (module leniency)", () => {
  // Old behavior: the trailing `\` was captured → a FABRICATED "/wt \" root.
  equal(extractCdPath("cd /a \\\n&& git push"), resolvePath("/a"));
  equal(extractCdPath("cd /a\\\n&& git push"), resolvePath("/a"));
  equal(extractCdPath("cd /a \\\r\n&& git push"), resolvePath("/a"));
  // The CRLF leg just above is MODULE leniency, not shell semantics: real bash
  // treats the CR as the escaped character and the LF as a real newline, so a
  // next line starting with an operator is a SYNTAX ERROR and no op runs at all
  // (the resolved root is moot). Recorded here; not an assertion about bash.
  // The DOUBLE-quoted leg (the other half of the quote-aware strip): bash
  // continues the line inside double quotes, so the operand is `/ab`.
  equal(extractCdPath('cd "/a\\\nb" && git commit'), resolvePath("/ab"));
});

test("a line continuation inside SINGLE quotes is literal, not stripped", () => {
  // bash keeps `\<newline>` literal inside single quotes, so the operand is
  // the literal path `/a<backslash><newline>b` — the parser must decline, NOT
  // unquote it into `/ab`. This is the DISCRIMINATING input: a quote-unaware
  // global strip fabricates the non-existent `/ab` with `unattributable:false`.
  equal(extractCdPath("cd '/a\\\nb' && git commit"), null);
  equal(parseCdChains("cd '/a\\\nb' && git commit").unattributable, true);
  // Control (no cd token): a prose `\<newline>` is inert either way.
  equal(extractCdPath("git commit -m 'a\\\nb'"), null);
});

test("`cd /x || exit 1` idiom splits at the pipe", () => {
  equal(extractCdPath("cd /tmp/x || exit 1\ngh pr merge 138"), resolvePath("/tmp/x"));
});

test("`cd X & op` backgrounds the cd — reported unattributable, never /X (fail-open)", () => {
  // bash runs `git commit` in the ORIGINAL cwd (the cd is backgrounded into a
  // subshell); resolving /X would hash the WRONG tree and attest it as verified.
  equal(extractCdPath("cd /a & git commit"), null);
  equal(parseCdChains("cd /a & git commit").unattributable, true, "a cd ran; we could not model it");
});

test("`cd -` ($OLDPWD) is reported unattributable, not fabricated as <cwd>/- ", () => {
  equal(extractCdPath("cd - && git commit"), null);
  equal(parseCdChains("cd - && git commit").unattributable, true);
});

test("an escaped-space target is not kept with its backslash", () => {
  equal(extractCdPath("cd /a\\ b && git commit"), null);
  equal(parseCdChains("cd /a\\ b && git commit").unattributable, true);
});

test("a redirect / subshell / brace in the target is conservative (unattributable, not fabricated)", () => {
  equal(extractCdPath("cd /a > log && git commit"), null);
  equal(extractCdPath("cd { /a && git commit"), null);
  // `last === null` with `unattributable === false` is the FAIL-OPEN state (a
  // caller then uses the session cwd), so the third state must be checked too.
  equal(parseCdChains("cd /a > log && git commit").unattributable, true);
  equal(parseCdChains("cd { /a && git commit").unattributable, true);
});

test("`cd -- <path>` resolves the operand (end-of-options is not part of the path)", () => {
  equal(extractCdPath("cd -- /a && git commit"), resolvePath("/a"));
  equal(parseCdChains("cd -- /a && git commit").unattributable, false);
  equal(extractCdPath("cd -- /a\ngit commit"), resolvePath("/a"), "newline form too");
});

test("`cd --` with no operand goes HOME like a bare cd", () => {
  equal(parseCdChains("cd -- && git commit").last, os.homedir());
});

test("`cd`'s own option words are not part of the target (`cd -P /a` → /a)", () => {
  equal(extractCdPath("cd -P /a && git commit"), resolvePath("/a"));
  equal(extractCdPath("cd -L /a\ngit commit"), resolvePath("/a"));
  equal(extractCdPath("cd -L -P -- /a && git commit"), resolvePath("/a"));
  equal(parseCdChains("cd -P && git commit").last, os.homedir(), "no operand → HOME");
  equal(parseCdChains("cd -P && git commit").unattributable, false);
  // `-e` / `-@` are NOT pinned as roots even though the module's option grammar
  // accepts them (bash >= 5's `cd [-L|[-P [-e]] [-@]]`): the shell that runs the
  // gated command on this fleet is bash 3.2, which REJECTS them ("cd: usage:
  // cd [-L|-P] [dir]") and leaves the cwd unchanged — so the module's `/a` for
  // `cd -e /a` is a WRONG-root attestation (bash-verified). Pinning `/a` would
  // cement that; declining them (as the combined form below already does) is a
  // module change, reported as a residual.
  // A COMBINED short-option word (`cd -Pe /a`) is not modelled and is
  // conservatively declined rather than truncated into a path — conservative on
  // BOTH grammars (bash 3.2 errors, bash >= 5 would cd /a).
  equal(parseCdChains("cd -Pe /a && git commit").last, null);
  equal(parseCdChains("cd -Pe /a && git commit").unattributable, true);
});

test("a residual leading `-` is bash state, never a path (`cd -`, `cd --help`)", () => {
  equal(extractCdPath("cd --help && git commit"), null);
  equal(parseCdChains("cd --help && git commit").unattributable, true);
});

test("an inline `#` comment is not part of the target", () => {
  // The op must be on the NEXT line: `cd /a # note && git commit` comments the
  // rest of the LINE out, so bash runs neither `&&` nor the op and the case
  // would prove nothing about the op's cwd.
  equal(extractCdPath("cd /a # note\ngit commit"), resolvePath("/a"));
  equal(extractCdPath("cd /a #note"), resolvePath("/a"));
  equal(extractCdPath("cd /a#b && git commit"), resolvePath("/a#b"), "mid-word # is literal");
  equal(extractCdPath("cd '/a # b' && git commit"), resolvePath("/a # b"), "quoted # is literal");
  // …and the RELATIVE quoted form resolves against the logical cwd (the
  // absolute spelling above cannot exercise the base).
  equal(extractCdPath("cd 'a # b' && git commit"), resolvePath(logicalBase(), "a # b"), "relative quoted # is literal");
});

test("`~user` and glob targets are unattributable, not fabricated", () => {
  equal(extractCdPath("cd ~root && git commit"), null);
  equal(extractCdPath("cd /a* && git commit"), null);
  equal(parseCdChains("cd ~root && git commit").unattributable, true);
  equal(parseCdChains("cd /a* && git commit").unattributable, true);
  equal(extractCdPath("cd ~ && git commit"), os.homedir(), "plain ~ still resolves");
  // KNOWN GAP (reported, module fix pending): `expandCdTarget` tests the `~/`
  // branch BEFORE its `$`/backtick guard, so `cd ~/$X` resolves to the
  // FABRICATED `<home>/$X` with `unattributable: false` — bash expands `$X` at
  // execution time, so it is statically unknowable and this is exactly the
  // wrong-root attestation the module header promises to refuse. No assertion is
  // added (it would fail); the fix is to reject `$`/backtick before `~/`.
});

test("partial/interior quoting and multi-word targets are never fabricated", () => {
  // bash concatenates the quoted fragments (`cd /a"b c"d` → /ab cd); the
  // parser cannot faithfully unquote them, so it declines rather than resolving
  // a literal-quote path. Two operands make bash's cd FAIL (cwd unchanged).
  equal(extractCdPath('cd /path/"my project" && git commit'), null);
  equal(extractCdPath('cd /a"b c"d && git commit'), null);
  equal(extractCdPath('cd "/a""/b" && git commit'), null);
  equal(extractCdPath('cd ~/"my dir" && git commit'), null);
  equal(extractCdPath("cd /a b && git commit"), null, "two operands");
  equal(extractCdPath("cd /a 'x y' && git commit"), null);
  // The name says "never fabricated": that requires the THIRD state too, since
  // {last:null, unattributable:false} is the state callers treat as "no cd".
  for (const cmd of [
    'cd /path/"my project" && git commit',
    'cd /a"b c"d && git commit',
    'cd "/a""/b" && git commit',
    'cd ~/"my dir" && git commit',
    "cd /a b && git commit",
    "cd /a 'x y' && git commit",
  ]) {
    equal(parseCdChains(cmd).unattributable, true, cmd);
  }
  // ...while a SINGLE fully-quoted operand still resolves.
  equal(extractCdPath('cd "/a b" && git commit'), resolvePath("/a b"));
  equal(extractCdPath("cd -P '/a b' && git commit"), resolvePath("/a b"), "option + quoted operand");
});

test("a cd AFTER the op (with nothing following) never becomes the op's cwd", () => {
  // `git commit && cd /a`: the commit ran in the invocation cwd, NOT /a —
  // returning /a would hash a tree no op touched.
  equal(extractCdPath("git commit && cd /a"), null);
  equal(parseCdChains("git commit && cd /a").unattributable, true);
  equal(extractCdPath("cd /a && git commit && cd /b"), null);
  equal(extractCdPath("cd /a && git commit"), resolvePath("/a"), "a cd BEFORE the op still governs");
  equal(extractCdPath("cd /a"), resolvePath("/a"), "a lone cd is not trailing");
  equal(extractCdPath("cd /a\n"), resolvePath("/a"), "a trailing newline is not a following command");
  // A trailing SEPARATOR or stripped comment leaves an empty final segment —
  // that must not defeat the rule (the op still ran before the cd).
  equal(extractCdPath("git commit && cd /a ;"), null);
  equal(extractCdPath("git commit && cd /a\n"), null);
  // NOTE: bash REJECTS a top-level `;;` (it is a `case` terminator) — this is a
  // text-robustness pin for the parser's separator handling, not an executable
  // shape, so it is asserted for `extractCdPath` only and deliberately kept out
  // of the third-state loop below (which uses valid bash shapes).
  equal(extractCdPath("git commit && cd /a ;;"), null);
  equal(extractCdPath("git commit && cd /a # note"), null);
  equal(extractCdPath("cd /a && git commit && cd /b ;"), null);
  equal(extractCdPath("cd /a && git commit && cd /b\n"), null);
  // Every one of these declines for the SAME reason, so each must report the
  // FULL third state — `{last: null, unattributable: false}` is the state a
  // caller reads as "no cd" and falls back to the session repo/root, and a
  // non-null `last` hands the caller a root no op ran in.
  for (const cmd of [
    "cd /a && git commit && cd /b",
    "git commit && cd /a ;",
    "git commit && cd /a\n",
    "git commit\ncd /a",
    "git commit && cd /a # note",
    "cd /a && git commit && cd /b ;",
    "cd /a && git commit && cd /b\n",
  ]) {
    const r = parseCdChains(cmd);
    equal(r.unattributable, true, `${cmd} — must be unattributable`);
    equal(r.last, null, `${cmd} — must not fabricate a root`);
  }
});

test("a nested/subshell cd alongside a parsed one is ambiguous, never the outer root", () => {
  // `cd /a && (cd /b && git commit)` commits in /b — returning /a would be a
  // wrong hash root. Full nesting awareness is #960's separate issue; declining
  // is the safe answer.
  equal(extractCdPath("cd /a && (cd /b && git commit)"), null);
  equal(parseCdChains("cd /a && (cd /b && git commit)").unattributable, true);
  equal(extractCdPath("cd /a && git commit"), resolvePath("/a"), "plain chain still resolves");
});

test("a QUOTED `~` is not tilde-expanded (bash keeps it literal)", () => {
  // bash: `cd '~/a'` looks for a literal `~/a` directory and normally fails, so
  // turning it into $HOME/a would be a wrong root attested as verified.
  equal(extractCdPath("cd '~/a' ; git commit"), null);
  equal(extractCdPath('cd "~/a" ; git commit'), null);
  equal(parseCdChains("cd '~/a' ; git commit").unattributable, true);
  equal(extractCdPath("cd ~/a && git commit"), resolvePath(os.homedir(), "a"), "unquoted ~ still expands");
  equal(extractCdPath("cd '/a b' && git commit"), resolvePath("/a b"), "a quoted plain path still resolves");
});

test("bracket globs are unattributable (pathname expansion we cannot model)", () => {
  equal(extractCdPath("cd /tmp/t[e]st && git commit"), null);
  equal(parseCdChains("cd /tmp/t[e]st && git commit").unattributable, true);
});

test("only ONE `--` ends option parsing; a later `--` is the operand", () => {
  equal(extractCdPath("cd -- /a && git commit"), resolvePath("/a"));
  equal(extractCdPath("cd -- -- /a ; git commit"), null, "bash cd fails on the literal '--'");
  equal(extractCdPath("cd -L -- -P /a ; git commit"), null, "post-`--` words are operands");
  equal(parseCdChains("cd -- -- /a ; git commit").unattributable, true);
  equal(parseCdChains("cd -L -- -P /a ; git commit").unattributable, true);
});

test("a `cd` inside a pipeline element does not set the effective cwd (fail-open)", () => {
  // bash runs a pipeline element in a subshell: the following op sees the
  // ORIGINAL cwd, so claiming /a would hash the wrong tree.
  equal(extractCdPath("cd /a | cat && git commit"), null);
  equal(parseCdChains("cd /a | cat && git commit").unattributable, true);
  equal(extractCdPath("echo x | cd /a && git commit"), null);
  // The piped-cd decline is the SAME third state as its sibling above — both
  // must be pinned, or a regression to `unattributable: false` is invisible.
  equal(parseCdChains("echo x | cd /a && git commit").unattributable, true);
  // ...but a cd OUTSIDE the pipeline still governs the later op.
  equal(extractCdPath("cd /a && cat | grep x && git commit"), resolvePath("/a"));
});

// ── parseCdChains third state ─────────────────────────

section("parseCdChains — the unattributable third state");

test("$VAR / $( ) command-substitution targets → last null, unattributable (never guessed)", () => {
  const r1 = parseCdChains('cd "$HOME/x" && git commit');
  equal(r1.last, null, "$ target not guessed");
  equal(r1.unattributable, true, "reported so a caller can skip the cwd fallback");
  const r2 = parseCdChains("cd $WORKTREE && git commit");
  equal(r2.last, null);
  equal(r2.unattributable, true);
  // The NAME's `$( )` class — an actual command substitution (the old body only
  // exercised `$VAR`). Both spellings resolve at EXECUTION time, so neither may
  // be guessed statically.
  const r3 = parseCdChains('cd "$(pwd)" && git commit');
  equal(r3.last, null, "a quoted command substitution is not guessed");
  equal(r3.unattributable, true);
  const r4 = parseCdChains("cd $(pwd) && git commit");
  equal(r4.last, null);
  equal(r4.unattributable, true);
});

test("a BACKTICK-opened cd is not even seen as a cd — pin the no-fabricated-root half only", () => {
  // Reported module gap (escalated, module fix pending), so this is its OWN
  // test: the `$VAR / $( )` class test above must not read as covering the
  // backtick's attribution outcome, which is the OPPOSITE of the class's.
  //
  // A backtick is absent from the cd-word boundary classes, so
  // `` `cd /tmp/x && <op>` `` returns {last: null, unattributable: FALSE} — the
  // chain scan finds no cd at all, and review-enforcer's `!unattributable &&
  // !last` path then attributes the op to the SESSION cwd's repo (the wrong-repo
  // read the third state exists to prevent). `$(cd …)` and `(cd …)` report true.
  //
  // Only the SAFE half is pinned here: no FABRICATED root (the #960 garbage-path
  // class). Asserting `unattributable` would either fail today or cement the
  // fail-open, so it is deliberately omitted.
  const r = parseCdChains("`cd /tmp/x && git commit`");
  equal(r.last, null, "a backtick form must never yield a fabricated root");
  equal(extractCdPath("`cd /tmp/x && git commit`"), null);
});

test("subshell (cd …) → unattributable", () => {
  const r = parseCdChains("(cd /tmp/x && git commit)");
  equal(r.last, null);
  equal(r.unattributable, true, "bash runs the cd; the caller must not trust the session cwd");
  // The `$(` command-substitution OPENER (a cd INSIDE the substitution) is the
  // same class — the backtick comment above records the one opener that is NOT.
  const d = parseCdChains("$(cd /tmp/x && git commit)");
  equal(d.last, null);
  equal(d.unattributable, true, "the `$( )` opener containing a cd is unattributable too");
});

test("bare cd → home, NOT unattributable", () => {
  const r = parseCdChains("cd && git commit");
  equal(r.last, os.homedir());
  equal(r.unattributable, false);
});

test("no cd at all → last null and NOT unattributable", () => {
  const r = parseCdChains("git commit -m x");
  equal(r.last, null);
  equal(r.unattributable, false);
});

test("quoted prose cd → last null and NOT unattributable (not a cd bash will run)", () => {
  const r = parseCdChains('gh pr merge 138 --comment "cd /tmp/foo"');
  equal(r.last, null);
  equal(r.unattributable, false);
});

test("expandCdTarget: statically resolvable, or null when bash would expand it", () => {
  equal(expandCdTarget("~"), os.homedir());
  equal(expandCdTarget("~/sub"), resolvePath(os.homedir(), "sub"));
  equal(expandCdTarget("/abs/path"), resolvePath("/abs/path"));
  equal(expandCdTarget("$HOME/x"), null);
  equal(expandCdTarget("`pwd`/x"), null);
  // The explicit `base` is the documented composition mechanism: a relative
  // operand resolves against the base (the previous cd's directory), an
  // absolute one ignores it, and `~` always means HOME. Asserting these
  // directly — not only via parseCdChains — isolates a regression that
  // ignored `base` and resolved against process.cwd().
  equal(expandCdTarget("sub", "/base"), "/base/sub");
  equal(expandCdTarget("..", "/base/sub"), "/base");
  equal(expandCdTarget(".", "/base"), "/base");
  equal(expandCdTarget("/abs", "/base"), "/abs");
  equal(expandCdTarget("~", "/base"), os.homedir());
});

const maskShape = (s: string) => unquotedMask(s).map((b) => (b ? "1" : "0")).join("");

test("unquotedMask: the module's single quote model, pinned directly", () => {
  // The mask is load-bearing: `maskQuoted` blanks exactly these characters so a
  // quoted MENTION is not read as command text, and review-enforcer's
  // matchUnquoted/countUnquotedMergeVerbs share it. Indirect coverage through
  // extractPrNumber cannot see the model itself.
  equal(maskShape("gh pr merge 138"), "111111111111111", "unquoted text stays visible");
  equal(maskShape('x"gh pr merge 1"'), "1" + "0".repeat(15), "a double-quoted span is blanked");
  equal(maskShape("x'gh pr merge 1'"), "1" + "0".repeat(15), "a single-quoted span is blanked");
  equal(maskShape("it\\'s cd /a"), "11111111111", "a backslash escapes the quote — the span stays open text");
  equal(maskShape("'a\\'b'"), "000010", "a backslash inside SINGLE quotes is literal — the quote still closes");
  equal(maskShape('"a\\"b" cd /a'), "000000111111", "a backslash-escaped quote does NOT close the span");
  equal(maskShape("echo 'unterminated"), "11111" + "0".repeat(13), "an unterminated quote masks the tail");
  equal(unquotedMask("a\"b\"c").length, 5, "mask length === command length (offsets preserved)");
});

// ── the fail-open property (the reason #960 is severity-high) ──

section("extractCdPath — fail-open regression (worktree root, never session root)");

test("a git op whose cd points at a worktree resolves to THAT worktree, not the session root", () => {
  // The #960 end-to-end shape: session cwd = a clean repo, the op targets a
  // linked worktree via a NEWLINE-separated cd. The old parser returned null,
  // the caller substituted the session root, the diff came back empty, and the
  // empty-scope path ALLOWED unverified content. `null` is the fail-open
  // trigger, so pin BOTH: not null, and specifically the worktree path.
  const worktree = "/tmp/wt-966-fail-open-probe";
  for (const op of ["git push", "git commit -m y", "git commit -m y && git push"]) {
    const resolved = extractCdPath(`cd ${worktree}\n${op}`);
    ok(resolved !== null, `newline-cd must resolve (op: ${op}) — null ⇒ session-root fallback`);
    equal(resolved, resolvePath(worktree), `must resolve to the worktree (op: ${op})`);
  }
});

// ── extractRepoFlag ───────────────────────────────────

section("extractRepoFlag — --repo / -R / --repo=");

test("--repo owner/name, -R owner/name, --repo=owner/name", () => {
  equal(extractRepoFlag("gh pr merge 123 --repo acme/widget"), "acme/widget");
  equal(extractRepoFlag("gh pr merge 123 -R acme/widget --squash"), "acme/widget");
  equal(extractRepoFlag("gh pr merge 123 --repo=acme/widget"), "acme/widget");
});

test("flag before the PR number", () => {
  equal(extractRepoFlag("gh pr merge --repo acme/widget 123"), "acme/widget");
});

test("absent → null (GH_REPO= is the env helper's job)", () => {
  equal(extractRepoFlag("gh pr merge 123"), null);
  equal(extractRepoFlag("GH_REPO=acme/widget gh pr merge 123"), null);
});

test("does not match git remote args", () => {
  equal(extractRepoFlag("git remote add origin git@github.com:a/b.git"), null);
});

test("extractRepoFlag: HOST/OWNER/REPO normalizes (old RE copy gave 'github.com/owner')", () => {
  equal(extractRepoFlag("gh pr merge 123 --repo github.com/owner/repo"), "owner/repo");
  // The strip is HOST-AGNOSTIC, and an EMPTY segment is not a segment.
  equal(extractRepoFlag("gh pr merge 123 --repo a/b/c"), "b/c");
  equal(extractRepoFlag("gh pr merge 123 --repo a//b"), null);
});

test("extractRepoFlag fails closed on the unmodelled value forms", () => {
  // The flag entry's own fail-closed classes (the `GH_REPO=` 4-segment case is
  // pinned above). verification-gate's merge window relies on a QUOTED value
  // degrading to no-match → verify, never a skip, so the null is load-bearing.
  equal(extractRepoFlag('gh pr merge --repo "a/b"'), null, "a quoted value is not captured");
  equal(extractRepoFlag("gh pr merge --repo= 123"), null, "an empty value is not an identity");
  equal(extractRepoFlag("gh pr merge 123 --repo a/b/c/d"), null, "4 segments = garbage identity");
  equal(extractRepoFlag("gh pr merge 123 --repo github.com:443/owner/repo"), null, "a port-like host is not a host segment");
  // The SAFE half of the MENTION gap below is assertable today and stays true
  // under the proposed fix: a REAL flag outranks a quoted mention, because the
  // scan takes its FIRST match and the real flag precedes the prose.
  equal(extractRepoFlag('gh pr merge 1 --repo acme/widget --body "see --repo evil/repo"'), "acme/widget");
  // KNOWN GAP (reported, module fix pending): the flag scan is QUOTE-UNAWARE, so
  // a `--repo` MENTION in quoted prose, with NO real flag before it, IS captured —
  // extractRepoFlag('gh pr merge 1 --body "see --repo evil/repo"') returns
  // "evil/repo". review-enforcer calls this on the RAW command, so the merge is
  // attributed to the MENTIONED repo and `readReviewRecord` reads another repo's
  // evidence (verification-gate is shielded: mergeCommandWindow blanks quoted
  // spans first). The fix is to run the scan on `maskQuoted(command)`. No
  // assertion is added for THAT half — it would fail, and asserting "evil/repo"
  // would cement the fail-open (the safe half above IS pinned).
});

// ── extractGhRepoEnv ──────────────────────────────────

section("extractGhRepoEnv — GH_REPO= prefix");

test("GH_REPO=owner/name prefix", () => {
  equal(extractGhRepoEnv("GH_REPO=acme/widget gh pr merge 123"), "acme/widget");
});

test("absent → null", () => {
  equal(extractGhRepoEnv("gh pr merge 123"), null);
});

test("a GH_REPO= word that is not an assignment prefix → null", () => {
  // `X=GH_REPO=a/b` assigns the literal string `GH_REPO=a/b` to X — it does NOT
  // set GH_REPO, so no repo may be read out of it.
  equal(extractGhRepoEnv("X=GH_REPO=a/b gh pr merge 123"), null);
});

test("extractGhRepoEnv: HOST/OWNER/REPO normalizes (old RE copy gave 'github.com/owner')", () => {
  equal(extractGhRepoEnv("GH_REPO=github.com/owner/repo gh pr merge 123"), "owner/repo");
  // The strip is HOST-AGNOSTIC — not a `github.com` special case.
  equal(extractGhRepoEnv("GH_REPO=a/b/c gh pr merge 123"), "b/c");
});

test("#966 divergence: a 4-segment garbage identity fails closed (old RE copy gave 'a/b')", () => {
  equal(extractGhRepoEnv("GH_REPO=a/b/c/d gh pr merge 123"), null);
});

test("priority: --repo beats GH_REPO= when both are present", () => {
  const command = "GH_REPO=env/repo gh pr merge 123 --repo flag/repo";
  equal(extractRepoFlag(command) ?? extractGhRepoEnv(command), "flag/repo");
});

// ── extractPrNumber ───────────────────────────────────

section("extractPrNumber — gh pr merge PR extraction");

test("plain, flags-follow, and cd-prefixed merges", () => {
  equal(extractPrNumber("gh pr merge 138"), 138);
  equal(extractPrNumber("gh pr merge 138 --repo owner/repo"), 138);
  equal(extractPrNumber("cd /tmp && gh pr merge 138"), 138);
});

test("the number must sit AT the verb: a flag-before-positional spelling declines (null)", () => {
  // Adjudicated on the MERGE of #966 (the shared copy was verification-gate's
  // flags-tolerant token scan; review-enforcer landed #1007/#1021 on main in the
  // meantime and pinned the opposite answer). Evidence, not preference: a token
  // scan takes the first pure-integer token after the verb, so a flag VALUE can
  // stand in for the positional — `gh pr merge --body 999 42` read 999 while gh
  // merges 42, and the registry path consults this function FIRST, so the gate
  // read ANOTHER PR's evidence (the fail-open class #1021 fixed). Declining is
  // fail-CLOSED at both call sites: review-enforcer falls back to its value-flag
  // aware positional selector, verification-gate resolves no head (→ verify).
  equal(extractPrNumber("gh pr merge --squash 123"), null);
  equal(extractPrNumber("gh pr merge -R x/y --squash 7"), null);
  equal(extractPrNumber("cd /wt && gh pr merge --repo x/y 42"), null);
  // A numeric flag value must never be read as the positional (the wrong-PR read).
  equal(extractPrNumber("gh pr merge --body 999 42"), null);
});

test("gh's global -R/--repo before the verb is accepted", () => {
  equal(extractPrNumber("gh -R owner/name pr merge 123"), 123);
  equal(extractPrNumber("GH_REPO=a/b gh --repo=owner/name pr merge 456"), 456);
  // The `-R=` spelling and the SPACE form of the global `--repo` are admitted
  // too — verification-gate matches this exported grammar directly.
  equal(extractPrNumber("gh -R=x/y pr merge 123"), 123);
  ok(GH_PR_MERGE_VERB.test("gh --repo x/y pr merge 1"), "global space-form --repo");
  // KNOWN GAP (documented divergence): the GLOBAL flag value admits ONE slash
  // segment, so `gh -R github.com/owner/repo pr merge 123` does not match, while
  // the POST-verb `--repo github.com/owner/repo` normalizes 3 segments. It is
  // conservative (review-enforcer's positional fallback resolves it;
  // verification-gate resolves no head → verify), so it is recorded, not pinned.
});

test("flag values never tokenize as the PR number", () => {
  equal(extractPrNumber("gh pr merge --repo 123/owner"), null);
});

test("non-merge / absent / non-numeric → null", () => {
  equal(extractPrNumber("gh pr create 138"), null);
  equal(extractPrNumber("gh pr merge"), null);
  equal(extractPrNumber("gh pr merge abc"), null);
  equal(extractPrNumber("git commit -m x"), null);
  equal(extractPrNumber("git push"), null);
});

test("a CHAINED integer is never the PR number (digits must sit AT the verb)", () => {
  // review-enforcer calls this on the RAW command (verification-gate passes a
  // pre-cut mergeCommandWindow), so `|| exit 1` / `; exit 1` must not read as
  // the PR. Old verification-gate on a raw command returned 1 here.
  equal(extractPrNumber("gh pr merge --squash || exit 1"), null);
  equal(extractPrNumber("gh pr merge -s -d; exit 1"), null);
  equal(extractPrNumber("gh pr merge 42\nexit 0"), 42);
  equal(extractPrNumber("gh pr merge 123 --squash || exit 1"), 123, "the merge's OWN number still wins");
});

test("a compound command resolves the FIRST verb (number and repo stay on the same verb)", () => {
  // The match is NON-GLOBAL, so it is the FIRST unquoted `gh pr merge`. This is
  // load-bearing: review-enforcer's repo attribution ALSO takes the first verb,
  // and if this ever took the LAST, the number and the repo could be read from
  // DIFFERENT verbs — the wrong-PR evidence read the composition exists to
  // prevent (see resolveRepoContext's compound-command guard).
  equal(extractPrNumber("gh pr merge 111; gh pr merge 222"), 111);
  equal(extractPrNumber("gh pr merge 111 && gh pr merge 222"), 111);
  equal(extractPrNumber("gh pr merge 111\ngh pr merge 222"), 111);
  // A FIRST verb with no digits still wins, so a LATER verb's digits are not
  // this merge's PR (the shape the compound-command guard refuses to gate on).
  equal(extractPrNumber("gh pr merge <url>; gh pr merge 123"), null);
});

test("a bracketed subshell merge still yields the PR (#426 cycle-4 contract)", () => {
  // review-enforcer gates on extractPrNumber alone: `(cd … && gh pr merge 7)`
  // MUST route into the merge-registry path — a trailing `)` rejected by a
  // strict integer-token test would silently skip the gate (found by this
  // suite's first run against the unified helper). `$(gh pr merge 8)` is the
  // same shape with the verb directly after an opener — the old review-enforcer
  // regex matched it (unanchored) and the gate must not silently stop seeing it.
  equal(extractPrNumber('(cd "$HOME/dmeer-wt" && gh pr merge 7)'), 7);
  equal(extractPrNumber("$(gh pr merge 8)"), 8);
});

test("a trailing brace glued to the number still yields the PR — a DELIBERATE wide match", () => {
  // `gh pr merge 9}` is not a valid gh spelling (gh would receive the argument
  // `9}`), so this is a wide match chosen so a subshell/brace-adjacent verb is
  // not silently skipped: the gate errs toward gating. Its own test so the wide
  // match is visible rather than buried in a "bracketed subshell" case.
  equal(extractPrNumber("gh pr merge 9}"), 9);
});

test("a quoted-prose merge is NOT matched for the pinned shapes", () => {
  // Not a fix for #960's general quoted-prose issue — just the boundary the
  // verb grammar keeps: a QUOTE before `gh` is prose, not an invocation.
  equal(extractPrNumber('git log -S "gh pr merge 42"'), null);
  equal(extractPrNumber("git log -S 'gh pr merge 42'"), null);
});

test("masking: a quoted verb is not this command's merge, and a quote-spliced token is refused", () => {
  // review-enforcer's #1007/#1021 pins, restated in the one suite for the one
  // copy: the mention in the quoted assignment is NOT the merge verb, so the
  // real verb's URL (no digits at it) yields null, and the registry path falls
  // to the positional selector instead of gating the mentioned number.
  equal(extractPrNumber('x="say gh pr merge 1"; gh pr merge <url> --admin'), null);
  equal(extractPrNumber('git commit -m "see gh pr merge 138"'), null);
  // A quoted positional was already null (the verb needs bare digits) and must stay so.
  equal(extractPrNumber('gh pr merge "138"'), null);
  // bash concatenates `"1"38` into `138`, so the digits the mask leaves visible are a
  // FRAGMENT of the real argument — refused rather than guessed, in either direction.
  equal(extractPrNumber('gh pr merge "1"38'), null);
  equal(extractPrNumber('gh pr merge 1"38"'), null);
  // STATED LIMIT (doc comment): the adjacency guard covers `'`/`"` only, so an
  // ANSI-C splice still reads the pre-splice digits — bash sees 138. Pinned as
  // the KNOWN residual so a change to the guard cannot alter it silently; the
  // dequote-aware positional follow-up is #1021.
  equal(extractPrNumber("gh pr merge 1$'38'"), 1, "ANSI-C splice is the known #1021 limit");
  // OFFSET sensitivity: `maskQuoted` blanks quoted regions IN PLACE (same
  // length, same offsets), so the guard lookup for a quote ADJACENT to the
  // digits must not be shifted onto a non-quote. A mask that COLLAPSED quoted
  // regions instead of blanking them (verified: collapsing each region to one
  // space) makes this read as a splice and returns 1 instead of null — this is
  // the assertion that detects that mutation. (The preceding-quoted-region
  // positive control is the `(cd "$HOME/…" && gh pr merge 7)` case above.)
  equal(extractPrNumber('echo "q"; gh pr merge 1"38"'), null);
});

test("GH_PR_MERGE_VERB is the shared verb grammar (exported)", () => {
  ok(GH_PR_MERGE_VERB.test("gh pr merge 1"));
  ok(GH_PR_MERGE_VERB.test("gh -R owner/name pr merge 1"));
  ok(!GH_PR_MERGE_VERB.test("gh pr create"));
  // Shell openers are real invocations and verification-gate matches this
  // grammar RAW (no masking), so pin the left boundary directly: backtick and
  // `(` are admitted, a QUOTE is prose and is deliberately NOT admitted.
  ok(GH_PR_MERGE_VERB.test("`gh pr merge 7`"), "a backtick opener is an invocation");
  equal(extractPrNumber("`gh pr merge 7`"), 7);
  ok(GH_PR_MERGE_VERB.test("(gh pr merge 7"), "a subshell opener is an invocation");
  ok(!GH_PR_MERGE_VERB.test('"gh pr merge 1'), "a double quote before gh is prose");
  ok(!GH_PR_MERGE_VERB.test("'gh pr merge 1"), "a single quote before gh is prose");
  // KNOWN GAP (reported, module fix pending): the grammar's `\s` also crosses a
  // NEWLINE, so `gh pr` ⏎ `merge 138` reads 138 although bash runs `gh pr` and
  // then a separate command — a false POSITIVE (it over-gates), hence
  // conservative; the fix is `[ \t]` for the inter-word/gap whitespace. No
  // assertion is added: it would fail today, and pinning 138 would cement it.
});

// ── Code-review regression pins (#987 review) ─────────
// Each defect below was found in review AFTER the promotion was written, and
// each failed OPEN: a fabricated/wrong root attested as resolved, or a repo
// identity taken from the session cwd while the op ran elsewhere.

section("code-review regression pins (#987)");

test("cd ~/$X is unattributable — never the fabricated <home>/$X", () => {
  // Guard-order bug: `~/` was expanded BEFORE the `$`/backtick guard, so an
  // unexpanded variable landed in a root the consumers hash and register.
  const info = parseCdChains("cd ~/$X && git commit");
  equal(info.last, null);
  equal(info.unattributable, true);
  // Control: a plain `~/dir` stays resolvable (the guard must not over-reach).
  equal(extractCdPath("cd ~/wt && git commit"), resolvePath(os.homedir(), "wt"));
});

test("a backslash-newline inside an inline comment is NOT a continuation", () => {
  // bash ends the comment at the newline, so the NEXT LINE is a real command.
  // Joining them hid the real cd and reported a wrong root attributably.
  equal(extractCdPath("# note \\\ncd /b && git commit"), resolvePath("/b"));
  equal(extractCdPath("cd /a && true # note \\\ncd /b && git commit"), resolvePath("/b"));
  // Control: outside a comment the same `\` + newline IS a continuation.
  equal(extractCdPath("cd /b \\\n&& git commit"), resolvePath("/b"));
});

test("an apostrophe inside a double-quoted argument cannot desync the quote model", () => {
  // `-m "don't"` used to latch the SINGLE-quote state, so the continuation was
  // not stripped and the cd target kept the backslash → unattributable.
  const info = parseCdChains('echo "don\'t" && cd a \\\n&& git commit');
  equal(info.last, resolvePath(logicalBase(), "a"));
  equal(info.unattributable, false);
});

test("a cd opened by a backtick is unattributable, not 'no cd at all'", () => {
  // `` `cd /a && op` `` runs in a command substitution — an op there is NOT in
  // the session cwd, so reporting `{null, false}` let consumers fall back to it.
  const info = parseCdChains("`cd /a && git commit`");
  equal(info.last, null);
  equal(info.unattributable, true);
  // The cost of counting the opener, measured and accepted: a CLOSED
  // substitution followed by a resolvable cd is declined too, though bash runs
  // the op in /b — the segment scan never learns where the op sits. This is the
  // SAME conservative class the `$(…)` spelling has always had (last line), and
  // it is FAIL-CLOSED: no root is attested, review-enforcer asks for an absolute
  // cd, verification-gate substitutes its session root exactly as it did before.
  // `{"/b", false}` would instead attest a root for an op that may be inside
  // the substitution — the fail-open this pin exists to prevent.
  equal(parseCdChains("`cd /a` && cd /b && git commit").unattributable, true);
  equal(parseCdChains("$(cd /a) && cd /b && git commit").unattributable, true);
});

test("an ESCAPED separator does not start an inline comment (fail-open fix)", () => {
  // bash: `echo x\ #y` is ONE word — the `#` is inside it, not a comment start.
  // An escape-unaware predicate read the `#` as a comment, dropped the rest of
  // the line, and reported a WRONG root ATTRIBUTABLY (the #960 class).
  equal(parseCdChains("cd /a && echo x\\ #y && cd /b && git commit").last, resolvePath("/b"));
  // With a line continuation the joined `cd /b` is an ARGUMENT to echo, so bash
  // runs the op in /a: the module must NOT attest /b — it declines instead.
  const cont = parseCdChains("cd /a && echo x\\ #y \\\ncd /b; git commit");
  equal(cont.last, null);
  equal(cont.unattributable, true);
  // Controls: `\#` is a literal `#`, and a real comment still ends its line.
  equal(parseCdChains("cd /a && echo \\#note && cd /b && git commit").last, resolvePath("/b"));
  equal(parseCdChains("cd /a && true # note \\\ncd /b && git commit").last, resolvePath("/b"));
});

test("an escaped quote cannot desync the scanner (outside-quote escapes)", () => {
  // bash: `echo it\'s` is one word; the `\'` used to latch the SINGLE-quote
  // state, swallow the rest of the command, and leave the cd unseen — so both
  // consumers fell back to the session root for an op that ran in /b.
  const info = parseCdChains("echo it\\'s && cd /b && git commit");
  equal(info.last, resolvePath("/b"));
  equal(info.unattributable, false);
});

test("extractRepoFlag: the ATTACHED short form is a real gh spelling (#931/#993)", () => {
  // gh's pflag accepts `-Rowner/repo`; review-enforcer's deleted copy supported
  // it explicitly. Dropping it sent resolveRepoContext to the session-cwd repo
  // while gh merged the -R target — the #426 wrong-repo evidence read.
  equal(extractRepoFlag("gh -Racme/widget pr merge 1"), "acme/widget");
  equal(extractRepoFlag("gh -R=acme/widget pr merge 1"), "acme/widget");
  equal(extractRepoFlag("gh pr merge 1 -Racme/widget"), "acme/widget");
  equal(extractRepoFlag("gh -R acme/widget pr merge 1"), "acme/widget");
  ok(GH_PR_MERGE_VERB.test("gh -Racme/widget pr merge 1"), "the shared grammar admits it too");
  // The flag is still a whole TOKEN: an embedded lookalike is not an identity.
  equal(extractRepoFlag("gh pr merge 1 --body=x--repo a/b"), null);
  equal(extractRepoFlag("gh pr merge 1 --body=see--repo x/y"), null);
});

// ── Results ───────────────────────────────────────────

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
