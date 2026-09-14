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

// ── #960 truth table ──────────────────────────────────

section("extractCdPath — #960 truth table (newline-separated cd)");

test("cd <wt> && <op> → the worktree", () => {
  equal(extractCdPath("cd /a && git commit"), resolvePath("/a"));
});

test("cd <wt> ; <op> → the worktree", () => {
  equal(extractCdPath("cd /a ; git commit"), resolvePath("/a"));
});

test("cd <wt> ⏎ && <op> → the worktree", () => {
  equal(extractCdPath("cd /a\n&& git commit"), resolvePath("/a"));
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

test("a vertical tab does not separate commands, so \\vcd is not a cd", () => {
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
});

test("a `||` alternate WITHOUT an abort never attests the cd's root (cycle-8)", () => {
  // `cd /nonexistent || true && op`: the cd FAILS, `true` succeeds and does not
  // change the cwd, so op runs in the PRE-cd cwd — attesting /nonexistent would
  // be a fail-open. Only exit/return force the op to exist solely in the
  // cd-succeeded branch, which is why the idiom above still resolves.
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
  equal(extractCdPath("cd /a | cat && cd b && git commit"), resolvePath("b"));
  equal(extractCdPath("cd /a | cat && cd .. && git commit"), resolvePath(".."));
  // A piped LATER cd leaves the earlier, effective one in charge.
  equal(extractCdPath("cd /a && cd /b | cat && git commit"), resolvePath("/a"));
  // A piped cd was the ONLY cd → nothing changed the shell's cwd.
  equal(parseCdChains("cd /a | cat && git commit").last, null);
  equal(parseCdChains("cd /a | cat && git commit").unattributable, true);
  equal(parseCdChains("echo x | cd /a && git commit").last, null);
});

test("a lone `&` backgrounds the cd's whole list — its cwd never reaches the op (cycle-8)", () => {
  // bash: `cd /wg/a && true & op` → the AND-OR list is backgrounded, op runs in
  // the pre-cd cwd. `&>`/`2>&1` are redirections and must NOT be split.
  for (const cmd of [
    "cd /a && true & git commit",
    "cd /a && : & git commit",
    "cd /a & git commit",
    "cd /a && git commit &",
  ]) {
    equal(parseCdChains(cmd).last, null, cmd);
    equal(parseCdChains(cmd).unattributable, true, cmd);
  }
  // A `&` BEFORE the cd doés not void it (the next command is still the parent shell).
  equal(extractCdPath("bg & cd /a && git commit"), resolvePath("/a"));
  // Redirections are not command separators.
  equal(extractCdPath("cd /a && git commit 2>&1"), resolvePath("/a"));
  equal(extractCdPath("cd /a && git commit &> /dev/null"), resolvePath("/a"));
});

test("relative operands resolve against bash's LOGICAL cwd, not Node's physical one", () => {
  // bash `cd` is logical by default, so `..` climbs the SYMLINK prefix:
  // from /tmp/link (→ /private/tmp/real) `cd ..` is /tmp, while resolving
  // against Node's physical process.cwd() yields /private/tmp.
  const real = fs.mkdtempSync(resolvePath(os.tmpdir(), "cdparse-logical-"));
  const link = `${real}-link`;
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

test("backslash line continuation is stripped (`cd /wt \\` ⏎ `&& op`)", () => {
  // Old behavior: the trailing `\` was captured → a FABRICATED "/wt \" root.
  equal(extractCdPath("cd /a \\\n&& git push"), resolvePath("/a"));
  equal(extractCdPath("cd /a\\\n&& git push"), resolvePath("/a"));
  equal(extractCdPath("cd /a \\\r\n&& git push"), resolvePath("/a"));
});

test("a line continuation inside SINGLE quotes is literal, not stripped", () => {
  // bash keeps `\<newline>` literal inside single quotes; the quoted span is
  // prose, so no cd is parsed out of it.
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
});

test("a residual leading `-` is bash state, never a path (`cd -`, `cd --help`)", () => {
  equal(extractCdPath("cd --help && git commit"), null);
  equal(parseCdChains("cd --help && git commit").unattributable, true);
});

test("an inline `#` comment is not part of the target", () => {
  equal(extractCdPath("cd /a # note && git commit"), resolvePath("/a"));
  equal(extractCdPath("cd /a #note"), resolvePath("/a"));
  equal(extractCdPath("cd /a#b && git commit"), resolvePath("/a#b"), "mid-word # is literal");
  equal(extractCdPath("cd 'a # b' && git commit"), resolvePath("a # b"), "quoted # is literal");
});

test("`~user` and glob targets are unattributable, not fabricated", () => {
  equal(extractCdPath("cd ~root && git commit"), null);
  equal(extractCdPath("cd /a* && git commit"), null);
  equal(extractCdPath("cd ~ && git commit"), os.homedir(), "plain ~ still resolves");
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
  equal(extractCdPath("git commit && cd /a ;;\n"), null);
  equal(extractCdPath("git commit && cd /a # note"), null);
  equal(extractCdPath("cd /a && git commit && cd /b ;"), null);
  equal(extractCdPath("cd /a && git commit && cd /b\n"), null);
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
});

test("a `cd` inside a pipeline element does not set the effective cwd (fail-open)", () => {
  // bash runs a pipeline element in a subshell: the following op sees the
  // ORIGINAL cwd, so claiming /a would hash the wrong tree.
  equal(extractCdPath("cd /a | cat && git commit"), null);
  equal(parseCdChains("cd /a | cat && git commit").unattributable, true);
  equal(extractCdPath("echo x | cd /a && git commit"), null);
  // ...but a cd OUTSIDE the pipeline still governs the later op.
  equal(extractCdPath("cd /a && cat | grep x && git commit"), resolvePath("/a"));
});

// ── parseCdChains third state ─────────────────────────

section("parseCdChains — the unattributable third state");

test("$VAR / quoted-$( ) targets → last null, unattributable (never guessed)", () => {
  const r1 = parseCdChains('cd "$HOME/x" && git commit');
  equal(r1.last, null, "$ target not guessed");
  equal(r1.unattributable, true, "reported so a caller can skip the cwd fallback");
  const r2 = parseCdChains("cd $WORKTREE && git commit");
  equal(r2.last, null);
  equal(r2.unattributable, true);
});

test("subshell (cd …) → unattributable", () => {
  const r = parseCdChains("(cd /tmp/x && git commit)");
  equal(r.last, null);
  equal(r.unattributable, true, "bash runs the cd; the caller must not trust the session cwd");
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
    ok(resolved !== process.cwd(), "must NOT fall back to the session cwd (the fail-open)");
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

test("#966 divergence: HOST/OWNER/REPO normalizes (old RE copy gave 'github.com/owner')", () => {
  equal(extractRepoFlag("gh pr merge 123 --repo github.com/owner/repo"), "owner/repo");
});

// ── extractGhRepoEnv ──────────────────────────────────

section("extractGhRepoEnv — GH_REPO= prefix");

test("GH_REPO=owner/name prefix", () => {
  equal(extractGhRepoEnv("GH_REPO=acme/widget gh pr merge 123"), "acme/widget");
});

test("absent → null", () => {
  equal(extractGhRepoEnv("gh pr merge 123"), null);
});

test("#966 divergence: HOST/OWNER/REPO normalizes (old RE copy gave 'github.com/owner')", () => {
  equal(extractGhRepoEnv("GH_REPO=github.com/owner/repo gh pr merge 123"), "owner/repo");
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

test("a bracketed subshell merge still yields the PR (#426 cycle-4 contract)", () => {
  // review-enforcer gates on extractPrNumber alone: `(cd … && gh pr merge 7)`
  // MUST route into the merge-registry path — a trailing `)` rejected by a
  // strict integer-token test would silently skip the gate (found by this
  // suite's first run against the unified helper). `$(gh pr merge 8)` is the
  // same shape with the verb directly after an opener — the old review-enforcer
  // regex matched it (unanchored) and the gate must not silently stop seeing it.
  equal(extractPrNumber('(cd "$HOME/dmeer-wt" && gh pr merge 7)'), 7);
  equal(extractPrNumber("$(gh pr merge 8)"), 8);
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
});

test("GH_PR_MERGE_VERB is the shared verb grammar (exported)", () => {
  ok(GH_PR_MERGE_VERB.test("gh pr merge 1"));
  ok(GH_PR_MERGE_VERB.test("gh -R owner/name pr merge 1"));
  ok(!GH_PR_MERGE_VERB.test("gh pr create"));
});

// ── Results ───────────────────────────────────────────

console.log(`\n=== Results: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  console.log("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
