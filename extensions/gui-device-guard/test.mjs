// Regression tests for extensions/gui-device-guard (issue #2249).
//
// The suite loads the REAL ./index.ts through ../main-worktree-guard/module-load-hooks.mjs
// (Node type-stripping + a stubbed @earendil-works/pi-coding-agent — the same shapes
// pi's jiti loader produces) and drives the REAL registered `tool_call` handler. That
// is the #744/#697 lesson: a suite that imports only a helper stays green while index.ts
// is broken and the guard is inert in every session.
//
// Every row below is a declared threat-surface entry from the module header. The BLOCK
// rows pin WHICH rule fired, so a row cannot pass for the wrong reason, and each has an
// ALLOW twin so a guard that blocks everything fails as loudly as one that blocks nothing.
//
// Usage:
//   node extensions/gui-device-guard/test.mjs                          # the suite
//   node extensions/gui-device-guard/test.mjs --classify <command…>    # one classification
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { register, registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const INDEX_TS = join(HERE, "index.ts");

// ── load the real module (shared with the #744 loader harness) ──────────────
const hooks = await import(new URL("../main-worktree-guard/module-load-hooks.mjs", import.meta.url).href);
if (typeof registerHooks === "function") {
  registerHooks({ resolve: hooks.resolve, load: hooks.load });
} else {
  register(new URL("../main-worktree-guard/module-load-hooks.mjs", import.meta.url), import.meta.url);
}
const mod = await import(pathToFileURL(INDEX_TS).href);
const laneMod = await import(new URL("../shared/headless-lane.ts", import.meta.url).href);
const classify = mod.classifyLaunchCommand;
const FAKE = [mod.FAKE_DEVICE_FLAG, mod.FAKE_UI_FLAG].join(" ");

// ── CLI mode (one classification, for a hand check and for the docs) ────────
if (process.argv[2] === "--classify") {
  const cmd = process.argv.slice(3).join(" ");
  console.log(JSON.stringify(classify(cmd), null, 2));
  process.exit(0);
}

let pass = 0;
let fail = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "✅" : "❌"} ${name}${ok || !detail ? "" : ` — ${detail}`}`);
  ok ? pass++ : fail++;
}

// ── hermetic fixture ───────────────────────────────────────────────────────
const FIX = mkdtempSync(join(tmpdir(), "gui-device-guard-"));
const LEDGER = join(FIX, "state", "host-app-launches.jsonl");
const saveEnv = { ...process.env };
function ledgerRows() {
  if (!existsSync(LEDGER)) return [];
  return readFileSync(LEDGER, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
}
function resetLedger() {
  rmSync(LEDGER, { force: true });
}

// ── the classifier: the threat table ───────────────────────────────────────
// [name, command, expected finding count, expected rule|null, expected media]
const ROWS = [
  // L1 — THE INCIDENT, verbatim.
  ["L1 incident: npm exec electron .", "npm exec electron .", 1, "electron", true],
  ["L2 npx electron .", "npx electron .", 1, "electron", true],
  ["L3 bare electron", "electron --inspect=0 .", 1, "electron", true],
  ["L4 local node_modules/.bin/electron", "node_modules/.bin/electron .", 1, "electron", true],
  ["L5 Electron bundle binary (argv shape that ps missed)", "/Applications/DMeer.app/Contents/MacOS/DMeer", 1, "electron", true],
  ["L6 npm exec -- electron", "npm exec -- electron .", 1, "electron", true],
  // L7 — an Electron launch behind a prefix-like word / env prefix.
  ["L7 prefixed: sudo -u root electron .", "sudo -u root electron .", 1, "electron", true],
  ["L8 env-prefixed: FOO=1 electron .", "FOO=1 electron .", 1, "electron", true],
  // L9 — macOS open of a named app: RECORDED, never blocked (media=false).
  ["L9a open -a Safari", "open -a Safari", 1, "open", false],
  ["L9b open -a 'Google Chrome'", 'open -a "Google Chrome" https://x.test', 1, "open", false],
  ["L9c open -b bundle id", "open -b com.apple.Safari", 1, "open", false],
  // ⛔ A PATH IS A MEDIA SHAPE, A NAME IS NOT (review cycle 2, F3). The incident's
  // own app, launched the way a lane launches the bundle it just built. `-a <name>`
  // stays record-only: that is the category-B rejection the scoping comment records.
  ["L9d open an explicit .app PATH", "open ./Build/DMeer.app", 1, "open", true],
  ["L9e open a bare .app in cwd is a path too", "open DMeer.app", 1, "open", true],
  // ⛔ THE SAME BUNDLE IN ITS OTHER SPELLING (review P2). `open -a DMeer.app` and
  // `open DMeer.app` name one bundle; the positional arm above and
  // `appBundleBinary` both decide "is this a bundle" by the `.app` SUFFIX, so the
  // `-a` arm judging only a `/` made the verdict depend on the spelling — a false
  // PASS on the incident's own app, invisible to `select(.media)`. The twin that
  // keeps this honest is L9a: `open -a Safari` (a NAME) stays record-only.
  ["L9f open -a <bundle>.app is a bundle, not a name", "open -a DMeer.app", 1, "open", true],
  // L10 — headed browser runs can present a REAL device picker.
  ["L10a playwright --headed", "npx playwright test --headed", 1, "playwright", true],
  ["L10b PWDEBUG", "PWDEBUG=1 npx playwright test", 1, "playwright", true],
  ["L10c --ui mode", "npx playwright test --ui", 1, "playwright", true],
  // ── L13 (review cycle 1, F2) — WRAPPERS ARE RE-READ, not declared away.
  //     Each of these was measured as `[]` before the recursion landed, i.e. an
  //     undeclared bypass of R2 in a shape AGENTS.md hands lanes routinely.
  ["L13a bash -c", 'bash -c "npm exec electron ."', 1, "electron", true],
  ["L13b sh -c", 'sh -c "electron ."', 1, "electron", true],
  ["L13c sudo bash -lc", 'sudo bash -lc "electron ."', 1, "electron", true],
  ["L13d env -i bash -c (a flag the prefix table does not know)", 'env -i bash -c "electron ."', 1, "electron", true],
  ["L13e eval", 'eval "electron ."', 1, "electron", true],
  ["L13f $( … ) substitution", "echo $(npm exec electron .)", 1, "electron", true],
  ["L13g backtick substitution", "echo \`npm exec electron .\`", 1, "electron", true],
  ["L13h nice -5 electron", "nice -5 electron .", 1, "electron", true],
  // ── L14 — headed-by-default Playwright subcommands and a line-scoped PWDEBUG
  ["L14a playwright codegen", "npx playwright codegen https://x.test", 1, "playwright", true],
  ["L14b playwright open", "npx playwright open https://x.test", 1, "playwright", true],
  ["L14c PWDEBUG exported in an EARLIER segment", "export PWDEBUG=1; npx playwright test", 1, "playwright", true],
  // ── L15 (review cycle 2, F1) — an UNLISTED value-taking flag must not swallow
  //     the command word. Every row below was measured `[]` at the previous head,
  //     i.e. a fail-open in the class the header called "a BYPASS". Two spellings
  //     of the SAME flag disagreed (`sudo -u` fired, `sudo --user` did not), which
  //     is the tell that a table was being trusted as if it were complete.
  ["L15a sudo --user", "sudo --user root electron .", 1, "electron", true],
  ["L15b sudo --user=", "sudo --user=root electron .", 1, "electron", true],
  ["L15c env --unset", "env --unset FOO electron .", 1, "electron", true],
  ["L15d npm exec --prefix <dir>", "npm exec --prefix apps/web electron .", 1, "electron", true],
  ["L15e npm --prefix <dir> exec", "npm --prefix apps/web exec electron .", 1, "electron", true],
  ["L15f yarn --cwd <dir> playwright", "yarn --cwd web playwright test --headed", 1, "playwright", true],
  ["L15g timeout --preserve-status", "timeout --preserve-status 300 electron .", 1, "electron", true],
  ["L15h timeout --signal=", "timeout --signal=KILL 300 electron .", 1, "electron", true],
  ["L15i timeout --kill-after= DUR", "timeout --kill-after=5 300 electron .", 1, "electron", true],
  // L15j/L15k exercise the SECOND line of defence — the fail-safe word scan — with
  // a flag this table has NEVER seen (the case the tables cannot cover by
  // construction). Without the scan these two return `[]`, because an unknown
  // value-taking flag is skipped ONE word and the launch is never classified.
  ["L15j an UNKNOWN sudo flag (fail-safe word scan)", "sudo --some-future-flag value electron .", 1, "electron", true],
  ["L15k an UNKNOWN npm exec flag (fail-safe word scan)", "npm exec --some-future-flag value electron .", 1, "electron", true],
  // ── L16 (review cycle 3, F1) — an UNKNOWN WRAPPER WORD must not hide the
  //     launch. Every row was `[]` before: not "allow" but a silent SKIP, which
  //     also lost the R1 ledger row (the handler returns early on an empty list),
  //     so the diagnosis half of #2249 vanished with the block.
  ["L16a setsid", "setsid npm exec electron .", 1, "electron", true],
  ["L16b caffeinate", "caffeinate -i npm exec electron .", 1, "electron", true],
  ["L16c arch", "arch -arm64 npm exec electron .", 1, "electron", true],
  ["L16d taskset", "taskset -c 0 npm exec electron .", 1, "electron", true],
  ["L16e flock -c <string>", 'flock /tmp/l -c "npm exec electron ."', 1, "electron", true],
  ["L16f script (pass-through wrapper)", "script -q /dev/null npm exec electron .", 1, "electron", true],
  ["L16g a BRACKETED backgrounded launch", "(npm exec electron . &)", 1, "electron", true],
  // ── L17 (review cycle 3, F3) — a `)` inside a QUOTED string must not truncate
  //     the substitution body: this command really does launch Electron.
  ["L17 a quoted ')' inside a substitution", 'echo "$(echo ")"; npm exec electron .)"', 1, "electron", true],
  // ── L18 — `open` does not forward Chromium switches, so a line that carries
  //     them is NOT a mitigation (review cycle 3, minor: it used to allow).
  ["L18 fake switches on an `open` line are not a mitigation",
    "open ./Build/DMeer.app --use-fake-device-for-media-stream --use-fake-ui-for-media-stream",
    1, "open", true],
  // ── L19 (review cycle 3, F1's CLASS) — a wrapper word the table has never
  //     heard of must not hide a launch. L16 named a few instances; these rows pin
  //     the STRUCTURAL rule that closes the rest: a package-runner anywhere in the
  //     segment is a launch shape whatever heads it (`runnerNested`), and a `-c`
  //     wrapper that consumes its whole segment (`su -c "…"`, cwi === -1) is
  //     still re-read. Every row was `[]` — no block AND no ledger row — before.
  ["L19a xvfb-run + runner (a cell's headed-display idiom)", "xvfb-run -a npm exec electron .", 1, "electron", true],
  ["L19b strace + runner", "strace -f npm exec electron .", 1, "electron", true],
  ["L19c su -c <string> (the wrapper consumes the whole segment)", 'su -c "npm exec electron ."', 1, "electron", true],
  ["L19d xvfb-run wrapping a BARE launch word", "xvfb-run -a electron .", 1, "electron", true],
  ["L19e gdb --args wrapping a bare launch word", "gdb --args electron .", 1, "electron", true],
  ["L19f xvfb-run + npx playwright --headed", "xvfb-run npx playwright test --headed", 1, "playwright", true],
  ["L19g runuser -c <string>", 'runuser -u x -c "npm exec electron ."', 1, "electron", true],
  // L19h/L19i name NO wrapper at all — they are the rows that pin the structural
  // rule itself (a runner anywhere in the segment), so deleting that rule cannot
  // leave the suite green. Any future wrapper word behaves like these.
  ["L19h an UNLISTED wrapper word + runner (structural rule)", "eatmydata npm exec electron .", 1, "electron", true],
  ["L19i a SECOND unlisted wrapper word + runner", "proxychains4 npm exec electron .", 1, "electron", true],
  // ── L20 (review cycle 4, F1) — a STANDALONE operator token is SEPARATION, not
  //     a command word. `stripLeadingMetachars` only normalised a token's inside,
  //     so a token that WAS `(`/`{`/`!` became "" and "" was taken as the command
  //     word: no finding, and — because the handler returns early on an empty
  //     list — no ledger row either. Every row here was `[]` before. L16g keeps
  //     the ATTACHED spelling green; L20a is its spaced twin, so neither spelling
  //     can regress alone.
  ["L20a a SPACED bracketed backgrounded launch", "( electron . &)", 1, "electron", true],
  ["L20b a spaced brace group", "{ electron . ; }", 1, "electron", true],
  ["L20c a spaced bracketed playwright launch", "( playwright test --headed &)", 1, "playwright", true],
  ["L20d a spaced `!` negation in front of the launch", "! electron .", 1, "electron", true],
  // L20e is the NESTED spelling: once the outer operator is dropped, the inner
  // `(` is token 0 and is skipped by `TRANSPARENT` — the entry the header has
  // always declared and which cycle 3 measured as unreachable. It names a BARE
  // launch word on purpose: with a package-runner inside, the structural rule
  // rescues the segment and nesting would stay invisible either way.
  ["L20e NESTED spaced brackets around a bare launch word", "( ( electron . &) &)", 1, "electron", true],
  // ── ALLOW rows: none of these may be refused ──────────────────────────────
  ["A1 plain grep", "grep -rn TODO src/", 0, null, false],
  ["A2 an ELECTRON MENTION inside quotes is not a launch", 'echo "npm exec electron ."', 0, null, false],
  ["A3 a mention in a commit message", "git commit -F - <<'EOF'\nelectron . is what broke\nEOF", 0, null, false],
  ["A4 headless playwright (the friction row)", "npx playwright test", 0, null, false],
  ["A5 open with no app flag", "open .", 0, null, false],
  ["A6 a path merely NAMING electron", "ls /usr/lib/electron/", 0, null, false],
  ["A7 electron as a non-command argument", "rg electron .", 0, null, false],
  ["A8 npm run of an unrelated script", "npm run build", 0, null, false],
  ["A9 a second, innocent segment after a launch", "true && ls -la", 0, null, false],
  // A10/A11 are the twins of L13/L14: the recursion must not turn a MENTION or a
  // benign wrapper into a refusal (the false-BLOCK class L/A2/A3 already guard).
  ["A10 a SINGLE-QUOTED substitution is literal text, not a launch", "echo '$(npm exec electron .)'", 0, null, false],
  ["A11 a benign bash -c", 'bash -c "ls -la"', 0, null, false],
  ["A12 headless playwright with an explicit PWDEBUG=0", "PWDEBUG=0 npx playwright test", 0, null, false],
  // A13 is the natural twin of L15d and the one that MUST stay clean: installing a
  // dependency is not launching it, and it is a shape every lane runs.
  ["A13 npm install electron is an INSTALL, not a launch", "npm install electron", 0, null, false],
  ["A14 npm exec --prefix= is the self-contained spelling", "npm exec --prefix=apps/web electron .", 1, "electron", true],
  ["A15 a plain argument naming electron stays clean", "rg electron .", 0, null, false],
  // A17–A20 are the twins of L16/L17: widening the wrapper set must not make a
  // benign wrapper or a benign quoted paren fire.
  ["A17 caffeinate wrapping ls", "caffeinate -i ls", 0, null, false],
  ["A18 setsid wrapping true", "setsid true", 0, null, false],
  ["A19 a bracketed backgrounded ls", "(ls &)", 0, null, false],
  ["A20 a quoted ')' in a benign substitution", 'echo "$(ls ")")"', 0, null, false],
  // A26–A27 are the ALLOW twins of L20: dropping a standalone operator token must
  // not turn a benign group or a shell negation of a benign command into a
  // refusal (the false-BLOCK direction is a defect in its own right).
  ["A26 a spaced brace group around ls", "{ ls -la ; }", 0, null, false],
  ["A27 a `!` negation of a benign command", "! ls -la", 0, null, false],
  // A28/A29 are review cycle 4's minor: `command -v`/`-V` LOOKS UP a name, it does
  // not run it — the comparable (Claude Code's bash permissions) exempts the query
  // form explicitly, and refusing `command -v electron` was a false block.
  ["A28 `command -v` is a lookup, not a launch", "command -v electron", 0, null, false],
  ["A29 `command -V` is a lookup, not a launch", "command -V npm exec electron .", 0, null, false],
  // A21–A23 are the twins of L19: the runner-wide scan must not turn a plain
  // search, a benign wrapper, or a benign `-c` body into a refusal.
  ["A21 a search whose pattern NAMES the launch stays clean", "rg -n electron src/", 0, null, false],
  ["A22 xvfb-run wrapping ls", "xvfb-run -a ls", 0, null, false],
  ["A23 su -c with a benign body", 'su -c "ls"', 0, null, false],
  ["A24 an unlisted wrapper around a NON-launch", "eatmydata ls -la", 0, null, false],
  // A25 is also a CRASH pin: a segment with NO command word at all (`FOO=1`, `sudo`
  // alone, `nice -n 5`) makes `commandWordIndex` return -1, and the exec runner was
  // read with that index — `basename(toks[-1])` threw `Cannot read properties of
  // undefined` out of the `tool_call` pre-hook, i.e. EVERY lane's bash call failed
  // on a bare assignment line. A thrown error fails this row, so the guard cannot
  // be deleted again without the suite going red.
  ["A25 a bare assignment segment (no command word) does not throw", "FOO=1", 0, null, false],
  ["A16 a comment is not argv", 'electron . # --use-fake-device-for-media-stream --use-fake-ui-for-media-stream', 1, "electron", true],
  // ── L21 (review cycle 5, F1) — an option's argument ATTACHED to its short flag
  //     is the same argument. `tokenize` collapses `bash -c"…"` to ONE token
  //     (`-cnpm exec electron .`), which is neither the exact flag nor a bare `-c`
  //     cluster, so it was skipped as an ordinary flag and no argument ever reached
  //     the wrapper recursion: `[]` — no block AND no ledger row. Every row here
  //     was measured `[]` at the previous head; `-cCMD` is a legal, common spelling
  //     of the very idiom the header says is recursed into. The control rows
  //     (L13a/L13c, the SEPARATED spelling) keep both spellings from regressing
  //     alone. A30/A31 are the ALLOW twins.
  ["L21a bash -c\"<cmd>\" (ATTACHED argument)", 'bash -c"npm exec electron ."', 1, "electron", true],
  ["L21b sh -c'<cmd>' (attached, single-quoted)", "sh -c'electron .'", 1, "electron", true],
  ["L21c an attached shell argument behind a prefix", 'nohup bash -c"npm exec electron ." &', 1, "electron", true],
  ["L21d an attached shell argument in a later segment", 'x=1; bash -c"npm exec electron ."', 1, "electron", true],
  ["L21e an attached argument on a `-lc` cluster", 'bash -lc"electron ."', 1, "electron", true],
  ["L21f flock -c\"<cmd>\" (the wrapper consumes the WHOLE segment)", 'flock -c"npm exec electron ."', 1, "electron", true],
  // The same root on the SECOND rule. `open -a"Google Chrome"` was `[]`: not refused
  // (correct — a NAMED app is record-only, that is the recorded category-B decision)
  // but not RECORDED either, which loses R1 — the half of #2249 that would have cut
  // the incident to one `jq` lookup. media=false on both, deliberately: L9a–L9c are
  // the same verdicts for the separated spelling.
  ["L21g open -a\"<name>\" (attached; RECORDED, never refused)", 'open -a"Google Chrome" https://x.test', 1, "open", false],
  ["L21h open -a<name> (attached, no space)", "open -aDMeer", 1, "open", false],
  // ── L22 (review cycle 5, F2) — a `<<` INSIDE A COMMENT is not a redirect. The
  //     heredoc scanner read raw lines with only the quote model, so a comment
  //     MENTIONING the idiom opened a heredoc, found no terminator, and deleted
  //     every following line: the launch was neither blocked nor recorded.
  ["L22a a `<<` in a comment must not delete the launch after it",
    "# usage: write a file with cat <<EOF\nnpm exec electron .", 1, "electron", true],
  ["L22b a trailing comment carrying `<<`", "true # see cat <<EOF\nnpm exec electron .", 1, "electron", true],
  // A30–A33 are the twins of L21/L22: normalising attached arguments and skipping a
  // commented `<<` must not turn a benign wrapper or a heredoc BODY into a refusal,
  // and the terminator rule must not change in either direction. A33 pins the case
  // the review warned about: `EOF # done` does NOT terminate a heredoc in `sh`, so
  // the text after it really is data — removing it must stay data-on-both-sides.
  ["A30 an attached shell argument with a benign body", 'bash -c"ls -la"', 0, null, false],
  ["A31 a heredoc BODY naming the launch stays data",
    "cat > /tmp/n.md <<'EOF'\nnpm exec electron .\nEOF", 0, null, false],
  ["A32 a heredoc whose TERMINATOR carries a trailing comment is still unterminated",
    "cat > /tmp/n.md <<'EOF'\nbody\nEOF # done\nnpm exec electron .", 0, null, false],
  ["A33 open -R (a boolean short flag, not an attached app)", "open -R .", 0, null, false],
  // ── L23 (round 7, P1-1 and P2-4) — the `open` argument is handed to an OPTION
  //     LETTER, and a plain word is never a flag. The one predicate that replaced
  //     `tok[1] === "a" || tok[1] === "b"` fixes BOTH directions of the same bug:
  //     any bare `<Name>.app` whose second letter is `a`/`b` was a FALSE PASS
  //     (`media:false`, `decision:"record"`, ledger identity `njo.app`), and
  //     `open -na <name>` — a getopt CLUSTER, the documented "named app, new
  //     instance" idiom — was `[]`, losing R1's row entirely. L9d/L9e are the
  //     same invariant in the one spelling the old predicate could not intercept;
  //     L23c keeps them from regressing alone.
  ["L23a open a bare .app whose 2nd letter is `a` (was media:false)", "open Banjo.app", 1, "open", true],
  ["L23b open a bare .app whose 2nd letter is `b` (was media:false)", "open Baz.app", 1, "open", true],
  ["L23c the `./` twin of L23a (the row that was already green)", "open ./Banjo.app", 1, "open", true],
  ["L23d open -na <name> (a CLUSTER; R1's row must exist)", 'open -na "Google Chrome" https://x.test', 1, "open", false],
  ["L23e open -nb <bundle id> (the same cluster, `b`)", "open -nb com.example.app", 1, "open", false],
  // ── L24 (round 7, P1-2) — a runner ALIAS and a version PIN are the same
  //     program. `bunx` was listed and `bun x` was not (Bun's own docs: "bunx is an
  //     alias for bun x"), and every `@version` payload missed the verbatim
  //     `head === "electron"` / `LAUNCH_WORDS` comparisons. Both were `[]`: no
  //     refusal AND no ledger row. A36/A41 are the ALLOW twins that keep the
  //     widened runner set from turning an INSTALL or a script run into a launch.
  ["L24a bun x electron . (bunx is an ALIAS for bun x)", "bun x electron .", 1, "electron", true],
  ["L24b bun x playwright --headed", "bun x playwright test --headed", 1, "playwright", true],
  ["L24c mise exec -- <cmd>", "mise exec -- electron .", 1, "electron", true],
  ["L24d asdf exec <cmd>", "asdf exec electron .", 1, "electron", true],
  ["L24e npx electron@30 . (a version pin is not another program)", "npx electron@30 .", 1, "electron", true],
  ["L24f npm exec electron@latest -- .", "npm exec electron@latest -- .", 1, "electron", true],
  ["L24g npx playwright@1.50.0 test --headed", "npx playwright@1.50.0 test --headed", 1, "playwright", true],
  // ── L25 (round 7, P1-3) — an argument that EXECUTES is re-read, whoever
  //     declared it a value. `env -S` was in `PREFIX_VALUE_FLAGS` (the prefix loop
  //     consumed it and never looked at it) and absent from
  //     `COMMAND_STRING_FLAGS` (the table built for exactly this); the runner
  //     family's `-c/--call` had no row at all. All were `[]`. A34/A35 are the
  //     ALLOW twins: a benign command string must not become a refusal.
  ["L25a env -S \"<cmd>\" (the value EXECUTES)", 'env -S "npm exec electron ."', 1, "electron", true],
  ["L25b env --split-string=<cmd> (self-contained long spelling)", "env --split-string='npm exec electron .'", 1, "electron", true],
  ["L25c sudo env -S (the wrapper is NOT at token 0)", 'sudo env -S "electron ."', 1, "electron", true],
  ["L25d npm exec -c <cmd> (npm's documented --call)", 'npm exec -c "electron ."', 1, "electron", true],
  ["L25e npx -c <cmd>", 'npx -c "electron ."', 1, "electron", true],
  ["L25f npx --package=<pinned> -c <cmd>", 'npx --package=electron@30 -c "electron ."', 1, "electron", true],
  // ── L26 (round 9, P2) — `open` forwards Chromium switches ONLY after `--args`
  //     (`open(1)`: "All remaining arguments are passed to the opened application
  //     in the argv parameter to main()"). The mitigation is real THERE and only
  //     there, so the two spellings must not read the same: before `--args` they
  //     are file arguments to `open` (the false PASS cycle 3 fixed).
  ["L26a open a bundle with the switches AFTER `--args`", `open ./Build/DMeer.app --args ${FAKE}`, 1, "open", true],
  ["L26b …and the un-forwarded twin (switches BEFORE `--args`)", `open ./Build/DMeer.app ${FAKE} --args`, 1, "open", true],
  // ── L27 (round 10, BLOCKING) — a comment begins after ANY bash metacharacter, and
  //     `)` was missing from the predecessor set. `(npm exec electron .)# <both fake
  //     switches>` therefore read the switches as ARGV and reported `faked: true` —
  //     this guard's one forbidden direction — while real bash discarded them:
  //         $ bash -c '(echo RAN)# --ignored-flag'   →   RAN
  //     So it was a false PASS of exactly the shape cycle 2's F2 closed for `;`. The
  //     `)`-after-`<<` half is the same one-character gap on R1's side: the heredoc
  //     opened, deleted the rest of the input, and the launch was neither blocked nor
  //     recorded. L27b is the mirror that pins the ESCAPE guard: bash reads `x\)#` as
  //     ONE word (`echo x\)#c` prints `x)#c`), so `#` there is data and the launch after
  //     the `;` must still be seen — a wider `.includes` without it would cut the line.
  ["L27a a fake switch in a comment after `)` is not a mitigation (was faked:true)",
    `(npm exec electron .)# ${FAKE}`, 1, "electron", true],
  ["L27b a `<<` inside a comment after `)` is not a heredoc (was [])",
    "(true)# cat <<EOF\nnpm exec electron .", 1, "electron", true],
  ["L27c …and an ESCAPED `)#` is data, so the launch after the `;` is still read",
    "echo a\\)#; npm exec electron .", 1, "electron", true],
  ["A42 the ALLOW twin of L27b: a benign line after a commented `<<`",
    "(true)# cat <<EOF\nls", 0, null, false],
  ["A43 the ALLOW twin of L27c: an escaped `)#` with a benign tail",
    "echo a\\)#; ls -la", 0, null, false],
  // ── L28 (round 11, BLOCKING) — a heredoc or here-string fed to a SHELL is its
  //     PROGRAM, not its data. `stripHeredocBodies` blanked EVERY body, so
  //
  //         bash <<'EOF'\n npm exec electron . \nEOF
  //
  //     was `[]`: no refusal AND no ledger row (the handler returns early on `[]`),
  //     the exact double loss cycles 3, 4 and 5 treated as blocking — and the same
  //     shape they closed for `bash -c "…"`, where the command string is argv.
  //     GNU Bash Reference Manual §3.6: Here Documents AND Here Strings redirect
  //     standard input; a shell with no command operand (or with `-s`) reads and
  //     executes its program from that input. The body is not a residual either: the
  //     scanner already LOCATED it, so the fix is a conditional, not a grammar.
  //     A44–A47 are the ALLOW twins — including A46, the `-c` gate that keeps the
  //     fix from over-firing: `bash -c 'script' <<EOF` runs the ARGUMENT and hands
  //     the body to that script as DATA.
  ["L28a a heredoc fed to a shell IS its program (was [])",
    "bash <<'EOF'\nnpm exec electron .\nEOF", 1, "electron", true],
  ["L28b the same through `sh`", "sh <<EOF\nelectron .\nEOF", 1, "electron", true],
  ["L28c `bash -s` (the explicit read-stdin spelling)",
    "bash -s <<'EOF'\nnpm exec electron .\nEOF", 1, "electron", true],
  ["L28d a here-STRING operand is stdin too (tokenize folds it into ONE token)",
    'bash <<< "npm exec electron ."', 1, "electron", true],
  ["L28e the same body behind a prefix", "sudo bash <<'EOF'\nelectron .\nEOF", 1, "electron", true],
  ["L28f a heredoc body PIPED into the shell", "cat <<EOF | bash\nelectron .\nEOF", 1, "electron", true],
  ["L28g an unquoted `<<<word` is a here-string, not a heredoc opener (it used to swallow the rest)",
    "bash <<<EOF\nnpm exec electron .", 1, "electron", true],
  ["L28h …and on a NON-shell line it must not delete the rest of the input either",
    "cat <<<EOF\ntrue; npm exec electron .", 1, "electron", true],
  ["A44 the ALLOW twin of L28a: a benign heredoc body stays data",
    "bash <<'EOF'\nls -la\nEOF", 0, null, false],
  ["A45 the ALLOW twin of L28d: a benign here-string", 'bash <<< "ls -la"', 0, null, false],
  ["A46 `bash -c` runs its ARGUMENT; the heredoc body is that script's DATA",
    "bash -c 'ls' <<EOF\nnpm exec electron .\nEOF", 0, null, false],
  ["A47 a `cat` heredoc body naming the launch stays data (the A31 twin, re-pinned)",
    "cat > /tmp/n.md <<'EOF'\nelectron .\nEOF", 0, null, false],
  // ── L29 (round 12, P1) — the redirect binds to the SEGMENT IT SITS IN, not to the
  //     line's last one. `lineFeedsShell` asked about `segs[segs.length - 1]`, so a
  //     heredoc/here-string fed to a shell on the LEFT of a pipe was tested against
  //     `tee log`, answered "not a shell", and blanked as data:
  //
  //         bash <<'EOF' | tee /tmp/log        (runs the body — measured)
  //         npm exec electron .
  //         EOF
  //
  //     → `[]`, i.e. no refusal AND no ledger row: the double loss rounds 3/4/5/11
  //     treat as blocking, on the pipeline spelling of the shape round 11 closed for
  //     a bare `bash <<'EOF'`. The scan follows `pipeToNext` FORWARD, so L28f
  //     (`cat <<EOF | bash`) keeps working — the body a pipe delivers to a shell IS
  //     that shell's program — while A48/A49 pin the two directions that must NOT
  //     over-fire: a benign body stays data, and a `;` (or `&`, or `||`) ends the
  //     pipeline, so nothing downstream receives it.
  ["L29a a heredoc fed to a shell on the LEFT of a pipe (was [])",
    "bash <<'EOF' | tee /tmp/log\nnpm exec electron .\nEOF", 1, "electron", true],
  ["L29b …the same as a here-string on the left of a pipe",
    'bash <<< "npm exec electron ." | tee log', 1, "electron", true],
  ["L29c …with the redirect in the MIDDLE of a pipeline",
    "true | bash <<'EOF' | tee log\nnpm exec electron .\nEOF", 1, "electron", true],
  ["L29d …and through a three-stage pipeline (`|&` is a pipe too)",
    "bash <<'EOF' |& tee log | cat\nnpm exec electron .\nEOF", 1, "electron", true],
  // ⛔ `2>&1` IS A REDIRECT, NOT A SEPARATOR (review round 2, P2 — measured). Treating
  // every `&` as a command separator cut the pipeline at `2>&`, so the forward scan
  // stopped before `bash` and these were `[]` — a regression the round-11 code did not
  // have, on a shape real bash executes (`cat <<EOF 2>&1 | bash` → `BODY_RAN`). The fd
  // number before the `>` decides: `2>&1` DUPLICATES stderr onto stdout, so stdout is
  // still piped and the body still reaches bash. A53 pins the other side — `>&2` sends
  // stdout AWAY from the pipe, so nothing reaches the shell and the body is data.
  ["L29e `2>&1` between the heredoc and the pipe does NOT end the pipeline (was [])",
    "cat <<EOF 2>&1 | bash\nnpm exec electron .\nEOF", 1, "electron", true],
  ["L29f …the same in the MIDDLE of a pipeline (was [])",
    "cat <<EOF | tee 2>&1 | bash\nnpm exec electron .\nEOF", 1, "electron", true],
  ["A48 the ALLOW twin of L29a: a NON-shell head's body stays data even when it names the launch",
    "cat <<'EOF' | tee /tmp/log\nnpm exec electron .\nEOF", 0, null, false],
  ["A53 `>&2` sends stdout AWAY from the pipe, so the body does not reach the shell",
    "cat <<EOF >&2 | bash\nnpm exec electron .\nEOF", 0, null, false],
  ["A49 a `;` after the heredoc ends the pipeline, so the body is NOT the shell's",
    "cat <<EOF; bash\nelectron .\nEOF", 0, null, false],
  // ── L30 (round 12, P2) — `open <bundle>/Contents/MacOS/<bin>` produced NO finding:
  //     the positional arm accepted only a `.app` SUFFIX, while the identical token as
  //     a command word is refused by the electron rule. README:33-35 lists the
  //     `…/Contents/MacOS/<bin>` shape as a recorded kind, so the `open` spelling
  //     contradicted the file's own list — and no row means R1 missed it too.
  ["L30a open a bundle's INNER binary (was []; the command-word spelling blocks)",
    "open /Applications/DMeer.app/Contents/MacOS/DMeer", 1, "open", true],
  ["L30b …and the relative `Contents/MacOS/<bin>` spelling (was [])",
    "open Contents/MacOS/DMeer", 1, "open", true],
  ["A50 the ALLOW twin of L30: `open` on an ordinary document is not a launch",
    "open notes.txt", 0, null, false],
  // ── L31 (round 12, P2) — `electron-forge` is the first-party Electron launcher and
  //     it was unclassified: every head test keyed on the package name `electron`
  //     exactly, so `npx electron-forge start` was `[]` — no refusal, no ledger row —
  //     against README:27's "an Electron launch" contract. It is distinguishable from
  //     a plain `node` run by its leftmost word, so it is not in the declared residual
  //     class. A51/A52 keep the fix from over-firing on the routine build verbs.
  ["L31a npx electron-forge start (was [])", "npx electron-forge start", 1, "electron", true],
  ["L31b …bare, as a package.json `start` script spells it (was [])",
    "electron-forge start", 1, "electron", true],
  ["L31c …behind `npm exec … --` (was [])", "npm exec electron-forge -- start", 1, "electron", true],
  ["L31d …and through its scoped package name `@electron-forge/cli`",
    "@electron-forge/cli start", 1, "electron", true],
  ["L31e …and version-pinned", "npx electron-forge@7.4.0 start", 1, "electron", true],
  ["A51 the ALLOW twin of L31a: `electron-forge package` BUILDS, it does not launch",
    "npx electron-forge package", 0, null, false],
  ["A52 …and `lint` inspects rather than launches", "npx electron-forge lint", 0, null, false],
  // ── L32 (round-12 review round 2, P2) — a PROCESS SUBSTITUTION runs its body in a
  //     subshell, exactly like `$(…)`: `diff <(echo RAN) /dev/null` prints `1d0 < RAN`
  //     (measured). Only `$(` and backticks were scanned, so every `<(`/`>(` spelling
  //     was `[]` — no refusal AND no ledger row, on a class the README already claims
  //     to recurse into, and one the residual list did not declare. A55 keeps the
  //     double-quoted spelling as DATA: `echo "<(npm exec electron .)"` prints the
  //     text (measured) — bash does not run it inside quotes, while it DOES run `"$(…)"`.
  ["L32a a process substitution `<(...)` runs its body (was [])",
    "diff <(npm exec electron .) /dev/null", 1, "electron", true],
  ["L32b …the `< <(...)` spelling", "cat < <(npm exec electron .)", 1, "electron", true],
  ["L32c …and the OUTPUT-direction `>(...)` spelling",
    "tee > >(npm exec electron .)", 1, "electron", true],
  ["A54 the ALLOW twin: a benign process substitution stays data",
    "diff <(ls) /dev/null", 0, null, false],
  ["A55 …and a DOUBLE-QUOTED `<(…)` is literal text, not a substitution",
    'echo "<(npm exec electron .)"', 0, null, false],
  // ── L33 (round-12 review round 2, P3) — the inner-binary shape must not depend on
  //     which rule is asking. `bundleInnerBinary` lived only in the `open` arm, so
  //     `open Contents/MacOS/DMeer` fired (L30b) while the SAME token as the COMMAND
  //     WORD — which executes the bundle's binary — was `[]`, against the comment on
  //     `bundleInnerBinary` and README's "in both spellings". A56 is the ALLOW twin:
  //     the DIRECTORY is not the binary.
  ["L33a a bundle's inner binary as the COMMAND WORD (was [])",
    "Contents/MacOS/DMeer", 1, "electron", true],
  ["A56 the ALLOW twin: the `Contents/MacOS` DIRECTORY is not the binary",
    "ls Contents/MacOS", 0, null, false],
  // ── L34–L36 (round-12 review, third pass) — three more spellings of classes this
  //     file claims to cover, each measured as `[]` (no block, no ledger row) while
  //     real bash runs the body.
  //   L34: ONE APOSTROPHE inside double quotes is DATA to bash, but the
  //        single-quote skip ran before any double-quote check, so
  //        `echo "it's" "$(npm exec electron .)"` skipped from the apostrophe to the
  //        quote opening the NEXT argument and swallowed the `$( … )` between them.
  //        bash prints `it's` and runs the substitution (measured `BODY_RAN`).
  ["L34a an apostrophe inside DOUBLE quotes does not hide a later `$( … )` (was [])",
    'echo "it\'s" "$(npm exec electron .)"', 1, "electron", true],
  ["A58 …and the SAME body in single quotes is literal text (must stay data)",
    'echo "it\'s" \'$(npm exec electron .)\'', 0, null, false],
  //   L35: a shell GLUED to its heredoc operator (`bash<<'EOF'`) arrives as one token
  //        from `tokenize`, so `basename` read `bash<<EOF`, missed `SHELLS`, and the
  //        body was blanked as data — while the spaced spelling fired and bash runs
  //        both (`bash<<'EOF'|tee` printed the body).
  ["L35a a shell GLUED to its heredoc operator (`bash<<'EOF'`, no space) (was [])",
    "bash<<'EOF'\nnpm exec electron .\nEOF", 1, "electron", true],
  ["A59 the ALLOW twin: a NON-shell glued head keeps its body as data",
    "cat<<'EOF'\nnpm exec electron .\nEOF", 0, null, false],
  //   L36: `>&1` / `1>&1` are NO-OP fd duplicates that leave stdout ON the pipe, but
  //        the exception keyed on the LEFT fd alone, so they ended the pipeline and
  //        the body was dropped (`cat <<'EOF' >&1 | bash` printed `BODY_RAN`).
  //        A53/A60 hold the other side: stdout leaving the pipe keeps the body data.
  ["L36a `>&1` is a no-op duplicate — stdout stays on the pipe (was [])",
    "cat <<'EOF' >&1 | bash\nnpm exec electron .\nEOF", 1, "electron", true],
  ["L36b …and the explicit `1>&1` spelling (was [])",
    "cat <<'EOF' 1>&1 | bash\nnpm exec electron .\nEOF", 1, "electron", true],
  ["A60 `1>&2` sends stdout AWAY from the pipe (the twin of L36)",
    "cat <<'EOF' 1>&2 | bash\nnpm exec electron .\nEOF", 0, null, false],
  // ── L37–L39 (round-12 review, fourth pass) — the delimiter SPELLING, a brace fd,
  //     and a listed wrapper's own POSITIONAL. Each was `[]` at 948b406b4/b10376f5a.
  //   L37: bash's delimiter is ANY word with quote removal applied. The scanner
  //        accepted only an identifier, so `<<\EOF` — the standard way to write a
  //        non-expanding heredoc — was not a heredoc: its body stayed in `cleaned`,
  //        and one apostrophe in it opened a literal run in the shared quote model,
  //        masking the newline separators and every later command.
  ["L37a `<<\\EOF` is a heredoc — its body cannot poison the quote model (was [])",
    "cat > /tmp/msg.txt <<\\EOF\ndon't touch the camera\nEOF\nnpm exec electron .", 1, "electron", true],
  ["L37b …and a QUOTED hyphenated delimiter `<<\"E-O-F\"` is the same word",
    'cat > /tmp/msg.txt <<"E-O-F"\ndon\'t touch the camera\nE-O-F\nnpm exec electron .', 1, "electron", true],
  ["A61 the over-fire twin: a WRITE whose heredoc body merely names a launch",
    "cat >> /tmp/runbook.md <<\\EOF\nopen ./Build/DMeer.app\nEOF", 0, null, false],
  //   L38: `{fd}>&2` ALLOCATES A NEW descriptor, so stdout stays on the pipe — the
  //        digit scan before `>` saw no left fd, read it as fd 1, and ended the
  //        pipeline (`cat <<'EOF' {fd}>&2 | bash` printed `BRACEFD_RAN`).
  ["L38a `{fd}>&2` allocates a descriptor — stdout stays on the pipe (was [])",
    "cat <<'EOF' {fd}>&2 | bash\nnpm exec electron .\nEOF", 1, "electron", true],
  ["L38b …and the `{fd}>&1` spelling of the same brace fd",
    "cat <<'EOF' {fd}>&1 | bash\nnpm exec electron .\nEOF", 1, "electron", true],
  //   L39: a LISTED wrapper's own positional (lock file, CPU mask, priority) became
  //        the command word, so the launch behind it vanished — while the runner
  //        spelling of the same wrapper fired, and real `flock`/`taskset` run the
  //        payload in both (measured with a stubbed `electron` on PATH).
  ["L39a a listed wrapper's own POSITIONAL is skipped: `flock FILE electron .` (was [])",
    "flock /tmp/l.lock electron .", 1, "electron", true],
  ["L39b …`taskset MASK electron .` (was [])",
    "taskset 0x3 electron .", 1, "electron", true],
  ["L39c …`chrt PRIORITY electron .` (was [])",
    "chrt 10 electron .", 1, "electron", true],
  ["L39d …and with the wrapper's own option in front of it (was [])",
    "flock -w 5 /tmp/l.lock electron .", 1, "electron", true],
  ["L39e …and with the positional MISSING, the launch after it is still found",
    "flock electron .", 1, "electron", true],
  ["A63 the ALLOW twin: a wrapper positional must not make every later word a launch",
    "flock /tmp/l.lock ls", 0, null, false],
  // ── L40–L43 (round-12 review, fifth pass) — a GLUED grouping operator, `chroot`,
  //     a line with TWO heredocs, and `$'…'` quoting in a delimiter.
  //   L40: `tokenize` splits on whitespace only, and `)` is a bash METACHARACTER.
  //        Only LEADING metachars were normalised, so `(open X.app)` compared
  //        `.app)` against the bundle tests, `--headed)` against HEADED_FLAGS, and
  //        the fake switches against their own spellings — one bug, both
  //        directions: a miss (no block, no row) and a FALSE BLOCK on mitigated work.
  ["L40a a GLUED grouping `)` does not hide an `open` (was [])",
    "(open ./Build/DMeer.app)", 1, "open", true],
  ["L40b …nor a HEADED Playwright run (was [])",
    "(npx playwright test --headed)", 1, "playwright", true],
  ["L40c …including a `&&` list inside the grouping (was [])",
    "(cd app && npx playwright test --headed)", 1, "playwright", true],
  ["A64 the ALLOW twin: a benign command in a glued grouping stays clean",
    "(ls)", 0, null, false],
  //   L41: `chroot NEWROOT [COMMAND …]` — a listed wrapper whose leading positional
  //        is not the command, so the launch behind it vanished.
  ["L41a `chroot ROOT electron .` — the root is a positional, not the command (was [])",
    "chroot /tmp/root electron .", 1, "electron", true],
  ["A65 the ALLOW twin: the same wrapper with a benign payload",
    "chroot /tmp/root ls", 0, null, false],
  //   L42: a line can open SEVERAL heredocs and their bodies arrive in order. Only
  //        the LAST `<<` was located, so `bash <<A; cat <<B` fed A's body — the one
  //        bash EXECUTES — to the void.
  ["L42a two heredocs on one line: the FIRST body is the one the shell reads (was [])",
    "bash <<A; cat <<B\nnpm exec electron .\nA\nx\nB", 1, "electron", true],
  ["A66 the ALLOW twin: both bodies are `cat` data",
    "cat <<A; cat <<B\nopen ./Build/DMeer.app\nA\nx\nB", 0, null, false],
  //   L43: `$'…'` / `$"…"` are QUOTE FORMS, so `$` must not survive quote removal.
  //        `<<$'EOF'` became the delimiter `$EOF`, found no terminator, and swallowed
  //        the rest of the input — including the launch after the real `EOF` line.
  ["L43a `<<$'EOF'` is the delimiter `EOF`, so the tail is still scanned (was [])",
    "cat <<$'EOF'\nhi\nEOF\nnpm exec electron .", 1, "electron", true],
  ["A67 the ALLOW twin: a benign body under `$'…'` quoting stays data",
    "cat <<$'EOF'\nopen ./Build/DMeer.app\nEOF", 0, null, false],
  // ── L44–L47 (round-12 review, sixth pass) — an ATTACHED option argument, `watch`'s
  //     command operand, the `until` keyword, and a heredoc inside a substitution.
  //   L44: `body.lastIndexOf(letter)` searched the ATTACHED ARGUMENT too, so the app
  //        name was cut at its last `a`/`b`: `open -aSafari` recorded `app: "ri"` and
  //        `open -aBanana` / `open -bcom.apple.Safari` produced NO finding at all
  //        (no block, NO ledger row) — one letter of the name changed the answer.
  ["L44a an ATTACHED `-a<app>` keeps the whole name (`-aSafari` was app 'ri')",
    "open -aSafari", 1, "open", false],
  ["L44b …including a name whose LAST letter is the option letter (was [])",
    "open -aBanana", 1, "open", false],
  ["L44c …and a reverse-DNS `-b<id>` (`-bcom.apple.Safari` was [])",
    "open -bcom.apple.Safari", 1, "open", false],
  //   L45: `watch`'s bare operand is a `sh -c` script, so it is re-read — the unquoted
  //        spelling already fired and the quoted one, the spelling a developer writes,
  //        produced no block and no row.
  ["L45a `watch … \"<cmd>\"` runs its operand and is re-read (was [])",
    'watch -n 1 "npm exec electron ."', 1, "electron", true],
  ["A68 the ALLOW twin: a benign `watch` operand stays clean",
    "watch -n 1 ls", 0, null, false],
  ["A69 the ALLOW twin: a benign `until` loop stays clean",
    "until false; do break; done", 0, null, false],
  //   L46: `until` is the same reserved word as `while` (which fired), and a `(` glued
  //        to a token AFTER the keyword was never normalised.
  ["L46a `until <launch>; do …` is a control-flow word like `while` (was [])",
    "until npm exec electron .; do break; done", 1, "electron", true],
  ["L46b a GLUED `(` after a control-flow word is normalised (was [])",
    "if (npm exec electron .); then :; fi", 1, "electron", true],
  ["L46c …and `until` resolves the bare launch word with no runner to rescue it",
    "until electron .; do break; done", 1, "electron", true],
  //   L47: the shell can sit INSIDE a substitution, where the resolved command word is
  //        the redirect operator — the body bash runs was blanked as data.
  ["L47a a heredoc fed to a shell inside `$( … )` is still the shell's program (was [])",
    "x=$(bash <<'EOF'\nnpm exec electron .\nEOF\n)", 1, "electron", true],
  ["A70 the ALLOW twin: the same shape with a NON-shell head stays data",
    "x=$(cat <<'EOF'\nopen ./Build/DMeer.app\nEOF\n)", 0, null, false],
  // ── L48–L49 (round-12 review, seventh pass) — a LINE CONTINUATION, and an attached
  //     `-a<name>` whose name is spelled only in letters `open` accepts as flags.
  //   L48: bash deletes `\\`+newline BEFORE word splitting, so the launch and its
  //        switches are ONE argv. Splitting on the newline put them in different
  //        segments: the mitigated launch was REFUSED (its own printed remedy was
  //        what the lane wrote) and the headed Playwright run lost block AND row.
  ["L48a a line continuation keeps the launch and its mitigation in ONE argv",
    "npm exec electron . \\\n  --use-fake-device-for-media-stream --use-fake-ui-for-media-stream", 1, "electron", true],
  ["L48b …and a continued HEADED Playwright run is still a media shape (was [])",
    "npx playwright test \\\n  --headed", 1, "playwright", true],
  ["L48c …including a continued `open -a <name>` (the R1 row was lost)",
    "open \\\n  -a Safari", 1, "open", false],
  ["A71 the ALLOW twins: a continuation inside SINGLE quotes is literal text",
    "echo 'x \\\ny'", 0, null, false],
  ["A72 …and a continuation at the end of a COMMENT is not a continuation",
    "# note \\\nls", 0, null, false],
  //   L49: a cluster needs a NEXT WORD for its value, so with nothing following, the
  //        attached reading is the only one that can be right (`open -anews`).
  ["L49a `open -anews` records the app `news` (was [])",
    "open -anews", 1, "open", false],
  ["L49b …and with a FILE argument after it (was []; the identity was the file)",
    "open -anews notes.txt", 1, "open", false],
  ["L49c …and `-aweb index.html` names `web`, not the file (was app 'index.html')",
    "open -aweb index.html", 1, "open", false],
  // ── L50–L51 (round-12 review, eighth pass) — a REDIRECTION is not a word, and it
  //     can be glued to the flag that decides the answer.
  //   L50: a leading redirection became the command word, so a BARE launch word was
  //        `[]` — no block, no row — while the runner spelling of the same line fired
  //        (the nested-payload scan starts at index 1).
  ["L50a a leading redirect does not become the command word (was [])",
    "2>/dev/null electron .", 1, "electron", true],
  ["L50b …including a bare `>` + target before the command (was [])",
    "> /tmp/o.log open ./Build/DMeer.app", 1, "open", true],
  ["L50c …and an fd duplicate (`2>&1`) is not an `&` separator (was [])",
    "2>&1 electron .", 1, "electron", true],
  ["A73 the ALLOW twins: redirects around a benign command stay clean",
    "2>/dev/null ls > /tmp/x", 0, null, false],
  //   L51: a redirect glued to the flag ends the WORD at the operator, so an exact-token
  //        predicate saw `--headed>/tmp/pw.log` and lost the headed run.
  ["L51a a redirect glued to `--headed` does not hide the headed run (was [])",
    "npx playwright test --headed>/tmp/pw.log", 1, "playwright", true],
  // ── L52–L53 (round-12 review, ninth pass) — the two ORDER-OF-OPERATION gaps the
  //     previous fixes left behind: a leading redirect on the SHELL side of a heredoc,
  //     and a continuation BEFORE the heredoc operator.
  ["L52a a leading redirect does not hide the shell that reads a heredoc (was [])",
    "2>/dev/null bash <<'EOF'\nnpm exec electron .\nEOF", 1, "electron", true],
  ["L52b …nor in front of a here-string (was [])",
    "2>/dev/null bash <<<'npm exec electron .'", 1, "electron", true],
  ["L53a a line continuation between the shell and its heredoc operator (was [])",
    "bash \\\n<<'EOF'\nnpm exec electron .\nEOF", 1, "electron", true],
  ["L53b …and between `<<<` and its operand (was [])",
    "bash <<<\\\n'npm exec electron .'", 1, "electron", true],
  ["A74 the ALLOW twin: a continuation in a COMMENT starts a new command, it does not\n    join one (bash RUNS the next line, so the launch there is still read)",
    "# note \\\nelectron .", 1, "electron", true],
  // ── L54–L56 (round-12 review, tenth pass) — the three gaps the ninth pass left:
  //     a continuation INSIDE a quoted heredoc body, a `#` glued to `;`/`)`, and
  //     `watch`'s operand behind another prefix.
  //   L54: the join ran over the WHOLE command, so a trailing backslash on the last
  //        body line of a QUOTED heredoc ate the terminator and turned every following
  //        command — including a launch — into body data. bash terminates at `EOF`
  //        and runs the next line (measured). The join is now per line INSIDE the
  //        scanner, so bodies are never joined.
  ["L54a a trailing backslash in a QUOTED heredoc body does not eat the terminator (was [])",
    "cat > /tmp/o.txt <<'EOF'\nx \\\nEOF\nnpm exec electron .", 1, "electron", true],
  ["L54b …the `<<\"EOF\"` spelling too (was [])",
    'cat > /tmp/o.txt <<"EOF"\nx \\\nEOF\nnpm exec electron .', 1, "electron", true],
  //   L55: the joiner carried its own, narrower comment rule ("previous char is a
  //        blank"), so a `#` glued to `;`/`)` was not a comment and the launch on the
  //        next line was joined INTO it. bash runs that line (measured).
  ["L55a `#` glued to `;` starts a comment — the launch after it still runs (was [])",
    "true;# note \\\nnpm exec electron .", 1, "electron", true],
  ["L55b …and glued to `)` (was [])",
    "(true)# note \\\nnpm exec electron .", 1, "electron", true],
  //   L56: `watch`'s operand was read from TOKEN 0, so any listed prefix in front of
  //        it lost the `sh -c` script while the unprefixed twin fired.
  ["L56a `watch`'s operand is read behind ANOTHER prefix (`timeout … watch`) (was [])",
    'timeout 30 watch -n 1 "npm exec electron ."', 1, "electron", true],
  ["L56b …behind `sudo` (was [])",
    'sudo watch -n 1 "npm exec electron ."', 1, "electron", true],
  ["L56c …behind `env` (was [])",
    'env FOO=1 watch -n 1 "npm exec electron ."', 1, "electron", true],
  ["A76 the ALLOW twin: a prefixed `watch` with a benign operand stays clean",
    "timeout 30 watch -n 1 ls", 0, null, false],
  // ── L57–L59 (round-12 review, ELEVENTH pass) — three MISSES the per-line join
  //     introduced or left, all reproduced against bash first.
  //   L57: a backslash escapes the NEXT character, so only an ODD trailing run is a
  //        continuation. `echo hi \` is a literal backslash and the line ENDS there —
  //        bash runs `electron .` on the next line — but the joiner took the last
  //        backslash at face value, joined the launch into `echo` and lost it.
  ["L57a `\\` at end of line is a LITERAL backslash — the launch on the next line runs (was [])",
    "echo hi \\\\\nelectron .", 1, "electron", true],
  ["A77 the ALLOW twin: three backslashes DO continue, so the word is an `echo` argument",
    "echo hi \\\\\\\nelectron .", 0, null, false],
  //   L58: joining re-emitted the consumed continuation line, and a duplicate fragment
  //        carrying a lone quote changed how the rest of the command read — the launch
  //        after it lost the refusal AND the row (was []).
  ["L58 a continuation whose joined line carries the closing quote must not be re-emitted (was [])",
    "cat > /tmp/x.log 2>/dev/null <<'EOF'\nplaceholder\nEOF\necho \"=== starting \\\napp ===\"\nnpm exec electron .",
    1, "electron", true],
  //   L59: the quote model is indexed by ABSOLUTE offset, so a `<<` past a join seam
  //        read the wrong characters, looked unquoted, and opened a phantom heredoc
  //        that blanked the launch after it (was []).
  ["L59 a `<<` inside a quoted word after a continuation is not an operator (was [])",
    "echo \"a \\\n<<EOF b\"\nnpm exec electron .", 1, "electron", true],
  //   L57b: the SAME parity rule on the per-line joiner, in a command that also carries
  //         a heredoc — the whole-command joiner cannot rescue a line it never sees
  //         separately, so without the per-line parity this launch was joined into
  //         `echo` and lost (was []).
  ["L57b …the per-line joiner applies the same parity (heredoc in the same command) (was [])",
    "cat > /tmp/x.log <<'EOF'\nplaceholder\nEOF\necho hi \\\\\nelectron .",
    1, "electron", true],
  //   A78: with the join seam in play, the quote model must be consulted at the JOINED
  //        text's own offsets. Off by one, the `<<` was read as quoted, no heredoc was
  //        found, and the body line was then executed as a command — an OVER-FIRE
  //        (`<<EOF` with no command discards its body; measured).
  ["A78 the ALLOW twin: `<<EOF` with no command discards its body, even after a join seam",
    "echo \"a \\\n\"<<EOF\nnpm exec electron .\nEOF", 0, null, false],
  // ── L60/A79/A80 (round-12 review, TWELFTH pass) — an UNQUOTED heredoc is a DIFFERENT
  //     document from the source bytes: bash removes `\` + newline and collapses
  //     `\\`, `\$`, `` \` ``, and it matches the TERMINATOR against that text.
  //   L60: `EO\` + newline + `F` ends the here-document (measured), so the launch after
  //        it RUNS — the raw comparison saw no terminator and swallowed it as body.
  ["L60 an UNQUOTED heredoc terminator spelled across a continuation still ends it (was [])",
    "cat <<EOF\nbody\nEO\\\nF\nnpm exec electron .", 1, "electron", true],
  //   A80: the QUOTED twin is literal — the `EO\`+`F` pair is NOT the terminator, so the
  //        launch stays inside the (discarded) body and nothing runs.
  ["A80 the ALLOW twin: a QUOTED heredoc body is literal, so `EO\\`+`F` is not its terminator",
    "cat <<'EOF'\nbody\nEO\\\nF\nnpm exec electron .\nEOF", 0, null, false],
  //   A79: the consuming shell receives the EXPANDED body, where `\\` has already become
  //        `\` — so its own continuation join makes `electron .` an `echo` argument.
  //        Classifying the raw body instead OVER-blocked (measured).
  ["A79 the ALLOW twin: an unquoted body's `\\\\` collapses to `\\`, so the inner shell joins",
    "sh <<EOF\necho a \\\\\nelectron .\nEOF", 0, null, false],
  //   A81: the `<<-` strip is applied to the ASSEMBLED line, so a tab that lands in the
  //        MIDDLE of it survives — `EO\` + tab + `F` assembles to `EO<TAB>F`, not the
  //        terminator, so the document runs to end-of-input and the launch is data
  //        (measured: `cat` prints `EO<TAB>F`).
  ["A81 the ALLOW twin: `<<-` does not strip a continuation line's tab, so `EO\`+tab+`F` is no terminator",
    "cat <<-EOF\n\tbody\n\tEO\\\n\tF\nnpm exec electron .", 0, null, false],
  //   A82: the backslash COLLAPSE is body-only — the terminator is compared BEFORE it,
  //        so a body line `A\$B` does not terminate `<<A$B` (measured).
  ["A82 the ALLOW twin: the terminator is compared before the body's backslash collapse",
    "cat <<A$B\nline\nA\\$B\nnpm exec electron .", 0, null, false],
  //   L61: `<<-` strips the leading tabs of the ASSEMBLED logical line — a bare `\` whose
  //        continuation line starts with a TAB therefore assembles to a TAB-LED `EOF`,
  //        which bash ACCEPTS as the terminator and then runs the launch after it
  //        (measured). Stripping only the first physical line left the document open and
  //        swallowed the launch as data: no block, no row.
  ["L61 `<<-` strips the leading tabs of the ASSEMBLED terminator line (`\\` + tab + `EOF`) (was [])",
    "cat <<-EOF\n\tbody\n\\\n\tEOF\nnpm exec electron .", 1, "electron", true],
  //   A83: the twin that keeps the strip honest — a SPACE before the continuation's tab
  //        means the tab is not LEADING, so the terminator is not recognised and the
  //        document runs to end-of-input (measured: `cat` prints ` \tEOF`).
  ["A83 the ALLOW twin: a space before the continuation's tab keeps the tab non-leading",
    "cat <<-EOF\n\tbody\n \\\n\tEOF\nnpm exec electron .", 0, null, false],
  //   L30c: tab completion appends a slash to directories, and `open
  //         ./Build/DMeer.app/` — the incident's own app — matched none of the three
  //         bundle tests while the `-a` spelling of the SAME token was refused.
  ["L30c open a bundle PATH with a trailing slash (tab completion; was [])",
    "open ./Build/DMeer.app/", 1, "open", true],
  ["A57 the ALLOW twin: a trailing-slash DIRECTORY that is not a bundle",
    "open ./build/", 0, null, false],
  // ── A34–A41 — ALLOW twins for L24/L25 AND for round 7's P2-5 over-fire. The
  //     fail-safe word scan is now gated on the prefix having SKIPPED A FLAG: with
  //     no flag between the prefix and the command word, nothing could have
  //     swallowed it, so a SEARCH that mentions `electron` is not a launch — while
  //     L15j/L15k (a flag the table has never seen) must stay refused. These rows
  //     are the two directions of that gate.
  ["A34 env -S with a benign command string", 'env -S "ls -la"', 0, null, false],
  ["A35 npx -c with a benign command string", 'npx -c "ls -la"', 0, null, false],
  ["A36 bun install electron is an INSTALL (the A13 twin)", "bun install electron", 0, null, false],
  ["A37 bun run build", "bun run build", 0, null, false],
  ["A38 sudo rg electron . (a prefix with NO flag cannot swallow the word)", "sudo rg electron .", 0, null, false],
  ["A39 timeout 30 rg electron . (its duration is not a flag)", "timeout 30 rg electron .", 0, null, false],
  ["A40 timeout 60 grep -rn electron src/", "timeout 60 grep -rn electron src/", 0, null, false],
  ["A41 sudo npm install electron -D (a nested runner that INSTALLS)", "sudo npm install electron -D", 0, null, false],
];

for (const [name, cmd, count, rule, media] of ROWS) {
  const found = classify(cmd);
  const okCount = found.length === count;
  const okRule = rule === null ? true : found.some((f) => f.rule === rule);
  const okMedia = rule === null ? true : found.some((f) => f.media === media);
  check(
    `classify: ${name}`,
    okCount && okRule && okMedia,
    `count=${found.length} (want ${count}) rules=[${found.map((f) => f.rule)}] media=[${found.map((f) => f.media)}]`,
  );
}

// ── the ledger's `app` field: the DIAGNOSIS half of #2249 ────────────────────
// ⛔ A ROW THAT ONLY COUNTS CANNOT SEE A MANGLED IDENTITY (round 7, P1-1/P2-4).
// `open Banjo.app` used to produce exactly one `open` finding — with
// `app: "njo.app"` — so a count/rule/media row stayed GREEN over the defect. The
// argument handed to the option letter is what R1 answers "which app?" with, so it
// is pinned here separately.
const APP_ROWS = [
  ["P1-1 an app name whose 2nd letter is `a` keeps its FULL identity", "open Banjo.app", "Banjo.app"],
  ["P1-1 …and a `Safari.app` bundle is not truncated to `fari.app`", "open Safari.app", "Safari.app"],
  // ⛔ CORRECTED IN ROUND 12, EIGHTH PASS — this row used to expect "com.x" on the
  // theory that `-bna` is the cluster `-b -n -a`. That is not getopt: `-b` TAKES A
  // VALUE, so it consumes the rest of the token. bash's own `getopts` settles it —
  // `set -- -bna com.x; getopts "a:b:"` gives `opt=b arg=na` — and the README's own
  // sentence ("getopt stops at the first VALUE-taking letter") already said so. The
  // identity is `na`; `com.x` is the FILE argument. Not a security change: both
  // readings record the launch with `media: false`.
  ["P2-4 (corrected) `open -bna com.x` is `-b na`, not a cluster", "open -bna com.x", "na"],
  ["P2-4 `open -na <name>` (was `[]`, so nothing was recorded)", 'open -na "Google Chrome"', "Google Chrome"],
  ["L21h twin: an ATTACHED `-a<app>`", "open -aDMeer", "DMeer"],
  // ⛔ THE `open <bundle>/Contents/MacOS/<bin>` SPELLING NAMES THE BUNDLE, not the inner
  // binary (round 12, P2): the owner quits `DMeer.app`, and the ledger's `app` is what
  // R1's "which app?" answer is read from. A count/rule/media row cannot see a mangled
  // identity, so it is pinned here the same way the round-7 rows are.
  ["L30a twin: an `open` of a bundle's inner binary names the BUNDLE",
    "open /Applications/DMeer.app/Contents/MacOS/DMeer", "/Applications/DMeer.app"],
  ["L30b twin: the relative inner-binary path names itself",
    "open Contents/MacOS/DMeer", "Contents/MacOS/DMeer"],
  ["L30c twin: a trailing slash is not part of the identity",
    "open ./Build/DMeer.app/", "./Build/DMeer.app"],
  ["L44a twin: `-aSafari` names Safari, not `ri`",
    "open -aSafari", "Safari"],
  ["L44b twin: `-aBanana` names Banana",
    "open -aBanana", "Banana"],
  ["L44c twin: `-b<id>` keeps the whole bundle identifier",
    "open -bcom.apple.Safari", "com.apple.Safari"],
  ["L49a twin: a flag-only-letters app name is still the ATTACHED argument",
    "open -anews", "news"],
  ["L49b twin: a FILE argument is not the app identity",
    "open -anews notes.txt", "news"],
  ["L49c twin: `-aweb` names web",
    "open -aweb index.html", "web"],
];
for (const [name, cmd, expected] of APP_ROWS) {
  const found = classify(cmd);
  check(
    `identity: ${name}`,
    found.length > 0 && found[0].app === expected,
    `app=${JSON.stringify(found[0]?.app)} (want ${JSON.stringify(expected)})`,
  );
}

// ── L11 — the fake-capture mitigation is RECOGNISED (both switches required) ─
// ⛔ `length === 1 &&` on BOTH rows (review minor): `.every()` over an EMPTY array
// is `true`, so a guard that stopped firing would have left these two GREEN — they
// would have survived exactly the mutant they exist to catch.
check(
  "L11a electron WITH both fake switches is classified faked",
  (() => { const f = classify(`electron . ${FAKE}`); return f.length === 1 && f[0].faked === true; })(),
);
check(
  "L11b HALF the switches is not a mitigation (one flag is not enough)",
  (() => { const f = classify(`electron . ${mod.FAKE_DEVICE_FLAG}`); return f.length === 1 && f[0].faked === false; })(),
);
// ⛔ THE MITIGATION SURVIVES A GLUED GROUPING (round-12 review, fifth pass): with
// `)` stuck to the last switch, the fake flags did not match and a REQUESTED
// mitigation turned into a BLOCK. Bash strips the paren; so must the guard.
check(
  "L11b1 both fake switches are recognised INSIDE a glued grouping `)`",
  (() => { const f = classify(`(electron . ${FAKE})`); return f.length === 1 && f[0].faked === true; })(),
);
// ⛔ A LINE CONTINUATION KEEPS THE MITIGATION IN THE SAME ARGV (round-12 review,
// seventh pass) — the launch was refused with its own remedy already written.
check(
  "L48a1 both fake switches are recognised across a line continuation",
  (() => { const f = classify(`electron . \\\n  ${FAKE}`); return f.length === 1 && f[0].faked === true; })(),
);
// ⛔ A REDIRECT GLUED TO THE LAST SWITCH IS NOT PART OF THE SWITCH (round-12 review,
// eighth pass): the mitigated launch was refused with its own two flags in argv.
check(
  "L51b1 both fake switches are recognised when a redirect is glued to the last one",
  (() => { const f = classify(`electron . ${FAKE}>/tmp/log`); return f.length === 1 && f[0].faked === true; })(),
);
check(
  "L51b2 …and when a leading redirect precedes the launch",
  (() => { const f = classify(`2>/dev/null electron . ${FAKE}`); return f.length === 1 && f[0].faked === true; })(),
);
// L11d — the mitigation must be ARGV, not COMMENT text (review cycle 2, F2).
check(
  "L11d a fake switch inside a COMMENT is not a mitigation (faked === false)",
  (() => {
    const f = classify(`electron . # ${FAKE}`);
    return f.length === 1 && f[0].faked === false;
  })(),
);
// L11f — the same invariant one character over, on the FIELD (round 10, blocking).
// A16/L11d already pin `faked`, and the classify row L27a's count/rule/media columns
// were ALREADY satisfied by the defect (it fired, with `media: true`), so only the
// field says whether the comment was read as ARGV. Bash's metacharacter set includes
// `)`, so `)#` starts a comment and the switches are data.
check(
  "L11f a fake switch in a comment after `)` is not a mitigation (faked === false)",
  (() => {
    const f = classify(`(npm exec electron .)# ${FAKE}`);
    return f.length === 1 && f[0].faked === false && f[0].media === true;
  })(),
);
check(
  "L11c a fake switch in ANOTHER segment does not cover the launch",
  classify(`electron . && echo ${FAKE}`)[0].faked === false,
);
// L18b — `open` cannot forward Chromium switches, so their presence must NOT be
// read as a mitigation (review cycle 3, minor: measured `faked: true`, i.e. the
// remedy inverted the gate). Asserted on the FIELD, because the classify table
// above only pins `media`.
check(
  "L18b fake switches on an `open` line leave faked === false",
  (() => {
    const f = classify(`open ./Build/DMeer.app ${FAKE}`);
    return f.length === 1 && f[0].faked === false && f[0].media === true;
  })(),
);
// L18c/L18d (round 9, P2) — the `--args` distinction, on the FIELD. L18b pins the
// un-forwarded spelling; these pin the forwarded one and its ordering twin, so the
// rule cannot regress to a blanket `false` (refusing mitigated work) or a blanket
// `toks.includes` (the false PASS cycle 3 fixed).
check(
  "L18c fake switches AFTER `--args` ARE a mitigation (faked === true)",
  (() => {
    const f = classify(`open ./Build/DMeer.app --args ${FAKE}`);
    return f.length === 1 && f[0].faked === true && f[0].media === true;
  })(),
);
check(
  "L18d one switch after `--args` is not a mitigation (half is not enough)",
  (() => {
    const f = classify(`open ./Build/DMeer.app --args ${mod.FAKE_DEVICE_FLAG}`);
    return f.length === 1 && f[0].faked === false;
  })(),
);
// L12 — a launch embedded after a separator is still a launch.
check(
  "L12 a launch after `&&` is still classified",
  classify("npm ci && npm exec electron .").some((f) => f.rule === "electron"),
);

// ── the registered handler is what actually runs in a session ──────────────
let handler = null;
mod.default({ on: (event, fn) => { if (event === "tool_call") handler = fn; } });
check("registration: tool_call handler installed", typeof handler === "function");

async function drive(command, env = {}) {
  process.env = { ...saveEnv, PI_MODE: "print", GUI_DEVICE_GUARD_RECORD: LEDGER, ...env };
  for (const k of ["GUI_DEVICE_GUARD_DISABLED", "GUI_DEVICE_GUARD_ALLOW_MEDIA"]) {
    if (!(k in env)) delete process.env[k];
  }
  try {
    return await handler({ toolName: "bash", input: { command } }, {});
  } finally {
    process.env = { ...saveEnv };
  }
}

if (handler) {
  // ── H1/H2 — the incident is BLOCKED, with a reason that is actionable ─────
  resetLedger();
  const blocked = await drive("npm exec electron .");
  check("H1 handler: BLOCKS the #2249 incident shape", Boolean(blocked?.block));
  check(
    "H2 the reason names the incident, the remedy flags and the ledger",
    typeof blocked?.reason === "string" &&
      blocked.reason.includes("#2249") &&
      blocked.reason.includes(mod.FAKE_DEVICE_FLAG) &&
      blocked.reason.includes(mod.FAKE_UI_FLAG) &&
      blocked.reason.includes(LEDGER),
    String(blocked?.reason ?? "").slice(0, 200),
  );

  // ── H3 — and it is RECORDED, which is the half that survives a refusal ───
  const rows = ledgerRows();
  check("H3 handler: the blocked launch wrote ONE ledger row", rows.length === 1, `rows=${rows.length}`);
  if (rows.length === 1) {
    const r = rows[0];
    check(
      "H3a the row carries the launch identity (rule/app/argv/cwd/pid/decision)",
      r.event === "host-app-launch" &&
        r.rule === "electron" &&
        r.app === "Electron" &&
        r.argv === "npm exec electron ." &&
        r.cwd === process.cwd() &&
        Number.isInteger(r.pid) &&
        r.decision === "block" &&
        r.issue === 2249,
      JSON.stringify(r).slice(0, 260),
    );
  }

  // ── H3b (review cycle 3, minor) — the `open` remedy cannot be carried by
  //         switches, so appending them must NOT unblock the launch.
  resetLedger();
  const openFaked = await drive(`open ./Build/DMeer.app ${FAKE}`);
  check(
    "H3b an `open` launch WITH the fake switches appended is STILL blocked",
    Boolean(openFaked?.block),
    JSON.stringify(openFaked ?? null).slice(0, 160),
  );
  check(
    "H3c …and its reason names the ONE spelling that actually forwards a switch",
    typeof openFaked?.reason === "string" &&
      openFaked.reason.includes("GUI_DEVICE_GUARD_ALLOW_MEDIA") &&
      openFaked.reason.includes("--args"),
    String(openFaked?.reason ?? "").slice(0, 200),
  );

  // ── H3d/H3e (round 9, P2) — `--args` IS the forwarding token (`open(1)`), so
  //         the mitigated spelling must RUN and be recorded faked=true, and the
  //         un-forwarded twin must stay refused. Driven through the handler on
  //         purpose: only the handler shows the ALLOW and the ledger row, and the
  //         defect was that the ONLY documented way past the refusal was the
  //         hatch that permits REAL capture.
  resetLedger();
  const openViaArgs = await drive(`open ./Build/DMeer.app --args ${FAKE}`);
  check(
    "H3d `open <bundle>.app --args <both switches>` is ALLOWED (a real mitigation)",
    openViaArgs === undefined,
    JSON.stringify(openViaArgs ?? null).slice(0, 160),
  );
  const viaArgsRows = ledgerRows();
  check(
    "H3d1 …and recorded with faked=true (the ledger does not lose the mitigation)",
    viaArgsRows.length === 1 && viaArgsRows[0].faked === true &&
      viaArgsRows[0].decision === "record",
    JSON.stringify(viaArgsRows).slice(0, 220),
  );
  resetLedger();
  const beforeArgs = await drive(`open ./Build/DMeer.app ${FAKE} --args`);
  check(
    "H3e the twin — both switches BEFORE `--args` — is still REFUSED",
    Boolean(beforeArgs?.block),
    JSON.stringify(beforeArgs ?? null).slice(0, 160),
  );
  check(
    "H3e1 …and that refusal is ATTRIBUTED to a real launch decision (faked=false, media=true)",
    classify(`open ./Build/DMeer.app ${FAKE} --args`)[0]?.faked === false &&
      classify(`open ./Build/DMeer.app ${FAKE} --args`)[0]?.media === true,
    JSON.stringify(classify(`open ./Build/DMeer.app ${FAKE} --args`)),
  );

  // ── H4 — a RECORD-ONLY launch: the ledger keeps it, the tool call proceeds ─
  resetLedger();
  const opened = await drive("open -a Safari");
  check("H4 handler: a plain GUI app launch is ALLOWED", opened === undefined);
  const openRows = ledgerRows();
  check(
    "H4a …but RECORDED (this is the row that would have cut #2249 to one lookup)",
    openRows.length === 1 && openRows[0].rule === "open" && openRows[0].app === "Safari" &&
      openRows[0].decision === "record",
    JSON.stringify(openRows).slice(0, 220),
  );

  // ── H5 — the mitigated launch runs and records faked=true ────────────────
  resetLedger();
  const faked = await drive(`npm exec electron . ${FAKE}`);
  check("H5 handler: an Electron launch WITH the fake switches is allowed", faked === undefined);
  const fakedRows = ledgerRows();
  check("H5a …and recorded with faked=true", fakedRows.length === 1 && fakedRows[0].faked === true);

  // ── H6 — nothing GUI: no verdict AND no ledger write (no noise) ──────────
  resetLedger();
  const quiet = await drive("grep -rn TODO src/");
  check("H6 handler: a non-GUI command is allowed", quiet === undefined);
  check("H6a …and writes NO ledger row", ledgerRows().length === 0, `rows=${ledgerRows().length}`);

  // ── H7 — the escape hatch: allowed, and STILL recorded (disclosed) ───────
  resetLedger();
  const allowed = await drive("npm exec electron .", { GUI_DEVICE_GUARD_ALLOW_MEDIA: "1" });
  check("H7 handler: GUI_DEVICE_GUARD_ALLOW_MEDIA=1 permits one real-device run", allowed === undefined);
  const allowedRows = ledgerRows();
  check(
    "H7a …and the permitted launch is recorded with decision=record (not hidden)",
    allowedRows.length === 1 && allowedRows[0].decision === "record",
    JSON.stringify(allowedRows).slice(0, 200),
  );

  // ── H8 — the kill switch is total ────────────────────────────────────────
  resetLedger();
  const killed = await drive("npm exec electron .", { GUI_DEVICE_GUARD_DISABLED: "1" });
  check("H8 handler: GUI_DEVICE_GUARD_DISABLED=1 disables the guard entirely", killed === undefined);
  check("H8a …including the ledger write", ledgerRows().length === 0);

  // ── H9 — an INTERACTIVE session is never guarded. The audience of #2249 is
  //        an unattended run; a human typing `open -a Safari` is not the bug,
  //        and a guard that refuses him is the category-B friction this repo
  //        has already paid for.
  //
  //        `laneContract()` MEMOISES on purpose (a session does not change its
  //        mode mid-run), so the earlier print-mode arms left `lane: true`
  //        cached. Forgetting the memo makes the contract re-derive from THIS
  //        argv/env, which is what an interactive process would have measured.
  resetLedger();
  process.env = { ...saveEnv, GUI_DEVICE_GUARD_RECORD: LEDGER };
  delete process.env.PI_MODE;
  laneMod._resetLaneContractForTest();
  const savedArgv = process.argv;
  process.argv = ["node", "test.mjs"]; // no -p, no --print
  let interactive;
  try {
    interactive = await handler({ toolName: "bash", input: { command: "npm exec electron ." } }, {});
  } finally {
    process.argv = savedArgv;
    process.env = { ...saveEnv };
    laneMod._resetLaneContractForTest();
  }
  check(
    "H9 handler: an INTERACTIVE session is not guarded (only an unattended run is)",
    interactive === undefined,
    "the interactive arm fired — check isUnattended()'s print-mode/lane derivation",
  );
  check("H9a …and wrote no ledger row either", ledgerRows().length === 0, `rows=${ledgerRows().length}`);

  // ── H10 — a non-bash tool is never inspected ────────────────────────────
  process.env = { ...saveEnv, PI_MODE: "print", GUI_DEVICE_GUARD_RECORD: LEDGER };
  const other = await handler({ toolName: "read", input: { path: "x" } }, {});
  process.env = { ...saveEnv };
  check("H10 handler: ignores non-bash tools", other === undefined);

  // ── H11 — an unwritable ledger must be LOUD, never silent, and must not
  //         break the lane over a full disk (#2249: "silence is not an
  //         acceptable answer").
  resetLedger();
  // ⛔ ONE probe, not two (round 11, review note). The first probe wrote to
  // `join(FIX, "a-file-not-a-dir")` — whose PARENT is the temp dir that exists — so it
  // SUCCEEDED, asserted nothing (its `wrote` value appeared only in a detail string),
  // and the comment above the surviving probe described the probe that was dropped.
  // The failure arm is the one below: the parent path is a regular FILE, so mkdir fails.
  const unwritable = join(FIX, "blocker");
  writeFileSync(unwritable, "x");
  const warned2 = [];
  const wrote2 = mod.recordLaunch(
    { event: "host-app-launch", ts: "t", issue: 2249, decision: "record", rule: "open",
      app: "Safari", argv: "open -a Safari", media: false, faked: false, cwd: "/",
      pid: 1, ppid: 0, host: "h", lane: false, tag: null },
    join(unwritable, "nested", "ledger.jsonl"),
    (m) => warned2.push(m),
  );
  check("H11 a failed ledger write returns false and WARNS (never silent)",
    wrote2 === false && warned2.length === 1 && /NOT recorded/.test(warned2[0]),
    `wrote2=${wrote2} warn=${JSON.stringify(warned2).slice(0, 200)}`);

  // ── H12 — review cycle 4, F1 measured through the REAL handler: a standalone
  //         operator token produced no block AND no ledger row, so BOTH halves of
  //         #2249 (the refusal and the diagnosis) were skipped together. Driven
  //         through the handler on purpose — the classify table alone cannot see
  //         the early-return path that lost the ledger row.
  resetLedger();
  const spaced = await drive("( electron . &)");
  check("H12 handler: BLOCKS a standalone-`(` bracketed launch", Boolean(spaced?.block),
    `block=${Boolean(spaced?.block)}`);
  check("H12a …and WROTE its ledger row (the diagnosis half)", ledgerRows().length === 1,
    `rows=${ledgerRows().length}`);
  resetLedger();
  const lookup = await drive("command -v electron");
  check("H12b handler: `command -v electron` is ALLOWED and not recorded",
    lookup === undefined && ledgerRows().length === 0,
    `allowed=${lookup === undefined} rows=${ledgerRows().length}`);

  // ── H13/H14 — review cycle 5's two findings measured through the REAL handler.
  //         F1: an attached `-c` argument lost the block, and an attached `-a`
  //         lost the RECORD (R1, the diagnosis half). F2: a `<<` in a comment
  //         deleted the rest of the command, losing both. Driven through the
  //         handler on purpose — only the handler shows the ledger row.
  resetLedger();
  const attachedC = await drive('bash -c"npm exec electron ."');
  check("H13 handler: BLOCKS an attached `-c` argument", Boolean(attachedC?.block),
    `block=${Boolean(attachedC?.block)}`);
  check("H13a …and WROTE its ledger row", ledgerRows().length === 1, `rows=${ledgerRows().length}`);
  resetLedger();
  const attachedA = await drive("open -aDMeer");
  check("H13b handler: an attached `-a<name>` is RECORDED, never refused",
    attachedA === undefined && ledgerRows().length === 1,
    `allowed=${attachedA === undefined} rows=${ledgerRows().length}`);
  resetLedger();
  const commented = await drive("# usage: write a file with cat <<EOF\nnpm exec electron .");
  check("H14 handler: BLOCKS a launch after a comment carrying `<<`", Boolean(commented?.block),
    `block=${Boolean(commented?.block)}`);
  check("H14a …and WROTE its ledger row", ledgerRows().length === 1, `rows=${ledgerRows().length}`);

  // ── H15 — a REMOVED cwd must never throw out of the pre-hook (review P1).
  //         `laneContract()` reaches `process.cwd()`, which throws ENOENT once the
  //         lane's worktree has been reaped; print mode short-circuits the guarded
  //         copy in `isUnattended()`, so the throw landed in the handler and FAILED
  //         the lane's own bash call while losing both halves of #2249. The fixture
  //         is the real thing: chdir into a temp dir, delete it, and `process.cwd()`
  //         throws `uv_cwd` (macOS and Linux both). Driven through the handler on
  //         purpose — only the handler runs the unguarded call.
  const GONE = mkdtempSync(join(tmpdir(), "gui-device-guard-gone-cwd-"));
  laneMod._resetLaneContractForTest();
  process.chdir(GONE);
  rmSync(GONE, { recursive: true, force: true });
  let cwdThrew = null;
  try { process.cwd(); } catch (e) { cwdThrew = e; }
  check("H15 fixture: process.cwd() throws once the cwd is removed", cwdThrew !== null,
    String(cwdThrew));
  resetLedger();
  let goneResult = null;
  let goneThrew = null;
  try { goneResult = await drive("npm exec electron ."); } catch (e) { goneThrew = e; }
  process.chdir(HERE);
  const goneRows = ledgerRows();
  laneMod._resetLaneContractForTest();
  check("H15a handler: an unreadable cwd does NOT throw out of the tool_call pre-hook",
    goneThrew === null, String(goneThrew));
  check("H15b …and the launch is still BLOCKED (the refusal half)",
    Boolean(goneResult?.block), `block=${Boolean(goneResult?.block)}`);
  check("H15c …and its ledger row is written, naming the unreadable cwd",
    goneRows.length === 1 && goneRows[0].cwd === "<cwd removed>",
    `rows=${JSON.stringify(goneRows).slice(0, 200)}`);
}

// ── drift pins ─────────────────────────────────────────────────────────────
const source = readFileSync(INDEX_TS, "utf8");
check("drift-pin: imports shared/git-command-parse.js (the ONE quote model)",
  source.includes('from "../shared/git-command-parse.js"'));
check("drift-pin: imports shared/print-mode.js + shared/headless-lane.js (derived, not launcher-set)",
  source.includes('from "../shared/print-mode.js"') && source.includes('from "../shared/headless-lane.js"'));
check("drift-pin: does not re-implement a quote model",
  !/function\s+unquotedMask/.test(source));
check("drift-pin: imports the ONE isToolCallEventType copy (#1330)",
  source.includes('from "../shared/tool-call-event.js"'));

// ── non-vacuity floor: the table is not empty and both polarities ran ──────
check("non-vacuity: the threat table carries >= 20 rows", ROWS.length >= 20, `rows=${ROWS.length}`);
check("non-vacuity: the table holds BLOCK rows and ALLOW rows",
  ROWS.some((r) => r[2] > 0) && ROWS.some((r) => r[2] === 0));
check("non-vacuity: the handler was driven", handler !== null && pass >= 25, `pass=${pass}`);

rmSync(FIX, { recursive: true, force: true });

console.log(`\n${fail === 0 ? "✅" : "❌"} gui-device-guard suite: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
